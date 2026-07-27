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
    { id: "stuff",    label: "STUFF",    icon: "i-stuff",   soon: true },
    { id: "tools",    label: "TOOLS",    icon: "i-tools",   soon: true },
    /* The rail opens the profile through the self card at its foot, so only
       the bottom bar, which has no foot, draws a button for it. */
    { id: "profile",  label: "PROFILE",  icon: "i-profile", foot: true }
];

var SOON_TEXT = {
    stuff: "Gallery, prints and icons come from get_files and get_prints, " +
           "which need an image proxy in front of them first.",
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

var TITLES = {
    feed: "Feed", online: "Online", inbox: "Inbox",
    stuff: "Stuff", tools: "Tools", profile: "Profile"
};

var PLACEHOLDERS = {
    feed: "Filter events...",
    online: "Filter friends and worlds..."
};

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
var view = { tab: "online", sel: null, filter: "" };
var lastJoinKey = "";
var lastNotifyKey = "";
/* Notification IDs with a request in flight. A snapshot replaces `state`
   wholesale, so the in-flight mark cannot live on the entry itself. */
var pendingNotifications = {};

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
        body.appendChild(placeholder(view.tab === "inbox"
            ? "Pick a sender you are already friends with."
            : "Pick a world or a friend."));
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
    document.getElementById("search").value = "";
    showList();
    render();
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

render();
connect();
