/// Offline stand-in for VRChat: a fixed scenario served over the normal API.
///
/// For working on the front-ends without a VRChat session, and for taking the
/// same screenshot twice. Nothing here talks to VRChat, and the database is
/// in memory, so every run starts from the scenario and nothing else.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.mock;

import core.thread : Thread;
import core.time : Duration, dur;
import std.algorithm.mutation : SwapStrategy;
import std.algorithm.sorting : sort;
import std.conv : to;
import std.datetime.systime : SysTime, Clock;
import std.file : readText;
import std.json;

import ddlogger;

import server.api;
import server.database;
import server.events;
import server.friends;
import server.userimage : UserImage;
import vrcd.notifications;

/// One scenario event, `offset` from when the server started.
struct MockEvent
{
    Duration offset;
    string type;
    JSONValue content;
}

/// A scenario file, parsed.
///
/// The file is a JSON object, every key optional:
/// - `now`: ISO 8601 time the scenario happens at, for repeatable screenshots.
///   Absent means the time the server started.
/// - `self`: the signed-in user, shaped like VRChat's user object
/// - `friends`: the roster, shaped like VRChat's friends listing
/// - `notifications`, `notificationsV2`: the inbox, as VRChat's two listings
/// - `events`: `{"at": "-5m", "type": "friend-online", "content": {...}}`
///
/// An event at or before zero is history, stored as is. One after zero is
/// sent live at that time through the same path as a VRChat event, so it
/// moves the roster and the inbox too.
struct MockScenario
{
    /// SysTime.init when the file sets none.
    SysTime now;
    JSONValue self;
    JSONValue[] friends;
    JSONValue[] notificationsV1;
    JSONValue[] notificationsV2;
    /// Oldest first.
    MockEvent[] history;
    /// Soonest first.
    MockEvent[] live;
}

/// Read and check the scenario at `path`. Throws with a message naming the
/// offending entry.
MockScenario loadScenario(string path)
{
    JSONValue root = parseJSON(readText(path));
    if (root.type != JSONType.object)
        throw new Exception("scenario is not a JSON object");

    MockScenario s;

    if (const(JSONValue)* v = "now" in root)
    {
        if (v.type != JSONType.string)
            throw new Exception("'now' is not a string");
        try s.now = SysTime.fromISOExtString(v.str);
        catch (Exception ex)
            throw new Exception("'now': " ~ ex.msg);
    }

    if (const(JSONValue)* v = "self" in root)
    {
        if (v.type != JSONType.object)
            throw new Exception("'self' is not an object");
        s.self = *v;
    }

    s.friends = objectArray(root, "friends");
    s.notificationsV1 = objectArray(root, "notifications");
    s.notificationsV2 = objectArray(root, "notificationsV2");

    foreach (size_t i, JSONValue entry; objectArray(root, "events"))
    {
        string where = "events[" ~ i.to!string ~ "]";
        MockEvent e;

        const(JSONValue)* at = "at" in entry;
        if (at is null || at.type != JSONType.string)
            throw new Exception(where ~ ": 'at' is missing or not a string");
        try e.offset = parseOffset(at.str);
        catch (Exception ex)
            throw new Exception(where ~ ": " ~ ex.msg);

        const(JSONValue)* type = "type" in entry;
        if (type is null || type.type != JSONType.string || type.str.length == 0)
            throw new Exception(where ~ ": 'type' is missing or not a string");
        e.type = type.str;

        e.content = JSONValue.emptyObject;
        if (const(JSONValue)* v = "content" in entry)
        {
            if (v.type != JSONType.object)
                throw new Exception(where ~ ": 'content' is not an object");
            e.content = *v;
        }

        if (e.offset > Duration.zero)
            s.live ~= e;
        else
            s.history ~= e;
    }

    // Stable, so events at the same time keep their file order.
    sort!((a, b) => a.offset < b.offset, SwapStrategy.stable)(s.history);
    sort!((a, b) => a.offset < b.offset, SwapStrategy.stable)(s.live);
    return s;
}

/// Load self, roster, inbox and history into `server` and `store`, with
/// history timestamps counted from `start`. Call before the server starts.
void applyScenario(ref MockScenario s, APIServer server, Database store, SysTime start)
{
    FriendsTracker tracker = server.getFriendsTracker();

    if (s.self.type == JSONType.object)
    {
        FriendsTracker.FriendState[string] built = FriendsTracker.buildFriendMap([ s.self ]);
        foreach (string id, ref FriendsTracker.FriendState f; built)
            tracker.setSelf(id, f.displayName, f.currentAvatar,
                f.status, f.statusDescription, f.bio, f.pronouns, f.bioLinks,
                UserImage(f.imageFileId, f.imageVersion));
    }

    tracker.replaceAll(FriendsTracker.buildFriendMap(s.friends));

    // After the roster, which is where a sender's name comes from.
    NotificationInfo[] inbox;
    foreach (JSONValue entry; s.notificationsV1)
        inbox ~= parseNotificationObject(entry, senderName(tracker, entry));
    foreach (JSONValue entry; s.notificationsV2)
        inbox ~= parseNotificationV2Object(entry, senderName(tracker, entry));
    server.replaceNotifications(inbox);

    foreach (ref MockEvent e; s.history)
    {
        VRCEvent event = makeEvent(e, start + e.offset);
        tracker.enrichContent(event);
        store.storeEvent(event);
    }

    server.setVRChatStatus(true, null);

    logInfo("Mock: %d friend(s), %d notification(s), %d event(s), %d live",
        s.friends.length, inbox.length, s.history.length, s.live.length);
}

/// Send the live events to `ingest` on a background thread, each its offset
/// from now, stamped with its offset from `start`.
void startLiveEvents(MockEvent[] live, SysTime start, void delegate(VRCEvent) ingest)
{
    if (live.length == 0)
        return;

    SysTime began = Clock.currTime();
    Thread t = new Thread({
        foreach (ref MockEvent e; live)
        {
            Duration wait = (began + e.offset) - Clock.currTime();
            if (wait > Duration.zero)
                Thread.sleep(wait);
            logInfo("Mock: live %s", e.type);
            ingest(makeEvent(e, start + e.offset));
        }
    });
    t.isDaemon = true;
    t.start();
}

/// Parse a signed offset such as "-5m", "+10s" or "-1h30m". Units are s, m, h
/// and d. Throws on anything else.
Duration parseOffset(string text)
{
    import std.ascii : isDigit;

    string s = text;
    bool negative;
    if (s.length > 0 && (s[0] == '-' || s[0] == '+'))
    {
        negative = s[0] == '-';
        s = s[1 .. $];
    }
    if (s.length == 0)
        throw new Exception("bad offset '" ~ text ~ "'");

    Duration total;
    while (s.length > 0)
    {
        size_t i;
        while (i < s.length && isDigit(s[i]))
            ++i;
        if (i == 0 || i == s.length)
            throw new Exception("bad offset '" ~ text ~ "'");

        long n = s[0 .. i].to!long;
        switch (s[i])
        {
            case 's': total += dur!"seconds"(n); break;
            case 'm': total += dur!"minutes"(n); break;
            case 'h': total += dur!"hours"(n); break;
            case 'd': total += dur!"days"(n); break;
            default:
                throw new Exception("bad unit '" ~ s[i] ~ "' in offset '" ~ text ~ "'");
        }
        s = s[i + 1 .. $];
    }
    return negative ? -total : total;
}
unittest
{
    assert(parseOffset("-5m") == -dur!"minutes"(5));
    assert(parseOffset("+10s") == dur!"seconds"(10));
    assert(parseOffset("10s") == dur!"seconds"(10));
    assert(parseOffset("-1h30m") == -(dur!"hours"(1) + dur!"minutes"(30)));
    assert(parseOffset("0s") == Duration.zero);

    foreach (string bad; [ "", "-", "5", "m", "5x", "-5m3" ])
    {
        bool threw;
        try parseOffset(bad);
        catch (Exception) threw = true;
        assert(threw, bad);
    }
}

private:

/// Array of objects under `key` in `root`, empty when absent. Throws when
/// it is something else.
JSONValue[] objectArray(JSONValue root, string key)
{
    JSONValue* v = key in root;
    if (v is null)
        return null;
    if (v.type != JSONType.array)
        throw new Exception("'" ~ key ~ "' is not an array");
    foreach (size_t i, ref JSONValue entry; v.array)
        if (entry.type != JSONType.object)
            throw new Exception(key ~ "[" ~ i.to!string ~ "] is not an object");
    return v.array;
}

/// Roster name of a notification's sender, or null.
string senderName(FriendsTracker tracker, JSONValue entry)
{
    if (const(JSONValue)* v = "senderUserId" in entry)
        if (v.type == JSONType.string)
            return tracker.getDisplayName(v.str);
    return null;
}

/// Build the event VRChat would have sent for `e`, received at `at`.
VRCEvent makeEvent(ref MockEvent e, SysTime at)
{
    return VRCEvent(toEventType(e.type), e.type, e.content, at,
        JSONValue([
            "type":    JSONValue(e.type),
            "content": JSONValue(e.content.toString()),
        ]).toString());
}
