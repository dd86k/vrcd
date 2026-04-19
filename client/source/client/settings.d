/// User settings
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module client.settings;

import std.json;
import std.file : exists, mkdirRecurse, readText, write;
import std.path : buildPath, dirName;

import ddlogger;

import client.directories : settingsFilePath;
import client.notifications : notifyEventLabels, feedEventLabels;

/// Persistent application settings, saved as JSON.
struct Settings
{
    string host = "127.0.0.1";
    ushort port = 9700;
    string secret;
    bool useTls;
    bool tlsSkipVerify;
    string tlsClientCert;
    string tlsClientKey;
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
    bool[feedEventLabels.length] feedEventVisible = true;
    bool feedHideSelfEvents;

    // Highest event id processed from the server. Used on reconnect
    // to resume catch-up instead of replaying the entire event store.
    long lastEventId;
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

        if (const(JSONValue) *jhost = "host" in json)
            if (jhost.type == JSONType.string)
            s.host = jhost.str;
        if (const(JSONValue) *jport = "port" in json)
            if (jport.type == JSONType.integer)
            s.port = cast(ushort) jport.integer;
        if (const(JSONValue) *jsecret = "secret" in json)
            if (jsecret.type == JSONType.string)
                s.secret = jsecret.str;
        if (const(JSONValue) *juse_tls = "use_tls" in json)
            if (juse_tls.type == JSONType.true_)
                s.useTls = true;
        if (const(JSONValue) *jtls_skip_verify = "tls_skip_verify" in json)
            if (jtls_skip_verify.type == JSONType.true_)
                s.tlsSkipVerify = true;
        if (const(JSONValue) *jtls_client_cert = "tls_client_cert" in json)
            if (jtls_client_cert.type == JSONType.string)
                s.tlsClientCert = jtls_client_cert.str;
        if (const(JSONValue) *jtls_client_key = "tls_client_key" in json)
            if (jtls_client_key.type == JSONType.string)
                s.tlsClientKey = jtls_client_key.str;
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
        if (const(JSONValue) *jfeed_hide_self_events = "feed_hide_self_events" in json)
            if (jfeed_hide_self_events.type == JSONType.true_)
                s.feedHideSelfEvents = true;
        if (const(JSONValue) *jlast_event_id = "last_event_id" in json)
            if (jlast_event_id.type == JSONType.integer)
                s.lastEventId = jlast_event_id.integer;
    }
    catch (Exception e)
    {
        logError("Failed to load settings from %s: %s", path, e.msg);
    }

    // Log important entries
    logDebugging("loadSettings: host=%s port=%d last_event_id=%d",
        s.host, s.port, s.lastEventId);
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
        json["host"] = s.host;
        json["port"] = s.port;
        json["secret"] = s.secret;
        json["use_tls"] = s.useTls;
        json["tls_skip_verify"] = s.tlsSkipVerify;
        json["tls_client_cert"] = s.tlsClientCert;
        json["tls_client_key"] = s.tlsClientKey;
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
