/++
    A collection of functions that relate to applying ANSI effects to text.

    This submodule has to do with terminal text colouring and is therefore
    gated behind version `Colours`.

    Example:
    ---
    Appender!(char[]) sink;

    // Output range version
    sink.put("Hello ");
    sink.applyANSI(TerminalForeground.red, ANSICodeType.foreground);
    sink.put("world!");
    sink.applyANSI(TerminalForeground.default_, ANSICodeType.foreground);

    with (TerminalForeground)
    {
        // Normal string-returning versions
        writeln("Hello ", red.asANSI, "world!", default_.asANSI);
        writeln("H3LL0".withANSI(red), ' ', "W0RLD!".withANSI(default_));
    }

    // Also accepts RGB form
    sink.put(" Also");
    sink.applyTruecolour(128, 128, 255);
    sink.put("magic");
    sink.applyANSI(TerminalForeground.default_);

    with (TerminalForeground)
    {
        writeln("Also ", asTruecolour(128, 128, 255), "magic", default_.asANSI);
    }

    immutable line = "Surrounding text kameloso surrounding text";
    immutable kamelosoInverted = line.invert("kameloso");
    assert(line != kamelosoInverted);

    immutable nicknameTint = "nickname".getColourByHash(*kameloso.common.settings);
    immutable substringTint = "substring".getColourByHash(*kameloso.common.settings);
    ---

    It is used heavily in the Printer plugin, to format sections of its output
    in different colours, but it's generic enough to use anywhere.

    The output range versions are cumbersome but necessary to minimise the number
    of strings generated.

    See_Also:
        [kameloso.terminal.colours.defs]

        [kameloso.terminal.colours.tags]

        [kameloso.terminal]
 +/
module kameloso.terminal.colours;

version(Colours):

private:

import kameloso.terminal : TerminalToken;
import kameloso.terminal.colours.defs : ANSICodeType;
import kameloso.pods : CoreSettings;
import std.range : isOutputRange;
import std.typecons : Flag, No, Yes;

public:


// applyANSI
/++
    Applies an ANSI code to a passed output range.

    Example:
    ---
    Appender!(char[]) sink;

    sink.put("Hello ");
    sink.applyANSI(TerminalForeground.red, ANSICodeType.foreground);
    sink.put("world!");
    sink.applyANSI(TerminalForeground.default_, ANSICodeType.foreground);
    ---

    Params:
        sink = Output range sink to write to.
        code = ANSI code to apply.
        overrideType = Force a specific [kameloso.terminal.colour.defs.ANSICodeType|ANSICodeType]
            in cases where there is ambiguity.
 +/
void applyANSI(Sink)
    (auto ref Sink sink,
    const uint code,
    const ANSICodeType overrideType = ANSICodeType.unset)
if (isOutputRange!(Sink, char[]))
{
    import lu.conv : toAlphaInto;

    void putBasic()
    {
        code.toAlphaInto(sink);
    }

    void putExtendedForegroundColour()
    {
        enum foregroundPrelude = "38;5;";
        sink.put(foregroundPrelude);
        code.toAlphaInto(sink);
    }

    void putExtendedBackgroundColour()
    {
        enum backgroundPrelude = "48;5;";
        sink.put(backgroundPrelude);
        code.toAlphaInto(sink);
    }

    sink.put(cast(char)TerminalToken.format);
    sink.put('[');
    scope(exit) sink.put('m');

    with (ANSICodeType)
    final switch (overrideType)
    {
    case foreground:
        if (((code >= 30) && (code <= 39)) ||
            ((code >= 90) && (code <= 97)))
        {
            // Basic foreground colour
            return putBasic();
        }
        else
        {
            // Extended foreground colour
            return putExtendedForegroundColour();
        }

    case background:
        if (((code >= 40) && (code <= 49)) ||
            ((code >= 100) && (code <= 107)))
        {
            // Basic background colour
            return putBasic();
        }
        else
        {
            // Extended background colour
            return putExtendedBackgroundColour();
        }

    case format:
    case reset:
        return putBasic();

    case unset:
        // Infer as best as possible
        switch (code)
        {
        case 1:
        ..
        case 8:
            // Format
            goto case;

        case 0:
        case 21:
        ..
        case 28:
            // Reset token
            goto case;

        case 40:
        ..
        case 49:
        case 100:
        ..
        case 107:
            // Background colour
            //enum backgroundPrelude = "48;5;";
            //sink.put(backgroundPrelude);
            goto case;

        case 30:
        ..
        case 39:
        case 90:
        ..
        case 97:
            // Basic foreground colour
            return putBasic();

        default:
            // Extended foreground colour
            return putExtendedForegroundColour();
        }
    }
}


// withANSI
/++
    Applies an ANSI code to a passed string and returns it as a new one.
    Convenience function to colour a piece of text without being passed an
    output sink to fill into.

    Example:
    ---
    with (TerminalForeground)
    {
        // Normal string-returning versions
        writeln("Hello ", red.asANSI, "world!", default_.asANSI);
        writeln("H3LL0".withANSI(red), ' ', "W0RLD!".withANSI(default_));
    }
    ---

    Params:
        text = Original string.
        code = ANSI code.
        overrideType = Force a specific [kameloso.terminal.colour.defs.ANSICodeType|ANSICodeType]
            in cases where there is ambiguity.

    Returns:
        A new string consisting of the passed `text` argument, but with the supplied
        ANSI code applied.
 +/
string withANSI(
    const string text,
    const uint code,
    const ANSICodeType overrideType = ANSICodeType.unset) pure @safe nothrow
{
    import kameloso.terminal.colours.defs : TerminalReset;
    import std.array : Appender;

    Appender!(char[]) sink;
    sink.reserve(text.length + 8);
    sink.applyANSI(code, overrideType);
    sink.put(text);
    sink.applyANSI(TerminalReset.all);
    return sink.data;
}


// asANSI
/++
    Returns an ANSI format sequence containing the passed code.

    Params:
        code = ANSI code.

    Returns:
        A string containing the passed ANSI `code` as an ANSI sequence.
 +/
string asANSI(const uint code) pure @safe nothrow
{
    import std.array : Appender;

    Appender!(char[]) sink;
    sink.reserve(16);
    sink.applyANSI(code);
    return sink.data;
}


// normaliseColoursBright
/++
    Takes a colour and, if it deems it is too bright to see on a light terminal
    background, makes it darker.

    Example:
    ---
    int r = 255;
    int g = 128;
    int b = 100;
    normaliseColoursBright(r, g, b);
    assert(r != 255);
    assert(g != 128);
    assert(b != 100);
    ---

    Params:
        r = Reference to a red value.
        g = Reference to a green value.
        b = Reference to a blue value.
 +/
private void normaliseColoursBright(ref uint r, ref uint g, ref uint b) pure @safe nothrow @nogc
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
    r -= ((r <= darkenUpperLimit) && (r > darkenLowerLimit)) * darken;
    g -= ((g <= darkenUpperLimit) && (g > darkenLowerLimit)) * darken;
    b -= ((b <= darkenUpperLimit) && (b > darkenLowerLimit)) * darken;

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
    Takes a colour and, if it deems it is too dark to see on a black terminal
    background, makes it brighter.

    Example:
    ---
    int r = 255;
    int g = 128;
    int b = 100;
    normaliseColours(r, g, b);
    assert(r != 255);
    assert(g != 128);
    assert(b != 100);
    ---

    Params:
        r = Reference to a red value.
        g = Reference to a green value.
        b = Reference to a blue value.
 +/
private void normaliseColours(ref uint r, ref uint g, ref uint b) pure @safe nothrow @nogc
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
    r -= ((r > darkenThreshold) && ((r < b) | (r < g))) * darken;
    g -= ((g > darkenThreshold) && ((g < r) | (g < b))) * darken;
    b -= ((b > darkenThreshold) && ((b < r) | (b < g))) * darken;

    // Sanity check
    if (r > 255) r = 255;
    if (g > 255) g = 255;
    if (b > 255) b = 255;
}

version(none)
unittest
{
    import std.conv : to;
    import std.stdio : write, writeln;

    enum bright = Yes.brightTerminal;
    // ▄█▀

    writeln("BRIGHT: ", bright);

    foreach (r; 0..256)
    {
        immutable n = r % 10;
        write(n.to!string.truecolour(r, 0, 0, bright));
        if (n == 0) write(r);
    }

    writeln();

    foreach (g; 0..256)
    {
        immutable n = g % 10;
        write(n.to!string.truecolour(0, g, 0, bright));
        if (n == 0) write(g);
    }

    writeln();

    foreach (b; 0..256)
    {
        immutable n = b % 10;
        write(n.to!string.truecolour(0, 0, b, bright));
        if (n == 0) write(b);
    }

    writeln();

    foreach (rg; 0..256)
    {
        immutable n = rg % 10;
        write(n.to!string.truecolour(rg, rg, 0, bright));
        if (n == 0) write(rg);
    }

    writeln();

    foreach (rb; 0..256)
    {
        immutable n = rb % 10;
        write(n.to!string.truecolour(rb, 0, rb, bright));
        if (n == 0) write(rb);
    }

    writeln();

    foreach (gb; 0..256)
    {
        immutable n = gb % 10;
        write(n.to!string.truecolour(0, gb, gb, bright));
        if (n == 0) write(gb);
    }

    writeln();

    foreach (rgb; 0..256)
    {
        immutable n = rgb % 10;
        write(n.to!string.truecolour(rgb, rgb, rgb, bright));
        if (n == 0) write(rgb);
    }

    writeln();
}


// applyTruecolour
/++
    Produces a terminal colour token for the colour passed, expressed in terms
    of red, green and blue, then writes it to the passed output range.

    Example:
    ---
    Appender!(char[]) sink;
    int r, g, b;
    numFromHex("3C507D", r, g, b);
    sink.applyTruecolour(r, g, b);
    sink.put("Foo");
    sink.applyANSI(TerminalReset.all);
    writeln(sink);  // "Foo" in #3C507D
    ---

    Params:
        sink = Output range to write the final code into.
        r = Red value.
        g = Green value.
        b = Blue value.
        bright = Whether the terminal has a bright background or not.
        normalise = Whether or not to normalise colours so that they aren't too
            dark or too bright.
 +/
void applyTruecolour(Sink)
    (auto ref Sink sink,
    uint r,
    uint g,
    uint b,
    const Flag!"brightTerminal" bright = No.brightTerminal,
    const Flag!"normalise" normalise = Yes.normalise)
if (isOutputRange!(Sink, char[]))
{
    import lu.conv : toAlphaInto;

    // \033[
    // 38 foreground
    // 2 truecolour?
    // r;g;bm

    if (normalise)
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


// asTruecolour
/++
    Produces a terminal colour token for the colour passed, expressed in terms
    of red, green and blue. Convenience function to colour a piece of text
    without being passed an output sink to fill into.

    Example:
    ---
    string foo = "Foo Bar".asTruecolour(172, 172, 255);

    int r, g, b;
    numFromHex("003388", r, g, b);
    string bar = "Bar Foo".asTruecolour(r, g, b);
    ---

    Params:
        word = String to tint.
        r = Red value.
        g = Green value.
        b = Blue value.
        bright = Whether the terminal has a bright background or not.
        normalise = Whether or not to normalise colours so that they aren't too
            dark or too bright.

    Returns:
        The passed string word encompassed by terminal colour tags.
 +/
string asTruecolour(
    const string word,
    const uint r,
    const uint g,
    const uint b,
    const Flag!"brightTerminal" bright = No.brightTerminal,
    const Flag!"normalise" normalise = Yes.normalise) pure @safe
{
    import kameloso.terminal.colours.defs : TerminalReset;
    import std.array : Appender;

    Appender!(char[]) sink;
    // \033[38;2;255;255;255m<word>\033[m
    // \033[48 for background
    sink.reserve(word.length + 23);

    sink.applyTruecolour(r, g, b, bright, normalise);
    sink.put(word);
    sink.applyANSI(TerminalReset.all);
    return sink.data;
}

///
unittest
{
    import std.format : format;

    immutable name = "blarbhl".asTruecolour(255, 255, 255, No.brightTerminal, No.normalise);
    immutable alsoName = "%c[38;2;%d;%d;%dm%s%c[0m"
        .format(cast(char)TerminalToken.format, 255, 255, 255,
           "blarbhl", cast(char)TerminalToken.format);

    assert((name == alsoName), alsoName);
}


// invert
/++
    Terminal-inverts the colours of a piece of text in a string.

    Example:
    ---
    immutable line = "This is an example!";
    writeln(line.invert("example"));  // "example" substring visually inverted
    writeln(line.invert("EXAMPLE", Yes.caseInsensitive)); // "example" inverted as "EXAMPLE"
    ---

    Params:
        line = Line to examine and invert a substring of.
        toInvert = Substring to invert.
        caseSensitive = Whether or not to look for matches case-insensitively,
            yet invert with the casing passed.

    Returns:
        Line with the substring in it inverted, if inversion was successful,
        else (a duplicate of) the line unchanged.
 +/
string invert(
    const string line,
    const string toInvert,
    const Flag!"caseSensitive" caseSensitive = Yes.caseSensitive) pure @safe
{
    import kameloso.terminal.colours.defs : TerminalFormat, TerminalReset;
    import dialect.common : isValidNicknameCharacter;
    import std.array : Appender;
    import std.format : format;
    import std.string : indexOf;

    ptrdiff_t startpos;

    if (caseSensitive)
    {
        startpos = line.indexOf(toInvert);
    }
    else
    {
        import std.algorithm.searching : countUntil;
        import std.uni : asLowerCase;
        startpos = line.asLowerCase.countUntil(toInvert.asLowerCase);
    }

    //assert((startpos != -1), "Tried to invert nonexistent text");
    if (startpos == -1) return line;

    enum pattern = "%c[%dm%s%c[%dm";
    immutable inverted = pattern.format(
        TerminalToken.format,
        TerminalFormat.reverse,
        toInvert,
        TerminalToken.format,
        TerminalReset.invert);

    Appender!(char[]) sink;
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
unittest
{
    import kameloso.terminal.colours.defs : TerminalFormat, TerminalReset;
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
        immutable line = "KAMELOSO".invert("kameloso", No.caseSensitive);
        immutable expected = pre ~ "kameloso" ~ post;
        assert((line == expected), line);
    }
    {
        immutable line = "KamelosoTV".invert("kameloso", No.caseSensitive);
        immutable expected = "KamelosoTV";
        assert((line == expected), line);
    }
    {
        immutable line = "Blah blah kAmElOsO Blah blah".invert("kameloso", No.caseSensitive);
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


// getColourByHash
/++
    Hashes the passed string and picks an ANSI colour for it by modulo.

    Picks any colour, taking care not to pick black or white based on
    the passed [kameloso.pods.CoreSettings|CoreSettings] struct (which has a
    field that signifies a bright terminal background).

    Example:
    ---
    immutable nickColour = "kameloso".getColourByHash(*kameloso.common.settings);
    ---

    Params:
        word = String to hash and base colour on.
        settings = A copy of the program-global [kameloso.pods.CoreSettings|CoreSettings].

    Returns:
        A `uint` that can be used in an ANSI foreground colour sequence.
 +/
auto getColourByHash(const string word, const CoreSettings settings) pure @safe /*@nogc*/ nothrow
in (word.length, "Tried to get colour by hash but no word was given")
{
    import kameloso.irccolours : ircANSIColourMap;
    import kameloso.terminal.colours.defs : TerminalForeground;
    import std.traits : EnumMembers;

    static immutable basicForegroundMembers = [ EnumMembers!TerminalForeground ];

    static immutable uint[basicForegroundMembers.length+(-2)] brightTableBasic =
        TerminalForeground.black ~ basicForegroundMembers[2..$-1];

    static immutable uint[basicForegroundMembers.length+(-2)] darkTableBasic =
        TerminalForeground.white ~ basicForegroundMembers[2..$-1];

    enum brightTableExtended = ()
    {
        uint[98] colourTable = ircANSIColourMap[1..$].dup;

        // Tweak colours, darken some very bright ones
        colourTable[0] = TerminalForeground.black;
        colourTable[11] = TerminalForeground.yellow;
        colourTable[53] = 224;
        colourTable[65] = 222;
        colourTable[77] = 223;
        colourTable[78] = 190;

        return colourTable;
    }();

    enum darkTableExtended = ()
    {
        uint[98] colourTable = ircANSIColourMap[1..$].dup;

        // Tweak colours, brighten some very dark ones
        colourTable[15] = 55;
        colourTable[23] = 20;
        colourTable[24] = 56;
        colourTable[25] = 57;
        colourTable[35] = 21;
        colourTable[33] = 243;
        colourTable[87] = 241;
        colourTable[88] = 242;
        colourTable[89] = 243;
        colourTable[90] = 243;
        colourTable[97] = 240;
        return colourTable;
    }();

    const table = settings.extendedANSIColours ?
        settings.brightTerminal ?
            brightTableExtended[] :
            darkTableExtended []
            :
        settings.brightTerminal ?
            brightTableBasic[] :
            darkTableBasic [];

    immutable colourIndex = (hashOf(word) % table.length);
    return table[colourIndex];
}

///
unittest
{
    import std.conv : to;

    CoreSettings brightSettings;
    CoreSettings darkSettings;
    brightSettings.brightTerminal = true;

    {
        immutable hash = getColourByHash("kameloso", darkSettings);
        assert((hash == 227), hash.to!string);
    }
    {
        immutable hash = getColourByHash("kameloso^", darkSettings);
        assert((hash == 46), hash.to!string);
    }
    {
        immutable hash = getColourByHash("zorael", brightSettings);
        assert((hash == 35), hash.to!string);
    }
    {
        immutable hash = getColourByHash("NO", brightSettings);
        assert((hash == 90), hash.to!string);
    }
}


// colourByHash
/++
    Shorthand function to colour a passed word by the hash of it.

    Params:
        word = String to colour.
        settings = A copy of the program-global [kameloso.pods.CoreSettings|CoreSettings].

    Returns:
        `word`, now in colour based on the hash of its contents.
 +/
auto colourByHash(const string word, const CoreSettings settings) pure @safe nothrow
{
    return word.withANSI(getColourByHash(word, settings));
}

///
unittest
{
    import std.conv : to;

    CoreSettings brightSettings;
    CoreSettings darkSettings;
    brightSettings.brightTerminal = true;

    {
        immutable coloured = "kameloso".colourByHash(darkSettings);
        assert((coloured == "\033[38;5;227mkameloso\033[0m"), coloured);
    }
    {
        immutable coloured = "kameloso".colourByHash(brightSettings);
        assert((coloured == "\033[38;5;222mkameloso\033[0m"), coloured);
    }
    {
        immutable coloured = "zorael".colourByHash(darkSettings);
        assert((coloured == "\033[35mzorael\033[0m"), coloured);
    }
    {
        immutable coloured = "NO".colourByHash(brightSettings);
        assert((coloured == "\033[90mNO\033[0m"), coloured);
    }
}
