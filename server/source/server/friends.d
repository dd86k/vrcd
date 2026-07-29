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
import server.userimage;
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
        string imageFileId;      // "file_..." of their profile picture, if any
        long imageVersion;       // Version of that file (1+)
        string bio;              // Long-form profile blurb (not statusDescription)
        string pronouns;         // User-set pronouns
        string[] bioLinks;       // URLs the user pinned on their profile
        bool online;             // Online in-game
    }

    private FriendState[string] friends; // keyed by userId
    private Mutex friendsMutex;
    private WorldCache worldCache;
    private InstanceCache instanceCache;
    private string selfUserId;           // also stored in `friends`, filtered from snapshots
    private VRCEvent[] pendingSynthetics; // derived events (e.g. avatar-change)
    private bool pendingSelfChange;       // self snapshot fields moved; broadcast a fresh `self`

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
    void setSelf(string userId, string displayName, string currentAvatar,
        string status, string statusDescription,
        string bio, string pronouns, string[] bioLinks,
        UserImage picture)
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
            if (status.length > 0)
                f.status = status;
            if (statusDescription.length > 0)
                f.statusDescription = statusDescription;
            if (bio.length > 0)
                f.bio = bio;
            if (pronouns.length > 0)
                f.pronouns = pronouns;
            if (bioLinks.length > 0)
                f.bioLinks = bioLinks;
            if (picture.fileId.length > 0)
            {
                f.imageFileId = picture.fileId;
                f.imageVersion = picture.fileVersion;
            }
        }
    }

    /// Return the logged-in user's id, or empty string if not set.
    string getSelfUserId()
    {
        synchronized (friendsMutex)
            return selfUserId;
    }

    /// Build a `self` snapshot for the currently logged-in user.
    /// Returns a null JSONValue if self has not been set yet.
    JSONValue buildSelfMessage()
    {
        synchronized (friendsMutex)
        {
            if (selfUserId.length == 0)
                return JSONValue(null);
            FriendState* f = selfUserId in friends;
            if (f is null)
                return JSONValue(null);
            return JSONValue([
                "type":              JSONValue("self"),
                "id":                JSONValue(f.userId),
                "displayName":       JSONValue(f.displayName),
                "status":            JSONValue(f.status),
                "statusDescription": JSONValue(f.statusDescription),
                "bio":               JSONValue(f.bio),
                "pronouns":          JSONValue(f.pronouns),
                "bioLinks":          JSONValue(f.bioLinks),
                "imageFileId":       JSONValue(f.imageFileId),
                "imageVersion":      JSONValue(f.imageVersion),
            ]);
        }
    }

    /// Apply a status / statusDescription change to the self entry. Used after
    /// a successful PUT users/{selfUserId} so subsequent self snapshots reflect
    /// the new values without waiting for the next user-update event. Pass
    /// false for the corresponding `set` flag to leave a field unchanged.
    void applySelfStatus(bool setStatus, string status, bool setDescription, string description)
    {
        synchronized (friendsMutex)
        {
            if (selfUserId.length == 0)
                return;
            FriendState* f = selfUserId in friends;
            if (f is null)
                return;
            if (setStatus)
                f.status = status;
            if (setDescription)
                f.statusDescription = description;
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

    /// Drain a queued "self snapshot changed" flag set when an incoming event
    /// (typically user-update from an in-game status edit) mutated one of the
    /// fields the client renders for self. Caller broadcasts a fresh `self`.
    bool takePendingSelfChange()
    {
        synchronized (friendsMutex)
        {
            bool r = pendingSelfChange;
            pendingSelfChange = false;
            return r;
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

            UserImage picture = pickUserImage(f);
            state.imageFileId = picture.fileId;
            state.imageVersion = picture.fileVersion;

            if (const(JSONValue)* v = "bio" in f)
                if (v.type == JSONType.string)
                    state.bio = v.str;
            if (const(JSONValue)* v = "pronouns" in f)
                if (v.type == JSONType.string)
                    state.pronouns = v.str;
            if (const(JSONValue)* v = "bioLinks" in f)
                if (v.type == JSONType.array)
                    state.bioLinks = jsonStringArray(*v);

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

            // A listing entry with no usable picture is the robot placeholder
            // or a legacy CloudFront URL, not a friend who lost their face:
            // keep the one we had rather than blinking every list back to
            // initials on each re-seed.
            foreach (string userId, ref FriendState replacement; newFriends)
            {
                if (replacement.imageFileId.length > 0)
                    continue;
                if (FriendState* old = userId in friends)
                {
                    replacement.imageFileId = old.imageFileId;
                    replacement.imageVersion = old.imageVersion;
                }
            }

            friends = newFriends;
            logInfo("Replaced friends tracker with %d friends", friends.length);
        }
    }

    /// Remove a friend eagerly after a successful unfriend REST call, so
    /// the follow-up snapshot doesn't wait on the friend-delete WS event.
    /// Returns true if the friend was present.
    bool removeFriend(string userId)
    {
        synchronized (friendsMutex)
        {
            if (userId in friends)
            {
                friends.remove(userId);
                return true;
            }
            return false;
        }
    }

    /// Last-seen display name for a tracked user, or empty string.
    string getDisplayName(string userId)
    {
        synchronized (friendsMutex)
        {
            if (FriendState* f = userId in friends)
                return f.displayName;
            return null;
        }
    }

    /// Process a VRCEvent and update friend state.
    /// Returns true if the *client-visible* state changed. Per-handler change
    /// flags are too eager (VRChat resends identical frames with slightly
    /// differing nested fields that bounce internal state without altering
    /// the snapshot clients receive). Authoritative diff: take a fingerprint
    /// of the affected friend before and after, compare.
    bool processEvent(VRCEvent event)
    {
        synchronized (friendsMutex)
        {
            string userId = extractUserId(event.content);
            VisibleState before = userId.length > 0 ? visibleStateOf(userId) : VisibleState.init;

            switch (event.type)
            {
                case EventType.friendOnline:   handleFriendOnline(event.content);   break;
                case EventType.friendOffline:  handleFriendOffline(event.content);  break;
                case EventType.friendActive:   handleFriendActive(event.content);   break;
                case EventType.friendLocation: handleFriendLocation(event.content); break;
                case EventType.friendUpdate:   handleFriendUpdate(event.content);   break;
                case EventType.friendDelete:   handleFriendDelete(event.content);   break;
                case EventType.friendAdd:      handleFriendAdd(event.content);      break;
                case EventType.userUpdate:     handleUserUpdate(event.content);     break;
                case EventType.userLocation:   handleUserLocation(event.content);   break;
                default:
                    logTrace("processEvent: ignoring type=%s", event.typeRaw);
                    return false;
            }

            VisibleState after = userId.length > 0 ? visibleStateOf(userId) : VisibleState.init;

            // Self never appears in the friends snapshot, but a change to its
            // status/description/bio/etc still needs to reach the client via a
            // fresh `self` push (e.g. user toggled status from the VRChat menu).
            if (userId.length > 0 && selfUserId.length > 0 && userId == selfUserId)
            {
                if (before != after)
                    pendingSelfChange = true;
                logDebugging("processEvent: type=%s self-update selfChanged=%s",
                    event.typeRaw, pendingSelfChange);
                return false;
            }

            bool changed = before != after;
            logDebugging("processEvent: type=%s changed=%s friends=%d",
                event.typeRaw, changed, friends.length);
            return changed;
        }
    }

    /// Fingerprint of the per-friend fields clients actually see in
    /// buildFriendsMessage. Used to gate broadcasts so that VRChat's
    /// repeated identical frames don't trigger redundant snapshots.
    private struct VisibleState
    {
        bool present;
        string displayName;
        string status;
        string statusDescription;
        string platform;
        string location;
        string worldName;
        string bio;
        string pronouns;
        string[] bioLinks;
        string imageFileId;
        long imageVersion;
        bool online;
    }

    private VisibleState visibleStateOf(string userId)
    {
        FriendState* f = userId in friends;
        if (f is null)
            return VisibleState.init;
        VisibleState v;
        v.present = true;
        v.displayName = f.displayName;
        v.status = f.status;
        v.statusDescription = f.statusDescription;
        v.platform = f.platform;
        v.location = canonicalLocation(f.location);
        v.worldName = f.worldName;
        v.bio = f.bio;
        v.pronouns = f.pronouns;
        v.bioLinks = f.bioLinks;
        v.imageFileId = f.imageFileId;
        v.imageVersion = f.imageVersion;
        v.online = f.online;
        return v;
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
            // canonical -> first-seen full location (with ~type(usr) and tags).
            // The InstanceCache hits /instances/{loc}, which only returns
            // accurate n_users when the access-type qualifier is present;
            // the canonical key alone yields capacity but n_users=0.
            string[string] locationFull;

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
                    if ((key in locationFull) is null)
                        locationFull[key] = f.location;
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

                string fullLoc = locationFull.get(loc, loc);

                JSONValue group = JSONValue([
                    "instance_id": JSONValue(loc),
                    "location":    JSONValue(fullLoc),
                    "world_name":  JSONValue(worldName),
                    "friends":     JSONValue(friendObjs),
                ]);

                // Attach instance occupancy if the cache has a fresh entry.
                // Pure lookup, no REST call. Key on the full location: the
                // canonical id lacks the access-type qualifier and VRChat
                // returns n_users=0 for those lookups.
                if (instanceCache)
                {
                    InstanceInfo info = instanceCache.tryGet(fullLoc);
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
            "bio": JSONValue(f.bio),
            "pronouns": JSONValue(f.pronouns),
            "bioLinks": JSONValue(f.bioLinks),
            "imageFileId": JSONValue(f.imageFileId),
            "imageVersion": JSONValue(f.imageVersion),
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

        bool changed;

        if (isMissingOrEmpty(event.content, "displayName") && cachedDisplayName.length > 0)
        {
            event.content["displayName"] = JSONValue(cachedDisplayName);
            changed = true;
            logTrace("enrichContent: added displayName=%s for %s",
                cachedDisplayName, userId);
        }

        if (isMissingOrEmpty(event.content, "platform") && cachedPlatform.length > 0)
        {
            event.content["platform"] = JSONValue(cachedPlatform);
            changed = true;
        }

        // Rebuild rawJson so storage reflects the enriched content; otherwise
        // catch-up replays the original wire payload and loses the displayName
        // for events like friend-offline that VRChat sends as userId-only.
        if (changed)
        {
            event.rawJson = JSONValue([
                "type":    JSONValue(event.typeRaw),
                "content": JSONValue(event.content.toString()),
            ]).toString();
        }
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
        if (applyProfileUpdate(f, c)) changed = true;
        if (applyPictureUpdate(f, c)) changed = true;
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
        if (applyProfileUpdate(f, c)) changed = true;
        if (applyPictureUpdate(f, c)) changed = true;
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
        // still in the same public instance. World transitions go through
        // "traveling", never a bare "private", so any "private" landing on
        // top of a cached wrld_ instance is treated as avatar-swap shadow:
        // skip the location/worldName overwrite. applyAvatarUpdate below
        // produces the synthetic when the new avatar id arrives (same frame
        // or a later one); the next genuine friend-update reaffirms the
        // instance.
        bool avatarSwapShadow =
            loc == "private"
            && f.location.length > 5
            && f.location[0 .. 5] == "wrld_";

        if (avatarSwapShadow)
        {
            logTrace("handleFriendLocation: avatar-swap shadow for %s "
                ~ "(keeping loc=%s)", f.userId, f.location);
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
        if (applyProfileUpdate(f, c)) changed = true;
        if (applyPictureUpdate(f, c)) changed = true;
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
        if (applyProfileUpdate(f, c)) changed = true;
        if (applyPictureUpdate(f, c)) changed = true;
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
        if (applyProfileUpdate(f, c)) changed = true;
        if (applyPictureUpdate(f, c)) changed = true;
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
        if (applyProfileUpdate(f, c)) changed = true;
        if (applyPictureUpdate(f, c)) changed = true;
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
    /// Suppressed when the friend's location isn't a concrete instance: a
    /// private/traveling/offline friend who swaps avatars has no observable
    /// moment for clients to render, and VRChat keeps emitting avatar id
    /// churn for these friends regardless.
    bool applyAvatarUpdate(FriendState* f, JSONValue c)
    {
        string newAvatar = extractCurrentAvatar(c);
        if (newAvatar.length == 0)
            return false;

        bool visibleInstance =
            f.location.length > 5 && f.location[0 .. 5] == "wrld_";

        bool changed = (f.currentAvatar != newAvatar);
        if (changed && f.currentAvatar && visibleInstance)
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

    /// Diff the incoming profile picture against cached state.
    ///
    /// No synthetic event: a friend swapping their profile picture is not a
    /// moment in a feed the way a world or avatar change is, it is just the
    /// face next to their name changing on the next snapshot.
    ///
    /// Only a frame offering a usable picture replaces the cached one. A frame
    /// with nothing usable in it is not a friend without a face: it is the
    /// robot placeholder VRChat serves while an avatar image is still being
    /// made, a legacy CloudFront URL that is not a file, or a stripped user
    /// object. Clearing on those would blank the face in every list and put it
    /// back a frame later. A friend who drops their profile picture still has
    /// their avatar, so the picture moves rather than disappearing.
    bool applyPictureUpdate(FriendState* f, JSONValue c)
    {
        UserImage picture;

        foreach (string field; userImageFields)
        {
            string url;
            if (extractProfileString(c, field, url) == false || url.length == 0)
                continue;

            picture = parseImageURL(url);
            if (picture.fileId.length > 0)
                break;
        }

        if (picture.fileId.length == 0)
            return false;
        if (picture.fileId == f.imageFileId && picture.fileVersion == f.imageVersion)
            return false;

        f.imageFileId = picture.fileId;
        f.imageVersion = picture.fileVersion;
        return true;
    }

    /// Diff incoming bio / pronouns / bioLinks against cached state and queue
    /// a synthetic profile-change when one or more of them transitions between
    /// two non-empty values (mirrors VRCX's Bio feed gating). First sighting
    /// of each subfield seeds silently; field-cleared transitions (non-empty
    /// to empty) also seed silently to avoid offline-purge noise. The
    /// synthetic is combined: edits to bio + pronouns in the same frame
    /// produce one event listing both.
    bool applyProfileUpdate(FriendState* f, JSONValue c)
    {
        bool stateChanged = false;
        string[string] changedScalars; // field name -> "previous" value

        string newBio;
        if (extractProfileString(c, "bio", newBio))
        {
            if (newBio != f.bio)
            {
                bool emit = f.bio.length > 0 && newBio.length > 0;
                if (emit)
                    changedScalars["bio"] = f.bio;
                f.bio = newBio;
                stateChanged = true;
            }
        }

        string newPronouns;
        if (extractProfileString(c, "pronouns", newPronouns))
        {
            if (newPronouns != f.pronouns)
            {
                bool emit = f.pronouns.length > 0 && newPronouns.length > 0;
                if (emit)
                    changedScalars["pronouns"] = f.pronouns;
                f.pronouns = newPronouns;
                stateChanged = true;
            }
        }

        string[] newBioLinks;
        bool bioLinksChangedAndEmit = false;
        string[] previousBioLinks;
        if (extractProfileBioLinks(c, newBioLinks))
        {
            if (bioLinksDiffer(f.bioLinks, newBioLinks))
            {
                bool emit = f.bioLinks.length > 0 && newBioLinks.length > 0;
                if (emit)
                {
                    bioLinksChangedAndEmit = true;
                    previousBioLinks = f.bioLinks;
                }
                f.bioLinks = newBioLinks;
                stateChanged = true;
            }
        }

        if (changedScalars.length == 0 && bioLinksChangedAndEmit == false)
            return stateChanged;

        JSONValue content = JSONValue([
            "userId":      JSONValue(f.userId),
            "displayName": JSONValue(f.displayName),
            "isSelf":      JSONValue(f.userId == selfUserId),
        ]);

        if (auto prev = "bio" in changedScalars)
        {
            content["previousBio"] = JSONValue(*prev);
            content["currentBio"] = JSONValue(f.bio);
        }
        if (auto prev = "pronouns" in changedScalars)
        {
            content["previousPronouns"] = JSONValue(*prev);
            content["currentPronouns"] = JSONValue(f.pronouns);
        }
        if (bioLinksChangedAndEmit)
        {
            content["previousBioLinks"] = JSONValue(previousBioLinks);
            content["currentBioLinks"] = JSONValue(f.bioLinks);
        }

        VRCEvent syn = VRCEvent(
            EventType.profileChange,
            "profile-change",
            content,
            Clock.currTime(),
            JSONValue([
                "type":    JSONValue("profile-change"),
                "content": JSONValue(content.toString()),
            ]).toString()
        );

        pendingSynthetics ~= syn;
        logTrace("applyProfileUpdate: queued profile-change for %s "
            ~ "(scalars=%d bioLinks=%s)",
            f.userId, changedScalars.length, bioLinksChangedAndEmit);

        return stateChanged;
    }

    // VRChat sometimes sends fields as "" rather than omitting them
    // (e.g. friend-offline carries "platform":""). Treat both as absent
    // so enrichContent can fill from cache.
    static bool isMissingOrEmpty(JSONValue c, string key)
    {
        const(JSONValue)* v = key in c;
        if (v is null)
            return true;
        if (v.type == JSONType.string && v.str.length == 0)
            return true;
        return false;
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

    /// Read a profile string (e.g. bio, pronouns) from event content. Profile
    /// fields can appear top-level (user-update payload variants) or nested
    /// under "user" (friend-* events). Returns true when the field is present;
    /// the empty string is a valid value (means "user cleared it").
    static bool extractProfileString(JSONValue c, string field, out string value)
    {
        if (const(JSONValue)* v = field in c)
            if (v.type == JSONType.string)
            {
                value = v.str;
                return true;
            }
        if (const(JSONValue)* u = "user" in c)
            if (u.type == JSONType.object)
                if (const(JSONValue)* v = field in *u)
                    if (v.type == JSONType.string)
                    {
                        value = v.str;
                        return true;
                    }
        return false;
    }

    /// Read bioLinks (an array of URL strings) from event content. Same
    /// top-level / nested-under-"user" search as extractProfileString.
    static bool extractProfileBioLinks(JSONValue c, out string[] value)
    {
        if (const(JSONValue)* v = "bioLinks" in c)
            if (v.type == JSONType.array)
            {
                value = jsonStringArray(*v);
                return true;
            }
        if (const(JSONValue)* u = "user" in c)
            if (u.type == JSONType.object)
                if (const(JSONValue)* v = "bioLinks" in *u)
                    if (v.type == JSONType.array)
                    {
                        value = jsonStringArray(*v);
                        return true;
                    }
        return false;
    }

    static string[] jsonStringArray(JSONValue arr)
    {
        string[] result;
        foreach (ref JSONValue item; arr.array)
            if (item.type == JSONType.string)
                result ~= item.str;
        return result;
    }

    static bool bioLinksDiffer(const(string)[] a, const(string)[] b)
    {
        if (a.length != b.length)
            return true;
        foreach (i, ref s; a)
            if (s != b[i])
                return true;
        return false;
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
    // -> real transitions as two avatar swaps. Matched by file ID (from
    // server.userimage) since the host portion varies between endpoints.
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
