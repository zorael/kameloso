/++
    Enum definitions of ANSI codes.

    See_Also:
        [kameloso.terminal],
        [kameloso.terminal.colours],
        [kameloso.terminal.colours.tags]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.terminal.colours.defs;


// TerminalFormat
/++
    Format codes that work like terminal colouring does, except here for formats
    like bold, dim, italics, etc.
 +/
enum TerminalFormat
{
    unset       = 0,  /// Seemingly resets to nothing.
    bold        = 1,  /// Bold.
    dim         = 2,  /// Dim, darkens it a bit.
    italics     = 3,  /// Italics; usually has some other effect.
    underlined  = 4,  /// Underlined.
    blink       = 5,  /// Blinking text.
    reverse     = 7,  /// Inverts text foreground and background.
    hidden      = 8,  /// "Hidden" text.
}


// TerminalForeground
/++
    The basic 16+1 foreground colour codes of terminal colouring.
 +/
enum TerminalForeground
{
    default_     = 39,  /// Default grey.
    black        = 30,  /// Black.
    red          = 31,  /// Red.
    green        = 32,  /// Green.
    yellow       = 33,  /// Yellow.
    blue         = 34,  /// Blue.
    magenta      = 35,  /// Magenta.
    cyan         = 36,  /// Cyan.
    lightgrey    = 37,  /// Light grey.
    darkgrey     = 90,  /// Dark grey.
    lightred     = 91,  /// Light red.
    lightgreen   = 92,  /// Light green.
    lightyellow  = 93,  /// Light yellow.
    lightblue    = 94,  /// Light blue.
    lightmagenta = 95,  /// Light magenta.
    lightcyan    = 96,  /// Light cyan.
    white        = 97,  /// White.
}


// TerminalBackground
/++
    The basic 16+1 background colour codes of terminal colouring.
 +/
enum TerminalBackground
{
    default_     = 49,  /// Default background colour.
    black        = 40,  /// Black.
    red          = 41,  /// Red.
    green        = 42,  /// Green.
    yellow       = 43,  /// Yellow.
    blue         = 44,  /// Blue.
    magenta      = 45,  /// Magenta.
    cyan         = 46,  /// Cyan.
    lightgrey    = 47,  /// Light grey.
    darkgrey     = 100, /// Dark grey.
    lightred     = 101, /// Light red.
    lightgreen   = 102, /// Light green.
    lightyellow  = 103, /// Light yellow.
    lightblue    = 104, /// Light blue.
    lightmagenta = 105, /// Light magenta.
    lightcyan    = 106, /// Light cyan.
    white        = 107, /// White.
}


// TerminalReset
/++
    Terminal colour/format reset codes.
 +/
enum TerminalReset
{
    all         = 0,    /// Resets everything.
    bright      = 21,   /// Resets "brighter" colours.
    dim         = 22,   /// Resets "dim" colours.
    underlined  = 24,   /// Resets underlined text.
    blink       = 25,   /// Resets blinking text.
    invert      = 27,   /// Resets inverted text.
    hidden      = 28,   /// Resets hidden text.
}


// ANSICodeType
/++
    ANSI code type bitflag enum.
 +/
enum ANSICodeType
{
    unset      = 0,       // init value.
    foreground = 1 << 0,  // Foreground colour.
    background = 1 << 1,  // Background colour.
    format     = 1 << 2,  // Format token.
    reset      = 1 << 3,  // Reset token.
}
