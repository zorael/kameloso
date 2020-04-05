/++
 +  A collection of enums and functions that relate to a terminal shell.
 +
 +  Much of this module has to do with terminal text colouring and is therefore
 +  version `Colours`.
 +
 +  Example:
 +  ---
 +  Appender!string sink;
 +
 +  // Output range version
 +  sink.put("Hello ");
 +  sink.colourWith(TerminalForeground.red);
 +  sink.put("world!");
 +  sink.colourWith(TerminalForeground.default_);
 +
 +  with (TerminalForeground)
 +  {
 +      // Normal string-returning version
 +      writeln("Hello ", red.colour, "world!", default_.colour);
 +  }
 +
 +  // Also accepts RGB form
 +  sink.put(" Also");
 +  sink.truecolour(128, 128, 255);
 +  sink.put("magic");
 +  sink.colourWith(TerminalForeground.default_);
 +
 +  with (TerminalForeground)
 +  {
 +      writeln("Also ", truecolour(128, 128, 255), "magic", default_.colour);
 +  }
 +
 +  immutable line = "Surrounding text kameloso surrounding text";
 +  immutable kamelosoInverted = line.invert("kameloso");
 +  assert(line != kamelosoInverted);
 +
 +  immutable tintedNickname = "nickname".colourByHash(false);   // "for bright background" false
 +  immutable tintedSubstring = "substring".colourByHash(true);  // "for bright background" true
 +  ---
 +
 +  It is used heavily in the Printer plugin, to format sections of its output
 +  in different colours, but it's generic enough to use anywhere.
 +
 +  The output range versions are cumbersome but necessary to minimise the number
 +  of strings generated.
 +/
module kameloso.terminal;

private:

import std.meta : allSatisfy;
import std.range.primitives : isOutputRange;
import std.typecons : Flag, No, Yes;

public:

@safe:

/// Special terminal control characters.
enum TerminalToken
{
    /// Character that preludes a terminal colouring code.
    format = '\033',

    /// Terminal bell/beep.
    bell = '\007',

    /// Character that resets a terminal that has entered "binary" mode.
    reset = 15,
}

version (Windows)
{
    // Taken from LDC: https://github.com/ldc-developers/ldc/pull/3086/commits/9626213a
    // https://github.com/ldc-developers/ldc/pull/3086/commits/9626213a

    import core.sys.windows.wincon : SetConsoleCP, SetConsoleMode, SetConsoleOutputCP;

    /// Original codepage at program start.
    __gshared uint originalCP;

    /// Original output codepage at program start.
    __gshared uint originalOutputCP;

    /// Original console mode at program start.
    __gshared uint originalConsoleMode;

    /++
     +  Sets the console codepage to display UTF-8 characters (åäö, 高所恐怖症, ...)
     +  and the console mode to display terminal colours.
     +/
    void setConsoleModeAndCodepage() @system
    {
        import core.stdc.stdlib : atexit;
        import core.sys.windows.winbase : GetStdHandle, INVALID_HANDLE_VALUE, STD_OUTPUT_HANDLE;
        import core.sys.windows.wincon : ENABLE_VIRTUAL_TERMINAL_PROCESSING,
            GetConsoleCP, GetConsoleMode, GetConsoleOutputCP;
        import core.sys.windows.winnls : CP_UTF8;

        originalCP = GetConsoleCP();
        originalOutputCP = GetConsoleOutputCP();

        SetConsoleCP(CP_UTF8);
        SetConsoleOutputCP(CP_UTF8);

        auto stdoutHandle = GetStdHandle(STD_OUTPUT_HANDLE);
        assert((stdoutHandle != INVALID_HANDLE_VALUE), "Failed to get standard output handle");

        immutable getModeRetval = GetConsoleMode(stdoutHandle, &originalConsoleMode);

        if (getModeRetval != 0)
        {
            // The console is a real terminal, not a pager (or Cygwin mintty)
            SetConsoleMode(stdoutHandle, originalConsoleMode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
        }

        // atexit handlers are also called when exiting via exit() etc.;
        // that's the reason this isn't a RAII struct.
        atexit(&resetConsoleModeAndCodepage);
    }

    /++
     +  Resets the console codepage and console mode to the values they had at
     +  program start.
     +/
    extern(C)
    private void resetConsoleModeAndCodepage() @system
    {
        import core.sys.windows.winbase : GetStdHandle, INVALID_HANDLE_VALUE, STD_OUTPUT_HANDLE;

        auto stdoutHandle = GetStdHandle(STD_OUTPUT_HANDLE);
        assert((stdoutHandle != INVALID_HANDLE_VALUE), "Failed to get standard output handle");

        SetConsoleCP(originalCP);
        SetConsoleOutputCP(originalOutputCP);
        SetConsoleMode(stdoutHandle, originalConsoleMode);
    }
}


// setTitle
/++
 +  Sets the terminal title to a given string. Supposedly.
 +
 +  Example:
 +  ---
 +  setTitle("kameloso IRC bot");
 +  ---
 +
 +  Params:
 +      title = String to set the title to.
 +/
void setTitle(const string title) @system
{
    version(Posix)
    {
        import std.stdio : stdout, write;

        write("\033]0;", title, "\007");
        stdout.flush();
    }
    else version(Windows)
    {
        import core.sys.windows.wincon : SetConsoleTitleA;
        import std.string : toStringz;

        SetConsoleTitleA(title.toStringz);
    }
    else
    {
        // Unexpected platform, do nothing
    }
}

version(Colours):

/++
 +  Format codes that work like terminal colouring does, except here for formats
 +  like bold, dim, italics, etc.
 +/
enum TerminalFormat
{
    bold = 1,
    dim  = 2,
    italics = 3,
    underlined = 4,
    blink   = 5,
    reverse = 7,
    hidden  = 8,
}

/// Foreground colour codes for terminal colouring.
enum TerminalForeground
{
    default_     = 39,
    black        = 30,
    red          = 31,
    green        = 32,
    yellow       = 33,
    blue         = 34,
    magenta      = 35,
    cyan         = 36,
    lightgrey    = 37,
    darkgrey     = 90,
    lightred     = 91,
    lightgreen   = 92,
    lightyellow  = 93,
    lightblue    = 94,
    lightmagenta = 95,
    lightcyan    = 96,
    white        = 97,
}

/// Background colour codes for terminal colouring.
enum TerminalBackground
{
    default_     = 49,
    black        = 40,
    red          = 41,
    green        = 42,
    yellow       = 43,
    blue         = 44,
    magenta      = 45,
    cyan         = 46,
    lightgrey    = 47,
    darkgrey     = 100,
    lightred     = 101,
    lightgreen   = 102,
    lightyellow  = 103,
    lightblue    = 104,
    lightmagenta = 105,
    lightcyan    = 106,
    white        = 107,
}

/// Terminal colour/format reset codes.
enum TerminalReset
{
    all         = 0,
    bright      = 21,
    dim         = 22,
    underlined  = 24,
    blink       = 25,
    invert      = 27,
    hidden      = 28,
}

/// Bool of whether or not a type is a colour code enum.
enum isAColourCode(T) = is(T : TerminalForeground) || is(T : TerminalBackground) ||
                        is(T : TerminalFormat) || is(T : TerminalReset) ||
                        is(T == int);  // FIXME


// colour
/++
 +  Takes a mix of a `TerminalForeground`, a `TerminalBackground`, a
 +  `TerminalFormat` and/or a `TerminalReset` and composes them into a single
 +  terminal format code token.
 +
 +  This overload creates an `std.array.Appender` and fills it with the return
 +  value of the output range version of `colour`.
 +
 +  Example:
 +  ---
 +  string blinkOn = colour(TerminalForeground.white, TerminalBackground.yellow, TerminalFormat.blink);
 +  string blinkOff = colour(TerminalForeground.default_, TerminalBackground.default_, TerminalReset.blink);
 +  string blinkyName = blinkOn ~ "Foo" ~ blinkOff;
 +  ---
 +
 +  Params:
 +      codes = Variadic list of terminal format codes.
 +
 +  Returns:
 +      A terminal code sequence of the passed codes.
 +/
version(Colours)
string colour(Codes...)(const Codes codes) pure nothrow
if (Codes.length && allSatisfy!(isAColourCode, Codes))
{
    import std.array : Appender;

    Appender!string sink;
    sink.reserve(16);

    sink.colourWith(codes);
    return sink.data;
}


// colourWith
/++
 +  Takes a mix of a `TerminalForeground`, a `TerminalBackground`, a
 +  `TerminalFormat` and/or a `TerminalReset` and composes them into a format code token.
 +
 +  This is the composing overload that fills its result into an output range.
 +
 +  Example:
 +  ---
 +  Appender!string sink;
 +  sink.colourWith(TerminalForeground.red, TerminalFormat.bold);
 +  sink.put("Foo");
 +  sink.colourWith(TerminalForeground.default_, TerminalReset.bold);
 +  ---
 +
 +  Params:
 +      sink = Output range to write output to.
 +      codes = Variadic list of terminal format codes.
 +/
version(Colours)
void colourWith(Sink, Codes...)(auto ref Sink sink, const Codes codes)
if (isOutputRange!(Sink, char[]) && Codes.length && allSatisfy!(isAColourCode, Codes))
{
    static if (!__traits(hasMember, Sink, "put")) import std.range.primitives : put;

    sink.put(TerminalToken.format);
    sink.put('[');

    uint numCodes;

    foreach (immutable code; codes)
    {
        import lu.conv : toAlphaInto;
        import std.conv : to;

        if (++numCodes > 1) sink.put(';');

        //sink.put((cast(uint)code).to!string);
        (cast(uint)code).toAlphaInto(sink);
    }

    sink.put('m');
}


// colour
/++
 +  Convenience function to colour or format a piece of text without an output
 +  buffer to fill into.
 +
 +  Example:
 +  ---
 +  string foo = "Foo Bar".colour(TerminalForeground.bold, TerminalFormat.reverse);
 +  ---
 +
 +  Params:
 +      text = Text to format.
 +      codes = Terminal formatting codes (colour, underscore, bold, ...) to apply.
 +
 +  Returns:
 +      A terminal code sequence of the passed codes, encompassing the passed text.
 +/
version(Colours)
string colour(Codes...)(const string text, const Codes codes) pure nothrow
if (Codes.length && allSatisfy!(isAColourCode, Codes))
{
    import std.array : Appender;

    Appender!string sink;
    sink.reserve(text.length + 15);

    sink.colourWith(codes);
    sink.put(text);
    sink.colourWith(TerminalReset.all);
    return sink.data;
}


// normaliseColoursBright
/++
 +  Takes a colour and, if it deems it is too bright to see on a light terminal
 +  background, makes it darker.
 +
 +  Example:
 +  ---
 +  int r = 255;
 +  int g = 128;
 +  int b = 100;
 +  normaliseColoursBright(r, g, b);
 +  assert(r != 255);
 +  assert(g != 128);
 +  assert(b != 100);
 +  ---
 +
 +  Params:
 +      r = Reference to a red value.
 +      g = Reference to a green value.
 +      b = Reference to a blue value.
 +/
version(Colours)
void normaliseColoursBright(ref uint r, ref uint g, ref uint b) pure nothrow @nogc
{
    enum pureWhiteReplacement = 120;
    enum pureWhiteRange = 200;

    enum darkenUpperLimit = 255;
    enum darkenLowerLimit = 200;
    enum darken = 45;

    // Sanity check
    if (r > 255) r = 255;
    if (g > 255) g = 255;
    if (b > 255) b = 255;

    if ((r + g + b) == 3*255)
    {
        // Specialcase pure white, set to grey and return
        r = pureWhiteReplacement;
        g = pureWhiteReplacement;
        b = pureWhiteReplacement;
        return;
    }

    // Darken high colours at high levels
    r -= ((r <= darkenUpperLimit) & (r > darkenLowerLimit)) * darken;
    g -= ((g <= darkenUpperLimit) & (g > darkenLowerLimit)) * darken;
    b -= ((b <= darkenUpperLimit) & (b > darkenLowerLimit)) * darken;

    if ((r > pureWhiteRange) && (b > pureWhiteRange) && (g > pureWhiteRange))
    {
        r = pureWhiteReplacement;
        g = pureWhiteReplacement;
        b = pureWhiteReplacement;
    }

    // Sanity check
    if (r > 255) r = 255;
    if (g > 255) g = 255;
    if (b > 255) b = 255;
}


// normaliseColours
/++
 +  Takes a colour and, if it deems it is too dark to see on a black terminal
 +  background, makes it brighter.
 +
 +  Example:
 +  ---
 +  int r = 255;
 +  int g = 128;
 +  int b = 100;
 +  normaliseColours(r, g, b);
 +  assert(r != 255);
 +  assert(g != 128);
 +  assert(b != 100);
 +  ---
 +
 +  Params:
 +      r = Reference to a red value.
 +      g = Reference to a green value.
 +      b = Reference to a blue value.
 +/
version(Colours)
void normaliseColours(ref uint r, ref uint g, ref uint b) pure nothrow @nogc
{
    enum pureBlackReplacement = 120;

    enum tooDarkThreshold = 100;
    enum tooDarkIncrement = 40;

    enum tooBlue = 130;
    enum tooBlueOtherColourThreshold = 45;

    enum highlight = 40;

    enum darkenThreshold = 240;
    enum darken = 20;

    // Sanity check
    if (r > 255) r = 255;
    if (g > 255) g = 255;
    if (b > 255) b = 255;

    if ((r + g + b) == 0)
    {
        // Specialcase pure black, set to grey and return
        r = pureBlackReplacement;
        g = pureBlackReplacement;
        b = pureBlackReplacement;
        return;
    }

    // Raise all low colours
    r += (r < tooDarkThreshold) * tooDarkIncrement;
    g += (g < tooDarkThreshold) * tooDarkIncrement;
    b += (b < tooDarkThreshold) * tooDarkIncrement;

    // Make dark colours more vibrant
    r += ((r > g) & (r > b)) * highlight;
    g += ((g > b) & (g > r)) * highlight;
    b += ((b > g) & (b > r)) * highlight;

    // Whitewash blue slightly
    if ((b > tooBlue) && (r < tooBlueOtherColourThreshold) && (g < tooBlueOtherColourThreshold))
    {
        r += tooBlueOtherColourThreshold;
        g += tooBlueOtherColourThreshold;
    }

    // Make bright colours more biased toward one colour
    r -= ((r > darkenThreshold) & ((r < b) | (r < g))) * darken;
    g -= ((g > darkenThreshold) & ((g < r) | (g < b))) * darken;
    b -= ((b > darkenThreshold) & ((b < r) | (b < g))) * darken;

    // Sanity check
    if (r > 255) r = 255;
    if (g > 255) g = 255;
    if (b > 255) b = 255;
}

version(none)
version(Colours)
unittest
{
    import std.conv : to;
    import std.stdio : write, writeln;

    enum bright = true;
    // ▄█▀

    writeln("BRIGHT: ", bright);

    foreach (i; 0..256)
    {
        int r, g, b;
        r = i;
        int n = i % 10;
        write(n.to!string.truecolour(r, g, b, bright));
        if (n == 0) write(i);
    }

    writeln();

    foreach (i; 0..256)
    {
        int r, g, b;
        g = i;
        int n = i % 10;
        write(n.to!string.truecolour(r, g, b, bright));
        if (n == 0) write(i);
    }

    writeln();

    foreach (i; 0..256)
    {
        int r, g, b;
        b = i;
        int n = i % 10;
        write(n.to!string.truecolour(r, g, b, bright));
        if (n == 0) write(i);
    }

    writeln();

    foreach (i; 0..256)
    {
        int r, g, b;
        r = i;
        g = i;
        int n = i % 10;
        write(n.to!string.truecolour(r, g, b, bright));
        if (n == 0) write(i);
    }

    writeln();

    foreach (i; 0..256)
    {
        int r, g, b;
        r = i;
        b = i;
        int n = i % 10;
        write(n.to!string.truecolour(r, g, b, bright));
        if (n == 0) write(i);
    }

    writeln();

    foreach (i; 0..256)
    {
        int r, g, b;
        g = i;
        b = i;
        int n = i % 10;
        write(n.to!string.truecolour(r, g, b, bright));
        if (n == 0) write(i);
    }

    writeln();

    foreach (i; 0..256)
    {
        int r, g, b;
        r = i;
        g = i;
        b = i;
        int n = i % 10;
        write(n.to!string.truecolour(r, g, b, bright));
        if (n == 0) write(i);
    }

    writeln();
}


// truecolour
/++
 +  Produces a terminal colour token for the colour passed, expressed in terms
 +  of red, green and blue.
 +
 +  Example:
 +  ---
 +  Appender!string sink;
 +  int r, g, b;
 +  numFromHex("3C507D", r, g, b);
 +  sink.truecolour(r, g, b);
 +  sink.put("Foo");
 +  sink.colourWith(TerminalReset.all);
 +  writeln(sink);  // "Foo" in #3C507D
 +  ---
 +
 +  Params:
 +      normalise = Whether or not to normalise colours so that they aren't too
            dark or too bright.
 +      sink = Output range to write the final code into.
 +      r = Red value.
 +      g = Green value.
 +      b = Blue value.
 +      bright = Whether the terminal has a bright background or not.
 +/
version(Colours)
void truecolour(Flag!"normalise" normalise = Yes.normalise, Sink)
    (auto ref Sink sink, uint r, uint g, uint b, const bool bright = false)
if (isOutputRange!(Sink, char[]))
{
    import lu.conv : toAlphaInto;

    // \033[
    // 38 foreground
    // 2 truecolour?
    // r;g;bm

    static if (normalise)
    {
        if (bright)
        {
            normaliseColoursBright(r, g, b);
        }
        else
        {
            normaliseColours(r, g, b);
        }
    }

    sink.put(cast(char)TerminalToken.format);
    sink.put("[38;2;");
    r.toAlphaInto(sink);
    sink.put(';');
    g.toAlphaInto(sink);
    sink.put(';');
    b.toAlphaInto(sink);
    sink.put('m');
}


// truecolour
/++
 +  Convenience function to colour a piece of text without being passed an
 +  output sink to fill into.
 +
 +  Example:
 +  ---
 +  string foo = "Foo Bar".truecolour(172, 172, 255);
 +
 +  int r, g, b;
 +  numFromHex("003388", r, g, b);
 +  string bar = "Bar Foo".truecolour(r, g, b);
 +  ---
 +
 +  Params:
 +      normalise = Whether or not to normalise colours so that they aren't too
 +          dark or too bright.
 +      word = String to tint.
 +      r = Red value.
 +      g = Green value.
 +      b = Blue value.
 +      bright = Whether the terminal has a bright background or not.
 +
 +  Returns:
 +      The passed string word encompassed by terminal colour tags.
 +/
version(Colours)
string truecolour(Flag!"normalise" normalise = Yes.normalise)
    (const string word, const uint r, const uint g, const uint b, const bool bright = false)
{
    import std.array : Appender;

    Appender!string sink;
    // \033[38;2;255;255;255m<word>\033[m
    // \033[48 for background
    sink.reserve(word.length + 23);

    sink.truecolour!normalise(r, g, b, bright);
    sink.put(word);
    sink.colourWith(TerminalReset.all);
    return sink.data;
}

///
version(Colours)
unittest
{
    import std.format : format;

    immutable name = "blarbhl".truecolour!(No.normalise)(255,255,255);
    immutable alsoName = "%c[38;2;%d;%d;%dm%s%c[0m"
        .format(cast(char)TerminalToken.format, 255, 255, 255,
        "blarbhl", cast(char)TerminalToken.format);

    assert((name == alsoName), alsoName);
}


// invert
/++
 +  Terminal-inverts the colours of a piece of text in a string.
 +
 +  Example:
 +  ---
 +  immutable line = "This is an example!";
 +  writeln(line.invert("example"));  // "example" substring visually inverted
 +  writeln(line.invert!(Yes.caseInsensitive)("EXAMPLE")); // "example" inverted as "EXAMPLE"
 +  ---
 +
 +  Params:
 +      caseSensitive = Whether or not to look for matches case-insensitively,
 +          yet invert with the casing passed.
 +      line = Line to examine and invert a substring of.
 +      toInvert = Substring to invert.
 +
 +  Returns:
 +      Line with the substring in it inverted, if inversion was successful,
 +      else (a duplicate of) the line unchanged.
 +/
version(Colours)
string invert(Flag!"caseSensitive" caseSensitive = Yes.caseSensitive)
    (const string line, const string toInvert)
{
    import dialect.common : isValidNicknameCharacter;
    import std.array : Appender;
    import std.format : format;
    import std.string : indexOf;

    static if (caseSensitive)
    {
        ptrdiff_t startpos = line.indexOf(toInvert);
    }
    else
    {
        import std.algorithm.searching : countUntil;
        import std.uni : asLowerCase;
        ptrdiff_t startpos = line.asLowerCase.countUntil(toInvert.asLowerCase);
    }

    //assert((startpos != -1), "Tried to invert nonexistent text");
    if (startpos == -1) return line;

    immutable inverted = "%c[%dm%s%c[%dm".format(TerminalToken.format,
        TerminalFormat.reverse, toInvert, TerminalToken.format, TerminalReset.invert);

    Appender!string sink;
    sink.reserve(line.length + 16);
    string slice = line;  // mutable

    uint i;

    do
    {
        immutable endpos = startpos + toInvert.length;

        if ((startpos == 0) && (i > 0))
        {
            // Not the first run and begins with the nick --> run-on nicks
            sink.put(slice[0..endpos]);
        }
        else if (endpos == slice.length)
        {
            // Line ends with the string; break
            sink.put(slice[0..startpos]);
            sink.put(inverted);
            //break;
        }
        else if ((startpos > 1) && slice[startpos-1].isValidNicknameCharacter)
        {
            // string is in the middle of a string, like abcTHISdef; skip
            sink.put(slice[0..endpos]);
        }
        else if (slice[endpos].isValidNicknameCharacter)
        {
            // string ends with a nick character --> different nick; skip
            sink.put(slice[0..endpos]);
        }
        else
        {
            // Begins at string start, or trailed by non-nickname character
            sink.put(slice[0..startpos]);
            sink.put(inverted);
        }

        ++i;
        slice = slice[endpos..$];
        startpos = slice.indexOf(toInvert);
    }
    while (startpos != -1);

    // Add the remainder, from the last match to the end
    sink.put(slice);

    return sink.data;
}

///
version(Colours)
unittest
{
    import std.format : format;

    immutable pre = "%c[%dm".format(TerminalToken.format, TerminalFormat.reverse);
    immutable post = "%c[%dm".format(TerminalToken.format, TerminalReset.invert);

    {
        immutable line = "abc".invert("abc");
        immutable expected = pre ~ "abc" ~ post;
        assert((line == expected), line);
    }
    {
        immutable line = "abc abc".invert("abc");
        immutable inverted = pre ~ "abc" ~ post;
        immutable expected = inverted ~ ' ' ~ inverted;
        assert((line == expected), line);
    }
    {
        immutable line = "abca abc".invert("abc");
        immutable inverted = pre ~ "abc" ~ post;
        immutable expected = "abca " ~ inverted;
        assert((line == expected), line);
    }
    {
        immutable line = "abcabc".invert("abc");
        immutable expected = "abcabc";
        assert((line == expected), line);
    }
    {
        immutable line = "kameloso^^".invert("kameloso");
        immutable expected = "kameloso^^";
        assert((line == expected), line);
    }
    {
        immutable line = "foo kameloso bar".invert("kameloso");
        immutable expected = "foo " ~ pre ~ "kameloso" ~ post ~ " bar";
        assert((line == expected), line);
    }
    {
        immutable line = "fookameloso bar".invert("kameloso");
        immutable expected = "fookameloso bar";
        assert((line == expected), line);
    }
    {
        immutable line = "foo kamelosobar".invert("kameloso");
        immutable expected = "foo kamelosobar";
        assert((line == expected), line);
    }
    {
        immutable line = "foo(kameloso)bar".invert("kameloso");
        immutable expected = "foo(" ~ pre ~ "kameloso" ~ post ~ ")bar";
        assert((line == expected), line);
    }
    {
        immutable line = "kameloso: 8ball".invert("kameloso");
        immutable expected = pre ~ "kameloso" ~ post ~ ": 8ball";
        assert((line == expected), line);
    }
    {
        immutable line = "Welcome to the freenode Internet Relay Chat Network kameloso^"
            .invert("kameloso^");
        immutable expected = "Welcome to the freenode Internet Relay Chat Network " ~
            pre ~ "kameloso^" ~ post;
        assert((line == expected), line);
    }
    {
        immutable line = "kameloso^: wfwef".invert("kameloso^");
        immutable expected = pre ~ "kameloso^" ~ post ~ ": wfwef";
        assert((line == expected), line);
    }
    {
        immutable line = "[kameloso^]".invert("kameloso^");
        immutable expected = "[kameloso^]";
        assert((line == expected), line);
    }
    {
        immutable line = `"kameloso^"`.invert("kameloso^");
        immutable expected = "\"" ~ pre ~ "kameloso^" ~ post ~ "\"";
        assert((line == expected), line);
    }
    {
        immutable line = "kameloso^".invert("kameloso");
        immutable expected = "kameloso^";
        assert((line == expected), line);
    }
    {
        immutable line = "That guy kameloso? is a bot".invert("kameloso");
        immutable expected = "That guy " ~ pre ~ "kameloso" ~ post  ~ "? is a bot";
        assert((line == expected), line);
    }
    {
        immutable line = "kameloso`".invert("kameloso");
        immutable expected = "kameloso`";
        assert((line == expected), line);
    }
    {
        immutable line = "kameloso9".invert("kameloso");
        immutable expected = "kameloso9";
        assert((line == expected), line);
    }
    {
        immutable line = "kameloso-".invert("kameloso");
        immutable expected = "kameloso-";
        assert((line == expected), line);
    }
    {
        immutable line = "kameloso_".invert("kameloso");
        immutable expected = "kameloso_";
        assert((line == expected), line);
    }
    {
        immutable line = "kameloso_".invert("kameloso_");
        immutable expected = pre ~ "kameloso_" ~ post;
        assert((line == expected), line);
    }
    {
        immutable line = "kameloso kameloso kameloso kameloso kameloso".invert("kameloso");
        immutable expected = "%1$skameloso%2$s %1$skameloso%2$s %1$skameloso%2$s %1$skameloso%2$s %1$skameloso%2$s"
            .format(pre, post);
        assert((line == expected), line);
    }

    // Case-insensitive tests

    {
        immutable line = "KAMELOSO".invert!(No.caseSensitive)("kameloso");
        immutable expected = pre ~ "kameloso" ~ post;
        assert((line == expected), line);
    }
    {
        immutable line = "KamelosoTV".invert!(No.caseSensitive)("kameloso");
        immutable expected = "KamelosoTV";
        assert((line == expected), line);
    }
    {
        immutable line = "Blah blah kAmElOsO Blah blah".invert!(No.caseSensitive)("kameloso");
        immutable expected = "Blah blah " ~ pre ~ "kameloso" ~ post ~ " Blah blah";
        assert((line == expected), line);
    }
    {
        immutable line = "Blah blah".invert("kameloso");
        immutable expected = "Blah blah";
        assert((line == expected), line);
    }
    {
        immutable line = "".invert("kameloso");
        immutable expected = "";
        assert((line == expected), line);
    }
    {
        immutable line = "KAMELOSO".invert("kameloso");
        immutable expected = "KAMELOSO";
        assert((line == expected), line);
    }
}


// colourByHash
/++
 +  Hashes the passed string and picks a `TerminalForeground` colour by modulo.
 +
 +  Example:
 +  ---
 +  immutable colouredNick = "kameloso".colourByHash;
 +  immutable colouredNickBright = "kameloso".colourByHash(Yes.bright);
 +  ---
 +
 +  Params:
 +      word = String to hash and base colour on.
 +      bright = Whether or not the colour should be appropriate for a bright terminal background.
 +
 +  Returns:
 +      A `TerminalForeground` based on the passed string.
 +/
version(Colours)
TerminalForeground colourByHash(const string word, const bool bright) pure @nogc nothrow
in (word.length, "Tried to colour by hash but no word was given")
do
{
    import kameloso.constants : DefaultColours;
    import std.algorithm.searching : countUntil;
    import std.traits : EnumMembers;

    alias Bright = DefaultColours.EventPrintingBright;
    alias Dark = DefaultColours.EventPrintingDark;
    alias foregroundMembers = EnumMembers!TerminalForeground;

    static immutable TerminalForeground[foregroundMembers.length] fg = [ foregroundMembers ];

    enum chancodeBright = fg[].countUntil(cast(int)Bright.channel);
    enum chancodeDark = fg[].countUntil(cast(int)Dark.channel);

    // Range from 2 to 15, excluding black and white and manually changing
    // the code for bright/dark channel to black/white
    size_t colourIndex = (hashOf(word) % 14) + 2;

    if (bright)
    {
        // Index is bright channel code, set to black
        if (colourIndex == chancodeBright) colourIndex = 1;  // black
    }
    else
    {
        // Index is dark channel code, set to white
        if (colourIndex == chancodeDark) colourIndex = 16; // white
    }

    return fg[colourIndex];
}

///
version(Colours)
unittest
{
    import lu.conv : Enum;

    alias FG = TerminalForeground;

    {
        immutable hash = colourByHash("kameloso", false);
        assert((hash == FG.lightgreen), Enum!FG.toString(hash));
    }
    {
        immutable hash = colourByHash("kameloso^", false);
        assert((hash == FG.lightcyan), Enum!FG.toString(hash));
    }
    {
        immutable hash = colourByHash("zorael", false);
        assert((hash == FG.cyan), Enum!FG.toString(hash));
    }
    {
        immutable hash = colourByHash("NO", false);
        assert((hash == FG.lightred), Enum!FG.toString(hash));
    }
}
