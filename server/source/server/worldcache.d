/// World cache
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.worldcache;

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
    private HTTPClient client;
    private RateLimitTracker rateLimiter;

    this(HTTPClient client, RateLimitTracker rateLimiter = null)
    {
        this.client = client;
        this.rateLimiter = rateLimiter;
    }

    /// Resolve a world ID to a human-readable name.
    /// Returns the cached name if fresh, otherwise fetches from VRChat API.
    /// On failure, returns the worldId as-is and caches with 1-hour TTL.
    string resolve(string worldId)
    {
        import core.stdc.time : time;
        long now = time(null);

        // Check cache.
        CacheEntry* entry = worldId in cache;
        if (entry !is null && entry.expiresAt > now)
            return entry.name;

        // Fetch from API.
        string name = fetchWorldName(worldId);
        long ttl;

        if (name.length > 0)
        {
            ttl = 24 * 60 * 60; // 1 day
        }
        else
        {
            name = worldId; // Fallback to ID
            ttl = 60 * 60;  // 1 hour
        }

        cache[worldId] = CacheEntry(name, now + ttl);
        return name;
    }

    /// Enrich a VRCEvent's content with a resolved world name.
    /// Checks for worldId or extracts it from the location field.
    void enrichWorldName(ref VRCEvent event)
    {
        // Skip if worldName is already present.
        if (jsonStr(event.content, "worldName").length > 0)
            return;

        string worldId = jsonStr(event.content, "worldId");
        if (worldId.length == 0)
        {
            string location = jsonStr(event.content, "location");
            worldId = extractWorldId(location);
        }

        if (worldId.length == 0)
            return;

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

        try
        {
            HTTPResponse resp = client.get("/worlds/" ~ worldId);
            if (rateLimiter !is null)
                rateLimiter.update(resp);
            if (resp.code != 200)
            {
                logWarn("Failed to fetch world %s: HTTP %d", worldId, resp.code);
                return "";
            }

            JSONValue json = parseJSON(resp.text);
            return jsonStr(json, "name");
        }
        catch (Exception e)
        {
            logWarn("Error fetching world %s: %s", worldId, e.msg);
            return "";
        }
    }
}

private string jsonStr(JSONValue json, string key)
{
    if (key in json && json[key].type == JSONType.string)
        return json[key].str;
    return "";
}
