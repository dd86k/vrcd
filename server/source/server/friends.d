/// Friends tracker
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.friends;

import std.json;

import ddlogger;

import server.events;

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

    /// Seed the tracker from a list of friend JSON objects
    /// (as returned by GET /auth/user/friends).
    void seedFromAPI(JSONValue[] friendObjects)
    {
        foreach (ref JSONValue f; friendObjects)
        {
            string userId = jsonStr(f, "id");
            if (userId.length == 0)
                continue;

            FriendState state;
            state.userId = userId;
            state.displayName = jsonStr(f, "displayName");
            state.status = jsonStr(f, "status");
            state.statusDescription = jsonStr(f, "statusDescription");
            state.location = jsonStr(f, "location");
            state.platform = jsonStr(f, "platform");

            // Determine online state from location/status.
            string loc = state.location;
            state.online = loc.length > 0 && loc != "offline" && loc != "";

            // Extract world name if the API included it (it usually doesn't
            // in the friends list, but location is enough for grouping).
            state.worldName = jsonStr(f, "worldName");

            friends[userId] = state;
        }

        logInfo("Seeded friends tracker with %d friends", friends.length);
    }

    /// Process a VRCEvent and update friend state.
    /// Returns true if the friends state changed.
    bool processEvent(VRCEvent event)
    {
        switch (event.type)
        {
            case EventType.friendOnline:
                return handleFriendOnline(event.content);
            case EventType.friendOffline:
                return handleFriendOffline(event.content);
            case EventType.friendActive:
                return handleFriendActive(event.content);
            case EventType.friendLocation:
                return handleFriendLocation(event.content);
            case EventType.friendUpdate:
                return handleFriendUpdate(event.content);
            case EventType.friendDelete:
                return handleFriendDelete(event.content);
            case EventType.friendAdd:
                return handleFriendAdd(event.content);
            default:
                return false;
        }
    }

    /// Build a JSON message with the full friends snapshot.
    JSONValue buildFriendsMessage()
    {
        JSONValue[] instanceList;
        JSONValue[] offlineList;

        // Group online friends by location.
        JSONValue[][string] byLocation;
        string[string] locationWorldName; // location -> worldName

        foreach (ref FriendState f; friends)
        {
            JSONValue fObj = friendToJSON(f);

            if (!f.online || f.location.length == 0 || f.location == "offline")
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

        FriendState* f = userId in friends;
        if (f is null)
            return;

        // Add displayName if missing.
        if (jsonStr(event.content, "displayName").length == 0 && f.displayName.length > 0)
            event.content["displayName"] = JSONValue(f.displayName);

        // Add platform if missing.
        if (jsonStr(event.content, "platform").length == 0 && f.platform.length > 0)
            event.content["platform"] = JSONValue(f.platform);
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
        f.platform = jsonStr(c, "platform");

        string loc = jsonStr(c, "location");
        if (loc.length > 0)
            f.location = loc;

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
        f.platform = jsonStr(c, "platform");
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

        string loc = jsonStr(c, "location");
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

        string status = jsonStr(c, "status");
        if (status.length > 0)
            f.status = status;

        string statusDesc = jsonStr(c, "statusDescription");
        if (statusDesc.length > 0)
            f.statusDescription = statusDesc;

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
        string id = jsonStr(c, "userId");
        if (id.length > 0)
            return id;

        // Some events put the ID at the top level as "id".
        // But only if it looks like a user ID.
        id = jsonStr(c, "id");
        if (id.length > 4 && id[0 .. 4] == "usr_")
            return id;

        if ("user" in c && c["user"].type == JSONType.object)
            return jsonStr(c["user"], "id");

        return "";
    }

    static string extractDisplayName(JSONValue c, string fallback)
    {
        string name = jsonStr(c, "displayName");
        if (name.length > 0)
            return name;

        if ("user" in c && c["user"].type == JSONType.object)
        {
            name = jsonStr(c["user"], "displayName");
            if (name.length > 0)
                return name;
        }

        return fallback;
    }

    static string extractWorldName(JSONValue c)
    {
        string name = jsonStr(c, "worldName");
        if (name.length > 0)
            return name;

        if ("world" in c && c["world"].type == JSONType.object)
            return jsonStr(c["world"], "name");

        return "";
    }
}

private string jsonStr(JSONValue json, string key)
{
    if (key in json && json[key].type == JSONType.string)
        return json[key].str;
    return "";
}
