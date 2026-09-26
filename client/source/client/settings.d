/// User settings
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module client.settings;

import std.json;
import std.file : exists, mkdirRecurse, readText, write;
import std.path : buildPath, dirName;

import ddlogger;

import client.directories : settingsFilePath, vrcdAppDataPath;
import client.notifications : notifyEventLabels, feedEventLabels, feedEventDefaultVisible;

/// One saved server connection.
///
/// Everything here is per-server, the event cursor included: an id is a rowid
/// in one particular server's database, so a cursor carried across a switch
/// would ask the wrong server to resume from a number that means nothing
/// there -- silently skipping events or replaying old ones.
struct Profile
{
    /// User-visible label. Empty until the server says who it is signed in
    /// as, which is a better name than anything asked for up front.
    string name;

    /// Run the server as our own child rather than connecting to one over
    /// the network. Defaults to false so a settings file written before
    /// embedding existed keeps pointing at whatever server it named; a
    /// fresh install gets true from loadSettings instead.
    bool embeddedServer;
    /// Override path to the server binary. Empty searches beside the client.
    string serverPath;
    /// Address an embedded server additionally listens on, so other devices
    /// (a phone running the web front-end) can reach it. Empty = pipe only.
    string serverListen;
    /// Config/data directory handed to an embedded server as `--basedir`.
    /// Empty leaves it on its own defaults, which is what the first profile
    /// wants: it is the one whose database already exists.
    string baseDir;

    string host = "127.0.0.1";
    ushort port = 9700;
    string secret;
    bool useTls;
    bool tlsSkipVerify;
    string tlsCaCert;
    string tlsClientCert;
    string tlsClientKey;

    // Highest event id processed from this server. Used on reconnect
    // to resume catch-up instead of replaying the entire event store.
    long lastEventId;
}

/// Persistent application settings, saved as JSON.
///
/// Split deliberately: connections live in `profiles`, everything else is an
/// application preference and stays shared. Nobody wants to re-pick their
/// notification backend per account.
struct Settings
{
    Profile[] profiles;
    size_t activeProfile;

    string fontPath;
    float fontSize = 16.0f;
    float feedPageSize = 25.0f;

    // VR notification backends
    bool notifyMute;
    bool notifyXSOverlay = true;
    bool notifyOVRToolkit;
    bool notifyDesktop;
    float notifyVolume = 0.7f;
    float notifyTimeout = 5.0f;
    float notifyOpacity = 1.0f;
    bool notifySound = true;
    bool[notifyEventLabels.length] notifyEventFilter = true;

    // Picture metadata
    bool insertPictureMetadata = true;

    // Feed tab filter (which event types appear in the feed list).
    bool[feedEventLabels.length] feedEventVisible = feedEventDefaultVisible;
    bool feedShowSelfEvents;

    /// The profile in use. Never out of range: an empty list gets a default
    /// entry and an index past the end falls back to the first.
    ref Profile active()
    {
        if (profiles.length == 0)
            profiles = [ Profile.init ];
        if (activeProfile >= profiles.length)
            activeProfile = 0;
        return profiles[activeProfile];
    }
}

/// Pick a data directory for a new embedded profile that no existing one has
/// claimed. Two embedded servers sharing a directory would fight over the
/// same cookie jar and log each other out of VRChat.
string newProfileBaseDir(const(Profile)[] existing)
{
    import std.format : format;

    // From 2: the first profile is the one left on the server's own default
    // paths, so "server1" would be a directory nothing points at.
    foreach (int n; 2 .. 1000)
    {
        string dir = vrcdAppDataPath(buildPath("profiles", format!"server%d"(n)));
        bool taken;
        foreach (ref const(Profile) p; existing)
        {
            if (p.baseDir == dir)
            {
                taken = true;
                break;
            }
        }
        if (taken == false)
            return dir;
    }
    return null;
}

/// Read one connection out of a JSON object.
///
/// The keys are the same ones a pre-profiles settings file kept at the top
/// level, so this serves both the profile array and the migration from that
/// older shape.
private void readProfileKeys(const(JSONValue) json, ref Profile p)
{
    if (const(JSONValue) *jname = "name" in json)
        if (jname.type == JSONType.string)
            p.name = jname.str;
    if (const(JSONValue) *jembedded_server = "embedded_server" in json)
        if (jembedded_server.type == JSONType.true_)
            p.embeddedServer = true;
    if (const(JSONValue) *jserver_path = "server_path" in json)
        if (jserver_path.type == JSONType.string)
            p.serverPath = jserver_path.str;
    if (const(JSONValue) *jserver_listen = "server_listen" in json)
        if (jserver_listen.type == JSONType.string)
            p.serverListen = jserver_listen.str;
    if (const(JSONValue) *jbase_dir = "base_dir" in json)
        if (jbase_dir.type == JSONType.string)
            p.baseDir = jbase_dir.str;
    if (const(JSONValue) *jhost = "host" in json)
        if (jhost.type == JSONType.string)
            p.host = jhost.str;
    if (const(JSONValue) *jport = "port" in json)
        if (jport.type == JSONType.integer)
            p.port = cast(ushort) jport.integer;
    if (const(JSONValue) *jsecret = "secret" in json)
        if (jsecret.type == JSONType.string)
            p.secret = jsecret.str;
    if (const(JSONValue) *juse_tls = "use_tls" in json)
        if (juse_tls.type == JSONType.true_)
            p.useTls = true;
    if (const(JSONValue) *jtls_skip_verify = "tls_skip_verify" in json)
        if (jtls_skip_verify.type == JSONType.true_)
            p.tlsSkipVerify = true;
    if (const(JSONValue) *jtls_ca_cert = "tls_ca_cert" in json)
        if (jtls_ca_cert.type == JSONType.string)
            p.tlsCaCert = jtls_ca_cert.str;
    if (const(JSONValue) *jtls_client_cert = "tls_client_cert" in json)
        if (jtls_client_cert.type == JSONType.string)
            p.tlsClientCert = jtls_client_cert.str;
    if (const(JSONValue) *jtls_client_key = "tls_client_key" in json)
        if (jtls_client_key.type == JSONType.string)
            p.tlsClientKey = jtls_client_key.str;
    if (const(JSONValue) *jlast_event_id = "last_event_id" in json)
        if (jlast_event_id.type == JSONType.integer)
            p.lastEventId = jlast_event_id.integer;
}

private JSONValue profileToJSON(Profile p)
{
    JSONValue j;
    j["name"] = p.name;
    j["embedded_server"] = p.embeddedServer;
    j["server_path"] = p.serverPath;
    j["server_listen"] = p.serverListen;
    j["base_dir"] = p.baseDir;
    j["host"] = p.host;
    j["port"] = p.port;
    j["secret"] = p.secret;
    j["use_tls"] = p.useTls;
    j["tls_skip_verify"] = p.tlsSkipVerify;
    j["tls_ca_cert"] = p.tlsCaCert;
    j["tls_client_cert"] = p.tlsClientCert;
    j["tls_client_key"] = p.tlsClientKey;
    j["last_event_id"] = p.lastEventId;
    return j;
}

/// Load settings from disk. Returns defaults if file is missing or invalid.
Settings loadSettings()
{
    Settings s;
    string path = settingsFilePath();

    if (exists(path) == false)
    {
        // Nothing configured means nobody has set a server up, which is the
        // case embedding exists for: launch, sign in to VRChat, done.
        logDebugging("loadSettings: no settings file at %s, defaulting to an embedded server", path);
        Profile p;
        p.embeddedServer = true;
        s.profiles = [ p ];
        return s;
    }

    logDebugging("loadSettings: reading %s", path);
    try
    {
        string text = readText(path);
        JSONValue json = parseJSON(text);

        const(JSONValue) *jprofiles = "profiles" in json;
        if (jprofiles && jprofiles.type == JSONType.array)
        {
            foreach (const(JSONValue) entry; jprofiles.array)
            {
                if (entry.type != JSONType.object)
                    continue;
                Profile p;
                readProfileKeys(entry, p);
                s.profiles ~= p;
            }
            if (const(JSONValue) *jactive = "active_profile" in json)
                if (jactive.type == JSONType.integer && jactive.integer >= 0)
                    s.activeProfile = cast(size_t) jactive.integer;
        }
        else
        {
            // Pre-profiles file: the one connection it describes becomes the
            // first profile, keeping its cursor and its server paths.
            Profile p;
            readProfileKeys(json, p);
            s.profiles = [ p ];
        }

        if (const(JSONValue) *jfont_path = "font_path" in json)
            if (jfont_path.type == JSONType.string)
                s.fontPath = jfont_path.str;
        if (const(JSONValue) *jfont_size = "font_size" in json)
        {
            if (jfont_size.type == JSONType.float_)
                s.fontSize = cast(float) jfont_size.floating;
            else if (jfont_size.type == JSONType.integer)
                s.fontSize = cast(float) jfont_size.integer;
        }
        if (const(JSONValue) *jfeed_page_size = "feed_page_size" in json)
        {
            if (jfeed_page_size.type == JSONType.float_)
                s.feedPageSize = cast(float) jfeed_page_size.floating;
            else if (jfeed_page_size.type == JSONType.integer)
                s.feedPageSize = cast(float) jfeed_page_size.integer;
        }

        // VR notification settings
        if (const(JSONValue) *jnotify_mute = "notify_mute" in json)
            if (jnotify_mute.type == JSONType.true_)
                s.notifyMute = true;
        if (const(JSONValue) *jnotify_xsoverlay = "notify_xsoverlay" in json)
        {
            if (jnotify_xsoverlay.type == JSONType.true_)
                s.notifyXSOverlay = true;
        }
        if (const(JSONValue) *jnotify_ovrtoolkit = "notify_ovrtoolkit" in json)
            if (jnotify_ovrtoolkit.type == JSONType.true_)
                s.notifyOVRToolkit = true;
        if (const(JSONValue) *jnotify_desktop = "notify_desktop" in json)
            if (jnotify_desktop.type == JSONType.true_)
                s.notifyDesktop = true;
        if (const(JSONValue) *jnotify_volume = "notify_volume" in json)
        {
            // TODO: There are a lot of patterns like this, make a util function
            if (jnotify_volume.type == JSONType.float_)
                s.notifyVolume = cast(float) jnotify_volume.floating;
            else if (jnotify_volume.type == JSONType.integer)
                s.notifyVolume = cast(float) jnotify_volume.integer;
        }
        if (const(JSONValue) *jnotify_timeout = "notify_timeout" in json)
        {
            if (jnotify_timeout.type == JSONType.float_)
                s.notifyTimeout = cast(float) jnotify_timeout.floating;
            else if (jnotify_timeout.type == JSONType.integer)
                s.notifyTimeout = cast(float) jnotify_timeout.integer;
        }
        if (const(JSONValue) *jnotify_opacity = "notify_opacity" in json)
        {
            if (jnotify_opacity.type == JSONType.float_)
                s.notifyOpacity = cast(float) jnotify_opacity.floating;
            else if (jnotify_opacity.type == JSONType.integer)
                s.notifyOpacity = cast(float) jnotify_opacity.integer;
        }
        if (const(JSONValue) *jnotify_sound = "notify_sound" in json)
            if (jnotify_sound.type == JSONType.true_)
                s.notifySound = true;
        if (const(JSONValue) *jnotify_event_filter = "notify_event_filter" in json)
        {
            if (jnotify_event_filter.type == JSONType.array)
            {
                foreach (i, f; jnotify_event_filter.array)
                {
                    // was notifyEventLabels.length
                    if (i >= s.notifyEventFilter.length)
                        break;
                    
                    s.notifyEventFilter[i] = f.type == JSONType.true_;
                }
            }
        }
        if (const(JSONValue) *jfeed_event_visible = "feed_event_visible" in json)
        {
            if (jfeed_event_visible.type == JSONType.array)
            {
                foreach (i, f; jfeed_event_visible.array)
                {
                    // was arr.length
                    if (i >= s.feedEventVisible.length)
                        break;
                    
                    s.feedEventVisible[i] = f.type == JSONType.true_;
                }
            }
        }
        if (const(JSONValue) *jinsert_picture_metadata = "insert_picture_metadata" in json)
            if (jinsert_picture_metadata.type == JSONType.true_)
                s.insertPictureMetadata = true;
        if (const(JSONValue) *jfeed_show_self_events = "feed_show_self_events" in json)
            if (jfeed_show_self_events.type == JSONType.true_)
                s.feedShowSelfEvents = true;
    }
    catch (Exception e)
    {
        logError("Failed to load settings from %s: %s", path, e.msg);
    }

    // Log important entries
    logDebugging("loadSettings: %d profile(s), active=%d embedded=%s host=%s port=%d last_event_id=%d",
        s.profiles.length, s.activeProfile, s.active().embeddedServer,
        s.active().host, s.active().port, s.active().lastEventId);
    return s;
}

/// Save settings to disk.
void saveSettings(Settings s)
{
    string path = settingsFilePath();

    try
    {
        // Ensure parent directory exists.
        string dir = dirName(path);
        if (exists(dir) == false)
            mkdirRecurse(dir);

        JSONValue json;
        JSONValue[] profileArr;
        foreach (Profile p; s.profiles)
            profileArr ~= profileToJSON(p);
        json["profiles"] = profileArr;
        json["active_profile"] = cast(long) s.activeProfile;
        json["font_path"] = s.fontPath;
        json["font_size"] = s.fontSize;
        json["feed_page_size"] = s.feedPageSize;

        // VR notification settings
        json["notify_mute"] = s.notifyMute;
        json["notify_xsoverlay"] = s.notifyXSOverlay;
        json["notify_ovrtoolkit"] = s.notifyOVRToolkit;
        json["notify_desktop"] = s.notifyDesktop;
        json["notify_volume"] = s.notifyVolume;
        json["notify_timeout"] = s.notifyTimeout;
        json["notify_opacity"] = s.notifyOpacity;
        json["notify_sound"] = s.notifySound;
        JSONValue[] filterArr;
        foreach (size_t i; 0 .. notifyEventLabels.length)
            filterArr ~= JSONValue(s.notifyEventFilter[i]);
        json["notify_event_filter"] = filterArr;

        JSONValue[] feedArr;
        foreach (size_t i; 0 .. feedEventLabels.length)
            feedArr ~= JSONValue(s.feedEventVisible[i]);
        json["feed_event_visible"] = feedArr;
        json["insert_picture_metadata"] = s.insertPictureMetadata;
        json["feed_show_self_events"] = s.feedShowSelfEvents;

        write(path, json.toPrettyString());
        logInfo("Settings saved to %s", path);
    }
    catch (Exception e)
    {
        logError("Failed to save settings to %s: %s", path, e.msg);
    }
}

unittest
{
    // A pre-profiles file keeps its connection and, importantly, its cursor:
    // dropping that would replay the whole event store on the next launch.
    JSONValue legacy = parseJSON(`{
        "embedded_server": true,
        "server_listen": "0.0.0.0:9700",
        "host": "10.0.0.5",
        "port": 9701,
        "secret": "hunter2",
        "last_event_id": 4821
    }`);
    Profile p;
    readProfileKeys(legacy, p);
    assert(p.embeddedServer);
    assert(p.serverListen == "0.0.0.0:9700");
    assert(p.host == "10.0.0.5");
    assert(p.port == 9701);
    assert(p.secret == "hunter2");
    assert(p.lastEventId == 4821);
    // Nothing named it, and no base dir means the server's own paths, which
    // is what keeps a migrated embedded profile pointed at its database.
    assert(p.name.length == 0);
    assert(p.baseDir.length == 0);
}

unittest
{
    Profile p = { name: "alt", embeddedServer: true, baseDir: "/tmp/alt",
        host: "example.net", port: 9999, useTls: true, lastEventId: 7 };
    Profile back;
    readProfileKeys(parseJSON(profileToJSON(p).toString()), back);
    assert(back == p);
}

unittest
{
    Settings s;
    // An empty list and an out-of-range index both have to answer with
    // something: active() is called before anything validates the file.
    assert(s.profiles.length == 0);
    s.active().host = "127.0.0.2";
    assert(s.profiles.length == 1);
    assert(s.profiles[0].host == "127.0.0.2");

    s.activeProfile = 40;
    assert(s.active().host == "127.0.0.2");
    assert(s.activeProfile == 0);
}

unittest
{
    // Each new embedded profile needs a directory of its own, or two of them
    // share a cookie jar and log each other out.
    Profile first; // default paths, no base dir
    string a = newProfileBaseDir([ first ]);
    assert(a.length > 0);

    Profile second;
    second.baseDir = a;
    string b = newProfileBaseDir([ first, second ]);
    assert(b.length > 0);
    assert(b != a);
}
