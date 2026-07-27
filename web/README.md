# vrcd Web

Browser front-end for vrcd. Links to vrcd-server over the same JSON-L API the
SDL client uses, and serves the roster and event feed as HTML over ddhttpd
(libmicrohttpd). It never talks to VRChat directly.

## Usage

```
vrcd_web [options]
  -l, --listen      Address to serve HTTP on (default: 127.0.0.1:8080)
  -s, --server      vrcd-server address as host:port (default: 127.0.0.1:9700)
      --secret      Shared secret for vrcd-server auth
      --web-secret  Shared secret browsers must present to sign in
      --web-root    Directory holding the front-end files
  -v, --verbose     Enable verbose logging
      --version     Show version and exit
```

There is no config file. Everything is on the command line, since the process
holds no state of its own: sessions live in memory and the roster comes from
vrcd-server.

`--secret` authenticates *this process to vrcd-server*. `--web-secret`
authenticates *browsers to this process*. They are unrelated and should not be
the same value.

```bash
./web/vrcd_web --listen 0.0.0.0:8080 --server 127.0.0.1:9700 \
    --secret <server secret> --web-secret <what you type in the browser>
```

> **Note:** the link to vrcd-server is plain TCP. TLS is not wired up on this
> side yet, so keep it on loopback or inside a tunnel.

### Document root

The front-end lives in `web/public/` as plain files, not string literals in the
binary, so editing a stylesheet is an edit plus a refresh with no rebuild and no
restart. The trade is that the directory has to travel with the binary.

The root is `--web-root` when given (a wrong path is a hard error, not a silent
fallback), otherwise the first of these that holds an `index.html`:

1. `public/` beside the binary (how a package installs)
2. `../public` relative to the binary
3. `./public` under the working directory
4. `./web/public` (how the repository is laid out)

When none exist, the candidates are logged and the process exits rather than
serving a broken page.

### Auth

A shared secret exchanged for a session cookie. It is a gate, not an identity
system: one secret, sessions in memory, all of them lost on restart.

- `POST /login` compares the submitted secret in constant time and sets
  `vrcd_session` (HttpOnly, SameSite=Strict, 12 hour lifetime).
- WebSockets get a second mechanism. ddhttpd upgrades the connection before the
  handler runs and `WebSocketConnection` exposes no request headers, so the
  cookie cannot be read there. The page trades it at `/api/wsticket` for a
  single-use ticket with a 30 second lifetime, and puts that in the socket path.
  A ticket that leaks into a log or a referrer is worthless seconds later, which
  the secret itself would not be.

Without `--web-secret` every route is open and the server says so at startup.
There is no logout route yet; clearing the cookie is the workaround.

## Routes

| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| GET | `/` | cookie | The shell document (`index.html`) |
| GET | `/login` | open | Sign-in page |
| POST | `/login` | -- | Exchange the secret for a session cookie |
| GET | `/static/:name` | open | One file from the web root |
| GET | `/api/state` | cookie | Current snapshot, same JSON as the socket sends |
| GET | `/api/wsticket` | cookie | Single-use WebSocket ticket |
| POST | `/api/join` | cookie | `{"location":"wrld_...:1234~..."}`, requests a self-invite |
| POST | `/api/notification` | cookie | `{"notification_id":"not_...","action":"accept"\|"hide"}` |
| WS | `/ws/:ticket` | ticket | State snapshots and feed events |

`/static/` is deliberately open: the assets carry no state, and the login page
needs its stylesheet before there is a session to check. Names are restricted to
a plain file name (no separators, no traversal, nothing hidden, 64 chars max)
and only known extensions are served.

Browser-to-server actions go over plain HTTP rather than up the socket, which
keeps the WebSocket unidirectional. Both are fire and forget: the outcome comes
back from vrcd-server as a `join_instance_result` or a
`notification_action_result` and reaches the page in the next state broadcast,
which is also what drops an answered notification from the inbox. An action
other than `accept` or `hide` is refused here rather than travelling down to
vrcd-server to be refused there.

## Architecture

### Threading model

```
+---------------------+     +----------------------+
| ServerLink thread   |     | libmicrohttpd thread |
| - TCP to vrcd-server|     | - HTTP handlers      |
| - reconnect/backoff |     +----------------------+
+----------+----------+
           | callbacks
           v
      +---------+     +--------------------------+
      |   Hub   +---->| one thread per browser   |
      +---------+     | - parks on a condition   |
                      | - only ever sends        |
                      +--------------------------+
```

- **ServerLink thread** -- owns the socket to vrcd-server. Connects,
  authenticates, answers pings, parses the handful of message types the page
  renders, and reconnects with a 2 second backoff doubling to 60 seconds. Its
  state is behind a mutex so HTTP handlers can read it from any thread.
- **libmicrohttpd threads** -- run the HTTP handlers. They read link state and
  reply; they never block on the network thread.
- **Browser threads** -- one per WebSocket, spawned by ddhttpd. Each parks on a
  condition variable until something moves, then writes.

The one-way rule for browser threads is deliberate. ddhttpd's `send_frame`
writes the frame header and payload as two separate socket writes with no lock,
so two threads sending on one connection would interleave and corrupt the
stream. Keeping every write on the connection's own thread sidesteps that. If
the page ever needs to send messages up the socket, that needs a reader thread
and a per-connection send mutex.

### Broadcast model

Two channels share one wakeup:

- **State** is a snapshot, so only the latest one matters. The hub keeps the
  encoded payload and a generation counter; each connection compares its
  last-seen generation. A browser that joins late gets the current snapshot
  rather than a replay, so it is correct immediately.
- **Feed** is an append-only log with a 500 entry ring. Each connection sends
  the slice it has not seen. A new epoch, a first look, or having fallen off the
  back of the ring all resolve the same way: send what we have as a
  *replacement* (`reset: true`) rather than trying to patch the browser's copy.
  So a browser gets a full replacement instead of a gap.

The timed wait doubles as a heartbeat: on a 30 second timeout the thread sends a
ping, which is how a browser that vanished without a close frame is noticed.

Snapshots are broadcast on every change and are small enough that diffing them
server-side would cost more than it saves.

### Inbox

The inbox cannot be rebuilt from the event log. The VRChat WebSocket only
reports *changes*, so a friend request that arrived while this process was down
has no event to replay, and the feed seed only reaches back one page anyway. So
the link asks vrcd-server for `get_notifications` on connect (protocol v4; on an
older server the tab says so and stays empty) and then keeps that list current
from the live events. The backlog deliberately does *not* feed the inbox:
replaying old events over the snapshot would resurrect notifications answered
long ago.

Order is oldest first and the list is never re-sorted. The accept and dismiss
buttons live in the rows, so a list that reflowed when something arrived would
slide a button under a thumb already on its way down to it, and on a friend
request the button that moves under it is an accept. New arrivals append.

A successful action drops the row immediately rather than waiting for VRChat's
matching `hide-notification` or `response-notification` event, which arrives
whenever it arrives.

One gap: a live `notification` event for a friend request carries no sender
name, and the sender is by definition not in the roster, so the row shows the
user ID until the next reconnect refetches the list. The server resolves names
for the fetched list but the link cannot do a REST lookup of its own.

### Feed seeding

On connect the link sends `fetch_older` with `before_id: long.max` and a limit
of 200, not `catch_up`. Catch-up walks *forward* from an ID and would hand back
the oldest page of a long backlog; this page wants the newest events. Entries
arrive newest first and are held until `older_fetched` terminates them, then
flipped to oldest-first so the browser can treat the feed as an ordered log
regardless of how it was filled. A reconnect re-seeds from scratch: the feed is
a live view, not an archive with gap tracking.

## Modules

### `app.d`
Entry point. Parses arguments, resolves the web root (before anything else
starts, so a missing document root is a startup error), wires the link
callbacks to the hub, registers every route, and parks the main thread while
libmicrohttpd serves.

### `web/connection.d`
TCP client for the vrcd-server JSON-L API, on its own thread.

- Interprets `auth_ok`, `self`, `status`, `friends`, `event`, `event_older`,
  `older_fetched`, `join_instance_result`, `notifications`,
  `notification_action_result`, `ping`, `error`. Everything else is logged and
  dropped.
- `self()`, `status()`, `roster()`, `joinResult()`, `notifications()`,
  `notifyResult()` -- mutex-guarded snapshots for HTTP threads.
- `requestJoin(location)`, `requestNotificationAction(id, action)` -- safe from
  any thread; sends are serialized.
- Change and feed callbacks fire on the network thread, outside the state lock
  (the callback rebuilds a snapshot, which takes that same lock).
- Types: `SelfInfo`, `LinkStatus`, `FeedEntry`, `JoinResult`,
  `NotifyActionResult`.

### `web/hub.d`
Fan-out to connected browsers. `publishState()`, `publishFeed()`, and `serve()`
(one call per connection, for the lifetime of the socket). Holds the state
generation counter and the feed ring.

### `web/state.d`
State encoding. `buildStateJSON()` produces the snapshot; `encodeFeedEntry()`
encodes one feed entry once so the hub can fan the string out as-is.

### `web/auth.d`
`SessionStore` (login, session validation, ticket issue and redeem, expiry
sweep) plus `sessionFromCookies()`, `formField()`, `constantTimeEquals()` and
`randomToken()` (128 bits from `RtlGenRandom` or `/dev/urandom`).

### `web/assets.d`
`AssetStore` reads a file on demand and keeps it until its mtime moves, and
`findWebRoot()` picks the directory. Replies carry `Cache-Control: no-cache` so
the browser revalidates rather than sitting on an edited stylesheet.

Shared via `sourceFiles`: `common/source/vrcd/friends.d` (bucketing and
ordering) and `common/source/vrcd/events.d` (labels and field extraction) with
the SDL client, and `common/source/vrcd/notifications.d` (the notification
shape, in both the wire forms VRChat uses) with the SDL client *and*
vrcd-server, so none of the three can drift.

## Wire format

State snapshot, sent on every change and also returned by `/api/state`:

```json
{
  "type": "state",
  "connected": true,
  "vrchat_connected": true,
  "server_version": 3,
  "last_error": "",
  "self": {
    "id": "usr_...", "displayName": "...", "status": "active",
    "statusDescription": "...", "bio": "...", "pronouns": "...",
    "bioLinks": ["https://..."]
  },
  "roster": {
    "instances": [{
      "instance_id": "wrld_...:12345",
      "location": "wrld_...:12345~friends(usr_...)~region(eu)",
      "world_name": "...", "n_users": 12, "capacity": 32,
      "friends": [{
        "id": "usr_...", "displayName": "...", "status": "active",
        "statusDescription": "...", "platform": "standalonewindows",
        "location": "...", "pronouns": "..."
      }]
    }],
    "active_elsewhere": [], "offline": []
  },
  "notifications": [{
    "id": "not_...", "notification_type": "friendRequest",
    "sender_user_id": "usr_...", "sender_name": "...", "message": "...",
    "location": "", "received_at_unix": 1753632000
  }],
  "join": { "attempted": true, "location": "...", "success": true, "error": "" },
  "notify_action": {
    "attempted": true, "notification_id": "not_...", "action": "accept",
    "success": true, "error": ""
  }
}
```

`self` is absent until the server says who is logged in, `join` until a
self-invite has been attempted this session, and `notify_action` until a
notification has been answered. `notifications` is always present, empty array
included: the page has to tell "nothing waiting" apart from "the link has not
answered yet", and its length is the badge on the rail. `location` is set only
on an invite, and is what lets the row offer a join instead of an
acknowledgement. `server_version` is the protocol
version from `auth_ok` as a number, zero when unknown. `n_users` and `capacity`
are -1 when unknown. Friend entries carry no `bio` or `bioLinks` on purpose:
the roster does not show them and they would bloat every broadcast.

Feed frame:

```json
{ "type": "feed", "reset": false, "events": [{
    "id": 1234, "event_type": "friend-location", "label": "Friend Location",
    "user": "alice", "detail": "The Great Pug",
    "received_at": "2026-07-27T18:00:00Z"
}]}
```

`reset` true means replace, false means append. `received_at` stays as the
server's ISO 8601 UTC string so the browser renders it in the viewer's timezone.

## Front-end

Plain files, no build step, no framework, no external requests (a page that
phones out would break behind a tunnel and leak who is looking).

| File | Purpose |
|------|---------|
| `index.html` | Shell markup, plus the icon sprite inlined so the rail draws without a second round trip |
| `app.css` | Whole stylesheet, dark, CSS custom properties for the palette |
| `app.js` | Everything else: socket, state, rendering |
| `login.html`, `login.css`, `login.js` | Sign-in page |

The layout is three columns on a desktop (tab rail, list, detail) and one on a
phone, where the rail becomes a bottom bar and the detail pane becomes a pushed
page. That transformation is entirely CSS, driven by the `data-pane` attribute
on `#shell` and one `max-width: 64rem` media query. Buttons are sized for a
thumb, since the point of the web front-end is reading the roster on a phone
while in headset.

Tabs:

| Tab | State |
|-----|-------|
| Feed | Live. Newest first, filterable; clicking an event jumps to that friend |
| Online | Live. Friends grouped by instance, with instance and friend detail |
| Inbox | Live. Friend requests and invites, oldest first, with a count badge on the rail |
| Stuff | Placeholder. Needs `get_files` / `get_prints` and an image proxy |
| Tools | Placeholder. Most client tools are local and cannot appear here |
| Profile | Live. Self profile plus the connection block |

The inbox draws its buttons in the row rather than the detail pane: answering a
friend request should be one tap, and in a headset the detour through a second
pane is the expensive part. What each row offers depends on the type, and only
what vrcd-server can actually do appears:

| Type | Buttons |
|------|---------|
| `friendRequest` | ACCEPT, DECLINE |
| `invite` | JOIN WORLD (the same self-invite the roster offers), DISMISS |
| `requestInvite` | DISMISS, and a line saying why there is nothing else - sending an invite back needs an API the server does not expose |

VRChat's accept endpoint only means anything for a friend request, so an invite
is answered by going where it points instead. The sender opens in the detail
pane when they are already a friend.

Placeholders are the `soon` flag in the `TABS` table at the top of `app.js`, and
each renders a line naming what it is waiting on. One profile layout serves both
your own profile and a friend's; rows appear only when the field is present, so
the difference between you and a friend is which fields the record carries.

World thumbnails are stand-in gradients seeded from the world name. Real
artwork needs an image proxy in front of the server's `get_image`, which does
not exist yet.

## Dependencies

| Package | Purpose |
|---------|---------|
| `ddhttpd` | HTTP and WebSocket server (libmicrohttpd wrapper) |
| `ddlogger` | Structured logging |

System packages:
- Ubuntu: `libmicrohttpd12t64` (runtime), or `libmicrohttpd-dev` for a static
  binding via `subConfiguration "ddhttpd" "static-binding"`

ddhttpd loads libmicrohttpd dynamically by default, so no development package
is needed to build.

## Building

```bash
dub build :web
dub test :web
./web/vrcd_web --web-secret hunter2
```

The binary looks for `public/` beside itself first, so a package is the binary
plus that directory. Running from the repository root works too, via the
`./web/public` candidate.
