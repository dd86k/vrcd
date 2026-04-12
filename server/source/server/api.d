/// Client API server
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.api;

import core.thread;
import core.time : Duration, dur, MonoTime;
import core.sync.mutex;
import core.sync.condition;

import std.json;
import std.conv : to;
import std.socket;
import std.string : strip;

import ddlogger;
import ddcurl;

import server.authdelegate;
import server.events;
import server.friends;
import server.instancecache;
import server.ratelimit;
import server.store;
import server.worldcache;
import server.config : DEFAULT_RESEED_INTERVAL;

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
    private EventStore store;
    private Thread acceptThread;
    private bool running;
    private Mutex clientsMutex;
    private ClientHandler[] clients;
    private bool vrchatConnected;
    private string vrchatLastError;
    private FriendsTracker friendsTracker;
    private WorldCache worldCache;
    private InstanceCache instanceCache;
    private HTTPClient httpClient;
    private Mutex apiMutex; // Shared VRChat API serializer, injected via setAPIMutex.
    private AuthDelegator authDelegator;
    private RateLimitTracker rateLimiter;

    // Re-seed worker state.
    private Thread reseedThread;
    private Mutex reseedSignalMutex;
    private Condition reseedSignalCond;
    private bool reseedRequested;
    private ReseedCallback reseedCallback;
    private MonoTime lastReseedAt;
    private bool firstReseed = true;
    private Duration reseedInterval;

    this(string bindAddr, ushort port, string sharedSecret, EventStore store,
        Duration reseedInterval = DEFAULT_RESEED_INTERVAL)
    {
        this.bindAddr = bindAddr;
        this.port = port;
        this.sharedSecret = sharedSecret;
        this.store = store;
        this.clientsMutex = new Mutex();
        this.friendsTracker = new FriendsTracker();
        this.reseedSignalMutex = new Mutex();
        this.reseedSignalCond = new Condition(this.reseedSignalMutex);
        this.reseedInterval = reseedInterval;
    }

    /// Access the friends tracker (e.g. to seed from REST API).
    FriendsTracker getFriendsTracker()
    {
        return friendsTracker;
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

    /// Update VRChat connection status and broadcast to all clients.
    void setVRChatStatus(bool connected, string lastError)
    {
        vrchatConnected = connected;
        if (lastError.length > 0)
            vrchatLastError = lastError;
        else if (connected)
            vrchatLastError = "";
        broadcastStatus();
    }

    /// Start accepting client connections.
    void start()
    {
        if (running)
            return;
        running = true;
        acceptThread = new Thread(&acceptLoop);
        acceptThread.isDaemon = true;
        acceptThread.start();

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

    /// Broadcast a live event to all authenticated clients.
    /// Also updates friends state and pushes a snapshot if it changed.
    void broadcast(VRCEvent event, long eventId)
    {
        JSONValue msg = buildEventMessage(event, eventId);
        string line = msg.toString() ~ "\n";

        // Update friends tracker; if state changed, push snapshot too.
        bool friendsChanged = friendsTracker.processEvent(event);
        string friendsLine;
        if (friendsChanged)
            friendsLine = friendsTracker.buildFriendsMessage().toString() ~ "\n";

        // Drain any synthesized events the tracker produced (e.g. avatar
        // changes). Persist + log them so catch-up and the server log see
        // them alongside real events, then queue their wire lines.
        // This keeps broadcast a little simpler and keeps FriendsTracker a
        // pure state machine.
        VRCEvent[] synthetics = friendsTracker.takePendingSynthetics();
        string[] synLines;
        foreach (ref syn; synthetics)
        {
            long synId = store.storeEvent(syn);
            logInfo("[#%d %s] %s", synId, syn.typeRaw, syn.content.toString());
            synLines ~= buildEventMessage(syn, synId).toString() ~ "\n";
        }

        clientsMutex.lock();
        scope(exit) clientsMutex.unlock();

        size_t delivered;
        foreach (client; clients)
        {
            if (client.authenticated)
            {
                client.sendLine(line);
                foreach (sl; synLines) // send synthesized events
                    client.sendLine(sl);
                if (friendsChanged)
                    client.sendLine(friendsLine);
                ++delivered;
            }
        }

        logDebugging("broadcast: id=%d type=%s clients=%d/%d friendsChanged=%s synth=%d",
            eventId, event.typeRaw, delivered, clients.length, friendsChanged, synLines.length);
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
        if (vrchatLastError.length > 0)
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
    void acceptLoop()
    {
        TcpSocket listener = new TcpSocket();
        listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
        listener.bind(new InternetAddress(bindAddr, port));
        listener.listen(5);
        listener.blocking = true;

        logInfo("API server listening on %s:%d", bindAddr, port);

        while (running)
        {
            Socket clientSock = listener.accept();
            if (clientSock is null)
                continue;

            string remote = clientSock.remoteAddress().toString();
            logInfo("Client connected from %s", remote);
            ClientHandler handler = new ClientHandler(clientSock, this);

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

/// Handles a single client connection.
private class ClientHandler
{
    Socket sock;
    APIServer server;
    bool authenticated;
    private Mutex sendMutex;

    this(Socket sock, APIServer server)
    {
        this.sock = sock;
        this.server = server;
        this.sendMutex = new Mutex();
    }

    void sendLine(string line)
    {
        sendMutex.lock();
        scope(exit) sendMutex.unlock();

        logTrace("sendLine: len=%d", line.length);
        try
            sock.send(cast(const(void)[]) line);
        catch (Exception e)
        {
            logDebugging("sendLine: send failed, client will be cleaned up: %s", e.msg);
        } // Client disconnected; will be cleaned up.
    }

    void run()
    {
        scope(exit)
        {
            logInfo("Client disconnected");
            server.removeClient(this);
            sock.close();
        }

        char[8192] buf;
        string buffer;

        while (true)
        {
            ptrdiff_t received = sock.receive(buf[]);
            if (received <= 0)
                break;

            buffer ~= cast(string) buf[0 .. received];

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
                case "notification_action":
                    if (authenticated == false)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    handleNotificationAction(msg);
                    break;
                case "auth_response":
                    if (authenticated == false)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    handleAuthResponse(msg);
                    break;
                case "pong":
                    break; // Keepalive response, no action.
                default:
                    sendError("Unknown message type: " ~ type);
                    break;
            }
        }
        catch (Exception e)
        {
            sendError("Invalid JSON: " ~ e.msg);
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
                "server_version": JSONValue(1),
            ]);
            sendLine(resp.toString() ~ "\n");
            // Send current status immediately after auth.
            sendLine(server.buildStatusMessage().toString() ~ "\n");
            logInfo("Client authenticated");

            // If there is a pending VRChat auth request, send it to this client.
            if (server.authDelegator !is null && server.authDelegator.hasPendingRequest())
            {
                JSONValue authReq = server.authDelegator.getPendingRequestMessage();
                if (authReq.type != JSONType.null_)
                    sendLine(authReq.toString() ~ "\n");
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
                    "content": parseJSON(row[3].to!string),
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
                    "content": parseJSON(row[3].to!string),
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
                    string loc;
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
        if (server.worldCache !is null)
            worldName = server.worldCache.resolve(worldId);

        logDebugging("handleGetWorld: worldId=%s resolved=%s", worldId, worldName);

        JSONValue resp = JSONValue([
            "type": JSONValue("world"),
            "world_id": JSONValue(worldId),
            "world_name": JSONValue(worldName),
        ]);
        sendLine(resp.toString() ~ "\n");
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
            HTTPResponse resp = server.httpClient.put(path);
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


private import std.datetime.timezone : UTC;
private import std.datetime.systime : SysTime;
