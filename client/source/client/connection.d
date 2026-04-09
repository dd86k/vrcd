/// Server connection
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module client.connection;

import std.json;
import std.conv : to;
import std.socket;
import std.string : indexOf, strip;

import bindbc.sdl;
import ddlogger;

import client.state;

/// Callback for received events.
alias EventCallback = void delegate(JSONValue event);

/// TCP connection to the vrcd server.
/// Handles auth, catch-up, and live event streaming via JSON-L.
class ServerConnection
{
    private string host;
    private ushort port;
    private string secret;
    private TcpSocket sock;
    private string recvBuffer;
    private bool authenticated;
    private EventCallback onEvent;
    private void delegate(string) onError;

    this(string host, ushort port, string secret)
    {
        this.host = host;
        this.port = port;
        this.secret = secret;
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
        logDebugging("connect: attempting %s:%d (secretLen=%d)", host, port, secret.length);
        sock = new TcpSocket();
        try
        {
            sock.connect(new InternetAddress(host, port));
        }
        catch (SocketException e)
        {
            logError("Failed to connect to %s:%d: %s", host, port, e.msg);
            return false;
        }

        logInfo("Connected to %s:%d", host, port);

        // Send auth.
        sendMessage(JSONValue([
            "type": JSONValue("auth"),
            "token": JSONValue(secret),
        ]));

        // Wait for auth response.
        JSONValue resp = readOneMessage();
        if (resp.type == JSONType.null_)
        {
            logError("Connection closed during auth");
            return false;
        }

        string msgType;
        if (const(JSONValue)* v = "type" in resp)
            msgType = v.str;
        if (msgType == "auth_ok")
        {
            authenticated = true;
            long serverVersion = 0;
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
            logError("Auth failed: %s", errMessage);
            return false;
        }
        else
        {
            logError("Unexpected auth response: %s", msgType);
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

    /// Send an auth response (credentials or 2FA code) to the server.
    void sendAuthResponse(JSONValue msg)
    {
        sendMessage(msg);
    }

    /// Read and dispatch messages until the connection closes.
    /// This blocks the calling thread.
    void run()
    {
        char[8192] buf;

        while (true)
        {
            ptrdiff_t received = sock.receive(buf[]);
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

    /// Close the connection. Calls shutdown first to unblock
    /// any thread blocked on receive().
    void close()
    {
        if (sock !is null)
        {
            try sock.shutdown(SocketShutdown.BOTH);
            catch (Exception) {}
            sock.close();
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

    private void runThreadedImpl(MessageQueue queue, uint sdlEventType)
    {
        char[8192] buf;

        while (true)
        {
            ptrdiff_t received = sock.receive(buf[]);
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
        SDL_Event ev;
        ev.type = sdlEventType;
        SDL_PushEvent(&ev);
    }


    void sendMessage(JSONValue msg)
    {
        string line = msg.toString() ~ "\n";
        logTrace("sendMessage: len=%d", line.length);
        sock.send(cast(const(void)[]) line);
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

            ptrdiff_t received = sock.receive(buf[]);
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
                    if (onEvent !is null)
                        onEvent(msg);
                    break;
                case "caught_up":
                    long lastId;
                    if ("last_id" in msg && msg["last_id"].type == JSONType.integer)
                        lastId = msg["last_id"].get!long;
                    logInfo("Caught up to event #%d", lastId);
                    break;
                case "error":
                    string errMsg;
                    if (const(JSONValue)* v = "message" in msg)
                        errMsg = v.str;
                    logError("Server error: %s", errMsg);
                    if (onError !is null)
                        onError(errMsg);
                    break;
                case "ping":
                    sendMessage(JSONValue(["type": JSONValue("pong")]));
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

