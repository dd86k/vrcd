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
import std.base64 : Base64;
import std.json;
import std.socket;
import std.string : indexOf, strip;

import ddlogger;
import vrcd.events;
import vrcd.friends;
import vrcd.notifications;
import web.debugging;
import web.images;
import web.profiles;

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

/// Protocol version that added the content API (`get_inventory`,
/// `inventory_action`, `get_image`).
private enum long PROTOCOL_CONTENT = 2;

/// Protocol version that added the moderation API (`get_moderations`,
/// `moderate_user`, `unfriend`).
private enum long PROTOCOL_MODERATION = 3;

/// Protocol version that added full user profiles (`get_user`).
private enum long PROTOCOL_PROFILES = 7;

/// Protocol version that added profile editing (`set_profile`). An older
/// server answers it with an `error`, so the editor is not drawn at all rather
/// than offering a SAVE that cannot work.
private enum long PROTOCOL_PROFILE_EDIT = 8;

/// Byte budget for proxied images. Thumbnails run tens of kilobytes each, so
/// this holds a few hundred of them; past that the oldest are dropped and
/// re-fetched if they are looked at again.
private enum size_t IMAGE_CACHE_BYTES = 32 * 1024 * 1024;

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
    /// Own profile picture, as a file for the image proxy. Same shape as a
    /// friend's, since the profile tab draws both through one path.
    string imageFileId;
    long imageVersion;
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

/// vrcd-server's SQLite store, as its `stats` reply describes it.
///
/// These are the server's own numbers, not this front-end's: the event count
/// is every event ever logged, while the feed here holds the last page of them.
struct StoreStats
{
    /// False until the first `stats` reply lands.
    bool known;
    long eventCount;
    long worldCacheCount;
    long avatarCacheCount;
    long dbSizeBytes;
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

/// Outcome of the most recent status change, for feedback on the page.
struct StatusUpdate
{
    /// False until a status change has been asked for this session.
    bool attempted;
    /// True while vrcd-server has yet to answer for one. Held here rather than
    /// in the browser because the answer arrives as a broadcast: every browser
    /// showing the profile has to be able to tell that one is on its way.
    bool pending;
    /// What was asked for, which the reply does not carry. Empty for a field
    /// the request left alone.
    string status;
    string statusDescription;
    bool success;
    string error;
}

/// Which fields a profile edit carries. Separate from the values, since an
/// empty bio is a bio somebody cleared and an absent one is a bio the editor
/// did not touch.
struct ProfileFields
{
    bool bio;
    bool pronouns;
    bool links;
    bool languages;

    /// Whether anything at all is being changed.
    bool any() const
    {
        return bio || pronouns || links || languages;
    }
}

/// Outcome of the most recent profile edit, on the same terms as
/// `StatusUpdate`: the page is waiting on it, and so is every other browser
/// open on the same profile.
struct ProfileUpdate
{
    /// False until a profile edit has been asked for this session.
    bool attempted;
    /// True while vrcd-server has yet to answer for one.
    bool pending;
    bool success;
    string error;
}

/// A VRChat sign-in prompt vrcd-server has delegated to its front-ends.
///
/// vrcd-server holds the VRChat session. When it runs headless and needs
/// credentials or a 2FA code it asks whoever is connected over the JSON-L API,
/// and the first answer wins. This is the same delegation the SDL client
/// answers, so either front-end can sign the server in.
struct AuthPrompt
{
    /// False when nothing is being asked for.
    bool active;
    /// "credentials" or "two_factor".
    string kind;
    /// 2FA method on a two_factor prompt: "totp", "otp", or "emailOtp".
    string method;
    /// What went wrong last time (e.g. "Invalid code"). Empty on a first ask.
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

/// The STUFF sections, in the order the page shows them.
///
/// The first four are tags on VRChat's files API, the last two have endpoints
/// of their own. They are one list here because the page treats them as one:
/// six lists of pictures with an action or two attached.
immutable string[6] CONTENT_SECTIONS =
    [ "gallery", "icon", "sticker", "emoji", "prints", "inventory" ];

/// How many entries a files page asks for. vrcd-server caps this at 100, and
/// VRChat caps most of these sections well below that, so one page is usually
/// the whole section.
enum int CONTENT_PAGE = 100;

/// Index of a section in `CONTENT_SECTIONS`, or -1 when the name is not one.
/// Doubles as validation for a section name arriving over HTTP.
ptrdiff_t contentSectionIndex(string section)
{
    foreach (size_t i, string name; CONTENT_SECTIONS)
    {
        if (name == section)
            return i;
    }
    return -1;
}

/// Whether this section is a tag on the files API, as opposed to prints or
/// the inventory, which have endpoints of their own.
bool isFilesSection(string section)
{
    switch (section)
    {
    case "gallery", "icon", "sticker", "emoji": return true;
    default:                                    return false;
    }
}

/// One section's entries, exactly as vrcd-server trimmed them.
///
/// Entries are handed to the browser over HTTP rather than in the state
/// broadcast: a few hundred would ride along with every friend movement, and
/// the tab that shows them is usually not even open.
struct ContentSnapshot
{
    /// True while a request for this section is outstanding.
    bool loading;
    /// True once a reply has landed. Stays true across a refresh, so the list
    /// on screen is not blanked while a newer one is on its way.
    bool loaded;
    /// Bumped on every change. The page re-fetches the entries when it moves.
    long revision;
    /// True when the last page came back full, so there may be another.
    bool more;
    /// Total VRChat reports for the inventory, which can exceed what is held:
    /// vrcd-server stops paging at 500 items. Zero for the other sections,
    /// which report no total of their own.
    long totalCount;
    /// Entries as vrcd-server trimmed them, held rather than re-modelled: this
    /// side renders them and has no opinion about what a file is.
    JSONValue[] items;
    string error;
}

/// Outcome of the most recent action on a piece of content: an equip, a
/// delete, an icon change, an upload.
struct ContentActionResult
{
    /// False until an action has been taken this session.
    bool attempted;
    /// The action asked for: "equip", "delete_file", "upload_image", ...
    string action;
    /// What it was aimed at: an item, file or print ID, or the tag an upload
    /// went to. Empty when the action carries no target (clearing the icon).
    string id;
    bool success;
    string error;
}

/// One muted or blocked user.
///
/// A player moderation is not limited to friends, so the entry carries the
/// display name VRChat last had for them: there may be no roster entry to look
/// it up in.
struct ModeratedUser
{
    string userId;
    string displayName;
}

/// The mute and block lists, as vrcd-server last gave them.
///
/// These ride in the state broadcast rather than being fetched like the STUFF
/// sections: an entry is a name and an ID, and nothing asks for them until a
/// browser has already been sent a roster many times their size.
struct ModerationSnapshot
{
    /// True while a `get_moderations` is outstanding.
    bool loading;
    /// True once a reply has landed. Stays true across a refresh, so the lists
    /// on screen are not blanked while newer ones are on their way.
    bool loaded;
    ModeratedUser[] muted;
    ModeratedUser[] blocked;
    string error;
}

/// Outcome of the most recent moderation: a mute, a block, or an unfriend.
struct ModerationActionResult
{
    /// False until one has been taken this session.
    bool attempted;
    /// "mute", "unmute", "block", "unblock" or "unfriend".
    string action;
    string userId;
    /// Who that was, for the page's toast. vrcd-server fills it in from the
    /// roster or from VRChat's answer, so it survives a name this side never
    /// had.
    string displayName;
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
        this.images = new ImageCache(IMAGE_CACHE_BYTES);
        this.profiles = new ProfileCache();
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

    /// vrcd-server's database counters. Unknown until the first `stats` reply.
    StoreStats stats()
    {
        synchronized (stateMutex)
            return storeStats;
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

    /// Outcome of the most recent status change.
    StatusUpdate statusResult()
    {
        synchronized (stateMutex)
            return lastStatus;
    }

    /// Outcome of the most recent profile edit.
    ProfileUpdate profileResult()
    {
        synchronized (stateMutex)
            return lastProfile;
    }

    /// Whether vrcd-server is new enough to take a profile edit at all.
    bool canEditProfile()
    {
        synchronized (stateMutex)
            return linkStatus.serverVersion >= PROTOCOL_PROFILE_EDIT;
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

    /// The VRChat sign-in prompt the server is waiting on, if any.
    AuthPrompt authPrompt()
    {
        synchronized (stateMutex)
            return pendingAuth;
    }

    /// One section's snapshot. Empty until its first reply, and empty for a
    /// name that is not a section.
    ContentSnapshot content(string section)
    {
        ptrdiff_t index = contentSectionIndex(section);
        if (index < 0)
            return ContentSnapshot.init;

        synchronized (stateMutex)
            return sections[index];
    }

    /// Outcome of the most recent content action: equip, delete, icon, upload.
    ContentActionResult contentResult()
    {
        synchronized (stateMutex)
            return lastContentAction;
    }

    /// The mute and block lists. Empty until the first reply lands.
    ModerationSnapshot moderations()
    {
        synchronized (stateMutex)
            return moderationList;
    }

    /// Outcome of the most recent mute, block or unfriend.
    ModerationActionResult moderationResult()
    {
        synchronized (stateMutex)
            return lastModeration;
    }

    /// Ask vrcd-server for the mute and block lists. Safe to call from an HTTP
    /// thread.
    ///
    /// VRChat sends no WebSocket events for player moderations, so nothing
    /// else keeps these current: they are asked for once per connection and
    /// then only when the page presses refresh, which is what `force` is. A
    /// moderation made from here updates them without a refetch, since
    /// vrcd-server re-broadcasts the lists after its own successful calls.
    ///
    /// Params:
    ///   force = Re-fetch even when the lists are already held.
    void requestModerations(bool force)
    {
        bool ask;
        synchronized (stateMutex)
        {
            if (moderationList.loading)
                return;
            if (force == false && moderationList.loaded)
                return;

            // Fills in the reason when it says no, so the page hears why
            // rather than sitting on "Loading...".
            ask = moderationsUnavailable() == false;
            if (ask)
            {
                moderationList.loading = true;
                moderationList.error = null;
            }
        }
        notifyChange();

        if (ask == false)
            return;

        logInfo("Requesting moderations");
        if (sendMessage(JSONValue([ "type": JSONValue("get_moderations") ])))
            return;

        failModerations("Not connected to vrcd-server");
    }

    /// Mute, unmute, block, unblock or unfriend someone.
    ///
    /// Params:
    ///   action = "mute", "unmute", "block", "unblock" or "unfriend".
    ///   userId = Who it is aimed at. Not necessarily a friend: a moderation
    ///            outlives the friendship it started in.
    void requestModeration(string action, string userId)
    {
        logInfo("Moderation %s: %s", action, userId);

        // Connected first: a link that is down reports version zero, and
        // "too old" would be the wrong thing to say about a server that has
        // not been asked yet.
        LinkStatus current = status();
        if (current.connected == false)
        {
            failModeration(action, userId, "Not connected to vrcd-server");
            return;
        }

        if (current.serverVersion < PROTOCOL_MODERATION)
        {
            failModeration(action, userId, "This vrcd-server is too old to " ~
                "moderate (needs protocol v3)");
            return;
        }

        // Unfriending is not a player moderation and has its own call, but it
        // reaches the page through the same result slot: both are "something
        // was done to a person", and one at a time is all the page offers.
        JSONValue message;
        if (action == "unfriend")
            message = JSONValue([
                "type":    JSONValue("unfriend"),
                "user_id": JSONValue(userId),
            ]);
        else
            message = JSONValue([
                "type":    JSONValue("moderate_user"),
                "action":  JSONValue(action),
                "user_id": JSONValue(userId),
            ]);

        if (sendMessage(message) == false)
            failModeration(action, userId, "Not connected to vrcd-server");
    }

    /// Ask vrcd-server for one section. Safe to call from an HTTP thread.
    ///
    /// Without `force` this is a no-op once the section has been fetched, so
    /// the page can call it every time the section is opened. A request
    /// already in flight is never doubled up: the reply reaches every browser
    /// anyway.
    ///
    /// Params:
    ///   section = One of `CONTENT_SECTIONS`.
    ///   force = Re-fetch even when the section is already held.
    void requestContent(string section, bool force)
    {
        ptrdiff_t index = contentSectionIndex(section);
        if (index < 0)
            return;

        bool ask;
        synchronized (stateMutex)
        {
            if (sections[index].loading)
                return;
            if (force == false && sections[index].loaded)
                return;

            // Fills in the reason and bumps the revision when it says no, so
            // the page hears why rather than sitting on "Loading...".
            if (sectionUnavailable(index) == false)
            {
                sections[index].loading = true;
                sections[index].error = null;
                ++sections[index].revision;
                ask = true;
            }
        }
        notifyChange();

        if (ask == false)
            return;

        logInfo("Requesting %s", section);
        if (sendMessage(sectionRequest(section, 0)))
            return;

        // The link went away between the check and the send. Nothing is going
        // to answer, so say so rather than spinning on "Loading...".
        failSection(index, "Not connected to vrcd-server");
    }

    /// Ask for the next page of a files section, appending to what is held.
    /// Only the files sections page: prints and the inventory come whole.
    void requestMoreContent(string section)
    {
        ptrdiff_t index = contentSectionIndex(section);
        if (index < 0 || isFilesSection(section) == false)
            return;

        int offset;
        bool ask;
        synchronized (stateMutex)
        {
            if (sections[index].loading || sections[index].more == false)
                return;

            offset = cast(int)sections[index].items.length;
            sections[index].loading = true;
            sections[index].error = null;
            ++sections[index].revision;
            ask = true;
        }
        notifyChange();

        if (ask == false)
            return;

        logInfo("Requesting %s from offset %d", section, offset);
        if (sendMessage(sectionRequest(section, offset)))
            return;

        failSection(index, "Not connected to vrcd-server");
    }

    /// Equip, unequip, or consume an inventory item. Safe to call from an HTTP
    /// thread; the reply arrives asynchronously as an
    /// `inventory_action_result`, which also triggers a refresh.
    void requestInventoryAction(string action, string inventoryId, string slot)
    {
        logInfo("Inventory %s: %s%s", action, inventoryId,
            slot.length > 0 ? " (slot " ~ slot ~ ")" : "");

        JSONValue message = JSONValue([
            "type":         JSONValue("inventory_action"),
            "action":       JSONValue(action),
            "inventory_id": JSONValue(inventoryId),
        ]);
        if (slot.length > 0)
            message["slot"] = JSONValue(slot);

        if (sendMessage(message) == false)
            failAction(action, inventoryId);
    }

    /// Delete a file or a print, or set the profile icon. Safe to call from an
    /// HTTP thread; the reply arrives as the matching `*_result`, which also
    /// refreshes the section it changed.
    ///
    /// Params:
    ///   action = "delete_file", "delete_print", or "set_icon".
    ///   id = File or print ID. Empty on a "set_icon", which clears the icon.
    void requestContentAction(string action, string id)
    {
        logInfo("Content %s: %s", action, id.length > 0 ? id : "(none)");

        JSONValue message;
        switch (action)
        {
        case "delete_file":
            message = JSONValue([
                "type":    JSONValue("delete_file"),
                "file_id": JSONValue(id),
            ]);
            break;

        case "delete_print":
            message = JSONValue([
                "type":     JSONValue("delete_print"),
                "print_id": JSONValue(id),
            ]);
            break;

        case "set_icon":
            message = JSONValue([
                "type":    JSONValue("set_user_icon"),
                "file_id": JSONValue(id),
            ]);
            break;

        default:
            logWarn("Refusing unknown content action: %s", action);
            return;
        }

        if (sendMessage(message) == false)
            failAction(action, id);
    }

    /// Upload a PNG as a gallery image, icon, sticker, emoji, or print.
    /// vrcd-server validates the picture (PNG, size, and square for stickers
    /// and emoji) and answers with an `upload_*_result`.
    ///
    /// Params:
    ///   tag = "gallery", "icon", "sticker", "emoji", or "print".
    ///   dataBase64 = The PNG, base64-encoded.
    ///   note = Caption, prints only.
    void requestUpload(string tag, string dataBase64, string note)
    {
        string action = tag == "print" ? "upload_print" : "upload_image";
        logInfo("Uploading %s (%u base64 bytes)", tag, dataBase64.length);

        JSONValue message;
        if (tag == "print")
        {
            message = JSONValue([
                "type":        JSONValue("upload_print"),
                "data_base64": JSONValue(dataBase64),
            ]);
            if (note.length > 0)
                message["note"] = JSONValue(note);
        }
        else
        {
            message = JSONValue([
                "type":        JSONValue("upload_image"),
                "tag":         JSONValue(tag),
                "data_base64": JSONValue(dataBase64),
            ]);
        }

        if (sendMessage(message) == false)
            failAction(action, tag);
    }

    /// Point image lookups at vrcd-server's own cache directory, for when the
    /// two run on one host. Null leaves every image going over the link.
    void setImageCacheDir(string dir)
    {
        this.imageCacheDir = dir;
    }

    /// Look one proxied image up, asking vrcd-server for it when it is not
    /// held yet. Never blocks: a caller that gets `pending` back replies 202
    /// and the browser comes for it again.
    ImageLookup image(string fileId, long fileVersion, int size)
    {
        string cacheKey = ImageCache.key(fileId, fileVersion, size);

        bool startFetch;
        ImageLookup found = images.lookup(cacheKey, startFetch);
        if (startFetch == false)
            return found;

        // vrcd-server has already downloaded most of what this page asks for,
        // and when it is on this host its cache is right there. Reading it is
        // a shortcut around base64 and a round trip, not around vrcd-server: a
        // miss still goes down the link, which is where the VRChat session and
        // the download spacing live.
        if (imageCacheDir.length > 0)
        {
            DiskImage onDisk = readFromServerCache(imageCacheDir, fileId, fileVersion, size);
            if (onDisk.found)
            {
                // Into memory too: the next look skips even the disk, and the
                // entry left pending by the lookup above has to be resolved.
                images.store(cacheKey, onDisk.data, onDisk.mimeType);
                logTrace("Image %s served from vrcd-server's cache", cacheKey);
                return ImageLookup(ImageState.ready, onDisk.data, onDisk.mimeType);
            }
        }

        logTrace("Fetching image %s", cacheKey);
        bool sent = sendMessage(JSONValue([
            "type":    JSONValue("get_image"),
            "file_id": JSONValue(fileId),
            "version": JSONValue(fileVersion),
            "size":    JSONValue(size),
        ]));

        if (sent == false)
        {
            images.storeFailure(cacheKey, "Not connected to vrcd-server");
            return ImageLookup(ImageState.failed, null, null,
                "Not connected to vrcd-server");
        }
        return found;
    }

    /// Look one user profile up, asking vrcd-server for it when it is not held
    /// yet. Never blocks: a caller that gets `pending` back replies 202 and the
    /// browser comes for it again.
    ///
    /// This is the only way to see anything about somebody who is not a friend
    /// -- most of all whoever just sent a friend request, who is a name and an
    /// ID until this answers.
    ProfileLookup profile(string userId)
    {
        // An invented person, answered here. Without this the one pane a fake
        // friend request exists to open would be a spinner and then an error,
        // which is the least useful thing it could be.
        if (debugFakes && isDebugUser(userId))
        {
            JSONValue fake = buildFakeProfile(userId);
            if (fake.type == JSONType.object)
                return ProfileLookup(ProfileState.ready, fake.toString());
        }

        bool startFetch;
        ProfileLookup found = profiles.lookup(userId, startFetch);
        if (startFetch == false)
            return found;

        long version_;
        bool connected;
        synchronized (stateMutex)
        {
            version_ = linkStatus.serverVersion;
            connected = linkStatus.connected;
        }

        // Both of these are answers, not failures to fetch, so they are given
        // straight back rather than remembered: a reconnect or a server upgrade
        // should not have to wait out a cached error. A stale-but-readable
        // entry outranks either: what we have beats saying nothing.
        string unavailable;
        if (connected == false)
            unavailable = "Not connected to vrcd-server";
        else if (version_ < PROTOCOL_PROFILES)
            unavailable = "This vrcd-server is too old to serve profiles " ~
                "(needs protocol v7)";

        if (unavailable.length > 0)
        {
            if (found.state == ProfileState.ready)
                return found;

            // Nothing was sent, so the mark the lookup left has to come off:
            // the next look should try again, not wait out a reply that is not
            // coming. Not stored as a failure either, for the reason above.
            profiles.forget(userId);
            return ProfileLookup(ProfileState.failed, null, unavailable);
        }

        logDebugging("Fetching profile for %s", userId);
        bool sent = sendMessage(JSONValue([
            "type":    JSONValue("get_user"),
            "user_id": JSONValue(userId),
        ]));

        if (sent == false)
        {
            if (found.state == ProfileState.ready)
                return found;
            profiles.storeFailure(userId, "Not connected to vrcd-server");
            return ProfileLookup(ProfileState.failed, null,
                "Not connected to vrcd-server");
        }
        return found;
    }

    /// Look one badge image up, asking vrcd-server for it when it is not held
    /// yet. Never blocks, on the same terms as `image`.
    ///
    /// Badges are the one picture in a profile that is not a VRChat file: they
    /// sit on a public CDN, so there is no file ID and the request names a URL.
    /// It still goes through vrcd-server rather than the browser, because this
    /// page makes no external requests -- one that phoned out would break
    /// behind a tunnel and would tell VRChat's CDN who is looking at whom.
    ///
    /// Shares the image cache, keyed by the URL. Badge art is small, there is
    /// little of it, and it never changes under a given URL, so it belongs in
    /// the same byte budget as everything else with a picture in it.
    ImageLookup badgeImage(string url)
    {
        string cacheKey = "badge:" ~ url;

        bool startFetch;
        ImageLookup found = images.lookup(cacheKey, startFetch);
        if (startFetch == false)
            return found;

        logTrace("Fetching badge image %s", url);
        bool sent = sendMessage(JSONValue([
            "type": JSONValue("get_badge_image"),
            "url":  JSONValue(url),
        ]));

        if (sent == false)
        {
            images.storeFailure(cacheKey, "Not connected to vrcd-server");
            return ImageLookup(ImageState.failed, null, null,
                "Not connected to vrcd-server");
        }
        return found;
    }

    /// Answer a credentials prompt. Safe to call from an HTTP thread; the
    /// server either signs in or asks again with an error.
    bool submitCredentials(string username, string password)
    {
        logInfo("Sending VRChat credentials for %s to vrcd-server", username);
        return answerAuth(JSONValue([
            "type":     JSONValue("auth_response"),
            "kind":     JSONValue("credentials"),
            "username": JSONValue(username),
            "password": JSONValue(password),
        ]));
    }

    /// Answer a two-factor prompt.
    bool submitTwoFactor(string code)
    {
        logInfo("Sending a %d-digit 2FA code to vrcd-server", code.length);
        return answerAuth(JSONValue([
            "type": JSONValue("auth_response"),
            "kind": JSONValue("two_factor"),
            "code": JSONValue(code),
        ]));
    }

    /// Refuse the prompt. The server gives up on that sign-in attempt, which
    /// for a headless server means it stops waiting and exits.
    bool cancelAuth()
    {
        logWarn("Cancelling the VRChat sign-in vrcd-server asked for");
        return answerAuth(JSONValue([
            "type":      JSONValue("auth_response"),
            "cancelled": JSONValue(true),
        ]));
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

    /// Set our own VRChat status, custom message, or both. Safe to call from an
    /// HTTP thread; the reply arrives asynchronously as a `set_status_result`,
    /// preceded by a fresh `self` for every front-end.
    ///
    /// Params:
    ///   status = One of "active", "join me", "ask me", "busy". Empty leaves
    ///            the status as it is.
    ///   description = Custom status message. Only sent with `setDescription`.
    ///   setDescription = Whether to send the description at all. Separate from
    ///                    it being empty, which is how the message is cleared.
    void requestStatus(string status, string description, bool setDescription)
    {
        logInfo("Setting status%s%s",
            status.length > 0 ? " to " ~ status : "",
            setDescription ? ` with message "` ~ description ~ `"` : "");

        JSONValue message = JSONValue([ "type": JSONValue("set_status") ]);
        if (status.length > 0)
            message["status"] = JSONValue(status);
        if (setDescription)
            message["status_description"] = JSONValue(description);

        // Published before the send, not after: this is what the page draws
        // "saving" from, and it should be up while the request is on the wire.
        StatusUpdate asked;
        asked.attempted = true;
        asked.pending = true;
        asked.status = status;
        asked.statusDescription = description;

        synchronized (stateMutex)
            lastStatus = asked;
        notifyChange();

        if (sendMessage(message))
            return;

        // Nothing carried it, so answer here: the page is waiting on a
        // set_status_result that no one is going to send.
        asked.pending = false;
        asked.error = "Not connected to vrcd-server";

        synchronized (stateMutex)
            lastStatus = asked;
        notifyChange();

        logWarn("Status change dropped: no link to vrcd-server");
    }

    /// Edit our own VRChat profile: bio, the links pinned under it, pronouns,
    /// languages. Safe to call from an HTTP thread; the reply arrives
    /// asynchronously as a `set_profile_result`.
    ///
    /// Each field is sent only when its flag is set, and the flag is separate
    /// from the value being empty because an empty value is how a field is
    /// cleared. The editor sets a flag for what it changed, so two browsers
    /// open on the same profile do not write each other's stale fields back.
    ///
    /// Params:
    ///   fields = Which of the four the request carries.
    ///   bio = Profile bio, sent when `fields.bio` is set.
    ///   pronouns = Pronouns, sent when `fields.pronouns` is set.
    ///   links = Links pinned under the bio, sent when `fields.links` is set.
    ///   languages = ISO 639-3 codes, sent when `fields.languages` is set.
    void requestProfile(ProfileFields fields, string bio, string pronouns,
        string[] links, string[] languages)
    {
        logInfo("Editing profile (%s%s%s%s)",
            fields.bio       ? "bio "       : "",
            fields.pronouns  ? "pronouns "  : "",
            fields.links     ? "links "     : "",
            fields.languages ? "languages"  : "");

        JSONValue message = JSONValue([ "type": JSONValue("set_profile") ]);
        if (fields.bio)
            message["bio"] = JSONValue(bio);
        if (fields.pronouns)
            message["pronouns"] = JSONValue(pronouns);
        if (fields.links)
            message["bio_links"] = JSONValue(links);
        if (fields.languages)
            message["languages"] = JSONValue(languages);

        // Published before the send, like a status change: this is what the
        // editor draws "saving" from, and it belongs up while the request is
        // on the wire.
        ProfileUpdate asked;
        asked.attempted = true;
        asked.pending = true;

        synchronized (stateMutex)
            lastProfile = asked;
        notifyChange();

        if (sendMessage(message))
            return;

        // Nothing carried it, so answer here: the page is waiting on a
        // set_profile_result that no one is going to send.
        asked.pending = false;
        asked.error = "Not connected to vrcd-server";

        synchronized (stateMutex)
            lastProfile = asked;
        notifyChange();

        logWarn("Profile edit dropped: no link to vrcd-server");
    }

    /// Answer a notification: `accept` or `hide` on a v1 one, `respond` or
    /// `hide` on a v2 one. Safe to call from an HTTP thread; the reply
    /// arrives asynchronously as a `notification_action_result`.
    ///
    /// Params:
    ///   notificationId = Notification to act on.
    ///   action = "accept", "hide", or "respond".
    ///   apiVersion = Which notification system it belongs to, 1 or 2.
    ///   responseType = Which of its responses was pressed ("respond" only).
    ///   responseData = That response's opaque payload, sent back with it.
    void requestNotificationAction(string notificationId, string action,
        int apiVersion = 1, string responseType = null, string responseData = null)
    {
        // A fake notification has nowhere to go: VRChat has never heard of it,
        // and sending it down the link would only come back a 404. Answering
        // it here is also the point -- the row has to be dismissable, or the
        // inbox fills up with debris that only a restart clears.
        //
        // Gated on debug being on rather than on the ID alone, so a crafted ID
        // can never talk a normal build into reporting success for something
        // that never happened.
        if (debugFakes && isDebugNotification(notificationId))
        {
            answerFake(notificationId, action);
            return;
        }

        logInfo("Notification %s: %s", action, notificationId);
        if (sendMessage(JSONValue([
            "type":            JSONValue("notification_action"),
            "notification_id": JSONValue(notificationId),
            "action":          JSONValue(action),
            "api_version":     JSONValue(apiVersion),
            "response_type":   JSONValue(responseType),
            "response_data":   JSONValue(responseData),
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

    /// Turn the fake-notification catalogue on. Set once at startup and only
    /// read after, so it needs no lock.
    void setDebugFakes(bool on)
    {
        this.debugFakes = on;
    }

    /// Whether fakes are on, which is what puts the `debug` key in the state
    /// snapshot and the chip on the page.
    bool debugEnabled() const
    {
        return debugFakes;
    }

    /// Put one fake notification in the inbox.
    ///
    /// It goes in where a real one would, so everything downstream -- the
    /// snapshot, the badge count, the row, its buttons -- is the real path.
    ///
    /// The sender is invented rather than taken from the roster. Borrowing a
    /// friend gave the row a real face, but it tested the wrong thing: a
    /// request from somebody already on the roster opens the *friend* pane,
    /// and the reason a friend request is worth faking is that its sender is a
    /// stranger. `profile()` answers for the invented ones, so the pane it
    /// opens is a full one.
    ///
    /// Returns: false when the action is not one of the catalogue's.
    bool addFakeNotification(string action)
    {
        if (debugFakes == false || isDebugFake(action) == false)
            return false;

        synchronized (stateMutex)
        {
            NotificationInfo fake = buildFakeNotification(action, ++fakeSequence);
            if (fake.id.length == 0)
                return false;

            inbox ~= fake; // Appends, like a real arrival: see the field comment.
        }

        notifyChange();
        logInfo("Debug: added a fake %s notification", action);
        return true;
    }

    /// Take every fake back out, leaving real notifications where they are.
    void clearFakeNotifications()
    {
        if (debugFakes == false)
            return;

        size_t removed;
        synchronized (stateMutex)
        {
            NotificationInfo[] kept;
            foreach (ref NotificationInfo entry; inbox)
            {
                if (isDebugNotification(entry.id))
                    ++removed;
                else
                    kept ~= entry;
            }
            inbox = kept;
        }

        notifyChange();
        logInfo("Debug: cleared %u fake notification(s)", removed);
    }

private:
    void delegate() onChange;
    /// Whether the fake-notification catalogue is on. Startup-only.
    bool debugFakes;
    /// Counter behind each fake's ID, so two presses make two rows.
    long fakeSequence;
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
    StoreStats storeStats;
    FriendRoster friendRoster;
    JoinResult lastJoin;
    /// Pending notifications, oldest first. Order is the server's, and new
    /// arrivals append: the inbox draws buttons per row, and re-ordering
    /// under a thumb that is already reaching for one is how the wrong
    /// friend request gets accepted.
    NotificationInfo[] inbox;
    NotifyActionResult lastNotifyAction;
    StatusUpdate lastStatus;
    ProfileUpdate lastProfile;
    AuthPrompt pendingAuth;
    /// One per entry in CONTENT_SECTIONS, in that order.
    ContentSnapshot[CONTENT_SECTIONS.length] sections;
    ContentActionResult lastContentAction;
    ModerationSnapshot moderationList;
    ModerationActionResult lastModeration;
    /// Proxied VRChat images. Has its own lock: HTTP threads look images up
    /// while this thread stores them, and neither needs the state lock.
    ImageCache images;
    /// Fetched user profiles, on the same terms as `images`.
    ProfileCache profiles;

    /// Whether the link cannot serve this section right now, filling in the
    /// reason as it says so. Caller holds the state lock.
    bool sectionUnavailable(ptrdiff_t index)
    {
        if (linkStatus.connected == false)
        {
            sections[index].error = "Not connected to vrcd-server";
            ++sections[index].revision;
            return true;
        }

        if (linkStatus.serverVersion < PROTOCOL_CONTENT)
        {
            sections[index].error = "This vrcd-server is too old to serve " ~
                "user content (needs protocol v2)";
            ++sections[index].revision;
            return true;
        }
        return false;
    }

    /// The message that fetches one section, from `offset` for the paged ones.
    JSONValue sectionRequest(string section, int offset)
    {
        switch (section)
        {
        case "prints":
            return JSONValue([ "type": JSONValue("get_prints") ]);

        case "inventory":
            return JSONValue([ "type": JSONValue("get_inventory") ]);

        default:
            return JSONValue([
                "type":   JSONValue("get_files"),
                "tag":    JSONValue(section),
                "n":      JSONValue(CONTENT_PAGE),
                "offset": JSONValue(offset),
            ]);
        }
    }

    /// Give up on a section that could not be asked for.
    void failSection(ptrdiff_t index, string error)
    {
        synchronized (stateMutex)
        {
            sections[index].loading = false;
            sections[index].error = error;
            ++sections[index].revision;
        }
        notifyChange();
    }

    /// Answer an action here, when nothing carried it. As with a join: the
    /// button that was pressed gets an answer rather than waiting on a result
    /// that no one is going to send.
    void failAction(string action, string id)
    {
        ContentActionResult result;
        result.attempted = true;
        result.action = action;
        result.id = id;
        result.error = "Not connected to vrcd-server";

        synchronized (stateMutex)
            lastContentAction = result;
        notifyChange();

        logWarn("Content %s for %s dropped: no link to vrcd-server", action,
            id.length > 0 ? id : "(none)");
    }

    /// Whether the link cannot serve the moderation lists right now, filling
    /// in the reason as it says so. Caller holds the state lock.
    bool moderationsUnavailable()
    {
        if (linkStatus.connected == false)
        {
            moderationList.error = "Not connected to vrcd-server";
            return true;
        }

        if (linkStatus.serverVersion < PROTOCOL_MODERATION)
        {
            moderationList.error = "This vrcd-server is too old to list mutes " ~
                "and blocks (needs protocol v3)";
            return true;
        }
        return false;
    }

    /// Give up on a listing that could not be asked for.
    void failModerations(string error)
    {
        synchronized (stateMutex)
        {
            moderationList.loading = false;
            moderationList.error = error;
        }
        notifyChange();
    }

    /// Answer a moderation here, when nothing carried it. As with a content
    /// action: the button that was pressed gets an answer rather than waiting
    /// on a result no one is going to send.
    void failModeration(string action, string userId, string error)
    {
        ModerationActionResult result;
        result.attempted = true;
        result.action = action;
        result.userId = userId;
        result.displayName = displayNameFor(userId);
        result.error = error;

        synchronized (stateMutex)
            lastModeration = result;
        notifyChange();

        logWarn("Moderation %s for %s dropped: %s", action, userId, error);
    }

    /// Best-known name for a user: the roster first, then the moderation
    /// lists, which is where someone who is not a friend is named.
    string displayNameFor(string userId)
    {
        synchronized (stateMutex)
        {
            string name = displayNameOf(userId);
            if (name.length > 0)
                return name;

            foreach (ref ModeratedUser entry; moderationList.muted)
            {
                if (entry.userId == userId)
                    return entry.displayName;
            }

            foreach (ref ModeratedUser entry; moderationList.blocked)
            {
                if (entry.userId == userId)
                    return entry.displayName;
            }
        }
        return null;
    }

    /// vrcd-server's image cache when it shares this host, else null. Set
    /// once before the link starts and only read after, so it needs no lock.
    string imageCacheDir;

    /// Fire the change callback. Never called with the state lock held: the
    /// callback rebuilds a snapshot, which takes that same lock.
    void notifyChange()
    {
        if (onChange)
            onChange();
    }

    /// Write one `auth_response` and take the prompt down once it is away.
    ///
    /// The prompt is cleared here rather than on a reply, because there is no
    /// reply: the server either signs in or asks again. Every browser is
    /// looking at the same prompt, so the one that got answered has to close
    /// on all of them, and a wrong answer comes back as a fresh auth_request.
    bool answerAuth(JSONValue message)
    {
        if (sendMessage(message) == false)
        {
            logWarn("Sign-in answer dropped: no link to vrcd-server");
            return false;
        }

        synchronized (stateMutex)
            pendingAuth = AuthPrompt.init;
        notifyChange();
        return true;
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
                // An answer has nowhere to go now, and the server replays a
                // still-pending prompt after the next auth_ok. Leaving the
                // modal up would collect a password for a socket that is gone.
                pendingAuth = AuthPrompt.init;

                // Same for a status change: the set_status_result it is waiting
                // on died with the socket, and a picker stuck on "saving" is
                // worse than one that can be pressed again.
                if (lastStatus.pending)
                {
                    lastStatus.pending = false;
                    lastStatus.error = "Not connected to vrcd-server";
                }

                // And a profile edit, for the same reason: an editor stuck on
                // "saving" cannot even be pressed again.
                if (lastProfile.pending)
                {
                    lastProfile.pending = false;
                    lastProfile.error = "Not connected to vrcd-server";
                }

                // A request that was in flight died with the socket. The
                // entries themselves stay: they are worth reading while
                // disconnected, and the reconnect re-fetches them.
                foreach (ref ContentSnapshot snapshot; sections)
                {
                    if (snapshot.loading == false)
                        continue;

                    snapshot.loading = false;
                    snapshot.error = "Not connected to vrcd-server";
                    ++snapshot.revision;
                }

                // Same for the mute and block lists, which the reconnect asks
                // for again.
                if (moderationList.loading)
                {
                    moderationList.loading = false;
                    moderationList.error = "Not connected to vrcd-server";
                }
            }

            // On the same terms as the content lists: profiles already fetched
            // stay readable, a request that died with the socket does not.
            profiles.dropUnresolved();
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
        // down has no event to replay. Ask the server for its authoritative
        // inbox; an APIv10 server re-broadcasts it on every change, and the
        // events keep it current against older servers.
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

        // Player moderations have no WebSocket events of any kind, so this is
        // the only thing that ever fills the mute and block lists. Asked for
        // on connect rather than when the tab opens: a friend's pane draws
        // mute and block as toggles, and a toggle that does not know which way
        // it is pointing is worse than one call per connection.
        if (status().serverVersion >= PROTOCOL_MODERATION)
            requestModerations(true);
        else
        {
            synchronized (stateMutex)
            {
                moderationList = ModerationSnapshot.init;
                moderationsUnavailable();
            }
            notifyChange();

            logWarn("Server protocol is too old for mutes and blocks " ~
                "(needs v%d, server is v%d)",
                PROTOCOL_MODERATION, status().serverVersion);
        }

        // The database counters. Nothing announces them, so they are asked for
        // here and then again off each keepalive: the counts move as events
        // land, and the ping is the only clock this thread already has.
        sendMessage(JSONValue([ "type": JSONValue("get_stats") ]));

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

        // Only sections someone has already looked at: each one costs
        // vrcd-server a VRChat call, and a browser that never opened the tab
        // does not need them spent every reconnect. What was fetched before is
        // refreshed, since it may have changed while the link was down and no
        // event replays that.
        foreach (size_t i, string section; CONTENT_SECTIONS)
        {
            bool loaded;
            synchronized (stateMutex)
                loaded = sections[i].loaded;
            if (loaded)
                requestContent(section, true);
        }

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
            info.imageFileId = jsonString(message, "imageFileId");
            if (const(JSONValue) *v = "imageVersion" in message)
                if (v.type == JSONType.integer)
                    info.imageVersion = v.integer;

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
            applyContentRefresh(message);

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
            {
                // Since APIv10 this arrives on every server-side inbox
                // change, not just as the answer to get_notifications, and a
                // bare replacement would silently take the fakes with it.
                if (debugFakes)
                    foreach (ref NotificationInfo entry; inbox)
                        if (isDebugNotification(entry.id))
                            parsed ~= entry;
                inbox = parsed;
            }
            notifyChange();

            logInfo("Inbox: %d notification(s)", parsed.length);
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

        case "moderations":
            applyModerations(message);
            break;

        case "moderate_result":
            applyModerationResult(message, jsonString(message, "action"));
            break;

        case "unfriend_result":
            applyModerationResult(message, "unfriend");
            break;

        case "inventory":
            applySection("inventory", message, "items", 0);
            break;

        case "prints":
            applySection("prints", message, "prints", 0);
            break;

        case "files":
            // The reply echoes the offset it was asked for, which is what
            // tells a "load more" page apart from a fresh listing: the first
            // replaces, the rest append.
            long offset;
            if (const(JSONValue) *v = "offset" in message)
                if (v.type == JSONType.integer)
                    offset = v.integer;
            applySection(jsonString(message, "tag"), message, "files", offset);
            break;

        case "inventory_action_result":
            applyActionResult(message, jsonString(message, "action"),
                jsonString(message, "inventory_id"), "inventory");
            break;

        case "delete_file_result":
            // The file's own section is not in the reply, so every files
            // section is refreshed. It is one listing each, only for sections
            // someone has actually opened, and only on a delete.
            applyActionResult(message, "delete_file",
                jsonString(message, "file_id"), null);
            break;

        case "delete_print_result":
            applyActionResult(message, "delete_print",
                jsonString(message, "print_id"), "prints");
            break;

        case "set_user_icon_result":
            // Nothing in a section changed, so nothing is re-listed: the icon
            // lives on the user, not in the files list.
            applyActionResult(message, "set_icon",
                jsonString(message, "file_id"), "");
            break;

        case "upload_image_result":
            applyActionResult(message, "upload_image",
                jsonString(message, "tag"), jsonString(message, "tag"));
            break;

        case "upload_print_result":
            applyActionResult(message, "upload_print", "print", "prints");
            break;

        case "image":
            applyImage(message);
            break;

        case "user":
            applyUser(message);
            break;

        case "badge_image":
            applyBadgeImage(message);
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

        case "set_status_result":
            string statusError = jsonString(message, "error");
            bool statusOK;
            if (const(JSONValue) *v = "success" in message)
                statusOK = v.type == JSONType.true_;

            // The reply says only how it went, so what was asked for stays as
            // requestStatus left it: the page names it in the failure. A
            // success has already arrived as a `self` of its own, which is what
            // moves the picker.
            synchronized (stateMutex)
            {
                lastStatus.attempted = true;
                lastStatus.pending = false;
                lastStatus.success = statusOK;
                lastStatus.error = statusError;
            }
            notifyChange();

            if (statusOK)
                logInfo("Status updated");
            else
                logWarn("Status update failed: %s", statusError);
            break;

        case "set_profile_result":
            string profileError = jsonString(message, "error");
            bool profileOK;
            if (const(JSONValue) *v = "success" in message)
                profileOK = v.type == JSONType.true_;

            string editedId;
            synchronized (stateMutex)
            {
                lastProfile.attempted = true;
                lastProfile.pending = false;
                lastProfile.success = profileOK;
                lastProfile.error = profileError;
                editedId = selfInfo.id;
            }

            // The cached profile now describes the profile as it was. Only some
            // of what was written comes back in the `self` snapshot -- languages
            // are not in it at all, and a field that was cleared is empty there,
            // which is exactly the case the merge lets the older record win. So
            // the copy held here goes, and the page's next look re-fetches it.
            if (profileOK && editedId.length > 0)
                profiles.forget(editedId);
            notifyChange();

            if (profileOK)
                logInfo("Profile updated");
            else
                logWarn("Profile update failed: %s", profileError);
            break;

        case "auth_request":
            // The server cannot reach VRChat without this, so it goes into the
            // snapshot and the page puts a modal over everything. A server
            // connecting mid-prompt replays it after auth_ok, so a browser
            // that arrives late still sees it.
            AuthPrompt asked;
            asked.active = true;
            asked.kind   = jsonString(message, "kind");
            asked.method = jsonString(message, "method");
            asked.error  = jsonString(message, "error");

            synchronized (stateMutex)
                pendingAuth = asked;
            notifyChange();

            logInfo("vrcd-server is asking for %s", asked.kind == "credentials"
                ? "VRChat credentials"
                : "a 2FA code (" ~ asked.method ~ ")");
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

        case "stats":
            StoreStats counted;
            counted.known = true;
            if (const(JSONValue) *v = "event_count" in message)
                if (v.type == JSONType.integer)
                    counted.eventCount = v.integer;
            if (const(JSONValue) *v = "world_cache_count" in message)
                if (v.type == JSONType.integer)
                    counted.worldCacheCount = v.integer;
            if (const(JSONValue) *v = "avatar_cache_count" in message)
                if (v.type == JSONType.integer)
                    counted.avatarCacheCount = v.integer;
            if (const(JSONValue) *v = "db_size_bytes" in message)
                if (v.type == JSONType.integer)
                    counted.dbSizeBytes = v.integer;

            bool moved;
            synchronized (stateMutex)
            {
                moved = storeStats != counted;
                storeStats = counted;
            }
            // Only when a number actually changed: this arrives every keepalive,
            // and a snapshot to every browser twice a minute for an unchanged
            // count would redraw the page for nothing.
            if (moved)
                notifyChange();

            logTrace("Stats: %d events, %d worlds, %d avatars, %d bytes",
                counted.eventCount, counted.worldCacheCount,
                counted.avatarCacheCount, counted.dbSizeBytes);
            break;

        case "ping":
            sendMessage(JSONValue([ "type": JSONValue("pong") ]));
            sendMessage(JSONValue([ "type": JSONValue("get_stats") ]));
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

        // An edit to something already on the page. Nothing is added for one:
        // an update for a row this front-end never saw is an update to a
        // notification the user already answered.
        if (change == NotificationChange.updated)
        {
            synchronized (stateMutex)
                foreach (ref NotificationInfo entry; inbox)
                {
                    if (entry.id != added.id)
                        continue;
                    mergeNotificationUpdate(entry, added);
                    break;
                }
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

    /// Fold the mute and block lists in.
    ///
    /// A failure is reported inside the message rather than as an `error`, so
    /// this is also where a refresh that did not work resolves. The lists that
    /// are on screen survive it: they are still the last thing VRChat said.
    void applyModerations(ref JSONValue message)
    {
        static ModeratedUser[] parseList(ref JSONValue message, string key)
        {
            ModeratedUser[] users;
            if (const(JSONValue) *v = key in message)
            {
                if (v.type != JSONType.array)
                    return users;

                users.reserve(v.array.length);
                foreach (const(JSONValue) entry; v.array)
                {
                    if (entry.type != JSONType.object)
                        continue;

                    ModeratedUser user;
                    user.userId = jsonString(entry, "user_id");
                    user.displayName = jsonString(entry, "display_name");
                    if (user.userId.length > 0)
                        users ~= user;
                }
            }
            return users;
        }

        string error = jsonString(message, "error");
        ModeratedUser[] muted = parseList(message, "muted");
        ModeratedUser[] blocked = parseList(message, "blocked");

        synchronized (stateMutex)
        {
            moderationList.loading = false;
            if (error.length > 0)
                moderationList.error = error;
            else
            {
                moderationList.error = null;
                moderationList.loaded = true;
                moderationList.muted = muted;
                moderationList.blocked = blocked;
            }
        }
        notifyChange();

        if (error.length > 0)
            logWarn("Could not fetch moderations: %s", error);
        else
            logInfo("Moderations: %d muted, %d blocked", muted.length, blocked.length);
    }

    /// Fold one moderation reply into the last-moderation slot.
    ///
    /// Nothing is re-listed here: vrcd-server broadcasts fresh `moderations`
    /// and `friends` snapshots of its own after a successful call, which reach
    /// every browser rather than only the one that pressed the button.
    void applyModerationResult(ref JSONValue message, string action)
    {
        ModerationActionResult result;
        result.attempted = true;
        result.action = action;
        result.userId = jsonString(message, "user_id");
        result.displayName = jsonString(message, "display_name");
        result.error = jsonString(message, "error");
        if (const(JSONValue) *v = "success" in message)
            result.success = v.type == JSONType.true_;

        if (result.displayName.length == 0)
            result.displayName = displayNameFor(result.userId);

        synchronized (stateMutex)
            lastModeration = result;
        notifyChange();

        if (result.success)
            logInfo("Moderation %s done: %s", action, result.userId);
        else
            logWarn("Moderation %s for %s failed: %s", action, result.userId,
                result.error);
    }

    /// Fold one listing reply into its section.
    ///
    /// Params:
    ///   section = Section the reply belongs to.
    ///   message = The reply itself.
    ///   arrayKey = Where the entries are: "items", "files", or "prints".
    ///   offset = Offset the page was asked for. Past zero this appends,
    ///            which is what a "load more" does.
    void applySection(string section, ref JSONValue message, string arrayKey,
        long offset)
    {
        ptrdiff_t index = contentSectionIndex(section);
        if (index < 0)
        {
            logWarn("Listing reply for an unknown section: %s", section);
            return;
        }

        string error = jsonString(message, "error");
        long totalCount;
        if (const(JSONValue) *v = "total_count" in message)
            if (v.type == JSONType.integer)
                totalCount = v.integer;

        JSONValue[] entries;
        if (JSONValue *v = arrayKey in message)
            if (v.type == JSONType.array)
                entries = v.array;

        synchronized (stateMutex)
        {
            sections[index].loading = false;

            // A failed refresh keeps the list that is on screen: it is still
            // the last thing VRChat told us, and blanking it turns a hiccup
            // into an empty section.
            if (error.length > 0)
                sections[index].error = error;
            else
            {
                sections[index].error = null;
                sections[index].loaded = true;
                sections[index].totalCount = totalCount;
                // Only the files sections page; a full page means there may be
                // another behind it.
                sections[index].more = isFilesSection(section) &&
                    entries.length >= CONTENT_PAGE;

                if (offset > 0)
                    sections[index].items ~= entries;
                else
                    sections[index].items = entries;
            }
            ++sections[index].revision;
        }
        notifyChange();

        if (error.length > 0)
            logWarn("Could not fetch %s: %s", section, error);
        else
            logInfo("%s: %d entries", section, entries.length);
    }

    /// Fold one action reply into the last-action slot, then re-list whatever
    /// it changed: VRChat's own view has moved and nothing else says how.
    ///
    /// Params:
    ///   message = The reply.
    ///   action = What was asked for, for the page's toast.
    ///   id = What it was aimed at.
    ///   refreshSection = Section to re-list on success. Empty refreshes
    ///                    nothing; null refreshes every files section, for a
    ///                    reply that does not say which one it changed.
    void applyActionResult(ref JSONValue message, string action, string id,
        string refreshSection)
    {
        ContentActionResult result;
        result.attempted = true;
        result.action = action;
        result.id = id;
        result.error = jsonString(message, "error");
        if (const(JSONValue) *v = "success" in message)
            result.success = v.type == JSONType.true_;

        synchronized (stateMutex)
            lastContentAction = result;
        notifyChange();

        string what = id.length > 0 ? id : "(none)";
        if (result.success == false)
        {
            logWarn("Content %s for %s failed: %s", action, what, result.error);
            return;
        }

        logInfo("Content %s done: %s", action, what);

        if (refreshSection is null)
            refreshFilesSections();
        else if (refreshSection.length > 0)
            requestContent(refreshSection, true);
    }

    /// Re-list every files section that has been looked at, for a reply that
    /// does not name the section it changed.
    void refreshFilesSections()
    {
        foreach (size_t i, string section; CONTENT_SECTIONS)
        {
            if (isFilesSection(section) == false)
                continue;

            bool loaded;
            synchronized (stateMutex)
                loaded = sections[i].loaded;
            if (loaded)
                requestContent(section, true);
        }
    }

    /// Refresh a section when VRChat says it changed somewhere else: an
    /// in-game upload, a drop, another device. Only when the section has been
    /// fetched at least once, since nothing is waiting on the others.
    void applyContentRefresh(ref JSONValue message)
    {
        if (jsonString(message, "event_type") != "content-refresh")
            return;

        const(JSONValue) *content = "content" in message;
        if (content is null || content.type != JSONType.object)
            return;

        string section = sectionForContentType(jsonString(*content, "contentType"));
        if (section.length == 0)
            return;

        bool loaded;
        synchronized (stateMutex)
            loaded = sections[contentSectionIndex(section)].loaded;
        if (loaded == false)
            return;

        logInfo("%s changed elsewhere, refreshing", section);
        requestContent(section, true);
    }

    /// File one proxied image away. No state change is published: the browser
    /// is already coming back for it, and a broadcast per thumbnail would put
    /// a whole grid's worth of snapshots on every socket.
    /// Take in one `user` reply. A failure is stored as one: the page has a
    /// pane open waiting on this, and it needs to be told there is nothing
    /// coming rather than retrying until it gives up.
    void applyUser(ref JSONValue message)
    {
        string userId = jsonString(message, "user_id");
        if (userId.length == 0)
            return;

        bool success;
        if (const(JSONValue) *v = "success" in message)
            success = v.type == JSONType.true_;

        const(JSONValue) *user = "user" in message;
        if (success == false || user is null || user.type != JSONType.object)
        {
            string error = jsonString(message, "error");
            profiles.storeFailure(userId, error.length > 0 ? error : "Profile unavailable");
            logDebugging("Profile for %s failed: %s", userId, error);
            return;
        }

        // Stored as it arrived: the page is the only thing that reads it, and
        // re-parsing on the way out would only be to build the same bytes.
        profiles.store(userId, user.toString());
        logDebugging("Profile for %s cached", userId);
    }

    /// Take in one `badge_image` reply, into the same cache as everything else
    /// with a picture in it, under the URL that was asked for.
    void applyBadgeImage(ref JSONValue message)
    {
        string url = jsonString(message, "url");
        if (url.length == 0)
            return;

        string cacheKey = "badge:" ~ url;

        bool success;
        if (const(JSONValue) *v = "success" in message)
            success = v.type == JSONType.true_;

        if (success == false)
        {
            string error = jsonString(message, "error");
            images.storeFailure(cacheKey,
                error.length > 0 ? error : "Badge image unavailable");
            logDebugging("Badge image %s failed: %s", url, error);
            return;
        }

        string encoded = jsonString(message, "data_base64");
        ubyte[] data;
        try data = Base64.decode(encoded);
        catch (Exception ex)
        {
            images.storeFailure(cacheKey, "Malformed image data");
            logWarn("Badge image %s came back malformed: %s", url, ex.msg);
            return;
        }

        string mimeType = jsonString(message, "mime_type");
        images.store(cacheKey, data,
            mimeType.length > 0 ? mimeType : "application/octet-stream");
        logTrace("Badge image %s cached (%u bytes)", url, data.length);
    }

    void applyImage(ref JSONValue message)
    {
        string fileId = jsonString(message, "file_id");
        long fileVersion = 1;
        int size;
        if (const(JSONValue) *v = "version" in message)
            if (v.type == JSONType.integer)
                fileVersion = v.integer;
        if (const(JSONValue) *v = "size" in message)
            if (v.type == JSONType.integer)
                size = cast(int)v.integer;

        string cacheKey = ImageCache.key(fileId, fileVersion, size);

        bool success;
        if (const(JSONValue) *v = "success" in message)
            success = v.type == JSONType.true_;

        if (success == false)
        {
            string error = jsonString(message, "error");
            images.storeFailure(cacheKey, error.length > 0 ? error : "Image unavailable");
            logDebugging("Image %s failed: %s", cacheKey, error);
            return;
        }

        string encoded = jsonString(message, "data_base64");
        ubyte[] data;
        try data = Base64.decode(encoded);
        catch (Exception ex)
        {
            images.storeFailure(cacheKey, "Malformed image data");
            logWarn("Image %s came back malformed: %s", cacheKey, ex.msg);
            return;
        }

        string mimeType = jsonString(message, "mime_type");
        images.store(cacheKey, data, mimeType.length > 0 ? mimeType : "application/octet-stream");
        logTrace("Image %s cached (%u bytes)", cacheKey, data.length);
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

    /// Answer a fake notification, here rather than down the link.
    ///
    /// The outcome is written into the same slot a real answer's
    /// `notification_action_result` lands in, so the page's toast, its button
    /// bookkeeping and the row leaving the list all happen exactly as they
    /// would for a real one. That is the point: the parts being exercised are
    /// the page's, not VRChat's.
    void answerFake(string notificationId, string action)
    {
        NotifyActionResult result;
        result.attempted = true;
        result.notificationId = notificationId;
        result.action = action;
        result.success = true;

        synchronized (stateMutex)
        {
            removeFromInbox(notificationId);
            lastNotifyAction = result;
        }
        notifyChange();

        logInfo("Debug: answered fake notification %s with %s",
            notificationId, action);
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

/// Section a `content-refresh` event names, or null when it names something
/// this front-end does not show. VRChat's own wording is the section name for
/// four of the six.
private string sectionForContentType(string contentType)
{
    switch (contentType)
    {
    case "gallery", "icon", "sticker", "emoji": return contentType;
    case "print", "prints":                     return "prints";
    case "inventory":                           return "inventory";
    default:                                    return null;
    }
}

/// Read a string field out of a JSON object, or null when absent or not a string.
private string jsonString(ref const(JSONValue) object, string key)
{
    if (const(JSONValue) *v = key in object)
        if (v.type == JSONType.string)
            return v.str;
    return null;
}
