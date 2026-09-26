# CHANGELOG

Changelog file for vrcd with newest tags first.

Rules:
- Separated by component: Client, Server, Web
- Keep things simple and easy to read, technical topics best left in source.

## v0.3.0

### Client

- Now uses SDL3.
- Can run its own server, so setting one up separately is optional.
- Save multiple server connections and switch between them.
- New PROFILE tab, and profiles can be opened for anyone, friend or not.
- Stickers and emoji are split between your uploads and the exclusive ones
  VRChat gave you.
- STUFF items can be downloaded as the original image to your Downloads folder.
- Window icon now shows up when launched from a menu or installed.
- Fix a crash when the server connection drops (Linux).

### Server

- Reconnects to VRChat faster (2 seconds instead of 30).
- Friend state is refreshed every 30 minutes instead of every 2 hours, and
  after a long disconnect.
- A sign-in prompt left unanswered no longer stops the server; it asks again.
- Supports communitating over standard I/O (`--stdio`).
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