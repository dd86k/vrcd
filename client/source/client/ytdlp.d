/// Control over VRChat's bundled yt-dlp video resolver.
///
/// VRChat ships its own yt-dlp.exe under the LocalLow "Tools" folder (the
/// same tree vrchatLogDir lives in) and shells out to it to resolve video
/// player URLs (YouTube, Twitch, etc). On Linux/Proton this can hang or
/// misbehave, and there is no supported setting to turn it off.
///
/// VRChat checks the executable on every world load and restores it when
/// missing, so renaming it alone does not last. Disabling renames it aside
/// and leaves an empty, read-only placeholder under the original name.
/// Windows refuses to overwrite or delete a read-only file, and Wine reports
/// a file without write permission as read-only.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module client.ytdlp;

import std.file : exists, getSize, remove, rename, setAttributes, write;
import std.path : buildPath;

import ddlogger;

import client.directories : vrchatLogDir;

version (Windows)
{
    import core.sys.windows.winnt : FILE_ATTRIBUTE_NORMAL, FILE_ATTRIBUTE_READONLY;

    /// Placeholder attributes: read-only.
    private enum uint LOCKED_ATTR = FILE_ATTRIBUTE_READONLY;
    /// Attributes restored before removing the placeholder.
    private enum uint UNLOCKED_ATTR = FILE_ATTRIBUTE_NORMAL;
}
else
{
    import std.conv : octal;

    /// Placeholder mode: a-rwx.
    private enum uint LOCKED_ATTR = 0;
    /// Mode restored before removing the placeholder.
    private enum uint UNLOCKED_ATTR = octal!644;
}

/// yt-dlp executable name as shipped by VRChat.
private static immutable string YTDLP_EXE = "yt-dlp.exe";

/// Suffix appended to the executable name to disable it without deleting it.
private static immutable string DISABLED_SUFFIX = ".disabled";

/// Current on-disk state of VRChat's bundled yt-dlp.
enum YtdlpState { missing, enabled, disabled }

/// Path to VRChat's bundled yt-dlp.exe, whether or not it currently exists.
string ytdlpPath()
{
    return buildPath(vrchatLogDir(), "Tools", YTDLP_EXE);
}

/// Path yt-dlp.exe is renamed to while disabled.
string ytdlpDisabledPath()
{
    return ytdlpPath() ~ DISABLED_SUFFIX;
}

/// True if path is the empty placeholder left by disabling.
private bool isPlaceholder(string path)
{
    try
        return exists(path) && getSize(path) == 0;
    catch (Exception)
        return false;
}

/// Query whether yt-dlp is currently enabled, disabled, or not installed.
/// A real executable counts as enabled even beside a stale disabled copy,
/// which is what VRChat restoring it looks like.
YtdlpState queryYtdlpState()
{
    string path = ytdlpPath();
    if (exists(path) && isPlaceholder(path) == false)
        return YtdlpState.enabled;
    if (exists(ytdlpDisabledPath()))
        return YtdlpState.disabled;
    return YtdlpState.missing;
}

/// Rename yt-dlp.exe aside and lock an empty placeholder in its place.
/// The rename replaces any stale disabled copy.
private void disable()
{
    string path = ytdlpPath();
    rename(path, ytdlpDisabledPath());
    write(path, null);
    setAttributes(path, LOCKED_ATTR);
}

/// Remove the placeholder, if any, and rename the disabled copy back.
private void enable()
{
    string path = ytdlpPath();
    if (isPlaceholder(path))
    {
        setAttributes(path, UNLOCKED_ATTR);
        remove(path);
    }
    rename(ytdlpDisabledPath(), path);
}

/// Toggle yt-dlp between enabled and disabled.
/// Returns false (and logs) if there is nothing to toggle or the file
/// operations failed, e.g. VRChat currently has the file open.
bool toggleYtdlp()
{
    final switch (queryYtdlpState()) with (YtdlpState)
    {
    case enabled:
        try
        {
            disable();
            logInfo("ytdlp: disabled (%s)", ytdlpPath());
            return true;
        }
        catch (Exception ex)
        {
            logError("ytdlp: failed to disable: %s", ex.msg);
            return false;
        }
    case disabled:
        try
        {
            enable();
            logInfo("ytdlp: enabled (%s)", ytdlpPath());
            return true;
        }
        catch (Exception ex)
        {
            logError("ytdlp: failed to enable: %s", ex.msg);
            return false;
        }
    case missing:
        logWarn("ytdlp: not found at %s, nothing to toggle", ytdlpPath());
        return false;
    }
}
