/// Client colours: the ddui style and the palette the custom widgets draw with.
///
/// The main window has no frame, so the clear colour is what every control
/// sits on, and the style's control colours are picked against it.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module client.theme;

import ddui;

// Surfaces

/// Window clear colour, behind everything.
enum mu_Color background    = mu_Color( 30,  30,  35, 255);
/// Status bar along the bottom.
enum mu_Color statusBarBg   = mu_Color( 20,  20,  25, 255);
/// Friend card.
enum mu_Color cardBg        = mu_Color( 38,  42,  52, 255);
/// Zebra band behind odd rows in management lists.
enum mu_Color rowBand       = mu_Color( 40,  44,  54, 255);
/// Row with an armed destructive confirmation.
enum mu_Color rowArmed      = mu_Color( 64,  44,  46, 255);
/// Hovered row or card.
enum mu_Color hoverBg       = mu_Color( 55,  62,  82, 255);
/// Outline drawn around a hovered entry that has no fill of its own.
enum mu_Color hoverEdge     = mu_Color( 90, 110, 150, 255);
/// Current tab, page, section or chosen popup row.
enum mu_Color selectedBg    = mu_Color( 60,  80, 120, 255);
/// Toggle button that is on.
enum mu_Color toggleOnBg    = mu_Color( 40,  70, 120, 255);
/// Edge of a toggle that is on, and of a picked boop emoji.
enum mu_Color toggleOnEdge  = mu_Color( 90, 140, 220, 255);
/// Button that cannot be pressed.
enum mu_Color disabledBg    = mu_Color( 40,  40,  50, 255);
/// Band behind a group heading.
enum mu_Color headingBg     = mu_Color( 45,  55,  75, 255);
/// Underline below a section header.
enum mu_Color headingRule   = mu_Color( 60,  60,  70, 255);
/// Separator between list rows.
enum mu_Color divider       = mu_Color( 50,  50,  60, 255);
/// Disc behind initials while a face has no picture.
enum mu_Color faceBg        = mu_Color( 52,  58,  72, 255);
/// Shade under a caption laid over a picture.
enum mu_Color captionShade  = mu_Color(  0,   0,   0, 170);
/// Progress bar fill.
enum mu_Color progressFill  = mu_Color(100, 150, 230, 255);
/// Unread count pill on a tab.
enum mu_Color badgeBg       = mu_Color(200,  50,  50, 255);

// Ink

/// Picture tint and text on a badge. Leaves pictures as they are.
enum mu_Color white         = mu_Color(255, 255, 255, 255);
/// Secondary text: dates, types, labels next to values.
enum mu_Color textDim       = mu_Color(150, 155, 165, 255);
/// Text for something switched off.
enum mu_Color textDisabled  = mu_Color(100, 100, 110, 255);
/// Hint inside an empty textbox.
enum mu_Color textHint      = mu_Color(110, 112, 125, 255);
/// Icon that is neither a yes nor a no.
enum mu_Color iconPlain     = mu_Color(205, 210, 220, 255);
/// Icon for a yes.
enum mu_Color iconYes       = mu_Color(110, 210, 120, 255);
/// Icon for a no.
enum mu_Color iconNo        = mu_Color(225, 100, 100, 255);

// Hues for strips and spines, also used for error text (red)

enum mu_Color green         = mu_Color( 70, 200,  90, 255); /// Green hue.
enum mu_Color blue          = mu_Color( 70, 140, 220, 255); /// Blue hue.
enum mu_Color red           = mu_Color(220,  70,  70, 255); /// Red hue.
enum mu_Color amber         = mu_Color(220, 170,  60, 255); /// Amber hue.
enum mu_Color purple        = mu_Color(160,  90, 220, 255); /// Purple hue.
enum mu_Color teal          = mu_Color( 54, 215, 192, 255); /// Teal hue, the accent.
enum mu_Color grey          = mu_Color( 90,  90, 100, 255); /// Grey hue, for unlisted.
enum mu_Color greyLight     = mu_Color(120, 120, 120, 255); /// Light grey, for offline.

/// ddui style. Metrics come from ddui's default, colours from here.
private __gshared mu_Style style;

/// Style for mu_init, copied from ddui's default with the client colours.
mu_Style* themeStyle()
{
    style = default_style;
    style.colors[MU_COLOR_TEXT]         = mu_Color(230, 230, 235, 255);
    style.colors[MU_COLOR_BORDER]       = mu_Color( 18,  18,  22, 255);
    style.colors[MU_COLOR_WINDOWBG]     = mu_Color( 42,  45,  55, 255);
    style.colors[MU_COLOR_TITLEBG]      = mu_Color( 25,  27,  33, 255);
    style.colors[MU_COLOR_TITLETEXT]    = mu_Color(240, 240, 245, 255);
    style.colors[MU_COLOR_PANELBG]      = mu_Color(  0,   0,   0,   0);
    style.colors[MU_COLOR_BUTTON]       = mu_Color( 70,  72,  82, 255);
    style.colors[MU_COLOR_BUTTONHOVER]  = mu_Color( 88,  91, 103, 255);
    style.colors[MU_COLOR_BUTTONFOCUS]  = mu_Color(105, 109, 123, 255);
    style.colors[MU_COLOR_BASE]         = mu_Color( 46,  48,  58, 255);
    style.colors[MU_COLOR_BASEHOVER]    = mu_Color( 52,  55,  66, 255);
    style.colors[MU_COLOR_BASEFOCUS]    = mu_Color( 58,  62,  76, 255);
    style.colors[MU_COLOR_SCROLLBASE]   = mu_Color( 38,  40,  48, 255);
    style.colors[MU_COLOR_SCROLLTHUMB]  = mu_Color( 70,  76,  94, 255);
    style.colors[MU_COLOR_SELECTION]    = mu_Color( 60,  90, 160, 255);
    return &style;
}
