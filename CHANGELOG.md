# CHANGELOG

## v0.3.0

### Client

- Officially upgraded from SDL2 to SDL3.
- Stickers and emoji are each split into two groups: the ones you uploaded, and
  the exclusive ones VRChat handed out (inventory entries, so nothing to
  delete).
- STUFF detail pages have a "Download Image" button: the original file (not the
  thumbnail) is written to your Downloads folder, named after the entry.
- Fix the client dying on SIGPIPE (POSIX) when the server connection drops:
  OpenSSL writes from inside SSL_read, so a disconnect killed the process from
  the network thread instead of reconnecting.

### Server

- Ping the VRChat WebSocket after a minute of silence. The connection was being
  dropped after exactly two minutes without a byte in either direction, so a
  quiet friends list meant reconnecting every 2.5 minutes all day.
- Ignore SIGPIPE (POSIX): a front-end hanging up mid-response, or a dropped
  VRChat connection, could kill the daemon from inside an OpenSSL or libcurl
  write.

### Web

- Same split in the STICKERS and EMOJI sections.
- Ignore SIGPIPE (POSIX) as well, so a browser disconnecting can never take the
  front-end down on a platform whose sends lack MSG_NOSIGNAL.
- DOWNLOAD button on every STUFF entry with artwork, saving the original file
  without going through the viewer first.

### API

- APIv9 brings a `limit` property to `catch_up` to avoid drowning new setups when synchronizing.
- APIv10 moves the notification inbox into the server: seeded from VRChat at startup and on every re-seed, kept current from the WebSocket, and `notifications` is re-broadcast to every client on change. A front-end connecting late still sees what arrived while nobody was watching.
- APIv11 lets `get_inventory` be filtered by item type and capability flag, which is how the exclusive stickers and emoji are asked for apart from the props. The reply echoes the filter, since one endpoint now feeds three of a front-end's listings.

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