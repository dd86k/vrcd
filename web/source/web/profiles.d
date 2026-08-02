/// Cache for user profiles fetched through vrcd-server.
///
/// Same shape as the image cache, and for the same reason: only vrcd-server
/// holds the VRChat session, so a profile has to travel down the JSON-L link
/// and back out over HTTP, which is far too slow to do inside an HTTP handler
/// -- ddhttpd runs those on its poll thread, and one waiting on the link would
/// stall every other request.
///
/// So nothing here blocks. A lookup either hands back a profile or says
/// "pending", the caller asks vrcd-server for it, and the browser comes back
/// for it. The page retries on a 202 until it lands.
///
/// Unlike an image, a profile does go stale: a bio or a status can change with
/// no event to say so. So entries expire, and the browser asking again after
/// that is what refreshes them. vrcd-server caches these too, so a re-ask that
/// lands inside its own window costs no VRChat call.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module web.profiles;

import core.sync.mutex : Mutex;
import std.datetime : Clock;

/// How long a fetched profile is served before it is asked for again.
private enum long PROFILE_TTL = 300;

/// How long an unanswered request is left alone before it is asked for again.
/// A link that dropped mid-request never answers, and without this the entry
/// would stay pending until the process restarts.
private enum long REQUEST_TIMEOUT = 20;

/// How long a failure is remembered. Long enough that a page redrawing on
/// every snapshot does not hammer the link, short enough that a transient
/// error (the link was down) heals on its own.
private enum long FAILURE_TTL = 60;

/// How many profiles are held. A profile is a few kilobytes and only somebody
/// looked at deliberately, so this is generous; past it the oldest go.
private enum size_t PROFILE_MAX = 256;

/// Where a lookup stands.
enum ProfileState
{
    /// Being fetched. The caller may have to start that fetch itself.
    pending,
    /// The profile is in `json`.
    ready,
    /// VRChat or vrcd-server refused it; `error` says why.
    failed,
}

/// Result of one cache lookup.
struct ProfileLookup
{
    ProfileState state;
    /// The `user` object as vrcd-server built it, ready to serve as a body.
    string json;
    string error;
}

/// Bounded profile cache, safe to use from any thread.
class ProfileCache
{
    this()
    {
        this.mutex = new Mutex();
    }

    /// Look one profile up.
    ///
    /// Params:
    ///   userId = VRChat user ID (usr_...).
    ///   startFetch = Set when the caller has to ask vrcd-server for this
    ///                profile: nothing usable is cached and nothing is on its
    ///                way.
    ProfileLookup lookup(string userId, out bool startFetch)
    {
        long now = Clock.currTime.toUnixTime!long();

        synchronized (mutex)
        {
            if (Entry *entry = userId in entries)
            {
                final switch (entry.state) with (ProfileState)
                {
                case ready:
                    if (now - entry.stamp < PROFILE_TTL)
                        return ProfileLookup(ready, entry.json);
                    // Stale, but still worth serving: the page gets what we
                    // have now rather than a spinner, and the fetch started
                    // here lands under it. The entry stays `ready` so a second
                    // browser does not start a second fetch.
                    entry.stamp = now;
                    startFetch = true;
                    return ProfileLookup(ready, entry.json);

                case failed:
                    if (now - entry.stamp < FAILURE_TTL)
                        return ProfileLookup(failed, null, entry.error);
                    break; // Expired; fall through to asking again.

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
    }

    /// Store a fetched profile.
    void store(string userId, string json)
    {
        synchronized (mutex)
            remember(userId, Entry(ProfileState.ready,
                Clock.currTime.toUnixTime!long(), json));
    }

    /// Remember that this profile could not be fetched.
    void storeFailure(string userId, string error)
    {
        synchronized (mutex)
            remember(userId, Entry(ProfileState.failed,
                Clock.currTime.toUnixTime!long(), null, error));
    }

    /// Forget one entry, back to holding nothing for it.
    ///
    /// The lookup that came back `pending` marked the entry as being fetched.
    /// When the caller then finds it cannot send the request at all, that mark
    /// is a lie the next 20 seconds of lookups would believe -- and answer with
    /// a 202 for a reply nobody is bringing.
    void forget(string userId)
    {
        synchronized (mutex)
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
    }

    /// Forget everything that is not an answer. Called when the link drops.
    ///
    /// Fetched profiles stay: they are worth reading while disconnected, the
    /// same way the content lists are. What goes is a request whose reply died
    /// with the socket, and a failure that was only ever "the link was down" --
    /// both would otherwise outlive their reason by a timeout the reconnect
    /// has no way to cut short.
    void dropUnresolved()
    {
        synchronized (mutex)
        {
            string[] kept;
            foreach (string userId; order)
            {
                Entry *entry = userId in entries;
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
    }

private:
    struct Entry
    {
        ProfileState state;
        /// When it was requested (pending), stored (ready), or failed.
        long stamp;
        string json;
        string error;
    }

    Mutex mutex;
    Entry[string] entries;
    /// User IDs in insertion order, oldest first.
    string[] order;

    /// Add or replace one entry, evicting the oldest past the cap. Caller
    /// holds the lock.
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

unittest
{
    ProfileCache cache = new ProfileCache();

    // A first look is pending and tells the caller to go fetch it.
    bool fetch;
    ProfileLookup miss = cache.lookup("usr_a", fetch);
    assert(miss.state == ProfileState.pending);
    assert(fetch);

    // A second look while that one is in flight does not ask twice.
    fetch = false;
    assert(cache.lookup("usr_a", fetch).state == ProfileState.pending);
    assert(fetch == false);

    cache.store("usr_a", `{"displayName":"Somebody"}`);
    fetch = false;
    ProfileLookup hit = cache.lookup("usr_a", fetch);
    assert(hit.state == ProfileState.ready);
    assert(hit.json == `{"displayName":"Somebody"}`);
    assert(fetch == false);

    cache.storeFailure("usr_b", "HTTP 404");
    ProfileLookup bad = cache.lookup("usr_b", fetch);
    assert(bad.state == ProfileState.failed);
    assert(bad.error == "HTTP 404");

    // A request that could not be sent takes its own mark off, so the next
    // look asks again rather than waiting out a reply nobody is bringing.
    fetch = false;
    assert(cache.lookup("usr_d", fetch).state == ProfileState.pending);
    cache.forget("usr_d");
    fetch = false;
    assert(cache.lookup("usr_d", fetch).state == ProfileState.pending);
    assert(fetch);

    // A dropped link resolves what was in flight and forgets what failed,
    // while what was actually fetched stays readable.
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
    // Past the cap the oldest goes, and the ones after it stay.
    ProfileCache cache = new ProfileCache();
    bool fetch;

    import std.conv : to;
    foreach (size_t i; 0 .. PROFILE_MAX + 1)
        cache.store("usr_" ~ i.to!string(), `{}`);

    // The survivors first: a lookup of the evicted one takes a slot of its
    // own, which would push the oldest survivor out from under the check.
    assert(cache.lookup("usr_1", fetch).state == ProfileState.ready);
    assert(cache.lookup("usr_" ~ PROFILE_MAX.to!string(), fetch).state
        == ProfileState.ready);
    assert(cache.lookup("usr_0", fetch).state == ProfileState.pending);

    // Storing the same ID twice is one entry, not two slots.
    cache.store("usr_2", `{"a":1}`);
    assert(cache.lookup("usr_2", fetch).json == `{"a":1}`);
    cache.store("usr_2", `{"a":2}`);
    assert(cache.lookup("usr_2", fetch).json == `{"a":2}`);
}
