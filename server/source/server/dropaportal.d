/// Drop a Portal companion integration (server side).
///
/// Self-contained sidecar: owns a background thread that talks to
/// https://dropaport.al/api, persists token and pending visits in
/// `server_state`, and broadcasts pairing prompts to clients via
/// `DropaPortalDelegator`.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.dropaportal;

import core.sync.condition;
import core.sync.mutex;
import core.thread;
import core.time;

import std.algorithm : startsWith;
import std.conv : to;
import std.datetime : Clock;
import std.json;
import std.string : indexOf;

import ddlogger;
import ddcurl;

import server.authdelegate : DropaPortalDelegator;
import server.config : USER_AGENT;
import server.database;

private enum string BASE_URL         = "https://dropaport.al/api";
private enum int    PROTOCOL_VERSION = 1;

// Keys in server_state. Namespaced so they don't collide with other modules.
private enum string KEY_TOKEN          = "dropaportal.token";
private enum string KEY_USERNAME       = "dropaportal.username";
private enum string KEY_PENDING_VISITS = "dropaportal.pending_visits";

/// One queued visit. Persisted to server_state across restarts so a
/// dropaport.al outage cannot lose entries.
private struct PendingVisit
{
    string worldId;
    long ts;
}

/// Drop a Portal sidecar.
///
/// One instance per server. Talks to dropaport.al on its own thread; the
/// rest of the server only ever calls `enqueueVisit()`, `triggerPair()`,
/// and `stop()`.
class DropaPortal
{
    private Database store;
    private DropaPortalDelegator delegator;
    private Thread thread;
    private shared bool running;

    private Mutex stateMutex;
    private Condition stateCond;
    private string accessToken;
    private string username;
    private PendingVisit[] pending;
    private string lastReportedWorldId;
    private bool pairRequested;
    /// True once a `dap_pair_complete` has been broadcast for the current
    /// token. Suppresses redundant broadcasts on every token-check pass so
    /// the client feed doesn't fill with `dap-login-ok` entries.
    private bool pairCompleteAnnounced;

    this(Database store, DropaPortalDelegator delegator)
    {
        this.store      = store;
        this.delegator  = delegator;
        this.stateMutex = new Mutex();
        this.stateCond  = new Condition(this.stateMutex);

        // Load persisted state.
        this.accessToken = store.getState(KEY_TOKEN);
        this.username    = store.getState(KEY_USERNAME);
        this.pending     = loadPendingFromStore(store);
    }

    /// Start the background thread.
    void start()
    {
        running = true;
        thread = new Thread(&run);
        thread.isDaemon = true;
        thread.start();
    }

    /// Request graceful shutdown. The thread exits at the next wake-up.
    void stop()
    {
        running = false;
        stateMutex.lock();
        stateCond.notifyAll();
        stateMutex.unlock();
    }

    /// Wait for the background thread to exit. Idempotent.
    void join()
    {
        if (thread)
        {
            thread.join();
            thread = null;
        }
    }

    /// Enqueue a world visit for reporting. `worldId` should be a bare
    /// `wrld_...` (without the instance suffix); non-world locations
    /// (private, traveling, offline) are silently dropped. `ts` is the
    /// unix timestamp at which the visit occurred.
    void enqueueVisit(string worldId, long ts)
    {
        if (startsWith(worldId, "wrld_") == false)
            return;

        stateMutex.lock();
        scope(exit) stateMutex.unlock();

        // Suppress dedup against the last reported world to avoid
        // duplicate inserts when a single transition produces multiple
        // user-location events with the same world.
        if (worldId == lastReportedWorldId && pending.length == 0)
        {
            logDebugging("DropaPortal: dedup visit %s (same as last reported)", worldId);
            return;
        }

        pending ~= PendingVisit(worldId, ts);
        savePendingLocked();
        stateCond.notifyAll();
    }

    /// Trigger a fresh pairing flow. Called from the API server when a
    /// client clicks "Pair" with no token stored. Idempotent: a second
    /// trigger while a flow is already running is a no-op.
    void triggerPair()
    {
        stateMutex.lock();
        scope(exit) stateMutex.unlock();
        // Ignore when a token already exists: the pairing branch only runs
        // (and clears pairRequested) while unpaired, so latching it here
        // would make waitForWork() return immediately every iteration and
        // busy-loop token-check. Re-pairing must go through unpair first.
        if (accessToken.length > 0)
            return;
        pairRequested = true;
        stateCond.notifyAll();
    }

    private void run()
    {
        logInfo("DropaPortal: thread started");

        HTTPClient client = new HTTPClient();
        client.setBaseUrl(BASE_URL);
        client.addHeader("Content-Type", "application/json");
        client.addHeader("User-Agent", USER_AGENT);

        while (running)
        {
            // Pair if we don't have a token yet.
            if (accessToken.length == 0)
            {
                if (waitForPairTrigger() == false)
                    break;
                runPairingFlow(client);
                continue; // After pairing (success or not), re-evaluate.
            }

            // Validate token on each iteration when we've just (re-)acquired
            // one. Cheaper option would be only on startup, but the cost is
            // small and it handles tokens revoked while idle.
            if (runTokenCheck(client) == false)
                continue;

            // Drain the queue: send oldest first.
            drainQueue(client);

            // Wait for new work, or shutdown.
            waitForWork();
        }

        logInfo("DropaPortal: thread stopped");
    }

    /// Blocks until pairing is triggered or the thread is stopped. Returns
    /// true if a pair was requested, false on shutdown.
    private bool waitForPairTrigger()
    {
        stateMutex.lock();
        scope(exit) stateMutex.unlock();
        while (running && pairRequested == false)
            stateCond.wait();
        if (running == false)
            return false;
        pairRequested = false;
        return true;
    }

    /// Blocks until something changes: a new pending visit, a pair request,
    /// or shutdown. Returns once any of those happens.
    private void waitForWork()
    {
        stateMutex.lock();
        scope(exit) stateMutex.unlock();
        // Re-check before waiting (queue may have grown while we were busy).
        if (pending.length > 0 || pairRequested || running == false)
            return;
        stateCond.wait();
    }

    /// RFC 8628 device authorization flow. Broadcasts the user code via
    /// the delegator, polls dropaport.al, and on success stores the token.
    private void runPairingFlow(HTTPClient client)
    {
        HTTPResponse resp;
        try resp = client.post("/companion/auth/request", "{}");
        catch (Exception e)
        {
            logError("DropaPortal: auth/request failed: %s", e.msg);
            broadcastPairError("Network error during pairing");
            return;
        }

        if (resp.code == 429)
        {
            broadcastPairError("Too many pairing attempts, try later");
            return;
        }
        if (resp.code != 200)
        {
            logError("DropaPortal: auth/request HTTP %d", resp.code);
            broadcastPairError("Pairing request failed (HTTP " ~ resp.code.to!string ~ ")");
            return;
        }

        JSONValue j;
        try j = parseJSON(resp.text);
        catch (Exception e)
        {
            logError("DropaPortal: auth/request bad JSON: %s", e.msg);
            broadcastPairError("Pairing response was malformed");
            return;
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
            broadcastPairError("Pairing response missing fields");
            return;
        }

        // Broadcast the pair prompt; client opens the URL and shows the code.
        delegator.beginPairing(userCode, verificationUriComplete, expiresIn, pollInterval);

        long deadline = Clock.currTime.toUnixTime!long() + expiresIn;
        JSONValue pollPayload = JSONValue(["device_code": JSONValue(deviceCode)]);
        string pollBody = pollPayload.toString();

        while (running && Clock.currTime.toUnixTime!long() < deadline)
        {
            sleepInterruptible(cast(int) pollInterval);
            if (running == false)
                return;

            if (delegator.wasCancelled())
            {
                logInfo("DropaPortal: pairing cancelled");
                broadcastPairError("Pairing cancelled");
                return;
            }

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
                    broadcastPairError("Pairing response was malformed");
                    return;
                }

                string token;
                if (const(JSONValue)* v = "access_token" in tj)
                    token = v.str;
                if (token.length == 0)
                {
                    logError("DropaPortal: auth/poll empty token");
                    broadcastPairError("Pairing returned an empty token");
                    return;
                }

                saveToken(token);
                logInfo("DropaPortal: paired successfully");
                // Username is filled in by the upcoming token-check.
                return;
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
                string detail =
                    errCode == "access_denied" ? "Pairing denied by user" :
                    errCode == "expired_token" ? "Pairing code expired"  :
                                                 "Pairing failed (" ~ errCode ~ ")";
                broadcastPairError(detail);
                return;
            }

            logError("DropaPortal: auth/poll unexpected HTTP %d", poll.code);
        }

        broadcastPairError("Pairing timed out");
    }

    /// Validates the stored token. Returns true to continue with visit
    /// reporting; false to skip this iteration (token cleared, will pair next).
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
            // Network errors are transient; keep the token and try later.
            sleepInterruptible(60);
            return false;
        }

        if (resp.code == 200)
        {
            string newUsername;
            try
            {
                JSONValue j = parseJSON(resp.text);
                if (const(JSONValue)* juser = "user" in j)
                    if (const(JSONValue)* v = "username" in *juser)
                        newUsername = v.str;
            }
            catch (Exception) {}
            if (newUsername.length > 0 && newUsername != username)
            {
                username = newUsername;
                store.setState(KEY_USERNAME, username);
            }
            logInfo("DropaPortal: token valid, logged in as %s", username);
            // Standing status: kept up-to-date for clients connecting after
            // this point.
            delegator.setPairedUsername(username);
            // Only announce once per token: routine token-check passes are
            // server bookkeeping, not user-visible events.
            if (pairCompleteAnnounced == false)
            {
                broadcastPairComplete(username);
                pairCompleteAnnounced = true;
            }
            return true;
        }

        if (resp.code == 401)
        {
            logWarn("DropaPortal: token revoked or invalid");
            clearTokenAndNotify("Token revoked, re-pairing required");
            return false;
        }

        if (resp.code == 426)
        {
            logError("DropaPortal: companion protocol version too old");
            broadcastLoginError("Companion out of date, please update vrcd");
            // Nothing we can do; sleep a long time before retrying so we don't spam logs.
            sleepInterruptible(3600);
            return false;
        }

        logError("DropaPortal: token-check unexpected HTTP %d", resp.code);
        sleepInterruptible(60);
        return false;
    }

    /// Drain pending visits. Stops on the first non-retryable failure
    /// (token revoked) or transient failure (network/5xx); the entry
    /// stays in the queue so the next iteration tries again.
    private void drainQueue(HTTPClient client)
    {
        while (running)
        {
            PendingVisit head;
            bool isMostRecent;
            stateMutex.lock();
            if (pending.length == 0)
            {
                stateMutex.unlock();
                return;
            }
            head = pending[0];
            // The freshest entry is reported as a "live" visit; older
            // queued entries are reported as historical so dropaport.al
            // distinguishes them.
            isMostRecent = pending.length == 1;
            stateMutex.unlock();

            VisitOutcome outcome = sendVisit(client, head.worldId, head.ts, isMostRecent);
            final switch (outcome)
            {
                case VisitOutcome.ok:
                    stateMutex.lock();
                    if (pending.length > 0 && pending[0].worldId == head.worldId
                        && pending[0].ts == head.ts)
                    {
                        pending = pending[1 .. $];
                        savePendingLocked();
                    }
                    lastReportedWorldId = head.worldId;
                    stateMutex.unlock();
                    break;
                case VisitOutcome.retry:
                    // Transient; sleep and bail to outer wait.
                    sleepInterruptible(30);
                    return;
                case VisitOutcome.tokenRevoked:
                    clearTokenAndNotify("Session expired, re-pairing required");
                    return;
            }
        }
    }

    private enum VisitOutcome { ok, retry, tokenRevoked }

    private VisitOutcome sendVisit(HTTPClient client, string worldId, long ts, bool live)
    {
        JSONValue payload = JSONValue([
            "world_id": JSONValue(worldId),
            "now":      JSONValue(live),
        ]);
        if (live == false)
            payload["timestamp"] = JSONValue(ts);

        client.addHeader("Authorization", "Bearer " ~ accessToken);
        scope (exit) client.removeHeader("Authorization");

        HTTPResponse resp;
        try resp = client.post("/companion/visits", payload.toString());
        catch (Exception e)
        {
            logWarn("DropaPortal: visit POST network error: %s", e.msg);
            return VisitOutcome.retry;
        }

        if (resp.code == 200)
        {
            logInfo("DropaPortal: visit logged %s (live=%s)", worldId, live);
            return VisitOutcome.ok;
        }

        if (resp.code == 401)
        {
            logWarn("DropaPortal: visit 401, token revoked");
            return VisitOutcome.tokenRevoked;
        }

        logError("DropaPortal: visit POST HTTP %d for %s", resp.code, worldId);
        return VisitOutcome.retry;
    }

    private void clearTokenAndNotify(string detail)
    {
        stateMutex.lock();
        accessToken = null;
        username = null;
        pairCompleteAnnounced = false;
        stateMutex.unlock();
        store.deleteState(KEY_TOKEN);
        store.deleteState(KEY_USERNAME);
        delegator.setPairedUsername(null);
        broadcastLoginError(detail);
    }

    private void saveToken(string token)
    {
        stateMutex.lock();
        accessToken = token;
        stateMutex.unlock();
        store.setState(KEY_TOKEN, token);
    }

    private void broadcastPairError(string detail)
    {
        JSONValue msg = JSONValue([
            "type":   JSONValue("dap_pair_error"),
            "detail": JSONValue(detail),
        ]);
        delegator.endPairing(msg);
    }

    private void broadcastPairComplete(string user)
    {
        JSONValue msg = JSONValue([
            "type":     JSONValue("dap_pair_complete"),
            "username": JSONValue(user),
        ]);
        delegator.endPairing(msg);
    }

    private void broadcastLoginError(string detail)
    {
        JSONValue msg = JSONValue([
            "type":   JSONValue("dap_login_error"),
            "detail": JSONValue(detail),
        ]);
        delegator.endPairing(msg);
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

    /// Caller holds stateMutex.
    private void savePendingLocked()
    {
        JSONValue[] arr;
        foreach (ref PendingVisit p; pending)
        {
            JSONValue entry = JSONValue([
                "world_id": JSONValue(p.worldId),
                "ts":       JSONValue(p.ts),
            ]);
            arr ~= entry;
        }
        store.setState(KEY_PENDING_VISITS, JSONValue(arr).toString());
    }

    private static PendingVisit[] loadPendingFromStore(Database store)
    {
        string raw = store.getState(KEY_PENDING_VISITS);
        if (raw.length == 0)
            return null;
        PendingVisit[] result;
        try
        {
            JSONValue j = parseJSON(raw);
            if (j.type != JSONType.array)
                return null;
            foreach (ref JSONValue entry; j.array)
            {
                if (entry.type != JSONType.object)
                    continue;
                PendingVisit p;
                if (const(JSONValue)* v = "world_id" in entry)
                    if (v.type == JSONType.string)
                        p.worldId = v.str;
                if (const(JSONValue)* v = "ts" in entry)
                    if (v.type == JSONType.integer)
                        p.ts = v.integer;
                if (p.worldId.length > 0)
                    result ~= p;
            }
        }
        catch (Exception e)
        {
            logWarn("DropaPortal: failed to load pending visits: %s", e.msg);
        }
        if (result.length > 0)
            logInfo("DropaPortal: loaded %d pending visit(s) from disk", result.length);
        return result;
    }
}
