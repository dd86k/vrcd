/// VRChat groups the logged-in user belongs to, and the group pane payload.
///
/// The list is fetched on a front-end's first `get_groups`, then kept current
/// from `group-joined`, `group-left` and `group-member-updated` and from our own
/// actions. Only member-side state is held here: no roles, bans or audit logs.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.groups;

import core.sync.mutex : Mutex;

import std.algorithm.sorting : sort;
import std.json;
import std.string : startsWith;
import std.uni : icmp;

import server.userimage : UserImage, parseImageURL;

/// Visibility values VRChat takes for a membership.
immutable string[] groupVisibilities = [ "visible", "friends", "hidden" ];

/// Whether this is a group ID safe to put in a URL path.
bool isGroupId(string value)
{
    import std.ascii : isAlphaNum;

    if (value.length < 5 || value.length > 64 || startsWith(value, "grp_") == false)
        return false;

    foreach (char c; value)
    {
        if (isAlphaNum(c) == false && c != '-' && c != '_')
            return false;
    }
    return true;
}

/// String field of a JSON object, or null.
private string text(ref const(JSONValue) obj, string field)
{
    if (obj.type != JSONType.object)
        return null;
    if (const(JSONValue)* v = field in obj)
        if (v.type == JSONType.string)
            return v.str;
    return null;
}

/// Boolean field of a JSON object, or `fallback` when missing.
private bool flag(ref const(JSONValue) obj, string field, bool fallback = false)
{
    if (obj.type != JSONType.object)
        return fallback;
    if (const(JSONValue)* v = field in obj)
    {
        if (v.type == JSONType.true_)
            return true;
        if (v.type == JSONType.false_)
            return false;
    }
    return fallback;
}

/// Integer field of a JSON object, or 0.
private long number(ref const(JSONValue) obj, string field)
{
    if (obj.type != JSONType.object)
        return 0;
    if (const(JSONValue)* v = field in obj)
    {
        switch (v.type)
        {
            case JSONType.integer:  return v.integer;
            case JSONType.uinteger: return cast(long)v.uinteger;
            case JSONType.float_:   return cast(long)v.floating;
            default:
        }
    }
    return 0;
}

/// String array field of a JSON object, empty strings dropped.
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

/// Set `<prefix>FileId` and `<prefix>Version` from a VRChat image URL field.
private void putImage(ref JSONValue into, string prefix, ref const(JSONValue) obj, string field)
{
    UserImage image = parseImageURL(text(obj, field));
    into[prefix ~ "FileId"] = JSONValue(image.fileId);
    into[prefix ~ "Version"] = JSONValue(image.fileVersion);
}

/// One group in the user's list.
struct GroupEntry
{
    string id;           /// grp_...
    string name;         /// Display name
    string shortCode;    /// Code shown before the discriminator
    string discriminator; /// Digits after the short code
    string iconUrl;      /// VRChat icon URL
    string bannerUrl;    /// VRChat banner URL
    long memberCount;    /// Members at last fetch
    bool isRepresenting; /// Worn on the user's nameplate
    string visibility;   /// visible, friends or hidden
    string privacy;      /// default or private
    string ownerId;      /// usr_... of the owner

    /// Entry as sent in the `groups` message.
    JSONValue toJSON() const
    {
        JSONValue j = JSONValue([
            "id":             JSONValue(id),
            "name":           JSONValue(name),
            "shortCode":      JSONValue(shortCode),
            "discriminator":  JSONValue(discriminator),
            "memberCount":    JSONValue(memberCount),
            "isRepresenting": JSONValue(isRepresenting),
            "visibility":     JSONValue(visibility),
            "privacy":        JSONValue(privacy),
            "ownerId":        JSONValue(ownerId),
        ]);
        UserImage icon = parseImageURL(iconUrl);
        UserImage banner = parseImageURL(bannerUrl);
        j["iconFileId"] = JSONValue(icon.fileId);
        j["iconVersion"] = JSONValue(icon.fileVersion);
        j["bannerFileId"] = JSONValue(banner.fileId);
        j["bannerVersion"] = JSONValue(banner.fileVersion);
        return j;
    }
}

/// Entry from a `GET /users/{id}/groups` element, or one with an empty ID.
GroupEntry entryFromUserGroup(ref const(JSONValue) g)
{
    GroupEntry e;
    // `id` here is the membership (gmem_), the group is `groupId`.
    e.id            = text(g, "groupId");
    e.name          = text(g, "name");
    e.shortCode     = text(g, "shortCode");
    e.discriminator = text(g, "discriminator");
    e.iconUrl       = text(g, "iconUrl");
    e.bannerUrl     = text(g, "bannerUrl");
    e.memberCount   = number(g, "memberCount");
    e.isRepresenting = flag(g, "isRepresenting");
    e.visibility    = text(g, "memberVisibility");
    e.privacy       = text(g, "privacy");
    e.ownerId       = text(g, "ownerId");
    return e;
}

/// Entry from a full `GET /groups/{id}` object, or one with an empty ID.
GroupEntry entryFromGroup(ref const(JSONValue) g)
{
    GroupEntry e;
    e.id            = text(g, "id");
    e.name          = text(g, "name");
    e.shortCode     = text(g, "shortCode");
    e.discriminator = text(g, "discriminator");
    e.iconUrl       = text(g, "iconUrl");
    e.bannerUrl     = text(g, "bannerUrl");
    e.memberCount   = number(g, "memberCount");
    e.privacy       = text(g, "privacy");
    e.ownerId       = text(g, "ownerId");
    if (const(JSONValue)* m = "myMember" in g)
    {
        e.isRepresenting = flag(*m, "isRepresenting");
        e.visibility     = text(*m, "visibility");
    }
    return e;
}

/// Whether a full group object says the user is a member.
bool isMemberOf(ref const(JSONValue) g)
{
    if (text(g, "membershipStatus") == "member")
        return true;
    if (const(JSONValue)* m = "myMember" in g)
        return text(*m, "membershipStatus") == "member";
    return false;
}

/// Build the `group` pane payload from `GET /groups/{id}?includeRoles=true`.
JSONValue buildGroupProfile(ref const(JSONValue) g)
{
    JSONValue p = JSONValue.emptyObject;
    if (g.type != JSONType.object)
        return p;

    p["id"]                = JSONValue(text(g, "id"));
    p["name"]              = JSONValue(text(g, "name"));
    p["shortCode"]         = JSONValue(text(g, "shortCode"));
    p["discriminator"]     = JSONValue(text(g, "discriminator"));
    p["description"]       = JSONValue(text(g, "description"));
    p["rules"]             = JSONValue(text(g, "rules"));
    p["links"]             = JSONValue(strings(g, "links"));
    p["languages"]         = JSONValue(strings(g, "languages"));
    p["memberCount"]       = JSONValue(number(g, "memberCount"));
    p["onlineMemberCount"] = JSONValue(number(g, "onlineMemberCount"));
    p["privacy"]           = JSONValue(text(g, "privacy"));
    p["joinState"]         = JSONValue(text(g, "joinState"));
    p["isVerified"]        = JSONValue(flag(g, "isVerified"));
    p["ownerId"]           = JSONValue(text(g, "ownerId"));
    p["createdAt"]         = JSONValue(text(g, "createdAt"));
    p["membershipStatus"]  = JSONValue(text(g, "membershipStatus"));
    putImage(p, "icon", g, "iconUrl");
    putImage(p, "banner", g, "bannerUrl");

    const(JSONValue)* m = "myMember" in g;
    if (m is null || m.type != JSONType.object)
        return p;

    // Role IDs mean nothing to a reader, so they go out as names.
    string[] roleIds = strings(*m, "roleIds");
    string[] roles;
    if (const(JSONValue)* r = "roles" in g)
    {
        if (r.type == JSONType.array)
            foreach (const(JSONValue) role; r.array)
            {
                string name = text(role, "name");
                if (name.length == 0)
                    continue;
                string id = text(role, "id");
                foreach (string want; roleIds)
                {
                    if (want == id)
                    {
                        roles ~= name;
                        break;
                    }
                }
            }
    }

    p["myMember"] = JSONValue([
        "isRepresenting":              JSONValue(flag(*m, "isRepresenting")),
        "isSubscribedToAnnouncements": JSONValue(flag(*m, "isSubscribedToAnnouncements", true)),
        "visibility":                  JSONValue(text(*m, "visibility")),
        "joinedAt":                    JSONValue(text(*m, "joinedAt")),
        "membershipStatus":            JSONValue(text(*m, "membershipStatus")),
        "roles":                       JSONValue(roles),
    ]);
    if (text(g, "membershipStatus").length == 0)
        p["membershipStatus"] = JSONValue(text(*m, "membershipStatus"));
    return p;
}

/// The user's group list. Safe to use from any thread.
class GroupsTracker
{
    this()
    {
        mtx = new Mutex();
    }

    /// Whether a full list has been fetched since startup.
    bool isLoaded()
    {
        synchronized (mtx)
            return loaded;
    }

    /// Replace the list from `GET /users/{id}/groups`.
    void replaceFromAPI(const(JSONValue)[] list)
    {
        GroupEntry[string] fresh;
        foreach (ref const(JSONValue) g; list)
        {
            GroupEntry e = entryFromUserGroup(g);
            if (e.id.length > 0)
                fresh[e.id] = e;
        }

        synchronized (mtx)
        {
            entries = fresh;
            loaded = true;
        }
    }

    /// Add or replace one group from a full group object. False when the
    /// object carries no ID or the list was never loaded.
    bool upsert(ref const(JSONValue) group)
    {
        GroupEntry e = entryFromGroup(group);
        if (e.id.length == 0)
            return false;

        synchronized (mtx)
        {
            if (loaded == false)
                return false;
            if (e.isRepresenting)
                clearRepresentingLocked();
            entries[e.id] = e;
            return true;
        }
    }

    /// Drop one group. True when it was listed.
    bool remove(string groupId)
    {
        synchronized (mtx)
            return entries.remove(groupId);
    }

    /// Fold a GroupMember object (event or PUT response) into its entry.
    /// True when a listed entry changed.
    bool applyMember(ref const(JSONValue) member)
    {
        string groupId = text(member, "groupId");
        if (groupId.length == 0)
            return false;

        synchronized (mtx)
        {
            GroupEntry* e = groupId in entries;
            if (e is null)
                return false;

            bool changed;
            if (const(JSONValue)* v = "isRepresenting" in member)
            {
                bool now = v.type == JSONType.true_;
                if (now != e.isRepresenting)
                {
                    if (now)
                        clearRepresentingLocked();
                    e.isRepresenting = now;
                    changed = true;
                }
            }
            string visibility = text(member, "visibility");
            if (visibility.length > 0 && visibility != e.visibility)
            {
                e.visibility = visibility;
                changed = true;
            }
            return changed;
        }
    }

    /// Record a representation change of ours. VRChat allows one at a time.
    void setRepresenting(string groupId, bool on)
    {
        synchronized (mtx)
        {
            if (on)
                clearRepresentingLocked();
            if (GroupEntry* e = groupId in entries)
                e.isRepresenting = on;
        }
    }

    /// Record a visibility change of ours.
    void setVisibility(string groupId, string visibility)
    {
        synchronized (mtx)
        {
            if (GroupEntry* e = groupId in entries)
                e.visibility = visibility;
        }
    }

    /// Listed name for a group, or null.
    string getName(string groupId)
    {
        synchronized (mtx)
        {
            if (GroupEntry* e = groupId in entries)
                return e.name;
            return null;
        }
    }

    /// Build the `groups` message, sorted by name.
    JSONValue buildGroupsMessage()
    {
        GroupEntry[] list;
        synchronized (mtx)
            list = entries.values;

        sort!((a, b) => icmp(a.name, b.name) < 0)(list);

        JSONValue[] arr;
        foreach (ref GroupEntry e; list)
            arr ~= e.toJSON();

        return JSONValue([
            "type": JSONValue("groups"),
            "groups": JSONValue(arr),
        ]);
    }

private:
    /// Clear every representing flag. Caller holds mtx.
    void clearRepresentingLocked()
    {
        foreach (ref GroupEntry e; entries)
            e.isRepresenting = false;
    }

    Mutex mtx;
    GroupEntry[string] entries;
    bool loaded;
}

unittest
{
    assert(isGroupId("grp_0d2f6e2a-1234-4abc-9def-0123456789ab"));
    assert(isGroupId("usr_abc") == false);
    assert(isGroupId("grp_") == false);
    assert(isGroupId("grp_../x") == false);

    GroupsTracker t = new GroupsTracker();

    // Not loaded: events cannot invent a list.
    JSONValue early = parseJSON(`{"id":"grp_c","name":"Early"}`);
    assert(t.upsert(early) == false);

    JSONValue list = parseJSON(`[
        {"id":"gmem_1","groupId":"grp_b","name":"beta","isRepresenting":true,
         "memberVisibility":"visible",
         "iconUrl":"https://api.vrchat.cloud/api/1/file/file_aaa/3/file"},
        {"id":"gmem_2","groupId":"grp_a","name":"Alpha","memberVisibility":"hidden"},
        {"id":"gmem_3","name":"no group id"}
    ]`);
    t.replaceFromAPI(list.array);
    assert(t.isLoaded());

    JSONValue msg = t.buildGroupsMessage();
    assert(msg["groups"].array.length == 2);
    assert(msg["groups"][0]["name"].str == "Alpha");
    assert(msg["groups"][1]["iconFileId"].str == "file_aaa");
    assert(msg["groups"][1]["iconVersion"].integer == 3);

    // Representing another group clears the first.
    JSONValue member = parseJSON(`{"groupId":"grp_a","isRepresenting":true}`);
    assert(t.applyMember(member));
    assert(t.applyMember(member) == false);
    msg = t.buildGroupsMessage();
    assert(msg["groups"][0]["isRepresenting"].type == JSONType.true_);
    assert(msg["groups"][1]["isRepresenting"].type == JSONType.false_);

    JSONValue joined = parseJSON(`{"id":"grp_c","name":"Gamma",
        "myMember":{"isRepresenting":false,"visibility":"friends"}}`);
    assert(t.upsert(joined));
    assert(t.getName("grp_c") == "Gamma");
    assert(t.remove("grp_c"));
    assert(t.remove("grp_c") == false);
}

unittest
{
    JSONValue g = parseJSON(`{
        "id":"grp_x","name":"X","shortCode":"XX","discriminator":"0001",
        "links":["https://a",""],"membershipStatus":"member",
        "bannerUrl":"https://api.vrchat.cloud/api/1/file/file_bbb/1/file",
        "roles":[{"id":"grol_1","name":"Member"},{"id":"grol_2","name":"Mod"}],
        "myMember":{"roleIds":["grol_2"],"isRepresenting":true,
                    "visibility":"visible","membershipStatus":"member"}
    }`);
    assert(isMemberOf(g));

    JSONValue p = buildGroupProfile(g);
    assert(p["links"].array.length == 1);
    assert(p["bannerFileId"].str == "file_bbb");
    assert(p["myMember"]["roles"].array.length == 1);
    assert(p["myMember"]["roles"][0].str == "Mod");
    // Missing means subscribed, VRChat's default.
    assert(p["myMember"]["isSubscribedToAnnouncements"].type == JSONType.true_);

    JSONValue stranger = parseJSON(`{"id":"grp_y","name":"Y","joinState":"request"}`);
    p = buildGroupProfile(stranger);
    assert(("myMember" in p) is null);
    assert(isMemberOf(stranger) == false);
}
