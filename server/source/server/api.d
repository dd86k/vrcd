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

import server.events;
import server.friends;
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
            string type = jsonStr(msg, "type");

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
        string token = jsonStr(msg, "token");
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
        string worldId = jsonStr(msg, "world_id");
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

private string jsonStr(JSONValue json, string key)
{
    if (key in json && json[key].type == JSONType.string)
        return json[key].str;
    return "";
}

private import std.datetime.timezone : UTC;
private import std.datetime.systime : SysTime;
