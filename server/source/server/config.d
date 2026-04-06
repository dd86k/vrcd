/// Server configuration
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.config;

import std.path : buildPath, expandTilde;

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
}
