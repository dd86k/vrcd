/// Application state
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module client.state;

import core.sync.mutex;
import core.time : MonoTime;

import client.notifications : notifyEventLabels, feedEventLabels;

/// Network connection state for the server connection.
enum ConnectionState { disconnected, connecting, connected, failed }

/// Thread-safe message queue from network thread to UI thread.
class MessageQueue
{
    private string[] pending;
    private Mutex mtx;
    private ConnectionState connState = ConnectionState.connecting;
    private string connError;

    this()
    {
        mtx = new Mutex();
    }

    void pushMessage(string jsonLine)
    {
        mtx.lock();
        pending ~= jsonLine;
        mtx.unlock();
    }

    void pushDisconnect()
    {
        mtx.lock();
        if (connState == ConnectionState.connected)
            connState = ConnectionState.disconnected;
        mtx.unlock();
    }

    void setConnected()
    {
        mtx.lock();
        connState = ConnectionState.connected;
        connError = null;
        mtx.unlock();
    }

    void setConnectFailed(string error)
    {
        mtx.lock();
        connState = ConnectionState.failed;
        connError = error;
        mtx.unlock();
    }

    ConnectionState getConnectionState()
    {
        mtx.lock();
        ConnectionState s = connState;
        mtx.unlock();
        return s;
    }

    string getConnectError()
    {
        mtx.lock();
        string e = connError;
        mtx.unlock();
        return e;
    }

    string[] drain()
    {
        mtx.lock();
        string[] result = pending;
        pending = null;
        mtx.unlock();
        return result;
    }

    bool isDisconnected()
    {
        mtx.lock();
        ConnectionState s = connState;
        mtx.unlock();
        return s == ConnectionState.disconnected || s == ConnectionState.failed;
    }
}

/// Origin of a feed entry, used to colour the accent strip.
enum EventSource { server, local, dropaportal, system }

/// A single event entry for the feed tab.
struct FeedEntry
{
    long id;
    string eventType;
    string user;
    string detail;
    string receivedAt;
    string rawContent;   // raw JSON content for detail view
    bool isSelf;         // event about the logged-in user (for the "hide self" filter)
    EventSource source;
}

/// Friend info as received from server.
struct FriendInfo
{
    string userId;
    string displayName;
    string status;
    string statusDescription;
    string platform;
    string location;
    string bio;
    string pronouns;
    string[] bioLinks;
}

/// Friends grouped by instance for the friends tab.
struct InstanceGroup
{
    string instanceId;
    string worldName;
    FriendInfo[] friends;
    long nUsers   = -1; // -1 = unknown
    long capacity = -1; // -1 = unknown
}

/// A pending notification action to send to the server.
struct NotificationAction
{
    string notificationId; // VRChat notification ID (not_...)
    string action;         // "accept" or "hide"
}

/// A notification entry (friend request, invite, etc.).
struct NotificationEntry
{
    string notificationId;   // VRChat "not_..." ID
    string notificationType; // "friendRequest", "invite", "requestInvite"
    string senderName;
    string message;
    string receivedAt;
    bool actionPending;      // true while waiting for server response
}

/// Application state read by the UI, written only by the main thread.
struct AppState
{
    // Connection status
    bool connected;
    string serverStatus = "Disconnected";
    string vrchatStatus = "Unknown";

    // Rate limit state from server
    long rateLimitRemaining = -1;
    long rateLimitMax = -1;
    bool rateLimited;

    // Settings (editable via UI)
    char[128] settingsHost = '\0';
    char[8] settingsPort = '\0';
    char[128] settingsSecret = '\0';
    int settingsTls;
    int settingsTlsSkipVerify;
    char[256] settingsTlsClientCert = '\0';
    char[256] settingsTlsClientKey = '\0';
    bool reconnectRequested;
    bool refreshFriendsRequested;

    // Font settings
    char[256] settingsFontPath = '\0';
    float settingsFontSize = 16.0f;
    bool fontReloadRequested;

    // Persistence
    bool saveSettingsRequested;

    // Feed tab
    float feedPageSize = 25.0f; // items per page (float for slider)
    FeedEntry[] feedEntries;

    // Feed filter (int for mu_checkbox compatibility). 1 = visible, 0 = hidden.
    int[feedEventLabels.length] feedEventVisible = 1;
    int feedShowSelfEvents;

    // Smallest server event id currently loaded in feedEntries (long.max = none).
    // Used as the cursor for "Fetch older" back-fill requests.
    long oldestLoadedEventId = long.max;
    // True while a fetch_older request is in flight; button shows "Fetching...".
    bool fetchingOlder;
    // Set by the UI to request a fetch_older round-trip on the next frame.
    bool fetchOlderRequested;
    // True when the server reports no events exist below oldestLoadedEventId.
    bool noOlderEvents;

    // Feed detail
    FeedEntry* selectedFeedEntry; // null = list view, non-null = detail view

    // Friends tab
    InstanceGroup[] instances;
    FriendInfo[] activeElsewhereFriends; // online but not in a visible/joinable world
    FriendInfo[] offlineFriends;
    FriendInfo* selectedFriend; // null = list view, non-null = profile view

    // Notifications tab
    NotificationEntry[] notifications;
    NotificationAction[] pendingActions;

    // Current VRChat instance (from local log watcher).
    string currentLocation; // e.g. "wrld_xxx:12345~region(us)"

    // Self user (from server `self` snapshot).
    string selfUserId;
    string selfDisplayName;
    string selfStatus;            // "active", "join me", "ask me", "busy"
    string selfStatusDescription;
    // UI textbox buffer for the custom status message. Synced from
    // selfStatusDescription whenever the server pushes a new snapshot
    // and the user isn't actively editing.
    // Sized for 32 UTF-8 code points (VRChat's status_description limit)
    // at up to 4 bytes each, plus the null terminator.
    char[32 * 4 + 1] statusDescriptionInput = '\0';
    // Draft status the user picked in the popup but hasn't committed yet.
    // Empty means "no draft, use selfStatus". The Update button compares
    // this and the textbox against selfStatus / selfStatusDescription and
    // queues whichever fields actually changed.
    string selfStatusDraft;

    // Set by the UI to request a status change on the next frame.
    // Either may be empty for "leave unchanged".
    string pendingSetStatus;
    string pendingSetStatusDescription;
    bool pendingSetStatusDescriptionSet;
    bool statusUpdateInFlight;
    // Last server-reported error from set_status, displayed inline.
    string statusUpdateError;

    // Drop a Portal status ("", "Paired as <user>", etc.)
    string dapStatus;
    bool dapPairRequested;
    bool dapUnpairRequested;

    // VR notification settings (int for mu_checkbox compatibility)
    int notifyMute;
    int notifyXSOverlay = 1;
    int notifyOVRToolkit;
    int notifyDesktop;
    float notifyVolume = 0.7f;
    float notifyTimeout = 5.0f;
    float notifyOpacity = 1.0f;
    int notifySound = 1;
    int[notifyEventLabels.length] notifyEventFilter = 1;
    bool testNotifyRequested;

    // Picture metadata insertion toggle (int for mu_checkbox compatibility).
    int insertPictureMetadata = 1;

    // Tools tab,  strip metadata
    bool stripMetadataPage;
    string[] droppedFiles;
    string stripStatus;

    // Auth delegation dialog
    enum AuthDialogKind { none, credentials, twoFactor }
    AuthDialogKind authDialogKind;
    bool authDialogVisible;
    string authDialogMethod;  // "totp", "otp", "emailOtp"
    string authDialogError;   // Error from previous attempt (e.g., "Invalid code")
    char[128] authUsername = '\0';
    char[128] authPassword = '\0';
    char[16] authCode = '\0';
    bool authDialogSubmit;
    bool authDialogCancel;

    // Status bar transient flash for user-action feedback.
    string statusFlash;
    MonoTime statusFlashEnd;

    void addFeedEntry(long id, string eventType, string user, string detail, string receivedAt,
        string rawContent = "", bool isSelf = false, EventSource source = EventSource.server)
    {
        // Deduplicate server events by ID (guards against catch-up/live race).
        if (id > 0)
        {
            foreach (ref FeedEntry e; feedEntries)
                if (e.id == id) return;
        }
        // Prepend (newest first), cap at 2000 entries.
        if (feedEntries.length >= 2000)
            feedEntries = feedEntries[0 .. 1999];
        feedEntries = FeedEntry(id, eventType, user, detail, receivedAt, rawContent, isSelf, source) ~ feedEntries;
        if (id > 0 && id < oldestLoadedEventId)
            oldestLoadedEventId = id;
    }

    /// Append an older event at the tail (oldest position).
    /// Used by `fetch_older` back-fill, does not cap.
    void appendOldFeedEntry(long id, string eventType, string user, string detail, string receivedAt,
        string rawContent = "", bool isSelf = false, EventSource source = EventSource.server)
    {
        feedEntries ~= FeedEntry(id, eventType, user, detail, receivedAt, rawContent, isSelf, source);
        if (id > 0 && id < oldestLoadedEventId)
            oldestLoadedEventId = id;
    }

    /// Add a notification, deduplicating by notificationId.
    void addNotification(string notificationId, string notificationType,
        string senderName, string message, string receivedAt)
    {
        // Deduplicate.
        foreach (ref NotificationEntry n; notifications)
        {
            if (n.notificationId == notificationId)
                return;
        }
        // Prepend (newest first).
        notifications = NotificationEntry(notificationId, notificationType,
            senderName, message, receivedAt) ~ notifications;
    }

    /// Remove a notification by its VRChat ID.
    void removeNotification(string notificationId)
    {
        NotificationEntry[] kept;
        foreach (ref NotificationEntry n; notifications)
        {
            if (n.notificationId != notificationId)
                kept ~= n;
        }
        notifications = kept;
    }
}
