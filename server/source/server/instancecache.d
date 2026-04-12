/// Instance cache
///
/// Caches instance occupancy (n_users) and capacity resolved from the
/// VRChat REST API endpoint /instances/{worldId}:{instanceId}.
///
/// Populations change quickly, so TTLs are deliberately short: fresh
/// data has a 2-minute TTL and failures a 1-minute TTL. Rapid refreshes
/// by clients hit the cache; slower refreshes pay the fetch cost.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.instancecache;

import core.sync.mutex : Mutex;

import std.json;

import ddlogger;
import ddcurl;

import server.ratelimit;

/// Snapshot of instance occupancy as known to the cache.
/// `known == false` means we have no fresh entry.
struct InstanceInfo
{
    bool known;
    long nUsers;
    long capacity;
}

/// Caches instance occupancy from the VRChat REST API.
class InstanceCache
{
    private struct CacheEntry
    {
        long nUsers;
        long capacity;
        long expiresAt; // Unix timestamp (seconds)
        bool ok;        // true if the fetch succeeded
    }

    private CacheEntry[string] cache; // location -> entry
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

    /// Cache-only lookup. Returns a populated InstanceInfo if fresh,
    /// otherwise an InstanceInfo with `known == false`. Never issues HTTP.
    InstanceInfo tryGet(string location)
    {
        import core.stdc.time : time;
        InstanceInfo result;
        if (isResolvable(location) == false)
            return result;
        long now = time(null);
        synchronized (cacheMutex)
        {
            CacheEntry* entry = location in cache;
            if (entry is null || entry.expiresAt <= now || entry.ok == false)
                return result;
            result.known = true;
            result.nUsers = entry.nUsers;
            result.capacity = entry.capacity;
        }
        return result;
    }

    /// Resolve an instance location to occupancy. Returns cached value if
    /// fresh, otherwise fetches from the VRChat API. Acquires the shared
    /// API mutex if one is configured.
    InstanceInfo resolve(string location)
    {
        if (apiMutex !is null)
        {
            synchronized (apiMutex)
                return resolveLocked(location);
        }
        return resolveLocked(location);
    }

    /// Same as resolve(), but assumes the caller already holds the shared
    /// API mutex. Use from paths that batch multiple VRChat API calls.
    InstanceInfo resolveLocked(string location)
    {
        import core.stdc.time : time;
        InstanceInfo result;
        if (isResolvable(location) == false)
            return result;

        long now = time(null);
        synchronized (cacheMutex)
        {
            CacheEntry* entry = location in cache;
            if (entry !is null && entry.expiresAt > now)
            {
                logTrace("resolve: cache hit for %s (%d/%d ok=%s)",
                    location, entry.nUsers, entry.capacity, entry.ok);
                if (entry.ok)
                {
                    result.known = true;
                    result.nUsers = entry.nUsers;
                    result.capacity = entry.capacity;
                }
                return result;
            }
        }

        logDebugging("resolve: cache miss for %s, fetching", location);
        CacheEntry fresh;
        bool ok = fetchInstance(location, fresh);
        long ttl;
        if (ok)
        {
            fresh.ok = true;
            ttl = 120; // 2 minutes
        }
        else
        {
            ttl = 60;  // 1 minute
        }
        fresh.expiresAt = now + ttl;

        synchronized (cacheMutex)
        {
            cache[location] = fresh;
            logDebugging("resolve: cached %s -> %d/%d ok=%s (ttl=%ds entries=%d)",
                location, fresh.nUsers, fresh.capacity, fresh.ok, ttl, cache.length);
        }

        if (ok)
        {
            result.known = true;
            result.nUsers = fresh.nUsers;
            result.capacity = fresh.capacity;
        }
        return result;
    }

    /// Whether this location should even be looked up via the API.
    /// "private", "offline", "traveling" etc. are not resolvable.
    static bool isResolvable(string location)
    {
        if (location.length < 5)
            return false;
        return location[0 .. 5] == "wrld_";
    }

private:

    bool fetchInstance(string location, out CacheEntry entry)
    {
        // Skip fetch if rate-limited.
        if (rateLimiter !is null && rateLimiter.isBlocked())
        {
            logWarn("Skipping instance fetch for %s: rate limited", location);
            return false;
        }

        logDebugging("fetchInstance: GET /instances/%s", location);
        try
        {
            HTTPResponse resp = client.get("/instances/" ~ location);
            logDebugging("fetchInstance: %s -> HTTP %d", location, resp.code);
            if (rateLimiter !is null)
                rateLimiter.update(resp);
            if (resp.code != 200)
            {
                logWarn("Failed to fetch instance %s: HTTP %d", location, resp.code);
                return false;
            }

            JSONValue json = parseJSON(resp.text);
            if (const(JSONValue)* v = "n_users" in json)
                if (v.type == JSONType.integer || v.type == JSONType.uinteger)
                    entry.nUsers = v.integer;
            if (const(JSONValue)* v = "capacity" in json)
                if (v.type == JSONType.integer || v.type == JSONType.uinteger)
                    entry.capacity = v.integer;
            return true;
        }
        catch (Exception e)
        {
            logWarn("Error fetching instance %s: %s", location, e.msg);
            return false;
        }
    }
}
