/// System tray icon with a show/hide and quit menu. Opt-in.
///
/// Menu presses come back as SDL events so the main loop handles them with
/// everything else. On Linux SDL loads GTK and an AppIndicator library at
/// runtime, so creating the tray can fail on a working system.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module client.tray;

import std.string : fromStringz;

import bindbc.sdl;
import ddlogger;

/// Menu actions, carried in the pushed event's `user.code`.
enum TrayAction : int
{
    toggle = 1, /// Show or hide the window
    quit,       /// Quit vrcd
}

/// Whether the tray needs the event loop to wake up on its own: true on
/// Linux, where SDL runs it from GTK, false on Windows, where its menu is a
/// window message.
version (Windows)
    enum bool trayNeedsPolling = false;
else
    enum bool trayNeedsPolling = true;

private __gshared SDL_Tray *tray;
private __gshared SDL_TrayEntry *toggleEntry;
private __gshared uint trayEventType;

/// Create the tray icon showing `icon` (may be null), pushing menu presses
/// as `eventType` events. Returns the SDL error, or null on success.
string trayCreate(SDL_Surface *icon, uint eventType, bool windowVisible)
{
    if (tray)
        return null;

    tray = SDL_CreateTray(icon, "vrcd");
    if (tray is null)
    {
        string err = fromStringz(SDL_GetError()).idup;
        logWarn("Tray icon unavailable: %s", err);
        return err.length ? err : "unavailable";
    }
    trayEventType = eventType;

    SDL_TrayMenu *menu = SDL_CreateTrayMenu(tray);
    toggleEntry = SDL_InsertTrayEntryAt(menu, -1,
        windowVisible ? "Hide vrcd" : "Show vrcd", SDL_TRAYENTRY_BUTTON);
    SDL_SetTrayEntryCallback(toggleEntry, &onEntry, cast(void*) TrayAction.toggle);
    SDL_InsertTrayEntryAt(menu, -1, null, SDL_TRAYENTRY_BUTTON); // separator
    SDL_TrayEntry *quitEntry = SDL_InsertTrayEntryAt(menu, -1, "Quit", SDL_TRAYENTRY_BUTTON);
    SDL_SetTrayEntryCallback(quitEntry, &onEntry, cast(void*) TrayAction.quit);

    logInfo("Tray icon created");
    return null;
}

/// Remove the tray icon, if any.
void trayDestroy()
{
    if (tray is null)
        return;
    SDL_DestroyTray(tray);
    tray = null;
    toggleEntry = null;
    logInfo("Tray icon removed");
}

/// Whether the tray icon exists.
bool trayActive()
{
    return tray !is null;
}

/// Relabel the show/hide entry for a window that is now `visible`.
void traySetWindowVisible(bool visible)
{
    if (toggleEntry)
        SDL_SetTrayEntryLabel(toggleEntry, visible ? "Hide vrcd" : "Show vrcd");
}

/// Push the entry's action to the main loop. Runs on the main thread.
private extern(C) void onEntry(void *userData, SDL_TrayEntry *entry) nothrow
{
    SDL_Event ev;
    ev.type = trayEventType;
    ev.user.code = cast(int) cast(size_t) userData;
    SDL_PushEvent(&ev);
}
