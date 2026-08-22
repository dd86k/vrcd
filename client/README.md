# vrcd Client

VRChat event viewer, log watcher, and screenshot metadata tool. Connects to the vrcd server for live events and monitors local VRChat logs. Built with SDL3 software rendering and an immediate-mode UI.

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

On Windows this works out of the box. On Linux the pipe lives in the game's
wineserver, which runs inside a pressure-vessel container, so the write has
to come from a Wine process attached to that same wineserver. Only one extra
piece is needed for that: place a Windows build of `vrcd-pipehelper.exe` (the
`pipehelper` subpackage) next to the client binary, or in `~/.config/vrcd/`.
The AppImage bundles the helper and installs it to `~/.config/vrcd/` on
launch.

No Steam launch options are involved. A wineserver's socket directory
(`/tmp/.wine-<uid>/server-<dev>-<inode>`) is shared with the host, so Wine
started on this side against the game's prefix attaches to the running
wineserver rather than starting its own, and finds the pipe there. The
client reads the prefix and the exact Proton build the game runs under from
`/proc/<pid>` (`environ` and `exe`), so the Proton version does not have to
be configured and cannot drift out of sync.

Earlier versions instead ran the helper inside the container through Steam's
launcher service, which needed `STEAM_COMPAT_LAUNCHER_SERVICE=proton` in the
game's launch options. That option makes Proton wrap the game's own Wine
process in `steam-runtime-launcher-service`, which breaks VRChat's video
players (they resolve URLs by spawning `yt-dlp.exe`), so it is no longer
used. If you still have it in your launch options, remove it.

If the helper is missing, or the IPC attempt fails, the client falls back to
a server-side self-invite (`POST /invite/myself/to/{location}`), which is
also available directly via the "Self-Invite" button.

## Architecture

### Threading Model

```
+--------------------+    +--------------------------------+
| Network Thread     +-+  | Main Thread                    |
+--------------------+ |  |                                |
                       +--->MessageQueue -> UI -> Renderer |
+--------------------+ |  | (mutex)      (SDL3 event loop) |
| Log Watcher Thread +-+  |                                |
+--------------------+    +--------------------------------+
```

- **Main thread** -- SDL3 event loop, UI rendering, state updates
- **Network thread** -- blocking receive from server, pushes JSON-L messages to queue, wakes main thread via SDL custom event
- **Log watcher thread** -- polls VRChat `output_log.txt` at 1-second intervals, synthesizes events into the same message queue
- **Timer** -- SDL timer fires every 1 second to refresh the UI

### Data Flow

1. Network and log watcher threads push messages to `MessageQueue`
2. Main thread drains the queue each frame and updates `AppState`
3. `AppState` drives immediate-mode UI layout via ddui
4. ddui draw commands go through the SDL3 software renderer

## Modules

### `main.d`
Entry point. Parses CLI arguments, initializes logging, and launches either GUI mode (`runGui`) or CLI mode (`cmdStream`).

### `gui.d`
Main GUI event loop. Initializes SDL3 and the window, spawns the network and log watcher threads, and runs the SDL event loop. Handles:
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
SDL3 software rendering and font management. Provides:
- `r_draw_rect()`, `r_draw_text()`, `r_draw_icon()` -- primitives with alpha blending
- `r_set_clip_rect()`, `r_clear()`, `r_present()` -- frame management
- `initFont()` opens a primary font (Segoe UI on Windows, Liberation Sans on Linux, with per-platform fallbacks) plus a coverage chain of per-script fonts (Thai, Arabic, Hebrew, Devanagari, CJK, emoji). `r_draw_text` splits strings into runs per-codepoint via `TTF_FontHasGlyph` and renders each run with the first font in the chain that provides the glyph, blitted at a shared baseline.
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

- **OS:** Linux (Ubuntu 25.04 or newer / equivalent) or Windows 10+
- **SDL3:** 3.2.0 or newer
- **SDL3_ttf:** 3.2.0 or newer
- **SDL3_image:** 3.2.0 or newer
- **DMD**, **GDC**, or **LDC** (D compiler) and **DUB** for building

For Unicode coverage outside Latin/Greek/Cyrillic (Thai, Arabic, CJK, etc.), install the matching Noto fonts:

```bash
# Debian/Ubuntu, but they likely already have them
sudo apt install fonts-noto fonts-noto-cjk
```

## Dependencies

Except for SDL3, these dependencies are pulled by DUB when building.

| Package | Purpose |
|---------|---------|
| `bindbc-sdl` | SDL3 bindings |
| SDL3, SDL3_ttf, SDL3_image | Windowing, software rendering, font rasterization, image decoding |
| `ddui` | Immediate-mode UI library |
| `ddlogger` | Structured logging |

System packages. SDL3 is only needed at link time under the `static` configuration; the default loads it at run time.

| | Always | `-c static` only |
|---|---|---|
| Ubuntu | SDL3, SDL3_ttf, SDL3_image runtime libraries (25.04+) | `libsdl3-dev`, `libsdl3-ttf-dev`, `libsdl3-image-dev` |
| Alpine | `sdl3`, `sdl3_ttf`, `sdl3_image` | `sdl3-dev`, `sdl3_ttf-dev`, `sdl3_image-dev` |

OpenSSL 3.x shared libraries (`libssl.so.3`, `libcrypto.so.3`) are loaded dynamically at run time for TLS support. They are not a build dependency under either configuration.

## Building

```bash
dub build :client              # SDL3 loaded at run time (default)
dub build :client -c static    # SDL3 linked at build time
dub test :client
```

### Configurations

| Configuration | SDL3 | Notes |
|---------------|------|-------|
| `application` (default) | loaded at run time through bindbc-loader | Nothing links against the build host's SDL3, so the binary moves between distributions and picks up system SDL3 updates |
| `static` | linked at build time | For hosts with no loadable SDL3, or when a self-contained binary is wanted. Needs the SDL3 development libraries present (`-lSDL3 -lSDL3_ttf -lSDL3_image`, `SDL3.lib` and friends on Windows) |

The versions in [Requirements](#requirements) apply either way. Under the default configuration that is a property of the libraries present at run time (checked by `loadSDL()` and friends, which report "library too old" and exit), rather than one frozen into the binary by whichever machine built it.

Which one a build used is logged at startup as `SDL3 binding: dynamic` or `SDL3 binding: static`, next to the linked library versions.

The AppImage (`packaging/package-appimage.sh`) uses `static`, which is what makes it packageable: SDL3 becomes a DT_NEEDED entry, so linuxdeploy finds and bundles it and its own dependencies. Under the default configuration the libraries are dlopen'd, so `ldd` reports nothing and every one of them has to be named by hand. The `.deb` uses the default configuration instead, since it can declare `libsdl3-0` and friends as package dependencies and let the system update them.

> **Note:** If you get linking issues on Windows, try with LDC: `--compiler=ldc2`
