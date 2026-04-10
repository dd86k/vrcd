/// World cache
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.worldcache;

import core.sync.mutex : Mutex;

import std.json;

import ddlogger;
import ddcurl;

import server.events;
import server.ratelimit;

/// Caches world names resolved from the VRChat REST API.
/// Success entries have a 1-day TTL; failure entries have a 1-hour TTL.
class WorldCache
{
    private struct CacheEntry
    {
        string name;
        long expiresAt; // Unix timestamp (seconds)
    }

    private CacheEntry[string] cache; // worldId -> entry
    private Mutex cacheMutex;
    private HTTPClient client;
    private RateLimitTracker rateLimiter;
    private Mutex apiMutex; // Shared VRChat API serializer (optional).

    this(HTTPClient client, RateLimitTracker rateLimiter = null)
    {
        this.client = client;
        this.rateLimiter = rateLimiter;
        this.cacheMutex = new Mutex();
    }

    /// Provide the shared VRChat API mutex so HTTPClient+RateLimitTracker
    /// access here is serialized with other VRChat API callers.
    void setAPIMutex(Mutex m)
    {
        apiMutex = m;
    }

    /// Cache-only lookup. Returns the cached name if fresh, empty string
    /// otherwise. Never issues HTTP and never touches the rate limiter.
    /// Safe to call from any thread without holding the API mutex.
    string tryGet(string worldId)
    {
        import core.stdc.time : time;
        if (worldId.length == 0)
            return "";
        long now = time(null);
        synchronized (cacheMutex)
        {
            CacheEntry* entry = worldId in cache;
            if (entry is null || entry.expiresAt <= now)
                return "";
            // Don't return the fallback-to-ID entry as a "name".
            return entry.name == worldId ? "" : entry.name;
        }
    }

    /// Resolve a world ID to a human-readable name.
    /// Returns the cached name if fresh, otherwise fetches from VRChat API.
    /// On failure, returns the worldId as-is and caches with 1-hour TTL.
    /// Acquires the shared API mutex if one is configured.
    string resolve(string worldId)
    {
        if (apiMutex !is null)
        {
            synchronized (apiMutex)
                return resolveLocked(worldId);
        }
        return resolveLocked(worldId);
    }

    /// Same as resolve(), but assumes the caller already holds the shared
    /// API mutex. Use from paths that batch multiple VRChat API calls.
    string resolveLocked(string worldId)
    {
        import core.stdc.time : time;
        long now = time(null);

        synchronized (cacheMutex)
        {
            CacheEntry* entry = worldId in cache;
            if (entry !is null && entry.expiresAt > now)
            {
                logTrace("resolve: cache hit for %s -> %s", worldId, entry.name);
                return entry.name;
            }
        }

        logDebugging("resolve: cache miss for %s, fetching", worldId);
        string name = fetchWorldName(worldId);
        long ttl; // Time to live in seconds (unix time)

        if (name.length > 0)
        {
            ttl = 24 * 60 * 60; // 1 day
        }
        else
        {
            name = worldId; // Fallback to ID
            ttl = 60 * 60;  // 1 hour
        }

        synchronized (cacheMutex)
        {
            cache[worldId] = CacheEntry(name, now + ttl);
            logDebugging("resolve: cached %s -> %s (ttl=%ds, entries=%d)",
                worldId, name, ttl, cache.length);
        }
        return name;
    }

    /// Enrich a VRCEvent's content with a resolved world name.
    /// Checks for worldId or extracts it from the location field.
    void enrichWorldName(ref VRCEvent event)
    {
        // Skip if worldName is already present.
        if (const(JSONValue)* v = "worldName" in event.content)
            if (v.str.length > 0)
                return;

        string worldId;
        if (const(JSONValue)* v = "worldId" in event.content)
            worldId = v.str;
        if (worldId.length == 0)
        {
            string location;
            if (const(JSONValue)* v = "location" in event.content)
                location = v.str;
            worldId = extractWorldId(location);
        }

        if (worldId.length == 0)
            return;

        logTrace("enrichWorldName: resolving %s", worldId);
        string name = resolve(worldId);
        if (name.length > 0)
            event.content["worldName"] = JSONValue(name);
    }

    /// Extract the world ID (wrld_xxx) from a location string like
    /// "wrld_xxx:12345~region(us)". Returns empty string if not a world location.
    static string extractWorldId(string location)
    {
        if (location.length < 5 || location[0 .. 5] != "wrld_")
            return "";

        import std.string : indexOf;
        ptrdiff_t sep = location.indexOf(':');
        if (sep > 0)
            return location[0 .. sep];

        return location; // No instance suffix, just the world ID
    }

private:

    string fetchWorldName(string worldId)
    {
        // Skip fetch if rate-limited.
        if (rateLimiter !is null && rateLimiter.isBlocked())
        {
            logWarn("Skipping world fetch for %s: rate limited", worldId);
            return "";
        }

        logDebugging("fetchWorldName: GET /worlds/%s", worldId);
        try
        {
            HTTPResponse resp = client.get("/worlds/" ~ worldId);
            logDebugging("fetchWorldName: %s -> HTTP %d", worldId, resp.code);
            if (rateLimiter !is null)
                rateLimiter.update(resp);
            if (resp.code != 200)
            {
                logWarn("Failed to fetch world %s: HTTP %d", worldId, resp.code);
                return "";
            }

            JSONValue json = parseJSON(resp.text);
            if (const(JSONValue)* v = "name" in json)
                return v.str;
            return "";
        }
        catch (Exception e)
        {
            logWarn("Error fetching world %s: %s", worldId, e.msg);
            return "";
        }
    }
}

