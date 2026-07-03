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

/// Launch VRChat into an instance via its launch URI ("Open in VRChat").
///
/// The host has no `vrchat://` scheme handler under Proton (xdg-open/gio
/// report "location not supported"), so on Linux we hand the URI to Steam,
/// which routes it through VRChat's Proton prefix. On Windows the scheme is
/// registered natively, so the shell opener handles it.
void openVRChatInstance(string location)
{
    import std.process : spawnProcess;

    if (location.length == 0)
        return;

    string uri = "vrchat://launch?ref=vrcd&id=" ~ location;

    logInfo("Launching VRChat instance '%s'...", location);

    version (Windows)
    {
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