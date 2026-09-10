/// UI components and layout
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module client.ui;

import core.stdc.string : memchr;
import core.time : MonoTime;
import std.string : toStringz;
import std.uni : toLower;
import std.format : sformat;
import std.utf : stride, UTFException;
import std.json : JSONValue;

import ddui;
import vrcd.events : prettyPlatform, prettyNotifType, shortAvatarId;
import vrcd.notifications : NotificationInfo, NotificationResponse, prettyResponseLabel;

import client.notifications : notifyEventLabels, feedEventLabels, feedFilterSections,
    feedEventIndex, prettyEventType;
import client.imagecache : imageKey, getIconId;
import client.renderer : window_width, window_height;
import client.connection : PROTOCOL_MODERATION;
import client.gui : wasClick, requestRepaint;
import client.state;
import client.stream : tlsAvailable;
import client.utils : openFolder, openBrowser;

/// Active tab selection.
enum Tab { feed, online, notifications, inventory, tools, settings }
private Tab activeTab = Tab.feed;

// Feed filter state
private char[128] searchBuf = '\0';
private size_t searchLen;

// Feed pagination state
private int feedPage;            // 0-indexed current page
private string lastSearchQuery;  // track changes to reset page

/// Set a transient status bar message that expires after `ms` milliseconds.
/// Used for user-action feedback (copy, save, refresh, etc.).
private void setStatusFlash(AppState* state, string msg, int ms = 1500)
{
    import core.time : dur;
    state.statusFlash = msg;
    state.statusFlashEnd = MonoTime.currTime + dur!"msecs"(ms);
}

/// Whether the given tab is currently showing a subpage (a detail or nested
/// view) rather than its root list. Drives the sticky Back button in the
/// header so navigation is reachable no matter how far a list is scrolled.
private bool tabInSubpage(AppState* state, Tab tab)
{
    final switch (tab) with (Tab)
    {
        case feed:          return state.feedDetailOpen;
        case online:        return state.selectedFriend !is null;
        case inventory:     return state.invDetailOpen;
        case tools:         return state.toolsPage != ToolsPage.main;
        case notifications:
        case settings:      return false;
    }
}

/// Return the active tab's subpage to its root list. Shared by the sticky
/// header Back button and by re-tapping an already-active tab.
private void resetTabSubpage(AppState* state, Tab tab)
{
    final switch (tab) with (Tab)
    {
        case feed:          state.feedDetailOpen = false;    break;
        case online:        state.selectedFriend = null;     break;
        case inventory:     state.invDetailOpen = false;     break;
        case tools:         state.toolsPage = ToolsPage.main; break;
        case notifications:
        case settings:      break;
    }
    state.armedConfirm = ArmedConfirm.init;
    requestRepaint();
}

/// Handle a "go back" gesture (Escape key, mouse back button) by popping the
/// active tab's subpage to its root list, mirroring the sticky header Back
/// button. Returns true if navigation occurred. A no-op while a modal auth
/// dialog is up so the gesture doesn't reach through it, and when the active
/// tab is already at its root.
bool navigateBack(AppState* state)
{
    if (state.authDialogKind != AppState.AuthDialogKind.none)
        return false;
    if (tabInSubpage(state, activeTab) == false)
        return false;
    resetTabSubpage(state, activeTab);
    return true;
}

/// Scroll a tab's root list panel back to the top. Used when re-tapping the
/// active tab. The container id matches the panel name because both are hashed
/// at the same id-stack depth (inside the "Main" window, outside any panel).
private void scrollTabToTop(mu_Context* ctx, Tab tab)
{
    string name;
    final switch (tab) with (Tab)
    {
        case feed:          name = "FeedPanel";          break;
        case online:        name = "FriendsPanel";       break;
        case notifications: name = "NotificationsPanel"; break;
        case inventory:     name = "InventoryPanel";     break;
        case tools:         name = "ToolsPanel";         break;
        case settings:      name = "SettingsPanel";      break;
    }
    mu_Container* cnt = mu_get_container(ctx, name.ptr, cast(int) name.length);
    if (cnt)
        cnt.scroll.y = 0;
}

/// Draw the full-window UI layout.
void drawFullWindow(mu_Context* ctx, AppState* state, int scrollDelta)
{
    // When the filter popup is open it consumes scroll input; the main
    // window's tab panels should not also move.
    int tabScroll = filterPopupOpen ? 0 : scrollDelta;

    enum opt = MU_OPT_NOTITLE | MU_OPT_NORESIZE | MU_OPT_NOCLOSE | MU_OPT_NOFRAME | MU_OPT_NOSCROLL;
    if (mu_begin_window_ex(ctx, "Main", mu_Rect(0, 0, window_width, window_height), opt))
    {
        mu_Container* win = mu_get_current_container(ctx);
        win.rect = mu_Rect(0, 0, window_width, window_height);

        // Tab bar
        drawTabBar(ctx, state);

        // Content area (fills remaining space minus status bar)
        static immutable int[1] fullCol = [-1];

        // Sticky Back: while a tab shows a subpage, keep a full-width Back
        // button in the always-visible header. Deep scrolling in a list can
        // never bury navigation, and re-tapping the tab also pops the subpage.
        if (tabInSubpage(state, activeTab))
        {
            mu_layout_row(ctx, 1, fullCol.ptr, 40);
            if (clickButton(ctx, "< Back"))
                resetTabSubpage(state, activeTab);
        }

        if (activeTab == Tab.feed && state.feedDetailOpen)
        {
            // Feed detail: just the sticky Back plus the detail panel, no
            // search bar or pagination chrome.
            mu_layout_row(ctx, 1, fullCol.ptr, -25);
            drawFeedTab(ctx, state, tabScroll);
        }
        else if (activeTab == Tab.feed)
        {
            // Search bar + filter button get their own row.
            drawFeedSearchBar(ctx);

            // Feed: panel fills remaining space minus pagination row, status bar,
            // and the inter-row spacing inserted between pagination and status
            // (otherwise the status bar lands one spacing lower than on other tabs).
            mu_layout_row(ctx, 1, fullCol.ptr, -(50 + 25 + ctx.style.spacing));
            drawFeedTab(ctx, state, tabScroll);

            // Pagination row (50px).
            mu_layout_row(ctx, 1, fullCol.ptr, 50);
            drawFeedPagination(ctx, state);
        }
        else
        {
            // Other tabs: panel fills remaining space minus status bar.
            mu_layout_row(ctx, 1, fullCol.ptr, -25);
            final switch (activeTab)
            {
                case Tab.feed:          break; // handled above
                case Tab.online:        drawOnlineTab(ctx, state, tabScroll);        break;
                case Tab.notifications: drawNotificationsTab(ctx, state, tabScroll); break;
                case Tab.inventory:     drawInventoryTab(ctx, state, tabScroll);     break;
                case Tab.tools:         drawToolsTab(ctx, state, tabScroll);         break;
                case Tab.settings:      drawSettingsTab(ctx, state, tabScroll);      break;
            }
        }

        // Status bar
        mu_layout_row(ctx, 1, fullCol.ptr, 25);
        drawStatusBar(ctx, state);

        mu_end_window(ctx);
    }

    // Filter popup must be outside the main window to render on top.
    drawFeedFilterPopup(ctx, state, scrollDelta);

    // Self-status popup (anchored under the status circle in the Online tab).
    drawSelfStatusPopup(ctx, state);

    // Auth delegation dialog (modal, on top of everything).
    drawAuthDialog(ctx, state);
}

/// Draw the tab bar with large VR-friendly buttons.
private void drawTabBar(mu_Context* ctx, AppState* state)
{
    // NOTE: Take padding into the calculation to make settings button slightly more equal
    //       With my testing, this makes 187px for first four and 186px wide for SETTINGS
    enum BUTTONS = 6;
    enum PADDING = 4; // default style has margin=4
    int tabWidth = (window_width - (PADDING * (BUTTONS+1))) / BUTTONS;
    int[BUTTONS] tabCols = [tabWidth, tabWidth, tabWidth, tabWidth, tabWidth, -1];
    mu_layout_row(ctx, BUTTONS, tabCols.ptr, 60);

    // Highlight active tab by drawing a colored background.
    drawTabButton(ctx, state, "FEED",          Tab.feed);
    drawTabButton(ctx, state, "ONLINE",        Tab.online);
    drawTabButton(ctx, state, "INBOX",         Tab.notifications);
    drawTabButton(ctx, state, "STUFF",         Tab.inventory);
    drawTabButton(ctx, state, "TOOLS",         Tab.tools);
    drawTabButton(ctx, state, "SETTINGS",      Tab.settings);
}

/// Draw a single tab button, highlighted if active.
private void drawTabButton(mu_Context* ctx, AppState* state, string label, Tab tab)
{
    if (activeTab == tab)
    {
        // Draw highlight behind the button area.
        mu_Rect r = mu_layout_next(ctx);
        mu_draw_rect(ctx, r, mu_Color(60, 80, 120, 255));
        mu_draw_control_text(ctx, label, r, MU_COLOR_TEXT, MU_OPT_ALIGNCENTER);

        // Make it clickable.
        mu_Id id = mu_get_id(ctx, &tab, tab.sizeof);
        mu_update_control(ctx, id, r, 0);
        if (ctx.mouse_pressed == MU_MOUSE_LEFT && ctx.focus == id)
        {
            // Re-tapping the active tab pops any subpage and scrolls its list
            // back to the top (the familiar tab-bar convention).
            resetTabSubpage(state, tab);
            scrollTabToTop(ctx, tab);
        }
    }
    else
    {
        if (mu_button(ctx, label))
            activeTab = tab;
    }
}

bool filterPopupOpen;

/// Compute the filter popup rect from current window dimensions.
/// Shared between drawFeedFilterPopup and the event loop's click-outside
/// dismissal check.
mu_Rect filterPopupRect()
{
    enum int maxW = 560;
    enum int margin = 40;
    int popupW = window_width - margin * 2;
    if (popupW > maxW)
        popupW = maxW;
    int popupH = window_height - margin * 2;
    int popupX = (window_width - popupW) / 2;
    int popupY = margin;
    return mu_Rect(popupX, popupY, popupW, popupH);
}

/// Whether (x, y) falls inside the filter popup rect.
bool filterPopupContains(int x, int y)
{
    mu_Rect r = filterPopupRect();
    return x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h;
}

/// Draw the feed search bar (called from main window layout).
private void drawFeedSearchBar(mu_Context* ctx)
{
    int[2] searchCols = [60, -1];
    mu_layout_row(ctx, 2, searchCols.ptr, 30);
    if (mu_button(ctx, "Filter"))
        filterPopupOpen = !filterPopupOpen;
    int res = mu_textbox(ctx, searchBuf.ptr, cast(int) searchBuf.length, cast(int) searchLen);
    if (res & MU_RES_CHANGE)
    {
        const(char)* p = cast(const(char)*) memchr(searchBuf.ptr, '\0', searchBuf.length);
        searchLen = p ? (p - searchBuf.ptr) : searchBuf.length;
    }
}

/// Draw the filter popup as a standalone window.
///
/// Layout: a scroll panel containing sections of large checkbox rows
/// (VR-friendly hit targets) plus a sticky bottom bar with bulk actions.
private void drawFeedFilterPopup(mu_Context* ctx, AppState* state, int scrollDelta)
{
    if (filterPopupOpen == false)
        return;

    mu_Rect rect = filterPopupRect();

    if (mu_begin_window_ex(ctx, "Filters", rect,
        MU_OPT_NOTITLE | MU_OPT_NORESIZE | MU_OPT_NOSCROLL))
    {
        // Keep popup above the full-screen main window so it receives input,
        // and pin its rect each frame so it tracks window resizes.
        mu_Container* pc = mu_get_current_container(ctx);
        pc.rect = rect;
        mu_bring_to_front(ctx, pc);

        enum int rowH = 36;       // big touch target for VR
        enum int btnRowH = 50;    // sticky bottom bar
        static immutable int[1] fullCol = [-1];

        bool changed;

        // Scroll region: fills the popup minus the sticky bottom bar
        // (and the inter-row spacing the layout inserts between them).
        mu_layout_row(ctx, 1, fullCol.ptr, -(btnRowH + ctx.style.spacing));
        mu_begin_panel(ctx, "FilterScroll");
        applyScroll(ctx, scrollDelta);

        // Event Types, grouped by topic
        foreach (size_t s, ref section; feedFilterSections)
        {
            if (s > 0)
                spacer(ctx, 8);
            sectionHeader(ctx, section.title);

            // "Show self events" is a master toggle that gates every
            // entry in the Self & Avatar section, so it lives at the top
            // of that group instead of in its own ad-hoc section.
            if (section.title == "Self & Avatar")
            {
                mu_layout_row(ctx, 1, fullCol.ptr, rowH);
                int prevShowSelf = state.feedShowSelfEvents;
                mu_checkbox(ctx, "Show self events", &state.feedShowSelfEvents);
                if (state.feedShowSelfEvents != prevShowSelf)
                {
                    feedPage = 0;
                    changed = true;
                }
            }

            foreach (size_t idx; section.indices)
            {
                mu_layout_row(ctx, 1, fullCol.ptr, rowH);
                int prev = state.feedEventVisible[idx];
                mu_checkbox(ctx, feedEventLabels[idx], &state.feedEventVisible[idx]);
                if (state.feedEventVisible[idx] != prev)
                {
                    feedPage = 0;
                    changed = true;
                }
            }
        }

        mu_end_panel(ctx);

        // Sticky bottom bar
        static immutable int[3] btnCols = [-2, -2, -1];
        mu_layout_row(ctx, 3, btnCols.ptr, btnRowH);
        if (mu_button(ctx, "All On"))
        {
            state.feedEventVisible[] = 1;
            feedPage = 0;
            changed = true;
        }
        if (mu_button(ctx, "All Off"))
        {
            state.feedEventVisible[] = 0;
            feedPage = 0;
            changed = true;
        }
        if (mu_button(ctx, "Close"))
            filterPopupOpen = false;

        if (changed)
            state.saveSettingsRequested = true;

        mu_end_window(ctx);
    }
}

/// Feed tab: scrollable list of events (newest first).
private void drawFeedTab(mu_Context* ctx, AppState* state, int scrollDelta)
{
    if (state.feedDetailOpen)
    {
        drawFeedDetail(ctx, state, scrollDelta);
        return;
    }

    // Column widths: date, type, user, detail (detail fills remaining space).
    static immutable int[1] fullCol = [-1];
    enum lineColor = mu_Color(50, 50, 60, 255);
    enum hoverColor = mu_Color(60, 60, 80, 255);

    mu_begin_panel(ctx, "FeedPanel");

    // Apply mouse wheel scroll directly to this panel.
    applyScroll(ctx, scrollDelta);

    // Column header. Positioned manually (rather than via mu_layout_row's
    // per-column widths) so it lines up exactly with the row cells below,
    // which are also drawn manually and packed with no inter-column
    // spacing. Using mu_layout_row here would insert style.spacing between
    // columns, drifting further out of alignment with each column.
    {
        mu_layout_row(ctx, 1, fullCol.ptr, 0);
        mu_Rect headerRect = mu_layout_next(ctx);
        int x = headerRect.x + 8; // leave gap matching the accent strip below
        int y = headerRect.y;
        int h = headerRect.h;

        mu_draw_control_text(ctx, "Date", mu_Rect(x, y, 150, h), MU_COLOR_TEXT, 0);
        mu_draw_rect(ctx, mu_Rect(x + 149, y, 1, h), lineColor);
        x += 150;

        mu_draw_control_text(ctx, "Type", mu_Rect(x, y, 120, h), MU_COLOR_TEXT, 0);
        mu_draw_rect(ctx, mu_Rect(x + 119, y, 1, h), lineColor);
        x += 120;

        mu_draw_control_text(ctx, "User", mu_Rect(x, y, 150, h), MU_COLOR_TEXT, 0);
        mu_draw_rect(ctx, mu_Rect(x + 149, y, 1, h), lineColor);
        x += 150;

        mu_draw_control_text(ctx, "Detail", mu_Rect(x, y, headerRect.w - (x - headerRect.x), h), MU_COLOR_TEXT, 0);
    }

    // Horizontal separator under header.
    mu_layout_row(ctx, 1, fullCol.ptr, 1);
    mu_draw_rect(ctx, mu_layout_next(ctx), lineColor);

    // Get search query; reset page if it changed.
    string searchQuery = searchStr();
    if (searchQuery != lastSearchQuery)
    {
        feedPage = 0;
        lastSearchQuery = searchQuery;
    }

    if (state.feedEntries.length == 0)
    {
        mu_layout_row(ctx, 1, fullCol.ptr, 0);
        mu_label(ctx, "No events yet.");

        // Empty-state CTA: big button occupies the "would-be" event area,
        // directly addressing the "restart with zero notifs" scenario.
        drawFetchOlderRow(ctx, state, 60, true);
    }
    else
    {
        // Count filtered entries and render only the current page.
        int filteredCount;
        int skipStart = feedPage * cast(int) state.feedPageSize;
        int skipEnd = skipStart + cast(int) state.feedPageSize;
        bool anyVisible;

        // Reverse: the feed is stored oldest first and read newest first.
        foreach_reverse (ref FeedEntry entry; state.feedEntries)
        {
            if (passesFilter(entry, searchQuery, state) == false)
                continue;

            if (filteredCount >= skipStart && filteredCount < skipEnd)
            {
                anyVisible = true;

                // Single full-width row as a clickable area.
                mu_layout_row(ctx, 1, fullCol.ptr, 0);
                mu_Rect rowRect = mu_layout_next(ctx);

                // Check hover manually (accounts for panel clip rect).
                bool mouseOver = mu_mouse_over(ctx, rowRect) != 0;

                // Highlight on hover.
                if (mouseOver && !ctx.mouse_down)
                    mu_draw_rect(ctx, rowRect, hoverColor);

                // Click to open detail (only on mouseup, not during drag scroll).
                if (wasClick && mouseOver)
                {
                    state.selectedFeedEntry = entry;
                    state.feedDetailOpen = true;
                }

                // Source accent strip on the left edge.
                mu_draw_rect(ctx, mu_Rect(rowRect.x, rowRect.y, 4, rowRect.h), sourceColor(entry.source));

                // Draw cell text at column offsets within the row rect.
                int x = rowRect.x + 8; // leave gap after accent strip
                int h = rowRect.h;
                int y = rowRect.y;

                mu_draw_control_text(ctx, entry.receivedAt, mu_Rect(x, y, 150, h), MU_COLOR_TEXT, 0);
                mu_draw_rect(ctx, mu_Rect(x + 149, y, 1, h), lineColor);
                x += 150;

                mu_draw_control_text(ctx, prettyEventType(entry.eventType), mu_Rect(x, y, 120, h), MU_COLOR_TEXT, 0);
                mu_draw_rect(ctx, mu_Rect(x + 119, y, 1, h), lineColor);
                x += 120;

                mu_draw_control_text(ctx, entry.user, mu_Rect(x, y, 150, h), MU_COLOR_TEXT, 0);
                mu_draw_rect(ctx, mu_Rect(x + 149, y, 1, h), lineColor);
                x += 150;

                int detailX = x;
                int detailW = rowRect.w - (x - rowRect.x);
                string detailText = entry.detail;
                if (entry.eventType == "friend-update" && entry.detail.length > 0)
                {
                    enum int SWATCH = 14;
                    enum int SWATCH_MARGIN = 4;
                    mu_draw_rect(ctx, mu_Rect(detailX + SWATCH_MARGIN, y + (h - SWATCH) / 2, SWATCH, SWATCH),
                        statusColor(entry.detail));
                    detailX += SWATCH_MARGIN + SWATCH + 4;
                    detailW -= SWATCH_MARGIN + SWATCH + 4;
                    detailText = prettyStatus(entry.detail);
                }
                mu_draw_control_text(ctx, detailText, mu_Rect(detailX, y, detailW, h), MU_COLOR_TEXT, 0);

                // Row separator.
                mu_layout_row(ctx, 1, fullCol.ptr, 1);
                mu_draw_rect(ctx, mu_layout_next(ctx), lineColor);
            }
            filteredCount++;
        }

        // Clamp page if filters changed and we're past the end.
        int totalPages = (filteredCount + cast(int) state.feedPageSize - 1) / cast(int) state.feedPageSize;
        if (totalPages < 1) totalPages = 1;
        if (feedPage >= totalPages)
            feedPage = totalPages - 1;

        if (anyVisible == false)
        {
            mu_layout_row(ctx, 1, fullCol.ptr, 0);
            mu_label(ctx, filteredCount > 0
                ? "No matching events on this page."
                : "No events match the current filters.");
        }

        // On the last page (filters hiding everything counts as the last page,
        // since totalPages clamps to 1), show how many of the loaded events the
        // filters let through and offer the fetch-older sentinel. Drawing the
        // row unconditionally here is deliberate: a heavily filtered view
        // ("0 of N shown") would otherwise hide the fetch button entirely and
        // leave no way to pull more history to look through.
        if (feedPage >= totalPages - 1)
        {
            drawFilterSummary(ctx, filteredCount, cast(int) state.feedEntries.length);
            drawFetchOlderRow(ctx, state, 45, false);
        }
    }

    mu_end_panel(ctx);
}

/// Feed event detail view.
private void drawFeedDetail(mu_Context* ctx, AppState* state, int scrollDelta)
{
    import std.json : parseJSON, JSONValue, JSONType;

    static immutable int[1] fullCol = [-1];
    static immutable int[2] labelValCols = [120, -1];
    enum lineColor = mu_Color(50, 50, 60, 255);

    FeedEntry* e = &state.selectedFeedEntry;

    // Parse the raw content once (re-parsed each frame, like the rest of this
    // immediate-mode view). Reused for the world-link button and the scalar
    // content listing below.
    JSONValue content;
    bool haveContent;
    if (e.rawContent.length > 0)
    {
        try
        {
            content = parseJSON(e.rawContent);
            if (content.type == JSONType.string)
                content = parseJSON(content.str);
            haveContent = content.type == JSONType.object;
        }
        catch (Exception) {}
    }

    mu_begin_panel(ctx, "FeedDetailPanel");

    applyScroll(ctx, scrollDelta);

    // Navigation back to the list is the sticky header Back button.

    // Event type as header.
    mu_layout_row(ctx, 1, fullCol.ptr, 0);
    mu_label(ctx, prettyEventType(e.eventType));

    // Separator.
    mu_layout_row(ctx, 1, fullCol.ptr, 1);
    mu_draw_rect(ctx, mu_layout_next(ctx), lineColor);

    // Summary fields.
    if (e.receivedAt.length > 0)
    {
        mu_layout_row(ctx, 2, labelValCols.ptr, 0);
        mu_label(ctx, "Date");
        clickableValue(ctx, state, e.receivedAt);
    }

    if (e.user.length > 0)
    {
        mu_layout_row(ctx, 2, labelValCols.ptr, 0);
        mu_label(ctx, "User");
        clickableValue(ctx, state, e.user);
    }

    if (e.detail.length > 0)
    {
        mu_layout_row(ctx, 2, labelValCols.ptr, 0);
        mu_label(ctx, "Detail");
        clickableValue(ctx, state, e.detail);
    }

    if (e.id != 0)
    {
        mu_layout_row(ctx, 2, labelValCols.ptr, 0);
        mu_label(ctx, "Event ID");

        import std.conv : to;
        clickableValue(ctx, state, e.id.to!string);
    }

    // Additional content
    if (haveContent)
    {
        int half = mu_get_current_container(ctx).body_.w / 2;
        
        // Open the world in the VRChat website, for entries that carry a world id.
        string worldId = extractWorldId(content);
        // Open user in VRChat website
        string userId = extractUserId(content);
        
        int rows;
        if (worldId.length > 0) rows++;
        if (userId.length > 0) rows++;
        
        if (rows)
        {
            int[2] halfrow = [ half, -1 ];
            mu_layout_row(ctx, rows, rows == 1 ? fullCol.ptr : halfrow.ptr, 40);
            
            if (worldId.length > 0)
                if (clickButton(ctx, "Browse World on VRChat Website"))
                    openBrowser("https://vrchat.com/home/world/" ~ worldId ~ "/info");
            
            if (userId.length > 0)
                if (clickButton(ctx, "Browse User on VRChat Website"))
                    openBrowser("https://vrchat.com/home/user/" ~ userId);
        }
        
        // Raw content fields (parsed from JSON).
        mu_layout_row(ctx, 1, fullCol.ptr, 1);
        mu_draw_rect(ctx, mu_layout_next(ctx), lineColor);

        mu_layout_row(ctx, 1, fullCol.ptr, 0);
        mu_label(ctx, "Content");

        foreach (string key, JSONValue val; content.objectNoRef)
        {
            // Skip nested objects/arrays, show scalar fields.
            if (val.type == JSONType.object || val.type == JSONType.array)
                continue;

            string valStr = val.type == JSONType.string ? val.str : val.toString();
            if (valStr.length == 0)
                continue;

            mu_layout_row(ctx, 2, labelValCols.ptr, 0);
            mu_label(ctx, key);
            clickableValue(ctx, state, valStr);
        }
    }

    mu_end_panel(ctx);
}

/// Extract a bare VRChat world id ("wrld_...") from a feed entry's parsed
/// content, if any. Location/instance fields carry the id with an instance
/// suffix ("wrld_...:12345~region(us)"); only the world id portion is kept.
/// Returns null when no world id is present.
private string extractWorldId(ref JSONValue c) // TODO: Needs unittests
{
    import std.json : JSONValue, JSONType;
    import std.string : indexOf;

    static string fromValue(const(JSONValue)* v)
    {
        if (v is null || v.type != JSONType.string)
            return null;

        string s = v.str;
        ptrdiff_t colon = s.indexOf(':');   // trim instance suffix, if any
        if (colon >= 0)
            s = s[0 .. colon];

        return s.length > 5 && s[0 .. 5] == "wrld_" ? s : null;
    }

    if (string id = fromValue("worldId" in c))
        return id;
    if (const(JSONValue)* w = "world" in c)
        if (w.type == JSONType.object)
            if (string id = fromValue("id" in *w))
                return id;
    if (string id = fromValue("location" in c))
        return id;
    if (string id = fromValue("instanceId" in c))
        return id;

    return null;
}

// Extract User ID from content
private string extractUserId(ref JSONValue c) // TODO: Needs unittests
{
    import std.json : JSONValue, JSONType;
    import std.string : indexOf;

    // .userId
    if (const(JSONValue) *juserId = "userId" in c)
        return juserId.str;
    // .user.id
    if (const(JSONValue) *juser = "user" in c)
        if (const(JSONValue) *jid = "id" in c)
            return jid.str;

    return null;
}

/// Right-aligned caption showing how many of the loaded events pass the
/// current filters. Sits above the fetch-older row so it's obvious when a
/// heavily filtered view is hiding most of the buffer, which is why "load
/// older" can feel like it does nothing.
private void drawFilterSummary(mu_Context* ctx, int shown, int loaded)
{
    static immutable int[1] fullCol = [-1];

    char[64] buf = void;
    const(char)[] s = sformat(buf, "%d of %d events shown", shown, loaded);

    mu_layout_row(ctx, 1, fullCol.ptr, 0);
    mu_Rect r = mu_layout_next(ctx);
    mu_draw_control_text(ctx, s.ptr, r, MU_COLOR_TEXT, MU_OPT_ALIGNRIGHT, cast(int) s.length);
}

/// Render a full-width "Fetch older events" row as the last item inside
/// the feed panel. Height is configurable so the empty-state can use a
/// larger, more prominent touch target. Disables itself while a request
/// is in flight or when the server has reported no more events.
private void drawFetchOlderRow(mu_Context* ctx, AppState* state, int height, bool emptyState)
{
    static immutable int[1] fullCol = [-1];

    string label;
    bool clickable = true;
    if (state.fetchingOlder)
    {
        label = "Fetching older events...";
        clickable = false;
    }
    else if (state.noOlderEvents)
    {
        label = "No older events on server";
        clickable = false;
    }
    else
    {
        label = emptyState
            ? "Fetch older events from server"
            : "Load older events  v";
    }

    mu_layout_row(ctx, 1, fullCol.ptr, height);
    if (clickable)
    {
        if (mu_button(ctx, label))
            state.fetchOlderRequested = true;
    }
    else
    {
        // Disabled-looking label inside a button-shaped rect.
        mu_Rect r = mu_layout_next(ctx);
        mu_draw_rect(ctx, r, mu_Color(40, 40, 50, 255));
        mu_draw_control_text(ctx, label, r, MU_COLOR_TEXT, MU_OPT_ALIGNCENTER);
    }
}

/// Pagination bar with First, Prev, page numbers, Next, Last buttons.
private void drawFeedPagination(mu_Context* ctx, AppState* state)
{
    string searchQuery = searchStr();

    // Count how many entries pass the filter. Order does not matter here,
    // but the feed is stored oldest first (see AppState.feedEntries).
    int filteredCount;
    foreach (ref FeedEntry entry; state.feedEntries)
    {
        if (passesFilter(entry, searchQuery, state))
            filteredCount++;
    }

    int totalPages = (filteredCount + cast(int) state.feedPageSize - 1) / cast(int) state.feedPageSize;
    if (totalPages < 1) totalPages = 1;
    if (feedPage >= totalPages)
        feedPage = totalPages - 1;
    if (feedPage < 0)
        feedPage = 0;

    mu_begin_panel(ctx, "PaginationPanel");

    int btnWidth = 80;
    mu_Container* panel = mu_get_current_container(ctx);
    int sp = ctx.style.spacing;
    int layoutW = panel.body_.w - ctx.style.padding * 2;

    // Cap page button count to what fits alongside the 4 nav buttons
    // (First, Prev, Next, Last) plus a spacer column.
    int maxPageButtons = 5;
    if (totalPages < maxPageButtons)
        maxPageButtons = totalPages;

    int fit = (layoutW - 4 * btnWidth - 5 * sp) / (btnWidth + sp);
    if (fit < 0) fit = 0;
    if (maxPageButtons > fit) maxPageButtons = fit;

    // If the panel is too narrow for even the 4 nav buttons at full width,
    // shrink them so Next and Last stay on-screen.
    if (layoutW < 4 * btnWidth + 5 * sp)
    {
        int avail = layoutW - 5 * sp;
        if (avail < 4) avail = 4;
        btnWidth = avail / 4;
        if (btnWidth < 10) btnWidth = 10;
    }

    // Centre the page window around current page.
    int pageStart = feedPage - maxPageButtons / 2;
    if (pageStart < 0) pageStart = 0;
    if (pageStart + maxPageButtons > totalPages)
        pageStart = totalPages - maxPageButtons;
    if (pageStart < 0) pageStart = 0;

    // Layout: First, Prev, [page buttons...], spacer, Next, Last
    int numCols = 5 + maxPageButtons; // First + Prev + pages + spacer + Next + Last
    int[10] colWidths;                // max 5 + 5 = 10
    assert(numCols <= colWidths.length);

    int usedWidth = btnWidth * (4 + maxPageButtons) + numCols * sp;
    int spacerWidth = layoutW - usedWidth;
    if (spacerWidth < 0) spacerWidth = 0;

    colWidths[0] = btnWidth; // First
    colWidths[1] = btnWidth; // Prev
    foreach (int i; 0 .. maxPageButtons)
        colWidths[2 + i] = btnWidth;
    colWidths[2 + maxPageButtons] = spacerWidth; // spacer
    colWidths[3 + maxPageButtons] = btnWidth;    // Next
    colWidths[4 + maxPageButtons] = btnWidth;    // Last

    mu_layout_row(ctx, numCols, colWidths.ptr, 40);

    // First
    if (mu_button(ctx, "<< First"))
        feedPage = 0;

    // Prev
    if (mu_button(ctx, "< Prev"))
    {
        if (feedPage > 0) feedPage--;
    }

    // Page number buttons.
    char[8] pageBuf;
    foreach (int i; 0 .. maxPageButtons)
    {
        int page = pageStart + i;
        string s = cast(string) sformat(pageBuf, "%d", page + 1);
        if (page == feedPage)
        {
            // Highlight current page.
            mu_Rect r = mu_layout_next(ctx);
            mu_draw_rect(ctx, r, mu_Color(60, 80, 120, 255));
            mu_draw_control_text(ctx, pageBuf.ptr, r, MU_COLOR_TEXT, MU_OPT_ALIGNCENTER, cast(int) s.length);
            mu_Id id = mu_get_id(ctx, &page, page.sizeof);
            mu_update_control(ctx, id, r, 0);
            if (ctx.mouse_pressed == MU_MOUSE_LEFT && ctx.focus == id)
                feedPage = page;
        }
        else
        {
            if (mu_button(ctx, s))
                feedPage = page;
        }
    }

    // Spacer to push Next/Last to the right.
    mu_layout_next(ctx);

    // Next
    if (mu_button(ctx, "Next >"))
    {
        if (feedPage < totalPages - 1) feedPage++;
    }

    // Last
    if (mu_button(ctx, "Last >>"))
        feedPage = totalPages - 1;

    mu_end_panel(ctx);
}

/// Extract the search buffer as a D string.
private string searchStr()
{
    if (searchLen == 0)
        return null;
    return cast(string) searchBuf[0 .. searchLen];
}

/// Check whether a feed entry passes the current filters.
private bool passesFilter(ref FeedEntry entry, string query, AppState* state)
{
    // Self events (user-update, user-location, self avatar changes, etc) are
    // hidden unless explicitly shown.
    if (state.feedShowSelfEvents == 0 && entry.isSelf)
        return false;

    // Event type filter. Unknown raw types (size_t.max) fall through
    // as visible so new VRChat events stay debuggable.
    size_t idx = feedEventIndex(entry.eventType);
    if (idx != size_t.max && state.feedEventVisible[idx] == 0)
        return false;

    // Text search filter.
    if (query.length == 0)
        return true;

    import std.algorithm : canFind;
    string q = toLower(query);
    return toLower(entry.user).canFind(q)
        || toLower(entry.detail).canFind(q)
        || toLower(prettyEventType(entry.eventType)).canFind(q);
}

/// Insert vertical spacing.
private void spacer(mu_Context* ctx, int height = 20)
{
    static immutable int[1] fullCol = [-1];
    mu_layout_row(ctx, 1, fullCol.ptr, height);
    mu_layout_next(ctx);
}

/// Draw a section header: bold-ish label with a horizontal separator line underneath.
private void sectionHeader(mu_Context* ctx, string label)
{
    static immutable int[1] fullCol = [-1];
    mu_layout_row(ctx, 1, fullCol.ptr, 0);
    mu_label(ctx, label);
    mu_layout_row(ctx, 1, fullCol.ptr, 1);
    mu_draw_rect(ctx, mu_layout_next(ctx), mu_Color(60, 60, 70, 255));
}

/// A label whose value can be copied to the clipboard on click.
/// Highlights on hover to hint interactivity.
private void clickableValue(mu_Context* ctx, AppState* state, string text)
{
    import bindbc.sdl : SDL_SetClipboardText;

    mu_Rect r = mu_layout_next(ctx);
    bool mouseOver = mu_mouse_over(ctx, r) != 0;

    if (mouseOver && !ctx.mouse_down)
        mu_draw_rect(ctx, r, mu_Color(50, 60, 80, 255));

    mu_draw_control_text(ctx, text, r, MU_COLOR_TEXT, 0);

    if (wasClick && mouseOver)
    {
        SDL_SetClipboardText(toStringz(text));
        setStatusFlash(state, "  Copied to clipboard");
        wasClick = false;
    }
}

/// A button that fires on mouseup (via wasClick) instead of mousedown.
/// Compatible with drag-to-scroll: dragging won't trigger the click.
private bool clickButton(mu_Context* ctx, string label)
{
    mu_Rect r = mu_layout_next(ctx);
    bool mouseOver = mu_mouse_over(ctx, r) != 0;

    // Draw button frame (highlighted on hover).
    int colorId = MU_COLOR_BUTTON + (mouseOver && !ctx.mouse_down ? 1 : 0);
    mu_draw_frame(ctx, r, colorId);
    mu_draw_control_text(ctx, label, r, MU_COLOR_TEXT, MU_OPT_ALIGNCENTER);

    if (wasClick && mouseOver)
    {
        wasClick = false;
        return true;
    }
    return false;
}

/// Two-tap destructive button that never places Confirm where the first
/// tap landed: arming turns the button itself into Cancel, and Confirm
/// appears below it offset to the right, so an accidental double tap
/// cancels instead of confirming. Returns true when confirmed.
/// kind+id key the armed state so only one confirmation is pending at a
/// time across the whole UI.
private bool confirmButton(mu_Context* ctx, AppState* state,
    string kind, string id, string label, string confirmLabel)
{
    static immutable int[1] fullCol = [-1];

    mu_layout_row(ctx, 1, fullCol.ptr, 60);
    if (state.armedConfirm.kind != kind || state.armedConfirm.id != id)
    {
        if (clickButton(ctx, label))
            state.armedConfirm = ArmedConfirm(kind, id);
        return false;
    }

    if (clickButton(ctx, "Cancel"))
        state.armedConfirm = ArmedConfirm.init;

    int half = mu_get_current_container(ctx).body_.w / 2;
    int[2] confirmCols = [half, -1];
    mu_layout_row(ctx, 2, confirmCols.ptr, 56);
    mu_layout_next(ctx); // left spacer keeps Confirm off the original button
    if (clickButton(ctx, confirmLabel))
    {
        state.armedConfirm = ArmedConfirm.init;
        return true;
    }
    return false;
}

/// The pictures drawn on icon-only action buttons.
///
/// The atlas ships four glyphs (a 16px X, a check, two arrows) and none of
/// the rest of these, so each icon is a handful of filled rects laid out on
/// a 0..100 grid scaled to the button -- the same trade drawStatusCircle
/// makes. Stamping a 16px bitmap in the middle of a VR-sized target would
/// have been the other option, and at that size the icon is what the button
/// is for.
private enum ActionIcon
{
    check,      /// accept, confirm, yes
    cross,      /// decline, reject, deny, no, cancel
    trash,      /// dismiss (delete/hide)
    ban,        /// block
    bellSlash,  /// unsubscribe
    join,       /// join, enter
    reply,      /// reply
    dots,       /// a response type this build has never heard of
}

/// Pixels of breathing room between an action button's frame and its icon.
private enum int actionIconPadding = 10;

/// A line `thick` pixels wide between two points, as a run of squares
/// stepped along the dominant axis. The software renderer only exposes
/// filled rects, so this is how a diagonal gets drawn.
private void iconLine(mu_Context* ctx, int x0, int y0, int x1, int y1,
    int thick, mu_Color color)
{
    int dx = x1 - x0;
    int dy = y1 - y0;
    int adx = dx < 0 ? -dx : dx;
    int ady = dy < 0 ? -dy : dy;
    int steps = adx > ady ? adx : ady;
    if (steps < 1)
        steps = 1;
    int half = thick / 2;
    foreach (int i; 0 .. steps + 1)
    {
        int x = x0 + (dx * i) / steps;
        int y = y0 + (dy * i) / steps;
        mu_draw_rect(ctx, mu_Rect(x - half, y - half, thick, thick), color);
    }
}

/// A circle outline, drawn as two passes so neither the sides nor the caps
/// come out as gaps: one pass walks rows and marks the left and right edge,
/// the other walks columns and marks the top and bottom.
private void iconRing(mu_Context* ctx, int cx, int cy, int radius,
    int thick, mu_Color color)
{
    import std.math : sqrt;

    if (radius < 1)
        return;
    int r2 = radius * radius;
    foreach (int dy; -radius .. radius + 1)
    {
        int span = cast(int) sqrt(cast(float)(r2 - dy * dy));
        mu_draw_rect(ctx, mu_Rect(cx - span, cy + dy, thick, 1), color);
        mu_draw_rect(ctx, mu_Rect(cx + span - thick, cy + dy, thick, 1), color);
    }
    foreach (int dx; -radius .. radius + 1)
    {
        int span = cast(int) sqrt(cast(float)(r2 - dx * dx));
        mu_draw_rect(ctx, mu_Rect(cx + dx, cy - span, 1, thick), color);
        mu_draw_rect(ctx, mu_Rect(cx + dx, cy + span - thick, 1, thick), color);
    }
}

/// Draw one icon filling the square `box`.
private void drawActionIcon(mu_Context* ctx, ActionIcon icon, mu_Rect box,
    mu_Color color)
{
    int thick = box.w / 10;
    if (thick < 2)
        thick = 2;

    // 0..100 grid over the box, so every icon below reads as coordinates
    // rather than as arithmetic.
    int gx(int u) { return box.x + (box.w * u) / 100; }
    int gy(int u) { return box.y + (box.h * u) / 100; }
    void line(int x0, int y0, int x1, int y1)
    {
        iconLine(ctx, gx(x0), gy(y0), gx(x1), gy(y1), thick, color);
    }
    void fill(int x0, int y0, int x1, int y1)
    {
        mu_draw_rect(ctx, mu_Rect(gx(x0), gy(y0),
            gx(x1) - gx(x0), gy(y1) - gy(y0)), color);
    }

    final switch (icon)
    {
        case ActionIcon.check:
            line(20, 52, 42, 74);
            line(42, 74, 80, 26);
            break;

        case ActionIcon.cross:
            line(26, 26, 74, 74);
            line(74, 26, 26, 74);
            break;

        case ActionIcon.trash:
            fill(40, 12, 60, 20);   // handle
            fill(16, 24, 84, 33);   // lid
            line(26, 36, 30, 86);   // body, tapered
            line(74, 36, 70, 86);
            line(30, 86, 70, 86);
            line(44, 46, 45, 76);   // slots
            line(56, 46, 55, 76);
            break;

        case ActionIcon.ban:
            iconRing(ctx, gx(50), gy(50), (box.w * 32) / 100, thick, color);
            line(28, 28, 72, 72);
            break;

        case ActionIcon.bellSlash:
            line(36, 58, 38, 34);   // dome
            line(38, 34, 50, 28);
            line(50, 28, 62, 34);
            line(62, 34, 64, 58);
            line(28, 60, 72, 60);   // rim
            fill(45, 66, 55, 74);   // clapper
            line(24, 76, 76, 24);   // slash
            break;

        case ActionIcon.join:
            line(20, 50, 58, 50);   // shaft
            line(44, 36, 58, 50);   // head
            line(44, 64, 58, 50);
            line(74, 20, 74, 80);   // doorpost
            break;

        case ActionIcon.reply:
            line(20, 40, 34, 26);   // head
            line(20, 40, 34, 54);
            line(20, 40, 66, 40);   // shaft, turning down
            line(66, 40, 66, 76);
            break;

        case ActionIcon.dots:
            fill(22, 44, 34, 56);
            fill(44, 44, 56, 56);
            fill(66, 44, 78, 56);
            break;
    }
}

/// A square, icon-only action button. Fires on mouseup like clickButton, so
/// dragging the list scrolls it instead of pressing whatever the finger
/// started on.
///
/// Icons say what they do only once somebody knows them, so the button hands
/// its `label` back through `hoverLabel` while the pointer is on it; the
/// caller captions the row with it. There is no hover in VR, which is the
/// same reason the caption is a courtesy and not the label itself.
private bool iconButton(mu_Context* ctx, ActionIcon icon, mu_Color tint,
    const(char)[] label, ref const(char)[] hoverLabel)
{
    mu_Rect r = mu_layout_next(ctx);
    bool mouseOver = mu_mouse_over(ctx, r) != 0;
    if (mouseOver)
        hoverLabel = label;

    int colorId = MU_COLOR_BUTTON + (mouseOver && !ctx.mouse_down ? 1 : 0);
    mu_draw_frame(ctx, r, colorId);

    // Square icon box centered in whatever cell the layout handed us.
    int side = (r.w < r.h ? r.w : r.h) - actionIconPadding * 2;
    if (side < 8)
        side = 8;
    mu_Rect iconBox = mu_Rect(r.x + (r.w - side) / 2, r.y + (r.h - side) / 2,
        side, side);
    drawActionIcon(ctx, icon, iconBox, tint);

    if (wasClick && mouseOver)
    {
        wasClick = false;
        return true;
    }
    return false;
}

/// Draw a grid cell: text with a right-side vertical separator line.
private void gridCell(mu_Context* ctx, const(char)[] text, mu_Color lineColor, bool lastCol = false)
{
    mu_Rect r = mu_layout_next(ctx);
    // Safe to cast: mu_draw_text memcpys the text into its command queue.
    mu_draw_control_text(ctx, cast(string) text, r, MU_COLOR_TEXT, 0);
    if (lastCol == false)
        mu_draw_rect(ctx, mu_Rect(r.x + r.w - 1, r.y, 1, r.h), lineColor);
}

/// Format a unix timestamp as a short relative time ("just now", "5m ago",
/// "3h ago", ...). Writes into the caller's buffer to avoid per-frame GC.
/// Returns an empty slice for `unixTime == 0` (unknown).
private const(char)[] formatRelative(long unixTime, char[] buf)
{
    import std.datetime : Clock;

    if (unixTime == 0)
        return null;

    long diff = Clock.currTime.toUnixTime!long() - unixTime;
    if (diff < 0)
        diff = 0;

    if (diff < 60)
        return sformat(buf, "just now");
    if (diff < 3600)
        return sformat(buf, "%dm ago", diff / 60);
    if (diff < 86_400)
        return sformat(buf, "%dh ago", diff / 3600);
    if (diff < 86_400 * 30)
        return sformat(buf, "%dd ago", diff / 86_400);
    if (diff < 86_400 * 365)
        return sformat(buf, "%dmo ago", diff / (86_400 * 30));
    return sformat(buf, "%dy ago", diff / (86_400 * 365));
}

/// Format a byte count for display. Whole bytes below a kilobyte, one decimal
/// above: "12.4 MB" says as much as the exact figure and keeps its width as
/// the file grows. Writes into the caller's buffer to avoid per-frame GC.
private const(char)[] formatBytes(long bytes, char[] buf)
{
    static immutable string[4] units = [ "B", "KB", "MB", "GB" ];

    double n = bytes;
    size_t unit;
    while (n >= 1024 && unit < units.length - 1)
    {
        n /= 1024;
        ++unit;
    }

    if (unit == 0)
        return sformat(buf, "%d %s", bytes, units[unit]);
    return sformat(buf, "%.1f %s", n, units[unit]);
}

/// Extra vertical margin (in pixels) added to collapsible headers in the
/// Online tab, on top of the style default, to make them easier to hit in VR.
private enum int onlineHeaderExtraHeight = 16;

/// Draw a collapsible header with extra height. mu_header forces a
/// default-height layout row, so the only lever for its height is the style
/// size; we bump it for the call and restore it right after.
private int bigHeader(mu_Context* ctx, string label, int opt)
{
    int saved = ctx.style.size.y;
    ctx.style.size.y = saved + onlineHeaderExtraHeight;
    int res = mu_header_ex(ctx, label, opt);
    ctx.style.size.y = saved;
    return res;
}

/// Online tab: friends grouped by instance, or profile view.
private void drawOnlineTab(mu_Context* ctx, AppState* state, int scrollDelta)
{
    if (state.selectedFriend)
    {
        drawFriendProfile(ctx, state, scrollDelta);
        return;
    }

    static immutable int[1] fullCol = [-1];
    mu_begin_panel(ctx, "FriendsPanel");

    applyScroll(ctx, scrollDelta);

    // Your-status section at the top.
    drawSelfStatusSection(ctx, state);

    mu_layout_row(ctx, 1, fullCol.ptr, 0);

    if (state.instances.length == 0 &&
        state.activeElsewhereFriends.length == 0 &&
        state.offlineFriends.length == 0)
    {
        mu_label(ctx, "No friend data yet.");
    }
    else
    {
        char[160] headerBuf = void;
        foreach (ref InstanceGroup grp; state.instances)
        {
            if (grp.instanceId == "private")
                continue;
            string baseName = grp.worldName.length > 0 ? grp.worldName : grp.instanceId;
            const(char)[] header = grp.nUsers >= 0 && grp.capacity > 0 ?
                sformat(headerBuf, "%s (%d/%d)", baseName, grp.nUsers, grp.capacity) : baseName;
            if (bigHeader(ctx, cast(string)header, MU_OPT_EXPANDED))
            {
                // Join this instance. "Open in VRChat" hands the launch URI
                // to the running client over its named pipe for a seamless
                // in-client transition (gui.d drains pendingOpens: in-process
                // on Windows, injected into the Proton container on Linux,
                // falling back per platform). "Self-Invite" asks the server
                // for an in-game invite instead: no setup, works everywhere,
                // and covers URIs VRChat refuses (restricted instances
                // without a shortName). Uses the full location (region tags
                // intact); falls back to the canonical grouping key if the
                // server carried none.
                string joinLoc = grp.location.length > 0 ? grp.location : grp.instanceId;
                if (joinLoc.length > 0)
                {
                    int half = mu_get_current_container(ctx).body_.w / 2;
                    int[2] joinCols = [half, -1];
                    mu_layout_row(ctx, 2, joinCols.ptr, 40);
                    if (clickButton(ctx, "Open in VRChat"))
                        state.pendingOpens ~= joinLoc;
                    if (clickButton(ctx, "Self-Invite"))
                        state.pendingJoins ~= joinLoc;
                }
                foreach (ref FriendInfo f; grp.friends)
                    drawFriendCard(ctx, state, f);
                mu_layout_row(ctx, 1, fullCol.ptr, 0);
            }
        }

        foreach (ref InstanceGroup grp; state.instances)
        {
            if (grp.instanceId != "private")
                continue;
            if (bigHeader(ctx, "Private", MU_OPT_EXPANDED))
            {
                foreach (ref FriendInfo f; grp.friends)
                    drawFriendCard(ctx, state, f);
                mu_layout_row(ctx, 1, fullCol.ptr, 0);
            }
        }

        if (state.activeElsewhereFriends.length > 0)
        {
            if (bigHeader(ctx, "Active elsewhere", 0))
            {
                foreach (ref FriendInfo f; state.activeElsewhereFriends)
                    drawFriendCard(ctx, state, f);
                mu_layout_row(ctx, 1, fullCol.ptr, 0);
            }
        }

        if (state.offlineFriends.length > 0)
        {
            if (bigHeader(ctx, "Offline", 0))
            {
                foreach (ref FriendInfo f; state.offlineFriends)
                    drawFriendCard(ctx, state, f);
                mu_layout_row(ctx, 1, fullCol.ptr, 0);
            }
        }
    }

    mu_end_panel(ctx);
}

/// Self-status popup state. The circle opens it; the popup itself is drawn
/// outside the friends panel so it can render on top. We anchor the popup to
/// the circle rect captured the same frame the user clicked, so it always
/// drops down directly beneath the indicator instead of at the cursor.
private bool selfStatusPopupRequested;
private mu_Rect selfStatusCircleRect;

/// Draw the "Your Status" row at the top of the Online tab:
///   [ textbox: custom status ] [ status circle ] [ Set ]
/// Clicking the circle opens a popup with the four VRChat statuses.
private void drawSelfStatusSection(mu_Context* ctx, AppState* state)
{
    enum int refreshW = 110; // fits "Refreshing..."
    enum int cancelW  = 40;
    enum int circleW  = 40;
    enum int setW     = 80;
    static immutable int[1] fullCol = [-1];

    bool busy = state.statusUpdateInFlight || state.connected == false;

    // Pending-change detection drives both the Update button and whether the
    // inline cancel ("X") button is shown.
    bool descChanged = textboxDiffersFrom(state.statusDescriptionInput[],
        state.selfStatusDescription);
    bool statusChanged = state.selfStatusDraft.length > 0
        && state.selfStatusDraft != state.selfStatus;
    bool dirty = descChanged || statusChanged;

    // Layout: Refresh sits to the left of the textbox so it's clear of both
    // the scrollable friend list below and the status controls to the right
    // (it used to be a full-width strip above the list and caught stray taps).
    // Cancel button is always present so the user can clear the textbox in one
    // click even when nothing is pending. Textbox flexes.
    int[5] cols =
        [refreshW, -(cancelW + circleW + setW + 16), cancelW, circleW, setW];
    mu_layout_row(ctx, 5, cols.ptr, 40);

    // Refresh: asks the server to re-read the roster from VRChat, the way
    // reloading a page does, rather than waiting on the server's own timer.
    // Inert while a pass is running, since a second one would only be
    // turned away by the server's debounce.
    if (mu_button(ctx, state.friendsRefreshing ? "Refreshing..." : "Refresh")
        && state.friendsRefreshing == false)
    {
        state.refreshFriendsRequested = true;
        setStatusFlash(state, state.connected
            ? "  Refreshing friends..." : "  Not connected");
    }

    // The server turned a refresh away because it re-seeded moments ago.
    // Say so once -- the roster sent with the refusal is already applied, so
    // there is nothing else to show for the press -- then clear it so the
    // flash doesn't renew itself every frame.
    if (state.friendsRefreshRetryAfter > 0)
    {
        static char[64] retryBuf;
        setStatusFlash(state, cast(string) sformat(retryBuf,
            "  Refreshed just now, again in %ds", state.friendsRefreshRetryAfter),
            2500);
        state.friendsRefreshRetryAfter = 0;
    }

    // Textbox. mu_textbox shows what's in the buffer, so an empty buffer
    // simply shows nothing; we overlay a placeholder string when empty
    // and unfocused. Use the _raw form so we own the rect for the overlay.
    {
        char* tbBuf = state.statusDescriptionInput.ptr;
        mu_Id tbId = mu_get_id(ctx, &tbBuf, tbBuf.sizeof);
        mu_Rect tbRect = mu_layout_next(ctx);
        mu_textbox_raw(ctx, tbBuf,
            cast(int) state.statusDescriptionInput.length, tbId, tbRect, 0);
        // VRChat caps status_description at 32 code points; the REST API
        // responds with HTTP 400 if you send more (observed with 34 chars).
        // VRChat's own client also strips emoji on input - the backend is
        // almost certainly MySQL utf8 (3-byte max), not utf8mb4, so any
        // code point >= U+10000 (4-byte UTF-8) is silently dropped on their
        // end. Strip them here too, then truncate to 32 code points.
        sanitizeStatusInput(state.statusDescriptionInput[], 32);
        if (state.statusDescriptionInput[0] == '\0' && ctx.focus != tbId)
            mu_draw_control_text(ctx, "Enter a custom status...",
                tbRect, MU_COLOR_TEXT, 0);
    }

    // Clear ("X"): empties the textbox and drops any pending status draft.
    // The user then commits the empty description via Update, same as any
    // other edit. Always present so it's a one-click clear regardless of
    // whether a description is currently committed.
    if (mu_button(ctx, "X"))
    {
        state.selfStatusDraft = null;
        state.statusDescriptionInput[] = '\0';
        state.statusUpdateError = null;
        requestRepaint();
    }

    // Status indicator "circle". Shows the draft color while a selection is
    // pending so the user can see what they picked before committing.
    string shownStatus = state.selfStatusDraft.length > 0
        ? state.selfStatusDraft : state.selfStatus;
    mu_Rect cr = mu_layout_next(ctx);
    selfStatusCircleRect = cr;
    drawStatusCircle(ctx, cr, statusColor(shownStatus));
    {
        enum string circleSlot = "self_status_circle";
        mu_Id cid = mu_get_id(ctx, circleSlot.ptr, cast(int) circleSlot.length);
        mu_update_control(ctx, cid, cr, 0);
        if (ctx.mouse_pressed == MU_MOUSE_LEFT && ctx.focus == cid && busy == false)
            selfStatusPopupRequested = true;
    }

    // Update button. Disabled visually (and inert) when there is nothing to
    // commit or while a previous update is in flight.
    bool canSubmit = busy == false && dirty;

    if (mu_button(ctx, busy ? "..." : "Update") && canSubmit)
    {
        if (statusChanged)
            state.pendingSetStatus = state.selfStatusDraft;
        if (descChanged)
        {
            const(char)* nul = cast(const(char)*)
                memchr(state.statusDescriptionInput.ptr, 0,
                    state.statusDescriptionInput.length);
            size_t n = nul
                ? cast(size_t)(nul - state.statusDescriptionInput.ptr)
                : state.statusDescriptionInput.length;
            state.pendingSetStatusDescription =
                state.statusDescriptionInput[0 .. n].idup;
            state.pendingSetStatusDescriptionSet = true;
        }
        state.statusUpdateError = null;
        setStatusFlash(state, "  Updating status...");
    }

    // Inline error line. Rendered in red so it doesn't get lost in the feed.
    if (state.statusUpdateError.length > 0)
    {
        char[256] errBuf = void;
        mu_layout_row(ctx, 1, fullCol.ptr, 24);
        mu_Rect er = mu_layout_next(ctx);
        const(char)[] line = sformat(errBuf, "Status update failed: %s",
            state.statusUpdateError);
        mu_draw_text(ctx, ctx.style.font, cast(string) line,
            mu_Vec2(er.x, er.y + 4), mu_Color(220, 70, 70, 255));
    }
}

/// Overwrite a NUL-terminated textbox buffer with `src` (truncated to fit,
/// always NUL-terminated).
private void setTextboxFrom(char[] buf, string src)
{
    import std.algorithm : min;
    buf[] = '\0';
    size_t n = min(src.length, buf.length - 1);
    buf[0 .. n] = src[0 .. n];
}

/// Truncate a NUL-terminated UTF-8 buffer to at most `maxCodePoints` code
/// points by zeroing the trailing bytes. Invalid sequences are also cut at
/// the bad byte so we never leave a half-character in the textbox.
/// In-place sanitize a NUL-terminated UTF-8 status buffer:
///   - drop any code point that requires a 4-byte UTF-8 sequence
///     (>= U+10000, i.e. nearly all emoji) since VRChat's backend
///     looks like MySQL utf8 (3-byte max) and strips them anyway,
///   - then truncate to at most `maxCodePoints` code points,
///   - and re-NUL the trailing bytes.
private void sanitizeStatusInput(char[] buf, size_t maxCodePoints)
{
    size_t read;
    size_t write;
    size_t cp;
    while (read < buf.length && buf[read] != '\0' && cp < maxCodePoints)
    {
        size_t s;
        try
            s = stride(buf, read);
        catch (UTFException)
            break;
        if (s == 0 || read + s > buf.length)
            break;
        if (s < 4)
        {
            if (write != read)
                buf[write .. write + s] = buf[read .. read + s];
            write += s;
            cp++;
        }
        read += s;
    }
    while (write < buf.length && buf[write] != '\0')
    {
        buf[write] = '\0';
        write++;
    }
}

/// True if the NUL-terminated textbox content differs from `cmp`.
private bool textboxDiffersFrom(const(char)[] buf, string cmp)
{
    size_t n;
    foreach (size_t i, char c; buf)
    {
        if (c == '\0') { n = i; goto found; }
    }
    n = buf.length;
found:
    return buf[0 .. n] != cmp;
}

/// Approximate a filled circle inside `bounds` with stacked rects.
/// The software renderer only exposes filled rects, so this is the
/// cheapest way to get something that reads as round at small sizes.
private void drawStatusCircle(mu_Context* ctx, mu_Rect bounds, mu_Color color)
{
    int size = bounds.w < bounds.h ? bounds.w : bounds.h;
    // Inset slightly so it looks like a separate badge, not a button.
    int pad = 6;
    if (size > pad * 2 + 4)
        size -= pad * 2;
    int cx = bounds.x + bounds.w / 2;
    int cy = bounds.y + bounds.h / 2;
    int r = size / 2;
    int r2 = r * r;
    import std.math : sqrt;
    foreach (int dy; -r .. r + 1)
    {
        int span = cast(int) sqrt(cast(float)(r2 - dy * dy));
        mu_draw_rect(ctx,
            mu_Rect(cx - span, cy + dy, span * 2, 1), color);
    }
}

/// Popup listing the four selectable VRChat statuses. Drawn from
/// drawFullWindow (outside the main panel) so it stacks on top. Clicking
/// a row only stages the selection (selfStatusDraft); the Update button
/// in drawSelfStatusSection commits the change. This matches VRChat's
/// own "pick + Update" flow.
package void drawSelfStatusPopup(mu_Context* ctx, AppState* state)
{
    enum string popupName = "self_status_popup";

    // Open ourselves rather than using mu_open_popup, which anchors at
    // the cursor; anchor under the circle for a tidy dropdown.
    if (selfStatusPopupRequested)
    {
        selfStatusPopupRequested = false;
        mu_Container* cnt = mu_get_container(ctx, popupName.ptr,
            cast(int) popupName.length);
        if (cnt)
        {
            // Reset to (1,1) so MU_OPT_AUTOSIZE in begin_window_ex resizes
            // to actual content size; keep the x,y we set here.
            int px = selfStatusCircleRect.x;
            int py = selfStatusCircleRect.y + selfStatusCircleRect.h + 4;
            cnt.rect = mu_Rect(px, py, 1, 1);
            cnt.open = 1;
            // Mark as hover root so begin_window_ex's outside-click guard
            // doesn't immediately close the popup on the opening press.
            ctx.hover_root = ctx.next_hover_root = cnt;
            mu_bring_to_front(ctx, cnt);
        }
    }

    if (mu_begin_popup(ctx, popupName.ptr, cast(int) popupName.length))
    {
        drawStatusPopupRow(ctx, state, "Join Me", "join me");
        drawStatusPopupRow(ctx, state, "Online",  "active");
        drawStatusPopupRow(ctx, state, "Ask Me",  "ask me");
        drawStatusPopupRow(ctx, state, "DND",     "busy");
        mu_end_popup(ctx);
    }
}

/// One row inside the self-status popup: colored badge + label, clickable.
/// The whole row (badge included) is one hit target; hover highlights and
/// the active choice gets a persistent fill. Clicking stages the choice in
/// selfStatusDraft and dismisses the popup; no network call happens until
/// the Update button is pressed.
private void drawStatusPopupRow(mu_Context* ctx, AppState* state,
    string label, string value)
{
    enum mu_Color rowHover  = mu_Color(55, 62, 82, 255);
    enum mu_Color rowActive = mu_Color(60, 80, 120, 255);

    // Fixed width: -1 ("remaining") resolves to 0 inside an AUTOSIZE popup
    // (its body width starts at 0 and grows from content), which would make
    // the row invisible and un-hittable.
    enum int rowW = 160;
    static immutable int[1] rowCol = [rowW];
    mu_layout_row(ctx, 1, rowCol.ptr, 32);
    mu_Rect row = mu_layout_next(ctx);

    // Whole-row hit target. Register before drawing so hover state is
    // available for the highlight below.
    mu_Id id = mu_get_id(ctx, &value, value.sizeof);
    mu_update_control(ctx, id, row, 0);

    string currentChoice = state.selfStatusDraft.length > 0
        ? state.selfStatusDraft : state.selfStatus;
    bool active = currentChoice == value;
    bool hovered = ctx.hover == id;

    // Background: active wins over hover.
    if (active)
        mu_draw_rect(ctx, row, rowActive);
    else if (hovered)
        mu_draw_rect(ctx, row, rowHover);

    // Badge (clickable too, since the whole row is one target).
    int badgeW = 28;
    mu_Rect badge = mu_Rect(row.x, row.y, badgeW, row.h);
    drawStatusCircle(ctx, badge, statusColor(value));

    // Label, padded right of the badge.
    mu_Rect lbl = mu_Rect(row.x + badgeW, row.y, row.w - badgeW, row.h);
    mu_draw_control_text(ctx, label, lbl, MU_COLOR_TEXT, 0);

    if (ctx.mouse_pressed == MU_MOUSE_LEFT && ctx.focus == id)
    {
        // Stage the choice. If the user picked back the live status,
        // clear the draft entirely so the Update button stays inert.
        state.selfStatusDraft = value == state.selfStatus ? "" : value;
        mu_Container* pcnt = mu_get_current_container(ctx);
        if (pcnt) pcnt.open = 0;
    }
}

/// Draw a single friend as a flexbox-style card. Clicks fire via wasClick,
/// so dragging on the row (or the left gutter) scrolls the panel instead.
private void drawFriendCard(mu_Context* ctx, AppState* state, ref FriendInfo f)
{
    enum mu_Color cardBg    = mu_Color(38, 42, 52, 255);
    enum mu_Color cardHover = mu_Color(55, 62, 82, 255);

    static immutable int[2] indentCols = [14, -1];
    mu_layout_row(ctx, 2, indentCols.ptr, 56);
    mu_layout_next(ctx); // left gutter,  empty, scrollable drag area

    mu_Rect r = mu_layout_next(ctx);
    bool mouseOver = mu_mouse_over(ctx, r) != 0;

    // Card background with hover highlight (suppressed while dragging).
    mu_draw_rect(ctx, r, (mouseOver && ctx.mouse_down == 0) ? cardHover : cardBg);

    // Status accent strip on the left edge.
    mu_draw_rect(ctx, mu_Rect(r.x, r.y, 4, r.h), statusColor(f.status));

    int padX = 14;
    int innerX = r.x + padX;
    int innerW = r.w - padX * 2;

    mu_draw_control_text(ctx, f.displayName,
        mu_Rect(innerX, r.y + 6, innerW, 22), MU_COLOR_TEXT, 0);

    // Moderation badge, right-aligned on the name line.
    string badge;
    if (state.isBlocked(f.userId))
        badge = "BLOCKED";
    else if (state.isMuted(f.userId))
        badge = "MUTED";
    if (badge.length > 0)
        mu_draw_control_text(ctx, badge,
            mu_Rect(innerX, r.y + 6, innerW, 22), MU_COLOR_TEXT, MU_OPT_ALIGNRIGHT);

    char[128] buffer = void;
    string sub;
    if (f.status && f.platform)
        sub = cast(string) sformat(buffer, "%s  -  %s", prettyStatus(f.status), prettyPlatform(f.platform));
    else if (f.status)
        sub = prettyStatus(f.status);
    else if (f.platform)
        sub = prettyPlatform(f.platform);

    if (sub.length > 0)
        mu_draw_control_text(ctx, sub, mu_Rect(innerX, r.y + 30, innerW, 20), MU_COLOR_TEXT, 0);

    if (wasClick && mouseOver)
    {
        state.selectedFriend = &f;
        state.armedConfirm = ArmedConfirm.init;
    }
}

/// Map feed event source to an accent colour for the row strip.
private mu_Color sourceColor(EventSource source)
{
    final switch (source)
    {
        case EventSource.server:        return mu_Color( 70, 140, 220, 255); // blue
        case EventSource.local:         return mu_Color(160,  90, 220, 255); // purple
        case EventSource.dropaportal:   return mu_Color( 54, 215, 192, 255); // teal (accent color)
        case EventSource.system:        return mu_Color( 90,  90, 100, 255); // gray
    }
}

/// Map VRChat status to an accent colour for the friend card strip.
private mu_Color statusColor(string status)
{
    switch (status)
    {
        case "active":  return mu_Color(70, 200, 90, 255);
        case "join me": return mu_Color(70, 140, 220, 255);
        case "ask me":  return mu_Color(220, 170, 60, 255);
        case "busy":    return mu_Color(220, 70, 70, 255);
        case "offline": return mu_Color(120, 120, 120, 255);
        default:        return mu_Color(120, 120, 120, 255);
    }
}

/// Friend profile detail view.
private void drawFriendProfile(mu_Context* ctx, AppState* state, int scrollDelta)
{
    static immutable int[1] fullCol = [-1];
    static immutable int[2] labelValCols = [120, -1];
    enum lineColor = mu_Color(50, 50, 60, 255);

    FriendInfo* f = state.selectedFriend;

    mu_begin_panel(ctx, "FriendProfilePanel");

    applyScroll(ctx, scrollDelta);

    // Navigation back to the list is the sticky header Back button.

    // Name as header.
    mu_layout_row(ctx, 1, fullCol.ptr, 0);
    mu_label(ctx, f.displayName);

    // Separator.
    mu_layout_row(ctx, 1, fullCol.ptr, 1);
    mu_draw_rect(ctx, mu_layout_next(ctx), lineColor);

    // Profile fields.
    if (f.status)
    {
        mu_layout_row(ctx, 2, labelValCols.ptr, 0);
        mu_label(ctx, "Status");
        clickableValue(ctx, state, prettyStatus(f.status));
    }

    if (f.statusDescription)
    {
        mu_layout_row(ctx, 2, labelValCols.ptr, 0);
        mu_label(ctx, "Status Note");
        clickableValue(ctx, state, f.statusDescription);
    }

    if (f.pronouns)
    {
        mu_layout_row(ctx, 2, labelValCols.ptr, 0);
        mu_label(ctx, "Pronouns");
        clickableValue(ctx, state, f.pronouns);
    }

    if (f.bio)
    {
        mu_layout_row(ctx, 2, labelValCols.ptr, 0);
        mu_label(ctx, "Bio");
        clickableValue(ctx, state, f.bio);
    }

    foreach (link; f.bioLinks)
    {
        if (link.length == 0)
            continue;
        mu_layout_row(ctx, 2, labelValCols.ptr, 0);
        mu_label(ctx, "Link");
        clickableValue(ctx, state, link);
    }

    if (f.platform)
    {
        mu_layout_row(ctx, 2, labelValCols.ptr, 0);
        mu_label(ctx, "Platform");
        clickableValue(ctx, state, prettyPlatform(f.platform));
    }

    if (f.location.length > 0)
    {
        mu_layout_row(ctx, 2, labelValCols.ptr, 0);
        mu_label(ctx, "Location");
        clickableValue(ctx, state, f.location == "offline" ? "Offline" : f.location);
    }

    if (f.userId.length > 0)
    {
        mu_layout_row(ctx, 2, labelValCols.ptr, 0);
        mu_label(ctx, "User ID");
        clickableValue(ctx, state, f.userId);
    }

    // Management actions. Requires the server-side moderation API.
    if (f.userId.length > 0 && state.serverProtocol >= PROTOCOL_MODERATION)
    {
        spacer(ctx);
        sectionHeader(ctx, "Manage");

        bool muted = state.isMuted(f.userId);
        bool blocked = state.isBlocked(f.userId);

        mu_layout_row(ctx, 1, fullCol.ptr, 60);
        if (clickButton(ctx, muted ? "Unmute" : "Mute"))
        {
            if (state.moderationActionInFlight == false)
            {
                state.pendingModerationActions ~= ModerationAction(f.userId, f.displayName,
                    muted ? "unmute" : "mute");
                setStatusFlash(state, muted ? "  Unmuting..." : "  Muting...");
            }
        }

        if (blocked)
        {
            mu_layout_row(ctx, 1, fullCol.ptr, 60);
            if (clickButton(ctx, "Unblock"))
            {
                if (state.moderationActionInFlight == false)
                {
                    state.pendingModerationActions ~= ModerationAction(f.userId, f.displayName, "unblock");
                    setStatusFlash(state, "  Unblocking...");
                }
            }
        }
        else if (confirmButton(ctx, state, "block", f.userId, "Block", "Confirm Block"))
        {
            if (state.moderationActionInFlight == false)
            {
                state.pendingModerationActions ~= ModerationAction(f.userId, f.displayName, "block");
                setStatusFlash(state, "  Blocking...");
            }
        }

        if (confirmButton(ctx, state, "unfriend", f.userId, "Unfriend", "Confirm Unfriend"))
        {
            if (state.moderationActionInFlight == false)
            {
                state.pendingModerationActions ~= ModerationAction(f.userId, f.displayName, "unfriend");
                setStatusFlash(state, "  Unfriending...");
            }
        }

        if (state.moderationActionInFlight)
        {
            mu_layout_row(ctx, 1, fullCol.ptr, 0);
            mu_label(ctx, "Working...");
        }
    }

    mu_end_panel(ctx);
}

/// Notifications tab: friend requests, invites, group notifications, and
/// anything else VRChat sends.
///
/// Layout: three lines of text over a row of square icon buttons, all of
/// them full width. At ~640px (half of a 1280 screen) a single meta row
/// squished the sender name, so the metadata is split across three short
/// rows; putting the buttons underneath rather than in a right-hand column
/// gives those rows the whole width back, and gives the actions somewhere
/// to grow sideways.
///
///   +------------------------------------------+
///   |# Type . Date                             |
///   |# From                                    |  (friendRequest)
///   |# Message                                 |
///   |# [check] [trash] [ban]  Accept           |
///   +------------------------------------------+
///
/// The `#` is a coloured spine down the left edge, and it is what makes the
/// four rows read as one entry rather than as seven lines of grey: the thing
/// that was hard to find in the list was where an entry started, which is a
/// grouping problem and not an emphasis one. Its colour says what kind of
/// notification this is before the words do, the same way a feed row is
/// coloured by source. The type-and-date line is dimmed for the same reason:
/// it labels the entry, the two lines under it are the entry.
///
/// A line with nothing in it is skipped rather than drawn blank -- a friend
/// request carries no message, most group notices carry no sender, and an
/// empty row reads as a missing one.
///
/// The buttons carry icons instead of words: a word wide enough to read is
/// a button too wide to sit beside three others, and these are the same
/// pictures VRChat draws in its own client. The caption to their right
/// names whichever one the pointer is on, which is a desktop courtesy --
/// there is no hover in VR, and no room for it either.
///
/// Deny was removed because it sent the same "hide" as Dismiss, so the
/// trash covers both cases. Block is the answer neither of them is: a
/// dismiss ends this notification, and somebody who sends one every day
/// needs the sender ended instead. It is last in the row, furthest from
/// Accept, since those two are opposite answers to the same request.
///
/// Being destructive, it arms rather than fires: the other buttons go away,
/// Cancel takes over the square the ban was in -- the spot the finger just
/// left, so a double tap cancels -- and Confirm sits a square further right
/// on a second row. Confirming also dismisses the notification, when VRChat
/// allows that notification to be dismissed at all: a request from somebody
/// who can no longer send one is not worth answering. The armed state is
/// keyed by sender rather than by notification, so it is the same arming the
/// friend list does, and blocking clears the button from every other
/// notification that sender left behind -- `isBlocked` follows the
/// `moderations` snapshot the server sends after the call lands.
///
/// A v2 notification (group invite, join request, transfer, queue-ready)
/// names its own buttons instead, and the row draws those: VRChat writes
/// their labels, and a type this build has never heard of still gets the
/// right actions -- an unmapped one draws as dots rather than as nothing.
/// Rows that answer nothing -- an announcement, an instance closure -- keep
/// only the trash, and rows VRChat says it will clear itself get no buttons
/// at all.
///
/// Rows are oldest first and are never re-sorted (see
/// AppState.addNotification). With the buttons in the rows, anything that
/// reordered on arrival would slide a button out from under a pointer that
/// was already on its way to it,  and on a friend request the one that moves
/// into place is Accept. New notifications append to the bottom.
///
/// The list is seeded once per connect from the server's `notifications`
/// snapshot and maintained from the events after that: the WebSocket only
/// reports changes, so a request that arrived while the client was closed has
/// no event to replay.
private void drawNotificationsTab(mu_Context* ctx, AppState* state, int scrollDelta)
{
    import std.string : startsWith;

    static immutable int[1] fullCol    = [-1];
    static immutable int[2] headerCols = [-130, 120];
    enum int actionSize = 64;   // square, and big enough to hit in VR
    enum lineColor = mu_Color(50, 50, 60, 255);

    mu_begin_panel(ctx, "NotificationsPanel");

    applyScroll(ctx, scrollDelta);

    if (state.notifications.length == 0)
    {
        mu_layout_row(ctx, 1, fullCol.ptr, 0);
        mu_label(ctx, "No notifications.");
    }
    else
    {
        // Collect IDs to remove optimistically after the foreach, so we don't
        // mutate state.notifications while iterating it.
        string[] dismissedIds;

        // Header row with "Dismiss all". Queues hide actions for every
        // non-pending notification VRChat lets us dismiss.
        mu_layout_row(ctx, 2, headerCols.ptr, 30);
        mu_label(ctx, "");
        if (mu_button(ctx, "Dismiss all"))
        {
            foreach (ref NotificationEntry n; state.notifications)
            {
                if (n.actionPending || n.info.canDelete == false)
                    continue;
                state.pendingActions ~= dismissAction(n.info);
                dismissedIds ~= n.info.id;
            }
        }

        foreach (ref NotificationEntry n; state.notifications)
        {
            // Text block: type+date / from / message, each on its own row
            // across the full width.
            char[32] relBuf = void;
            const(char)[] relDate = formatRelative(n.info.receivedAtUnix, relBuf[]);
            string label = prettyNotifType(n.info.notificationType);
            char[96] headBuf = void;
            const(char)[] head = relDate.length > 0
                ? sformat(headBuf[], "%s . %s", label, relDate)
                : label;

            // A group notification has no sender to name (VRChat puts the
            // group's own ID there), so its title takes that line instead --
            // unless the title is just the type over again, which it often is.
            const(char)[] from = n.info.senderName;
            if (from.length == 0 && n.info.title != label)
                from = n.info.title;

            // The head line doubles as the top of the entry: the spine is
            // drawn at the end, once the rows below have given it a height.
            mu_layout_row(ctx, 1, fullCol.ptr, 0);
            int entryTop = notifLine(ctx, head, notifMetaColor).y;

            // An empty line is a hole rather than a blank: a friend request
            // carries no message, and most group notices carry no sender.
            if (from.length > 0)
            {
                mu_layout_row(ctx, 1, fullCol.ptr, 0);
                notifLine(ctx, from, ctx.style.colors[MU_COLOR_TEXT]);
            }
            if (n.info.message.length > 0)
            {
                mu_layout_row(ctx, 1, fullCol.ptr, 0);
                notifLine(ctx, n.info.message, ctx.style.colors[MU_COLOR_TEXT]);
            }

            // Action row underneath.
            if (n.actionPending)
            {
                mu_layout_row(ctx, 1, fullCol.ptr, actionSize);
                mu_label(ctx, "Pending...");
            }
            else
            {
                // A v2 notification's own buttons replace anything this build
                // would have guessed: a group invite is not accepted through
                // the friend-request endpoint.
                bool ownAccept = n.info.responses.length == 0
                    && n.info.notificationType == "friendRequest";

                // Block answers the whole sender rather than this one
                // notification, which is the point: dismissing a request
                // from somebody who sends another every day is not an
                // answer. Offered only for a notification from an actual
                // person -- a v2 group notification carries a grp_ ID in
                // the same field -- and only when the server is new enough
                // to moderate and does not already have them blocked.
                bool canBlock = state.serverProtocol >= PROTOCOL_MODERATION
                    && n.info.senderUserId.startsWith("usr_")
                    && state.isBlocked(n.info.senderUserId) == false;

                // A row whose own responses already dismiss it does not get
                // this build's Dismiss on top of them.
                bool ownDismiss = n.info.canDelete && hasOwnDismiss(n.info) == false;

                int buttons = cast(int) n.info.responses.length;
                if (ownAccept)
                    ++buttons;
                if (ownDismiss)
                    ++buttons;
                if (canBlock)
                    ++buttons;

                if (buttons > MU_MAX_WIDTHS - 2)
                    buttons = MU_MAX_WIDTHS - 2;

                // Block is the last square, so that is the column Cancel has
                // to take over once it is armed.
                int banColumn = buttons - 1;
                bool blockArmed = canBlock
                    && state.armedConfirm.kind == "block"
                    && state.armedConfirm.id == n.info.senderUserId;

                if (blockArmed)
                {
                    // Armed: every other button goes away and Cancel takes
                    // the square the ban was in -- the spot the finger just
                    // left -- so an accidental double tap cancels. Confirm
                    // waits on its own row, a full square further right.
                    string blockName = n.info.senderName.length > 0
                        ? n.info.senderName : n.info.senderUserId;

                    int[MU_MAX_WIDTHS] cols = void;
                    cols[0] = notifSpineGap;
                    foreach (int i; 0 .. banColumn + 1)
                        cols[i + 1] = actionSize;
                    cols[banColumn + 2] = -1;
                    mu_layout_row(ctx, banColumn + 3, cols.ptr, actionSize);
                    mu_layout_next(ctx); // the gap
                    foreach (int i; 0 .. banColumn)
                        mu_layout_next(ctx); // where the other buttons were

                    // Plain, not the cross's usual red: in an armed pair the
                    // red one has to be the button that does something, and
                    // that is Confirm. A red Cancel reads as the dangerous
                    // one and inverts the whole point of arming.
                    const(char)[] cancelLabel;
                    if (iconButton(ctx, ActionIcon.cross, actionPlainTint,
                        "Cancel", cancelLabel))
                        state.armedConfirm = ArmedConfirm.init;

                    char[128] promptBuf = void;
                    mu_draw_control_text(ctx,
                        cast(string) sformat(promptBuf, "Block %s?", blockName),
                        mu_layout_next(ctx), MU_COLOR_TEXT, 0);

                    static immutable int[4] confirmCols =
                        [notifSpineGap, actionSize, 220, -1];
                    mu_layout_row(ctx, 4, confirmCols.ptr, actionSize);
                    mu_layout_next(ctx); // the gap
                    mu_layout_next(ctx); // keeps Confirm off the Cancel square
                    if (clickButton(ctx, "Confirm Block"))
                    {
                        state.armedConfirm = ArmedConfirm.init;
                        if (state.moderationActionInFlight == false)
                        {
                            state.pendingModerationActions ~= ModerationAction(
                                n.info.senderUserId, blockName, "block");
                            setStatusFlash(state, "  Blocking...");

                            // Blocking answers the notification too: leaving
                            // it in the inbox would be a request from
                            // somebody who can no longer send one. Only when
                            // VRChat allows the hide -- a row it clears
                            // itself would just come back on the next seed.
                            if (n.info.canDelete)
                            {
                                state.pendingActions ~= dismissAction(n.info);
                                dismissedIds ~= n.info.id;
                            }
                        }
                    }
                    mu_layout_next(ctx); // right spacer
                }
                else if (buttons > 0)
                {
                    // A gap clearing the spine, a square per action, then one
                    // cell taking the rest of the width for the hover caption.
                    // Anything past the widths microui carries wraps onto a
                    // second row of the same squares, which is a shape no
                    // notification has reached but beats dropping a button.
                    int[MU_MAX_WIDTHS] cols = void;
                    cols[0] = notifSpineGap;
                    foreach (int i; 0 .. buttons)
                        cols[i + 1] = actionSize;
                    cols[buttons + 1] = -1;
                    mu_layout_row(ctx, buttons + 2, cols.ptr, actionSize);
                    mu_layout_next(ctx); // the gap

                    const(char)[] hoverLabel;

                    foreach (ref NotificationResponse response; n.info.responses)
                    {
                        ActionIcon icon = responseIcon(response);
                        // Not response.text: VRChat writes that as a sentence
                        // ("Acknowledge and dismiss this notification"), which
                        // even the caption shows the first few words of.
                        if (iconButton(ctx, icon, iconTint(icon),
                            prettyResponseLabel(response), hoverLabel))
                        {
                            // Waits for the result rather than dropping the
                            // row: the user pressed Accept on something and
                            // wants to know whether it took.
                            n.actionPending = true;
                            state.pendingActions ~= NotificationAction(n.info.id,
                                "respond", n.info.apiVersion,
                                response.type, response.data);
                        }
                    }

                    if (ownAccept)
                    {
                        if (iconButton(ctx, ActionIcon.check,
                            iconTint(ActionIcon.check), "Accept", hoverLabel))
                        {
                            // Keep pending-confirmation flow for Accept: the user
                            // wants to know whether the friendship was actually made.
                            n.actionPending = true;
                            state.pendingActions ~= NotificationAction(n.info.id,
                                "accept", n.info.apiVersion);
                        }
                    }

                    // VRChat clears some of its own (a queue-ready expires, an
                    // announcement is retracted) and refuses to be told to.
                    // Those rows are read-only rather than wearing a button
                    // that only fails.
                    if (ownDismiss)
                    {
                        if (iconButton(ctx, ActionIcon.trash,
                            iconTint(ActionIcon.trash), "Dismiss", hoverLabel))
                        {
                            state.pendingActions ~= dismissAction(n.info);
                            dismissedIds ~= n.info.id;
                        }
                    }

                    // Last, and so furthest from Accept: the two are the
                    // opposite answers to the same request, and they should
                    // not be neighbours under a thumb.
                    if (canBlock)
                    {
                        if (iconButton(ctx, ActionIcon.ban,
                            iconTint(ActionIcon.ban), "Block", hoverLabel))
                            state.armedConfirm =
                                ArmedConfirm("block", n.info.senderUserId);
                    }

                    mu_Rect caption = mu_layout_next(ctx);
                    if (hoverLabel.length > 0)
                        mu_draw_control_text(ctx, cast(string) hoverLabel,
                            caption, MU_COLOR_TEXT, 0);
                }
            }

            // Separator, and the spine spanning everything above it. Drawn
            // last because that is when the entry's height is known; nothing
            // else paints in that column, so painting over it is safe.
            mu_layout_row(ctx, 1, fullCol.ptr, 1);
            mu_Rect separator = mu_layout_next(ctx);
            mu_draw_rect(ctx, mu_Rect(separator.x, entryTop, notifSpineWidth,
                separator.y - entryTop), notifAccent(n.info.notificationType));
            mu_draw_rect(ctx, separator, lineColor);
        }

        // Apply optimistic removals.
        foreach (string id; dismissedIds)
            state.removeNotification(id);
    }

    mu_end_panel(ctx);
}

/// Width of the accent spine down the left edge of a notification entry,
/// and the gap everything else in the entry is inset by to clear it.
private enum int notifSpineWidth = 4;
private enum int notifSpineGap   = 8;

/// Ink for the type-and-date line. Dimmer than the rest: it is the label on
/// the entry, not the content of it, and three lines of identical grey was
/// the thing that made an entry hard to take in at a glance.
private enum mu_Color notifMetaColor = mu_Color(140, 145, 155, 255);

/// Colour of an entry's spine, by what kind of notification it is.
///
/// Same idea as the feed's source strip: the colour is the first thing read
/// and it answers "what is this" before any of the words do. Grouped by
/// family rather than by exact type, since the list of types grows faster
/// than a palette usefully can -- an unlisted `group.somethingNew` still
/// lands on the group colour by prefix.
///
/// Invites are blue rather than the teal they used to be. Teal sat 42 degrees
/// of hue from the green above it at much the same lightness, which is close
/// enough to confuse on a list and the pair that collapses first under
/// deuteranopia; blue is 83 away and on the axis red-green colour blindness
/// keeps. It is also lighter than the group purple, so those two separate even
/// where hue does not survive.
private mu_Color notifAccent(string notifType)
{
    import std.string : startsWith;

    switch (notifType)
    {
        case "friendRequest":
            return mu_Color(70, 200, 90, 255);      // green, someone new
        case "invite", "requestInvite",
             "requestInviteResponse", "inviteResponse":
            return mu_Color(74, 158, 255, 255);     // blue, somewhere to be
        case "votetokick", "instance.closed":
            return mu_Color(220, 70, 70, 255);      // red, something ending
        case "boop", "message":
            return mu_Color(220, 170, 60, 255);     // amber, someone talking
        default:
            break;
    }

    if (notifType.startsWith("group"))
        return mu_Color(160, 90, 220, 255);         // purple, as the feed
    return mu_Color(90, 90, 100, 255);              // grey, unlisted
}

/// One line of a notification entry: text inset past the spine, in whatever
/// ink the caller asks for. mu_draw_control_text takes a style slot rather
/// than a colour, so the slot is swapped for the call and put back -- the
/// same trick bigHeader plays with the header size.
///
/// Returns the cell it drew into, which is how the caller learns where the
/// entry starts without laying out a row it does not need.
private mu_Rect notifLine(mu_Context* ctx, const(char)[] text, mu_Color color)
{
    mu_Rect r = mu_layout_next(ctx);
    if (text.length == 0)
        return r;

    mu_Color saved = ctx.style.colors[MU_COLOR_TEXT];
    ctx.style.colors[MU_COLOR_TEXT] = color;
    mu_draw_control_text(ctx, cast(string) text,
        mu_Rect(r.x + notifSpineGap, r.y, r.w - notifSpineGap, r.h),
        MU_COLOR_TEXT, 0);
    ctx.style.colors[MU_COLOR_TEXT] = saved;
    return r;
}

/// The dismiss for one notification. Which endpoint that is depends on the
/// system it came from, so the version travels with the action.
private NotificationAction dismissAction(ref NotificationInfo info)
{
    return NotificationAction(info.id, "hide", info.apiVersion);
}

/// The picture for a v2 notification response.
///
/// The `type` is the action -- it is what gets posted back -- so it picks the
/// icon, the same way prettyResponseLabel words the caption from it. VRChat's
/// own `icon` hint is the fallback rather than the source: it is advisory,
/// often absent, and names art this build does not have. A response neither
/// names draws as dots, which at least says "there is something here to
/// press" -- the button still works, since the type travels with it.
private ActionIcon responseIcon(ref const(NotificationResponse) response)
{
    switch (response.type)
    {
        case "accept", "confirm", "yes":     return ActionIcon.check;
        case "decline", "reject", "deny",
             "no", "cancel":                 return ActionIcon.cross;
        case "delete", "acknowledge":        return ActionIcon.trash;
        case "block":                        return ActionIcon.ban;
        case "unsubscribe":                  return ActionIcon.bellSlash;
        case "join":                         return ActionIcon.join;
        case "reply":                        return ActionIcon.reply;
        default:                             break;
    }

    switch (response.icon)
    {
        case "check":       return ActionIcon.check;
        case "cancel":      return ActionIcon.cross;
        case "ban":         return ActionIcon.ban;
        case "bell-slash":  return ActionIcon.bellSlash;
        case "reply":       return ActionIcon.reply;
        default:            return ActionIcon.dots;
    }
}

/// Whether a v2 response already does what the row's own Dismiss would.
///
/// VRChat sends one of these on the rows with nothing to accept -- a group
/// post, a group join request -- and drawing the row's own Dismiss beside it
/// put two trash cans in the same row. VRChat's own wins: it is the button
/// VRChat named, and it carries whatever `data` goes back with it.
///
/// Mirrors `NOTIFY_DISMISS_TYPES` in the web front-end.
private bool responseDismisses(ref const(NotificationResponse) response)
{
    return response.type == "delete" || response.type == "acknowledge";
}

/// Whether any of a notification's own responses dismisses it.
private bool hasOwnDismiss(ref const(NotificationInfo) info)
{
    foreach (ref const(NotificationResponse) response; info.responses)
    {
        if (responseDismisses(response))
            return true;
    }
    return false;
}

/// Ink for an icon that is neither a yes nor a no.
private enum mu_Color actionPlainTint = mu_Color(205, 210, 220, 255);

/// Ink for an icon: yes is green, the two ways of saying no are red, and
/// everything else is plain. Colour is doing the same work the words used
/// to -- it is the fastest thing to read on a button with no label, and it
/// is what keeps Accept and Decline from being two grey squares.
private mu_Color iconTint(ActionIcon icon)
{
    final switch (icon)
    {
        case ActionIcon.check:
            return mu_Color(110, 210, 120, 255);
        case ActionIcon.cross:
        case ActionIcon.ban:
            return mu_Color(225, 100, 100, 255);
        case ActionIcon.trash:
        case ActionIcon.bellSlash:
        case ActionIcon.join:
        case ActionIcon.reply:
        case ActionIcon.dots:
            return actionPlainTint;
    }
}

unittest
{
    // The type names the icon even when the hint disagrees or is missing.
    NotificationResponse accept = NotificationResponse("accept", "Accept", "", "");
    assert(responseIcon(accept) == ActionIcon.check);

    NotificationResponse ack = NotificationResponse("delete",
        "Acknowledge and dismiss this notification", "check", "");
    assert(responseIcon(ack) == ActionIcon.trash);

    // Unlisted type, usable hint.
    NotificationResponse odd = NotificationResponse("mysteryAction", "", "ban", "");
    assert(responseIcon(odd) == ActionIcon.ban);

    // Neither: still a button, just an unnamed one.
    NotificationResponse blank = NotificationResponse("mysteryAction", "", "", "");
    assert(responseIcon(blank) == ActionIcon.dots);
}

/// Tools tab: utility buttons.
//
// Inventory ("STUFF") tab: gallery, icons, stickers, emoji, prints, items.
//

/// Section labels, indexed by InvSection.
private static immutable string[INV_SECTIONS] invSectionLabels =
    ["Gallery", "Icons", "Stickers", "Emoji", "Prints", "Items"];

/// Thumbnail edge size requested for grid cells.
private enum int INV_THUMBNAIL_SIZE = 256;

/// Files-API page size; a full reply page means more may follow.
private enum int INV_PAGE_SIZE = 60;

private void drawInventoryTab(mu_Context* ctx, AppState* state, int scrollDelta)
{
    if (state.invDetailOpen)
    {
        drawInventoryDetailPage(ctx, state, scrollDelta);
        return;
    }

    static immutable int[1] fullCol = [-1];
    int sec = cast(int) state.invSection;

    mu_begin_panel(ctx, "InventoryPanel");
    applyScroll(ctx, scrollDelta);
    mu_Container* panel = mu_get_current_container(ctx);
    int bodyW = panel.body_.w;

    // Auto-load the visible section (initial view, reconnect, or a
    // content-refresh event marking it stale).
    if (state.connected && state.invLoading[sec] == false
        && (state.invLoaded[sec] == false || state.invStale[sec]))
        state.invRefreshRequested = true;

    // Section selector row.
    enum PADDING = 4;
    int secWidth = (bodyW - (PADDING * (INV_SECTIONS + 1))) / INV_SECTIONS;
    int[INV_SECTIONS] secCols = [secWidth, secWidth, secWidth, secWidth, secWidth, -1];
    mu_layout_row(ctx, INV_SECTIONS, secCols.ptr, 50);
    foreach (int i; 0 .. INV_SECTIONS)
    {
        InvSection section = cast(InvSection) i;
        if (state.invSection == section)
        {
            mu_Rect r = mu_layout_next(ctx);
            mu_draw_rect(ctx, r, mu_Color(60, 80, 120, 255));
            mu_draw_control_text(ctx, invSectionLabels[i], r, MU_COLOR_TEXT, MU_OPT_ALIGNCENTER);
        }
        else if (mu_button(ctx, invSectionLabels[i]))
        {
            state.invSection = section;
            state.armedConfirm = ArmedConfirm.init;
        }
    }
    // The selector row may have just switched sections; everything below
    // must index state arrays with the fresh value.
    sec = cast(int) state.invSection;

    // Status row: count/loading state + Refresh.
    char[96] statusBuf = void;
    const(char)[] status;
    if (state.connected == false)
        status = "Not connected";
    else if (state.invLoading[sec])
        status = "Loading...";
    else if (state.invError[sec].length > 0)
        status = state.invError[sec];
    else
    {
        final switch (state.invSection) with (InvSection)
        {
        case stickers:
            // The exclusive count is said only once there is one: a server too
            // old to have that listing would otherwise report zero of them.
            status = state.invStickerItems.length > 0
                ? sformat(statusBuf, "%d file(s), %d exclusive",
                    state.invFiles[sec].length, state.invStickerItems.length)
                : sformat(statusBuf, "%d file(s)", state.invFiles[sec].length);
            break;
        case gallery, icons, emoji:
            status = sformat(statusBuf, "%d file(s)", state.invFiles[sec].length);
            break;
        case prints:
            status = sformat(statusBuf, "%d print(s)", state.invPrints.length);
            break;
        case items:
            status = sformat(statusBuf, "%d item(s) of %d", state.invItems.length,
                state.invItemsTotal);
            break;
        }
    }
    int[2] statusCols = [-130, -1];
    mu_layout_row(ctx, 2, statusCols.ptr, 40);
    // Safe cast: mu_draw_text copies the text into the command queue.
    mu_label(ctx, cast(string) status);
    if (clickButton(ctx, "Refresh") && state.invLoading[sec] == false)
        state.invRefreshRequested = true;

    // Upload row for uploadable sections.
    if (state.invSection != InvSection.items)
        drawInventoryUploadRow(ctx, state);

    // Thumbnail grid.
    final switch (state.invSection) with (InvSection)
    {
    case gallery, icons, stickers, emoji:
        drawFilesGrid(ctx, state, panel);
        break;
    case prints:
        drawPrintsGrid(ctx, state, panel);
        break;
    case items:
        drawItemsGrid(ctx, state, panel);
        break;
    }

    mu_end_panel(ctx);
}

/// Upload row: first dropped file + note textbox (prints) + Upload button.
private void drawInventoryUploadRow(mu_Context* ctx, AppState* state)
{
    import std.path : baseName;

    static immutable int[1] fullCol = [-1];

    if (state.invSection == InvSection.prints)
    {
        // File label | note textbox | button.
        int[3] cols = [-400, -130, -1];
        mu_layout_row(ctx, 3, cols.ptr, 40);
        mu_label(ctx, state.droppedFiles.length > 0
            ? baseName(state.droppedFiles[0])
            : "Drop a PNG onto the window to upload");
        mu_textbox(ctx, state.invUploadNote.ptr, cast(int) state.invUploadNote.length);
        if (clickButton(ctx, state.invUploadInFlight ? "Uploading..." : "Upload")
            && state.invUploadInFlight == false)
            state.invUploadRequested = true;
    }
    else
    {
        int[2] cols = [-130, -1];
        mu_layout_row(ctx, 2, cols.ptr, 40);
        mu_label(ctx, state.droppedFiles.length > 0
            ? baseName(state.droppedFiles[0])
            : "Drop a PNG onto the window to upload");
        if (clickButton(ctx, state.invUploadInFlight ? "Uploading..." : "Upload")
            && state.invUploadInFlight == false)
            state.invUploadRequested = true;
    }

    if (state.invUploadStatus.length > 0)
    {
        mu_layout_row(ctx, 1, fullCol.ptr, 0);
        mu_label(ctx, state.invUploadStatus);
    }
}

/// Lay out the next grid row when `index` starts one. Returns cells/row.
private int gridRow(mu_Context* ctx, size_t index, int bodyW)
{
    int columns = bodyW / 170;
    if (columns < 2)
        columns = 2;
    if (columns > 8)
        columns = 8;
    if (index % columns == 0)
    {
        int[8] cols;
        int cellW = bodyW / columns - ctx.style.spacing;
        foreach (int c; 0 .. columns)
            cols[c] = cellW;
        cols[columns - 1] = -1;
        mu_layout_row(ctx, columns, cols.ptr, 150);
    }
    return columns;
}

/// Whether a cell rect is (vertically) inside the panel body; used to
/// avoid requesting thumbnails for cells scrolled out of view.
private bool cellVisible(mu_Rect r, mu_Container* panel)
{
    return r.y + r.h >= panel.body_.y && r.y <= panel.body_.y + panel.body_.h;
}

/// A clickable thumbnail cell: image (or placeholder) + caption strip.
/// Enqueues the thumbnail request when visible and not yet resident.
private bool imageCell(mu_Context* ctx, AppState* state, mu_Container* panel,
    string fileId, long fileVersion, const(char)[] caption)
{
    mu_Rect r = mu_layout_next(ctx);
    bool mouseOver = mu_mouse_over(ctx, r) != 0;
    mu_draw_frame(ctx, r, MU_COLOR_BUTTON + (mouseOver && !ctx.mouse_down ? 1 : 0));

    if (fileId.length > 0 && fileVersion > 0)
    {
        string key = imageKey(fileId, fileVersion, INV_THUMBNAIL_SIZE);
        int iconId = getIconId(key);
        if (iconId > 0)
        {
            mu_draw_icon(ctx, iconId, r, mu_Color(255, 255, 255, 255));
        }
        else if (key in state.failedImages)
        {
            mu_draw_control_text(ctx, "unavailable", r, MU_COLOR_TEXT, MU_OPT_ALIGNCENTER);
        }
        else
        {
            mu_draw_control_text(ctx, "...", r, MU_COLOR_TEXT, MU_OPT_ALIGNCENTER);
            if (cellVisible(r, panel))
                state.pendingImageRequests ~= ImageRequest(fileId, fileVersion, INV_THUMBNAIL_SIZE);
        }
    }
    else
    {
        mu_draw_control_text(ctx, "no image", r, MU_COLOR_TEXT, MU_OPT_ALIGNCENTER);
    }

    if (caption.length > 0)
    {
        mu_Rect cap = mu_Rect(r.x, r.y + r.h - 24, r.w, 24);
        mu_draw_rect(ctx, cap, mu_Color(0, 0, 0, 170));
        // Safe cast: mu_draw_text copies the text into the command queue.
        mu_draw_control_text(ctx, cast(string) caption, cap, MU_COLOR_TEXT, MU_OPT_ALIGNCENTER);
    }

    if (wasClick && mouseOver)
    {
        wasClick = false;
        return true;
    }
    return false;
}

/// A heading banner spanning the panel width, for a section drawn as more
/// than one group.
private void groupHeading(mu_Context* ctx, const(char)[] text)
{
    static immutable int[1] fullCol = [-1];

    mu_layout_row(ctx, 1, fullCol.ptr, 34);
    mu_Rect head = mu_layout_next(ctx);
    mu_draw_rect(ctx, head, mu_Color(45, 55, 75, 255));
    // Safe cast: mu_draw_text copies the text into the command queue.
    mu_draw_control_text(ctx, cast(string) text, head, MU_COLOR_TEXT, 0);
}

private void drawFilesGrid(mu_Context* ctx, AppState* state, mu_Container* panel)
{
    static immutable int[1] fullCol = [-1];
    int sec = cast(int) state.invSection;

    // Stickers come from two places: files this account uploaded, and the ones
    // VRChat handed out, which are inventory items. Headings appear only once
    // there is a second group to tell apart from the first.
    bool grouped = state.invSection == InvSection.stickers
        && (state.invStickerItems.length > 0
            || state.invStickerItemsError.length > 0
            || state.invStickerItemsLoading);
    if (grouped)
        groupHeading(ctx, "Uploaded");

    foreach (size_t i, ref ContentFile f; state.invFiles[sec])
    {
        gridRow(ctx, i, panel.body_.w);
        if (imageCell(ctx, state, panel, f.fileId, f.fileVersion, f.name))
        {
            state.selectedInvFile = f;
            state.invStickerItemSelected = false;
            state.invDetailOpen = true;
            state.armedConfirm = ArmedConfirm.init;
            requestRepaint();
        }
    }

    if (state.invMoreAvailable[sec])
    {
        mu_layout_row(ctx, 1, fullCol.ptr, 50);
        if (clickButton(ctx, state.invLoading[sec] ? "Loading..." : "Load more"))
            state.invLoadMoreRequested = true;
    }

    if (grouped == false)
        return;

    groupHeading(ctx, "Exclusive");
    if (state.invStickerItemsError.length > 0)
    {
        mu_layout_row(ctx, 1, fullCol.ptr, 0);
        mu_label(ctx, state.invStickerItemsError);
        return;
    }
    foreach (size_t i, ref InventoryEntry it; state.invStickerItems)
    {
        gridRow(ctx, i, panel.body_.w);
        if (imageCell(ctx, state, panel, it.imageFileId, it.imageVersion, it.name))
        {
            state.selectedInvItem = it;
            state.invStickerItemSelected = true;
            state.invDetailOpen = true;
            state.armedConfirm = ArmedConfirm.init;
            requestRepaint();
        }
    }
}

private void drawPrintsGrid(mu_Context* ctx, AppState* state, mu_Container* panel)
{
    foreach (size_t i, ref PrintEntry p; state.invPrints)
    {
        gridRow(ctx, i, panel.body_.w);
        const(char)[] caption = p.note.length > 0 ? p.note : p.worldName;
        if (imageCell(ctx, state, panel, p.fileId, p.fileVersion, caption))
        {
            state.selectedInvPrint = p;
            state.invDetailOpen = true;
            state.armedConfirm = ArmedConfirm.init;
            requestRepaint();
        }
    }
}

/// The heading an item falls under: its item-type label ("Drone", "Item",
/// ...), falling back to the raw type or a catch-all bucket.
private const(char)[] itemCategory(ref InventoryEntry it)
{
    if (it.itemTypeLabel.length > 0)
        return it.itemTypeLabel;
    if (it.itemType.length > 0)
        return it.itemType;
    return "Other";
}

private void drawItemsGrid(mu_Context* ctx, AppState* state, mu_Container* panel)
{
    static immutable int[1] fullCol = [-1];

    // Distinct categories in first-seen order. Item count is small (the
    // server caps at 500) and categories are few, so a linear scan per
    // group is cheap and avoids per-frame allocation.
    const(char)[][32] cats = void;
    size_t catCount;
    foreach (ref InventoryEntry it; state.invItems)
    {
        const(char)[] cat = itemCategory(it);
        bool seen;
        foreach (size_t c; 0 .. catCount)
            if (cats[c] == cat)
            {
                seen = true;
                break;
            }
        if (seen == false && catCount < cats.length)
            cats[catCount++] = cat;
    }

    foreach (size_t c; 0 .. catCount)
    {
        const(char)[] cat = cats[c];
        groupHeading(ctx, cat);

        // This category's items, indexed within the group so each group
        // packs a fresh set of rows under its heading.
        size_t index;
        foreach (ref InventoryEntry it; state.invItems)
        {
            if (itemCategory(it) != cat)
                continue;
            gridRow(ctx, index, panel.body_.w);
            index++;
            if (imageCell(ctx, state, panel, it.imageFileId, it.imageVersion, it.name))
            {
                state.selectedInvItem = it;
                state.invDetailOpen = true;
                state.armedConfirm = ArmedConfirm.init;
                requestRepaint();
            }
        }
    }
}

/// Detail page: full-size image, metadata, and management actions for the
/// selected entry of the current section.
private void drawInventoryDetailPage(mu_Context* ctx, AppState* state, int scrollDelta)
{
    static immutable int[1] fullCol = [-1];

    mu_begin_panel(ctx, "InventoryDetailPanel");
    applyScroll(ctx, scrollDelta);
    mu_Container* panel = mu_get_current_container(ctx);

    // Navigation back to the list is the sticky header Back button.

    // An exclusive sticker is an inventory item, whichever section it was
    // opened from, so it is drawn as one.
    bool asItem = state.invSection == InvSection.items
        || (state.invSection == InvSection.stickers && state.invStickerItemSelected);

    // Resolve the selected entry's image reference per section, plus what to
    // call it in a saved file.
    string fileId;
    long fileVersion;
    string entryName;
    if (asItem)
    {
        fileId = state.selectedInvItem.imageFileId;
        fileVersion = state.selectedInvItem.imageVersion;
        entryName = state.selectedInvItem.name;
    }
    else if (state.invSection == InvSection.prints)
    {
        fileId = state.selectedInvPrint.fileId;
        fileVersion = state.selectedInvPrint.fileVersion;
        entryName = state.selectedInvPrint.note.length > 0
            ? state.selectedInvPrint.note
            : state.selectedInvPrint.worldName;
    }
    else
    {
        fileId = state.selectedInvFile.fileId;
        fileVersion = state.selectedInvFile.fileVersion;
        entryName = state.selectedInvFile.name;
    }

    // Full image (size 0 = original file), letterboxed into a tall row.
    int imageH = window_height / 2;
    if (imageH < 200)
        imageH = 200;
    mu_layout_row(ctx, 1, fullCol.ptr, imageH);
    mu_Rect imgRect = mu_layout_next(ctx);
    if (fileId.length > 0 && fileVersion > 0)
    {
        string key = imageKey(fileId, fileVersion, 0);
        int iconId = getIconId(key);
        if (iconId > 0)
            mu_draw_icon(ctx, iconId, imgRect, mu_Color(255, 255, 255, 255));
        else if (key in state.failedImages)
            mu_draw_control_text(ctx, "Image unavailable", imgRect, MU_COLOR_TEXT, MU_OPT_ALIGNCENTER);
        else
        {
            mu_draw_control_text(ctx, "Loading image...", imgRect, MU_COLOR_TEXT, MU_OPT_ALIGNCENTER);
            state.pendingImageRequests ~= ImageRequest(fileId, fileVersion, 0);
        }
    }
    else
        mu_draw_control_text(ctx, "No image", imgRect, MU_COLOR_TEXT, MU_OPT_ALIGNCENTER);

    // Metadata + actions per section.
    final switch (asItem ? InvSection.items : state.invSection) with (InvSection)
    {
    case gallery, icons, stickers, emoji:
        if (state.selectedInvFile.name.length > 0)
        {
            mu_layout_row(ctx, 1, fullCol.ptr, 0);
            mu_label(ctx, state.selectedInvFile.name);
        }
        mu_layout_row(ctx, 1, fullCol.ptr, 0);
        clickableValue(ctx, state, state.selectedInvFile.fileId);

        spacer(ctx);
        if (state.invSection == icons)
        {
            mu_layout_row(ctx, 1, fullCol.ptr, 60);
            if (clickButton(ctx, "Set as Profile Icon") && state.invActionInFlight == false)
                state.pendingContentActions ~= ContentAction("set_icon", state.selectedInvFile.fileId);
            mu_layout_row(ctx, 1, fullCol.ptr, 60);
            if (clickButton(ctx, "Clear Profile Icon") && state.invActionInFlight == false)
                state.pendingContentActions ~= ContentAction("set_icon", "");
        }
        drawDownloadButton(ctx, state, fileId, fileVersion, entryName);
        drawDeleteButton(ctx, state, "delete_file", state.selectedInvFile.fileId);
        break;

    case prints:
        if (state.selectedInvPrint.note.length > 0)
        {
            mu_layout_row(ctx, 1, fullCol.ptr, 0);
            mu_label(ctx, state.selectedInvPrint.note);
        }
        if (state.selectedInvPrint.worldName.length > 0)
        {
            mu_layout_row(ctx, 1, fullCol.ptr, 0);
            mu_label(ctx, state.selectedInvPrint.worldName);
        }
        if (state.selectedInvPrint.timestamp.length > 0)
        {
            mu_layout_row(ctx, 1, fullCol.ptr, 0);
            mu_label(ctx, state.selectedInvPrint.timestamp);
        }
        mu_layout_row(ctx, 1, fullCol.ptr, 0);
        clickableValue(ctx, state, state.selectedInvPrint.printId);

        spacer(ctx);
        drawDownloadButton(ctx, state, fileId, fileVersion, entryName);
        drawDeleteButton(ctx, state, "delete_print", state.selectedInvPrint.printId);
        break;

    case items:
        if (state.selectedInvItem.name.length > 0)
        {
            mu_layout_row(ctx, 1, fullCol.ptr, 0);
            mu_label(ctx, state.selectedInvItem.name);
        }
        if (state.selectedInvItem.itemTypeLabel.length > 0)
        {
            mu_layout_row(ctx, 1, fullCol.ptr, 0);
            mu_label(ctx, state.selectedInvItem.itemTypeLabel);
        }
        if (state.selectedInvItem.description.length > 0)
        {
            mu_layout_row(ctx, 1, fullCol.ptr, 0);
            mu_label(ctx, state.selectedInvItem.description);
        }
        mu_layout_row(ctx, 1, fullCol.ptr, 0);
        clickableValue(ctx, state, state.selectedInvItem.id);

        spacer(ctx);
        bool equippable;
        bool consumable;
        foreach (string flag; state.selectedInvItem.flags)
        {
            if (flag == "equippable") equippable = true;
            if (flag == "consumable") consumable = true;
        }
        if (equippable && state.selectedInvItem.equipSlot.length > 0)
        {
            mu_layout_row(ctx, 1, fullCol.ptr, 60);
            if (clickButton(ctx, "Equip") && state.invActionInFlight == false)
                state.pendingContentActions ~= ContentAction("equip",
                    state.selectedInvItem.id, state.selectedInvItem.equipSlot);
            mu_layout_row(ctx, 1, fullCol.ptr, 60);
            if (clickButton(ctx, "Unequip") && state.invActionInFlight == false)
                state.pendingContentActions ~= ContentAction("unequip",
                    state.selectedInvItem.id, state.selectedInvItem.equipSlot);
        }
        if (consumable)
        {
            mu_layout_row(ctx, 1, fullCol.ptr, 60);
            if (clickButton(ctx, "Consume") && state.invActionInFlight == false)
                state.pendingContentActions ~= ContentAction("consume",
                    state.selectedInvItem.id);
        }
        // An item has nothing to delete, so this is the end of the row rather
        // than the step before it.
        drawDownloadButton(ctx, state, fileId, fileVersion, entryName);
        break;
    }

    if (state.invActionInFlight)
    {
        mu_layout_row(ctx, 1, fullCol.ptr, 0);
        mu_label(ctx, "Working...");
    }

    mu_end_panel(ctx);
}

/// Keeping the file itself, offered beside the section's own actions rather
/// than under the picture: the entry's name and tags are worth reading as one
/// block, and a button in the middle of them splits it.
private void drawDownloadButton(mu_Context* ctx, AppState* state, string fileId,
    long fileVersion, const(char)[] name)
{
    static immutable int[1] fullCol = [-1];

    if (fileId.length == 0 || fileVersion <= 0)
        return;

    mu_layout_row(ctx, 1, fullCol.ptr, 60);
    if (clickButton(ctx, "Download Image"))
        downloadInventoryImage(state, fileId, fileVersion, name);
}

/// Write the shown image into the user's Downloads folder, saying where it
/// went in the status bar. The bytes come from the disk cache the detail view
/// already filled, so nothing is fetched here; a picture still on its way has
/// nothing to save yet.
private void downloadInventoryImage(AppState* state, string fileId, long fileVersion,
    const(char)[] name)
{
    import client.directories : userDownloadsDir;
    import client.imagecache : exportCachedImage;

    string saved = exportCachedImage(imageKey(fileId, fileVersion, 0), name,
        userDownloadsDir());
    setStatusFlash(state, saved.length > 0
        ? "  Saved to " ~ saved
        : "  Image is still loading", 4000);
}

/// Two-tap delete button (non-aligned confirm; see confirmButton).
private void drawDeleteButton(mu_Context* ctx, AppState* state, string kind, string id)
{
    if (confirmButton(ctx, state, "delete", id, "Delete", "Confirm Delete"))
    {
        if (state.invActionInFlight == false && id.length > 0)
            state.pendingContentActions ~= ContentAction(kind, id);
    }
}

/// "Video" section of the Tools tab: shows whether VRChat's bundled yt-dlp
/// is currently enabled and offers a button to toggle it. Disabling it stops
/// VRChat's in-world video players from resolving URLs (YouTube, Twitch,
/// etc), which sidesteps yt-dlp hangs/crashes some Linux/Proton setups hit.
/// VRChat may restore its own copy on the next game update.
private void drawYtdlpControl(mu_Context* ctx, AppState* state)
{
    import client.ytdlp : queryYtdlpState, toggleYtdlp, YtdlpState;

    static immutable int[1] fullCol = [-1];

    YtdlpState ytState = queryYtdlpState();
    string statusLabel;
    final switch (ytState) with (YtdlpState)
    {
        case enabled:  statusLabel = "yt-dlp: enabled";   break;
        case disabled: statusLabel = "yt-dlp: disabled"; break;
        case missing:  statusLabel = "yt-dlp: not found (start VRChat once first)"; break;
    }

    mu_layout_row(ctx, 1, fullCol.ptr, 0);
    mu_label(ctx, statusLabel);

    if (ytState == YtdlpState.missing)
        return;

    string btnLabel = ytState == YtdlpState.enabled ? "Disable yt-dlp" : "Enable yt-dlp";
    mu_layout_row(ctx, 1, fullCol.ptr, 60);
    if (clickButton(ctx, btnLabel))
    {
        bool wasEnabled = ytState == YtdlpState.enabled;
        if (toggleYtdlp())
            setStatusFlash(state, wasEnabled ? "  yt-dlp disabled" : "  yt-dlp re-enabled");
        else
            setStatusFlash(state, "  yt-dlp toggle failed, see logs");
        requestRepaint();
    }
}

private void drawToolsTab(mu_Context* ctx, AppState* state, int scrollDelta)
{
    final switch (state.toolsPage)
    {
        case ToolsPage.main:          break;
        case ToolsPage.stripMetadata: drawStripMetadataPage(ctx, state);              return;
        case ToolsPage.friendList:    drawFriendListPage(ctx, state, scrollDelta);    return;
        case ToolsPage.muteList:      drawModerationListPage(ctx, state, scrollDelta, true);  return;
        case ToolsPage.blockList:     drawModerationListPage(ctx, state, scrollDelta, false); return;
    }

    static immutable int[1] fullCol  = [-1];
    static immutable int    COLCOUNT = cast(int) fullCol.length;
    mu_begin_panel(ctx, "ToolsPanel");

    applyScroll(ctx, scrollDelta);

    sectionHeader(ctx, "Social");

    mu_layout_row(ctx, COLCOUNT, fullCol.ptr, 60);
    if (clickButton(ctx, "Friend List"))
        state.toolsPage = ToolsPage.friendList;

    mu_layout_row(ctx, COLCOUNT, fullCol.ptr, 60);
    if (clickButton(ctx, "Muted Users"))
    {
        state.toolsPage = ToolsPage.muteList;
        if (state.moderationsLoaded == false)
            state.refreshModerationsRequested = true;
    }

    mu_layout_row(ctx, COLCOUNT, fullCol.ptr, 60);
    if (clickButton(ctx, "Blocked Users"))
    {
        state.toolsPage = ToolsPage.blockList;
        if (state.moderationsLoaded == false)
            state.refreshModerationsRequested = true;
    }

    spacer(ctx);
    sectionHeader(ctx, "Pictures");

    mu_layout_row(ctx, COLCOUNT, fullCol.ptr, 60);
    if (clickButton(ctx, "Open Pictures Folder"))
    {
        import client.directories : vrchatPicturesDir;
        openFolder(vrchatPicturesDir());
    }

    mu_layout_row(ctx, COLCOUNT, fullCol.ptr, 60);
    if (clickButton(ctx, "Open Steam Screenshots"))
    {
        import client.directories : steamScreenshotDir;
        openFolder(steamScreenshotDir());
    }

    mu_layout_row(ctx, COLCOUNT, fullCol.ptr, 60);
    if (clickButton(ctx, "Strip Metadata"))
    {
        state.toolsPage = ToolsPage.stripMetadata;
    }

    spacer(ctx);
    sectionHeader(ctx, "Video");
    drawYtdlpControl(ctx, state);

    spacer(ctx);
    sectionHeader(ctx, "Drop a Portal");

    if (state.dapPairState == AppState.DapPairState.unknown)
    {
        // We don't yet know the server's pair state (just connected, or
        // disconnected). Show a passive label instead of a Pair/Unpair
        // button so a stray click can't fire a spurious pairing request.
        mu_layout_row(ctx, COLCOUNT, fullCol.ptr, 0);
        mu_label(ctx, state.connected ? "Checking pairing status..." : "Not connected");
    }
    else
    {
        if (state.dapStatus.length > 0)
        {
            mu_layout_row(ctx, COLCOUNT, fullCol.ptr, 0);
            mu_label(ctx, state.dapStatus);
        }
        mu_layout_row(ctx, COLCOUNT, fullCol.ptr, 60);
        if (state.dapStatus.length > 0)
        {
            if (clickButton(ctx, "Unpair"))
                state.dapUnpairRequested = true;
        }
        else
        {
            if (clickButton(ctx, "Pair"))
                state.dapPairRequested = true;
        }
    }

    spacer(ctx);
    sectionHeader(ctx, "Diagnostics");

    mu_layout_row(ctx, COLCOUNT, fullCol.ptr, 60);
    if (clickButton(ctx, "Open VRChat Logs Folder"))
    {
        import client.directories : vrchatLogDir;
        openFolder(vrchatLogDir());
    }
    if (clickButton(ctx, "Open VRCD Logs Folder"))
    {
        import client.directories : vrcdAppDataPath;
        openFolder(vrcdAppDataPath());
    }

    mu_layout_row(ctx, COLCOUNT, fullCol.ptr, 60);
    if (clickButton(ctx, "Inject Test Notification"))
    {
        import std.datetime.systime : Clock;
        import std.conv : to;
        // Synthetic id with "test_" prefix so the server-bound action would
        // be a no-op if accidentally dispatched, and unique per click so the
        // dedup in addNotification doesn't swallow repeats.
        string stamp = to!string(Clock.currTime.toUnixTime!long());
        string id = "test_" ~ stamp;
        NotificationInfo test;
        test.id = id;
        test.notificationType = "friendRequest";
        // An invented sender, so the row draws its Block button and the
        // arm-and-confirm can be walked through -- that flow is the hardest
        // part of the inbox to get in front of, since a real friend request
        // arrives when somebody sends one. The "usr_test_" prefix keeps the
        // moderation inside the client (see the drain in gui.d): there is
        // nobody behind this ID for VRChat to be asked about.
        test.senderUserId = "usr_test_" ~ stamp;
        test.senderName = "TestUser";
        test.message = "Synthetic friend request";
        test.receivedAtUnix = Clock.currTime.toUnixTime!long();
        state.addNotification(test);
    }

    mu_end_panel(ctx);
}

/// Strip metadata sub-page: drop PNGs, batch-strip iTXt chunks.
private void drawStripMetadataPage(mu_Context* ctx, AppState* state)
{
    import std.path : baseName;
    import std.format : sformat;

    static immutable int[1] fullCol = [-1];

    mu_begin_panel(ctx, "StripMetadataPanel");

    // Navigation back to TOOLS is the sticky header Back button.

    // Header line.
    char[64] buffer = void;
    mu_layout_row(ctx, 1, fullCol.ptr, 0);
    if (state.droppedFiles.length == 0)
        mu_label(ctx, "Drop one or more PNG files onto this window.");
    else
        mu_label(ctx, cast(string) sformat(buffer, "Queue: %d file(s)", state.droppedFiles.length));

    // Queue list: one row per file with a remove button.
    int[2] queueCols = [-80, -1];
    size_t removeIndex = size_t.max;
    foreach (size_t i, string path; state.droppedFiles)
    {
        mu_push_id(ctx, &i, i.sizeof);
        mu_layout_row(ctx, 2, queueCols.ptr, 40);
        mu_label(ctx, baseName(path));
        if (mu_button(ctx, "X"))
            removeIndex = i;
        mu_pop_id(ctx);
    }
    if (removeIndex != size_t.max)
    {
        state.droppedFiles = state.droppedFiles[0 .. removeIndex]
            ~ state.droppedFiles[removeIndex + 1 .. $];
    }

    // Strip + Clear + Open folder buttons.
    int third = mu_get_current_container(ctx).body_.w / 3;
    int[3] thirdCols = [third, third, -1];
    mu_layout_row(ctx, 3, thirdCols.ptr, 60);
    if (mu_button(ctx, "Strip All"))
    {
        stripDroppedFiles(state);
    }
    if (mu_button(ctx, "Clear"))
    {
        state.droppedFiles = null;
        state.stripStatus = null;
    }
    if (mu_button(ctx, "Open Folder"))
    {
        openDroppedFileFolder(state);
    }

    // Status message.
    if (state.stripStatus.length > 0)
    {
        mu_layout_row(ctx, 1, fullCol.ptr, 0);
        mu_label(ctx, state.stripStatus);
    }

    mu_end_panel(ctx);
}

/// Build the -stripped.png output path, or null if not a .png.
private string stripOutputPath(string path)
{
    import std.uni : toLower;
    import std.path : dirName, baseName, buildPath;
    import std.string : endsWith;

    if (endsWith(toLower(path), ".png") == 0)
        return null;

    string base = baseName(path);
    string dir = dirName(path);
    return buildPath(dir, base[0 .. $ - 4] ~ "-stripped.png");
}

/// Strip iTXt metadata from every queued PNG. Successful entries are removed.
private void stripDroppedFiles(AppState* state)
{
    import client.png : PNG;
    import std.format : format;

    if (state.droppedFiles.length == 0)
    {
        state.stripStatus = "Queue is empty. Drop PNG files onto this window.";
        return;
    }

    string[] remaining;
    size_t okCount;
    size_t failCount;
    string firstError;

    foreach (string path; state.droppedFiles)
    {
        string outputPath = stripOutputPath(path);
        if (outputPath is null)
        {
            failCount++;
            if (firstError.length == 0)
                firstError = "Not a PNG: " ~ path;
            remaining ~= path;
            continue;
        }

        try
        {
            PNG png = PNG(path);
            png.strip(outputPath);
            png.close();
            okCount++;
        }
        catch (Exception e)
        {
            failCount++;
            if (firstError.length == 0)
                firstError = e.msg;
            remaining ~= path;
        }
    }

    state.droppedFiles = remaining;

    if (failCount == 0)
        state.stripStatus = format("Stripped %d file(s).", okCount);
    else
        state.stripStatus = format("Stripped %d, failed %d. First error: %s",
            okCount, failCount, firstError);
}

/// Open the folder containing the first queued file.
private void openDroppedFileFolder(AppState* state)
{
    import std.path : dirName;

    if (state.droppedFiles.length == 0)
        return;

    openFolder( dirName(state.droppedFiles[0]) );
}

/// TOOLS > Friend List: flat roster with mute/block/unfriend management.
private void drawFriendListPage(mu_Context* ctx, AppState* state, int scrollDelta)
{
    static immutable int[1] fullCol = [-1];

    mu_begin_panel(ctx, "FriendListPanel");
    applyScroll(ctx, scrollDelta);

    // Navigation back to TOOLS is the sticky header Back button.

    char[64] countBuffer = void;
    mu_layout_row(ctx, 1, fullCol.ptr, 0);
    mu_label(ctx, cast(string) sformat(countBuffer, "Friends: %d", state.allFriends.length));

    bool canManage = state.connected && state.serverProtocol >= PROTOCOL_MODERATION;
    if (state.connected && canManage == false)
    {
        mu_layout_row(ctx, 1, fullCol.ptr, 0);
        mu_label(ctx, "Server too old for management actions (needs protocol 3).");
    }

    if (state.allFriends.length == 0)
    {
        mu_layout_row(ctx, 1, fullCol.ptr, 0);
        mu_label(ctx, "No friend data yet.");
    }

    foreach (size_t i, ref FriendInfo f; state.allFriends)
        drawFriendManageRow(ctx, state, f, canManage, i);

    if (state.moderationActionInFlight)
    {
        mu_layout_row(ctx, 1, fullCol.ptr, 0);
        mu_label(ctx, "Working...");
    }

    mu_end_panel(ctx);
}

/// Background for odd rows in management lists: a full-width band that
/// binds a name to its buttons so the eye doesn't lose the row.
private enum mu_Color manageRowBg = mu_Color(40, 44, 54, 255);
/// Warm-tinted band for a row with an armed destructive confirmation.
private enum mu_Color manageArmedBg = mu_Color(64, 44, 46, 255);

/// Draw the zebra band behind the current row and return the first cell.
/// Call right after mu_layout_row; the band spans the panel body width and
/// widgets drawn afterwards land on top of it.
private mu_Rect manageRowBand(mu_Context* ctx, size_t index, mu_Color armed = mu_Color.init,
    int extraH = 0)
{
    mu_Rect cell = mu_layout_next(ctx);
    mu_Rect body_ = mu_get_current_container(ctx).body_;
    if (armed != mu_Color.init)
        mu_draw_rect(ctx, mu_Rect(body_.x, cell.y, body_.w, cell.h + extraH), armed);
    else if (index % 2)
        mu_draw_rect(ctx, mu_Rect(body_.x, cell.y, body_.w, cell.h + extraH), manageRowBg);
    return cell;
}

/// One friend row for the management list: name plus Mute/Block/Unfriend.
/// When Block or Unfriend is armed for this row, Cancel takes over the
/// button column (where the finger just was) and Confirm appears on the
/// opposite side of a second row, so an accidental double tap cancels.
private void drawFriendManageRow(mu_Context* ctx, AppState* state, ref FriendInfo f,
    bool canManage, size_t index)
{
    int padX = ctx.style.padding;

    if (canManage == false)
    {
        static immutable int[1] fullCol = [-1];
        mu_layout_row(ctx, 1, fullCol.ptr, 40);
        mu_Rect cell = manageRowBand(ctx, index);
        mu_draw_control_text(ctx, f.displayName,
            mu_Rect(cell.x + padX, cell.y, cell.w - padX, cell.h), MU_COLOR_TEXT, 0);
        return;
    }

    string armedKind;
    if (state.armedConfirm.id == f.userId)
        armedKind = state.armedConfirm.kind;

    if (armedKind == "block" || armedKind == "unfriend")
    {
        // Prompt on the left, Cancel over the old button column. The armed
        // band covers both rows so the pending action reads as one unit.
        static immutable int[2] armedCols = [-260, -1];
        char[128] buffer = void;
        mu_layout_row(ctx, 2, armedCols.ptr, 56);
        mu_Rect promptCell = manageRowBand(ctx, index, manageArmedBg,
            56 + ctx.style.spacing);
        mu_draw_control_text(ctx,
            cast(string) sformat(buffer, "%s %s?",
                armedKind == "block" ? "Block" : "Unfriend", f.displayName),
            mu_Rect(promptCell.x + padX, promptCell.y, promptCell.w - padX, promptCell.h),
            MU_COLOR_TEXT, 0);
        if (clickButton(ctx, "Cancel"))
            state.armedConfirm = ArmedConfirm.init;

        // Confirm goes bottom-left, away from the button column above.
        static immutable int[2] confirmCols = [220, -1];
        mu_layout_row(ctx, 2, confirmCols.ptr, 56);
        if (clickButton(ctx, armedKind == "block" ? "Confirm Block" : "Confirm Unfriend"))
        {
            state.armedConfirm = ArmedConfirm.init;
            if (state.moderationActionInFlight == false)
                state.pendingModerationActions ~= ModerationAction(f.userId, f.displayName, armedKind);
        }
        mu_layout_next(ctx); // right spacer
        return;
    }

    bool muted = state.isMuted(f.userId);
    bool blocked = state.isBlocked(f.userId);

    static immutable int[4] cols = [-360, 110, 110, -1];
    mu_layout_row(ctx, 4, cols.ptr, 56);
    mu_Rect nameCell = manageRowBand(ctx, index);
    mu_draw_control_text(ctx, f.displayName,
        mu_Rect(nameCell.x + padX, nameCell.y, nameCell.w - padX, nameCell.h),
        MU_COLOR_TEXT, 0);
    if (clickButton(ctx, muted ? "Unmute" : "Mute"))
    {
        if (state.moderationActionInFlight == false)
            state.pendingModerationActions ~= ModerationAction(f.userId, f.displayName,
                muted ? "unmute" : "mute");
    }
    if (blocked)
    {
        if (clickButton(ctx, "Unblock"))
        {
            if (state.moderationActionInFlight == false)
                state.pendingModerationActions ~= ModerationAction(f.userId, f.displayName, "unblock");
        }
    }
    else
    {
        if (clickButton(ctx, "Block"))
            state.armedConfirm = ArmedConfirm("block", f.userId);
    }
    if (clickButton(ctx, "Unfriend"))
        state.armedConfirm = ArmedConfirm("unfriend", f.userId);
}

/// TOOLS > Muted/Blocked Users: moderation lists with undo buttons.
/// Unmute/unblock are restorative, so they fire without confirmation.
private void drawModerationListPage(mu_Context* ctx, AppState* state, int scrollDelta, bool mutePage)
{
    static immutable int[1] fullCol = [-1];

    mu_begin_panel(ctx, mutePage ? "MuteListPanel" : "BlockListPanel");
    applyScroll(ctx, scrollDelta);

    // Navigation back to TOOLS is the sticky header Back button.

    mu_layout_row(ctx, 1, fullCol.ptr, 60);
    if (clickButton(ctx, state.moderationsLoading ? "Refreshing..." : "Refresh"))
        state.refreshModerationsRequested = true;

    if (state.connected == false)
    {
        mu_layout_row(ctx, 1, fullCol.ptr, 0);
        mu_label(ctx, "Not connected.");
    }
    else if (state.serverProtocol < PROTOCOL_MODERATION)
    {
        mu_layout_row(ctx, 1, fullCol.ptr, 0);
        mu_label(ctx, "Server too old for the moderation API (needs protocol 3).");
    }

    if (state.moderationsError.length > 0)
    {
        mu_layout_row(ctx, 1, fullCol.ptr, 0);
        mu_label(ctx, state.moderationsError);
    }

    ModerationEntry[] list = mutePage ? state.mutedUsers : state.blockedUsers;

    if (state.moderationsLoaded && list.length == 0)
    {
        mu_layout_row(ctx, 1, fullCol.ptr, 0);
        mu_label(ctx, mutePage ? "No muted users." : "No blocked users.");
    }

    static immutable int[2] rowCols = [-160, -1];
    int padX = ctx.style.padding;
    foreach (size_t i, ref ModerationEntry m; list)
    {
        mu_layout_row(ctx, 2, rowCols.ptr, 56);
        mu_Rect nameCell = manageRowBand(ctx, i);
        mu_draw_control_text(ctx, m.displayName,
            mu_Rect(nameCell.x + padX, nameCell.y, nameCell.w - padX, nameCell.h),
            MU_COLOR_TEXT, 0);
        if (clickButton(ctx, mutePage ? "Unmute" : "Unblock"))
        {
            if (state.moderationActionInFlight == false)
                state.pendingModerationActions ~= ModerationAction(m.userId, m.displayName,
                    mutePage ? "unmute" : "unblock");
        }
    }

    if (state.moderationActionInFlight)
    {
        mu_layout_row(ctx, 1, fullCol.ptr, 0);
        mu_label(ctx, "Working...");
    }

    mu_end_panel(ctx);
}

/// Settings tab: application configuration.
private void drawSettingsTab(mu_Context* ctx, AppState* state, int scrollDelta)
{
    static immutable int[2] labelFieldCols = [200, -1];
    static immutable int[1] fullCol = [-1];

    mu_begin_panel(ctx, "SettingsPanel");

    applyScroll(ctx, scrollDelta);

    // Section: Server connection.
    sectionHeader(ctx, "Server Connection");

    mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
    mu_label(ctx, "Host");
    mu_textbox(ctx, state.settingsHost.ptr, cast(int) state.settingsHost.length);

    mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
    mu_label(ctx, "Port");
    mu_textbox(ctx, state.settingsPort.ptr, cast(int) state.settingsPort.length);

    mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
    mu_label(ctx, "Secret");
    mu_textbox_ex(ctx, state.settingsSecret.ptr, cast(int) state.settingsSecret.length, MU_OPT_PASSWORD);

    // Section: TLS. The header carries the context, so the field labels stay short.
    spacer(ctx);
    sectionHeader(ctx, "TLS");

    if (tlsAvailable())
    {
        mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
        mu_label(ctx, "Enable");
        mu_checkbox(ctx, "", &state.settingsTls);

        mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
        mu_label(ctx, "Skip verify");
        mu_checkbox(ctx, "", &state.settingsTlsSkipVerify);

        // CA file for verifying the server. Empty falls back to the system
        // trust store, which knows nothing about a private CA.
        mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
        mu_label(ctx, "CA cert");
        mu_textbox(ctx, state.settingsTlsCaCert.ptr, cast(int) state.settingsTlsCaCert.length);

        mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
        mu_label(ctx, "Certificate");
        mu_textbox(ctx, state.settingsTlsClientCert.ptr, cast(int) state.settingsTlsClientCert.length);

        mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
        mu_label(ctx, "Key");
        mu_textbox(ctx, state.settingsTlsClientKey.ptr, cast(int) state.settingsTlsClientKey.length);
    }
    else
    {
        mu_layout_row(ctx, 1, fullCol.ptr, 0);
        mu_label(ctx, "(unavailable)");
    }

    // Connect / Reconnect button. Commits all connection settings above.
    spacer(ctx);
    mu_layout_row(ctx, 1, fullCol.ptr, 60);
    string btnLabel = state.connected ? "Reconnect" : "Connect";
    if (mu_button(ctx, btnLabel))
        state.reconnectRequested = true;

    // Section: Font settings.
    spacer(ctx);
    sectionHeader(ctx, "Font");

    mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
    mu_label(ctx, "Font Path");
    mu_textbox(ctx, state.settingsFontPath.ptr, cast(int) state.settingsFontPath.length);

    mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
    mu_label(ctx, "Font Size");
    mu_slider_ex(ctx, &state.settingsFontSize, 8.0f, 72.0f, 1.0f, "%.0f", MU_OPT_ALIGNCENTER);

    mu_layout_row(ctx, 1, fullCol.ptr, 60);
    if (mu_button(ctx, "Apply Font"))
    {
        state.fontReloadRequested = true;
        setStatusFlash(state, "  Font applied");
    }

    // Section: Feed settings.
    spacer(ctx);
    sectionHeader(ctx, "Feed");

    mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
    mu_label(ctx, "Page Size");
    mu_slider_ex(ctx, &state.feedPageSize, 10.0f, 100.0f, 5.0f, "%.0f", MU_OPT_ALIGNCENTER);

    // Section: Pictures.
    spacer(ctx);
    sectionHeader(ctx, "Pictures");

    mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
    mu_label(ctx, "Insert picture metadata");
    mu_checkbox(ctx, "", &state.insertPictureMetadata);

    // Section: VR notifications.
    spacer(ctx);
    sectionHeader(ctx, "VR Notifications");

    mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
    mu_label(ctx, "Mute (silence all)");
    mu_checkbox(ctx, "", &state.notifyMute);

    mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
    mu_label(ctx, "XSOverlay / WayVR");
    mu_checkbox(ctx, "", &state.notifyXSOverlay);

    version (Windows)
    {
        mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
        mu_label(ctx, "OVR Toolkit");
        mu_checkbox(ctx, "", &state.notifyOVRToolkit);
    }

    version (linux)
    {
        mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
        mu_label(ctx, "Desktop (notify-send)");
        mu_checkbox(ctx, "", &state.notifyDesktop);
    }

    mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
    mu_label(ctx, "Sound");
    mu_checkbox(ctx, "", &state.notifySound);

    mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
    mu_label(ctx, "Volume");
    mu_slider_ex(ctx, &state.notifyVolume, 0.0f, 1.0f, 0.1f, "%.1f", MU_OPT_ALIGNCENTER);

    mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
    mu_label(ctx, "Opacity");
    mu_slider_ex(ctx, &state.notifyOpacity, 0.0f, 1.0f, 0.1f, "%.1f", MU_OPT_ALIGNCENTER);

    mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
    mu_label(ctx, "Timeout (seconds)");
    mu_slider_ex(ctx, &state.notifyTimeout, 1.0f, 30.0f, 1.0f, "%.0f", MU_OPT_ALIGNCENTER);

    mu_layout_row(ctx, 1, fullCol.ptr, 60);
    if (mu_button(ctx, "Test Notification"))
        state.testNotifyRequested = true;

    // Per-event-type notification filter.
    spacer(ctx);
    sectionHeader(ctx, "Notify Events");

    foreach (size_t i; 0 .. notifyEventLabels.length)
    {
        mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
        mu_label(ctx, notifyEventLabels[i]);
        mu_checkbox(ctx, "", &state.notifyEventFilter[i]);
    }

    // Save / load settings.
    spacer(ctx);
    sectionHeader(ctx, "Persistence");

    mu_layout_row(ctx, 1, fullCol.ptr, 60);
    if (mu_button(ctx, "Save Settings"))
    {
        state.saveSettingsRequested = true;
        setStatusFlash(state, "  Settings saved");
    }
    
    // Server db stats after settings (not part of settings) and before about (not related to software compile options)
    if (state.statsKnown)
    {
        spacer(ctx);
        sectionHeader(ctx, "Database Statistics");

        // One buffer for all four rows: mu_label copies the text into ddui's
        // arena, so the next sformat is free to overwrite it.
        char[32] statBuf = void;

        mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
        mu_label(ctx, "Events");
        mu_label(ctx, cast(string) sformat(statBuf, "%,d", state.statsEventCount));

        mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
        mu_label(ctx, "Worlds cached");
        mu_label(ctx, cast(string) sformat(statBuf, "%,d", state.statsWorldCacheCount));

        mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
        mu_label(ctx, "Avatars cached");
        mu_label(ctx, cast(string) sformat(statBuf, "%,d", state.statsAvatarCacheCount));

        mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
        mu_label(ctx, "Size");
        mu_label(ctx, cast(string) formatBytes(state.statsDbSizeBytes, statBuf));
    }

    // About this project.
    spacer(ctx);
    sectionHeader(ctx, "About");

    mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
    mu_label(ctx, "Version");
    import client.config : VERSION;
    mu_label(ctx, VERSION);

    mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
    mu_label(ctx, "Built");
    mu_label(ctx, __TIMESTAMP__);

    mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
    mu_label(ctx, "Author");
    mu_label(ctx, "dd86k <dd@dax.moe>");

    mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
    mu_label(ctx, "License");
    mu_label(ctx, "BSD-3-Clause-Clear");

    mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
    mu_label(ctx, "Source");
    mu_label(ctx, "https://github.com/dd86k/vrcd");

    import std.format : format;
    static immutable string COMPILER = format("%s %u.%u", __VENDOR__, __VERSION__ / 1000, __VERSION__ % 1000);
    mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
    mu_label(ctx, "Compiler");
    mu_label(ctx, COMPILER);
    
    // TODO: Compile/runtime settings (compiler, package versions, SDL3 versions, etc.)

    mu_end_panel(ctx);
}

/// Draw the status bar at the bottom.
private void drawStatusBar(mu_Context* ctx, AppState* state)
{
    mu_Rect r = mu_layout_next(ctx);
    // NOTE: Consider changing statusbar color
    //       Worried about constrast
    mu_draw_rect(ctx, r, mu_Color(20, 20, 25, 255));

    // Show transient action-feedback flash when active.
    if (state.statusFlash && MonoTime.currTime < state.statusFlashEnd)
    {
        mu_draw_control_text(ctx, state.statusFlash, r, MU_COLOR_TEXT, 0);
        return;
    }

    char[256] buf = void;
    // NOTE: Consider sending a VR notification when rate limited (notify option)
    const(char)[] s;
    if (state.rateLimited)
    {
        s = sformat(buf, "  Server: %s | VRChat: %s | RATE LIMITED",
            state.serverStatus, state.vrchatStatus);
    }
    else if (state.rateLimitRemaining >= 0 && state.rateLimitMax > 0)
    {
        s = sformat(buf, "  Server: %s | VRChat: %s | API: %d/%d",
            state.serverStatus, state.vrchatStatus,
            state.rateLimitRemaining, state.rateLimitMax);
    }
    else
    {
        s = sformat(buf, "  Server: %s | VRChat: %s",
            state.serverStatus, state.vrchatStatus);
    }
    mu_draw_control_text(ctx, s.ptr, r, MU_COLOR_TEXT, 0, cast(int) s.length);
}

/// Apply mouse wheel scroll delta to the current panel container.
private void applyScroll(mu_Context* ctx, int scrollDelta)
{
    if (scrollDelta == 0)
        return;
    mu_Container* panel = mu_get_current_container(ctx);
    panel.scroll.y += scrollDelta;
    // Clamp: don't scroll above the top.
    if (panel.scroll.y < 0)
        panel.scroll.y = 0;
    // Clamp to content (use previous frame's content_size). ddui's own
    // scrollbar adds style.padding * 2 to the content size before computing
    // its limit, because a panel's layout starts one padding in and the last
    // row is meant to come to rest one padding above the bottom edge. Leaving
    // it out here stopped the wheel two paddings early, which clipped the
    // bottom of the last row on every panel while the scrollbar thumb (which
    // uses ddui's limit) could still be dragged past it.
    int maxScroll = panel.content_size.y + ctx.style.padding * 2 - panel.body_.h;
    if (maxScroll < 0) maxScroll = 0;
    if (panel.scroll.y > maxScroll)
        panel.scroll.y = maxScroll;
}

/// Map VRChat status enum values to readable names.
string prettyStatus(string status)
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



/// Draw the auth delegation dialog (modal popup).
private void drawAuthDialog(mu_Context* ctx, AppState* state)
{
    if (state.authDialogVisible == false)
        return;

    // Center the dialog on screen.
    enum WIDTH = 400;
    enum HEIGHT = 300;
    int x = (window_width - WIDTH) / 2;
    int y = (window_height - HEIGHT) / 2;

    if (mu_begin_window_ex(ctx, "VRChat Authentication",
        mu_Rect(x, y, WIDTH, HEIGHT),
        MU_OPT_NORESIZE | MU_OPT_NOCLOSE | MU_OPT_NOSCROLL))
    {
        mu_bring_to_front(ctx, mu_get_current_container(ctx));
        static immutable int[1] fullCol = [-1];
        static immutable int[2] btnCols = [190, -1];

        if (state.authDialogKind == AppState.AuthDialogKind.credentials)
        {
            mu_layout_row(ctx, 1, fullCol.ptr, 0);
            mu_label(ctx, "Server needs VRChat credentials");

            mu_layout_row(ctx, 1, fullCol.ptr, 0);
            mu_label(ctx, "Username:");
            mu_layout_row(ctx, 1, fullCol.ptr, 30);
            mu_textbox(ctx, state.authUsername.ptr, cast(int) state.authUsername.length);

            mu_layout_row(ctx, 1, fullCol.ptr, 0);
            mu_label(ctx, "Password:");
            mu_layout_row(ctx, 1, fullCol.ptr, 30);
            mu_textbox_ex(ctx, state.authPassword.ptr, cast(int) state.authPassword.length, MU_OPT_PASSWORD);
        }
        else if (state.authDialogKind == AppState.AuthDialogKind.twoFactor)
        {
            mu_layout_row(ctx, 1, fullCol.ptr, 0);
            string methodLabel = void;
            switch (state.authDialogMethod) {
            case "totp":     methodLabel = "Enter authenticator code (TOTP)"; break;
            case "emailOtp": methodLabel = "Enter email verification code"; break;
            case "otp":      methodLabel = "Enter OTP code"; break;
            default:         methodLabel = "Enter 2FA code"; break;
            }
            mu_label(ctx, methodLabel);

            mu_layout_row(ctx, 1, fullCol.ptr, 30);
            mu_textbox(ctx, state.authCode.ptr, cast(int) state.authCode.length);
        }

        // Show error from previous attempt.
        if (state.authDialogError.length > 0)
        {
            mu_layout_row(ctx, 1, fullCol.ptr, 0);
            mu_label(ctx, state.authDialogError);
        }

        // Buttons row.
        mu_layout_row(ctx, 2, btnCols.ptr, 40);
        if (mu_button(ctx, "Submit"))
            state.authDialogSubmit = true;
        if (mu_button(ctx, "Cancel"))
            state.authDialogCancel = true;

        mu_end_window(ctx);
    }
}
