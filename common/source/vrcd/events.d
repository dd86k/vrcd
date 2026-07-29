/// Feed event presentation shared by the SDL client and the web front-end.
///
/// Event labelling and the user/detail extraction below decide how a raw
/// VRChat event reads in a feed. Both front-ends show the same feed, so this
/// lives here rather than being written once per UI.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module vrcd.events;

import std.json;

/// Metadata for one feed event type: the human-readable label shown in
/// the UI, the raw event-type strings that map to it (one label can
/// collapse multiple wire types,  e.g. "Notification" covers both
/// "notification" and "notification-v2"), and whether the filter
/// toggle starts on or off by default.
struct FeedEventType
{
    string label;
    immutable(string)[] rawTypes;
    bool defaultVisible;
}

/// Single source of truth for feed event types.
///
/// Position in this array is the persistence index for feedEventVisible
/// in Settings and AppState. New entries MUST be appended at the end:
/// saved settings reference these positions by index, so reordering
/// would silently flip filters for users with existing config.
immutable FeedEventType[] feedEventTypes = [
    // VRChat WS, friends
    FeedEventType("Online",            ["friend-online"],                                 true),
    FeedEventType("Offline",           ["friend-offline"],                                true),
    FeedEventType("Active",            ["friend-active"],                                 true),
    FeedEventType("Friend Add",        ["friend-add"],                                    true),
    FeedEventType("Friend Remove",     ["friend-delete"],                                 true),
    FeedEventType("Friend Update",     ["friend-update"],                                 true),
    FeedEventType("Friend Location",   ["friend-location"],                               true),
    // VRChat WS, self
    FeedEventType("Update",            ["user-update"],                                   true),
    FeedEventType("Location",          ["user-location"],                                 true),
    // VRChat WS, notifications
    FeedEventType("Notification",      ["notification", "notification-v2"],               true),
    FeedEventType("Notif Delete",      ["notification-v2-delete"],                        true),
    FeedEventType("Notif Update",      ["notification-v2-update"],                        true),
    // VRChat WS, groups
    FeedEventType("Group Joined",      ["group-joined"],                                  true),
    FeedEventType("Group Left",        ["group-left"],                                    true),
    FeedEventType("Group Role",        ["group-role-updated"],                            true),
    FeedEventType("Group Member",      ["group-member-updated"],                          true),
    // VRChat WS, misc
    FeedEventType("Content Refresh",   ["content-refresh"],                               true),
    FeedEventType("Queue Position",    ["instance-queue-position"],                       true),
    // Local logs
    FeedEventType("Player Joining",    ["player-joining"],                                true),
    FeedEventType("Player Joined",     ["player-joined"],                                 true),
    FeedEventType("Player Left",       ["player-left"],                                   true),
    // Synthetic
    FeedEventType("Avatar Change",     ["avatar-change"],                                 true),
    // Appended (keep order to preserve persistence indices)
    FeedEventType("Friend Traveling",  ["friend-traveling"],                              false),
    FeedEventType("Profile Change",    ["profile-change"],                                true),
    FeedEventType("Badge Assigned",    ["user-badge-assigned"],                           true),
    FeedEventType("Badge Unassigned",  ["user-badge-unassigned"],                         true),
    FeedEventType("Notif Seen",        ["see-notification"],                              true),
    FeedEventType("Notif Hidden",      ["hide-notification"],                             true),
    FeedEventType("Notif Response",    ["response-notification"],                         true),
    FeedEventType("Queue Joined",      ["instance-queue-joined"],                         true),
    FeedEventType("Queue Ready",       ["instance-queue-ready"],                          true),
    FeedEventType("Queue Left",        ["instance-queue-left"],                           true),
    FeedEventType("Instance Closed",   ["instance-closed"],                               true),
    FeedEventType("Photo Taken",       ["photo-taken"],                                   true),
    FeedEventType("URL Video",         ["url-video"],                                     true),
    FeedEventType("URL String",        ["url-string"],                                    true),
    FeedEventType("URL Image",         ["url-image"],                                     true),
    FeedEventType("DAP Pairing",       ["dap-pair-start", "dap-pair-code", "dap-paired"], true),
    FeedEventType("DAP",               ["dap-login-ok", "dap-started"],                   true),
    FeedEventType("DAP Error",         ["dap-error", "dap-login-error"],                  true),
    FeedEventType("System",            ["system"],                                        true),
    FeedEventType("Error",             ["error"],                                         true),
];

/// Display labels, derived from feedEventTypes. Kept as a separate symbol
/// so existing code (settings persistence, UI rendering) keeps reading
/// labels by index without churn.
immutable string[] feedEventLabels = () {
    string[feedEventTypes.length] r;
    foreach (size_t i, ref t; feedEventTypes)
        r[i] = t.label;
    return r[].idup;
}();

/// Default visibility, derived from feedEventTypes.
immutable bool[feedEventTypes.length] feedEventDefaultVisible = () {
    bool[feedEventTypes.length] r;
    foreach (size_t i, ref t; feedEventTypes)
        r[i] = t.defaultVisible;
    return r;
}();

/// Look up a raw event type's index in feedEventTypes. Returns size_t.max
/// when the raw type is unrecognized (e.g. a new VRChat event we haven't
/// added,  the entry will still display in the feed but won't be filterable).
size_t feedEventIndex(string rawType)
{
    foreach (size_t i, ref t; feedEventTypes)
        foreach (string raw; t.rawTypes)
            if (raw == rawType)
                return i;
    return size_t.max;
}

void extractEventFields(string eventType, JSONValue msg, out string user, out string detail)
{
    if ("content" !in msg)
        return;

    try
    {
        JSONValue c = msg["content"];
        if (c.type == JSONType.string)
            c = parseJSON(c.str);

        if (const(JSONValue)* v = "displayName" in c)
            user = v.str;

        // Most events nest the user info inside a "user" sub-object.
        if (user.length == 0)
            if (const(JSONValue)* v = "user" in c)
                if (v.type == JSONType.object)
                    if (const(JSONValue)* dn = "displayName" in *v)
                        user = dn.str;
        
        switch (eventType)
        {
            case "friend-online":
                if (const(JSONValue)* v = "platform" in c)
                    if (v.str.length > 0)
                        detail = prettyPlatform(v.str);
                return;

            case "friend-active":
                if (const(JSONValue)* v = "platform" in c)
                    if (v.str.length > 0)
                        detail = prettyPlatform(v.str);
                return;

            case "friend-offline":
                if (const(JSONValue)* v = "platform" in c)
                    if (v.str.length > 0)
                        detail = prettyPlatform(v.str);
                return;

            case "friend-add":
            case "friend-delete":
                return;

            case "friend-update":
                // Status fields are nested inside the "user" sub-object.
                if (const(JSONValue)* userObj = "user" in c)
                if (userObj.type == JSONType.object)
                {
                    if (const(JSONValue)* v = "status" in *userObj)
                        if (v.str.length > 0)
                            detail = v.str;
                }
                return;

            case "friend-location":
            case "user-location":
                string worldName;
                if (const(JSONValue)* v = "worldName" in c)
                    worldName = v.str;
                if (worldName.length == 0)
                    if (const(JSONValue)* v = "world" in c)
                        if (v.type == JSONType.object)
                            if (const(JSONValue)* wn = "name" in *v)
                                worldName = wn.str;
                if (worldName.length > 0)
                    detail = worldName;
                else
                {
                    string loc;
                    if (const(JSONValue)* v = "location" in c)
                        loc = v.str;
                    if (loc == "private")
                        detail = "Private World";
                    else if (loc == "offline" || loc.length == 0)
                        detail = "Offline";
                    else
                        detail = loc;
                }
                return;

            case "user-update":
                if (const(JSONValue)* v = "statusDescription" in c)
                    if (v.str.length > 0)
                        detail = v.str;
                return;

            case "notification":
            case "notification-v2":
                if (const(JSONValue)* v = "senderUsername" in c)
                    if (v.str.length > 0)
                        user = v.str;
                if (const(JSONValue)* v = "type" in c)
                    if (v.str.length > 0)
                        detail = prettyNotifType(v.str);
                return;

            case "notification-v2-delete":
            case "notification-v2-update":
            case "see-notification":
            case "hide-notification":
            case "response-notification":
                if (const(JSONValue)* v = "type" in c)
                    if (v.str.length > 0)
                        detail = prettyNotifType(v.str);
                return;

            case "group-joined":
            case "group-left":
            case "group-role-updated":
            case "group-member-updated":
                if (const(JSONValue)* v = "groupName" in c)
                    if (v.str.length > 0)
                        detail = v.str;
                return;

            case "instance-queue-position":
                if (const(JSONValue)* v = "position" in c)
                    if (v.str.length > 0)
                        detail = "Position " ~ v.str;
                return;

            case "instance-queue-joined":
            case "instance-queue-ready":
            case "instance-queue-left":
            case "instance-closed":
                if (const(JSONValue)* v = "instanceId" in c)
                    if (v.str.length > 0)
                        detail = v.str;
                return;

            case "avatar-change":
                // For self events this is an avtr_<uuid>; for friends VRChat
                // only exposes the image URL, so extract the file_<uuid>
                // segment as the most compact stable handle.
                if (const(JSONValue)* v = "currentAvatar" in c)
                    if (v.str.length > 0)
                        detail = shortAvatarId(v.str);
                return;

            case "profile-change":
                // Synthetic carries previous*/current* pairs for whichever
                // subfields changed. Surface the field names in display order
                // so the feed reads "bio" / "bio, pronouns" / etc.
                string[] fields;
                if ("currentBio" in c)       fields ~= "bio";
                if ("currentPronouns" in c)  fields ~= "pronouns";
                if ("currentBioLinks" in c)  fields ~= "bioLinks";
                if (fields.length > 0)
                {
                    import std.array : join;
                    detail = fields.join(", ");
                }
                return;

            case "content-refresh":
                if (const(JSONValue)* v = "contentType" in c)
                    if (v.str.length > 0)
                        detail = v.str;
                return;

            default:
                break;
        }
    }
    catch (Exception) {}
}

/// Human-readable platform name.
string prettyPlatform(string platform)
{
    switch (platform)
    {
        case "standalonewindows": return "PC";
        case "android":          return "Quest";
        case "ios":              return "iOS";
        case "nativemobile":     return "Mobile";
        case "web":              return "Website";
        default:                 return platform;
    }
}

/// Human-readable notification type.
///
/// The dotted names are v2 notifications. Unknown types fall through as-is:
/// VRChat adds them faster than this list can be maintained, and a raw
/// "group.somethingNew" still tells the reader what it is about.
string prettyNotifType(string notifType)
{
    switch (notifType)
    {
        case "invite":                    return "Invite";
        case "requestInvite":             return "Request Invite";
        case "requestInviteResponse":     return "Invite Response";
        case "inviteResponse":            return "Invite Response";
        case "friendRequest":             return "Friend Request";
        case "votetokick":                return "Vote to Kick";
        case "boop":                      return "Boop";
        case "message":                   return "Message";
        case "groupChange":               return "Group Change";
        case "group.announcement":        return "Group Announcement";
        case "group.informative":         return "Group Notice";
        case "group.invite":              return "Group Invite";
        case "group.joinRequest":         return "Group Join Request";
        case "group.transfer":            return "Group Transfer";
        case "group.queueReady":          return "Queue Ready";
        case "instance.closed":           return "Instance Closed";
        default:                          return notifType;
    }
}

/// Reduce a `currentAvatar` value to a compact identifier. Self events carry
/// an `avtr_<uuid>` directly; friend events expose only an image URL like
/// `https://api.vrchat.cloud/api/1/file/file_<uuid>/<ver>/file`, in which the
/// `file_<uuid>` segment is the most stable handle we can show.
string shortAvatarId(string s)
{
    import std.string : indexOf;

    ptrdiff_t i = s.indexOf("avtr_");
    if (i >= 0)
        return s[i .. $];

    i = s.indexOf("file_");
    if (i >= 0)
    {
        string rest = s[i .. $];
        ptrdiff_t slash = rest.indexOf('/');
        return slash >= 0 ? rest[0 .. slash] : rest;
    }

    return s;
}

unittest
{
    // Labels collapse several wire types onto one index.
    assert(feedEventIndex("notification") == feedEventIndex("notification-v2"));
    assert(feedEventIndex("not-a-real-event") == size_t.max);
    assert(feedEventLabels[feedEventIndex("friend-online")] == "Online");

    // friend-location prefers the resolved world name over the raw location.
    JSONValue msg = parseJSON(`{"event_type":"friend-location","content":` ~
        `{"user":{"displayName":"alice"},"worldName":"The Great Pug",` ~
        `"location":"wrld_a:1"}}`);
    string user, detail;
    extractEventFields("friend-location", msg, user, detail);
    assert(user == "alice");
    assert(detail == "The Great Pug");

    // Without a world name, "private" reads as a phrase rather than a token.
    msg = parseJSON(`{"event_type":"friend-location","content":` ~
        `{"displayName":"betty","location":"private"}}`);
    extractEventFields("friend-location", msg, user, detail);
    assert(user == "betty");
    assert(detail == "Private World");

    // Friend avatar changes only expose an image URL.
    assert(shortAvatarId(
        "https://api.vrchat.cloud/api/1/file/file_abc/1/file") == "file_abc");
    assert(shortAvatarId("avtr_xyz") == "avtr_xyz");
}
