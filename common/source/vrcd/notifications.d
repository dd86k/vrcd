/// Notification model shared by vrcd-server and both front-ends.
///
/// VRChat has two notification systems and hands each one out twice.
///
/// The v1 system (`auth/user/notifications`, the `notification` event) covers
/// friend requests, invites and the older person-to-person types. Its REST
/// shape encodes `details` as a JSON *string* while the WebSocket shape makes
/// it a real object, so both are accepted here.
///
/// The v2 system (`notifications`, the `notification-v2` event) covers
/// everything VRChat added later: group invites, join requests, transfers,
/// announcements, queue-ready, instance closures, moderation. A v2
/// notification describes its own buttons in a `responses` array rather than
/// having a fixed accept/decline pair, which is what lets a front-end draw
/// the right actions for a type nobody wrote code for.
///
/// Both reduce to one NotificationInfo, with `apiVersion` recording which
/// system answers it -- the endpoints for acting on the two do not overlap.
///
/// The server normalizes both REST listings through this module and sends the
/// result as a `notifications` message; the front-ends parse that message and
/// then keep the list current from the WebSocket events, which arrive faster
/// than a refetch would and cost no API call.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module vrcd.notifications;

import std.datetime : SysTime;
import std.json;

/// One button a v2 notification offers, as VRChat describes it.
///
/// The point of carrying these rather than a per-type table is that a group
/// invite, a join request and a transfer all answer the same way -- POST the
/// `type` back -- and a type nobody anticipated still draws correct buttons.
struct NotificationResponse
{
    /// Response type, posted back as `responseType`. Also the identity of
    /// the button: it is what the front-end sends when it is pressed.
    string type;
    /// Button label. VRChat writes these ("Accept", "Decline", "Block").
    string text;
    /// Icon hint: "check", "cancel", "ban", "bell-slash", "reply". Advisory,
    /// and often absent.
    string icon;
    /// Opaque payload posted back as `responseData` alongside the type.
    string data;
}

/// One inbox notification, normalized out of any of the four wire shapes.
struct NotificationInfo
{
    /// VRChat notification ID ("not_..."). Empty when the object was
    /// unusable, which is how callers test for a failed parse.
    string id;
    /// VRChat's type string: "friendRequest", "invite", "group.announcement",
    /// "group.queueReady", "instance.closed", and so on. Not an enum: VRChat
    /// adds these faster than anyone can enumerate them, and a type this
    /// build has never seen still has a title, a message and its buttons.
    string notificationType;
    /// Sender's user ID, when VRChat included one. A v2 notification from a
    /// group carries a `grp_...` ID here instead of a `usr_...` one.
    string senderUserId;
    /// Best-known sender name. VRChat deprecated `senderUsername` and no
    /// longer returns it for other users, so this is often filled in by the
    /// caller from a friend roster instead.
    string senderName;
    /// Headline, v2 only ("Group Invite", the announcement's subject).
    /// Empty on v1, which has no such field.
    string title;
    /// Message body, or the world name for an invite that carries no text.
    string message;
    /// Instance an invite points at, empty for every other type. Carrying it
    /// is what lets the inbox offer a join rather than just an acknowledgement.
    string location;
    /// Creation time as a UNIX timestamp, 0 when VRChat gave none or it did
    /// not parse. Ordering falls back to arrival order when this is 0.
    long receivedAtUnix;
    /// Buttons this notification offers, empty on v1. A front-end that gets
    /// none falls back to what it knows about the type, which for anything
    /// unrecognized is a dismiss and nothing else.
    NotificationResponse[] responses;
    /// Whether the notification can be dismissed at all. VRChat clears some
    /// of its own (a queue-ready expires, an announcement is retracted), and
    /// a dismiss button on one of those would just fail.
    bool canDelete = true;
    /// Which notification system this came from: 1 or 2. Decides the
    /// endpoint an action uses, so it travels with every entry.
    int apiVersion = 1;
}

/// What a WebSocket notification event did to the inbox.
enum NotificationChange
{
    /// Not a notification event, or one that changes nothing (a malformed
    /// payload, an event carrying no ID).
    none,
    /// One notification arrived.
    added,
    /// One or more notifications are gone.
    removed,
    /// One notification changed in place. Only the fields VRChat sent are
    /// filled in, so this is a merge, not a replacement.
    updated,
}

/// Decode a v1 notification object into the normalized form. Accepts both v1
/// wire shapes: `details` may be an object (WebSocket) or a JSON-encoded
/// string (REST). Returns an entry with an empty `id` when the object is
/// unusable.
///
/// Every type is kept, not just the ones with an Accept button. A vote to
/// kick or an invite response is still something that happened to the user
/// and still reads as a row; the front-ends draw a dismiss for anything they
/// have nothing better to offer.
///
/// Params:
///   content = The notification object.
///   fallbackSender = Name to use when the object carries no sender name,
///                    typically resolved from a friend roster by user ID.
NotificationInfo parseNotificationObject(JSONValue content, string fallbackSender = null)
{
    NotificationInfo info;
    if (content.type != JSONType.object)
        return info;

    string id;
    if (const(JSONValue)* v = "id" in content)
        if (v.type == JSONType.string)
            id = v.str;

    string notifType;
    if (const(JSONValue)* v = "type" in content)
        if (v.type == JSONType.string)
            notifType = v.str;

    if (id.length == 0 || notifType.length == 0)
        return info;

    info.id = id;
    info.notificationType = notifType;

    if (const(JSONValue)* v = "senderUserId" in content)
        if (v.type == JSONType.string)
            info.senderUserId = v.str;

    // Deprecated upstream and usually absent, but still sent for some
    // notification kinds, and it beats showing a raw user ID.
    if (const(JSONValue)* v = "senderUsername" in content)
        if (v.type == JSONType.string)
            info.senderName = v.str;
    if (info.senderName.length == 0)
        info.senderName = fallbackSender;

    if (const(JSONValue)* v = "message" in content)
        if (v.type == JSONType.string)
            info.message = v.str;

    JSONValue details = decodeDetails(content);
    if (details.type == JSONType.object)
    {
        // An invite points at a full instance ID, which is exactly what a
        // self-invite takes, so the inbox can offer a join.
        if (const(JSONValue)* v = "worldId" in details)
            if (v.type == JSONType.string)
                info.location = v.str;

        // An invite with no message of its own still knows where it points,
        // which is the one thing worth reading on the row.
        if (info.message.length == 0)
            if (const(JSONValue)* v = "inviteMessage" in details)
                if (v.type == JSONType.string)
                    info.message = v.str;
        if (info.message.length == 0)
            if (const(JSONValue)* v = "worldName" in details)
                if (v.type == JSONType.string)
                    info.message = v.str;
    }

    if (const(JSONValue)* v = "created_at" in content)
        if (v.type == JSONType.string)
            info.receivedAtUnix = parseTimestamp(v.str);

    return info;
}

/// Decode a v2 notification object into the normalized form. One shape here,
/// object all the way down, whether it came from `GET /notifications` or a
/// `notification-v2` event.
///
/// Returns an entry with an empty `id` when the object is unusable. Partial
/// objects are expected: a `notification-v2-update` carries only what moved,
/// so absent fields stay at their defaults for the caller to merge.
///
/// Params:
///   content = The notification object.
///   fallbackSender = Name to use when the object carries no sender name.
NotificationInfo parseNotificationV2Object(JSONValue content, string fallbackSender = null)
{
    NotificationInfo info;
    info.apiVersion = 2;
    if (content.type != JSONType.object)
        return info;

    if (const(JSONValue)* v = "id" in content)
        if (v.type == JSONType.string)
            info.id = v.str;
    if (info.id.length == 0)
        return info;

    if (const(JSONValue)* v = "type" in content)
        if (v.type == JSONType.string)
            info.notificationType = v.str;

    // A group notification puts the group's own ID here, which is why the
    // front-ends cannot assume this resolves against the friend roster.
    if (const(JSONValue)* v = "senderUserId" in content)
        if (v.type == JSONType.string)
            info.senderUserId = v.str;
    if (const(JSONValue)* v = "senderUsername" in content)
        if (v.type == JSONType.string)
            info.senderName = v.str;
    if (info.senderName.length == 0)
        info.senderName = fallbackSender;

    // v2 splits what v1 crammed into `message`: the title names the kind of
    // thing ("Group Invite"), the message says what it is about. Both are
    // kept apart so the row can draw them apart.
    if (const(JSONValue)* v = "title" in content)
        if (v.type == JSONType.string)
            info.title = v.str;
    if (const(JSONValue)* v = "message" in content)
        if (v.type == JSONType.string)
            info.message = v.str;

    if (const(JSONValue)* v = "canDelete" in content)
        info.canDelete = v.type == JSONType.true_;

    if (const(JSONValue)* jresponses = "responses" in content)
    if (jresponses.type == JSONType.array)
    {
        foreach (const(JSONValue) entry; jresponses.array)
        {
            if (entry.type != JSONType.object)
                continue;

            NotificationResponse response;
            if (const(JSONValue)* v = "type" in entry)
                if (v.type == JSONType.string)
                    response.type = v.str;
            if (const(JSONValue)* v = "text" in entry)
                if (v.type == JSONType.string)
                    response.text = v.str;
            if (const(JSONValue)* v = "icon" in entry)
                if (v.type == JSONType.string)
                    response.icon = v.str;
            if (const(JSONValue)* v = "data" in entry)
                if (v.type == JSONType.string)
                    response.data = v.str;

            // A response with no type cannot be sent back, and a "link" one
            // points at a VRChat-client screen (`group:grp_...`) that neither
            // front-end has. Both would draw a button that does nothing.
            if (response.type.length == 0 || response.type == "link")
                continue;
            info.responses ~= response;
        }
    }

    // Same instant, different spelling: v2 went camelCase.
    if (const(JSONValue)* v = "createdAt" in content)
        if (v.type == JSONType.string)
            info.receivedAtUnix = parseTimestamp(v.str);

    return info;
}

/// Apply one WebSocket event to the inbox. Both notification systems and all
/// of their events land here; anything else falls straight back out.
///
/// Params:
///   eventType = Raw VRChat event type.
///   msg = The event message, whose "content" holds the payload.
///   fallbackSender = Sender name to use when the payload carries none.
///   rawReceivedAt = The event's own ISO 8601 timestamp, used when the
///                   notification object carries no creation time.
///   added = Filled in when the return is `added` (the whole notification)
///           or `updated` (its ID, plus only the fields that moved -- feed
///           that one to mergeNotificationUpdate).
///   removedIds = Filled in when the return is `removed`.
NotificationChange applyNotificationEvent(string eventType, JSONValue msg,
    string fallbackSender, string rawReceivedAt,
    out NotificationInfo added, out string[] removedIds)
{
    const(JSONValue)* jcontent = "content" in msg;
    if (jcontent is null) // Every one of these carries its payload there.
        return NotificationChange.none;

    try switch (eventType)
    {
        // Content is the notification object, double-encoded on some events.
        case "notification":
            JSONValue content = jcontent.type == JSONType.string
                ? parseJSON(jcontent.str) : *jcontent;

            added = parseNotificationObject(content, fallbackSender);
            if (added.id.length == 0)
                return NotificationChange.none;
            if (added.receivedAtUnix == 0)
                added.receivedAtUnix = parseTimestamp(rawReceivedAt);
            return NotificationChange.added;

        case "notification-v2":
            JSONValue content = jcontent.type == JSONType.string
                ? parseJSON(jcontent.str) : *jcontent;

            added = parseNotificationV2Object(content, fallbackSender);
            if (added.id.length == 0)
                return NotificationChange.none;
            if (added.receivedAtUnix == 0)
                added.receivedAtUnix = parseTimestamp(rawReceivedAt);
            return NotificationChange.added;

        // A group edits an announcement, a queue-ready loses its buttons as
        // it expires. VRChat sends only the fields that moved, so this is a
        // merge onto the row already in the inbox and never adds one.
        case "notification-v2-update":
            JSONValue content = jcontent.type == JSONType.string
                ? parseJSON(jcontent.str) : *jcontent;

            // Two shapes seen in the wild: the changed fields wrapped in
            // `updates` next to the ID, or the whole object over again.
            JSONValue fields = content;
            if (content.type == JSONType.object)
                if (const(JSONValue)* v = "updates" in content)
                    if (v.type == JSONType.object)
                    {
                        // The wrapper holds the ID, the updates rarely do.
                        // Copied into a fresh object rather than written into
                        // `updates`: a JSONValue shares its members with the
                        // value it was copied from, so assigning there would
                        // reach back into the caller's message.
                        fields = JSONValue.emptyObject;
                        foreach (string key, const(JSONValue) member; v.object)
                            fields[key] = member;
                        if (const(JSONValue)* jid = "id" in content)
                            fields["id"] = *jid;
                    }

            added = parseNotificationV2Object(fields, fallbackSender);
            if (added.id.length == 0)
                return NotificationChange.none;
            return NotificationChange.updated;

        case "notification-v2-delete":
            JSONValue content = jcontent.type == JSONType.string
                ? parseJSON(jcontent.str) : *jcontent;

            if (const(JSONValue)* jids = "ids" in content)
            if (jids.type == JSONType.array)
            {
                foreach (JSONValue idVal; jids.array)
                {
                    if (idVal.type == JSONType.string)
                        removedIds ~= idVal.str;
                }
            }
            return removedIds.length ? NotificationChange.removed : NotificationChange.none;

        // Content is a plain string here: the notification ID itself.
        case "hide-notification":
        case "see-notification":
            if (jcontent.type != JSONType.string || jcontent.str.length == 0)
                return NotificationChange.none;
            removedIds = [ jcontent.str ];
            return NotificationChange.removed;

        case "response-notification":
            JSONValue content = jcontent.type == JSONType.string
                ? parseJSON(jcontent.str) : *jcontent;

            if (const(JSONValue)* v = "notificationId" in content)
                if (v.type == JSONType.string && v.str.length > 0)
                {
                    removedIds = [ v.str ];
                    return NotificationChange.removed;
                }
            return NotificationChange.none;

        default:
            return NotificationChange.none;
    }
    catch (JSONException)
    {
        // Malformed payload: the feed still shows the event, the inbox just
        // does not learn anything from it.
        return NotificationChange.none;
    }
}

/// Merge a `notification-v2-update` onto the entry already in the inbox.
///
/// Only what the update carried moves. VRChat sends partial objects and JSON
/// gives no way to tell "field absent" from "field empty", so an empty string
/// is read as absent: an update that blanks a title leaves the old one, which
/// is the harmless direction. `canDelete` is only ever taken away for the
/// same reason -- a dismiss button that fails is worse than a missing one.
void mergeNotificationUpdate(ref NotificationInfo target, ref NotificationInfo update)
{
    if (update.notificationType.length)
        target.notificationType = update.notificationType;
    if (update.senderUserId.length)
        target.senderUserId = update.senderUserId;
    if (update.senderName.length)
        target.senderName = update.senderName;
    if (update.title.length)
        target.title = update.title;
    if (update.message.length)
        target.message = update.message;
    if (update.location.length)
        target.location = update.location;
    if (update.receivedAtUnix)
        target.receivedAtUnix = update.receivedAtUnix;
    if (update.responses.length)
        target.responses = update.responses;
    if (update.canDelete == false)
        target.canDelete = false;
}

/// Encode one entry for the server's `notifications` message.
JSONValue buildNotificationJSON(ref NotificationInfo info)
{
    JSONValue[] responses;
    responses.reserve(info.responses.length);
    foreach (ref NotificationResponse response; info.responses)
    {
        responses ~= JSONValue([
            "type": JSONValue(response.type),
            "text": JSONValue(response.text),
            "icon": JSONValue(response.icon),
            "data": JSONValue(response.data),
        ]);
    }

    return JSONValue([
        "id":                JSONValue(info.id),
        "notification_type": JSONValue(info.notificationType),
        "sender_user_id":    JSONValue(info.senderUserId),
        "sender_name":       JSONValue(info.senderName),
        "title":             JSONValue(info.title),
        "message":           JSONValue(info.message),
        "location":          JSONValue(info.location),
        "received_at_unix":  JSONValue(info.receivedAtUnix),
        "responses":         JSONValue(responses),
        "can_delete":        JSONValue(info.canDelete),
        "api_version":       JSONValue(info.apiVersion),
    ]);
}

/// Decode a server `notifications` message back into entries. Order is left
/// as the server sent it (oldest first), since that is the order the inbox
/// draws in and re-sorting per client would only invite the two to disagree.
NotificationInfo[] parseNotificationsMessage(ref JSONValue msg)
{
    NotificationInfo[] list;

    const(JSONValue)* items = "notifications" in msg;
    if (items is null || items.type != JSONType.array)
        return list;

    list.reserve(items.array.length);
    foreach (const(JSONValue) item; items.array)
    {
        if (item.type != JSONType.object)
            continue;

        NotificationInfo info;
        if (const(JSONValue)* v = "id" in item)
            if (v.type == JSONType.string)
                info.id = v.str;
        if (info.id.length == 0)
            continue;

        if (const(JSONValue)* v = "notification_type" in item)
            if (v.type == JSONType.string)
                info.notificationType = v.str;
        if (const(JSONValue)* v = "sender_user_id" in item)
            if (v.type == JSONType.string)
                info.senderUserId = v.str;
        if (const(JSONValue)* v = "sender_name" in item)
            if (v.type == JSONType.string)
                info.senderName = v.str;
        if (const(JSONValue)* v = "title" in item)
            if (v.type == JSONType.string)
                info.title = v.str;
        if (const(JSONValue)* v = "message" in item)
            if (v.type == JSONType.string)
                info.message = v.str;
        if (const(JSONValue)* v = "location" in item)
            if (v.type == JSONType.string)
                info.location = v.str;
        if (const(JSONValue)* v = "received_at_unix" in item)
            if (v.type == JSONType.integer)
                info.receivedAtUnix = v.integer;
        if (const(JSONValue)* v = "can_delete" in item)
            info.canDelete = v.type != JSONType.false_;
        if (const(JSONValue)* v = "api_version" in item)
            if (v.type == JSONType.integer)
                info.apiVersion = cast(int)v.integer;

        if (const(JSONValue)* jresponses = "responses" in item)
        if (jresponses.type == JSONType.array)
        {
            foreach (const(JSONValue) entry; jresponses.array)
            {
                if (entry.type != JSONType.object)
                    continue;

                NotificationResponse response;
                if (const(JSONValue)* v = "type" in entry)
                    if (v.type == JSONType.string)
                        response.type = v.str;
                if (const(JSONValue)* v = "text" in entry)
                    if (v.type == JSONType.string)
                        response.text = v.str;
                if (const(JSONValue)* v = "icon" in entry)
                    if (v.type == JSONType.string)
                        response.icon = v.str;
                if (const(JSONValue)* v = "data" in entry)
                    if (v.type == JSONType.string)
                        response.data = v.str;

                if (response.type.length == 0)
                    continue;
                info.responses ~= response;
            }
        }

        list ~= info;
    }
    return list;
}

/// `details` as an object, whichever shape it arrived in. Returns a null
/// JSONValue when it is absent or does not decode.
private JSONValue decodeDetails(ref JSONValue content)
{
    const(JSONValue)* details = "details" in content;
    if (details is null)
        return JSONValue(null);

    if (details.type == JSONType.object)
        return *details;
    if (details.type != JSONType.string)
        return JSONValue(null);

    try return parseJSON(details.str);
    catch (JSONException)
        return JSONValue(null);
}

/// ISO 8601 to a UNIX timestamp, 0 when it does not parse.
private long parseTimestamp(string raw)
{
    if (raw.length == 0)
        return 0;

    try return SysTime.fromISOExtString(raw).toUnixTime!long();
    catch (Exception)
        return 0;
}

unittest
{
    // REST shape: details is a JSON-encoded string.
    JSONValue rest = parseJSON(`{"id":"not_1","type":"invite",` ~
        `"senderUserId":"usr_a","message":"",` ~
        `"details":"{\"worldName\":\"The Great Pug\",` ~
        `\"worldId\":\"wrld_x:123~region(eu)\"}",` ~
        `"created_at":"2026-07-27T18:00:00Z"}`);
    NotificationInfo info = parseNotificationObject(rest, "alice");
    assert(info.id == "not_1");
    assert(info.notificationType == "invite");
    assert(info.senderUserId == "usr_a");
    assert(info.senderName == "alice"); // No senderUsername, so the fallback.
    assert(info.message == "The Great Pug");
    assert(info.location == "wrld_x:123~region(eu)");
    assert(info.receivedAtUnix > 0);

    // WebSocket shape: details is an object, and the whole notification is
    // itself double-encoded inside the event.
    JSONValue event = parseJSON(`{"content":"{\"id\":\"not_2\",` ~
        `\"type\":\"friendRequest\",\"senderUserId\":\"usr_b\",` ~
        `\"senderUsername\":\"betty\",\"message\":\"\",\"details\":{}}"}`);
    NotificationInfo added = void;
    string[] removed;
    assert(applyNotificationEvent("notification", event, null,
        "2026-07-27T18:00:00Z", added, removed) == NotificationChange.added);
    assert(added.id == "not_2");
    assert(added.senderName == "betty");
    assert(added.receivedAtUnix > 0); // Taken from the event's own timestamp.

    // A v2 notification describes its own buttons, and a group puts its own
    // ID where a user ID would be.
    JSONValue invite = parseJSON(`{"content":{"id":"not_3",` ~
        `"type":"group.invite","senderUserId":"grp_a","title":"Group Invite",` ~
        `"message":"You were invited to Cool Group","canDelete":false,` ~
        `"createdAt":"2026-07-27T18:00:00Z","responses":[` ~
        `{"type":"accept","text":"Accept","icon":"check","data":""},` ~
        `{"type":"decline","text":"Decline","icon":"cancel","data":""},` ~
        `{"type":"link","text":"View Group","data":"group:grp_a"}]}}`);
    assert(applyNotificationEvent("notification-v2", invite, null, "",
        added, removed) == NotificationChange.added);
    assert(added.apiVersion == 2);
    assert(added.title == "Group Invite");
    assert(added.senderUserId == "grp_a");
    assert(added.canDelete == false);
    assert(added.responses.length == 2); // The link response is not drawable.
    assert(added.responses[0].type == "accept");
    assert(added.responses[0].text == "Accept");
    NotificationInfo groupInvite = added;

    // A type nobody wrote code for still lands in the inbox.
    JSONValue announcement = parseJSON(`{"content":{"id":"not_7",` ~
        `"type":"group.announcement","title":"Movie night","message":"8pm"}}`);
    assert(applyNotificationEvent("notification-v2", announcement, null, "",
        added, removed) == NotificationChange.added);
    assert(added.notificationType == "group.announcement");
    assert(added.responses.length == 0); // Nothing to answer, only a dismiss.
    assert(added.canDelete); // Absent `canDelete` means it can go.

    // An update carries only what moved, and merges onto the existing row.
    JSONValue update = parseJSON(`{"content":{"id":"not_3",` ~
        `"updates":{"message":"Invite expired","responses":[]}}}`);
    assert(applyNotificationEvent("notification-v2-update", update, null, "",
        added, removed) == NotificationChange.updated);
    assert(added.id == "not_3");
    mergeNotificationUpdate(groupInvite, added);
    assert(groupInvite.message == "Invite expired");
    assert(groupInvite.title == "Group Invite"); // Untouched by the update.

    // hide/see carry a bare ID string, not an object.
    JSONValue hide = parseJSON(`{"content":"not_1"}`);
    assert(applyNotificationEvent("hide-notification", hide, null, "",
        added, removed) == NotificationChange.removed);
    assert(removed == [ "not_1" ]);

    JSONValue del = parseJSON(`{"content":{"ids":["not_4","not_5"]}}`);
    assert(applyNotificationEvent("notification-v2-delete", del, null, "",
        added, removed) == NotificationChange.removed);
    assert(removed == [ "not_4", "not_5" ]);

    JSONValue response = parseJSON(`{"content":"{\"notificationId\":\"not_6\"}"}`);
    assert(applyNotificationEvent("response-notification", response, null, "",
        added, removed) == NotificationChange.removed);
    assert(removed == [ "not_6" ]);

    // Round trip through the server message shape.
    JSONValue message = JSONValue([
        "type": JSONValue("notifications"),
        "notifications": JSONValue([
            buildNotificationJSON(info), buildNotificationJSON(groupInvite),
        ]),
    ]);
    NotificationInfo[] back = parseNotificationsMessage(message);
    assert(back.length == 2);
    assert(back[0].id == "not_1");
    assert(back[0].message == "The Great Pug");
    assert(back[0].location == info.location);
    assert(back[0].receivedAtUnix == info.receivedAtUnix);
    assert(back[0].apiVersion == 1);
    assert(back[0].canDelete);
    assert(back[1].apiVersion == 2);
    assert(back[1].title == "Group Invite");
    assert(back[1].canDelete == false);
    assert(back[1].responses.length == 2);
    assert(back[1].responses[1].type == "decline");
    assert(back[1].responses[1].icon == "cancel");
}
