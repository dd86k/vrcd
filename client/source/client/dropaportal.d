/// Drop a Portal companion integration
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module client.dropaportal;

import core.sync.mutex;
import core.thread;
import core.time;

import std.algorithm : startsWith;
import std.conv : to;
import std.datetime : Clock;
import std.json;
import std.string : indexOf, stripRight;

import bindbc.sdl;
import ddlogger;
import ddcurl;

import client.state : MessageQueue;

private enum string BASE_URL      = "https://dropaport.al/api";
private enum int PROTOCOL_VERSION = 1;

/// Companion integration for Drop a Portal world visit reporting.
/// Runs on its own background thread. Communicates back to the main thread
/// via the shared MessageQueue using "dap-event" and "dap-save-token" messages.
class DropaPortal
{
    private Thread thread;
    private shared bool running;
    private MessageQueue queue;
    private uint sdlEventType;

    private string accessToken;
    private long lastVisitTs;

    private Mutex locationMtx;
    private string pendingLocation;
    private string reportedWorldId;
    private string lastBackfilledWorldId;

    this(MessageQueue queue, uint sdlEventType, string token, long lastVisitTs)
    {
        this.queue        = queue;
        this.sdlEventType = sdlEventType;
        this.accessToken  = token;
        this.lastVisitTs  = lastVisitTs;
        this.locationMtx  = new Mutex();
    }

    void start()
    {
        running = true;
        thread = new Thread(&run);
        thread.isDaemon = true;
        thread.start();
    }

    void stop()
    {
        running = false;
    }

    bool isRunning()
    {
        return thread && thread.isRunning();
    }

    void join()
    {
        if (thread)
        {
            thread.join();
            thread = null;
        }
    }

    /// Called by the main thread when the local VRChat location changes.
    void setLocation(string location)
    {
        locationMtx.lock();
        pendingLocation = location;
        locationMtx.unlock();
    }

    private string readLocation()
    {
        locationMtx.lock();
        string loc = pendingLocation;
        locationMtx.unlock();
        return loc;
    }

    private void run()
    {
        logInfo("DropaPortal: thread started");

        HTTPClient client = new HTTPClient();
        client.setBaseUrl(BASE_URL);
        client.addHeader("Content-Type", "application/json");

        // If started with no token, run the pairing flow first.
        if (accessToken.length == 0)
        {
            if (runPairingFlow(client) == false)
            {
                logInfo("DropaPortal: pairing failed, thread stopping");
                return;
            }
        }

        // Validate token on startup.
        if (runTokenCheck(client) == false)
        {
            logInfo("DropaPortal: token invalid, thread stopping");
            return;
        }

        // Backfill world visits from existing VRChat log files.
        runHistoricalBackfill(client);
        // Seed the live-loop dedup key so we don't re-submit a world whose
        // "Destination requested" line was already sent as a historical visit
        // but whose "Joining" line arrives as a new live event (race at startup).
        reportedWorldId = lastBackfilledWorldId;

        // Visit-reporting loop: wake every 5 s and report pending location.
        while (running && accessToken.length > 0)
        {
            string loc = readLocation();
            if (loc.length > 0)
            {
                string worldId = loc;
                ptrdiff_t colon = indexOf(loc, ':');
                if (colon > 0)
                    worldId = loc[0 .. colon];

                if (worldId != reportedWorldId)
                {
                    if (reportVisit(client, loc))
                        reportedWorldId = worldId;
                }
            }
            sleepInterruptible(5);
        }

        logInfo("DropaPortal: thread stopped");
    }

    // Runs the device authorization flow (RFC 8628). Returns true when a
    // token was obtained and stored in accessToken.
    private bool runPairingFlow(HTTPClient client)
    {
        pushFeedEvent("dap-pair-start", "Pairing...");

        HTTPResponse resp;
        try resp = client.post("/companion/auth/request", "{}");
        catch (Exception e)
        {
            logError("DropaPortal: auth/request failed: %s", e.msg);
            pushFeedEvent("dap-error", "Network error during pairing");
            return false;
        }

        if (resp.code == 429)
        {
            pushFeedEvent("dap-error", "Too many pairing attempts, try later");
            return false;
        }
        if (resp.code != 200)
        {
            logError("DropaPortal: auth/request HTTP %d", resp.code);
            pushFeedEvent("dap-error", "Pairing request failed (HTTP " ~ resp.code.to!string ~ ")");
            return false;
        }

        JSONValue j;
        try j = parseJSON(resp.text);
        catch (Exception e)
        {
            logError("DropaPortal: auth/request bad JSON: %s", e.msg);
            return false;
        }

        string deviceCode;
        string userCode;
        string verificationUriComplete;
        long expiresIn    = 900;
        long pollInterval = 5;

        if (const(JSONValue)* v = "device_code" in j)
            deviceCode = v.str;
        if (const(JSONValue)* v = "user_code" in j)
            userCode = v.str;
        if (const(JSONValue)* v = "verification_uri_complete" in j)
            verificationUriComplete = v.str;
        if (const(JSONValue)* v = "expires_in" in j)
            expiresIn = v.integer;
        if (const(JSONValue)* v = "interval" in j)
            pollInterval = v.integer;

        if (deviceCode.length == 0 || userCode.length == 0)
        {
            logError("DropaPortal: auth/request missing fields");
            return false;
        }

        import client.utils : openBrowser;
        openBrowser(verificationUriComplete);
        JSONValue pairContent;
        pairContent["user_code"] = userCode;
        pairContent["url"]       = verificationUriComplete;
        pushFeedEvent("dap-pair-code", "Code: " ~ userCode ~ " — approve in browser", pairContent.toString());
        logInfo("DropaPortal: pairing started");

        long deadline = Clock.currTime.toUnixTime!long() + expiresIn;
        JSONValue pollPayload = JSONValue(["device_code": JSONValue(deviceCode)]);
        string pollBody = pollPayload.toString();

        while (running && Clock.currTime.toUnixTime!long() < deadline)
        {
            sleepInterruptible(cast(int) pollInterval);
            if (running == false)
                return false;

            HTTPResponse poll;
            try poll = client.post("/companion/auth/poll", pollBody);
            catch (Exception e)
            {
                logWarn("DropaPortal: auth/poll network error: %s", e.msg);
                continue; // keep polling until deadline
            }

            if (poll.code == 200)
            {
                JSONValue tj;
                try tj = parseJSON(poll.text);
                catch (Exception e)
                {
                    logError("DropaPortal: auth/poll bad JSON: %s", e.msg);
                    return false;
                }

                string token;
                if (const(JSONValue)* v = "access_token" in tj)
                    token = v.str;
                if (token.length == 0)
                {
                    logError("DropaPortal: auth/poll empty token");
                    return false;
                }

                accessToken = token;
                pushSaveToken(token);
                logInfo("DropaPortal: paired successfully");
                return true;
            }

            if (poll.code == 400)
            {
                string errCode;
                try
                {
                    JSONValue ej = parseJSON(poll.text);
                    if (const(JSONValue)* v = "error" in ej)
                        errCode = v.str;
                }
                catch (Exception) {}

                if (errCode == "authorization_pending")
                    continue;

                logWarn("DropaPortal: auth/poll terminal: %s", errCode);
                string msg =
                    errCode == "access_denied" ? "Pairing denied by user" :
                    errCode == "expired_token"  ? "Pairing code expired"  :
                                                  "Pairing failed (" ~ errCode ~ ")";
                pushFeedEvent("dap-error", msg);
                return false;
            }

            logError("DropaPortal: auth/poll unexpected HTTP %d", poll.code);
        }

        pushFeedEvent("dap-error", "Pairing timed out");
        return false;
    }

    // Calls token-check on startup to validate the stored token and negotiate
    // the protocol version. Returns false only when the token is definitively
    // invalid or the protocol is too old to continue.
    private bool runTokenCheck(HTTPClient client)
    {
        client.addHeader("Authorization", "Bearer " ~ accessToken);
        scope (exit) client.removeHeader("Authorization");

        JSONValue payload = JSONValue(["protocol_version": JSONValue(PROTOCOL_VERSION)]);

        HTTPResponse resp;
        try resp = client.post("/companion/token-check", payload.toString());
        catch (Exception e)
        {
            logWarn("DropaPortal: token-check network error: %s", e.msg);
            // Keep the token; network errors are transient.
            return true;
        }

        if (resp.code == 200)
        {
            string username;
            try
            {
                JSONValue j = parseJSON(resp.text);
                if (const(JSONValue)* juser = "user" in j)
                    if (const(JSONValue)* v = "username" in *juser)
                        username = v.str;
            }
            catch (Exception) {}
            logInfo("DropaPortal: token valid, logged in as %s", username);
            pushLoginOkEvent(username);
            return true;
        }

        if (resp.code == 401)
        {
            logWarn("DropaPortal: token revoked or invalid");
            pushSaveToken("");
            pushFeedEvent("dap-login-error", "Token revoked, re-pairing required");
            return false;
        }

        if (resp.code == 426)
        {
            logError("DropaPortal: companion protocol version too old");
            pushFeedEvent("dap-error", "Companion out of date, please update vrcd");
            running = false; // stop the thread; nothing more we can do
            return false;
        }

        logError("DropaPortal: token-check unexpected HTTP %d", resp.code);
        return true; // preserve token on unexpected errors
    }

    // POST a live world visit. Returns true on success so the caller can
    // advance reportedLocation. Returns false on transient failure (will retry).
    private bool reportVisit(HTTPClient client, string location)
    {
        string worldId = location;
        ptrdiff_t colon = indexOf(location, ':');
        if (colon > 0)
            worldId = location[0 .. colon];

        if (startsWith(worldId, "wrld_") == false)
        {
            logDebugging("DropaPortal: skipping non-world location: %s", location);
            return true; // advance reportedLocation past non-world entries
        }

        JSONValue payload = JSONValue([
            "world_id": JSONValue(worldId),
            "now":      JSONValue(true),
        ]);

        client.addHeader("Authorization", "Bearer " ~ accessToken);
        scope (exit) client.removeHeader("Authorization");

        HTTPResponse resp;
        try resp = client.post("/companion/visits", payload.toString());
        catch (Exception e)
        {
            logWarn("DropaPortal: visit POST network error: %s", e.msg);
            return false;
        }

        if (resp.code == 200)
        {
            logInfo("DropaPortal: visit logged %s", worldId);
            return true;
        }

        if (resp.code == 401)
        {
            logWarn("DropaPortal: visit 401, token revoked");
            accessToken = null;
            pushSaveToken("");
            pushFeedEvent("dap-login-error", "Session expired, re-pairing required");
            return false;
        }

        logError("DropaPortal: visit POST HTTP %d", resp.code);
        return false;
    }

    private void sleepInterruptible(int seconds)
    {
        foreach (int i; 0 .. seconds)
        {
            if (running == false)
                return;
            Thread.sleep(1.seconds);
        }
    }

    private void runHistoricalBackfill(HTTPClient client)
    {
        import client.directories : vrchatLogDir;
        import std.file : dirEntries, SpanMode, DirEntry, exists;
        import std.algorithm : sort;

        string logDir = vrchatLogDir();
        if (logDir is null || exists(logDir) == false)
        {
            logDebugging("DropaPortal: no VRChat log dir, skipping backfill");
            return;
        }

        DirEntry[] logFiles;
        foreach (DirEntry entry; dirEntries(logDir, "output_log_*.txt", SpanMode.shallow))
            logFiles ~= entry;
        if (logFiles.length == 0)
            return;

        sort!((DirEntry a, DirEntry b) => a.name < b.name)(logFiles);

        int sent;
        foreach (DirEntry f; logFiles)
        {
            if (running == false || accessToken.length == 0)
                break;
            sent += backfillFromFile(client, f.name);
        }

        if (sent > 0)
        {
            logInfo("DropaPortal: backfilled %d historical visits", sent);
        }
    }

    private int backfillFromFile(HTTPClient client, string path)
    {
        import std.stdio : File;

        int sent;
        try
        {
            File f = File(path, "r");
            char[] buf;
            while (f.readln(buf))
            {
                if (running == false || accessToken.length == 0)
                    break;

                string line = cast(string) buf;
                long ts;
                string worldId;
                if (parseVisitLine(line, ts, worldId) == false)
                    continue;
                if (ts <= lastVisitTs)
                    continue;

                if (sendHistoricalVisit(client, worldId, ts))
                {
                    lastVisitTs = ts;
                    lastBackfilledWorldId = worldId;
                    pushSaveTs(ts);
                    sent++;
                }
            }
            f.close();
        }
        catch (Exception e)
        {
            logError("DropaPortal: failed to read log file %s: %s", path, e.msg);
        }
        return sent;
    }

    // Parse a VRChat log line for a world visit.
    // Matches [Behaviour] Destination requested: wrld_xxx (same as reference companion).
    // Returns true and populates ts/worldId on success.
    private static bool parseVisitLine(string line, out long ts, out string worldId)
    {
        // Minimum: 19-char timestamp + at least one more char
        if (line.length < 20)
            return false;

        ts = parseLogTimestamp(line[0 .. 19]);
        if (ts < 0)
            return false;

        static immutable string destMarker = "[Behaviour] Destination requested: ";
        ptrdiff_t idx = indexOf(line, destMarker);
        if (idx < 0)
            return false;

        size_t start = cast(size_t)(idx + destMarker.length);
        if (start + 5 > line.length)
            return false;
        if (line[start .. start + 5] != "wrld_")
            return false;

        string rest = stripRight(line[start .. $]);
        ptrdiff_t colon = indexOf(rest, ':');
        worldId = (colon > 0 ? rest[0 .. colon] : rest).idup;
        return worldId.length > 0;
    }

    // Parse "YYYY.MM.DD HH:MM:SS" (first 19 chars of every VRChat log line)
    // into a Unix timestamp. Returns -1 on parse failure.
    private static long parseLogTimestamp(string s)
    {
        if (s.length < 19)
            return -1;
        // Positions: YYYY.MM.DD HH:MM:SS
        //            0123456789012345678
        try
        {
            int year   = (s[0]-'0')*1000 + (s[1]-'0')*100 + (s[2]-'0')*10 + (s[3]-'0');
            int month  = (s[5]-'0')*10  + (s[6]-'0');
            int day    = (s[8]-'0')*10  + (s[9]-'0');
            int hour   = (s[11]-'0')*10 + (s[12]-'0');
            int minute = (s[14]-'0')*10 + (s[15]-'0');
            int second = (s[17]-'0')*10 + (s[18]-'0');

            import std.datetime : DateTime, SysTime;
            return SysTime(DateTime(year, month, day, hour, minute, second)).toUnixTime!long();
        }
        catch (Exception)
        {
            return -1;
        }
    }

    private bool sendHistoricalVisit(HTTPClient client, string worldId, long timestamp)
    {
        JSONValue payload = JSONValue([
            "world_id":  JSONValue(worldId),
            "now":       JSONValue(false),
            "timestamp": JSONValue(timestamp),
        ]);

        client.addHeader("Authorization", "Bearer " ~ accessToken);
        scope (exit) client.removeHeader("Authorization");

        HTTPResponse resp;
        try resp = client.post("/companion/visits", payload.toString());
        catch (Exception e)
        {
            logWarn("DropaPortal: historical visit network error: %s", e.msg);
            return false;
        }

        if (resp.code == 200)
            return true;

        if (resp.code == 401)
        {
            logWarn("DropaPortal: historical visit 401, token revoked");
            accessToken = null;
            pushSaveToken("");
            pushFeedEvent("dap-login-error", "Session expired, re-pairing required");
            return false;
        }

        logError("DropaPortal: historical visit HTTP %d for %s", resp.code, worldId);
        return false;
    }

    private void pushSaveTs(long ts)
    {
        JSONValue msg;
        msg["type"] = "dap-save-ts";
        msg["ts"]   = ts;
        queue.pushMessage(msg.toString());
        pushWakeEvent();
    }

    private void pushFeedEvent(string subType, string detail, string rawContent = "")
    {
        JSONValue msg;
        msg["type"]     = "dap-event";
        msg["sub_type"] = subType;
        msg["detail"]   = detail;
        if (rawContent.length > 0)
            msg["raw_content"] = rawContent;
        queue.pushMessage(msg.toString());
        pushWakeEvent();
    }

    private void pushLoginOkEvent(string username)
    {
        JSONValue msg;
        msg["type"]     = "dap-event";
        msg["sub_type"] = "login-ok";
        msg["username"] = username;
        queue.pushMessage(msg.toString());
        pushWakeEvent();
    }

    private void pushSaveToken(string token)
    {
        JSONValue msg;
        msg["type"]  = "dap-save-token";
        msg["token"] = token;
        queue.pushMessage(msg.toString());
        pushWakeEvent();
    }

    private void pushWakeEvent()
    {
        SDL_Event ev = void;
        ev.type = sdlEventType;
        SDL_PushEvent(&ev);
    }
}
