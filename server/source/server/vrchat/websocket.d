/// VRChat WebSocket connection
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.vrchat.websocket;

import core.thread;
import core.time : dur;

import ddlogger;
import ddcurl;
import ddcurl.libcurl : CurlException;
import server.vrchat.vrcconfig : USER_AGENT;

import server.events;

/// Callback type for received events.
alias EventCallback = void delegate(VRCEvent event);

/// Callback type for connection status changes.
/// Params: connected, lastError (empty on successful connect).
alias StatusCallback = void delegate(bool connected, string lastError);

/// Manages the VRChat WebSocket connection with automatic reconnection.
class VRCWebSocket
{
    /// Params:
    ///   token = VRChat WebSocket auth token from GET /auth.
    ///   callback = Called for each received event.
    this(string token, EventCallback callback)
    {
        authToken = token;
        onEvent = callback;
    }

    /// Set callback for connection status changes.
    void setStatusCallback(StatusCallback cb)
    {
        onStatusChange = cb;
    }

    /// Update the auth token (e.g., after re-authentication).
    void setToken(string token)
    {
        authToken = token;
    }

    /// Start the WebSocket receive loop in a background thread.
    void start()
    {
        if (running)
            return;
        running = true;
        recvThread = new Thread(&receiveLoop);
        recvThread.isDaemon = true;
        recvThread.start();
    }

    /// Stop the WebSocket connection and thread.
    void stop()
    {
        running = false;
        if (connected)
        {
            ws.close();
            connected = false;
        }
    }

    /// Whether the WebSocket is currently connected.
    bool isConnected()
    {
        return connected;
    }

private:
    string authToken;
    EventCallback onEvent;
    StatusCallback onStatusChange;
    Thread recvThread;
    bool running;
    WebSocket ws;
    bool connected;

    void receiveLoop()
    {
        while (running)
        {
            try
            {
                connect();
                logInfo("WebSocket connected");
                notifyStatus(true, "");

                while (running && connected)
                {
                    ubyte[] data = ws.receive();
                    if (data is null)
                    {
                        logInfo("WebSocket closed by server");
                        connected = false;
                        notifyStatus(false, "Connection closed by server");
                        break;
                    }

                    const(char)[] message = cast(const(char)[]) data;
                    logDebugging("WS recv: %s", message);

                    try
                    {
                        VRCEvent event = parseEvent(message);
                        onEvent(event);
                    }
                    catch (Exception e)
                    {
                        logError("Failed to parse event: %s -- message: %s", e.msg, message);
                    }
                }
            }
            catch (CurlException e)
            {
                logError("WebSocket error: %s", e.msg);
                string error = e.msg;
                if (e.statusCode == 401 || e.statusCode == 403)
                {
                    error = "Auth token invalid or expired";
                    logError("  Re-run 'auth' to refresh.");
                }
                connected = false;
                notifyStatus(false, error);
            }
            catch (Exception e)
            {
                logError("WebSocket error: %s", e.msg);
                connected = false;
                notifyStatus(false, e.msg);
            }

            logInfo("Reconnecting in 5 seconds...");
            Thread.sleep(dur!"seconds"(5));
        }
    }

    void notifyStatus(bool status, string error)
    {
        if (onStatusChange !is null)
            onStatusChange(status, error);
    }

    void connect()
    {
        string url = "wss://pipeline.vrchat.cloud/?auth=" ~ authToken;
        logInfo("Connecting to VRChat WebSocket...");
        logDebugging("WS URL: wss://pipeline.vrchat.cloud/?auth=<redacted, %d chars>", authToken.length);

        WebSocketClient client = new WebSocketClient();
        client.addHeader("User-Agent", USER_AGENT);
        client.setVerbose(false);
        ws = client.connect(url);
        ws.setPollTimeout(30_000); // 30s poll timeout for receive.
        connected = true;
    }
}
