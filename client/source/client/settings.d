/// User settings
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module client.settings;

import std.json;
import std.file : exists, mkdirRecurse, readText, write;
import std.path : buildPath, dirName;

import ddlogger;

import client.notifications : notifyEventLabels, feedEventLabels;

/// Persistent application settings, saved as JSON.
struct Settings
{
    string host = "127.0.0.1";
    ushort port = 9700;
    string secret;
    string fontPath;
    float fontSize = 16.0f;
    float feedPageSize = 25.0f;

    // VR notification backends
    bool notifyXSOverlay = true;
    bool notifyOVRToolkit;
    bool notifyDesktop;
    float notifyVolume = 0.7f;
    float notifyTimeout = 5.0f;
    float notifyOpacity = 1.0f;
    bool notifySound = true;
    bool[notifyEventLabels.length] notifyEventFilter = true;

    // Feed tab filter (which event types appear in the feed list).
    bool[feedEventLabels.length] feedEventVisible = true;
    bool feedHideSelfEvents;

    // Highest event id processed from the server. Used on reconnect
    // to resume catch-up instead of replaying the entire event store.
    long lastEventId;
}

/// Return the settings file path per platform.
string settingsFilePath()
{
    version (Windows)
    {
        import std.process : environment;
        string appdata = environment.get("APPDATA", ".");
        return buildPath(appdata, "vrcd", "settings.json");
    }
    else
    {
        import std.path : expandTilde;
        string configDir = expandTilde("~/.config/vrcd");
        return buildPath(configDir, "settings.json");
    }
}

/// Load settings from disk. Returns defaults if file is missing or invalid.
Settings loadSettings()
{
    Settings s;
    string path = settingsFilePath();

    if (exists(path) == false)
    {
        logDebugging("loadSettings: no settings file at %s, using defaults", path);
        return s;
    }

    logDebugging("loadSettings: reading %s", path);
    try
    {
        string text = readText(path);
        JSONValue json = parseJSON(text);

        if ("host" in json && json["host"].type == JSONType.string)
            s.host = json["host"].str;
        if ("port" in json && json["port"].type == JSONType.integer)
            s.port = cast(ushort) json["port"].get!long;
        if ("secret" in json && json["secret"].type == JSONType.string)
            s.secret = json["secret"].str;
        if ("font_path" in json && json["font_path"].type == JSONType.string)
            s.fontPath = json["font_path"].str;
        if ("font_size" in json && json["font_size"].type == JSONType.float_)
            s.fontSize = json["font_size"].get!double;
        else if ("font_size" in json && json["font_size"].type == JSONType.integer)
            s.fontSize = cast(float) json["font_size"].get!long;
        if ("feed_page_size" in json && json["feed_page_size"].type == JSONType.float_)
            s.feedPageSize = json["feed_page_size"].get!double;
        else if ("feed_page_size" in json && json["feed_page_size"].type == JSONType.integer)
            s.feedPageSize = cast(float) json["feed_page_size"].get!long;

        // VR notification settings
        if ("notify_xsoverlay" in json && json["notify_xsoverlay"].type == JSONType.true_)
            s.notifyXSOverlay = true;
        else if ("notify_xsoverlay" in json)
            s.notifyXSOverlay = false;
        if ("notify_ovrtoolkit" in json && json["notify_ovrtoolkit"].type == JSONType.true_)
            s.notifyOVRToolkit = true;
        if ("notify_desktop" in json && json["notify_desktop"].type == JSONType.true_)
            s.notifyDesktop = true;
        if ("notify_volume" in json && json["notify_volume"].type == JSONType.float_)
            s.notifyVolume = json["notify_volume"].get!double;
        else if ("notify_volume" in json && json["notify_volume"].type == JSONType.integer)
            s.notifyVolume = cast(float) json["notify_volume"].get!long;
        if ("notify_timeout" in json && json["notify_timeout"].type == JSONType.float_)
            s.notifyTimeout = json["notify_timeout"].get!double;
        else if ("notify_timeout" in json && json["notify_timeout"].type == JSONType.integer)
            s.notifyTimeout = cast(float) json["notify_timeout"].get!long;
        if ("notify_opacity" in json && json["notify_opacity"].type == JSONType.float_)
            s.notifyOpacity = json["notify_opacity"].get!double;
        else if ("notify_opacity" in json && json["notify_opacity"].type == JSONType.integer)
            s.notifyOpacity = cast(float) json["notify_opacity"].get!long;
        if ("notify_sound" in json && json["notify_sound"].type == JSONType.true_)
            s.notifySound = true;
        else if ("notify_sound" in json)
            s.notifySound = false;
        if ("notify_event_filter" in json && json["notify_event_filter"].type == JSONType.array)
        {
            JSONValue[] arr = json["notify_event_filter"].array;
            foreach (size_t i; 0 .. notifyEventLabels.length)
            {
                if (i < arr.length)
                    s.notifyEventFilter[i] = arr[i].type == JSONType.true_;
            }
        }
        if ("feed_event_visible" in json && json["feed_event_visible"].type == JSONType.array)
        {
            JSONValue[] arr = json["feed_event_visible"].array;
            foreach (size_t i; 0 .. feedEventLabels.length)
            {
                if (i < arr.length)
                    s.feedEventVisible[i] = arr[i].type == JSONType.true_;
            }
        }
        if ("feed_hide_self_events" in json && json["feed_hide_self_events"].type == JSONType.true_)
            s.feedHideSelfEvents = true;
        else if ("feed_hide_self_events" in json)
            s.feedHideSelfEvents = false;
        if ("last_event_id" in json && json["last_event_id"].type == JSONType.integer)
            s.lastEventId = json["last_event_id"].get!long;
    }
    catch (Exception e)
    {
        logError("Failed to load settings from %s: %s", path, e.msg);
    }

    logDebugging("loadSettings: host=%s port=%d fontSize=%.1f feedPageSize=%.0f",
        s.host, s.port, s.fontSize, s.feedPageSize);
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

        JSONValue json = JSONValue(string[string].init);
        json["host"] = s.host;
        json["port"] = s.port;
        json["secret"] = s.secret;
        json["font_path"] = s.fontPath;
        json["font_size"] = s.fontSize;
        json["feed_page_size"] = s.feedPageSize;

        // VR notification settings
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
        json["feed_hide_self_events"] = s.feedHideSelfEvents;

        json["last_event_id"] = s.lastEventId;

        write(path, json.toPrettyString());
        logInfo("Settings saved to %s", path);
    }
    catch (Exception e)
    {
        logError("Failed to save settings to %s: %s", path, e.msg);
    }
}
