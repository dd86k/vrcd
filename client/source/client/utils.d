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

/// Give up on an IPC join attempt after this long (covers a hung Wine
/// startup against the game's wineserver).
private enum ipcJoinTimeout = dur!"seconds"(15);

/// A running VRChat process, with what is needed to attach a second Wine
/// process to the wineserver it lives in.
private struct ProtonProcess
{
    int pid;       /// PID of the VRChat.exe process.
    string wine;   /// Wine binary of the Proton build running the game.
    string prefix; /// Prefix the game runs in, as visible from the host.
    string esync;  /// WINEESYNC, "0" when the game runs without it.
    string fsync;  /// WINEFSYNC, "0" when the game runs without it.
}

/// Locate a running VRChat.exe and read out of /proc what is needed to talk
/// to its wineserver. Proton keeps the Windows image path in the command
/// line, and pressure-vessel does not hide the game's processes from the
/// host, so the game is visible from here even though its filesystem view
/// is not.
///
/// Several processes in the launch chain carry "VRChat.exe" in their command
/// line (reaper, steam-launch-wrapper, the runtime entry point, the proton
/// script) and none of those can answer for a prefix, so `wine` and `prefix`
/// come from the first candidate that yields both. `pid` is set for any
/// candidate, which is all "is the game running" needs.
private ProtonProcess findVRChatProcess()
{
    import std.algorithm.searching : canFind;
    import std.ascii : isDigit;
    import std.conv : to;
    import std.file : dirEntries, exists, read, DirEntry, SpanMode;
    import std.path : baseName, buildPath;

    import client.directories : vrchatProtonPrefix;

    ProtonProcess result;
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
                if (canFind(cmdline, "VRChat.exe") == false)
                    continue;

                int pid = to!int(name);
                if (result.pid == 0)
                    result.pid = pid;

                string wine = wineBinaryOf(entry.name);
                if (wine is null)
                    continue;

                string[string] vars = wineEnvironOf(entry.name);
                string prefix = vars.get("WINEPREFIX", null);
                // The container can see the prefix at a path that does not
                // exist out here; the Steam library layout gives the same
                // prefix from this side. Never point Wine at a missing
                // prefix: it would create a fresh one and start its own
                // wineserver, which has no launch pipe in it.
                if (prefix is null || exists(prefix) == false)
                    prefix = vrchatProtonPrefix();
                if (prefix is null || exists(prefix) == false)
                    continue;

                result.pid = pid;
                result.wine = wine;
                result.prefix = prefix;
                result.esync = vars.get("WINEESYNC", "0");
                result.fsync = vars.get("WINEFSYNC", "0");
                return result;
            }
            catch (Exception) {} // Process exited mid-scan, unreadable, etc.
        }
    }
    catch (Exception ex)
    {
        logWarn("findVRChatProcess: /proc scan failed: %s", ex.msg);
    }
    return result;
}

/// Resolve the Wine binary of a running Proton process. `/proc/<pid>/exe`
/// points at the loader the process was started with (`wine64-preloader` on
/// older Proton builds, `wine` on wow64 ones), which is not something to
/// start a program with, so a sibling Wine binary is used instead. Returns
/// null when the process is not a Wine one.
private string wineBinaryOf(string procDir)
{
    import std.algorithm.searching : startsWith;
    import std.file : exists, readLink;
    import std.path : baseName, buildPath, dirName;

    string exe = readLink(buildPath(procDir, "exe"));
    if (startsWith(baseName(exe), "wine") == false)
        return null;

    string dir = dirName(exe);
    foreach (string candidate; [ "wine64", "wine" ])
    {
        string path = buildPath(dir, candidate);
        if (exists(path))
            return path;
    }
    return null;
}

/// Read the `WINE*` environment of a running process out of /proc.
private string[string] wineEnvironOf(string procDir)
{
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : startsWith;
    import std.file : read;
    import std.path : buildPath;
    import std.string : indexOf;

    string[string] vars;
    // environ is a NUL-separated blob; 64 KiB covers it with room to spare.
    const(char)[] blob =
        cast(const(char)[]) read(buildPath(procDir, "environ"), 64 * 1024);
    foreach (const(char)[] item; splitter(blob, '\0'))
    {
        ptrdiff_t eq = indexOf(item, '=');
        if (eq <= 0)
            continue;
        const(char)[] key = item[0 .. eq];
        if (startsWith(key, "WINE") == false)
            continue;
        vars[key.idup] = item[eq + 1 .. $].idup;
    }
    return vars;
}

/// True when a VRChat process is visible.
bool isVRChatRunning()
{
    return findVRChatProcess().pid != 0;
}

/// Result of starting an IPC join attempt.
enum IPCJoinStart
{
    started,     /// Helper spawned; poll pollVRChatIPCJoin for the outcome.
    busy,        /// Another join attempt is still in flight.
    unavailable, /// Missing launch-client or helper; use a fallback path.
}

/// Ask the running VRChat client to join an instance, over its launch-URI
/// named pipe.
///
/// The pipe lives in the game's wineserver, which runs inside a
/// pressure-vessel container, but the wineserver's socket directory
/// (`/tmp/.wine-<uid>/server-<dev>-<inode>`) is shared with the host, so a
/// Wine process started here against the same prefix attaches to that same
/// wineserver and sees the pipe. The write is done by vrcd-pipehelper.exe,
/// run with the Proton build the game itself is running under, both read out
/// of /proc. No Steam launch options are involved.
IPCJoinStart startVRChatIPCJoin(string location)
{
    import std.file : exists, thisExePath;
    import std.path : buildPath, dirName;
    import std.process : spawnProcess;
    import std.stdio : File;

    import client.directories : vrcdConfigPath;

    if (ipcJoinPid)
        return IPCJoinStart.busy;

    ProtonProcess game = findVRChatProcess();
    if (game.wine is null)
    {
        logWarn("IPC join: no VRChat Wine process found in /proc");
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
    logInfo("IPC join: sending '%s' to the wineserver of pid %d (prefix %s)",
        uri, game.pid, game.prefix);
    try
    {
        // Same prefix, same wineserver, so the helper sees the pipe the
        // game listens on; esync/fsync have to match the server it joins.
        // Wine takes the host path of the helper as is. The helper is a
        // console program with nothing to say that its exit code does not,
        // and Wine is chatty on stderr, so its output goes nowhere.
        string[string] env = [
            "WINEPREFIX": game.prefix,
            "WINEESYNC":  game.esync,
            "WINEFSYNC":  game.fsync,
            "WINEDEBUG":  "-all",
        ];
        File devNull = File("/dev/null", "r+");
        ipcJoinPid = spawnProcess([ game.wine, helper, uri ],
            devNull, devNull, devNull, env);
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

    // 2 comes from the helper: it reached a wineserver, but not one with a
    // launch pipe in it, so it is not the one the game listens in.
    if (res.status == 2)
        logWarn("IPC join: no launch pipe in the prefix; wrong wineserver?");
    else
        logWarn("IPC join: helper exit %d", res.status);
    return IPCJoinPoll.failed;
}