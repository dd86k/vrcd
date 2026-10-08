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
        logpath = vrcdAppDataPath( format("vrcd_%04d%02d%02d.log", time.year, time.month, time.day) );
    }

    string logdir  = dirName( logpath ); // slice, no allocation

    mkdirRecurse(logdir);

    // FileAppender appends existing files
    FileAppender fileAppender = new FileAppender(logpath);
    fileAppender.setLogLevel(loglevel);
    logAddAppender(fileAppender);

    logInfo("New launch at %s, logging to %s", time, logpath);
}

// Windows: a GUI-subsystem process only has a stderr when it was redirected.
bool hasStderr()
{
    version (Windows)
    {
        import core.sys.windows.windows : HANDLE, GetStdHandle, GetFileType,
            STD_ERROR_HANDLE, INVALID_HANDLE_VALUE, FILE_TYPE_UNKNOWN;
        HANDLE h = GetStdHandle(STD_ERROR_HANDLE);
        return h && h != INVALID_HANDLE_VALUE && GetFileType(h) != FILE_TYPE_UNKNOWN;
    }
    else
        return true;
}

// Windows: no console even when launched from one, so borrow the parent's.
bool attachConsole()
{
    if (hasStderr())
        return true;
    version (Windows)
    {
        import core.sys.windows.windows : AttachConsole, ATTACH_PARENT_PROCESS;
        if (AttachConsole(ATTACH_PARENT_PROCESS) == 0)
            return false;
        try stderr.reopen("CONOUT$", "w");
        catch (Exception)
            return false;
        return true;
    }
    else
        return false;
}

void printLine(string name, const(char)[] val)
{
    enum WIDTH = -15;
    writefln("%*s %s", WIDTH, name ? name : "", val);
}

int main(string[] args)
{
    version (Posix)
    {
        import core.sys.posix.signal : signal, SIGPIPE, SIG_IGN;

        // OpenSSL writes with write(2), including from inside SSL_read: a
        // TLS 1.3 session ticket or key update is answered on the spot, and
        // so is the alert a shutdown sends. On the default disposition a
        // peer that has gone away then kills the whole process from the
        // network thread -- and TLSClientStream.unblock() shuts the socket
        // down underneath a blocked reader deliberately, so this is the
        // ordinary way a connection ends here, not an edge case. Ignored,
        // the write fails, SSL_read returns <= 0, and the reader exits the
        // way it does for any other closed connection.
        signal(SIGPIPE, SIG_IGN);
    }
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
        std.getopt.config.caseSensitive,
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
    // Set up logging.
    LogLevel logLevel = verbose ? LogLevel.trace : LogLevel.info;
    // Errors reach stderr regardless of --verbose: the log file is no help to
    // somebody who does not know where it is, nor when it is what failed.
    ConsoleAppender console;
    if (verbose ? attachConsole() : hasStderr())
    {
        console = new ConsoleAppender();
        console.setLogLevel(verbose ? logLevel : LogLevel.error);
        logAddAppender(console);
    }
    try setuplogging(logLevel, logFilePath);
    catch (Exception ex)
    {
        if (console)
            console.setLogLevel(logLevel);
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

