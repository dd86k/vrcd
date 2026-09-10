/// VRChat WebSocket connection
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.vrchat.websocket;

import core.thread;
import core.time : dur, Duration, MonoTime;

import ddlogger;
import ddcurl;
import ddcurl.libcurl : CurlException;
import ddcurl.websocket : WebSocketMessage, WebSocketStatus;

import server.vrchat.vrcconfig : USER_AGENT;
import server.events;
import server.config : DEFAULT_RECONNECT_MAX, DEFAULT_RECONNECT_INTERVAL;

/// Callback type for received events.
alias EventCallback = void delegate(VRCEvent event);

/// Callback type for connection status changes.
/// Params: connected, lastError (empty on successful connect).
alias StatusCallback = void delegate(bool connected, string lastError);

/// Callback for re-authentication when the auth token expires.
alias ReAuthCallback = void delegate();

/// RFC 6455 close status codes we react to specially. The pipeline does not
/// publish its own code set, so we follow the standard meanings.
private enum : ushort
{
    CLOSE_POLICY_VIOLATION = 1008, // Token rejected: re-auth and reconnect.
    CLOSE_TRY_AGAIN_LATER  = 1013, // Explicit back-off request: go to max delay.
}

/// How long a connection has to stay up before it counts as a good one and
/// the reconnect backoff is allowed to reset.
private enum Duration STABLE_CONNECTION = dur!"seconds"(60);

/// Human-readable description for an RFC 6455 close code.
/// A zero code means the peer closed without sending one.
private string describeCloseCode(ushort code)
{
    switch (code)
    {
    case 0:    return "no close code";
    case 1000: return "normal closure";
    case 1001: return "going away";
    case 1002: return "protocol error";
    case 1003: return "unsupported data";
    case 1007: return "invalid payload data";
    case 1008: return "policy violation";
    case 1009: return "message too big";
    case 1010: return "mandatory extension";
    case 1011: return "internal server error";
    case 1012: return "service restart";
    case 1013: return "try again later";
    case 1014: return "bad gateway";
    default:   return "unknown close code";
    }
}

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

    /// Set callback for re-authentication on 401/403.
    void setReAuthCallback(ReAuthCallback cb)
    {
        onReAuth = cb;
    }

    /// Configure exponential reconnect backoff.
    ///
    /// `base` is the initial delay after a failed connect; the delay doubles
    /// on each successive failure up to `max`, and resets to `base` once a
    /// connection has stayed up for STABLE_CONNECTION.
    void setReconnectBackoff(Duration base, Duration max)
    {
        reconnectBase = base;
        reconnectMax = max;
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
    ReAuthCallback onReAuth;
    Thread recvThread;
    bool running;
    WebSocket ws;
    bool connected;
    Duration reconnectBase  = DEFAULT_RECONNECT_INTERVAL;
    Duration reconnectMax   = DEFAULT_RECONNECT_MAX;
    Duration reconnectDelay = DEFAULT_RECONNECT_INTERVAL; // current backoff value

    void receiveLoop()
    {
        while (running)
        {
            MonoTime connectedAt; // .init until the handshake goes through

            try
            {
                connect();
                connectedAt = MonoTime.currTime;
                notifyStatus(true, "");

                bool reconnectNow; // Skip backoff and reconnect immediately (e.g. after re-auth).

                while (running && connected)
                {
                    WebSocketMessage msg = ws.receive();
                    final switch (msg.status) with (WebSocketStatus)
                    {
                    case data:
                        const(char)[] message = cast(const(char)[]) msg.data;
                        logTrace("WS recv: %s", message);

                        try
                        {
                            VRCEvent event = parseNewVrcEvent(message);
                            // event.content.toString().length is wasteful, by the way
                            logDebugging("WS parsed event: type=%s length=%s", event.typeRaw, message.length);
                            // A frame that parses to an empty type is not a
                            // normal event; surface the raw payload so we can
                            // tell an auth/error frame from a genuine event.
                            if (event.typeRaw.length == 0)
                                logWarn("WS event with empty type, raw: %s", message);
                            onEvent(event);
                        }
                        catch (Exception e)
                        {
                            logError("Failed to parse event: %s -- message: %s", e.msg, message);
                        }
                        break;

                    case timedOut:
                        // No frame within the poll window. The VRChat pipeline can stay
                        // quiet for long stretches, so an idle timeout is not a
                        // disconnect: keep waiting.
                        logTrace("WS idle (poll timeout), still connected");
                        break;

                    case closed:
                        connected = false;
                        string reason = describeCloseCode(msg.closeCode);
                        logInfo("WebSocket closed by server (code %d: %s)", msg.closeCode, reason);

                        // 1008 (policy violation) is how the pipeline rejects a stale or
                        // revoked auth token; treat it like an HTTP 401/403 and re-auth.
                        if (msg.closeCode == CLOSE_POLICY_VIOLATION)
                        {
                            reconnectNow = tryReAuth(reason);
                            break;
                        }

                        // 1013 (try again later) is an explicit back-off request, mirror 429.
                        if (msg.closeCode == CLOSE_TRY_AGAIN_LATER)
                        {
                            logError("Pipeline asked to try again later (1013), jumping to max backoff");
                            reconnectDelay = reconnectMax;
                        }

                        notifyStatus(false, reason);
                        break;
                    }
                }

                if (reconnectNow)
                    continue; // Reconnect immediately with the refreshed token.
            }
            catch (CurlException e)
            {
                // statusCode is the HTTP code from the handshake (0 if none);
                // log it explicitly since the re-auth decision below keys on it.
                logError("WebSocket CurlException: %s (HTTP status %d)", e.msg, e.statusCode);
                connected = false;

                if (e.statusCode == 401 || e.statusCode == 403)
                {
                    if (tryReAuth("Auth token invalid or expired"))
                        continue; // Reconnect with new token.
                }
                else
                {
                    // 429 is VRChat explicitly telling us to back off.
                    // VRC tend to not put Retry-After headers... Use max cap to stay safe.
                    if (e.statusCode == 429)
                    {
                        logError("WebSocket rate limited (429), jumping to max backoff");
                        reconnectDelay = reconnectMax;
                    }
                    notifyStatus(false, e.msg);
                }
            }
            catch (Exception e)
            {
                logError("WebSocket Exception: %s", e.msg);
                connected = false;
                notifyStatus(false, e.msg);
            }

            // A handshake that goes through is not a working connection. Reset
            // the backoff only once one has stayed up, or a socket VRChat drops
            // on sight reconnects at the base interval forever -- every attempt
            // "succeeds" -- and the status line flaps at that rate.
            if (connectedAt != MonoTime.init && MonoTime.currTime - connectedAt >= STABLE_CONNECTION)
                reconnectDelay = reconnectBase;

            // Exponential backoff to try going around network outages
            logInfo("Reconnecting in %s (last connection lasted %s)...", reconnectDelay,
                connectedAt != MonoTime.init ? MonoTime.currTime - connectedAt : Duration.zero);
            Thread.sleep(reconnectDelay);
            reconnectDelay = reconnectDelay * 2;
            if (reconnectDelay > reconnectMax)
                reconnectDelay = reconnectMax;
        }
    }

    void notifyStatus(bool status, string error)
    {
        if (onStatusChange)
            onStatusChange(status, error);
    }

    /// Attempt to refresh the auth token after the pipeline rejected it.
    /// Returns: true when a new token was obtained and an immediate reconnect
    /// should follow; false when no re-auth callback is configured.
    /// Exits the process if re-auth fails, to avoid hammering the VRChat API.
    bool tryReAuth(string statusMessage)
    {
        notifyStatus(false, statusMessage);

        if (onReAuth is null)
        {
            logError("Auth token expired. Re-run 'auth' to refresh.");
            return false;
        }

        try
        {
            onReAuth();
            logInfo("Re-auth succeeded, reconnecting...");
            Thread.sleep(dur!"seconds"(2));
            return true;
        }
        catch (Exception reAuthEx)
        {
            import core.stdc.stdlib : exit;
            logError("Re-authentication failed: %s", reAuthEx.msg);
            logCritical("Exiting to avoid spamming VRChat API.");
            exit(2);
        }
        assert(0);
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
