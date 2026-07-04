/// Server connection
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module client.connection;

import core.sync.mutex;
import std.json;
import std.conv : to;
import std.socket;
import std.string : indexOf, strip;

import bindbc.sdl;
import ddlogger;

import client.state;
import client.stream;

/// Callback for received events.
alias EventCallback = void delegate(JSONValue event);

/// TCP connection to the vrcd server.
/// Handles auth, catch-up, and live event streaming via JSON-L.
/// Supports optional TLS encryption when compiled with the openssl dependency.
class ServerConnection
{
    private string host;
    private ushort port;
    private string secret;
    private bool useTls;
    private bool tlsSkipVerify;
    private string tlsClientCert;
    private string tlsClientKey;
    private Stream stream;
    private void* sslCtx;
    private string recvBuffer;
    private bool authenticated;
    private string lastConnectError;
    private EventCallback onEvent;
    private void delegate(string) onError;
    private Mutex sendMutex;

    /// Protocol version reported by the server in auth_ok. Zero when unknown.
    long serverVersion;

    this(string host, ushort port, string secret,
        bool useTls = false, bool tlsSkipVerify = false,
        string tlsClientCert = null, string tlsClientKey = null)
    {
        this.host = host;
        this.port = port;
        this.secret = secret;
        this.useTls = useTls;
        this.tlsSkipVerify = tlsSkipVerify;
        this.tlsClientCert = tlsClientCert;
        this.tlsClientKey = tlsClientKey;
        this.sendMutex = new Mutex();
    }

    /// Set callback for incoming events.
    void setEventCallback(EventCallback cb)
    {
        this.onEvent = cb;
    }

    /// Set callback for errors.
    void setErrorCallback(void delegate(string) cb)
    {
        this.onError = cb;
    }

    /// Connect to the server and authenticate.
    /// Returns true on success.
    bool connect()
    {
        logDebugging("connect: attempting %s:%d (secretLen=%d tls=%s)", host, port, secret.length, useTls);
        TcpSocket tcpSock = new TcpSocket();
        try
        {
            tcpSock.connect(new InternetAddress(host, port));
        }
        catch (SocketException e)
        {
            logError("Failed to connect to %s:%d: %s", host, port, e.msg);
            lastConnectError = e.msg;
            return false;
        }

        // Wrap in TLS if requested, or use plain TCP.
        if (useTls && tlsAvailable())
        {
            if (sslCtx is null)
            {
                try sslCtx = createClientTLSContext(tlsSkipVerify, tlsClientCert, tlsClientKey);
                catch (Exception e)
                {
                    logError("TLS context creation failed: %s", e.msg);
                    lastConnectError = "TLS context: " ~ e.msg;
                    tcpSock.close();
                    return false;
                }
            }
            try stream = new TLSClientStream(tcpSock, sslCtx, host);
            catch (Exception e)
            {
                logError("TLS handshake failed with %s:%d: %s", host, port, e.msg);
                lastConnectError = "TLS handshake: " ~ e.msg;
                tcpSock.close();
                return false;
            }
        }
        else
        {
            if (useTls)
                logWarn("TLS requested but not available, connecting without TLS");
            stream = new PlainStream(tcpSock);
        }

        logInfo("Connected to %s:%d%s", host, port, useTls ? " (TLS)" : "");

        // Send auth.
        sendMessage(JSONValue([
            "type": JSONValue("auth"),
            "token": JSONValue(secret),
        ]));

        // Wait for auth response.
        JSONValue resp = readOneMessage();
        if (resp.type == JSONType.null_)
        {
            logError("Server closed connection during authentication");
            lastConnectError = "Server closed connection during authentication";
            return false;
        }

        string msgType;
        if (const(JSONValue)* v = "type" in resp)
            msgType = v.str;
        if (msgType == "auth_ok")
        {
            authenticated = true;
            if ("server_version" in resp && resp["server_version"].type == JSONType.integer)
                serverVersion = resp["server_version"].get!long;
            logInfo("Authenticated (server v%d)", serverVersion);
            return true;
        }
        else if (msgType == "auth_error")
        {
            string errMessage;
            if (const(JSONValue)* v = "message" in resp)
                errMessage = v.str;
            logError("Server authentication failed: %s (check client token matches server)", errMessage);
            lastConnectError = errMessage.length ? "Auth failed: " ~ errMessage : "Auth failed";
            return false;
        }
        else
        {
            logError("Unexpected server auth response: %s", msgType);
            lastConnectError = "Unexpected auth response: " ~ msgType;
            return false;
        }
    }

    /// Request catch-up from a given event ID (0 = all events).
    void catchUp(long sinceId = 0)
    {
        logDebugging("catchUp: sinceId=%d", sinceId);
        sendMessage(JSONValue([
            "type": JSONValue("catch_up"),
            "since_id": JSONValue(sinceId),
        ]));
    }

    /// Request a page of older events (with id < beforeId), newest first.
    /// Server replies with `event_older` messages followed by an
    /// `older_fetched` terminator.
    void fetchOlder(long beforeId, int limit = 100)
    {
        logDebugging("fetchOlder: beforeId=%d limit=%d", beforeId, limit);
        sendMessage(JSONValue([
            "type": JSONValue("fetch_older"),
            "before_id": JSONValue(beforeId),
            "limit": JSONValue(limit),
        ]));
    }

    /// Request the current friends state from the server.
    void requestFriends()
    {
        logDebugging("requestFriends");
        sendMessage(JSONValue([
            "type": JSONValue("get_friends"),
        ]));
    }

    /// Send a notification action (accept/hide) to the server.
    void sendNotificationAction(string notificationId, string action)
    {
        logDebugging("sendNotificationAction: id=%s action=%s", notificationId, action);
        sendMessage(JSONValue([
            "type": JSONValue("notification_action"),
            "notification_id": JSONValue(notificationId),
            "action": JSONValue(action),
        ]));
    }

    /// Ask the server to self-invite us to an instance ("Self-Invite" join).
    /// The server holds the authenticated VRChat session and issues the REST
    /// call; we just pass the full location. Server replies with
    /// `join_instance_result`.
    void sendJoinInstance(string location)
    {
        logDebugging("sendJoinInstance: location=%s", location);
        sendMessage(JSONValue([
            "type": JSONValue("join_instance"),
            "location": JSONValue(location),
        ]));
    }

    /// Change the logged-in user's VRChat status and/or custom status message.
    /// Pass `setStatus = false` to leave the status unchanged; same for the
    /// description. Server replies with `set_status_result`.
    void sendSetStatus(bool setStatus, string status,
        bool setDescription, string description)
    {
        logDebugging("sendSetStatus: status=%s desc=%s",
            setStatus ? status : "(unchanged)",
            setDescription ? description : "(unchanged)");
        JSONValue msg = JSONValue([
            "type": JSONValue("set_status"),
        ]);
        if (setStatus)
            msg["status"] = JSONValue(status);
        if (setDescription)
            msg["status_description"] = JSONValue(description);
        sendMessage(msg);
    }

    /// Request server statistics.
    void requestStats()
    {
        logDebugging("requestStats");
        sendMessage(JSONValue([
            "type": JSONValue("get_stats"),
        ]));
    }

    /// Send an auth response (credentials or 2FA code) to the server.
    void sendAuthResponse(JSONValue msg)
    {
        sendMessage(msg);
    }

    /// Ask the server to begin a Drop-a-Portal pairing flow. Server
    /// responds with `dap_pair_request` carrying the user code & URL.
    void sendDapPairStart()
    {
        logDebugging("sendDapPairStart");
        sendMessage(JSONValue([
            "type": JSONValue("dap_pair_start"),
        ]));
    }

    /// Cancel an in-progress Drop-a-Portal pairing flow.
    void sendDapPairCancel()
    {
        logDebugging("sendDapPairCancel");
        sendMessage(JSONValue([
            "type": JSONValue("dap_pair_cancel"),
        ]));
    }

    /// Request a page of the user's files (tag: gallery/icon/sticker/emoji).
    /// Server replies with `files`.
    void requestFiles(string tag, long n, long offset)
    {
        logDebugging("requestFiles: tag=%s n=%d offset=%d", tag, n, offset);
        sendMessage(JSONValue([
            "type": JSONValue("get_files"),
            "tag": JSONValue(tag),
            "n": JSONValue(n),
            "offset": JSONValue(offset),
        ]));
    }

    /// Request the user's prints. Server replies with `prints`.
    void requestPrints()
    {
        logDebugging("requestPrints");
        sendMessage(JSONValue([
            "type": JSONValue("get_prints"),
        ]));
    }

    /// Request the user's inventory items. Server replies with `inventory`.
    void requestInventory(bool archived = false)
    {
        logDebugging("requestInventory: archived=%s", archived);
        sendMessage(JSONValue([
            "type": JSONValue("get_inventory"),
            "archived": JSONValue(archived),
        ]));
    }

    /// Request image bytes through the server proxy. size 0 downloads the
    /// original file, other sizes a thumbnail. Server replies with `image`
    /// (base64 payload).
    void requestImage(string fileId, long fileVersion, int size)
    {
        logDebugging("requestImage: %s v%d size=%d", fileId, fileVersion, size);
        sendMessage(JSONValue([
            "type": JSONValue("get_image"),
            "file_id": JSONValue(fileId),
            "version": JSONValue(fileVersion),
            "size": JSONValue(size),
        ]));
    }

    /// Delete a file (gallery/icon/sticker/emoji). Server replies with
    /// `delete_file_result`.
    void sendDeleteFile(string fileId)
    {
        logDebugging("sendDeleteFile: %s", fileId);
        sendMessage(JSONValue([
            "type": JSONValue("delete_file"),
            "file_id": JSONValue(fileId),
        ]));
    }

    /// Delete a print. Server replies with `delete_print_result`.
    void sendDeletePrint(string printId)
    {
        logDebugging("sendDeletePrint: %s", printId);
        sendMessage(JSONValue([
            "type": JSONValue("delete_print"),
            "print_id": JSONValue(printId),
        ]));
    }

    /// Set (or clear, with an empty fileId) the profile icon. Requires
    /// VRC+. Server replies with `set_user_icon_result`.
    void sendSetUserIcon(string fileId)
    {
        logDebugging("sendSetUserIcon: %s", fileId.length ? fileId : "(clear)");
        sendMessage(JSONValue([
            "type": JSONValue("set_user_icon"),
            "file_id": JSONValue(fileId),
        ]));
    }

    /// Equip/unequip/consume an inventory item. `slot` is required for
    /// equip and unequip. Server replies with `inventory_action_result`.
    void sendInventoryAction(string action, string inventoryId, string slot)
    {
        logDebugging("sendInventoryAction: %s %s slot=%s", action, inventoryId, slot);
        JSONValue msg = JSONValue([
            "type": JSONValue("inventory_action"),
            "action": JSONValue(action),
            "inventory_id": JSONValue(inventoryId),
        ]);
        if (slot.length)
            msg["slot"] = JSONValue(slot);
        sendMessage(msg);
    }

    /// Upload a PNG to the files API (tag: gallery/icon/sticker/emoji).
    /// Server replies with `upload_image_result`.
    void sendUploadImage(string tag, string dataBase64)
    {
        logDebugging("sendUploadImage: tag=%s bytes=%d", tag, dataBase64.length);
        sendMessage(JSONValue([
            "type": JSONValue("upload_image"),
            "tag": JSONValue(tag),
            "data_base64": JSONValue(dataBase64),
        ]));
    }

    /// Upload a print. Server replies with `upload_print_result`.
    void sendUploadPrint(string dataBase64, string note, string worldId, string worldName)
    {
        logDebugging("sendUploadPrint: bytes=%d note=%s", dataBase64.length, note);
        JSONValue msg = JSONValue([
            "type": JSONValue("upload_print"),
            "data_base64": JSONValue(dataBase64),
        ]);
        if (note.length)
            msg["note"] = JSONValue(note);
        if (worldId.length)
            msg["world_id"] = JSONValue(worldId);
        if (worldName.length)
            msg["world_name"] = JSONValue(worldName);
        sendMessage(msg);
    }

    /// Read and dispatch messages until the connection closes.
    /// This blocks the calling thread.
    void run()
    {
        char[8192] buf;

        while (true)
        {
            ptrdiff_t received = stream.receive(buf);
            if (received <= 0)
            {
                logInfo("Server connection closed");
                break;
            }

            recvBuffer ~= cast(string) buf[0 .. received];

            // Process complete lines.
            while (true)
            {
                ptrdiff_t nlPos = recvBuffer.indexOf('\n');
                if (nlPos < 0)
                    break;

                string line = recvBuffer[0 .. nlPos].strip();
                recvBuffer = recvBuffer[nlPos + 1 .. $];

                if (line.length == 0)
                    continue;

                processLine(line);
            }
        }
    }

    /// Close the connection, unblocking any thread blocked on receive().
    void close()
    {
        if (stream)
        {
            try stream.close();
            catch (Exception) {}
            stream = null;
        }
        if (sslCtx)
        {
            freeTLSContext(sslCtx);
            sslCtx = null;
        }
    }

    /// Whether we are authenticated with the server.
    bool isAuthenticated() const
    {
        return authenticated;
    }

    /// Run blocking receive loop for GUI mode.
    /// Pushes raw JSON lines into the queue and wakes the main
    /// thread via SDL_PushEvent. Intended to run in a dedicated thread.
    void runThreaded(MessageQueue queue, uint sdlEventType)
    {
        try
            runThreadedImpl(queue, sdlEventType);
        catch (Exception e)
            logError("Network thread: %s", e.msg);

        queue.pushDisconnect();
        pushWakeEvent(sdlEventType);
    }

    /// Connect (blocking) and then run the receive loop, all on this thread.
    /// Reports connection state via the queue and wakes the main thread on
    /// each transition so the UI never blocks on TCP connect.
    void connectAndRun(MessageQueue queue, uint sdlEventType, long sinceId)
    {
        bool ok;
        try ok = connect();
        catch (Exception e)
        {
            logError("Network thread: connect threw: %s", e.msg);
            lastConnectError = e.msg;
            ok = false;
        }

        if (ok == false)
        {
            queue.setConnectFailed(lastConnectError);
            pushWakeEvent(sdlEventType);
            return;
        }

        queue.setConnected();
        pushWakeEvent(sdlEventType);

        try
        {
            catchUp(sinceId);
            requestFriends();
            runThreadedImpl(queue, sdlEventType);
        }
        catch (Exception e)
            logError("Network thread: %s", e.msg);

        queue.pushDisconnect();
        pushWakeEvent(sdlEventType);
    }

    /// Last connect error message, if connect() returned false.
    string connectError() const
    {
        return lastConnectError;
    }

    private void runThreadedImpl(MessageQueue queue, uint sdlEventType)
    {
        char[8192] buf;

        while (true)
        {
            ptrdiff_t received = stream.receive(buf[]);
            if (received <= 0)
            {
                logInfo("Server connection closed");
                return;
            }

            logTrace("runThreadedImpl: received %d bytes", received);

            recvBuffer ~= cast(string) buf[0 .. received];
            bool pushed;
            size_t queuedHere;

            while (true)
            {
                ptrdiff_t nlPos = recvBuffer.indexOf('\n');
                if (nlPos < 0)
                    break;

                string line = recvBuffer[0 .. nlPos].strip();
                recvBuffer = recvBuffer[nlPos + 1 .. $];

                if (line.length == 0)
                    continue;

                // Handle ping/pong in the network thread directly.
                if (line.length > 10 && line[0] == '{')
                {
                    try
                    {
                        JSONValue msg = parseJSON(line);
                        string msgType;
                        if (const(JSONValue)* v = "type" in msg)
                            msgType = v.str;
                        if (msgType == "ping")
                        {
                            logTrace("runThreadedImpl: ping -> pong");
                            sendMessage(JSONValue(["type": JSONValue("pong")]));
                            continue;
                        }
                    }
                    catch (Exception) {}
                }

                queue.pushMessage(line);
                pushed = true;
                ++queuedHere;
            }

            if (pushed)
            {
                logTrace("runThreadedImpl: queued %d messages, waking main thread",
                    queuedHere);
                pushWakeEvent(sdlEventType);
            }
        }
    }

private:
    static void pushWakeEvent(uint sdlEventType)
    {
        SDL_Event ev = void;
        ev.type = sdlEventType;
        SDL_PushEvent(&ev);
    }


    void sendMessage(JSONValue msg)
    {
        string line = msg.toString() ~ "\n";
        logTrace("sendMessage: len=%d", line.length);

        // Serialized between the main thread (requests) and the network
        // thread (pongs); large lines may need several send() calls and
        // interleaving them would corrupt the JSON-L framing.
        sendMutex.lock();
        scope(exit) sendMutex.unlock();

        const(void)[] remaining = cast(const(void)[]) line;
        while (remaining.length > 0)
        {
            ptrdiff_t sent = stream.send(remaining);
            if (sent <= 0)
                break; // Disconnected; receive loop will notice.
            remaining = remaining[sent .. $];
        }
    }

    /// Block until one complete JSON-L message is received.
    JSONValue readOneMessage()
    {
        char[4096] buf;
        while (true)
        {
            // Check buffer first.
            ptrdiff_t nlPos = recvBuffer.indexOf('\n');
            if (nlPos >= 0)
            {
                string line = recvBuffer[0 .. nlPos].strip();
                recvBuffer = recvBuffer[nlPos + 1 .. $];
                if (line.length > 0)
                    return parseJSON(line);
                continue;
            }

            ptrdiff_t received = stream.receive(buf[]);
            if (received <= 0)
                return JSONValue(null);

            recvBuffer ~= cast(string) buf[0 .. received];
        }
    }

    void processLine(string line)
    {
        try
        {
            JSONValue msg = parseJSON(line);
            string msgType;
            if (const(JSONValue)* v = "type" in msg)
                msgType = v.str;

            logTrace("processLine: type=%s len=%d", msgType, line.length);

            switch (msgType)
            {
                case "event":
                    if (onEvent)
                        onEvent(msg);
                    break;
                case "caught_up":
                    long lastId;
                    if ("last_id" in msg && msg["last_id"].type == JSONType.integer)
                        lastId = msg["last_id"].get!long;
                    logInfo("Caught up to event #%d", lastId);
                    break;
                case "event_older":
                    // CLI mode treats back-filled events like live events.
                    if (onEvent)
                        onEvent(msg);
                    break;
                case "older_fetched":
                    long count;
                    if (const(JSONValue) *jcount = "count" in msg)
                        if (jcount.type == JSONType.integer)
                            count = jcount.integer;
                    logInfo("Fetched %d older events", count);
                    break;
                case "error":
                    string errMsg;
                    if (const(JSONValue)* v = "message" in msg)
                        errMsg = v.str;
                    logError("Server error: %s", errMsg);
                    if (onError)
                        onError(errMsg);
                    break;
                case "stats":
                    if (onEvent)
                        onEvent(msg);
                    break;
                case "ping":
                    sendMessage(JSONValue(["type": JSONValue("pong")]));
                    break;
                case "self":
                    // CLI doesn't track self state; just log the snapshot.
                    string selfName;
                    if (const(JSONValue)* v = "displayName" in msg)
                        selfName = v.str;
                    string selfStatus;
                    if (const(JSONValue)* v = "status" in msg)
                        selfStatus = v.str;
                    logInfo("Self: %s (%s)", selfName, selfStatus);
                    break;
                case "set_status_result":
                    bool ok;
                    if (const(JSONValue)* v = "success" in msg)
                        ok = v.type == JSONType.true_;
                    if (ok)
                        logInfo("Status updated");
                    else
                    {
                        string err;
                        if (const(JSONValue)* v = "error" in msg)
                            err = v.str;
                        logWarn("Status update failed: %s", err);
                    }
                    break;
                default:
                    logWarn("Unknown message type: %s", msgType);
                    break;
            }
        }
        catch (Exception e)
        {
            logError("Failed to parse server message: %s", e.msg);
        }
    }
}

