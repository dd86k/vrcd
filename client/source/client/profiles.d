/// User profiles fetched through vrcd-server, and the cache that holds them.
///
/// The roster is a thin record: enough to draw a row and say where somebody is
/// standing. The rest of a profile -- trust rank, the languages somebody
/// listed, badges, the day they joined -- is asked for one person at a time,
/// since it changes on a different timescale than the roster does and would
/// otherwise be re-broadcast on every friend movement. It is also the only way
/// to see somebody who is *not* a friend, which is the case that matters most:
/// a friend request arrives as a name and an ID.
///
/// Main-thread only, like the image cache: the UI reads it while drawing and
/// link replies are applied from the same loop, so there is nothing to lock
/// against. The web front-end's equivalent carries a mutex because ddhttpd
/// answers out of its poll thread.
///
/// Unlike an image, a profile goes stale -- a bio changes with no event to say
/// so -- so entries expire and the next lookup refetches. The stale one keeps
/// being drawn while that runs: this UI redraws the page sixty times a second,
/// and a frame with a hole in it is visible in a way a browser's is not.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module client.profiles;

import std.datetime : Clock;
import std.json;

import vrcd.friends : FriendInfo;

/// How long a fetched profile is drawn before it is asked for again.
private enum long PROFILE_TTL = 300;

/// How long an unanswered request is left alone before it is asked for again.
/// A link that dropped mid-request never answers, and without this the entry
/// would stay pending for the rest of the session.
private enum long REQUEST_TIMEOUT = 20;

/// How long a failure is remembered. Long enough that a page redrawing every
/// frame does not hammer the link, short enough that a transient error heals
/// on its own.
private enum long FAILURE_TTL = 60;

/// How many profiles are held. A profile is a few kilobytes and belongs to
/// somebody looked at deliberately, so this is generous; past it the oldest go.
private enum size_t PROFILE_MAX = 128;

/// One badge off a profile.
///
/// `imageUrl` is a public CDN address rather than a VRChat file, so the art is
/// fetched by URL (`get_badge_image`) instead of through the image proxy.
struct BadgeInfo
{
    string id;
    string name;
    string description;
    string imageUrl;
    bool showcased;
}

/// A profile as vrcd-server normalizes it, which is VRChat's user record with
/// the tag soup already sorted out (see `server.userprofile`).
struct UserProfile
{
    string userId;
    string displayName;
    string status;
    string statusDescription;
    string bio;
    string[] bioLinks;
    string pronouns;
    /// Your own private note on this person.
    string note;
    string platform;
    string location;
    string dateJoined;
    /// VRChat's own wording ("Known User"), derived server-side from the tags.
    string trustRank;
    string[] languages;
    bool isFriend;
    bool moderator;
    bool troll;
    string imageFileId;
    long imageVersion;
    BadgeInfo[] badges;
}

/// Parse the `user` object out of a `get_user` reply.
///
/// Every field is optional: VRChat trims a stranger's record, and the server
/// passes that through rather than inventing values, so a missing field is an
/// empty one.
UserProfile parseUserProfile(ref JSONValue user)
{
    UserProfile profile;
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

    string[] strings(string field)
    {
        string[] list;
        if (const(JSONValue)* v = field in user)
            if (v.type == JSONType.array)
                foreach (ref const(JSONValue) item; v.array)
                    if (item.type == JSONType.string && item.str.length > 0)
                        list ~= item.str;
        return list;
    }

    profile.userId            = text("id");
    profile.displayName       = text("displayName");
    profile.status            = text("status");
    profile.statusDescription = text("statusDescription");
    profile.bio               = text("bio");
    profile.bioLinks          = strings("bioLinks");
    profile.pronouns          = text("pronouns");
    profile.note              = text("note");
    profile.platform          = text("platform");
    profile.location          = text("location");
    profile.dateJoined        = text("dateJoined");
    profile.trustRank         = text("trustRank");
    profile.languages         = strings("languages");
    profile.isFriend          = flag("isFriend");
    profile.moderator         = flag("moderator");
    profile.troll             = flag("troll");
    profile.imageFileId       = text("imageFileId");

    if (const(JSONValue)* v = "imageVersion" in user)
        if (v.type == JSONType.integer || v.type == JSONType.uinteger)
            profile.imageVersion = v.integer;

    if (const(JSONValue)* jbadges = "badges" in user)
    if (jbadges.type == JSONType.array)
    {
        foreach (ref const(JSONValue) item; jbadges.array)
        {
            if (item.type != JSONType.object)
                continue;

            BadgeInfo badge;
            if (const(JSONValue)* v = "id" in item)
                if (v.type == JSONType.string)
                    badge.id = v.str;
            if (const(JSONValue)* v = "name" in item)
                if (v.type == JSONType.string)
                    badge.name = v.str;
            if (const(JSONValue)* v = "description" in item)
                if (v.type == JSONType.string)
                    badge.description = v.str;
            if (const(JSONValue)* v = "imageUrl" in item)
                if (v.type == JSONType.string)
                    badge.imageUrl = v.str;
            if (const(JSONValue)* v = "showcased" in item)
                badge.showcased = v.type == JSONType.true_;

            // Showcased first: it is the order VRChat draws them in, and the
            // ones somebody chose to show say more than the ones they earned.
            if (badge.showcased)
                profile.badges = badge ~ profile.badges;
            else
                profile.badges ~= badge;
        }
    }

    return profile;
}

/// Where a lookup stands.
enum ProfileState
{
    /// Being fetched. The caller may have to start that fetch itself.
    pending,
    /// The profile is in `profile`.
    ready,
    /// VRChat or vrcd-server refused it; `error` says why.
    failed,
}

/// Result of one cache lookup.
struct ProfileLookup
{
    ProfileState state;
    UserProfile profile;
    string error;
}

/// Bounded profile cache. Main-thread only.
struct ProfileCache
{
    /// Look one profile up.
    ///
    /// Params:
    ///   userId = VRChat user ID.
    ///   startFetch = Set when the caller has to ask vrcd-server for this
    ///                profile: nothing usable is held and nothing is on its way.
    ProfileLookup lookup(string userId, out bool startFetch)
    {
        long now = Clock.currTime.toUnixTime!long();

        if (Entry* entry = userId in entries)
        {
            final switch (entry.state) with (ProfileState)
            {
            case ready:
                if (now - entry.stamp < PROFILE_TTL)
                    return ProfileLookup(ready, entry.profile);
                // Stale, but still worth drawing: the page keeps what we have
                // and the fetch started here lands under it. The entry stays
                // `ready` with a fresh stamp so the next frame does not start
                // a second fetch.
                entry.stamp = now;
                startFetch = true;
                return ProfileLookup(ready, entry.profile);

            case failed:
                if (now - entry.stamp < FAILURE_TTL)
                    return ProfileLookup(failed, UserProfile.init, entry.error);
                break; // Expired; ask again.

            case pending:
                if (now - entry.stamp < REQUEST_TIMEOUT)
                    return ProfileLookup(pending);
                break; // The answer never came; ask again.
            }
        }

        remember(userId, Entry(ProfileState.pending, now));
        startFetch = true;
        return ProfileLookup(ProfileState.pending);
    }

    /// Store a fetched profile.
    void store(string userId, UserProfile profile)
    {
        remember(userId, Entry(ProfileState.ready,
            Clock.currTime.toUnixTime!long(), profile));
    }

    /// Remember that this profile could not be fetched.
    void storeFailure(string userId, string error)
    {
        remember(userId, Entry(ProfileState.failed,
            Clock.currTime.toUnixTime!long(), UserProfile.init, error));
    }

    /// Forget one entry, back to holding nothing for it.
    ///
    /// The lookup that came back `pending` marked the entry as being fetched.
    /// When the caller then finds it cannot send that request at all, the mark
    /// is a lie the next twenty seconds of frames would believe, and they would
    /// draw a spinner for a reply nobody is bringing.
    void forget(string userId)
    {
        if ((userId in entries) is null)
            return;

        entries.remove(userId);
        string[] kept;
        foreach (string held; order)
        {
            if (held != userId)
                kept ~= held;
        }
        order = kept;
    }

    /// Forget everything that is not an answer. Called when the link drops.
    ///
    /// Fetched profiles stay: they are worth reading while disconnected. What
    /// goes is a request whose reply died with the socket, and a failure that
    /// was only ever "the link was down" -- both would otherwise outlive their
    /// reason by a timeout the reconnect has no way to cut short.
    void dropUnresolved()
    {
        string[] kept;
        foreach (string userId; order)
        {
            Entry* entry = userId in entries;
            if (entry is null)
                continue;

            if (entry.state == ProfileState.ready)
            {
                kept ~= userId;
                continue;
            }
            entries.remove(userId);
        }
        order = kept;
    }

private:
    struct Entry
    {
        ProfileState state;
        /// When it was requested (pending), stored (ready), or failed.
        long stamp;
        UserProfile profile;
        string error;
    }

    Entry[string] entries;
    /// User IDs in insertion order, oldest first.
    string[] order;

    /// Add or replace one entry, evicting the oldest past the cap.
    void remember(string userId, Entry entry)
    {
        if ((userId in entries) is null)
            order ~= userId;
        entries[userId] = entry;

        while (order.length > PROFILE_MAX)
        {
            string oldest = order[0];
            order = order[1 .. $];
            entries.remove(oldest);
        }
    }
}

/// The profile page's subject: the roster half, the fetched half, and where
/// that fetch stands.
///
/// The two halves overlap, and the rule for the overlap is that the snapshot
/// owns every field it carries. It is maintained from VRChat's live friend
/// events where a fetched profile is up to five minutes old, and a status
/// blank there is a status somebody cleared on purpose. The profile answers
/// what the snapshot does not carry at all -- trust rank, languages, badges,
/// the join date, your note -- and answers everything for somebody who is not
/// on the roster, which is the case it exists for.
struct ProfileView
{
    string userId;
    /// Your own profile rather than somebody else's.
    bool self;
    /// A roster entry (or the `self` snapshot) exists for this person.
    bool hasSnapshot;
    FriendInfo snapshot;
    ProfileState state;
    UserProfile profile;
    string error;

    string displayName() { return hasSnapshot ? snapshot.displayName : profile.displayName; }
    string status() { return hasSnapshot ? snapshot.status : profile.status; }
    string statusDescription()
    {
        return hasSnapshot ? snapshot.statusDescription : profile.statusDescription;
    }
    string platform() { return hasSnapshot ? snapshot.platform : profile.platform; }
    string location() { return hasSnapshot ? snapshot.location : profile.location; }
    string bio() { return hasSnapshot ? snapshot.bio : profile.bio; }
    string pronouns() { return hasSnapshot ? snapshot.pronouns : profile.pronouns; }
    string[] bioLinks() { return hasSnapshot ? snapshot.bioLinks : profile.bioLinks; }
    string imageFileId() { return hasSnapshot ? snapshot.imageFileId : profile.imageFileId; }
    long imageVersion() { return hasSnapshot ? snapshot.imageVersion : profile.imageVersion; }
}

unittest
{
    JSONValue user = parseJSON(`{
        "id": "usr_abc", "displayName": "Somebody", "bio": "line one\nline two",
        "bioLinks": ["https://example.com", ""], "pronouns": "they/them",
        "platform": "standalonewindows", "dateJoined": "2019-04-01",
        "trustRank": "Known User", "languages": ["eng","fra"],
        "isFriend": true, "moderator": false, "troll": false,
        "note": "met at the pug", "imageFileId": "file_av", "imageVersion": 3,
        "badges": [
            {"id":"bdg_1","name":"Early","showcased":false},
            {"id":"bdg_2","name":"Supporter","showcased":true}
        ]
    }`);

    UserProfile profile = parseUserProfile(user);
    assert(profile.userId == "usr_abc");
    assert(profile.displayName == "Somebody");
    assert(profile.bio == "line one\nline two");
    assert(profile.pronouns == "they/them");
    assert(profile.trustRank == "Known User");
    assert(profile.dateJoined == "2019-04-01");
    assert(profile.note == "met at the pug");
    assert(profile.isFriend);
    assert(profile.troll == false);
    assert(profile.imageFileId == "file_av");
    assert(profile.imageVersion == 3);

    // An empty link is not a link.
    assert(profile.bioLinks.length == 1);
    assert(profile.languages == ["eng", "fra"]);

    // Showcased badges come first whatever order they arrived in.
    assert(profile.badges.length == 2);
    assert(profile.badges[0].name == "Supporter");
    assert(profile.badges[1].name == "Early");
}

unittest
{
    // VRChat trims a stranger's record, and a reply that is not an object at
    // all reads as empty rather than throwing.
    JSONValue thin = parseJSON(`{"id":"usr_abc","displayName":"Nobody"}`);
    UserProfile profile = parseUserProfile(thin);
    assert(profile.displayName == "Nobody");
    assert(profile.bio.length == 0);
    assert(profile.bioLinks.length == 0);
    assert(profile.badges.length == 0);
    assert(profile.imageVersion == 0);

    JSONValue nonsense = JSONValue("nonsense");
    assert(parseUserProfile(nonsense).userId.length == 0);
}

unittest
{
    ProfileCache cache;

    // A first look is pending and tells the caller to go fetch it.
    bool fetch;
    assert(cache.lookup("usr_a", fetch).state == ProfileState.pending);
    assert(fetch);

    // A second look while that one is in flight does not ask twice.
    fetch = false;
    assert(cache.lookup("usr_a", fetch).state == ProfileState.pending);
    assert(fetch == false);

    UserProfile stored;
    stored.displayName = "Somebody";
    cache.store("usr_a", stored);
    fetch = false;
    ProfileLookup hit = cache.lookup("usr_a", fetch);
    assert(hit.state == ProfileState.ready);
    assert(hit.profile.displayName == "Somebody");
    assert(fetch == false);

    cache.storeFailure("usr_b", "HTTP 404");
    ProfileLookup bad = cache.lookup("usr_b", fetch);
    assert(bad.state == ProfileState.failed);
    assert(bad.error == "HTTP 404");

    // A request that could not be sent takes its own mark off, so the next
    // frame asks again rather than waiting out a reply nobody is bringing.
    fetch = false;
    assert(cache.lookup("usr_d", fetch).state == ProfileState.pending);
    cache.forget("usr_d");
    fetch = false;
    assert(cache.lookup("usr_d", fetch).state == ProfileState.pending);
    assert(fetch);

    // A dropped link clears what was in flight and what failed, while what was
    // actually fetched stays readable.
    cache.lookup("usr_c", fetch);
    cache.dropUnresolved();
    assert(cache.lookup("usr_a", fetch).state == ProfileState.ready);
    fetch = false;
    assert(cache.lookup("usr_b", fetch).state == ProfileState.pending);
    assert(fetch);
    fetch = false;
    assert(cache.lookup("usr_c", fetch).state == ProfileState.pending);
    assert(fetch);
}

unittest
{
    // Past the cap the oldest goes and the ones after it stay.
    import std.conv : to;

    ProfileCache cache;
    bool fetch;

    foreach (size_t i; 0 .. PROFILE_MAX + 1)
        cache.store("usr_" ~ i.to!string(), UserProfile.init);

    // The survivors first: a lookup of the evicted one takes a slot of its
    // own, which would push the oldest survivor out from under the check.
    assert(cache.lookup("usr_1", fetch).state == ProfileState.ready);
    assert(cache.lookup("usr_" ~ PROFILE_MAX.to!string(), fetch).state == ProfileState.ready);
    assert(cache.lookup("usr_0", fetch).state == ProfileState.pending);

    // Storing the same ID twice is one entry, not two slots.
    UserProfile one, two;
    one.displayName = "one";
    two.displayName = "two";
    cache.store("usr_2", one);
    assert(cache.lookup("usr_2", fetch).profile.displayName == "one");
    cache.store("usr_2", two);
    assert(cache.lookup("usr_2", fetch).profile.displayName == "two");
}

unittest
{
    // The snapshot owns what it carries; the profile fills the rest.
    ProfileView view;
    view.hasSnapshot = true;
    view.snapshot.displayName = "Somebody";
    view.snapshot.status = "join me";
    view.snapshot.statusDescription = null;
    view.profile.status = "busy";
    view.profile.statusDescription = "five minutes old";
    view.profile.trustRank = "Known User";

    assert(view.displayName == "Somebody");
    assert(view.status == "join me");
    // Deliberately cleared, not missing.
    assert(view.statusDescription.length == 0);
    assert(view.profile.trustRank == "Known User");

    // A stranger has no snapshot half at all, so the profile answers for it.
    ProfileView stranger;
    stranger.profile.displayName = "Nobody";
    stranger.profile.status = "active";
    assert(stranger.displayName == "Nobody");
    assert(stranger.status == "active");
}
