/// State encoding for the browser.
///
/// The documents themselves are plain files under the web root (see
/// web.assets); this module only produces what they render. State goes out
/// over the WebSocket at /ws as one full snapshot per change, and the page
/// redraws from it. Snapshots are small enough that diffing them server-side
/// would cost more than it saves, and a full snapshot means a reconnecting
/// browser is correct immediately without replaying anything.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module web.state;

import std.json;

import vrcd.friends;
import vrcd.notifications;
import web.connection;

/// Build the state snapshot broadcast to browsers and served by /api/state.
string buildStateJSON(ServerLink link)
{
    SelfInfo info = link.self();
    LinkStatus status = link.status();
    FriendRoster roster = link.roster();
    JoinResult join = link.joinResult();
    NotificationInfo[] inbox = link.notifications();
    NotifyActionResult notifyAction = link.notifyResult();
    StatusUpdate statusUpdate = link.statusResult();
    AuthPrompt signin = link.authPrompt();
    ContentActionResult contentAction = link.contentResult();

    JSONValue root = JSONValue([
        "type":             JSONValue("state"),
        "connected":        JSONValue(status.connected),
        "vrchat_connected": JSONValue(status.vrchatConnected),
        "server_version":   JSONValue(status.serverVersion),
        "last_error":       JSONValue(status.lastError),
    ]);

    if (info.known)
    {
        root["self"] = JSONValue([
            "id":                JSONValue(info.id),
            "displayName":       JSONValue(info.displayName),
            "status":            JSONValue(info.status),
            "statusDescription": JSONValue(info.statusDescription),
            "bio":               JSONValue(info.bio),
            "pronouns":          JSONValue(info.pronouns),
            "bioLinks":          JSONValue(info.bioLinks),
            "imageFileId":       JSONValue(info.imageFileId),
            "imageVersion":      JSONValue(info.imageVersion),
        ]);
    }

    JSONValue[] instances;
    foreach (ref InstanceGroup group; roster.instances)
    {
        instances ~= JSONValue([
            "instance_id": JSONValue(group.instanceId),
            "location":    JSONValue(group.location),
            "world_name":  JSONValue(group.worldName),
            "n_users":     JSONValue(group.nUsers),
            "capacity":    JSONValue(group.capacity),
            "friends":     friendsJSON(group.friends),
        ]);
    }

    root["roster"] = JSONValue([
        "instances":        JSONValue(instances),
        "active_elsewhere": friendsJSON(roster.activeElsewhere),
        "offline":          friendsJSON(roster.offline),
    ]);

    if (join.attempted)
    {
        root["join"] = JSONValue([
            "attempted": JSONValue(true),
            "location":  JSONValue(join.location),
            "success":   JSONValue(join.success),
            "error":     JSONValue(join.error),
        ]);
    }

    // Always present, empty array included: the inbox tab needs to tell "no
    // notifications" apart from "the link has not answered yet", and the
    // count drives a badge on the rail.
    JSONValue[] pending;
    pending.reserve(inbox.length);
    foreach (ref NotificationInfo entry; inbox)
        pending ~= buildNotificationJSON(entry);
    root["notifications"] = JSONValue(pending);

    // Present only while the server is actually asking: the page drives its
    // sign-in modal off this key existing, and an "inactive" object would put
    // the burden of telling the two apart on every reader.
    if (signin.active)
    {
        root["auth"] = JSONValue([
            "kind":   JSONValue(signin.kind),
            "method": JSONValue(signin.method),
            "error":  JSONValue(signin.error),
        ]);
    }

    // Only what the page needs to know *that* a section moved. The entries
    // come from /api/content/:section instead: a few hundred of them would
    // ride along with every friend movement, and the tab showing them is
    // usually closed.
    JSONValue content = JSONValue.emptyObject;
    foreach (string name; CONTENT_SECTIONS)
    {
        ContentSnapshot section = link.content(name);
        content[name] = JSONValue([
            "revision":    JSONValue(section.revision),
            "loading":     JSONValue(section.loading),
            "loaded":      JSONValue(section.loaded),
            "count":       JSONValue(cast(long)section.items.length),
            "total_count": JSONValue(section.totalCount),
            "more":        JSONValue(section.more),
            "error":       JSONValue(section.error),
        ]);
    }
    root["content"] = content;

    if (contentAction.attempted)
    {
        root["content_action"] = JSONValue([
            "attempted": JSONValue(true),
            "action":    JSONValue(contentAction.action),
            "id":        JSONValue(contentAction.id),
            "success":   JSONValue(contentAction.success),
            "error":     JSONValue(contentAction.error),
        ]);
    }

    // The status picker on the profile tab. `pending` is in the snapshot rather
    // than in the browser because the answer is broadcast: a second browser
    // watching the same profile has to show the change going out too.
    if (statusUpdate.attempted)
    {
        root["status_action"] = JSONValue([
            "attempted":         JSONValue(true),
            "pending":           JSONValue(statusUpdate.pending),
            "status":            JSONValue(statusUpdate.status),
            "statusDescription": JSONValue(statusUpdate.statusDescription),
            "success":           JSONValue(statusUpdate.success),
            "error":             JSONValue(statusUpdate.error),
        ]);
    }

    if (notifyAction.attempted)
    {
        root["notify_action"] = JSONValue([
            "attempted":       JSONValue(true),
            "notification_id": JSONValue(notifyAction.notificationId),
            "action":          JSONValue(notifyAction.action),
            "success":         JSONValue(notifyAction.success),
            "error":           JSONValue(notifyAction.error),
        ]);
    }

    return root.toString();
}

/// Build the payload served by /api/content/:section.
///
/// The entries go out as vrcd-server trimmed them: this side renders them and
/// has no opinion about what a file, print or item is, so re-modelling them
/// here would only add a place for the two to disagree.
string buildContentJSON(ServerLink link, string name)
{
    ContentSnapshot section = link.content(name);

    JSONValue root = JSONValue([
        "section":     JSONValue(name),
        "revision":    JSONValue(section.revision),
        "loading":     JSONValue(section.loading),
        "loaded":      JSONValue(section.loaded),
        "total_count": JSONValue(section.totalCount),
        "more":        JSONValue(section.more),
        "error":       JSONValue(section.error),
    ]);
    root["items"] = JSONValue(section.items);
    return root.toString();
}

/// Encode one feed entry. Done once per entry rather than once per browser:
/// the hub fans out the encoded string as-is.
string encodeFeedEntry(FeedEntry entry)
{
    return JSONValue([
        "id":          JSONValue(entry.id),
        "event_type":  JSONValue(entry.eventType),
        "label":       JSONValue(entry.label),
        "user":        JSONValue(entry.user),
        "detail":      JSONValue(entry.detail),
        "received_at": JSONValue(entry.receivedAt),
    ]).toString();
}

/// Friend list as JSON. Bio and links are left out: the roster view does not
/// show them, and they would bloat every broadcast.
private JSONValue friendsJSON(FriendInfo[] friends)
{
    JSONValue[] items;
    foreach (ref FriendInfo friend; friends)
    {
        JSONValue entry = JSONValue([
            "id":                JSONValue(friend.userId),
            "displayName":       JSONValue(friend.displayName),
            "status":            JSONValue(friend.status),
            "statusDescription": JSONValue(friend.statusDescription),
            "platform":          JSONValue(friend.platform),
            "location":          JSONValue(friend.location),
            "pronouns":          JSONValue(friend.pronouns),
        ]);

        // Only when there is one. A roster runs to hundreds of entries and
        // goes out whole on every friend movement, so two empty fields per
        // friend without a picture is worth not sending.
        if (friend.imageFileId.length > 0)
        {
            entry["imageFileId"] = JSONValue(friend.imageFileId);
            entry["imageVersion"] = JSONValue(friend.imageVersion);
        }

        items ~= entry;
    }
    return JSONValue(items);
}
