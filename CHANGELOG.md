# CHANGELOG

## 0.3.0

### Client

- Officially upgraded from SDL2 to SDL3.

### API

- APIv9 brings a `limit` property to `catch_up` to avoid drowning new setups when synchronizing.

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