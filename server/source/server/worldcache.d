/// World cache
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.worldcache;

import core.sync.mutex : Mutex;

import std.json;
import std.datetime;

import ddlogger;
import ddcurl;

import server.database;
import server.events;
import server.ratelimit;

/// How long a resolved world is believed, in seconds. Applies to both tiers:
/// the same age decides whether a row in `cache_world` is still worth using.
private enum long WORLD_TTL = 24 * 60 * 60;
/// How long a failed lookup is remembered, in seconds. Memory only: a failure
/// says nothing about the world, only about this moment.
private enum long FAILURE_TTL = 60 * 60;

/// Caches world names resolved from the VRChat REST API.
///
/// Two tiers. The in-memory map is the hot one and holds negative entries as
/// well; `cache_world` in the database is the one that survives a restart,
/// which is the point of it: world names do not change, and re-fetching every
/// world the server already knew is VRChat calls spent on an answer it had.
/// A row older than the TTL is still kept and still returned when VRChat
/// cannot be reached -- an old name beats a raw ID on the page.
///
/// Without a database this is memory-only, exactly as it was.
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
    private Database store;  // Persistent tier (optional).

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

    /// Provide the database that backs the cache across restarts. Optional:
    /// without one, the cache lives and dies with the process.
    void setDatabase(Database db)
    {
        store = db;
    }

    /// Cache-only lookup. Returns the cached name if fresh, empty string
    /// otherwise. Never issues HTTP and never touches the rate limiter.
    /// Safe to call from any thread without holding the API mutex.
    string tryGet(string worldId)
    {
        if (worldId is null)
            return null;
        long now = Clock.currTime.toUnixTime!long();
        synchronized (cacheMutex)
        {
            CacheEntry* entry = worldId in cache;
            if (entry && entry.expiresAt > now)
                // Don't return the fallback-to-ID entry as a "name".
                return entry.name == worldId ? null : entry.name;
        }

        // Fall through to the database. This is the path the friends snapshot
        // takes, and right after a restart nothing has put anything in memory
        // yet -- without this, the first snapshots after every restart show
        // raw IDs for worlds the server has known for months. Fresh rows only:
        // this path promises not to spend a VRChat call, and a stale row has
        // one waiting behind it.
        CachedWorld row = lookupStore(worldId, now, false);
        if (row.found == false)
            return null;

        remember(worldId, row.name, now + WORLD_TTL);
        return row.name;
    }

    /// Resolve a world ID to a human-readable name.
    /// Returns the cached name if fresh, otherwise fetches from VRChat API.
    /// On failure, returns the worldId as-is and caches with 1-hour TTL.
    /// Acquires the shared API mutex if one is configured.
    string resolve(string worldId)
    {
        if (apiMutex)
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
        // Skip non-world IDs like "private", "offline", "traveling" —
        // /worlds/{id} always 404s for these.
        if (isResolvable(worldId) == false)
            return worldId;

        long now = Clock.currTime.toUnixTime!long();

        synchronized (cacheMutex)
        {
            CacheEntry* entry = worldId in cache;
            if (entry && entry.expiresAt > now)
            {
                logTrace("resolve: cache hit for %s -> %s", worldId, entry.name);
                return entry.name;
            }
        }

        // The persistent tier, before spending a VRChat call on something the
        // server already fetched in a previous run.
        CachedWorld row = lookupStore(worldId, now, false);
        if (row.found)
        {
            remember(worldId, row.name, now + WORLD_TTL);
            logDebugging("resolve: database hit for %s -> %s", worldId, row.name);
            return row.name;
        }

        logDebugging("resolve: cache miss for %s, fetching", worldId);
        CachedWorld fetched = fetchWorld(worldId);
        string name = fetched.name;
        long ttl; // Time to live in seconds (unix time)

        if (name)
        {
            ttl = WORLD_TTL;
            // Write-through, so the next run starts where this one left off.
            // Only successes: a failure is about this moment, not the world,
            // and a row saying a world is named "wrld_..." would outlive the
            // outage that produced it.
            if (store)
            {
                try
                    store.cacheWorld(fetched);
                catch (Exception e)
                    logWarn("Failed to cache world %s: %s", worldId, e.msg);
            }
        }
        else
        {
            // Nothing came back. A row that has aged out is still the best
            // answer available -- names rarely change, and the alternative is
            // showing a raw ID while VRChat is unreachable or rate limiting.
            // Remembered on the failure TTL either way, so the next hour
            // retries rather than settling for it.
            CachedWorld stale = lookupStore(worldId, now, true);
            name = stale.found && stale.name.length > 0 ? stale.name : worldId;
            ttl = FAILURE_TTL;
        }

        remember(worldId, name, now + ttl);
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

        // resolve() falls back to returning the input ID as the "name" for
        // unresolvable inputs like "private"/"offline"/"traveling". Guard
        // here so we don't poison content with worldName="private", which
        // downstream handlers then mistake for a real world name.
        if (isResolvable(worldId) == false)
            return;

        logTrace("enrichWorldName: resolving %s", worldId);
        string name = resolve(worldId);
        if (name.length > 0 && name != worldId)
            event.content["worldName"] = JSONValue(name);
    }

    /// Extract the world ID (wrld_xxx) from a location string like
    /// "wrld_xxx:12345~region(us)". Returns empty string if not a world location.
    static string extractWorldId(string location)
    {
        import std.string : indexOf;

        if (isResolvable(location) == false)
            return null;

        ptrdiff_t sep = location.indexOf(':');
        if (sep > 0)
            return location[0 .. sep];

        return location; // No instance suffix, just the world ID
    }

    /// Whether this string is a real world ID worth fetching.
    /// "private", "offline", "traveling", null, etc. are not.
    static bool isResolvable(string worldId)
    {
        if (worldId.length < 5)
            return false;
        return worldId[0 .. 5] == "wrld_";
    }

private:

    /// Put a name in the memory tier.
    void remember(string worldId, string name, long expiresAt)
    {
        synchronized (cacheMutex)
        {
            cache[worldId] = CacheEntry(name, expiresAt);
            logTrace("remember: %s -> %s (entries=%d)", worldId, name, cache.length);
        }
    }

    /// Read the database tier. `allowStale` takes a row whatever its age, which
    /// is for the case where the fetch that would have replaced it just failed.
    ///
    /// A cache that cannot be read is a slow cache, not a broken server, so a
    /// database error here is logged and treated as a miss.
    CachedWorld lookupStore(string worldId, long now, bool allowStale)
    {
        CachedWorld row;
        if (store is null)
            return row;

        try row = store.getCachedWorld(worldId);
        catch (Exception e)
        {
            logWarn("Failed to read cached world %s: %s", worldId, e.msg);
            return CachedWorld.init;
        }

        if (row.found == false)
            return row;

        // A row with no name is not an answer, whatever its age.
        if (row.name.length == 0)
            return CachedWorld.init;

        if (allowStale == false && row.addedAt + WORLD_TTL <= now)
        {
            logTrace("lookupStore: %s is stale (added %d)", worldId, row.addedAt);
            return CachedWorld.init;
        }

        return row;
    }

    /// Fetch a world's metadata. `found` is false when nothing came back.
    ///
    /// Everything the table has a column for is kept, not just the name: the
    /// response carries it all anyway, and a fetch is the expensive part.
    CachedWorld fetchWorld(string worldId)
    {
        CachedWorld world;

        // Skip fetch if rate-limited.
        if (rateLimiter && rateLimiter.isBlocked())
        {
            logWarn("Skipping world fetch for %s: rate limited", worldId);
            return world;
        }

        logDebugging("fetchWorld: GET /worlds/%s", worldId);
        try
        {
            HTTPResponse resp = client.get("/worlds/" ~ worldId);
            logDebugging("fetchWorld: %s -> HTTP %d", worldId, resp.code);
            if (rateLimiter)
                rateLimiter.update(resp);
            if (resp.code != 200)
            {
                logWarn("Failed to fetch world %s: HTTP %d", worldId, resp.code);
                return world;
            }

            JSONValue json = parseJSON(resp.text);
            string name = jsonString(json, "name");
            if (name.length == 0)
                return world;

            world.found             = true;
            world.id                = worldId;
            world.name              = name;
            world.authorId          = jsonString(json, "authorId");
            world.authorName        = jsonString(json, "authorName");
            world.createdAt         = jsonString(json, "created_at");
            world.description       = jsonString(json, "description");
            world.imageUrl          = jsonString(json, "imageUrl");
            world.releaseStatus     = jsonString(json, "releaseStatus");
            world.thumbnailImageUrl = jsonString(json, "thumbnailImageUrl");
            world.updatedAt         = jsonString(json, "updated_at");
            if (const(JSONValue)* v = "version" in json)
                if (v.type == JSONType.integer)
                    world.worldVersion = v.integer;
            return world;
        }
        catch (Exception e)
        {
            logWarn("Error fetching world %s: %s", worldId, e.msg);
            return CachedWorld.init;
        }
    }
}

/// A string field, or empty when it is missing or is not one. VRChat leaves
/// optional fields out entirely and sends null for others.
private string jsonString(ref JSONValue json, string key)
{
    if (const(JSONValue)* v = key in json)
        if (v.type == JSONType.string)
            return v.str;
    return null;
}

