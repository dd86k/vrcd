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
      --image-cache vrcd-server's image cache directory, when it shares this host
      --no-image-cache  Never read that cache, even on one host
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
| GET | `/api/content/:section` | cookie | One section's entries, and the fetch that fills them. `?refresh=1` re-lists, `?more=1` asks for the next page |
| POST | `/api/content` | cookie | `{"action":"...","id":"...","slot":"drone"}` -- see below |
| POST | `/api/upload` | cookie | `{"tag":"gallery"\|"icon"\|"sticker"\|"emoji"\|"print","data_base64":"...","note":"..."}` |
| GET | `/api/image/:file_id` | cookie | One proxied VRChat image, `?v=` version and `?size=` edge |
| POST | `/api/auth` | cookie | Answers a delegated VRChat sign-in prompt |
| WS | `/ws/:ticket` | ticket | State snapshots and feed events |

`/static/` is deliberately open: the assets carry no state, and the login page
needs its stylesheet before there is a session to check. Names are restricted to
a plain file name (no separators, no traversal, nothing hidden, 64 chars max)
and only known extensions are served.

`/api/auth` takes one of three bodies:

```json
{"action": "credentials", "username": "...", "password": "..."}
{"action": "two_factor",  "code": "123456"}
{"action": "cancel"}
```

Unlike the two above it is not fire and forget: there is no result message for
a sign-in, so the reply is all the page hears. 200 means the answer went down
the link, 503 means there is no link to put it on, 400 means the action was not
one of the three or the fields it needs were empty (a blank password is refused
here rather than spending one of VRChat's login attempts on it).

`/api/content` takes one action per request:

| Action | ID | Effect |
|--------|----|--------|
| `equip` | `inv_...` | Puts the item in `slot` (`drone`, `portal`, `warp`) |
| `unequip` | -- | Empties `slot`; VRChat addresses the slot, not the item |
| `consume` | `inv_...` | Uses the item up |
| `delete_file` | `file_...` | Deletes a gallery image, icon, sticker or emoji |
| `delete_print` | `prnt_...` | Deletes a print |
| `set_icon` | `file_...` | Sets the profile icon, or clears it when the ID is empty |

Browser-to-server actions go over plain HTTP rather than up the socket, which
keeps the WebSocket unidirectional. They are fire and forget: the outcome comes
back from vrcd-server as a `join_instance_result`, a
`notification_action_result` or one of the content results, and reaches the
page in the next state broadcast, which is also what drops an answered
notification from the inbox. An action other than the ones listed is refused
here rather than travelling down to vrcd-server to be refused there.

Request bodies are capped at 16 MB, which is VRChat's 10 MB picture plus base64
expansion and the JSON around it. Past that the reply is a 413 and nothing is
buffered.

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

### Stuff

The STUFF tab is six sections over one mechanism:

| Section | Source | Actions |
|---------|--------|---------|
| Gallery | `get_files` tag `gallery` | Upload, delete |
| Icons | `get_files` tag `icon` | Upload, delete, set or clear the profile icon |
| Stickers | `get_files` tag `sticker` | Upload, delete |
| Emoji | `get_files` tag `emoji` | Upload, delete |
| Prints | `get_prints` | Upload with a caption, delete |
| Items | `get_inventory` | Equip, unequip, consume |

Items are props, bundles, drone and portal skins and warp effects. Emoji and
stickers are not among them: vrcd-server filters them out of `get_inventory`
because they have sections of their own above.

The entries do *not* ride in the state snapshot. A few hundred of them would be
re-encoded and fanned out to every browser on every friend movement, and the
tab is usually closed. So the snapshot carries a small block per section --
`revision`, `loading`, `count`, `more`, `error` -- and the entries come from
`GET /api/content/:section`. A revision that moves is the page's cue to come
back for a new copy; a bump that lands while a fetch is in flight is
remembered, since the copy already on its way is the one *before* the change.

Nothing is fetched until someone opens a section: each listing costs
vrcd-server a VRChat call, and most sessions never look at most of them. After
that a section refreshes itself, because several things change one and only
some of them are buttons here:

- an action from this page -- the result says which section it touched, except
  a delete, which does not name one, so every *loaded* files section re-lists,
- an upload, which refreshes the section it went to,
- a `content-refresh` event naming that section, which is how VRChat reports a
  change made in-game or on another device,
- a reconnect, but only for sections already fetched -- nothing that happened
  while the link was down replays as an event.

A failed refresh keeps the list that is on screen rather than blanking it: it
is still the last thing VRChat said, and an empty section reads as "you own
nothing" rather than "that did not work".

Only the files sections page, at 100 entries a request (vrcd-server's own cap);
prints and the inventory arrive whole. A full page means there may be another,
which is what puts LOAD MORE under the grid, and those pages append.

Deletes and consumes are two taps, and the second is not where the first
landed: Cancel takes that spot, because none of them can be undone. Equip and
unequip are both offered whenever an item is equippable, rather than guessing
which one applies: VRChat reports which slot an item belongs to, not whether it
is currently sitting in it, and both are one reversible tap. An item whose slot
comes back empty falls back to its type (`droneskin` -> drone, `portalskin` ->
portal, `warpeffect` -> warp), which are the only three slots vrcd-server
accepts.

Uploads are a file picker, read as base64 in the browser and posted whole. PNG
and the 10 MB ceiling are checked here so a picture that was never going to be
accepted does not travel twice; everything else -- dimensions, and the square
requirement on stickers and emoji -- is vrcd-server's call, since it is the
side that knows VRChat's rules and has to answer for them. There is no crop
step yet, so a non-square sticker comes back refused rather than trimmed.
Animated emoji upload as a still: the sprite-sheet fields exist in the API but
this page has nothing to describe them with.

### Image proxy

A browser cannot fetch a VRChat file: the session lives on vrcd-server. So an
image travels down the JSON-L link as base64 and back out over HTTP, which is
far too slow to do inside a request handler -- ddhttpd runs handlers on the
same thread as its poll loop, so one blocking handler stalls every other
request and every WebSocket on that thread.

`GET /api/image/:file_id` therefore never blocks:

- **200** with the bytes, when they are cached.
- **202** when the request has been put on the link. The page retries, backing
  off at 800 ms for about 30 seconds; vrcd-server spaces uncached downloads
  250 ms apart, so a cold grid takes a while to fill in.
- **502** when VRChat or vrcd-server refused it. That is remembered for a
  minute, so a wall of broken thumbnails does not hammer the link, and a
  transient failure still heals.

The cache is bounded by bytes (32 MB, oldest evicted first) and never
invalidated: a file ID, version and size always describe the same picture, so
a new upload is a new key. Replies carry a long `Cache-Control`, and the page
keeps the object URLs it made, since the shell redraws on every snapshot.

#### Reading vrcd-server's cache

When vrcd-server is on this host, most of what the page asks for is already on
its disk, so a miss checks there before going down the link. The name is the
one vrcd-server writes -- `<image cache>/<file id>.<version>.<size>` -- and two
properties of that cache make reading it from outside safe: entries are written
to a temporary name and renamed into place, so a half-written file is never
visible, and the name is the whole identity of the content, so there is no such
thing as a stale hit.

It is a shortcut around base64 and a round trip, never around vrcd-server: a
miss still goes down the link, which is where the VRChat session, the rate
limiter and the 250 ms spacing live. What it buys is that everything already
downloaded answers 200 on the first request instead of 202 and a retry.

The directory is `--image-cache` when given, otherwise vrcd-server's own
default (`~/.local/share/vrcd/imagecache`, or `%APPDATA%\vrcd\imagecache`),
used only when it is there. A path that does not exist is a warning rather
than a startup error: sharing a host is a deployment choice, and losing the
shortcut costs speed, not function. `--no-image-cache` turns it off outright.
Reads bump the file's mtime, because vrcd-server evicts by mtime and bumps it
on its own hits -- without that, the entries this page uses most would look
like the coldest ones it holds. That bump is best effort, since the directory
may belong to another user.

`?size=` is 0 for the original file or one of VRChat's thumbnail edges (128,
256, 512, 1024); the grid asks for 256 and the detail pane for 512. A file ID
that is not shaped like one is refused here, since it lands in a path
vrcd-server builds.

### VRChat sign-in

vrcd-server holds the VRChat session; this process never talks to VRChat. When
the server runs headless and needs credentials or a 2FA code it delegates the
prompt to whichever front-end is connected, as an `auth_request`, and the first
`auth_response` wins. The SDL client has answered these since it existed; this
front-end answers the same ones, so a server can be signed in from a browser.

The prompt goes into the state snapshot as `auth` and the page puts a modal
over everything. Answering clears it locally the moment the response is on the
wire, which closes the modal on *every* browser: there is no "answered" message
to wait for, and a wrong answer comes back as a fresh `auth_request` carrying
the error. A server that is already waiting when this process connects replays
the prompt after `auth_ok`, so a browser that arrives mid-prompt still sees it.
A dropped link clears it too, since an answer would have nowhere to go and the
server re-sends after the next `auth_ok`.

Cancel is an answer, not a dismissal: the server stops waiting, and a headless
one gives up on the sign-in.

> **Note:** the password crosses the browser-to-web-server hop, so this is one
> more reason to keep the listener on loopback or behind TLS. It is held only
> long enough to forward and is never logged, and with no `--web-secret` set
> anyone who can reach the port can answer these prompts.

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
  `notification_action_result`, `files`, `prints`, `inventory`,
  `inventory_action_result`, `delete_file_result`, `delete_print_result`,
  `set_user_icon_result`, `upload_image_result`, `upload_print_result`,
  `image`, `auth_request`, `ping`, `error`. Everything else is logged and
  dropped.
- `self()`, `status()`, `roster()`, `joinResult()`, `notifications()`,
  `notifyResult()`, `authPrompt()`, `content(section)`, `contentResult()` --
  mutex-guarded snapshots for HTTP threads.
- `requestJoin(location)`, `requestNotificationAction(id, action)`,
  `requestContent(section, force)`, `requestMoreContent(section)`,
  `requestInventoryAction(action, id, slot)`, `requestContentAction(action,
  id)`, `requestUpload(tag, base64, note)`, `image(fileId, version, size)`,
  `submitCredentials(user, pass)`, `submitTwoFactor(code)`, `cancelAuth()` --
  safe from any thread; sends are serialized, and none of them block on a
  reply.
- Change and feed callbacks fire on the network thread, outside the state lock
  (the callback rebuilds a snapshot, which takes that same lock). An image
  arriving publishes nothing: the browser is already coming back for it, and a
  broadcast per thumbnail would put a whole grid's worth of snapshots on every
  socket.
- Types: `SelfInfo`, `LinkStatus`, `FeedEntry`, `JoinResult`,
  `NotifyActionResult`, `AuthPrompt`, `ContentSnapshot`,
  `ContentActionResult`, plus `CONTENT_SECTIONS` and the two helpers that
  validate a section name arriving over HTTP.

### `web/hub.d`
Fan-out to connected browsers. `publishState()`, `publishFeed()`, and `serve()`
(one call per connection, for the lifetime of the socket). Holds the state
generation counter and the feed ring.

### `web/state.d`
State encoding. `buildStateJSON()` produces the snapshot; `encodeFeedEntry()`
encodes one feed entry once so the hub can fan the string out as-is;
`buildContentJSON()` produces the `/api/content/:section` body around the
entries vrcd-server already trimmed.

### `web/images.d`
`ImageCache`: a bounded, mutex-guarded store of proxied images. `lookup()`
answers ready, pending or failed and tells the caller when it has to start the
fetch itself; `store()` and `storeFailure()` file the answer. Nothing here
blocks or knows about the link.

`readFromServerCache()` reads one image straight out of vrcd-server's cache
directory, and `findServerImageCache()` picks that directory (the flag, else
vrcd-server's own default, else null for link-only). Both refuse anything that
could climb out of the directory, since the file ID lands in a path.

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
  "auth": { "kind": "two_factor", "method": "totp", "error": "Invalid code" },
  "join": { "attempted": true, "location": "...", "success": true, "error": "" },
  "notify_action": {
    "attempted": true, "notification_id": "not_...", "action": "accept",
    "success": true, "error": ""
  },
  "content": {
    "gallery": { "revision": 4, "loading": false, "loaded": true,
                 "count": 12, "total_count": 0, "more": false, "error": "" },
    "icon": {}, "sticker": {}, "emoji": {}, "prints": {}, "inventory": {}
  },
  "content_action": {
    "attempted": true, "action": "equip", "id": "inv_...",
    "success": true, "error": ""
  }
}
```

`self` is absent until the server says who is logged in, `join` until a
self-invite has been attempted this session, `notify_action` until a
notification has been answered, and `content_action` until something in STUFF
has been acted on -- its `id` is the entry acted on, or the tag an upload went
to. `content` is always there, with all six sections, and carries no entries on
purpose: it says *that* a section moved, and the page fetches the entries from
`/api/content/:section`. `total_count` is VRChat's own total, which only the
inventory reports; `more` says the last page came back full. `auth` is there only while vrcd-server is
waiting on a sign-in answer, so its presence is what raises the modal; `kind`
is `credentials` or `two_factor`, `method` is VRChat's `totp`, `otp` or
`emailOtp` and is empty on a credentials prompt, and `error` carries what went
wrong last time. `notifications` is always present, empty array
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
| Stuff | Live. Gallery, icons, stickers, emoji, prints and inventory items as grids, with uploads, deletes, the profile icon, and equip/unequip/consume |
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

World thumbnails are stand-in gradients seeded from the world name. The image
proxy that would replace them exists now, but the roster carries no world image
to ask it for; that needs the world cache vrcd-server keeps. Everything in
STUFF goes through the proxy, and falls back to the same gradient when there is
nothing to fetch -- an item with no artwork, or a file whose only versions were
deleted (`version: 0`, which the proxy would refuse anyway).

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
