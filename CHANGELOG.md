# CHANGELOG

## 0.3.0

### Client

- Officially upgraded from SDL2 to SDL3.
- Stickers are split into two groups: the ones you uploaded, and the exclusive
  ones VRChat handed out (inventory entries, so nothing to delete).

### Web

- Same split in the STICKERS section.

### API

- APIv9 brings a `limit` property to `catch_up` to avoid drowning new setups when synchronizing.
- APIv10 moves the notification inbox into the server: seeded from VRChat at startup and on every re-seed, kept current from the WebSocket, and `notifications` is re-broadcast to every client on change. A front-end connecting late still sees what arrived while nobody was watching.
- APIv11 lets `get_inventory` be filtered by item type and capability flag, which is how the exclusive stickers are asked for apart from the props. The reply echoes the filter, since one endpoint now feeds two of a front-end's sections.

## 0.2.0

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

## 0.1.0

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

## 0.0.1

Initial release.