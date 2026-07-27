/// Static document root.
///
/// The pages, stylesheets, and scripts live in `public/` as plain files rather
/// than string literals compiled into the binary, so editing the front-end is
/// an edit plus a refresh instead of a rebuild. Files are read on demand and
/// kept in memory until their mtime changes, which is what makes the refresh
/// pick the change up without a restart.
///
/// The trade for that is a runtime dependency: the directory has to travel
/// with the binary. `findWebRoot` therefore checks the likely locations up
/// front and the caller aborts on startup rather than serving a broken page.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module web.assets;

import core.sync.mutex : Mutex;
import std.datetime : SysTime;
import std.file : exists, getcwd, isDir, read, thisExePath, timeLastModified;
import std.path : buildNormalizedPath, buildPath, dirName, extension;

import ddlogger;

/// One file, as served.
struct Asset
{
    /// File contents. Empty when the file could not be read.
    const(void)[] content;
    /// Value for the Content-Type header, zero-terminated.
    const(char) *contentType;

    /// True when the file was found and read.
    bool found() const { return contentType !is null; }
}

/// Serves files out of one directory, caching each until its mtime moves.
class AssetStore
{
    /// Params: root = Directory holding the front-end files.
    this(string root)
    {
        this.root = root;
        mutex = new Mutex();
    }

    /// Read a file from the root. Returns an Asset with `found` false when the
    /// name is unacceptable or the file is not there.
    Asset get(string name)
    {
        if (acceptableName(name) == false)
        {
            logWarn("Rejected asset name '%s'", name);
            return Asset.init;
        }

        const(char) *type = contentTypeFor(extension(name));
        if (type is null)
        {
            logWarn("Rejected asset '%s': unhandled file type", name);
            return Asset.init;
        }

        string path = buildPath(root, name);

        // Stat before locking: an unchanged file is the common case and only
        // needs the timestamp to prove it.
        SysTime stamp = timeLastModified(path, SysTime.min);
        if (stamp == SysTime.min)
            return Asset.init;

        synchronized (mutex)
        {
            if (CacheEntry *entry = name in cache)
                if (entry.stamp == stamp)
                    return Asset(entry.content, type);

            void[] content;
            try content = read(path);
            catch (Exception ex)
            {
                logError("Could not read %s: %s", path, ex.msg);
                return Asset.init;
            }

            logTrace("Loaded %s (%u bytes)", path, content.length);
            cache[name] = CacheEntry(content, stamp);
            return Asset(content, type);
        }
    }

    /// Directory being served.
    string root;

private:

    struct CacheEntry
    {
        void[] content;
        SysTime stamp;
    }

    CacheEntry[string] cache;
    Mutex mutex;
}

/// Pick the directory to serve the front-end from.
///
/// A `preferred` path is taken as given, so a wrong `--web-root` fails loudly
/// instead of silently falling back to a stale copy. Otherwise the usual spots
/// are tried: next to the binary first (how a package installs), then under
/// the working directory (how the repository is laid out).
///
/// Returns: The directory, or null when none of the candidates hold an
/// index.html.
string findWebRoot(string preferred)
{
    if (preferred.length)
    {
        if (usableRoot(preferred))
            return preferred;

        logError("--web-root %s does not contain index.html", preferred);
        return null;
    }

    string exeDir = dirName(thisExePath());
    string cwd = getcwd();
    string[] candidates = [
        buildNormalizedPath(exeDir, "public"),
        buildNormalizedPath(exeDir, "..", "public"),
        buildNormalizedPath(cwd, "public"),
        buildNormalizedPath(cwd, "web", "public"),
    ];

    foreach (string candidate; candidates)
        if (usableRoot(candidate))
            return candidate;

    logError("No web root found, looked in:");
    foreach (string candidate; candidates)
        logError("  %s", candidate);
    logError("Pass --web-root DIR to point at the directory holding index.html");
    return null;
}

/// A directory only counts as a root when the shell document is in it, so a
/// coincidentally named directory is not mistaken for the front-end.
private bool usableRoot(string path)
{
    return exists(path) && isDir(path) && exists(buildPath(path, "index.html"));
}

/// Names come straight off the request path, so restrict them to a plain file
/// name: no separators, no traversal, nothing hidden.
private bool acceptableName(string name)
{
    if (name.length == 0 || name.length > 64)
        return false;
    if (name[0] == '.')
        return false;

    foreach (char c; name)
    {
        if (c >= 'a' && c <= 'z') continue;
        if (c >= 'A' && c <= 'Z') continue;
        if (c >= '0' && c <= '9') continue;
        if (c == '.' || c == '-' || c == '_') continue;
        return false;
    }
    return true;
}

unittest
{
    assert(acceptableName("app.js"));
    assert(acceptableName("index.html"));
    assert(acceptableName("logo-2.png"));

    assert(acceptableName("") == false);
    assert(acceptableName("..") == false);
    assert(acceptableName(".env") == false);
    assert(acceptableName("../secret") == false);
    assert(acceptableName("sub/app.js") == false);
    assert(acceptableName(`sub\app.js`) == false);
    assert(acceptableName("app.js\0") == false);
}

/// Content type for a file extension. Null for anything not served.
private const(char)* contentTypeFor(string ext)
{
    switch (ext)
    {
    case ".html": return "text/html; charset=utf-8".ptr;
    case ".css":  return "text/css; charset=utf-8".ptr;
    case ".js":   return "text/javascript; charset=utf-8".ptr;
    case ".json": return "application/json".ptr;
    case ".svg":  return "image/svg+xml".ptr;
    case ".png":  return "image/png".ptr;
    case ".jpg", ".jpeg": return "image/jpeg".ptr;
    case ".webp": return "image/webp".ptr;
    case ".ico":  return "image/x-icon".ptr;
    case ".woff2": return "font/woff2".ptr;
    case ".txt":  return "text/plain; charset=utf-8".ptr;
    default:      return null;
    }
}
