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
    string user;        // VRChat display name (not ID!)
    string detail;      // World name, or whatever related to event
    string receivedAt;  // Formatted timestamp (ie, 07-05 11:46:32)
    string rawContent;  // raw JSON content for detail view
    bool isSelf;        // event about the logged-in user (for the "hide self" filter)
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
    string instanceId; // canonical grouping key (wrld_xxx:12345)
    string location;   // full location with region tags, for launch URIs
    string worldName;
    FriendInfo[] friends;
    long nUsers   = -1; // -1 = unknown
    long capacity = -1; // -1 = unknown
}

/// A muted or blocked user from the server `moderations` snapshot.
/// Player moderations are not limited to friends, so entries carry their
/// own display names instead of referencing FriendInfo.
struct ModerationEntry
{
    string userId;
    string displayName;
}

/// A pending moderation/friendship action to send to the server.
struct ModerationAction
{
    string userId;
    string displayName; // for status flash wording
    string action;      // "mute", "unmute", "block", "unblock", "unfriend"
}

/// Armed state for two-tap destructive buttons. kind+id identify the
/// arming button, so only one confirmation can be pending at a time.
struct ArmedConfirm
{
    string kind; // "block", "unfriend", "delete", ...; empty = disarmed
    string id;   // user/file/print/inventory id
}

/// Sub-pages of the TOOLS tab.
enum ToolsPage { main, stripMetadata, friendList, muteList, blockList }

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
    long receivedAtUnix;     // 0 if unknown; UI formats relative to now
    bool actionPending;      // true while waiting for server response
}

/// A file entry from the VRChat files API (gallery, icon, sticker, emoji).
struct ContentFile
{
    string fileId;      // file_...
    string name;
    long fileVersion;   // latest usable version
    string mimeType;
}

/// A print entry from the VRChat prints API.
struct PrintEntry
{
    string printId;     // prnt_...
    string fileId;      // extracted from files.image URL
    long fileVersion;
    string note;
    string worldName;
    string timestamp;
}

/// An inventory item (props: drone skins, emoji drops, etc.).
struct InventoryEntry
{
    string id;          // inv_...
    string name;
    string description;
    string itemType;
    string itemTypeLabel;
    string equipSlot;   // non-empty when currently equipped
    string[] flags;     // "equippable", "consumable", "archivable", ...
    string imageFileId;
    long imageVersion;
    bool archived;
}

/// Sections of the inventory ("STUFF") tab. The first four map to files
/// API tags and index AppState.invFiles.
enum InvSection { gallery, icons, stickers, emoji, prints, items }

/// Number of InvSection members.
enum INV_SECTIONS = 6;

/// Files-API tag for a section, or null for prints/items.
string invSectionTag(InvSection section)
{
    final switch (section) with (InvSection)
    {
    case gallery:  return "gallery";
    case icons:    return "icon";
    case stickers: return "sticker";
    case emoji:    return "emoji";
    case prints, items: return null;
    }
}

/// An image download to request from the server, drained by gui.d.
struct ImageRequest
{
    string fileId;
    long fileVersion;
    int size;   // 0 = original file, else thumbnail edge (256, ...)
}

/// A queued content management action, drained by gui.d.
struct ContentAction
{
    string kind;    // delete_file, delete_print, set_icon, equip, unequip, consume
    string id;      // file/print/inventory id (empty for set_icon clear)
    string extra;   // equip/unequip: slot name
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

    // Feed detail. A value copy (not a pointer into feedEntries): the feed
    // array reallocates on live `addFeedEntry` prepends and `fetch_older`
    // back-fill, which would dangle a pointer into it. feedDetailOpen acts as
    // the list-vs-detail toggle.
    bool feedDetailOpen;
    FeedEntry selectedFeedEntry;

    // Friends tab
    InstanceGroup[] instances;
    FriendInfo[] activeElsewhereFriends; // online but not in a visible/joinable world
    FriendInfo[] offlineFriends;
    FriendInfo[] allFriends;    // flat roster sorted by name, for the TOOLS friend list
    FriendInfo* selectedFriend; // null = list view, non-null = profile view

    // Moderations (mutes/blocks) from the server `moderations` snapshot.
    ModerationEntry[] mutedUsers;
    ModerationEntry[] blockedUsers;
    bool moderationsLoaded;
    bool moderationsLoading;
    string moderationsError;
    bool refreshModerationsRequested;

    // Moderation/friendship actions queued by the UI, drained by gui.d.
    ModerationAction[] pendingModerationActions;
    bool moderationActionInFlight;

    // Server protocol version from auth_ok (0 = unknown). The moderation
    // API (get_moderations, moderate_user, unfriend) needs version 3.
    long serverProtocol;

    // Two-tap confirmation state shared by all destructive buttons.
    ArmedConfirm armedConfirm;

    // Notifications tab
    NotificationEntry[] notifications;
    NotificationAction[] pendingActions;

    // Instance locations queued for a "Self-Invite" join, drained by gui.d.
    string[] pendingJoins;

    // Instance locations queued for an "Open in VRChat" join (Linux: async
    // IPC into the running Proton container), drained by gui.d.
    string[] pendingOpens;

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

    // Drop a Portal pairing state. Starts at `unknown` on (re)connect and
    // resolves to paired/unpaired once the server sends a `dap_status`
    // snapshot. The DAP UI stays disabled while unknown so we don't present
    // a "Pair" button against a server that may already be paired.
    enum DapPairState { unknown, unpaired, paired }
    DapPairState dapPairState;
    // Drop a Portal status label ("", "Paired as <user>", "Pairing: <code>").
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

    // Tools tab
    ToolsPage toolsPage;
    string[] droppedFiles;  // strip metadata queue (also inventory upload source)
    string stripStatus;

    // Inventory ("STUFF") tab
    InvSection invSection;
    ContentFile[][4] invFiles;   // per files-API section (gallery..emoji)
    PrintEntry[] invPrints;
    InventoryEntry[] invItems;
    long invItemsTotal;
    bool[INV_SECTIONS] invLoading;
    bool[INV_SECTIONS] invLoaded;
    bool[INV_SECTIONS] invStale;    // content-refresh received, reload on view
    bool[4] invMoreAvailable;       // files sections: last page was full
    string[INV_SECTIONS] invError;
    bool invRefreshRequested;       // UI asks gui.d to (re)load current section
    bool invLoadMoreRequested;      // UI asks for the next files page

    // Image pipeline: UI enqueues requests, gui.d dispatches them (disk
    // cache first, then server), replies land in the image cache.
    ImageRequest[] pendingImageRequests;
    bool[string] imageRequestsInFlight; // keyed by image cache key
    bool[string] failedImages;          // don't re-request known failures

    // Inventory detail page (value copies; lists reallocate on refresh).
    bool invDetailOpen;
    ContentFile selectedInvFile;
    PrintEntry selectedInvPrint;
    InventoryEntry selectedInvItem;

    // Management actions queued by the UI, drained by gui.d.
    ContentAction[] pendingContentActions;
    bool invActionInFlight;

    // Upload state (gallery/icon/sticker/emoji + prints).
    char[256] invUploadNote = '\0'; // prints only
    bool invUploadRequested;        // upload first droppedFiles entry
    bool invUploadInFlight;
    string invUploadStatus;

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
        string senderName, string message, long receivedAtUnix)
    {
        // Deduplicate.
        foreach (ref NotificationEntry n; notifications)
        {
            if (n.notificationId == notificationId)
                return;
        }
        // Prepend (newest first).
        notifications = NotificationEntry(notificationId, notificationType,
            senderName, message, receivedAtUnix) ~ notifications;
    }

    /// Whether a user is muted, per the last moderations snapshot.
    bool isMuted(string userId)
    {
        foreach (ref ModerationEntry m; mutedUsers)
        {
            if (m.userId == userId)
                return true;
        }
        return false;
    }

    /// Whether a user is blocked, per the last moderations snapshot.
    bool isBlocked(string userId)
    {
        foreach (ref ModerationEntry m; blockedUsers)
        {
            if (m.userId == userId)
                return true;
        }
        return false;
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
