/// Notification model shared by vrcd-server and both front-ends.
///
/// VRChat hands the same notification out twice in two shapes: once as a REST
/// object from `auth/user/notifications` (where `details` is a JSON-*encoded*
/// string) and once as a WebSocket `notification` event (where `details` is a
/// real object). Both reduce to the same handful of fields, so the decoding
/// lives here and every consumer sees a NotificationInfo.
///
/// The server normalizes its REST listing through this module and sends the
/// result as a `notifications` message; the front-ends parse that message and
/// then keep the list current from the WebSocket events, which arrive faster
/// than a refetch would and cost no API call.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module vrcd.notifications;

import std.datetime : SysTime;
import std.json;

/// Notification types the inbox can act on. Anything else (badges, boops,
/// group announcements) is feed material: it shows up as an event, but there
/// is no Accept button to draw for it, so keeping it out of the inbox keeps
/// the list to things that are actually waiting on the user.
immutable string[] actionableNotifTypes = [
    "friendRequest", "invite", "requestInvite",
];

/// Whether a notification type belongs in the inbox.
bool isActionableNotification(string notificationType)
{
    foreach (string t; actionableNotifTypes)
    {
        if (t == notificationType)
            return true;
    }
    return false;
}

/// One inbox notification, normalized out of either wire shape.
struct NotificationInfo
{
    /// VRChat notification ID ("not_..."). Empty when the object was
    /// unusable, which is how callers test for a failed parse.
    string id;
    /// "friendRequest", "invite", or "requestInvite".
    string notificationType;
    /// Sender's user ID, when VRChat included one.
    string senderUserId;
    /// Best-known sender name. VRChat deprecated `senderUsername` and no
    /// longer returns it for other users, so this is often filled in by the
    /// caller from a friend roster instead.
    string senderName;
    /// Message body, or the world name for an invite that carries no text.
    string message;
    /// Instance an invite points at, empty for every other type. Carrying it
    /// is what lets the inbox offer a join rather than just an acknowledgement.
    string location;
    /// Creation time as a UNIX timestamp, 0 when VRChat gave none or it did
    /// not parse. Ordering falls back to arrival order when this is 0.
    long receivedAtUnix;
}

/// What a WebSocket notification event did to the inbox.
enum NotificationChange
{
    /// Not a notification event, or one that changes nothing (an
    /// unactionable type, a malformed payload).
    none,
    /// One notification arrived.
    added,
    /// One or more notifications are gone.
    removed,
}

/// Decode a notification object into the normalized form. Accepts both wire
/// shapes: `details` may be an object (WebSocket) or a JSON-encoded string
/// (REST). Returns an entry with an empty `id` when the object is not an
/// actionable notification.
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

    if (id.length == 0 || isActionableNotification(notifType) == false)
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

/// Apply one WebSocket event to the inbox.
///
/// Params:
///   eventType = Raw VRChat event type.
///   msg = The event message, whose "content" holds the payload.
///   fallbackSender = Sender name to use when the payload carries none.
///   rawReceivedAt = The event's own ISO 8601 timestamp, used when the
///                   notification object carries no `created_at`.
///   added = Filled in when the return is `added`.
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
        case "notification-v2":
            JSONValue content = jcontent.type == JSONType.string
                ? parseJSON(jcontent.str) : *jcontent;

            added = parseNotificationObject(content, fallbackSender);
            if (added.id.length == 0)
                return NotificationChange.none;
            if (added.receivedAtUnix == 0)
                added.receivedAtUnix = parseTimestamp(rawReceivedAt);
            return NotificationChange.added;

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

/// Encode one entry for the server's `notifications` message.
JSONValue buildNotificationJSON(ref NotificationInfo info)
{
    return JSONValue([
        "id":                JSONValue(info.id),
        "notification_type": JSONValue(info.notificationType),
        "sender_user_id":    JSONValue(info.senderUserId),
        "sender_name":       JSONValue(info.senderName),
        "message":           JSONValue(info.message),
        "location":          JSONValue(info.location),
        "received_at_unix":  JSONValue(info.receivedAtUnix),
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
        if (const(JSONValue)* v = "message" in item)
            if (v.type == JSONType.string)
                info.message = v.str;
        if (const(JSONValue)* v = "location" in item)
            if (v.type == JSONType.string)
                info.location = v.str;
        if (const(JSONValue)* v = "received_at_unix" in item)
            if (v.type == JSONType.integer)
                info.receivedAtUnix = v.integer;

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

    // Unactionable types stay out of the inbox.
    JSONValue boop = parseJSON(`{"content":{"id":"not_3","type":"boop"}}`);
    assert(applyNotificationEvent("notification-v2", boop, null, "",
        added, removed) == NotificationChange.none);

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
        "notifications": JSONValue([ buildNotificationJSON(info) ]),
    ]);
    NotificationInfo[] back = parseNotificationsMessage(message);
    assert(back.length == 1);
    assert(back[0].id == "not_1");
    assert(back[0].message == "The Great Pug");
    assert(back[0].location == info.location);
    assert(back[0].receivedAtUnix == info.receivedAtUnix);
}
