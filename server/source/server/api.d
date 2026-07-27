/// Server-Client API
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.api;

import core.atomic : atomicLoad, atomicStore;
import core.thread;
import core.time : Duration, MonoTime, dur;
import core.sync.mutex;
import core.sync.condition;

import std.json;
import std.conv : to;
import std.socket;
import std.string : strip;

import ddlogger;
import ddcurl;

import server.authdelegate;
import server.content;
import server.events;
import server.friends;
import server.instancecache;
import server.moderations;
import server.ratelimit;
import server.database;
import server.stream;
import server.worldcache;
import server.config : DEFAULT_RESEED_INTERVAL;
import server.vrchat.auth : postJSON, putJSON;
import vrcd.notifications;

/// Protocol version reported in `auth_ok`. 1 = base, 2 = content API,
/// 3 = moderation API, 4 = notification listing (`get_notifications`).
private enum int PROTOCOL_VERSION = 4;

/// How many notifications to pull for `get_notifications`. The inbox only
/// holds things still waiting on an answer, so this is a ceiling nobody
/// realistically reaches rather than a page size.
private enum int NOTIFICATION_FETCH_LIMIT = 100;

/// How many GET /users/:id calls one `get_notifications` may spend resolving
/// sender names the friend roster could not answer.
private enum int NOTIFICATION_SENDER_LOOKUPS = 12;

/// Callback invoked by the re-seed worker to actually perform a full
/// re-seed pass. The callback owns HTTPClient/RateLimitTracker access and
/// must acquire the shared API mutex itself. Returns the newly-built friend
/// map; the worker will swap it into the tracker and broadcast a snapshot.
alias ReseedCallback = void delegate();

/// TCP JSON-L API server for clients.
class APIServer
{
    private ushort port;
    private string bindAddr;
    private string sharedSecret;
    private Database store;
    private Thread acceptThread;
    private bool running;
    private Mutex clientsMutex;
    private ClientHandler[] clients;
    private bool vrchatConnected;
    private string vrchatLastError;
    private FriendsTracker friendsTracker;
    private ModerationsTracker moderationsTracker;
    private WorldCache worldCache;
    private InstanceCache instanceCache;
    private HTTPClient httpClient;
    private ContentService contentService;
    private Mutex apiMutex; // Shared VRChat API serializer, injected via setAPIMutex.
    private AuthDelegator authDelegator;
    private DropaPortalDelegator dapDelegator;
    private void delegate() dapPairTrigger;
    private RateLimitTracker rateLimiter;
    private void* sslCtx;
    private ushort tlsPort;
    private bool tlsOnly;

    // Re-seed worker state.
    private Thread reseedThread;
    private Mutex reseedSignalMutex;
    private Condition reseedSignalCond;
    private bool reseedRequested;
    private ReseedCallback reseedCallback;
    private MonoTime lastReseedAt;
    private bool firstReseed = true;
    private Duration reseedInterval;

    this(string bindAddr, ushort port, string sharedSecret, Database store,
        Duration reseedInterval = DEFAULT_RESEED_INTERVAL)
    {
        this.bindAddr = bindAddr;
        this.port = port;
        this.sharedSecret = sharedSecret;
        this.store = store;
        this.clientsMutex = new Mutex();
        this.friendsTracker = new FriendsTracker();
        this.moderationsTracker = new ModerationsTracker();
        this.reseedSignalMutex = new Mutex();
        this.reseedSignalCond = new Condition(this.reseedSignalMutex);
        this.reseedInterval = reseedInterval;
    }

    /// Access the friends tracker (e.g. to seed from REST API).
    FriendsTracker getFriendsTracker()
    {
        return friendsTracker;
    }

    /// Access the moderations tracker (mutes/blocks).
    ModerationsTracker getModerationsTracker()
    {
        return moderationsTracker;
    }

    /// Set the world cache for resolving world names.
    void setWorldCache(WorldCache wc)
    {
        worldCache = wc;
    }

    /// Set the instance cache for resolving instance occupancy.
    void setInstanceCache(InstanceCache ic)
    {
        instanceCache = ic;
    }

    /// Set the HTTP client for proxying VRChat API calls.
    void setHTTPClient(HTTPClient client)
    {
        httpClient = client;
    }

    /// Set the content service (gallery/icons/stickers/emoji/prints/inventory).
    void setContentService(ContentService cs)
    {
        contentService = cs;
    }

    /// Set the shared VRChat API mutex. All HTTPClient + RateLimitTracker
    /// access across the server goes through this mutex.
    void setAPIMutex(Mutex m)
    {
        apiMutex = m;
    }

    /// Install the re-seed callback invoked by the re-seed worker thread.
    /// The callback is responsible for acquiring the API mutex, fetching,
    /// repairing, and calling friendsTracker.replaceAll() on success.
    /// After a successful pass, broadcastFriendsSnapshot() is called by
    /// the worker automatically.
    void setReseedCallback(ReseedCallback cb)
    {
        reseedCallback = cb;
    }

    /// Set the rate limit tracker for monitoring VRChat API limits.
    void setRateLimiter(RateLimitTracker rl)
    {
        rateLimiter = rl;
    }

    /// Set the TLS context for encrypting client connections.
    /// When tlsPort is non-zero, TLS runs on a separate port; otherwise
    /// the main port performs TLS handshakes for every connection.
    /// When tlsOnly is true and a TLS context is set, the plain TCP
    /// listener is not started.
    void setTLS(void* ctx, ushort separatePort = 0, bool onlyTls = false)
    {
        sslCtx = ctx;
        tlsPort = separatePort;
        tlsOnly = onlyTls;
    }

    /// Set the auth delegator for headless auth delegation to clients.
    void setAuthDelegator(AuthDelegator d)
    {
        authDelegator = d;
        // When the auth thread needs input, broadcast to all authenticated clients.
        d.setBroadcastCallback((JSONValue msg) {
            string line = msg.toString() ~ "\n";
            clientsMutex.lock();
            scope(exit) clientsMutex.unlock();
            foreach (client; clients)
            {
                if (client.authenticated)
                    client.sendLine(line);
            }
        });
    }

    /// Set the Drop-a-Portal pair-request delegator. Mirrors the auth
    /// delegator wiring: messages broadcast to all authenticated clients,
    /// and clients connecting mid-flow get a replay via handleAuth.
    /// `pairTrigger` is invoked when a client sends `dap_pair_start`.
    void setDropaPortalDelegator(DropaPortalDelegator d, void delegate() pairTrigger)
    {
        dapDelegator = d;
        dapPairTrigger = pairTrigger;
        d.setBroadcastCallback((JSONValue msg) {
            string line = msg.toString() ~ "\n";
            clientsMutex.lock();
            scope(exit) clientsMutex.unlock();
            foreach (client; clients)
            {
                if (client.authenticated)
                    client.sendLine(line);
            }
        });
    }

    /// Update VRChat connection status and broadcast to all clients.
    void setVRChatStatus(bool connected, string lastError)
    {
        vrchatConnected = connected;
        if (lastError.length > 0)
            vrchatLastError = lastError;
        else if (connected)
            vrchatLastError = null;
        broadcastStatus();
    }

    /// Start accepting client connections.
    void start()
    {
        if (running)
            return;
        running = true;

        // When a separate TLS port is configured, start two listeners:
        // one for plain TCP and one for TLS. When tlsOnly is set and TLS
        // is active, skip the plain listener entirely.
        bool hasTls = sslCtx !is null;
        bool separatePort = hasTls && tlsPort != 0 && tlsPort != port;

        if (separatePort)
        {
            if (tlsOnly == false)
            {
                acceptThread = new Thread({ acceptLoop(port, false); });
                acceptThread.isDaemon = true;
                acceptThread.start();
            }
            Thread tlsThread = new Thread({ acceptLoop(tlsPort, true); });
            tlsThread.isDaemon = true;
            tlsThread.start();
        }
        else
        {
            // Single port: TLS wraps every connection when context is set.
            acceptThread = new Thread({ acceptLoop(port, hasTls); });
            acceptThread.isDaemon = true;
            acceptThread.start();
        }

        reseedThread = new Thread(&reseedLoop);
        reseedThread.isDaemon = true;
        reseedThread.start();
    }

    /// Stop the server.
    void stop()
    {
        running = false;
        // Wake the reseed worker so it can exit promptly.
        reseedSignalMutex.lock();
        reseedSignalCond.notifyAll();
        reseedSignalMutex.unlock();
    }

    /// Request a re-seed as soon as possible. Safe to call from any thread.
    /// The request is coalesced: multiple calls before the worker wakes
    /// result in a single pass. A 60-second debounce against the last
    /// completed re-seed prevents reconnect storms from amplifying load.
    void requestReseed()
    {
        reseedSignalMutex.lock();
        scope(exit) reseedSignalMutex.unlock();

        MonoTime now = MonoTime.currTime;
        if (firstReseed == false && (now - lastReseedAt) < dur!"seconds"(60))
        {
            logDebugging("requestReseed: ignored (debounced, last=%d ms ago)",
                (now - lastReseedAt).total!"msecs");
            return;
        }

        reseedRequested = true;
        reseedSignalCond.notifyAll();
        logDebugging("requestReseed: signaled");
    }

    /// Broadcast a fresh friends snapshot to all authenticated clients.
    void broadcastFriendsSnapshot()
    {
        string line = friendsTracker.buildFriendsMessage().toString() ~ "\n";

        clientsMutex.lock();
        scope(exit) clientsMutex.unlock();

        size_t delivered;
        foreach (client; clients)
        {
            if (client.authenticated)
            {
                client.sendLine(line);
                ++delivered;
            }
        }
        logDebugging("broadcastFriendsSnapshot: clients=%d/%d",
            delivered, clients.length);
    }

    /// Broadcast the current moderations snapshot to all authenticated
    /// clients. Called after a successful moderate_user mutation.
    void broadcastModerationsSnapshot()
    {
        string line = moderationsTracker.buildModerationsMessage().toString() ~ "\n";

        clientsMutex.lock();
        scope(exit) clientsMutex.unlock();

        size_t delivered;
        foreach (client; clients)
        {
            if (client.authenticated)
            {
                client.sendLine(line);
                ++delivered;
            }
        }
        logDebugging("broadcastModerationsSnapshot: clients=%d/%d",
            delivered, clients.length);
    }

    /// Broadcast a single event line to all authenticated clients.
    /// Tracker orchestration (state diff, synthetics, friends snapshot)
    /// lives in main.d so the suppression decision is in one place.
    void broadcast(VRCEvent event, long eventId)
    {
        string line = buildEventMessage(event, eventId).toString() ~ "\n";

        clientsMutex.lock();
        scope(exit) clientsMutex.unlock();

        size_t delivered;
        foreach (client; clients)
        {
            if (client.authenticated)
            {
                client.sendLine(line);
                ++delivered;
            }
        }

        logDebugging("broadcast: id=%d type=%s clients=%d/%d",
            eventId, event.typeRaw, delivered, clients.length);
    }

    /// Broadcast the current self snapshot to all authenticated clients.
    void broadcastSelf()
    {
        JSONValue self = friendsTracker.buildSelfMessage();
        if (self.type == JSONType.null_)
            return;
        string line = self.toString() ~ "\n";

        clientsMutex.lock();
        scope(exit) clientsMutex.unlock();

        foreach (client; clients)
            if (client.authenticated)
                client.sendLine(line);
    }

    /// Broadcast current status to all authenticated clients.
    void broadcastStatus()
    {
        string line = buildStatusMessage().toString() ~ "\n";

        clientsMutex.lock();
        scope(exit) clientsMutex.unlock();

        size_t delivered;
        foreach (client; clients)
        {
            if (client.authenticated)
            {
                client.sendLine(line);
                ++delivered;
            }
        }
        logDebugging("broadcastStatus: vrchatConnected=%s clients=%d/%d",
            vrchatConnected, delivered, clients.length);
    }

    /// Build a status JSON message.
    JSONValue buildStatusMessage()
    {
        JSONValue msg = JSONValue([
            "type": JSONValue("status"),
            "vrchat_connected": JSONValue(vrchatConnected),
        ]);
        if (vrchatLastError)
            msg["vrchat_last_error"] = JSONValue(vrchatLastError);
        if (rateLimiter)
        {
            int remaining = rateLimiter.getRemaining();
            int max = rateLimiter.getMax();
            if (remaining >= 0)
                msg["ratelimit_remaining"] = JSONValue(remaining);
            if (max > 0)
                msg["ratelimit_max"] = JSONValue(max);
            if (rateLimiter.isBlocked())
                msg["rate_limited"] = JSONValue(true);
        }
        return msg;
    }

private:
    void acceptLoop(ushort listenOnPort, bool useTls)
    {
        TcpSocket listener = new TcpSocket();
        listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
        listener.bind(new InternetAddress(bindAddr, listenOnPort));
        listener.listen(5);
        listener.blocking = true;

        logInfo("API server listening on %s:%d%s", bindAddr, listenOnPort,
            useTls ? " (TLS)" : "");

        while (running)
        {
            Socket clientSock = listener.accept();
            if (clientSock is null)
                continue;

            string remote = clientSock.remoteAddress().toString();
            logInfo("Client connected from %s%s", remote, useTls ? " (TLS)" : "");

            // Every broadcast sends to each client while holding clientsMutex,
            // so a client that stops reading would otherwise block in send()
            // once its window fills and take the whole server with it: no
            // events for anyone, and acceptLoop stuck registering the next
            // connection. A bounded timeout turns that into one dropped client.
            clientSock.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO,
                SEND_TIMEOUT);

            Stream stream;
            if (useTls)
            {
                try
                    stream = new TLSServerStream(clientSock, sslCtx);
                catch (Exception e)
                {
                    logWarn("TLS handshake failed from %s: %s", remote, e.msg);
                    clientSock.close();
                    continue;
                }
            }
            else
                stream = new PlainStream(clientSock);

            ClientHandler handler = new ClientHandler(stream, this);

            clientsMutex.lock();
            clients ~= handler;
            size_t total = clients.length;
            clientsMutex.unlock();
            logDebugging("acceptLoop: new client %s; total=%d", remote, total);

            Thread t = new Thread(&handler.run);
            t.isDaemon = true;
            t.start();
        }

        listener.close();
        logDebugging("acceptLoop: listener closed");
    }

    void removeClient(ClientHandler handler)
    {
        clientsMutex.lock();
        scope(exit) clientsMutex.unlock();

        ClientHandler[] updated;
        foreach (c; clients)
            if (c !is handler)
                updated ~= c;
        clients = updated;
    }

    void reseedLoop()
    {
        logInfo("Re-seed worker started (interval=%d minutes)",
            reseedInterval.total!"minutes");

        while (running)
        {
            bool signaled;
            reseedSignalMutex.lock();
            if (reseedRequested == false)
            {
                reseedSignalCond.wait(reseedInterval);
            }
            signaled = reseedRequested;
            reseedRequested = false;
            reseedSignalMutex.unlock();

            if (running == false)
                break;

            if (reseedCallback is null)
            {
                logWarn("Re-seed worker: no callback installed, skipping");
                continue;
            }

            logInfo("Re-seed worker: starting pass (signaled=%s)", signaled);
            try
            {
                reseedCallback();
                broadcastFriendsSnapshot();
            }
            catch (Exception e)
            {
                logError("Re-seed worker: pass failed: %s", e.msg);
            }

            reseedSignalMutex.lock();
            lastReseedAt = MonoTime.currTime;
            firstReseed = false;
            reseedSignalMutex.unlock();
        }

        logDebugging("reseedLoop: exited");
    }
}

/// How often to send a keepalive ping to connected clients.
private enum Duration PING_INTERVAL = dur!"seconds"(30);
/// How long to wait for a pong before treating the client as dead.
private enum Duration PONG_DEADLINE  = dur!"seconds"(15);
/// How long a single send may make no progress before the client is dropped.
private enum Duration SEND_TIMEOUT   = dur!"seconds"(10);

/// Handles a single client connection.
private class ClientHandler
{
    Stream stream;
    APIServer server;
    bool authenticated;
    private Mutex sendMutex;
    private Mutex pongMutex;
    private MonoTime lastPongAt;
    private shared bool disconnected;

    this(Stream stream, APIServer server)
    {
        this.stream = stream;
        this.server = server;
        this.sendMutex = new Mutex();
        this.pongMutex = new Mutex();
        this.lastPongAt = MonoTime.currTime;
    }

    void sendLine(string line)
    {
        sendMutex.lock();
        scope(exit) sendMutex.unlock();

        logTrace("sendLine: len=%d", line.length);
        // Plain TCP sockets may accept fewer bytes than requested on large
        // payloads (e.g. base64 image lines); loop until everything is out
        // or the connection dies.
        try
        {
            const(void)[] remaining = cast(const(void)[]) line;
            while (remaining.length > 0)
            {
                ptrdiff_t sent = stream.send(remaining);
                if (sent <= 0)
                {
                    // Errored or hit the send timeout part-way through a line.
                    // Half a JSON object is worse than no connection, so end
                    // it here and let the client reconnect and re-sync.
                    logWarn("sendLine: stalled with %d of %d bytes left, dropping client",
                        remaining.length, line.length);
                    stream.shutdown();
                    break;
                }
                remaining = remaining[sent .. $];
            }
        }
        catch (Exception e)
        {
            logDebugging("sendLine: send failed, client will be cleaned up: %s", e.msg);
            stream.shutdown();
        }
    }

    void run()
    {
        Thread pingThread = new Thread(&pingLoop);
        pingThread.isDaemon = true;
        pingThread.start();

        scope(exit)
        {
            atomicStore(disconnected, true);
            logInfo("Client disconnected");
            server.removeClient(this);
            stream.close();
        }

        // Upload messages carry base64 image data (a 10 MB PNG is ~13.7 MB
        // in base64, plus JSON envelope); anything past this is abuse.
        enum size_t MAX_LINE_LENGTH = 32 * 1024 * 1024;

        char[8192] buf;
        string buffer;

        while (true)
        {
            ptrdiff_t received = stream.receive(buf[]);
            if (received <= 0)
                break;

            buffer ~= cast(string) buf[0 .. received];

            if (buffer.length > MAX_LINE_LENGTH)
            {
                logWarn("Client exceeded maximum line length, disconnecting");
                break;
            }

            // Process complete lines.
            while (true)
            {
                import std.string : indexOf;
                ptrdiff_t nlPos = buffer.indexOf('\n');
                if (nlPos < 0)
                    break;

                string line = buffer[0 .. nlPos].strip();
                buffer = buffer[nlPos + 1 .. $];

                if (line.length == 0)
                    continue;

                processMessage(line);
            }
        }
    }

    void processMessage(string line)
    {
        try
        {
            JSONValue msg = parseJSON(line);
            string type;
            if (const(JSONValue)* v = "type" in msg)
                type = v.str;

            // Keepalives arrive twice a minute per client and say nothing;
            // logging them buries everything else at debugging level.
            if (type != "pong" && type != "ping")
                logDebugging("processMessage: type=%s authenticated=%s len=%d",
                    type, authenticated, line.length);

            switch (type)
            {
                case "auth":
                    handleAuth(msg);
                    break;
                case "catch_up":
                    if (authenticated == false)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    handleCatchUp(msg);
                    break;
                case "fetch_older":
                    if (authenticated == false)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    handleFetchOlder(msg);
                    break;
                case "status":
                    if (authenticated == false)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    sendLine(server.buildStatusMessage().toString() ~ "\n");
                    break;
                case "get_friends":
                    if (authenticated == false)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    handleGetFriends();
                    break;
                case "get_world":
                    if (authenticated == false)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    handleGetWorld(msg);
                    break;
                case "get_moderations":
                    if (authenticated == false)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    handleGetModerations();
                    break;
                case "moderate_user":
                    if (authenticated == false)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    handleModerateUser(msg);
                    break;
                case "unfriend":
                    if (authenticated == false)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    handleUnfriend(msg);
                    break;
                case "get_notifications":
                    if (authenticated == false)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    handleGetNotifications();
                    break;
                case "notification_action":
                    if (authenticated == false)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    handleNotificationAction(msg);
                    break;
                case "join_instance":
                    if (authenticated == false)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    handleJoinInstance(msg);
                    break;
                case "set_status":
                    if (authenticated == false)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    handleSetStatus(msg);
                    break;
                case "auth_response":
                    if (authenticated == false)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    handleAuthResponse(msg);
                    break;
                case "dap_pair_start":
                    if (authenticated == false)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    if (server.dapPairTrigger)
                        server.dapPairTrigger();
                    else
                        sendError("Drop-a-Portal not configured");
                    break;
                case "dap_pair_cancel":
                    if (authenticated == false)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    if (server.dapDelegator)
                        server.dapDelegator.cancel();
                    break;
                case "get_stats":
                    if (authenticated == false)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    handleGetStats();
                    break;
                case "get_files":
                    if (authenticated == false)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    handleGetFiles(msg);
                    break;
                case "get_prints":
                    if (authenticated == false)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    handleGetPrints();
                    break;
                case "get_inventory":
                    if (authenticated == false)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    handleGetInventory(msg);
                    break;
                case "get_inventory_drops":
                    if (authenticated == false)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    handleGetInventoryDrops();
                    break;
                case "get_image":
                    if (authenticated == false)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    handleGetImage(msg);
                    break;
                case "delete_file":
                    if (authenticated == false)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    handleDeleteFile(msg);
                    break;
                case "delete_print":
                    if (authenticated == false)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    handleDeletePrint(msg);
                    break;
                case "set_user_icon":
                    if (authenticated == false)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    handleSetUserIcon(msg);
                    break;
                case "inventory_action":
                    if (authenticated == false)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    handleInventoryAction(msg);
                    break;
                case "upload_image":
                    if (authenticated == false)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    handleUploadImage(msg);
                    break;
                case "upload_print":
                    if (authenticated == false)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    handleUploadPrint(msg);
                    break;
                case "pong":
                    pongMutex.lock();
                    lastPongAt = MonoTime.currTime;
                    pongMutex.unlock();
                    break;
                default:
                    sendError("Unknown message type: " ~ type);
                    break;
            }
        }
        catch (Exception e)
        {
            sendError("Error processing: "~e.msg);
        }
    }

    void handleAuth(JSONValue msg)
    {
        string token;
        if (const(JSONValue)* v = "token" in msg)
            token = v.str;
        if (server.sharedSecret.length == 0 || token == server.sharedSecret)
        {
            authenticated = true;
            JSONValue resp = JSONValue([
                "type": JSONValue("auth_ok"),
                "server_version": JSONValue(PROTOCOL_VERSION),
            ]);
            sendLine(resp.toString() ~ "\n");
            // Send current status immediately after auth.
            sendLine(server.buildStatusMessage().toString() ~ "\n");
            // Send self snapshot so the client knows its own status/description.
            JSONValue selfMsg = server.friendsTracker.buildSelfMessage();
            if (selfMsg.type != JSONType.null_)
                sendLine(selfMsg.toString() ~ "\n");
            logInfo("Client authenticated");

            // If there is a pending VRChat auth request, send it to this client.
            if (server.authDelegator && server.authDelegator.hasPendingRequest())
            {
                JSONValue authReq = server.authDelegator.getPendingRequestMessage();
                if (authReq.type != JSONType.null_)
                    sendLine(authReq.toString() ~ "\n");
            }

            // If a Drop-a-Portal pair flow is active, replay the prompt so
            // a client connecting mid-flow can show the code. Otherwise send
            // the standing pair status so the UI reflects the current state
            // (paired or not) without re-triggering the pairing feed event.
            // These are mutually exclusive: the standing status would clobber
            // the pairing prompt on the client.
            if (server.dapDelegator)
            {
                if (server.dapDelegator.hasPendingRequest())
                {
                    JSONValue dapReq = server.dapDelegator.getPendingRequestMessage();
                    if (dapReq.type != JSONType.null_)
                        sendLine(dapReq.toString() ~ "\n");
                }
                else
                {
                    JSONValue dapStat = server.dapDelegator.getPairStatusMessage();
                    if (dapStat.type != JSONType.null_)
                        sendLine(dapStat.toString() ~ "\n");
                }
            }
        }
        else
        {
            JSONValue resp = JSONValue([
                "type": JSONValue("auth_error"),
                "message": JSONValue("Invalid token"),
            ]);
            sendLine(resp.toString() ~ "\n");
            logWarn("Client auth failed");
        }
    }

    void handleCatchUp(JSONValue msg)
    {
        long sinceId = 0;
        if ("since_id" in msg)
        {
            JSONValue val = msg["since_id"];
            if (val.type == JSONType.integer)
                sinceId = val.get!long;
            else if (val.type == JSONType.string)
                sinceId = val.str.to!long;
        }

        logInfo("Client catching up from event #%d", sinceId);

        enum int batchSize = 1000;
        long lastId = sinceId;
        long sent;
        while (true)
        {
            long batchSent;
            foreach (row; server.store.queryEventsAfter(lastId, batchSize))
            {
                long id = row[0].to!long;
                JSONValue eventMsg = JSONValue([
                    "type": JSONValue("event"),
                    "id": JSONValue(id),
                    "received_at": JSONValue(row[1].to!string),
                    "event_type": JSONValue(row[2].to!string),
                    "content": vrcContent(row[3].to!string),
                ]);
                sendLine(eventMsg.toString() ~ "\n");
                lastId = id;
                ++sent;
                ++batchSent;
            }
            if (batchSent < batchSize)
                break;
        }

        JSONValue doneMsg = JSONValue([
            "type": JSONValue("caught_up"),
            "last_id": JSONValue(lastId),
        ]);
        sendLine(doneMsg.toString() ~ "\n");
        logDebugging("handleCatchUp: sent %d events, lastId=%d", sent, lastId);
        logInfo("Client caught up to event #%d", lastId);
    }

    /// Refresh instance occupancy for every public instance that has at
    /// least one friend in it, then send the friends snapshot. Caps the
    /// number of fetches per refresh to avoid spamming the VRChat API.
    /// Send a page of older events (id < before_id) for UI back-fill.
    /// Events are sent newest-first as `event_older` messages, capped at
    /// the requested limit (hard cap 500), followed by an `older_fetched`
    /// terminator carrying the oldest id in the page (or the floor sentinel).
    void handleFetchOlder(JSONValue msg)
    {
        long beforeId;
        if (const(JSONValue)* v = "before_id" in msg)
        {
            if (v.type == JSONType.integer)
                beforeId = v.integer;
            else if (v.type == JSONType.string)
                beforeId = v.str.to!long;
        }
        int limit = 100;
        if (const(JSONValue)* v = "limit" in msg)
        {
            if (v.type == JSONType.integer)
                limit = cast(int) v.integer;
            else if (v.type == JSONType.string)
                limit = v.str.to!int;
        }
        if (limit <= 0)
            limit = 100;
        if (limit > 500)
            limit = 500;

        logInfo("Client fetching older events: before=%d limit=%d", beforeId, limit);

        long oldestId = beforeId;
        long sent;
        if (beforeId > 0)
        {
            foreach (row; server.store.queryEventsBefore(beforeId, limit))
            {
                long id = row[0].to!long;
                JSONValue eventMsg = JSONValue([
                    "type": JSONValue("event_older"),
                    "id": JSONValue(id),
                    "received_at": JSONValue(row[1].to!string),
                    "event_type": JSONValue(row[2].to!string),
                    "content": vrcContent(row[3].to!string),
                ]);
                sendLine(eventMsg.toString() ~ "\n");
                oldestId = id;
                ++sent;
            }
        }

        JSONValue doneMsg = JSONValue([
            "type": JSONValue("older_fetched"),
            "before_id": JSONValue(beforeId),
            "oldest_id": JSONValue(oldestId),
            "count": JSONValue(sent),
        ]);
        sendLine(doneMsg.toString() ~ "\n");
        logDebugging("handleFetchOlder: sent %d events, before=%d oldest=%d",
            sent, beforeId, oldestId);
    }

    void handleGetFriends()
    {
        enum int INSTANCE_REFRESH_CAP = 20;

        if (server.instanceCache && server.apiMutex)
        {
            // Gather unique resolvable locations from the current tracker
            // state. This snapshot is cheap and doesn't hold the API mutex.
            JSONValue pre = server.friendsTracker.buildFriendsMessage();
            string[] toRefresh;
            bool[string] seen;
            if (JSONValue* v = "instances" in pre)
            {
                foreach (ref JSONValue grp; v.array)
                {
                    // Prefer the full location (with ~type(usr) qualifier);
                    // /instances/{loc} only returns accurate n_users when the
                    // access type is present. Fall back to instance_id (the
                    // canonical form) for older snapshots that lack it.
                    string loc;
                    if (const(JSONValue)* l = "location" in grp)
                        loc = l.str;
                    if (loc.length == 0)
                        if (const(JSONValue)* l = "instance_id" in grp)
                            loc = l.str;
                    if (InstanceCache.isResolvable(loc) == false)
                        continue;
                    if (loc in seen)
                        continue;
                    seen[loc] = true;
                    toRefresh ~= loc;
                    if (toRefresh.length >= INSTANCE_REFRESH_CAP)
                        break;
                }
            }

            if (toRefresh.length > 0)
            {
                synchronized (server.apiMutex)
                {
                    foreach (string loc; toRefresh)
                    {
                        // Respect rate limit, stop early if we get blocked.
                        if (server.rateLimiter && server.rateLimiter.isBlocked())
                        {
                            logWarn("handleGetFriends: stopping refresh, rate limited");
                            break;
                        }
                        server.instanceCache.resolveLocked(loc);
                    }
                }
            }
        }

        sendLine(server.friendsTracker.buildFriendsMessage().toString() ~ "\n");
    }

    void handleGetWorld(JSONValue msg)
    {
        string worldId;
        if (const(JSONValue)* v = "world_id" in msg)
            worldId = v.str;
        if (worldId.length == 0)
        {
            sendError("Missing world_id");
            return;
        }

        string worldName = worldId;
        if (server.worldCache)
            worldName = server.worldCache.resolve(worldId);

        logDebugging("handleGetWorld: worldId=%s resolved=%s", worldId, worldName);

        JSONValue resp = JSONValue([
            "type": JSONValue("world"),
            "world_id": JSONValue(worldId),
            "world_name": JSONValue(worldName),
        ]);
        sendLine(resp.toString() ~ "\n");
    }

    /// Reply to `get_notifications`: fetch the pending notification list from
    /// VRChat and send a normalized `notifications` snapshot.
    ///
    /// The WebSocket only ever reports *changes*, so a front-end that starts
    /// mid-session has no way to learn about a friend request that arrived
    /// while it was down; reconstructing the inbox from the event log would
    /// only reach as far back as whatever page of events was fetched. This is
    /// the authoritative list, and the front-ends keep it current from the
    /// events afterwards.
    ///
    /// Always refetches. Notifications are few, asked for once per connect,
    /// and a stale inbox shows actions that no longer exist. Failures are
    /// reported inside the `notifications` message (not via `error`) so the
    /// client's loading state resolves.
    void handleGetNotifications()
    {
        void sendNotificationsError(string error)
        {
            JSONValue result = JSONValue([
                "type": JSONValue("notifications"),
                "notifications": JSONValue.emptyArray,
                "error": JSONValue(error),
            ]);
            sendLine(result.toString() ~ "\n");
        }

        if (server.httpClient is null || server.apiMutex is null)
        {
            sendNotificationsError("Server HTTP client not configured");
            return;
        }

        server.apiMutex.lock();
        scope(exit) server.apiMutex.unlock();

        if (server.rateLimiter && server.rateLimiter.isBlocked())
        {
            sendNotificationsError("Rate limited by VRChat, try again later");
            return;
        }

        try
        {
            // v1 covers exactly the actionable types (friend requests and
            // invites); the v2 endpoint carries badges and announcements the
            // inbox has no action to draw for.
            HTTPResponse resp = server.httpClient.get(
                "/auth/user/notifications?n=" ~ NOTIFICATION_FETCH_LIMIT.to!string());
            logDebugging("handleGetNotifications: VRC GET /auth/user/notifications -> HTTP %d",
                resp.code);
            if (server.rateLimiter)
            {
                server.rateLimiter.update(resp);
                server.broadcastStatus();
            }
            if (resp.code < 200 || resp.code >= 300)
            {
                sendNotificationsError("HTTP " ~ resp.code.to!string);
                return;
            }

            JSONValue json = parseJSON(resp.text);
            if (json.type != JSONType.array)
            {
                sendNotificationsError("Unexpected notifications response");
                return;
            }

            NotificationInfo[] parsed;
            foreach (JSONValue entry; json.array)
            {
                // VRChat no longer returns sender names, so try the roster
                // first: a raw usr_ ID reads as nothing, and an invite is
                // nearly always from someone already in it.
                string senderId;
                if (const(JSONValue)* v = "senderUserId" in entry)
                    if (v.type == JSONType.string)
                        senderId = v.str;

                NotificationInfo info = parseNotificationObject(entry,
                    senderId.length ? server.friendsTracker.getDisplayName(senderId) : null);
                if (info.id.length == 0) // Not actionable, or unusable.
                    continue;
                parsed ~= info;
            }

            // A friend request is precisely the case the roster cannot
            // answer: the sender is not a friend yet, which is the whole
            // point of the request. Look those up, since "accept or decline
            // usr_c3f2..." is not a question anyone can answer.
            resolveSenderNamesLocked(parsed);

            JSONValue[] items;
            items.reserve(parsed.length);
            foreach (ref NotificationInfo info; parsed)
                items ~= buildNotificationJSON(info);

            // Oldest first: the front-ends draw the inbox in this order, so a
            // new notification appends to the end instead of pushing every
            // Accept button down a row under the user's finger.
            sortNotificationsOldestFirst(items);

            JSONValue result = JSONValue([
                "type": JSONValue("notifications"),
                "notifications": JSONValue(items),
            ]);
            sendLine(result.toString() ~ "\n");
            logDebugging("handleGetNotifications: %d actionable of %d",
                items.length, json.array.length);
        }
        catch (Exception e)
        {
            sendNotificationsError(e.msg);
        }
    }

    /// Fill in sender names the roster could not, with one GET /users/:id
    /// each. Caller holds the API mutex.
    ///
    /// Capped rather than unbounded: this runs on every front-end connect,
    /// and an inbox someone let pile up should not turn a reconnect into a
    /// hundred API calls. Past the cap the ID stands in, which is ugly but
    /// honest. Senders repeat across notifications, so the cap counts
    /// lookups, not entries.
    void resolveSenderNamesLocked(ref NotificationInfo[] list)
    {
        string[string] resolved;
        int lookups;

        foreach (ref NotificationInfo info; list)
        {
            if (info.senderName.length > 0 || info.senderUserId.length == 0)
                continue;

            if (string *cached = info.senderUserId in resolved)
            {
                info.senderName = *cached;
                continue;
            }

            if (lookups >= NOTIFICATION_SENDER_LOOKUPS)
            {
                info.senderName = info.senderUserId;
                continue;
            }

            // Checked per lookup, not once up front: the first few calls can
            // be what tips the budget over.
            if (server.rateLimiter && server.rateLimiter.isBlocked())
            {
                info.senderName = info.senderUserId;
                continue;
            }

            ++lookups;
            string name = info.senderUserId;
            try
            {
                HTTPResponse resp = server.httpClient.get("/users/" ~ info.senderUserId);
                if (server.rateLimiter)
                    server.rateLimiter.update(resp);
                if (resp.code == 200)
                {
                    JSONValue user = parseJSON(resp.text);
                    if (user.type == JSONType.object)
                        if (const(JSONValue)* v = "displayName" in user)
                            if (v.type == JSONType.string && v.str.length > 0)
                                name = v.str;
                }
                else
                    logWarn("Notification sender: GET /users/%s -> HTTP %d",
                        info.senderUserId, resp.code);
            }
            catch (Exception e)
            {
                logWarn("Notification sender: GET /users/%s failed: %s",
                    info.senderUserId, e.msg);
            }

            resolved[info.senderUserId] = name;
            info.senderName = name;
        }

        if (lookups > 0)
            logDebugging("resolveSenderNamesLocked: %d lookup(s)", lookups);
    }

    void handleNotificationAction(JSONValue msg)
    {
        string notifId;
        if (const(JSONValue)* v = "notification_id" in msg)
            notifId = v.str;
        string action;
        if (const(JSONValue)* v = "action" in msg)
            action = v.str;

        if (notifId.length == 0 || action.length == 0)
        {
            sendError("Missing notification_id or action");
            return;
        }

        if (server.httpClient is null || server.apiMutex is null)
        {
            sendError("Server HTTP client not configured");
            return;
        }

        // Map action to VRChat API endpoint.
        string path;
        switch (action)
        {
            case "accept":
                path = "/auth/user/notifications/" ~ notifId ~ "/accept";
                break;
            case "hide":
                path = "/auth/user/notifications/" ~ notifId ~ "/hide";
                break;
            default:
                sendError("Unknown action: " ~ action);
                return;
        }

        logDebugging("handleNotificationAction: action=%s notifId=%s path=%s",
            action, notifId, path);

        // Call VRChat API (serialized via mutex).
        server.apiMutex.lock();
        scope(exit) server.apiMutex.unlock();

        // Wait out any active rate limit before calling.
        if (server.rateLimiter && server.rateLimiter.isBlocked())
        {
            sendError("Rate limited by VRChat, try again later");
            return;
        }

        try
        {
            HTTPResponse resp = server.httpClient.putJSON(path);
            logDebugging("handleNotificationAction: VRC PUT %s -> HTTP %d", path, resp.code);
            if (server.rateLimiter)
            {
                server.rateLimiter.update(resp);
                server.broadcastStatus();
            }
            bool success = resp.code >= 200 && resp.code < 300;
            // For hide, treat 404 as success: the notification is already
            // gone from VRChat (e.g. the friend request was accepted on
            // another client), which is the desired end state.
            if (success == false && action == "hide" && resp.code == 404)
                success = true;

            JSONValue result = JSONValue([
                "type": JSONValue("notification_action_result"),
                "notification_id": JSONValue(notifId),
                "action": JSONValue(action),
                "success": JSONValue(success),
            ]);
            if (success == false)
                result["error"] = JSONValue("HTTP " ~ resp.code.to!string);
            sendLine(result.toString() ~ "\n");
        }
        catch (Exception e)
        {
            JSONValue result = JSONValue([
                "type": JSONValue("notification_action_result"),
                "notification_id": JSONValue(notifId),
                "action": JSONValue(action),
                "success": JSONValue(false),
            ]);
            result["error"] = JSONValue(e.msg);
            sendLine(result.toString() ~ "\n");
        }
    }

    /// Self-invite the logged-in user to an instance ("Self-Invite" join).
    /// VRChat sends the account an invite to the given location, which the
    /// user then accepts in-game. Works on every platform (no URI handler or
    /// named pipe), so it is the cross-platform / Proton-friendly join path.
    void handleJoinInstance(JSONValue msg)
    {
        string location;
        if (const(JSONValue)* v = "location" in msg)
            location = v.str;

        if (location.length == 0)
        {
            sendError("Missing location");
            return;
        }

        if (server.httpClient is null || server.apiMutex is null)
        {
            sendError("Server HTTP client not configured");
            return;
        }

        server.apiMutex.lock();
        scope(exit) server.apiMutex.unlock();

        if (server.rateLimiter && server.rateLimiter.isBlocked())
        {
            sendError("Rate limited by VRChat, try again later");
            return;
        }

        try
        {
            // Restricted instances (friends/private/invite) require the
            // instance's shortName in the invite body; fetch it first. A
            // failure here is non-fatal: public instances self-invite fine
            // without it, so fall through and let the POST decide.
            string shortName;
            HTTPResponse snResp = server.httpClient.get(
                "/instances/" ~ location ~ "/shortName");
            if (server.rateLimiter)
                server.rateLimiter.update(snResp);
            if (snResp.code >= 200 && snResp.code < 300)
            {
                try
                {
                    JSONValue sn = parseJSON(snResp.text);
                    if (const(JSONValue)* v = "shortName" in sn)
                        shortName = v.str;
                }
                catch (Exception) {}
            }

            string body_;
            if (shortName.length > 0)
                body_ = JSONValue(["shortName": JSONValue(shortName)]).toString();

            HTTPResponse resp = server.httpClient.postJSON(
                "/invite/myself/to/" ~ location, body_);
            logDebugging("handleJoinInstance: POST /invite/myself/to/%s -> HTTP %d",
                location, resp.code);
            if (server.rateLimiter)
            {
                server.rateLimiter.update(resp);
                server.broadcastStatus();
            }
            bool success = resp.code >= 200 && resp.code < 300;

            JSONValue result = JSONValue([
                "type": JSONValue("join_instance_result"),
                "location": JSONValue(location),
                "success": JSONValue(success),
            ]);
            if (success == false)
                result["error"] = JSONValue("HTTP " ~ resp.code.to!string);
            sendLine(result.toString() ~ "\n");
        }
        catch (Exception e)
        {
            JSONValue result = JSONValue([
                "type": JSONValue("join_instance_result"),
                "location": JSONValue(location),
                "success": JSONValue(false),
            ]);
            result["error"] = JSONValue(e.msg);
            sendLine(result.toString() ~ "\n");
        }
    }

    void handleSetStatus(JSONValue msg)
    {
        // Either or both of status / status_description may be provided.
        // An omitted field means "leave unchanged".
        bool haveStatus;
        string status;
        if (const(JSONValue)* v = "status" in msg)
            if (v.type == JSONType.string)
            {
                status = v.str;
                haveStatus = true;
            }

        bool haveDesc;
        string desc;
        if (const(JSONValue)* v = "status_description" in msg)
            if (v.type == JSONType.string)
            {
                desc = v.str;
                haveDesc = true;
            }

        if (haveStatus == false && haveDesc == false)
        {
            sendError("set_status: nothing to update");
            return;
        }

        // VRChat only accepts these four values from the client.
        if (haveStatus)
        {
            switch (status)
            {
                case "active":
                case "join me":
                case "ask me":
                case "busy":
                    break;
                default:
                    sendError("set_status: invalid status '" ~ status ~ "'");
                    return;
            }
        }

        string selfId = server.friendsTracker.getSelfUserId();
        if (selfId.length == 0)
        {
            sendError("set_status: self user id not known yet");
            return;
        }

        if (server.httpClient is null || server.apiMutex is null)
        {
            sendError("Server HTTP client not configured");
            return;
        }

        JSONValue payload = parseJSON("{}");
        if (haveStatus)
            payload["status"] = JSONValue(status);
        if (haveDesc)
            payload["statusDescription"] = JSONValue(desc);

        string path = "/users/" ~ selfId;
        logDebugging("handleSetStatus: PUT %s body=%s", path, payload.toString());

        server.apiMutex.lock();
        scope(exit) server.apiMutex.unlock();

        if (server.rateLimiter && server.rateLimiter.isBlocked())
        {
            sendError("Rate limited by VRChat, try again later");
            return;
        }

        try
        {
            HTTPResponse resp = server.httpClient.putJSON(path, payload.toString());
            logDebugging("handleSetStatus: VRC PUT %s -> HTTP %d", path, resp.code);
            if (server.rateLimiter)
            {
                server.rateLimiter.update(resp);
                server.broadcastStatus();
            }
            bool success = resp.code >= 200 && resp.code < 300;

            JSONValue result = JSONValue([
                "type": JSONValue("set_status_result"),
                "success": JSONValue(success),
            ]);

            if (success)
            {
                // Update the tracker's self entry so the next self snapshot
                // reflects the new values immediately. Use values from the
                // response when present (canonical), otherwise fall back to
                // what we sent.
                string newStatus = status;
                string newDesc = desc;
                try
                {
                    JSONValue user = parseJSON(resp.text);
                    if (const(JSONValue)* v = "status" in user)
                        if (v.type == JSONType.string)
                            newStatus = v.str;
                    if (const(JSONValue)* v = "statusDescription" in user)
                        if (v.type == JSONType.string)
                            newDesc = v.str;
                }
                catch (Exception) {}

                server.friendsTracker.applySelfStatus(
                    haveStatus, newStatus, haveDesc, newDesc);
                server.broadcastSelf();
            }
            else
            {
                result["error"] = JSONValue("HTTP " ~ resp.code.to!string);
            }
            sendLine(result.toString() ~ "\n");
        }
        catch (Exception e)
        {
            JSONValue result = JSONValue([
                "type": JSONValue("set_status_result"),
                "success": JSONValue(false),
            ]);
            result["error"] = JSONValue(e.msg);
            sendLine(result.toString() ~ "\n");
        }
    }

    /// Reply to `get_moderations`: refetch the mute/block lists from VRChat
    /// and send a fresh `moderations` snapshot. Always refetches: VRChat has
    /// no WS events for player moderations, so the cache goes stale whenever
    /// the user moderates in-game, and the lists are small and rarely asked
    /// for. Failures are reported inside the `moderations` message (not via
    /// `error`) so the client's loading state resolves.
    void handleGetModerations()
    {
        void sendModerationsError(string error)
        {
            JSONValue result = JSONValue([
                "type": JSONValue("moderations"),
                "error": JSONValue(error),
            ]);
            sendLine(result.toString() ~ "\n");
        }

        if (server.httpClient is null || server.apiMutex is null)
        {
            sendModerationsError("Server HTTP client not configured");
            return;
        }

        server.apiMutex.lock();
        scope(exit) server.apiMutex.unlock();

        if (server.rateLimiter && server.rateLimiter.isBlocked())
        {
            sendModerationsError("Rate limited by VRChat, try again later");
            return;
        }

        try
        {
            HTTPResponse resp = server.httpClient.get("/auth/user/playermoderations");
            logDebugging("handleGetModerations: VRC GET /auth/user/playermoderations -> HTTP %d",
                resp.code);
            if (server.rateLimiter)
            {
                server.rateLimiter.update(resp);
                server.broadcastStatus();
            }
            if (resp.code < 200 || resp.code >= 300)
            {
                sendModerationsError("HTTP " ~ resp.code.to!string);
                return;
            }

            JSONValue json = parseJSON(resp.text);
            if (json.type != JSONType.array)
            {
                sendModerationsError("Unexpected playermoderations response");
                return;
            }

            server.moderationsTracker.replaceFromAPI(json.array);
            sendLine(server.moderationsTracker.buildModerationsMessage().toString() ~ "\n");
        }
        catch (Exception e)
        {
            sendModerationsError(e.msg);
        }
    }

    /// Add or remove a player moderation (mute/unmute/block/unblock).
    /// Replies with `moderate_result`; on success also broadcasts a fresh
    /// `moderations` snapshot to all authenticated clients.
    void handleModerateUser(JSONValue msg)
    {
        string userId;
        if (const(JSONValue)* v = "user_id" in msg)
            userId = v.str;
        string action;
        if (const(JSONValue)* v = "action" in msg)
            action = v.str;

        if (userId.length == 0 || action.length == 0)
        {
            sendError("Missing user_id or action");
            return;
        }

        // VRChat wants the moderation type; the action encodes both the
        // type and the direction (add/remove).
        string moderationType;
        bool adding;
        switch (action)
        {
            case "mute":    moderationType = "mute";  adding = true;  break;
            case "unmute":  moderationType = "mute";  adding = false; break;
            case "block":   moderationType = "block"; adding = true;  break;
            case "unblock": moderationType = "block"; adding = false; break;
            default:
                sendError("Unknown moderation action: " ~ action);
                return;
        }

        // From here on failures reply with moderate_result so the client's
        // in-flight state resolves.
        void sendResult(bool success, string displayName, string error)
        {
            JSONValue result = JSONValue([
                "type": JSONValue("moderate_result"),
                "success": JSONValue(success),
                "action": JSONValue(action),
                "user_id": JSONValue(userId),
                "display_name": JSONValue(displayName),
            ]);
            if (error.length > 0)
                result["error"] = JSONValue(error);
            sendLine(result.toString() ~ "\n");
        }

        // Best-known display name for feedback wording; the POST response
        // may improve on it below.
        string displayName = server.friendsTracker.getDisplayName(userId);
        if (displayName.length == 0)
            displayName = server.moderationsTracker.getDisplayName(userId);

        if (server.httpClient is null || server.apiMutex is null)
        {
            sendResult(false, displayName, "Server HTTP client not configured");
            return;
        }

        server.apiMutex.lock();
        scope(exit) server.apiMutex.unlock();

        if (server.rateLimiter && server.rateLimiter.isBlocked())
        {
            sendResult(false, displayName, "Rate limited by VRChat, try again later");
            return;
        }

        JSONValue payload = JSONValue([
            "moderated": JSONValue(userId),
            "type": JSONValue(moderationType),
        ]);

        try
        {
            HTTPResponse resp;
            if (adding)
                resp = server.httpClient.postJSON("/auth/user/playermoderations", payload.toString());
            else
                resp = server.httpClient.putJSON("/auth/user/unplayermoderate", payload.toString());
            logDebugging("handleModerateUser: action=%s user=%s -> HTTP %d",
                action, userId, resp.code);
            if (server.rateLimiter)
            {
                server.rateLimiter.update(resp);
                server.broadcastStatus();
            }
            bool success = resp.code >= 200 && resp.code < 300;
            if (success == false)
            {
                sendResult(false, displayName, "HTTP " ~ resp.code.to!string);
                return;
            }

            // The created PlayerModeration object carries the canonical
            // display name; useful when moderating a non-friend.
            if (adding)
            {
                try
                {
                    JSONValue mod = parseJSON(resp.text);
                    if (const(JSONValue)* v = "targetDisplayName" in mod)
                        if (v.type == JSONType.string && v.str.length > 0)
                            displayName = v.str;
                }
                catch (Exception) {}
            }

            server.moderationsTracker.apply(action, userId, displayName);
            sendResult(true, displayName, null);
            server.broadcastModerationsSnapshot();
        }
        catch (Exception e)
        {
            sendResult(false, displayName, e.msg);
        }
    }

    /// Remove a friend. Replies with `unfriend_result`; on success also
    /// removes the friend from the tracker eagerly and broadcasts a fresh
    /// `friends` snapshot (the friend-delete WS event arrives later).
    void handleUnfriend(JSONValue msg)
    {
        string userId;
        if (const(JSONValue)* v = "user_id" in msg)
            userId = v.str;

        if (userId.length == 0)
        {
            sendError("Missing user_id");
            return;
        }

        void sendResult(bool success, string displayName, string error)
        {
            JSONValue result = JSONValue([
                "type": JSONValue("unfriend_result"),
                "success": JSONValue(success),
                "user_id": JSONValue(userId),
                "display_name": JSONValue(displayName),
            ]);
            if (error.length > 0)
                result["error"] = JSONValue(error);
            sendLine(result.toString() ~ "\n");
        }

        string displayName = server.friendsTracker.getDisplayName(userId);

        if (server.httpClient is null || server.apiMutex is null)
        {
            sendResult(false, displayName, "Server HTTP client not configured");
            return;
        }

        server.apiMutex.lock();
        scope(exit) server.apiMutex.unlock();

        if (server.rateLimiter && server.rateLimiter.isBlocked())
        {
            sendResult(false, displayName, "Rate limited by VRChat, try again later");
            return;
        }

        try
        {
            HTTPResponse resp = server.httpClient.del("/auth/user/friends/" ~ userId);
            logDebugging("handleUnfriend: user=%s -> HTTP %d", userId, resp.code);
            if (server.rateLimiter)
            {
                server.rateLimiter.update(resp);
                server.broadcastStatus();
            }
            bool success = resp.code >= 200 && resp.code < 300;
            // Already not a friend: the desired end state, treat as success.
            if (success == false && resp.code == 404)
                success = true;

            if (success)
            {
                server.friendsTracker.removeFriend(userId);
                sendResult(true, displayName, null);
                server.broadcastFriendsSnapshot();
            }
            else
            {
                sendResult(false, displayName, "HTTP " ~ resp.code.to!string);
            }
        }
        catch (Exception e)
        {
            sendResult(false, displayName, e.msg);
        }
    }

    void handleAuthResponse(JSONValue msg)
    {
        if (server.authDelegator is null)
        {
            sendError("No auth delegation active");
            return;
        }

        // Check for cancellation.
        if ("cancelled" in msg && msg["cancelled"].type == JSONType.true_)
        {
            AuthResponse resp;
            resp.cancelled = true;
            server.authDelegator.submitResponse(resp);
            return;
        }

        string kind;
        if (const(JSONValue)* v = "kind" in msg)
            kind = v.str;
        AuthResponse resp;
        if (kind == "credentials")
        {
            if (const(JSONValue)* v = "username" in msg)
                resp.username = v.str;
            if (const(JSONValue)* v = "password" in msg)
                resp.password = v.str;
            logDebugging("handleAuthResponse: credentials for user=%s", resp.username);
        }
        else if (kind == "two_factor")
        {
            if (const(JSONValue)* v = "code" in msg)
                resp.code = v.str;
            logDebugging("handleAuthResponse: two_factor code received (len=%d)",
                resp.code.length);
        }
        else
        {
            sendError("Unknown auth_response kind: " ~ kind);
            return;
        }

        server.authDelegator.submitResponse(resp);
    }

    void handleGetStats()
    {
        DatabaseStats stats = server.store.getStats();
        JSONValue resp = JSONValue([
            "type": JSONValue("stats"),
            "event_count": JSONValue(stats.eventCount),
            "world_cache_count": JSONValue(stats.worldCacheCount),
            "avatar_cache_count": JSONValue(stats.avatarCacheCount),
            "db_size_bytes": JSONValue(stats.dbSizeBytes),
        ]);
        sendLine(resp.toString() ~ "\n");
        logDebugging("handleGetStats: events=%d worlds=%d avatars=%d db_bytes=%d",
            stats.eventCount, stats.worldCacheCount, stats.avatarCacheCount, stats.dbSizeBytes);
    }

    //
    // Content: gallery, icons, stickers, emoji, prints, inventory.
    //
    // Listing replies carry an "error" field instead of using the generic
    // error path so the client can clear the right section's loading state.
    //

    void handleGetFiles(JSONValue msg)
    {
        string tag;
        if (const(JSONValue)* v = "tag" in msg)
            tag = v.str;
        int n = 60;
        if (const(JSONValue)* v = "n" in msg)
            if (v.type == JSONType.integer)
                n = cast(int) v.integer;
        int offset;
        if (const(JSONValue)* v = "offset" in msg)
            if (v.type == JSONType.integer)
                offset = cast(int) v.integer;

        JSONValue resp = JSONValue([
            "type": JSONValue("files"),
            "tag": JSONValue(tag),
            "offset": JSONValue(offset),
        ]);
        try
        {
            JSONValue files = requireContent().listFiles(tag, n, offset);
            resp["count"] = JSONValue(cast(long) files.array.length);
            resp["files"] = files;
        }
        catch (Exception e)
        {
            resp["count"] = JSONValue(0);
            resp["files"] = JSONValue.emptyArray;
            resp["error"] = JSONValue(e.msg);
        }
        sendLine(resp.toString() ~ "\n");
    }

    void handleGetPrints()
    {
        JSONValue resp = JSONValue([
            "type": JSONValue("prints"),
        ]);
        try resp["prints"] = requireContent().listPrints();
        catch (Exception e)
        {
            resp["prints"] = JSONValue.emptyArray;
            resp["error"] = JSONValue(e.msg);
        }
        sendLine(resp.toString() ~ "\n");
    }

    void handleGetInventory(JSONValue msg)
    {
        bool archived;
        if (const(JSONValue)* v = "archived" in msg)
            archived = v.type == JSONType.true_;

        JSONValue resp = JSONValue([
            "type": JSONValue("inventory"),
            "archived": JSONValue(archived),
        ]);
        try
        {
            long totalCount;
            resp["items"] = requireContent().listInventory(archived, totalCount);
            resp["total_count"] = JSONValue(totalCount);
        }
        catch (Exception e)
        {
            resp["items"] = JSONValue.emptyArray;
            resp["total_count"] = JSONValue(0);
            resp["error"] = JSONValue(e.msg);
        }
        sendLine(resp.toString() ~ "\n");
    }

    void handleGetInventoryDrops()
    {
        JSONValue resp = JSONValue([
            "type": JSONValue("inventory_drops"),
        ]);
        try resp["items"] = requireContent().listInventoryDrops();
        catch (Exception e)
        {
            resp["items"] = JSONValue.emptyArray;
            resp["error"] = JSONValue(e.msg);
        }
        sendLine(resp.toString() ~ "\n");
    }

    void handleGetImage(JSONValue msg)
    {
        import std.base64 : Base64;

        string fileId;
        if (const(JSONValue)* v = "file_id" in msg)
            fileId = v.str;
        long fileVersion = 1;
        if (const(JSONValue)* v = "version" in msg)
            if (v.type == JSONType.integer)
                fileVersion = v.integer;
        int size;
        if (const(JSONValue)* v = "size" in msg)
            if (v.type == JSONType.integer)
                size = cast(int) v.integer;

        JSONValue resp = JSONValue([
            "type": JSONValue("image"),
            "file_id": JSONValue(fileId),
            "version": JSONValue(fileVersion),
            "size": JSONValue(size),
        ]);
        try
        {
            ImageResult image = requireContent().getImage(fileId, fileVersion, size);
            resp["success"] = JSONValue(image.success);
            if (image.success)
            {
                resp["mime_type"] = JSONValue(image.mimeType);
                resp["data_base64"] = JSONValue(cast(string) Base64.encode(image.data));
            }
            else
                resp["error"] = JSONValue(image.error);
        }
        catch (Exception e)
        {
            resp["success"] = JSONValue(false);
            resp["error"] = JSONValue(e.msg);
        }
        sendLine(resp.toString() ~ "\n");
    }

    void handleDeleteFile(JSONValue msg)
    {
        string fileId;
        if (const(JSONValue)* v = "file_id" in msg)
            fileId = v.str;

        JSONValue resp = JSONValue([
            "type": JSONValue("delete_file_result"),
            "file_id": JSONValue(fileId),
        ]);
        sendActionResult(resp, tryAction({
            return requireContent().deleteFile(fileId);
        }));
    }

    void handleDeletePrint(JSONValue msg)
    {
        string printId;
        if (const(JSONValue)* v = "print_id" in msg)
            printId = v.str;

        JSONValue resp = JSONValue([
            "type": JSONValue("delete_print_result"),
            "print_id": JSONValue(printId),
        ]);
        sendActionResult(resp, tryAction({
            return requireContent().deletePrint(printId);
        }));
    }

    void handleSetUserIcon(JSONValue msg)
    {
        // Empty file_id clears the icon.
        string fileId;
        if (const(JSONValue)* v = "file_id" in msg)
            fileId = v.str;

        JSONValue resp = JSONValue([
            "type": JSONValue("set_user_icon_result"),
            "file_id": JSONValue(fileId),
        ]);
        sendActionResult(resp, tryAction({
            return requireContent().setUserIcon(fileId);
        }));
    }

    void handleInventoryAction(JSONValue msg)
    {
        string action;
        if (const(JSONValue)* v = "action" in msg)
            action = v.str;
        string inventoryId;
        if (const(JSONValue)* v = "inventory_id" in msg)
            inventoryId = v.str;
        string slot;
        if (const(JSONValue)* v = "slot" in msg)
            slot = v.str;

        JSONValue resp = JSONValue([
            "type": JSONValue("inventory_action_result"),
            "action": JSONValue(action),
            "inventory_id": JSONValue(inventoryId),
        ]);
        sendActionResult(resp, tryAction({
            return requireContent().inventoryAction(action, inventoryId, slot);
        }));
    }

    void handleUploadImage(JSONValue msg)
    {
        import std.base64 : Base64;

        string tag;
        if (const(JSONValue)* v = "tag" in msg)
            tag = v.str;

        JSONValue resp = JSONValue([
            "type": JSONValue("upload_image_result"),
            "tag": JSONValue(tag),
        ]);

        const(ubyte)[] png;
        if (const(JSONValue)* v = "data_base64" in msg)
        {
            try png = Base64.decode(v.str);
            catch (Exception)
            {
                resp["success"] = JSONValue(false);
                resp["error"] = JSONValue("Invalid base64 data");
                sendLine(resp.toString() ~ "\n");
                return;
            }
        }

        ActionResult result = tryAction({
            return requireContent().uploadImage(tag, png, msg);
        });
        if (result.success && result.data.type == JSONType.object)
            resp["file"] = result.data;
        sendActionResult(resp, result);
    }

    void handleUploadPrint(JSONValue msg)
    {
        import std.base64 : Base64;

        string note, worldId, worldName, timestamp;
        if (const(JSONValue)* v = "note" in msg)
            note = v.str;
        if (const(JSONValue)* v = "world_id" in msg)
            worldId = v.str;
        if (const(JSONValue)* v = "world_name" in msg)
            worldName = v.str;
        if (const(JSONValue)* v = "timestamp" in msg)
            timestamp = v.str;

        JSONValue resp = JSONValue([
            "type": JSONValue("upload_print_result"),
        ]);

        const(ubyte)[] png;
        if (const(JSONValue)* v = "data_base64" in msg)
        {
            try png = Base64.decode(v.str);
            catch (Exception)
            {
                resp["success"] = JSONValue(false);
                resp["error"] = JSONValue("Invalid base64 data");
                sendLine(resp.toString() ~ "\n");
                return;
            }
        }

        ActionResult result = tryAction({
            return requireContent().uploadPrint(png, timestamp, note, worldId, worldName);
        });
        if (result.success && result.data.type == JSONType.object)
            resp["print"] = result.data;
        sendActionResult(resp, result);
    }

    /// Get the content service or throw (caught by the per-message handler
    /// or by tryAction and turned into an error reply).
    ContentService requireContent()
    {
        if (server.contentService is null)
            throw new Exception("Content service not configured");
        return server.contentService;
    }

    /// Run an action, converting exceptions into a failed ActionResult.
    ActionResult tryAction(ActionResult delegate() dg)
    {
        try return dg();
        catch (Exception e)
            return ActionResult(false, e.msg);
    }

    /// Fill success/error into a prepared result message and send it.
    /// Also refreshes the rate-limit status shown by clients, since the
    /// action consumed VRChat API budget.
    void sendActionResult(JSONValue resp, ActionResult result)
    {
        resp["success"] = JSONValue(result.success);
        if (result.success == false)
            resp["error"] = JSONValue(result.error);
        sendLine(resp.toString() ~ "\n");
        server.broadcastStatus();
    }

    private void pingLoop()
    {
        while (true)
        {
            Thread.sleep(PING_INTERVAL);

            if (atomicLoad(disconnected))
                return;

            // Record when the ping was sent, then send it.
            MonoTime pingSentAt = MonoTime.currTime;
            sendLine(`{"type":"ping"}` ~ "\n");

            Thread.sleep(PONG_DEADLINE);

            if (atomicLoad(disconnected))
                return;

            // Check whether a pong arrived since the ping was sent.
            pongMutex.lock();
            bool gotPong = lastPongAt >= pingSentAt;
            pongMutex.unlock();

            if (gotPong == false)
            {
                logWarn("Client pong timeout (%ds deadline), closing stale connection",
                    PONG_DEADLINE.total!"seconds");
                // shutdown(), not close(): run() is parked in a blocking
                // receive on this stream and close() would neither wake it
                // nor keep the descriptor number reserved. run() does the
                // close once its receive returns.
                stream.shutdown();
                return;
            }
        }
    }

    void sendError(string message)
    {
        JSONValue resp = JSONValue([
            "type": JSONValue("error"),
            "message": JSONValue(message),
        ]);
        sendLine(resp.toString() ~ "\n");
    }
}

/// Build a JSON event message for broadcasting.
JSONValue buildEventMessage(VRCEvent event, long eventId)
{
    return JSONValue([
        "type": JSONValue("event"),
        "id": JSONValue(eventId),
        "received_at": JSONValue(event.receivedAt.toUTC().toISOExtString()),
        "event_type": JSONValue(event.typeRaw),
        "content": event.content,
    ]);
}

/// The `received_at_unix` of an encoded notification, 0 when it has none.
private long notificationStamp(JSONValue item)
{
    if (const(JSONValue)* v = "received_at_unix" in item)
        if (v.type == JSONType.integer)
            return v.integer;
    return 0;
}

/// Order encoded notifications oldest first. Entries VRChat gave no timestamp
/// for sort as 0, so they lead; that keeps them in one place rather than
/// scattered through the list.
private void sortNotificationsOldestFirst(JSONValue[] items)
{
    import std.algorithm.sorting : sort;

    sort!((JSONValue a, JSONValue b) => notificationStamp(a) < notificationStamp(b))(items);
}
