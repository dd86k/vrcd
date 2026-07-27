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

var lastJoinKey = "";
var feed = [];
var FEED_MAX = 500;

function el(tag, cls, text) {
    var node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text) node.textContent = text;
    return node;
}

function statusDot(status) {
    var dot = el("span", "dot");
    dot.style.background = STATUS_COLORS[status] || "#8a8a99";
    return dot;
}

function friendRow(friend) {
    var row = el("div", "friend");
    row.appendChild(statusDot(friend.status));

    var who = el("div", "who");
    who.appendChild(el("div", "name", friend.displayName));
    if (friend.statusDescription)
        who.appendChild(el("div", "desc", friend.statusDescription));
    row.appendChild(who);

    if (friend.platform)
        row.appendChild(el("span", "plat", PLATFORMS[friend.platform] || friend.platform));
    return row;
}

function friendList(friends) {
    var list = el("div", "friends");
    friends.forEach(function (f) { list.appendChild(friendRow(f)); });
    return list;
}

function instanceGroup(group) {
    var wrap = el("div", "group");
    var head = el("div", "group-head");

    var isPrivate = group.instance_id === "private";
    head.appendChild(el("div", "world",
        isPrivate ? "Private" : (group.world_name || group.instance_id)));

    if (group.n_users >= 0 && group.capacity > 0)
        head.appendChild(el("div", "count", group.n_users + "/" + group.capacity));

    // Private instances have no joinable location, and neither does a group
    // the server gave us no location for.
    if (!isPrivate && group.location) {
        var button = el("button", "join", "Self-Invite");
        button.onclick = function () { join(group.location, button); };
        head.appendChild(button);
    }

    wrap.appendChild(head);
    wrap.appendChild(friendList(group.friends));
    return wrap;
}

function collapsible(title, friends) {
    var box = document.createElement("details");
    box.appendChild(el("summary", null, title + " (" + friends.length + ")"));
    box.appendChild(friendList(friends));
    return box;
}

function join(location, button) {
    button.disabled = true;
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
    });
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

function renderLink(state) {
    var link = document.getElementById("link");
    if (state.connected) {
        link.textContent = "vrcd-server v" + state.server_version +
            (state.vrchat_connected ? " - VRChat connected" : " - VRChat disconnected");
        link.classList.remove("down");
    } else {
        link.textContent = "disconnected from vrcd-server" +
            (state.last_error ? ": " + state.last_error : "");
        link.classList.add("down");
    }
}

function renderSelf(state) {
    var self = state.self;
    var dot = document.getElementById("selfDot");
    if (!self) {
        document.getElementById("selfName").textContent = "Not logged in";
        document.getElementById("selfDesc").textContent = "";
        dot.style.background = "#8a8a99";
        return;
    }
    document.getElementById("selfName").textContent = self.displayName;
    document.getElementById("selfDesc").textContent = self.statusDescription || self.status;
    dot.style.background = STATUS_COLORS[self.status] || "#8a8a99";
}

function renderRoster(state) {
    var roster = state.roster || { instances: [], active_elsewhere: [], offline: [] };
    var groups = document.getElementById("groups");
    groups.textContent = "";

    var total = roster.instances.length + roster.active_elsewhere.length + roster.offline.length;
    document.getElementById("empty").classList.toggle("hidden", total > 0);

    roster.instances.forEach(function (group) {
        groups.appendChild(instanceGroup(group));
    });
    if (roster.active_elsewhere.length)
        groups.appendChild(collapsible("Active elsewhere", roster.active_elsewhere));
    if (roster.offline.length)
        groups.appendChild(collapsible("Offline", roster.offline));
}

function renderJoin(state) {
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

function render(state) {
    renderLink(state);
    renderSelf(state);
    renderRoster(state);
    renderJoin(state);
}

function eventRow(event) {
    var row = el("div", "event");

    // The server sends UTC ISO 8601; render it in the viewer's timezone.
    var when = new Date(event.received_at);
    row.appendChild(el("div", "time",
        isNaN(when.getTime()) ? "--:--:--" : when.toLocaleTimeString()));

    row.appendChild(el("div", "label", event.label));
    row.appendChild(el("div", "who", event.user));
    row.appendChild(el("div", "what", event.detail));
    return row;
}

function renderFeed() {
    var box = document.getElementById("events");
    box.textContent = "";
    document.getElementById("feedEmpty").classList.toggle("hidden", feed.length > 0);

    // Newest first, which is the opposite of how the log arrives.
    for (var i = feed.length - 1; i >= 0; i--)
        box.appendChild(eventRow(feed[i]));
}

function applyFeed(message) {
    if (message.reset)
        feed = message.events;
    else
        feed = feed.concat(message.events);

    if (feed.length > FEED_MAX)
        feed = feed.slice(feed.length - FEED_MAX);
    renderFeed();
}

function showTab(name) {
    var online = name === "online";
    document.getElementById("viewOnline").classList.toggle("hidden", !online);
    document.getElementById("viewFeed").classList.toggle("hidden", online);
    document.getElementById("tabOnline").classList.toggle("on", online);
    document.getElementById("tabFeed").classList.toggle("on", !online);
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
            render(message);
    };
    socket.onclose = function () {
        var link = document.getElementById("link");
        link.textContent = "vrcd web server unreachable, retrying...";
        link.classList.add("down");
        setTimeout(connect, 3000);
    };
}

connect();
