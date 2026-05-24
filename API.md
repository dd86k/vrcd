# Server-Client API Reference

vrcd uses a **JSON-L** (newline-delimited JSON) protocol over TCP for server-client communication.

- **Default port:** 9700
- **Default bind:** 127.0.0.1
- **Encoding:** UTF-8
- **Line terminator:** `\n`
- **Buffer size:** 8192 bytes (both sides)

## Transport

A single TCP connection carries both requests and live event streams. The protocol is **full-duplex**: either side can send a message at any time. JSON-L framing (one JSON object per `\n`-terminated line) makes messages self-delimiting regardless of direction.

There is no peeking or out-of-band signaling. Both sides use a blocking receive loop that accumulates bytes into a buffer and extracts complete lines as they arrive.

### Server Threading Model

The server spawns one thread per client. Each `ClientHandler` thread runs a blocking `receive()` loop to read client requests. Live events (from the VRChat WebSocket) are broadcast from the main event-processing path, writing directly to each client's socket. A per-client `sendMutex` serializes writes from the handler thread and the broadcast path so they don't interleave.

### Client Threading Model

The client has two receive modes:

- **Blocking (`run`)**: A single-threaded receive loop that processes messages inline via callbacks. Used for CLI mode.
- **Threaded (`runThreaded`)**: A dedicated network thread pushes received JSON lines into a thread-safe `MessageQueue`. The main SDL thread is woken via `SDL_PushEvent` to drain the queue. Ping/pong is handled directly in the network thread to avoid queuing delay.

In both modes the client sends requests (`auth`, `catch_up`, `get_friends`, etc.) by writing to the same socket. Sends are not mutex-protected on the client because only one thread writes (the main thread sends requests; the network thread only sends `pong`).

## Authentication

Authentication uses a shared secret token. If the server's secret is empty, auth is disabled.

### Client sends:
```json
{"type": "auth", "token": "<shared-secret>"}
```

### Server responds:

**Success:**
```json
{"type": "auth_ok", "server_version": 1}
```

**Failure:**
```json
{"type": "auth_error", "message": "Invalid token"}
```

All other messages require authentication. Unauthenticated messages are rejected with an error.

## Client-to-Server Messages

### `auth`

Authenticate with the server. Must be sent first.

| Field   | Type   | Description          |
|---------|--------|----------------------|
| `type`  | string | `"auth"`             |
| `token` | string | Shared secret token  |

### `status`

Request current server status.

```json
{"type": "status"}
```

### `catch_up`

Request events since a given ID. Server sends up to 1000 events in ascending order, followed by a `caught_up` message. To paginate, send another `catch_up` with the last received event ID.

| Field      | Type | Description                        |
|------------|------|------------------------------------|
| `type`     | string | `"catch_up"`                     |
| `since_id` | long | Last known event ID (0 for all)    |

### `fetch_older`

Request a page of older events (with id strictly less than `before_id`). Server sends matching events in **descending** order as `event_older` messages (capped at `limit`, max 500), followed by an `older_fetched` terminator. Intended for UI back-fill when a client has caught up and wants to scroll into history.

| Field       | Type | Description                               |
|-------------|------|-------------------------------------------|
| `type`      | string | `"fetch_older"`                         |
| `before_id` | long | Return events with id < before_id         |
| `limit`     | int  | Max events to return (default 100, max 500) |

### `get_friends`

Request current friends state snapshot.

```json
{"type": "get_friends"}
```

### `get_world`

Request world name resolution.

| Field      | Type   | Description                  |
|------------|--------|------------------------------|
| `type`     | string | `"get_world"`                |
| `world_id` | string | World ID (e.g. `"wrld_..."`) |

### `set_status`

Set the logged-in user's status and/or custom status message. The server issues a `PUT users/{selfUserId}` to VRChat, updates its self entry from the response, broadcasts a fresh `self` snapshot to all authenticated clients, and replies to the requester with `set_status_result`.

Either field may be omitted to leave it unchanged; at least one must be present.

| Field                | Type   | Description                                                  |
|----------------------|--------|-------------------------------------------------------------|
| `type`               | string | `"set_status"`                                              |
| `status`             | string | Optional. One of `"active"`, `"join me"`, `"ask me"`, `"busy"` |
| `status_description` | string | Optional. Custom status message text                        |

### `pong`

Keepalive response to server's `ping`.

```json
{"type": "pong"}
```

## Server-to-Client Messages

### `auth_ok`

Authentication succeeded.

| Field            | Type   | Description              |
|------------------|--------|--------------------------|
| `type`           | string | `"auth_ok"`              |
| `server_version` | int    | Protocol version (currently 1) |

### `auth_error`

Authentication failed.

| Field     | Type   | Description        |
|-----------|--------|--------------------|
| `type`    | string | `"auth_error"`     |
| `message` | string | Error description  |

### `status`

Server status. Sent after auth and on VRChat connection changes, or when requested.

| Field                | Type   | Description                          |
|----------------------|--------|--------------------------------------|
| `type`               | string | `"status"`                           |
| `vrchat_connected`   | bool   | Whether VRChat WebSocket is connected |
| `vrchat_last_error`  | string | Last connection error (optional)     |

### `event`

A VRChat event, either live or during catch-up.

| Field         | Type   | Description                                |
|---------------|--------|--------------------------------------------|
| `type`        | string | `"event"`                                  |
| `id`          | long   | Auto-incrementing event ID (1-based). `0` for ephemeral broadcasts (not persisted; see below) |
| `received_at` | string | ISO 8601 timestamp (UTC)                   |
| `event_type`  | string | VRChat event type (see below)              |
| `content`     | object | Parsed event content (enriched by server)  |

Ephemeral events (`id == 0`) are live-only signals that the server never writes to `ws_events`. They will not appear in catch-up or `fetch_older` results, and clients must not advance their stored high-water mark (`last_event_id`) when they arrive. Currently emitted for `friend-traveling`.

### `caught_up`

Sent after all catch-up events have been delivered.

| Field     | Type   | Description                  |
|-----------|--------|------------------------------|
| `type`    | string | `"caught_up"`                |
| `last_id` | long   | ID of the last event in the database |

### `event_older`

A back-filled VRChat event from a `fetch_older` request. Same fields as `event` but the `type` is `"event_older"` so the client can append it to the tail of the feed without advancing its live-cursor high-water mark.

### `older_fetched`

Terminator for a `fetch_older` response. Sent after all `event_older` messages in the batch.

| Field       | Type   | Description                                  |
|-------------|--------|----------------------------------------------|
| `type`      | string | `"older_fetched"`                            |
| `before_id` | long   | The `before_id` the client requested         |
| `oldest_id` | long   | ID of the oldest event in this batch (equals `before_id` when `count == 0`) |
| `count`     | long   | Number of events returned in this batch      |

### `friends`

Friends state snapshot. Sent after `get_friends` and when friends state changes.

| Field       | Type  | Description                              |
|-------------|-------|------------------------------------------|
| `type`      | string | `"friends"`                             |
| `instances` | array | Online friends grouped by instance       |
| `offline`   | array | Offline friends                          |

Each instance entry:

| Field         | Type   | Description                |
|---------------|--------|----------------------------|
| `instance_id` | string | VRChat instance ID         |
| `world_name`  | string | Resolved world name        |
| `friends`     | array  | Friends in this instance   |

Each friend entry (in both `instances[].friends` and `offline`):

| Field               | Type   | Description              |
|---------------------|--------|--------------------------|
| `id`                | string | User ID (`usr_...`)      |
| `displayName`       | string | Display name             |
| `status`            | string | `"active"`, `"join me"`, `"ask me"`, `"busy"`, `"offline"` |
| `statusDescription` | string | Custom status text       |
| `platform`          | string | `"standalonewindows"`, `"android"`, etc. |
| `location`          | string | Instance ID, `"private"`, or `"offline"` |

### `self`

Snapshot of the logged-in user's own status. Sent after auth (immediately following `status`) and whenever the self status changes (e.g. after a successful `set_status`). Omitted if the server does not yet know the logged-in user.

| Field               | Type   | Description                                                |
|---------------------|--------|------------------------------------------------------------|
| `type`              | string | `"self"`                                                   |
| `id`                | string | User ID (`usr_...`)                                        |
| `displayName`       | string | Display name                                               |
| `status`            | string | `"active"`, `"join me"`, `"ask me"`, `"busy"`              |
| `statusDescription` | string | Custom status text                                         |

### `set_status_result`

Reply to a `set_status` request, sent only to the requesting client. On success, a `self` broadcast precedes this for all clients.

| Field     | Type   | Description                                  |
|-----------|--------|----------------------------------------------|
| `type`    | string | `"set_status_result"`                        |
| `success` | bool   | Whether the VRChat update succeeded          |
| `error`   | string | Error description (present only on failure)  |

### `world`

Response to `get_world`.

| Field        | Type   | Description          |
|--------------|--------|----------------------|
| `type`       | string | `"world"`            |
| `world_id`   | string | World ID             |
| `world_name` | string | Resolved world name  |

### `ping`

Server keepalive. Client must respond with `pong`.

```json
{"type": "ping"}
```

### `error`

Error response for invalid messages.

| Field     | Type   | Description        |
|-----------|--------|--------------------|
| `type`    | string | `"error"`          |
| `message` | string | Error description  |

## VRChat Event Types

Events forwarded from VRChat's WebSocket, stored and broadcast as `event` messages.

### Friend Events
- `friend-online` - Friend came online
- `friend-offline` - Friend went offline
- `friend-active` - Friend became active
- `friend-update` - Friend profile updated
- `friend-location` - Friend changed location
- `friend-add` - New friend added
- `friend-delete` - Friend removed

### User Events
- `user-update` - Current user updated
- `user-location` - Current user changed location
- `user-badge-assigned` - Badge assigned
- `user-badge-unassigned` - Badge unassigned

### Notification Events
- `notification` - Legacy notification
- `notification-v2` - Notification received
- `notification-v2-delete` - Notification deleted
- `notification-v2-update` - Notification updated
- `see-notification` - Notification marked seen
- `hide-notification` - Notification hidden
- `response-notification` - Notification response

### Group Events
- `group-joined` - Joined a group
- `group-left` - Left a group
- `group-role-updated` - Group role changed
- `group-member-updated` - Group member updated

### Instance Events
- `instance-queue-joined` - Joined instance queue
- `instance-queue-position` - Queue position updated
- `instance-queue-ready` - Queue ready to enter
- `instance-queue-left` - Left instance queue
- `instance-closed` - Instance closed

### Content Events
- `content-refresh` - Content refresh signal

### Synthesized Events
Derived on the server, not produced by VRChat's WebSocket.

- `avatar-change` *(persisted)* - A tracked entry's `currentAvatar` changed between updates. Content: `{ userId, displayName, previousAvatar, currentAvatar, isSelf }`.
- `friend-traveling` *(ephemeral, `id == 0`)* - A friend's client is loading the next world (raw `friend-location` with `location == "traveling"`). Broadcast live for "Joining X" UI; never stored. The concrete arrival arrives shortly after as a normal `friend-location`. Content: `{ userId, displayName, travelingToLocation, world?, worldName? }`.

## Connection Flow

A typical client session:

```
Client                          Server
  |                                |
  |-------- TCP connect ---------> |
  |                                |
  |-- {"type":"auth","token":..} ->|
  |                                |
  |<- {"type":"auth_ok",...} ------|
  |<- {"type":"status",...} -------|
  |<- {"type":"self",...} ---------|
  |<- {"type":"friends",...} ------|
  |                                |
  |-- {"type":"catch_up",          |
  |    "since_id": 0} ------------>|
  |                                |
  |<- {"type":"event",...} --------|  (up to 1000 events)
  |<- {"type":"event",...} --------|
  |<- {"type":"caught_up",...} ----|
  |                                |
  |    ... live events ...         |
  |<- {"type":"event",...} --------|
  |<- {"type":"friends",...} ------|
  |                                |
  |<- {"type":"ping"} -------------|
  |-- {"type":"pong"} ------------>|
  |                                |
```

## Event Content Enrichment

Before forwarding events to clients, the server enriches event content:

1. **Display names and platform** - Looked up from the friends tracker cache
2. **World names** - Resolved via the world name cache (fetched from VRChat REST API, cached for 1 day; failures cached for 1 hour)

## Database Schema

Events are stored in SQLite with WAL mode:

```sql
CREATE TABLE ws_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  received_at TEXT NOT NULL,
  event_type TEXT NOT NULL,
  content_json TEXT,
  raw_json TEXT
);

CREATE INDEX idx_ws_events_type ON ws_events (event_type);
```

## Configuration

| Setting           | Default         | Description                    |
|-------------------|-----------------|--------------------------------|
| Listen address    | `127.0.0.1`     | TCP bind address               |
| Listen port       | `9700`          | TCP port                       |
| API secret        | (empty)         | Shared auth token; empty = no auth |
| Config directory  | `~/.config/vrcd/` (Linux), `%APPDATA%\vrcd\` (Windows) | |
| Data directory    | `~/.local/share/vrcd/` (Linux), `%APPDATA%\vrcd\` (Windows) | |
