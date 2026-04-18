/// GUI logic, including loop
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module client.gui;

import std.algorithm.sorting : sort;
import std.conv : to;
import std.format : format;
import std.json;
import std.string : fromStringz;

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

/// False until the server has finished streaming backlogged events. Used
/// to silence dispatchNotification for catch-up traffic so the user does
/// not get flooded with toasts for events that happened while they were
/// away. Local log events are unaffected.
private bool catchUpComplete;

/// Accumulated scroll delta from mouse wheel, applied to active panel.
private int pendingScrollY;

//
// Touch/drag scroll state
//

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

/// Request a repaint on the next iteration.  Call from ui.d when navigation
/// changes state that was already committed this frame (e.g. clicking Back).
void requestRepaint()
{
    wakeRequested = true;
}
private bool wakeRequested;

int runGui(string host, ushort port, string secret, long sinceId,
    bool hostExplicit, bool portExplicit, bool secretExplicit, bool sinceExplicit,
    bool hardwareAccel)
{
    // Load saved settings; CLI args override.
    saved = loadSettings();
    if (hostExplicit == false)
        host = saved.host;
    if (portExplicit == false)
        port = saved.port;
    if (secretExplicit == false)
        secret = saved.secret;
    // Resume catch-up from persisted cursor unless --since was explicit.
    if (sinceExplicit == false)
        sinceId = saved.lastEventId;
    appState.settingsFontSize = saved.fontSize;
    appState.feedPageSize = saved.feedPageSize;

    // Load notification settings into appState (bool -> int).
    appState.notifyMute = cast(int) saved.notifyMute;
    appState.notifyXSOverlay = cast(int) saved.notifyXSOverlay;
    appState.notifyOVRToolkit = cast(int) saved.notifyOVRToolkit;
    appState.notifyDesktop = cast(int) saved.notifyDesktop;
    appState.notifyVolume = saved.notifyVolume;
    appState.notifyTimeout = saved.notifyTimeout;
    appState.notifyOpacity = saved.notifyOpacity;
    appState.notifySound = cast(int) saved.notifySound;
    foreach (size_t i; 0 .. notifyEventLabels.length)
        appState.notifyEventFilter[i] = cast(int) saved.notifyEventFilter[i];

    // Load feed filter settings into appState (bool -> int).
    foreach (size_t i; 0 .. feedEventLabels.length)
        appState.feedEventVisible[i] = cast(int) saved.feedEventVisible[i];
    appState.feedHideSelfEvents = cast(int) saved.feedHideSelfEvents;

    // Load picture metadata setting into appState (bool -> int).
    appState.insertPictureMetadata = cast(int) saved.insertPictureMetadata;

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
    
    // Load SDL2_image
    SDLImageSupport imgStatus = loadSDLImage(); // includes libSDL2_image-2.0.so.0
    if (imgStatus == SDLImageSupport.noLibrary)
    {
        logError("No SDL2_image library found");
        return 1;
    }
    if (imgStatus == SDLImageSupport.badLibrary)
    {
        logError("SDL2_image library too old");
        return 1;
    }

    // NOTE: SDL_HINT_FRAMEBUFFER_ACCELERATION is not set because we use
    //       SDL_CreateRenderer + owned surface instead of SDL_GetWindowSurface
    //       (which is unsupported on Wayland / sdl2-compat).
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
    initiate_renderer(hardwareAccel);

    // Load system font.
    if (initFont() == false)
    {
        logError("No system font found, text will not render");
        version (Windows)
            static immutable string msg =
                "No usable system font.\n" ~
                "Check C:\\Windows\\Fonts for Segoe UI.";
        else
            static immutable string msg =
                "No usable system font.\n" ~
                "Install a TTF font (e.g. fonts-liberation).";
        SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "vrcd: No font found", msg.ptr, window);
        return 2;
    }
    
    // Load icon
    SDL_Surface *icon = IMG_Load("res/vrcd-logo.png");
    if (icon)
    {
        SDL_SetWindowIcon(window, icon);
        SDL_FreeSurface(icon); // SDL2/SDL3 keeps its own copy
    }

    // Init UI context (heap-allocated since mu_Context is ~4 MB, far too
    // large for the stack and triggers __chkstk failures on Windows).
    mu_Context* uictx = new mu_Context();
    mu_init(uictx);
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

    // Run main event loop and clean up.
    eventLoop(uictx);
    guiCleanup();

    return 0;
}

/// Main event loop, split out to keep stack frames small (avoids
/// __chkstk failures on Windows when a single function is too large).
private void eventLoop(mu_Context* uictx)
{
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
                    mu_input_mousemove(uictx, e.motion.x, e.motion.y);

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
                    mu_input_text(uictx, e.text.text.ptr);
                    break;

                case SDL_MOUSEBUTTONDOWN:
                    if (e.button.button == SDL_BUTTON_LEFT)
                    {
                        if (filterPopupOpen)
                        {
                            // Pass directly to ddui,  no drag in popup mode.
                            mu_input_mousedown(uictx, e.button.x, e.button.y, MU_MOUSE_LEFT);
                        }
                        else
                        {
                            // Defer scroll-drag decision, but pass to ddui immediately
                            // so controls like sliders can track while held.
                            dragState = DragState.pending;
                            dragStartX = e.button.x;
                            dragStartY = e.button.y;
                            momentumVY = 0.0f;  // Stop any active momentum.
                            mu_input_mousedown(uictx, e.button.x, e.button.y, MU_MOUSE_LEFT);
                        }
                    }
                    else
                    {
                        int b = buttonMap[e.button.button & 0xff];
                        if (b)
                            mu_input_mousedown(uictx, e.button.x, e.button.y, b);
                    }
                    break;

                case SDL_MOUSEBUTTONUP:
                    if (e.button.button == SDL_BUTTON_LEFT)
                    {
                        if (filterPopupOpen)
                        {
                            // Pass directly to ddui,  no drag in popup mode.
                            mu_input_mouseup(uictx, e.button.x, e.button.y, MU_MOUSE_LEFT);
                        }
                        else if (dragState == DragState.pending)
                        {
                            // Was a click, not a drag,  mousedown already sent.
                            mu_input_mouseup(uictx, e.button.x, e.button.y, MU_MOUSE_LEFT);
                            wasClick = true;
                        }
                        else if (dragState == DragState.dragging)
                        {
                            // Scroll-drag ended,  release ddui control.
                            mu_input_mouseup(uictx, e.button.x, e.button.y, MU_MOUSE_LEFT);
                        }
                        dragState = DragState.idle;
                    }
                    else
                    {
                        int b = buttonMap[e.button.button & 0xff];
                        if (b)
                            mu_input_mouseup(uictx, e.button.x, e.button.y, b);
                    }
                    break;

                case SDL_KEYDOWN:
                case SDL_KEYUP:
                    // Ctrl+V paste
                    if (e.type == SDL_KEYDOWN &&
                        (e.key.keysym.mod & KMOD_CTRL) &&
                        e.key.keysym.sym == SDLK_v)
                    {
                        char* clip = SDL_GetClipboardText();
                        if (clip)
                        {
                            mu_input_text(uictx, clip);
                            SDL_free(clip);
                        }
                        break;
                    }
                    int k = keyMap[e.key.keysym.sym & 0xff];
                    if (k)
                    {
                        if (e.type == SDL_KEYDOWN)
                            mu_input_keydown(uictx, k);
                        else
                            mu_input_keyup(uictx, k);
                    }
                    break;

                case SDL_DROPFILE:
                    string path = cast(string) fromStringz(e.drop.file).idup;
                    SDL_free(e.drop.file);
                    // Append to queue, skipping duplicates.
                    bool dup;
                    foreach (string p; appState.droppedFiles)
                    {
                        if (p == path) { dup = true; break; }
                    }
                    if (dup == false)
                        appState.droppedFiles ~= path;
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
            if (conn && appState.connected)
                conn.requestFriends();
        }

        // Handle "Fetch older" request from the Feed tab.
        if (appState.fetchOlderRequested)
        {
            appState.fetchOlderRequested = false;
            if (conn && appState.connected && appState.fetchingOlder == false)
            {
                // Cursor: smallest id currently in feed, or lastEventId+1
                // if the feed hasn't loaded any server events yet.
                long beforeId = appState.oldestLoadedEventId == long.max
                    ? saved.lastEventId + 1
                    : appState.oldestLoadedEventId;
                if (beforeId > 0)
                {
                    appState.fetchingOlder = true;
                    appState.noOlderEvents = false;
                    conn.fetchOlder(beforeId, 100);
                }
            }
        }

        // Handle font reload request from Settings tab.
        if (appState.fontReloadRequested)
        {
            appState.fontReloadRequested = false;
            import core.stdc.string : memchr;
            const(char)[] fontPath;
            const(char)* nul = cast(const(char)*) memchr(appState.settingsFontPath.ptr, 0, appState.settingsFontPath.length);
            if (nul)
                fontPath = appState.settingsFontPath[0 .. nul - appState.settingsFontPath.ptr];
            if (initFont(fontPath, cast(int) appState.settingsFontSize) == false)
                logError("Failed to load font");
        }

        // Drain pending notification actions.
        if (appState.pendingActions.length > 0)
        {
            if (conn && appState.connected)
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
            if (conn)
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
            if (conn)
            {
                conn.sendAuthResponse(JSONValue([
                    "type": JSONValue("auth_response"),
                    "cancelled": JSONValue(true),
                ]));
            }
        }

        // Sync notification settings from UI state so toggles take
        // effect immediately without requiring a manual save.
        syncNotifySettings();

        // Sync picture metadata toggle to logWatcher immediately.
        if (logWatcher)
            logWatcher.writeMetadata = appState.insertPictureMetadata != 0;

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

        // Build UI
        mu_begin(uictx);
        drawFullWindow(uictx, &appState, pendingScrollY);
        pendingScrollY = 0;
        mu_end(uictx);

        // Push a wake event when the UI mutated state that won't be visible
        // until the next frame.  Three sources:
        //   wasClick:       tab switches and other mu_button changes (activeTab
        //                   is set at the bottom of drawFullWindow, after the
        //                   content area was already rendered with the old tab)
        //   wakeRequested:  clickButton-based navigation (Back buttons) that
        //                   consumes wasClick before we can see it here
        //   pendingActions: optimistic notification dismiss
        if (wasClick || wakeRequested || appState.pendingActions.length > 0)
        {
            SDL_Event wakeEv;
            wakeEv.type = networkEventType;
            SDL_PushEvent(&wakeEv);
        }
        wakeRequested = false;

        // Render UI
        r_clear(mu_Color(30, 30, 35, 255));
        foreach (ref mu_Command cmd; mu_command_range(uictx))
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
}

/// Tear down resources in correct order: log watcher, timer, network, SDL.
private void guiCleanup()
{
    if (logWatcher)
    {
        logWatcher.stop();
        logWatcher.join();
        logWatcher = null;
    }
    if (timerID)
        SDL_RemoveTimer(timerID);
    if (conn)
        conn.close();
    if (netThread)
    {
        netThread.join();
        netThread = null;
    }
    // Persist the event cursor so the next run resumes instead of
    // replaying everything from id 0.
    saveSettings(saved);
    destroyFont();
    destroy_renderer();
    SDL_DestroyWindow(window);
    TTF_Quit();
    SDL_Quit();
}

/// Drain queued messages from the network thread and update app state.
private void drainNetworkMessages()
{
    string[] messages = msgQueue.drain();
    if (messages.length > 0)
        logTrace("drainNetworkMessages: %d messages", messages.length);
    foreach (string line; messages)
    {
        try
        {
            JSONValue msg = parseJSON(line);
            string msgType;
            if (const(JSONValue)* v = "type" in msg)
                msgType = v.str;

            logTrace("drainNetworkMessages: type=%s", msgType);

            switch (msgType) {
            case "event":
                long id;
                if (const(JSONValue) *jid = "id" in msg)
                    id = jid.integer;

                if (id > saved.lastEventId)
                    saved.lastEventId = id;

                string eventType;
                if (const(JSONValue)* v = "event_type" in msg)
                    eventType = v.str;
                string rawReceivedAt;
                if (const(JSONValue)* v = "received_at" in msg)
                    rawReceivedAt = v.str;
                string receivedAt = formatTimestamp(rawReceivedAt);
                string user;
                string detail;
                extractEventFields(eventType, msg, user, detail);

                // Store raw content JSON for the detail view.
                string rawContent;
                bool isSelfEvent = isSelfEventType(eventType);
                if (const(JSONValue) *content = "content" in msg)
                {
                    rawContent = content.toString(); // full json
                    // avatar-change carries isSelf in its content.
                    if (eventType == "avatar-change" && content.type == JSONType.object)
                        if (const(JSONValue)* v = "isSelf" in *content)
                            if (v.type == JSONType.true_)
                                isSelfEvent = true;
                }

                appState.addFeedEntry(id, prettyEventType(eventType), user, detail, receivedAt, rawContent, isSelfEvent, EventSource.server);
                if (catchUpComplete)
                    dispatchNotification(eventType, user, detail, saved);

                // Store actionable notifications.
                storeNotification(eventType, msg, user, receivedAt);

                // Detect "player joining" from friend-location events:
                // when a friend's location is "traveling" and their
                // travelingToLocation matches our current instance.
                // Gated on catch-up so replayed history doesn't toast.
                if (catchUpComplete &&
                    eventType == "friend-location" &&
                    appState.currentLocation.length > 0)
                {
                    checkPlayerJoining(msg, user);
                }
                break;

            case "caught_up":
                long lastId;
                if (const(JSONValue) *last_id = "last_id" in msg)
                    lastId = last_id.integer;
                if (lastId > saved.lastEventId)
                    saved.lastEventId = lastId;
                saveSettings(saved);
                appState.addFeedEntry(0, "system", "", "Caught up to event #" ~ lastId.to!string, timeNow(), "", false, EventSource.system);
                catchUpComplete = true;
                break;

            case "event_older":
                // Back-filled event from a fetch_older request. Append to
                // the tail of the feed (oldest position). Do NOT touch
                // saved.lastEventId — that's the high-water mark for live
                // catch-up, not the oldest.
                long id;
                if (const(JSONValue) *jid = "id" in msg)
                    id = jid.integer;

                string eventType;
                if (const(JSONValue)* v = "event_type" in msg)
                    eventType = v.str;
                string rawReceivedAt;
                if (const(JSONValue)* v = "received_at" in msg)
                    rawReceivedAt = v.str;
                string receivedAt = formatTimestamp(rawReceivedAt);
                string user;
                string detail;
                extractEventFields(eventType, msg, user, detail);

                string rawContent;
                bool isSelfEvent = isSelfEventType(eventType);
                if (const(JSONValue) *content = "content" in msg)
                {
                    rawContent = content.toString();
                    if (eventType == "avatar-change" && content.type == JSONType.object)
                        if (const(JSONValue)* v = "isSelf" in *content)
                            if (v.type == JSONType.true_)
                                isSelfEvent = true;
                }

                appState.appendOldFeedEntry(id, prettyEventType(eventType),
                    user, detail, receivedAt, rawContent, isSelfEvent, EventSource.server);
                break;

            case "older_fetched":
                long count;
                if (const(JSONValue) *c = "count" in msg)
                    count = c.integer;
                long beforeId;
                if (const(JSONValue) *b = "before_id" in msg)
                    beforeId = b.integer;
                appState.fetchingOlder = false;
                if (count == 0)
                {
                    appState.noOlderEvents = true;
                    appState.addFeedEntry(0, "system", "",
                        "No events older than #" ~ beforeId.to!string, timeNow(), "", false, EventSource.system);
                }
                else
                {
                    appState.noOlderEvents = false;
                }
                break;

            case "status":
                if (const(JSONValue) *vrchat_connected = "vrchat_connected" in msg)
                {
                    bool vrchatUp = vrchat_connected.boolean;
                    string lastError;
                if (const(JSONValue)* v = "vrchat_last_error" in msg)
                    lastError = v.str;
                    if (vrchatUp)
                        appState.vrchatStatus = "Connected";
                    else if (lastError.length > 0)
                        appState.vrchatStatus = "Disconnected (" ~ lastError ~ ")";
                    else
                        appState.vrchatStatus = "Disconnected";
                }
                if (const(JSONValue) *ratelimit_remaining = "ratelimit_remaining" in msg)
                    appState.rateLimitRemaining = ratelimit_remaining.integer;
                if (const(JSONValue) *ratelimit_max = "ratelimit_max" in msg)
                    appState.rateLimitMax = ratelimit_max.integer;
                
                if (const(JSONValue) *rate_limited = "rate_limited" in msg)
                    appState.rateLimited = rate_limited.boolean;
                break;

            case "friends":
                applyFriendsSnapshot(msg);
                break;

            case "error":
                string errMsg;
                if (const(JSONValue)* v = "message" in msg)
                    errMsg = v.str;
                appState.addFeedEntry(0, "error", "", "Server error: " ~ errMsg, timeNow(), "", false, EventSource.system);
                break;

            case "log-event":
                string logEventType;
                if (const(JSONValue)* v = "event_type" in msg)
                    logEventType = v.str;
                logDebugging("log-event received: %s", logEventType);
                switch (logEventType) {
                case "location-change":
                    // Update current instance from local log.
                    if (const(JSONValue)* v = "location" in msg)
                        appState.currentLocation = v.str;
                    break;
                case "photo-taken":
                    string photoPath;
                    if (const(JSONValue)* v = "path" in msg)
                        photoPath = v.str;
                    dispatchNotification(logEventType, "", photoPath, saved);
                    break;
                case "url-video", "url-string", "url-image":
                    string url;
                    string urlUser;
                    if (const(JSONValue)* v = "url" in msg)
                        url = v.str;
                    if (const(JSONValue)* v = "display_name" in msg)
                        urlUser = v.str;
                    appState.addFeedEntry(0, prettyEventType(logEventType), urlUser, url, timeNow(), "", false, EventSource.local);
                    break;
                default:
                    string logUser;
                    if (const(JSONValue)* v = "display_name" in msg)
                        logUser = v.str;
                    bool logIsSelf = "is_self" in msg && msg["is_self"].type == JSONType.true_;
                    appState.addFeedEntry(0, prettyEventType(logEventType), logUser, "", timeNow(), "", logIsSelf, EventSource.local);
                    dispatchNotification(logEventType, logUser, "", saved);
                }
                break;

            case "notification_action_result":
                string notifId;
                if (const(JSONValue)* v = "notification_id" in msg)
                    notifId = v.str;
                string resultAction;
                if (const(JSONValue)* v = "action" in msg)
                    resultAction = v.str;
                bool success = "success" in msg && msg["success"].type == JSONType.true_;
                if (success)
                {
                    appState.removeNotification(notifId);
                }
                else
                {
                    // Check whether the notification is still in state.
                    // For fire-and-forget "hide", it was already removed
                    // optimistically,  suppress the error to avoid noise.
                    bool stillPresent;
                    foreach (ref NotificationEntry n; appState.notifications)
                    {
                        if (n.notificationId == notifId)
                        {
                            n.actionPending = false;
                            stillPresent = true;
                        }
                    }
                    if (stillPresent)
                    {
                        string errMsg;
                        if (const(JSONValue)* v = "error" in msg)
                            errMsg = v.str;
                        appState.addFeedEntry(0, "error", "",
                            "Notification action failed: " ~ errMsg, timeNow(), "", false, EventSource.system);
                    }
                    else if (resultAction == "hide")
                    {
                        logDebugging("notification_action_result: hide for already-removed id=%s, suppressing", notifId);
                    }
                }
                break;

            case "auth_request":
                string kind;
                if (const(JSONValue)* v = "kind" in msg)
                    kind = v.str;
                logDebugging("auth_request: kind=%s", kind);
                if (kind == "credentials")
                {
                    appState.authDialogKind = AppState.AuthDialogKind.credentials;
                }
                else if (kind == "two_factor")
                {
                    appState.authDialogKind = AppState.AuthDialogKind.twoFactor;
                    if (const(JSONValue)* v = "method" in msg)
                        appState.authDialogMethod = v.str;
                }
                if (const(JSONValue)* v = "error" in msg)
                    appState.authDialogError = v.str;
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

        if (const(JSONValue)* v = "displayName" in c)
            user = v.str;

        // Most events nest the user info inside a "user" sub-object.
        if (user.length == 0)
            if (const(JSONValue)* v = "user" in c)
                if (v.type == JSONType.object)
                    if (const(JSONValue)* dn = "displayName" in *v)
                        user = dn.str;
        
        switch (eventType)
        {
            case "friend-online":
                if (const(JSONValue)* v = "platform" in c)
                    if (v.str.length > 0)
                        detail = prettyPlatform(v.str);
                return;

            case "friend-active":
                if (const(JSONValue)* v = "platform" in c)
                    if (v.str.length > 0)
                        detail = prettyPlatform(v.str);
                return;

            case "friend-offline":
                if (const(JSONValue)* v = "platform" in c)
                    if (v.str.length > 0)
                        detail = prettyPlatform(v.str);
                return;

            case "friend-add":
            case "friend-delete":
                return;

            case "friend-update":
                // Status fields are nested inside the "user" sub-object.
                if (const(JSONValue)* userObj = "user" in c)
                if (userObj.type == JSONType.object)
                {
                    if (const(JSONValue)* v = "status" in *userObj)
                        if (v.str.length > 0)
                            detail = prettyStatus(v.str);
                }
                return;

            case "friend-location":
            case "user-location":
                string worldName;
                if (const(JSONValue)* v = "worldName" in c)
                    worldName = v.str;
                if (worldName.length == 0)
                    if (const(JSONValue)* v = "world" in c)
                        if (v.type == JSONType.object)
                            if (const(JSONValue)* wn = "name" in *v)
                                worldName = wn.str;
                if (worldName.length > 0)
                    detail = worldName;
                else
                {
                    string loc;
                    if (const(JSONValue)* v = "location" in c)
                        loc = v.str;
                    if (loc == "private")
                        detail = "Private World";
                    else if (loc == "offline" || loc.length == 0)
                        detail = "Offline";
                    else
                        detail = loc;
                }
                return;

            case "user-update":
                if (const(JSONValue)* v = "statusDescription" in c)
                    if (v.str.length > 0)
                        detail = v.str;
                return;

            case "notification":
            case "notification-v2":
                if (const(JSONValue)* v = "senderUsername" in c)
                    if (v.str.length > 0)
                        user = v.str;
                if (const(JSONValue)* v = "type" in c)
                    if (v.str.length > 0)
                        detail = prettyNotifType(v.str);
                return;

            case "notification-v2-delete":
            case "notification-v2-update":
            case "see-notification":
            case "hide-notification":
            case "response-notification":
                if (const(JSONValue)* v = "type" in c)
                    if (v.str.length > 0)
                        detail = prettyNotifType(v.str);
                return;

            case "group-joined":
            case "group-left":
            case "group-role-updated":
            case "group-member-updated":
                if (const(JSONValue)* v = "groupName" in c)
                    if (v.str.length > 0)
                        detail = v.str;
                return;

            case "instance-queue-position":
                if (const(JSONValue)* v = "position" in c)
                    if (v.str.length > 0)
                        detail = "Position " ~ v.str;
                return;

            case "instance-queue-joined":
            case "instance-queue-ready":
            case "instance-queue-left":
            case "instance-closed":
                if (const(JSONValue)* v = "instanceId" in c)
                    if (v.str.length > 0)
                        detail = v.str;
                return;

            case "avatar-change":
                // user already extracted from content.displayName above.
                // Avatar IDs/URLs are opaque; name lookup isn't available.
                return;

            case "content-refresh":
                if (const(JSONValue)* v = "contentType" in c)
                    if (v.str.length > 0)
                        detail = v.str;
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
    FriendInfo[] privateGroup; // in VRChat but private/traveling
    FriendInfo[] activeElsewhere; // online on web (or other platform), not in VRChat
    FriendInfo[] offlineFriends;

    // Parse instances.
    if ("instances" in msg && msg["instances"].type == JSONType.array)
    {
        foreach (ref JSONValue grp; msg["instances"].array)
        {
            InstanceGroup ig;
            if (const(JSONValue)* v = "instance_id" in grp)
                ig.instanceId = v.str;
            if (const(JSONValue)* v = "world_name" in grp)
                ig.worldName = v.str;
            if (const(JSONValue)* v = "n_users" in grp)
                if (v.type == JSONType.integer || v.type == JSONType.uinteger)
                    ig.nUsers = v.integer;
            if (const(JSONValue)* v = "capacity" in grp)
                if (v.type == JSONType.integer || v.type == JSONType.uinteger)
                    ig.capacity = v.integer;

            if ("friends" in grp && grp["friends"].type == JSONType.array)
            {
                foreach (ref JSONValue fVal; grp["friends"].array)
                    ig.friends ~= parseFriendInfo(fVal);
            }
            sort!friendLess(ig.friends);

            // "private" and "traveling" are not joinable world instances.
            // Split by platform: web-only friends go to "Active elsewhere";
            // game-platform friends go to the "Private" section.
            if (ig.instanceId == "private" || ig.instanceId == "traveling")
            {
                foreach (ref FriendInfo f; ig.friends)
                {
                    if (f.platform == "web")
                        activeElsewhere ~= f;
                    else
                        privateGroup ~= f;
                }
            }
            else
                instances ~= ig;
        }
    }

    if (privateGroup.length > 0)
    {
        sort!friendLess(privateGroup);
        InstanceGroup pg;
        pg.instanceId = "private";
        pg.friends = privateGroup;
        instances ~= pg;
    }
    sort!friendLess(activeElsewhere);

    // Parse offline friends. Web-platform friends with a non-offline status
    // are active on the website but may have an empty location in the API
    // seed, causing the server to bucket them as offline. Re-route them to
    // "Active elsewhere" so they appear in the correct section.
    if ("offline" in msg && msg["offline"].type == JSONType.array)
    {
        foreach (ref JSONValue fVal; msg["offline"].array)
        {
            FriendInfo fi = parseFriendInfo(fVal);
            if (fi.platform == "web" && fi.status != "offline")
                activeElsewhere ~= fi;
            else
                offlineFriends ~= fi;
        }
    }
    sort!friendLess(activeElsewhere);
    sort!friendLess(offlineFriends);

    appState.instances = instances;
    appState.activeElsewhereFriends = activeElsewhere;
    appState.offlineFriends = offlineFriends;
    appState.selectedFriend = null; // Reset selection on refresh.
}

// Friend comparison function
private bool friendLess(ref const FriendInfo a, ref const FriendInfo b)
{
    // First, try ranking by status if those differ
    int ra = statusRank(a.status);
    int rb = statusRank(b.status);
    if (ra != rb)
        return ra < rb;
    // Then, rank by name if their status rank is the same
    import std.uni : icmp;
    return icmp(a.displayName, b.displayName) < 0;
}

/// Status rank for sorting: Join Me, Online, Ask Me, Busy, then anything else,
/// with Offline last. Ties fall back to case-insensitive display name.
private int statusRank(string status)
{
    switch (status)
    {
        case "join me": return 0;
        case "active":  return 1;
        case "ask me":  return 2;
        case "busy":    return 3;
        case "offline": return 5;
        default:        return 4;
    }
}

/// Parse a FriendInfo from a JSON friend object.
private FriendInfo parseFriendInfo(JSONValue f)
{
    FriendInfo fi;
    if (const(JSONValue)* v = "id" in f)
        fi.userId = v.str;
    if (const(JSONValue)* v = "displayName" in f)
        fi.displayName = v.str;
    if (const(JSONValue)* v = "status" in f)
        fi.status = v.str;
    if (const(JSONValue)* v = "statusDescription" in f)
        fi.statusDescription = v.str;
    if (const(JSONValue)* v = "platform" in f)
        fi.platform = v.str;
    if (const(JSONValue)* v = "location" in f)
        fi.location = v.str;
    return fi;
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
                // I wonder what's up with this?
                JSONValue c = msg["content"];
                if (c.type == JSONType.string)
                    c = parseJSON(c.str);

                string notifId;
                if (const(JSONValue)* v = "id" in c)
                    notifId = v.str;
                string notifType;
                if (const(JSONValue)* v = "type" in c)
                    notifType = v.str;
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

                string sender;
                if (const(JSONValue)* v = "senderUsername" in c)
                    sender = v.str;
                if (sender.length == 0)
                    sender = user;

                // Build a message from available details.
                string notifMessage;
                if (const(JSONValue)* v = "message" in c)
                    notifMessage = v.str;
                if (notifMessage.length == 0)
                {
                    if ("details" in c && c["details"].type == JSONType.object)
                    {
                        JSONValue details = c["details"];
                        string worldName;
                        if (const(JSONValue)* v = "worldName" in details)
                            worldName = v.str;
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
                string respId;
                if (const(JSONValue)* v = "notificationId" in rc)
                    respId = v.str;
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

        string location;
        if (const(JSONValue)* v = "location" in c)
            location = v.str;
        if (location != "traveling")
            return;

        string travelingTo;
        if (const(JSONValue)* v = "travelingToLocation" in c)
            travelingTo = v.str;
        if (travelingTo.length == 0 || travelingTo != appState.currentLocation)
            return;

        // Friend is traveling to our instance.
        appState.addFeedEntry(0, "Player Joining", user, "", timeNow(), "", false, EventSource.local);
        dispatchNotification("player-joining", user, "", saved);
    }
    catch (Exception e)
    {
        logError("Failed to check player joining: %s", e.msg);
    }
}

/// Map raw event type strings to pretty display names.
/// Event types that are inherently about the logged-in user.
/// avatar-change is handled separately (check content.isSelf).
private bool isSelfEventType(string eventType)
{
    switch (eventType)
    {
        case "user-update":
        case "user-location":
        case "user-badge-assigned":
        case "user-badge-unassigned":
            return true;
        default:
            return false;
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

// Get current local time and format as "MM-DD HH:MM:SS" for display.
// This function is used for local log events, to be consistent with VRC events.
private string timeNow()
{
    import std.datetime : Clock, SysTime;
    
    try
    {
        SysTime t = Clock.currTime();
        return format!"%02d-%02d %02d:%02d:%02d"(t.month, t.day, t.hour, t.minute, t.second);
    }
    catch (Exception ex)
    {
        logError("timeNow error: %s", ex.msg);
    }
    
    return "";
}

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

    logDebugging("doReconnect: tearing down existing connection");

    // Close existing connection and wait for network thread.
    if (conn)
        conn.close();
    if (netThread)
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

    // Silence notifications until the fresh catch-up completes.
    catchUpComplete = false;

    logDebugging("doReconnect: connecting to %s:%d", host, port);
    appState.serverStatus = "Connecting...";
    appState.connected = false;
    conn = new ServerConnection(host, port, secret);
    if (conn.connect())
    {
        appState.connected = true;
        appState.serverStatus = "Connected";
        conn.catchUp(saved.lastEventId);
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
/// Keep the module-level `saved` notification fields in sync with the UI
/// so that toggling a checkbox takes effect immediately for dispatch,
/// without requiring the user to click "Save Settings".
private void syncNotifySettings()
{
    saved.notifyMute        = appState.notifyMute != 0;
    saved.notifyXSOverlay   = appState.notifyXSOverlay != 0;
    saved.notifyOVRToolkit  = appState.notifyOVRToolkit != 0;
    saved.notifyDesktop     = appState.notifyDesktop != 0;
    saved.notifyVolume      = appState.notifyVolume;
    saved.notifyTimeout     = appState.notifyTimeout;
    saved.notifyOpacity     = appState.notifyOpacity;
    saved.notifySound       = appState.notifySound != 0;
    foreach (size_t i; 0 .. notifyEventLabels.length)
        saved.notifyEventFilter[i] = appState.notifyEventFilter[i] != 0;
}

private void doSaveSettings()
{
    import core.stdc.string : strlen;

    Settings s;
    s.host = cast(string) appState.settingsHost[0 .. strlen(appState.settingsHost.ptr)].idup;
    s.port = {
        string p = cast(string) appState.settingsPort[0 .. strlen(appState.settingsPort.ptr)].idup;
        try return p.to!ushort;
        catch (Exception) return cast(ushort) 9700;
    }();
    s.secret = cast(string) appState.settingsSecret[0 .. strlen(appState.settingsSecret.ptr)].idup;
    s.fontPath = cast(string) appState.settingsFontPath[0 .. strlen(appState.settingsFontPath.ptr)].idup;
    s.fontSize = appState.settingsFontSize;
    s.feedPageSize = appState.feedPageSize;

    // Notification settings (int -> bool).
    s.notifyMute = appState.notifyMute != 0;
    s.notifyXSOverlay = appState.notifyXSOverlay != 0;
    s.notifyOVRToolkit = appState.notifyOVRToolkit != 0;
    s.notifyDesktop = appState.notifyDesktop != 0;
    s.notifyVolume = appState.notifyVolume;
    s.notifyTimeout = appState.notifyTimeout;
    s.notifyOpacity = appState.notifyOpacity;
    s.notifySound = appState.notifySound != 0;
    foreach (size_t i; 0 .. notifyEventLabels.length)
        s.notifyEventFilter[i] = appState.notifyEventFilter[i] != 0;

    // Feed filter settings (int -> bool).
    foreach (size_t i; 0 .. feedEventLabels.length)
        s.feedEventVisible[i] = appState.feedEventVisible[i] != 0;
    s.feedHideSelfEvents = appState.feedHideSelfEvents != 0;

    // Picture metadata setting (int -> bool).
    s.insertPictureMetadata = appState.insertPictureMetadata != 0;

    // Preserve the runtime-tracked event cursor; the Settings tab
    // doesn't expose it and we don't want to reset it to 0.
    s.lastEventId = saved.lastEventId;

    saved = s; // Update module-level copy used by notification dispatch.
    saveSettings(s);
}

/// Copy a D string into a fixed-size null-terminated char buffer.
private void initSettingsBuf(char[] buf, string value)
{
    assert(buf);
    assert(buf.length); // len>0, so safe to do len-1
    size_t len = value.length < buf.length ? value.length : buf.length - 1; // @suppress(dscanner.suspicious.length_subtraction)
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
    m[SDLK_TAB       & 0xff] = MU_KEY_TAB;
    return m;
}();
