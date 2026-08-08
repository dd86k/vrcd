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
import web.debugging;

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

    // Present only once vrcd-server has answered `get_stats`: the connection
    // block draws nothing rather than four zeroes for a link that has not said
    // yet. Cheap enough to ride along -- four numbers against a roster in the
    // same message -- and they are refreshed off the keepalive, so no route of
    // their own is needed.
    StoreStats stats = link.stats();
    if (stats.known)
    {
        root["database"] = JSONValue([
            "event_count":        JSONValue(stats.eventCount),
            "world_cache_count":  JSONValue(stats.worldCacheCount),
            "avatar_cache_count": JSONValue(stats.avatarCacheCount),
            "size_bytes":         JSONValue(stats.dbSizeBytes),
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
    {
        JSONValue encoded = buildNotificationJSON(entry);

        // Marked here rather than in the shared notification shape: a fake is
        // this front-end's own idea, and nothing else on the link has any
        // business carrying the field.
        //
        // The row it marks says ACCEPT and DECLINE like any other, and the
        // danger runs both ways -- accepting a real request while thinking it
        // is a fake, or leaving a real one sitting because it looked like one.
        // So the page draws a badge off this, rather than the two being told
        // apart by whoever is looking.
        if (isDebugNotification(entry.id))
            encoded["debug"] = JSONValue(true);

        pending ~= encoded;
    }
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

    // Present only when --debug (or VRCD_WEB_DEBUG) is on, which is what the
    // page tests to decide whether to draw the chip at all. The catalogue
    // rides along rather than living in the page: adding a fake should be one
    // edit, and the labels belong next to the thing that builds them.
    if (link.debugEnabled)
    {
        JSONValue[] fakes;
        fakes.reserve(DEBUG_FAKES.length);
        foreach (ref const DebugFake fake; DEBUG_FAKES)
        {
            fakes ~= JSONValue([
                "action": JSONValue(fake.action),
                "label":  JSONValue(fake.label),
                "hint":   JSONValue(fake.hint),
            ]);
        }
        root["debug"] = JSONValue([ "fakes": JSONValue(fakes) ]);
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

    // Carried whole, unlike the content sections: an entry is a name and an
    // ID, and the roster in the same message is many times their size. Always
    // present so the page can tell "nobody is muted" from "not asked yet".
    ModerationSnapshot moderation = link.moderations();
    root["moderations"] = JSONValue([
        "loading": JSONValue(moderation.loading),
        "loaded":  JSONValue(moderation.loaded),
        "error":   JSONValue(moderation.error),
        "muted":   moderatedJSON(moderation.muted),
        "blocked": moderatedJSON(moderation.blocked),
    ]);

    ModerationActionResult moderationAction = link.moderationResult();
    if (moderationAction.attempted)
    {
        root["moderation_action"] = JSONValue([
            "attempted":    JSONValue(true),
            "action":       JSONValue(moderationAction.action),
            "user_id":      JSONValue(moderationAction.userId),
            "display_name": JSONValue(moderationAction.displayName),
            "success":      JSONValue(moderationAction.success),
            "error":        JSONValue(moderationAction.error),
        ]);
    }

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

    // The profile editor on the same tab, and on the same terms as the picker
    // above it. `can_edit` is separate from the outcome: an older vrcd-server
    // would answer `set_profile` with an error, so the editor is not drawn at
    // all rather than offering a SAVE that cannot work.
    root["can_edit_profile"] = JSONValue(link.canEditProfile());
    ProfileUpdate profileUpdate = link.profileResult();
    if (profileUpdate.attempted)
    {
        root["profile_action"] = JSONValue([
            "attempted": JSONValue(true),
            "pending":   JSONValue(profileUpdate.pending),
            "success":   JSONValue(profileUpdate.success),
            "error":     JSONValue(profileUpdate.error),
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

/// Mute or block list as JSON. Keys are the server's own, since these entries
/// pass through unchanged: vrcd-server is where a display name for a
/// non-friend comes from.
private JSONValue moderatedJSON(ModeratedUser[] users)
{
    JSONValue[] items;
    items.reserve(users.length);
    foreach (ref ModeratedUser user; users)
    {
        items ~= JSONValue([
            "user_id":      JSONValue(user.userId),
            "display_name": JSONValue(user.displayName),
        ]);
    }
    return JSONValue(items);
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
