/// Player moderations tracker (mutes and blocks)
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.moderations;

import core.sync.mutex;

import std.json;

/// Tracks the logged-in user's player moderations (mutes and blocks).
///
/// Player moderations are not limited to friends, so this is its own store
/// keyed by user id rather than part of FriendsTracker. VRChat has no
/// WebSocket events for player moderations, so the store is refreshed from
/// the REST API on every client `get_moderations` and updated locally after
/// our own successful mutations.
class ModerationsTracker
{
    private string[string] muted;   // userId -> displayName
    private string[string] blocked; // userId -> displayName
    private Mutex mtx;

    this()
    {
        mtx = new Mutex();
    }

    /// Replace both lists from GET /auth/user/playermoderations entries.
    /// Moderation types other than "mute"/"block" (e.g. interactOff) are
    /// ignored until the client grows UI for them.
    void replaceFromAPI(JSONValue[] entries)
    {
        string[string] newMuted;
        string[string] newBlocked;

        foreach (ref JSONValue e; entries)
        {
            string modType;
            if (const(JSONValue)* v = "type" in e)
                if (v.type == JSONType.string)
                    modType = v.str;

            string target;
            if (const(JSONValue)* v = "targetUserId" in e)
                if (v.type == JSONType.string)
                    target = v.str;

            string name;
            if (const(JSONValue)* v = "targetDisplayName" in e)
                if (v.type == JSONType.string)
                    name = v.str;

            if (target.length == 0)
                continue;

            switch (modType)
            {
                case "mute":  newMuted[target] = name; break;
                case "block": newBlocked[target] = name; break;
                default:
            }
        }

        synchronized (mtx)
        {
            muted = newMuted;
            blocked = newBlocked;
        }
    }

    /// Record a successful mutation of ours so the next snapshot reflects
    /// it without a refetch.
    void apply(string action, string userId, string displayName)
    {
        synchronized (mtx)
        {
            switch (action)
            {
                case "mute":    muted[userId] = displayName; break;
                case "unmute":  muted.remove(userId); break;
                case "block":   blocked[userId] = displayName; break;
                case "unblock": blocked.remove(userId); break;
                default:
            }
        }
    }

    /// Last-seen display name for a moderated user, or empty string.
    string getDisplayName(string userId)
    {
        synchronized (mtx)
        {
            if (string* name = userId in muted)
                return *name;
            if (string* name = userId in blocked)
                return *name;
            return null;
        }
    }

    /// Build the `moderations` snapshot message.
    JSONValue buildModerationsMessage()
    {
        static JSONValue entryToJSON(string userId, string displayName)
        {
            return JSONValue([
                "user_id": JSONValue(userId),
                "display_name": JSONValue(displayName),
            ]);
        }

        synchronized (mtx)
        {
            JSONValue[] mutedArr;
            foreach (userId, displayName; muted)
                mutedArr ~= entryToJSON(userId, displayName);

            JSONValue[] blockedArr;
            foreach (userId, displayName; blocked)
                blockedArr ~= entryToJSON(userId, displayName);

            return JSONValue([
                "type": JSONValue("moderations"),
                "muted": JSONValue(mutedArr),
                "blocked": JSONValue(blockedArr),
            ]);
        }
    }
}

unittest
{
    ModerationsTracker t = new ModerationsTracker();

    JSONValue mkEntry(string type, string id, string name)
    {
        return JSONValue([
            "type": JSONValue(type),
            "targetUserId": JSONValue(id),
            "targetDisplayName": JSONValue(name),
        ]);
    }

    t.replaceFromAPI([
        mkEntry("mute", "usr_a", "Alice"),
        mkEntry("block", "usr_b", "Bob"),
        mkEntry("interactOff", "usr_c", "Carol"), // ignored
    ]);

    JSONValue snap = t.buildModerationsMessage();
    assert(snap["muted"].array.length == 1);
    assert(snap["blocked"].array.length == 1);
    assert(t.getDisplayName("usr_a") == "Alice");
    assert(t.getDisplayName("usr_c") == "");

    t.apply("unmute", "usr_a", null);
    t.apply("block", "usr_d", "Dave");
    snap = t.buildModerationsMessage();
    assert(snap["muted"].array.length == 0);
    assert(snap["blocked"].array.length == 2);
}
