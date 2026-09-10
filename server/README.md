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
        --tls-cert        Path to PEM TLS certificate (enables TLS when paired with --tls-key)
        --tls-key         Path to PEM TLS private key
        --tls-ca          Path to CA certificate for client verification (mTLS)
        --tls-verify-client  Require clients to present a valid certificate
        --tls-port        Separate port for TLS connections
        --tls-only        Disable plain TCP listener when TLS is active
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

# TLS: both tls_cert and tls_key must be set together to enable encryption.
# Requires OpenSSL 3.x shared libraries at runtime (libssl, libcrypto).
# tls_cert = /srv/vrcd/server.crt
# tls_key  = /srv/vrcd/server.key

# Separate port for TLS (like HTTP/HTTPS). 0 or omit = same port.
# tls_port = 9701

# Disable the plain TCP listener when TLS is active.
# tls_only = false

# Mutual TLS: require clients to present a certificate signed by this CA.
# tls_ca = /srv/vrcd/ca.crt
# tls_verify_client = false
```

### TLS

TLS is available when OpenSSL 3.x shared libraries (`libssl.so.3` / `libcrypto.so.3` on Linux, `libssl-3-x64.dll` / `libcrypto-3-x64.dll` on Windows) are present at runtime. No compile-time dependency or build flag is needed. If the libraries can't be loaded, TLS options are simply unavailable.

#### Server-only TLS (one-way)

Encrypts the connection; the server proves its identity to the client.

**1. Generate a self-signed certificate** (suitable for a local network or VPN):

```bash
openssl req -x509 -newkey rsa:4096 -keyout server.key -out server.crt \
    -days 3650 -nodes -subj "/CN=vrcd-server"
```

**2. Configure the server** set `tls_cert` / `tls_key` in `server.conf`, or pass `--tls-cert` / `--tls-key` on the CLI.

**3. Configure the client** enable "TLS" in Settings. A self-signed certificate is not in any trust store, so either set "CA cert" to a copy of the certificate itself, or check "Skip certificate verify".

#### Separate TLS port

By default, when TLS is configured the main listen port performs TLS handshakes for every connection. To run plain and TLS on different ports (like HTTP/HTTPS):

```conf
listen = 0.0.0.0:9700
tls_port = 9701
```

This starts two listeners: plain TCP on 9700 and TLS on 9701. To disable the plain listener entirely:

```conf
tls_only = true
```

#### Mutual TLS (mTLS)

Both sides verify each other's certificate. The server rejects clients that don't present a valid cert. Useful when you want to restrict access beyond the shared secret.

**1. Create a CA** and sign both server and client certificates. `tools/gen-certs.sh` does this in one run, with subject alternative names and the right key usages, and reuses an existing CA so a client can be added later:

```bash
tools/gen-certs.sh -o /srv/vrcd -H vrcd.lan -c desktop
```

By hand:

```bash
# CA key and cert
openssl req -x509 -newkey rsa:4096 -keyout ca.key -out ca.crt \
    -days 3650 -nodes -subj "/CN=vrcd-ca"

# Server cert signed by CA
openssl req -newkey rsa:4096 -keyout server.key -out server.csr \
    -nodes -subj "/CN=vrcd-server"
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key \
    -CAcreateserial -out server.crt -days 3650

# Client cert signed by same CA
openssl req -newkey rsa:4096 -keyout client.key -out client.csr \
    -nodes -subj "/CN=vrcd-client"
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key \
    -CAcreateserial -out client.crt -days 3650
```

**2. Server config:**

```conf
tls_cert = /srv/vrcd/server.crt
tls_key  = /srv/vrcd/server.key
tls_ca   = /srv/vrcd/ca.crt
tls_verify_client = true
```

**3. Client settings** enable "TLS", then set:

- **CA cert** to `ca.crt`, so the server is verified against your CA. Leaving it empty falls back to the system trust store, which does not know a private CA; installing `ca.crt` there instead would also trust it for every other program on that machine. "Skip certificate verify" turns verification off entirely, which leaves the client certificate as the only thing being checked.
- **Certificate** and **Key** to `client.crt` and `client.key`.

With "CA cert" set, the host you connect to must appear in the server certificate's SAN -- the name is checked, not just the chain, so a certificate the CA issued to a client cannot pose as the server. `tools/gen-certs.sh` puts `vrcd-server`, `localhost`, `127.0.0.1` and `::1` in there by default; pass `-H` for anything else.

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
                 └──> Synthesized events
                           │
                           ├──> Persisted (e.g. avatar-change) -> Store + Broadcast
                           └──> Ephemeral (e.g. friend-traveling) -> Broadcast only (id=0)
```

Events arrive from VRChat's WebSocket, get parsed and enriched with display names and world names from cache, then are both persisted to SQLite and broadcast live to all authenticated clients. The tracker may also derive synthesized events from state diffs (e.g. an `avatar-change` when a cached `currentAvatar` changes between two `friend-update`/`user-update` payloads); persisted synthetics go through the same store+broadcast path as real events. Ephemeral synthetics are broadcast live with `id=0` and never stored — they convey transient real-time signal (e.g. "friend is joining a world") that has no value in the historical log.

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
- **WebSocket thread** -- persistent connection to `wss://pipeline.vrchat.cloud`, exponential reconnect backoff (2s base, doubling to a 5-min cap)
- **TCP accept thread** -- listens for client connections
- **Client threads** -- one per connected client, handles JSON-L protocol

## Modules

### `main.d`
Entry point and command dispatcher. Parses CLI arguments, orchestrates startup, and wires the event callback chain (enrich -> store -> broadcast). Also implements `cmdAuth` for interactive login and `cmdEvents` for querying stored events.

### `config.d`
Configuration struct with platform-specific defaults. Fields: listen address/port, database path, credentials path, cookie jar path, shared secret, prune retain period, TLS settings (certificate, key, CA, verify client, separate port, TLS-only mode).

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
| Synthesized (persisted) | `avatar-change` |
| Synthesized (ephemeral) | `friend-traveling` |

**Synthesized events** are not produced by VRChat's WebSocket. They are derived on the server from observed state, in two flavors:

- *Persisted* synthetics go through the same store + broadcast path as real events, so catch-up and the event viewer see them alongside the rest.
- *Ephemeral* synthetics are broadcast live with `id=0` and never written to `ws_events`. They carry transient signal that would only pollute the historical feed (typically because VRChat will send a follow-up frame seconds later that supersedes them). Clients must not advance their high-water cursor on `id=0` events.

Currently:

- `avatar-change` *(persisted)* -- emitted when the cached `currentAvatar` on a tracked entry (friend or self) changes between updates. Content: `{ userId, displayName, previousAvatar, currentAvatar, isSelf }`. Clients can filter self-originated changes via the `isSelf` flag.
- `friend-traveling` *(ephemeral)* -- emitted when an incoming `friend-location` carries `location == "traveling"`, i.e. the friend's client is loading the next world. The raw traveling frame is suppressed (never stored, never broadcast) since the concrete arrival event follows seconds later; the `friend-traveling` ping lets clients render a "Joining X" pseudo event without inflating the DB or producing feed doubles. Content: `{ userId, displayName, travelingToLocation, world, worldName }` (world/worldName included when VRChat populated them on the source frame).

### `database.d`
SQLite persistence layer via arsd-official:sqlite.

- `storeEvent()` -- insert into `ws_events`, returns auto-incremented ID
- `queryEventsAfter(afterId)` -- fetch events for client catch-up
- `queryEventsBefore(beforeId)` -- fetch older events for client back-fill
- `queryRecentEvents()` -- fetch last N events for CLI viewer
- `pruneOldEvents(modifier)` -- delete events older than a SQLite datetime modifier (e.g. `"-3 months"`); prunes both `ws_events` and `ws_connection_log`

Database tables:
- **`ws_events`** -- append-only event log holding both raw VRChat WS events and synthetic events derived by the server (id, received_at, event_type, source, data). `source` is `"raw"` or `"synthetic"`. `data` is the event JSON envelope: the original WS frame for raw events, or a server-built envelope for synthetic ones.
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

### `stream.d`
Transport abstraction over plain TCP and TLS. OpenSSL is loaded dynamically at runtime.

- `Stream` -- abstract class with `receive`, `send`, `close`.
- `PlainStream` -- wraps a `std.socket.Socket`.
- `TLSServerStream` -- wraps `Socket` + dynamically loaded OpenSSL; performs `SSL_accept` on construction.
- `loadTLS()` -- attempts to load OpenSSL shared libraries; returns true if TLS is available.
- `tlsAvailable()` -- returns whether OpenSSL was loaded successfully.
- `createServerTLSContext(certPath, keyPath, caPath, verifyClient)` -- creates and validates a server SSL context from PEM files; optionally enables mutual TLS.

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

- Background thread with automatic reconnection using exponential backoff (2s base, doubling to a 5-min cap; reset once a connection has stayed up a minute)
- The pipeline drops a connection after roughly two minutes regardless of traffic, so reconnecting is routine rather than an outage response, and the base delay is kept short for that reason. A reconnect re-seeds friend state to cover the gap only when the gap ran past 15 seconds: recovering the two seconds of a routine cycle costs a full REST pass and recovers nothing
- 30-second receive poll timeout. An idle timeout is treated as still-connected, not a disconnect. No ping is sent: one was tried as a probe for a half-open socket and never once fired, since the pipeline never goes a minute without a frame, and curl reports the drop by itself
- RFC 6455 close codes are logged and acted on: `1008` (policy violation) triggers re-auth like an HTTP 401/403, `1013` (try again later) jumps to the max backoff like a 429
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

System packages. SQLite is always needed at link time: `arsd-official:sqlite` declares `libs: ["sqlite3"]` unconditionally and offers no configuration to avoid it. libcurl is only needed at link time under the `static` configuration.

| | Always | `-c static` only |
|---|---|---|
| Ubuntu | `libsqlite3-dev` | `libcurl4-openssl-dev` (build libcurl yourself if the distribution ships <8.11) |
| Alpine | `sqlite-dev` | `curl-dev` |

For `-b static-release`, use the fully static variants on Alpine (`sqlite-static`, `curl-static`).

OpenSSL 3.x shared libraries (`libssl.so.3`, `libcrypto.so.3`) are loaded dynamically at runtime for TLS support. They are not a build dependency under either configuration.

### Version pinning

Registry dependencies are pinned exactly (`==`), git dependencies to a commit SHA. `dub build` never corrects a `dub.selections.json` that disagrees with those pins. A version conflict at least fails the build; a stale git commit is accepted silently and used in preference to the manifest. After changing any dependency, run:

```bash
dub upgrade -s
```

`-s` (`--sub-packages`) is required. Without it dub upgrades only the root package, which declares no dependencies of its own, so the command reports success while changing nothing.

## Building

```bash
dub build :server              # dynamic libcurl (default)
dub build :server -c static    # libcurl linked at build time
dub test :server
```

### Configurations

| Configuration | libcurl | Notes |
|---------------|---------|-------|
| `application` (default) | loaded at run time through ddloader | Nothing links against the build host's libcurl, so the binary moves between distributions and picks up system libcurl updates |
| `static` | linked at build time | For hosts with no loadable libcurl, or when a self-contained binary is wanted. Needs libcurl's import library present (`-lcurl`, `libcurl-x64.lib` on Windows) |

libcurl 8.11+ is required for WebSocket support either way. Under the default configuration that is a property of the library present at run time, rather than one frozen into the binary by whichever machine built it.

`static-release` is a *build type*, not a configuration, and covers a different axis: it links libc itself statically and enables optimizations. Combine the two for a fully self-contained binary:

```bash
dub build :server -c static -b static-release
```

Do that on musl (Alpine) rather than glibc: a statically linked glibc binary
still resolves names through NSS, which is loaded at run time, so it works on
the machine that built it and fails on the next one. musl resolves in-process
and has no such split. CI builds this in an `alpine:3.21` container and
attaches the binary to releases.

The trade is that a fully static binary cannot `dlopen` anything, so the
server's *own* TLS listener is unavailable in that build (OpenSSL is loaded at
run time; see [`stream.d`](#streamd)). It starts, logs that TLS is
unavailable, and serves the JSON-L API in plain TCP. Outgoing HTTPS to VRChat
is unaffected, since that TLS comes from the statically linked libcurl.

Linking it needs the archives of everything libcurl itself pulls in, which
`-lcurl` alone does not name. `pkg-config` does:

```bash
DFLAGS="$(pkg-config --static --libs libcurl sqlite3 | xargs -n1 printf -- '-L%s ')" \
    dub build :server -c static -b static-release
```

> **Note:** If you get linking issues on Windows, try with LDC: `--compiler=ldc2`