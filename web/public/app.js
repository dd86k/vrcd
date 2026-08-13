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

/* The four statuses VRChat lets you set, in the order it offers them. Offline
   is in STATUS_COLORS but not here: it is a state, not a choice. */
var STATUS_CHOICES = [
    { value: "join me", label: "Join Me" },
    { value: "active",  label: "Active" },
    { value: "ask me",  label: "Ask Me" },
    { value: "busy",    label: "Busy" }
];

/* VRChat counts characters, not bytes, and cuts a longer message off. Matched
   on the box so the limit is visible while typing rather than after saving. */
var STATUS_MESSAGE_MAX = 32;

/* The same for the profile editor's fields. vrcd-server checks all four again,
   being the side that answers to VRChat and the side a second front-end also
   goes through; here they only keep a box from taking a character that would
   come back refused. */
var BIO_MAX = 512;
var PRONOUNS_MAX = 32;
var LINKS_MAX = 3;
var LANGUAGES_MAX = 3;

var PLATFORMS = {
    "standalonewindows": "PC",
    "android": "Quest",
    "ios": "iOS",
    "nativemobile": "Mobile",
    "web": "Web"
};

/* Tabs the rail offers. */
var TABS = [
    { id: "feed",     label: "FEED",     icon: "i-feed",    search: true },
    { id: "online",   label: "ONLINE",   icon: "i-online",  search: true },
    { id: "inbox",    label: "INBOX",    icon: "i-inbox",   badge: true },
    { id: "stuff",    label: "STUFF",    icon: "i-stuff",   search: true },
    { id: "tools",    label: "TOOLS",    icon: "i-tools",   search: true },
    /* The rail opens the profile through the self card at its foot, so only
       the bottom bar, which has no foot, draws a button for it. */
    { id: "profile",  label: "PROFILE",  icon: "i-profile", foot: true }
];

/* What each v1 notification type is called, and what can be done about it.
   `accept` is VRChat's accept endpoint, which only means anything for a
   friend request. An invite is answered by joining where it points, and a
   request for an invite cannot be answered at all from here: sending one back
   needs an API vrcd-server does not expose yet, so the row says so rather
   than drawing a button that would lie.

   Only v1 needs this table. A v2 notification - group invites, join
   requests, announcements, queue-ready, instance closures, moderation -
   carries its own buttons in `responses`, so those rows are drawn from the
   data and a type nobody here has heard of still works. Anything not listed
   and not carrying responses gets a dismiss and its type as the label. */
var NOTIFY_TYPES = {
    friendRequest: { label: "Friend request", accept: "ACCEPT", hide: "DECLINE" },
    invite:        { label: "Invite",         join: true,       hide: "DISMISS" },
    requestInvite: { label: "Invite request", hide: "DISMISS",
                     note: "Sending an invite back needs an API the server " +
                           "does not expose yet." },
    inviteResponse:        { label: "Invite response",  hide: "DISMISS" },
    requestInviteResponse: { label: "Request response", hide: "DISMISS" },
    boop:                  { label: "Boop",             hide: "DISMISS" },
    message:               { label: "Message",          hide: "DISMISS" },
    votetokick:            { label: "Vote to kick",     hide: "DISMISS" }
};

/* Which response types read as the affirmative one, so the row can give that
   button the primary treatment. Everything else draws plain, and a response
   type nobody listed here still draws - just not emphasised. */
var NOTIFY_PRIMARY = { accept: true, join: true, confirm: true, yes: true };

/* VRChat writes a v2 response's `text` as a sentence describing the action -
   "Acknowledge and dismiss this notification", "Unsubscribe from this group's
   event announcements". That is a caption, not a button, and on a phone it
   wraps to three lines each. The response *type* is the action, so it names
   the button; the full sentence goes in the tooltip where it costs nothing.

   The table is only for types worth wording differently from their own name
   (delete reads as DISMISS everywhere else on this page). Everything else
   falls through to the type, which uppercases into a perfectly good label -
   including types this build has never heard of. */
var NOTIFY_RESPONSE_LABELS = {
    "delete": "DISMISS",
    reject: "DECLINE",
    deny: "DECLINE"
};

/* Response types that already do what the card's own dismiss button would.
   VRChat sends one of these on the rows that have nothing to accept - a group
   post, a group join request - and drawing the card's dismiss beside it put
   two trash cans in the same row. VRChat's own wins: it is the button VRChat
   named, and it carries whatever `data` goes back with it.

   Mirrors `responseDismisses` in the SDL client. */
var NOTIFY_DISMISS_TYPES = { "delete": true, acknowledge: true };

/* hasOwnProperty because the type comes off the wire. */
function responseDismisses(response) {
    return NOTIFY_DISMISS_TYPES.hasOwnProperty(response.type);
}

/* A button's worth of text: short enough not to wrap in a row of them. */
var NOTIFY_LABEL_MAX = 14;

function responseLabel(response) {
    // hasOwnProperty because the type comes off the wire, and "constructor"
    // would otherwise hand back a function to use as a label.
    if (NOTIFY_RESPONSE_LABELS.hasOwnProperty(response.type))
        return NOTIFY_RESPONSE_LABELS[response.type];

    /* VRChat's own text when it is already button-sized ("Join", "View
       Group"): it is the more specific of the two, and a type like "link"
       says less than the label VRChat gave it. */
    var text = (response.text || "").trim();
    if (text && text.length <= NOTIFY_LABEL_MAX) return text.toUpperCase();

    if (response.type) return notifyLabel(response.type).toUpperCase();
    return text ? text.split(/\s+/)[0].toUpperCase() : "RESPOND";
}

/* What to say once one went through. Keyed by the action, not the response:
   which button of a group invite was pressed is the server's business. */
var NOTIFY_DONE = { accept: "Accepted", hide: "Dismissed", respond: "Answered" };

/* The picture on a v2 response's button, by response type. The type is the
   action - it is what gets posted back - so it picks the icon, the same way
   responseLabel words the button from it. Mirrors `responseIcon` in the SDL
   client (client/source/client/ui.d), so both front-ends draw one action the
   same way. */
var NOTIFY_ICONS = {
    accept: "i-check", confirm: "i-check", yes: "i-check",
    decline: "i-x", reject: "i-x", deny: "i-x", no: "i-x", cancel: "i-x",
    "delete": "i-trash", acknowledge: "i-trash",
    block: "i-ban",
    unsubscribe: "i-bell-slash",
    join: "i-enter",
    reply: "i-reply"
};

/* VRChat's own icon hint, which is advisory, often absent, and names art
   nobody here has. Only consulted for a response type not listed above. */
var NOTIFY_ICON_HINTS = {
    check: "i-check", cancel: "i-x", ban: "i-ban",
    "bell-slash": "i-bell-slash", reply: "i-reply"
};

function responseIcon(response) {
    // hasOwnProperty for the same reason responseLabel uses it: the type
    // comes off the wire, and "constructor" is not an icon.
    if (NOTIFY_ICONS.hasOwnProperty(response.type))
        return NOTIFY_ICONS[response.type];
    if (NOTIFY_ICON_HINTS.hasOwnProperty(response.icon || ""))
        return NOTIFY_ICON_HINTS[response.icon];
    // Still a button, just an unnamed one: the type travels with it, so it
    // posts back correctly whether or not this build can draw it.
    return "i-dots";
}

/* The colour of a card's left edge, by notification type. Grouped by family
   rather than by exact type, since VRChat adds types faster than a palette
   usefully grows - an unlisted `group.somethingNew` still lands on the group
   colour by prefix. Mirrors `notifAccent` in the SDL client.

   Invites are blue rather than the teal they used to be. Teal sat 42 degrees of
   hue from the green above it at much the same lightness, which is close enough
   to confuse on a list and the pair that collapses first under deuteranopia;
   blue is 83 away and on the axis red-green colour blindness keeps. It is also
   lighter than the group purple, so those two separate even where hue does not
   survive. */
var NOTIFY_ACCENTS = {
    friendRequest: "#46c85a",           // green, someone new
    invite: "#4a9eff",                  // blue, somewhere to be
    requestInvite: "#4a9eff",
    inviteResponse: "#4a9eff",
    requestInviteResponse: "#4a9eff",
    votetokick: "#dc4646",              // red, something ending
    "instance.closed": "#dc4646",
    boop: "#dcaa3c",                    // amber, someone talking
    message: "#dcaa3c"
};

function notifyAccent(type) {
    if (NOTIFY_ACCENTS.hasOwnProperty(type)) return NOTIFY_ACCENTS[type];
    if ((type || "").indexOf("group") === 0) return "#a05adc";
    return "#5a5a64";
}

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
    stuff: "Filter your stuff...",
    tools: "Filter people..."
};

/* The TOOLS sections, in the order the switcher shows them. Friends is the
   roster the page already has, flat and whole rather than grouped by where
   everyone is; the other two are VRChat's player moderations, which are not
   limited to friends and so are lists of their own.

   `undo` is what the row's own button does, which is the one action worth
   having without a trip through the detail pane: a list of blocked people is
   read in order to unblock somebody. */
var TOOL_SECTIONS = [
    { id: "friends", label: "FRIENDS" },
    { id: "muted",   label: "MUTED",   undo: "unmute",  undoLabel: "UNMUTE" },
    { id: "blocked", label: "BLOCKED", undo: "unblock", undoLabel: "UNBLOCK" }
];

/* What each section is, under its list. Both moderation lists say where they
   come from: VRChat sends no events for them, so what is on screen is what was
   true when it was last asked for. */
var TOOL_HINTS = {
    friends: "Everyone on your friends list, online or not. Pick someone to " +
             "mute, block or unfriend them.",
    muted: "People you have muted. VRChat reports no changes to this, so a " +
           "mute made in-game shows up after a refresh.",
    blocked: "People you have blocked. VRChat reports no changes to this, so " +
             "a block made in-game shows up after a refresh.",
    debug: "Only here because this vrcd-web was started with --debug or " +
           "VRCD_WEB_DEBUG. Nothing below touches VRChat: the rows are made " +
           "here and answered here."
};

/* The tools on offer. DEBUG is in the list only when the snapshot carries a
   `debug` key, which it does only when the web server was started with the
   debugging tools on. Built per draw rather than being a constant, since that
   key can arrive after the page has. */
function toolSections() {
    if (state.debug === undefined) return TOOL_SECTIONS;
    return TOOL_SECTIONS.concat([{ id: "debug", label: "DEBUG" }]);
}

/* What to say once a moderation went through. Keyed by the action, and the
   name of whoever it was aimed at is appended. */
var MOD_DONE = {
    mute: "Muted", unmute: "Unmuted", block: "Blocked", unblock: "Unblocked",
    unfriend: "Unfriended"
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
    notifications: [],
    moderations: { loading: false, loaded: false, error: "", muted: [], blocked: [] }
};
var feed = [];
var view = { tab: "online", sel: null, filter: "", section: "gallery",
             tool: "friends" };
var lastJoinKey = "";
var lastNotifyKey = "";
var lastActionKey = "";
var lastStatusKey = "";
var lastModKey = "";

/* The staged status change: the row that has been picked, what has been typed
   into the message box, and where the caret was in it. Null means untouched, so
   the picker and the box show what VRChat has; a redraw arrives on every friend
   movement, which is why none of this lives in the DOM. `statusPending` covers
   the gap between the press and the first snapshot that says a change is in
   flight; the snapshot's own `pending` takes over. */
var statusChoice = null;
var statusDraft = null;
var statusPending = false;

/* The profile editor under it, staged the same way and for the same reasons:
   null while it is closed, and a draft of every field it edits once it opens.
   Nothing of it lives in the DOM either -- a snapshot arrives on every friend
   movement and takes the boxes with it.

   `profileWasPending` is how an answer is told apart from the snapshot that
   merely repeats the last one: the same edit sent twice is identical in the
   snapshot, so what is watched for is the pending flag falling rather than the
   outcome changing. */
var profileDraft = null;
var profilePending = false;
var profileWasPending = false;
/* False until a snapshot has been through the reporters. The snapshot carries
   the last outcome indefinitely, so a page that just opened would otherwise
   announce a change somebody made an hour ago; the line under the picker still
   says it, which is the right weight for old news. Every reporter that watches
   an outcome for a change is seeded from the same flag: the first snapshot is
   where the page learns what the outcomes already are, not news about them. */
var seeded = false;
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

/* User IDs with a moderation in flight, and whether a refresh of the lists is.
   Same reason as the two above: the snapshot that arrives while one is going
   out redraws the button that sent it. */
var pendingModerations = {};
var refreshingModerations = false;

/* Whether the last snapshot said the link to vrcd-server was down, so the
   moment it comes back can be told from every other snapshot. */
var linkWasDown = false;

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

/* The initials on a hued disc are the avatar, not a placeholder for one: a
   friend with no profile picture, and one whose picture is still coming down
   the link, both keep it underneath. `person` is any record carrying a picture
   (a roster friend, self); leave it out for someone we only know by name. */
function avatar(name, big, person) {
    var node = el("div", "av" + (big ? " lg" : ""), name.slice(0, 2).toUpperCase());
    node.style.background = "hsl(" + (hash(name) % 360) + " 55% 62%)";

    if (person && person.imageFileId) {
        var img = document.createElement("img");
        img.alt = "";
        node.appendChild(img);
        imageWhenVisible(img, person.imageFileId, person.imageVersion || 1,
            big ? AV_BIG_SIZE : AV_SIZE);
    }
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

/* Every friend in one list, sorted by name: the roster arrives grouped by
   where everyone is, which is what the online tab is for and the wrong shape
   for looking somebody up. */
function allFriends() {
    var roster = state.roster;
    var all = roster.active_elsewhere.concat(roster.offline);
    roster.instances.forEach(function (group) { all = all.concat(group.friends); });
    return all.sort(function (a, b) {
        return a.displayName.toLowerCase() < b.displayName.toLowerCase() ? -1 : 1;
    });
}

function tabInfo(id) {
    for (var i = 0; i < TABS.length; i++)
        if (TABS[i].id === id) return TABS[i];
    return TABS[0];
}

function toolInfo(id) {
    var sections = toolSections();
    for (var i = 0; i < sections.length; i++)
        if (sections[i].id === id) return sections[i];
    // Also what puts somebody back on the friends list when a page left on
    // the debug tool reconnects to a server that no longer offers it.
    return sections[0];
}

/* One of the two moderation lists. Never undefined, so a page drawing before
   the first snapshot lands is a list with nothing in it rather than a crash. */
function moderated(section) {
    var mod = state.moderations;
    if (!mod) return [];
    return (section === "muted" ? mod.muted : mod.blocked) || [];
}

function isModerated(section, id) {
    var list = moderated(section);
    for (var i = 0; i < list.length; i++)
        if (list[i].user_id === id) return true;
    return false;
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
    var button = el("button", tab.id === view.tab ? "on" : null);

    // Your own face reads faster than a generic person glyph.
    if (tab.id === "profile" && state.self) {
        var face = avatar(state.self.displayName, false, state.self);
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
    row.appendChild(avatar(friend.displayName, false, friend));

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

    // Offline friends are not what this tab is for and TOOLS carries the whole
    // list flat, so the section is drawn only for a search: a name typed here
    // that came back empty because they happen to be offline reads as a bug,
    // when "they are offline" is the answer the search was asking for.
    var down = view.filter
        ? roster.offline.filter(function (f) { return matches(f.displayName); })
        : [];
    if (down.length) {
        shown++;
        body.appendChild(el("div", "section", "Offline (" + down.length + ")"));
        var downBox = el("div", "flat");
        down.forEach(function (f) { downBox.appendChild(friendRow(f)); });
        body.appendChild(downBox);
    }

    // Nobody online with a roster in hand is a different answer than a roster
    // that has not arrived, now that the offline ones no longer fill the pane.
    if (shown === 0)
        body.appendChild(placeholder(view.filter
            ? "Nothing matches that filter."
            : (roster.offline.length ? "No friends online." : "No friend data yet.")));
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
    var responses = entry.responses || [];
    var kind = NOTIFY_TYPES[entry.notification_type] ||
        { label: notifyLabel(entry.notification_type), hide: "DISMISS" };
    var busy = pendingNotifications[entry.id] === true;

    /* A group notification puts the group's own ID where a user ID goes and
       sends no name with it, so there is nobody to name and nobody to open.
       The title carries the row instead. */
    var fromUser = (entry.sender_user_id || "").indexOf("usr_") === 0;
    var who = entry.sender_name || (fromUser ? entry.sender_user_id : "") ||
        entry.title || "VRChat";

    var card = el("div", "notify" + (entry.debug ? " fake" : ""));

    /* The spine down the left edge, which is what makes the lines above the
       buttons read as one card rather than as a block of text. A fake gets one
       too, in its own type's colour: the amber that marks it as fake goes round
       the other three sides instead, since a catalogue of one fake per type is
       spawned precisely to look at what this line does. */
    card.style.setProperty("--spine", notifyAccent(entry.notification_type));

    /* A button, not a div, so the sender opens in the detail pane the way a
       feed row does. The action buttons are siblings of it, never inside it.

       Anybody with a user ID opens, friend or not. A stranger is the one whose
       pane is worth opening: a friend request is a name and nothing else until
       their profile is fetched, and accepting one is exactly the decision that
       needs a bio and a trust rank to make. */
    var hit = fromUser ? findFriend(entry.sender_user_id) : null;
    var friend = hit ? hit.friend : null;
    var head = el(fromUser ? "button" : "div", "head");
    head.appendChild(avatar(who, false, friend));
    var text = el("div", "who");
    text.appendChild(el("div", "n", who));

    /* A fake row says ACCEPT and DECLINE like any other, and the danger runs
       both ways: accepting a real request believing it is a fake, or leaving a
       real one sitting because it looked like one. So it is marked, next to the
       type where the eye already is, rather than left to be told apart by
       whoever is looking. Only ever present under --debug. */
    var label = el("div", "d");
    if (entry.debug) label.appendChild(el("span", "tag fake", "FAKE"));
    label.appendChild(document.createTextNode(kind.label));
    text.appendChild(label);
    head.appendChild(text);
    if (entry.received_at_unix)
        head.appendChild(el("div", "when", whenText(entry.received_at_unix)));
    if (fromUser)
        head.onclick = function () {
            select(friend
                ? { kind: "friend", id: entry.sender_user_id }
                : { kind: "person", id: entry.sender_user_id, name: who });
        };
    card.appendChild(head);

    // Only when it says something the two lines above did not: VRChat's
    // titles are often just the type over again ("Group Invite").
    if (entry.title && entry.title !== who && entry.title !== kind.label)
        card.appendChild(el("div", "ntitle", entry.title));
    if (entry.message) card.appendChild(el("div", "msg", entry.message));
    if (kind.note) card.appendChild(el("div", "note", kind.note));

    /* A v2 notification names its own buttons, and they are the only ones
       that mean anything for it - a group invite is not accepted through the
       friend-request endpoint. So when there are responses they replace the
       table's buttons rather than joining them. */
    var actions = el("div", "actions");
    if (responses.length) {
        responses.forEach(function (response) {
            actions.appendChild(notifyButton(entry, "respond",
                responseLabel(response),
                NOTIFY_PRIMARY[response.type] === true, busy, response,
                responseIcon(response)));
        });
    } else {
        if (kind.accept)
            actions.appendChild(notifyButton(entry, "accept", kind.accept,
                true, busy, null, "i-check"));
        // An invite is answered by going there, which is the same self-invite
        // the roster offers; VRChat's accept endpoint does nothing for one.
        if (kind.join && entry.location) {
            var go = joinButton(entry.location, "JOIN WORLD", "i-enter");
            go.disabled = busy;
            actions.appendChild(go);
        }
    }

    /* VRChat clears some of its own (a queue-ready expires, an announcement
       is retracted) and refuses to be told to. Those rows are read-only:
       a dismiss button on one only fails. And a row whose own responses
       already include a dismiss has one - drawing this beside it is the same
       button twice. */
    if (entry.can_delete !== false && responses.some(responseDismisses) === false) {
        var dismiss = responses.length ? "DISMISS" : kind.hide;
        if (dismiss)
            actions.appendChild(notifyButton(entry, "hide", dismiss, false,
                busy, null, "i-trash"));
    }

    notifyBlock(actions, entry, busy);

    if (actions.childNodes.length) card.appendChild(actions);

    return card;
}

/* Block, last in the row and so furthest from accept: the two are opposite
   answers to the same request and should not be neighbours under a thumb.
   It answers the sender rather than this one notification, which is the
   point - dismissing a request from somebody who sends another every day is
   not an answer.

   Offered only for a notification from an actual person: a v2 group
   notification carries a `grp_` ID in the same field, and there is nobody to
   block behind it. Armed rather than fired, like every other block on this
   page, and keyed by sender, so the same person armed here reads as armed in
   their pane.

   A fake gets no block button. Everything else a fake answers is answered by
   the link and never reaches VRChat, but a moderation has no such path: it
   would be a real call about a person who was invented two clicks ago. */
function notifyBlock(actions, entry, busy) {
    if (entry.debug) return;
    if ((entry.sender_user_id || "").indexOf("usr_") !== 0) return;

    var id = entry.sender_user_id;
    var mod = state.moderations;
    // Which way it points is not known until the lists land, and there is no
    // unblock to offer here: the inbox is not where that is undone.
    if (!mod || mod.loaded === false || isModerated("blocked", id)) return;

    appendArmed(actions, "block|" + id, "BLOCK", "CONFIRM BLOCK",
        busy || pendingModerations[id] === true,
        function (label) {
            var button = el("button", "act", label);
            button.disabled = state.connected === false;
            button.onclick = function () {
                moderate("block", id, button);
                /* Blocking answers the notification too: a request from
                   somebody who can no longer send one is not worth leaving
                   in the inbox. Only when VRChat allows the dismiss - a row
                   it clears itself would come back on the next seed. No
                   button of its own: it rides on the block's, which is
                   already saying it is working. */
                if (entry.can_delete !== false)
                    notifyAct(entry, "hide", null);
            };
            return button;
        }, render, "i-ban");
}

/* "group.queueReady" -> "Group queue ready". A type this build has never
   heard of still has to head its row, and raw it reads like code. */
function notifyLabel(type) {
    if (!type) return "Notification";
    var words = type.replace(/\./g, " ").replace(/([a-z])([A-Z])/g, "$1 $2");
    return words.charAt(0).toUpperCase() + words.slice(1).toLowerCase();
}

function notifyButton(entry, action, label, primary, busy, response, iconName) {
    var cls = "act" + (primary ? " primary" : "");
    var button = iconName ? iconAct(cls, label, iconName) : el("button", cls, label);
    // What VRChat called it, for the cases where the short label dropped
    // something ("...this group's event announcements" - which group?). It
    // joins the label rather than replacing it now that the label is the only
    // thing saying what the picture means.
    if (response && response.text && response.text.toUpperCase() !== label)
        button.title = iconName ? label + " - " + response.text : response.text;
    button.disabled = busy;
    button.onclick = function () { notifyAct(entry, action, button, response); };
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
/* What the proxy said each held picture is, for the one caller that has to
   name a file: the viewer's save button. */
var imageTypes = {};
/* Key -> the callbacks waiting on it. One fetch serves all of them, which is
   what stops a redraw mid-fetch from starting a second. */
var imageWaiting = {};
/* Key -> when it is worth asking again, and how long that wait was.

   A failure is remembered but never permanently, because every layer under
   this one treats a failure as passing: the web server forgets its own after a
   minute, VRChat's rate limit lifts, and a link that was down comes back. A
   page is open for hours and reloaded almost never, so a tombstone that
   outlived its cause would leave a face blank for the rest of the day over one
   bad moment -- which is exactly what a restart appeared to fix, since what it
   really did was force a reload. */
var imageFailed = {};

/* The web server refused it. It caches its own failures for a minute
   (FAILURE_TTL in web/source/web/images.d), so asking again before that is
   over only replays the same answer -- and a retry that lands a moment early
   would double the wait below over an answer that was already stale. */
var IMAGE_FAIL_MS = 65000;
/* Nothing refused it: the retries ran out with the picture still on its way,
   or the web server itself was unreachable. The wait is only to let the bytes
   land, and by then they are usually already cached there. */
var IMAGE_SLOW_MS = 15000;
/* Each further failure on one key waits twice as long, up to this. A picture
   that has failed all afternoon is not worth a fetch a minute for every face
   on screen. */
var IMAGE_FAIL_MAX_MS = 600000;

/* Thumbnail edges asked for behind a face. A row avatar is 36 CSS pixels and
   the profile hero 80, so these cover both at twice the density; VRChat serves
   128/256/512/1024 and nothing in between. */
var AV_SIZE = 128;
var AV_BIG_SIZE = 256;

var IMAGE_RETRY_MS = 800;
/* Roughly 30 seconds of retries. vrcd-server spaces uncached downloads 250 ms
   apart, so a full grid takes a while to come through on a cold cache. */
var IMAGE_TRIES = 40;

function imageKey(fileId, version, size) {
    return fileId + "/" + version + "/" + size;
}

/* Whether this key is inside the wait left by its last failure. An expired
   mark is kept rather than dropped: it is what the next failure doubles from,
   and a key that keeps failing should back off rather than start over. */
function imageBlocked(key) {
    var mark = imageFailed[key];
    return mark !== undefined && Date.now() < mark.until;
}

function rememberImageFailure(key, base) {
    var mark = imageFailed[key];
    var wait = mark ? Math.min(Math.max(base, mark.wait * 2), IMAGE_FAIL_MAX_MS)
                    : base;
    imageFailed[key] = { until: Date.now() + wait, wait: wait };
}

/* A link or a socket that came back is a reason to stop remembering that a
   picture could not be had while it was down. What was actually fetched stays:
   a file, version and size never change what they point at. */
function forgetImageErrors() {
    imageFailed = {};
}

/* Fetch a proxied image and hand the object URL to `then`, or null when it
   could not be had. One fetch per key however many callers ask for it, and a
   key already held answers on the spot.

   The viewer asks this way rather than through imageInto: it has a caption to
   take down and a save button to arm once the full-size picture has actually
   landed, and an <img> pointed at a URL says nothing about which one it is. */
function imageThen(fileId, version, size, then) {
    var key = imageKey(fileId, version, size);
    if (imageURLs[key]) { then(imageURLs[key]); return; }
    if (imageBlocked(key)) { then(null); return; }

    if (imageWaiting[key]) { imageWaiting[key].push(then); return; }
    imageWaiting[key] = [then];
    fetchImage(key, fileId, version, size, IMAGE_TRIES);
}

function imageInto(img, fileId, version, size) {
    imageThen(fileId, version, size, function (url) {
        if (url) img.src = url;
    });
}

/* Same, but not until the picture is near the viewport.

   A roster runs to hundreds of friends, and vrcd-server spaces uncached
   downloads a quarter second apart, so asking for every face at once would
   spend minutes of link time on rows nobody scrolled to -- and hold up the
   ones on screen behind them. Faces already fetched are set straight away:
   they cost nothing, and waiting for the observer would blank them for a frame
   on every redraw.

   The observer is dropped at the start of each render (see render()), since a
   redraw replaces the nodes it was watching. */
var imageObserver = null;

function imageWhenVisible(img, fileId, version, size) {
    var key = imageKey(fileId, version, size);
    if (imageURLs[key]) { img.src = imageURLs[key]; return; }
    if (imageBlocked(key)) return;

    if (window.IntersectionObserver === undefined) {
        imageInto(img, fileId, version, size);
        return;
    }

    if (imageObserver === null) {
        imageObserver = new IntersectionObserver(function (entries) {
            entries.forEach(function (entry) {
                if (entry.isIntersecting === false) return;
                imageObserver.unobserve(entry.target);
                var want = entry.target.imageWanted;
                if (want) imageInto(entry.target, want.id, want.version, want.size);
            });
        // A screenful of lead time, so scrolling lands on faces rather than
        // on the gap where they are about to appear.
        }, { rootMargin: "300px" });
    }

    img.imageWanted = { id: fileId, version: version, size: size };
    imageObserver.observe(img);
}

/* Badge art, through the same proxy and the same object-URL bookkeeping. The
   URL is the key: it names one picture forever, the way a file and version do.

   Not deferred to the viewport like a face. A profile holds a handful of these
   and they are all on the one screen somebody opened deliberately, so waiting
   for an observer would only make them appear late. */
function badgeInto(img, url) {
    var key = "badge:" + url;
    var give = function (found) { if (found) img.src = found; };

    if (imageURLs[key]) { give(imageURLs[key]); return; }
    if (imageBlocked(key)) return;

    if (imageWaiting[key]) { imageWaiting[key].push(give); return; }
    imageWaiting[key] = [give];
    fetchBadge(key, url, IMAGE_TRIES);
}

function fetchBadge(key, url, tries) {
    fetch("/api/badge?url=" + encodeURIComponent(url)).then(function (r) {
        if (r.status === 202) {
            if (tries > 0)
                setTimeout(function () { fetchBadge(key, url, tries - 1); },
                    IMAGE_RETRY_MS);
            else
                imageDone(key, null, null, IMAGE_SLOW_MS);
            return null;
        }
        if (r.ok === false) { imageDone(key, null, null, IMAGE_FAIL_MS); return null; }
        return r.blob();
    }).then(function (blob) {
        if (blob) imageDone(key, URL.createObjectURL(blob), blob.type);
    }).catch(function () {
        imageDone(key, null, null, IMAGE_SLOW_MS);
    });
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
                imageDone(key, null, null, IMAGE_SLOW_MS);
            }
            return null;
        }
        if (r.ok === false) { imageDone(key, null, null, IMAGE_FAIL_MS); return null; }
        return r.blob();
    }).then(function (blob) {
        if (blob) imageDone(key, URL.createObjectURL(blob), blob.type);
    }).catch(function () {
        imageDone(key, null, null, IMAGE_SLOW_MS);
    });
}

/* `retryAfter` is how long to leave a failed key alone before a redraw may ask
   for it again, and says which kind of failure this was: a refusal that the
   web server will repeat from its own cache, or bytes that simply had not
   arrived yet. */
function imageDone(key, url, type, retryAfter) {
    var waiting = imageWaiting[key] || [];
    delete imageWaiting[key];

    if (url === null) {
        rememberImageFailure(key, retryAfter || IMAGE_FAIL_MS);
    } else {
        delete imageFailed[key];
        imageURLs[key] = url;
        imageTypes[key] = type || "";
    }

    // Callbacks left over from a render that has since been replaced are
    // pointing at detached nodes by now, and setting src on one of those
    // costs nothing.
    waiting.forEach(function (give) { give(url); });
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

    // A print is a photograph and a gallery picture was uploaded to be looked
    // at; a card in a pane is not looking at either of them.
    var picture = thumb(entry, section, 512, true);
    viewable(picture, entryImage(entry, section), entryName(entry, section), 512);
    body.appendChild(picture);

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
        appendArmed(actions, "consume|" + item.id, "CONSUME", "CONFIRM CONSUME",
            busy, function (label) {
                return actionButton(item.id, "consume", "", label, false, busy);
            });

    actions.appendChild(copyButton("Copy item ID", item.id));
    return actions;
}

function appendDelete(actions, id, action, busy) {
    appendArmed(actions, action + "|" + id, "DELETE", "CONFIRM DELETE", busy,
        function (label) { return actionButton(id, action, "", label, false, busy); });
}

/* Two taps, and the second one is not where the first landed: Cancel takes
   that spot, because none of these can be undone. `make` builds the confirm
   button, since what one sends is not what the next one does: a delete and a
   block do not go to the same place.

   `redraw` is what puts the armed state on screen, and defaults to the detail
   pane because that is where all of these but one live. `iconName` draws the
   arming button as a square icon instead of a word, for the one row that is
   built out of those - and then Cancel is a square too, so it lands on the
   same spot rather than merely near it. */
function appendArmed(actions, key, label, confirmLabel, busy, make, redraw, iconName) {
    if (armedAction === key) {
        /* Plain, not the cross's usual red: in an armed pair the red one has
           to be the button that does something, and that is Confirm. A red
           Cancel reads as the dangerous one and inverts the whole point. */
        actions.appendChild(iconName
            ? iconAct("act", "CANCEL", "i-x", function () {
                  armedAction = ""; render();
              }, "")
            : cancelButton(""));
        actions.appendChild(make(confirmLabel));
        return;
    }

    var arm = iconName ? iconAct("act", label, iconName) : el("button", "act", label);
    arm.disabled = busy;
    arm.onclick = function () { armedAction = key; (redraw || renderDetail)(); };
    actions.appendChild(arm);
}

/* Put a button into its "working on it" state, and hand back the undo.

   A button made of words says so in words. An icon button cannot: writing
   text into it throws the picture away, and "SENDING..." in a square button
   is clipped anyway - so for those the disabled state is the whole signal.
   Null is allowed, for an action that rides along with another one and has no
   button of its own. */
function markSending(button) {
    if (!button) return function () {};

    button.disabled = true;
    if (button.classList.contains("ico"))
        return function () { button.disabled = false; };

    var label = button.textContent;
    button.textContent = "SENDING...";
    return function () {
        button.disabled = false;
        button.textContent = label;
    };
}

/* Ink for a picture, by which picture it is: yes is green, the two ways of
   saying no are red, everything else plain. Keyed by icon rather than by
   label so it still holds for a response type nobody here has heard of,
   which is how `iconTint` does it in the SDL client. */
var ICON_TONES = { "i-check": "yes", "i-x": "no", "i-ban": "no" };

/* A button carrying a picture instead of a word. The word still travels with
   it: a title for a pointer, an aria-label for everything else. An icon says
   what it does only to somebody who already knows it, and a button with no
   accessible name says nothing at all. */
function iconAct(cls, label, name, onclick, tone) {
    var ink = tone === undefined ? ICON_TONES[name] : tone;
    var button = el("button", cls + " ico" + (ink ? " " + ink : ""));
    button.appendChild(icon(name, 22));
    button.title = label;
    button.setAttribute("aria-label", label);
    if (onclick) button.onclick = onclick;
    return button;
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

/* A date with no time of day, which is what VRChat sends for the day somebody
   joined. Built from the parts rather than parsed: "2019-04-01" is read as UTC
   midnight, which west of Greenwich is the day before. */
function whenDay(text) {
    var parts = /^(\d{4})-(\d{2})-(\d{2})$/.exec(text || "");
    if (parts === null) return whenDate(text);

    var when = new Date(Number(parts[1]), Number(parts[2]) - 1, Number(parts[3]));
    return isNaN(when.getTime()) ? text : when.toLocaleDateString();
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

/* Caption for the next print, kept out of the DOM so a redraw mid-typing does
   not take it with it (the caret is handled for every box at once, see
   rememberCaret). */
var printNote = "";

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

/* ----------------------------------------------------------- image viewer */

/* One picture, on its own, over the page: the face on a profile, and anything
   in STUFF with artwork behind it. A print is a photograph and a profile
   picture is cropped to a circle in every place it is drawn, so the page has
   plenty of pictures nothing on it actually shows.

   What the hero and the grid draw are thumbnails; this asks the proxy for size
   0, which is the file VRChat was given. The thumbnail already in hand goes up
   first, so the frame is never empty while several megabytes come down the
   link, and it is replaced in place when they land.

   Zoom starts at fit and only goes in - at fit the whole picture is already
   there - and pinch, wheel and a pair of buttons all reach it, since a headset
   has no scroll wheel and a phone has no cursor. */

var VIEWER_ZOOM_MAX = 8;
/* Where a double-press goes, and comes back from. */
var VIEWER_TAP_ZOOM = 2.5;
/* What a button press moves the zoom by. */
var VIEWER_ZOOM_STEP = 1.6;
/* How long the second press of a double has to arrive in. */
var VIEWER_TAP_MS = 350;
/* How far a press may wander and still be a press rather than a pan. */
var VIEWER_TAP_SLOP = 12;

/* The viewer while it is open, null the rest of the time. `zoom` is a multiple
   of the fitted size and `x`/`y` are the picture's offset from the middle of
   the frame in screen pixels, which is the space the transform is written in.
   Everything drawn comes from those three. */
var viewer = null;

/* Params:
     picture = { id, version }, the shape entryImage() already returns.
     title   = what to call it in the bar, and in the file if it is saved.
     preview = thumbnail edge already on screen behind it, or 0 for none. */
function openViewer(picture, title, preview) {
    closeViewer();
    viewer = {
        picture: picture,
        title: title || "Picture",
        zoom: 1,
        x: 0,
        y: 0,
        pointers: {},
        pinch: 0,
        /* Where the press being held started, whether it has moved far enough
           to be a pan, and when and where the last one that was not ended -
           between them that is a double-press. */
        pressX: 0,
        pressY: 0,
        dragged: false,
        tapAt: 0,
        tapX: 0,
        tapY: 0,
        url: "",
        full: false,
        error: ""
    };
    buildViewer();

    // Captured, so a callback that arrives after this one was closed and
    // another opened does not paint into the new one.
    var mine = viewer;

    if (preview)
        imageThen(picture.id, picture.version, preview, function (url) {
            // Only while the full one is still coming: a thumbnail that
            // arrives second would otherwise be put back over it.
            if (viewer === mine && mine.full === false && url) mine.image.src = url;
        });

    imageThen(picture.id, picture.version, 0, function (url) {
        if (viewer !== mine) return;

        if (url === null) {
            mine.error = "That picture could not be fetched";
            drawViewer();
            return;
        }
        mine.full = true;
        mine.url = url;
        mine.image.src = url;
        drawViewer();
    });
}

function closeViewer() {
    if (viewer === null) return;
    // The object URL is a cache entry shared with every thumbnail on the page,
    // so it is not revoked here: it belongs to imageURLs, not to this modal.
    viewer = null;

    var box = document.getElementById("viewer");
    box.textContent = "";
    box.classList.add("hidden");
}

function buildViewer() {
    var box = document.getElementById("viewer");
    box.textContent = "";

    var bar = el("div", "viewer-bar");
    var title = el("div", "viewer-title", viewer.title);
    title.id = "viewerTitle";
    bar.appendChild(title);

    var close = el("button", "act", "CLOSE");
    close.onclick = closeViewer;
    bar.appendChild(close);
    box.appendChild(bar);

    var stage = el("div", "viewer-stage");
    /* A press beside the picture is a press on nothing, which is the other way
       out of here.

       Both halves are load-bearing. A click is delivered to the nearest
       ancestor of where the press began and where it ended, so a pan that
       starts on the picture and finishes past its edge arrives here looking
       exactly like a press on the backdrop - hence the drag check. And a press
       that does begin on the backdrop never reaches viewerDown, so it clears
       the flag itself or a pan a minute ago would still be suppressing it. */
    stage.onpointerdown = function (ev) {
        if (ev.target === stage) viewer.dragged = false;
    };
    stage.onclick = function (ev) {
        if (ev.target === stage && viewer.dragged === false) closeViewer();
    };
    stage.onwheel = viewerWheel;

    var img = document.createElement("img");
    img.className = "viewer-img";
    img.alt = viewer.title;
    // The browser's own drag would pick the picture up mid-pan.
    img.draggable = false;
    img.onpointerdown = viewerDown;
    img.onpointermove = viewerMove;
    img.onpointerup = viewerUp;
    img.onpointercancel = viewerUp;
    /* The fitted size is only known once the browser has the picture, and the
       zoom is a multiple of it - so both the clamp and the caption wait for
       this. It fires again when the full-size one replaces the thumbnail. */
    img.onload = function () { clampViewer(); drawViewer(); };
    stage.appendChild(img);

    viewer.image = img;
    viewer.stage = stage;
    box.appendChild(stage);

    var foot = el("div", "viewer-foot");
    viewer.note = el("div", "viewer-note");
    foot.appendChild(viewer.note);

    var out = el("button", "act", "-");
    out.setAttribute("aria-label", "Zoom out");
    out.onclick = function () { zoomViewer(1 / VIEWER_ZOOM_STEP, 0, 0); };
    foot.appendChild(out);

    var into = el("button", "act", "+");
    into.setAttribute("aria-label", "Zoom in");
    into.onclick = function () { zoomViewer(VIEWER_ZOOM_STEP, 0, 0); };
    foot.appendChild(into);

    var fit = el("button", "act", "FIT");
    fit.onclick = fitViewer;
    foot.appendChild(fit);

    var save = el("button", "act", "SAVE");
    save.onclick = saveViewer;
    foot.appendChild(save);

    box.appendChild(foot);
    box.classList.remove("hidden");
    drawViewer();
}

function drawViewer() {
    if (viewer === null) return;

    viewer.image.style.transform = "translate(" + viewer.x + "px, " +
        viewer.y + "px) scale(" + viewer.zoom + ")";
    viewer.note.textContent = viewerNote();
}

/* The caption under the picture: what went wrong, or what is still coming, or
   what is there. The dimensions are the file's own, which is the thing the
   page has nowhere else to say. */
function viewerNote() {
    if (viewer.error) return viewer.error;
    if (viewer.full === false) return "Loading full size...";

    var zoom = Math.round(viewer.zoom * 100) + "%";
    if (viewer.image.naturalWidth < 1) return zoom;
    return viewer.image.naturalWidth + " x " + viewer.image.naturalHeight +
        "  -  " + zoom;
}

/* Zoom about a point, given relative to the middle of the frame. The buttons
   pass 0,0 - the middle - since there is no cursor behind them. */
function zoomViewer(step, atX, atY) {
    if (viewer === null) return;

    var was = viewer.zoom;
    viewer.zoom = Math.min(Math.max(viewer.zoom * step, 1), VIEWER_ZOOM_MAX);

    // The point under the cursor stays under it.
    var moved = viewer.zoom / was;
    viewer.x = atX + (viewer.x - atX) * moved;
    viewer.y = atY + (viewer.y - atY) * moved;

    clampViewer();
    drawViewer();
}

function fitViewer() {
    if (viewer === null) return;
    viewer.zoom = 1;
    viewer.x = 0;
    viewer.y = 0;
    drawViewer();
}

/* Keep an edge of the picture in the frame. clientWidth is the fitted size -
   the CSS fits it - so the drawn size is that times the zoom, and half the
   overhang is how far it can go before the far edge comes into view. */
function clampViewer() {
    if (viewer === null) return;

    var overX = Math.max(0,
        (viewer.image.clientWidth * viewer.zoom - viewer.stage.clientWidth) / 2);
    var overY = Math.max(0,
        (viewer.image.clientHeight * viewer.zoom - viewer.stage.clientHeight) / 2);

    viewer.x = Math.min(Math.max(viewer.x, -overX), overX);
    viewer.y = Math.min(Math.max(viewer.y, -overY), overY);
}

/* Pan with one pointer, pinch with two, the way the crop frame does. Each of
   these checks the modal is still up: closing it during a drag tears the
   picture out from under a captured pointer, and the release still arrives. */
function viewerDown(ev) {
    if (viewer === null) return;
    ev.preventDefault();
    viewer.image.setPointerCapture(ev.pointerId);
    viewer.pointers[ev.pointerId] = { x: ev.clientX, y: ev.clientY };
    viewer.pinch = viewerSpan();

    viewer.pressX = ev.clientX;
    viewer.pressY = ev.clientY;
    // A second finger is a pinch, whatever either of them does next.
    viewer.dragged = Object.keys(viewer.pointers).length > 1;
}

function viewerMove(ev) {
    if (viewer === null) return;
    var held = viewer.pointers[ev.pointerId];
    if (held === undefined) return;
    ev.preventDefault();

    var ids = Object.keys(viewer.pointers);
    if (ids.length === 1) {
        viewer.x += ev.clientX - held.x;
        viewer.y += ev.clientY - held.y;
    }
    held.x = ev.clientX;
    held.y = ev.clientY;

    if (Math.abs(ev.clientX - viewer.pressX) +
        Math.abs(ev.clientY - viewer.pressY) > VIEWER_TAP_SLOP)
        viewer.dragged = true;

    if (ids.length > 1) {
        var span = viewerSpan();
        if (viewer.pinch > 0 && span > 0) {
            var middle = viewerMiddle();
            zoomViewer(span / viewer.pinch, middle.x, middle.y);
        }
        viewer.pinch = span;
    }

    clampViewer();
    drawViewer();
}

function viewerUp(ev) {
    if (viewer === null) return;

    var was = viewer.pointers[ev.pointerId] !== undefined;
    delete viewer.pointers[ev.pointerId];
    // Whichever finger is left starts a fresh span, or the next move jumps by
    // the distance between the two.
    viewer.pinch = viewerSpan();

    if (was && viewer.dragged === false) viewerTap(ev);
}

function viewerSpan() {
    var ids = Object.keys(viewer.pointers);
    if (ids.length < 2) return 0;
    var a = viewer.pointers[ids[0]], b = viewer.pointers[ids[1]];
    return Math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
}

/* Where a pinch is centred, relative to the middle of the frame. */
function viewerMiddle() {
    var ids = Object.keys(viewer.pointers);
    var a = viewer.pointers[ids[0]], b = viewer.pointers[ids[1]];
    var box = viewer.stage.getBoundingClientRect();
    return {
        x: (a.x + b.x) / 2 - (box.left + box.width / 2),
        y: (a.y + b.y) / 2 - (box.top + box.height / 2)
    };
}

function viewerWheel(ev) {
    if (viewer === null) return;
    ev.preventDefault();

    var box = viewer.stage.getBoundingClientRect();
    zoomViewer(Math.exp(-ev.deltaY / 400),
        ev.clientX - (box.left + box.width / 2),
        ev.clientY - (box.top + box.height / 2));
}

/* Double-press to zoom in where it was pressed, double-press again to come
   back: the one gesture that means the same thing with a mouse, a finger and a
   controller.

   Counted here rather than left to dblclick. The pointer handlers
   preventDefault to keep a drag from selecting the picture or scrolling the
   page, and a browser is then entitled to send no compatibility mouse events
   at all - and a touchscreen would not send a dblclick anyway. */
function viewerTap(ev) {
    var now = Date.now();
    var second = viewer.tapAt > 0 && now - viewer.tapAt < VIEWER_TAP_MS &&
        Math.abs(ev.clientX - viewer.tapX) +
        Math.abs(ev.clientY - viewer.tapY) < VIEWER_TAP_SLOP * 2;

    // A third press starts counting again rather than reading as another
    // double against the second.
    viewer.tapAt = second ? 0 : now;
    viewer.tapX = ev.clientX;
    viewer.tapY = ev.clientY;
    if (second === false) return;

    if (viewer.zoom > 1) { fitViewer(); return; }

    var box = viewer.stage.getBoundingClientRect();
    zoomViewer(VIEWER_TAP_ZOOM,
        ev.clientX - (box.left + box.width / 2),
        ev.clientY - (box.top + box.height / 2));
}

/* Keeping the picture. The bytes are already in the browser as an object URL,
   so this is a link click and nothing goes over the network again. Before the
   full-size one lands there is nothing worth saving - the thumbnail on screen
   is not what was asked for - so it says so rather than saving that. */
function saveViewer() {
    if (viewer === null) return;
    if (viewer.url === "") {
        showToast(viewer.error || "Still fetching that picture", true);
        return;
    }

    var link = document.createElement("a");
    link.href = viewer.url;
    link.download = viewerFileName();
    link.click();
}

var IMAGE_EXTENSIONS = {
    "image/png": "png", "image/jpeg": "jpg",
    "image/webp": "webp", "image/gif": "gif"
};

/* A display name is not a file name: it can hold a slash, and on Windows a
   colon or a quote. Everything but letters, digits, dots and dashes becomes an
   underscore, which leaves something recognisable and safe to write. */
function viewerFileName() {
    var mime = imageTypes[imageKey(viewer.picture.id, viewer.picture.version, 0)];
    var name = viewer.title.replace(/[^\w.-]+/g, "_").replace(/^[_.]+/, "");
    return (name || viewer.picture.id) + "." + (IMAGE_EXTENSIONS[mime] || "png");
}

/* Make a picture on the page open in the viewer. The node keeps whatever it
   already is - the hero face and a 4:3 card are both a box with an <img> in
   them, and neither wants to become a <button> - so the role and the key
   handler are what a keyboard and a screen reader go by. */
function viewable(node, picture, title, preview) {
    if (!picture) return node;

    node.classList.add("zoomable");
    node.tabIndex = 0;
    node.setAttribute("role", "button");
    node.setAttribute("aria-label", "View " + title + " full size");

    var open = function () { openViewer(picture, title, preview); };
    node.onclick = open;
    node.onkeydown = function (ev) {
        if (ev.key !== "Enter" && ev.key !== " ") return;
        // Space scrolls the pane underneath otherwise.
        ev.preventDefault();
        open();
    };
    return node;
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

/* --------------------------------------------------------------- tools */

/* Friend management: the whole friends list, and the two lists of people
   VRChat calls player moderations. The friends list is the roster the page
   already holds, flattened; the other two come down the link and are only
   filled in on connect and on refresh, since VRChat sends no events for
   them. */
function renderTools(body) {
    var info = toolInfo(view.tool);
    // Written back, so a page left on DEBUG that reconnects to a server
    // without it lands on the friends list with that chip lit, rather than on
    // the friends list with no chip lit at all.
    view.tool = info.id;
    body.appendChild(toolSwitcher());

    if (info.id === "friends")     renderFriendList(body);
    else if (info.id === "debug")  renderDebug(body);
    else                           renderModerated(body, info);

    body.appendChild(el("div", "hint", TOOL_HINTS[info.id]));
}

/* One button per fake the server offers, drawn from the catalogue in the
   snapshot rather than a table here: adding a fake should be one edit, on the
   side that knows how to build one.

   Each press makes a row in the inbox that took the same path a real
   notification takes, so what appears there is what a real one looks like, and
   answering it presses the same buttons. Nothing here reaches VRChat. */
function renderDebug(body) {
    var fakes = (state.debug && state.debug.fakes) || [];

    body.appendChild(el("div", "section", "Fake notifications"));

    var list = el("div", "actions");
    fakes.forEach(function (fake) {
        var button = el("button", "act", fake.label);
        button.onclick = function () { debugAct(fake.action, button); };
        list.appendChild(button);

        if (fake.hint) list.appendChild(el("div", "hint", fake.hint));
    });

    if (fakes.length === 0)
        list.appendChild(placeholder("This vrcd-web offers no fakes."));
    body.appendChild(list);

    body.appendChild(el("div", "section", "Clean up"));
    var clear = el("div", "actions");
    var wipe = el("button", "act", "CLEAR FAKES");
    wipe.onclick = function () { debugAct("clear", wipe); };
    clear.appendChild(wipe);
    clear.appendChild(el("div", "hint",
        "Takes every fake back out. Real notifications stay where they are."));
    body.appendChild(clear);

    var count = (state.notifications || []).filter(function (entry) {
        return entry.debug === true;
    }).length;
    if (count)
        body.appendChild(el("div", "hint",
            count + " fake notification(s) in the inbox."));
}

/* Unlike the actions that travel down the link, this one is answered entirely
   by the web server, so the reply is all there is to hear. The rows themselves
   arrive in the next snapshot. */
function debugAct(action, button) {
    var label = button.textContent;
    button.disabled = true;
    button.textContent = "...";

    function done(message, bad) {
        button.disabled = false;
        button.textContent = label;
        if (message) showToast(message, bad);
    }

    fetch("/api/debug", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: action })
    }).then(function (r) {
        if (r.ok) { done(action === "clear" ? "Fakes cleared" : "Added", false); return; }
        done(r.status === 403
            ? "This vrcd-web was not started with --debug"
            : "The vrcd web server refused that", true);
    }).catch(function () {
        done("Could not reach the vrcd web server", true);
    });
}

function toolSwitcher() {
    var row = el("div", "chips");
    toolSections().forEach(function (section) {
        var chip = el("button", "chip" + (section.id === view.tool ? " on" : ""),
            section.label);

        // A count only once the list it counts has actually arrived: a zero
        // that means "not asked yet" reads as "nobody". The debug chip counts
        // nothing: it is buttons, not a list.
        var count = 0;
        if (section.id === "friends")
            count = allFriends().length;
        else if (section.id !== "debug")
            count = state.moderations.loaded ? moderated(section.id).length : 0;
        if (count) chip.appendChild(el("span", "n", String(count)));

        chip.onclick = function () { showTool(section.id); };
        row.appendChild(chip);
    });
    return row;
}

function renderFriendList(body) {
    var friends = allFriends().filter(function (f) { return matches(f.displayName); });

    var bar = el("div", "bar");
    bar.appendChild(el("div", "count",
        friends.length + (friends.length === 1 ? " friend" : " friends")));
    body.appendChild(bar);

    if (friends.length === 0) {
        body.appendChild(placeholder(view.filter
            ? "Nothing matches that filter."
            : "No friend data yet."));
        return;
    }

    var list = el("div", "flat");
    friends.forEach(function (friend) { list.appendChild(friendRow(friend)); });
    body.appendChild(list);
}

function renderModerated(body, info) {
    var mod = state.moderations;
    var entries = moderated(info.id).filter(function (entry) {
        return matches(moderatedName(entry)) || matches(entry.user_id);
    });

    var bar = el("div", "bar");
    bar.appendChild(el("div", "count", moderationStatus(info)));
    var refresh = el("button", "act small", "REFRESH");
    refresh.disabled = mod.loading || refreshingModerations || state.connected === false;
    refresh.onclick = function () { refreshModerations(refresh); };
    bar.appendChild(refresh);
    body.appendChild(bar);

    if (mod.error) body.appendChild(el("div", "err", mod.error));

    if (entries.length === 0) {
        var why = "Nobody is " + (info.id === "muted" ? "muted" : "blocked") + ".";
        if (mod.loaded === false)
            why = mod.error ? "That list could not be fetched." : "Loading...";
        else if (view.filter) why = "Nothing matches that filter.";
        body.appendChild(placeholder(why));
        return;
    }

    var list = el("div", "flat");
    entries.forEach(function (entry) { list.appendChild(moderatedRow(entry, info)); });
    body.appendChild(list);
}

function moderationStatus(info) {
    var mod = state.moderations;
    if (mod.loading || refreshingModerations) return "Loading...";
    if (mod.loaded === false) return "";

    var count = moderated(info.id).length;
    return count + (count === 1 ? " person" : " people");
}

/* The list carries the name VRChat had for them, which is the only one there
   is when they are not a friend. */
function moderatedName(entry) {
    if (entry.display_name) return entry.display_name;

    var hit = findFriend(entry.user_id);
    return hit ? hit.friend.displayName : entry.user_id;
}

/* Unlike a friend row, this one holds a button of its own: a list of blocked
   people is read in order to unblock somebody, and sending them through the
   detail pane for it is a tap that buys nothing. Which makes the row a
   container and the name its own button - a button inside a button is not a
   thing. */
function moderatedRow(entry, info) {
    var id = entry.user_id;
    var name = moderatedName(entry);
    var hit = findFriend(id);

    var row = el("div", "row");
    if (view.sel && view.sel.id === id) row.classList.add("on");
    row.appendChild(avatar(name, false, hit ? hit.friend : null));

    var who = el("button", "who bare");
    who.appendChild(el("div", "n", name));
    who.appendChild(el("div", "d", hit
        ? (hit.friend.statusDescription || hit.friend.status)
        : "not on your friends list"));
    who.onclick = function () {
        select(hit
            ? { kind: "friend", id: id }
            : { kind: "person", id: id, name: name });
    };
    row.appendChild(who);

    var undo = el("button", "act small", info.undoLabel);
    undo.disabled = pendingModerations[id] === true || state.connected === false;
    undo.onclick = function () { moderate(info.undo, id, undo); };
    row.appendChild(undo);
    return row;
}

/* Mute, block and unfriend for one person, at the foot of their pane: the two
   that are worth a mis-tap sit as far down as the pane goes.

   Mute is one tap either way - it is invisible from the other side and undone
   by pressing the same button again - while block and unfriend arm first:
   both are visible to the other person, and neither is undone by a second
   press. */
function moderationActions(actions, id, canUnfriend) {
    var mod = state.moderations;
    var busy = pendingModerations[id] === true;

    // Which way the toggles point is not known until the lists land, and a
    // MUTE that is really an unmute is worse than no button at all.
    if (mod.loaded === false) {
        actions.appendChild(el("div", "hint", mod.error ||
            "Mute and block state has not arrived yet."));
        return;
    }

    if (isModerated("muted", id))
        actions.appendChild(modButton(id, "unmute", "UNMUTE", busy));
    else
        actions.appendChild(modButton(id, "mute", "MUTE", busy));

    if (isModerated("blocked", id))
        actions.appendChild(modButton(id, "unblock", "UNBLOCK", busy));
    else
        appendArmed(actions, "block|" + id, "BLOCK", "CONFIRM BLOCK", busy,
            function (label) { return modButton(id, "block", label, busy); });

    if (canUnfriend)
        appendArmed(actions, "unfriend|" + id, "UNFRIEND", "CONFIRM UNFRIEND",
            busy, function (label) { return modButton(id, "unfriend", label, busy); });
}

function modButton(id, action, label, busy) {
    var button = el("button", "act", label);
    button.disabled = busy || state.connected === false;
    button.onclick = function () { moderate(action, id, button); };
    return button;
}

function showTool(section) {
    view.tool = section;
    view.sel = null;
    armedAction = "";
    render();
}

/* Fire and forget, like every other action: the outcome arrives in the next
   snapshot, as a result and as lists that have already moved. */
function moderate(action, id, button) {
    // In the map rather than on the button: a snapshot redraws the row or the
    // pane from scratch and would hand back an enabled button otherwise.
    pendingModerations[id] = true;
    armedAction = "";
    var restore = markSending(button);

    fetch("/api/moderation", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: action, user_id: id })
    }).then(function (r) {
        if (r.ok) return;
        delete pendingModerations[id];
        showToast("The vrcd web server refused that", true);
        restore();
    }).catch(function () {
        delete pendingModerations[id];
        showToast("Could not reach the vrcd web server", true);
        restore();
    });
}

/* The lists are asked for once per link connection, so this is what picks up a
   mute or block made in-game: VRChat reports neither. */
function refreshModerations(button) {
    refreshingModerations = true;
    button.disabled = true;

    fetch("/api/moderation", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: "refresh" })
    }).then(function (r) {
        if (r.ok) return;
        showToast("The vrcd web server refused that", true);
    }).catch(function () {
        showToast("Could not reach the vrcd web server", true);
    }).then(function () {
        // The snapshot that carries `loading` takes over from here; this only
        // covers the gap between the press and it arriving.
        refreshingModerations = false;
        if (view.tab === "tools") renderList();
    });
}

/* ------------------------------------------------------------- profile */

/* A profile is fetched, not broadcast. Bio, links, badges and the rest change
   on a different timescale than where somebody is standing, so carrying them
   in the snapshot would fan a few kilobytes per friend out to every browser on
   every friend movement, for a page opened one person at a time.

   It is also the only way to see somebody who is not a friend, which is the
   case this exists for: a friend request arrives as a name and an ID, and
   there is nothing else to decide on.

   Kept per user ID across redraws, the same way images are: the shell redraws
   on every snapshot, and a pane that re-fetched each time would keep both ends
   busy for nothing. The web server holds these too, and expires them, so
   asking again after a while is what refreshes one. */
var profiles = {};
var profileErrors = {};
var profileWaiting = {};

/* IDs that visibly belong to something other than a person. The `usr_` prefix
   is not required the other way round: accounts old enough predate it, and the
   mute and block lists are full of them. */
var NOT_A_USER = /^(grp|wrld|avtr|file|inst|prnt|inv|not)_/;

var PROFILE_RETRY_MS = 700;
/* Roughly 20 seconds. A cold profile is one VRChat call, so this only has to
   outlast a rate-limit pause, not a queue of downloads. */
var PROFILE_TRIES = 30;
/* How long a failure stands before the next look tries again. Most of what
   fails here is temporary - a rate limit, a link that was down - and there is
   no button on this pane to retry with, so the next look is the retry. Long
   enough that a redraw per snapshot does not turn into a fetch per snapshot. */
var PROFILE_ERROR_MS = 30000;

/* What we hold for this person, and a fetch started if we hold nothing. Null
   until one lands, which is what the pane draws its loading line from. */
function profileFor(userId) {
    if (!userId || NOT_A_USER.test(userId)) return null;
    if (profiles[userId]) return profiles[userId];
    if (profileWaiting[userId]) return null;

    var failed = profileErrors[userId];
    if (failed && Date.now() - failed.at < PROFILE_ERROR_MS) return null;

    profileWaiting[userId] = true;
    fetchProfile(userId, PROFILE_TRIES);
    return null;
}

/* What went wrong last time, once it is worth saying. A fetch on its way is
   drawn as loading even when an older failure is still remembered: the retry
   is the more useful thing to report. */
function profileError(userId) {
    if (profileWaiting[userId]) return "";
    var failed = profileErrors[userId];
    return failed ? failed.error : "";
}

function fetchProfile(userId, tries) {
    fetch("/api/user/" + encodeURIComponent(userId)).then(function (r) {
        if (r.status === 202) {
            if (tries > 0) {
                setTimeout(function () { fetchProfile(userId, tries - 1); },
                    PROFILE_RETRY_MS);
            } else {
                profileDone(userId, null, "vrcd-server did not answer in time");
            }
            return null;
        }
        return r.json().then(function (body) {
            if (r.ok) profileDone(userId, body, null);
            else profileDone(userId, null, body.error || "Profile unavailable");
            return null;
        });
    }).catch(function () {
        profileDone(userId, null, "Could not reach the vrcd web server");
    });
}

function profileDone(userId, profile, error) {
    delete profileWaiting[userId];
    if (profile) {
        profiles[userId] = profile;
        delete profileErrors[userId];
    } else {
        profileErrors[userId] = { error: error, at: Date.now() };
    }

    // Only the pane that is waiting on it, and only when it still is: a
    // profile that landed after the user moved on redraws nothing.
    if (view.sel && view.sel.id === userId) renderDetail();
    else if (view.tab === "profile" && state.self && state.self.id === userId)
        renderList();
}

/* A dropped link is not a reason to forget a profile, but a new one is a
   reason to stop remembering that a fetch failed while it was down. */
function forgetProfileErrors() {
    profileErrors = {};
}

/* Fields the snapshot is the authority on, even when it says nothing. These
   are the ones that move: a status cleared a second ago is empty on purpose,
   and letting a profile fetched five minutes back fill it back in would put a
   stale message under a live dot. An offline friend's blank platform is the
   same kind of deliberate silence.

   Everything outside this list follows the opposite rule, since the snapshot
   is the thinner record: what it leaves out, the profile answers.

   `displayName` is not one of them: it is live in the roster but the roster
   never leaves it blank, so the general rule already picks the same value --
   and staying out of the live list is what lets a pane seeded with nothing but
   an ID take the real name from the profile when it lands. */
var LIVE_FIELDS = {
    status: true, statusDescription: true, platform: true, location: true
};

/* The snapshot and the profile describe the same person at two speeds. */
function mergeProfile(person, full) {
    if (!full) return person;

    var merged = {};
    var key;
    for (key in full) if (full.hasOwnProperty(key)) merged[key] = full[key];
    for (key in person) {
        if (person.hasOwnProperty(key) === false) continue;
        if (person[key] === undefined) continue;

        if (LIVE_FIELDS[key] === true) { merged[key] = person[key]; continue; }

        if (person[key] === "") continue;
        if (key === "bioLinks" && person[key].length === 0) continue;
        // The picture is a file and a version together. Taking the version
        // from a record that carries no file would point it at the profile's
        // file at the wrong version, which fetches nothing.
        if (key === "imageVersion" && !person.imageFileId) continue;
        merged[key] = person[key];
    }
    return merged;
}

/* One profile layout for everybody: your own on the profile tab, a friend from
   the roster, and a stranger who sent a friend request. Rows appear only when
   the field is there, which is what lets one layout serve all three - a friend
   request sender is a thinner record than a friend, not a different kind of
   thing. */
function renderProfile(body, person, opts) {
    var full = profileFor(person.id);
    var p = mergeProfile(person, full);

    var hero = el("div", "hero");
    /* The face opens full size. Every place this page draws a profile picture
       crops it to a circle, so the picture somebody actually uploaded is not
       otherwise on screen anywhere. */
    var face = avatar(p.displayName || "?", true, p);
    if (p.imageFileId)
        viewable(face, { id: p.imageFileId, version: p.imageVersion || 1 },
            p.displayName || "Profile picture", AV_BIG_SIZE);
    hero.appendChild(face);
    hero.appendChild(el("div", "name", p.displayName || p.id));

    // Pronouns ride with the name rather than sitting in a row further down:
    // they are part of how somebody is addressed, and a row would put them
    // below the fold on a phone.
    if (p.pronouns) hero.appendChild(el("div", "pronouns", p.pronouns));

    var sub = el("div", "sub");
    sub.appendChild(statusDot(p.status));
    sub.appendChild(document.createTextNode(" " +
        (p.statusDescription || p.status || "unknown")));
    hero.appendChild(sub);

    var marks = profileMarks(p, opts);
    if (marks) hero.appendChild(marks);
    body.appendChild(hero);

    // Directly under the hero, above everything else: on your own profile this
    // is the reason the tab is open. It comes before the two things below that
    // arrive late, so neither can push the picker down under a thumb already
    // on its way to it.
    if (opts.editStatus) statusEditor(body, person);

    // Not on your own profile: nothing there is waiting on the fetch, and a
    // line that appears and then goes is only a shift.
    if (full === null && person.id && opts.editStatus === undefined) {
        var why = profileError(person.id);
        body.appendChild(el("div", "hint", why || "Loading profile..."));
    }

    // Open, the editor stands in for the three blocks below that it covers:
    // they would otherwise sit above their own boxes saying the same thing.
    var editing = opts.editStatus === true && profileDraft !== null;
    if (opts.editStatus) profileEditor(body, p, full !== null);

    if (p.badges && p.badges.length) {
        body.appendChild(el("div", "section", "Badges")); // padding
        body.appendChild(badgeStrip(p.badges));
    }

    // Its own block rather than a row in the list: a bio runs to 512
    // characters over as many lines as somebody felt like, and a definition
    // list is the wrong shape for a paragraph.
    if (p.bio && editing === false) {
        body.appendChild(el("div", "section", "Bio"));
        body.appendChild(el("div", "bio", p.bio));
    }

    if (p.bioLinks && p.bioLinks.length && editing === false) {
        body.appendChild(el("div", "section", "Links"));
        var links = el("dl", "kv");
        p.bioLinks.forEach(function (url, index) {
            var dd = el("dd");
            dd.appendChild(profileLink(url));
            links.appendChild(el("dt", null, "#" + (index + 1)));
            links.appendChild(dd);
        });
        body.appendChild(links);
    }

    body.appendChild(el("div", "section", "Details"));
    var kv = el("dl", "kv");
    // The picker already says which one is on, and says it larger.
    if (opts.editStatus === undefined)
        pair(kv, "Status", p.status || "unknown");
    if (p.platform)
        pair(kv, "Platform", PLATFORMS[p.platform] || p.platform);
    if (opts.where) pair(kv, "Where", opts.where);
    if (p.languages && p.languages.length && editing === false)
        pair(kv, "Languages", p.languages.map(languageName).join(", "));
    if (p.dateJoined) pair(kv, "Joined", whenDay(p.dateJoined));
    // Only for somebody who is not standing somewhere we can already see, and
    // never for yourself: "last seen" about the person reading it is noise.
    if (p.lastActivity && opts.where === undefined && opts.editStatus === undefined)
        pair(kv, "Last seen", whenDate(p.lastActivity));
    // VRChat's own private memo about this person, which only you can see.
    if (p.note) pair(kv, "Note", p.note);
    pair(kv, "User ID", p.id);
    body.appendChild(kv);

    var actions = el("div", "actions");
    if (opts.location) actions.appendChild(joinButton(opts.location, "SELF-INVITE"));
    actions.appendChild(copyButton("Copy user ID", p.id));
    // Last, and only for someone else: nothing here is aimed at yourself, and
    // the pane's own order is what keeps a block away from a self-invite.
    if (opts.moderate) moderationActions(actions, p.id, opts.friend === true);
    body.appendChild(actions);
}

/* One of the links pinned under a bio, as something safe to press. VRChat
   stores whatever it was handed, and an href is not only ever a link:
   `javascript:` in one is script, running on a signed-in page, out of a field
   any account can write. The two schemes that are links become an anchor and
   everything else stays text, which is still readable and still copyable. */
function profileLink(url) {
    if (/^https?:\/\//i.test(url) === false) return el("span", null, url);

    var a = el("a", null, url);
    a.href = url;
    a.rel = "noopener noreferrer";
    a.target = "_blank";
    return a;
}

/* The row of pills under the name: trust rank, and the marks that qualify it.
   Together they are most of what there is to go on when a friend request
   arrives from a name nobody recognises, so they sit in the hero rather than
   in the list of fields below it. */
function profileMarks(p, opts) {
    var marks = el("div", "marks");

    if (p.trustRank)
        marks.appendChild(el("span", "pill rank " + rankClass(p.trustRank),
            p.trustRank.toUpperCase()));
    if (p.moderator) marks.appendChild(el("span", "pill staff", "VRCHAT TEAM"));
    // VRChat's own word for an account it has flagged. Worth the space on the
    // one screen where somebody is deciding whether to let a stranger in.
    if (p.troll) marks.appendChild(el("span", "pill bad", "FLAGGED"));
    if (p.ageVerified) marks.appendChild(el("span", "pill", "18+ VERIFIED"));
    /* Only said when it is news: every friend's pane would otherwise carry a
       pill saying they are a friend. Taken from the caller, which read the
       roster, rather than from the profile's own `isFriend`: accepting a
       request makes somebody a friend within a snapshot, while the profile
       saying so is a fetch away. */
    if (opts.friend === false)
        marks.appendChild(el("span", "pill", "NOT A FRIEND"));

    return marks.childNodes.length ? marks : null;
}

function rankClass(rank) {
    switch (rank) {
    case "Trusted User": return "r5";
    case "Known User":   return "r4";
    case "User":         return "r3";
    case "New User":     return "r2";
    default:             return "r1";
    }
}

/* Badge art is the one picture with no file behind it: badges live on a public
   CDN rather than behind VRChat's authenticated files API, so the proxy is
   handed the URL instead. It still goes through the proxy - this page makes no
   external requests, since one that phoned out would break behind a tunnel and
   would tell VRChat's CDN who is looking at whom. A badge whose art does not
   arrive keeps its name, which is the part that means something. */
function badgeStrip(badges) {
    var strip = el("div", "badges");

    // Showcased first: that flag is the user saying which of these they want
    // seen, and a profile with a dozen of them scrolls otherwise.
    var sorted = badges.slice().sort(function (a, b) {
        return (b.showcased === true) - (a.showcased === true);
    });

    sorted.forEach(function (badge) {
        var box = el("div", "badge" + (badge.showcased ? " showcased" : ""));
        box.title = badge.description
            ? badge.name + " - " + badge.description
            : badge.name;

        if (badge.imageUrl) {
            var img = document.createElement("img");
            img.alt = "";
            box.appendChild(img);
            badgeInto(img, badge.imageUrl);
        }
        box.appendChild(el("div", "bn", badge.name));
        strip.appendChild(box);
    });
    return strip;
}

/* VRChat tags languages with ISO 639-3 codes. The common ones are named; the
   rest keep their code, which is at least what the game shows. */
var LANGUAGES = {
    eng: "English",  jpn: "Japanese", kor: "Korean",   zho: "Chinese",
    cmn: "Chinese",  spa: "Spanish",  por: "Portuguese", fra: "French",
    deu: "German",   rus: "Russian",  ita: "Italian",  nld: "Dutch",
    pol: "Polish",   swe: "Swedish",  dan: "Danish",   nor: "Norwegian",
    fin: "Finnish",  ces: "Czech",    tur: "Turkish",  ara: "Arabic",
    tha: "Thai",     vie: "Vietnamese", ind: "Indonesian", ukr: "Ukrainian",
    hun: "Hungarian", ron: "Romanian", heb: "Hebrew",  hin: "Hindi",
    fil: "Filipino", ell: "Greek",    tok: "Toki Pona"
};

function languageName(code) {
    return LANGUAGES[code] || code.toUpperCase();
}

/* Your own status, on your own profile. The four are always open rather than
   behind a dropdown: this pane has the room, and hiding them trades one press
   for two plus a smaller target to find first. They are the same rows the
   friends list is built from, which is what a dropdown's opened menu looks like
   anyway.

   A press selects rather than sends. Two reasons, and both are about this being
   a list inside a scrolling pane: a stationary mis-tap on the way to the message
   box would otherwise reach VRChat, and a status and a message picked together
   would cost two calls instead of the one `set_status` that carries both. The
   SDL client stages the same way.

   Which means two states have to be legible at once, and the two the app already
   draws split cleanly: the accent band is what SET STATUS will send, the tick is
   what VRChat has. They sit on the same row until a pick separates them. */
function statusEditor(body, self) {
    var busy = statusPending ||
        (state.status_action !== undefined && state.status_action.pending === true);
    var offline = state.connected === false;
    var liveStatus = self.status;
    var live = self.statusDescription || "";
    var picked = statusChoice === null ? liveStatus : statusChoice;
    var typed = statusDraft === null ? live : statusDraft;
    var dirty = picked !== liveStatus || typed !== live;

    body.appendChild(el("div", "section", "Status"));

    var list = el("div", "flat status-list");
    STATUS_CHOICES.forEach(function (choice) {
        var row = el("button", "row" + (picked === choice.value ? " on" : ""));
        row.appendChild(statusDot(choice.value, true));

        var who = el("div", "who");
        who.appendChild(el("div", "n", choice.label));
        row.appendChild(who);

        if (liveStatus === choice.value) row.appendChild(el("span", "tick", "✓"));

        row.disabled = busy || offline;
        // Staged, not sent. A redraw is what moves the accent, and it also puts
        // the caret back in the message box (see renderList), so typing a
        // message and then picking a status does not lose the typing.
        row.onclick = function () {
            statusChoice = choice.value;
            renderList();
        };
        list.appendChild(row);
    });
    body.appendChild(list);

    var box = el("input", "note-input status-message");
    box.id = "statusMessage";
    box.type = "text";
    box.placeholder = "Custom status message";
    box.maxLength = STATUS_MESSAGE_MAX;
    box.value = typed;
    box.disabled = busy || offline;
    body.appendChild(box);

    var ready = busy === false && offline === false && dirty;
    var save = el("button", "act" + (ready ? " primary" : ""),
        busy ? "SENDING..." : "SET STATUS");
    save.disabled = ready === false;
    // Read at the press rather than closed over: typing does not redraw the
    // pane, so `typed` is already out of date by the time this runs. Only what
    // actually changed is sent, so the request says what was asked for.
    save.onclick = function () {
        var choice = statusChoice === null ? liveStatus : statusChoice;
        var message = statusDraft === null ? live : statusDraft;
        sendStatus(choice === liveStatus ? "" : choice,
            message === live ? null : message);
    };
    body.appendChild(save);

    // The button is armed from here rather than through a redraw: a redraw per
    // keypress would take the caret with it.
    box.oninput = function (ev) {
        statusDraft = ev.target.value;
        save.disabled = busy || offline ||
            (picked === liveStatus && statusDraft === live);
        save.classList.toggle("primary", save.disabled === false);
    };
    box.onkeydown = function (ev) {
        if (ev.key === "Enter" && save.disabled === false) save.onclick();
    };

    if (busy === false && state.status_action !== undefined &&
        state.status_action.error)
        body.appendChild(el("div", "err", state.status_action.error));
}

/* The rest of your own profile: the bio, the links pinned under it, pronouns,
   and the languages you speak. Behind a button rather than always open, unlike
   the status picker above it. Two reasons: this is five boxes of text where
   that is four rows, and a form standing open on a tab that redraws itself
   every time a friend moves is a form somebody edits by accident.

   Open, it stands in for the blocks it covers (see renderProfile), so a bio is
   either being read or being written, never both at once. It is seeded from the
   fetched profile rather than from the roster: the roster carries no languages
   at all, and a form seeded without them would clear them the first time it
   saved. So the button waits for the profile to land. */
function profileEditor(body, p, ready) {
    // An older vrcd-server answers `set_profile` with an error, so the button
    // is not offered at all rather than failing when it is pressed.
    if (state.can_edit_profile === false) return;

    var busy = profilePending ||
        (state.profile_action !== undefined && state.profile_action.pending === true);
    var offline = state.connected === false;

    if (profileDraft === null) {
        // Spaced off the picker above it: two full-width buttons touching read
        // as a pair, and a slip off SET STATUS is the one that reaches VRChat.
        // The gap is the same one the section heading gives when this is open.
        var open = el("button", "act edit-profile", "EDIT PROFILE");
        open.disabled = ready === false || offline || busy;
        open.onclick = function () {
            profileDraft = profileDraftOf(p);
            renderList();
        };
        body.appendChild(open);
        return;
    }

    body.appendChild(el("div", "section", "Bio"));
    var bio = el("textarea", "note-input bio-input");
    bio.id = "profileBio";
    bio.rows = 6;
    bio.maxLength = BIO_MAX;
    bio.placeholder = "Anything you want on your profile";
    bio.value = profileDraft.bio;
    bio.disabled = busy || offline;
    body.appendChild(bio);

    // Under the box rather than beside the heading: what it counts is what is
    // in the box, and VRChat cuts a bio that runs past it.
    var count = el("div", "hint", bioCount(profileDraft.bio));
    body.appendChild(count);

    body.appendChild(el("div", "section", "Links"));
    var links = el("div", "fields");
    // Always all three, since VRChat takes three: an empty one is a row to
    // type into, which is one press fewer than a button that adds one.
    profileDraft.links.forEach(function (url, index) {
        var box = el("input", "note-input");
        box.id = "profileLink" + index;
        box.type = "url";
        box.placeholder = "https://";
        box.value = url;
        box.disabled = busy || offline;
        box.oninput = function (ev) {
            profileDraft.links[index] = ev.target.value;
            arm();
        };
        links.appendChild(box);
    });
    body.appendChild(links);

    body.appendChild(el("div", "section", "Pronouns"));
    var pronouns = el("input", "note-input");
    pronouns.id = "profilePronouns";
    pronouns.type = "text";
    pronouns.maxLength = PRONOUNS_MAX;
    pronouns.placeholder = "they/them";
    pronouns.value = profileDraft.pronouns;
    pronouns.disabled = busy || offline;
    body.appendChild(pronouns);

    body.appendChild(el("div", "section", "Languages"));
    body.appendChild(languagePicker(busy || offline));

    var actions = el("div", "actions");
    var save = el("button", "act", busy ? "SAVING..." : "SAVE PROFILE");
    save.onclick = function () { sendProfile(p); };
    actions.appendChild(save);

    // Not aligned with SAVE and not a confirm: what it discards is text that is
    // still on screen, and the way back is to type it again.
    var cancel = el("button", "act", "CANCEL");
    cancel.disabled = busy;
    cancel.onclick = function () {
        profileDraft = null;
        renderList();
    };
    actions.appendChild(cancel);
    body.appendChild(actions);

    if (busy === false && state.profile_action !== undefined &&
        state.profile_action.error)
        body.appendChild(el("div", "err", state.profile_action.error));

    /* SAVE follows what is in the boxes, and typing does not redraw the pane
       (a redraw would take the caret with it), so it is armed from here. */
    function arm() {
        var dirty = Object.keys(profileChanges(p)).length > 0;
        save.disabled = busy || offline || dirty === false;
        save.classList.toggle("primary", save.disabled === false);
    }

    bio.oninput = function (ev) {
        profileDraft.bio = ev.target.value;
        count.textContent = bioCount(profileDraft.bio);
        arm();
    };
    pronouns.oninput = function (ev) {
        profileDraft.pronouns = ev.target.value;
        arm();
    };
    arm();
}

function bioCount(text) {
    // Code points, which is what VRChat counts. `length` would count UTF-16
    // units, and a bio of emoji would read as twice what VRChat sees -- the
    // box's own maxlength counts those units too, so it stops a little early
    // rather than a little late, which is the right way round.
    return Array.from(text).length + " / " + BIO_MAX;
}

/* The languages already picked, each one press away from going, and a list to
   add one from. A picked language is a chip rather than a row: three of them
   fit on one line, and the list they come from is thirty entries long.

   The list is the same names the profile is read with, so a language VRChat
   knows and this page does not cannot be added here -- it can still be kept,
   since a chip is drawn from the code either way. */
function languagePicker(disabled) {
    var box = el("div");

    var chips = el("div", "chips");
    profileDraft.languages.forEach(function (code) {
        var chip = el("button", "chip on");
        chip.appendChild(el("span", null, languageName(code)));
        chip.appendChild(el("span", "n", "REMOVE"));
        chip.disabled = disabled;
        chip.onclick = function () {
            profileDraft.languages = profileDraft.languages.filter(
                function (held) { return held !== code; });
            renderList();
        };
        chips.appendChild(chip);
    });
    if (profileDraft.languages.length === 0)
        chips.appendChild(el("div", "hint", "None set."));
    box.appendChild(chips);

    var full = profileDraft.languages.length >= LANGUAGES_MAX;
    var add = el("select", "note-input");
    add.id = "profileLanguage";
    add.disabled = disabled || full;
    var head = el("option", null,
        full ? "VRChat takes " + LANGUAGES_MAX + " languages" : "Add a language...");
    // Explicit, since an option with no value of its own is its own text.
    head.value = "";
    add.appendChild(head);

    Object.keys(LANGUAGES).map(function (code) {
        return { code: code, name: LANGUAGES[code] };
    }).filter(function (entry) {
        return profileDraft.languages.indexOf(entry.code) < 0;
    }).sort(function (a, b) {
        return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0);
    }).forEach(function (entry) {
        var option = el("option", null, entry.name);
        option.value = entry.code;
        add.appendChild(option);
    });

    // A pick is staged like everything else here: it moves a chip, and nothing
    // reaches VRChat until SAVE PROFILE.
    add.onchange = function (ev) {
        if (ev.target.value === "") return;
        profileDraft.languages = profileDraft.languages.concat([ ev.target.value ]);
        renderList();
    };
    box.appendChild(add);
    return box;
}

/* The draft the editor opens with: what VRChat has, in the shape the boxes
   want. The links are padded to three so every box exists whether or not it
   has anything in it. */
function profileDraftOf(p) {
    var links = (p.bioLinks || []).slice(0, LINKS_MAX);
    while (links.length < LINKS_MAX) links.push("");

    return {
        bio: p.bio || "",
        pronouns: p.pronouns || "",
        links: links,
        languages: (p.languages || []).slice()
    };
}

/* What the draft changes about the profile VRChat has, as the body to send.
   Only the fields that actually moved: an untouched one costs a VRChat call
   for nothing, and two browsers open on the same profile would otherwise write
   each other's stale fields back over each other. */
function profileChanges(p) {
    var body = {};

    if (profileDraft.bio !== (p.bio || "")) body.bio = profileDraft.bio;
    if (profileDraft.pronouns.trim() !== (p.pronouns || ""))
        body.pronouns = profileDraft.pronouns.trim();

    // A blank box is a link not filled in, which is also how one is removed.
    var links = profileDraft.links.map(function (url) { return url.trim(); })
        .filter(function (url) { return url.length > 0; });
    if (sameStrings(links, p.bioLinks || []) === false) body.bio_links = links;

    if (sameStrings(profileDraft.languages, p.languages || []) === false)
        body.languages = profileDraft.languages;

    return body;
}

function sameStrings(a, b) {
    if (a.length !== b.length) return false;
    for (var i = 0; i < a.length; i++) {
        if (a[i] !== b[i]) return false;
    }
    return true;
}

/* Send what the editor changed. Nothing to send closes it: pressing SAVE on a
   draft that matches what VRChat has is the same intent as CANCEL, and the
   round trip would say nothing back. The outcome arrives in the next
   snapshot. */
function sendProfile(p) {
    var body = profileChanges(p);
    if (Object.keys(body).length === 0) {
        profileDraft = null;
        renderList();
        return;
    }

    profilePending = true;
    if (view.tab === "profile") renderList();

    fetch("/api/profile", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body)
    }).then(function (r) {
        if (r.ok) return;
        profilePending = false;
        showToast("The vrcd web server refused that edit", true);
        if (view.tab === "profile") renderList();
    }).catch(function () {
        profilePending = false;
        showToast("Could not reach the vrcd web server", true);
        if (view.tab === "profile") renderList();
    });
}

function renderProfileTab(body) {
    if (state.self) {
        renderProfile(body, state.self, { editStatus: true });
    } else {
        body.appendChild(placeholder("Not signed in to VRChat yet."));
    }

    body.appendChild(el("div", "section", "Connection"));
    var conn = el("dl", "kv");
    pair(conn, "vrcd", state.connected ? "connected" : "disconnected");
    pair(conn, "Protocol", state.server_version ? "v" + state.server_version : "unknown");
    pair(conn, "VRChat", state.vrchat_connected ? "connected" : "disconnected");
    if (state.last_error) pair(conn, "Last error", state.last_error);
    body.appendChild(conn);

    // vrcd-server's store, not this page's feed: the event count is everything
    // ever logged, while the feed holds the last page of it. Absent until the
    // link has answered once, which is why the whole block is conditional
    // rather than showing zeroes.
    if (state.database) {
        body.appendChild(el("div", "section", "Database"));
        var db = el("dl", "kv");
        pair(db, "Events", countText(state.database.event_count));
        pair(db, "Worlds cached", countText(state.database.world_cache_count));
        pair(db, "Avatars cached", countText(state.database.avatar_cache_count));
        pair(db, "Size", sizeText(state.database.size_bytes));
        body.appendChild(db);
    }
}

/* Thousands separators, since these run to six figures and a wall of digits is
   unreadable at a glance. */
function countText(value) {
    return (value || 0).toLocaleString();
}

function sizeText(value) {
    var n = value || 0;
    var units = ["B", "KB", "MB", "GB"];
    var i = 0;
    while (n >= 1024 && i < units.length - 1) {
        n /= 1024;
        i++;
    }
    // Whole bytes, one decimal above that: "12.4 MB" says as much as the exact
    // figure and stays the same width as it grows.
    return (i === 0 ? n : n.toFixed(1)) + " " + units[i];
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

    rememberCaret(body);
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
    else if (tab.id === "tools")   renderTools(body);
    else if (tab.id === "profile") renderProfileTab(body);

    // Last, once every box the tab draws is in the document: focus does
    // nothing to a node that is not.
    restoreCaret();
}

/* Where the caret was when a redraw started, so it can be put back afterwards.
   A snapshot arrives on every friend movement and takes every box on the page
   with it; without this, typing a bio next to a busy friends list would lose a
   character every few seconds.

   Read just before the redraw rather than from a blur handler, because
   browsers disagree about whether removing a focused node fires one. Only
   boxes inside the pane being redrawn count: the search field survives the
   redraw, and re-focusing it would collapse a selection nobody asked to lose. */
var caretBox = null;

function rememberCaret(pane) {
    var box = document.activeElement;
    var typed = box && (box.tagName === "INPUT" || box.tagName === "TEXTAREA");

    caretBox = typed && box.id && pane.contains(box)
        ? { id: box.id, at: box.selectionStart }
        : null;
}

function restoreCaret() {
    if (caretBox === null) return;

    var box = document.getElementById(caretBox.id);
    if (box === null) return;

    box.focus();
    box.setSelectionRange(caretBox.at, caretBox.at);
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
        friend: true,
        where: group
            ? groupName(group)
            : (friend.status === "offline" ? "offline" : "not in a world"),
        location: group ? group.location : "",
        // Offered wherever a friend's pane is, not only under the tools tab:
        // the pane is the same one either way, and muting somebody is usually
        // decided while looking at where they are.
        moderate: true
    });
}

/* Somebody who is not on the friends list: whoever sent a friend request, and
   whoever is in the mute or block list (a moderation outlives the friendship
   it started in, and can be aimed at somebody who never was one).

   The roster has nothing on them at all, so the pane is the fetched profile
   and nothing else - which is the whole point of it. Until it lands there is
   the name the list or the notification came with, which is what the hero is
   seeded with here. */
function detailPerson(body, id, name) {
    document.getElementById("detailTitle").textContent = name;
    // A notification whose sender vrcd-server could not name arrives as the ID
    // over again. Passing that as a display name would keep it there after the
    // profile lands with the real one.
    renderProfile(body, { id: id, displayName: name === id ? "" : name }, {
        friend: false,
        moderate: true
    });
}

function joinButton(location, label, iconName) {
    var button = iconName
        ? iconAct("act primary", label, iconName)
        : el("button", "act primary", label);
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
        if (view.tab === "inbox") nothing = "Pick a sender to see their profile.";
        else if (view.tab === "stuff") nothing = "Pick something.";
        else if (view.tab === "tools") nothing = "Pick someone.";
        body.appendChild(placeholder(nothing));
        return;
    }

    if (view.sel.kind === "person") {
        // Somebody opened as a stranger who has since turned up in the roster:
        // accepting their friend request is the way that happens, and the pane
        // they are looking at should become the friend's, where they are and
        // how to reach them. The snapshot after the accept is what does it.
        var known = findFriend(view.sel.id);
        if (known) detailFriend(body, known.friend, known.group);
        else detailPerson(body, view.sel.id, view.sel.name);
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
    // Every node the observer was watching is about to be replaced, and an
    // IntersectionObserver holds on to its targets, so the watch list is
    // dropped here rather than grown by one screenful per snapshot. Fetches
    // already in flight are keyed by file, not by node, and land in whatever
    // node is on screen when they arrive.
    if (imageObserver) imageObserver.disconnect();

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

/* Send a status change. `status` empty leaves the status alone, `message` null
   leaves the message alone; an empty message clears it, which is why the two
   are not the same thing. The outcome comes back in the next snapshot. */
function sendStatus(status, message) {
    var body = {};
    if (status) body.status = status;
    if (message !== null) body.status_description = message;

    statusPending = true;
    if (view.tab === "profile") renderList();

    fetch("/api/status", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body)
    }).then(function (r) {
        if (r.ok) return;
        statusPending = false;
        showToast("The vrcd web server refused that status", true);
        if (view.tab === "profile") renderList();
    }).catch(function () {
        statusPending = false;
        showToast("Could not reach the vrcd web server", true);
        if (view.tab === "profile") renderList();
    });
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

function notifyAct(entry, action, button, response) {
    var id = entry.id;
    // Marked in the map rather than on the button: the next snapshot redraws
    // the card from scratch and would hand back an enabled button otherwise.
    pendingNotifications[id] = true;
    var restore = markSending(button);

    fetch("/api/notification", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
            notification_id: id,
            action: action,
            // Which system this notification belongs to: the endpoints for
            // the two do not overlap, so the server has to be told.
            api_version: entry.api_version || 1,
            response_type: response ? response.type : "",
            response_data: response ? response.data : ""
        })
    }).then(function (r) {
        if (r.ok) return;
        delete pendingNotifications[id];
        showToast("The vrcd web server refused that", true);
        restore();
    }).catch(function () {
        delete pendingNotifications[id];
        showToast("Could not reach the vrcd web server", true);
        restore();
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
    if (!state.moderations)
        state.moderations = { loading: false, loaded: false, error: "",
                              muted: [], blocked: [] };

    // A notification that left the snapshot is answered, however it was
    // answered: by us, by another client, or by VRChat itself. Pruned before
    // the draw so the row never comes back wearing "SENDING...".
    Object.keys(pendingNotifications).forEach(function (id) {
        var stillThere = state.notifications.some(function (e) { return e.id === id; });
        if (stillThere === false) delete pendingNotifications[id];
    });

    // A link that went down takes the answer with it, so the picker goes back
    // to being pressable rather than sitting on "SAVING..." for an answer that
    // is never coming.
    if (state.connected === false) {
        statusPending = false;
        // Same for a profile edit. The draft stays: what is in it is typing
        // nobody would want dropped by a reconnect, and the link comes back.
        profilePending = false;
        profileWasPending = false;
        // Same for a moderation: the result it is waiting on died with the
        // link, and a button stuck on "SENDING..." is worse than one that can
        // be pressed again.
        pendingModerations = {};
        refreshingModerations = false;
        linkWasDown = true;
    } else if (linkWasDown) {
        // Profiles that failed while the link was down failed for a reason
        // that has just gone away. What was actually fetched stays.
        linkWasDown = false;
        forgetProfileErrors();
        // Pictures the same way, and this is the common case rather than the
        // odd one: a proxied image asked for while the link was down is
        // refused on the spot, and a roster is hundreds of faces. The render
        // below is what asks for them again.
        forgetImageErrors();
    }

    render();
    // Each reporter is told whether this is the first snapshot this page has
    // seen, which is flipped here rather than in them: a first snapshot
    // carrying no outcome at all still counts as seen, or the first real one
    // would be swallowed as though it predated the page.
    var seeding = seeded === false;
    seeded = true;
    reportJoin(seeding);
    reportNotifyAction(seeding);
    reportContentAction(seeding);
    reportModeration(seeding);
    reportStatus(seeding);
    reportProfile();
    syncContent();
}

/* A profile edit that has been answered. Watched as the snapshot's pending flag
   falling rather than as its outcome changing, unlike every other reporter
   here: the same edit sent twice is identical in the snapshot, and an editor
   that had already gone back to saying SAVE would be the only sign that
   anything happened. It also makes a seeding pass unnecessary -- a page that
   opens on somebody else's old outcome never saw it pending. */
function reportProfile() {
    var result = state.profile_action;
    if (!result || !result.attempted) return;

    if (result.pending) {
        profileWasPending = true;
        return;
    }
    if (profileWasPending === false) return;
    profileWasPending = false;

    // Ours, rather than another browser's: that one's success should not close
    // an editor with typing in it, and its failure is not this page's to
    // explain. The toast is said either way -- it is the same profile.
    var mine = profilePending;
    profilePending = false;

    if (result.success) {
        // The copy held here describes the profile as it was. vrcd-server and
        // the link have both dropped theirs, so the next look re-fetches -- and
        // it has to, since a cleared field is empty in the `self` snapshot and
        // the merge lets the older record win there.
        if (state.self) delete profiles[state.self.id];
        if (mine) profileDraft = null;
    }
    if (view.tab === "profile") renderList();

    showToast(result.success
        ? "Profile updated"
        : "Profile change failed: " + result.error, !result.success);
}

function reportStatus(seeding) {
    var result = state.status_action;
    if (!result || !result.attempted || result.pending) return;

    // Like the join result, the snapshot carries the last one indefinitely, so
    // only say something when it actually changed.
    var key = result.status + "|" + result.statusDescription + "|" +
        result.success + "|" + result.error;
    if (key === lastStatusKey) return;
    lastStatusKey = key;

    // Already there when the page opened, so it is not news, and whoever did it
    // has been told once already.
    if (seeding) return;

    statusPending = false;
    // What was staged is what VRChat now has, so both go back to following the
    // snapshot; either one left behind would keep SET STATUS armed against it.
    if (result.success) {
        statusChoice = null;
        statusDraft = null;
    }
    if (view.tab === "profile") renderList();

    showToast(result.success
        ? "Status updated"
        : "Status change failed: " + result.error, !result.success);
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

function reportContentAction(seeding) {
    var result = state.content_action;
    if (!result || !result.attempted) return;

    // Same as the join and notification results: the snapshot carries the last
    // one indefinitely, so only say something when it actually changed.
    var key = result.id + "|" + result.action + "|" +
        result.success + "|" + result.error;
    if (key === lastActionKey) return;
    lastActionKey = key;

    // Already there when the page opened, so it is not news. Nothing below is
    // worth doing either: a page this new has no press in flight to answer.
    if (seeding) return;

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

function reportModeration(seeding) {
    var result = state.moderation_action;
    if (!result || !result.attempted) return;

    // Same as the rest: the snapshot carries the last one indefinitely, so
    // only say something when it actually changed.
    var key = result.user_id + "|" + result.action + "|" +
        result.success + "|" + result.error;
    if (key === lastModKey) return;
    lastModKey = key;

    // Old news to a page that just opened, and the lists in the snapshot
    // already show where the mute or block landed.
    if (seeding) return;

    delete pendingModerations[result.user_id];
    armedAction = "";
    // The pane redraws whichever tab it is on: a friend's buttons are the same
    // ones under online as under tools.
    if (view.tab === "tools") renderList();
    renderDetail();

    var who = result.display_name || result.user_id;
    if (result.success) {
        showToast((MOD_DONE[result.action] || "Done") + " " + who, false);
        return;
    }
    showToast("That failed: " + result.error, true);
}

function reportNotifyAction(seeding) {
    var result = state.notify_action;
    if (!result || !result.attempted) return;

    // Like the join result, the snapshot carries this indefinitely, so only
    // say something when it actually changed.
    var key = result.notification_id + "|" + result.action + "|" +
        result.success + "|" + result.error;
    if (key === lastNotifyKey) return;
    lastNotifyKey = key;

    // The confirmation is worth saying for a press -- the buttons in a row sit
    // side by side and an accept is not a dismiss -- but a page that just
    // opened pressed nothing, and the notification it names is long gone from
    // the inbox anyway.
    if (seeding) return;

    if (result.success) {
        showToast(NOTIFY_DONE[result.action] || "Done", false);
        return;
    }

    // A failure leaves the row where it was, so give its buttons back.
    delete pendingNotifications[result.notification_id];
    if (view.tab === "inbox") renderList();
    showToast("That failed: " + result.error, true);
}

function reportJoin(seeding) {
    var join = state.join;
    if (!join || !join.attempted) return;

    // The snapshot carries the last result indefinitely; only surface it when
    // it actually changed, so a reconnect does not replay an old toast.
    var key = join.location + "|" + join.success + "|" + join.error;
    if (key === lastJoinKey) return;
    lastJoinKey = key;

    // An invite somebody asked for an hour ago is not news to a page that just
    // opened, and "check VRChat" points at a notification already read.
    if (seeding) return;

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

    // A socket that opened means the web server is answering again, which is
    // the other half of the story above: while it was away every image fetch
    // failed on the network rather than on an answer. A snapshot follows this
    // immediately, so nothing needs redrawing here.
    socket.onopen = function () {
        forgetImageErrors();
    };

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

/* Escape leaves the viewer and the crop modal but not the sign-in one: the
   server is blocked waiting on that answer, and a stray key is not one. The
   viewer goes first, being the one that can be opened over the other. */
document.addEventListener("keydown", function (ev) {
    if (ev.key !== "Escape") return;
    if (viewer)    closeViewer();
    else if (crop) closeCrop();
});

window.addEventListener("resize", function () {
    layoutCrop();
    // The frame changed size under a picture that may be zoomed into a corner
    // of it, so what was against an edge has to be pulled back to one.
    clampViewer();
    drawViewer();
});

watchDrops();
render();
connect();

/* Registered last and on load: the worker is what makes the browser offer to
   install the page, and none of the screen depends on it, so it waits until
   the shell is drawn and the socket is on its way. Registration only happens
   on a secure origin -- https, or localhost -- so a plain-http LAN address
   fails here, which is not worth interrupting the page over. */
if ("serviceWorker" in navigator)
    window.addEventListener("load", function () {
        navigator.serviceWorker.register("/sw.js").catch(function (err) {
            console.log("service worker not registered:", err);
        });
    });
