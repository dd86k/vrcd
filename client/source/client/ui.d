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

import client.notifications : notifyEventLabels, feedEventLabels, feedFilterSections,
    feedEventIndex, prettyEventType;
import client.renderer : window_width, window_height;
import client.gui : wasClick, requestRepaint;
import client.state;
import client.stream : tlsAvailable;
import client.utils : openFolder, openBrowser;

/// Active tab selection.
enum Tab { feed, online, notifications, tools, settings }
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
        drawTabBar(ctx);

        // Content area (fills remaining space minus status bar)
        static immutable int[1] fullCol = [-1];

        if (activeTab == Tab.feed)
        {
            // Search bar + filter button get their own row.
            drawFeedSearchBar(ctx);
        }

        if (activeTab == Tab.feed)
        {
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
private void drawTabBar(mu_Context* ctx)
{
    // NOTE: Take padding into the calculation to make settings button slightly more equal
    //       With my testing, this makes 187px for first four and 186px wide for SETTINGS
    enum BUTTONS = 5;
    enum PADDING = 4; // default style has margin=4
    int tabWidth = (window_width - (PADDING * (BUTTONS+1))) / BUTTONS;
    int[BUTTONS] tabCols = [tabWidth, tabWidth, tabWidth, tabWidth, -1];
    mu_layout_row(ctx, BUTTONS, tabCols.ptr, 60);

    // Highlight active tab by drawing a colored background.
    drawTabButton(ctx, "FEED",          Tab.feed);
    drawTabButton(ctx, "ONLINE",        Tab.online);
    drawTabButton(ctx, "INBOX",         Tab.notifications);
    drawTabButton(ctx, "TOOLS",         Tab.tools);
    drawTabButton(ctx, "SETTINGS",      Tab.settings);
}

/// Draw a single tab button, highlighted if active.
private void drawTabButton(mu_Context* ctx, string label, Tab tab)
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
            activeTab = tab;
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
    static immutable int[4] feedCols = [150, 120, 150, -1];
    static immutable int[1] fullCol = [-1];
    enum lineColor = mu_Color(50, 50, 60, 255);
    enum hoverColor = mu_Color(60, 60, 80, 255);

    mu_begin_panel(ctx, "FeedPanel");

    // Apply mouse wheel scroll directly to this panel.
    applyScroll(ctx, scrollDelta);

    // Column header.
    mu_layout_row(ctx, 4, feedCols.ptr, 0);
    gridCell(ctx, "Date", lineColor);
    gridCell(ctx, "Type", lineColor);
    gridCell(ctx, "User", lineColor);
    gridCell(ctx, "Detail", lineColor, true);

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

        foreach (ref FeedEntry entry; state.feedEntries)
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

    // Back button (uses clickButton to avoid re-selecting a row on the same click).
    mu_layout_row(ctx, 1, fullCol.ptr, 40);
    if (clickButton(ctx, "< Back"))
    {
        state.feedDetailOpen = false;
        requestRepaint();
        mu_end_panel(ctx);
        return;
    }

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

    // Open the world in the VRChat website, for entries that carry a world id.
    if (haveContent)
    {
        string worldId = extractWorldId(content);
        if (worldId.length > 0)
        {
            mu_layout_row(ctx, 1, fullCol.ptr, 40);
            if (clickButton(ctx, "Open in VRChat Website"))
                openBrowser("https://vrchat.com/home/world/" ~ worldId ~ "/info");
        }
    }

    // Raw content fields (parsed from JSON).
    if (haveContent)
    {
        mu_layout_row(ctx, 1, fullCol.ptr, 1);
        mu_draw_rect(ctx, mu_layout_next(ctx), lineColor);

        mu_layout_row(ctx, 1, fullCol.ptr, 0);
        mu_label(ctx, "Content");

        foreach (string key, JSONValue val; content.objectNoRef)
        {
            // Skip nested objects/arrays, show scalar fields.
            if (val.type == JSONType.object || val.type == JSONType.array)
                continue;

            string valStr;
            if (val.type == JSONType.string)
                valStr = val.str;
            else
                valStr = val.toString();

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
private string extractWorldId(ref JSONValue c)
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

    // Count how many entries pass the filter.
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
    enum int refreshW = 80;
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

    // Refresh: asks the server to pull fresh friend state from VRChat.
    if (mu_button(ctx, "Refresh"))
    {
        state.refreshFriendsRequested = true;
        setStatusFlash(state, "  Refreshing friends...");
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
        state.selectedFriend = &f;
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

    // Back button.
    mu_layout_row(ctx, 1, fullCol.ptr, 40);
    if (mu_button(ctx, "< Back"))
    {
        state.selectedFriend = null;
        mu_end_panel(ctx);
        return;
    }

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

    mu_end_panel(ctx);
}

/// Notifications tab: friend requests, invites, etc.
///
/// Layout: each entry is a three-line cell with action buttons stacked
/// on the right (VR-friendly touch targets). At ~640px (half of a 1280
/// screen) a single meta row squished the sender name, so the metadata
/// is split across three short rows that all get the full column width.
///
///   +----------------------------------+--------+
///   | Type . Date                      | Accept |
///   | From                             |        |  (friendRequest)
///   | Message                          |   X    |
///   +----------------------------------+--------+
///
/// Deny was removed because it sent the same "hide" as Dismiss, so the
/// X covers both cases.
private void drawNotificationsTab(mu_Context* ctx, AppState* state, int scrollDelta)
{
    static immutable int[2] outerCols  = [-170, 160];
    static immutable int[1] fullCol    = [-1];
    static immutable int[2] headerCols = [-130, 120];
    enum int rowHeight    = 90;
    enum int actionHeight = 36; // two stacked buttons fit in ~90px row
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
        // non-pending notification.
        mu_layout_row(ctx, 2, headerCols.ptr, 30);
        mu_label(ctx, "");
        if (mu_button(ctx, "Dismiss all"))
        {
            foreach (ref NotificationEntry n; state.notifications)
            {
                if (n.actionPending)
                    continue;
                state.pendingActions ~= NotificationAction(n.notificationId, "hide");
                dismissedIds ~= n.notificationId;
            }
        }

        foreach (ref NotificationEntry n; state.notifications)
        {
            // Scope widget IDs by notificationId so identical button labels
            // ("X", "Accept") across rows don't collide in microui.
            mu_push_id(ctx, n.notificationId.ptr, cast(int) n.notificationId.length);

            mu_layout_row(ctx, 2, outerCols.ptr, rowHeight);

            // Left column: type+date / from / message, each on its own row.
            char[32] relBuf = void;
            const(char)[] relDate = formatRelative(n.receivedAtUnix, relBuf[]);
            char[96] headBuf = void;
            const(char)[] head = relDate.length > 0
                ? sformat(headBuf[], "%s . %s", prettyNotifType(n.notificationType), relDate)
                : prettyNotifType(n.notificationType);

            mu_layout_begin_column(ctx);
                mu_layout_row(ctx, 1, fullCol.ptr, 0);
                gridCell(ctx, head, lineColor, true);

                mu_layout_row(ctx, 1, fullCol.ptr, 0);
                gridCell(ctx, n.senderName, lineColor, true);

                mu_layout_row(ctx, 1, fullCol.ptr, 0);
                gridCell(ctx, n.message, lineColor, true);
            mu_layout_end_column(ctx);

            // Right column: stacked action buttons.
            mu_layout_begin_column(ctx);
                if (n.actionPending)
                {
                    mu_layout_row(ctx, 1, fullCol.ptr, 0);
                    mu_label(ctx, "Pending...");
                }
                else if (n.notificationType == "friendRequest")
                {
                    mu_layout_row(ctx, 1, fullCol.ptr, actionHeight);
                    if (mu_button(ctx, "Accept"))
                    {
                        // Keep pending-confirmation flow for Accept: the user
                        // wants to know whether the friendship was actually made.
                        n.actionPending = true;
                        state.pendingActions ~= NotificationAction(n.notificationId, "accept");
                    }
                    mu_layout_row(ctx, 1, fullCol.ptr, actionHeight);
                    if (mu_button(ctx, "X"))
                    {
                        state.pendingActions ~= NotificationAction(n.notificationId, "hide");
                        dismissedIds ~= n.notificationId;
                    }
                }
                else
                {
                    // Other types (invite, requestInvite, ...) only support hide.
                    mu_layout_row(ctx, 1, fullCol.ptr, 0);
                    if (mu_button(ctx, "X"))
                    {
                        state.pendingActions ~= NotificationAction(n.notificationId, "hide");
                        dismissedIds ~= n.notificationId;
                    }
                }
            mu_layout_end_column(ctx);

            // Row separator.
            mu_layout_row(ctx, 1, fullCol.ptr, 1);
            mu_draw_rect(ctx, mu_layout_next(ctx), lineColor);

            mu_pop_id(ctx);
        }

        // Apply optimistic removals.
        foreach (string id; dismissedIds)
            state.removeNotification(id);
    }

    mu_end_panel(ctx);
}

/// Map notification type to display name.
string prettyNotifType(string notifType)
{
    switch (notifType)
    {
        case "invite":                    return "Invite";
        case "requestInvite":             return "Request Invite";
        case "requestInviteResponse":     return "Invite Response";
        case "friendRequest":             return "Friend Request";
        case "votetokick":                return "Vote to Kick";
        default:                          return notifType;
    }
}

/// Tools tab: utility buttons.
private void drawToolsTab(mu_Context* ctx, AppState* state, int scrollDelta)
{
    if (state.stripMetadataPage)
    {
        drawStripMetadataPage(ctx, state);
        return;
    }

    static immutable int[1] fullCol  = [-1];
    static immutable int    COLCOUNT = cast(int) fullCol.length;
    mu_begin_panel(ctx, "ToolsPanel");

    applyScroll(ctx, scrollDelta);

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
        state.stripMetadataPage = true;
    }

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
        string id = "test_" ~ to!string(Clock.currTime.toUnixTime!long());
        state.addNotification(id, "friendRequest", "TestUser",
            "Synthetic friend request", Clock.currTime.toUnixTime!long());
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

    // Back button.
    mu_layout_row(ctx, 1, fullCol.ptr, 40);
    if (clickButton(ctx, "< Back"))
    {
        state.stripMetadataPage = false;
        requestRepaint();
        mu_end_panel(ctx);
        return;
    }

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
    mu_textbox(ctx, state.settingsSecret.ptr, cast(int) state.settingsSecret.length);

    mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
    mu_label(ctx, "TLS");
    if (tlsAvailable())
        mu_checkbox(ctx, "", &state.settingsTls);
    else
        mu_label(ctx, "(unavailable)");

    mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
    mu_label(ctx, "Skip certificate verify");
    if (tlsAvailable())
        mu_checkbox(ctx, "", &state.settingsTlsSkipVerify);
    else
        mu_label(ctx, "(unavailable)");

    mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
    mu_label(ctx, "Client certificate");
    if (tlsAvailable())
        mu_textbox(ctx, state.settingsTlsClientCert.ptr, cast(int) state.settingsTlsClientCert.length);
    else
        mu_label(ctx, "(unavailable)");

    mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
    mu_label(ctx, "Client key");
    if (tlsAvailable())
        mu_textbox(ctx, state.settingsTlsClientKey.ptr, cast(int) state.settingsTlsClientKey.length);
    else
        mu_label(ctx, "(unavailable)");

    // Connect / Reconnect button.
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
    
    // TODO: Compile/runtime settings (compiler, package versions, SDL2 versions, etc.)
    
    // BUG: Can't scroll to bottom 100% flush, so add empty row for now
    mu_layout_row(ctx, 2, labelFieldCols.ptr, 0);
    mu_label(ctx, "");

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
    // Clamp to content (use previous frame's content_size).
    int maxScroll = panel.content_size.y - panel.body_.h;
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

/// Map VRChat platform strings to readable names.
string prettyPlatform(string platform)
{
    switch (platform)
    {
        case "standalonewindows": return "PC";
        case "android":          return "Quest";
        case "ios":              return "iOS";
        case "nativemobile":     return "Mobile";
        case "web":              return "Website";
        default:                 return platform;
    }
}

/// Reduce a `currentAvatar` value to a compact identifier. Self events carry
/// an `avtr_<uuid>` directly; friend events expose only an image URL like
/// `https://api.vrchat.cloud/api/1/file/file_<uuid>/<ver>/file`, in which the
/// `file_<uuid>` segment is the most stable handle we can show.
string shortAvatarId(string s)
{
    import std.string : indexOf;

    ptrdiff_t i = s.indexOf("avtr_");
    if (i >= 0)
        return s[i .. $];

    i = s.indexOf("file_");
    if (i >= 0)
    {
        string rest = s[i .. $];
        ptrdiff_t slash = rest.indexOf('/');
        return slash >= 0 ? rest[0 .. slash] : rest;
    }

    return s;
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
            mu_textbox(ctx, state.authPassword.ptr, cast(int) state.authPassword.length);
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
