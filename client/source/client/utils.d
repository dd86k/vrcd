/// System utilities
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clearmodule client.utils;
module client.utils;

import ddlogger;

/// Open a specific folder or url with the system's file manager.
void openFolder(string path)
{
    import std.process : spawnProcess;

    if (path.length == 0)
        return;

    version (Windows) static immutable app = "explorer";
    else              static immutable app = "xdg-open";
    
    logInfo("Opening '%s'...", path);

    try spawnProcess([app, path]); catch (Exception ex) { logError("%s: %s", app, ex.msg); }
}
alias openBrowser = openFolder;

/// Build the `vrchat://launch` URI for a location ("wrld_xxx:12345~...").
private string vrchatLaunchUri(string location)
{
    return "vrchat://launch?ref=vrcd&id=" ~ location;
}

/// Launch VRChat into an instance via its launch URI ("Open in VRChat").
///
/// Windows: a running client is reached directly over its launch-URI named
/// pipe (seamless in-client transition); otherwise the natively registered
/// `vrchat://` scheme handles it, cold-booting the game into the instance.
///
/// Linux: the host has no `vrchat://` scheme handler under Proton
/// (xdg-open/gio report "location not supported"), so the URI is handed to
/// Steam, which cold-boots VRChat with it. Only correct when the game is
/// not running: a second launch gets its own pressure-vessel container and
/// wineserver, so the URI never reaches the running client. For that case
/// use startVRChatIPCJoin instead.
void openVRChatInstance(string location)
{
    import std.process : spawnProcess;

    if (location.length == 0)
        return;

    string uri = vrchatLaunchUri(location);

    logInfo("Launching VRChat instance '%s'...", location);

    version (Windows)
    {
        import vrcpipe;

        final switch (sendLaunchUri(uri)) with (PipeSendStatus)
        {
        case accepted:
            logInfo("VRChat accepted launch URI over pipe");
            return;
        case rejected:
            logWarn("VRChat rejected launch URI over pipe");
            break;
        case error:
            logWarn("VRChat launch pipe I/O error");
            break;
        case notFound: // Not running: the scheme launch boots the game.
            break;
        }

        try spawnProcess(["explorer", uri]);
        catch (Exception ex) { logError("explorer: %s", ex.msg); }
    }
    else
    {
        // VRChat's Steam app ID is 438100.
        try spawnProcess(["steam", "-applaunch", "438100", uri]);
        catch (Exception ex) { logError("steam: %s", ex.msg); }
    }
}

version (linux):

import std.process : Pid;
import core.time : MonoTime, dur;

// In-flight IPC join, polled by the GUI loop. Main thread only.
private __gshared Pid ipcJoinPid;
private __gshared string ipcJoinLocation;
private __gshared MonoTime ipcJoinStart;

/// D-Bus name the Steam launcher service registers for VRChat when the
/// game is launched with STEAM_COMPAT_LAUNCHER_SERVICE=proton.
private static immutable string VRCHAT_BUS_NAME = "com.steampowered.App438100";

/// Give up on an IPC join attempt after this long (covers a hung Wine
/// startup inside the container).
private enum ipcJoinTimeout = dur!"seconds"(15);

/// True when a VRChat.exe process is visible. Proton keeps the Windows
/// image path in the command line, and pressure-vessel does not hide the
/// game's processes from the host.
bool isVRChatRunning()
{
    import std.algorithm.searching : canFind;
    import std.ascii : isDigit;
    import std.file : dirEntries, read, DirEntry, SpanMode;
    import std.path : baseName, buildPath;

    try
    {
        foreach (DirEntry entry; dirEntries("/proc", SpanMode.shallow))
        {
            string name = baseName(entry.name);
            if (name.length == 0 || isDigit(name[0]) == false)
                continue;
            try
            {
                const(char)[] cmdline =
                    cast(const(char)[]) read(buildPath(entry.name, "cmdline"), 4096);
                if (canFind(cmdline, "VRChat.exe"))
                    return true;
            }
            catch (Exception) {} // Process exited mid-scan, unreadable, etc.
        }
    }
    catch (Exception ex)
    {
        logWarn("isVRChatRunning: /proc scan failed: %s", ex.msg);
    }
    return false;
}

/// Result of starting an IPC join attempt.
enum IPCJoinStart
{
    started,     /// Helper spawned; poll pollVRChatIPCJoin for the outcome.
    busy,        /// Another join attempt is still in flight.
    unavailable, /// Missing launch-client or helper; use a fallback path.
}

/// Ask the running VRChat client to join an instance, over its launch-URI
/// named pipe. The pipe lives inside the game's wineserver, which is
/// isolated in a pressure-vessel container, so the write is done by
/// running vrcd-pipehelper.exe (with the container's own Proton Wine) via
/// Steam's launcher service. Requires VRChat to be launched with
/// STEAM_COMPAT_LAUNCHER_SERVICE=proton in its Steam launch options.
IPCJoinStart startVRChatIPCJoin(string location)
{
    import std.file : exists, thisExePath;
    import std.path : buildPath, dirName;
    import std.process : spawnProcess;

    import client.directories : steamRuntimeLaunchClientPath, vrcdConfigPath;

    if (ipcJoinPid)
        return IPCJoinStart.busy;

    string launchClient = steamRuntimeLaunchClientPath();
    if (launchClient is null)
    {
        logWarn("IPC join: steam-runtime-launch-client not found in any Steam library");
        return IPCJoinStart.unavailable;
    }

    // The helper is a Windows build dropped next to the client binary, or
    // in the config dir for read-only installs (AppImage).
    string helper = buildPath(dirName(thisExePath()), "vrcd-pipehelper.exe");
    if (exists(helper) == false)
        helper = vrcdConfigPath("vrcd-pipehelper.exe");
    if (exists(helper) == false)
    {
        logWarn("IPC join: vrcd-pipehelper.exe not found next to client or in config dir");
        return IPCJoinStart.unavailable;
    }

    string uri = vrchatLaunchUri(location);
    logInfo("IPC join: injecting '%s' into container %s", uri, VRCHAT_BUS_NAME);
    try
    {
        // The "proton" launcher service runs commands inside the game's
        // Wine environment, so plain `wine` resolves to the same Proton
        // build (and wineserver) the game uses. Wine accepts the host path
        // of the helper directly.
        ipcJoinPid = spawnProcess([
            launchClient,
            "--bus-name=" ~ VRCHAT_BUS_NAME,
            "--",
            "wine", helper, uri,
        ]);
    }
    catch (Exception ex)
    {
        logError("IPC join: %s", ex.msg);
        return IPCJoinStart.unavailable;
    }
    ipcJoinLocation = location;
    ipcJoinStart = MonoTime.currTime;
    return IPCJoinStart.started;
}

/// Outcome of polling the in-flight IPC join.
enum IPCJoinPoll
{
    idle,    /// Nothing in flight.
    running, /// Still waiting on the helper.
    success, /// VRChat accepted the URI; the user is transitioning.
    failed,  /// Helper or injection failed; `location` is set for fallback.
}

/// Poll the in-flight IPC join attempt. Call once per frame; on `success`
/// and `failed`, `location` receives the requested instance location.
IPCJoinPoll pollVRChatIPCJoin(out string location)
{
    import std.process : kill, tryWait, wait;
    import std.typecons : Tuple;

    if (ipcJoinPid is null)
        return IPCJoinPoll.idle;

    Tuple!(bool, "terminated", int, "status") res = tryWait(ipcJoinPid);
    if (res.terminated == false)
    {
        if (MonoTime.currTime - ipcJoinStart < ipcJoinTimeout)
            return IPCJoinPoll.running;
        logWarn("IPC join: timed out after %s, killing helper", ipcJoinTimeout);
        try { kill(ipcJoinPid); wait(ipcJoinPid); }
        catch (Exception ex) { logWarn("IPC join: kill: %s", ex.msg); }
        res.status = -1;
    }

    location = ipcJoinLocation;
    ipcJoinPid = null;
    ipcJoinLocation = null;

    if (res.status == 0)
    {
        logInfo("IPC join: VRChat accepted '%s'", location);
        return IPCJoinPoll.success;
    }

    // 2 comes from the helper (pipe missing inside the container); 125-127
    // come from launch-client itself, typically because the launcher
    // service is not running.
    if (res.status >= 125 && res.status <= 127)
        logWarn("IPC join: launch-client exit %d; is VRChat launched with "
            ~ "STEAM_COMPAT_LAUNCHER_SERVICE=proton %%command%% ?", res.status);
    else
        logWarn("IPC join: helper exit %d", res.status);
    return IPCJoinPoll.failed;
}