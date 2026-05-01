/// VRChat event types
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.events;

import std.json;
import std.datetime.systime : SysTime, Clock;

// NOTE: Could be generalize for other platforms

/// All known VRChat WebSocket event types.
enum EventType : string
{
    // Friend events
    friendOnline   = "friend-online",
    friendOffline  = "friend-offline",
    friendActive   = "friend-active",
    friendUpdate   = "friend-update",
    friendLocation = "friend-location",
    friendAdd      = "friend-add",
    friendDelete   = "friend-delete",

    // User events
    userUpdate          = "user-update",
    userLocation        = "user-location",
    userBadgeAssigned   = "user-badge-assigned",
    userBadgeUnassigned = "user-badge-unassigned",

    // Notification events
    notification         = "notification",
    notificationV2       = "notification-v2",
    notificationV2Delete = "notification-v2-delete",
    notificationV2Update = "notification-v2-update",
    seeNotification      = "see-notification",
    hideNotification     = "hide-notification",
    responseNotification = "response-notification",

    // Group events
    groupJoined       = "group-joined",
    groupLeft         = "group-left",
    groupRoleUpdated  = "group-role-updated",
    groupMemberUpdated = "group-member-updated",

    // Instance events
    instanceQueueJoined   = "instance-queue-joined",
    instanceQueuePosition = "instance-queue-position",
    instanceQueueReady    = "instance-queue-ready",
    instanceQueueLeft     = "instance-queue-left",
    instanceClosed        = "instance-closed",

    // Content events
    contentRefresh = "content-refresh",

    // Synthesized (not from VRChat; derived by the server from other events)
    avatarChange = "avatar-change",

    // Unknown
    unknown = "unknown",
}

/// A parsed VRChat WebSocket event.
struct VRCEvent
{
    EventType type;
    string typeRaw;       /// Original type string from the WebSocket message.
    JSONValue content;    /// Parsed content (double-decoded).
    SysTime receivedAt;   /// When we received this event.
    string rawJson;       /// Original raw JSON message for storage.
}

/// Parse a raw WebSocket message into a VRCEvent.
///
/// WebSocket messages are JSON with structure: {"type": "...", "content": "..."}
/// The content field is a JSON-encoded string that must be parsed separately.
VRCEvent parseEvent(const(char)[] rawMessage)
{
    VRCEvent event;
    event.receivedAt = Clock.currTime();
    // TODO: Confirm why .idup is used here
    //       We could also transform `string rawJson` into `JSONValue rawJSON`,
    //       assuming it is valid, and keep `JSONValue content` as stub/full.
    //       This would also trim off newlines/whitespace with for DB using .toString().
    event.rawJson = rawMessage.idup;

    JSONValue json = parseJSON(rawMessage);

    // Extract type.
    if (const(JSONValue)* v = "type" in json)
        event.typeRaw = v.str;
    event.type = toEventType(event.typeRaw);

    // Extract and double-decode content.
    if ("content" in json)
    {
        JSONValue contentVal = json["content"];
        if (contentVal.type == JSONType.string)
        {
            // Content is a JSON-encoded string,  parse it.
            try
                event.content = parseJSON(contentVal.str);
            catch (Exception)
                event.content = contentVal; // Fall back to raw string.
        }
        else
        {
            event.content = contentVal;
        }
    }

    return event;
}

/// Convert a type string to the EventType enum.
EventType toEventType(string typeStr)
{
    // Try to match against known event types.
    static foreach (member; __traits(allMembers, EventType))
    {
        if (typeStr == __traits(getMember, EventType, member))
            return __traits(getMember, EventType, member);
    }
    return EventType.unknown;
}

