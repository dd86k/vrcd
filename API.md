# Server-Client API Reference

vrcd uses a **JSON-L** (newline-delimited JSON) protocol over TCP for server-client communication.

- **Default port:** 9700
- **Default bind:** 127.0.0.1
- **Encoding:** UTF-8
- **Line terminator:** `\n`
- **Receive buffer:** 8192 bytes per read; lines are accumulated until a `\n` arrives
- **Max line length:** 32 MiB (server-side inbound cap; exceeding it disconnects the client). Large payloads (image uploads/downloads) are base64-encoded inside a single line, so this bounds them to ~24 MiB of binary

## Transport

A single TCP connection carries both requests and live event streams. The protocol is **full-duplex**: either side can send a message at any time. JSON-L framing (one JSON object per `\n`-terminated line) makes messages self-delimiting regardless of direction.

There is no peeking or out-of-band signaling. Both sides use a blocking receive loop that accumulates bytes into a buffer and extracts complete lines as they arrive.

### Server Threading Model

The server spawns one thread per client. Each `ClientHandler` thread runs a blocking `receive()` loop to read client requests. Live events (from the VRChat WebSocket) are broadcast from the main event-processing path, writing directly to each client's socket. A per-client `sendMutex` serializes writes from the handler thread and the broadcast path so they don't interleave.

### Client Threading Model

The client has two receive modes:

- **Blocking (`run`)**: A single-threaded receive loop that processes messages inline via callbacks. Used for CLI mode.
- **Threaded (`runThreaded`)**: A dedicated network thread pushes received JSON lines into a thread-safe `MessageQueue`. The main SDL thread is woken via `SDL_PushEvent` to drain the queue. Ping/pong is handled directly in the network thread to avoid queuing delay.

In both modes the client sends requests (`auth`, `catch_up`, `get_friends`, etc.) by writing to the same socket. Client sends are serialized by a `sendMutex` and loop on partial sends: the main thread sends requests while the network thread sends `pong`, and large lines (base64 image uploads) can exceed what a single `send()` accepts.

## Authentication

Authentication uses a shared secret token. If the server's secret is empty, auth is disabled.

### Client sends:
```json
{"type": "auth", "token": "<shared-secret>"}
```

### Server responds:

**Success:**
```json
{"type": "auth_ok", "server_version": 2}
```

Protocol versions: `1` = base protocol, `2` = adds the content API (files, prints, inventory, images, uploads), `3` = adds the moderation API (moderations, moderate_user, unfriend).

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

### `get_moderations`

Request the mute/block moderations snapshot. Server replies with `moderations`. Always refetches `GET auth/user/playermoderations` from VRChat: there are no WebSocket events for player moderations, so the cache goes stale whenever the user moderates in-game. Clients send this automatically after connect (when `server_version >= 3`) and from the Refresh button on the moderation list pages.

```json
{"type": "get_moderations"}
```

### `moderate_user`

Add or remove a player moderation. The server calls `POST auth/user/playermoderations` (mute/block) or `PUT auth/user/unplayermoderate` (unmute/unblock), updates its cache, replies with `moderate_result`, and on success broadcasts a fresh `moderations` snapshot to all authenticated clients.

| Field     | Type   | Description                                             |
|-----------|--------|---------------------------------------------------------|
| `type`    | string | `"moderate_user"`                                       |
| `user_id` | string | Target user ID (`usr_...`)                              |
| `action`  | string | One of `"mute"`, `"unmute"`, `"block"`, `"unblock"`     |

### `unfriend`

Remove a friend. The server calls `DELETE auth/user/friends/{userId}`, replies with `unfriend_result`, and on success eagerly removes the friend from the tracker and broadcasts a fresh `friends` snapshot (rather than waiting for the `friend-delete` WebSocket event). HTTP 404 is treated as success: the friendship is already gone, which is the desired end state.

| Field     | Type   | Description                 |
|-----------|--------|-----------------------------|
| `type`    | string | `"unfriend"`                |
| `user_id` | string | Target user ID (`usr_...`)  |

### `set_status`

Set the logged-in user's status and/or custom status message. The server issues a `PUT users/{selfUserId}` to VRChat, updates its self entry from the response, broadcasts a fresh `self` snapshot to all authenticated clients, and replies to the requester with `set_status_result`.

Either field may be omitted to leave it unchanged; at least one must be present.

| Field                | Type   | Description                                                  |
|----------------------|--------|-------------------------------------------------------------|
| `type`               | string | `"set_status"`                                              |
| `status`             | string | Optional. One of `"active"`, `"join me"`, `"ask me"`, `"busy"` |
| `status_description` | string | Optional. Custom status message text                        |

### `get_files`

Request a page of the logged-in user's files for one content tag. The server proxies `GET /files` on VRChat and replies with `files`.

| Field    | Type   | Description                                             |
|----------|--------|---------------------------------------------------------|
| `type`   | string | `"get_files"`                                           |
| `tag`    | string | One of `"gallery"`, `"icon"`, `"sticker"`, `"emoji"`    |
| `n`      | int    | Optional. Page size (default 60)                        |
| `offset` | int    | Optional. Page offset (default 0)                       |

### `get_prints`

Request the logged-in user's prints. Server replies with `prints` (single page, up to 100 entries; VRChat caps prints at 64 per user).

```json
{"type": "get_prints"}
```

### `get_inventory`

Request the logged-in user's inventory items (props, bundles, drone/portal skins, warp effects). Emoji and stickers are excluded, since they have their own sections sourced from the files endpoint. The server pages through VRChat's inventory API (up to 500 items) and replies with `inventory`.

| Field      | Type   | Description                              |
|------------|--------|------------------------------------------|
| `type`     | string | `"get_inventory"`                        |
| `archived` | bool   | Optional. Return archived items instead  |

### `get_inventory_drops`

Request the currently active inventory drop campaigns. Server replies with `inventory_drops`.

```json
{"type": "get_inventory_drops"}
```

### `get_image`

Request image bytes through the server proxy. The server serves from its disk cache when possible, otherwise downloads from VRChat (rate-limit aware, 250 ms minimum spacing) and caches the result. Replies with `image`.

| Field     | Type   | Description                                                    |
|-----------|--------|----------------------------------------------------------------|
| `type`    | string | `"get_image"`                                                  |
| `file_id` | string | File ID (`file_...`)                                           |
| `version` | int    | Optional. File version (default 1)                             |
| `size`    | int    | Optional. `0` = original file (default); `128`, `256`, `512`, or `1024` = thumbnail edge |

### `delete_file`

Delete a file (gallery image, icon, sticker, or emoji). Server replies with `delete_file_result`.

| Field     | Type   | Description          |
|-----------|--------|----------------------|
| `type`    | string | `"delete_file"`      |
| `file_id` | string | File ID (`file_...`) |

### `delete_print`

Delete a print. Server replies with `delete_print_result`.

| Field      | Type   | Description           |
|------------|--------|-----------------------|
| `type`     | string | `"delete_print"`      |
| `print_id` | string | Print ID (`prnt_...`) |

### `set_user_icon`

Set or clear the logged-in user's profile icon. Requires VRC+ (VRChat returns 403 otherwise). Server replies with `set_user_icon_result`.

| Field     | Type   | Description                                  |
|-----------|--------|----------------------------------------------|
| `type`    | string | `"set_user_icon"`                            |
| `file_id` | string | Icon file ID; empty string clears the icon   |

### `inventory_action`

Equip, unequip, or consume an inventory item. Server replies with `inventory_action_result`.

| Field          | Type   | Description                                            |
|----------------|--------|--------------------------------------------------------|
| `type`         | string | `"inventory_action"`                                   |
| `action`       | string | `"equip"`, `"unequip"`, or `"consume"`                 |
| `inventory_id` | string | Inventory item ID (`inv_...`); not used for `unequip`  |
| `slot`         | string | Equip slot name; required for `equip` and `unequip`    |

### `upload_image`

Upload a PNG to the files API under a content tag. The server validates the payload (PNG only, max 10 MB, max 2000x2000, square for stickers/emoji) before forwarding it as a multipart POST. Replies with `upload_image_result`.

| Field            | Type   | Description                                          |
|------------------|--------|------------------------------------------------------|
| `type`           | string | `"upload_image"`                                     |
| `tag`            | string | One of `"gallery"`, `"icon"`, `"sticker"`, `"emoji"` |
| `data_base64`    | string | PNG bytes, base64-encoded                            |
| `animationStyle` | string | Optional (animated emoji)                            |
| `loopStyle`      | string | Optional (animated emoji)                            |
| `frames`         | int    | Optional (animated emoji)                            |
| `framesOverTime` | int    | Optional (animated emoji)                            |

### `upload_print`

Upload a PNG as a print. Same size limits as `upload_image`; additionally throttled server-side to one upload per 2.5 seconds. Replies with `upload_print_result`.

| Field         | Type   | Description                                            |
|---------------|--------|--------------------------------------------------------|
| `type`        | string | `"upload_print"`                                       |
| `data_base64` | string | PNG bytes, base64-encoded                              |
| `note`        | string | Optional. Print caption                                |
| `world_id`    | string | Optional. World the picture was taken in               |
| `world_name`  | string | Optional. World name                                   |
| `timestamp`   | string | Optional. ISO 8601; defaults to the current time (UTC) |

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
| `server_version` | int    | Protocol version (currently 2) |

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
| `bio`               | string | Long-form profile blurb (distinct from `statusDescription`) |
| `pronouns`          | string | User-set pronouns        |
| `bioLinks`          | array  | Profile URLs the user pinned |

### `self`

Snapshot of the logged-in user's own status. Sent after auth (immediately following `status`) and whenever the self status changes (e.g. after a successful `set_status`). Omitted if the server does not yet know the logged-in user.

| Field               | Type   | Description                                                |
|---------------------|--------|------------------------------------------------------------|
| `type`              | string | `"self"`                                                   |
| `id`                | string | User ID (`usr_...`)                                        |
| `displayName`       | string | Display name                                               |
| `status`            | string | `"active"`, `"join me"`, `"ask me"`, `"busy"`              |
| `statusDescription` | string | Custom status text                                         |
| `bio`               | string | Long-form profile blurb                                    |
| `pronouns`          | string | User-set pronouns                                          |
| `bioLinks`          | array  | Profile URLs the user pinned                               |

### `set_status_result`

Reply to a `set_status` request, sent only to the requesting client. On success, a `self` broadcast precedes this for all clients.

| Field     | Type   | Description                                  |
|-----------|--------|----------------------------------------------|
| `type`    | string | `"set_status_result"`                        |
| `success` | bool   | Whether the VRChat update succeeded          |
| `error`   | string | Error description (present only on failure)  |

### `moderations`

Mute/block snapshot. Sent as the reply to `get_moderations` and broadcast to all authenticated clients after any successful `moderate_user`. Moderation types other than mute/block (e.g. `interactOff`) are not included.

| Field     | Type   | Description                                        |
|-----------|--------|----------------------------------------------------|
| `type`    | string | `"moderations"`                                    |
| `muted`   | array  | Muted users: `{user_id, display_name}`             |
| `blocked` | array  | Blocked users: `{user_id, display_name}`           |
| `error`   | string | On failure, sent *instead of* the lists (rate limit, VRChat error) |

### `moderate_result`

Reply to a `moderate_user` request, sent only to the requesting client. On success, a `moderations` broadcast for all clients follows.

| Field          | Type   | Description                                  |
|----------------|--------|----------------------------------------------|
| `type`         | string | `"moderate_result"`                          |
| `success`      | bool   | Whether the VRChat call succeeded            |
| `action`       | string | Echoed action                                |
| `user_id`      | string | Echoed target user ID                        |
| `display_name` | string | Target display name (best known; may be empty) |
| `error`        | string | Error description (present only on failure)  |

### `unfriend_result`

Reply to an `unfriend` request, sent only to the requesting client. On success, a `friends` broadcast for all clients follows. Same fields as `moderate_result`, without `action`.

### `world`

Response to `get_world`.

| Field        | Type   | Description          |
|--------------|--------|----------------------|
| `type`       | string | `"world"`            |
| `world_id`   | string | World ID             |
| `world_name` | string | Resolved world name  |

### `files`

Reply to `get_files`: one page of trimmed file entries.

| Field    | Type   | Description                                     |
|----------|--------|--------------------------------------------------|
| `type`   | string | `"files"`                                        |
| `tag`    | string | The requested tag                                |
| `offset` | int    | The requested offset                             |
| `count`  | long   | Number of entries in this page                   |
| `files`  | array  | File entries (empty on failure)                  |
| `error`  | string | Error description (present only on failure)      |

Each file entry:

| Field       | Type   | Description                                            |
|-------------|--------|--------------------------------------------------------|
| `id`        | string | File ID (`file_...`)                                   |
| `name`      | string | File name                                              |
| `version`   | long   | Highest complete, non-deleted version (`0` = none usable) |
| `mimeType`  | string | MIME type                                              |
| `extension` | string | File extension                                         |
| `tags`      | array  | VRChat tags                                            |

Animated emoji entries may also carry `animationStyle`, `loopStyle`, `frames`, and `framesOverTime`.

### `prints`

Reply to `get_prints`.

| Field    | Type   | Description                                 |
|----------|--------|---------------------------------------------|
| `type`   | string | `"prints"`                                  |
| `prints` | array  | Print entries (empty on failure)            |
| `error`  | string | Error description (present only on failure) |

Each print entry:

| Field          | Type   | Description                                  |
|----------------|--------|----------------------------------------------|
| `id`           | string | Print ID (`prnt_...`)                        |
| `file_id`      | string | Image file ID, for `get_image`               |
| `file_version` | long   | Image file version                           |
| `note`         | string | Caption                                      |
| `worldId`      | string | World the picture was taken in               |
| `worldName`    | string | World name                                   |
| `authorName`   | string | Author display name                          |
| `timestamp`    | string | Picture timestamp (ISO 8601)                 |
| `createdAt`    | string | Print creation time (ISO 8601)               |

### `inventory`

Reply to `get_inventory`.

| Field         | Type   | Description                                 |
|---------------|--------|---------------------------------------------|
| `type`        | string | `"inventory"`                               |
| `archived`    | bool   | Whether archived items were requested       |
| `total_count` | long   | Total items VRChat reports for this filter  |
| `items`       | array  | Inventory entries (empty on failure)        |
| `error`       | string | Error description (present only on failure) |

Each inventory entry:

| Field           | Type   | Description                                          |
|-----------------|--------|------------------------------------------------------|
| `id`            | string | Inventory item ID (`inv_...`)                        |
| `name`          | string | Item name                                            |
| `description`   | string | Item description                                     |
| `itemType`      | string | VRChat item type (e.g. `"prop"`, `"emoji"`)          |
| `itemTypeLabel` | string | Human-readable type label                            |
| `equipSlot`     | string | Equip slot, when applicable                          |
| `flags`         | array  | Capability flags (`"equippable"`, `"consumable"`, ...) |
| `collections`   | array  | Collections the item belongs to                      |
| `isArchived`    | bool   | Whether the item is archived                         |
| `expiryDate`    | string | Expiry, when applicable                              |
| `image_file_id` | string | Image file ID, for `get_image` (when resolvable)     |
| `image_version` | long   | Image file version                                   |

### `inventory_drops`

Reply to `get_inventory_drops`. Same envelope as `inventory` (`items` array + optional `error`), carrying VRChat's drop campaign objects.

### `image`

Reply to `get_image`. Echoes the request identity so the client can key its cache.

| Field         | Type   | Description                                    |
|---------------|--------|-------------------------------------------------|
| `type`        | string | `"image"`                                       |
| `file_id`     | string | Requested file ID                               |
| `version`     | long   | Requested version                               |
| `size`        | int    | Requested size                                  |
| `success`     | bool   | Whether the bytes are included                  |
| `mime_type`   | string | Sniffed MIME type (success only)                |
| `data_base64` | string | Image bytes, base64-encoded (success only)      |
| `error`       | string | Error description (present only on failure)     |

### Action results

`delete_file_result`, `delete_print_result`, `set_user_icon_result`, and `inventory_action_result` share the same envelope: the request's identifying fields echoed back (`file_id`, `print_id`, or `action` + `inventory_id`) plus:

| Field     | Type   | Description                                  |
|-----------|--------|----------------------------------------------|
| `success` | bool   | Whether the VRChat call succeeded            |
| `error`   | string | Error description (present only on failure)  |

`set_user_icon_result` reports `"HTTP 403 (VRC+ required)"` when the account lacks VRC+. Each action result is followed by a `status` broadcast, since the action consumed VRChat API budget.

### `upload_image_result` / `upload_print_result`

Reply to `upload_image` / `upload_print`. Same success/error envelope as action results; on success also carries the created object:

| Field   | Type   | Description                                           |
|---------|--------|-------------------------------------------------------|
| `file`  | object | Trimmed file entry (see `files`) - `upload_image_result` only |
| `print` | object | Trimmed print entry (see `prints`) - `upload_print_result` only |

After a successful upload, VRChat emits a `content-refresh` event on the WebSocket, which the server stores and broadcasts as a normal `event`.

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
- `content-refresh` - The user's content changed (upload, delete, in-game print, inventory drop). `content.contentType` names what changed: `"gallery"`, `"icon"`, `"emoji"`, `"sticker"`, `"print"`, `"prints"`, `"inventory"`, `"avatar"`, `"world"`. Clients use it to mark the matching STUFF section stale and re-list on next view

### Synthesized Events
Derived on the server, not produced by VRChat's WebSocket.

- `avatar-change` *(persisted)* - A tracked entry's `currentAvatar` changed between updates. Content: `{ userId, displayName, previousAvatar, currentAvatar, isSelf }`.
- `profile-change` *(persisted)* - A tracked entry's `bio`, `pronouns`, or `bioLinks` changed between two non-empty values. First sighting of a subfield and clears (non-empty -> empty) seed silently and do not emit. A single edit covering multiple subfields produces one combined event. Content: `{ userId, displayName, isSelf, previousBio?, currentBio?, previousPronouns?, currentPronouns?, previousBioLinks?, currentBioLinks? }` - only the `previous*`/`current*` pairs for subfields that actually changed are included.
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
| `image_cache`     | `<data dir>/imagecache/` | Server-side image disk cache directory |
| `image_cache_max_mb` | `256`        | Image cache size cap (mtime-LRU eviction) |
