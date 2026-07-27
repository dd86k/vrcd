/// VR notifications
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module client.notifications;

import std.json;
import std.socket : UdpSocket, InternetAddress;

import core.time : MonoTime, Duration, dur;
import ddlogger;

import client.settings;

/// Feed event types, labels, and the raw-type lookup are shared with the web
/// front-end so both feeds label events identically.
public import vrcd.events :
    FeedEventType, feedEventTypes, feedEventLabels,
    feedEventDefaultVisible, feedEventIndex;

/// Human-readable label for a raw event type. Falls through to the raw
/// string when unknown so unrecognized events stay visible (and debuggable).
string prettyEventType(string rawType)
{
    size_t i = feedEventIndex(rawType);
    return i == size_t.max ? rawType : feedEventTypes[i].label;
}

/// A topical group of feed event labels shown together in the filter popup.
/// Topical grouping is purely a display concern,  feedEventLabels' index
/// order is the persistence contract and must not change.
struct FeedFilterSection
{
    string title;
    immutable(size_t)[] indices;
}

/// CTFE label lookup. Fails to compile if a section references a label
/// that doesn't exist,  keeping the section table and the label list in sync.
private size_t labelIdx(string label) pure
{
    foreach (size_t i, string l; feedEventLabels)
        if (l == label)
            return i;
    assert(0, "Unknown feed event label: " ~ label);
}

/// Topical sections for the filter popup. Order here is display order.
/// Every feedEventLabels entry must appear in exactly one section
/// (enforced by the static assert below).
immutable FeedFilterSection[] feedFilterSections = [
    FeedFilterSection("Self & Avatar", [
        labelIdx("Update"), labelIdx("Location"),
        labelIdx("Profile Change"), labelIdx("Avatar Change"),
        labelIdx("Badge Assigned"), labelIdx("Badge Unassigned"),
    ]),
    FeedFilterSection("Friends", [
        labelIdx("Online"), labelIdx("Offline"), labelIdx("Active"),
        labelIdx("Friend Add"), labelIdx("Friend Remove"),
        labelIdx("Friend Update"), labelIdx("Friend Location"),
        labelIdx("Friend Traveling"),
    ]),
    FeedFilterSection("Notifications", [
        labelIdx("Notification"), labelIdx("Notif Delete"),
        labelIdx("Notif Update"), labelIdx("Notif Seen"),
        labelIdx("Notif Hidden"), labelIdx("Notif Response"),
    ]),
    FeedFilterSection("Groups", [
        labelIdx("Group Joined"), labelIdx("Group Left"),
        labelIdx("Group Role"), labelIdx("Group Member"),
    ]),
    FeedFilterSection("Instances", [
        labelIdx("Queue Joined"), labelIdx("Queue Position"),
        labelIdx("Queue Ready"), labelIdx("Queue Left"),
        labelIdx("Instance Closed"), labelIdx("Content Refresh"),
    ]),
    FeedFilterSection("In-Game", [
        labelIdx("Player Joining"), labelIdx("Player Joined"),
        labelIdx("Player Left"), labelIdx("Photo Taken"),
        labelIdx("URL Video"), labelIdx("URL String"), labelIdx("URL Image"),
    ]),
    FeedFilterSection("DAP", [
        labelIdx("DAP Pairing"), labelIdx("DAP"), labelIdx("DAP Error"),
    ]),
    FeedFilterSection("System", [
        labelIdx("System"), labelIdx("Error"),
    ]),
];

/// Compile-time check: every label appears in exactly one section.
static assert(() {
    bool[feedEventLabels.length] seen;
    foreach (sec; feedFilterSections)
        foreach (idx; sec.indices)
        {
            if (seen[idx])
                return false;
            seen[idx] = true;
        }
    foreach (s; seen)
        if (s == false)
            return false;
    return true;
}(), "feedFilterSections must cover every feedEventLabels entry exactly once");

/// Event types that can trigger VR notifications.
/// Order matches notifyEventFilter arrays in Settings and AppState.
immutable string[] notifyEventLabels = [
    "Online",
    "Offline",
    "Active",
    "Friend Location",
    "Notification",
    "Player Joining",
    "Player Joined",
    "Player Left",
    "Photo Taken",
];

/// Raw event type strings corresponding to each notifyEventLabels entry.
private immutable string[][] notifyEventTypes = [
    ["friend-online"],
    ["friend-offline"],
    ["friend-active"],
    ["friend-location"],
    ["notification", "notification-v2"],
    ["player-joining"],
    ["player-joined"],
    ["player-left"],
    ["photo-taken"],
];

/// Format a VR notification from event fields.
/// Returns empty strings for event types that should not notify.
private void formatNotification(string eventType, string user, string detail,
    out string title, out string body_)
{
    switch (eventType)
    {
        case "friend-online":
            title = "Friend Online";
            body_ = detail.length > 0 ? user ~ " \u2014 " ~ detail : user;
            return;
        case "friend-offline":
            title = "Friend Offline";
            body_ = user;
            return;
        case "friend-active":
            title = "Friend Active";
            body_ = detail.length > 0 ? user ~ " \u2014 " ~ detail : user;
            return;
        case "friend-add":
            title = "Friend Added";
            body_ = user;
            return;
        case "friend-delete":
            title = "Friend Removed";
            body_ = user;
            return;
        case "friend-location":
            title = "Friend Moved";
            body_ = detail.length > 0 ? user ~ " \u2192 " ~ detail : user;
            return;
        case "notification":
        case "notification-v2":
            title = detail.length > 0 ? detail : "Notification";
            body_ = user;
            return;
        case "player-joining":
            title = "Player Joining";
            body_ = user;
            return;
        case "player-joined":
            title = "Player Joined";
            body_ = user;
            return;
        case "player-left":
            title = "Player Left";
            body_ = user;
            return;
        case "photo-taken":
            import std.path : baseName;
            title = "Photo Taken";
            // detail holds the screenshot path; show just the file name.
            body_ = baseName(detail);
            return;
        default:
            return;
    }
}

/// Look up the filter index for a raw event type. Returns -1 if not filterable.
private int filterIndex(string eventType)
{
    foreach (size_t i, immutable string[] types; notifyEventTypes)
    {
        foreach (string t; types)
        {
            if (t == eventType)
                return cast(int) i;
        }
    }
    return -1;
}

/// Minimum interval between dispatched notifications to avoid flooding
/// the VR overlay and causing lag.
private immutable Duration notifyCooldown = dur!"msecs"(5000);

/// Timestamp of the last successfully dispatched notification.
private MonoTime lastNotifyTime;

/// Dispatch a notification to all enabled backends.
void dispatchNotification(string eventType, string user, string detail, Settings settings)
{
    string title;
    string body_;
    formatNotification(eventType, user, detail, title, body_);

    if (title.length == 0)
    {
        logTrace("dispatchNotification: no title for event=%s, skipping", eventType);
        return;
    }

    if (settings.notifyMute)
    {
        logTrace("dispatchNotification: muted, skipping event=%s", eventType);
        return;
    }

    // Check per-event-type filter.
    int idx = filterIndex(eventType);
    if (idx >= 0 && idx < cast(int) settings.notifyEventFilter.length)
    {
        if (settings.notifyEventFilter[idx] == false)
        {
            logTrace("dispatchNotification: event=%s filtered out", eventType);
            return;
        }
    }

    // Rate-limit: drop notifications that arrive faster than the cooldown.
    MonoTime now = MonoTime.currTime;
    if (lastNotifyTime != MonoTime.init)
    {
        Duration elapsed = now - lastNotifyTime;
        if (elapsed < notifyCooldown)
        {
            logTrace("dispatchNotification: rate-limited event=%s (elapsed=%dms)",
                eventType, elapsed.total!"msecs");
            return;
        }
    }
    lastNotifyTime = now;

    logDebugging("dispatchNotification: event=%s title=\"%s\" xs=%s ovrt=%s desktop=%s",
        eventType, title, settings.notifyXSOverlay,
        settings.notifyOVRToolkit, settings.notifyDesktop);

    if (settings.notifyXSOverlay)
        sendXSOverlay(title, body_, settings);

    version (Windows)
    {
        if (settings.notifyOVRToolkit)
            sendOVRToolkit(title, body_);
    }

    version (linux)
    {
        if (settings.notifyDesktop)
            sendDesktopNotification(title, body_, settings);
    }
}

/// Send a test notification to all enabled backends using current settings.
void sendTestNotification(Settings settings)
{
    string title = "vrcd";
    string body_ = "Test notification";

    if (settings.notifyXSOverlay)
        sendXSOverlay(title, body_, settings);

    version (Windows)
    {
        if (settings.notifyOVRToolkit)
            sendOVRToolkit(title, body_);
    }

    version (linux)
    {
        if (settings.notifyDesktop)
            sendDesktopNotification(title, body_, settings);
    }
}

//
// XSOverlay UDP backend
//

/// Persistent UDP socket for XSOverlay notifications.
private UdpSocket xsSocket;

/// Cached target address for XSOverlay.
private InternetAddress xsAddr;

/// Send a notification via XSOverlay UDP protocol (127.0.0.1:42069).
/// Also compatible with WayVR on Linux.
private void sendXSOverlay(string title, string body_, Settings settings)
{
    // Height heuristic from VRCX.
    float height = 110.0f;
    if (body_.length > 300)
        height = 250.0f;
    else if (body_.length > 200)
        height = 200.0f;
    else if (body_.length > 100)
        height = 150.0f;

    try
    {
        // Lazily create and reuse a single UDP socket
        if (xsSocket is null)
        {
            xsSocket = new UdpSocket();
            xsAddr   = new InternetAddress("127.0.0.1", 42069);
        }

        JSONValue msg;
        msg["messageType"]  = 1;
        msg["title"]        = title;
        msg["content"]      = body_;
        msg["timeout"]      = settings.notifyTimeout;
        msg["height"]       = height;
        msg["volume"]       = settings.notifySound ? settings.notifyVolume : -1.0f;
        msg["sourceApp"]    = "vrcd";
        msg["opacity"]      = settings.notifyOpacity;

        xsSocket.sendTo(cast(const(ubyte)[]) msg.toString(), xsAddr);
    }
    catch (Exception e)
    {
        logError("XSOverlay send failed: %s", e.msg);
        // Socket may be in a bad state; discard so next call recreates it.
        if (xsSocket)
        {
            try xsSocket.close(); catch (Exception) {}
            xsSocket = null;
        }
    }
}

//
// OVR Toolkit WebSocket backend (Windows only)
//

version (Windows)
{
    import std.socket : TcpSocket, InternetAddress, SocketException;
    import core.time : MonoTime, Duration, dur;

    private TcpSocket ovrtSocket;
    private bool ovrtConnected;
    private MonoTime ovrtLastAttempt;

    /// Send a HUD notification to OVR Toolkit via WebSocket.
    private void sendOVRToolkit(string title, string body_)
    {
        ensureOVRTConnected();
        if (ovrtConnected == false)
            return;

        // Build the inner payload.
        JSONValue inner;
        inner["title"] = title;
        inner["body"] = body_;
        inner["icon"] = null;

        // Build the envelope.
        JSONValue envelope;
        envelope["messageType"] = "SendNotification";
        envelope["json"] = inner.toString();

        string json = envelope.toString();
        try
        {
            sendWebSocketFrame(cast(const(ubyte)[]) json);
        }
        catch (Exception e)
        {
            logError("OVR Toolkit send failed: %s", e.msg);
            closeOVRT();
        }
    }

    /// Lazily connect to OVR Toolkit WebSocket with cooldown.
    private void ensureOVRTConnected()
    {
        if (ovrtConnected)
            return;

        // 30-second cooldown between attempts.
        MonoTime now = MonoTime.currTime;
        if (ovrtLastAttempt != MonoTime.init)
        {
            Duration elapsed = now - ovrtLastAttempt;
            if (elapsed < dur!"seconds"(30))
                return;
        }
        ovrtLastAttempt = now;

        try
        {
            // Yes... Manual WebSocket creation to avoid a dependencing
            ovrtSocket = new TcpSocket();
            ovrtSocket.connect(new InternetAddress("127.0.0.1", 11450));

            // Send HTTP upgrade request.
            string request =
                "GET /api HTTP/1.1\r\n" ~
                "Host: 127.0.0.1:11450\r\n" ~
                "Upgrade: websocket\r\n" ~
                "Connection: Upgrade\r\n" ~
                "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ~
                "Sec-WebSocket-Version: 13\r\n" ~
                "\r\n";
            ovrtSocket.send(cast(const(ubyte)[]) request);

            // Read upgrade response (consume until empty line).
            ubyte[1024] buf = void;
            ptrdiff_t n = ovrtSocket.receive(buf);
            if (n <= 0)
            {
                closeOVRT();
                return;
            }

            // Check for 101 Switching Protocols.
            string response = cast(string) buf[0 .. n];
            if (response.length < 12 || response[9 .. 12] != "101")
            {
                logError("OVR Toolkit WebSocket upgrade rejected");
                closeOVRT();
                return;
            }

            ovrtConnected = true;
        }
        catch (Exception e)
        {
            logError("OVR Toolkit connect failed: %s", e.msg);
            closeOVRT();
        }
    }

    /// Send a masked WebSocket text frame (RFC 6455).
    private void sendWebSocketFrame(const(ubyte)[] payload)
    {
        import std.random : unpredictableSeed;

        ubyte[14] header = void; // max header: 2 + 8 + 4 = 14
        size_t headerLen;

        // Opcode 0x1 (text), FIN bit set, mask bit set.
        header[0] = 0x81;

        if (payload.length < 126)
        {
            header[1] = cast(ubyte)(0x80 | payload.length);
            headerLen = 2;
        }
        else if (payload.length <= 0xFFFF)
        {
            header[1] = 0x80 | 126;
            header[2] = cast(ubyte)(payload.length >> 8);
            header[3] = cast(ubyte)(payload.length);
            headerLen = 4;
        }
        else
        {
            header[1] = 0x80 | 127;
            ulong len = payload.length;
            foreach (int i; 0 .. 8)
                header[2 + i] = cast(ubyte)(len >> ((7 - i) * 8));
            headerLen = 10;
        }

        // 4-byte mask key.
        uint maskSeed = unpredictableSeed();
        ubyte[4] mask;
        mask[0] = cast(ubyte)(maskSeed >> 24);
        mask[1] = cast(ubyte)(maskSeed >> 16);
        mask[2] = cast(ubyte)(maskSeed >> 8);
        mask[3] = cast(ubyte)(maskSeed);

        header[headerLen .. headerLen + 4] = mask[];
        headerLen += 4;

        // Mask the payload.
        ubyte[] masked = new ubyte[payload.length];
        foreach (size_t i; 0 .. payload.length)
            masked[i] = payload[i] ^ mask[i % 4];

        ovrtSocket.send(header[0 .. headerLen]);
        ovrtSocket.send(masked);
    }

    /// Close OVR Toolkit connection.
    private void closeOVRT()
    {
        ovrtConnected = false;
        if (ovrtSocket)
        {
            try ovrtSocket.close();
            catch (Exception) {}
            ovrtSocket = null;
        }
    }
}

//
// freedesktop Desktop Notifications (Linux only)
//

version (linux)
{
    /// Send a desktop notification via notify-send.
    /// WayVR intercepts these and renders them in VR.
    private void sendDesktopNotification(string title, string body_, Settings settings)
    {
        import std.process : spawnProcess;
        import std.conv : to;

        // notify-send expects timeout in milliseconds.
        string timeoutMs = to!string(cast(int)(settings.notifyTimeout * 1000));

        try
        {
            spawnProcess(["notify-send", "-a", "vrcd", "-t", timeoutMs, title, body_]);
        }
        catch (Exception e)
        {
            logError("notify-send failed: %s", e.msg);
        }
    }
}
