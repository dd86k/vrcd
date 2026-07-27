/// GUI logic, including loop
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module client.gui;

import std.algorithm.sorting : sort;
import std.conv : to;
import std.format : format;
import std.json;
import std.string : fromStringz, indexOf;

import core.thread;

import core.stdc.string : memcpy, strlen;

import bindbc.sdl;
import sdl_ttf;
import sdl_image;
import ddlogger;
import ddui;
import vrcd.friends : FriendRoster, parseFriendsMessage;
import vrcd.events : extractEventFields;

import client.connection;
import client.stream : loadTLS;
import client.imagecache;
import client.logwatcher;
import client.notifications;
import client.renderer;
import client.settings;
import client.state;
import client.ui;
import client.utils;

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

/// True while a press's mousedown has been withheld from ddui, to be sent
/// only if the press resolves as a click (not a drag). Used inside the
/// filter popup so dragging the surface doesn't toggle checkboxes underneath.
private bool deferredMousedown;

/// Previous mouse Y during an active drag (for delta calculation).
private int dragPrevY;

/// Movement threshold (pixels) before a press becomes a drag.
private enum DRAG_THRESHOLD = 8;

/// Momentum velocity (pixels per frame, positive = scroll down).
private float momentumVY = 0.0f;

/// Friction multiplier applied each frame (0.0-1.0).
private enum MOMENTUM_FRICTION = 0.92f;

/// Stop momentum when velocity falls below this.
private enum MOMENTUM_MIN = 0.5f;

/// True for one frame after a non-drag mouseup (a real click).
bool wasClick;

/// Request a repaint on the next iteration. Call from ui.d when navigation
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
    appState.feedShowSelfEvents = cast(int) saved.feedShowSelfEvents;

    // Load picture metadata setting into appState (bool -> int).
    appState.insertPictureMetadata = cast(int) saved.insertPictureMetadata;

    // Load TLS settings into appState (bool -> int).
    appState.settingsTls = cast(int) saved.useTls;
    appState.settingsTlsSkipVerify = cast(int) saved.tlsSkipVerify;
    if (saved.tlsClientCert.length > 0)
        initSettingsBuf(appState.settingsTlsClientCert, saved.tlsClientCert);
    if (saved.tlsClientKey.length > 0)
        initSettingsBuf(appState.settingsTlsClientKey, saved.tlsClientKey);

    // Attempt to load OpenSSL for TLS support.
    loadTLS();

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
    
    // Load SDL2_image.
    SDLImageSupport imgStatus = loadSDLImage();
    if (imgStatus == SDLImageSupport.noLibrary)
    {
        // Debian/Ubuntu ship libSDL2_image-2.0.so.0 which bindbc doesn't
        // search for by default; try it explicitly.
        imgStatus = loadSDLImage("libSDL2_image-2.0.so.0");
    }
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

    // Content image disk cache (gallery thumbnails, prints, ...).
    initImageCache();

    // NOTE: SDL_HINT_FRAMEBUFFER_ACCELERATION is not set because we use
    //       SDL_CreateRenderer + owned surface instead of SDL_GetWindowSurface
    //       (which is unsupported on Wayland / sdl2-compat).
    //       It's a note here because it WAS used to do "software rendering", and
    //       here it meant the Xorg server was just holding the bag for us.
    SDL_SetHint(SDL_HINT_VIDEO_HIGHDPI_DISABLED, "0");
    // Match Wayland app_id / X11 WM_CLASS to the desktop file so launchers
    // (and Flatpak) associate the window with the correct icon and entry.
    SDL_SetHint(SDL_HINT_APP_NAME, "io.github.dd86k.vrcd");
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_TIMER | SDL_INIT_EVENTS) != 0)
    {
        logError("SDL_Init failed: %s", fromStringz( SDL_GetError() ));
        return 1;
    }

    if (TTF_Init() != 0)
    {
        logError("TTF_Init failed: %s", fromStringz( TTF_GetError() ));
        SDL_Quit();
        return 1;
    }

    // Log startup environment info.
    logStartupInfo();

    // Create window.
    window = SDL_CreateWindow("vrcd",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        window_width, window_height,
        SDL_WINDOW_RESIZABLE);
    if (window is null)
    {
        logError("SDL_CreateWindow failed: %s", fromStringz( SDL_GetError() ));
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
    uictx.get_clipboard = &get_clipboard;
    uictx.set_clipboard = &set_clipboard;

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

    // Connect asynchronously: the TCP connect can take 20s+ to time out,
    // so we do it on the network thread to keep the window responsive.
    appState.serverStatus = "Connecting...";
    conn = new ServerConnection(host, port, secret,
        saved.useTls, saved.tlsSkipVerify,
        saved.tlsClientCert, saved.tlsClientKey);
    long initialSinceId = sinceId;
    netThread = new Thread({
        conn.connectAndRun(msgQueue, networkEventType, initialSinceId);
    });
    netThread.isDaemon = true;
    netThread.start();

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
    SDL_Event e = void;

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
                        // Click-outside dismissal for the filter popup. The
                        // click is swallowed (no ddui input, no wasClick) so
                        // it doesn't activate something behind the popup.
                        if (filterPopupOpen &&
                            filterPopupContains(e.button.x, e.button.y) == false)
                        {
                            filterPopupOpen = false;
                            requestRepaint();
                            break;
                        }
                        // Defer scroll-drag decision. Normally we pass mousedown
                        // to ddui immediately so controls like sliders can
                        // track while held, but inside the popup the contents
                        // are checkboxes that toggle on mousedown, so we
                        // withhold the press until the gesture resolves.
                        dragState = DragState.pending;
                        dragStartX = e.button.x;
                        dragStartY = e.button.y;
                        momentumVY = 0.0f;  // Stop any active momentum.
                        deferredMousedown = filterPopupOpen
                            && filterPopupContains(e.button.x, e.button.y);
                        if (deferredMousedown == false)
                            mu_input_mousedown(uictx, e.button.x, e.button.y, MU_MOUSE_LEFT);
                    }
                    else if (e.button.button == SDL_BUTTON_X1)
                    {
                        // Mouse back button: pop the active tab's subpage,
                        // same as the sticky header Back button.
                        navigateBack(&appState);
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
                        if (dragState == DragState.pending)
                        {
                            // Was a click, not a drag. If the mousedown was
                            // deferred (popup case), send it now so the click
                            // registers as a complete press+release this frame.
                            if (deferredMousedown)
                                mu_input_mousedown(uictx, e.button.x, e.button.y, MU_MOUSE_LEFT);
                            mu_input_mouseup(uictx, e.button.x, e.button.y, MU_MOUSE_LEFT);
                            wasClick = true;
                        }
                        else if (dragState == DragState.dragging)
                        {
                            // Scroll-drag ended. If mousedown was deferred
                            // we never sent a press, so no release is needed
                            // and ddui never saw the click.
                            if (deferredMousedown == false)
                                mu_input_mouseup(uictx, e.button.x, e.button.y, MU_MOUSE_LEFT);
                        }
                        dragState = DragState.idle;
                        deferredMousedown = false;
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
                    // Escape dismisses the filter popup first, otherwise it
                    // pops the active tab's subpage like the header Back button.
                    if (e.type == SDL_KEYDOWN &&
                        e.key.keysym.sym == SDLK_ESCAPE)
                    {
                        if (filterPopupOpen)
                        {
                            filterPopupOpen = false;
                            requestRepaint();
                            break;
                        }
                        if (navigateBack(&appState))
                            break;
                    }
                    // Clipboard shortcuts (Ctrl+C/X/V/A) are plain key flags in
                    // the map below: ddui only acts on them while Ctrl is held,
                    // and does the editing itself through the clipboard hooks.
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

        // Reconcile connection state from the network thread.
        {
            ConnectionState cs = msgQueue.getConnectionState();
            final switch (cs)
            {
                case ConnectionState.connecting:
                    // No transition; serverStatus stays "Connecting...".
                    break;
                case ConnectionState.connected:
                    if (appState.connected == false)
                    {
                        appState.connected = true;
                        appState.serverStatus = "Connected";
                        appState.serverProtocol = conn ? conn.serverVersion : 0;
                        // Don't reset dapPairState here. The server sends its
                        // dap_status snapshot right after auth_ok, so by the
                        // time we observe this `connected` transition the
                        // snapshot may already have been drained and applied
                        // this same frame (drainNetworkMessages runs inside the
                        // event loop, ahead of this reconcile). Resetting to
                        // `unknown` here would clobber it and leave the UI stuck
                        // on "Checking pairing status...". The reset is done at
                        // connection initiation instead (startup default and
                        // doReconnect / disconnect).
                    }
                    break;
                case ConnectionState.failed:
                    if (appState.serverStatus == "Connecting...")
                    {
                        string err = msgQueue.getConnectError();
                        appState.connected = false;
                        appState.serverStatus = err.length
                            ? "Failed to connect: " ~ err
                            : "Failed to connect";
                    }
                    break;
                case ConnectionState.disconnected:
                    if (appState.connected)
                    {
                        appState.connected = false;
                        appState.serverStatus = "Disconnected";
                        // We no longer know the server's pair state.
                        appState.dapPairState = AppState.DapPairState.unknown;
                        appState.dapStatus = "";
                        // A fetch_older in flight will never get its
                        // `older_fetched` reply now; clear the flag so the
                        // "Load older events" button isn't stuck disabled.
                        appState.fetchingOlder = false;
                        // Same for moderation round-trips.
                        appState.moderationsLoading = false;
                        appState.moderationActionInFlight = false;
                        appState.serverProtocol = 0;
                    }
                    break;
            }
        }

        // Handle reconnect request from Settings tab.
        if (appState.reconnectRequested)
        {
            appState.reconnectRequested = false;
            doReconnect();
        }

        // Handle Drop a Portal unpair request from Settings tab.
        // The token now lives on the server; cancelling a pair flow is the
        // closest "unpair" gesture available from the client. Actual token
        // revocation happens on dropaport.al's side, after which the server
        // will broadcast `dap_login_error`.
        if (appState.dapUnpairRequested)
        {
            appState.dapUnpairRequested = false;
            if (conn && appState.connected)
                conn.sendDapPairCancel();
            appState.dapStatus = "";
        }

        // Handle Drop a Portal pair request from Settings tab.
        if (appState.dapPairRequested)
        {
            appState.dapPairRequested = false;
            if (conn && appState.connected)
                conn.sendDapPairStart();
        }

        // Handle friends refresh request.
        if (appState.refreshFriendsRequested)
        {
            appState.refreshFriendsRequested = false;
            if (conn && appState.connected)
                conn.requestFriends();
        }

        // Handle moderations (mute/block lists) refresh request.
        if (appState.refreshModerationsRequested)
        {
            appState.refreshModerationsRequested = false;
            if (conn && appState.connected &&
                conn.serverVersion >= PROTOCOL_MODERATION &&
                appState.moderationsLoading == false)
            {
                conn.requestModerations();
                appState.moderationsLoading = true;
                appState.moderationsError = null;
            }
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

        // Drain pending status change request.
        if (appState.pendingSetStatus.length > 0 || appState.pendingSetStatusDescriptionSet)
        {
            if (conn && appState.connected && appState.statusUpdateInFlight == false)
            {
                bool setStatus = appState.pendingSetStatus.length > 0;
                bool setDesc = appState.pendingSetStatusDescriptionSet;
                conn.sendSetStatus(setStatus, appState.pendingSetStatus,
                    setDesc, appState.pendingSetStatusDescription);
                appState.statusUpdateInFlight = true;
            }
            appState.pendingSetStatus = null;
            appState.pendingSetStatusDescription = null;
            appState.pendingSetStatusDescriptionSet = false;
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

        // Drain pending self-invite join requests.
        if (appState.pendingJoins.length > 0)
        {
            if (conn && appState.connected)
            {
                foreach (string loc; appState.pendingJoins)
                    conn.sendJoinInstance(loc);
            }
            appState.pendingJoins.length = 0;
        }

        // Drain pending "Open in VRChat" requests. Windows reaches the
        // running client's launch pipe in-process (with a vrchat:// scheme
        // fallback); on Linux the pipe write runs inside VRChat's Proton
        // container, so it is spawned and polled asynchronously, with
        // self-invite as the fallback.
        if (appState.pendingOpens.length > 0)
        {
            foreach (string loc; appState.pendingOpens)
            {
                version (Windows)
                {
                    openVRChatInstance(loc);
                }
                else
                {
                    if (isVRChatRunning() == false)
                    {
                        // Cold boot straight into the instance via Steam.
                        openVRChatInstance(loc);
                        appState.addFeedEntry(0, "info", "",
                            "Launching VRChat into instance", timeNow(), "", false, EventSource.system);
                        continue;
                    }
                    final switch (startVRChatIPCJoin(loc)) with (IPCJoinStart)
                    {
                    case started:
                        break;
                    case busy:
                        appState.addFeedEntry(0, "error", "",
                            "A join request is already in progress", timeNow(), "", false, EventSource.system);
                        break;
                    case unavailable:
                        appState.pendingJoins ~= loc;
                        appState.addFeedEntry(0, "info", "",
                            "VRChat IPC unavailable, self-inviting instead", timeNow(), "", false, EventSource.system);
                        break;
                    }
                }
            }
            appState.pendingOpens.length = 0;
        }

        // Poll the in-flight IPC join attempt.
        version (linux)
        {
            string ipcLoc;
            final switch (pollVRChatIPCJoin(ipcLoc)) with (IPCJoinPoll)
            {
            case idle, running:
                break;
            case success:
                appState.addFeedEntry(0, "info", "",
                    "Join request sent to VRChat", timeNow(), "", false, EventSource.system);
                break;
            case failed:
                appState.pendingJoins ~= ipcLoc;
                appState.addFeedEntry(0, "info", "",
                    "VRChat IPC join failed, self-inviting instead", timeNow(), "", false, EventSource.system);
                break;
            }
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

        // Handle inventory tab (re)load request for the current section.
        if (appState.invRefreshRequested)
        {
            appState.invRefreshRequested = false;
            if (conn && appState.connected)
            {
                int sec = cast(int) appState.invSection;
                string tag = invSectionTag(appState.invSection);
                if (tag)
                    conn.requestFiles(tag, 60, 0);
                else if (appState.invSection == InvSection.prints)
                    conn.requestPrints();
                else
                    conn.requestInventory();
                appState.invLoading[sec] = true;
                appState.invStale[sec] = false;
                appState.invError[sec] = null;
            }
        }

        // Handle "Load more" for paged files sections.
        if (appState.invLoadMoreRequested)
        {
            appState.invLoadMoreRequested = false;
            int sec = cast(int) appState.invSection;
            string tag = invSectionTag(appState.invSection);
            if (tag && conn && appState.connected && appState.invLoading[sec] == false)
            {
                conn.requestFiles(tag, 60, appState.invFiles[sec].length);
                appState.invLoading[sec] = true;
            }
        }

        // Dispatch queued image requests: local disk cache first, then the
        // server proxy. In-flight and known-failed keys are skipped so a
        // visible placeholder re-enqueueing every frame stays cheap.
        if (appState.pendingImageRequests.length > 0)
        {
            foreach (ref ImageRequest req; appState.pendingImageRequests)
            {
                string key = imageKey(req.fileId, req.fileVersion, req.size);
                if (key in appState.imageRequestsInFlight)
                    continue;
                if (key in appState.failedImages)
                    continue;
                if (loadFromDisk(key))
                    continue;
                if (conn && appState.connected)
                {
                    conn.requestImage(req.fileId, req.fileVersion, req.size);
                    appState.imageRequestsInFlight[key] = true;
                }
            }
            appState.pendingImageRequests.length = 0;
        }

        // Drain queued content management actions.
        if (appState.pendingContentActions.length > 0)
        {
            if (conn && appState.connected)
            {
                foreach (ref ContentAction act; appState.pendingContentActions)
                {
                    switch (act.kind)
                    {
                    case "delete_file":  conn.sendDeleteFile(act.id); break;
                    case "delete_print": conn.sendDeletePrint(act.id); break;
                    case "set_icon":     conn.sendSetUserIcon(act.id); break;
                    case "equip", "unequip", "consume":
                        conn.sendInventoryAction(act.kind, act.id, act.extra);
                        break;
                    default:
                        logWarn("Unknown content action: %s", act.kind);
                        continue;
                    }
                    appState.invActionInFlight = true;
                }
            }
            appState.pendingContentActions.length = 0;
        }

        // Drain queued moderation/friendship actions.
        if (appState.pendingModerationActions.length > 0)
        {
            if (conn && appState.connected)
            {
                foreach (ref ModerationAction act; appState.pendingModerationActions)
                {
                    if (act.action == "unfriend")
                        conn.sendUnfriend(act.userId);
                    else
                        conn.sendModerateUser(act.userId, act.action);
                    appState.moderationActionInFlight = true;
                }
            }
            appState.pendingModerationActions.length = 0;
        }

        // Handle upload request from the inventory tab.
        if (appState.invUploadRequested)
        {
            appState.invUploadRequested = false;
            doInventoryUpload();
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
            SDL_Event wakeEv = void;
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
                case MU_COMMAND_TEXT: r_draw_text(mu_command_text_slice(uictx, &cmd), cmd.text.pos, cmd.text.color); break;
                case MU_COMMAND_RECT: r_draw_rect(cmd.rect.rect, cmd.rect.color); break;
                case MU_COMMAND_ICON:
                    if (r_is_image_id(cmd.icon.id))
                        r_draw_image(cmd.icon.id, cmd.icon.rect);
                    else
                        r_draw_icon(cmd.icon.id, cmd.icon.rect, cmd.icon.color);
                    break;
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
                    // avatar-change and profile-change carry isSelf in their content.
                    if ((eventType == "avatar-change" || eventType == "profile-change")
                        && content.type == JSONType.object)
                        if (const(JSONValue)* v = "isSelf" in *content)
                            if (v.type == JSONType.true_)
                                isSelfEvent = true;
                }

                appState.addFeedEntry(id, eventType, user, detail, receivedAt, rawContent, isSelfEvent, EventSource.server);
                if (catchUpComplete)
                    dispatchNotification(eventType, user, detail, saved);

                // Store actionable notifications.
                storeNotification(eventType, msg, user, rawReceivedAt);

                // The user's files/prints/inventory changed somewhere else
                // (in-game upload, another device). Mark the section stale
                // so the STUFF tab reloads it when next viewed.
                if (eventType == "content-refresh")
                    markContentStale(msg);

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
                // saved.lastEventId, that's the high-water mark for live
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
                    if ((eventType == "avatar-change" || eventType == "profile-change")
                        && content.type == JSONType.object)
                        if (const(JSONValue)* v = "isSelf" in *content)
                            if (v.type == JSONType.true_)
                                isSelfEvent = true;
                }

                appState.appendOldFeedEntry(id, eventType,
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

            case "self":
                if (const(JSONValue)* v = "id" in msg)
                    appState.selfUserId = v.str;
                if (const(JSONValue)* v = "displayName" in msg)
                    appState.selfDisplayName = v.str;
                if (const(JSONValue)* v = "status" in msg)
                    appState.selfStatus = v.str;
                if (const(JSONValue)* v = "statusDescription" in msg)
                {
                    appState.selfStatusDescription = v.str;
                    // Sync the textbox buffer when not in-flight, so the
                    // user doesn't see their own typed text overwritten by
                    // a snapshot that crosses paths with their edit.
                    if (appState.statusUpdateInFlight == false)
                    {
                        import std.algorithm : min;
                        appState.statusDescriptionInput[] = '\0';
                        size_t n = min(v.str.length, appState.statusDescriptionInput.length - 1);
                        appState.statusDescriptionInput[0 .. n] = v.str[0 .. n];
                    }
                }
                break;

            case "set_status_result":
                appState.statusUpdateInFlight = false;
                bool ok;
                if (const(JSONValue) *jsuccess = "success" in msg)
                    ok = jsuccess.type == JSONType.true_;
                if (ok)
                {
                    // Server will follow up with a fresh `self` snapshot.
                    appState.statusUpdateError = null;
                    appState.selfStatusDraft = null;
                    appState.addFeedEntry(0, "system", "",
                        "Status updated", timeNow(), "", false, EventSource.system);
                }
                else
                {
                    string errMsg;
                    if (const(JSONValue)* v = "error" in msg)
                        errMsg = v.str;
                    appState.statusUpdateError = errMsg.length > 0 ? errMsg : "Unknown error";
                    appState.addFeedEntry(0, "error", "",
                        "Status update failed: " ~ errMsg, timeNow(), "", false, EventSource.system);
                }
                break;

            case "moderations":
                applyModerationsSnapshot(msg);
                break;

            case "moderate_result", "unfriend_result":
                appState.moderationActionInFlight = false;
                bool modOk;
                if (const(JSONValue) *jsuccess = "success" in msg)
                    modOk = jsuccess.type == JSONType.true_;
                string modAction = msgType == "unfriend_result" ? "unfriend" : null;
                if (modAction is null)
                    if (const(JSONValue)* v = "action" in msg)
                        modAction = v.str;
                string modUser;
                if (const(JSONValue)* v = "display_name" in msg)
                    modUser = v.str;
                if (modOk)
                {
                    // Server follows up with a fresh moderations/friends snapshot.
                    appState.addFeedEntry(0, "system", modUser,
                        moderationDoneLabel(modAction), timeNow(), "", false, EventSource.system);
                }
                else
                {
                    string modErr;
                    if (const(JSONValue)* v = "error" in msg)
                        modErr = v.str;
                    appState.addFeedEntry(0, "error", modUser,
                        moderationVerbLabel(modAction) ~ " failed: " ~ modErr,
                        timeNow(), "", false, EventSource.system);
                }
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
                    // Update current instance from local log. The server
                    // tracks self-location via VRChat WS and reports visits
                    // to dropaport.al on its own.
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
                    appState.addFeedEntry(0, logEventType, urlUser, url, timeNow(), "", false, EventSource.local);
                    break;
                default:
                    string logUser;
                    if (const(JSONValue)* v = "display_name" in msg)
                        logUser = v.str;
                    bool logIsSelf;
                    if (const(JSONValue) *jis_self = "is_self" in msg)
                        logIsSelf = jis_self.type == JSONType.true_;
                    appState.addFeedEntry(0, logEventType, logUser, "", timeNow(), "", logIsSelf, EventSource.local);
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
                
                const(JSONValue) *jsuccess = "success" in msg;
                if (jsuccess && jsuccess.type == JSONType.true_)
                {
                    appState.removeNotification(notifId);
                }
                else
                {
                    // Check whether the notification is still in state.
                    // For fire-and-forget "hide", it was already removed
                    // optimistically, suppress the error to avoid noise.
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

            case "join_instance_result":
                const(JSONValue) *jok = "success" in msg;
                if (jok && jok.type == JSONType.true_)
                {
                    appState.addFeedEntry(0, "info", "",
                        "Self-invite sent, check your VRChat invites", timeNow(), "", false, EventSource.system);
                }
                else
                {
                    string errMsg;
                    if (const(JSONValue)* v = "error" in msg)
                        errMsg = v.str;
                    appState.addFeedEntry(0, "error", "",
                        "Self-invite failed: " ~ errMsg, timeNow(), "", false, EventSource.system);
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

            case "dap_status":
                {
                    // Quiet state replay from the server, sent on
                    // (re)connect. Updates the UI without producing a feed
                    // entry; live transitions still come through
                    // dap_pair_complete / dap_*_error.
                    bool paired;
                    if (const(JSONValue)* v = "paired" in msg)
                        paired = v.type == JSONType.true_;
                    string dapUsername;
                    if (const(JSONValue)* v = "username" in msg)
                        dapUsername = v.str;
                    if (paired)
                    {
                        appState.dapPairState = AppState.DapPairState.paired;
                        appState.dapStatus = dapUsername.length > 0
                            ? "Paired as " ~ dapUsername
                            : "Paired";
                    }
                    else
                    {
                        appState.dapPairState = AppState.DapPairState.unpaired;
                        appState.dapStatus = "";
                    }
                }
                break;

            case "dap_pair_request":
                {
                    string userCode;
                    string url;
                    if (const(JSONValue)* v = "user_code" in msg)
                        userCode = v.str;
                    if (const(JSONValue)* v = "verification_uri" in msg)
                        url = v.str;
                    if (url.length > 0)
                    {
                        import client.utils : openBrowser;
                        openBrowser(url);
                    }
                    // Mid-pairing: state is known (unpaired) and the label
                    // shows the code; the button becomes a cancel gesture.
                    appState.dapPairState = AppState.DapPairState.unpaired;
                    JSONValue pairContent;
                    pairContent["user_code"] = userCode;
                    pairContent["url"] = url;
                    appState.dapStatus = userCode.length > 0
                        ? "Pairing: " ~ userCode
                        : "Pairing...";
                    appState.addFeedEntry(0, "dap-pair-code", "",
                        "Code: " ~ userCode ~ " (approve in browser)",
                        timeNow(), pairContent.toString(), false, EventSource.dropaportal);
                }
                break;

            case "dap_pair_complete":
                {
                    string dapUsername;
                    if (const(JSONValue)* v = "username" in msg)
                        dapUsername = v.str;
                    string dapStatus = dapUsername.length > 0
                        ? "Paired as " ~ dapUsername
                        : "Paired";
                    appState.dapPairState = AppState.DapPairState.paired;
                    appState.dapStatus = dapStatus;
                    appState.addFeedEntry(0, "dap-login-ok", "", dapStatus,
                        timeNow(), "", false, EventSource.dropaportal);
                }
                break;

            case "dap_pair_error":
                string detail;
                if (const(JSONValue)* v = "detail" in msg)
                    detail = v.str;
                appState.dapPairState = AppState.DapPairState.unpaired;
                appState.dapStatus = "";
                appState.addFeedEntry(0, "dap-error", "",
                    detail.length > 0 ? detail : "Pairing failed",
                    timeNow(), "", false, EventSource.dropaportal);
                break;

            case "dap_login_error":
                string detail;
                if (const(JSONValue)* v = "detail" in msg)
                    detail = v.str;
                appState.dapPairState = AppState.DapPairState.unpaired;
                appState.dapStatus = "";
                appState.addFeedEntry(0, "dap-login-error", "",
                    detail.length > 0 ? detail : "Drop a Portal session expired",
                    timeNow(), "", false, EventSource.dropaportal);
                break;

            case "files":
                applyFilesReply(msg);
                break;

            case "prints":
                applyPrintsReply(msg);
                break;

            case "inventory":
                applyInventoryReply(msg);
                break;

            case "image":
                applyImageReply(msg);
                break;

            case "delete_file_result", "delete_print_result",
                "set_user_icon_result", "inventory_action_result":
                applyContentActionResult(msgType, msg);
                break;

            case "upload_image_result", "upload_print_result":
                appState.invUploadInFlight = false;
                const(JSONValue) *jup = "success" in msg;
                if (jup && jup.type == JSONType.true_)
                {
                    appState.invUploadStatus = "Upload complete";
                    // Reload the section so the new entry shows up.
                    int sec = cast(int) appState.invSection;
                    appState.invStale[sec] = true;
                    appState.invRefreshRequested = true;
                    if (appState.droppedFiles.length > 0)
                        appState.droppedFiles = appState.droppedFiles[1 .. $];
                }
                else
                {
                    string errMsg;
                    if (const(JSONValue)* v = "error" in msg)
                        errMsg = v.str;
                    appState.invUploadStatus = "Upload failed: "
                        ~ (errMsg.length > 0 ? errMsg : "unknown error");
                }
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

/// Mark the inventory section named by a content-refresh event as stale.
private void markContentStale(JSONValue msg)
{
    string contentType;
    if (const(JSONValue)* content = "content" in msg)
    {
        if (content.type == JSONType.object)
            if (const(JSONValue)* v = "contentType" in *content)
                contentType = v.str;
    }

    InvSection section;
    switch (contentType)
    {
    case "gallery":          section = InvSection.gallery; break;
    case "icon":             section = InvSection.icons; break;
    case "sticker":          section = InvSection.stickers; break;
    case "emoji":            section = InvSection.emoji; break;
    case "print", "prints":  section = InvSection.prints; break;
    case "inventory":        section = InvSection.items; break;
    default:
        return;
    }
    appState.invStale[cast(int) section] = true;
}

/// Apply a `files` listing reply (gallery/icon/sticker/emoji page).
private void applyFilesReply(JSONValue msg)
{
    string tag;
    if (const(JSONValue)* v = "tag" in msg)
        tag = v.str;

    InvSection section;
    switch (tag)
    {
    case "gallery": section = InvSection.gallery; break;
    case "icon":    section = InvSection.icons; break;
    case "sticker": section = InvSection.stickers; break;
    case "emoji":   section = InvSection.emoji; break;
    default:
        logWarn("files reply with unknown tag: %s", tag);
        return;
    }
    int sec = cast(int) section;

    appState.invLoading[sec] = false;
    appState.invLoaded[sec] = true;
    if (const(JSONValue)* v = "error" in msg)
    {
        appState.invError[sec] = v.str;
        return;
    }
    appState.invError[sec] = null;

    long offset;
    if (const(JSONValue)* v = "offset" in msg)
        offset = v.integer;
    long count;
    if (const(JSONValue)* v = "count" in msg)
        count = v.integer;

    ContentFile[] page;
    if (const(JSONValue)* files = "files" in msg)
    {
        foreach (ref const(JSONValue) f; files.array)
        {
            ContentFile entry;
            if (const(JSONValue)* v = "id" in f)
                entry.fileId = v.str;
            if (const(JSONValue)* v = "name" in f)
                entry.name = v.str;
            if (const(JSONValue)* v = "version" in f)
                entry.fileVersion = v.integer;
            if (const(JSONValue)* v = "mimeType" in f)
                entry.mimeType = v.str;
            if (entry.fileId.length > 0 && entry.fileVersion > 0)
                page ~= entry;
        }
    }

    if (offset == 0)
        appState.invFiles[sec] = page;
    else
        appState.invFiles[sec] ~= page;
    // A full page means more entries may follow.
    appState.invMoreAvailable[sec] = count >= 60;
}

/// Apply a `prints` listing reply.
private void applyPrintsReply(JSONValue msg)
{
    int sec = cast(int) InvSection.prints;
    appState.invLoading[sec] = false;
    appState.invLoaded[sec] = true;
    if (const(JSONValue)* v = "error" in msg)
    {
        appState.invError[sec] = v.str;
        return;
    }
    appState.invError[sec] = null;

    PrintEntry[] list;
    if (const(JSONValue)* prints = "prints" in msg)
    {
        foreach (ref const(JSONValue) p; prints.array)
        {
            PrintEntry entry;
            if (const(JSONValue)* v = "id" in p)
                entry.printId = v.str;
            if (const(JSONValue)* v = "file_id" in p)
                entry.fileId = v.str;
            if (const(JSONValue)* v = "file_version" in p)
                entry.fileVersion = v.integer;
            if (const(JSONValue)* v = "note" in p)
                entry.note = v.str;
            if (const(JSONValue)* v = "worldName" in p)
                entry.worldName = v.str;
            if (const(JSONValue)* v = "timestamp" in p)
                entry.timestamp = v.str;
            else if (const(JSONValue)* v = "createdAt" in p)
                entry.timestamp = v.str;
            if (entry.printId.length > 0)
                list ~= entry;
        }
    }
    appState.invPrints = list;
}

/// Apply an `inventory` listing reply.
private void applyInventoryReply(JSONValue msg)
{
    int sec = cast(int) InvSection.items;
    appState.invLoading[sec] = false;
    appState.invLoaded[sec] = true;
    if (const(JSONValue)* v = "error" in msg)
    {
        appState.invError[sec] = v.str;
        return;
    }
    appState.invError[sec] = null;

    if (const(JSONValue)* v = "total_count" in msg)
        appState.invItemsTotal = v.integer;

    InventoryEntry[] list;
    if (const(JSONValue)* items = "items" in msg)
    {
        foreach (ref const(JSONValue) it; items.array)
        {
            InventoryEntry entry;
            if (const(JSONValue)* v = "id" in it)
                entry.id = v.str;
            if (const(JSONValue)* v = "name" in it)
                entry.name = v.str;
            if (const(JSONValue)* v = "description" in it)
                entry.description = v.str;
            if (const(JSONValue)* v = "itemType" in it)
                entry.itemType = v.str;
            if (const(JSONValue)* v = "itemTypeLabel" in it)
                entry.itemTypeLabel = v.str;
            if (const(JSONValue)* v = "equipSlot" in it)
                entry.equipSlot = v.str;
            if (const(JSONValue)* v = "flags" in it)
            {
                if (v.type == JSONType.array)
                    foreach (ref const(JSONValue) f; v.array)
                        if (f.type == JSONType.string)
                            entry.flags ~= f.str;
            }
            if (const(JSONValue)* v = "isArchived" in it)
                entry.archived = v.type == JSONType.true_;
            if (const(JSONValue)* v = "image_file_id" in it)
                entry.imageFileId = v.str;
            if (const(JSONValue)* v = "image_version" in it)
                entry.imageVersion = v.integer;
            if (entry.id.length > 0)
                list ~= entry;
        }
    }
    appState.invItems = list;
}

/// Apply an `image` reply: decode into the image cache, or record failure.
private void applyImageReply(JSONValue msg)
{
    import std.base64 : Base64;

    string fileId;
    if (const(JSONValue)* v = "file_id" in msg)
        fileId = v.str;
    long fileVersion = 1;
    if (const(JSONValue)* v = "version" in msg)
        fileVersion = v.integer;
    int size;
    if (const(JSONValue)* v = "size" in msg)
        size = cast(int) v.integer;

    string key = imageKey(fileId, fileVersion, size);
    appState.imageRequestsInFlight.remove(key);

    const(JSONValue) *jok = "success" in msg;
    if (jok is null || jok.type != JSONType.true_)
    {
        string errMsg;
        if (const(JSONValue)* v = "error" in msg)
            errMsg = v.str;
        logWarn("image %s failed: %s", key, errMsg);
        appState.failedImages[key] = true;
        return;
    }

    const(ubyte)[] data;
    if (const(JSONValue)* v = "data_base64" in msg)
    {
        try data = Base64.decode(v.str);
        catch (Exception e)
        {
            logWarn("image %s: bad base64: %s", key, e.msg);
            appState.failedImages[key] = true;
            return;
        }
    }
    if (insertEncoded(key, data) == false)
        appState.failedImages[key] = true;
}

/// Apply a content management action result (delete/set icon/equip/...).
private void applyContentActionResult(string msgType, JSONValue msg)
{
    appState.invActionInFlight = false;
    appState.armedConfirm = ArmedConfirm.init;

    const(JSONValue) *jok = "success" in msg;
    bool ok = jok && jok.type == JSONType.true_;
    if (ok == false)
    {
        string errMsg;
        if (const(JSONValue)* v = "error" in msg)
            errMsg = v.str;
        appState.addFeedEntry(0, "error", "",
            "Action failed: " ~ (errMsg.length > 0 ? errMsg : msgType),
            timeNow(), "", false, EventSource.system);
        return;
    }

    switch (msgType)
    {
    case "delete_file_result":
        string fileId;
        if (const(JSONValue)* v = "file_id" in msg)
            fileId = v.str;
        // Splice out of every files section; a file lives in only one, but
        // scanning all four is cheaper than tracking which.
        foreach (size_t sec; 0 .. appState.invFiles.length)
        {
            ContentFile[] kept;
            foreach (ref ContentFile f; appState.invFiles[sec])
                if (f.fileId != fileId)
                    kept ~= f;
            appState.invFiles[sec] = kept;
        }
        if (appState.selectedInvFile.fileId == fileId)
            appState.invDetailOpen = false;
        appState.addFeedEntry(0, "system", "", "File deleted",
            timeNow(), "", false, EventSource.system);
        break;

    case "delete_print_result":
        string printId;
        if (const(JSONValue)* v = "print_id" in msg)
            printId = v.str;
        PrintEntry[] kept;
        foreach (ref PrintEntry p; appState.invPrints)
            if (p.printId != printId)
                kept ~= p;
        appState.invPrints = kept;
        if (appState.selectedInvPrint.printId == printId)
            appState.invDetailOpen = false;
        appState.addFeedEntry(0, "system", "", "Print deleted",
            timeNow(), "", false, EventSource.system);
        break;

    case "set_user_icon_result":
        string fileId;
        if (const(JSONValue)* v = "file_id" in msg)
            fileId = v.str;
        appState.addFeedEntry(0, "system", "",
            fileId.length > 0 ? "Profile icon updated" : "Profile icon cleared",
            timeNow(), "", false, EventSource.system);
        break;

    case "inventory_action_result":
        string action;
        if (const(JSONValue)* v = "action" in msg)
            action = v.str;
        appState.addFeedEntry(0, "system", "",
            "Inventory action done: " ~ action,
            timeNow(), "", false, EventSource.system);
        // Item state (equipSlot, consumed) changed server-side; reload.
        appState.invStale[cast(int) InvSection.items] = true;
        if (appState.invSection == InvSection.items)
            appState.invRefreshRequested = true;
        break;

    default:
        break;
    }
}

/// Apply a friends snapshot from the server to the app state.
private void applyFriendsSnapshot(JSONValue msg)
{
    // Bucketing and ordering live in vrcd.friends, shared with the web
    // front-end so the two rosters cannot disagree on what counts as
    // "Private" versus "Active elsewhere".
    FriendRoster roster = parseFriendsMessage(msg);

    appState.instances = roster.instances;
    appState.activeElsewhereFriends = roster.activeElsewhere;
    appState.offlineFriends = roster.offline;
    // Flat roster for the TOOLS friend list, sorted by name only.
    appState.allFriends = roster.all;
    appState.selectedFriend = null; // Reset selection on refresh.
    // Rows may have moved under an armed confirmation; disarm.
    appState.armedConfirm = ArmedConfirm.init;
}

/// Apply a `moderations` snapshot: mute and block lists.
private void applyModerationsSnapshot(JSONValue msg)
{
    appState.moderationsLoading = false;

    if (const(JSONValue)* v = "error" in msg)
    {
        appState.moderationsError = v.str;
        return;
    }

    static ModerationEntry parseModerationEntry(JSONValue v)
    {
        ModerationEntry e;
        if (const(JSONValue)* p = "user_id" in v)
            e.userId = p.str;
        if (const(JSONValue)* p = "display_name" in v)
            e.displayName = p.str;
        return e;
    }

    ModerationEntry[] muted;
    ModerationEntry[] blocked;

    if (const(JSONValue) *jmuted = "muted" in msg)
    if (jmuted.type == JSONType.array)
    {
        foreach (v; jmuted.array)
            muted ~= parseModerationEntry(v);
    }

    if (const(JSONValue) *jblocked = "blocked" in msg)
    if (jblocked.type == JSONType.array)
    {
        foreach (v; jblocked.array)
            blocked ~= parseModerationEntry(v);
    }

    sort!moderationLess(muted);
    sort!moderationLess(blocked);

    appState.mutedUsers = muted;
    appState.blockedUsers = blocked;
    appState.moderationsLoaded = true;
    appState.moderationsError = null;
    // Rows may have moved under an armed confirmation; disarm.
    appState.armedConfirm = ArmedConfirm.init;
}

/// Feed wording for a completed moderation action.
private string moderationDoneLabel(string action)
{
    switch (action)
    {
        case "mute":     return "Muted";
        case "unmute":   return "Unmuted";
        case "block":    return "Blocked";
        case "unblock":  return "Unblocked";
        case "unfriend": return "Unfriended";
        default:         return "Moderation done";
    }
}

/// Feed wording for a failed moderation action.
private string moderationVerbLabel(string action)
{
    switch (action)
    {
        case "mute":     return "Mute";
        case "unmute":   return "Unmute";
        case "block":    return "Block";
        case "unblock":  return "Unblock";
        case "unfriend": return "Unfriend";
        default:         return "Moderation";
    }
}

/// Case-insensitive display-name ordering for moderation entries.
private bool moderationLess(ref const ModerationEntry a, ref const ModerationEntry b)
{
    import std.uni : icmp;
    return icmp(a.displayName, b.displayName) < 0;
}

/// Actionable notification types that get stored in the notifications tab.
private immutable string[] actionableNotifTypes = [
    "friendRequest", "invite", "requestInvite",
];

/// Store an actionable notification or remove on delete/hide events.
private void storeNotification(string eventType, JSONValue msg, string user, string rawReceivedAt)
{
    import std.datetime : SysTime;
    long receivedAtUnix;
    if (rawReceivedAt.length > 0)
    {
        try
            receivedAtUnix = SysTime.fromISOExtString(rawReceivedAt).toUnixTime!long();
        catch (Exception) {}
    }

    const(JSONValue) *jcontent = "content" in msg;
    if (jcontent is null) // we depend on 'content' for all of these
        return;
    
    // NOTE: Except for 'see-notification' and 'hide-notification', 'content' is double-encoded
    JSONValue content = void;
    try switch (eventType)
    {
        case "notification":
        case "notification-v2":
            content = jcontent.type == JSONType.string ? parseJSON(jcontent.str) : *jcontent;
            
            string notifId;
            if (const(JSONValue)* v = "id" in content)
                notifId = v.str;
            string notifType;
            if (const(JSONValue)* v = "type" in content)
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
            if (const(JSONValue)* v = "senderUsername" in content)
                sender = v.str;
            if (sender.length == 0)
                sender = user;

            // Build a message from available details.
            string notifMessage;
            if (const(JSONValue)* v = "message" in content)
                notifMessage = v.str;
            if (notifMessage.length == 0)
            {
                if (const(JSONValue) *jdetails = "details" in content)
                if (jdetails.type == JSONType.object)
                {
                    string worldName;
                    if (const(JSONValue)* v = "worldName" in *jdetails)
                        worldName = v.str;
                    if (worldName.length > 0)
                        notifMessage = worldName;
                }
            }

            appState.addNotification(notifId, notifType, sender, notifMessage, receivedAtUnix);
            return;

        case "notification-v2-delete":
            content = jcontent.type == JSONType.string ? parseJSON(jcontent.str) : *jcontent;

            if (const(JSONValue) *jids = "ids" in content)
            if (jids.type == JSONType.array)
            {
                foreach (JSONValue idVal; jids.array)
                {
                    if (idVal.type == JSONType.string)
                        appState.removeNotification(idVal.str);
                }
            }
            return;

        case "hide-notification":
        case "see-notification":
            // Content is a plain string (notification ID).
            if (jcontent.type == JSONType.string)
                appState.removeNotification(jcontent.str);
            return;

        case "response-notification":
            content = jcontent.type == JSONType.string ? parseJSON(jcontent.str) : *jcontent;

            string respId;
            if (const(JSONValue)* v = "notificationId" in content)
                respId = v.str;
            if (respId.length > 0)
                appState.removeNotification(respId);
            return;

        default:
            return;
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
        appState.addFeedEntry(0, "player-joining", user, "", timeNow(), "", false, EventSource.local);
        dispatchNotification("player-joining", user, "", saved);
    }
    catch (Exception e)
    {
        logError("Failed to check player joining: %s", e.msg);
    }
}

/// Log platform, video driver, and library versions at startup.
/// Called after SDL_Init + TTF_Init so all queries are valid.
private void logStartupInfo()
{
    import std.format : sformat;

    // Platform (OS).
    const(char)* platform = SDL_GetPlatform();
    logInfo("Platform: %s", platform ? fromStringz( platform ) : "unknown");

    // Video driver (wayland, x11, windows, cocoa, etc.).
    const(char)* videoDriver = SDL_GetCurrentVideoDriver();
    logInfo("Video driver: %s", videoDriver ? fromStringz( videoDriver ) : "unknown");

    // SDL2 linked version.
    char[256] buffer = void;
    SDL_version ver = void;
    SDL_GetVersion(&ver);
    logInfo("SDL2: %s", sformat(buffer, "%d.%d.%d", ver.major, ver.minor, ver.patch));

    // SDL2_ttf linked version.
    const(SDL_version)* ttfVer = TTF_Linked_Version();
    if (ttfVer)
        logInfo("SDL2_ttf: %s", sformat(buffer, "%d.%d.%d", ttfVer.major, ttfVer.minor, ttfVer.patch));

    // SDL2_image linked version.
    const(SDL_version)* imgVer = IMG_Linked_Version();
    if (imgVer)
        logInfo("SDL2_image: %s", sformat(buffer, "%d.%d.%d", imgVer.major, imgVer.minor, imgVer.patch));

    // Number of available video drivers.
    int numDrivers = SDL_GetNumVideoDrivers();
    if (numDrivers > 1)
    {
        size_t pos;
        foreach (int i; 0 .. numDrivers)
        {
            const(char)* name = SDL_GetVideoDriver(i);
            if (name is null)
                continue;
            const(char)[] nameSlice = fromStringz(name);
            if (pos > 0 && pos + 2 + nameSlice.length < buffer.length)
            {
                buffer[pos .. pos + 2] = ", ";
                pos += 2;
            }
            if (pos + nameSlice.length < buffer.length)
            {
                buffer[pos .. pos + nameSlice.length] = nameSlice;
                pos += nameSlice.length;
            }
        }
        logInfo("Available video drivers: %s", buffer[0 .. pos]);
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
    // NOTE: zero-init is optionally good, but we don't use any other fields...
    SDL_Event ev = void;
    ev.type = networkEventType;
    SDL_PushEvent(&ev);
    return interval;
}

/// Text measurement callbacks for ddui (must be extern(C)).
extern(C) int text_width(mu_Font font, const(char)* text, int len)
{
    if (len == -1)
        len = cast(int) strlen(text);
    return r_get_text_width(text, len);
}

extern(C) int text_height(mu_Font font)
{
    return r_get_text_height();
}

/// Clipboard callbacks for ddui (must be extern(C)).
///
/// ddui only reads the returned pointer during the call, but SDL hands us an
/// allocation we have to free, so the text is copied into a static buffer.
extern(C) const(char)* get_clipboard(mu_Context* ctx)
{
    static char[4096] clip;
    char* text = SDL_GetClipboardText();
    if (text is null)
        return null;
    size_t n = strlen(text);
    if (n >= clip.sizeof)
        n = mu_utf8_trim(text, clip.sizeof - 1);
    memcpy(clip.ptr, text, n);
    clip[n] = '\0';
    SDL_free(text);
    return clip.ptr;
}

extern(C) void set_clipboard(mu_Context* ctx, const(char)* text)
{
    SDL_SetClipboardText(text);
}

/// Tear down the current connection and establish a new one using
/// the host/port/secret from the Settings tab.
private void doReconnect()
{
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

    ushort port = void;
    try port = portStr.to!ushort;
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
    // Pair state is unknown until the new connection replays a dap_status
    // snapshot. Reset here (initiation) rather than on the `connected`
    // transition so we can't race-clobber the freshly arrived snapshot.
    appState.dapPairState = AppState.DapPairState.unknown;
    appState.dapStatus = "";
    string clientCert = cast(string) appState.settingsTlsClientCert[0 .. strlen(appState.settingsTlsClientCert.ptr)].idup;
    string clientKey  = cast(string) appState.settingsTlsClientKey[0 .. strlen(appState.settingsTlsClientKey.ptr)].idup;
    conn = new ServerConnection(host, port, secret,
        appState.settingsTls != 0, appState.settingsTlsSkipVerify != 0,
        clientCert, clientKey);
    long sinceId = saved.lastEventId;
    netThread = new Thread({
        conn.connectAndRun(msgQueue, networkEventType, sinceId);
    });
    netThread.isDaemon = true;
    netThread.start();
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
    Settings s;
    s.host = cast(string) appState.settingsHost[0 .. strlen(appState.settingsHost.ptr)].idup;
    s.port = {
        string p = cast(string) appState.settingsPort[0 .. strlen(appState.settingsPort.ptr)].idup;
        try return p.to!ushort;
        catch (Exception) return cast(ushort) 9700;
    }();
    s.secret = cast(string) appState.settingsSecret[0 .. strlen(appState.settingsSecret.ptr)].idup;
    s.useTls = appState.settingsTls != 0;
    s.tlsSkipVerify = appState.settingsTlsSkipVerify != 0;
    s.tlsClientCert = cast(string) appState.settingsTlsClientCert[0 .. strlen(appState.settingsTlsClientCert.ptr)].idup;
    s.tlsClientKey  = cast(string) appState.settingsTlsClientKey[0 .. strlen(appState.settingsTlsClientKey.ptr)].idup;
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
    s.feedShowSelfEvents = appState.feedShowSelfEvents != 0;

    // Picture metadata setting (int -> bool).
    s.insertPictureMetadata = appState.insertPictureMetadata != 0;

    // Preserve the runtime-tracked event cursor; the Settings tab
    // doesn't expose it and we don't want to reset it to 0.
    s.lastEventId = saved.lastEventId;

    saved = s; // Update module-level copy used by notification dispatch.
    saveSettings(s);
}

/// Read the first dropped file, validate it for the current inventory
/// section, and send it to the server for upload.
private void doInventoryUpload()
{
    import std.base64 : Base64;
    import std.file : read;

    if (conn is null || appState.connected == false || appState.invUploadInFlight)
        return;
    if (appState.invSection == InvSection.items)
        return; // nothing uploadable there
    if (appState.droppedFiles.length == 0)
    {
        appState.invUploadStatus = "Drop a PNG onto the window first";
        return;
    }

    string path = appState.droppedFiles[0];
    ubyte[] data;
    try
        data = cast(ubyte[]) read(path);
    catch (Exception e)
    {
        appState.invUploadStatus = "Cannot read file: " ~ e.msg;
        return;
    }

    string err = validateUploadPNG(data, appState.invSection);
    if (err)
    {
        appState.invUploadStatus = err;
        return;
    }

    string b64 = cast(string) Base64.encode(data);
    if (appState.invSection == InvSection.prints)
    {
        string note = cast(string) fromStringz(appState.invUploadNote.ptr).idup;
        // Attach the current world when known (log watcher location).
        string worldId;
        ptrdiff_t colon = indexOf(appState.currentLocation, ':');
        if (colon > 0)
            worldId = appState.currentLocation[0 .. colon];
        conn.sendUploadPrint(b64, note, worldId, "");
    }
    else
    {
        conn.sendUploadImage(invSectionTag(appState.invSection), b64);
    }
    appState.invUploadInFlight = true;
    appState.invUploadStatus = "Uploading...";
}

/// Validate an image for VRChat upload: PNG only, 10MB and 2000x2000 max,
/// square for stickers and emoji. Returns an error message, or null when
/// acceptable. Mirrors the server-side check so most rejections happen
/// before base64-encoding megabytes onto the wire.
private string validateUploadPNG(const(ubyte)[] data, InvSection section)
{
    static immutable ubyte[8] pngSignature =
        [0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A];

    if (data.length > 10 * 1024 * 1024)
        return "File too large (max 10MB)";
    if (data.length < 24 || data[0 .. 8] != pngSignature)
        return "Not a PNG file (VRChat only accepts PNG)";
    // IHDR is always the first chunk: width/height at offsets 16/20.
    uint width  = (data[16] << 24) | (data[17] << 16) | (data[18] << 8) | data[19];
    uint height = (data[20] << 24) | (data[21] << 16) | (data[22] << 8) | data[23];
    if (width == 0 || height == 0 || width > 2000 || height > 2000)
        return format("Image is %dx%d (max 2000x2000)", width, height);
    if ((section == InvSection.stickers || section == InvSection.emoji) && width != height)
        return "Stickers and emoji must be square";
    return null;
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
///
/// Keypad and non-printable SDL keycodes have bit 30 set (e.g. SDLK_LEFT is
/// 0x4000004f), so masking to a byte lands them in the upper-ASCII range where
/// SDL has no printable keys, and they cannot collide with the letter keys.
private immutable ushort[256] keyMap = () {
    ushort[256] m;
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
    // Caret movement and forward deletion.
    m[SDLK_LEFT      & 0xff] = MU_KEY_LEFT;
    m[SDLK_RIGHT     & 0xff] = MU_KEY_RIGHT;
    m[SDLK_HOME      & 0xff] = MU_KEY_HOME;
    m[SDLK_END       & 0xff] = MU_KEY_END;
    m[SDLK_DELETE    & 0xff] = MU_KEY_DELETE;
    // Clipboard shortcuts: ddui only acts on these while Ctrl is held, so
    // mapping the bare letters is safe (typing them still inserts text).
    m[SDLK_c         & 0xff] = MU_KEY_COPY;
    m[SDLK_x         & 0xff] = MU_KEY_CUT;
    m[SDLK_v         & 0xff] = MU_KEY_PASTE;
    m[SDLK_a         & 0xff] = MU_KEY_SELECTALL;
    return m;
}();
