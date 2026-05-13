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
import server.instancecache;
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
        bool online;             // Online in-game
    }

    private FriendState[string] friends; // keyed by userId
    private Mutex friendsMutex;
    private WorldCache worldCache;
    private InstanceCache instanceCache;
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

    /// Provide an InstanceCache for cache-only instance occupancy in snapshots.
    void setInstanceCache(InstanceCache ic)
    {
        instanceCache = ic;
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
            // A web-platform friend with a non-offline status is active on
            // the website even when location is empty (the API omits it).
            bool activeOnWeb = state.platform == "web" && state.status != "offline";
            state.online = (loc && loc != "offline") || activeOnWeb;
            if (activeOnWeb && state.location.length == 0)
                state.location = "private";

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
            f.platform = null;
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
            // Use the canonical instance ID (everything before the first '~') as
            // the grouping key so friends in the same physical instance are never
            // split into two groups due to differing nonces or tag orderings that
            // can appear between REST-seed data and live WebSocket events.
            JSONValue[][string] byLocation;
            string[string] locationWorldName; // canonical location -> worldName

            foreach (ref FriendState f; friends)
            {
                // Don't list self among friends.
                if (selfUserId && f.userId == selfUserId)
                    continue;

                JSONValue fObj = friendToJSON(f);

                if (f.online == false || f.status == "offline"
                    || f.location is null || f.location == "offline")
                {
                    offlineList ~= fObj;
                    continue;
                }

                if (f.location)
                {
                    string key = canonicalLocation(f.location);
                    byLocation[key] ~= fObj;
                    if (f.worldName)
                        locationWorldName[key] = f.worldName;
                }
            }

            foreach (string loc, JSONValue[] friendObjs; byLocation)
            {
                string worldName = void;
                if (const(string) *l = loc in locationWorldName)
                    worldName = *l;
                else
                    worldName = null;

                // Fallback: ask the WorldCache whether it already knows
                // this world's name. Pure lookup, no REST call.
                if (worldName is null && worldCache)
                {
                    string worldId = WorldCache.extractWorldId(loc);
                    if (worldId)
                    {
                        string cachedName = worldCache.tryGet(worldId);
                        if (cachedName) worldName = cachedName;
                    }
                }

                JSONValue group = JSONValue([
                    "instance_id": JSONValue(loc),
                    "world_name": JSONValue(worldName),
                    "friends": JSONValue(friendObjs),
                ]);

                // Attach instance occupancy if the cache has a fresh entry.
                // Pure lookup, no REST call.
                if (instanceCache)
                {
                    InstanceInfo info = instanceCache.tryGet(loc);
                    if (info.known)
                    {
                        group["n_users"] = JSONValue(info.nUsers);
                        group["capacity"] = JSONValue(info.capacity);
                    }
                }

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
        if (userId is null)
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
    // Notified of a friend coming Online to a world
    bool handleFriendOnline(JSONValue c)
    {
        string userId = extractUserId(c);
        if (userId is null)
            return false;

        FriendState* f = getOrCreate(userId);
        bool changed = false;

        // Online means online: in-game
        if (f.online == false) { f.online = true; changed = true; }

        string dn = extractDisplayName(c, f.displayName);
        if (dn != f.displayName)
        {
            f.displayName = dn;
            changed = true;
        }

        if (const(JSONValue)* v = "platform" in c)
        {
            // NOTE: When string is empty (can happen), do not bother checking
            if (v.str.length > 0 && v.str != f.platform)
            {
                f.platform = v.str;
                changed = true;
            }
        }

        string newStatus = extractNestedUserString(c, "status");
        if (newStatus && newStatus != f.status)
        {
            f.status = newStatus;
            changed = true;
        }

        string newStatusDesc = extractNestedUserString(c, "statusDescription");
        if (newStatusDesc && newStatusDesc != f.statusDescription)
        {
            f.statusDescription = newStatusDesc;
            changed = true;
        }

        if (const(JSONValue)* v = "location" in c)
        {
            if (v.str.length > 0 && v.str != f.location)
            {
                f.location = v.str;
                changed = true;
            }
        }

        string worldName = extractWorldName(c);
        if (worldName && worldName != f.worldName)
        {
            f.worldName = worldName;
            changed = true;
        }

        if (applyAvatarUpdate(f, c)) changed = true;
        return changed;
    }

    bool handleFriendOffline(JSONValue c)
    {
        string userId = extractUserId(c);
        if (userId is null)
            return false;

        FriendState* f = getOrCreate(userId);
        bool changed = false;

        if (f.online) { f.online = false; changed = true; }
        if (f.status != "offline") { f.status = "offline"; changed = true; }
        if (f.location != "offline") { f.location = "offline"; changed = true; }
        if (f.worldName) { f.worldName = null; changed = true; }

        string dn = extractDisplayName(c, f.displayName);
        if (dn != f.displayName) { f.displayName = dn; changed = true; }

        string oldPlat = f.platform;
        normalizeOfflinePlatform(*f);
        if (f.platform != oldPlat) changed = true;

        return changed;
    }

    bool handleFriendActive(JSONValue c)
    {
        string userId = extractUserId(c);
        if (userId is null)
            return false;

        FriendState* f = getOrCreate(userId);
        bool changed = false;

        if (f.online == false) { f.online = true; changed = true; }

        string dn = extractDisplayName(c, f.displayName);
        if (dn != f.displayName)
        {
            f.displayName = dn;
            changed = true;
        }

        if (const(JSONValue)* v = "platform" in c)
        {
            if (v.str.length > 0 && v.str != f.platform)
            {
                f.platform = v.str;
                changed = true;
            }
        }

        string newStatus = extractNestedUserString(c, "status");
        if (newStatus && newStatus != f.status)
        {
            f.status = newStatus;
            changed = true;
        }

        string newStatusDesc = extractNestedUserString(c, "statusDescription");
        if (newStatusDesc && newStatusDesc != f.statusDescription)
        {
            f.statusDescription = newStatusDesc;
            changed = true;
        }

        if (f.location != "private")
        {
            f.location = "private";
            changed = true;
        }
        if (f.worldName)
        {
            f.worldName = null;
            changed = true;
        }

        if (applyAvatarUpdate(f, c)) changed = true;
        return changed;
    }

    bool handleFriendLocation(JSONValue c)
    {
        string userId = extractUserId(c);
        if (userId is null)
            return false;

        FriendState* f = getOrCreate(userId);
        bool changed = false;

        string dn = extractDisplayName(c, f.displayName);
        if (dn != f.displayName)
        {
            f.displayName = dn;
            changed = true;
        }

        string newStatus = extractNestedUserString(c, "status");
        if (newStatus && newStatus != f.status)
        {
            f.status = newStatus;
            changed = true;
        }

        string newStatusDesc = extractNestedUserString(c, "statusDescription");
        if (newStatusDesc && newStatusDesc != f.statusDescription)
        {
            f.statusDescription = newStatusDesc;
            changed = true;
        }

        string loc;
        if (const(JSONValue)* v = "location" in c)
            loc = v.str;

        // VRChat emits a friend-location with location="private" as a
        // side-effect of the friend swapping avatars, even when the friend is
        // still in the same public instance. Detect by: a real instance was
        // cached, the new loc is "private", and the avatar id in this event
        // differs from what we had. In that case skip the location/worldName
        // overwrite. The synthetic avatar-change below carries the real
        // signal, and the next genuine friend-update will reaffirm the
        // instance.
        string newAvatar = extractCurrentAvatar(c);
        bool avatarSwapShadow =
            loc == "private"
            && newAvatar.length > 0
            && f.currentAvatar.length > 0
            && newAvatar != f.currentAvatar
            && f.location.length > 5
            && f.location[0 .. 5] == "wrld_";

        if (avatarSwapShadow)
        {
            logTrace("handleFriendLocation: avatar-swap shadow for %s "
                ~ "(keeping loc=%s, avatar %s -> %s)",
                f.userId, f.location, f.currentAvatar, newAvatar);
        }
        else
        {
            if (loc != f.location)
            {
                f.location = loc;
                f.online = (loc != "offline");
                changed = true;
            }

            string worldName = extractWorldName(c);
            if (worldName && worldName != f.worldName)
            {
                f.worldName = worldName;
                changed = true;
            }
            else if (f.worldName && (loc == "private" || loc == "traveling"))
            {
                f.worldName = null;
                changed = true;
            }
        }

        if (applyAvatarUpdate(f, c)) changed = true;
        return changed;
    }

    bool handleFriendUpdate(JSONValue c)
    {
        string userId = extractUserId(c);
        if (userId is null)
            return false;

        FriendState* f = getOrCreate(userId);
        bool changed = false;

        string dn = extractDisplayName(c, f.displayName);
        if (dn != f.displayName) { f.displayName = dn; changed = true; }

        if (const(JSONValue)* v = "status" in c)
        {
            if (v.str.length > 0 && v.str != f.status)
            {
                f.status = v.str;
                changed = true;
            }
        }

        if (const(JSONValue)* v = "statusDescription" in c)
        {
            if (v.str.length > 0 && v.str != f.statusDescription)
            {
                f.statusDescription = v.str;
                changed = true;
            }
        }

        if (applyAvatarUpdate(f, c)) changed = true;
        return changed;
    }

    bool handleUserUpdate(JSONValue c)
    {
        string userId = extractUserId(c);
        if (userId is null)
            return false;

        FriendState* f = getOrCreate(userId);
        bool changed = false;

        string dn = extractDisplayName(c, f.displayName);
        if (dn != f.displayName) { f.displayName = dn; changed = true; }

        if (const(JSONValue)* u = "user" in c)
        {
            if (u.type == JSONType.object)
            {
                if (const(JSONValue)* v = "status" in *u)
                {
                    if (v.type == JSONType.string && v.str.length > 0 && v.str != f.status)
                    {
                        f.status = v.str;
                        changed = true;
                    }
                }
                if (const(JSONValue)* v = "statusDescription" in *u)
                {
                    if (v.type == JSONType.string && v.str != f.statusDescription)
                    {
                        f.statusDescription = v.str;
                        changed = true;
                    }
                }
            }
        }

        if (applyAvatarUpdate(f, c)) changed = true;
        // Self is filtered out of buildFriendsMessage, so no snapshot push.
        return false;
    }

    bool handleUserLocation(JSONValue c)
    {
        string userId = extractUserId(c);
        if (userId is null)
            return false;

        FriendState* f = getOrCreate(userId);
        bool changed = false;

        string dn = extractDisplayName(c, f.displayName);
        if (dn != f.displayName) { f.displayName = dn; changed = true; }

        if (const(JSONValue)* v = "location" in c)
        {
            if (v.str.length > 0 && v.str != f.location)
            {
                f.location = v.str;
                changed = true;
            }
        }

        string worldName = extractWorldName(c);
        if (worldName && worldName != f.worldName)
        {
            f.worldName = worldName;
            changed = true;
        }

        if (applyAvatarUpdate(f, c)) changed = true;
        // Self is filtered out of buildFriendsMessage, so no snapshot push.
        return false;
    }

    bool handleFriendDelete(JSONValue c)
    {
        string userId = extractUserId(c);
        if (userId is null)
            return false;

        if (userId in friends)
        {
            friends.remove(userId);
            return true;
        }
        return false;
    }

    bool handleFriendAdd(JSONValue c)
    {
        string userId = extractUserId(c);
        if (userId is null)
            return false;

        if (userId !in friends)
        {
            FriendState* f = getOrCreate(userId);
            f.displayName = extractDisplayName(c, f.displayName);
            return true;
        }

        // Friend already exists, just update displayName.
        FriendState* f = getOrCreate(userId);
        string dn = extractDisplayName(c, f.displayName);
        if (dn != f.displayName)
        {
            f.displayName = dn;
            return true;
        }
        return false;
    }

    FriendState* getOrCreate(string userId)
    {
        if (userId !in friends)
            friends[userId] = FriendState(userId);
        return &friends[userId];
    }

    /// Diff an incoming avatar id against cached state. First sighting seeds
    /// silently; subsequent changes queue a synthetic avatar-change event.
    bool applyAvatarUpdate(FriendState* f, JSONValue c)
    {
        string newAvatar = extractCurrentAvatar(c);
        if (newAvatar.length == 0)
            return false;

        bool changed = (f.currentAvatar != newAvatar);
        if (changed && f.currentAvatar)
        {
            JSONValue content = JSONValue([
                "userId":         JSONValue(f.userId),
                "displayName":    JSONValue(f.displayName),
                "previousAvatar": JSONValue(f.currentAvatar),
                "currentAvatar":  JSONValue(newAvatar),
                "isSelf":         JSONValue(f.userId == selfUserId),
            ]);

            VRCEvent syn = VRCEvent(
                EventType.avatarChange,
                "avatar-change",
                content,
                Clock.currTime(),
                // Synthesized: no real WebSocket frame, so build a canonical
                // envelope.
                JSONValue([
                    "type":    JSONValue("avatar-change"),
                    "content": JSONValue(content.toString()),
                ]).toString()
            );

            pendingSynthetics ~= syn;
            logTrace("applyAvatarUpdate: queued avatar-change for %s (%s -> %s)",
                f.userId, f.currentAvatar, newAvatar);
        }

        f.currentAvatar = newAvatar;
        return changed;
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

        return null;
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

        return null;
    }

    /// Read a nested user field from event content as a string.
    /// friend-online/active/location carry the full User object under
    /// "user", so status/statusDescription live at content.user.<field>.
    static string extractNestedUserString(JSONValue c, string field)
    {
        if (const(JSONValue)* v = "user" in c)
            if (v.type == JSONType.object)
                if (const(JSONValue)* f = field in *v)
                    if (f.type == JSONType.string)
                        return f.str;
        return null;
    }

    /// Strip per-user location modifiers (nonce, region tags, etc.) to get
    /// the canonical instance ID: "wrld_xxx:NNNNN". Two friends in the same
    /// physical instance must share this prefix even if their full location
    /// strings differ (e.g. different ~nonce values from separate invites, or
    /// a difference between REST-seed data and live WebSocket event format).
    static string canonicalLocation(string location)
    {
        import std.string : indexOf;
        // "private", "traveling", "offline" have no '~'; return as-is.
        if (location.length < 5 || location[0 .. 5] != "wrld_")
            return location;
        ptrdiff_t tilde = location.indexOf('~');
        return tilde > 0 ? location[0 .. tilde] : location;
    }

    // VRChat's "robot" placeholder image, served while the real avatar
    // image is still loading. Treat it as absent so we don't see real -> robot
    // -> real transitions as two avatar swaps. Matched by file ID since the
    // host portion varies between endpoints (cf. VRCX src/stores/user.js).
    enum string robotAvatarFileId = "file_0e8c4e32-7444-44ea-ade4-313c010d4bae";

    static bool isRobotAvatar(string s)
    {
        import std.string : indexOf;
        return s.indexOf(robotAvatarFileId) >= 0;
    }

    static string extractCurrentAvatar(JSONValue c)
    {
        // Top-level avatar ID (self user-update events send this)
        if (const(JSONValue)* v = "currentAvatar" in c)
            if (v.type == JSONType.string && v.str.length > 0)
                return v.str;

        // Top-level image URL fallback
        if (const(JSONValue)* v = "currentAvatarImageUrl" in c)
            if (v.type == JSONType.string && v.str.length > 0 && isRobotAvatar(v.str) == false)
                return v.str;

        // Nested under "user" sub-object. Friend events (friend-update,
        // friend-location, friend-online, etc.) carry the full User object
        // here. VRChat omits the avatar ID for friends but includes
        // currentAvatarImageUrl, so we check both.
        if (const(JSONValue)* v = "user" in c)
        {
            if (v.type == JSONType.object)
            {
                if (const(JSONValue)* ca = "currentAvatar" in *v)
                    if (ca.type == JSONType.string && ca.str.length > 0)
                        return ca.str;
                if (const(JSONValue)* ca = "currentAvatarImageUrl" in *v)
                    if (ca.type == JSONType.string && ca.str.length > 0 && isRobotAvatar(ca.str) == false)
                        return ca.str;
            }
        }

        return null;
    }
}
