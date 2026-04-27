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

import ddui;

import client.notifications : notifyEventLabels, feedEventLabels;
import client.renderer : window_width, window_height;
import client.gui : wasClick, requestRepaint;
import client.state;
import client.stream : tlsAvailable;

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
            drawFeedTab(ctx, state, scrollDelta);

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
                case Tab.online:        drawOnlineTab(ctx, state, scrollDelta);        break;
                case Tab.notifications: drawNotificationsTab(ctx, state, scrollDelta); break;
                case Tab.tools:         drawToolsTab(ctx, state);                      break;
                case Tab.settings:      drawSettingsTab(ctx, state, scrollDelta);       break;
            }
        }

        // Status bar
        mu_layout_row(ctx, 1, fullCol.ptr, 25);
        drawStatusBar(ctx, state);

        mu_end_window(ctx);
    }

    // Filter popup must be outside the main window to render on top.
    drawFeedFilterPopup(ctx, state);

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
private void drawFeedFilterPopup(mu_Context* ctx, AppState* state)
{
    if (filterPopupOpen == false)
        return;

    if (mu_begin_window_ex(ctx, "Filters", mu_Rect(10, 100, 340, 500),
        MU_OPT_NOTITLE | MU_OPT_NORESIZE | MU_OPT_AUTOSIZE | MU_OPT_NOSCROLL))
    {
        // Keep popup above the full-screen main window so it receives input.
        mu_bring_to_front(ctx, mu_get_current_container(ctx));
        enum cols = 2;
        enum totalItems = feedEventLabels.length;
        enum rows = (totalItems + cols - 1) / cols;
        static immutable int[cols] filterCols = [160, 160];

        bool changed;

        foreach (size_t row; 0 .. rows)
        {
            mu_layout_row(ctx, cols, filterCols.ptr, 0);
            foreach (size_t col; 0 .. cols)
            {
                size_t i = col * rows + row;
                if (i < totalItems)
                {
                    int prev = state.feedEventVisible[i];
                    mu_checkbox(ctx, feedEventLabels[i], &state.feedEventVisible[i]);
                    if (state.feedEventVisible[i] != prev)
                        changed = true;
                }
                else
                    mu_layout_next(ctx); // empty cell
            }
        }

        static immutable int[1] selfCol = [320];
        mu_layout_row(ctx, 1, selfCol.ptr, 0);
        int prevHideSelf = state.feedHideSelfEvents;
        mu_checkbox(ctx, "Hide self events", &state.feedHideSelfEvents);
        if (state.feedHideSelfEvents != prevHideSelf)
        {
            feedPage = 0;
            changed = true;
        }

        static immutable int[2] btnCols = [160, 160];
        mu_layout_row(ctx, 2, btnCols.ptr, 30);
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
    if (state.selectedFeedEntry)
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
                    state.selectedFeedEntry = &entry;

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
            mu_label(ctx, "No matching events.");
        }
        else if (feedPage == totalPages - 1)
        {
            // On the last page, append the Fetch Older button after the
            // last row as an "infinite scroll" style sentinel.
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

    FeedEntry* e = state.selectedFeedEntry;

    mu_begin_panel(ctx, "FeedDetailPanel");

    applyScroll(ctx, scrollDelta);

    // Back button (uses clickButton to avoid re-selecting a row on the same click).
    mu_layout_row(ctx, 1, fullCol.ptr, 40);
    if (clickButton(ctx, "< Back"))
    {
        state.selectedFeedEntry = null;
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

    // Raw content fields (parsed from JSON).
    if (e.rawContent.length > 0)
    {
        mu_layout_row(ctx, 1, fullCol.ptr, 1);
        mu_draw_rect(ctx, mu_layout_next(ctx), lineColor);

        mu_layout_row(ctx, 1, fullCol.ptr, 0);
        mu_label(ctx, "Content");

        try
        {
            JSONValue c = parseJSON(e.rawContent);
            if (c.type == JSONType.string)
                c = parseJSON(c.str);

            if (c.type == JSONType.object)
            {
                foreach (string key, JSONValue val; c.objectNoRef)
                {
                    // Skip nested objects/arrays,  show scalar fields.
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
        }
        catch (Exception) {}
    }

    mu_end_panel(ctx);
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
    // Hide self events (user-update, user-location, self avatar changes, etc).
    if (state.feedHideSelfEvents != 0 && entry.isSelf)
        return false;

    // Event type filter.
    bool typeAllowed = true;
    foreach (size_t i, string label; feedEventLabels)
    {
        if (prettyEventType(entry.eventType) == label)
        {
            typeAllowed = state.feedEventVisible[i] != 0;
            break;
        }
    }
    if (typeAllowed == false)
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
private void gridCell(mu_Context* ctx, string text, mu_Color lineColor, bool lastCol = false)
{
    mu_Rect r = mu_layout_next(ctx);
    mu_draw_control_text(ctx, text, r, MU_COLOR_TEXT, 0);
    if (lastCol == false)
        mu_draw_rect(ctx, mu_Rect(r.x + r.w - 1, r.y, 1, r.h), lineColor);
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

    // Refresh button inside the panel.
    mu_layout_row(ctx, 1, fullCol.ptr, 30);
    if (mu_button(ctx, "Refresh"))
    {
        state.refreshFriendsRequested = true;
        setStatusFlash(state, "  Refreshing friends...");
    }

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
            if (mu_header_ex(ctx, cast(string)header, MU_OPT_EXPANDED))
            {
                foreach (ref FriendInfo f; grp.friends)
                    drawFriendCard(ctx, state, f);
                mu_layout_row(ctx, 1, fullCol.ptr, 0);
            }
        }

        foreach (ref InstanceGroup grp; state.instances)
        {
            if (grp.instanceId != "private")
                continue;
            if (mu_header_ex(ctx, "Private", MU_OPT_EXPANDED))
            {
                foreach (ref FriendInfo f; grp.friends)
                    drawFriendCard(ctx, state, f);
                mu_layout_row(ctx, 1, fullCol.ptr, 0);
            }
        }

        if (state.activeElsewhereFriends.length > 0)
        {
            if (mu_header_ex(ctx, "Active elsewhere", 0))
            {
                foreach (ref FriendInfo f; state.activeElsewhereFriends)
                    drawFriendCard(ctx, state, f);
                mu_layout_row(ctx, 1, fullCol.ptr, 0);
            }
        }

        if (state.offlineFriends.length > 0)
        {
            if (mu_header_ex(ctx, "Offline", 0))
            {
                foreach (ref FriendInfo f; state.offlineFriends)
                    drawFriendCard(ctx, state, f);
                mu_layout_row(ctx, 1, fullCol.ptr, 0);
            }
        }
    }

    mu_end_panel(ctx);
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
        case EventSource.server: return mu_Color(70, 140, 220, 255); // blue
        case EventSource.local:  return mu_Color(70, 200, 90,  255); // green
        case EventSource.system: return mu_Color(90, 90,  100, 255); // gray
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
        mu_label(ctx, "Bio");
        clickableValue(ctx, state, f.statusDescription);
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
private void drawNotificationsTab(mu_Context* ctx, AppState* state, int scrollDelta)
{
    static immutable int[4] infoCols = [120, 150, -1, 100];
    static immutable int[3] btnCols = [100, 100, 100];
    static immutable int[1] dismissCol = [-1];
    static immutable int[1] fullCol = [-1];
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

        foreach (ref NotificationEntry n; state.notifications)
        {
            // Info row: Type | From | Message | Date
            mu_layout_row(ctx, 4, infoCols.ptr, 0);
            gridCell(ctx, prettyNotifType(n.notificationType), lineColor);
            gridCell(ctx, n.senderName, lineColor);
            gridCell(ctx, n.message, lineColor);
            gridCell(ctx, n.receivedAt, lineColor, true);

            // Action row.
            if (n.actionPending)
            {
                mu_layout_row(ctx, 1, fullCol.ptr, 30);
                mu_label(ctx, "Pending...");
            }
            else if (n.notificationType == "friendRequest")
            {
                // Friend requests can be accepted, denied, or dismissed.
                // Deny and Dismiss both send "hide"; Dismiss is the clearer
                // label for stale requests already accepted on another client.
                mu_layout_row(ctx, 3, btnCols.ptr, 30);
                if (mu_button(ctx, "Accept"))
                {
                    // Keep pending-confirmation flow for Accept: the user
                    // wants to know whether the friendship was actually made.
                    n.actionPending = true;
                    state.pendingActions ~= NotificationAction(n.notificationId, "accept");
                }
                if (mu_button(ctx, "Deny"))
                {
                    // Fire-and-forget: remove locally, send "hide" to server.
                    state.pendingActions ~= NotificationAction(n.notificationId, "hide");
                    dismissedIds ~= n.notificationId;
                }
                if (mu_button(ctx, "Dismiss"))
                {
                    state.pendingActions ~= NotificationAction(n.notificationId, "hide");
                    dismissedIds ~= n.notificationId;
                }
            }
            else
            {
                // Other notification types (invite, requestInvite, message, ...)
                // can only be dismissed (hide). Fire-and-forget.
                mu_layout_row(ctx, 1, dismissCol.ptr, 30);
                if (mu_button(ctx, "Dismiss"))
                {
                    state.pendingActions ~= NotificationAction(n.notificationId, "hide");
                    dismissedIds ~= n.notificationId;
                }
            }

            // Row separator.
            mu_layout_row(ctx, 1, fullCol.ptr, 1);
            mu_draw_rect(ctx, mu_layout_next(ctx), lineColor);
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
private void drawToolsTab(mu_Context* ctx, AppState* state)
{
    if (state.stripMetadataPage)
    {
        drawStripMetadataPage(ctx, state);
        return;
    }

    static immutable int[1] fullCol = [-1];
    mu_begin_panel(ctx, "ToolsPanel");

    sectionHeader(ctx, "Pictures");

    mu_layout_row(ctx, 1, fullCol.ptr, 60);
    if (mu_button(ctx, "Open Pictures Folder"))
    {
        import client.directories : vrchatPicturesDir;
        openFolder(vrchatPicturesDir());
    }

    mu_layout_row(ctx, 1, fullCol.ptr, 60);
    if (mu_button(ctx, "Strip Metadata"))
    {
        state.stripMetadataPage = true;
    }

    spacer(ctx);
    sectionHeader(ctx, "Debugging");

    mu_layout_row(ctx, 1, fullCol.ptr, 60);
    if (mu_button(ctx, "Open VRChat Logs Folder"))
    {
        import client.directories : vrchatLogDir;
        openFolder(vrchatLogDir());
    }
    if (mu_button(ctx, "Open VRCD Logs Folder"))
    {
        import client.directories : vrcdAppDataPath;
        openFolder(vrcdAppDataPath());
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

/// Open a specific folder with the system's file manager.
private void openFolder(string path)
{
    import std.process : spawnProcess;

    if (path is null || path.length == 0)
        return;
    version (Windows)
        try spawnProcess(["explorer", path]); catch (Exception) {}
    else
        try spawnProcess(["xdg-open", path]); catch (Exception) {}
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
    // NOTE: Consider sending a VR notification when rate limited
    //       Toggle option
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
    if (s) mu_draw_control_text(ctx, s.ptr, r, MU_COLOR_TEXT, 0, cast(int) s.length);
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

/// Map VRChat WebSocket event type strings to readable names.
string prettyEventType(string eventType)
{
    switch (eventType)
    {
        case "friend-online":               return "Online";
        case "friend-offline":              return "Offline";
        case "friend-active":               return "Active";
        case "friend-add":                  return "Friend Add";
        case "friend-delete":               return "Friend Remove";
        case "friend-update":               return "Friend Update";
        case "friend-location":             return "Friend Location";
        case "user-update":                 return "Update";
        case "user-location":               return "Location";
        case "user-badge-assigned":         return "Badge Assigned";
        case "user-badge-unassigned":       return "Badge Unassigned";
        case "notification":
        case "notification-v2":             return "Notification";
        case "notification-v2-delete":      return "Notif Delete";
        case "notification-v2-update":      return "Notif Update";
        case "see-notification":            return "Notif Seen";
        case "hide-notification":           return "Notif Hidden";
        case "response-notification":       return "Notif Response";
        case "group-joined":                return "Group Joined";
        case "group-left":                  return "Group Left";
        case "group-role-updated":          return "Group Role";
        case "group-member-updated":        return "Group Member";
        case "instance-queue-joined":       return "Queue Joined";
        case "instance-queue-position":     return "Queue Position";
        case "instance-queue-ready":        return "Queue Ready";
        case "instance-queue-left":         return "Queue Left";
        case "instance-closed":             return "Instance Closed";
        case "avatar-change":               return "Avatar Change";
        case "content-refresh":             return "Content Refresh";
        case "player-joining":              return "Player Joining";
        case "player-joined":               return "Player Joined";
        case "player-left":                 return "Player Left";
        case "photo-taken":                 return "Photo Taken";
        case "url-video":                   return "URL Video";
        case "url-string":                  return "URL String";
        case "url-image":                   return "URL Image";
        case "system":                      return "System";
        case "error":                       return "Error";
        default:                            return eventType;
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
