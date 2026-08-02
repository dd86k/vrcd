/// Badge art, proxied off VRChat's asset CDN.
///
/// Badges are the one picture in a profile that is not a VRChat file. They sit
/// on a public CDN rather than behind the authenticated files API, so there is
/// no file ID for `get_image` to be handed -- only an absolute URL VRChat put
/// in the user object.
///
/// A front-end could load that URL itself, and it would be six lines. It does
/// not, because the front-ends make no external requests on purpose: one that
/// phoned out would break behind a tunnel, and would tell VRChat's CDN who is
/// looking at whom. So the badge comes through here instead, on the same terms
/// as every other picture.
///
/// Which makes this a fetch-by-URL, the one place in the server where a client
/// names what to request rather than which object to request. So the URL is
/// checked hard, by `vrcd.badgeurl.isBadgeImageURL` -- which lives in `common`
/// because the web front-end checks the same rule before putting a request on
/// the link, and if the two ever disagreed the looser one would be the real
/// rule.
///
/// The CDN is not the VRChat API: no session, no cookies, no rate limiter, no
/// API mutex. A badge fetch and a friend-list refresh have nothing to contend
/// over, and it would be wrong to make them.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.badgeimage;

import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : Duration, MonoTime, dur;

import std.conv : to;

import ddlogger;
import ddcurl;

import vrcd.badgeurl : isBadgeImageURL;
import server.config : USER_AGENT;
import server.content : sniffImageMime;

/// Byte budget for cached badge art. Badges are a few kilobytes each and there
/// are not many distinct ones in the world, so this holds effectively all of
/// them; past it the oldest go.
private enum size_t CACHE_MAX_BYTES = 8 * 1024 * 1024;

/// How long a failure is remembered, so a profile full of badges VRChat has
/// stopped serving is not re-fetched on every redraw.
private enum long FAILURE_TTL = 300;

/// Shortest gap between two downloads, so a profile with a dozen badges does
/// not open a dozen connections at once.
private enum Duration DOWNLOAD_MIN_INTERVAL = dur!"msecs"(100);

/// How long to wait on the CDN before giving up.
private enum long TRANSFER_TIMEOUT_MS = 15_000;

/// Result of one badge fetch. Failure is an expected outcome (a badge whose
/// art was withdrawn, a CDN blip), not an exception.
struct BadgeImageResult
{
    bool success;
    string error;
    string mimeType;
    const(ubyte)[] data;
}

/// Fetches and caches badge art. Safe to use from any thread.
class BadgeImageService
{
    this()
    {
        this.mutex = new Mutex();
    }

    /// Fetch one badge image, from the cache when it is held.
    ///
    /// Serialized on one mutex, which is also what spaces the downloads: a
    /// profile with a dozen badges arrives as a dozen of these at once, and
    /// they are small enough that doing them one after another costs nothing
    /// worth the connections.
    BadgeImageResult fetch(string url)
    {
        BadgeImageResult result;

        if (isBadgeImageURL(url) == false)
        {
            result.error = "Not a badge image URL";
            return result;
        }

        synchronized (mutex)
        {
            if (Entry* entry = url in entries)
            {
                if (entry.data.length > 0)
                {
                    result.success = true;
                    result.mimeType = entry.mimeType;
                    result.data = entry.data;
                    return result;
                }

                import std.datetime : Clock;
                if (Clock.currTime.toUnixTime!long() - entry.stamp < FAILURE_TTL)
                {
                    result.error = entry.error;
                    return result;
                }
                drop(url);
            }

            if (client is null)
            {
                // No base URL, no cookies, no VRChat headers: this client
                // talks to a CDN and must not carry a session there.
                client = new HTTPClient();
                client.setUserAgent(USER_AGENT);
                client.setTimeout(TRANSFER_TIMEOUT_MS);
            }

            if (haveDownloadedOnce)
            {
                Duration elapsed = MonoTime.currTime - lastDownloadAt;
                if (elapsed < DOWNLOAD_MIN_INTERVAL)
                    Thread.sleep(DOWNLOAD_MIN_INTERVAL - elapsed);
            }

            try
            {
                logDebugging("BadgeImage: GET %s", url);
                HTTPResponse resp = client.get(url);
                lastDownloadAt = MonoTime.currTime;
                haveDownloadedOnce = true;

                if (resp.code != 200)
                {
                    remember(url, null, null, "HTTP " ~ resp.code.to!string);
                    result.error = "HTTP " ~ resp.code.to!string;
                    return result;
                }

                // resp.bytes() aliases the client's own buffer, which the next
                // request overwrites. This outlives the lock, so it owns its
                // memory.
                const(ubyte)[] data = resp.bytes().dup;
                if (data.length == 0)
                {
                    remember(url, null, null, "Empty response");
                    result.error = "Empty response";
                    return result;
                }

                string mimeType = sniffImageMime(data);
                // A CDN answering with something that is not a picture is a
                // redirect to an error page, not a badge.
                if (mimeType == "application/octet-stream")
                {
                    remember(url, null, null, "Not an image");
                    result.error = "Not an image";
                    return result;
                }

                remember(url, data, mimeType, null);
                result.success = true;
                result.mimeType = mimeType;
                result.data = data;
                return result;
            }
            catch (Exception e)
            {
                remember(url, null, null, e.msg);
                result.error = e.msg;
                return result;
            }
        }
    }

private:
    struct Entry
    {
        const(ubyte)[] data;
        string mimeType;
        string error;
        /// When it was stored, which only a failure is read back for.
        long stamp;
    }

    Mutex mutex;
    HTTPClient client;
    Entry[string] entries;
    /// URLs holding bytes, oldest first. Failures are not listed: they hold
    /// none, and expire on their own.
    string[] order;
    size_t bytes;
    MonoTime lastDownloadAt;
    bool haveDownloadedOnce;

    /// File one answer, evicting older art to stay inside the budget. Caller
    /// holds the lock.
    void remember(string url, const(ubyte)[] data, string mimeType, string error)
    {
        import std.datetime : Clock;

        drop(url);

        Entry entry;
        entry.data = data;
        entry.mimeType = mimeType;
        entry.error = error;
        entry.stamp = Clock.currTime.toUnixTime!long();
        entries[url] = entry;

        if (data.length == 0)
            return;

        order ~= url;
        bytes += data.length;

        while (bytes > CACHE_MAX_BYTES && order.length > 1)
        {
            string oldest = order[0];
            order = order[1 .. $];
            if (Entry* victim = oldest in entries)
            {
                bytes -= victim.data.length;
                entries.remove(oldest);
            }
        }
    }

    /// Remove one entry and its bytes. Caller holds the lock.
    void drop(string url)
    {
        Entry* entry = url in entries;
        if (entry is null)
            return;

        if (entry.data.length > 0)
        {
            bytes -= entry.data.length;
            string[] kept;
            foreach (string held; order)
            {
                if (held != url)
                    kept ~= held;
            }
            order = kept;
        }
        entries.remove(url);
    }
}

unittest
{
    // A URL that does not pass never reaches the network, and says so.
    BadgeImageService badges = new BadgeImageService();
    BadgeImageResult refused = badges.fetch("https://evil.invalid/badges/x.png");
    assert(refused.success == false);
    assert(refused.error == "Not a badge image URL");
}
