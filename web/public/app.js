/* vrcd front-end.
 *
 * The page is a shell: a tab rail, a list column, and a detail pane. State
 * arrives as a full snapshot over the WebSocket and the whole shell redraws
 * from it, so a reconnecting browser is correct immediately. The feed arrives
 * separately as an append-only log and is kept in a bounded ring.
 *
 * On a phone the rail becomes a bottom bar and the detail pane becomes a
 * pushed page; that is all CSS, driven by the data-pane attribute on #shell.
 */

var STATUS_COLORS = {
    "active":  "#51e57e",
    "join me": "#42caff",
    "ask me":  "#e88134",
    "busy":    "#ff4d4d",
    "offline": "#8a8a99"
};

var PLATFORMS = {
    "standalonewindows": "PC",
    "android": "Quest",
    "ios": "iOS",
    "web": "Web"
};

/* Tabs the rail offers. `soon` marks the ones the web link does not carry
   data for yet: the server API has the calls, this front-end does not use
   them. Drop the flag once it does. */
var TABS = [
    { id: "feed",     label: "FEED",     icon: "i-feed",    search: true },
    { id: "online",   label: "ONLINE",   icon: "i-online",  search: true },
    { id: "inbox",    label: "INBOX",    icon: "i-inbox",   badge: true },
    { id: "stuff",    label: "STUFF",    icon: "i-stuff",   search: true },
    { id: "tools",    label: "TOOLS",    icon: "i-tools",   soon: true },
    /* The rail opens the profile through the self card at its foot, so only
       the bottom bar, which has no foot, draws a button for it. */
    { id: "profile",  label: "PROFILE",  icon: "i-profile", foot: true }
];

var SOON_TEXT = {
    tools: "Screenshot and log tools belong to the local client; only the " +
           "ones that go through the server can appear here."
};

/* What each notification type is called, and what can be done about it.
   `accept` is VRChat's accept endpoint, which only means anything for a
   friend request. An invite is answered by joining where it points, and a
   request for an invite cannot be answered at all from here: sending one back
   needs an API vrcd-server does not expose yet, so the row says so rather
   than drawing a button that would lie. */
var NOTIFY_TYPES = {
    friendRequest: { label: "Friend request", accept: "ACCEPT", hide: "DECLINE" },
    invite:        { label: "Invite",         join: true,       hide: "DISMISS" },
    requestInvite: { label: "Invite request", hide: "DISMISS",
                     note: "Sending an invite back needs an API the server " +
                           "does not expose yet." }
};

/* What each 2FA method is asking for. VRChat calls them totp, otp and
   emailOtp; only the first is the usual authenticator app. */
var TWOFA_TEXT = {
    totp:     "Enter the code from the account's authenticator app.",
    emailOtp: "Enter the code VRChat emailed to the account.",
    otp:      "Enter one of the account's one-time recovery codes."
};

var TITLES = {
    feed: "Feed", online: "Online", inbox: "Inbox",
    stuff: "Stuff", tools: "Tools", profile: "Profile"
};

var PLACEHOLDERS = {
    feed: "Filter events...",
    online: "Filter friends and worlds...",
    stuff: "Filter your stuff..."
};

/* The STUFF sections, in the order the switcher shows them. The first four are
   tags on VRChat's files API and take uploads of the same name; prints and
   items have endpoints of their own. `kind` is what an entry looks like, which
   is what the card and the detail pane draw from. */
var SECTIONS = [
    { id: "gallery",   label: "GALLERY",  kind: "file",  upload: "gallery" },
    { id: "icon",      label: "ICONS",    kind: "file",  upload: "icon" },
    { id: "sticker",   label: "STICKERS", kind: "file",  upload: "sticker" },
    { id: "emoji",     label: "EMOJI",    kind: "file",  upload: "emoji" },
    { id: "prints",    label: "PRINTS",   kind: "print", upload: "print" },
    { id: "inventory", label: "ITEMS",    kind: "item" }
];

/* What each section is, and what VRChat will not accept there. Shown under the
   grid rather than on the upload button: it is worth reading once. The shape
   and format are what the crop frame is for, so they are stated as what a
   picture becomes rather than as what will be refused. */
var SECTION_HINTS = {
    gallery: "Your VRC+ gallery. Goes up as PNG, at most 2000x2000.",
    icon: "Profile icons. Goes up as PNG, at most 2000x2000. Setting one " +
          "needs VRC+.",
    sticker: "Stickers you can drop in a world. Square PNG, at most 2000x2000.",
    emoji: "Emoji you can play. Square PNG, at most 2000x2000. Animated emoji " +
           "upload as a sprite sheet, which this page cannot describe yet, so " +
           "they arrive as a still.",
    prints: "Photos printed in-world. Goes up as PNG, at most 2000x2000. " +
            "VRChat keeps 64.",
    inventory: "Props, bundles and skins. Emoji and stickers are not here: " +
               "they have their own sections above."
};

/* Which equip slot an item type belongs to. VRChat reports the slot on the
   item itself, but only ever one of these three exists, so an item whose slot
   comes back empty can still be placed by its type. */
var ITEM_SLOTS = {
    droneskin: "drone",
    portalskin: "portal",
    warpeffect: "warp"
};

var ACTION_DONE = {
    equip: "Equipped",
    unequip: "Unequipped",
    consume: "Consumed",
    delete_file: "Deleted",
    delete_print: "Print deleted",
    set_icon: "Profile icon updated",
    upload_image: "Uploaded",
    upload_print: "Print uploaded"
};

/* VRChat's own ceiling. Checked here so a picture that was never going to be
   accepted does not travel twice before being refused. */
var UPLOAD_MAX_BYTES = 10 * 1024 * 1024;

var FEED_MAX = 500;

/* Everything the page draws from. `state` is replaced wholesale by each
   snapshot; `view` is local and survives them. */
var state = {
    connected: false,
    vrchat_connected: false,
    server_version: "",
    last_error: "",
    roster: { instances: [], active_elsewhere: [], offline: [] },
    notifications: []
};
var feed = [];
var view = { tab: "online", sel: null, filter: "", section: "gallery" };
var lastJoinKey = "";
var lastNotifyKey = "";
var lastActionKey = "";
/* Notification IDs with a request in flight. A snapshot replaces `state`
   wholesale, so the in-flight mark cannot live on the entry itself. */
var pendingNotifications = {};

/* The STUFF sections, fetched over HTTP rather than carried in the snapshot: a
   few hundred entries would ride along with every friend movement. The
   snapshot's `content.<section>.revision` is the signal to come back for a new
   copy. Everything here is per section and keyed by section id. */
var content = {};
var contentInFlight = {};
var contentDirty = {};
var contentRevisions = {};
SECTIONS.forEach(function (section) {
    content[section.id] = { fetched: false, loading: false, loaded: false,
                            more: false, error: "", total_count: 0, items: [] };
    contentRevisions[section.id] = -1;
});

/* Entry IDs with an action in flight, the entry armed for a destructive
   confirm, and the sections with an upload going up. All three survive the
   redraw a snapshot causes. */
var pendingItems = {};
var armedAction = "";
var uploading = {};

/* ------------------------------------------------------------- helpers */

function el(tag, cls, text) {
    var node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text) node.textContent = text;
    return node;
}

function icon(name, size) {
    var svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("width", size);
    svg.setAttribute("height", size);
    svg.setAttribute("class", "icon");
    var use = document.createElementNS("http://www.w3.org/2000/svg", "use");
    use.setAttribute("href", "#" + name);
    svg.appendChild(use);
    return svg;
}

/* Stable per-name hue, so a friend keeps the same colour and a world keeps
   the same stand-in thumbnail between reloads. */
function hash(text) {
    var h = 2166136261;
    for (var i = 0; i < text.length; i++) {
        h ^= text.charCodeAt(i);
        h = (h * 16777619) >>> 0;
    }
    return h;
}

function avatar(name, big) {
    var node = el("div", "av" + (big ? " lg" : ""), name.slice(0, 2).toUpperCase());
    node.style.background = "hsl(" + (hash(name) % 360) + " 55% 62%)";
    return node;
}

function shotBackground(name) {
    var h = hash(name);
    var hue = h % 360;
    var hue2 = (hue + 40 + (h >> 8) % 60) % 360;
    return "radial-gradient(120% 90% at 20% 15%, hsl(" + hue + " 45% 38%), " +
           "hsl(" + hue2 + " 40% 20%) 60%, hsl(" + hue2 + " 35% 12%))";
}

function statusDot(status, big) {
    var dot = el("span", "dot" + (big ? " big" : ""));
    dot.style.background = STATUS_COLORS[status] || "#8a8a99";
    return dot;
}

/* Instance type and region are encoded in the location string:
   wrld_x:12345~friends(usr_y)~region(eu) */
function parseLocation(location) {
    var out = { type: "public", region: "" };
    if (!location) return out;

    if (location.indexOf("~friends(") >= 0)      out.type = "friends+";
    else if (location.indexOf("~hidden(") >= 0)  out.type = "friends";
    else if (location.indexOf("~private(") >= 0) out.type = "invite";
    else if (location.indexOf("~group(") >= 0)   out.type = "group";

    var region = /~region\(([a-z]+)\)/.exec(location);
    if (region) out.region = region[1];
    return out;
}

/* A group's identity for selection. instance_id alone is not unique across
   worlds, and the private bucket has no location at all. */
function groupKey(group) {
    return group.location ? group.location : "private";
}

function groupName(group) {
    if (group.instance_id === "private") return "Private world";
    return group.world_name || group.instance_id;
}

function findGroup(key) {
    var groups = state.roster.instances;
    for (var i = 0; i < groups.length; i++)
        if (groupKey(groups[i]) === key) return groups[i];
    return null;
}

/* Returns { friend, group } so the detail pane knows where they are. */
function findFriend(id) {
    var roster = state.roster;
    for (var i = 0; i < roster.instances.length; i++) {
        var group = roster.instances[i];
        for (var j = 0; j < group.friends.length; j++)
            if (group.friends[j].id === id)
                return { friend: group.friends[j], group: group };
    }

    var loose = roster.active_elsewhere.concat(roster.offline);
    for (var k = 0; k < loose.length; k++)
        if (loose[k].id === id)
            return { friend: loose[k], group: null };
    return null;
}

function findFriendByName(name) {
    var roster = state.roster;
    var all = roster.active_elsewhere.concat(roster.offline);
    roster.instances.forEach(function (group) { all = all.concat(group.friends); });
    for (var i = 0; i < all.length; i++)
        if (all[i].displayName === name) return all[i];
    return null;
}

function tabInfo(id) {
    for (var i = 0; i < TABS.length; i++)
        if (TABS[i].id === id) return TABS[i];
    return TABS[0];
}

function matches(text) {
    return view.filter === "" || (text || "").toLowerCase().indexOf(view.filter) >= 0;
}

/* ---------------------------------------------------------------- rail */

function renderRail() {
    var rail = document.getElementById("rail");
    var bottom = document.getElementById("bottom");
    rail.textContent = "";
    bottom.textContent = "";

    var brand = el("div", "brand");
    brand.appendChild(el("span", "v", "vrc"));
    brand.appendChild(document.createTextNode("d"));
    rail.appendChild(brand);

    TABS.forEach(function (tab) {
        if (tab.foot === undefined) rail.appendChild(tabButton(tab));
        bottom.appendChild(tabButton(tab));
    });

    var foot = el("div", "rail-foot");
    foot.appendChild(selfCard());

    var link = el("div", "link", linkText());
    if (state.connected === false) link.classList.add("down");
    foot.appendChild(link);

    rail.appendChild(foot);
}

function tabButton(tab) {
    var cls = tab.id === view.tab ? "on" : (tab.soon ? "soon" : null);
    var button = el("button", cls);

    // Your own face reads faster than a generic person glyph.
    if (tab.id === "profile" && state.self) {
        var face = avatar(state.self.displayName);
        face.classList.add("xs");
        button.appendChild(face);
    } else {
        button.appendChild(icon(tab.icon, 20));
    }

    button.appendChild(el("span", null, tab.label));

    // Only the inbox counts for anything: the number is how many things are
    // waiting on an answer, so a zero is drawn as nothing at all.
    if (tab.badge && state.notifications && state.notifications.length)
        button.appendChild(el("span", "badge", String(state.notifications.length)));

    button.onclick = function () { showTab(tab.id); };
    return button;
}

function selfCard() {
    var card = el("button", "self-card" + (view.tab === "profile" ? " on" : ""));
    var self = state.self;
    card.appendChild(statusDot(self ? self.status : "offline", true));

    var who = el("div", "who");
    who.appendChild(el("div", "name", self ? self.displayName : "Not signed in"));
    who.appendChild(el("div", "st", self
        ? (self.statusDescription || self.status)
        : "waiting for vrcd-server"));
    card.appendChild(who);

    card.onclick = function () { showTab("profile"); };
    return card;
}

function linkText() {
    if (state.connected === false)
        return "disconnected" + (state.last_error ? ": " + state.last_error : "");
    return "vrcd-server v" + state.server_version +
        (state.vrchat_connected ? " - VRChat up" : " - VRChat down");
}

/* ----------------------------------------------------------- list pane */

function friendRow(friend) {
    var row = el("button", "row");
    if (view.sel && view.sel.kind === "friend" && view.sel.id === friend.id)
        row.classList.add("on");
    row.appendChild(avatar(friend.displayName));

    var who = el("div", "who");
    var line = el("div", "n");
    line.appendChild(statusDot(friend.status));
    line.appendChild(document.createTextNode(" " + friend.displayName));
    who.appendChild(line);
    if (friend.statusDescription)
        who.appendChild(el("div", "d", friend.statusDescription));
    row.appendChild(who);

    if (friend.platform)
        row.appendChild(el("span", "plat", PLATFORMS[friend.platform] || friend.platform));

    row.onclick = function () { select({ kind: "friend", id: friend.id }); };
    return row;
}

function renderOnline(body) {
    var roster = state.roster;
    var shown = 0;

    roster.instances.forEach(function (group) {
        var name = groupName(group);
        var key = groupKey(group);

        // A world name match keeps the whole group; otherwise the group is
        // kept only for the friends that matched.
        var friends = group.friends;
        if (matches(name) === false) {
            friends = group.friends.filter(function (f) { return matches(f.displayName); });
            if (friends.length === 0) return;
        }
        shown++;

        var box = el("div", "group");
        var head = el("button", "group-head");
        if (view.sel && view.sel.kind === "instance" && view.sel.id === key)
            head.classList.add("on");
        head.appendChild(statusDot(group.instance_id === "private" ? "offline" : "active"));
        head.appendChild(el("div", "world", name));
        if (group.n_users >= 0 && group.capacity > 0)
            head.appendChild(el("div", "count", group.n_users + "/" + group.capacity));
        head.onclick = function () { select({ kind: "instance", id: key }); };
        box.appendChild(head);

        var list = el("div", "friends");
        friends.forEach(function (f) { list.appendChild(friendRow(f)); });
        box.appendChild(list);
        body.appendChild(box);
    });

    var away = roster.active_elsewhere.filter(function (f) { return matches(f.displayName); });
    if (away.length) {
        shown++;
        body.appendChild(el("div", "section", "Active elsewhere"));
        var awayBox = el("div", "flat");
        away.forEach(function (f) { awayBox.appendChild(friendRow(f)); });
        body.appendChild(awayBox);
    }

    var down = roster.offline.filter(function (f) { return matches(f.displayName); });
    if (down.length) {
        shown++;
        body.appendChild(el("div", "section", "Offline (" + down.length + ")"));
        var downBox = el("div", "flat");
        down.forEach(function (f) { downBox.appendChild(friendRow(f)); });
        body.appendChild(downBox);
    }

    if (shown === 0)
        body.appendChild(placeholder(view.filter
            ? "Nothing matches that filter."
            : "No friend data yet."));
}

function renderFeed(body) {
    var visible = feed.filter(function (event) {
        return matches(event.user) || matches(event.label) || matches(event.detail);
    });

    if (visible.length === 0) {
        body.appendChild(placeholder(feed.length ? "Nothing matches that filter." : "No events yet."));
        return;
    }

    var box = el("div", "flat");
    // Newest first, which is the opposite of how the log arrives.
    for (var i = visible.length - 1; i >= 0; i--)
        box.appendChild(eventRow(visible[i]));
    body.appendChild(box);
}

function eventRow(event) {
    var row = el("button", "event");

    // The server sends UTC ISO 8601; render it in the viewer's timezone.
    var when = new Date(event.received_at);
    row.appendChild(el("div", "time",
        isNaN(when.getTime()) ? "--:--:--" : when.toLocaleTimeString()));

    row.appendChild(el("div", "label", event.label));
    row.appendChild(el("div", "u", event.user));
    row.appendChild(el("div", "what", event.detail));

    row.onclick = function () {
        var friend = findFriendByName(event.user);
        if (friend) select({ kind: "friend", id: friend.id });
    };
    return row;
}

/* Oldest first, and never re-sorted. The buttons sit in the rows, so a list
   that reflowed when something arrived would slide the button under a thumb
   that was already on its way down to it - and the two buttons on a friend
   request mean the wrong one is an accept. New notifications append. */
function renderInbox(body) {
    var pending = state.notifications || [];

    if (pending.length === 0) {
        var why = "Nothing waiting on you.";
        if (state.connected === false)
            why = "Waiting for vrcd-server.";
        else if (state.server_version && state.server_version < 4)
            why = "This vrcd-server is too old to list notifications " +
                  "(needs protocol v4).";
        body.appendChild(placeholder(why));
        return;
    }

    pending.forEach(function (entry) { body.appendChild(notifyCard(entry)); });
}

function notifyCard(entry) {
    var kind = NOTIFY_TYPES[entry.notification_type] ||
        { label: entry.notification_type, hide: "DISMISS" };
    var who = entry.sender_name || entry.sender_user_id || "Someone";
    var busy = pendingNotifications[entry.id] === true;

    var card = el("div", "notify");

    // A button, not a div, so the sender opens in the detail pane the way a
    // feed row does. The action buttons are siblings of it, never inside it.
    var friend = entry.sender_user_id ? findFriend(entry.sender_user_id) : null;
    var head = el(friend ? "button" : "div", "head");
    head.appendChild(avatar(who));
    var text = el("div", "who");
    text.appendChild(el("div", "n", who));
    text.appendChild(el("div", "d", kind.label));
    head.appendChild(text);
    if (entry.received_at_unix)
        head.appendChild(el("div", "when", whenText(entry.received_at_unix)));
    if (friend)
        head.onclick = function () { select({ kind: "friend", id: entry.sender_user_id }); };
    card.appendChild(head);

    if (entry.message) card.appendChild(el("div", "msg", entry.message));
    if (kind.note) card.appendChild(el("div", "note", kind.note));

    var actions = el("div", "actions");
    if (kind.accept)
        actions.appendChild(notifyButton(entry, "accept", kind.accept, true, busy));
    // An invite is answered by going there, which is the same self-invite the
    // roster offers; VRChat's accept endpoint does nothing useful for one.
    if (kind.join && entry.location) {
        var go = joinButton(entry.location, "JOIN WORLD");
        go.disabled = busy;
        actions.appendChild(go);
    }
    if (kind.hide)
        actions.appendChild(notifyButton(entry, "hide", kind.hide, false, busy));
    card.appendChild(actions);

    return card;
}

function notifyButton(entry, action, label, primary, busy) {
    var button = el("button", "act" + (primary ? " primary" : ""), label);
    button.disabled = busy;
    button.onclick = function () { notifyAct(entry.id, action, button); };
    return button;
}

/* Coarse on purpose: the exact minute a friend request landed does not
   matter, only whether it is new or has been sitting there. */
function whenText(unix) {
    var mins = Math.floor((Date.now() / 1000 - unix) / 60);
    if (mins < 1)   return "just now";
    if (mins < 60)  return mins + "m ago";
    if (mins < 1440) return Math.floor(mins / 60) + "h ago";
    return Math.floor(mins / 1440) + "d ago";
}

/* --------------------------------------------------------------- images */

/* Images are proxied: the browser cannot fetch a VRChat file itself, so the
   web server asks vrcd-server for it and answers 202 until the bytes land. A
   miss is therefore a retry, not a failure.

   Object URLs are kept per key. The shell redraws on every snapshot, and a
   grid that re-fetched its thumbnails each time would keep both ends busy for
   nothing. A file, version and size never change what they point at, so a
   cached URL never goes stale. */
var imageURLs = {};
/* Key -> the img nodes waiting on it. One fetch serves all of them, which is
   what stops a redraw mid-fetch from starting a second. */
var imageWaiting = {};
var imageFailed = {};

var IMAGE_RETRY_MS = 800;
/* Roughly 30 seconds of retries. vrcd-server spaces uncached downloads 250 ms
   apart, so a full grid takes a while to come through on a cold cache. */
var IMAGE_TRIES = 40;

function imageInto(img, fileId, version, size) {
    var key = fileId + "/" + version + "/" + size;
    if (imageURLs[key]) { img.src = imageURLs[key]; return; }
    if (imageFailed[key]) return;

    if (imageWaiting[key]) { imageWaiting[key].push(img); return; }
    imageWaiting[key] = [img];
    fetchImage(key, fileId, version, size, IMAGE_TRIES);
}

function fetchImage(key, fileId, version, size, tries) {
    fetch("/api/image/" + encodeURIComponent(fileId) +
          "?v=" + version + "&size=" + size).then(function (r) {
        if (r.status === 202) {
            if (tries > 0) {
                setTimeout(function () {
                    fetchImage(key, fileId, version, size, tries - 1);
                }, IMAGE_RETRY_MS);
            } else {
                imageDone(key, null);
            }
            return null;
        }
        if (r.ok === false) { imageDone(key, null); return null; }
        return r.blob();
    }).then(function (blob) {
        if (blob) imageDone(key, URL.createObjectURL(blob));
    }).catch(function () {
        imageDone(key, null);
    });
}

function imageDone(key, url) {
    var waiting = imageWaiting[key] || [];
    delete imageWaiting[key];

    if (url === null) { imageFailed[key] = true; return; }
    imageURLs[key] = url;
    // Nodes from a render that has since been replaced are detached by now,
    // and setting src on one of those costs nothing.
    waiting.forEach(function (img) { img.src = url; });
}

/* The gradient underneath is not a placeholder for a slow image so much as
   what an artless entry looks like: plenty of items, and any file whose only
   version was deleted, have no picture to show. */
function thumb(entry, section, size, big) {
    var box = el("div", "thumb" + (big ? " lg" : ""));
    box.style.background = shotBackground(entryName(entry, section) || "?");

    var picture = entryImage(entry, section);
    if (picture) {
        var img = document.createElement("img");
        img.alt = "";
        box.appendChild(img);
        imageInto(img, picture.id, picture.version, size);
    }
    return box;
}

/* -------------------------------------------------------------- stuff */

function sectionInfo(id) {
    for (var i = 0; i < SECTIONS.length; i++)
        if (SECTIONS[i].id === id) return SECTIONS[i];
    return SECTIONS[0];
}

/* Where an entry's picture lives, which is a different pair of fields in each
   of the three shapes. Null when there is none to ask for: a file version of 0
   means every version was deleted, and the proxy would only refuse it. */
function entryImage(entry, section) {
    var kind = sectionInfo(section).kind;

    if (kind === "file")
        return entry.version > 0 ? { id: entry.id, version: entry.version } : null;
    if (kind === "print")
        return entry.file_id ? { id: entry.file_id, version: entry.file_version || 1 } : null;
    return entry.image_file_id
        ? { id: entry.image_file_id, version: entry.image_version || 1 }
        : null;
}

function entryName(entry, section) {
    var kind = sectionInfo(section).kind;
    if (kind === "print") return entry.note || entry.worldName || entry.id;
    return entry.name || entry.id;
}

/* The second line on a card: what the entry is, rather than what it is called.
   Prints say where they were taken, which is the thing that tells two photos
   of the same evening apart. */
function entryDetail(entry, section) {
    var kind = sectionInfo(section).kind;
    if (kind === "file") return (entry.extension || entry.mimeType || "").replace(".", "");
    if (kind === "print") return entry.worldName || "";
    return entry.itemTypeLabel || entry.itemType || "";
}

function findEntry(section, id) {
    var items = content[section].items;
    for (var i = 0; i < items.length; i++)
        if (items[i].id === id) return items[i];
    return null;
}

function hasFlag(item, flag) {
    return (item.flags || []).indexOf(flag) >= 0;
}

/* The slot to equip into. VRChat reports it on the item, but an item that is
   not in a slot right now can come back with it empty, and the type says
   where it would go. */
function itemSlot(item) {
    return item.equipSlot || ITEM_SLOTS[item.itemType] || "";
}

function sectionStatus(section) {
    var held = content[section];
    if (held.loading || (held.fetched === false && contentInFlight[section]))
        return "Loading...";
    if (held.fetched === false) return "";

    var count = held.items.length;
    // The inventory is the only section that reports a total, and vrcd-server
    // stops paging at 500, so the two can disagree.
    if (held.total_count > count) return count + " of " + held.total_count;
    return count + (count === 1 ? " entry" : " entries");
}

/* ------------------------------------------------------------ stuff list */

function renderStuff(body) {
    var section = view.section;
    var info = sectionInfo(section);
    var held = content[section];

    body.appendChild(sectionSwitcher());
    body.appendChild(sectionBar(info, held));
    restorePrintCaret();

    if (held.error) body.appendChild(el("div", "err", held.error));

    var items = held.items.filter(function (entry) {
        return matches(entryName(entry, section)) ||
               matches(entryDetail(entry, section)) ||
               matches(entry.description);
    });

    if (items.length === 0) {
        var why = "Nothing in " + info.label.toLowerCase() + ".";
        if (held.fetched === false || held.loading) why = "Loading...";
        else if (view.filter) why = "Nothing matches that filter.";
        else if (held.error) why = "That section could not be fetched.";
        body.appendChild(placeholder(why));
    } else {
        var grid = el("div", "items");
        items.forEach(function (entry) { grid.appendChild(entryCard(entry, section)); });
        body.appendChild(grid);
    }

    // Only the files sections page, and only when the last page came back
    // full. Everything else arrives whole.
    if (held.more) {
        var more = el("button", "act", "LOAD MORE");
        more.disabled = held.loading || contentInFlight[section] === true;
        more.onclick = function () { loadContent(section, "more"); };
        body.appendChild(more);
    }

    var hint = SECTION_HINTS[section];
    // Said where the limits are said, since the limits are the reason it is
    // worth knowing: a picture the section would have refused is croppable
    // into one it takes, and dropping is the shortest way to that frame.
    if (info.upload)
        hint += " Drop a picture anywhere here to crop it to fit.";
    body.appendChild(el("div", "hint", hint));
}

/* Big enough to hit in a headset, and scrolls sideways on a phone rather than
   wrapping into a second row that pushes the grid off screen. */
function sectionSwitcher() {
    var row = el("div", "chips");
    SECTIONS.forEach(function (section) {
        var chip = el("button", "chip" + (section.id === view.section ? " on" : ""),
            section.label);
        var count = state.content && state.content[section.id];
        if (count && count.loaded && count.count)
            chip.appendChild(el("span", "n", String(count.count)));
        chip.onclick = function () { showSection(section.id); };
        row.appendChild(chip);
    });
    return row;
}

function sectionBar(info, held) {
    var bar = el("div", "bar");
    bar.appendChild(el("div", "count", sectionStatus(info.id)));

    var refresh = el("button", "act small", "REFRESH");
    refresh.disabled = held.loading || contentInFlight[info.id] === true;
    refresh.onclick = function () { loadContent(info.id, "refresh"); };
    bar.appendChild(refresh);

    // The inventory is the one section nothing can be uploaded to: items come
    // from VRChat, not from a file picker.
    if (info.upload) {
        var busy = uploading[info.id] === true;
        var upload = el("button", "act small primary", busy ? "UPLOADING..." : "UPLOAD");
        upload.disabled = busy;
        upload.onclick = function () { pickUpload(info); };
        bar.appendChild(upload);
    }

    // Clearing the icon is not aimed at any one file, so it lives up here
    // rather than in a detail pane. Two taps, since it undoes something the
    // account is wearing.
    if (info.id === "icon") {
        if (armedAction === "clear-icon") {
            bar.appendChild(cancelButton("small"));
            var yes = el("button", "act small", "CONFIRM CLEAR");
            yes.onclick = function () { contentAct("", "set_icon", "", yes); };
            bar.appendChild(yes);
        } else {
            var clear = el("button", "act small", "CLEAR ICON");
            clear.onclick = function () { armedAction = "clear-icon"; renderList(); };
            bar.appendChild(clear);
        }
    }

    if (info.id === "prints") {
        var note = el("input", "note-input");
        note.id = "printNote";
        note.type = "text";
        note.placeholder = "Caption for the next print";
        note.maxLength = 32;
        note.value = printNote;
        // A snapshot arrives every time a friend moves and redraws this bar,
        // so the text lives outside the DOM. Where the caret was is read off
        // the old box just before the redraw drops it (see renderList), not
        // from a blur handler: browsers disagree about whether removing a
        // focused node fires one.
        note.oninput = function (ev) { printNote = ev.target.value; };
        bar.appendChild(note);
    }
    return bar;
}

/* Put the caption box back the way the redraw found it. Called once the bar is
   in the document, since focus does nothing to a detached node. */
function restorePrintCaret() {
    if (printCaret < 0) return;

    var note = document.getElementById("printNote");
    if (note === null) return;

    note.focus();
    note.setSelectionRange(printCaret, printCaret);
}

function entryCard(entry, section) {
    var card = el("button", "item");
    if (view.sel && view.sel.kind === "content" && view.sel.id === entry.id)
        card.classList.add("on");
    card.appendChild(thumb(entry, section, 256));

    var who = el("div", "who");
    who.appendChild(el("div", "n", entryName(entry, section)));
    var detail = entryDetail(entry, section);
    if (detail) who.appendChild(el("div", "t", detail));
    if (entry.equipSlot)
        who.appendChild(el("span", "pill", entry.equipSlot.toUpperCase()));
    card.appendChild(who);

    card.onclick = function () {
        select({ kind: "content", id: entry.id, section: section });
    };
    return card;
}

/* ---------------------------------------------------------- stuff detail */

function detailContent(body, entry, section) {
    var kind = sectionInfo(section).kind;
    document.getElementById("detailTitle").textContent = entryName(entry, section);
    body.appendChild(thumb(entry, section, 512, true));

    if (kind === "item") detailItemBody(body, entry);
    else if (kind === "print") detailPrintBody(body, entry);
    else detailFileBody(body, entry, section);
}

function detailFileBody(body, file, section) {
    var pills = el("div", "pills");
    if (file.extension)
        pills.appendChild(el("span", "pill", file.extension.replace(".", "").toUpperCase()));
    (file.tags || []).forEach(function (tag) {
        pills.appendChild(el("span", "pill", tag.toUpperCase()));
    });
    body.appendChild(pills);

    var kv = el("dl", "kv");
    if (file.name) pair(kv, "Name", file.name);
    if (file.mimeType) pair(kv, "Type", file.mimeType);
    // Zero means every version was deleted, which is why the card shows a
    // gradient rather than the picture.
    if (file.version !== undefined)
        pair(kv, "Version", file.version > 0 ? String(file.version) : "none left");
    pair(kv, "File ID", file.id);
    body.appendChild(kv);

    var actions = el("div", "actions");
    var busy = pendingItems[file.id] === true;

    // VRChat takes a profile icon from the icon tag only, so the button is
    // offered there and nowhere else. It needs VRC+; the server says so if not.
    if (section === "icon") {
        var set = el("button", "act primary", "SET AS PROFILE ICON");
        set.disabled = busy;
        set.onclick = function () { contentAct(file.id, "set_icon", "", set); };
        actions.appendChild(set);
    }

    appendDelete(actions, file.id, "delete_file", busy);
    actions.appendChild(copyButton("Copy file ID", file.id));
    body.appendChild(actions);
}

function detailPrintBody(body, print) {
    if (print.note) body.appendChild(el("div", "blurb", print.note));

    var kv = el("dl", "kv");
    if (print.worldName) pair(kv, "World", print.worldName);
    if (print.authorName) pair(kv, "Author", print.authorName);
    if (print.timestamp) pair(kv, "Taken", whenDate(print.timestamp));
    else if (print.createdAt) pair(kv, "Created", whenDate(print.createdAt));
    pair(kv, "Print ID", print.id);
    body.appendChild(kv);

    var actions = el("div", "actions");
    appendDelete(actions, print.id, "delete_print", pendingItems[print.id] === true);
    actions.appendChild(copyButton("Copy print ID", print.id));
    body.appendChild(actions);
}

function detailItemBody(body, item) {
    var pills = el("div", "pills");
    if (item.itemTypeLabel || item.itemType)
        pills.appendChild(el("span", "pill", (item.itemTypeLabel || item.itemType).toUpperCase()));
    if (item.equipSlot)
        pills.appendChild(el("span", "pill", item.equipSlot.toUpperCase()));
    if (item.isArchived) pills.appendChild(el("span", "pill", "ARCHIVED"));
    (item.flags || []).forEach(function (flag) {
        pills.appendChild(el("span", "pill", flag.toUpperCase()));
    });
    body.appendChild(pills);

    if (item.description) body.appendChild(el("div", "blurb", item.description));

    var kv = el("dl", "kv");
    if (item.itemType) pair(kv, "Type", item.itemType);
    var slot = itemSlot(item);
    if (slot) pair(kv, "Slot", slot);
    if (item.collections && item.collections.length)
        pair(kv, "Collections", item.collections.join(", "));
    if (item.expiryDate) pair(kv, "Expires", whenDate(item.expiryDate));
    pair(kv, "Item ID", item.id);
    body.appendChild(kv);

    body.appendChild(itemActions(item));
}

/* Equip and unequip are both offered whenever the item can be equipped at all,
   rather than guessing which one applies: VRChat reports the slot, not whether
   the item is sitting in it, and both are one reversible tap. */
function itemActions(item) {
    var actions = el("div", "actions");
    var busy = pendingItems[item.id] === true;
    var slot = itemSlot(item);

    if (hasFlag(item, "equippable") && slot) {
        actions.appendChild(actionButton(item.id, "equip", slot, "EQUIP", true, busy));
        actions.appendChild(actionButton(item.id, "unequip", slot, "UNEQUIP", false, busy));
    }

    if (hasFlag(item, "consumable"))
        appendArmed(actions, item.id, "consume", "", "CONSUME", "CONFIRM CONSUME", busy);

    actions.appendChild(copyButton("Copy item ID", item.id));
    return actions;
}

function appendDelete(actions, id, action, busy) {
    appendArmed(actions, id, action, "", "DELETE", "CONFIRM DELETE", busy);
}

/* Two taps, and the second one is not where the first landed: Cancel takes
   that spot, because none of these can be undone. */
function appendArmed(actions, id, action, slot, label, confirmLabel, busy) {
    if (armedAction === action + "|" + id) {
        actions.appendChild(cancelButton(""));
        actions.appendChild(actionButton(id, action, slot, confirmLabel, false, busy));
        return;
    }

    var arm = el("button", "act", label);
    arm.disabled = busy;
    arm.onclick = function () { armedAction = action + "|" + id; renderDetail(); };
    actions.appendChild(arm);
}

function cancelButton(size) {
    var cancel = el("button", "act" + (size ? " " + size : ""), "CANCEL");
    cancel.onclick = function () { armedAction = ""; render(); };
    return cancel;
}

function actionButton(id, action, slot, label, primary, busy) {
    var button = el("button", "act" + (primary ? " primary" : ""), label);
    button.disabled = busy;
    button.onclick = function () { contentAct(id, action, slot, button); };
    return button;
}

/* Dates arrive as ISO 8601 UTC; show them in the viewer's own timezone, and
   fall back to the raw string rather than printing "Invalid Date". */
function whenDate(text) {
    var when = new Date(text);
    return isNaN(when.getTime()) ? text : when.toLocaleString();
}

/* -------------------------------------------------------- stuff actions */

function showSection(section) {
    view.section = section;
    view.sel = null;
    armedAction = "";
    render();

    // On demand, not on connect: each section costs vrcd-server a VRChat call,
    // and most sessions never open most of them.
    if (content[section].fetched === false) loadContent(section, "");
}

function loadContent(section, mode) {
    // A bump that lands mid-fetch would otherwise be lost: the revision is
    // already marked as seen, and this copy is the one before it.
    if (contentInFlight[section]) { contentDirty[section] = true; return; }
    contentInFlight[section] = true;
    contentDirty[section] = false;

    // Reflects the request itself, not the server's: the page has to say it is
    // doing something between the tap and the first reply.
    if (view.tab === "stuff") renderList();

    var query = mode === "refresh" ? "?refresh=1" : (mode === "more" ? "?more=1" : "");
    fetch("/api/content/" + section + query).then(function (r) {
        if (r.status === 401) { location.href = "/login"; return null; }
        return r.json();
    }).then(function (data) {
        if (!data) return;
        data.fetched = true;
        if (!data.items) data.items = [];
        content[section] = data;
        armedAction = "";
    }).catch(function () {
        showToast("Could not reach the vrcd web server", true);
    }).then(function () {
        contentInFlight[section] = false;
        if (view.tab === "stuff") { renderList(); renderDetail(); }
        if (contentDirty[section]) loadContent(section, "");
    });
}

function contentAct(id, action, slot, button) {
    var label = button.textContent;
    // In the map rather than on the button: a snapshot redraws the pane from
    // scratch and would hand back an enabled button otherwise.
    if (id) pendingItems[id] = true;
    armedAction = "";
    button.disabled = true;
    button.textContent = "SENDING...";

    fetch("/api/content", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: action, id: id, slot: slot })
    }).then(function (r) {
        if (r.ok) return;
        delete pendingItems[id];
        showToast("The vrcd web server refused that", true);
        button.disabled = false;
        button.textContent = label;
    }).catch(function () {
        delete pendingItems[id];
        showToast("Could not reach the vrcd web server", true);
        button.disabled = false;
        button.textContent = label;
    });
}

/* ---------------------------------------------------------- stuff upload */

/* Caption for the next print, and where the caret was in it. Both kept out of
   the DOM so a redraw mid-typing does not take them with it; -1 means the box
   does not have focus and should not be given it back. */
var printNote = "";
var printCaret = -1;

/* A picked file does not go straight up. VRChat takes PNG only, at most
   2000x2000, and refuses a sticker or emoji that is not square, so a phone
   photo is three separate rejections away from being accepted. The crop modal
   is where it becomes one of those, which is also why anything the browser can
   decode is allowed in: whatever comes out of the frame leaves as PNG. */
function pickUpload(info) {
    var input = document.createElement("input");
    input.type = "file";
    input.accept = "image/*";
    input.onchange = function () {
        if (input.files && input.files[0]) openCrop(info, input.files[0]);
    };
    input.click();
}

/* Send a picture already known to be PNG and within VRChat's limits: the
   original bytes, straight from the file, no canvas in the way. */
function sendUpload(info, file) {
    var reader = new FileReader();
    reader.onerror = function () { showToast("Could not read that file", true); };
    reader.onload = function () {
        // readAsDataURL gives "data:image/png;base64,...."; the server wants
        // the part after the comma.
        var encoded = String(reader.result);
        var comma = encoded.indexOf(",");
        if (comma < 0) { showToast("Could not read that file", true); return; }
        uploadData(info, encoded.slice(comma + 1));
    };
    reader.readAsDataURL(file);
}

function uploadData(info, base64) {
    // Base64 carries four characters per three bytes, so this is the size the
    // picture will land at without decoding it again to find out.
    if (base64.length * 3 / 4 > UPLOAD_MAX_BYTES) {
        showToast("That picture is over 10 MB. Crop tighter or zoom in.", true);
        return;
    }

    var body = { tag: info.upload, data_base64: base64 };
    if (info.id === "prints" && printNote) body.note = printNote;

    uploading[info.id] = true;
    if (view.tab === "stuff") renderList();

    fetch("/api/upload", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body)
    }).then(function (r) {
        if (r.ok) return;
        uploading[info.id] = false;
        showToast(r.status === 413
            ? "That picture is too large to send"
            : "The vrcd web server refused that upload", true);
        if (view.tab === "stuff") renderList();
    }).catch(function () {
        uploading[info.id] = false;
        showToast("Could not reach the vrcd web server", true);
        if (view.tab === "stuff") renderList();
    });
}

/* ------------------------------------------------------------ crop widget */

/* The frame stays put and the picture moves behind it, rather than a rectangle
   with corner handles dragged over a still picture. Handles are small targets
   by nature, and this page is meant to be usable in a headset: panning the
   whole picture and a zoom slider are both as big as the thing they sit in.

   VRChat's own ceiling. A crop is only ever downscaled to reach it; zooming in
   past a picture's own resolution is allowed on screen but the output stops at
   the pixels that were actually there. */
var CROP_MAX = 2000;

/* How far in the frame will go. Past this a crop is mostly guesswork about
   pixels that were never in the file. */
var CROP_ZOOM_MAX = 8;

/* Frame shapes on offer. Stickers and emoji get none of this - VRChat takes
   them square or not at all - so those sections are locked to SQUARE. */
var CROP_ASPECTS = [
    { id: "orig",  label: "ORIGINAL", ratio: 0 },
    { id: "sq",    label: "SQUARE",   ratio: 1 },
    { id: "wide",  label: "16:9",     ratio: 16 / 9 },
    { id: "photo", label: "4:3",      ratio: 4 / 3 }
];

/* A raw camera file is far bigger than anything that comes out of the frame,
   so the 10 MB ceiling cannot apply going in. This is only here to keep a
   video or a disk image from being decoded as a picture. */
var CROP_SOURCE_MAX_BYTES = 64 * 1024 * 1024;

/* The modal while it is open, null the rest of the time. The picture is held
   as a decoded Image; `cx`/`cy` are the point of it under the middle of the
   frame, in its own pixels, and `zoom` is a multiple of the smallest scale
   that still covers the frame. Everything drawn is derived from those three. */
var crop = null;

function openCrop(info, file) {
    if (file.size > CROP_SOURCE_MAX_BYTES) {
        showToast("That file is too big to open as a picture", true);
        return;
    }

    var url = URL.createObjectURL(file);
    var image = new Image();
    image.onload = function () {
        if (image.naturalWidth < 1 || image.naturalHeight < 1) {
            URL.revokeObjectURL(url);
            showToast("That picture has no pixels in it", true);
            return;
        }
        closeCrop();
        crop = {
            info: info,
            file: file,
            image: image,
            url: url,
            square: info.id === "sticker" || info.id === "emoji",
            aspect: CROP_ASPECTS[0],
            zoom: 1,
            cx: image.naturalWidth / 2,
            cy: image.naturalHeight / 2,
            frameW: 0,
            frameH: 0,
            pointers: {},
            pinch: 0
        };
        if (crop.square) crop.aspect = CROP_ASPECTS[1];
        buildCrop();
    };
    image.onerror = function () {
        URL.revokeObjectURL(url);
        showToast("The browser could not read that picture", true);
    };
    image.src = url;
}

function closeCrop() {
    if (crop === null) return;
    URL.revokeObjectURL(crop.url);
    crop = null;

    var box = document.getElementById("crop");
    box.textContent = "";
    box.classList.add("hidden");
}

function buildCrop() {
    var box = document.getElementById("crop");
    box.textContent = "";

    var card = el("div", "modal-card crop-card");
    var title = el("h2", null, "Crop for " + crop.info.label.toLowerCase());
    title.id = "cropTitle";
    card.appendChild(title);

    card.appendChild(el("div", "why", crop.square
        ? "VRChat takes these square only. Drag to move, pinch or use the " +
          "slider to zoom."
        : "Drag to move, pinch or use the slider to zoom. Whatever fills the " +
          "frame is what goes up."));

    if (crop.square === false) {
        var chips = el("div", "chips");
        CROP_ASPECTS.forEach(function (aspect) {
            var chip = el("button", "chip" + (aspect.id === crop.aspect.id ? " on" : ""),
                aspect.label);
            chip.onclick = function () {
                crop.aspect = aspect;
                // Rebuilt rather than relaid out, so the chips redraw with the
                // new one lit. The frame is measured at the end of that.
                buildCrop();
            };
            chips.appendChild(chip);
        });
        card.appendChild(chips);
    }

    var stage = el("div", "crop-stage");
    crop.canvas = el("canvas", "crop-canvas");
    crop.canvas.onpointerdown = cropDown;
    crop.canvas.onpointermove = cropMove;
    crop.canvas.onpointerup = cropUp;
    crop.canvas.onpointercancel = cropUp;
    crop.canvas.onwheel = cropWheel;
    stage.appendChild(crop.canvas);
    card.appendChild(stage);

    var zoom = el("input", "crop-zoom");
    zoom.type = "range";
    zoom.min = "100";
    zoom.max = String(CROP_ZOOM_MAX * 100);
    zoom.step = "1";
    zoom.value = String(Math.round(crop.zoom * 100));
    zoom.setAttribute("aria-label", "Zoom");
    zoom.oninput = function (ev) {
        crop.zoom = Number(ev.target.value) / 100;
        drawCrop();
    };
    crop.zoomInput = zoom;
    card.appendChild(zoom);

    crop.size = el("div", "crop-size");
    card.appendChild(crop.size);

    var actions = el("div", "actions");
    var send = el("button", "act primary", "UPLOAD");
    send.onclick = commitCrop;
    actions.appendChild(send);

    var cancel = el("button", "act", "CANCEL");
    cancel.onclick = closeCrop;
    actions.appendChild(cancel);
    card.appendChild(actions);

    box.appendChild(card);
    box.classList.remove("hidden");

    // The frame is sized from the card, so it can only be measured once the
    // card is in the document.
    layoutCrop();
}

/* Fit the frame into the card at the chosen shape. Called on open, on an
   aspect change and on a resize; the picture keeps the point it had under the
   middle, so none of the three move what the crop is looking at. */
function layoutCrop() {
    if (crop === null) return;

    var image = crop.image;
    var ratio = crop.aspect.ratio > 0
        ? crop.aspect.ratio
        : image.naturalWidth / image.naturalHeight;

    // The stage's content box, not its border box: clientWidth carries the
    // padding, and a frame sized to that would hang over both edges.
    var stage = crop.canvas.parentNode;
    var pad = window.getComputedStyle(stage);
    var wide = Math.max(80, stage.clientWidth -
        parseFloat(pad.paddingLeft) - parseFloat(pad.paddingRight));
    // Leaves the card's own chrome - title, chips, slider, buttons - on screen
    // on a phone held in landscape, where the height is what runs out first.
    var tall = Math.max(140, Math.min(window.innerHeight * 0.46, 460));

    var w = wide, h = wide / ratio;
    if (h > tall) { h = tall; w = tall * ratio; }

    crop.frameW = Math.max(1, Math.round(w));
    crop.frameH = Math.max(1, Math.round(h));
    crop.canvas.style.width = crop.frameW + "px";
    crop.canvas.style.height = crop.frameH + "px";

    // A device pixel ratio of 1 on a 2x screen is a blurry preview of a sharp
    // crop, which reads as the crop itself being soft.
    var dpr = window.devicePixelRatio || 1;
    crop.canvas.width = Math.round(crop.frameW * dpr);
    crop.canvas.height = Math.round(crop.frameH * dpr);
    crop.dpr = dpr;

    drawCrop();
}

/* Smallest scale at which the picture still covers the frame. Zoom is a
   multiple of it, so 1 always means "as much as the shape allows". */
function cropMinScale() {
    return Math.max(crop.frameW / crop.image.naturalWidth,
                    crop.frameH / crop.image.naturalHeight);
}

/* Keep the frame inside the picture. Called after every pan and zoom, which is
   what makes an empty corner impossible rather than merely unlikely. */
function clampCrop() {
    var scale = cropMinScale() * crop.zoom;
    var halfW = crop.frameW / (2 * scale);
    var halfH = crop.frameH / (2 * scale);
    crop.cx = Math.min(Math.max(crop.cx, halfW), crop.image.naturalWidth - halfW);
    crop.cy = Math.min(Math.max(crop.cy, halfH), crop.image.naturalHeight - halfH);
    return scale;
}

function drawCrop() {
    if (crop === null || crop.canvas === undefined) return;

    // A pinch can push past either end, and the slider only holds the values
    // it was given itself.
    crop.zoom = Math.min(Math.max(crop.zoom, 1), CROP_ZOOM_MAX);
    var scale = clampCrop();
    var ctx = crop.canvas.getContext("2d");

    ctx.setTransform(crop.dpr, 0, 0, crop.dpr, 0, 0);
    ctx.clearRect(0, 0, crop.frameW, crop.frameH);
    ctx.imageSmoothingQuality = "high";
    ctx.drawImage(crop.image,
        crop.frameW / 2 - crop.cx * scale, crop.frameH / 2 - crop.cy * scale,
        crop.image.naturalWidth * scale, crop.image.naturalHeight * scale);

    // Thirds, drawn over the picture rather than beside it: the frame is the
    // only place the composition can be judged.
    ctx.strokeStyle = "rgba(255, 255, 255, .28)";
    ctx.lineWidth = 1;
    ctx.beginPath();
    for (var i = 1; i < 3; i++) {
        var x = Math.round(crop.frameW * i / 3) + 0.5;
        var y = Math.round(crop.frameH * i / 3) + 0.5;
        ctx.moveTo(x, 0); ctx.lineTo(x, crop.frameH);
        ctx.moveTo(0, y); ctx.lineTo(crop.frameW, y);
    }
    ctx.stroke();

    if (crop.zoomInput) crop.zoomInput.value = String(Math.round(crop.zoom * 100));

    var out = cropOutput(scale);
    crop.size.textContent = out.w + " x " + out.h + " PNG" +
        (out.whole ? ", the whole picture" : "");
}

/* What the upload will be: the frame in the picture's own pixels, never
   upscaled past them and never past VRChat's 2000. */
function cropOutput(scale) {
    var full = { w: crop.image.naturalWidth, h: crop.image.naturalHeight };
    var sw = Math.min(crop.frameW / scale, full.w);
    var sh = Math.min(crop.frameH / scale, full.h);
    // The clamp keeps the frame inside the picture to within rounding; this
    // takes the rounding, since drawImage answers a source rectangle that
    // hangs a hair over the edge with a transparent strip.
    var sx = Math.min(Math.max(crop.cx - sw / 2, 0), full.w - sw);
    var sy = Math.min(Math.max(crop.cy - sh / 2, 0), full.h - sh);

    var w = sw, h = sh;
    if (w > CROP_MAX || h > CROP_MAX) {
        var shrink = Math.min(CROP_MAX / w, CROP_MAX / h);
        w *= shrink;
        h *= shrink;
    }
    w = Math.max(1, Math.round(w));
    h = Math.max(1, Math.round(h));
    // Rounding two sides separately is how a square crop arrives one pixel off
    // square, which VRChat refuses.
    if (crop.aspect.ratio === 1) h = w;

    return {
        sx: sx, sy: sy, sw: sw, sh: sh, w: w, h: h,
        whole: sw >= full.w - 0.5 && sh >= full.h - 0.5
    };
}

function commitCrop() {
    if (crop === null) return;

    var info = crop.info;
    var out = cropOutput(clampCrop());

    // Nothing was asked of it and VRChat would have taken it as it stands, so
    // send the file itself. Re-encoding here would cost quality and size for
    // a crop that is not a crop.
    if (out.whole && crop.file.type === "image/png" &&
        crop.image.naturalWidth <= CROP_MAX && crop.image.naturalHeight <= CROP_MAX &&
        (crop.square === false || crop.image.naturalWidth === crop.image.naturalHeight)) {
        var file = crop.file;
        closeCrop();
        sendUpload(info, file);
        return;
    }

    var canvas = document.createElement("canvas");
    canvas.width = out.w;
    canvas.height = out.h;

    var ctx = canvas.getContext("2d");
    ctx.imageSmoothingQuality = "high";
    ctx.drawImage(crop.image, out.sx, out.sy, out.sw, out.sh, 0, 0, out.w, out.h);

    var encoded;
    try {
        encoded = canvas.toDataURL("image/png");
    } catch (err) {
        // A picture from another origin would taint the canvas. Ours never is,
        // since it came off the local file picker, but a failure here is silent
        // otherwise.
        showToast("The browser would not encode that crop", true);
        return;
    }

    closeCrop();
    var comma = encoded.indexOf(",");
    if (comma < 0) { showToast("The browser would not encode that crop", true); return; }
    uploadData(info, encoded.slice(comma + 1));
}

/* Pan with one pointer, pinch with two. Pointer events cover mouse, touch and
   pen at once, and capture keeps a drag alive when it leaves the frame.

   Each of these checks the modal is still up: Escape during a drag tears the
   canvas out from under a captured pointer, and the release still arrives. */
function cropDown(ev) {
    if (crop === null) return;
    ev.preventDefault();
    crop.canvas.setPointerCapture(ev.pointerId);
    crop.pointers[ev.pointerId] = { x: ev.clientX, y: ev.clientY };
    crop.pinch = pinchSpan();
}

function cropMove(ev) {
    if (crop === null) return;
    var held = crop.pointers[ev.pointerId];
    if (held === undefined) return;
    ev.preventDefault();

    var ids = Object.keys(crop.pointers);
    var scale = cropMinScale() * crop.zoom;

    if (ids.length === 1) {
        crop.cx -= (ev.clientX - held.x) / scale;
        crop.cy -= (ev.clientY - held.y) / scale;
    }
    held.x = ev.clientX;
    held.y = ev.clientY;

    if (ids.length > 1) {
        var span = pinchSpan();
        if (crop.pinch > 0 && span > 0) crop.zoom *= span / crop.pinch;
        crop.pinch = span;
    }
    drawCrop();
}

function cropUp(ev) {
    if (crop === null) return;
    delete crop.pointers[ev.pointerId];
    // Whichever finger is left starts a fresh span, or the next move jumps by
    // the distance between the two.
    crop.pinch = pinchSpan();
}

function pinchSpan() {
    var ids = Object.keys(crop.pointers);
    if (ids.length < 2) return 0;
    var a = crop.pointers[ids[0]], b = crop.pointers[ids[1]];
    return Math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
}

function cropWheel(ev) {
    if (crop === null) return;
    ev.preventDefault();
    // Zoom about the pointer, so the pixel under the cursor stays under it.
    var box = crop.canvas.getBoundingClientRect();
    var scale = cropMinScale() * crop.zoom;
    var atX = crop.cx + (ev.clientX - box.left - crop.frameW / 2) / scale;
    var atY = crop.cy + (ev.clientY - box.top - crop.frameH / 2) / scale;

    var step = Math.exp(-ev.deltaY / 400);
    var was = crop.zoom;
    crop.zoom = Math.min(Math.max(crop.zoom * step, 1), CROP_ZOOM_MAX);

    var moved = crop.zoom / was;
    crop.cx = atX + (crop.cx - atX) / moved;
    crop.cy = atY + (crop.cy - atY) / moved;
    drawCrop();
}

/* --------------------------------------------------------- drag and drop */

/* A file dragged onto the window is the other way into the crop modal. The
   whole window is the target rather than the grid: a drop that lands two
   pixels outside a zone is a page navigation away from losing the session,
   so every drop is caught and answered, even the ones that cannot be used. */
function watchDrops() {
    var hint = document.getElementById("drop");
    var depth = 0;
    var idle = 0;

    function dragging(ev) {
        var kinds = ev.dataTransfer && ev.dataTransfer.types;
        return kinds && Array.prototype.indexOf.call(kinds, "Files") >= 0;
    }

    function show() {
        hint.textContent = dropTarget().hint;
        hint.classList.remove("hidden");
        // Browsers disagree about the last dragleave when a drag goes out of
        // the window or ends over another application, and an overlay stuck
        // over the whole page is not a recoverable state. dragover repeats
        // while the file is over us, so a gap in those takes it down whatever
        // the counting says. Hiding early costs nothing: the drop handler does
        // not read this.
        clearTimeout(idle);
        idle = setTimeout(hide, 1200);
    }

    function hide() {
        clearTimeout(idle);
        depth = 0;
        hint.classList.add("hidden");
    }

    document.addEventListener("dragenter", function (ev) {
        if (dragging(ev) === false) return;
        ev.preventDefault();
        depth++;
        show();
    });
    document.addEventListener("dragover", function (ev) {
        if (dragging(ev) === false) return;
        // Without this the browser takes the drop and opens the file, which
        // navigates away from the page.
        ev.preventDefault();
        ev.dataTransfer.dropEffect = dropTarget().info ? "copy" : "none";
        show();
    });
    document.addEventListener("dragleave", function (ev) {
        if (dragging(ev) === false) return;
        // Dragging over a child fires leave on the parent, so this counts
        // rather than hides on the first one.
        depth = Math.max(0, depth - 1);
        if (depth === 0) hide();
    });
    document.addEventListener("dragend", hide);
    document.addEventListener("drop", function (ev) {
        if (dragging(ev) === false) return;
        ev.preventDefault();
        hide();

        var target = dropTarget();
        if (target.info === null) { showToast(target.hint, true); return; }

        var files = ev.dataTransfer.files;
        if (files.length === 0) return;
        if (files.length > 1)
            showToast("One at a time - taking the first", false);
        openCrop(target.info, files[0]);
    });
}

/* Where a drop would land right now, and what to say about it. A section has
   to be open for a drop to mean anything: the picture is going somewhere
   specific, and guessing which is worse than saying so. */
function dropTarget() {
    if (view.tab !== "stuff")
        return { info: null, hint: "Open STUFF to upload a picture" };

    var info = sectionInfo(view.section);
    if (info.upload === undefined)
        return { info: null, hint: "Items come from VRChat, not from a file" };
    if (uploading[info.id] === true)
        return { info: null, hint: "That section already has an upload going" };

    return { info: info, hint: "Drop to crop and upload to " + info.label };
}

/* One profile layout, two callers: your own on the profile tab and a friend in
   the detail pane. Rows appear only when the field is there, which is what
   keeps the two honest - a friend entry is a thinner record than self, not a
   different kind of thing. */
function renderProfile(body, person, opts) {
    var hero = el("div", "hero");
    hero.appendChild(avatar(person.displayName, true));
    hero.appendChild(el("div", "name", person.displayName));
    var sub = el("div", "sub");
    sub.appendChild(statusDot(person.status));
    sub.appendChild(document.createTextNode(" " + (person.statusDescription || person.status)));
    hero.appendChild(sub);
    body.appendChild(hero);

    var kv = el("dl", "kv");
    pair(kv, "Status", person.status || "unknown");
    if (person.platform)
        pair(kv, "Platform", PLATFORMS[person.platform] || person.platform);
    if (person.pronouns) pair(kv, "Pronouns", person.pronouns);
    if (opts.where) pair(kv, "Where", opts.where);
    // Friend entries carry no bio or links: the roster broadcast leaves them
    // out on purpose, so these two rows only fill in for self.
    if (person.bio) pair(kv, "Bio", person.bio);
    pair(kv, "User ID", person.id);
    body.appendChild(kv);

    if (person.bioLinks && person.bioLinks.length) {
        body.appendChild(el("div", "section", "Links"));
        var links = el("dl", "kv");
        person.bioLinks.forEach(function (url, index) {
            var dd = el("dd");
            var a = el("a", null, url);
            a.href = url;
            a.rel = "noopener noreferrer";
            a.target = "_blank";
            dd.appendChild(a);
            links.appendChild(el("dt", null, "#" + (index + 1)));
            links.appendChild(dd);
        });
        body.appendChild(links);
    }

    var actions = el("div", "actions");
    if (opts.location) actions.appendChild(joinButton(opts.location, "SELF-INVITE"));
    actions.appendChild(copyButton("Copy user ID", person.id));
    body.appendChild(actions);
}

function renderProfileTab(body) {
    if (state.self)
        renderProfile(body, state.self, {});
    else
        body.appendChild(placeholder("Not signed in to VRChat yet."));

    body.appendChild(el("div", "section", "Connection"));
    var conn = el("dl", "kv");
    pair(conn, "vrcd", state.connected ? "connected" : "disconnected");
    pair(conn, "Protocol", state.server_version ? "v" + state.server_version : "unknown");
    pair(conn, "VRChat", state.vrchat_connected ? "connected" : "disconnected");
    if (state.last_error) pair(conn, "Last error", state.last_error);
    body.appendChild(conn);
}

function pair(list, key, value) {
    list.appendChild(el("dt", null, key));
    list.appendChild(el("dd", null, value));
}

function placeholder(text, title) {
    var box = el("div", "placeholder");
    if (title) box.appendChild(el("b", null, title));
    box.appendChild(document.createTextNode(text));
    return box;
}

function renderList() {
    var tab = tabInfo(view.tab);
    var body = document.getElementById("listBody");
    var search = document.getElementById("search");

    // Read off the print caption box before the redraw drops it, so the caret
    // can be put back where the typing was. -1 means it did not have focus and
    // must not be given it.
    var note = document.getElementById("printNote");
    printCaret = note && document.activeElement === note ? note.selectionStart : -1;

    body.textContent = "";
    document.getElementById("listTitle").textContent = TITLES[tab.id];
    document.title = "vrcd - " + TITLES[tab.id];

    // Nothing to filter means no header at all, rather than a bar that only
    // repeats the tab you just pressed.
    document.getElementById("listHead").classList.toggle("hidden", tab.search === undefined);
    body.classList.toggle("top-pad", tab.search === undefined);
    if (tab.search) search.placeholder = PLACEHOLDERS[tab.id];

    if (tab.id === "online")       renderOnline(body);
    else if (tab.id === "feed")    renderFeed(body);
    else if (tab.id === "inbox")   renderInbox(body);
    else if (tab.id === "stuff")   renderStuff(body);
    else if (tab.id === "profile") renderProfileTab(body);
    else body.appendChild(placeholder(SOON_TEXT[tab.id], "Not wired up yet"));
}

/* --------------------------------------------------------- detail pane */

function detailInstance(body, group) {
    var name = groupName(group);
    var isPrivate = group.instance_id === "private";
    var meta = parseLocation(group.location);
    document.getElementById("detailTitle").textContent = name;

    var shot = el("div", "shot");
    shot.style.background = isPrivate
        ? "linear-gradient(140deg, #2a2a36, #1b1b24)"
        : shotBackground(name);
    shot.appendChild(el("div", "world", name));
    body.appendChild(shot);

    var pills = el("div", "pills");
    if (isPrivate) {
        pills.appendChild(el("span", "pill", "PRIVATE"));
    } else {
        pills.appendChild(el("span", "pill", meta.type.toUpperCase()));
        if (meta.region) pills.appendChild(el("span", "pill", meta.region.toUpperCase()));
        if (group.n_users >= 0 && group.capacity > 0) {
            var full = group.n_users >= group.capacity;
            pills.appendChild(el("span", "pill" + (full ? " full" : ""),
                group.n_users + " / " + group.capacity));
        }
    }
    body.appendChild(pills);

    var kv = el("dl", "kv");
    pair(kv, "Friends", String(group.friends.length));
    if (group.location) pair(kv, "Location", group.location);
    body.appendChild(kv);

    var list = el("div", "flat");
    group.friends.forEach(function (f) { list.appendChild(friendRow(f)); });
    body.appendChild(list);

    var actions = el("div", "actions");
    if (isPrivate || !group.location) {
        var none = el("button", "act", "No joinable location");
        none.disabled = true;
        actions.appendChild(none);
    } else {
        actions.appendChild(joinButton(group.location, "SELF-INVITE"));
        actions.appendChild(copyButton("Copy location", group.location));
    }
    body.appendChild(actions);
}

function detailFriend(body, friend, group) {
    document.getElementById("detailTitle").textContent = friend.displayName;
    renderProfile(body, friend, {
        where: group
            ? groupName(group)
            : (friend.status === "offline" ? "offline" : "not in a world"),
        location: group ? group.location : ""
    });
}

function joinButton(location, label) {
    var button = el("button", "act primary", label);
    button.onclick = function () { join(location, button); };
    return button;
}

function copyButton(label, text) {
    var button = el("button", "act", label);
    button.onclick = function () {
        // Only available on a secure origin; fall back to showing the value
        // so it can still be selected by hand.
        if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(text).then(function () {
                showToast("Copied", false);
            }).catch(function () {
                showToast(text, false);
            });
            return;
        }
        showToast(text, false);
    };
    return button;
}

function renderDetail() {
    var body = document.getElementById("detailBody");
    var title = document.getElementById("detailTitle");
    body.textContent = "";
    title.textContent = "Details";

    if (view.sel === null) {
        var nothing = "Pick a world or a friend.";
        if (view.tab === "inbox") nothing = "Pick a sender you are already friends with.";
        else if (view.tab === "stuff") nothing = "Pick something.";
        body.appendChild(placeholder(nothing));
        return;
    }

    if (view.sel.kind === "content") {
        var entry = findEntry(view.sel.section, view.sel.id);
        if (entry) detailContent(body, entry, view.sel.section);
        // Deleting or consuming is how something leaves the list while it is
        // still on screen.
        else body.appendChild(placeholder("That is no longer there."));
        return;
    }

    if (view.sel.kind === "instance") {
        var group = findGroup(view.sel.id);
        if (group) detailInstance(body, group);
        else body.appendChild(placeholder("That instance is gone."));
        return;
    }

    if (view.sel.kind === "friend") {
        var hit = findFriend(view.sel.id);
        if (hit) detailFriend(body, hit.friend, hit.group);
        else body.appendChild(placeholder("That friend is no longer in the roster."));
    }
}

/* ------------------------------------------------------------- actions */

function render() {
    renderRail();
    renderList();
    renderDetail();
    renderSignin();
}

function select(sel) {
    view.sel = sel;
    document.getElementById("shell").dataset.pane = "detail";
    render();
}

function showList() {
    document.getElementById("shell").dataset.pane = "list";
}

function showTab(tab) {
    view.tab = tab;
    view.sel = null;
    // The box is hidden on tabs that cannot filter, so a leftover term would
    // silently cut the next list down.
    view.filter = "";
    armedAction = "";
    document.getElementById("search").value = "";
    showList();
    render();

    // On demand, not on connect: each section costs vrcd-server a VRChat call,
    // and most sessions never open this tab.
    if (tab === "stuff" && content[view.section].fetched === false)
        loadContent(view.section, "");
}

var toastTimer = null;
function showToast(message, bad) {
    var toast = document.getElementById("toast");
    toast.textContent = message;
    toast.classList.remove("hidden");
    toast.classList.toggle("bad", !!bad);
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { toast.classList.add("hidden"); }, 6000);
}

function join(location, button) {
    var label = button.textContent;
    button.disabled = true;
    button.textContent = "SENDING...";
    fetch("/api/join", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ location: location })
    }).then(function () {
        showToast("Self-invite requested...", false);
    }).catch(function () {
        showToast("Could not reach the vrcd web server", true);
    }).then(function () {
        button.disabled = false;
        button.textContent = label;
    });
}

function notifyAct(id, action, button) {
    var label = button.textContent;
    // Marked in the map rather than on the button: the next snapshot redraws
    // the card from scratch and would hand back an enabled button otherwise.
    pendingNotifications[id] = true;
    button.disabled = true;
    button.textContent = "SENDING...";

    fetch("/api/notification", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ notification_id: id, action: action })
    }).then(function (r) {
        if (r.ok) return;
        delete pendingNotifications[id];
        showToast("The vrcd web server refused that", true);
        button.disabled = false;
        button.textContent = label;
    }).catch(function () {
        delete pendingNotifications[id];
        showToast("Could not reach the vrcd web server", true);
        button.disabled = false;
        button.textContent = label;
    });
}

/* --------------------------------------------------------- vrchat sign-in */

/* vrcd-server holds the VRChat session. When it runs headless and needs
   credentials or a 2FA code it asks whichever front-end is connected - this
   page or the SDL client - and the first answer wins. The prompt arrives in
   the snapshot as `auth` and leaves it the moment anyone answers, so the modal
   is driven by that key alone and closes on every browser at once.

   The card is rebuilt only when the prompt itself changes. A snapshot arrives
   every time a friend moves, and redrawing on one of those would take the
   half-typed password with it. */
var signinKey = "";

function renderSignin() {
    var box = document.getElementById("signin");
    var ask = state.auth;

    if (!ask) {
        box.textContent = "";
        box.classList.add("hidden");
        // Cleared, so a repeat of the same prompt (the same wrong code twice)
        // still counts as a change and draws a fresh card.
        signinKey = "";
        return;
    }

    var key = ask.kind + "|" + ask.method + "|" + ask.error;
    if (key === signinKey) return;
    signinKey = key;

    box.textContent = "";
    box.appendChild(signinCard(ask));
    box.classList.remove("hidden");

    var first = box.querySelector("input");
    if (first) first.focus();
}

function signinCard(ask) {
    var twoFactor = ask.kind === "two_factor";

    // A form, so Enter submits and the browser can offer to fill and to save.
    var card = el("form", "modal-card");
    var title = el("h2", null, twoFactor ? "Two-factor code" : "Sign in to VRChat");
    title.id = "signinTitle";
    card.appendChild(title);

    card.appendChild(el("div", "why", twoFactor
        ? (TWOFA_TEXT[ask.method] || "vrcd-server needs a two-factor code.")
        : "vrcd-server is signing in to VRChat and needs the account's " +
          "credentials. They are passed straight through to VRChat and are " +
          "not stored here."));

    if (ask.error) card.appendChild(el("div", "err", ask.error));

    var code, user, pass;
    if (twoFactor) {
        code = signinField(card, "Code", { name: "code",
            autocomplete: "one-time-code", inputmode: "numeric", maxlength: 16 });
    } else {
        user = signinField(card, "Username or email", { name: "username",
            autocomplete: "username" });
        pass = signinField(card, "Password", { name: "password",
            type: "password", autocomplete: "current-password" });
    }

    var actions = el("div", "actions");
    var submit = el("button", "act primary", twoFactor ? "SUBMIT" : "SIGN IN");
    submit.type = "submit";
    actions.appendChild(submit);

    // Cancel is an answer too: the server stops waiting, and a headless one
    // gives up on the sign-in entirely.
    var cancel = el("button", "act", "CANCEL");
    cancel.type = "button";
    cancel.onclick = function () { sendSignin({ action: "cancel" }, card); };
    actions.appendChild(cancel);
    card.appendChild(actions);

    card.onsubmit = function (ev) {
        ev.preventDefault();
        if (twoFactor) {
            sendSignin({ action: "two_factor", code: code.value.trim() }, card);
            return;
        }
        // The password is passed as typed; only the username is trimmed, since
        // trailing spaces are legal in one and a slip in the other.
        sendSignin({ action: "credentials",
            username: user.value.trim(), password: pass.value }, card);
    };
    return card;
}

function signinField(card, label, opts) {
    var id = "signin-" + opts.name;
    var tag = el("label", null, label);
    tag.htmlFor = id;
    card.appendChild(tag);

    var input = el("input");
    input.id = id;
    input.name = opts.name;
    input.type = opts.type || "text";
    input.autocomplete = opts.autocomplete;
    input.required = true;
    if (opts.inputmode) input.inputMode = opts.inputmode;
    if (opts.maxlength) input.maxLength = opts.maxlength;
    card.appendChild(input);
    return input;
}

/* Not fire and forget, unlike a join: there is no result message for a
   sign-in, so this reply is all the page hears. On success the modal goes when
   the next snapshot arrives without `auth`. */
function sendSignin(body, card) {
    var buttons = card.querySelectorAll("button");
    function enable(on) {
        for (var i = 0; i < buttons.length; i++) buttons[i].disabled = !on;
    }
    enable(false);

    fetch("/api/auth", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body)
    }).then(function (r) {
        if (r.ok) {
            showToast(body.action === "cancel"
                ? "Sign-in cancelled" : "Sent to vrcd-server", false);
            return;
        }
        showToast(r.status === 503
            ? "No link to vrcd-server right now"
            : "The vrcd web server refused that", true);
        enable(true);
    }).catch(function () {
        showToast("Could not reach the vrcd web server", true);
        enable(true);
    });
}

/* --------------------------------------------------------------- state */

function applyState(message) {
    state = message;
    if (!state.roster)
        state.roster = { instances: [], active_elsewhere: [], offline: [] };
    if (!state.notifications)
        state.notifications = [];

    // A notification that left the snapshot is answered, however it was
    // answered: by us, by another client, or by VRChat itself. Pruned before
    // the draw so the row never comes back wearing "SENDING...".
    Object.keys(pendingNotifications).forEach(function (id) {
        var stillThere = state.notifications.some(function (e) { return e.id === id; });
        if (stillThere === false) delete pendingNotifications[id];
    });

    render();
    reportJoin();
    reportNotifyAction();
    reportContentAction();
    syncContent();
}

/* The snapshot carries only that a section moved, not its entries. A bump
   means something changed it: our own action, an in-game upload, another
   client. Nothing is fetched for a section that has never been opened. */
function syncContent() {
    if (!state.content) return;

    // A link that went down takes every pending answer with it, and a button
    // stuck on "SENDING..." or "UPLOADING..." is worse than one that can be
    // pressed again: the answer it was waiting for is never coming.
    if (state.connected === false) {
        pendingItems = {};
        uploading = {};
    }

    SECTIONS.forEach(function (section) {
        var meta = state.content[section.id];
        if (!meta || meta.revision === contentRevisions[section.id]) return;
        contentRevisions[section.id] = meta.revision;

        if (content[section.id].fetched ||
            (view.tab === "stuff" && view.section === section.id))
            loadContent(section.id, "");
    });
}

function reportContentAction() {
    var result = state.content_action;
    if (!result || !result.attempted) return;

    // Same as the join and notification results: the snapshot carries the last
    // one indefinitely, so only say something when it actually changed.
    var key = result.id + "|" + result.action + "|" +
        result.success + "|" + result.error;
    if (key === lastActionKey) return;
    lastActionKey = key;

    delete pendingItems[result.id];
    armedAction = "";
    // An upload finishing is what takes the button out of "UPLOADING...", and
    // the tag it went to is what the result carries as its id.
    uploading[result.id === "print" ? "prints" : result.id] = false;
    if (view.tab === "stuff") { renderList(); renderDetail(); }

    if (result.success) {
        // The caption belonged to the print that just went up, not to the next
        // one, which would otherwise inherit it silently.
        if (result.action === "upload_print") printNote = "";
        showToast(ACTION_DONE[result.action] || "Done", false);
        return;
    }
    showToast("That failed: " + result.error, true);
}

function reportNotifyAction() {
    var result = state.notify_action;
    if (!result || !result.attempted) return;

    // Like the join result, the snapshot carries this indefinitely, so only
    // say something when it actually changed.
    var key = result.notification_id + "|" + result.action + "|" +
        result.success + "|" + result.error;
    if (key === lastNotifyKey) return;
    lastNotifyKey = key;

    if (result.success) {
        showToast(result.action === "accept" ? "Accepted" : "Dismissed", false);
        return;
    }

    // A failure leaves the row where it was, so give its buttons back.
    delete pendingNotifications[result.notification_id];
    if (view.tab === "inbox") renderList();
    showToast("Could not " + result.action + " that: " + result.error, true);
}

function reportJoin() {
    var join = state.join;
    if (!join || !join.attempted) return;

    // The snapshot carries the last result indefinitely; only surface it when
    // it actually changed, so a reconnect does not replay an old toast.
    var key = join.location + "|" + join.success + "|" + join.error;
    if (key === lastJoinKey) return;
    lastJoinKey = key;

    showToast(join.success
        ? "Invite sent, check VRChat"
        : "Self-invite failed: " + join.error, !join.success);
}

function applyFeed(message) {
    if (message.reset)
        feed = message.events;
    else
        feed = feed.concat(message.events);

    if (feed.length > FEED_MAX)
        feed = feed.slice(feed.length - FEED_MAX);

    if (view.tab === "feed")
        renderList();
}

function connect() {
    // The socket cannot carry the session cookie into ddhttpd's upgrade, so
    // trade the cookie for a short-lived single-use ticket first.
    fetch("/api/wsticket").then(function (r) {
        if (r.status === 401) { location.href = "/login"; return null; }
        return r.json();
    }).then(function (data) {
        if (!data) return;
        openSocket(data.ticket);
    }).catch(function () {
        setTimeout(connect, 3000);
    });
}

function openSocket(ticket) {
    var proto = location.protocol === "https:" ? "wss://" : "ws://";
    var socket = new WebSocket(proto + location.host + "/ws/" + ticket);

    socket.onmessage = function (ev) {
        var message = JSON.parse(ev.data);
        if (message.type === "feed")
            applyFeed(message);
        else
            applyState(message);
    };
    socket.onclose = function () {
        state.connected = false;
        state.last_error = "web server unreachable, retrying...";
        renderRail();
        setTimeout(connect, 3000);
    };
}

document.getElementById("search").oninput = function (ev) {
    view.filter = ev.target.value.trim().toLowerCase();
    renderList();
};

/* Escape leaves the crop modal but not the sign-in one: the server is blocked
   waiting on that answer, and a stray key is not one. */
document.addEventListener("keydown", function (ev) {
    if (ev.key === "Escape" && crop) closeCrop();
});

window.addEventListener("resize", layoutCrop);

watchDrops();
render();
connect();
