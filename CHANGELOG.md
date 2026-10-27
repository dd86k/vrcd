# CHANGELOG

Changelog file for vrcd with newest tags first.

Rules:
- Separated by component: Client, Server, Web, Packaging, and API.
- Keep things simple and easy to read, long technical topics best left in source.
- Better to keep entries closest to the actual intent: "Server supports standard I/O"
  is clearer than "Client can start server" (37b843ed1d2d4bca6011a69dcb5e64fa581cf235).

## Unreleased

### Client

- Notification rules (TOOLS): get a notification for events VRChat does not
  notify about, like an unfriend or a friend coming online. A rule can be
  narrowed to some friends or a status, and quieted after firing.
- "Notify When Online" on a friend's profile.
- Text falls back to other fonts for characters the main one lacks, emoji
  included.
- Smoother thumbnails, and text is drawn faster.
- Folders and links are opened through SDL.
- Disabling yt-dlp should now last across world loads.
- No more join/leave notifications for yourself.

### Server

- Turns events matching the notification rules into notifications, kept in
  the inbox. Your own avatar and profile changes never match.
- New "status-change" event when a friend changes their status or status
  message.
- Fix a location change being dropped from the log when the same update also
  changed an avatar or profile.

### Web

- Notification rules (TOOLS > RULES), and NOTIFY WHEN ONLINE on a friend.
- Browser alerts for rule notifications while the page is open (needs HTTPS).

### API

- Protocol version 15: notification rules (`get_promotions`, `set_promotions`,
  `promotions`), and `vrcd.promoted` entries in the inbox.
- Protocol version 16: `set_promotions` takes a `request_id`.
- Protocol version 17: `status-change` event, rules take `statuses`.

## v0.4.1

### Web

- Fixed the page failing to load (`card is not defined`).

## v0.4.0

### Client

- A missing SDL3 is now reported: a message box on Windows, stderr on Linux.
- Errors are printed to the console. `--verbose` prints everything there,
  starting with where the log file is.
- Notifications tab shows how many are pending.
- Boops can be answered with a boop, optionally with an emoji (built-in or
  uploaded).
- Supports high-DPI displays.
- The "Open in VRChat" button shows an activity indicator.
- On Windows, the "Open in VRChat" button no longer blocks the UI.
- No more join/leave notifications for the people already in a room you enter
  or leave.

### Server

- Can send a boop in reply to one.

### Web

- Boops can be answered with a boop, optionally with an emoji (built-in or
  uploaded).

### API

- Protocol version 14: `notification_action` takes `boop`.

## v0.3.0

### Client

- Now uses SDL3.
- Can run its own server, so setting one up separately is optional.
- Windows zip, AppImage and Flatpak now carry the server for this.
- Save multiple server connections and switch between them.
- New PROFILE tab, and profiles can be opened for anyone, friend or not.
- Stickers and emoji are split between your uploads and the exclusive ones
  VRChat gave you.
- STUFF items can be downloaded as the original image to your Downloads folder.
- Window icon now shows up when launched from a menu or installed.
- Fix a crash when the server connection drops (Linux).

### Server

- Fix the VRChat connection dropping every two minutes while no events arrive.
- Reconnects to VRChat faster (2 seconds instead of 30).
- Friend state is refreshed every 30 minutes instead of every 2 hours, and
  after a long disconnect.
- A sign-in prompt left unanswered no longer stops the server; it asks again.
- Supports communicating over standard I/O (`--stdio`).
- Import friend history from a VRCX database (`--import-vrcx`). Only the time
  vrcd was not recording is filled in, and an import can be undone
  (`imports` command, `--undo-import`).
- Fix a crash when a client or VRChat disconnects mid-transfer (Linux).

### Web

- Stickers and emoji are split the same way as in the client.
- DOWNLOAD button on STUFF items.
- Sessions stay signed in while the page is in use, fixing pictures going
  blank after 12 hours.
- Guard against a browser disconnect crashing vrcd-web on some platforms.

### Packaging

- The client .deb recommends vrcd-server.

### API

- APIv9: `catch_up` accepts a `limit`, so new setups aren't flooded on first sync.
- APIv10: The server keeps the notification inbox, so notifications that
  arrived while no client was open still show up.
- APIv11: `get_inventory` can filter by item type and flag.
- APIv12: Events are ordered by time rather than by ID; `catch_up` takes an
  `epoch`, and clients get `events_reset` when history was rewritten.
- APIv13: Imports (`import_begin`, `import_events`, `import_end`,
  `import_abort`, `get_imports`, `import_undo`).
- `auth_cancelled`: Sent when a sign-in prompt expires unanswered, so clients
  can take it down before the server asks again.
- `get_stats` includes the database path (`db_path`).

## v0.2.0

Way too many things changed to list.

New things:
 - Web subpackage: Useful for mobile!
	- Friend list, muted/blocked management, profile viewing and editing
	- Notification inbox
	- Status setting, profile picture cropping, inventory/items/stickers hookup
	- Image proxy with shared cache fast-path, PWA support (manifest + service worker)
 - Inventory management for both client and web.
 - Show instance info in VRChat for Windows and Linux (needs pipehelper next to executable).
 - server: ddcurl upgrades (brotli/gzip support), reauth delegation, sticker upload fixes
 - server: World cache DB persistence, additional WS logging, crash fixes
 - So, so many bug fixes.

## v0.1.0

- Add DAP (Drop-A-Portal) integration.
- Add support for setting status.
- Add tracking for bio/pronoun/links changes as "profile-change" events.
- Add support for Flatpak and DEB packaging.
- Add "friend-traveling" synthetic event.
- Add "totp_secret" server config.
- Add Steam Screenshots folder button in client.
- Add backfilling for client.
- Rename "Debugging" to "Diagnostics" in client, tools section header.
- Various improvements to server and client.

## v0.0.1

Initial release.