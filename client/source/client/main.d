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

// TODO: Move CLI mode to its own subpackage
// Part of CLI mode
void cmdStream(string host, ushort port, string secret, long sinceId)
{
    ServerConnection conn = new ServerConnection(host, port, secret);

    conn.setEventCallback((JSONValue event) {
        long id = 0;
        if ("id" in event && event["id"].type == JSONType.integer)
            id = event["id"].get!long;

        string eventType;
        if (const(JSONValue)* v = "event_type" in event)
            eventType = v.str;
        string receivedAt;
        if (const(JSONValue)* v = "received_at" in event)
            receivedAt = v.str;
        string content = "";
        if ("content" in event)
            content = event["content"].toString();
        
        //writefln("#%d [%s] %s: %s", id, receivedAt, eventType, content);
        writefln("#%d [%s] %s", id, receivedAt, eventType);
    });

    conn.setErrorCallback((string msg) {
        logError("Server: %s", msg);
    });

    if (conn.connect() == false)
    {
        logError("Could not connect to server");
        return;
    }

    // Request catch-up then listen for live events.
    conn.catchUp(sinceId);
    conn.run();
}

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

// TODO: Once client becomes "true GUI", move this to CLI subpackage
void cmdVersion()
{
    import std.format : format, sformat;
    
    // Version, built date
    import client.config : VERSION;
    printLine("vrcd-client", VERSION);
    static immutable string BUILT_DATE = "Built: " ~ __TIMESTAMP__;
    printLine(null, BUILT_DATE);
    
    // License, Homepage
    printLine("License", "BSD-3-Clause-Clear");
    printLine(null,      "Copyright (c) dd86k <dd@dax.moe>");
    printLine("Homepage", "https://github.com/dd86k/vrcd");
    
    // Compiler
    static immutable string COMPILER = __VENDOR__ ~ " " ~ format("%u.%u", __VERSION__ / 1000, __VERSION__ % 1000);
    printLine("Compiler", COMPILER);
    
    // TODO: Take directly from dub.selections.json
    printLine("bindbc-common",  "1.0.5");
    printLine("bindbc-loader",  "1.1.5");
    printLine("bindbc-sdl",     "1.5.2");
    printLine("ddlogger",       "4ec9bc06bb90c4a7844f62fcfc1429bc7cdb1378");
    printLine("ddui",           "106ff4bdd26cfa07953acff559c195fb228909f5");
    
    static immutable const(char)[] NOT_FOUND = "(not found)";
    
    // SDL2 (core)
    char[16] buf = void;
    const(char)[] val = void;
    SDLSupport sdlStatus = loadSDL();
    if (sdlStatus == SDLSupport.noLibrary || sdlStatus == SDLSupport.badLibrary)
    {
        val = NOT_FOUND;
    }
    else
    {
        SDL_version ver = void;
        SDL_GetVersion(&ver);
        val = sformat(buf, "%d.%d.%d", ver.major, ver.minor, ver.patch);
    }
    printLine("SDL2", val);
    
    // SDL2_ttf
    SDLTTFSupport ttfStatus = loadSDLTTF();
    if (ttfStatus == SDLTTFSupport.noLibrary)
        ttfStatus = loadSDLTTF("libSDL2_ttf-2.0.so.0");
    if (ttfStatus == SDLTTFSupport.noLibrary || ttfStatus == SDLTTFSupport.badLibrary)
    {
        val = NOT_FOUND;
    }
    else
    {
        const(SDL_version)* ttfVer = TTF_Linked_Version();
        val = sformat(buf, "%d.%d.%d", ttfVer.major, ttfVer.minor, ttfVer.patch);
    }
    printLine("SDL2_ttf", val);
    
    // SDL2_image
    SDLImageSupport imgStatus = loadSDLImage();
    if (imgStatus == SDLImageSupport.noLibrary)
        imgStatus = loadSDLImage("libSDL2_image-2.0.so.0");
    if (imgStatus == SDLImageSupport.noLibrary || imgStatus == SDLImageSupport.badLibrary)
    {
        val = NOT_FOUND;
    }
    else
    {
        const(SDL_version)* imgVer = IMG_Linked_Version();
        val = sformat(buf, "%d.%d.%d", imgVer.major, imgVer.minor, imgVer.patch);
    }
    printLine("SDL2_image", val);
}

int main(string[] args)
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

    if (showVersion)
    {
        cmdVersion();
        return 0;
    }
    
    // HACK: Hide console window on Windows
    //       - "/SUBSYSTEM:WINDOWS" is proper but leads to linker errors
    // TODO: WinMain wrapper to startvrcd(string args[])
    version (Windows)
    {
        import core.sys.windows.windows : ShowWindow, GetConsoleWindow, SW_HIDE, FreeConsole, FALSE;
        if (FreeConsole() == FALSE)
            ShowWindow(GetConsoleWindow(), SW_HIDE); // Fallback
    }

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

    if (cliMode)
    {
        cmdStream(host, port, secret, sinceId);
        return 0;
    }

    try return runGui(host, port, secret, sinceId, hostSet, postSet, secretSet, sinceSet, hardwareAccel);
    catch (Exception ex)
    {
        // File logger or console logger can pick this up
        logCritical("Fatal: %s", ex);
        return 2;
    }
}

