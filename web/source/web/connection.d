/// Link to vrcd-server over the JSON-L server-client API.
///
/// A single background thread owns the socket: it connects, authenticates,
/// answers keepalive pings, and keeps a snapshot of the logged-in user that
/// HTTP request handlers read from any MHD thread.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module web.connection;

import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : Duration, dur;
import std.json;
import std.socket;
import std.string : indexOf, strip;

import ddlogger;
import vrcd.events;
import vrcd.friends;
import vrcd.notifications;

/// First reconnect delay; doubles on every consecutive failure.
private enum Duration RECONNECT_BASE = dur!"seconds"(2);
/// Upper bound for the reconnect backoff.
private enum Duration RECONNECT_MAX = dur!"seconds"(60);

/// How many past events to pull on connect. The server caps `fetch_older` at
/// 500 per request.
private enum int FEED_BACKLOG = 200;

/// Protocol version that added `get_notifications`. An older server answers
/// it with an `error`, so the inbox asks only when it will be understood.
private enum long PROTOCOL_NOTIFICATIONS = 4;

/// Snapshot of the logged-in VRChat user, from the server's `self` message.
struct SelfInfo
{
    /// False until the server has told us who is logged in.
    bool known;
    string id;
    string displayName;
    string status;
    string statusDescription;
    string bio;
    string pronouns;
    string[] bioLinks;
}

/// Snapshot of the link to vrcd-server itself.
struct LinkStatus
{
    /// Connected and authenticated to vrcd-server.
    bool connected;
    /// vrcd-server's own VRChat WebSocket state, from its `status` message.
    bool vrchatConnected;
    /// Protocol version reported in `auth_ok`. Zero when unknown.
    long serverVersion;
    /// Last connection or authentication error.
    string lastError;
}

/// One event, labelled and reduced to what the feed shows. The timestamp
/// stays as the server's ISO 8601 UTC string so the browser can render it in
/// the viewer's own timezone.
struct FeedEntry
{
    long id;
    string eventType;
    string label;
    string user;
    string detail;
    string receivedAt;
}

/// Outcome of the most recent self-invite, for feedback on the page.
struct JoinResult
{
    /// False until a join has been attempted this session.
    bool attempted;
    string location;
    bool success;
    string error;
}

/// Outcome of the most recent accept/hide, for feedback on the page.
struct NotifyActionResult
{
    /// False until a notification action has been taken this session.
    bool attempted;
    string notificationId;
    string action;
    bool success;
    string error;
}

/// TCP client for the vrcd-server JSON-L API.
///
/// Only the messages the web front-end renders are interpreted (`self`,
/// `status`, `friends`, `join_instance_result`); everything else is logged and
/// dropped. TLS is not wired up yet, so this expects a plain listener
/// (loopback, or a tunnel).
class ServerLink
{
    this(string host, ushort port, string secret)
    {
        this.host = host;
        this.port = port;
        this.secret = secret;
        this.stateMutex = new Mutex();
        this.sendMutex = new Mutex();
    }

    /// Set the callback fired after any state change worth re-rendering.
    /// Runs on the network thread, outside the state lock.
    void setChangeCallback(void delegate() callback)
    {
        this.onChange = callback;
    }

    /// Set the callback fired when feed entries arrive. `reset` marks a fresh
    /// backlog that replaces whatever the browser is showing; otherwise the
    /// entries are appended.
    void setFeedCallback(void delegate(FeedEntry[] entries, bool reset) callback)
    {
        this.onFeed = callback;
    }

    /// Start the network thread. Returns immediately; the link connects and
    /// reconnects on its own for the lifetime of the process.
    void start()
    {
        Thread thread = new Thread(&runLoop);
        thread.isDaemon = true;
        thread.start();
    }

    /// Current snapshot of the logged-in user.
    SelfInfo self()
    {
        synchronized (stateMutex)
            return selfInfo;
    }

    /// Current snapshot of the link state.
    LinkStatus status()
    {
        synchronized (stateMutex)
            return linkStatus;
    }

    /// Current friend roster. Empty until the first `friends` snapshot lands.
    FriendRoster roster()
    {
        synchronized (stateMutex)
            return friendRoster;
    }

    /// Outcome of the most recent self-invite.
    JoinResult joinResult()
    {
        synchronized (stateMutex)
            return lastJoin;
    }

    /// Pending notifications, oldest first. Empty until the server's
    /// `notifications` snapshot lands.
    NotificationInfo[] notifications()
    {
        synchronized (stateMutex)
            return inbox;
    }

    /// Outcome of the most recent accept/hide.
    NotifyActionResult notifyResult()
    {
        synchronized (stateMutex)
            return lastNotifyAction;
    }

    /// Ask the server to self-invite us to an instance. Safe to call from an
    /// HTTP thread: sends are serialized and the reply arrives asynchronously
    /// as a `join_instance_result`.
    void requestJoin(string location)
    {
        logInfo("Requesting self-invite to %s", location);
        if (sendMessage(JSONValue([
            "type":     JSONValue("join_instance"),
            "location": JSONValue(location),
        ])))
            return;

        // Nothing carried it, so answer here: the page is waiting on a
        // join_instance_result that no one is going to send.
        JoinResult result;
        result.attempted = true;
        result.location = location;
        result.error = "Not connected to vrcd-server";

        synchronized (stateMutex)
            lastJoin = result;
        notifyChange();

        logWarn("Self-invite for %s dropped: no link to vrcd-server", location);
    }

    /// Accept or hide a notification. Safe to call from an HTTP thread; the
    /// reply arrives asynchronously as a `notification_action_result`.
    void requestNotificationAction(string notificationId, string action)
    {
        logInfo("Notification %s: %s", action, notificationId);
        if (sendMessage(JSONValue([
            "type":            JSONValue("notification_action"),
            "notification_id": JSONValue(notificationId),
            "action":          JSONValue(action),
        ])))
            return;

        // As with a join: the row stays put and says why, rather than the
        // button going quiet on a press that never left the process.
        NotifyActionResult result;
        result.attempted = true;
        result.notificationId = notificationId;
        result.action = action;
        result.error = "Not connected to vrcd-server";

        synchronized (stateMutex)
            lastNotifyAction = result;
        notifyChange();

        logWarn("Notification %s for %s dropped: no link to vrcd-server",
            action, notificationId);
    }

private:
    void delegate() onChange;
    void delegate(FeedEntry[] entries, bool reset) onFeed;
    /// Backlog accumulating between `event_older` messages and the
    /// `older_fetched` that terminates them. Only touched on this thread.
    FeedEntry[] pendingBacklog;
    string host;
    ushort port;
    string secret;
    Socket socket;
    string recvBuffer;
    Mutex stateMutex;
    Mutex sendMutex;
    SelfInfo selfInfo;
    LinkStatus linkStatus;
    FriendRoster friendRoster;
    JoinResult lastJoin;
    /// Pending notifications, oldest first. Order is the server's, and new
    /// arrivals append: the inbox draws buttons per row, and re-ordering
    /// under a thumb that is already reaching for one is how the wrong
    /// friend request gets accepted.
    NotificationInfo[] inbox;
    NotifyActionResult lastNotifyAction;

    /// Fire the change callback. Never called with the state lock held: the
    /// callback rebuilds a snapshot, which takes that same lock.
    void notifyChange()
    {
        if (onChange)
            onChange();
    }

    void runLoop()
    {
        Duration backoff = RECONNECT_BASE;
        while (true)
        {
            if (connectAndAuth())
            {
                backoff = RECONNECT_BASE;
                receiveLoop();
            }

            closeSocket();
            synchronized (stateMutex)
            {
                linkStatus.connected = false;
                linkStatus.vrchatConnected = false;
            }
            notifyChange();

            logInfo("Reconnecting in %d second(s)", backoff.total!"seconds");
            Thread.sleep(backoff);
            backoff = backoff * 2 > RECONNECT_MAX ? RECONNECT_MAX : backoff * 2;
        }
    }

    bool connectAndAuth()
    {
        logInfo("Connecting to %s:%u", host, port);

        // Connect on a local reference and publish it only once it is up, so
        // a send from an HTTP thread never lands on a half-built socket.
        Socket sock = new TcpSocket();
        try sock.connect(new InternetAddress(host, port));
        catch (SocketException ex)
        {
            sock.close();
            setError(ex.msg);
            logError("Failed to connect to %s:%u: %s", host, port, ex.msg);
            return false;
        }

        recvBuffer = null;
        synchronized (sendMutex)
            socket = sock;

        sendMessage(JSONValue([
            "type":  JSONValue("auth"),
            "token": JSONValue(secret),
        ]));

        JSONValue response = readMessage();
        if (response.type != JSONType.object)
        {
            setError("Server closed the connection during authentication");
            logError("Server closed the connection during authentication");
            return false;
        }

        string type = jsonString(response, "type");
        if (type != "auth_ok")
        {
            string message = type == "auth_error"
                ? jsonString(response, "message")
                : "Unexpected auth response: " ~ type;
            setError(message);
            logError("Authentication failed: %s", message);
            return false;
        }

        long serverVersion;
        if (const(JSONValue) *v = "server_version" in response)
            if (v.type == JSONType.integer)
                serverVersion = v.integer;

        synchronized (stateMutex)
        {
            linkStatus.connected = true;
            linkStatus.serverVersion = serverVersion;
            linkStatus.lastError = null;
        }

        logInfo("Authenticated (server protocol v%d)", serverVersion);
        notifyChange();
        return true;
    }

    void receiveLoop()
    {
        // `status` and `self` arrive unprompted after auth_ok, and the server
        // re-broadcasts `friends` whenever it changes, so the roster only needs
        // asking for once.
        sendMessage(JSONValue([ "type": JSONValue("get_friends") ]));

        // The inbox cannot be rebuilt from the event log: the WebSocket only
        // reports changes, so anything that arrived while this process was
        // down has no event to replay. Ask the server for the authoritative
        // list, then keep it current from the events that follow.
        // Not cleared first: the reply replaces it a round trip later, and
        // blanking the inbox in between would blink every browser's list.
        if (status().serverVersion >= PROTOCOL_NOTIFICATIONS)
            sendMessage(JSONValue([ "type": JSONValue("get_notifications") ]));
        else
        {
            // Nothing is going to answer, so do not keep showing a list from
            // a connection that is gone.
            synchronized (stateMutex)
                inbox = null;
            logWarn("Server protocol is too old for the inbox " ~
                "(needs v%d, server is v%d)",
                PROTOCOL_NOTIFICATIONS, status().serverVersion);
        }

        // Seed the feed with the newest events. `fetch_older` is the right
        // call rather than `catch_up`: catch-up walks forward from an ID and
        // would hand us the *oldest* page of a long backlog, while this page
        // wants the most recent events. A reconnect re-seeds from scratch, so
        // the feed is a live view rather than an archive with gap tracking.
        pendingBacklog = null;
        sendMessage(JSONValue([
            "type":      JSONValue("fetch_older"),
            "before_id": JSONValue(long.max),
            "limit":     JSONValue(FEED_BACKLOG),
        ]));

        while (true)
        {
            JSONValue message = readMessage();
            if (message.type != JSONType.object)
            {
                logWarn("Server closed the connection");
                return;
            }

            processMessage(message);
        }
    }

    void processMessage(ref JSONValue message)
    {
        string type = jsonString(message, "type");
        switch (type)
        {
        case "self":
            SelfInfo info;
            info.known             = true;
            info.id                = jsonString(message, "id");
            info.displayName       = jsonString(message, "displayName");
            info.status            = jsonString(message, "status");
            info.statusDescription = jsonString(message, "statusDescription");
            info.bio               = jsonString(message, "bio");
            info.pronouns          = jsonString(message, "pronouns");
            if (const(JSONValue) *v = "bioLinks" in message)
                if (v.type == JSONType.array)
                    foreach (const(JSONValue) link; v.array)
                        if (link.type == JSONType.string)
                            info.bioLinks ~= link.str;

            synchronized (stateMutex)
                selfInfo = info;
            notifyChange();

            logInfo("Self: %s (%s)", info.displayName, info.status);
            break;

        case "friends":
            FriendRoster parsed = parseFriendsMessage(message);
            synchronized (stateMutex)
                friendRoster = parsed;
            notifyChange();

            logInfo("Friends: %d online in %d instance(s), %d elsewhere, %d offline",
                parsed.all.length - parsed.offline.length - parsed.activeElsewhere.length,
                parsed.instances.length, parsed.activeElsewhere.length,
                parsed.offline.length);
            break;

        case "event":
            // Live events maintain the inbox; the backlog below deliberately
            // does not. Replaying old events over the server's snapshot would
            // resurrect notifications that were answered long ago.
            applyInboxEvent(message);

            if (onFeed)
                onFeed([ toFeedEntry(message) ], false);
            break;

        case "event_older":
            // Delivered newest first; held until older_fetched terminates it.
            pendingBacklog ~= toFeedEntry(message);
            break;

        case "older_fetched":
            // Flip to oldest-first so the browser can treat the feed as an
            // ordered log regardless of how it was filled.
            FeedEntry[] backlog;
            backlog.reserve(pendingBacklog.length);
            foreach_reverse (ref FeedEntry entry; pendingBacklog)
                backlog ~= entry;
            pendingBacklog = null;

            if (onFeed)
                onFeed(backlog, true);

            logInfo("Feed seeded with %d event(s)", backlog.length);
            break;

        case "notifications":
            string listError = jsonString(message, "error");
            if (listError.length > 0)
            {
                logWarn("Could not fetch notifications: %s", listError);
                break;
            }

            NotificationInfo[] parsed = parseNotificationsMessage(message);
            synchronized (stateMutex)
                inbox = parsed;
            notifyChange();

            logInfo("Inbox seeded with %d notification(s)", parsed.length);
            break;

        case "notification_action_result":
            NotifyActionResult result;
            result.attempted = true;
            result.notificationId = jsonString(message, "notification_id");
            result.action = jsonString(message, "action");
            result.error = jsonString(message, "error");
            if (const(JSONValue) *v = "success" in message)
                result.success = v.type == JSONType.true_;

            synchronized (stateMutex)
            {
                lastNotifyAction = result;
                // VRChat does send a hide/response event for this, but it
                // arrives whenever it arrives; dropping the row now means the
                // button the user just pressed stops offering itself again.
                if (result.success)
                    removeFromInbox(result.notificationId);
            }
            notifyChange();

            if (result.success)
                logInfo("Notification %s: %s", result.action, result.notificationId);
            else
                logWarn("Notification %s for %s failed: %s",
                    result.action, result.notificationId, result.error);
            break;

        case "join_instance_result":
            JoinResult result;
            result.attempted = true;
            result.location = jsonString(message, "location");
            result.error = jsonString(message, "error");
            if (const(JSONValue) *v = "success" in message)
                result.success = v.type == JSONType.true_;

            synchronized (stateMutex)
                lastJoin = result;
            notifyChange();

            if (result.success)
                logInfo("Self-invite sent for %s", result.location);
            else
                logWarn("Self-invite for %s failed: %s", result.location, result.error);
            break;

        case "status":
            bool vrchatConnected;
            if (const(JSONValue) *v = "vrchat_connected" in message)
                vrchatConnected = v.type == JSONType.true_;

            synchronized (stateMutex)
                linkStatus.vrchatConnected = vrchatConnected;
            notifyChange();

            logInfo("VRChat WebSocket %s", vrchatConnected ? "connected" : "disconnected");
            break;

        case "ping":
            sendMessage(JSONValue([ "type": JSONValue("pong") ]));
            break;

        case "error":
            logWarn("Server error: %s", jsonString(message, "message"));
            break;

        default:
            // Events, friend snapshots, and the rest of the API are not used
            // by this prototype.
            logTrace("Ignoring message type: %s", type);
            break;
        }
    }

    /// Fold one live event into the inbox. Most events are not notification
    /// events and fall straight back out.
    void applyInboxEvent(ref JSONValue message)
    {
        string eventType = jsonString(message, "event_type");

        NotificationInfo added = void;
        string[] removedIds;
        NotificationChange change = applyNotificationEvent(eventType, message,
            null, jsonString(message, "received_at"), added, removedIds);
        if (change == NotificationChange.none)
            return;

        if (change == NotificationChange.removed)
        {
            synchronized (stateMutex)
                foreach (string id; removedIds)
                    removeFromInbox(id);
            notifyChange();
            return;
        }

        synchronized (stateMutex)
        {
            // VRChat stopped sending sender names, so fall back to the
            // roster: a friend request is nearly always from someone already
            // in it, and a bare usr_ ID reads as nothing.
            if (added.senderName.length == 0 && added.senderUserId.length > 0)
                added.senderName = displayNameOf(added.senderUserId);

            // Repeats happen (a reconnect on VRChat's side re-emits), and the
            // same notification twice would draw two rows with the same
            // buttons.
            foreach (ref NotificationInfo entry; inbox)
            {
                if (entry.id == added.id)
                    return;
            }
            inbox ~= added; // Appends: see the `inbox` field comment.
        }
        notifyChange();

        logInfo("Notification: %s from %s", added.notificationType, added.senderName);
    }

    /// Drop one notification. Caller holds the state lock.
    void removeFromInbox(string notificationId)
    {
        NotificationInfo[] kept;
        foreach (ref NotificationInfo entry; inbox)
        {
            if (entry.id != notificationId)
                kept ~= entry;
        }
        inbox = kept;
    }

    /// Roster display name for a user ID, empty when they are not a friend.
    /// Caller holds the state lock.
    string displayNameOf(string userId)
    {
        foreach (ref FriendInfo friend; friendRoster.all)
        {
            if (friend.userId == userId)
                return friend.displayName;
        }
        return null;
    }

    /// Write one JSON-L message. Returns false when nothing went out, which
    /// callers on an HTTP thread have to answer for themselves.
    ///
    /// The socket is read once under sendMutex rather than touched directly:
    /// HTTP threads call this, the network thread replaces the socket on
    /// every reconnect, and between the two there is a window where there is
    /// no socket at all. Reaching for the field each time meant a join
    /// pressed during a reconnect dereferenced null.
    bool sendMessage(JSONValue message)
    {
        string line = message.toString() ~ "\n";

        sendMutex.lock();
        scope(exit) sendMutex.unlock();

        Socket sock = socket;
        if (sock is null)
            return false;

        const(void)[] remaining = cast(const(void)[])line;
        while (remaining.length > 0)
        {
            ptrdiff_t sent = sock.send(remaining);
            if (sent <= 0)
                return false; // Disconnected; the receive loop will notice.
            remaining = remaining[sent .. $];
        }
        return true;
    }

    /// Block until one complete JSON-L message arrives. Returns a null
    /// JSONValue when the connection is gone.
    JSONValue readMessage()
    {
        char[4096] buffer = void;
        while (true)
        {
            ptrdiff_t newline = recvBuffer.indexOf('\n');
            if (newline >= 0)
            {
                string line = recvBuffer[0 .. newline].strip();
                recvBuffer = recvBuffer[newline + 1 .. $];
                if (line.length == 0)
                    continue;

                try return parseJSON(line);
                catch (JSONException ex)
                {
                    logError("Malformed server message: %s", ex.msg);
                    continue;
                }
            }

            ptrdiff_t received = socket.receive(buffer);
            if (received <= 0)
                return JSONValue(null);

            recvBuffer ~= cast(string)buffer[0 .. received];
        }
    }

    void closeSocket()
    {
        // Clear the field under sendMutex so a send already in flight on an
        // HTTP thread finishes on the old socket instead of racing the close.
        Socket sock;
        synchronized (sendMutex)
        {
            sock = socket;
            socket = null;
        }

        if (sock is null)
            return;

        try sock.shutdown(SocketShutdown.BOTH);
        catch (SocketException) {} // Already down.
        sock.close();
    }

    void setError(string message)
    {
        synchronized (stateMutex)
        {
            linkStatus.connected = false;
            linkStatus.vrchatConnected = false;
            linkStatus.lastError = message;
        }
    }
}

/// Reduce an `event` or `event_older` message to what the feed shows.
private FeedEntry toFeedEntry(ref JSONValue message)
{
    FeedEntry entry;
    if (const(JSONValue) *v = "id" in message)
        if (v.type == JSONType.integer)
            entry.id = v.integer;

    entry.eventType = jsonString(message, "event_type");
    entry.receivedAt = jsonString(message, "received_at");

    size_t index = feedEventIndex(entry.eventType);
    entry.label = index == size_t.max ? entry.eventType : feedEventLabels[index];

    extractEventFields(entry.eventType, message, entry.user, entry.detail);
    return entry;
}

/// Read a string field out of a JSON object, or null when absent or not a string.
private string jsonString(ref const(JSONValue) object, string key)
{
    if (const(JSONValue) *v = key in object)
        if (v.type == JSONType.string)
            return v.str;
    return null;
}
