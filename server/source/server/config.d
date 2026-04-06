/// Server configuration
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.config;

import std.path : buildPath, expandTilde;
import std.string : strip, indexOf, lineSplitter;

/// Server configuration loaded from file or CLI args.
struct Config
{
    string configPath;
    string dbPath;
    string listenAddr = "127.0.0.1";
    ushort listenPort = 9700;
    string credentialsPath;
    string cookieJarPath;
    string apiSecret; /// Shared secret for client auth. Empty = no auth required.
    bool verbose;

    /// Bitmask constants for tracking which fields were set by CLI.
    enum : uint
    {
        SET_DB         = 1 << 0,
        SET_LISTEN     = 1 << 1,
        SET_SECRET     = 1 << 2,
        SET_AUTH       = 1 << 3,
        SET_COOKIE_JAR = 1 << 4,
        SET_VERBOSE    = 1 << 5,
    }

    /// Resolve default paths based on platform.
    static Config defaults()
    {
        Config c;
        version (Windows)
        {
            import std.process : environment;
            string appdata  = environment.get("APPDATA", ".");
            string base     = buildPath(appdata, "vrcd");
            c.configPath    = buildPath(base, "server.conf");
            c.dbPath        = buildPath(base, "server.db");
            c.credentialsPath = buildPath(base, "credentials.json");
            c.cookieJarPath = buildPath(base, "cookies.txt");
        }
        else
        {
            string configHome   = expandTilde("~/.config/vrcd");
            c.configPath        = buildPath(configHome, "server.conf");
            c.credentialsPath   = buildPath(configHome, "credentials.json");

            string dataHome     = expandTilde("~/.local/share/vrcd");
            c.dbPath            = buildPath(dataHome, "server.db");
            c.cookieJarPath     = buildPath(dataHome, "cookies.txt");
        }
        return c;
    }

    /// Override all paths to use the given base directory.
    void setBaseDir(string base)
    {
        configPath    = buildPath(base, "server.conf");
        dbPath        = buildPath(base, "server.db");
        credentialsPath = buildPath(base, "credentials.json");
        cookieJarPath = buildPath(base, "cookies.txt");
    }

    /// Load configuration from a key=value file.
    /// Lines starting with # are comments. Empty lines are ignored.
    /// Fields in cliSet are skipped (already set by CLI).
    void loadFromFile(string path, uint cliSet = 0)
    {
        import std.file : readText, exists;

        if (!exists(path))
            return;

        string text = readText(path);
        foreach (string line; text.lineSplitter())
        {
            line = line.strip();
            if (line.length == 0 || line[0] == '#')
                continue;

            ptrdiff_t eq = line.indexOf('=');
            if (eq < 1)
                continue;

            string key = line[0 .. eq].strip();
            string val = line[eq + 1 .. $].strip();

            switch (key)
            {
                case "basedir":
                    // Only override paths not already set by CLI.
                    string base = val;
                    if ((cliSet & SET_DB) == 0)
                        dbPath = buildPath(base, "server.db");
                    if ((cliSet & SET_AUTH) == 0)
                        credentialsPath = buildPath(base, "credentials.json");
                    if ((cliSet & SET_COOKIE_JAR) == 0)
                        cookieJarPath = buildPath(base, "cookies.txt");
                    break;
                case "db":
                    if ((cliSet & SET_DB) == 0)
                        dbPath = val;
                    break;
                case "listen":
                    if ((cliSet & SET_LISTEN) == 0)
                        parseListen(val);
                    break;
                case "secret":
                    if ((cliSet & SET_SECRET) == 0)
                        apiSecret = val;
                    break;
                case "auth":
                    if ((cliSet & SET_AUTH) == 0)
                        credentialsPath = val;
                    break;
                case "cookie_jar":
                    if ((cliSet & SET_COOKIE_JAR) == 0)
                        cookieJarPath = val;
                    break;
                case "verbose":
                    if ((cliSet & SET_VERBOSE) == 0)
                        verbose = (val == "true" || val == "1");
                    break;
                default:
                    break;
            }
        }
    }

    void parseListen(string val)
    {
        import std.conv : to;
        import std.string : lastIndexOf;

        ptrdiff_t sep = val.lastIndexOf(':');
        if (sep > 0)
        {
            listenAddr = val[0 .. sep];
            listenPort = val[sep + 1 .. $].to!ushort;
        }
    }
}
