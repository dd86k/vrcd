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