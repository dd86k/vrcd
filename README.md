# vrcd

![Main feed with details](res/main1.png)

A little companion suite for VRChat, written in D.

Features:
- VR friendly UI
- Server-client architecture to avoid having multiple connections to VRC APIs
- Relatively light client using software rendering
- Relatively simple API with "catch up" request (that's for my FOMO!)
- Embed world and player metadata into VRChat screenshots
- VR overlay notifications (XSOverlay, OVR Toolkit) and desktop

Status: I'd say I'm half-way there for an initial release.

Get ready to frequently pull, upgrade dependencies, and build otherwise!

```text
+ ~ ~ ~ ~ ~ ~ ~ ~+
| VRChat servers |
+~ ~ ~ ~ ~ ~ ~ ~ +
        ^
HTTP requests/WS events
        v
+----------------+              +-----------------+
| vrcd-server    | <- JSON-L -> | vrcd-client     |
| - VRC API sync |              | - Picture meta  |
| - State        |              | - Notifications |
+----------------+              +-----------------+
```

- **[Server](server/)** -- Stays connected to VRChat's WebSocket 24/7, records events to SQLite, and serves them over TCP.
- **[Client](client/)** -- Connects to the server, watches local VRChat logs, and injects metadata into screenshots.

Targets Windows and Linux.

Related projects:
- [vrcd-server-container](https://github.com/ArcaneDisgea/vrcd-server-container) by ArcaneDisgea.

## Quick Start

See each component's README for dependencies, configuration, and architecture details.

In short, client needs SDL2 dynamic libraries. Server needs libcurl and sqlite static libraries.

```bash
# Build server and client
dub build :server
dub build :client

# Unit tests
dub test :server
dub test :client
```

See [API.md](./API.md) for server-client API details.
