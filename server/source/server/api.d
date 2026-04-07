/// Client API server
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.api;

import core.thread;
import core.time : dur;
import core.sync.mutex;

import std.json;
import std.conv : to;
import std.socket;
import std.string : strip;

import ddlogger;
import ddcurl;

import server.authdelegate;
import server.events;
import server.friends;
import server.ratelimit;
import server.store;
import server.worldcache;

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
    private HTTPClient httpClient;
    private Mutex apiMutex; // Serializes VRChat API calls
    private AuthDelegator authDelegator;
    private RateLimitTracker rateLimiter;

    this(string bindAddr, ushort port, string sharedSecret, EventStore store)
    {
        this.bindAddr = bindAddr;
        this.port = port;
        this.sharedSecret = sharedSecret;
        this.store = store;
        this.clientsMutex = new Mutex();
        this.friendsTracker = new FriendsTracker();
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

    /// Set the HTTP client for proxying VRChat API calls.
    void setHTTPClient(HTTPClient client)
    {
        httpClient = client;
        apiMutex = new Mutex();
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
    }

    /// Stop the server.
    void stop()
    {
        running = false;
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

        clientsMutex.lock();
        scope(exit) clientsMutex.unlock();

        foreach (client; clients)
        {
            if (client.authenticated)
            {
                client.sendLine(line);
                if (friendsChanged)
                    client.sendLine(friendsLine);
            }
        }
    }

    /// Broadcast current status to all authenticated clients.
    void broadcastStatus()
    {
        string line = buildStatusMessage().toString() ~ "\n";

        clientsMutex.lock();
        scope(exit) clientsMutex.unlock();

        foreach (client; clients)
        {
            if (client.authenticated)
                client.sendLine(line);
        }
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

            logInfo("Client connected from %s", clientSock.remoteAddress().toString());
            ClientHandler handler = new ClientHandler(clientSock, this);

            clientsMutex.lock();
            clients ~= handler;
            clientsMutex.unlock();

            Thread t = new Thread(&handler.run);
            t.isDaemon = true;
            t.start();
        }

        listener.close();
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

        try
            sock.send(cast(const(void)[]) line);
        catch (Exception)
            {} // Client disconnected; will be cleaned up.
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

            switch (type)
            {
                case "auth":
                    handleAuth(msg);
                    break;
                case "catch_up":
                    if (!authenticated)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    handleCatchUp(msg);
                    break;
                case "status":
                    if (!authenticated)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    sendLine(server.buildStatusMessage().toString() ~ "\n");
                    break;
                case "get_friends":
                    if (!authenticated)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    sendLine(server.friendsTracker.buildFriendsMessage().toString() ~ "\n");
                    break;
                case "get_world":
                    if (!authenticated)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    handleGetWorld(msg);
                    break;
                case "notification_action":
                    if (!authenticated)
                    {
                        sendError("Not authenticated");
                        return;
                    }
                    handleNotificationAction(msg);
                    break;
                case "auth_response":
                    if (!authenticated)
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

        long lastId = sinceId;
        foreach (row; server.store.queryEventsAfter(sinceId))
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
        }

        JSONValue doneMsg = JSONValue([
            "type": JSONValue("caught_up"),
            "last_id": JSONValue(lastId),
        ]);
        sendLine(doneMsg.toString() ~ "\n");
        logInfo("Client caught up to event #%d", lastId);
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
            if (server.rateLimiter)
            {
                server.rateLimiter.update(resp);
                server.broadcastStatus();
            }
            bool success = resp.code >= 200 && resp.code < 300;

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
        }
        else if (kind == "two_factor")
        {
            if (const(JSONValue)* v = "code" in msg)
                resp.code = v.str;
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
