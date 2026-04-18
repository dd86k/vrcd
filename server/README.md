# vrcd Server

VRChat event recorder and broadcaster. Connects to VRChat's WebSocket for real-time events, stores them in SQLite, and serves them to vrcd clients over a JSON-L TCP API.

## Usage

```
vrcd-server [command] [options]
  Commands:
    run       Start the server (default)
    auth      Interactive VRChat login
    events    Print recent stored events

  Options:
    -b, --basedir   Base directory for all config/data files
    -c, --config    Path to config file
    -d, --db        Path to SQLite database
    -l, --listen    Listen address (host:port, default: 127.0.0.1:9700)
        --secret    Shared secret for client authentication
    -a, --auth      Path to credentials file
    -v, --verbose         Enable trace logging
        --prune-retain    Delete events older than AMOUNT UNIT (e.g. '3 months')
        --version         Show version info
```

Config/data paths default to:
- **Linux:** `~/.config/vrcd` (config), `~/.local/share/vrcd` (data)
- **Windows:** `%APPDATA%/vrcd`

## Configuration

Use `--basedir <path>` to put all files in a single directory (e.g. `--basedir /srv/vrcd`). Individual path flags (`--db`, `--auth`, etc.) override `--basedir` when both are given.

The config file is loaded from the default path (or the path given by `--config`). CLI arguments take precedence over config file values.

Default paths:

| File | Linux | Windows |
|------|-------|---------|
| Config | `~/.config/vrcd/server.conf` | `%APPDATA%/vrcd/server.conf` |
| Database | `~/.local/share/vrcd/server.db` | `%APPDATA%/vrcd/server.db` |
| Credentials | `~/.config/vrcd/credentials.json` | `%APPDATA%/vrcd/credentials.json` |
| Cookie jar | `~/.local/share/vrcd/cookies.txt` | `%APPDATA%/vrcd/cookies.txt` |

### Config file (`server.conf`)

Simple `key = value` format. Lines starting with `#` are comments.

```conf
# vrcd server configuration

# Base directory for all data files (db, credentials, cookies).
# Individual keys below override specific paths.
# basedir = /srv/vrcd

# SQLite database path
# db = /srv/vrcd/server.db

# Listen address and port
listen = 0.0.0.0:9700

# Shared secret for client authentication (empty = no auth)
secret = changeme

# Path to credentials.json
# auth = /srv/vrcd/credentials.json

# Path to cookie jar
# cookie_jar = /srv/vrcd/cookies.txt

# Enable verbose logging
# verbose = true

# Delete events older than the given period on startup.
# Supported units: days, weeks, months, years.
# Unset by default — events are kept forever.
# prune_retain = 3 months
```

### Credentials file (`credentials.json`)

Created automatically during interactive login (`vrcd-server auth`), or can be written manually:

```json
{
    "username": "your-vrchat-username",
    "password": "your-vrchat-password"
}
```

If the file doesn't exist, the server will prompt for credentials interactively and save them. The server also persists session cookies in `cookies.txt` so re-authentication is only needed when the session expires.

### Auth flow

1. If `cookies.txt` has a valid session, skip login entirely
2. Otherwise read `credentials.json` (or prompt interactively)
3. Login via VRChat Basic Auth
4. Handle 2FA if required (TOTP, OTP, or email,  interactive when on a TTY, delegated to a connected client when headless)
5. Fetch WebSocket auth token

## Architecture

### Startup Sequence (`cmdRun`)

1. Initialize database (SQLite)
2. Authenticate with VRChat (credentials file or interactive prompt, 2FA support)
3. Prune old events (if `prune_retain` is set)
4. Start TCP API server
5. Seed FriendsTracker from REST API (paginated)
6. Initialize WorldCache
7. Start WebSocket connection to VRChat
8. Block main thread (sleep loop)

### Event Pipeline

```
VRChat WebSocket
       │
       ▼
  Parse Event (double-decoded JSON)
       │
       ▼
  Enrich (friend name/platform, world name)
       │
       ├──> Store in SQLite
       │
       └──> Broadcast to connected clients
                 │
                 ▼
           FriendsTracker.processEvent
                 │
                 └──> Synthesized events (e.g. avatar-change)
                           │
                           ├──> Store in SQLite
                           └──> Broadcast to connected clients
```

Events arrive from VRChat's WebSocket, get parsed and enriched with display names and world names from cache, then are both persisted to SQLite and broadcast live to all authenticated clients. The tracker may also derive synthesized events from state diffs (e.g. an `avatar-change` when a cached `currentAvatar` changes between two `friend-update`/`user-update` payloads); those go through the same store+broadcast path as real events.

### Threading Model

```
+-------------------+
| Main Thread       |  (sleep loop after init)
+-------------------+

+-------------------+    +----------------+    +--------------------+
| WebSocket Thread  +--->| Event Pipeline +--->| Client Broadcast   |
+-------------------+    | (enrichment,   |    | (per-client mutex) |
                         |  storage)      |    +--------------------+
                         +----------------+

+-------------------+    +----------------------+
| TCP Accept Thread +--->| Client Threads       |
+-------------------+    | (one per connection) |
                         +----------------------+
```

- **Main thread** -- initializes all components, then idles
- **WebSocket thread** -- persistent connection to `wss://pipeline.vrchat.cloud`, 5-second reconnect backoff
- **TCP accept thread** -- listens for client connections
- **Client threads** -- one per connected client, handles JSON-L protocol

## Modules

### `main.d`
Entry point and command dispatcher. Parses CLI arguments, orchestrates startup, and wires the event callback chain (enrich -> store -> broadcast). Also implements `cmdAuth` for interactive login and `cmdEvents` for querying stored events.

### `config.d`
Configuration struct with platform-specific defaults. Fields: listen address/port, database path, credentials path, cookie jar path, shared secret, prune retain period.

### `events.d`
Event type definitions and parser.

- `EventType` enum -- recognized VRChat event types (see list below)
- `VRCEvent` struct -- parsed event with type, content (double-decoded JSON), timestamp, and raw JSON
- `parseEvent()` -- handles VRChat's double-encoded JSON format (content field is JSON-in-a-string)

All recognized events are stored in SQLite and broadcast to clients. Friend and self (`user-update`/`user-location`) events additionally update the in-memory `FriendsTracker` state, which may derive synthesized events. Unrecognized types are stored as `unknown` but still broadcast.

| Category | Event types |
|----------|-------------|
| Friend | `friend-online`, `friend-offline`, `friend-active`, `friend-update`, `friend-location`, `friend-add`, `friend-delete` |
| User | `user-update`, `user-location`, `user-badge-assigned`, `user-badge-unassigned` |
| Notification | `notification`, `notification-v2`, `notification-v2-update`, `notification-v2-delete`, `see-notification`, `hide-notification`, `response-notification` |
| Group | `group-joined`, `group-left`, `group-role-updated`, `group-member-updated` |
| Instance | `instance-queue-joined`, `instance-queue-position`, `instance-queue-ready`, `instance-queue-left`, `instance-closed` |
| Content | `content-refresh` |
| Synthesized | `avatar-change` |

**Synthesized events** are not produced by VRChat's WebSocket. They are derived on the server from state diffs and then persisted + broadcast identically to real events, so catch-up and the event viewer see them alongside the rest. Currently:

- `avatar-change` -- emitted when the cached `currentAvatar` on a tracked entry (friend or self) changes between updates. Content: `{ userId, displayName, previousAvatar, currentAvatar, isSelf }`. Clients can filter self-originated changes via the `isSelf` flag.

### `database.d`
SQLite persistence layer via arsd-official:sqlite.

- `storeEvent()` -- insert into `ws_events`, returns auto-incremented ID
- `queryEventsAfter(afterId)` -- fetch events for client catch-up
- `queryEventsBefore(beforeId)` -- fetch older events for client back-fill
- `queryRecentEvents()` -- fetch last N events for CLI viewer
- `pruneOldEvents(modifier)` -- delete events older than a SQLite datetime modifier (e.g. `"-3 months"`); prunes both `ws_events` and `ws_connection_log`

Database tables:
- **`ws_events`** -- canonical append-only event log (id, received_at, event_type, content_json, raw_json)
- **`ws_connection_log`** -- WebSocket connect/disconnect events; used to detect gaps in the stream
- **`server_state`** -- key-value store for persistent server state
- **`cache_world`**, **`cache_avatar`** -- world and avatar metadata caches

### `friends.d`
In-memory friend presence tracker. Also tracks the logged-in user (self) in the same map so self-originated events go through the same state-diff machinery; self is filtered out of the friends snapshot sent to clients.

- `FriendsTracker` -- state machine updated by WebSocket events
- `setSelf(userId, displayName, currentAvatar)` -- register the logged-in user; called once at startup from `AuthState`. The self entry is preserved across re-seeds.
- `replaceAll()` -- atomic swap used by the re-seed worker; re-injects the self entry since the REST friend list doesn't include the logged-in user.
- `processEvent()` -- update state from friend events (online, offline, active, location, update, add, delete) and self events (`user-update`, `user-location`). May queue synthesized events.
- `takePendingSynthetics()` -- drain derived events (e.g. `avatar-change`) produced since the last call. `APIServer.broadcast` drains and stores/logs/broadcasts them immediately after processing the triggering event.
- `buildFriendsMessage()` -- serialize friends grouped by instance for client delivery; self is skipped.
- `enrichContent()` -- add displayName/platform to event content when missing.

### `worldcache.d`
World name resolution cache with TTL.

- `resolve(worldId)` -- returns cached name or fetches from VRChat REST API
- `enrichWorldName(event)` -- adds world name to event content
- TTL: 1 day for successful lookups, 1 hour for failures

### `api.d`
Multi-threaded TCP server implementing the JSON-L client protocol.

**Client -> Server messages:**

| Type | Fields | Description |
|------|--------|-------------|
| `auth` | `token` | Authenticate with shared secret |
| `catch_up` | `since_id` | Replay stored events after given ID |
| `status` | | Request VRChat connection status |
| `get_friends` | | Request friends snapshot |
| `get_world` | `world_id` | Resolve world ID to name |
| `pong` | | Keepalive response |

**Server -> Client messages:**

| Type | Key Fields | Description |
|------|------------|-------------|
| `auth_ok` | `server_version` | Authentication successful |
| `auth_error` | `message` | Authentication failed |
| `event` | `id`, `event_type`, `content` | Live or replayed event |
| `caught_up` | `last_id` | Catch-up replay complete |
| `status` | `vrchat_connected`, `vrchat_last_error` | Connection status |
| `friends` | `instances`, `offline` | Friends grouped by instance |
| `world` | `world_id`, `world_name` | World name resolution result |
| `error` | `message` | Error response |

### `vrchat/auth.d`
VRChat authentication and session management.

- Full login flow: credentials -> Basic Auth -> 2FA (TOTP/OTP/email) -> session token
- Cookie jar persistence for session reuse
- Credential file read/write for unattended operation
- Headless 2FA delegation: when running without a TTY, 2FA prompts are sent to a connected client; times out after 30 minutes then exits

### `vrchat/websocket.d`
Persistent WebSocket connection to `wss://pipeline.vrchat.cloud`.

- Background thread with automatic reconnection (5-second backoff)
- 30-second poll timeout
- Status callback for connection state changes
- Token refresh support for re-authentication

### `vrchat/vrcconfig.d`
API constants. Currently defines `USER_AGENT = "vrcd/0.1"`.

## Dependencies

These are pulled by DUB when upgrading and building.

| Package | Purpose |
|---------|---------|
| `ddlogger` | Structured logging |
| `ddcurl` | HTTP client and WebSocket (libcurl wrapper) |
| `arsd-official:sqlite` | SQLite database access |

Packages:
- Alpine: `sqlite-dev libcurl-dev`
- Ubuntu: `libsqlite3-dev libcurl4-openssl-dev` (or build libcurl if <8.11)

## Building

```bash
dub build :server
dub test :server
```

> **Note:** If you get linking issues on Windows, try with LDC: `--compiler=ldc2`

Requires libcurl 8.11+ for WebSocket support.

Uses static build by default via ddcurl due to the WS requirement and some platforms providing older versions, allowing custom builds.
