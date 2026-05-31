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
    avatarChange    = "avatar-change",
    profileChange   = "profile-change",
    friendTraveling = "friend-traveling",

    // Unknown
    unknown = "unknown",
}

// NOTE: Events
//       Right now, the VRC event is softly "parsed" into a content field containing everything,
//       but I need to confirm what consists of what it is using.
//       It does contain a little too much of everything. Eventually, it'd be lighter on
//       transmitting just the required details, which then could be a simple text field.
//       Which means, there are no dedicated Event struct with just the necessary detail.

/// A parsed VRChat WebSocket event.
struct VRCEvent
{
    EventType type;
    string typeRaw;       /// Original type string from the WebSocket message.
    JSONValue content;    /// Parsed content (double-decoded).
    SysTime receivedAt;   /// When we received this event.
    string rawJson;       /// Original raw JSON message for storage.
}

/// True for raw event types that VRChat re-emits constantly and that the
/// tracker may turn into a synthetic (avatar-change, profile-change). When
/// a synthetic is produced from one of these, the raw event is dropped: it
/// carries no new information beyond what the synthetic plus prior state
/// already convey. Other triggers (e.g. friend-online, friend-active) remain
/// meaningful on their own and are not suppressed.
bool isAvatarNoiseEvent(EventType type)
{
    switch (type)
    {
        case EventType.friendLocation:
        case EventType.friendUpdate:
        case EventType.userUpdate:
        case EventType.userLocation:
            return true;
        default:
            return false;
    }
}

/// Obtain content out of a raw VRChat WS message.
///
/// WebSocket messages are JSON with structure: {"type": "...", "content": "..."}
/// The content field is a JSON-encoded string that must be parsed separately.
///
/// This function exists to allow re-"parsing" of old raw messages.
JSONValue vrcContent(const(char)[] rawVrcMessage)
{
    JSONValue json = parseJSON(rawVrcMessage);
    
    JSONValue content;

    // Extract and double-decode content.
    if (const(JSONValue) *jcontent = "content" in json)
    {
        //JSONValue contentVal = json["content"];
        if (jcontent.type == JSONType.string)
        {
            // Content is a JSON-encoded string,  parse it.
            try content = parseJSON(jcontent.str);
            catch (Exception) content = *jcontent; // Fall back to raw string.
        }
        else
        {
            content = *jcontent;
        }
    }
    // else: No content available
    
    return content;
}
unittest
{
    JSONValue content = vrcContent(
`{
    "content": "{\"userId\":\"usr_afafafaf-afaf-afaf-afaf-afafafafafaf\"}}",
    "type": "user-location"
}`
    );
    
    assert(content["userId"].str == "usr_afafafaf-afaf-afaf-afaf-afafafafafaf");
}

/// Parse a NEW raw WebSocket message into a VRCEvent.
///
/// WebSocket messages are JSON with structure: {"type": "...", "content": "..."}
/// The content field is a JSON-encoded string that must be parsed separately.
VRCEvent parseNewVrcEvent(const(char)[] rawMessage)
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
    if (const(JSONValue) *jcontent = "content" in json)
    {
        //JSONValue contentVal = json["content"];
        if (jcontent.type == JSONType.string)
        {
            // Content is a JSON-encoded string,  parse it.
            try
                event.content = parseJSON(jcontent.str);
            catch (Exception)
                event.content = *jcontent; // Fall back to raw string.
        }
        else
        {
            event.content = *jcontent;
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

