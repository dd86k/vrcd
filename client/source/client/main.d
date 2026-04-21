/// Client entry point
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module client.main;

import std.getopt;
import std.stdio : stderr, writeln, writefln;
import std.json;
import std.string : stripRight;

import bindbc.sdl;
import sdl_ttf;
import sdl_image;

import ddlogger;

import client.connection;
import client.gui;
import client.directories;

// Setup file logger
void setuplogging(LogLevel loglevel, string logpath = null)
{
    import client.directories : vrcdAppDataPath;
    import std.path : dirName;
    import std.datetime : Clock, SysTime;
    import std.format : format;
    import std.file : mkdirRecurse;
    
    SysTime time = Clock.currTime();
    
    if (logpath is null)
    {
        logpath = vrcdAppDataPath( format("vrcd_%04d%02d%02d_%02d%02d.log",
            time.year, time.month, time.day, time.hour, time.minute) );
    }
    
    string logdir  = dirName( logpath ); // slice, no allocation
    
    mkdirRecurse(logdir);
    
    FileAppender fileAppender = new FileAppender(logpath);
    fileAppender.setLogLevel(loglevel);
    logAddAppender(fileAppender);
    
    logInfo("New launch at %s", time);
}

void printLine(string name, const(char)[] val)
{
    enum WIDTH = -15;
    writefln("%*s %s", WIDTH, name ? name : "", val);
}

version (Windows)
{
    import core.runtime;
    import core.sys.windows.windows;
    import std.string;
    
    // NOTE: Windows subsystem
    //       Because SUBSYSTEM:CONSOLE spawns a console, we otherwise have to call
    //       FreeConsole() or hide it, which isn't wrong, but since it's supposed
    //       to be a GUI app anyway, having SUBSYSTEM:WINDOWS makes it a little
    //       more "proper"
    //
    //       Using the WinMain signature is a temporary solution until we can use
    //       D main again
    //
    //       Using LDC 1.41 fails because PAGESIZE is undefined in core.thread.fiber,
    //       outside my control
    //
    //       The following lflags will fail under LDC (tested with 1.40)
    //       lflags "/SUBSYSTEM:WINDOWS" "/ENTRY:mainCRTStartup" platform="windows"
    //       libcmt.lib: Unresolved symbol ?__scrt_common_main_seh@@YAHXZ
    extern (Windows)
    int WinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance,
                LPSTR lpCmdLine, int nCmdShow)
    {
        Runtime.initialize(); // required, crashes otherwise
        // NOTE: Runtime.args() doesn't work because we're defining our own entrypoint
        string[] args = split( cast(string) fromStringz(lpCmdLine) );
        int r = startvrcd("vrcd_client.exe" ~ args); // std.getopt depends argv[0]
        Runtime.terminate();
        return r;
    }
}
else
int main(string[] args)
{
    return startvrcd(args);
}

int startvrcd(string[] args)
{
    string host;
    ushort port;
    string secret;
    long sinceId = -1;
    bool verbose;
    bool cliMode;
    bool hardwareAccel;
    bool showVersion;
    string logFilePath;

    GetoptResult opts = void;
    try opts = getopt(args,
        "host|h",     "Server host", &host,
        "port|p",     "Server port", &port,
        "secret|s",   "API secret", &secret,
        "since",      "Catch up from event ID (overrides persisted cursor; 0 = all)", &sinceId,
        "verbose|v",  "Enable verbose logging", &verbose,
        "cli",        "CLI mode (no GUI)", &cliMode,
        "hardware",   "Allow hardware-accelerated framebuffer (default: software)", &hardwareAccel,
        "log-file|L", "Append log output to file", &logFilePath,
        "version",    "Show version information and exit", &showVersion,
    );
    catch (Exception ex)
    {
        stderr.writeln("error: ", ex.msg);
        return 1;
    }

    if (opts.helpWanted)
    {
        defaultGetoptPrinter(
            "vrcd client - VRChat event viewer\n" ~
            "\n" ~
            "Usage: client [options...]\n" ~
            "\n" ~
            "Connects to a vrcd server, catches up on missed events,\n" ~
            "and displays them in a GUI (default) or streams to stdout (--cli).\n" ~
            "\n" ~
            "Options:",
            opts.options,
        );
        return 0;
    }
    
    // HACK: Hide console window on Windows
    //       - "/SUBSYSTEM:WINDOWS" is proper but leads to linker errors
    // TODO: WinMain wrapper to startvrcd(string args[])
    /*
    version (Windows)
    {
        import core.sys.windows.windows : ShowWindow, GetConsoleWindow, SW_HIDE, FreeConsole, FALSE;
        if (FreeConsole() == FALSE)
            ShowWindow(GetConsoleWindow(), SW_HIDE); // Fallback
    }
    */

    // Set up logging.
    LogLevel logLevel = verbose ? LogLevel.trace : LogLevel.info;
    try setuplogging(logLevel, logFilePath);
    catch (Exception ex)
    {
        // Fallback to console logging
        ConsoleAppender logAppender = new ConsoleAppender();
        logAppender.setLogLevel(logLevel);
        logAddAppender(logAppender);
        
        logWarn("Failed to init file logs: %s", ex.msg);
    }

    // Detect which args were explicitly provided on the CLI.
    bool hostSet = host.length > 0;
    bool postSet = port != 0;
    bool secretSet = secret.length > 0;
    bool sinceSet = sinceId >= 0;

    // Apply defaults for unset CLI args.
    if (hostSet == false)
        host = "127.0.0.1";
    if (postSet == false)
        port = 9700;
    if (sinceSet == false)
        sinceId = 0;

    logDebugging("main: host=%s port=%d sinceId=%d sinceSet=%s verbose=%s hardware=%s",
        host, port, sinceId, sinceSet, verbose, hardwareAccel);

    try return runGui(host, port, secret, sinceId, hostSet, postSet, secretSet, sinceSet, hardwareAccel);
    catch (Exception ex)
    {
        // File logger or console logger can pick this up
        logCritical("Fatal: %s", ex);
        return 2;
    }
}

