/// Friends tracker
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.friends;

import core.sync.mutex : Mutex;

import std.json;

import ddlogger;

import server.events;
import server.worldcache;

/// Tracks the current state of all friends from WebSocket events.
/// Maintained in-memory on the server; clients request a snapshot.
class FriendsTracker
{
    /// Per-friend state.
    struct FriendState
    {
        string userId;
        string displayName;
        string status;           // "active", "join me", "ask me", "busy", "offline"
        string statusDescription;
        string location;         // instance ID, "private", "offline", or ""
        string worldName;
        string platform;         // "standalonewindows", "android", etc.
        bool online;
    }

    private FriendState[string] friends; // keyed by userId
    private Mutex friendsMutex;
    private WorldCache worldCache;

    this()
    {
        friendsMutex = new Mutex();
    }

    /// Provide a WorldCache for cache-only world-name fallback in snapshots.
    void setWorldCache(WorldCache wc)
    {
        worldCache = wc;
    }

    /// Build a FriendState map from a list of friend JSON objects
    /// (as returned by GET /auth/user/friends). Pure: no locks, no I/O.
    static FriendState[string] buildFriendMap(JSONValue[] friendObjects)
    {
        FriendState[string] result;
        foreach (ref JSONValue f; friendObjects)
        {
            string userId;
            if (const(JSONValue)* v = "id" in f)
                userId = v.str;
            if (userId.length == 0)
                continue;

            FriendState state;
            state.userId = userId;
            if (const(JSONValue)* v = "displayName" in f)
                state.displayName = v.str;
            if (const(JSONValue)* v = "status" in f)
                state.status = v.str;
            if (const(JSONValue)* v = "statusDescription" in f)
                state.statusDescription = v.str;
            string rawLoc;
            if (const(JSONValue)* v = "location" in f)
                rawLoc = v.str;
            state.location = rawLoc == "offline:offline" ? "offline" : rawLoc;
            if (const(JSONValue)* v = "platform" in f)
                state.platform = v.str;

            string loc = state.location;
            state.online = loc.length > 0 && loc != "offline" && loc != "";

            if (const(JSONValue)* v = "worldName" in f)
                state.worldName = v.str;

            result[userId] = state;
        }
        return result;
    }

    /// Seed the tracker from a list of friend JSON objects
    /// (as returned by GET /auth/user/friends).
    void seedFromAPI(JSONValue[] friendObjects)
    {
        FriendState[string] built = buildFriendMap(friendObjects);
        synchronized (friendsMutex)
        {
            friends = built;
            logInfo("Seeded friends tracker with %d friends", friends.length);
        }
    }

    /// Replace all friend state atomically. Used by the re-seed worker after
    /// a successful bulk fetch + repair pass.
    void replaceAll(FriendState[string] newFriends)
    {
        synchronized (friendsMutex)
        {
            friends = newFriends;
            logInfo("Replaced friends tracker with %d friends", friends.length);
        }
    }

    /// Process a VRCEvent and update friend state.
    /// Returns true if the friends state changed.
    bool processEvent(VRCEvent event)
    {
        synchronized (friendsMutex)
        {
            bool changed;
            switch (event.type)
            {
                case EventType.friendOnline:
                    changed = handleFriendOnline(event.content); break;
                case EventType.friendOffline:
                    changed = handleFriendOffline(event.content); break;
                case EventType.friendActive:
                    changed = handleFriendActive(event.content); break;
                case EventType.friendLocation:
                    changed = handleFriendLocation(event.content); break;
                case EventType.friendUpdate:
                    changed = handleFriendUpdate(event.content); break;
                case EventType.friendDelete:
                    changed = handleFriendDelete(event.content); break;
                case EventType.friendAdd:
                    changed = handleFriendAdd(event.content); break;
                default:
                    logTrace("processEvent: ignoring type=%s", event.typeRaw);
                    return false;
            }
            logDebugging("processEvent: type=%s changed=%s friends=%d",
                event.typeRaw, changed, friends.length);
            return changed;
        }
    }

    /// Build a JSON message with the full friends snapshot.
    JSONValue buildFriendsMessage()
    {
        synchronized (friendsMutex)
        {
            JSONValue[] instanceList;
            JSONValue[] offlineList;

            // Group online friends by location.
            JSONValue[][string] byLocation;
            string[string] locationWorldName; // location -> worldName

            foreach (ref FriendState f; friends)
            {
                JSONValue fObj = friendToJSON(f);

                if (f.online == false || f.location.length == 0 || f.location == "offline")
                {
                    offlineList ~= fObj;
                    continue;
                }

                byLocation[f.location] ~= fObj;
                if (f.worldName.length > 0)
                    locationWorldName[f.location] = f.worldName;
            }

            foreach (string loc, JSONValue[] friendObjs; byLocation)
            {
                string worldName = loc in locationWorldName ? locationWorldName[loc] : "";

                // Fallback: ask the WorldCache whether it already knows
                // this world's name. Pure lookup, no REST call.
                if (worldName.length == 0 && worldCache !is null)
                {
                    string worldId = WorldCache.extractWorldId(loc);
                    if (worldId.length > 0)
                        worldName = worldCache.tryGet(worldId);
                }

                JSONValue group = JSONValue([
                    "instance_id": JSONValue(loc),
                    "world_name": JSONValue(worldName),
                    "friends": JSONValue(friendObjs),
                ]);
                instanceList ~= group;
            }

            return JSONValue([
                "type": JSONValue("friends"),
                "instances": JSONValue(instanceList),
                "offline": JSONValue(offlineList),
            ]);
        }
    }

    /// Serialize a FriendState to JSON.
    static JSONValue friendToJSON(ref FriendState f)
    {
        return JSONValue([
            "id": JSONValue(f.userId),
            "displayName": JSONValue(f.displayName),
            "status": JSONValue(f.status),
            "statusDescription": JSONValue(f.statusDescription),
            "platform": JSONValue(f.platform),
            "location": JSONValue(f.location),
        ]);
    }

    /// Enrich an event's content with cached friend state.
    /// Call before processEvent so data is available before state changes.
    /// Adds displayName and platform from cached state if missing in content.
    void enrichContent(ref VRCEvent event)
    {
        string userId = extractUserId(event.content);
        if (userId.length == 0)
            return;

        string cachedDisplayName;
        string cachedPlatform;
        synchronized (friendsMutex)
        {
            FriendState* f = userId in friends;
            if (f is null)
            {
                logTrace("enrichContent: no cached friend for %s", userId);
                return;
            }
            cachedDisplayName = f.displayName;
            cachedPlatform = f.platform;
        }

        if ("displayName" !in event.content && cachedDisplayName.length > 0)
        {
            event.content["displayName"] = JSONValue(cachedDisplayName);
            logTrace("enrichContent: added displayName=%s for %s",
                cachedDisplayName, userId);
        }

        if ("platform" !in event.content && cachedPlatform.length > 0)
            event.content["platform"] = JSONValue(cachedPlatform);
    }

private:
    bool handleFriendOnline(JSONValue c)
    {
        string userId = extractUserId(c);
        if (userId.length == 0)
            return false;

        FriendState* f = getOrCreate(userId);
        f.online = true;
        f.displayName = extractDisplayName(c, f.displayName);
        if (const(JSONValue)* v = "platform" in c)
            f.platform = v.str;

        if (const(JSONValue)* v = "location" in c)
        {
            if (v.str.length > 0)
                f.location = v.str;
        }

        string worldName = extractWorldName(c);
        if (worldName.length > 0)
            f.worldName = worldName;

        return true;
    }

    bool handleFriendOffline(JSONValue c)
    {
        string userId = extractUserId(c);
        if (userId.length == 0)
            return false;

        FriendState* f = getOrCreate(userId);
        f.online = false;
        f.location = "offline";
        f.worldName = "";
        f.displayName = extractDisplayName(c, f.displayName);
        return true;
    }

    bool handleFriendActive(JSONValue c)
    {
        string userId = extractUserId(c);
        if (userId.length == 0)
            return false;

        FriendState* f = getOrCreate(userId);
        f.online = true;
        f.displayName = extractDisplayName(c, f.displayName);
        if (const(JSONValue)* v = "platform" in c)
            f.platform = v.str;
        // friend-active means on the website, no world location.
        f.location = "private";
        f.worldName = "";
        return true;
    }

    bool handleFriendLocation(JSONValue c)
    {
        string userId = extractUserId(c);
        if (userId.length == 0)
            return false;

        FriendState* f = getOrCreate(userId);
        f.displayName = extractDisplayName(c, f.displayName);

        string loc;
        if (const(JSONValue)* v = "location" in c)
            loc = v.str;
        if (loc.length > 0)
        {
            f.location = loc;
            f.online = (loc != "offline");
        }

        string worldName = extractWorldName(c);
        if (worldName.length > 0)
            f.worldName = worldName;
        else if (loc == "private")
            f.worldName = "";

        return true;
    }

    bool handleFriendUpdate(JSONValue c)
    {
        string userId = extractUserId(c);
        if (userId.length == 0)
            return false;

        FriendState* f = getOrCreate(userId);
        f.displayName = extractDisplayName(c, f.displayName);

        if (const(JSONValue)* v = "status" in c)
            if (v.str.length > 0)
                f.status = v.str;

        if (const(JSONValue)* v = "statusDescription" in c)
            if (v.str.length > 0)
                f.statusDescription = v.str;

        return true;
    }

    bool handleFriendDelete(JSONValue c)
    {
        string userId = extractUserId(c);
        if (userId.length == 0)
            return false;

        friends.remove(userId);
        return true;
    }

    bool handleFriendAdd(JSONValue c)
    {
        string userId = extractUserId(c);
        if (userId.length == 0)
            return false;

        FriendState* f = getOrCreate(userId);
        f.displayName = extractDisplayName(c, f.displayName);
        return true;
    }

    FriendState* getOrCreate(string userId)
    {
        if (userId !in friends)
            friends[userId] = FriendState(userId);
        return &friends[userId];
    }

    static string extractUserId(JSONValue c)
    {
        // Try top-level "userId" first, then nested "user.id".
        if (const(JSONValue)* v = "userId" in c)
            if (v.str.length > 0)
                return v.str;

        // Some events put the ID at the top level as "id".
        // But only if it looks like a user ID.
        if (const(JSONValue)* v = "id" in c)
            if (v.str.length > 4 && v.str[0 .. 4] == "usr_")
                return v.str;

        if (const(JSONValue)* v = "user" in c)
            if (v.type == JSONType.object)
                if (const(JSONValue)* uid = "id" in *v)
                    return uid.str;

        return "";
    }

    static string extractDisplayName(JSONValue c, string fallback)
    {
        if (const(JSONValue)* v = "displayName" in c)
            if (v.str.length > 0)
                return v.str;

        if (const(JSONValue)* v = "user" in c)
            if (v.type == JSONType.object)
                if (const(JSONValue)* dn = "displayName" in *v)
                    if (dn.str.length > 0)
                        return dn.str;

        return fallback;
    }

    static string extractWorldName(JSONValue c)
    {
        if (const(JSONValue)* v = "worldName" in c)
            if (v.str.length > 0)
                return v.str;

        if (const(JSONValue)* v = "world" in c)
            if (v.type == JSONType.object)
                if (const(JSONValue)* wn = "name" in *v)
                    return wn.str;

        return "";
    }
}
