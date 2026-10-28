/// VRChat groups as vrcd-server hands them out: the user's list and one
/// group's page. Shapes follow `server.groups`.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module client.groups;

import std.json;

import client.profiles : CacheOf, LookupOf;

/// One group in the user's list (`groups` message).
struct GroupEntry
{
    string id;            /// grp_...
    string name;          /// Display name
    string shortCode;     /// Code shown before the discriminator
    string discriminator; /// Digits after the short code
    string iconFileId;    /// Icon file for the image proxy, or empty
    long iconVersion;     /// Icon file version
    long memberCount;     /// Members at last fetch
    bool isRepresenting;  /// Worn on the user's nameplate
    string visibility;    /// visible, friends or hidden
    string ownerId;       /// usr_... of the owner
}

/// One group's page (`group` message).
struct GroupProfile
{
    string id;
    string name;
    string shortCode;
    string discriminator;
    string description;
    string rules;
    string[] links;
    string[] languages;
    string iconFileId;
    long iconVersion;
    long memberCount;
    long onlineMemberCount;
    string privacy;          /// default or private
    string joinState;        /// open, request, invite or closed
    bool isVerified;
    string ownerId;
    string createdAt;
    string membershipStatus; /// member, requested, invited, inactive, ...
    /// Set when VRChat sent a membership, which carries the fields below.
    bool hasMember;
    bool isRepresenting;
    bool isSubscribedToAnnouncements;
    string visibility;
    string joinedAt;
    string[] roles;          /// Role names
}

/// A member-side group action queued by the UI, drained by gui.d.
struct GroupAction
{
    string groupId;
    string action; /// represent, unrepresent, subscribe, unsubscribe, visibility, join, cancel_request, leave
    string value;  /// Visibility for `visibility`
}

/// Cache of fetched group pages, keyed by group ID.
alias GroupCache = CacheOf!GroupProfile;
/// ditto
alias GroupLookup = LookupOf!GroupProfile;

/// "CODE.1234", or empty when VRChat gave no short code.
string groupCode(string shortCode, string discriminator)
{
    if (shortCode.length == 0)
        return null;
    return discriminator.length > 0 ? shortCode ~ "." ~ discriminator : shortCode;
}

/// String field of an object, or null.
private string text(ref const(JSONValue) obj, string field)
{
    if (obj.type != JSONType.object)
        return null;
    if (const(JSONValue)* v = field in obj)
        if (v.type == JSONType.string)
            return v.str;
    return null;
}

/// Integer field of an object, or 0.
private long number(ref const(JSONValue) obj, string field)
{
    if (obj.type != JSONType.object)
        return 0;
    if (const(JSONValue)* v = field in obj)
    {
        if (v.type == JSONType.integer)
            return v.integer;
        if (v.type == JSONType.uinteger)
            return cast(long)v.uinteger;
    }
    return 0;
}

/// Boolean field of an object, or false.
private bool flag(ref const(JSONValue) obj, string field)
{
    if (obj.type != JSONType.object)
        return false;
    if (const(JSONValue)* v = field in obj)
        return v.type == JSONType.true_;
    return false;
}

/// String array field of an object.
private string[] strings(ref const(JSONValue) obj, string field)
{
    string[] list;
    if (obj.type != JSONType.object)
        return list;
    if (const(JSONValue)* v = field in obj)
    {
        if (v.type == JSONType.array)
            foreach (const(JSONValue) item; v.array)
            {
                if (item.type == JSONType.string && item.str.length > 0)
                    list ~= item.str;
            }
    }
    return list;
}

/// Parse one `groups` list element.
GroupEntry parseGroupEntry(ref const(JSONValue) j)
{
    GroupEntry e;
    e.id             = text(j, "id");
    e.name           = text(j, "name");
    e.shortCode      = text(j, "shortCode");
    e.discriminator  = text(j, "discriminator");
    e.iconFileId     = text(j, "iconFileId");
    e.iconVersion    = number(j, "iconVersion");
    e.memberCount    = number(j, "memberCount");
    e.isRepresenting = flag(j, "isRepresenting");
    e.visibility     = text(j, "visibility");
    e.ownerId        = text(j, "ownerId");
    return e;
}

/// Parse a `group` payload.
GroupProfile parseGroupProfile(ref const(JSONValue) j)
{
    GroupProfile p;
    p.id                = text(j, "id");
    p.name              = text(j, "name");
    p.shortCode         = text(j, "shortCode");
    p.discriminator     = text(j, "discriminator");
    p.description       = text(j, "description");
    p.rules             = text(j, "rules");
    p.links             = strings(j, "links");
    p.languages         = strings(j, "languages");
    p.iconFileId        = text(j, "iconFileId");
    p.iconVersion       = number(j, "iconVersion");
    p.memberCount       = number(j, "memberCount");
    p.onlineMemberCount = number(j, "onlineMemberCount");
    p.privacy           = text(j, "privacy");
    p.joinState         = text(j, "joinState");
    p.isVerified        = flag(j, "isVerified");
    p.ownerId           = text(j, "ownerId");
    p.createdAt         = text(j, "createdAt");
    p.membershipStatus  = text(j, "membershipStatus");

    if (j.type == JSONType.object)
    {
        if (const(JSONValue)* m = "myMember" in j)
        {
            if (m.type == JSONType.object)
            {
                p.hasMember = true;
                p.isRepresenting = flag(*m, "isRepresenting");
                p.isSubscribedToAnnouncements = flag(*m, "isSubscribedToAnnouncements");
                p.visibility = text(*m, "visibility");
                p.joinedAt = text(*m, "joinedAt");
                p.roles = strings(*m, "roles");
            }
        }
    }
    return p;
}

unittest
{
    JSONValue list = parseJSON(`{"id":"grp_a","name":"A","shortCode":"AA",
        "discriminator":"0001","iconFileId":"file_x","iconVersion":2,
        "memberCount":5,"isRepresenting":true,"visibility":"friends"}`);
    GroupEntry e = parseGroupEntry(list);
    assert(e.id == "grp_a" && e.iconVersion == 2 && e.isRepresenting);
    assert(groupCode(e.shortCode, e.discriminator) == "AA.0001");
    assert(groupCode("", "0001").length == 0);

    JSONValue pane = parseJSON(`{"id":"grp_a","name":"A","joinState":"request",
        "links":["https://x",""],"membershipStatus":"member",
        "myMember":{"isRepresenting":false,"isSubscribedToAnnouncements":true,
                    "visibility":"visible","roles":["Mod"]}}`);
    GroupProfile p = parseGroupProfile(pane);
    assert(p.hasMember && p.isSubscribedToAnnouncements);
    assert(p.links.length == 1 && p.roles == ["Mod"]);

    JSONValue stranger = parseJSON(`{"id":"grp_b","name":"B"}`);
    assert(parseGroupProfile(stranger).hasMember == false);
}
