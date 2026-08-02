/// One VRChat user, reduced to what a profile page shows.
///
/// The friend roster is a thin record: enough to draw a row and say where
/// somebody is. A profile is the other half -- bio, links, badges, trust rank,
/// when they joined -- and none of it rides in the roster, because it never
/// changes on the timescale the roster does and would be re-broadcast on every
/// friend movement for nothing.
///
/// It is also the only way to see somebody who is *not* a friend, which is the
/// case that matters most: a friend request arrives with a name and an ID, and
/// deciding on it means looking at the person behind them.
///
/// Normalizing here rather than in each front-end keeps VRChat's spelling
/// (`last_platform`, `date_joined`, tag soup) in one place, and means the SDL
/// client and the web front-end cannot disagree about what somebody's trust
/// rank is.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.userprofile;

import core.sync.mutex : Mutex;

import std.datetime : Clock;
import std.json;
import std.string : startsWith;

import server.userimage;

/// How long a fetched profile is served from cache. Short: a bio or a status
/// changes without any event to say so, and this is a page somebody opens
/// deliberately. Long enough that flipping between two friend requests, or two
/// browsers looking at the same person, costs one call rather than four.
private enum long PROFILE_TTL = 300;

/// How long a failure is remembered, so a profile VRChat refuses (a deleted
/// account, a 404 on a group ID) is not asked for again on every redraw.
private enum long PROFILE_FAILURE_TTL = 60;

/// The prefixes VRChat gives its other objects. A `get_user` naming one of
/// these is a 404 spent for nothing, and the group case is not hypothetical: a
/// v2 group notification puts the group's own ID where a sender's user ID goes.
private immutable string[] notUserPrefixes = [
    "grp_", "wrld_", "avtr_", "file_", "inst_", "prnt_", "inv_", "not_",
];

/// Whether this could be a VRChat user ID. It ends up in a URL path, so the
/// characters are checked; the `usr_` prefix is not required, because accounts
/// old enough predate it and are still perfectly real (the same reason the web
/// front-end's moderation route does not require it either).
///
/// What is refused is an ID that visibly belongs to something else, so the
/// common mistake costs no VRChat call.
bool isUserId(string value)
{
    import std.ascii : isAlphaNum;

    if (value.length < 3 || value.length > 64)
        return false;

    foreach (string prefix; notUserPrefixes)
    {
        if (startsWith(value, prefix))
            return false;
    }

    foreach (char c; value)
    {
        if (isAlphaNum(c) == false && c != '-' && c != '_')
            return false;
    }
    return true;
}

/// Trust rank as VRChat's own UI words it, derived from the user's tags.
///
/// The tags are cumulative -- somebody trusted carries every rank below theirs
/// -- so the order here is highest first and the first hit wins. Names follow
/// VRCX (`applyUserTrustLevel`), which follows the game: the tag named
/// "trusted" is the rank shown as "Known User", and getting that pairing wrong
/// would mislabel everyone by one rank.
string trustRank(const(JSONValue)[] tags)
{
    bool has(string tag)
    {
        foreach (const(JSONValue) v; tags)
        {
            if (v.type == JSONType.string && v.str == tag)
                return true;
        }
        return false;
    }

    if (has("system_trust_veteran")) return "Trusted User";
    if (has("system_trust_trusted")) return "Known User";
    if (has("system_trust_known"))   return "User";
    if (has("system_trust_basic"))   return "New User";
    return "Visitor";
}

/// Build the `user` payload from VRChat's `GET /users/:id` response.
///
/// Every field is optional on the way in: VRChat trims its user object
/// differently depending on who is asking (a stranger's record is thinner than
/// a friend's), and a front-end draws a row only when the field is there. So a
/// missing field becomes an empty one rather than an error.
JSONValue buildUserProfile(JSONValue user)
{
    JSONValue profile = JSONValue.emptyObject;
    if (user.type != JSONType.object)
        return profile;

    string text(string field)
    {
        if (const(JSONValue)* v = field in user)
            if (v.type == JSONType.string)
                return v.str;
        return null;
    }

    bool flag(string field)
    {
        if (const(JSONValue)* v = field in user)
            return v.type == JSONType.true_;
        return false;
    }

    profile["id"]                  = JSONValue(text("id"));
    profile["displayName"]         = JSONValue(text("displayName"));
    profile["status"]              = JSONValue(text("status"));
    profile["statusDescription"]   = JSONValue(text("statusDescription"));
    profile["bio"]                 = JSONValue(text("bio"));
    profile["pronouns"]            = JSONValue(text("pronouns"));
    profile["note"]                = JSONValue(text("note"));
    profile["state"]               = JSONValue(text("state"));
    profile["location"]            = JSONValue(text("location"));
    // VRChat's own spelling, flattened to the roster's: a front-end that draws
    // a friend and a stranger through one path should not have to know which
    // of the two it has.
    profile["platform"]            = JSONValue(text("last_platform"));
    profile["dateJoined"]          = JSONValue(text("date_joined"));
    profile["lastActivity"]        = JSONValue(text("last_activity"));
    profile["lastLogin"]           = JSONValue(text("last_login"));
    profile["friendRequestStatus"] = JSONValue(text("friendRequestStatus"));
    profile["isFriend"]            = JSONValue(flag("isFriend"));
    profile["ageVerified"]         = JSONValue(flag("ageVerified"));

    string[] links;
    if (const(JSONValue)* v = "bioLinks" in user)
    {
        if (v.type == JSONType.array)
            foreach (const(JSONValue) link; v.array)
            {
                if (link.type == JSONType.string && link.str.length > 0)
                    links ~= link.str;
            }
    }
    profile["bioLinks"] = JSONValue(links);

    // Tags carry three separate things: the trust rank, the languages someone
    // listed, and moderator/troll marks. They are split apart here so no
    // front-end has to know the tag vocabulary.
    const(JSONValue)[] tags;
    if (const(JSONValue)* v = "tags" in user)
        if (v.type == JSONType.array)
            tags = v.array;

    string[] languages;
    bool troll;
    foreach (const(JSONValue) tag; tags)
    {
        if (tag.type != JSONType.string)
            continue;
        if (startsWith(tag.str, "language_") && tag.str.length > 9)
            languages ~= tag.str[9 .. $];
        else if (tag.str == "system_troll" || tag.str == "system_probable_troll")
            troll = true;
    }
    profile["trustRank"] = JSONValue(trustRank(tags));
    profile["languages"] = JSONValue(languages);
    profile["troll"]     = JSONValue(troll);

    // A "developer type" other than none is what marks VRChat staff, and the
    // moderator tag says the same thing for accounts that carry it instead.
    bool moderator = text("developerType").length > 0 &&
        text("developerType") != "none";
    foreach (const(JSONValue) tag; tags)
    {
        if (tag.type == JSONType.string && tag.str == "admin_moderator")
            moderator = true;
    }
    profile["moderator"] = JSONValue(moderator);

    // Badges keep VRChat's own image URLs. Unlike everything else with a
    // picture, these live on a public CDN rather than behind the authenticated
    // files API, so a front-end can load one itself and there is no file for
    // the image proxy to be handed.
    JSONValue[] badges;
    if (const(JSONValue)* v = "badges" in user)
    {
        if (v.type == JSONType.array)
            foreach (const(JSONValue) badge; v.array)
            {
                if (badge.type != JSONType.object)
                    continue;

                string badgeText(string field)
                {
                    if (const(JSONValue)* b = field in badge)
                        if (b.type == JSONType.string)
                            return b.str;
                    return null;
                }

                bool showcased;
                if (const(JSONValue)* b = "showcased" in badge)
                    showcased = b.type == JSONType.true_;

                badges ~= JSONValue([
                    "id":          JSONValue(badgeText("badgeId")),
                    "name":        JSONValue(badgeText("badgeName")),
                    "description": JSONValue(badgeText("badgeDescription")),
                    "imageUrl":    JSONValue(badgeText("badgeImageUrl")),
                    "showcased":   JSONValue(showcased),
                ]);
            }
    }
    profile["badges"] = JSONValue(badges);

    // Same pick the roster and the SDL client make, so a friend's face does
    // not change when their profile is opened.
    UserImage picture = pickUserImage(user);
    profile["imageFileId"] = JSONValue(picture.fileId);
    profile["imageVersion"] = JSONValue(picture.fileVersion);

    return profile;
}

/// Short-lived cache of built profiles, shared by every connected front-end.
///
/// A profile is asked for whenever somebody opens a pane, which on a browser
/// is often enough to matter: two front-ends and a scroll back and forth would
/// otherwise be four `GET /users/:id` against a rate limit shared with
/// everything else the server does.
///
/// Failures are cached too, and for the same reason: a page that retries a 404
/// on every redraw is the worst thing to point at a rate limit.
class UserProfileCache
{
    this()
    {
        this.mutex = new Mutex();
    }

    /// Fresh profile for this user, or a null JSONValue pointer when there is
    /// nothing usable cached. `error` is set when what was cached is a
    /// remembered failure.
    bool lookup(string userId, out JSONValue profile, out string error)
    {
        long now = Clock.currTime.toUnixTime!long();

        synchronized (mutex)
        {
            Entry* entry = userId in entries;
            if (entry is null)
                return false;

            if (now >= entry.expiresAt)
            {
                entries.remove(userId);
                return false;
            }

            profile = entry.profile;
            error = entry.error;
            return true;
        }
    }

    /// Remember one fetched profile.
    void store(string userId, JSONValue profile)
    {
        synchronized (mutex)
        {
            entries[userId] = Entry(profile, null,
                Clock.currTime.toUnixTime!long() + PROFILE_TTL);
        }
    }

    /// Remember that this profile could not be fetched.
    void storeFailure(string userId, string error)
    {
        synchronized (mutex)
        {
            entries[userId] = Entry(JSONValue.init, error,
                Clock.currTime.toUnixTime!long() + PROFILE_FAILURE_TTL);
        }
    }

    /// Forget one entry, so the next look goes back to VRChat. Used after
    /// anything that changes what a profile says (accepting a friend request
    /// flips `isFriend`).
    void forget(string userId)
    {
        synchronized (mutex)
            entries.remove(userId);
    }

private:
    struct Entry
    {
        JSONValue profile;
        string error;
        long expiresAt;
    }

    Mutex mutex;
    Entry[string] entries;
}

unittest
{
    assert(isUserId("usr_8b5e4d3c-0000-4000-8000-1a2b3c4d5e6f"));
    // An account old enough to predate the prefix.
    assert(isUserId("8b5e4d3c-0000-4000-8000-1a2b3c4d5e6f"));

    // Something that is visibly not a user, most of all the group ID a v2
    // group notification puts in the sender field.
    assert(isUserId("grp_8b5e4d3c") == false);
    assert(isUserId("wrld_8b5e4d3c") == false);

    // Nothing that could climb out of a URL path.
    assert(isUserId("usr_../../auth/user") == false);
    assert(isUserId("usr_a/b") == false);
    assert(isUserId("") == false);
}

unittest
{
    // The tag named "trusted" is the rank shown as "Known User".
    JSONValue veteran = parseJSON(`["system_trust_veteran","system_trust_trusted"]`);
    assert(trustRank(veteran.array) == "Trusted User");
    assert(trustRank(parseJSON(`["system_trust_trusted"]`).array) == "Known User");
    assert(trustRank(parseJSON(`["system_trust_known"]`).array) == "User");
    assert(trustRank(parseJSON(`["system_trust_basic"]`).array) == "New User");
    assert(trustRank(parseJSON(`["language_eng"]`).array) == "Visitor");
    assert(trustRank(null) == "Visitor");
}

unittest
{
    JSONValue user = parseJSON(`{
        "id": "usr_abc",
        "displayName": "Somebody",
        "bio": "line one\nline two",
        "bioLinks": ["https://example.invalid", ""],
        "pronouns": "they/them",
        "status": "join me",
        "statusDescription": "come say hi",
        "date_joined": "2019-04-01",
        "last_platform": "standalonewindows",
        "developerType": "none",
        "isFriend": false,
        "tags": ["system_trust_known", "language_eng", "language_jpn"],
        "badges": [
            {
                "badgeId": "bdg_1",
                "badgeName": "Supporter",
                "badgeDescription": "Thanks",
                "badgeImageUrl": "https://assets.vrchat.com/badges/x.png",
                "showcased": true
            },
            "not a badge"
        ],
        "currentAvatarThumbnailImageUrl":
            "https://api.vrchat.cloud/api/1/image/file_av/3/256"
    }`);

    JSONValue profile = buildUserProfile(user);
    assert(profile["displayName"].str == "Somebody");
    assert(profile["bio"].str == "line one\nline two");
    assert(profile["pronouns"].str == "they/them");
    assert(profile["platform"].str == "standalonewindows");
    assert(profile["dateJoined"].str == "2019-04-01");
    assert(profile["trustRank"].str == "User");
    assert(profile["isFriend"].type == JSONType.false_);
    assert(profile["moderator"].type == JSONType.false_);
    assert(profile["troll"].type == JSONType.false_);

    // An empty link is not a link.
    assert(profile["bioLinks"].array.length == 1);
    assert(profile["languages"].array.length == 2);
    assert(profile["languages"].array[0].str == "eng");

    // The array member that is not an object is skipped, not fatal.
    assert(profile["badges"].array.length == 1);
    assert(profile["badges"].array[0]["name"].str == "Supporter");
    assert(profile["badges"].array[0]["showcased"].type == JSONType.true_);

    // Same face the roster would show.
    assert(profile["imageFileId"].str == "file_av");
    assert(profile["imageVersion"].integer == 3);
}

unittest
{
    // VRChat trims a stranger's record; every missing field reads as empty
    // rather than throwing.
    JSONValue thin = parseJSON(`{"id":"usr_abc","displayName":"Nobody"}`);
    JSONValue profile = buildUserProfile(thin);
    assert(profile["bio"].str.length == 0);
    assert(profile["bioLinks"].array.length == 0);
    assert(profile["badges"].array.length == 0);
    assert(profile["trustRank"].str == "Visitor");
    assert(profile["imageFileId"].str.length == 0);

    assert(buildUserProfile(JSONValue("nonsense")).object.length == 0);

    // A staff account is marked whichever way VRChat says it.
    JSONValue staff = parseJSON(`{"id":"usr_a","developerType":"internal"}`);
    assert(buildUserProfile(staff)["moderator"].type == JSONType.true_);
    JSONValue tagged = parseJSON(`{"id":"usr_a","tags":["admin_moderator"]}`);
    assert(buildUserProfile(tagged)["moderator"].type == JSONType.true_);
}

unittest
{
    UserProfileCache cache = new UserProfileCache();

    JSONValue found;
    string error;
    assert(cache.lookup("usr_a", found, error) == false);

    cache.store("usr_a", parseJSON(`{"displayName":"Somebody"}`));
    assert(cache.lookup("usr_a", found, error));
    assert(found["displayName"].str == "Somebody");
    assert(error.length == 0);

    cache.storeFailure("usr_b", "HTTP 404");
    assert(cache.lookup("usr_b", found, error));
    assert(error == "HTTP 404");

    cache.forget("usr_a");
    assert(cache.lookup("usr_a", found, error) == false);
}
