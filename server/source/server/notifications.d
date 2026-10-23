/// Server-side notification inbox.
///
/// The inbox used to be front-end state: every connect asked VRChat for the
/// pending list and then folded the WebSocket events in on its own. That left
/// a hole -- a notification that arrived and was answered while no front-end
/// was connected was never seen anywhere -- and spent two VRChat calls per
/// front-end connect. The server watches the WebSocket the whole time, so it
/// keeps the one authoritative copy: seeded from the REST listings,
/// maintained from the events, re-broadcast on change. Deliberately not
/// persisted to the database: VRChat's listing is the source of truth for
/// what is still pending, and a stored inbox would resurrect notifications
/// answered while the server was down.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.notifications;

import core.sync.mutex;

import std.json;

import vrcd.notifications;

/// Tracks the logged-in user's pending notifications, oldest first -- the
/// order the front-ends draw, so an arrival appends instead of moving rows
/// under someone's finger.
class NotificationsTracker
{
    private NotificationInfo[] inbox;
    // Promoted entries live apart from VRChat's, since a re-seed replaces
    // the inbox with VRChat's listing and that has never heard of them.
    private NotificationInfo[] promoted;
    private long promotedSeq;
    private bool seeded;
    private Mutex mtx;

    this()
    {
        mtx = new Mutex();
    }

    /// Whether a REST seed has ever succeeded. Events are folded in either
    /// way, but an unseeded inbox is a partial one and `get_notifications`
    /// retries the seed rather than serving it.
    bool isSeeded()
    {
        synchronized (mtx)
            return seeded;
    }

    /// Replace the whole inbox from a REST seed. Returns whether anything
    /// actually changed, so a quiet re-seed does not redraw every client.
    bool replaceAll(NotificationInfo[] list)
    {
        sortOldestFirst(list);
        synchronized (mtx)
        {
            bool changed = seeded == false || inbox != list;
            inbox = list;
            seeded = true;
            return changed;
        }
    }

    /// Fold one WebSocket event in. Returns whether the inbox changed.
    ///
    /// Same semantics as the front-ends: a repeated arrival is dropped
    /// (VRChat re-emits on its own reconnects), an update merges onto a row
    /// already present and never adds one -- an update for a row never seen
    /// is an update to a notification already answered.
    bool applyEvent(string eventType, JSONValue msg, string fallbackSender,
        string rawReceivedAt)
    {
        NotificationInfo added = void;
        string[] removedIds;
        NotificationChange change = applyNotificationEvent(eventType, msg,
            fallbackSender, rawReceivedAt, added, removedIds);

        final switch (change)
        {
        case NotificationChange.none:
            return false;

        case NotificationChange.added:
            synchronized (mtx)
            {
                foreach (ref NotificationInfo entry; inbox)
                {
                    if (entry.id == added.id)
                        return false;
                }
                inbox ~= added;
            }
            return true;

        case NotificationChange.updated:
            synchronized (mtx)
            {
                foreach (ref NotificationInfo entry; inbox)
                {
                    if (entry.id != added.id)
                        continue;
                    mergeNotificationUpdate(entry, added);
                    return true;
                }
            }
            return false;

        case NotificationChange.removed:
            return remove(removedIds);
        }
    }

    /// Append a promoted entry, assigning its ID. The oldest go first past the
    /// cap: these are reminders, not requests waiting on an answer.
    NotificationInfo addPromoted(NotificationInfo delegate(long seq) build)
    {
        synchronized (mtx)
        {
            NotificationInfo info = build(++promotedSeq);
            promoted ~= info;
            if (promoted.length > PROMOTED_MAX)
                promoted = promoted[$ - PROMOTED_MAX .. $].dup;
            return info;
        }
    }

    /// Take entries out by ID (an answer observed on the wire, or one made
    /// through us). Returns whether any were present.
    bool remove(string[] ids)
    {
        if (ids.length == 0)
            return false;

        synchronized (mtx)
        {
            size_t before = inbox.length + promoted.length;
            inbox = without(inbox, ids);
            promoted = without(promoted, ids);
            return inbox.length + promoted.length != before;
        }
    }

    /// Build the `notifications` snapshot message. Promoted entries are
    /// merged in by time, so the front-ends draw one list in one order.
    JSONValue buildNotificationsMessage()
    {
        synchronized (mtx)
        {
            JSONValue[] items;
            items.reserve(inbox.length + promoted.length);
            size_t i, p;
            while (i < inbox.length || p < promoted.length)
            {
                if (p == promoted.length || (i < inbox.length
                    && inbox[i].receivedAtUnix <= promoted[p].receivedAtUnix))
                    items ~= buildNotificationJSON(inbox[i++]);
                else
                    items ~= buildNotificationJSON(promoted[p++]);
            }

            return JSONValue([
                "type": JSONValue("notifications"),
                "notifications": JSONValue(items),
            ]);
        }
    }
}

/// Promoted entries kept at most; past this the inbox stops being an inbox.
private enum size_t PROMOTED_MAX = 50;

private NotificationInfo[] without(NotificationInfo[] list, string[] ids)
{
    import std.algorithm.searching : canFind;

    NotificationInfo[] kept;
    kept.reserve(list.length);
    foreach (ref NotificationInfo entry; list)
        if (canFind(ids, entry.id) == false)
            kept ~= entry;
    return kept;
}

/// Entries VRChat gave no timestamp sort as 0, so they lead; that keeps them
/// in one place rather than scattered through the list.
private void sortOldestFirst(NotificationInfo[] list)
{
    import std.algorithm.sorting : sort;

    sort!((ref NotificationInfo a, ref NotificationInfo b)
        => a.receivedAtUnix < b.receivedAtUnix)(list);
}

unittest
{
    NotificationsTracker t = new NotificationsTracker();
    assert(t.isSeeded() == false);

    NotificationInfo mkInfo(string id, long stamp)
    {
        NotificationInfo info;
        info.id = id;
        info.notificationType = "friendRequest";
        info.receivedAtUnix = stamp;
        return info;
    }

    // Seed sorts oldest first and reports the change.
    assert(t.replaceAll([ mkInfo("not_b", 200), mkInfo("not_a", 100) ]));
    assert(t.isSeeded());
    JSONValue snap = t.buildNotificationsMessage();
    assert(snap["notifications"].array.length == 2);
    assert(snap["notifications"][0]["id"].str == "not_a");

    // The same list over again is not a change.
    assert(t.replaceAll([ mkInfo("not_a", 100), mkInfo("not_b", 200) ]) == false);

    // An arrival appends; the same arrival twice does not.
    JSONValue arrival = parseJSON(`{"content":{"id":"not_c",` ~
        `"type":"group.announcement","title":"Movie night","message":"8pm"}}`);
    assert(t.applyEvent("notification-v2", arrival, null, "2026-09-07T00:00:00Z"));
    assert(t.applyEvent("notification-v2", arrival, null, "2026-09-07T00:00:00Z") == false);
    snap = t.buildNotificationsMessage();
    assert(snap["notifications"].array.length == 3);
    assert(snap["notifications"][2]["id"].str == "not_c");

    // An update merges in place, and one for an unseen row changes nothing.
    JSONValue update = parseJSON(`{"content":{"id":"not_c",` ~
        `"updates":{"message":"9pm"}}}`);
    assert(t.applyEvent("notification-v2-update", update, null, ""));
    snap = t.buildNotificationsMessage();
    assert(snap["notifications"][2]["message"].str == "9pm");
    JSONValue stranger = parseJSON(`{"content":{"id":"not_x",` ~
        `"updates":{"message":"gone"}}}`);
    assert(t.applyEvent("notification-v2-update", stranger, null, "") == false);

    // An answer seen on the wire removes the row; a repeat is a no-op.
    JSONValue hide = parseJSON(`{"content":"not_a"}`);
    assert(t.applyEvent("hide-notification", hide, null, ""));
    assert(t.applyEvent("hide-notification", hide, null, "") == false);
    assert(t.remove([ "not_b" ]));
    snap = t.buildNotificationsMessage();
    assert(snap["notifications"].array.length == 1);
}

unittest
{
    NotificationsTracker t = new NotificationsTracker();

    NotificationInfo mkInfo(string id, long stamp)
    {
        NotificationInfo info;
        info.id = id;
        info.receivedAtUnix = stamp;
        return info;
    }

    t.replaceAll([ mkInfo("not_a", 100), mkInfo("not_c", 300) ]);
    NotificationInfo added = t.addPromoted((long seq) =>
        mkInfo("user_notification_" ~ (seq == 1 ? "1" : "?"), 200));
    assert(added.id == "user_notification_1");

    // Merged in by time, and a re-seed does not take it away.
    JSONValue snap = t.buildNotificationsMessage();
    assert(snap["notifications"].array.length == 3);
    assert(snap["notifications"][1]["id"].str == "user_notification_1");
    t.replaceAll([ mkInfo("not_a", 100) ]);
    snap = t.buildNotificationsMessage();
    assert(snap["notifications"][1]["id"].str == "user_notification_1");

    assert(t.remove([ "user_notification_1" ]));
    assert(t.remove([ "user_notification_1" ]) == false);
    snap = t.buildNotificationsMessage();
    assert(snap["notifications"].array.length == 1);
}
