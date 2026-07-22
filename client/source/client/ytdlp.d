/// Control over VRChat's bundled yt-dlp video resolver.
///
/// VRChat ships its own yt-dlp.exe under the LocalLow "Tools" folder (the
/// same tree vrchatLogDir lives in) and shells out to it to resolve video
/// player URLs (YouTube, Twitch, etc). On Linux/Proton this can hang or
/// misbehave; there is no supported setting to turn it off, so the only
/// reliable control is renaming the executable so VRChat can't find it.
/// VRChat may restore its own bundled copy on the next launch or update -
/// this only affects the copy currently on disk.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module client.ytdlp;

import std.file : exists, rename;
import std.path : buildPath;

import ddlogger;

import client.directories : vrchatLogDir;

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

/// Query whether yt-dlp is currently enabled, disabled, or not installed.
YtdlpState queryYtdlpState()
{
    if (exists(ytdlpPath()))
        return YtdlpState.enabled;
    if (exists(ytdlpDisabledPath()))
        return YtdlpState.disabled;
    return YtdlpState.missing;
}

/// Toggle yt-dlp between enabled and disabled by renaming the executable.
/// Returns false (and logs) if there is nothing to toggle or the rename
/// failed, e.g. VRChat currently has the file open.
bool toggleYtdlp()
{
    final switch (queryYtdlpState()) with (YtdlpState)
    {
    case enabled:
        try
        {
            rename(ytdlpPath(), ytdlpDisabledPath());
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
            rename(ytdlpDisabledPath(), ytdlpPath());
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
