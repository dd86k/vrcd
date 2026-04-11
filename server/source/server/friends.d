/// Friends tracker
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.friends;

import core.sync.mutex : Mutex;

import std.datetime.systime : Clock;
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
        string currentAvatar;    // "avtr_..." of currently-equipped avatar
        bool online;
    }

    private FriendState[string] friends; // keyed by userId
    private Mutex friendsMutex;
    private WorldCache worldCache;
    private string selfUserId;           // also stored in `friends`, filtered from snapshots
    private VRCEvent[] pendingSynthetics; // derived events (e.g. avatar-change)

    this()
    {
        friendsMutex = new Mutex();
    }

    /// Provide a WorldCache for cache-only world-name fallback in snapshots.
    void setWorldCache(WorldCache wc)
    {
        worldCache = wc;
    }

    /// Register the logged-in user as a tracked entry. The self entry lives
    /// in the same map as friends so user-update/user-location events go
    /// through the same avatar-diff logic, but buildFriendsMessage filters
    /// it out so clients never see themselves in the friends list.
    void setSelf(string userId, string displayName, string currentAvatar)
    {
        if (userId.length == 0)
            return;
        synchronized (friendsMutex)
        {
            this.selfUserId = userId;
            FriendState* f = getOrCreate(userId);
            if (displayName.length > 0)
                f.displayName = displayName;
            if (currentAvatar.length > 0)
                f.currentAvatar = currentAvatar;
        }
    }

    /// Drain any synthesized events the tracker has queued (e.g. avatar
    /// changes derived from user-update/friend-update diffs). Caller is
    /// responsible for storing, logging and broadcasting them.
    VRCEvent[] takePendingSynthetics()
    {
        synchronized (friendsMutex)
        {
            VRCEvent[] result = pendingSynthetics;
            pendingSynthetics = null;
            return result;
        }
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

            if (const(JSONValue)* v = "currentAvatar" in f)
                if (v.type == JSONType.string)
                    state.currentAvatar = v.str;

            normalizeOfflinePlatform(state);
            result[userId] = state;
        }
        return result;
    }

    /// An offline friend must not carry a stale game platform. "web" is the
    /// one platform valid on an offline-in-game friend (they're web-active).
    /// Anything else gets cleared so the client doesn't render "Offline - PC".
    static void normalizeOfflinePlatform(ref FriendState f)
    {
        if (f.status != "offline" && f.online)
            return;
        if (f.platform != "web")
            f.platform = "";
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
    /// a successful bulk fetch + repair pass. Preserves the self entry,
    /// which buildFriendMap does not include.
    void replaceAll(FriendState[string] newFriends)
    {
        synchronized (friendsMutex)
        {
            if (selfUserId.length > 0)
                if (FriendState* self = selfUserId in friends)
                    newFriends[selfUserId] = *self;
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
                case EventType.userUpdate:
                    changed = handleUserUpdate(event.content); break;
                case EventType.userLocation:
                    changed = handleUserLocation(event.content); break;
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
                // Don't list self among friends.
                if (selfUserId.length > 0 && f.userId == selfUserId)
                    continue;

                JSONValue fObj = friendToJSON(f);

                if (f.online == false || f.status == "offline"
                    || f.location.length == 0 || f.location == "offline")
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

        applyAvatarUpdate(f, c);
        return true;
    }

    bool handleFriendOffline(JSONValue c)
    {
        string userId = extractUserId(c);
        if (userId.length == 0)
            return false;

        FriendState* f = getOrCreate(userId);
        f.online = false;
        f.status = "offline";
        f.location = "offline";
        f.worldName = "";
        f.displayName = extractDisplayName(c, f.displayName);
        normalizeOfflinePlatform(*f);
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
        applyAvatarUpdate(f, c);
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

        applyAvatarUpdate(f, c);
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

        applyAvatarUpdate(f, c);
        return true;
    }

    bool handleUserUpdate(JSONValue c)
    {
        string userId = extractUserId(c);
        if (userId.length == 0)
            return false;

        FriendState* f = getOrCreate(userId);
        f.displayName = extractDisplayName(c, f.displayName);

        // user-update nests fields under "user".
        if (const(JSONValue)* u = "user" in c)
        {
            if (u.type == JSONType.object)
            {
                if (const(JSONValue)* v = "status" in *u)
                    if (v.type == JSONType.string && v.str.length > 0)
                        f.status = v.str;
                if (const(JSONValue)* v = "statusDescription" in *u)
                    if (v.type == JSONType.string)
                        f.statusDescription = v.str;
            }
        }

        applyAvatarUpdate(f, c);
        // Self is filtered out of buildFriendsMessage, so no snapshot push.
        return false;
    }

    bool handleUserLocation(JSONValue c)
    {
        string userId = extractUserId(c);
        if (userId.length == 0)
            return false;

        FriendState* f = getOrCreate(userId);
        f.displayName = extractDisplayName(c, f.displayName);

        if (const(JSONValue)* v = "location" in c)
            if (v.str.length > 0)
                f.location = v.str;

        string worldName = extractWorldName(c);
        if (worldName.length > 0)
            f.worldName = worldName;

        applyAvatarUpdate(f, c);
        // Self is filtered out of buildFriendsMessage, so no snapshot push.
        return false;
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

    /// Diff an incoming avatar id against cached state. First sighting seeds
    /// silently; subsequent changes queue a synthetic avatar-change event.
    void applyAvatarUpdate(FriendState* f, JSONValue c)
    {
        string newAvatar = extractCurrentAvatar(c);
        if (newAvatar.length == 0)
            return;

        if (f.currentAvatar.length > 0 && f.currentAvatar != newAvatar)
        {
            JSONValue content = JSONValue([
                "userId":         JSONValue(f.userId),
                "displayName":    JSONValue(f.displayName),
                "previousAvatar": JSONValue(f.currentAvatar),
                "currentAvatar":  JSONValue(newAvatar),
                "isSelf":         JSONValue(f.userId == selfUserId),
            ]);

            VRCEvent syn;
            syn.type = EventType.avatarChange;
            syn.typeRaw = "avatar-change";
            syn.content = content;
            syn.receivedAt = Clock.currTime();
            // Synthesized: no real WebSocket frame, so build a canonical
            // envelope so the stored raw_json stays consistent.
            syn.rawJson = JSONValue([
                "type":    JSONValue("avatar-change"),
                "content": JSONValue(content.toString()),
            ]).toString();

            pendingSynthetics ~= syn;
            logTrace("applyAvatarUpdate: queued avatar-change for %s (%s -> %s)",
                f.userId, f.currentAvatar, newAvatar);
        }

        f.currentAvatar = newAvatar;
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

    static string extractCurrentAvatar(JSONValue c)
    {
        if (const(JSONValue)* v = "currentAvatar" in c)
            if (v.type == JSONType.string && v.str.length > 0)
                return v.str;

        if (const(JSONValue)* v = "user" in c)
            if (v.type == JSONType.object)
                if (const(JSONValue)* ca = "currentAvatar" in *v)
                    if (ca.type == JSONType.string && ca.str.length > 0)
                        return ca.str;

        return "";
    }
}
