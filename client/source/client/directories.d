/// VRChat / Steam directory resolver.
///
/// On Linux, parses Steam's libraryfolders.vdf to locate the library
/// containing the VRChat app (438100) and builds Proton compatdata paths
/// from it. On Windows, VRChat is a native install: the log dir lives under
/// LOCALAPPDATALow and the screenshots dir is resolved through the shell's
/// Pictures known folder (which may be redirected off the user profile).
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module client.directories;

import std.array : replace;
import std.file : exists, readText, dirEntries, SpanMode, DirEntry;
import std.path : buildPath, expandTilde;
import std.process : environment;

import ddlogger;

//
// vrcd client paths
//

/// Return the settings file path ("settings.json")
string settingsFilePath()
{
    return vrcdConfigPath("settings.json");
}

/// Create a new vrcd config path with given end filename
string vrcdConfigPath(string filename = null)
{
    // null is OK with buildPath, tested with dmd-2.112, gdc-13.3 (dmd-fe-2.103)
    version (Windows)
    {
        string appdata = environment.get("APPDATA", ".");
        return buildPath(appdata, "vrcd", filename);
    }
    else version (linux)
    {
        string configDir = expandTilde("~/.config/vrcd");
        return buildPath(configDir, filename);
    }
}

/// Create a new vrcd user app data path with given end filename
string vrcdAppDataPath(string filename = null)
{
    // null is OK with buildPath, tested with dmd-2.112, gdc-13.3 (dmd-fe-2.103)
    version (Windows)
    {
        string localappdata = environment.get("LOCALAPPDATA", ".");
        return buildPath(localappdata, "vrcd", filename);
    }
    else version (linux)
    {
        string appdir = expandTilde("~/.local/share/vrcd");
        return buildPath(appdir, filename);
    }
}

/// Return the folder the client writes files it saves for the user into
/// (inventory artwork, ...). Never null: when the platform cannot answer,
/// the conventional location under the home directory is used.
string userDownloadsDir()
{
    version (Windows)
    {
        string known = knownFolderPath(FOLDERID_Downloads);
        if (known)
            return known;
        logWarn("directories: SHGetKnownFolderPath(Downloads) failed, falling back to USERPROFILE");
        return buildPath(environment.get("USERPROFILE", "."), "Downloads");
    }
    else version (linux)
    {
        // The folder is localised and can be moved, so XDG's own answer wins
        // over the English default.
        string configured = environment.get("XDG_DOWNLOAD_DIR");
        if (configured is null)
            configured = xdgUserDir("XDG_DOWNLOAD_DIR");
        return configured ? configured : expandTilde("~/Downloads");
    }
}

version (linux)
/// Read one entry out of XDG's user-dirs.dirs, which writes paths relative to
/// `$HOME`. Null when the file or the key is absent.
private string xdgUserDir(string key)
{
    import std.algorithm.searching : startsWith;
    import std.string : splitLines, strip;

    string configHome = environment.get("XDG_CONFIG_HOME");
    if (configHome is null)
        configHome = expandTilde("~/.config");

    string path = buildPath(configHome, "user-dirs.dirs");
    if (exists(path) == false)
        return null;

    string content;
    try
        content = readText(path);
    catch (Exception e)
    {
        logWarn("directories: failed to read %s: %s", path, e.msg);
        return null;
    }

    foreach (string line; content.splitLines())
    {
        string entry = line.strip();
        if (entry.startsWith(key ~ "=") == false)
            continue;

        string value = entry[key.length + 1 .. $].strip();
        if (value.length >= 2 && value[0] == '"' && value[$ - 1] == '"')
            value = value[1 .. $ - 1];
        if (value.startsWith("$HOME"))
            value = environment.get("HOME", "~") ~ value["$HOME".length .. $];
        return value.length > 0 ? value : null;
    }
    return null;
}

//
// VRChat paths
//

/// VRChat Steam app ID.
static immutable string VRCHAT_APP_ID = "438100";

private __gshared string cachedLogDir;
private __gshared string cachedPicturesDir;
private __gshared string cachedProtonPrefix; // Linux only, drive_c root
private __gshared string cachedSteamRoot;    // Steam install root (has userdata)
private __gshared string[] cachedLibraryPaths; // Linux only, all Steam libraries
private __gshared bool resolved;

/// Return the VRChat log directory for the current platform.
string vrchatLogDir()
{
    resolve();
    return cachedLogDir;
}

/// Return the VRChat pictures (screenshots) directory for the current platform.
string vrchatPicturesDir()
{
    resolve();
    return cachedPicturesDir;
}

/// Return Steam's own screenshot directory for VRChat (Steam overlay / F12
/// captures), or null if it cannot be located. These live separately from
/// VRChat's screenshot folder, under userdata/<id>/760/remote/<appId>/screenshots.
string steamScreenshotDir()
{
    resolve();
    if (cachedSteamRoot is null)
        return null;

    string userdata = buildPath(cachedSteamRoot, "userdata");
    if (exists(userdata) == false)
        return null;

    // userdata holds one folder per Steam account id. Prefer the first that
    // already has VRChat screenshots, falling back to the first candidate.
    string fallback;
    try
    {
        foreach (DirEntry entry; dirEntries(userdata, SpanMode.shallow))
        {
            if (entry.isDir == false)
                continue;
            string shots = buildPath(entry.name, "760", "remote",
                VRCHAT_APP_ID, "screenshots");
            if (exists(shots))
                return shots;
            if (fallback is null)
                fallback = shots;
        }
    }
    catch (Exception e)
    {
        logWarn("directories: failed to scan %s: %s", userdata, e.msg);
    }
    return fallback;
}

/// Translate a Windows-flavoured path from a VRChat log line into a local
/// path. On Windows this is a no-op; on Linux it strips the drive letter
/// and reroots under the detected Proton prefix.
string translateVRChatPath(string logPath)
{
    version (Windows)
    {
        return logPath;
    }
    else version (linux)
    {
        resolve();
        if (logPath.length < 3 || logPath[1] != ':')
            return logPath;
        char sep = logPath[2];
        if (sep != '\\' && sep != '/')
            return logPath;
        string tail = logPath[2 .. $].replace("\\", "/");
        return cachedProtonPrefix ~ tail;
    }
}

private void resolve()
{
    if (resolved)
        return;

    version (Windows)
    {
        resolveWindows();
    }
    else version (linux)
    {
        resolveLinux();
    }

    resolved = true;
}

version (Windows)
{
private void resolveWindows()
{
    string localAppData = environment.get("LOCALAPPDATA");
    if (localAppData)
        cachedLogDir = buildPath(localAppData ~ "Low", "VRChat", "VRChat");

    // Resolve the Pictures folder via the shell so a redirected library
    // (moved to another drive, etc.) is honoured. USERPROFILE\Pictures is
    // wrong whenever the user has relocated their Pictures known folder.
    string pictures = knownFolderPath(FOLDERID_Pictures);
    if (pictures)
    {
        cachedPicturesDir = buildPath(pictures, "VRChat");
    }
    else
    {
        logWarn("directories: SHGetKnownFolderPath(Pictures) failed, falling back to USERPROFILE");
        string userProfile = environment.get("USERPROFILE");
        if (userProfile)
            pictures = buildPath(userProfile, "Pictures");
    }

    cachedSteamRoot = steamRootWindows();
}

/// Read the Steam install path from HKCU\Software\Valve\Steam (SteamPath),
/// or null if Steam is not installed / the key is missing.
private string steamRootWindows()
{
    import core.sys.windows.winreg;
    import core.sys.windows.winerror : ERROR_SUCCESS;
    import core.sys.windows.windef : KEY_READ, HKEY;
    import std.conv : to;

    HKEY key;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, "Software\\Valve\\Steam"w.ptr, 0, KEY_READ, &key) != ERROR_SUCCESS)
        return null;
    scope(exit) RegCloseKey(key);

    wchar[1024] buf = void;
    DWORD size = buf.sizeof; // in bytes
    if (RegQueryValueExW(key, "SteamPath"w.ptr, null, null, cast(ubyte*) buf.ptr, &size) != ERROR_SUCCESS)
        return null;

    size_t chars = size / wchar.sizeof;
    if (chars > 0 && buf[chars - 1] == '\0')
        chars--;
    if (chars == 0)
        return null;
    // Steam stores SteamPath with forward slashes. Left as-is, buildPath
    // appends the rest with backslashes, and the mixed-separator path is
    // rejected by Explorer (it silently opens Documents instead).
    return to!string(buf[0 .. chars]).replace("/", "\\");
}

import core.sys.windows.windows : GUID, HRESULT, DWORD;

pragma(lib, "shell32");
pragma(lib, "ole32");
pragma(lib, "advapi32");

// FOLDERID_Pictures: {33E28130-4E1E-4676-835A-98395C3BC3BB}
private static immutable GUID FOLDERID_Pictures =
    GUID(0x33E28130, 0x4E1E, 0x4676, [0x83, 0x5A, 0x98, 0x39, 0x5C, 0x3B, 0xC3, 0xBB]);

// FOLDERID_Downloads: {374DE290-123F-4565-9164-39C4925E467B}
private static immutable GUID FOLDERID_Downloads =
    GUID(0x374DE290, 0x123F, 0x4565, [0x91, 0x64, 0x39, 0xC4, 0x92, 0x5E, 0x46, 0x7B]);

private extern (Windows) @nogc nothrow
{
    HRESULT SHGetKnownFolderPath(const(GUID)* rfid, DWORD dwFlags,
        void* hToken, wchar** ppszPath);
    void CoTaskMemFree(void* pv);
}

/// Resolve a Windows known folder to a UTF-8 path, or null on failure.
private string knownFolderPath(const(GUID) id)
{
    import std.conv : to;
    import core.stdc.wchar_ : wcslen;

    wchar* wpath;
    HRESULT hr = SHGetKnownFolderPath(&id, 0, null, &wpath);
    if (hr != 0 || wpath is null)
        return null;
    scope(exit) CoTaskMemFree(wpath);
    return to!string(wpath[0 .. wcslen(wpath)]);
}
} // version Windows

version (linux)
private void resolveLinux()
{
    string home = environment.get("HOME");
    if (home is null)
    {
        logWarn("directories: HOME not set, VRChat paths will be empty");
        return;
    }

    // Candidate Steam roots to search for libraryfolders.vdf. Ordered so the
    // standard symlink wins over direct native and Flatpak layouts.
    string[] steamRoots = [
        buildPath(home, ".steam", "steam"),
        buildPath(home, ".local", "share", "Steam"),
        buildPath(home, ".var", "app", "com.valvesoftware.Steam", ".local", "share", "Steam"),
    ];

    string libraryPath;
    foreach (root; steamRoots)
    {
        string vdfPath = buildPath(root, "steamapps", "libraryfolders.vdf");
        if (exists(vdfPath) == false)
            continue;
        // The Steam install root (where userdata lives) is the dir holding
        // libraryfolders.vdf, not necessarily the library VRChat installs to.
        if (cachedSteamRoot is null)
            cachedSteamRoot = root;
        try
        {
            string content = readText(vdfPath);
            if (cachedLibraryPaths.length == 0)
                cachedLibraryPaths = findAllLibraries(content);
            libraryPath = findLibraryForApp(content, VRCHAT_APP_ID);
            if (libraryPath)
            {
                logInfo("directories: VRChat located via %s at %s",
                    vdfPath, libraryPath);
                break;
            }
        }
        catch (Exception e)
        {
            logWarn("directories: failed to read %s: %s", vdfPath, e.msg);
        }
    }

    if (libraryPath is null)
    {
        libraryPath = buildPath(home, ".steam", "steam");
        logWarn("directories: libraryfolders.vdf lookup failed, "
            ~ "falling back to %s", libraryPath);
    }
    if (cachedSteamRoot is null)
        cachedSteamRoot = buildPath(home, ".steam", "steam");

    cachedProtonPrefix = buildPath(libraryPath, "steamapps", "compatdata",
        VRCHAT_APP_ID, "pfx", "drive_c");
    cachedLogDir = buildPath(cachedProtonPrefix, "users", "steamuser",
        "AppData", "LocalLow", "VRChat", "VRChat");
    cachedPicturesDir = buildPath(cachedProtonPrefix, "users", "steamuser",
        "Pictures", "VRChat");
}

version (linux)
{
/// Return the Proton prefix (WINEPREFIX) VRChat runs in, derived from the
/// Steam library layout. Used to attach a Wine process to the game's
/// wineserver when the prefix cannot be read out of the running game's own
/// environment. Returns null when the Steam library was not found.
string vrchatProtonPrefix()
{
    import std.path : dirName;

    resolve();
    if (cachedProtonPrefix is null)
        return null;
    return dirName(cachedProtonPrefix); // .../compatdata/438100/pfx
}
} // version (linux)

/// Parse a libraryfolders.vdf body and return every library `path`.
/// Returns an empty array on failure.
string[] findAllLibraries(string vdf)
{
    VdfNode root = parseVdf(vdf);
    VdfNode *libs = "libraryfolders" in root.children;
    if (libs is null)
        return null;

    string[] paths;
    foreach (entry; libs.children)
    {
        if (string *p = "path" in entry.values)
            paths ~= *p;
    }
    return paths;
}

/// Parse a libraryfolders.vdf body and return the `path` of the first
/// library whose `apps` map contains `appId`. Returns empty string on
/// failure or absence.
string findLibraryForApp(string vdf, string appId)
{
    VdfNode root = parseVdf(vdf);
    VdfNode *libs = "libraryfolders" in root.children;
    if (libs is null)
        return null;

    foreach (entry; libs.children)
    {
        VdfNode *apps = "apps" in entry.children;
        if (apps is null)
            continue;
        if (appId in apps.values)
        {
            if (string *p = "path" in entry.values)
                return *p;
        }
    }

    return null;
}

/// Minimal Valve KeyValues tree. Insertion order is not preserved but
/// the libraryfolders.vdf format does not require it for lookups.
private struct VdfNode
{
    string[string] values;
    VdfNode[string] children;
}

/// Parse a libraryfolders-style VDF document. Handles only double-quoted
/// strings and `{`/`}` blocks, sufficient for Steam's generated files.
/// Returns an empty node on any parse error.
private VdfNode parseVdf(string src)
{
    VdfNode root;
    size_t pos;
    try
    {
        parseBlock(src, pos, root);
    }
    catch (Exception)
    {
        return VdfNode.init;
    }
    return root;
}

private void parseBlock(string src, ref size_t pos, ref VdfNode node)
{
    while (pos < src.length)
    {
        skipWs(src, pos);
        if (pos >= src.length)
            return;
        if (src[pos] == '}')
        {
            pos++;
            return;
        }
        string key = readQuoted(src, pos);
        skipWs(src, pos);
        if (pos >= src.length)
            return;
        if (src[pos] == '{')
        {
            pos++;
            VdfNode child;
            parseBlock(src, pos, child);
            node.children[key] = child;
        }
        else if (src[pos] == '"')
        {
            string value = readQuoted(src, pos);
            node.values[key] = value;
        }
        else
        {
            // Unexpected, skip a character to make progress and keep going.
            pos++;
        }
    }
}

private void skipWs(string src, ref size_t pos)
{
    while (pos < src.length)
    {
        char c = src[pos];
        if (c == ' ' || c == '\t' || c == '\r' || c == '\n')
        {
            pos++;
            continue;
        }
        // Line comments `//`, not used by Steam's file but cheap to tolerate.
        if (c == '/' && pos + 1 < src.length && src[pos + 1] == '/')
        {
            pos += 2;
            while (pos < src.length && src[pos] != '\n')
                pos++;
            continue;
        }
        break;
    }
}

private string readQuoted(string src, ref size_t pos)
{
    if (pos >= src.length || src[pos] != '"')
        throw new Exception("vdf: expected opening quote");
    pos++;
    size_t start = pos;
    while (pos < src.length && src[pos] != '"')
    {
        if (src[pos] == '\\' && pos + 1 < src.length)
            pos += 2;
        else
            pos++;
    }
    if (pos >= src.length)
        throw new Exception("vdf: unterminated string");
    string result = src[start .. pos];
    pos++;
    return result;
}

unittest
{
    // Sample mirrors perso/libraryfolders.vdf shape with two libraries.
    string sample = `"libraryfolders"
{
    "0"
    {
        "path"    "/mnt/ssd/Steam"
        "label"   ""
        "apps"
        {
            "220"    "5774110510"
            "440"    "1234567890"
        }
    }
    "1"
    {
        "path"    "/home/test/.local/share/Steam"
        "label"   ""
        "apps"
        {
            "438100"  "1096365330"
            "4000"    "7250381773"
        }
    }
}
`;
    assert(findLibraryForApp(sample, "438100") == "/home/test/.local/share/Steam");
    assert(findLibraryForApp(sample, "220") == "/mnt/ssd/Steam");
    assert(findLibraryForApp(sample, "999999") == null);

    import std.algorithm.sorting : sort;
    string[] libs = findAllLibraries(sample);
    sort(libs); // AA iteration order is unspecified
    assert(libs == ["/home/test/.local/share/Steam", "/mnt/ssd/Steam"]);
    assert(findAllLibraries("").length == 0);
}

unittest
{
    // Missing libraryfolders block to empty result, no exception.
    assert(findLibraryForApp(`"other" { "path" "/x" }`, "438100") == null);
    // Malformed input to empty result, no exception.
    assert(findLibraryForApp(`"libraryfolders" {`, "438100") == null);
    assert(findLibraryForApp("", "438100") == null);
}
