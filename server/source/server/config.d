/// Server configuration
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.config;

import core.time : dur, Duration;
import std.path : buildPath, expandTilde;
import std.string : strip, indexOf, lineSplitter;

/// Default friend state reseed interval.
///
/// This variable dictates how often to re-fetch all friends from the VRChat API.
///
/// Used in config and api.
immutable DEFAULT_RESEED_INTERVAL = dur!"hours"(2);

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
    string logFilePath; /// Optional file to append log output to. Empty = disabled.
    Duration reseedInterval = DEFAULT_RESEED_INTERVAL;
    /// SQLite datetime modifier for event retention, e.g. "-3 months".
    /// Empty = keep forever (default).
    string pruneRetain;
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
        SET_LOG_FILE   = 1 << 6,
        SET_PRUNE      = 1 << 7,
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

        if (exists(path) == false)
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
                case "log_file":
                    if ((cliSet & SET_LOG_FILE) == 0)
                        logFilePath = val;
                    break;
                case "reseed_interval":
                    import std.conv : to;
                    try reseedInterval = dur!"minutes"(val.to!int);
                    catch (Exception ex)
                    {
                        throw new Exception("Invalid value for reseed_interval: " ~ ex.msg);
                    }
                    break;
                case "prune_retain":
                    if ((cliSet & SET_PRUNE) == 0)
                        // NOTE: SQLite format
                        pruneRetain = parsePruneRetain(val);
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

/// Parse a human-friendly retention string (e.g. "3 months") into a SQLite
/// datetime modifier (e.g. "-3 months") suitable for use in
/// `datetime('now', modifier)`. Throws on invalid input.
///
/// Supported units: days, weeks, months, years (singular or plural).
/// Weeks are converted to days since SQLite has no native week modifier.
string parsePruneRetain(string val)
{
    import std.conv : to, ConvException;
    import std.format : format;
    import std.string : split, strip;
    import std.uni : toLower;

    string[] parts = val.strip().split();
    if (parts.length != 2)
        throw new Exception("Expected format: AMOUNT UNIT (e.g. '3 months')");

    // Get amount
    long amount;
    try
        amount = parts[0].to!long;
    catch (ConvException)
        throw new Exception("Invalid amount '" ~ parts[0] ~ "': must be a positive integer");
    if (amount <= 0)
        throw new Exception("Retention amount must be greater than zero");

    // Translate to SQLite happy words
    string unit;
    switch (parts[1].toLower())
    {
        case "day",   "days":   unit = "days";   break;
        case "week",  "weeks":  unit = "days"; amount *= 7; break;
        case "month", "months": unit = "months"; break;
        case "year",  "years":  unit = "years";  break;
        default:
            throw new Exception("Unknown unit '" ~ parts[1] ~ "': use days, weeks, months, or years");
    }

    return format!"-%d %s"(amount, unit);
}

unittest
{
    // Plural forms.
    assert(parsePruneRetain("3 months") == "-3 months");
    assert(parsePruneRetain("30 days")  == "-30 days");
    assert(parsePruneRetain("1 year")   == "-1 years");
    assert(parsePruneRetain("2 years")  == "-2 years");

    // Singular forms.
    assert(parsePruneRetain("1 day")   == "-1 days");
    assert(parsePruneRetain("1 month") == "-1 months");

    // Weeks expand to days.
    assert(parsePruneRetain("1 week")  == "-7 days");
    assert(parsePruneRetain("2 weeks") == "-14 days");

    // Case-insensitive units.
    assert(parsePruneRetain("3 Months") == "-3 months");
    assert(parsePruneRetain("5 DAYS")   == "-5 days");

    // Leading/trailing whitespace is stripped.
    assert(parsePruneRetain("  6 months  ") == "-6 months");
    
    // Invalid
    try
    {
        parsePruneRetain("-6 months");
        assert(false);
    }
    catch (Exception) {}
}

unittest
{
    import std.exception : assertThrown;

    // Wrong number of tokens.
    assertThrown(parsePruneRetain(""));
    assertThrown(parsePruneRetain("3"));
    assertThrown(parsePruneRetain("3 months extra"));

    // Non-integer amount.
    assertThrown(parsePruneRetain("abc months"));
    assertThrown(parsePruneRetain("1.5 months"));

    // Zero and negative amounts.
    assertThrown(parsePruneRetain("0 days"));
    assertThrown(parsePruneRetain("-1 months"));

    // Unknown unit.
    assertThrown(parsePruneRetain("3 hours"));
    assertThrown(parsePruneRetain("3 minutes"));
    assertThrown(parsePruneRetain("3 fortnights"));
}
