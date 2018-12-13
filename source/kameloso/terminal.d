/++
 +  A collection of enums and functions that relate to a terminal shell.
 +
 +  Much of this module has to do with terminal text colouring and is therefore
 +  version `Colours`.
 +/
module kameloso.terminal;

import std.meta : allSatisfy;
import std.typecons : Flag, No, Yes;

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

/// Bool of whether a type is a colour code enum.
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

    sink.colour(codes);
    return sink.data;
}


// colour
/++
 +  Takes a mix of a `TerminalForeground`, a `TerminalBackground`, a
 +  `TerminalFormat` and/or a `TerminalReset` and composes them into a format
 +  code token.
 +
 +  This is the composing overload that fills its result into an output range.
 +
 +  Example:
 +  ---
 +  Appender!string sink;
 +  sink.colour(TerminalForeground.red, TerminalFormat.bold);
 +  sink.put("Foo");
 +  sink.colour(TerminalForeground.default_, TerminalReset.bold);
 +  ---
 +
 +  Params:
 +      sink = Output range to write output to.
 +      codes = Variadic list of terminal format codes.
 +/
import std.range : isOutputRange;
version(Colours)
void colour(Sink, Codes...)(auto ref Sink sink, const Codes codes)
if (isOutputRange!(Sink, string) && Codes.length && allSatisfy!(isAColourCode, Codes))
{
    sink.put(TerminalToken.format);
    sink.put('[');

    uint numCodes;

    foreach (immutable code; codes)
    {
        import std.conv : to;

        if (++numCodes > 1) sink.put(';');

        sink.put((cast(uint)code).to!string);
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

    sink.colour(codes);
    sink.put(text);
    sink.colour(TerminalReset.all);
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
void normaliseColours(ref uint r, ref uint g, ref uint b) pure nothrow @nogc
{
    enum pureBlackReplacement = 150;

    enum tooDarkThreshold = 140;
    enum tooDarkIncrement = 80;

    enum highlight = 20;

    enum darkenThreshold = 200;
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
 +  sink.colour(TerminalReset.all);
 +  writeln(sink);  // "Foo" in #3C507D
 +  ---
 +
 +  Params:
 +      normalise = Whether to normalise colours so that they aren't too dark.
 +      sink = Output range to write the final code into.
 +      r = Red value.
 +      g = Green value.
 +      b = Blue value.
 +      bright = Whether the terminal has a bright background or not.
 +/
version(Colours)
void truecolour(Flag!"normalise" normalise = Yes.normalise, Sink)
    (auto ref Sink sink, uint r, uint g, uint b, const bool bright = false)
if (isOutputRange!(Sink, string))
{
    import std.format : formattedWrite;

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

    sink.formattedWrite("%c[38;2;%d;%d;%dm", cast(char)TerminalToken.format, r, g, b);
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
 +      normalise = Whether to normalise colours so that they aren't too dark.
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
    sink.colour(TerminalReset.all);
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
 +  ---
 +
 +  Params:
 +      line = Line to examine and invert a substring of.
 +      toInvert = Substring to invert.
 +
 +  Returns:
 +      Line with the substring in it inverted, if inversion was successful,
 +      else (a duplicate of) the line unchanged.
 +/
version(Colours)
string invert(const string line, const string toInvert)
{
    import kameloso.irc.common : isValidNicknameCharacter;
    import std.array : Appender;
    import std.format : format;
    import std.string : indexOf;

    immutable inverted = "%c[%dm%s%c[%dm".format(TerminalToken.format,
        TerminalFormat.reverse, toInvert, TerminalToken.format, TerminalReset.invert);

    Appender!string sink;
    sink.reserve(512);  // Maximum IRC message length by spec
    string slice = line;

    ptrdiff_t startpos = slice.indexOf(toInvert);
    assert((startpos != -1), "Tried to invert nonexistent text");

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
}
