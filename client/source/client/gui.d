/// GUI logic
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module client.gui;

import std.format : format;
import std.json;

import core.thread;

import bindbc.sdl;
import sdl_ttf;
import ddlogger;
import ddui;

import client.connection;
import client.logwatcher;
import client.notifications;
import client.renderer;
import client.settings;
import client.state;
import client.ui;

/// Custom SDL event type for network wake-ups.
/// __gshared: accessed by network thread (pushWakeEvent) and timer thread.
private __gshared uint networkEventType;

/// Timer callback ID.
private SDL_TimerID timerID;

/// Application state (main thread only).
AppState appState;

/// Message queue (network thread -> main thread).
/// __gshared: written by network thread, read by main thread.
private __gshared MessageQueue msgQueue;

/// Network reader thread.
private Thread netThread;

/// Local VRChat log file watcher.
private LogWatcher logWatcher;

/// Server connection.
/// __gshared: used by network thread after main thread finishes setup.
private __gshared ServerConnection conn;

/// Persisted settings (used for notification dispatch).
private Settings saved;

/// Accumulated scroll delta from mouse wheel, applied to active panel.
private int pendingScrollY;

/// --- Touch/drag scroll state ---

/// Drag detection state machine.
private enum DragState { idle, pending, dragging }
private DragState dragState = DragState.idle;

/// Mouse position when left button was pressed (for threshold check).
private int dragStartX, dragStartY;

/// Previous mouse Y during an active drag (for delta calculation).
private int dragPrevY;

/// Movement threshold (pixels) before a press becomes a drag.
private enum DRAG_THRESHOLD = 8;

/// Momentum velocity (pixels per frame, positive = scroll down).
private float momentumVY = 0.0f;

/// Friction multiplier applied each frame (0.0–1.0).
private enum MOMENTUM_FRICTION = 0.92f;

/// Stop momentum when velocity falls below this.
private enum MOMENTUM_MIN = 0.5f;

/// True for one frame after a non-drag mouseup (a real click).
bool wasClick;

int runGui(string host, ushort port, string secret, long sinceId,
    bool hostExplicit, bool portExplicit, bool secretExplicit)
{
    // Load saved settings; CLI args override.
    saved = loadSettings();
    if (hostExplicit == false)
        host = saved.host;
    if (portExplicit == false)
        port = saved.port;
    if (secretExplicit == false)
        secret = saved.secret;
    appState.settingsFontSize = saved.fontSize;
    appState.feedPageSize = saved.feedPageSize;

    // Load notification settings into appState (bool -> int).
    appState.notifyXSOverlay = cast(int) saved.notifyXSOverlay;
    appState.notifyOVRToolkit = cast(int) saved.notifyOVRToolkit;
    appState.notifyDesktop = cast(int) saved.notifyDesktop;
    appState.notifyVolume = saved.notifyVolume;
    appState.notifyTimeout = saved.notifyTimeout;
    appState.notifyOpacity = saved.notifyOpacity;
    appState.notifySound = cast(int) saved.notifySound;
    foreach (size_t i; 0 .. notifyEventLabels.length)
        appState.notifyEventFilter[i] = cast(int) saved.notifyEventFilter[i];

    // Load SDL2.
    SDLSupport sdlStatus = loadSDL();
    if (sdlStatus == SDLSupport.noLibrary)
    {
        logError("No SDL2 library found");
        return 1;
    }
    if (sdlStatus == SDLSupport.badLibrary)
    {
        logError("SDL2 library too old");
        return 1;
    }

    // Load SDL2_ttf.
    SDLTTFSupport ttfStatus = loadSDLTTF();
    if (ttfStatus == SDLTTFSupport.noLibrary)
    {
        // Debian/Ubuntu ship libSDL2_ttf-2.0.so.0 which bindbc doesn't
        // search for by default; try it explicitly.
        ttfStatus = loadSDLTTF("libSDL2_ttf-2.0.so.0");
    }
    if (ttfStatus == SDLTTFSupport.noLibrary)
    {
        logError("No SDL2_ttf library found");
        return 1;
    }
    if (ttfStatus == SDLTTFSupport.badLibrary)
    {
        logError("SDL2_ttf library too old");
        return 1;
    }

    // Init SDL.
    SDL_SetHint(SDL_HINT_FRAMEBUFFER_ACCELERATION, "0");
    SDL_SetHint(SDL_HINT_VIDEO_HIGHDPI_DISABLED, "0");
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_TIMER | SDL_INIT_EVENTS) != 0)
    {
        logError("SDL_Init failed");
        return 1;
    }

    if (TTF_Init() != 0)
    {
        logError("TTF_Init failed");
        SDL_Quit();
        return 1;
    }

    // Create window.
    window = SDL_CreateWindow("vrcd",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        window_width, window_height,
        SDL_WINDOW_RESIZABLE);
    if (window is null)
    {
        logError("SDL_CreateWindow failed");
        SDL_Quit();
        return 1;
    }
    SDL_SetWindowMinimumSize(window, 600, 400);

    // Init renderer.
    initiate_renderer();

    // Load system font.
    if (!initFont())
        logError("No system font found — text will not render");

    // Init UI context.
    mu_Context uictx;
    mu_init(&uictx);
    uictx.text_width  = &text_width;
    uictx.text_height = &text_height;

    // Register custom SDL event for network wake-ups.
    networkEventType = SDL_RegisterEvents(1);

    // Start 1-second timer for periodic status bar refresh.
    timerID = SDL_AddTimer(1000, &timerCallback, null);

    // Init message queue.
    msgQueue = new MessageQueue();

    // Populate settings buffers.
    initSettingsBuf(appState.settingsHost, host);
    initSettingsBuf(appState.settingsPort, format!"%d"(port));
    initSettingsBuf(appState.settingsSecret, secret);
    if (saved.fontPath.length > 0)
        initSettingsBuf(appState.settingsFontPath, saved.fontPath);

    // Connect to server in background.
    appState.serverStatus = "Connecting...";
    conn = new ServerConnection(host, port, secret);
    if (conn.connect())
    {
        appState.connected = true;
        appState.serverStatus = "Connected";
        conn.catchUp(sinceId);
        conn.requestFriends();

        // Spawn network reader thread.
        netThread = new Thread({
            conn.runThreaded(msgQueue, networkEventType);
        });
        netThread.isDaemon = true;
        netThread.start();
    }
    else
    {
        appState.serverStatus = "Failed to connect";
    }

    // Start log watcher for local VRChat player join/leave events.
    logWatcher = new LogWatcher(msgQueue, networkEventType);
    logWatcher.start();

    // Main event loop.
    bool running = true;
    SDL_Event e;

    while (running)
    {
        // When momentum is active, use a short timeout so we keep
        // animating.  Otherwise block until an event arrives (zero CPU).
        bool hasMomentum = (momentumVY > MOMENTUM_MIN || momentumVY < -MOMENTUM_MIN);
        bool gotEvent;
        if (hasMomentum)
            gotEvent = SDL_WaitEventTimeout(&e, 16) != 0;   // ~60 fps
        else
            gotEvent = SDL_WaitEvent(&e) != 0;

        // Clear per-frame flags.
        wasClick = false;

        // Process all pending events.
        while (gotEvent)
        {
            switch (e.type)
            {
                case SDL_QUIT:
                    running = false;
                    break;

                case SDL_WINDOWEVENT:
                    if (e.window.event == SDL_WINDOWEVENT_RESIZED)
                    {
                        window_width  = e.window.data1;
                        window_height = e.window.data2;
                    }
                    break;

                case SDL_MOUSEMOTION:
                    // Always pass motion to ddui for hover states.
                    mu_input_mousemove(&uictx, e.motion.x, e.motion.y);

                    if (dragState == DragState.pending)
                    {
                        int dx = e.motion.x - dragStartX;
                        int dy = e.motion.y - dragStartY;
                        if (dx*dx + dy*dy > DRAG_THRESHOLD * DRAG_THRESHOLD)
                        {
                            dragState = DragState.dragging;
                            dragPrevY = e.motion.y;
                            momentumVY = 0.0f;
                        }
                    }
                    else if (dragState == DragState.dragging)
                    {
                        int dy = dragPrevY - e.motion.y;
                        pendingScrollY += dy;
                        momentumVY = cast(float) dy;
                        dragPrevY = e.motion.y;
                    }
                    break;

                case SDL_MOUSEWHEEL:
                    pendingScrollY += e.wheel.y * -30;
                    momentumVY = 0.0f;
                    break;

                case SDL_TEXTINPUT:
                    mu_input_text(&uictx, e.text.text.ptr);
                    break;

                case SDL_MOUSEBUTTONDOWN:
                    if (e.button.button == SDL_BUTTON_LEFT)
                    {
                        if (filterPopupOpen)
                        {
                            // Pass directly to ddui — no drag in popup mode.
                            mu_input_mousedown(&uictx, e.button.x, e.button.y, MU_MOUSE_LEFT);
                        }
                        else
                        {
                            // Defer scroll-drag decision, but pass to ddui immediately
                            // so controls like sliders can track while held.
                            dragState = DragState.pending;
                            dragStartX = e.button.x;
                            dragStartY = e.button.y;
                            momentumVY = 0.0f;  // Stop any active momentum.
                            mu_input_mousedown(&uictx, e.button.x, e.button.y, MU_MOUSE_LEFT);
                        }
                    }
                    else
                    {
                        int b = buttonMap[e.button.button & 0xff];
                        if (b)
                            mu_input_mousedown(&uictx, e.button.x, e.button.y, b);
                    }
                    break;

                case SDL_MOUSEBUTTONUP:
                    if (e.button.button == SDL_BUTTON_LEFT)
                    {
                        if (filterPopupOpen)
                        {
                            // Pass directly to ddui — no drag in popup mode.
                            mu_input_mouseup(&uictx, e.button.x, e.button.y, MU_MOUSE_LEFT);
                        }
                        else if (dragState == DragState.pending)
                        {
                            // Was a click, not a drag — mousedown already sent.
                            mu_input_mouseup(&uictx, e.button.x, e.button.y, MU_MOUSE_LEFT);
                            wasClick = true;
                        }
                        else if (dragState == DragState.dragging)
                        {
                            // Scroll-drag ended — release ddui control.
                            mu_input_mouseup(&uictx, e.button.x, e.button.y, MU_MOUSE_LEFT);
                        }
                        dragState = DragState.idle;
                    }
                    else
                    {
                        int b = buttonMap[e.button.button & 0xff];
                        if (b)
                            mu_input_mouseup(&uictx, e.button.x, e.button.y, b);
                    }
                    break;

                case SDL_KEYDOWN:
                case SDL_KEYUP:
                    int k = keyMap[e.key.keysym.sym & 0xff];
                    if (k)
                    {
                        if (e.type == SDL_KEYDOWN)
                            mu_input_keydown(&uictx, k);
                        else
                            mu_input_keyup(&uictx, k);
                    }
                    break;

                case SDL_DROPFILE:
                    import std.string : fromStringz;
                    string path = cast(string) fromStringz(e.drop.file).idup;
                    SDL_free(e.drop.file);
                    appState.droppedFilePath = path;
                    break;

                default:
                    // Handle custom network event and timer event.
                    if (e.type == networkEventType)
                        drainNetworkMessages();
                    break;
            }
            gotEvent = SDL_PollEvent(&e) != 0;
        }

        // Apply momentum scrolling.
        if (momentumVY > MOMENTUM_MIN || momentumVY < -MOMENTUM_MIN)
        {
            if (dragState != DragState.dragging)
            {
                pendingScrollY += cast(int) momentumVY;
                momentumVY *= MOMENTUM_FRICTION;
            }
        }
        else
        {
            momentumVY = 0.0f;
        }

        // Check for disconnect.
        if (msgQueue.isDisconnected() && appState.connected)
        {
            appState.connected = false;
            appState.serverStatus = "Disconnected";
        }

        // Handle reconnect request from Settings tab.
        if (appState.reconnectRequested)
        {
            appState.reconnectRequested = false;
            doReconnect();
        }

        // Handle friends refresh request.
        if (appState.refreshFriendsRequested)
        {
            appState.refreshFriendsRequested = false;
            if (conn !is null && appState.connected)
                conn.requestFriends();
        }

        // Handle font reload request from Settings tab.
        if (appState.fontReloadRequested)
        {
            appState.fontReloadRequested = false;
            import core.stdc.string : memchr;
            const(char)[] fontPath;
            auto nul = cast(const(char)*) memchr(appState.settingsFontPath.ptr, 0, appState.settingsFontPath.length);
            if (nul !is null)
                fontPath = appState.settingsFontPath[0 .. nul - appState.settingsFontPath.ptr];
            if (!initFont(fontPath, cast(int) appState.settingsFontSize))
                logError("Failed to load font");
        }

        // Drain pending notification actions.
        if (appState.pendingActions.length > 0)
        {
            if (conn !is null && appState.connected)
            {
                foreach (ref NotificationAction act; appState.pendingActions)
                    conn.sendNotificationAction(act.notificationId, act.action);
            }
            appState.pendingActions.length = 0;
        }

        // Handle auth delegation responses.
        if (appState.authDialogSubmit)
        {
            appState.authDialogSubmit = false;
            appState.authDialogVisible = false;
            if (conn !is null)
            {
                if (appState.authDialogKind == AppState.AuthDialogKind.credentials)
                {
                    conn.sendAuthResponse(JSONValue([
                        "type": JSONValue("auth_response"),
                        "kind": JSONValue("credentials"),
                        "username": JSONValue(cast(string) fromStringz(appState.authUsername.ptr)),
                        "password": JSONValue(cast(string) fromStringz(appState.authPassword.ptr)),
                    ]));
                }
                else if (appState.authDialogKind == AppState.AuthDialogKind.twoFactor)
                {
                    conn.sendAuthResponse(JSONValue([
                        "type": JSONValue("auth_response"),
                        "kind": JSONValue("two_factor"),
                        "code": JSONValue(cast(string) fromStringz(appState.authCode.ptr)),
                    ]));
                }
            }
            // Clear sensitive buffers.
            appState.authUsername[] = '\0';
            appState.authPassword[] = '\0';
            appState.authCode[] = '\0';
        }
        if (appState.authDialogCancel)
        {
            appState.authDialogCancel = false;
            appState.authDialogVisible = false;
            if (conn !is null)
            {
                conn.sendAuthResponse(JSONValue([
                    "type": JSONValue("auth_response"),
                    "cancelled": JSONValue(true),
                ]));
            }
        }

        // Handle test notification request from Settings tab.
        if (appState.testNotifyRequested)
        {
            appState.testNotifyRequested = false;
            sendTestNotification(saved);
        }

        // Handle save-settings request from Settings tab.
        if (appState.saveSettingsRequested)
        {
            appState.saveSettingsRequested = false;
            doSaveSettings();
        }

        // Build and render UI.
        mu_begin(&uictx);
        drawFullWindow(&uictx, &appState, pendingScrollY);
        pendingScrollY = 0;
        mu_end(&uictx);

        r_clear(mu_Color(30, 30, 35, 255));
        foreach (ref mu_Command cmd; mu_command_range(&uictx))
        {
            switch (cmd.type)
            {
                case MU_COMMAND_TEXT: r_draw_text(cmd.text.str.ptr, cmd.text.pos, cmd.text.color); break;
                case MU_COMMAND_RECT: r_draw_rect(cmd.rect.rect, cmd.rect.color); break;
                case MU_COMMAND_ICON: r_draw_icon(cmd.icon.id, cmd.icon.rect, cmd.icon.color); break;
                case MU_COMMAND_CLIP: r_set_clip_rect(cmd.clip.rect); break;
                default: break;
            }
        }
        r_present();
    }

    // Cleanup: stop log watcher, timer, then close socket to unblock
    // the network thread, join it, and only then tear down SDL.
    if (logWatcher)
    {
        logWatcher.stop();
        logWatcher.join();
        logWatcher = null;
    }
    if (timerID)
        SDL_RemoveTimer(timerID);
    if (conn !is null)
        conn.close();
    if (netThread !is null)
    {
        netThread.join();
        netThread = null;
    }
    destroyFont();
    destroy_renderer();
    SDL_DestroyWindow(window);
    TTF_Quit();
    SDL_Quit();

    return 0;
}

/// Drain queued messages from the network thread and update app state.
private void drainNetworkMessages()
{
    string[] messages = msgQueue.drain();
    foreach (string line; messages)
    {
        try
        {
            JSONValue msg = parseJSON(line);
            string msgType = jsonStr(msg, "type");

            switch (msgType)
            {
                case "event":
                    long id;
                    if ("id" in msg && msg["id"].type == JSONType.integer)
                        id = msg["id"].get!long;

                    string eventType = jsonStr(msg, "event_type");
                    string receivedAt = formatTimestamp(jsonStr(msg, "received_at"));
                    string user;
                    string detail;
                    extractEventFields(eventType, msg, user, detail);

                    // Store raw content JSON for the detail view.
                    string rawContent;
                    if ("content" in msg)
                        rawContent = msg["content"].toString();

                    appState.addFeedEntry(id, prettyEventType(eventType), user, detail, receivedAt, rawContent);
                    dispatchNotification(eventType, user, detail, saved);

                    // Store actionable notifications.
                    storeNotification(eventType, msg, user, receivedAt);

                    // Detect "player joining" from friend-location events:
                    // when a friend's location is "traveling" and their
                    // travelingToLocation matches our current instance.
                    if (eventType == "friend-location" &&
                        appState.currentLocation.length > 0)
                    {
                        checkPlayerJoining(msg, user);
                    }
                    break;

                case "caught_up":
                    long lastId;
                    if ("last_id" in msg && msg["last_id"].type == JSONType.integer)
                        lastId = msg["last_id"].get!long;
                    appState.addFeedEntry(0, "system", "", "Caught up to event #" ~ lastId.to!string, "");
                    break;

                case "status":
                    if ("vrchat_connected" in msg)
                    {
                        bool vrchatUp = msg["vrchat_connected"].type == JSONType.true_;
                        string lastError = jsonStr(msg, "vrchat_last_error");
                        if (vrchatUp)
                            appState.vrchatStatus = "Connected";
                        else if (lastError.length > 0)
                            appState.vrchatStatus = "Disconnected (" ~ lastError ~ ")";
                        else
                            appState.vrchatStatus = "Disconnected";
                    }
                    break;

                case "friends":
                    applyFriendsSnapshot(msg);
                    break;

                case "error":
                    string errMsg = jsonStr(msg, "message");
                    appState.addFeedEntry(0, "error", "", "Server error: " ~ errMsg, "");
                    break;

                case "log-event":
                    string logEventType = jsonStr(msg, "event_type");
                    if (logEventType == "location-change")
                    {
                        // Update current instance from local log.
                        appState.currentLocation = jsonStr(msg, "location");
                    }
                    else
                    {
                        string logUser = jsonStr(msg, "display_name");
                        appState.addFeedEntry(0, prettyEventType(logEventType), logUser, "", "");
                        dispatchNotification(logEventType, logUser, "", saved);
                    }
                    break;

                case "notification_action_result":
                    string notifId = jsonStr(msg, "notification_id");
                    bool success = "success" in msg && msg["success"].type == JSONType.true_;
                    if (success)
                    {
                        appState.removeNotification(notifId);
                    }
                    else
                    {
                        // Re-enable buttons on failure.
                        foreach (ref NotificationEntry n; appState.notifications)
                        {
                            if (n.notificationId == notifId)
                                n.actionPending = false;
                        }
                        string errMsg = jsonStr(msg, "error");
                        appState.addFeedEntry(0, "error", "",
                            "Notification action failed: " ~ errMsg, "");
                    }
                    break;

                case "auth_request":
                    string kind = jsonStr(msg, "kind");
                    if (kind == "credentials")
                    {
                        appState.authDialogKind = AppState.AuthDialogKind.credentials;
                    }
                    else if (kind == "two_factor")
                    {
                        appState.authDialogKind = AppState.AuthDialogKind.twoFactor;
                        appState.authDialogMethod = jsonStr(msg, "method");
                    }
                    appState.authDialogError = jsonStr(msg, "error");
                    appState.authDialogVisible = true;
                    // Clear previous input.
                    appState.authUsername[] = '\0';
                    appState.authPassword[] = '\0';
                    appState.authCode[] = '\0';
                    break;

                default:
                    break;
            }
        }
        catch (Exception e)
        {
            logError("Failed to parse message: %s", e.msg);
        }
    }
}

/// Extract user and detail fields from a feed event.
/// Detail shows what's affected (world, status, group, etc.).
private void extractEventFields(string eventType, JSONValue msg, out string user, out string detail)
{
    if ("content" !in msg)
        return;

    try
    {
        JSONValue c = msg["content"];
        if (c.type == JSONType.string)
            c = parseJSON(c.str);

        user = jsonStr(c, "displayName");

        // Most events nest the user info inside a "user" sub-object.
        if (user.length == 0 && "user" in c && c["user"].type == JSONType.object)
            user = jsonStr(c["user"], "displayName");

        switch (eventType)
        {
            case "friend-online":
                string platform = jsonStr(c, "platform");
                if (platform.length > 0)
                    detail = prettyPlatform(platform);
                return;

            case "friend-active":
                string activePlatform = jsonStr(c, "platform");
                if (activePlatform.length > 0)
                    detail = prettyPlatform(activePlatform);
                return;

            case "friend-offline":
                string offlinePlatform = jsonStr(c, "platform");
                if (offlinePlatform.length > 0)
                    detail = prettyPlatform(offlinePlatform);
                return;

            case "friend-add":
            case "friend-delete":
                return;

            case "friend-update":
                string status = jsonStr(c, "statusDescription");
                if (status.length > 0)
                    detail = status;
                else
                {
                    string statusEnum = jsonStr(c, "status");
                    if (statusEnum.length > 0)
                        detail = prettyStatus(statusEnum);
                }
                return;

            case "friend-location":
            case "user-location":
                string worldName = jsonStr(c, "worldName");
                if (worldName.length == 0 && "world" in c && c["world"].type == JSONType.object)
                    worldName = jsonStr(c["world"], "name");
                if (worldName.length > 0)
                    detail = worldName;
                else
                {
                    string loc = jsonStr(c, "location");
                    if (loc == "private")
                        detail = "Private World";
                    else if (loc == "offline" || loc.length == 0)
                        detail = "Offline";
                    else
                        detail = loc;
                }
                return;

            case "user-update":
                string updatedStatus = jsonStr(c, "statusDescription");
                if (updatedStatus.length > 0)
                    detail = updatedStatus;
                return;

            case "notification":
            case "notification-v2":
                string senderName = jsonStr(c, "senderUsername");
                if (senderName.length > 0)
                    user = senderName;
                string notifType = jsonStr(c, "type");
                if (notifType.length > 0)
                    detail = prettyNotifType(notifType);
                return;

            case "notification-v2-delete":
            case "notification-v2-update":
            case "see-notification":
            case "hide-notification":
            case "response-notification":
                string nType = jsonStr(c, "type");
                if (nType.length > 0)
                    detail = prettyNotifType(nType);
                return;

            case "group-joined":
            case "group-left":
            case "group-role-updated":
            case "group-member-updated":
                string groupName = jsonStr(c, "groupName");
                if (groupName.length > 0)
                    detail = groupName;
                return;

            case "instance-queue-position":
                string position = jsonStr(c, "position");
                if (position.length > 0)
                    detail = "Position " ~ position;
                return;

            case "instance-queue-joined":
            case "instance-queue-ready":
            case "instance-queue-left":
            case "instance-closed":
                string instanceId = jsonStr(c, "instanceId");
                if (instanceId.length > 0)
                    detail = instanceId;
                return;

            case "content-refresh":
                string contentType = jsonStr(c, "contentType");
                if (contentType.length > 0)
                    detail = contentType;
                return;

            default:
                break;
        }
    }
    catch (Exception) {}
}

/// Apply a friends snapshot from the server to the app state.
private void applyFriendsSnapshot(JSONValue msg)
{
    InstanceGroup[] instances;
    FriendInfo[] offlineFriends;

    // Parse instances.
    if ("instances" in msg && msg["instances"].type == JSONType.array)
    {
        foreach (ref JSONValue grp; msg["instances"].array)
        {
            InstanceGroup ig;
            ig.instanceId = jsonStr(grp, "instance_id");
            ig.worldName = jsonStr(grp, "world_name");

            if ("friends" in grp && grp["friends"].type == JSONType.array)
            {
                foreach (ref JSONValue fVal; grp["friends"].array)
                    ig.friends ~= parseFriendInfo(fVal);
            }
            instances ~= ig;
        }
    }

    // Parse offline friends.
    if ("offline" in msg && msg["offline"].type == JSONType.array)
    {
        foreach (ref JSONValue fVal; msg["offline"].array)
        {
            offlineFriends ~= parseFriendInfo(fVal);
        }
    }

    appState.instances = instances;
    appState.offlineFriends = offlineFriends;
    appState.selectedFriend = null; // Reset selection on refresh.
}

/// Parse a FriendInfo from a JSON friend object.
private FriendInfo parseFriendInfo(JSONValue f)
{
    FriendInfo fi;
    fi.userId = jsonStr(f, "id");
    fi.displayName = jsonStr(f, "displayName");
    fi.status = jsonStr(f, "status");
    fi.statusDescription = jsonStr(f, "statusDescription");
    fi.platform = jsonStr(f, "platform");
    fi.location = jsonStr(f, "location");
    return fi;
}

/// Map VRChat platform strings to readable names.
private string prettyPlatform(string platform)
{
    switch (platform)
    {
        case "standalonewindows": return "PC";
        case "android":          return "Quest";
        case "ios":              return "iOS";
        default:                 return platform;
    }
}

/// Map VRChat status enum values to readable names.
private string prettyStatus(string status)
{
    switch (status)
    {
        case "active":       return "Online";
        case "join me":      return "Join Me";
        case "ask me":       return "Ask Me";
        case "busy":         return "Do Not Disturb";
        case "offline":      return "Offline";
        default:             return status;
    }
}

/// Map notification type strings to readable names.
private string prettyNotifType(string notifType)
{
    switch (notifType)
    {
        case "invite":              return "Invite";
        case "requestInvite":       return "Request Invite";
        case "requestInviteResponse": return "Invite Response";
        case "friendRequest":       return "Friend Request";
        case "votetokick":          return "Vote to Kick";
        default:                    return notifType;
    }
}

/// Actionable notification types that get stored in the notifications tab.
private immutable string[] actionableNotifTypes = [
    "friendRequest", "invite", "requestInvite",
];

/// Store an actionable notification or remove on delete/hide events.
private void storeNotification(string eventType, JSONValue msg, string user, string receivedAt)
{
    if ("content" !in msg)
        return;

    try
    {
        switch (eventType)
        {
            case "notification":
            case "notification-v2":
                JSONValue c = msg["content"];
                if (c.type == JSONType.string)
                    c = parseJSON(c.str);

                string notifId = jsonStr(c, "id");
                string notifType = jsonStr(c, "type");
                if (notifId.length == 0 || notifType.length == 0)
                    return;

                // Only store actionable types.
                bool actionable;
                foreach (string t; actionableNotifTypes)
                {
                    if (t == notifType)
                    {
                        actionable = true;
                        break;
                    }
                }
                if (actionable == false)
                    return;

                string sender = jsonStr(c, "senderUsername");
                if (sender.length == 0)
                    sender = user;

                // Build a message from available details.
                string notifMessage = jsonStr(c, "message");
                if (notifMessage.length == 0)
                {
                    if ("details" in c && c["details"].type == JSONType.object)
                    {
                        JSONValue details = c["details"];
                        string worldName = jsonStr(details, "worldName");
                        if (worldName.length > 0)
                            notifMessage = worldName;
                    }
                }

                appState.addNotification(notifId, notifType, sender, notifMessage, receivedAt);
                return;

            case "notification-v2-delete":
                JSONValue dc = msg["content"];
                if (dc.type == JSONType.string)
                    dc = parseJSON(dc.str);
                if ("ids" in dc && dc["ids"].type == JSONType.array)
                {
                    foreach (JSONValue idVal; dc["ids"].array)
                    {
                        if (idVal.type == JSONType.string)
                            appState.removeNotification(idVal.str);
                    }
                }
                return;

            case "hide-notification":
            case "see-notification":
                // Content is a plain string (notification ID).
                JSONValue hc = msg["content"];
                if (hc.type == JSONType.string)
                    appState.removeNotification(hc.str);
                return;

            case "response-notification":
                JSONValue rc = msg["content"];
                if (rc.type == JSONType.string)
                    rc = parseJSON(rc.str);
                string respId = jsonStr(rc, "notificationId");
                if (respId.length > 0)
                    appState.removeNotification(respId);
                return;

            default:
                return;
        }
    }
    catch (Exception e)
    {
        logError("Failed to store notification: %s", e.msg);
    }
}

/// Check if a friend-location event indicates a friend is traveling to our instance.
/// If so, synthesize a "player-joining" feed entry and notification.
private void checkPlayerJoining(JSONValue msg, string user)
{
    if ("content" !in msg)
        return;

    try
    {
        JSONValue c = msg["content"];
        if (c.type == JSONType.string)
            c = parseJSON(c.str);

        string location = jsonStr(c, "location");
        if (location != "traveling")
            return;

        string travelingTo = jsonStr(c, "travelingToLocation");
        if (travelingTo.length == 0 || travelingTo != appState.currentLocation)
            return;

        // Friend is traveling to our instance.
        appState.addFeedEntry(0, "Player Joining", user, "", "");
        dispatchNotification("player-joining", user, "", saved);
    }
    catch (Exception e)
    {
        logError("Failed to check player joining: %s", e.msg);
    }
}

/// Map raw event type strings to pretty display names.
private string prettyEventType(string eventType)
{
    switch (eventType)
    {
        case "friend-online":   return "Online";
        case "friend-offline":  return "Offline";
        case "friend-active":   return "Active";
        case "friend-add":      return "Friend Add";
        case "friend-delete":   return "Friend Remove";
        case "friend-update":   return "Friend Update";
        case "friend-location": return "Friend Location";
        case "user-update":           return "Update";
        case "user-location":         return "Location";
        case "user-badge-assigned":   return "Badge Assigned";
        case "user-badge-unassigned": return "Badge Unassigned";
        case "notification":
        case "notification-v2": return "Notification";
        case "notification-v2-delete": return "Notif Delete";
        case "notification-v2-update": return "Notif Update";
        case "see-notification":      return "Notif Seen";
        case "hide-notification":     return "Notif Hidden";
        case "response-notification": return "Notif Response";
        case "group-joined":        return "Group Joined";
        case "group-left":          return "Group Left";
        case "group-role-updated":  return "Group Role";
        case "group-member-updated": return "Group Member";
        case "instance-queue-joined":   return "Queue Joined";
        case "instance-queue-position": return "Queue Position";
        case "instance-queue-ready":    return "Queue Ready";
        case "instance-queue-left":     return "Queue Left";
        case "instance-closed":         return "Instance Closed";
        case "content-refresh": return "Content Refresh";
        case "player-joining":  return "Player Joining";
        case "player-joined":   return "Player Joined";
        case "player-left":     return "Player Left";
        case "system":          return "System";
        case "error":           return "Error";
        default:                return eventType;
    }
}

/// Format an ISO 8601 timestamp into "MM-DD HH:MM:SS" for display.
private string formatTimestamp(string isoTimestamp)
{
    import std.datetime : SysTime;

    if (isoTimestamp.length == 0)
        return "";

    try
    {
        SysTime t = SysTime.fromISOExtString(isoTimestamp).toLocalTime();
        return format!"%02d-%02d %02d:%02d:%02d"(t.month, t.day, t.hour, t.minute, t.second);
    }
    catch (Exception) {}

    // Fallback: return first 19 chars (YYYY-MM-DDTHH:MM:SS).
    if (isoTimestamp.length >= 19)
        return isoTimestamp[0 .. 19];
    return isoTimestamp;
}

private string jsonStr(JSONValue json, string key)
{
    if (key in json && json[key].type == JSONType.string)
        return json[key].str;
    return "";
}

private import std.string : fromStringz;

private import std.conv : to;

/// SDL timer callback -- pushes a user event to wake the main loop.
private extern(C) uint timerCallback(uint interval, void* param) nothrow
{
    SDL_Event ev;
    ev.type = networkEventType;
    SDL_PushEvent(&ev);
    return interval;
}

/// Text measurement callbacks for ddui (must be extern(C)).
extern(C) int text_width(mu_Font font, const(char)* text, int len)
{
    import core.stdc.string : strlen;
    if (len == -1)
        len = cast(int) strlen(text);
    return r_get_text_width(text, len);
}

extern(C) int text_height(mu_Font font)
{
    return r_get_text_height();
}

/// Tear down the current connection and establish a new one using
/// the host/port/secret from the Settings tab.
private void doReconnect()
{
    import core.stdc.string : strlen;
    import std.conv : to;

    // Close existing connection and wait for network thread.
    if (conn !is null)
        conn.close();
    if (netThread !is null)
    {
        netThread.join();
        netThread = null;
    }

    // Read settings buffers.
    string host = cast(string) appState.settingsHost[0 .. strlen(appState.settingsHost.ptr)].idup;
    string portStr = cast(string) appState.settingsPort[0 .. strlen(appState.settingsPort.ptr)].idup;
    string secret = cast(string) appState.settingsSecret[0 .. strlen(appState.settingsSecret.ptr)].idup;

    ushort port;
    try
        port = portStr.to!ushort;
    catch (Exception)
    {
        appState.serverStatus = "Invalid port";
        return;
    }

    // Reset queue state for the new connection.
    msgQueue = new MessageQueue();

    appState.serverStatus = "Connecting...";
    appState.connected = false;
    conn = new ServerConnection(host, port, secret);
    if (conn.connect())
    {
        appState.connected = true;
        appState.serverStatus = "Connected";
        conn.catchUp(0);
        conn.requestFriends();

        netThread = new Thread({
            conn.runThreaded(msgQueue, networkEventType);
        });
        netThread.isDaemon = true;
        netThread.start();
    }
    else
    {
        appState.serverStatus = "Failed to connect";
    }
}

/// Read current UI state into a Settings struct and persist to disk.
private void doSaveSettings()
{
    import core.stdc.string : strlen;

    Settings s;
    s.host = cast(string) appState.settingsHost[0 .. strlen(appState.settingsHost.ptr)].idup;
    s.port = {
        import std.conv : to;
        string p = cast(string) appState.settingsPort[0 .. strlen(appState.settingsPort.ptr)].idup;
        try return p.to!ushort;
        catch (Exception) return cast(ushort) 9700;
    }();
    s.secret = cast(string) appState.settingsSecret[0 .. strlen(appState.settingsSecret.ptr)].idup;
    s.fontPath = cast(string) appState.settingsFontPath[0 .. strlen(appState.settingsFontPath.ptr)].idup;
    s.fontSize = appState.settingsFontSize;
    s.feedPageSize = appState.feedPageSize;

    // Notification settings (int -> bool).
    s.notifyXSOverlay = appState.notifyXSOverlay != 0;
    s.notifyOVRToolkit = appState.notifyOVRToolkit != 0;
    s.notifyDesktop = appState.notifyDesktop != 0;
    s.notifyVolume = appState.notifyVolume;
    s.notifyTimeout = appState.notifyTimeout;
    s.notifyOpacity = appState.notifyOpacity;
    s.notifySound = appState.notifySound != 0;
    foreach (size_t i; 0 .. notifyEventLabels.length)
        s.notifyEventFilter[i] = appState.notifyEventFilter[i] != 0;

    saved = s; // Update module-level copy used by notification dispatch.
    saveSettings(s);
}

/// Copy a D string into a fixed-size null-terminated char buffer.
private void initSettingsBuf(char[] buf, string value)
{
    assert(buf);
    assert(buf.length);
    size_t len = value.length < buf.length ? value.length : buf.length - 1;
    buf[0 .. len] = value[0 .. len];
    buf[len] = 0;
}

/// SDL-DDUI mouse button mapping.
private immutable ubyte[256] buttonMap = () {
    ubyte[256] m;
    m[SDL_BUTTON_LEFT   & 0xff] = MU_MOUSE_LEFT;
    m[SDL_BUTTON_RIGHT  & 0xff] = MU_MOUSE_RIGHT;
    m[SDL_BUTTON_MIDDLE & 0xff] = MU_MOUSE_MIDDLE;
    return m;
}();

/// SDL-DDUI keyboard key mapping.
private immutable ubyte[256] keyMap = () {
    ubyte[256] m;
    m[SDLK_LSHIFT    & 0xff] = MU_KEY_SHIFT;
    m[SDLK_RSHIFT    & 0xff] = MU_KEY_SHIFT;
    m[SDLK_LCTRL     & 0xff] = MU_KEY_CTRL;
    m[SDLK_RCTRL     & 0xff] = MU_KEY_CTRL;
    m[SDLK_LALT      & 0xff] = MU_KEY_ALT;
    m[SDLK_RALT      & 0xff] = MU_KEY_ALT;
    m[SDLK_RETURN    & 0xff] = MU_KEY_RETURN;
    m[SDLK_KP_ENTER  & 0xff] = MU_KEY_RETURN;
    m[SDLK_BACKSPACE & 0xff] = MU_KEY_BACKSPACE;
    return m;
}();
