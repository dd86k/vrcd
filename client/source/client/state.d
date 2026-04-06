/// Application state
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module client.state;

import core.sync.mutex;

import client.notifications : notifyEventLabels;

/// Thread-safe message queue from network thread to UI thread.
class MessageQueue
{
    private string[] pending;
    private Mutex mtx;
    private bool disconnected;

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
        disconnected = true;
        mtx.unlock();
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
        bool result = disconnected;
        mtx.unlock();
        return result;
    }
}

/// A single event entry for the feed tab.
struct FeedEntry
{
    long id;
    string eventType;
    string user;
    string detail;
    string receivedAt;
    string rawContent; // raw JSON content for detail view
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
}

/// Friends grouped by instance for the friends tab.
struct InstanceGroup
{
    string instanceId;
    string worldName;
    FriendInfo[] friends;
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

    // Settings (editable via UI)
    char[128] settingsHost = '\0';
    char[8] settingsPort = '\0';
    char[128] settingsSecret = '\0';
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

    // Feed detail
    FeedEntry* selectedFeedEntry; // null = list view, non-null = detail view

    // Friends tab
    InstanceGroup[] instances;
    FriendInfo[] offlineFriends;
    FriendInfo* selectedFriend; // null = list view, non-null = profile view

    // Notifications tab
    NotificationEntry[] notifications;
    NotificationAction[] pendingActions;

    // Current VRChat instance (from local log watcher).
    string currentLocation; // e.g. "wrld_xxx:12345~region(us)"

    // VR notification settings (int for mu_checkbox compatibility)
    int notifyXSOverlay = 1;
    int notifyOVRToolkit;
    int notifyDesktop;
    float notifyVolume = 0.7f;
    float notifyTimeout = 5.0f;
    float notifyOpacity = 1.0f;
    int notifySound = 1;
    int[notifyEventLabels.length] notifyEventFilter = 1;
    bool testNotifyRequested;

    // Tools tab — strip metadata
    bool stripMetadataPage;
    string droppedFilePath;
    string stripStatus;

    void addFeedEntry(long id, string eventType, string user, string detail, string receivedAt,
        string rawContent = "")
    {
        // Prepend (newest first), cap at 500 entries.
        if (feedEntries.length >= 500)
            feedEntries = feedEntries[0 .. 499];
        feedEntries = FeedEntry(id, eventType, user, detail, receivedAt, rawContent) ~ feedEntries;
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
