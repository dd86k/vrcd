/// Server entry point
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.main;

import std.getopt;
import std.stdio : stderr, writeln, writefln;

import ddlogger;
import ddcurl;

import server.api;
import server.authdelegate;
import server.config;
import server.events;
import server.friends;
import server.ratelimit;
import server.store;
import server.worldcache;
import server.vrchat.auth;
import server.vrchat.websocket;

void cmdRun(ref Config config)
{
    import core.stdc.stdlib : exit;
    import core.thread : Thread;
    import core.time : dur;

    // Initialize database.
    EventStore store = new EventStore(config.dbPath);
    logInfo("Database loaded from '%s'", config.dbPath);

    scope HTTPClient client = new HTTPClient();
    bool headless = isHeadless();
    AuthDelegator delegator;
    APIServer apiServer;

    if (config.apiSecret.length == 0)
        logWarn("No --secret set, clients can connect without authentication");

    if (headless)
    {
        logInfo("Running in headless mode (no TTY), auth will be delegated to clients");

        // In headless mode, start API server first so clients can connect
        // and provide credentials/2FA codes if needed.
        delegator = new AuthDelegator();
        apiServer = new APIServer(config.listenAddr, config.listenPort, config.apiSecret, store);
        apiServer.setAuthDelegator(delegator);
        apiServer.start();
        logInfo("Server started, listening on %s:%d", config.listenAddr, config.listenPort);
    }

    // Auth VRChat (may block waiting for client in headless mode).
    AuthState authState;
    try
        authState = authenticate(config, client, delegator);
    catch (Exception e)
    {
        logError("Authentication failed: %s", e.msg);
        exit(1);
    }
    logInfo("Authenticated as %s (%s)", authState.displayName, authState.userId);

    // Create per-user VRCX-compatible tables from VRC user-id.
    store.initUserTables(authState.userId);

    if (apiServer is null)
    {
        // Interactive mode: start API server after auth.
        apiServer = new APIServer(config.listenAddr, config.listenPort, config.apiSecret, store);
        apiServer.start();
        logInfo("Server started, listening on %s:%d", config.listenAddr, config.listenPort);
    }

    // Rate limit tracker for VRChat API.
    RateLimitTracker rateLimiter = new RateLimitTracker();

    // Seed friends tracker from REST API.
    fetchAndSeedFriends(client, apiServer.getFriendsTracker(), rateLimiter);

    // World name cache for resolving world IDs via VRChat API.
    WorldCache worldCache = new WorldCache(client, rateLimiter);
    apiServer.setWorldCache(worldCache);
    apiServer.setHTTPClient(client);
    apiServer.setRateLimiter(rateLimiter);

    // Start WebSocket event listener.
    VRCWebSocket vrcws = new VRCWebSocket(authState.authToken,
    (VRCEvent event)
    {
        apiServer.getFriendsTracker().enrichContent(event);
        worldCache.enrichWorldName(event);
        long eventId = store.storeEvent(event);
        logInfo("[#%d %s] %s", eventId, event.typeRaw, event.content.toString());
        apiServer.broadcast(event, eventId);
    });
    vrcws.setStatusCallback((bool connected, string lastError)
    {
        logInfo("VRChat WebSocket %s", connected ? "connected" : "disconnected");
        apiServer.setVRChatStatus(connected, lastError);
        store.logConnection(connected ? "connected" : "disconnected");
    });
    vrcws.setReAuthCallback({
        logInfo("Re-authenticating with VRChat...");
        AuthState newState = authenticate(config, client, delegator);
        vrcws.setToken(newState.authToken);
        logInfo("Re-authenticated as %s", newState.displayName);
    });
    vrcws.start();

    logInfo("Server running. Press Ctrl+C to stop.");

    // Keep main thread alive.
    while (true)
        Thread.sleep(dur!"seconds"(1));
}

void cmdAuth(ref Config config)
{
    logInfo("Interactive VRChat login");
    scope HTTPClient client = new HTTPClient();
    AuthState authState = interactiveLogin(config, client);
    logInfo("Authenticated as %s (%s)", authState.displayName, authState.userId);
    logInfo("Session saved. You can now run the server.");
}

void cmdEvents(ref Config config)
{
    import std.stdio : writefln;
    scope EventStore store = new EventStore(config.dbPath);
    foreach (row; store.queryRecentEvents(50))
        writefln("#%s [%s] %s: %s", row[0], row[1], row[2], row[3]);
}

template DVER(uint ver)
{
    enum DVER =
        cast(char)((ver / 1000) + '0') ~ "." ~
        cast(char)(((ver % 1000) / 100) + '0') ~
        cast(char)(((ver % 100) / 10) + '0') ~
        cast(char)((ver % 10) + '0');
}

// Hack to get arsd-official version at compile-time
enum string arsdVersion = () {
    import std.json;
    // string import resolved at compile time                           
    enum selectionsJson = import("dub.selections.json");
    enum parsed = parseJSON(selectionsJson);                            
    enum ver = parsed["versions"]["arsd-official"].str;
    return ver;  // "11.5.3" 
}();

void printline(string field, string value)
{
    writefln("%*s  %s", -16, field ? field : "", value);
}

void cliVersion()
{
    import core.stdc.stdlib : exit;
    static immutable string BUILT       = "Built: " ~ __TIMESTAMP__;
    static immutable string COMPILER    = __VENDOR__ ~ " " ~ DVER!__VERSION__;
    enum APP_VERSION = import("VERSION");
    printline("vrcd-server",    APP_VERSION);
    printline(null,             BUILT);
    printline("License",        "BSD-3-Clause-Clear");
    printline(null,             "Copyright 2026 (c) dd86k <dd@dax.moe>");
    printline("Homepage",       "https://github.com/dd86k/vrcd");
    printline("Compiler",       COMPILER);
    
    import ddcurl.libcurl : curlVersion;
    printline("libcurl",        curlVersion());
    
    printline("arsd-official",  arsdVersion);
    
    exit(0);
}

int main(string[] args)
{
    Config config = Config.defaults();
    uint cliSet; // Bitmask of fields explicitly set by CLI.
    bool helpConfig;

    GetoptResult opts = void;
    try opts = getopt(args,
        "basedir|b", "Base directory for all config/data files", (string _, string val) {
            config.setBaseDir(val);
            cliSet |= Config.SET_DB | Config.SET_AUTH | Config.SET_COOKIE_JAR;
        },
        "config|c", "Path to config file", (string _, string val) {
            config.configPath = val;
        },
        "db|d",     "Path to SQLite database", (string _, string val) {
            config.dbPath = val;
            cliSet |= Config.SET_DB;
        },
        "listen|l", "Listen address (host:port)", (string _, string val) {
            config.parseListen(val);
            cliSet |= Config.SET_LISTEN;
        },
        "secret",   "Shared secret for client auth", (string _, string val) {
            config.apiSecret = val;
            cliSet |= Config.SET_SECRET;
        },
        "auth|a",   "Path to credentials file", (string _, string val) {
            config.credentialsPath = val;
            cliSet |= Config.SET_AUTH;
        },
        "verbose|v","Enable verbose logging", () {
            config.verbose = true;
            cliSet |= Config.SET_VERBOSE;
        },
        "version",  "Show version page and exit", &cliVersion,
        "help-config", "Show effective config paths and exit", &helpConfig,
    );
    catch (Exception ex)
    {
        stderr.writeln("error: ", ex.msg);
        return 1;
    }

    // Load config file after CLI so we can use --config to set the path.
    // Fields explicitly set on CLI are preserved; file fills in the rest.
    config.loadFromFile(config.configPath, cliSet);

    if (opts.helpWanted)
    {
        defaultGetoptPrinter(
            "vrcd server - VRChat event recorder\n" ~
            "\n" ~
            "Usage: server [commands...] [options...]\n" ~
            "\n" ~
            "Commands:\n" ~
            "  run      Start the server (default)\n" ~
            "  auth     Interactive login to VRChat\n" ~
            "  events   Query stored events\n" ~
            "\n" ~
            "Options:",
            opts.options,
        );
        return 0;
    }

    if (helpConfig)
    {
        import std.file : exists;
        import std.conv : to;
        printline("Config file", config.configPath ~
            (exists(config.configPath) ? " (loaded)" : " (not found)"));
        printline("Database", config.dbPath);
        printline("Credentials", config.credentialsPath);
        printline("Cookie jar", config.cookieJarPath);
        printline("Listen", config.listenAddr ~ ":" ~ to!string(config.listenPort));
        printline("Secret", config.apiSecret.length > 0 ? "(set)" : "(not set)");
        printline("Verbose", config.verbose ? "true" : "false");
        return 0;
    }

    // Set up logging
    ConsoleAppender logAppender = new ConsoleAppender();
    logAppender.setLogLevel(config.verbose ? LogLevel.trace : LogLevel.info);
    logAddAppender(logAppender);
    
    // Throws and prints by default
    if (args.length > 1)
    {
        foreach (string command; args[1..$])
        {
            switch (command)
            {
                case "run":
                    cmdRun(config);
                    break;
                case "auth":
                    cmdAuth(config);
                    break;
                case "events":
                    cmdEvents(config);
                    break;
                default:
                    logError("Unknown command: %s", command);
                    break;
            }
        }
    }
    else // by default, run
    {
        cmdRun(config);
    }
    
    return 0;
}

/// Fetch the full friends list from VRChat REST API and seed the tracker.
/// Paginates with offset/n until fewer than `n` results are returned.
void fetchAndSeedFriends(HTTPClient client, FriendsTracker tracker, RateLimitTracker rateLimiter = null)
{
    import std.json : JSONValue, JSONType, parseJSON;
    import std.conv : to;
    import std.format : format;

    enum PAGE_SIZE = 100;
    int offset;
    JSONValue[] allFriends;

    logInfo("Fetching friends list from VRChat API...");

    while (true)
    {
        if (rateLimiter !is null)
            rateLimiter.waitIfNeeded();

        string path = format!"/auth/user/friends?offset=%d&n=%d&offline=false"(offset, PAGE_SIZE);
        HTTPResponse resp = client.get(path);
        if (rateLimiter !is null)
            rateLimiter.update(resp);

        if (resp.code != 200)
        {
            logWarn("Failed to fetch friends (offset=%d): HTTP %d", offset, resp.code);
            break;
        }

        JSONValue json = parseJSON(resp.text);
        if (json.type != JSONType.array)
        {
            logWarn("Unexpected friends response type");
            break;
        }

        JSONValue[] page = json.array;
        foreach (ref JSONValue f; page)
            allFriends ~= f;

        logInfo("Fetched %d friends (offset=%d)", page.length, offset);

        if (page.length < PAGE_SIZE)
            break;

        offset += PAGE_SIZE;
    }

    // Also fetch offline friends.
    offset = 0;
    while (true)
    {
        if (rateLimiter !is null)
            rateLimiter.waitIfNeeded();

        string path = format!"/auth/user/friends?offset=%d&n=%d&offline=true"(offset, PAGE_SIZE);
        HTTPResponse resp = client.get(path);
        if (rateLimiter !is null)
            rateLimiter.update(resp);

        if (resp.code != 200)
        {
            logWarn("Failed to fetch offline friends (offset=%d): HTTP %d", offset, resp.code);
            break;
        }

        JSONValue json = parseJSON(resp.text);
        if (json.type != JSONType.array)
            break;

        JSONValue[] page = json.array;
        foreach (ref JSONValue f; page)
            allFriends ~= f;

        logInfo("Fetched %d offline friends (offset=%d)", page.length, offset);

        if (page.length < PAGE_SIZE)
            break;

        offset += PAGE_SIZE;
    }

    tracker.seedFromAPI(allFriends);
}
