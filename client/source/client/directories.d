/// VRChat / Steam directory resolver.
///
/// On Linux, parses Steam's libraryfolders.vdf to locate the library
/// containing the VRChat app (438100) and builds Proton compatdata paths
/// from it. On Windows, VRChat is a native install and paths live under
/// the user profile regardless of Steam library layout.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module client.directories;

import std.array : replace;
import std.file : exists, readText;
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

//
// VRChat paths
//

/// VRChat Steam app ID.
static immutable string VRCHAT_APP_ID = "438100";

private __gshared string cachedLogDir;
private __gshared string cachedPicturesDir;
private __gshared string cachedProtonPrefix; // Linux only, drive_c root
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
private void resolveWindows()
{
    string localAppData = environment.get("LOCALAPPDATA");
    if (localAppData)
        cachedLogDir = buildPath(localAppData ~ "Low", "VRChat", "VRChat");
    string userProfile = environment.get("USERPROFILE");
    if (userProfile)
        cachedPicturesDir = buildPath(userProfile, "Pictures", "VRChat");
}

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
        try
        {
            string content = readText(vdfPath);
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

    cachedProtonPrefix = buildPath(libraryPath, "steamapps", "compatdata",
        VRCHAT_APP_ID, "pfx", "drive_c");
    cachedLogDir = buildPath(cachedProtonPrefix, "users", "steamuser",
        "AppData", "LocalLow", "VRChat", "VRChat");
    cachedPicturesDir = buildPath(cachedProtonPrefix, "users", "steamuser",
        "Pictures", "VRChat");
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
}

unittest
{
    // Missing libraryfolders block to empty result, no exception.
    assert(findLibraryForApp(`"other" { "path" "/x" }`, "438100") == null);
    // Malformed input to empty result, no exception.
    assert(findLibraryForApp(`"libraryfolders" {`, "438100") == null);
    assert(findLibraryForApp("", "438100") == null);
}
