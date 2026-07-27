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
import web.connection;

/// Build the state snapshot broadcast to browsers and served by /api/state.
string buildStateJSON(ServerLink link)
{
    SelfInfo info = link.self();
    LinkStatus status = link.status();
    FriendRoster roster = link.roster();
    JoinResult join = link.joinResult();

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
        items ~= JSONValue([
            "id":                JSONValue(friend.userId),
            "displayName":       JSONValue(friend.displayName),
            "status":            JSONValue(friend.status),
            "statusDescription": JSONValue(friend.statusDescription),
            "platform":          JSONValue(friend.platform),
            "location":          JSONValue(friend.location),
            "pronouns":          JSONValue(friend.pronouns),
        ]);
    }
    return JSONValue(items);
}
