/// Cache for images proxied from vrcd-server.
///
/// vrcd-server holds the VRChat session, so a thumbnail cannot be fetched by
/// the browser: it has to travel down the JSON-L link as base64 and back out
/// over HTTP. That round trip is far too slow to do inside an HTTP handler,
/// which in ddhttpd runs on the same thread as the poll loop and would stall
/// every other request while it waited.
///
/// So nothing here blocks. A lookup either hands back bytes or says "pending",
/// the caller asks vrcd-server for it, and the browser comes back for it. The
/// page retries on a 202 until the bytes are there.
///
/// Entries are keyed by file, version, and size, all three of which are part
/// of what VRChat serves, so an entry never goes stale: a new upload is a new
/// file ID. The only reason to evict is the byte budget.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module web.images;

import core.sync.mutex : Mutex;
import std.conv : to;
import std.datetime : Clock;
import std.file : exists, isDir, read, setTimes;
import std.path : buildPath, expandTilde;

import ddlogger;

/// How long an unanswered request is left alone before it is asked for again.
/// A link that dropped mid-request never answers, and without this the entry
/// would stay pending until the process restarts.
private enum long REQUEST_TIMEOUT = 20;

/// How long a failure is remembered. Long enough that a grid of broken
/// thumbnails does not hammer the link, short enough that a transient error
/// (the link was down) heals on its own.
private enum long FAILURE_TTL = 60;

/// Where a lookup stands.
enum ImageState
{
    /// Being fetched. The caller may have to start that fetch itself.
    pending,
    /// Bytes are in `data`.
    ready,
    /// VRChat or vrcd-server refused it; `error` says why.
    failed,
}

/// Result of one cache lookup.
struct ImageLookup
{
    ImageState state;
    const(ubyte)[] data;
    string mimeType;
    string error;
}

/// Bounded in-memory image cache, safe to use from any thread.
class ImageCache
{
    /// Params:
    ///   maxBytes = Byte budget for stored images. Oldest go first.
    this(size_t maxBytes)
    {
        this.maxBytes = maxBytes;
        this.mutex = new Mutex();
    }

    /// Cache key for one image request.
    static string key(string fileId, long fileVersion, int size)
    {
        return fileId ~ "/" ~ fileVersion.to!string() ~ "/" ~ size.to!string();
    }

    /// Look one image up.
    ///
    /// Params:
    ///   cacheKey = Key from `key()`.
    ///   startFetch = Set when the caller has to ask vrcd-server for this
    ///                image: nothing is cached and nothing is on its way.
    ImageLookup lookup(string cacheKey, out bool startFetch)
    {
        long now = Clock.currTime.toUnixTime!long();

        synchronized (mutex)
        {
            if (Entry *entry = cacheKey in entries)
            {
                final switch (entry.state) with (ImageState)
                {
                case ready:
                    return ImageLookup(ready, entry.data, entry.mimeType);

                case failed:
                    if (now - entry.stamp < FAILURE_TTL)
                        return ImageLookup(failed, null, null, entry.error);
                    break; // Expired; fall through to asking again.

                case pending:
                    if (now - entry.stamp < REQUEST_TIMEOUT)
                        return ImageLookup(pending);
                    break; // The answer never came; ask again.
                }
            }

            entries[cacheKey] = Entry(ImageState.pending, now);
            startFetch = true;
            return ImageLookup(ImageState.pending);
        }
    }

    /// Store fetched bytes, evicting older entries to stay inside the budget.
    void store(string cacheKey, const(ubyte)[] data, string mimeType)
    {
        synchronized (mutex)
        {
            drop(cacheKey);

            Entry entry;
            entry.state = ImageState.ready;
            entry.stamp = Clock.currTime.toUnixTime!long();
            entry.data = data;
            entry.mimeType = mimeType;
            entries[cacheKey] = entry;

            order ~= cacheKey;
            bytes += data.length;

            // Oldest first. Nothing is pinned: a browser that loses the race
            // asks again, which is the same path a cold cache takes.
            while (bytes > maxBytes && order.length > 1)
            {
                string oldest = order[0];
                order = order[1 .. $];
                if (Entry *victim = oldest in entries)
                {
                    bytes -= victim.data.length;
                    entries.remove(oldest);
                }
            }
        }
    }

    /// Remember that this image could not be fetched.
    void storeFailure(string cacheKey, string error)
    {
        synchronized (mutex)
        {
            drop(cacheKey);
            entries[cacheKey] = Entry(ImageState.failed,
                Clock.currTime.toUnixTime!long(), null, null, error);
        }
    }

private:
    struct Entry
    {
        ImageState state;
        /// When it was requested (pending), stored (ready), or failed.
        long stamp;
        const(ubyte)[] data;
        string mimeType;
        string error;
    }

    Mutex mutex;
    size_t maxBytes;
    size_t bytes;
    Entry[string] entries;
    /// Keys of stored images, oldest first. Only `ready` entries are listed,
    /// since only those hold bytes worth evicting.
    string[] order;

    /// Remove one entry and its bytes. Caller holds the lock.
    void drop(string cacheKey)
    {
        Entry *entry = cacheKey in entries;
        if (entry is null)
            return;

        if (entry.state == ImageState.ready)
        {
            bytes -= entry.data.length;
            string[] kept;
            foreach (string k; order)
            {
                if (k != cacheKey)
                    kept ~= k;
            }
            order = kept;
        }
        entries.remove(cacheKey);
    }
}

/// One image read straight out of vrcd-server's own cache directory.
struct DiskImage
{
    bool found;
    ubyte[] data;
    string mimeType;
}

/// Read one image from vrcd-server's image cache, when that server is on this
/// host and its cache directory is readable.
///
/// This is a shortcut, never a substitute: only vrcd-server holds the VRChat
/// session, the rate limiter and the spacing between downloads, so a miss
/// still has to travel down the link. What it saves is the base64 round trip
/// (a third more bytes than the picture) on everything already downloaded,
/// which for a grid of thumbnails is most of them.
///
/// Two properties of the server's cache make reading it from outside safe.
/// Entries are written to a temporary name and renamed into place, so a
/// half-written file is never visible. And the name is the whole identity of
/// the content -- file, version, size -- so there is no such thing as a stale
/// hit: a new upload is a new file ID.
///
/// Params:
///   dir = vrcd-server's image cache directory.
///   fileId = VRChat file ID (file_...).
///   fileVersion = File version.
///   size = 0 for the original, or a thumbnail edge.
DiskImage readFromServerCache(string dir, string fileId, long fileVersion, int size)
{
    DiskImage result;
    if (dir.length == 0 || safeFileId(fileId) == false)
        return result;

    // Same name vrcd-server writes: <file id>.<version>.<size>.
    string path = buildPath(dir,
        fileId ~ "." ~ fileVersion.to!string() ~ "." ~ size.to!string());

    // Eviction can take the file out from under us between the two calls, so
    // a read that fails is a miss and not an error: the link answers instead.
    try
    {
        if (exists(path) == false)
            return result;

        result.data = cast(ubyte[])read(path);
        if (result.data.length == 0)
            return DiskImage.init;

        // vrcd-server evicts by mtime and bumps it on its own cache hits.
        // Serving from here without bumping would make the entries this page
        // uses most look like the coldest ones it holds. Best effort: the
        // directory may well be another user's.
        try setTimes(path, Clock.currTime, Clock.currTime);
        catch (Exception) {}

        result.found = true;
        result.mimeType = sniffMime(result.data);
        return result;
    }
    catch (Exception ex)
    {
        logDebugging("Image cache read failed for %s: %s", path, ex.msg);
        return DiskImage.init;
    }
}

/// Pick vrcd-server's image cache directory, or null to go through the link
/// for everything.
///
/// A directory given on the command line that is not there is a warning and
/// not a startup error: sharing a host with vrcd-server is a deployment
/// choice, and losing the shortcut costs speed rather than function.
string findServerImageCache(string given)
{
    if (given.length > 0)
    {
        string path = expandTilde(given);
        if (usableCacheDir(path))
        {
            logInfo("Reading images from vrcd-server's cache at %s", path);
            return path;
        }

        logWarn("No image cache at %s; images will come over the link", path);
        return null;
    }

    // vrcd-server's own defaults, from its Config.defaults(). A hit means the
    // two are on one host under one user, which is the common case: the link
    // is plain TCP and expected on loopback anyway.
    string[] candidates;
    version (Windows)
    {
        import std.process : environment;
        candidates ~= buildPath(environment.get("APPDATA", "."), "vrcd", "imagecache");
    }
    else
    {
        candidates ~= expandTilde("~/.local/share/vrcd/imagecache");
    }

    foreach (string path; candidates)
    {
        if (usableCacheDir(path) == false)
            continue;

        logInfo("Found vrcd-server's image cache at %s", path);
        return path;
    }
    return null;
}

/// Whether this path is a directory we can read.
private bool usableCacheDir(string path)
{
    try return exists(path) && isDir(path);
    catch (Exception) return false;
}

/// Whether this file ID can be put in a path. The route checks the shape
/// already; this is the guard for anything else that reaches this module.
private bool safeFileId(string fileId)
{
    if (fileId.length == 0 || fileId.length > 64)
        return false;

    foreach (char c; fileId)
    {
        if (c == '/' || c == '\\' || c == ':' || c == '.')
            return false;
    }
    return true;
}

/// What the bytes are, from their first few. Mirrors vrcd-server's own
/// sniffing, which is what fills the cache these bytes come out of.
private string sniffMime(const(ubyte)[] data)
{
    if (data.length >= 8 &&
        data[0] == 0x89 && data[1] == 'P' && data[2] == 'N' && data[3] == 'G')
        return "image/png";
    if (data.length >= 3 &&
        data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF)
        return "image/jpeg";
    if (data.length >= 4 && data[0 .. 4] == cast(const(ubyte)[])"GIF8")
        return "image/gif";
    if (data.length >= 12 && data[0 .. 4] == cast(const(ubyte)[])"RIFF" &&
        data[8 .. 12] == cast(const(ubyte)[])"WEBP")
        return "image/webp";
    return "application/octet-stream";
}

unittest
{
    ImageCache cache = new ImageCache(16);

    // A first look is pending and tells the caller to go fetch it.
    bool fetch;
    ImageLookup miss = cache.lookup("file_a/1/256", fetch);
    assert(miss.state == ImageState.pending);
    assert(fetch);

    // A second look while that one is in flight does not ask twice.
    fetch = false;
    assert(cache.lookup("file_a/1/256", fetch).state == ImageState.pending);
    assert(fetch == false);

    ubyte[8] png = 1;
    cache.store("file_a/1/256", png, "image/png");
    ImageLookup hit = cache.lookup("file_a/1/256", fetch);
    assert(hit.state == ImageState.ready);
    assert(hit.data.length == 8);
    assert(hit.mimeType == "image/png");

    // Budget is 16 bytes, so a third 8 byte image evicts the first.
    cache.store("file_b/1/256", png, "image/png");
    cache.store("file_c/1/256", png, "image/png");
    fetch = false;
    assert(cache.lookup("file_a/1/256", fetch).state == ImageState.pending);
    assert(fetch);
    assert(cache.lookup("file_c/1/256", fetch).state == ImageState.ready);

    cache.storeFailure("file_d/1/256", "HTTP 404");
    ImageLookup bad = cache.lookup("file_d/1/256", fetch);
    assert(bad.state == ImageState.failed);
    assert(bad.error == "HTTP 404");
}

unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;

    string dir = buildPath(tempDir(), "vrcd-web-imagecache-test");
    mkdirRecurse(dir);
    scope(exit) rmdirRecurse(dir);

    // A PNG signature is enough to be sniffed as one.
    ubyte[] png = [ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0 ];
    write(buildPath(dir, "file_abc.2.256"), png);

    DiskImage hit = readFromServerCache(dir, "file_abc", 2, 256);
    assert(hit.found);
    assert(hit.data.length == png.length);
    assert(hit.mimeType == "image/png");

    // Version and size are part of the identity, so neither is a hit.
    assert(readFromServerCache(dir, "file_abc", 1, 256).found == false);
    assert(readFromServerCache(dir, "file_abc", 2, 512).found == false);
    assert(readFromServerCache(dir, "file_missing", 1, 256).found == false);

    // No directory means everything goes over the link.
    assert(readFromServerCache(null, "file_abc", 2, 256).found == false);

    // Nothing that could climb out of the directory is looked up at all.
    write(buildPath(dir, "escaped"), png);
    assert(readFromServerCache(dir, "../escaped", 2, 256).found == false);
    assert(readFromServerCache(dir, "sub/file_abc", 2, 256).found == false);
}
