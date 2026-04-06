/// Client entry point
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module client.main;

import std.getopt;
import std.stdio : stderr, writeln, writefln;
import std.json;

import ddlogger;

import client.connection;
import client.gui;

void cmdStream(string host, ushort port, string secret, long sinceId)
{
    ServerConnection conn = new ServerConnection(host, port, secret);

    conn.setEventCallback((JSONValue event) {
        long id = 0;
        if ("id" in event && event["id"].type == JSONType.integer)
            id = event["id"].get!long;

        string eventType = jsonStr(event, "event_type");
        string receivedAt = jsonStr(event, "received_at");
        string content = "";
        if ("content" in event)
            content = event["content"].toString();
        
        //writefln("#%d [%s] %s: %s", id, receivedAt, eventType, content);
        writefln("#%d [%s] %s", id, receivedAt, eventType);
    });

    conn.setErrorCallback((string msg) {
        logError("Server: %s", msg);
    });

    if (!conn.connect())
    {
        logError("Could not connect to server");
        return;
    }

    // Request catch-up then listen for live events.
    conn.catchUp(sinceId);
    conn.run();
}

int main(string[] args)
{
    string host;
    ushort port;
    string secret;
    long sinceId;
    bool verbose;
    bool cliMode;

    GetoptResult opts = void;
    try opts = getopt(args,
        "host|h",     "Server host", &host,
        "port|p",     "Server port", &port,
        "secret|s",   "API secret", &secret,
        "since",      "Catch up from event ID (0 = all)", &sinceId,
        "verbose|v",  "Enable verbose logging", &verbose,
        "cli",        "CLI mode (no GUI)", &cliMode,
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
    ConsoleAppender logAppender = new ConsoleAppender();
    logAppender.setLogLevel(verbose ? LogLevel.trace : LogLevel.info);
    logAddAppender(logAppender);

    // Detect which args were explicitly provided on the CLI.
    bool hostExplicit = host.length > 0;
    bool portExplicit = port != 0;
    bool secretExplicit = secret.length > 0;

    // Apply defaults for unset CLI args.
    if (!hostExplicit)
        host = "127.0.0.1";
    if (!portExplicit)
        port = 9700;

    if (cliMode)
    {
        cmdStream(host, port, secret, sinceId);
        return 0;
    }

    return runGui(host, port, secret, sinceId,
        hostExplicit, portExplicit, secretExplicit);
}

private string jsonStr(JSONValue json, string key)
{
    if (key in json && json[key].type == JSONType.string)
        return json[key].str;
    return "";
}
