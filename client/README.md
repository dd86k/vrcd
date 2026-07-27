# vrcd Client

VRChat event viewer, log watcher, and screenshot metadata tool. Connects to the vrcd server for live events and monitors local VRChat logs. Built with SDL2 software rendering and an immediate-mode UI.

## Usage

```
vrcd-client [options]
  -h, --host     Server host (default: 127.0.0.1)
  -p, --port     Server port (default: 9700)
  -s, --secret   Authentication token
      --since    Catch-up from event ID
  -v, --verbose  Enable trace logging
      --cli      CLI mode (stream events to stdout)
```

Settings are persisted to `~/.config/vrcd/settings.json` (Linux) or `%APPDATA%/vrcd/settings.json` (Windows).

### "Open in VRChat"

The Online tab's "Open in VRChat" button asks a *running* VRChat client to
join an instance directly, by writing a `vrchat://launch?...` URI to VRChat's
`VRChatURLLaunchPipe` named pipe (a seamless in-client transition, no invite
notification). When VRChat is not running, the game is launched into the
instance instead.

On Windows this works out of the box. On Linux the pipe only exists inside
the game's wineserver, which Steam isolates in a pressure-vessel container,
so two extra pieces are needed:

1. Set VRChat's Steam launch options to include:
   `STEAM_COMPAT_LAUNCHER_SERVICE=proton %command%`
   This makes Steam expose a launcher service for the running game that
   vrcd uses (via `steam-runtime-launch-client`) to run commands inside the
   container.
2. Place a Windows build of `vrcd-pipehelper.exe` (the `pipehelper`
   subpackage) next to the client binary, or in `~/.config/vrcd/`. It is
   executed with the container's own Proton Wine and performs the pipe
   write. The AppImage bundles the helper and installs it to
   `~/.config/vrcd/` on launch (the AppImage mount lives under `/tmp`,
   which the container cannot see). Note that this path must be visible
   inside the container, so keep it under your home directory.

If either piece is missing, or the IPC attempt fails, the client falls back
to a server-side self-invite (`POST /invite/myself/to/{location}`), which is
also available directly via the "Self-Invite" button.

## Architecture

### Threading Model

```
+--------------------+    +--------------------------------+
| Network Thread     +-+  | Main Thread                    |
+--------------------+ |  |                                |
                       +--->MessageQueue -> UI -> Renderer |
+--------------------+ |  | (mutex)      (SDL2 event loop) |
| Log Watcher Thread +-+  |                                |
+--------------------+    +--------------------------------+
```

- **Main thread** -- SDL2 event loop, UI rendering, state updates
- **Network thread** -- blocking receive from server, pushes JSON-L messages to queue, wakes main thread via SDL custom event
- **Log watcher thread** -- polls VRChat `output_log.txt` at 1-second intervals, synthesizes events into the same message queue
- **Timer** -- SDL timer fires every 1 second to refresh the UI

### Data Flow

1. Network and log watcher threads push messages to `MessageQueue`
2. Main thread drains the queue each frame and updates `AppState`
3. `AppState` drives immediate-mode UI layout via ddui
4. ddui draw commands go through the SDL2 software renderer

## Modules

### `main.d`
Entry point. Parses CLI arguments, initializes logging, and launches either GUI mode (`runGui`) or CLI mode (`cmdStream`).

### `gui.d`
Main GUI event loop. Initializes SDL2 and the window, spawns the network and log watcher threads, and runs the SDL event loop. Handles:
- SDL events (mouse, keyboard, window resize, file drops)
- Draining `MessageQueue` and dispatching to `AppState`
- Drag detection state machine with momentum scrolling
- Reconnection and settings persistence

### `ui.d`
UI layout using ddui (immediate-mode). Defines five tabs:

| Tab | Content |
|-----|---------|
| Feed | Paginated event list with type filtering and text search |
| Friends | Online friends grouped by instance |
| Notifications | Friend requests, invites; oldest first, never re-sorted |
| Tools | PNG metadata stripping (drag-and-drop) |
| Settings | Connection, font, notification preferences |

### `renderer.d`
SDL2 software rendering and font management. Provides:
- `r_draw_rect()`, `r_draw_text()`, `r_draw_icon()` -- primitives with alpha blending
- `r_set_clip_rect()`, `r_clear()`, `r_present()` -- frame management
- `initFont()` opens a primary font (Segoe UI on Windows, Liberation Sans on Linux, with per-platform fallbacks) plus a coverage chain of per-script fonts (Thai, Arabic, Hebrew, Devanagari, CJK, emoji). `r_draw_text` splits strings into runs per-codepoint via `TTF_GlyphIsProvided32` and renders each run with the first font in the chain that provides the glyph, blitted at a shared baseline.
- 128x128 monochrome icon atlas from ddui

### `state.d`
Shared state and thread-safe primitives.

- **`MessageQueue`** -- mutex-protected queue with `pushMessage()`, `pushDisconnect()`, `drain()`
- **`AppState`** -- all UI state: connection status, feed entries (capped at 500), friend/instance lists, notification entries, settings, tool state
- **`FeedEntry`**, **`FriendInfo`**, **`InstanceGroup`**, **`NotificationEntry`** -- data types

### `connection.d`
TCP client for the vrcd server using JSON-L protocol.

- `connect()` -- establish TCP connection and authenticate with token
- `catchUp(sinceId)` -- request replay of missed events
- `requestFriends()` -- request friend state snapshot
- `requestNotifications()` -- request the pending inbox (protocol v4). Sent once per connect, because the inbox cannot be rebuilt from the event stream: the VRChat WebSocket reports changes, not state, so a friend request that arrived while the client was closed has no event to replay. Catch-up may still replay old notification events into the list; the snapshot lands after them and replaces it
- `runThreaded()` -- blocking receive loop on a separate thread; pushes messages to `MessageQueue` and wakes the main thread via SDL custom event
- Protocol messages: `auth`, `auth_ok`, `event`, `caught_up`, `ping`/`pong`, `status`, `friends`, `notifications`, `error`

### `logwatcher.d`
Monitors local VRChat log files for player and location events.

- Finds the latest `output_log_*.txt` in the platform-specific VRChat log directory
- Parses `[Behaviour] OnPlayerJoined`, `OnPlayerLeft`, and `Joining wrld_...` lines
- Emits synthetic `log-event` messages (`player-joined`, `player-left`, `location-change`)

Log directories:
- **Windows:** `%LOCALAPPDATA%Low\VRChat\VRChat`
- **Linux:** `~/.steam/steam/steamapps/compatdata/438100/pfx/drive_c/users/steamuser/AppData/LocalLow/VRChat/VRChat`

### `notifications.d`
Multi-backend VR notification dispatch.

| Backend | Transport | Platform |
|---------|-----------|----------|
| XSOverlay | UDP to `127.0.0.1:42069` | Windows, Linux (WayVR) |
| OVR Toolkit | WebSocket to `127.0.0.1:11450` | Windows |
| Desktop | `notify-send` subprocess | Linux |

Configurable per-event-type filtering, volume, timeout, and opacity. Formats event data into title/body pairs for each notification type.

### `png.d`
PNG parser for metadata extraction and stripping.

- `metadata()` -- reads iTXt chunks: VRC XMP (`XML:com.adobe.xmp`) and VRCX JSON (`Description`)
- `strip()` -- writes a copy of the PNG with all iTXt chunks removed
- Implements chunk-level parsing per the W3C PNG spec

### `settings.d`
JSON-based persistent settings.

- `loadSettings()` / `saveSettings()` -- read/write from platform-specific config path
- Fields: host, port, secret, font path/size, feed page size, notification preferences

## Requirements

- **OS:** Linux (Ubuntu 24.04 or newer / equivalent) or Windows 10+
- **SDL2:** 2.0.22 or newer
- **SDL2_ttf:** 2.22 or newer (required for `TTF_GlyphIsProvided32`, used by the font fallback chain)
- **DMD**, **GDC**, or **LDC** (D compiler) and **DUB** for building

For Unicode coverage outside Latin/Greek/Cyrillic (Thai, Arabic, CJK, etc.), install the matching Noto fonts:

```bash
# Debian/Ubuntu, but they likely already have them
sudo apt install fonts-noto fonts-noto-cjk
```

## Dependencies

Except for SDL2, these dependencies are pulled by DUB when building.

| Package | Purpose |
|---------|---------|
| `bindbc-sdl` | SDL2 dynamic bindings |
| SDL2, SDL2_ttf | Windowing, software rendering, font rasterization |
| `ddui` | Immediate-mode UI library |
| `ddlogger` | Structured logging |

## Building

```bash
dub build :client
dub test :client
```

> **Note:** If you get linking issues on Windows, try with LDC: `--compiler=ldc2`
