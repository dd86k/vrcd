/// VRChat user content: gallery, icons, stickers, emoji, prints, inventory.
///
/// Wraps the VRChat files/prints/inventory REST endpoints and proxies image
/// bytes to clients, since only the server holds the VRChat auth cookie.
/// Downloaded images are cached on disk; versioned file content is
/// immutable, so entries never expire (only evicted for space).
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.content;

import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : Duration, MonoTime, dur;

import std.algorithm.sorting : sort;
import std.conv : to;
import std.datetime : Clock, UTC;
import std.file;
import std.json;
import std.path : buildPath, baseName;
import std.string : startsWith;

import ddlogger;
import ddcurl;

import server.ratelimit;
import server.vrchat.auth : putJSON;

/// Result of an image fetch. Failure is an expected outcome here (403 on
/// other users' content, 404 on stale references), not an exception.
struct ImageResult
{
    bool success;
    string error;
    string mimeType;
    const(ubyte)[] data;
}

/// Result of a management action or upload against the VRChat API.
struct ActionResult
{
    bool success;
    string error;
    JSONValue data;
}

/// Image tags accepted by GET /files and POST /file/image.
immutable string[] IMAGE_TAGS = [ "icon", "gallery", "emoji", "sticker" ];

/// Whether this tag is one of the four user-content image kinds.
bool isImageTag(string tag)
{
    foreach (string t; IMAGE_TAGS)
        if (t == tag)
            return true;
    return false;
}

/// Whether this is a valid inventory equip slot name.
bool isEquipSlot(string slot)
{
    switch (slot)
    {
        case "drone", "portal", "warp":
            return true;
        default:
            return false;
    }
}

/// Upload limits, matching what VRChat/VRCX enforce.
private enum size_t UPLOAD_MAX_BYTES = 10 * 1024 * 1024;
private enum int UPLOAD_MAX_DIMENSION = 2000;

/// Minimum spacing between uncached image downloads, to stay polite while
/// a client walks a whole grid of thumbnails.
private immutable Duration DOWNLOAD_MIN_INTERVAL = dur!"msecs"(250);

/// Minimum spacing between print uploads (VRCX uses the same figure).
private immutable Duration PRINT_UPLOAD_MIN_INTERVAL = dur!"msecs"(2500);

/// Timeout for large transfers (image downloads, multipart uploads).
private enum long TRANSFER_TIMEOUT_MS = 60_000;
/// HTTPClient default timeout, restored after large transfers.
private enum long DEFAULT_TIMEOUT_MS = 10_000;

/// VRChat user content service.
///
/// All VRChat API access is serialized through the shared API mutex and
/// checked against the rate limiter, same as every other caller.
class ContentService
{
    private HTTPClient client;
    private RateLimitTracker rateLimiter;
    private Mutex apiMutex;
    private string cacheDir;
    private long cacheMaxBytes;
    private string selfUserId;
    private MonoTime lastDownloadAt;
    private bool haveDownloadedOnce;
    private MonoTime lastPrintUploadAt;
    private bool haveUploadedPrintOnce;

    this(HTTPClient client, RateLimitTracker rateLimiter, Mutex apiMutex,
        string cacheDir, long cacheMaxBytes)
    {
        this.client = client;
        this.rateLimiter = rateLimiter;
        this.apiMutex = apiMutex;
        this.cacheDir = cacheDir;
        this.cacheMaxBytes = cacheMaxBytes;

        mkdirRecurse(cacheDir);
    }

    /// Set the logged-in user's ID, required for prints and profile icon.
    void setSelfUserId(string userId)
    {
        selfUserId = userId;
    }

    //
    // Listing
    //

    /// List own files by image tag (icon, gallery, emoji, sticker).
    /// Returns a trimmed JSON array. Throws on failure.
    JSONValue listFiles(string tag, int n, int offset)
    {
        if (isImageTag(tag) == false)
            throw new Exception("Invalid tag: " ~ tag);
        if (n < 1) n = 1;
        if (n > 100) n = 100;
        if (offset < 0) offset = 0;

        string path = "/files?tag=" ~ tag ~
            "&n=" ~ n.to!string ~ "&offset=" ~ offset.to!string;
        JSONValue json = getJSON(path);

        JSONValue files = JSONValue.emptyArray;
        foreach (ref JSONValue file; json.array)
            files.array ~= trimFile(file);
        return files;
    }

    /// List own prints. VRC+ caps prints well below 100, so one page is
    /// enough. Throws on failure.
    JSONValue listPrints()
    {
        if (selfUserId.length == 0)
            throw new Exception("Self user id not known yet");

        JSONValue json = getJSON("/prints/user/" ~ selfUserId ~ "?n=100");

        JSONValue prints = JSONValue.emptyArray;
        foreach (ref JSONValue print; json.array)
            prints.array ~= trimPrint(print);
        return prints;
    }

    /// List own inventory items (props, bundles, drone/portal skins, ...).
    /// Pages through the endpoint up to a sane cap. Throws on failure.
    /// Emoji and stickers are excluded here: they have their own STUFF
    /// sections sourced from the files endpoint, so the Items view only
    /// shows true inventory items.
    /// Params:
    ///   archived = Include archived items instead of active ones.
    ///   totalCount = Receives the server-reported total.
    JSONValue listInventory(bool archived, out long totalCount)
    {
        enum int PAGE_SIZE = 100;
        enum int MAX_ITEMS = 500;

        JSONValue items = JSONValue.emptyArray;
        int offset;
        while (true)
        {
            string path = "/inventory?n=" ~ PAGE_SIZE.to!string ~
                "&offset=" ~ offset.to!string ~
                "&notTypes=emoji,sticker" ~
                "&inventoryItemArchived=" ~ (archived ? "true" : "false");
            JSONValue page = getJSON(path);

            JSONValue[] data;
            if (JSONValue* v = "data" in page)
                data = v.array;
            if (const(JSONValue)* v = "totalCount" in page)
                totalCount = v.integer;

            foreach (ref JSONValue item; data)
                items.array ~= trimInventoryItem(item);

            offset += cast(int) data.length;
            if (data.length < PAGE_SIZE || offset >= totalCount || offset >= MAX_ITEMS)
                break;
        }
        return items;
    }

    /// List inventory drops (timed item giveaways). Throws on failure.
    JSONValue listInventoryDrops()
    {
        return getJSON("/inventory/drops");
    }

    //
    // Images
    //

    /// Fetch image bytes for a file, from the disk cache or VRChat.
    /// Params:
    ///   fileId = VRChat file ID (file_...).
    ///   fileVersion = File version (1+; version 0 is an empty placeholder).
    ///   size = 0 for the original file, or a thumbnail edge size
    ///          (128/256/512/1024) served by VRChat's /image endpoint.
    ImageResult getImage(string fileId, long fileVersion, int size)
    {
        ImageResult result;

        // The ID lands in a filesystem path; reject anything fishy.
        if (isValidFileId(fileId) == false)
        {
            result.error = "Invalid file id";
            return result;
        }
        if (fileVersion < 1)
        {
            result.error = "Invalid file version";
            return result;
        }
        switch (size)
        {
            case 0, 128, 256, 512, 1024:
                break;
            default:
                result.error = "Invalid size";
                return result;
        }

        string cachePath = buildPath(cacheDir,
            fileId ~ "." ~ fileVersion.to!string ~ "." ~ size.to!string);

        // Cache hit: bump mtime so LRU eviction keeps warm entries.
        if (exists(cachePath))
        {
            try
            {
                const(ubyte)[] data = cast(const(ubyte)[]) read(cachePath);
                setTimes(cachePath, Clock.currTime, Clock.currTime);
                result.success = true;
                result.mimeType = sniffImageMime(data);
                result.data = data;
                return result;
            }
            catch (Exception e)
            {
                logWarn("getImage: cache read failed for %s: %s", cachePath, e.msg);
                // Fall through to a fresh download.
            }
        }

        string path = size == 0 ?
            "/file/" ~ fileId ~ "/" ~ fileVersion.to!string ~ "/file" :
            "/image/" ~ fileId ~ "/" ~ fileVersion.to!string ~ "/" ~ size.to!string;

        apiMutex.lock();
        scope(exit) apiMutex.unlock();

        if (rateLimiter && rateLimiter.isBlocked())
        {
            result.error = "Rate limited by VRChat, try again later";
            return result;
        }

        // Space out uncached downloads; a client painting a grid of
        // thumbnails should not hammer the API.
        if (haveDownloadedOnce)
        {
            Duration elapsed = MonoTime.currTime - lastDownloadAt;
            if (elapsed < DOWNLOAD_MIN_INTERVAL)
                Thread.sleep(DOWNLOAD_MIN_INTERVAL - elapsed);
        }

        client.setTimeout(TRANSFER_TIMEOUT_MS);
        scope(exit) client.setTimeout(DEFAULT_TIMEOUT_MS);

        try
        {
            logDebugging("getImage: GET %s", path);
            HTTPResponse resp = client.get(path);
            if (rateLimiter)
                rateLimiter.update(resp);
            lastDownloadAt = MonoTime.currTime;
            haveDownloadedOnce = true;

            if (resp.code != 200)
            {
                result.error = "HTTP " ~ resp.code.to!string;
                return result;
            }

            // resp.bytes() aliases the HTTPClient's internal buffer, which
            // the next request on this shared client reallocates and
            // overwrites. This result outlives apiMutex (the caller
            // base64-encodes it after we return), so it must own its memory.
            const(ubyte)[] data = resp.bytes().dup;
            if (data.length == 0)
            {
                result.error = "Empty response";
                return result;
            }

            saveToCache(cachePath, data);

            result.success = true;
            result.mimeType = sniffImageMime(data);
            result.data = data;
            return result;
        }
        catch (Exception e)
        {
            result.error = e.msg;
            return result;
        }
    }

    //
    // Management actions
    //

    /// Delete an own file (gallery image, icon, emoji, sticker).
    ActionResult deleteFile(string fileId)
    {
        if (isValidFileId(fileId) == false)
            return ActionResult(false, "Invalid file id");
        return simpleCall("DELETE", "/file/" ~ fileId, null);
    }

    /// Delete an own print.
    ActionResult deletePrint(string printId)
    {
        if (printId.startsWith("prnt_") == false)
            return ActionResult(false, "Invalid print id");
        return simpleCall("DELETE", "/prints/" ~ printId, null);
    }

    /// Set (or clear, with an empty fileId) the profile icon. VRC+ only.
    ActionResult setUserIcon(string fileId)
    {
        if (selfUserId.length == 0)
            return ActionResult(false, "Self user id not known yet");
        if (fileId.length && isValidFileId(fileId) == false)
            return ActionResult(false, "Invalid file id");

        // VRChat stores the icon as a file URL; version is literally 1.
        string url;
        if (fileId.length)
            url = "https://api.vrchat.cloud/api/1/file/" ~ fileId ~ "/1";
        JSONValue payload = JSONValue(["userIcon": JSONValue(url)]);

        ActionResult result = simpleCall("PUT", "/users/" ~ selfUserId,
            payload.toString());
        if (result.success == false && result.error == "HTTP 403")
            result.error = "HTTP 403 (VRC+ required)";
        return result;
    }

    /// Equip, unequip, or consume an inventory item.
    /// Params:
    ///   action = "equip", "unequip", or "consume".
    ///   inventoryId = Inventory item ID (inv_...). Unused for "unequip",
    ///                 which targets the slot instead.
    ///   slot = Equip slot (drone, portal, warp). Required for "equip"
    ///          (request body) and "unequip" (path selector).
    ActionResult inventoryAction(string action, string inventoryId, string slot)
    {
        switch (action)
        {
            case "equip":
                if (inventoryId.startsWith("inv_") == false)
                    return ActionResult(false, "Invalid inventory id");
                if (isEquipSlot(slot) == false)
                    return ActionResult(false, "Invalid equip slot");
                JSONValue payload = JSONValue(["equipSlot": JSONValue(slot)]);
                return simpleCall("PUT",
                    "/inventory/" ~ inventoryId ~ "/equip", payload.toString());
            case "unequip":
                // Unequip addresses the slot, not the item: the slot name
                // takes the item ID's place in the path.
                if (isEquipSlot(slot) == false)
                    return ActionResult(false, "Invalid equip slot");
                return simpleCall("DELETE",
                    "/inventory/" ~ slot ~ "/equip", null);
            case "consume":
                if (inventoryId.startsWith("inv_") == false)
                    return ActionResult(false, "Invalid inventory id");
                return simpleCall("PUT",
                    "/inventory/" ~ inventoryId ~ "/consume", "{}");
            default:
                return ActionResult(false, "Unknown action: " ~ action);
        }
    }

    //
    // Uploads
    //

    /// Upload a PNG as a gallery image, icon, emoji, or sticker.
    /// extra carries optional animated-emoji fields straight from the
    /// client message (animation_style, frames, frames_over_time,
    /// loop_style, mask_tag).
    ActionResult uploadImage(string tag, const(ubyte)[] png, JSONValue extra)
    {
        if (isImageTag(tag) == false)
            return ActionResult(false, "Invalid tag: " ~ tag);

        int width, height;
        string verr = validatePNG(png, width, height);
        if (verr)
            return ActionResult(false, verr);

        // Stickers and emoji must be square (VRChat rejects them otherwise).
        if ((tag == "sticker" || tag == "emoji") && width != height)
            return ActionResult(false, "Stickers and emoji must be square");

        MultipartForm form = new MultipartForm();
        form.addField("tag", tag);
        string maskTag;
        if (extra.type == JSONType.object)
        {
            if (const(JSONValue)* v = "animation_style" in extra)
                form.addField("animationStyle", v.str);
            if (const(JSONValue)* v = "frames" in extra)
                form.addField("frames", v.integer.to!string);
            if (const(JSONValue)* v = "frames_over_time" in extra)
                form.addField("framesOverTime", v.integer.to!string);
            if (const(JSONValue)* v = "loop_style" in extra)
                form.addField("loopStyle", v.str);
            if (const(JSONValue)* v = "mask_tag" in extra)
                maskTag = v.str;
        }
        // Stickers require a maskTag; VRChat returns HTTP 400 without one.
        // Default to "square" (what VRCX sends) when the client omits it.
        if (maskTag.length == 0 && tag == "sticker")
            maskTag = "square";
        if (maskTag.length)
            form.addField("maskTag", maskTag);
        form.addFile("file", "blob", "image/png", png);

        ActionResult result = multipartCall("/file/image", form);
        if (result.success)
            result.data = trimFile(result.data);
        else if (result.error == "HTTP 403")
            result.error = "HTTP 403 (VRC+ required)";
        return result;
    }

    /// Upload a PNG as a print. Throttled to one upload per 2.5 seconds.
    ActionResult uploadPrint(const(ubyte)[] png, string timestamp,
        string note, string worldId, string worldName)
    {
        int width, height;
        string verr = validatePNG(png, width, height);
        if (verr)
            return ActionResult(false, verr);

        // Same politeness throttle as VRCX. Reject rather than sleep: a
        // sleep here would stall every other VRChat API caller.
        if (haveUploadedPrintOnce)
        {
            Duration elapsed = MonoTime.currTime - lastPrintUploadAt;
            if (elapsed < PRINT_UPLOAD_MIN_INTERVAL)
                return ActionResult(false, "Print upload throttled, try again shortly");
        }

        if (timestamp.length == 0)
            timestamp = Clock.currTime(UTC()).toISOExtString();

        MultipartForm form = new MultipartForm();
        form.addField("timestamp", timestamp);
        if (note.length)
            form.addField("note", note);
        if (worldId.length)
            form.addField("worldId", worldId);
        if (worldName.length)
            form.addField("worldName", worldName);
        form.addFile("image", "image", "image/png", png);

        ActionResult result = multipartCall("/prints", form);
        lastPrintUploadAt = MonoTime.currTime;
        haveUploadedPrintOnce = true;
        if (result.success)
            result.data = trimPrint(result.data);
        return result;
    }

private:

    /// GET a VRChat API path and parse the JSON body. Locks the API mutex,
    /// checks the rate limiter. Throws on any failure.
    JSONValue getJSON(string path)
    {
        apiMutex.lock();
        scope(exit) apiMutex.unlock();

        if (rateLimiter && rateLimiter.isBlocked())
            throw new Exception("Rate limited by VRChat, try again later");

        logDebugging("getJSON: GET %s", path);
        HTTPResponse resp = client.get(path);
        if (rateLimiter)
            rateLimiter.update(resp);
        if (resp.code != 200)
            throw new Exception("HTTP " ~ resp.code.to!string);
        return parseJSON(resp.text);
    }

    /// Perform a simple JSON API call (PUT/DELETE) under the API mutex.
    ActionResult simpleCall(string method, string path, string payload)
    {
        apiMutex.lock();
        scope(exit) apiMutex.unlock();

        if (rateLimiter && rateLimiter.isBlocked())
            return ActionResult(false, "Rate limited by VRChat, try again later");

        try
        {
            HTTPResponse resp;
            switch (method)
            {
                case "PUT":
                    resp = client.putJSON(path, payload);
                    break;
                case "DELETE":
                    resp = client.del(path);
                    break;
                default:
                    return ActionResult(false, "Unsupported method: " ~ method);
            }
            logDebugging("simpleCall: %s %s -> HTTP %d", method, path, resp.code);
            if (rateLimiter)
                rateLimiter.update(resp);

            ActionResult result;
            result.success = resp.code >= 200 && resp.code < 300;
            if (result.success)
            {
                try result.data = parseJSON(resp.text);
                catch (Exception) {}
            }
            else
                result.error = "HTTP " ~ resp.code.to!string;
            return result;
        }
        catch (Exception e)
        {
            return ActionResult(false, e.msg);
        }
    }

    /// Perform a multipart POST under the API mutex with a raised timeout.
    ActionResult multipartCall(string path, MultipartForm form)
    {
        apiMutex.lock();
        scope(exit) apiMutex.unlock();

        if (rateLimiter && rateLimiter.isBlocked())
            return ActionResult(false, "Rate limited by VRChat, try again later");

        client.setTimeout(TRANSFER_TIMEOUT_MS);
        scope(exit) client.setTimeout(DEFAULT_TIMEOUT_MS);

        // libcurl's mime code sets its own "multipart/form-data" Content-Type.
        // JSON calls now set "Content-Type: application/json" per request (see
        // postJSON/putJSON), so the client holds no content type at rest and
        // nothing here overrides the multipart header.
        try
        {
            HTTPResponse resp = client.postMultipart(path, form);
            logDebugging("multipartCall: POST %s -> HTTP %d", path, resp.code);
            if (rateLimiter)
                rateLimiter.update(resp);

            ActionResult result;
            result.success = resp.code >= 200 && resp.code < 300;
            if (result.success)
            {
                try result.data = parseJSON(resp.text);
                catch (Exception) {}
            }
            else
            {
                result.error = "HTTP " ~ resp.code.to!string;
                logDebugging("multipartCall: POST %s failed body: %s", path, resp.text);
            }
            return result;
        }
        catch (Exception e)
        {
            return ActionResult(false, e.msg);
        }
    }

    /// Write image bytes to the cache (atomic via temp + rename), then
    /// evict oldest entries if the cache grew past its cap.
    void saveToCache(string cachePath, const(ubyte)[] data)
    {
        try
        {
            string tmp = cachePath ~ ".tmp";
            write(tmp, data);
            rename(tmp, cachePath);
        }
        catch (Exception e)
        {
            logWarn("saveToCache: %s: %s", cachePath, e.msg);
            return;
        }

        evictCache();
    }

    /// Delete oldest-mtime cache entries until total size is under the cap.
    void evictCache()
    {
        struct Entry
        {
            string path;
            long mtime;
            ulong size;
        }

        try
        {
            Entry[] entries;
            ulong total;
            foreach (DirEntry de; dirEntries(cacheDir, SpanMode.shallow))
            {
                if (de.isFile == false)
                    continue;
                entries ~= Entry(de.name, de.timeLastModified.toUnixTime!long(), de.size);
                total += de.size;
            }

            if (total <= cacheMaxBytes)
                return;

            entries.sort!((a, b) => a.mtime < b.mtime);
            foreach (ref Entry entry; entries)
            {
                if (total <= cacheMaxBytes)
                    break;
                logDebugging("evictCache: removing %s (%d bytes)",
                    baseName(entry.path), entry.size);
                remove(entry.path);
                total -= entry.size;
            }
        }
        catch (Exception e)
        {
            logWarn("evictCache: %s", e.msg);
        }
    }
}

//
// Trimming: pass only what the client renders, not the whole wire object.
//

/// Trim a VRChat File object down to client-relevant fields.
/// version is the highest complete version (0 = no usable data yet).
JSONValue trimFile(JSONValue file)
{
    JSONValue trimmed = JSONValue.emptyObject;
    copyString(file, trimmed, "id");
    copyString(file, trimmed, "name");
    copyString(file, trimmed, "mimeType");
    copyString(file, trimmed, "extension");
    if (const(JSONValue)* v = "tags" in file)
        trimmed["tags"] = *v;

    long fileVersion;
    if (const(JSONValue)* vs = "versions" in file)
    {
        foreach (ref const(JSONValue) ver; vs.array)
        {
            long num;
            if (const(JSONValue)* n = "version" in ver)
                num = n.integer;
            string status;
            if (const(JSONValue)* s = "status" in ver)
                status = s.str;
            bool deleted;
            if (const(JSONValue)* d = "deleted" in ver)
                deleted = d.type == JSONType.true_;
            if (num > fileVersion && status == "complete" && deleted == false)
                fileVersion = num;
        }
    }
    trimmed["version"] = JSONValue(fileVersion);

    // Animated emoji parameters, when present.
    copyString(file, trimmed, "animationStyle");
    copyString(file, trimmed, "loopStyle");
    if (const(JSONValue)* v = "frames" in file)
        if (v.type == JSONType.integer)
            trimmed["frames"] = *v;
    if (const(JSONValue)* v = "framesOverTime" in file)
        if (v.type == JSONType.integer)
            trimmed["framesOverTime"] = *v;

    return trimmed;
}

/// Trim a VRChat Print object down to client-relevant fields, extracting
/// the file reference for the generic image path.
JSONValue trimPrint(JSONValue print)
{
    JSONValue trimmed = JSONValue.emptyObject;
    copyString(print, trimmed, "id");
    copyString(print, trimmed, "note");
    copyString(print, trimmed, "timestamp");
    copyString(print, trimmed, "createdAt");
    copyString(print, trimmed, "worldId");
    copyString(print, trimmed, "worldName");
    copyString(print, trimmed, "authorName");

    if (const(JSONValue)* files = "files" in print)
    {
        if (const(JSONValue)* v = "fileId" in *files)
            trimmed["file_id"] = *v;
        // The image URL carries the version: .../file/{id}/{version}/file
        string imageUrl;
        if (const(JSONValue)* v = "image" in *files)
            imageUrl = v.str;
        string fileId;
        long fileVersion;
        if (extractFileRef(imageUrl, fileId, fileVersion))
        {
            if (("file_id" in trimmed) is null)
                trimmed["file_id"] = JSONValue(fileId);
            trimmed["file_version"] = JSONValue(fileVersion);
        }
        else
            trimmed["file_version"] = JSONValue(1);
    }
    return trimmed;
}

/// Trim a VRChat InventoryItem down to client-relevant fields, extracting
/// the image file reference for the generic image path.
JSONValue trimInventoryItem(JSONValue item)
{
    JSONValue trimmed = JSONValue.emptyObject;
    copyString(item, trimmed, "id");
    copyString(item, trimmed, "name");
    copyString(item, trimmed, "description");
    copyString(item, trimmed, "itemType");
    copyString(item, trimmed, "itemTypeLabel");
    copyString(item, trimmed, "equipSlot");
    copyString(item, trimmed, "expiryDate");
    if (const(JSONValue)* v = "flags" in item)
        trimmed["flags"] = *v;
    if (const(JSONValue)* v = "collections" in item)
        trimmed["collections"] = *v;
    if (const(JSONValue)* v = "isArchived" in item)
        trimmed["isArchived"] = *v;

    // Image reference: prefer the item-level imageUrl, fall back to
    // metadata. Either way the client only needs fileId + version.
    string imageUrl;
    if (const(JSONValue)* v = "imageUrl" in item)
        if (v.type == JSONType.string)
            imageUrl = v.str;
    if (imageUrl.length == 0)
    {
        if (const(JSONValue)* meta = "metadata" in item)
            if (const(JSONValue)* v = "imageUrl" in *meta)
                if (v.type == JSONType.string)
                    imageUrl = v.str;
    }
    string fileId;
    long fileVersion;
    if (extractFileRef(imageUrl, fileId, fileVersion))
    {
        trimmed["image_file_id"] = JSONValue(fileId);
        trimmed["image_version"] = JSONValue(fileVersion);
    }
    return trimmed;
}

/// Copy a string field between JSON objects if present.
private void copyString(ref JSONValue src, ref JSONValue dst, string key)
{
    if (const(JSONValue)* v = key in src)
        if (v.type == JSONType.string)
            dst[key] = *v;
}

/// Extract a file reference from a VRChat file/image URL like
/// ".../file/file_xxx/2/file" or ".../image/file_xxx/1/256".
/// Returns: true when both the file ID and version were found.
bool extractFileRef(string url, out string fileId, out long fileVersion)
{
    import std.string : indexOf;

    ptrdiff_t start = url.indexOf("file_");
    if (start < 0)
        return false;

    // File ID runs until the next path separator.
    size_t idEnd = start;
    while (idEnd < url.length && url[idEnd] != '/')
        ++idEnd;
    fileId = url[start .. idEnd];
    if (isValidFileId(fileId) == false)
        return false;

    // Next path segment is the version number.
    size_t verStart = idEnd + 1;
    size_t verEnd = verStart;
    while (verEnd < url.length && url[verEnd] >= '0' && url[verEnd] <= '9')
        ++verEnd;
    if (verEnd == verStart)
        return false;
    fileVersion = url[verStart .. verEnd].to!long;
    return fileVersion >= 1;
}

/// Whether this is a plausible VRChat file ID. The ID is used in cache
/// file paths, so this doubles as a path-injection guard.
bool isValidFileId(string fileId)
{
    if (fileId.startsWith("file_") == false)
        return false;
    if (fileId.length < 6 || fileId.length > 64)
        return false;
    foreach (char c; fileId[5 .. $])
    {
        bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
            || (c >= '0' && c <= '9') || c == '-';
        if (ok == false)
            return false;
    }
    return true;
}

/// Identify an image format from its magic bytes.
string sniffImageMime(const(ubyte)[] data)
{
    if (data.length >= 8 &&
        data[0] == 0x89 && data[1] == 'P' && data[2] == 'N' && data[3] == 'G')
        return "image/png";
    if (data.length >= 3 &&
        data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF)
        return "image/jpeg";
    if (data.length >= 4 && data[0 .. 4] == cast(const(ubyte)[]) "GIF8")
        return "image/gif";
    if (data.length >= 12 && data[0 .. 4] == cast(const(ubyte)[]) "RIFF" &&
        data[8 .. 12] == cast(const(ubyte)[]) "WEBP")
        return "image/webp";
    return "application/octet-stream";
}

/// Validate a PNG for upload: signature, size cap, dimension cap.
/// Returns: null when valid, otherwise the rejection reason.
string validatePNG(const(ubyte)[] data, out int width, out int height)
{
    if (data.length > UPLOAD_MAX_BYTES)
        return "Image too large (max 10 MB)";
    if (data.length < 24)
        return "Not a PNG image";
    if (sniffImageMime(data) != "image/png")
        return "Not a PNG image (VRChat only accepts PNG here)";
    if (data[12 .. 16] != cast(const(ubyte)[]) "IHDR")
        return "Malformed PNG (no IHDR)";

    // IHDR: width and height as big-endian u32 at offsets 16 and 20.
    width  = (data[16] << 24) | (data[17] << 16) | (data[18] << 8) | data[19];
    height = (data[20] << 24) | (data[21] << 16) | (data[22] << 8) | data[23];
    if (width < 1 || height < 1)
        return "Malformed PNG (bad dimensions)";
    if (width > UPLOAD_MAX_DIMENSION || height > UPLOAD_MAX_DIMENSION)
        return "Image dimensions too large (max 2000x2000)";
    return null;
}

unittest
{
    string fileId;
    long ver;
    assert(extractFileRef(
        "https://api.vrchat.cloud/api/1/file/file_0e8c4e32-7444-44ea-ade4-313c010d4bae/2/file",
        fileId, ver));
    assert(fileId == "file_0e8c4e32-7444-44ea-ade4-313c010d4bae");
    assert(ver == 2);

    assert(extractFileRef(
        "https://api.vrchat.cloud/api/1/image/file_abc-123/1/256", fileId, ver));
    assert(fileId == "file_abc-123");
    assert(ver == 1);

    assert(extractFileRef("https://example.com/nope.png", fileId, ver) == false);
    assert(extractFileRef("file_abc", fileId, ver) == false); // no version
}

unittest
{
    assert(isValidFileId("file_0e8c4e32-7444-44ea-ade4-313c010d4bae"));
    assert(isValidFileId("file_abc") );
    assert(isValidFileId("wrld_abc") == false);
    assert(isValidFileId("file_") == false);
    assert(isValidFileId("file_../etc/passwd") == false);
    assert(isValidFileId("file_a/b") == false);
}

unittest
{
    // Minimal valid PNG header: signature + IHDR for a 2x3 image.
    ubyte[] png = [
        0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, // signature
        0, 0, 0, 13, 'I', 'H', 'D', 'R',             // IHDR chunk header
        0, 0, 0, 2,                                  // width = 2
        0, 0, 0, 3,                                  // height = 3
        8, 6, 0, 0, 0,                               // bit depth etc.
    ];
    int w, h;
    assert(validatePNG(png, w, h) is null);
    assert(w == 2 && h == 3);

    ubyte[] junk = [ 1, 2, 3 ];
    assert(validatePNG(junk, w, h) !is null);
}
