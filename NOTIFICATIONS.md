# Notification System Specifications

This document describes the VR notification protocols that vrcd can use to display in-headset notifications. Multiple backends are supported depending on platform and overlay software.

## WayVR (Linux)

WayVR captures notifications from two sources and renders them as VR toast overlays.

## Notification Sources

### D-Bus (Linux Desktop Notifications)

WayVR monitors the `org.freedesktop.Notifications` interface on D-Bus for `Notify` method calls. It first attempts to register as a `BecomeMonitor` client; if that fails, it falls back to `add_match` with eavesdrop.

Parsed fields from the D-Bus message:

| Field         | D-Bus type | Usage                                  |
|---------------|------------|----------------------------------------|
| `app_name`    | `string`   | Used as title if `summary` is empty    |
| `replaces_id` | `uint32`   | Ignored                                |
| `app_icon`    | `string`   | Ignored                                |
| `summary`     | `string`   | Toast title                            |
| `body`        | `string`   | Toast body                             |

D-Bus toasts use a fixed 5-second timeout, full opacity, and no sound (sound is left to the desktop environment).

### XSOverlay UDP Protocol

WayVR listens for UDP packets on `127.0.0.1:42069`, which is the standard XSOverlay notification API endpoint. Any application that sends XSOverlay-compatible JSON to this address (e.g. VRCX, OVR Toolkit, custom scripts) will work.

The receive buffer is 16 KB to accommodate base64-encoded icons.

#### JSON Message Format

| Field            | Type     | Required | Description                                  |
|------------------|----------|----------|----------------------------------------------|
| `messageType`    | `int`    | Yes      | Must be `1` for notification (others ignored) |
| `title`          | `string` | Yes      | Toast title                                  |
| `content`        | `string` | No       | Toast body (defaults to empty)               |
| `timeout`        | `float`  | No       | Display duration in seconds (default: 5)     |
| `volume`         | `float`  | No       | Sound volume; sound plays if >= 0 (default: -1, no sound) |
| `index`          | `int`    | No       | Unused                                       |
| `audioPath`      | `string` | No       | Unused                                       |
| `icon`           | `string` | No       | Unused                                       |
| `height`         | `float`  | No       | Unused                                       |
| `opacity`        | `float`  | No       | Unused                                       |
| `useBase64Icon`  | `bool`   | No       | Unused                                       |
| `sourceApp`      | `string` | No       | Unused                                       |
| `alwaysShow`     | `bool`   | No       | Unused                                       |

#### Example Payload

```json
{
  "messageType": 1,
  "title": "VRCD",
  "content": "Friend is now online",
  "timeout": 5.0,
  "volume": 0.5
}
```

## Toast Display

Both notification sources produce `Toast` objects that are rendered as VR overlay panels from `gui/toast.xml`.

### Toast Topics

Each toast has a topic that controls its display method:

| Topic                 | Default Display | Description                     |
|-----------------------|-----------------|---------------------------------|
| `System`              | `Center`        | Internal system messages        |
| `Error`               | `Center`        | Error messages                  |
| `DesktopNotification` | `Center`        | D-Bus desktop notifications     |
| `XSNotification`      | `Center`        | XSOverlay UDP notifications     |
| `IpdChange`           | (not set)       | IPD change events               |

### Display Methods

| Method   | Behavior                                                     |
|----------|--------------------------------------------------------------|
| `Center` | Follows the user's head position with interpolation          |
| `Watch`  | Attached to the left hand, aligned toward the HMD            |
| `Hide`   | Notification is silently discarded                           |

## Configuration

All notification settings live in the WayVR config file (`config.yaml`).

### Global Toggles

```yaml
# Enable or disable all notifications (default: true)
notifications_enabled: true

# Enable or disable notification sounds (default: true)
notifications_sound_enabled: true
```

When `notifications_enabled` is `false`, incoming notifications are consumed and discarded without being displayed.

### Per-Topic Display Method

The `notification_topics` map overrides the default display method for each topic:

```yaml
notification_topics:
  System: Center
  DesktopNotification: Center
  XSNotification: Center
  IpdChange: Hide
```

Valid values are `Center`, `Watch`, and `Hide`.

---

## XSOverlay (Windows, Linux)

XSOverlay is a paid SteamVR overlay application. It listens for UDP packets on `127.0.0.1:42069` (configurable in `NotificationAPIConfig.json`). Only accepts packets from localhost.

WayVR also implements this same UDP protocol (see above), so targeting the XSOverlay protocol covers both.

### Full XSOverlay JSON Message Format

| Field            | Type     | Default     | Description                                                     |
|------------------|----------|-------------|-----------------------------------------------------------------|
| `messageType`    | `int`    | —           | `1` = notification popup, `2` = media player info               |
| `title`          | `string` | `""`        | Notification title (supports Rich Text)                         |
| `content`        | `string` | `""`        | Notification body (supports Rich Text); if empty, shows compact |
| `timeout`        | `float`  | `0.5`       | Display duration in seconds                                     |
| `height`         | `float`  | `175`       | Pixel height the notification expands to (if content is set)    |
| `volume`         | `float`  | `0.7`       | Notification sound volume                                       |
| `audioPath`      | `string` | `""`        | Path to `.ogg` file, or `"default"`, `"error"`, `"warning"`    |
| `icon`           | `string` | `""`        | Base64 image data, file path, or `"default"`/`"error"`/`"warning"` |
| `useBase64Icon`  | `bool`   | `false`     | Set `true` when `icon` contains base64 data                    |
| `sourceApp`      | `string` | `""`        | Application name (for debugging)                                |
| `opacity`        | `float`  | —           | Notification opacity (0.0–1.0)                                  |
| `index`          | `int`    | `0`         | Only used for media player (messageType 2)                      |

### Height Heuristic

Height (`height`) should be set based on content length:

| Content length | Height |
|----------------|--------|
| ≤ 100 chars    | 110    |
| 101–200 chars  | 150    |
| 201–300 chars  | 200    |
| > 300 chars    | 250    |

### Example

```json
{
  "messageType": 1,
  "title": "vrcd",
  "content": "Friend is now online",
  "timeout": 5.0,
  "height": 110,
  "volume": 0.7,
  "audioPath": "default",
  "icon": "",
  "useBase64Icon": false,
  "sourceApp": "vrcd",
  "opacity": 1.0
}
```

---

## OVR Toolkit (Windows)

OVR Toolkit is a paid SteamVR overlay. It exposes a WebSocket API at `ws://127.0.0.1:11450/api`.

### Connection

- WebSocket client connecting to `ws://127.0.0.1:11450/api`
- Keep-alive interval: 5 seconds recommended
- Reconnect on error after ~30 seconds

### Message Envelope

All messages use the same wrapper:

```json
{
  "messageType": "<CommandName>",
  "json": "<JSON-encoded payload>"
}
```

### HUD Notification

Displayed in the lower part of the HMD view, moves with the head.

**messageType:** `"SendNotification"`

**Payload fields:**

| Field   | Type     | Description                          |
|---------|----------|--------------------------------------|
| `title` | `string` | Notification title                   |
| `body`  | `string` | Notification body                    |
| `icon`  | `bytes`  | PNG image as raw byte array          |

### Wrist Notification

Displayed above the virtual wristwatch until the user dismisses it.

**messageType:** `"SendWristNotification"`

**Payload fields:**

| Field  | Type     | Description                                      |
|--------|----------|--------------------------------------------------|
| `body` | `string` | Notification text (VRCX sends `"title - body"`)  |

### Example (HUD)

```json
{
  "messageType": "SendNotification",
  "json": "{\"title\":\"vrcd\",\"body\":\"Friend is now online\",\"icon\":null}"
}
```

---

## freedesktop Desktop Notifications (Linux)

Standard D-Bus notification via `org.freedesktop.Notifications.Notify`. Works with any Linux notification daemon. WayVR intercepts these and renders them in VR (see WayVR section above).

### Trivial Approach

Shell out to `notify-send`:

```
notify-send "vrcd" "Friend is now online"
```

### D-Bus Approach

Call `org.freedesktop.Notifications.Notify` on the session bus:

| Parameter        | Type       | Value                        |
|------------------|------------|------------------------------|
| `app_name`       | `string`   | `"vrcd"`                     |
| `replaces_id`    | `uint32`   | `0`                          |
| `app_icon`       | `string`   | `""` (or path to icon)       |
| `summary`        | `string`   | Notification title           |
| `body`           | `string`   | Notification body            |
| `actions`        | `string[]` | `[]`                         |
| `hints`          | `dict`     | `{}`                         |
| `expire_timeout` | `int32`    | Timeout in ms (`-1` = default, `0` = never) |

---

## Platform Summary

| Backend              | Platform      | Protocol       | Complexity | Overlay Software Required      |
|----------------------|---------------|----------------|------------|--------------------------------|
| XSOverlay UDP        | Windows/Linux | UDP JSON       | Low        | XSOverlay or WayVR             |
| OVR Toolkit          | Windows       | WebSocket JSON | Low-Medium | OVR Toolkit                    |
| freedesktop D-Bus    | Linux         | D-Bus          | Low        | WayVR (for VR); any daemon otherwise |

Since XSOverlay UDP is the simplest protocol and is supported by both XSOverlay (Windows/Linux) and WayVR (Linux), it should be the primary notification backend.
