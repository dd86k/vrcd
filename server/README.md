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
    -v, --verbose   Enable trace logging
        --version   Show version info
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
4. Handle 2FA if required (TOTP, OTP, or email — prompted interactively)
5. Fetch WebSocket auth token

## Architecture

### Startup Sequence (`cmdRun`)

1. Initialize EventStore (SQLite)
2. Authenticate with VRChat (credentials file or interactive prompt, 2FA support)
3. Create per-user database tables
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
```

Events arrive from VRChat's WebSocket, get parsed and enriched with display names and world names from cache, then are both persisted to SQLite and broadcast live to all authenticated clients.

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
Configuration struct with platform-specific defaults. Fields: listen address/port, database path, credentials path, cookie jar path, shared secret.

### `events.d`
Event type definitions and parser.

- `EventType` enum -- 40+ VRChat event types (friend, user, notification, group, instance, content)
- `VRCEvent` struct -- parsed event with type, content (double-decoded JSON), timestamp, and raw JSON
- `parseEvent()` -- handles VRChat's double-encoded JSON format (content field is JSON-in-a-string)

### `store.d`
SQLite persistence layer via arsd-official:sqlite.

- `storeEvent()` -- insert into `ws_events`, returns auto-incremented ID
- `queryEventsAfter(afterId)` -- fetch events for client catch-up
- `queryRecentEvents()` -- fetch last N events for CLI viewer
- `initUserTables(userId)` -- create per-user VRCX-compatible tables

Database tables:
- **`ws_events`** -- raw event log (id, received_at, event_type, content_json, raw_json)
- **`ws_connection_log`** -- WebSocket connection/disconnection events
- **`cache_world`**, **`cache_avatar`** -- VRCX-compatible global caches
- **Per-user tables** (prefixed with sanitized user ID):
  - `*_feed_gps`, `*_feed_status`, `*_feed_bio`, `*_feed_avatar` -- change logs
  - `*_feed_online_offline` -- presence history
  - `*_friend_log_current`, `*_friend_log_history` -- friend list tracking
  - `*_notifications`, `*_moderation` -- notification and block/mute logs

### `friends.d`
In-memory friend presence tracker.

- `FriendsTracker` -- state machine updated by WebSocket events
- `seedFromAPI()` -- initialize from REST API friend list
- `processEvent()` -- update state from live events (online, offline, active, location, update, add, delete)
- `buildFriendsMessage()` -- serialize all friends grouped by instance for client delivery
- `enrichContent()` -- add displayName/platform to event content when missing

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

## Building

```bash
dub build :server
dub test :server
```

Requires libcurl 8.11+ for WebSocket support.

Uses static build by default via ddcurl due to the WS requirement and some platforms providing older versions, allowing custom builds.
