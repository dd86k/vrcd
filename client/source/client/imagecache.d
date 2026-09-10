/// Client-side image cache for VRChat content (gallery, icons, prints, ...).
///
/// Two layers:
/// - Disk: encoded bytes under vrcdAppDataPath("imagecache"), keyed
///   "<fileId>.<version>.<size>" (same scheme as the server cache), so a
///   restart never re-downloads through the server proxy.
/// - RAM: decoded SDL surfaces registered with the renderer, byte-capped
///   LRU. Detail images (size 0) can be multi-megabyte, hence the cap.
///
/// Main-thread only: surfaces feed the software renderer directly.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module client.imagecache;

import std.file : exists, mkdirRecurse, read, rename, write;
import std.format : format;
import std.path : buildPath;
import std.string : fromStringz;

import bindbc.sdl;
import ddlogger;

import client.directories : vrcdAppDataPath;
import client.renderer : r_register_image, r_unregister_image;

/// RAM budget for decoded surfaces. ARGB8888 at 2000x2000 is 16MB, so this
/// holds a handful of detail images plus plenty of 256px thumbnails.
private enum long RAM_CACHE_MAX_BYTES = 128L * 1024 * 1024;

private struct CachedImage
{
    int iconId;          // renderer handle (>= R_IMAGE_ID_BASE)
    SDL_Surface* surface;
    long bytes;          // decoded size, for the RAM budget
    long lastUse;        // LRU tick
}

private __gshared CachedImage[string] resident;
private __gshared long residentBytes;
private __gshared long useTick;
private __gshared string cacheDir;

/// Build the cache key for a file image. size 0 means the original file.
string imageKey(string fileId, long fileVersion, int size)
{
    return format("%s.%d.%d", fileId, fileVersion, size);
}

/// Prepare the disk cache directory. Call once at startup, after SDL_image
/// is loaded.
void initImageCache()
{
    cacheDir = vrcdAppDataPath("imagecache");
    try
        mkdirRecurse(cacheDir);
    catch (Exception e)
        logWarn("imagecache: cannot create %s: %s", cacheDir, e.msg);
}

/// Path of the on-disk encoded copy of `key`, or null when there is none.
string cachedImagePath(string key)
{
    if (cacheDir is null)
        return null;
    string path = buildPath(cacheDir, key);
    return exists(path) ? path : null;
}

/// Copy the cached copy of `key` into `dir` under a readable name, returning
/// the path written or null when the image is not on disk (nothing asked for
/// it yet, or the fetch is still in flight).
string exportCachedImage(string key, const(char)[] name, string dir)
{
    string src = cachedImagePath(key);
    if (src is null || dir.length == 0)
        return null;

    try
    {
        const(ubyte)[] data = cast(const(ubyte)[])read(src);
        mkdirRecurse(dir);

        string base = safeFileName(name, key);
        string ext = imageExtension(data);
        string path = buildPath(dir, base ~ ext);
        // Saving the same picture twice keeps both copies: which one is
        // wanted is not this side's call.
        for (int n = 2; exists(path) && n < 1000; ++n)
            path = buildPath(dir, format("%s-%d%s", base, n, ext));

        write(path, data);
        return path;
    }
    catch (Exception e)
    {
        logWarn("imagecache: cannot export %s: %s", key, e.msg);
        return null;
    }
}

/// File extension for encoded image bytes, dot included. The cache keys files
/// by id and size rather than by format, so the bytes are what says. Unknown
/// data stays ".bin": a blob named ".png" is a file that will not open.
private string imageExtension(const(ubyte)[] data)
{
    static immutable ubyte[8] pngMagic = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

    if (data.length >= 8 && data[0 .. 8] == pngMagic)
        return ".png";
    if (data.length >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF)
        return ".jpg";
    if (data.length >= 4 && data[0 .. 4] == cast(const(ubyte)[])"GIF8")
        return ".gif";
    if (data.length >= 12 && data[0 .. 4] == cast(const(ubyte)[])"RIFF"
        && data[8 .. 12] == cast(const(ubyte)[])"WEBP")
        return ".webp";
    return ".bin";
}

/// A display name is not a file name: it can hold a slash, and on Windows a
/// colon or a quote. Everything outside letters, digits, dots, dashes and
/// underscores collapses into one underscore, which leaves something both
/// recognisable and safe to write. Falls back to `fallback` when nothing
/// usable is left, which a name written entirely in another script does.
private string safeFileName(const(char)[] name, string fallback)
{
    import std.ascii : isAlphaNum;

    char[] buf;
    foreach (char c; name)
    {
        if (buf.length >= 64)
            break;
        if (isAlphaNum(c) || c == '.' || c == '-' || c == '_')
            buf ~= c;
        else if (buf.length > 0 && buf[$ - 1] != '_')
            buf ~= '_';
    }
    while (buf.length > 0 && (buf[0] == '.' || buf[0] == '_'))
        buf = buf[1 .. $];
    while (buf.length > 0 && (buf[$ - 1] == '.' || buf[$ - 1] == '_'))
        buf = buf[0 .. $ - 1];

    return buf.length > 0 ? buf.idup : fallback;
}

unittest
{
    assert(imageExtension(cast(const(ubyte)[])"\x89PNG\r\n\x1a\n....") == ".png");
    assert(imageExtension(cast(const(ubyte)[])"\xff\xd8\xff\xe0") == ".jpg");
    assert(imageExtension(cast(const(ubyte)[])"GIF89a") == ".gif");
    assert(imageExtension(cast(const(ubyte)[])"RIFF____WEBPVP8 ") == ".webp");
    assert(imageExtension(cast(const(ubyte)[])"nope") == ".bin");
    assert(imageExtension(null) == ".bin");

    assert(safeFileName("My Sticker", "fb") == "My_Sticker");
    assert(safeFileName("a/b:c", "fb") == "a_b_c");
    assert(safeFileName("...", "fb") == "fb");
    assert(safeFileName("", "fb") == "fb");
    assert(safeFileName("ふわふわ", "fb") == "fb");
}

/// Return the renderer icon id for a cached image, or 0 when the image is
/// not resident in RAM. A hit refreshes the LRU position.
int getIconId(string key)
{
    CachedImage* entry = key in resident;
    if (entry is null)
        return 0;
    entry.lastUse = ++useTick;
    return entry.iconId;
}

/// Decode encoded image bytes and make them resident, also persisting the
/// encoded form to disk. Returns false when decoding fails.
bool insertEncoded(string key, const(ubyte)[] data)
{
    if (cacheDir)
    {
        string path = buildPath(cacheDir, key);
        string tmp = path ~ ".tmp";
        try
        {
            write(tmp, data);
            rename(tmp, path);
        }
        catch (Exception e)
            logWarn("imagecache: cannot persist %s: %s", key, e.msg);
    }
    return makeResident(key, data);
}

/// Try to make an image resident from its on-disk encoded copy.
/// Returns false when absent or undecodable.
bool loadFromDisk(string key)
{
    if (getIconId(key) > 0)
        return true;
    if (cacheDir is null)
        return false;
    string path = buildPath(cacheDir, key);
    if (exists(path) == false)
        return false;
    try
    {
        const(ubyte)[] data = cast(const(ubyte)[])read(path);
        return makeResident(key, data);
    }
    catch (Exception e)
    {
        logWarn("imagecache: cannot read %s: %s", key, e.msg);
        return false;
    }
}

private bool makeResident(string key, const(ubyte)[] data)
{
    if (key in resident)
        return true;
    if (data.length == 0)
        return false;

    // IMG_Load_IO with closeIO=true releases the stream even on failure.
    SDL_IOStream* io = SDL_IOFromConstMem(data.ptr, data.length);
    if (io is null)
        return false;
    SDL_Surface* raw = IMG_Load_IO(io, true);
    if (raw is null)
    {
        logWarn("imagecache: decode failed for %s: %s", key, fromStringz( SDL_GetError() ));
        return false;
    }

    // Convert to the renderer's format once so the scaled blit never converts
    // per frame.
    SDL_Surface* converted = SDL_ConvertSurface(raw, SDL_PIXELFORMAT_ARGB8888);
    SDL_DestroySurface(raw);
    if (converted is null)
    {
        logWarn("imagecache: convert failed for %s: %s", key, fromStringz( SDL_GetError() ));
        return false;
    }

    long bytes = cast(long)converted.w * converted.h * 4;
    evictFor(bytes);

    CachedImage entry;
    entry.iconId = r_register_image(converted);
    entry.surface = converted;
    entry.bytes = bytes;
    entry.lastUse = ++useTick;
    resident[key] = entry;
    residentBytes += bytes;
    return true;
}

/// Evict least-recently-used surfaces until `incoming` bytes fit the budget.
private void evictFor(long incoming)
{
    while (resident.length > 0 && residentBytes + incoming > RAM_CACHE_MAX_BYTES)
    {
        string oldestKey;
        long oldestUse = long.max;
        foreach (string k, ref CachedImage e; resident)
        {
            if (e.lastUse < oldestUse)
            {
                oldestUse = e.lastUse;
                oldestKey = k;
            }
        }
        if (oldestKey is null)
            return;
        CachedImage victim = resident[oldestKey];
        r_unregister_image(victim.iconId);
        SDL_DestroySurface(victim.surface);
        residentBytes -= victim.bytes;
        resident.remove(oldestKey);
    }
}
