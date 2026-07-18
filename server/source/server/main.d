/// Server entry point
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.main;

import core.sync.mutex : Mutex;
import core.time : MonoTime;

import std.getopt;
import std.json;
import std.stdio : stderr, writeln, writefln;

import ddlogger;
import ddcurl;

import server.api;
import server.authdelegate;
import server.config;
import server.content;
import server.dropaportal;
import server.events;
import server.friends;
import server.instancecache;
import server.ratelimit;
import server.database;
import server.stream;
import server.worldcache;
import server.vrchat.auth;
import server.vrchat.websocket;

/// Graceful-shutdown flag. Cleared by the signal handlers so the main
/// loop can exit and flush the cookie jar before the process terminates.
private __gshared bool g_running = true;

version (Posix)
{
    extern (C) void onTerminateSignal(int) nothrow @nogc @system
    {
        g_running = false;
    }
}
else version (Windows)
{
    import core.sys.windows.windef : BOOL, DWORD, TRUE;
    extern (Windows) BOOL onConsoleCtrl(DWORD) nothrow @nogc @system
    {
        g_running = false;
        return TRUE;
    }
}

/// Install SIGINT/SIGTERM (Ctrl+C) handlers so shutdown is graceful and
/// the cookie jar gets flushed instead of the process being torn down.
private void installSignalHandlers()
{
    version (Posix)
    {
        import core.sys.posix.signal : sigaction, sigaction_t, SIGINT, SIGTERM;
        sigaction_t sa;
        sa.sa_handler = &onTerminateSignal;
        sigaction(SIGINT, &sa, null);
        sigaction(SIGTERM, &sa, null);
    }
    else version (Windows)
    {
        import core.sys.windows.wincon : SetConsoleCtrlHandler;
        SetConsoleCtrlHandler(&onConsoleCtrl, TRUE);
    }
}

void cmdRun(ref Config config)
{
    import core.stdc.stdlib : exit;
    import core.thread : Thread;
    import core.time : dur;

    logDebugging("cmdRun: dbPath=%s listen=%s:%d credsPath=%s cookiePath=%s",
        config.dbPath, config.listenAddr, config.listenPort,
        config.credentialsPath, config.cookieJarPath);

    // Attempt to load OpenSSL for TLS support.
    loadTLS();

    // Initialize database.
    Database store = new Database(config.dbPath);
    logInfo("Database loaded from '%s'", config.dbPath);

    scope HTTPClient client = new HTTPClient();
    bool headless = isHeadless();
    AuthDelegator delegator;
    APIServer apiServer;

    if (config.apiSecret.length == 0)
        logWarn("No --secret set, clients can connect without authentication");

    // Initialize TLS context if cert and key are configured.
    void* tlsCtx;
    bool hasCert = config.tlsCertPath.length > 0;
    bool hasKey  = config.tlsKeyPath.length > 0;
    if (hasCert && hasKey)
    {
        if (tlsAvailable())
        {
            try tlsCtx = createServerTLSContext(config.tlsCertPath, config.tlsKeyPath,
                    config.tlsCaPath, config.tlsVerifyClient);
            catch (Exception e)
            {
                logError("TLS setup failed: %s", e.msg);
                exit(1);
            }
            logInfo("TLS enabled (cert: %s%s)", config.tlsCertPath,
                config.tlsVerifyClient ? ", mTLS on" : "");
        }
        else
        {
            logWarn("TLS not available: OpenSSL could not be loaded");
            if (config.tlsOnly)
            {
                logError("tls_only is set but TLS is not available");
                exit(1);
            }
        }
    }
    else if (hasCert || hasKey)
        logWarn("TLS partially configured; both tls_cert and tls_key are required");

    if (headless)
    {
        logInfo("Running in headless mode (no TTY), auth will be delegated to clients");

        // In headless mode, start API server first so clients can connect
        // and provide credentials/2FA codes if needed.
        delegator = new AuthDelegator();
        apiServer = new APIServer(config.listenAddr, config.listenPort, config.apiSecret, store, config.reseedInterval);
        apiServer.setAuthDelegator(delegator);
        if (tlsCtx)
            apiServer.setTLS(tlsCtx, config.tlsPort, config.tlsOnly);
        apiServer.start();
        logInfo("Server started, listening on %s:%d", config.listenAddr, config.listenPort);
    }

    // Auth VRChat (may block waiting for client in headless mode).
    AuthState authState;
    try authState = authenticate(config, client, delegator);
    catch (Exception e)
    {
        logError("Authentication failed: %s", e.msg);
        exit(1);
    }
    logInfo("Authenticated as %s (%s)", authState.displayName, authState.userId);

    // Persist cookies obtained or refreshed during authentication so a
    // restart can reuse the session instead of forcing a re-login. Safe
    // without the API mutex here: the HTTP client is not shared yet.
    client.flushCookies();

    if (config.pruneRetain)
    {
        long pruned = store.pruneOldEvents(config.pruneRetain);
        logInfo("Pruned %d old event(s) (retain: %s)", pruned, config.pruneRetain);
    }

    if (apiServer is null)
    {
        // Interactive mode: start API server after auth.
        apiServer = new APIServer(config.listenAddr, config.listenPort, config.apiSecret, store, config.reseedInterval);
        if (tlsCtx)
            apiServer.setTLS(tlsCtx, config.tlsPort, config.tlsOnly);
        apiServer.start();
        logInfo("Server started, listening on %s:%d", config.listenAddr, config.listenPort);
    }

    // Rate limit tracker for VRChat API.
    RateLimitTracker rateLimiter = new RateLimitTracker();

    // Shared serializer for all HTTPClient + RateLimitTracker access.
    // Acquired by the event path (worldcache), the reseed worker, and
    // client-initiated API calls in api.d.
    Mutex vrcApiMutex = new Mutex();

    // World name cache for resolving world IDs via VRChat API.
    WorldCache worldCache = new WorldCache(client, rateLimiter);
    worldCache.setAPIMutex(vrcApiMutex);

    // Instance occupancy cache for "n_users/capacity" in the ONLINE tab.
    InstanceCache instanceCache = new InstanceCache(client, rateLimiter);
    instanceCache.setAPIMutex(vrcApiMutex);

    // User content: gallery, icons, stickers, emoji, prints, inventory.
    ContentService contentService = new ContentService(client, rateLimiter,
        vrcApiMutex, config.imageCachePath, config.imageCacheMaxMB * 1024 * 1024);
    contentService.setSelfUserId(authState.userId);

    FriendsTracker tracker = apiServer.getFriendsTracker();
    tracker.setWorldCache(worldCache);
    tracker.setInstanceCache(instanceCache);
    tracker.setSelf(authState.userId, authState.displayName, authState.currentAvatar,
        authState.status, authState.statusDescription,
        authState.bio, authState.pronouns, authState.bioLinks);

    apiServer.setWorldCache(worldCache);
    apiServer.setInstanceCache(instanceCache);
    apiServer.setHTTPClient(client);
    apiServer.setContentService(contentService);
    apiServer.setRateLimiter(rateLimiter);
    apiServer.setAPIMutex(vrcApiMutex);

    // Drop a Portal companion sidecar. Owns its own thread; the rest of
    // the server only ever calls enqueueVisit() and (via the API) triggerPair().
    DropaPortalDelegator dapDelegator = new DropaPortalDelegator();
    DropaPortal dropaPortal = new DropaPortal(store, dapDelegator);
    apiServer.setDropaPortalDelegator(dapDelegator, &dropaPortal.triggerPair);
    dropaPortal.start();

    // Shared re-authentication routine, assigned once `vrcws` exists (below).
    // The WebSocket calls it when the pipeline rejects the token; the re-seed
    // path calls it when a REST call comes back 401. Captured by reference
    // here so the callback sees the real delegate once it's assigned.
    void delegate() reauth;

    // Install the re-seed callback the worker thread will call on its
    // periodic tick or when requested via requestReseed().
    apiServer.setReseedCallback({
        doReseed(client, rateLimiter, vrcApiMutex, worldCache, instanceCache, tracker, reauth);
    });

    // Flag used to ignore the very first WebSocket connect event, since
    // we already seeded above. Subsequent (reconnect) events trigger a
    // re-seed via APIServer.requestReseed().
    shared bool wsSeenFirstConnect = false;

    // WebSocket event listener and callback.
    //
    // Orchestrates: enrich -> tracker -> (maybe suppress raw) -> store/broadcast
    // synthetics -> push friends snapshot. Suppression: when the tracker
    // produces a synthetic avatar-change, the triggering raw event
    // (friend-location/friend-update/user-update/user-location) is just noise
    // so we drop it instead of polluting the log and the live feed.
    VRCWebSocket vrcws = new VRCWebSocket(authState.authToken,
    (VRCEvent event)
    {
        logDebugging("event callback: type=%s", event.typeRaw);
        FriendsTracker tracker = apiServer.getFriendsTracker();

        tracker.enrichContent(event);
        worldCache.enrichWorldName(event);

        // Process event to see if a friend changed
        bool friendsChanged = tracker.processEvent(event);
        VRCEvent[] synthetics = tracker.takePendingSynthetics();

        // Surface self world transitions to the DropAPortal sidecar.
        // Filter raw events here so the sidecar stays self-contained.
        // enqueueVisit is mutex-guarded and safe to call regardless of
        // thread state, so no liveness check is needed.
        if (event.type == EventType.userLocation)
        {
            string selfId = tracker.getSelfUserId();
            string evUserId;
            if (const(JSONValue)* v = "userId" in event.content)
                if (v.type == JSONType.string)
                    evUserId = v.str;
            if (selfId.length > 0 && evUserId == selfId)
            {
                string location;
                if (const(JSONValue)* v = "location" in event.content)
                    if (v.type == JSONType.string)
                        location = v.str;
                string worldId = WorldCache.extractWorldId(location);
                if (worldId.length > 0)
                    dropaPortal.enqueueVisit(worldId, event.receivedAt.toUnixTime!long());
            }
        }

        // A friend-location with location="traveling" is the first half of a
        // world transition; the arrival event follows seconds later carrying
        // the concrete instance. Persisting both produces feed doubles. Emit
        // an ephemeral friend-traveling instead — broadcast live so clients
        // can show a "Joining X" indicator, but never stored. Tracker state
        // already absorbed the transient via processEvent above.
        VRCEvent traveling;
        bool isTraveling = false;
        if (event.type == EventType.friendLocation)
        {
            if (const(JSONValue)* v = "location" in event.content)
            {
                if (v.type == JSONType.string && v.str == "traveling")
                    isTraveling = true;
            }
        }
        if (isTraveling)
        {
            JSONValue tc;
            tc["userId"] = JSONValue("");
            if (const(JSONValue)* v = "userId" in event.content)       tc["userId"] = *v;
            if (const(JSONValue)* v = "displayName" in event.content)  tc["displayName"] = *v;
            if (const(JSONValue)* v = "travelingToLocation" in event.content) tc["travelingToLocation"] = *v;
            if (const(JSONValue)* v = "worldName" in event.content)    tc["worldName"] = *v;
            if (const(JSONValue)* v = "world" in event.content)        tc["world"] = *v;
            traveling = VRCEvent(
                EventType.friendTraveling,
                "friend-traveling",
                tc,
                event.receivedAt,
                JSONValue([
                    "type":    JSONValue("friend-traveling"),
                    "content": JSONValue(tc.toString()),
                ]).toString()
            );
        }

        // Drop avatar-noise raws when they bring no new info: either we
        // already produced a synthetic for them, or nothing in our cached
        // friend state actually moved (VRChat re-emits friend-update /
        // friend-location even when no observable property changed).
        // Also drop traveling friend-locations; currently no use for saving it.
        bool suppressRaw = isTraveling
            || (isAvatarNoiseEvent(event.type)
                && (synthetics.length > 0 || friendsChanged == false));
        if (suppressRaw)
        {
            logTrace("suppressed raw %s (synthetics=%d changed=%s traveling=%s)",
                event.typeRaw, synthetics.length, friendsChanged, isTraveling);
        }
        else
        {
            long eventId = store.storeEvent(event);
            logTrace("[#%d %s] %s", eventId, event.typeRaw, event.content.toString());
            apiServer.broadcast(event, eventId);
        }

        // Ephemeral broadcast: id=0 signals "not persisted, do not advance
        // client high-water mark."
        if (isTraveling)
        {
            logTrace("[#0 friend-traveling] %s", traveling.content.toString());
            apiServer.broadcast(traveling, 0);
        }

        foreach (ref syn; synthetics)
        {
            long synId = store.storeEvent(syn);
            logInfo("[#%d %s] %s", synId, syn.typeRaw, syn.content.toString());
            apiServer.broadcast(syn, synId);
        }

        if (friendsChanged)
            apiServer.broadcastFriendsSnapshot();

        if (tracker.takePendingSelfChange())
            apiServer.broadcastSelf();
    });
    vrcws.setReconnectBackoff(config.reconnectInterval, config.reconnectMax);
    // This is the callback when the WS connection status changes
    vrcws.setStatusCallback((bool connected, string lastError)
    {
        logInfo("VRChat WebSocket %s", connected ? "connected" : "disconnected");
        apiServer.setVRChatStatus(connected, lastError);
        store.logConnection(connected ? "connected" : "disconnected");

        if (connected)
        {
            // Skip the very first connect; it's the initial startup
            // handshake right after we already seeded inline above.
            if (wsSeenFirstConnect == false)
            {
                wsSeenFirstConnect = true;
                return;
            }
            // Reconnect after a disconnect window: refresh friend state
            // since events fired during the gap are lost.
            apiServer.requestReseed();
        }
    });
    // Shared re-auth. authenticate() runs unguarded (as before) so a headless
    // 2FA prompt can't stall other API work; only the cookie flush is taken
    // under the mutex. When the re-seed path invokes this it already holds
    // vrcApiMutex, but the mutex is recursive so the flush re-lock is safe.
    reauth = {
        logInfo("Re-authenticating with VRChat...");
        AuthState newState = authenticate(config, client, delegator);
        vrcws.setToken(newState.authToken);
        // Persist the rotated session cookie under the API mutex so we
        // don't touch the curl handle concurrently with other callers.
        synchronized (vrcApiMutex)
            client.flushCookies();
        logInfo("Re-authenticated as %s", newState.displayName);
    };
    vrcws.setReAuthCallback(reauth);

    // Initial seed reuses the same helper so startup state quality matches
    // what the worker produces on subsequent passes. Runs after reauth is
    // wired (so a stale startup cookie can recover) and before the WS starts
    // (so tracker state is ready for the first live events).
    doReseed(client, rateLimiter, vrcApiMutex, worldCache, instanceCache, tracker, reauth);

    vrcws.start();

    installSignalHandlers();

    logInfo(headless ? "Server running." : "Server running. Press Ctrl+C to stop.");

    // Wait for a shutdown signal. The session cookie is already flushed
    // after each (re)auth; we only need one more flush on the way out.
    while (g_running)
        Thread.sleep(dur!"msecs"(1000));

    logInfo("Shutting down, flushing session...");
    synchronized (vrcApiMutex)
        client.flushCookies();
}

void cmdAuth(ref Config config)
{
    logInfo("Interactive VRChat login");
    scope HTTPClient client = new HTTPClient();
    AuthState authState = interactiveLogin(config, client);
    logInfo("Authenticated as %s (%s)", authState.displayName, authState.userId);
    logInfo("Session saved. You can now run the server.");
}

void cmdEvents(ref Config config)
{
    import std.stdio : writefln;
    scope Database store = new Database(config.dbPath);
    foreach (row; store.queryRecentEvents(50))
        writefln("#%s [%s] %s: %s", row[0], row[1], row[2], row[3]);
}

template DVER(uint ver)
{
    enum DVER =
        cast(char)((ver / 1000) + '0') ~ "." ~
        cast(char)(((ver % 1000) / 100) + '0') ~
        cast(char)(((ver % 100) / 10) + '0') ~
        cast(char)((ver % 10) + '0');
}

// Hack to get arsd-official version at compile-time
enum string arsdVersion = () {
    // string import resolved at compile time
    enum selectionsJson = import("dub.selections.json");
    enum parsed = parseJSON(selectionsJson);                            
    enum ver = parsed["versions"]["arsd-official"].str;
    return ver;  // "11.5.3" 
}();

void printline(string field, string value)
{
    writefln("%*s  %s", -16, field ? field : "", value);
}

void cliVersion()
{
    import core.stdc.stdlib : exit;
    import server.config : VERSION;
    static immutable string BUILT       = "Built: " ~ __TIMESTAMP__;
    static immutable string COMPILER    = __VENDOR__ ~ " " ~ DVER!__VERSION__;
    printline("vrcd-server",    VERSION);
    printline(null,             BUILT);
    printline("License",        "BSD-3-Clause-Clear");
    printline(null,             "Copyright 2026 (c) dd86k <dd@dax.moe>");
    printline("Homepage",       "https://github.com/dd86k/vrcd");
    printline("Compiler",       COMPILER);
    
    import ddcurl.libcurl : curlVersion;
    printline("libcurl",        curlVersion());
    
    printline("arsd-official",  arsdVersion);
    
    exit(0);
}

/// Maximum number of individual GET /users/{id} calls per re-seed pass.
/// Bounds the repair work to avoid spamming the VRChat API.
private enum int REPAIR_CAP = 25;

/// Minimum rate-limit headroom before the repair pass is skipped.
private enum int REPAIR_HEADROOM = 50;

/// Fetch the friends list from VRChat, repair any obviously-stale entries,
/// backfill world names and instance occupancy, and swap the result into
/// the tracker. Holds the shared VRChat API mutex for the duration of the
/// REST work.
void doReseed(HTTPClient client, RateLimitTracker rateLimiter,
    Mutex vrcApiMutex, WorldCache worldCache, InstanceCache instanceCache,
    FriendsTracker tracker, void delegate() reauth)
{
    logInfo("Re-seed: starting pass");

    JSONValue[] allFriends;
    int repairedCount;
    int mismatchCount;
    int worldFetchCount;
    int instanceFetchCount;

    synchronized (vrcApiMutex)
    {
        allFriends = fetchAllFriendsLocked(client, rateLimiter, reauth);
        if (allFriends.length == 0)
        {
            logWarn("Re-seed: bulk fetch returned no friends, aborting pass");
            return;
        }

        // Broken-friend repair.
        repairBrokenFriendsLocked(allFriends, client, rateLimiter,
            repairedCount, mismatchCount);

        // World-name backfill: walk unique worldIds and prime the cache.
        worldFetchCount = backfillWorldNamesLocked(allFriends, worldCache, rateLimiter);

        // Instance occupancy backfill: walk unique public locations.
        instanceFetchCount = backfillInstancesLocked(allFriends, instanceCache, rateLimiter);
    }

    logInfo("Re-seed: fetched=%d mismatches=%d repaired=%d worlds_fetched=%d instances_fetched=%d",
        allFriends.length, mismatchCount, repairedCount, worldFetchCount, instanceFetchCount);

    FriendsTracker.FriendState[string] newMap = FriendsTracker.buildFriendMap(allFriends);
    tracker.replaceAll(newMap);
}

/// Paginate /auth/user/friends (both online and offline pages).
/// Caller must hold vrcApiMutex.
private JSONValue[] fetchAllFriendsLocked(HTTPClient client, RateLimitTracker rateLimiter,
    void delegate() reauth)
{
    import std.format : format;

    enum int PAGE_SIZE = 100;
    JSONValue[] allFriends;

    // A 401 means VRChat rejected the session cookie (expired or revoked).
    // Re-authenticate once and retry, then give up so a persistently bad
    // session can't spin. The guard spans both the online and offline pages:
    // one refresh restores the cookie for every remaining request.
    bool reauthed = false;

    logInfo("Fetching friends list from VRChat API...");

    foreach (bool offlinePage; [false, true])
    {
        int offset;
        while (true)
        {
            if (rateLimiter)
                rateLimiter.waitIfNeeded();

            string path = format!"/auth/user/friends?offset=%d&n=%d&offline=%s"(
                offset, PAGE_SIZE, offlinePage ? "true" : "false");
            HTTPResponse resp = client.get(path);
            if (rateLimiter)
                rateLimiter.update(resp);

            if (resp.code == 401 && reauth && reauthed == false)
            {
                reauthed = true;
                logWarn("Friends fetch got HTTP 401; re-authenticating and retrying");
                reauth();
                continue; // Retry the same page with the refreshed session.
            }

            if (resp.code != 200)
            {
                logWarn("Failed to fetch friends (offline=%s offset=%d): HTTP %d",
                    offlinePage, offset, resp.code);
                break;
            }

            JSONValue json = parseJSON(resp.text);
            if (json.type != JSONType.array)
            {
                logWarn("Unexpected friends response type");
                break;
            }

            JSONValue[] page = json.array;
            foreach (ref JSONValue f; page)
                allFriends ~= f;

            logInfo("Fetched %d friends (offline=%s offset=%d)",
                page.length, offlinePage, offset);

            if (page.length < PAGE_SIZE)
                break;

            offset += PAGE_SIZE;
        }
    }

    return allFriends;
}

/// Walk the friend list and individually refetch any whose derived state
/// (from `platform`) disagrees with the bulk-reported location, or whose
/// `location == "traveling"`. Caps the number of individual calls.
/// Caller must hold vrcApiMutex.
private void repairBrokenFriendsLocked(ref JSONValue[] friendsArr,
    HTTPClient client, RateLimitTracker rateLimiter,
    out int repairedCount, out int mismatchCount)
{
    if (rateLimiter)
    {
        if (rateLimiter.isBlocked())
        {
            logWarn("Repair pass skipped: rate limited");
            return;
        }
        int remaining = rateLimiter.getRemaining();
        if (remaining >= 0 && remaining < REPAIR_HEADROOM)
        {
            logWarn("Repair pass skipped: rate-limit headroom low (%d < %d)",
                remaining, REPAIR_HEADROOM);
            return;
        }
    }

    foreach (size_t i, ref JSONValue f; friendsArr)
    {
        if (repairedCount >= REPAIR_CAP)
            break;

        string userId;
        if (const(JSONValue)* v = "id" in f)
            userId = v.str;
        if (userId.length == 0)
            continue;

        string platform;
        if (const(JSONValue)* v = "platform" in f)
            platform = v.str;

        string location;
        if (const(JSONValue)* v = "location" in f)
            location = v.str;

        // Derive expected state from platform and compare to bulk location.
        // platform == "web"  -> expected active (location "offline")
        // platform empty     -> expected offline
        // else               -> expected online (location should be real)
        bool mismatched;
        if (platform == "web")
        {
            // Active-on-website: location should be offline/empty/offline:offline.
            mismatched = location.length > 0 && location != "offline"
                && location != "offline:offline";
        }
        else if (platform.length == 0)
        {
            mismatched = location.length > 0 && location != "offline"
                && location != "offline:offline";
        }
        else
        {
            // In-game platform: should have a real instance or private.
            mismatched = location.length == 0
                || location == "offline"
                || location == "offline:offline";
        }

        bool traveling = location == "traveling";
        if (mismatched == false && traveling == false)
            continue;

        ++mismatchCount;

        if (rateLimiter)
            rateLimiter.waitIfNeeded();

        try
        {
            HTTPResponse resp = client.get("/users/" ~ userId);
            if (rateLimiter)
                rateLimiter.update(resp);
            if (resp.code != 200)
            {
                logWarn("Repair: GET /users/%s -> HTTP %d", userId, resp.code);
                continue;
            }
            JSONValue fresh = parseJSON(resp.text);
            if (fresh.type != JSONType.object)
                continue;
            friendsArr[i] = fresh;
            ++repairedCount;
            logDebugging("Repair: refreshed %s (platform=%s location=%s -> new)",
                userId, platform, location);
        }
        catch (Exception e)
        {
            logWarn("Repair: GET /users/%s failed: %s", userId, e.msg);
        }
    }
}

/// Walk the friend list, extract unique world IDs, and call
/// WorldCache.resolveLocked on each so subsequent snapshot builds can
/// return a name via tryGet. Caller must hold vrcApiMutex.
private int backfillWorldNamesLocked(JSONValue[] friendsArr,
    WorldCache worldCache, RateLimitTracker rateLimiter)
{
    if (worldCache is null)
        return 0;

    bool[string] seen;
    int fetched;

    foreach (ref JSONValue f; friendsArr)
    {
        string location;
        if (const(JSONValue)* v = "location" in f)
            location = v.str;

        string worldId = WorldCache.extractWorldId(location);
        if (worldId is null)
            continue;
        if (worldId in seen)
            continue;
        seen[worldId] = true;

        if (rateLimiter)
        {
            if (rateLimiter.isBlocked())
            {
                logWarn("World-name backfill stopping: rate limited");
                break;
            }
            int remaining = rateLimiter.getRemaining();
            if (remaining >= 0 && remaining < REPAIR_HEADROOM)
            {
                logWarn("World-name backfill stopping: headroom low (%d)", remaining);
                break;
            }
        }

        // resolveLocked returns the cached name if fresh, otherwise fetches.
        // It only incurs a REST call on a true cache miss.
        string name = worldCache.resolveLocked(worldId);
        if (name && name != worldId)
            ++fetched;
    }

    return fetched;
}

/// Walk the friend list, extract unique public instance locations, and
/// call InstanceCache.resolveLocked on each so snapshot builds can return
/// occupancy via tryGet. Caller must hold vrcApiMutex.
private int backfillInstancesLocked(JSONValue[] friendsArr,
    InstanceCache instanceCache, RateLimitTracker rateLimiter)
{
    if (instanceCache is null)
        return 0;

    bool[string] seen;
    int fetched;

    foreach (ref JSONValue f; friendsArr)
    {
        string location;
        if (const(JSONValue)* v = "location" in f)
            location = v.str;

        if (InstanceCache.isResolvable(location) == false)
            continue;
        if (location in seen)
            continue;
        seen[location] = true;

        if (rateLimiter)
        {
            if (rateLimiter.isBlocked())
            {
                logWarn("Instance backfill stopping: rate limited");
                break;
            }
            int remaining = rateLimiter.getRemaining();
            if (remaining >= 0 && remaining < REPAIR_HEADROOM)
            {
                logWarn("Instance backfill stopping: headroom low (%d)", remaining);
                break;
            }
        }

        InstanceInfo info = instanceCache.resolveLocked(location);
        if (info.known)
            ++fetched;
    }

    return fetched;
}

// As per tradition, keep main() at the end of module
int main(string[] args)
{
    Config config = Config.defaults();
    uint cliSet; // Bitmask of fields explicitly set by CLI.
    bool helpConfig;

    GetoptResult opts = void;
    try opts = getopt(args,
        std.getopt.config.caseSensitive,
        "basedir|b", "Base directory for all config/data files", (string _, string val) {
            config.setBaseDir(val);
            cliSet |= Config.SET_DB | Config.SET_AUTH | Config.SET_COOKIE_JAR;
        },
        "config|c", "Path to config file", (string _, string val) {
            config.configPath = val;
        },
        "db|d",     "Path to SQLite database", (string _, string val) {
            config.dbPath = val;
            cliSet |= Config.SET_DB;
        },
        "listen|l", "Listen address (host:port)", (string _, string val) {
            config.parseListen(val);
            cliSet |= Config.SET_LISTEN;
        },
        "secret",   "Shared secret for client auth", (string _, string val) {
            config.apiSecret = val;
            cliSet |= Config.SET_SECRET;
        },
        "totp-secret", "Base32 TOTP secret to auto-answer VRChat's 2FA prompt", (string _, string val) {
            config.totpSecret = val;
            cliSet |= Config.SET_TOTP;
        },
        "auth|a",   "Path to credentials file", (string _, string val) {
            config.credentialsPath = val;
            cliSet |= Config.SET_AUTH;
        },
        "verbose|v","Enable verbose logging", () {
            config.verbose = true;
            cliSet |= Config.SET_VERBOSE;
        },
        "log-file|L","Append log output to file", (string _, string val) {
            config.logFilePath = val;
            cliSet |= Config.SET_LOG_FILE;
        },
        "reconnect-interval", "Base seconds between VRChat WS reconnect attempts (doubles per failure)", (string _, string val) {
            import std.conv : to;
            import core.time : dur;
            config.reconnectInterval = dur!"seconds"(val.to!int);
        },
        "reconnect-max", "Cap on the exponential reconnect backoff in seconds", (string _, string val) {
            import std.conv : to;
            import core.time : dur;
            config.reconnectMax = dur!"seconds"(val.to!int);
        },
        "prune-retain", "Delete events older than AMOUNT UNIT (e.g. '3 months')", (string _, string val) {
            import server.config : parsePruneRetain;
            config.pruneRetain = parsePruneRetain(val);
            cliSet |= Config.SET_PRUNE;
        },
        "tls-cert", "Path to PEM TLS certificate (enables TLS when paired with --tls-key)", (string _, string val) {
            config.tlsCertPath = val;
            cliSet |= Config.SET_TLS_CERT;
        },
        "tls-key",  "Path to PEM TLS private key", (string _, string val) {
            config.tlsKeyPath = val;
            cliSet |= Config.SET_TLS_KEY;
        },
        "tls-ca",   "Path to CA certificate for client verification (mTLS)", (string _, string val) {
            config.tlsCaPath = val;
            cliSet |= Config.SET_TLS_CA;
        },
        "tls-verify-client", "Require clients to present a valid certificate", () {
            config.tlsVerifyClient = true;
            cliSet |= Config.SET_TLS_VERIFY;
        },
        "tls-port", "Separate port for TLS connections", (string _, string val) {
            import std.conv : to;
            config.tlsPort = val.to!ushort;
            cliSet |= Config.SET_TLS_PORT;
        },
        "tls-only", "Disable plain TCP listener when TLS is active", () {
            config.tlsOnly = true;
            cliSet |= Config.SET_TLS_ONLY;
        },
        "version",  "Show version page and exit", &cliVersion,
        "help-config", "Show effective config paths and exit", &helpConfig,
    );
    catch (Exception ex)
    {
        stderr.writeln("error: ", ex.msg);
        return 1;
    }

    // Load config file after CLI so we can use --config to set the path.
    // Fields explicitly set on CLI are preserved; file fills in the rest.
    config.loadFromFile(config.configPath, cliSet);

    if (opts.helpWanted)
    {
        defaultGetoptPrinter(
            "vrcd server - VRChat event recorder\n" ~
            "\n" ~
            "Usage: server [commands...] [options...]\n" ~
            "\n" ~
            "Commands:\n" ~
            "  run      Start the server (default)\n" ~
            "  auth     Interactive login to VRChat\n" ~
            "  events   Query stored events\n" ~
            "\n" ~
            "Options:",
            opts.options,
        );
        return 0;
    }

    if (helpConfig)
    {
        import std.file : exists;
        import std.conv : text;
        printline("Config file", config.configPath ~ (exists(config.configPath) ? " (loaded)" : " (not found)"));
        printline("Database", config.dbPath);
        printline("Credentials", config.credentialsPath);
        printline("Cookie jar", config.cookieJarPath);
        printline("Listen", text(config.listenAddr, ":", config.listenPort));
        printline("Secret", config.apiSecret.length > 0 ? "(set)" : "(not set)");
        printline("Log file", config.logFilePath.length > 0 ? config.logFilePath : "(not set)");
        printline("Verbose", config.verbose ? "true" : "false");
        printline("Prune retain", config.pruneRetain.length > 0 ? config.pruneRetain : "(disabled)");
        return 0;
    }

    // Set up logging, if log-file is set, do not bother creating the console appender
    LogLevel logLevel = config.verbose ? LogLevel.trace : LogLevel.info;
    if (config.logFilePath.length > 0)
    {
        try
        {
            FileAppender fileAppender = new FileAppender(config.logFilePath);
            fileAppender.setLogLevel(logLevel);
            logAddAppender(fileAppender);
        }
        catch (Exception ex)
        {
            stderr.writeln("error: could not open log file '", config.logFilePath, "': ", ex.msg);
            return 1;
        }
    }
    else
    {
        ConsoleAppender logAppender = new ConsoleAppender();
        logAppender.setLogLevel(logLevel);
        logAddAppender(logAppender);
    }
    
    // Useless: [ddcurl.utils:35] data=74DF5C6EE6ED size=105
    logSetModuleLevel("ddcurl.utils", LogLevel.none);
    // Useless: [ddcurl.websocket:86] curl_ws_recv: code=0 curl_ws_frame { age=0 flags=1 offset=0 left=0 len=2976 }
    logSetModuleLevel("ddcurl.websocket", LogLevel.none);
    // Redundant with server.main module logging info
    logSetModuleLevel("server.vrchat.websocket", LogLevel.none);
    // Useless: [server.api:473] sendLine: len=16
    // Useless: [server.api:534] processMessage: type=pong authenticated=true len=15
    // Useless: [server.api:610] processMessage: pong received
    logSetModuleLevel("server.api", LogLevel.none);
    
    // ddhttp.http has some useful and useless entries, don't disable it yet
    
    // Throws and prints by default
    if (args.length > 1)
    {
        foreach (string command; args[1..$])
        {
            switch (command)
            {
                case "run":
                    cmdRun(config);
                    break;
                case "auth":
                    cmdAuth(config);
                    break;
                case "events":
                    cmdEvents(config);
                    break;
                default:
                    logError("Unknown command: %s", command);
                    break;
            }
        }
    }
    else // by default, run
    {
        cmdRun(config);
    }
    
    return 0;
}