/// VRCX history as vrcd events, in the shape `import_events` takes.
///
/// Only the friend feeds and the friend log are read. `gamelog_*` is the
/// game's own side of things (the client's, not the server's), and the file
/// also holds saved credentials, notes and memos that have no business
/// leaving it. Each account's history lives in tables named after it, so
/// only the signed-in account's are opened at all.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module vrcd.vrcx;

import std.json;
import std.string : startsWith, indexOf;
import std.array : replace;

import arsd.sqlite;

import vrcd.timerange;

/// One converted row.
struct VRCXEvent
{
    string receivedAt;
    string eventType;
    JSONValue content;

    /// As an entry of `import_events`' `events`.
    JSONValue toJSON()
    {
        return JSONValue([
            "received_at": JSONValue(receivedAt),
            "event_type": JSONValue(eventType),
            "content": content,
        ]);
    }
}

/// How much of a VRCX file an import plan would take.
struct VRCXPreview
{
    /// Events per accepted span, in the plan's order.
    long[] perSpan;
    /// Events in periods vrcd recorded itself, or earlier imports covered.
    long outside;
    /// Rows with nothing vrcd shows (renames, trust changes, travel) or no
    /// usable time.
    long skipped;
}

/// VRCX's table prefix for an account: the user ID without its dashes and
/// underscores, behind an underscore when that leaves a leading digit.
string vrcxPrefix(string userId)
{
    string prefix = userId.replace("-", "").replace("_", "");
    if (prefix.length && prefix[0] >= '0' && prefix[0] <= '9')
        prefix = "_" ~ prefix;
    return prefix;
}

/// One account's history in a VRCX database, opened read-only.
final class VRCXReader
{
    /// Rows `opApply` passed over so far. See `VRCXPreview.skipped`.
    long skipped;

    private Sqlite db;
    private string userId;
    private string prefix;
    private const(Feed)[] feeds;

    /// Throws when the file cannot be opened or holds no history for
    /// `userId`, which is usually a VRCX signed in as another account.
    this(string path, string userId)
    {
        db = new Sqlite(path, SQLITE_OPEN_READONLY);
        this.userId = userId;
        prefix = vrcxPrefix(userId);

        // Older VRCX versions lack some of them.
        bool[string] present;
        foreach (row; db.query("SELECT name FROM sqlite_master WHERE type = 'table'"))
            present[row[0]] = true;
        foreach (ref const(Feed) feed; FEEDS)
            if (prefix ~ feed.suffix in present)
                feeds ~= feed;
        if (feeds.length == 0)
            throw new Exception("No VRCX history for " ~ userId ~ " in " ~ path);
    }

    /// Every convertible row, table by table.
    int opApply(scope int delegate(ref VRCXEvent) dg)
    {
        foreach (ref const(Feed) feed; feeds)
        {
            foreach (row; db.query("SELECT " ~ feed.columns ~ " FROM " ~ prefix ~ feed.suffix ~ " ORDER BY id"))
            {
                string[] cols = row.toStringArray();

                VRCXEvent ev;
                ev.receivedAt = normalizeTime(cols[0]);
                if (ev.receivedAt is null || feed.convert(cols[1 .. $], ev) == false)
                {
                    ++skipped;
                    continue;
                }
                if (const(JSONValue)* v = "userId" in ev.content)
                    if (v.str == userId)
                        ev.content["isSelf"] = JSONValue(true);
                if (int r = dg(ev))
                    return r;
            }
        }
        return 0;
    }

    /// Count what an import with these accepted spans would send.
    VRCXPreview preview(const(TimeRange)[] accept)
    {
        VRCXPreview p;
        p.perSpan.length = accept.length;
        long before = skipped;
        foreach (ref VRCXEvent ev; this)
        {
            ptrdiff_t span = findRange(accept, ev.receivedAt);
            if (span < 0)
                ++p.outside;
            else
                ++p.perSpan[span];
        }
        p.skipped = skipped - before;
        return p;
    }
}

private:

// `columns` starts with the row's time; `convert` gets the rest.
struct Feed
{
    string suffix;
    string columns;
    bool function(string[] c, ref VRCXEvent ev) convert;
}

immutable Feed[] FEEDS = [
    Feed("_feed_gps", "created_at, user_id, display_name, location, world_name, group_name", &fromGps),
    Feed("_feed_online_offline", "created_at, user_id, display_name, type, location, world_name", &fromOnlineOffline),
    Feed("_feed_status", "created_at, user_id, display_name, status, status_description", &fromStatus),
    Feed("_feed_avatar", "created_at, user_id, display_name, avatar_name, " ~
        "current_avatar_image_url, previous_current_avatar_image_url", &fromAvatar),
    Feed("_feed_bio", "created_at, user_id, display_name, bio, previous_bio", &fromBio),
    Feed("_friend_log_history", "created_at, type, user_id, display_name", &fromFriendLog),
];

JSONValue who(string userId, string displayName)
{
    return JSONValue([
        "userId": JSONValue(userId),
        "displayName": JSONValue(displayName),
    ]);
}

// Same place the location's own world is named in live friend-location.
void putLocation(ref JSONValue content, string location, string worldName)
{
    content["location"] = JSONValue(location);
    if (location.startsWith("wrld_"))
    {
        ptrdiff_t colon = location.indexOf(':');
        content["worldId"] = JSONValue(colon > 0 ? location[0 .. colon] : location);
    }
    if (worldName.length)
        content["worldName"] = JSONValue(worldName);
}

bool fromGps(string[] c, ref VRCXEvent ev)
{
    // vrcd keeps the move, not the trip, and so does VRCX nearly always.
    if (c[2].length == 0 || c[2] == "traveling")
        return false;
    ev.eventType = "friend-location";
    ev.content = who(c[0], c[1]);
    putLocation(ev.content, c[2], c[3]);
    if (c[4].length)
        ev.content["groupName"] = JSONValue(c[4]);
    return true;
}

bool fromOnlineOffline(string[] c, ref VRCXEvent ev)
{
    ev.content = who(c[0], c[1]);
    switch (c[2])
    {
    case "Online":
        ev.eventType = "friend-online";
        if (c[3].length)
            putLocation(ev.content, c[3], c[4]);
        return true;
    case "Offline":
        ev.eventType = "friend-offline";
        return true;
    default:
        return false;
    }
}

bool fromStatus(string[] c, ref VRCXEvent ev)
{
    ev.eventType = "friend-update";
    ev.content = who(c[0], c[1]);
    ev.content["user"] = JSONValue([
        "id": JSONValue(c[0]),
        "displayName": JSONValue(c[1]),
        "status": JSONValue(c[2]),
        "statusDescription": JSONValue(c[3]),
    ]);
    return true;
}

// VRChat hands out a friend's avatar as its image URL, not its ID, and so
// do vrcd's own avatar-change events for friends.
bool fromAvatar(string[] c, ref VRCXEvent ev)
{
    if (c[3].length == 0)
        return false;
    ev.eventType = "avatar-change";
    ev.content = who(c[0], c[1]);
    ev.content["currentAvatar"] = JSONValue(c[3]);
    ev.content["previousAvatar"] = JSONValue(c[4]);
    ev.content["isSelf"] = JSONValue(false);
    if (c[2].length)
        ev.content["avatarName"] = JSONValue(c[2]);
    return true;
}

bool fromBio(string[] c, ref VRCXEvent ev)
{
    ev.eventType = "profile-change";
    ev.content = who(c[0], c[1]);
    ev.content["currentBio"] = JSONValue(c[2]);
    ev.content["previousBio"] = JSONValue(c[3]);
    ev.content["isSelf"] = JSONValue(false);
    return true;
}

// Renames, trust changes and friend requests have no vrcd event.
bool fromFriendLog(string[] c, ref VRCXEvent ev)
{
    switch (c[0])
    {
    case "Friend":
        ev.eventType = "friend-add";
        ev.content = who(c[1], c[2]);
        ev.content["user"] = JSONValue([
            "id": JSONValue(c[1]),
            "displayName": JSONValue(c[2]),
        ]);
        return true;
    case "Unfriend":
        ev.eventType = "friend-delete";
        ev.content = who(c[1], c[2]);
        return true;
    default:
        return false;
    }
}

unittest
{
    assert(vrcxPrefix("usr_0a1b-2c") == "usr0a1b2c");
    assert(vrcxPrefix("usr_ab-cd") == "usrabcd");
    assert(vrcxPrefix("0123-4") == "_01234");
}

unittest
{
    import std.file : exists, remove, tempDir;
    import std.path : buildPath;

    string path = buildPath(tempDir(), "vrcd-vrcx-test.sqlite3");
    if (exists(path))
        remove(path);
    scope(exit) remove(path);

    enum string ME = "usr_11111111-2222";
    string p = vrcxPrefix(ME);
    Sqlite w = new Sqlite(path);
    w.exec("CREATE TABLE " ~ p ~ "_feed_gps (id INTEGER PRIMARY KEY, created_at TEXT, user_id TEXT, " ~
        "display_name TEXT, location TEXT, world_name TEXT, previous_location TEXT, time INTEGER, group_name TEXT)");
    w.exec("CREATE TABLE " ~ p ~ "_feed_online_offline (id INTEGER PRIMARY KEY, created_at TEXT, user_id TEXT, " ~
        "display_name TEXT, type TEXT, location TEXT, world_name TEXT, time INTEGER, group_name TEXT)");
    w.exec("CREATE TABLE " ~ p ~ "_friend_log_history (id INTEGER PRIMARY KEY, created_at TEXT, type TEXT, " ~
        "user_id TEXT, display_name TEXT, previous_display_name TEXT, trust_level TEXT, " ~
        "previous_trust_level TEXT, friend_number INTEGER)");
    // Another account's, which must not be read.
    w.exec("CREATE TABLE usrother_feed_bio (id INTEGER PRIMARY KEY, created_at TEXT, user_id TEXT, " ~
        "display_name TEXT, bio TEXT, previous_bio TEXT)");
    w.exec("INSERT INTO usrother_feed_bio VALUES (1, '2024-01-01T00:00:00.000Z', 'usr_x', 'x', 'b', 'a')");

    w.exec("INSERT INTO " ~ p ~ "_feed_gps VALUES " ~
        "(1, '2024-01-01T10:00:00.000Z', 'usr_a', 'Alice', 'wrld_1:123~private(usr_a)', 'Home', '', 0, NULL), " ~
        "(2, '2024-01-01T10:05:00.000Z', 'usr_a', 'Alice', 'traveling', '', '', 0, NULL), " ~
        "(3, '2024-01-01T11:00:00.000Z', 'usr_a', 'Alice', 'private', '', '', 0, NULL)");
    w.exec("INSERT INTO " ~ p ~ "_feed_online_offline VALUES " ~
        "(1, '2024-01-01T09:00:00.000Z', 'usr_a', 'Alice', 'Online', 'wrld_2:9', 'Club', 0, ''), " ~
        "(2, '2024-01-02T09:00:00.000Z', 'usr_a', 'Alice', 'Offline', 'private', '', 0, ''), " ~
        "(3, 'garbage', 'usr_a', 'Alice', 'Online', '', '', 0, '')");
    w.exec("INSERT INTO " ~ p ~ "_friend_log_history VALUES " ~
        "(1, '2023-12-31T00:00:00.000Z', 'Friend', 'usr_a', 'Alice', NULL, NULL, NULL, 1), " ~
        "(2, '2023-12-31T01:00:00.000Z', 'DisplayName', 'usr_a', 'Alice', 'Al', NULL, NULL, 1)");
    w = null;

    VRCXReader r = new VRCXReader(path, ME);
    VRCXEvent[] got;
    foreach (ref VRCXEvent ev; r)
        got ~= ev;
    assert(r.skipped == 3);
    assert(got.length == 5);

    assert(got[0].eventType == "friend-location");
    assert(got[0].receivedAt == "2024-01-01T10:00:00.000Z");
    assert(got[0].content["displayName"].str == "Alice");
    assert(got[0].content["worldId"].str == "wrld_1");
    assert(got[0].content["worldName"].str == "Home");
    assert(got[1].content["location"].str == "private");
    assert("worldId" !in got[1].content);

    assert(got[2].eventType == "friend-online");
    assert(got[2].content["worldName"].str == "Club");
    assert(got[3].eventType == "friend-offline");
    assert("location" !in got[3].content);

    assert(got[4].eventType == "friend-add");
    assert(got[4].toJSON()["content"]["user"]["id"].str == "usr_a");

    VRCXPreview pv = r.preview([
        TimeRange("", "2024-01-01T09:30:00.000Z"),
        TimeRange("2024-01-02T00:00:00.000Z", "2024-01-03T00:00:00.000Z"),
    ]);
    assert(pv.perSpan == [ 2, 1 ]);
    assert(pv.outside == 2);
    assert(pv.skipped == 3);

    bool refused;
    try new VRCXReader(path, "usr_nobody");
    catch (Exception) refused = true;
    assert(refused);
}
