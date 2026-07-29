/// Friend roster shared by the SDL client and the web front-end.
///
/// The server's `friends` snapshot is deliberately close to what VRChat
/// reports; deciding what belongs in "Private" vs "Active elsewhere", and in
/// what order friends are listed, is presentation. Both front-ends need the
/// exact same answers, so that logic lives here instead of being written twice.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module vrcd.friends;

import std.algorithm.sorting : sort;
import std.json;
import std.uni : icmp;

/// A friend, as carried in the server's `friends` snapshot.
struct FriendInfo
{
    string userId;
    string displayName;
    string status;
    string statusDescription;
    string platform;
    string location;
    string bio;
    string pronouns;
    string[] bioLinks;
    /// Profile picture, as a file the image proxy can ask for. The server
    /// picks which of VRChat's several picture fields this came from; empty
    /// when the friend has none we can fetch.
    string imageFileId;
    long imageVersion;
}

/// Friends grouped by instance.
struct InstanceGroup
{
    string instanceId; // canonical grouping key (wrld_xxx:12345)
    string location;   // full location with region tags, for launch URIs
    string worldName;
    FriendInfo[] friends;
    long nUsers   = -1; // -1 = unknown
    long capacity = -1; // -1 = unknown
}

/// A bucketed and sorted roster, ready to render.
struct FriendRoster
{
    /// Joinable world instances, with the catch-all "private" group last.
    InstanceGroup[] instances;
    /// Online on the website (or another non-game platform), not in VRChat.
    FriendInfo[] activeElsewhere;
    FriendInfo[] offline;
    /// Flat roster sorted by name only.
    FriendInfo[] all;
}

/// Bucket and sort a server `friends` snapshot.
FriendRoster parseFriendsMessage(ref JSONValue msg)
{
    FriendRoster roster;
    FriendInfo[] privateGroup; // in VRChat but private/traveling

    // Parse instances.
    if (const(JSONValue) *jinstances = "instances" in msg)
    if (jinstances.type == JSONType.array)
    {
        foreach (grp; jinstances.array)
        {
            InstanceGroup ig;
            if (const(JSONValue)* v = "instance_id" in grp)
                ig.instanceId = v.str;
            if (const(JSONValue)* v = "location" in grp)
                ig.location = v.str;
            if (const(JSONValue)* v = "world_name" in grp)
                ig.worldName = v.str;
            if (const(JSONValue)* v = "n_users" in grp)
                if (v.type == JSONType.integer || v.type == JSONType.uinteger)
                    ig.nUsers = v.integer;
            if (const(JSONValue)* v = "capacity" in grp)
                if (v.type == JSONType.integer || v.type == JSONType.uinteger)
                    ig.capacity = v.integer;

            if (const(JSONValue) *jfriends = "friends" in grp)
            if (jfriends.type == JSONType.array)
            {
                foreach (fVal; jfriends.array)
                    ig.friends ~= parseFriendInfo(fVal);
            }

            sort!friendLess(ig.friends);

            // "private" and "traveling" are not joinable world instances.
            // Split by platform: web-only friends go to "Active elsewhere";
            // game-platform friends go to the "Private" section.
            if (ig.instanceId == "private" || ig.instanceId == "traveling")
            {
                foreach (ref FriendInfo f; ig.friends)
                {
                    if (f.platform == "web")
                        roster.activeElsewhere ~= f;
                    else
                        privateGroup ~= f;
                }
            }
            else
                roster.instances ~= ig;
        }
    }

    if (privateGroup.length > 0)
    {
        sort!friendLess(privateGroup);
        InstanceGroup pg;
        pg.instanceId = "private";
        pg.friends = privateGroup;
        roster.instances ~= pg;
    }
    sort!friendLess(roster.activeElsewhere);

    // Parse offline friends. Web-platform friends with a non-offline status
    // are active on the website but may have an empty location in the API
    // seed, causing the server to bucket them as offline. Re-route them to
    // "Active elsewhere" so they appear in the correct section.
    if (const(JSONValue) *joffline = "offline" in msg)
    if (joffline.type == JSONType.array)
    {
        foreach (fVal; joffline.array)
        {
            FriendInfo fi = parseFriendInfo(fVal);
            if (fi.platform == "web" && fi.status != "offline")
                roster.activeElsewhere ~= fi;
            else
                roster.offline ~= fi;
        }
    }
    sort!friendLess(roster.activeElsewhere);
    sort!friendLess(roster.offline);

    foreach (ref InstanceGroup ig; roster.instances)
        roster.all ~= ig.friends;
    roster.all ~= roster.activeElsewhere;
    roster.all ~= roster.offline;
    sort!nameLess(roster.all);

    return roster;
}

/// Parse a FriendInfo from a JSON friend object.
FriendInfo parseFriendInfo(JSONValue f)
{
    FriendInfo fi;
    if (const(JSONValue)* v = "id" in f)
        fi.userId = v.str;
    if (const(JSONValue)* v = "displayName" in f)
        fi.displayName = v.str;
    if (const(JSONValue)* v = "status" in f)
        fi.status = v.str;
    if (const(JSONValue)* v = "statusDescription" in f)
        fi.statusDescription = v.str;
    if (const(JSONValue)* v = "platform" in f)
        fi.platform = v.str;
    if (const(JSONValue)* v = "location" in f)
        fi.location = v.str;
    if (const(JSONValue)* v = "bio" in f)
        if (v.type == JSONType.string)
            fi.bio = v.str;
    if (const(JSONValue)* v = "pronouns" in f)
        if (v.type == JSONType.string)
            fi.pronouns = v.str;
    if (const(JSONValue)* v = "bioLinks" in f)
        if (v.type == JSONType.array)
            foreach (ref const(JSONValue) item; v.array)
                if (item.type == JSONType.string)
                    fi.bioLinks ~= item.str;
    if (const(JSONValue)* v = "imageFileId" in f)
        if (v.type == JSONType.string)
            fi.imageFileId = v.str;
    if (const(JSONValue)* v = "imageVersion" in f)
        if (v.type == JSONType.integer || v.type == JSONType.uinteger)
            fi.imageVersion = v.integer;
    return fi;
}

/// Case-insensitive display-name ordering for the flat friend roster.
bool nameLess(ref const FriendInfo a, ref const FriendInfo b)
{
    return icmp(a.displayName, b.displayName) < 0;
}

/// Friend ordering within a section: status rank first, then display name.
bool friendLess(ref const FriendInfo a, ref const FriendInfo b)
{
    // First, try ranking by status if those differ
    int ra = statusRank(a.status);
    int rb = statusRank(b.status);
    if (ra != rb)
        return ra < rb;
    // Then, rank by name if their status rank is the same
    return icmp(a.displayName, b.displayName) < 0;
}

/// Status rank for sorting: Join Me, Online, Ask Me, Busy, then anything else,
/// with Offline last. Ties fall back to case-insensitive display name.
int statusRank(string status)
{
    switch (status)
    {
        case "join me": return 0;
        case "active":  return 1;
        case "ask me":  return 2;
        case "busy":    return 3;
        case "offline": return 5;
        default:        return 4;
    }
}

unittest
{
    // A web-platform friend parked in "private" belongs in Active elsewhere,
    // while a game-platform one stays in the Private bucket.
    JSONValue msg = parseJSON(`{
        "instances": [
            {"instance_id":"wrld_a:1","location":"wrld_a:1~region(us)",
             "world_name":"Test World","n_users":3,"capacity":16,
             "friends":[
                {"id":"usr_b","displayName":"betty","status":"active","platform":"standalonewindows"},
                {"id":"usr_a","displayName":"alice","status":"join me","platform":"standalonewindows"}]},
            {"instance_id":"private","friends":[
                {"id":"usr_c","displayName":"carol","status":"busy","platform":"web"},
                {"id":"usr_d","displayName":"dave","status":"active","platform":"android"}]}
        ],
        "offline": [
            {"id":"usr_e","displayName":"erin","status":"offline","platform":"standalonewindows"},
            {"id":"usr_f","displayName":"frank","status":"active","platform":"web"}
        ]
    }`);

    FriendRoster roster = parseFriendsMessage(msg);

    assert(roster.instances.length == 2);
    assert(roster.instances[0].worldName == "Test World");
    assert(roster.instances[0].nUsers == 3);
    assert(roster.instances[0].capacity == 16);
    // "join me" outranks "active".
    assert(roster.instances[0].friends[0].displayName == "alice");
    // The synthesized Private group is last and holds only the game platform.
    assert(roster.instances[1].instanceId == "private");
    assert(roster.instances[1].friends.length == 1);
    assert(roster.instances[1].friends[0].displayName == "dave");
    // carol (web, private) and frank (web, non-offline in the offline list).
    assert(roster.activeElsewhere.length == 2);
    assert(roster.offline.length == 1);
    assert(roster.offline[0].displayName == "erin");
    assert(roster.all.length == 6);
    assert(roster.all[0].displayName == "alice");
    assert(roster.all[$ - 1].displayName == "frank");
}
