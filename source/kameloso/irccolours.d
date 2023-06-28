/++
    Functions related to IRC colouring and formatting; mapping it to ANSI
    terminal such, stripping it, etc.

    IRC colours are not in the standard per se, but there is a de-facto standard
    based on the mIRC coluring syntax of `\3fg,bg...\3`, where '\3' is byte 3,
    `fg` is a foreground colour number (of [IRCColour]) and `bg` is a similar
    background colour number.

    Example:
    ---
    immutable nameInColour = "kameloso".ircColour(IRCColour.red);
    immutable nameInHashedColour = "kameloso".ircColourByHash;
    immutable nameInBold = "kameloso".ircBold;
    ---

    See_Also:
        [kameloso.terminal.colours]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.irccolours;

private:

import kameloso.terminal.colours.defs : TerminalBackground, TerminalForeground,
    TerminalFormat, TerminalReset;
import dialect.common : IRCControlCharacter;
import std.range.primitives : isOutputRange;
import std.typecons : Flag, No, Yes;


public:

@safe:

/++
    Official mIRC colour table.
 +/
enum IRCColour
{
    unset       = -1,  /// Unset
    white       = 0,   /// White
    black       = 1,   /// Black
    blue        = 2,   /// Blue
    green       = 3,   /// Green
    red         = 4,   /// Red
    brown       = 5,   /// Brown
    magenta     = 6,   /// Magenta
    orange      = 7,   /// Orange
    yellow      = 8,   /// Yellow
    lightgreen  = 9,   /// Light green
    cyan        = 10,  /// Cyan
    lightcyan   = 11,  /// Light cyan
    lightblue   = 12,  /// Light blue
    pink        = 13,  /// Pink
    grey        = 14,  /// Grey
    lightgrey   = 15,  /// Light grey
    transparent = 99,  /// "Transparent"
}


// ircANSIColourMap
/++
    Map of IRC colour values above 16 to ANSI terminal colours, as per ircdocs.

    See_Also:
        https://modern.ircdocs.horse/formatting.html#colors-16-98.
 +/
immutable uint[99] ircANSIColourMap =
[
     0 : TerminalForeground.default_,
     1 : TerminalForeground.white,  // replace with .black on bright terminals
     2 : TerminalForeground.red,
     3 : TerminalForeground.green,
     4 : TerminalForeground.yellow,
     5 : TerminalForeground.blue,
     6 : TerminalForeground.magenta,
     7 : TerminalForeground.cyan,
     8 : TerminalForeground.lightgrey,
     9 : TerminalForeground.darkgrey,
    10 : TerminalForeground.lightred,
    11 : TerminalForeground.lightgreen,
    12 : TerminalForeground.lightyellow,
    13 : TerminalForeground.lightblue,
    14 : TerminalForeground.lightmagenta,
    15 : TerminalForeground.lightcyan,
    16 : 52,
    17 : 94,
    18 : 100,
    19 : 58,
    20 : 22,
    21 : 29,
    22 : 23,
    23 : 24,
    24 : 17,
    25 : 54,
    26 : 53,
    27 : 89,
    28 : 88,
    29 : 130,
    30 : 142,
    31 : 64,
    32 : 28,
    33 : 35,
    34 : 30,
    35 : 25,
    36 : 18,
    37 : 91,
    38 : 90,
    39 : 125,
    40 : 124,
    41 : 166,
    42 : 184,
    43 : 106,
    44 : 34,
    45 : 49,
    46 : 37,
    47 : 33,
    48 : 19,
    49 : 129,
    50 : 127,
    51 : 161,
    52 : 196,
    53 : 208,
    54 : 226,
    55 : 154,
    56 : 46,
    57 : 86,
    58 : 51,
    59 : 75,
    60 : 21,
    61 : 171,
    62 : 201,
    63 : 198,
    64 : 203,
    65 : 215,
    66 : 227,
    67 : 191,
    68 : 83,
    69 : 122,
    70 : 87,
    71 : 111,
    72 : 63,
    73 : 177,
    74 : 207,
    75 : 205,
    76 : 217,
    77 : 223,
    78 : 229,
    79 : 193,
    80 : 157,
    81 : 158,
    82 : 159,
    83 : 153,
    84 : 147,
    85 : 183,
    86 : 219,
    87 : 212,
    88 : 16,
    89 : 233,
    90 : 235,
    91 : 237,
    92 : 239,
    93 : 241,
    94 : 244,
    95 : 247,
    96 : 250,
    97 : 254,
    98 : 231,
];


// ircColourInto
/++
    Colour-codes the passed string with mIRC colouring, foreground and background.
    Takes an output range sink and writes to it instead of allocating a new string.

    Params:
        line = Line to tint.
        sink = Output range sink to fill with the function's output.
        fg = Foreground [IRCColour] integer.
        bg = Optional background [IRCColour] integer.
 +/
void ircColourInto(Sink)
    (const string line,
    auto ref Sink sink,
    const int fg,
    const int bg = IRCColour.unset)
if (isOutputRange!(Sink, char[]))
in (line.length, "Tried to apply IRC colours to a string but no string was given")
{
    import lu.conv : toAlphaInto;

    sink.put(cast(char)IRCControlCharacter.colour);
    (cast(int)fg).toAlphaInto!(2, 2)(sink);  // So far the highest colour seems to be 99; two digits

    if (bg != IRCColour.unset)
    {
        sink.put(',');
        (cast(int)bg).toAlphaInto!(2, 2)(sink);
    }

    sink.put(line);
    sink.put(cast(char)IRCControlCharacter.colour);
}

///
unittest
{
    import std.array : Appender;

    alias I = IRCControlCharacter;
    Appender!(char[]) sink;

    "kameloso".ircColourInto(sink, IRCColour.red, IRCColour.white);
    assert((sink.data == I.colour ~ "04,00kameloso" ~ I.colour), sink.data);
    sink.clear();

    "harbl".ircColourInto(sink, IRCColour.green);
    assert((sink.data == I.colour ~ "03harbl" ~ I.colour), sink.data);
}


// ircColour
/++
    Colour-codes the passed string with mIRC colouring, foreground and background.
    Direct overload that leverages the output range version to colour an internal
    [std.array.Appender|Appender], and returns the resulting string.

    Params:
        line = Line to tint.
        fg = Foreground [IRCColour] integer.
        bg = Optional background [IRCColour] integer.

    Returns:
        The passed line, encased within IRC colour tags.
 +/
string ircColour(
    const string line,
    const int fg,
    const int bg = IRCColour.unset) pure
in (line.length, "Tried to apply IRC colours to a string but no string was given")
{
    import std.array : Appender;

    if (!line.length) return string.init;

    Appender!(char[]) sink;

    sink.reserve(line.length + 7);  // Two colour tokens, four colour numbers and a comma
    line.ircColourInto(sink, fg, bg);
    return sink.data;
}

///
unittest
{
    alias I = IRCControlCharacter;

    immutable redwhite = "kameloso".ircColour(IRCColour.red, IRCColour.white);
    assert((redwhite == I.colour ~ "04,00kameloso" ~ I.colour), redwhite);

    immutable green = "harbl".ircColour(IRCColour.green);
    assert((green == I.colour ~ "03harbl" ~ I.colour), green);
}


// ircColour
/++
    Returns a mIRC colour code for the passed foreground and background colour.
    Overload that doesn't take a string to tint, only the [IRCColour]s to
    produce a colour code from.

    Params:
        fg = Foreground [IRCColour].
        bg = Optional background [IRCColour].

    Returns:
        An opening IRC colour token with the passed colours.
 +/
string ircColour(const IRCColour fg, const IRCColour bg = IRCColour.unset) pure
{
    import lu.conv : toAlphaInto;
    import std.array : Appender;

    Appender!(char[]) sink;
    sink.reserve(6);

    sink.put(cast(char)IRCControlCharacter.colour);
    (cast(int)fg).toAlphaInto!(2, 2)(sink);

    if (bg != IRCColour.unset)
    {
        sink.put(',');
        (cast(int)bg).toAlphaInto!(2, 2)(sink);
    }

    return sink.data;
}

///
unittest
{
    alias I = IRCControlCharacter;

    with (IRCColour)
    {
        {
            immutable line = "abcdefg".ircColour(white);
            immutable expected = I.colour ~ "00abcdefg" ~ I.colour;
            assert((line == expected), line);
        }
        {
            immutable line = "abcdefg".ircBold;
            immutable expected = I.bold ~ "abcdefg" ~ I.bold;
            assert((line == expected), line);
        }
        {
            immutable line = ircColour(white) ~ "abcdefg" ~ I.reset;
            immutable expected = I.colour ~ "00abcdefg" ~ I.reset;
            assert((line == expected), line);
        }
        {
            immutable line = "" ~ I.bold ~ I.underlined ~ ircColour(green) ~
                "abcdef" ~ "ghijkl".ircColour(red) ~ I.reset;
            immutable expected = "" ~ I.bold ~ I.underlined ~ I.colour ~ "03abcdef" ~
                I.colour ~ "04ghijkl" ~ I.colour ~ I.reset;
            assert((line == expected), line);

            immutable expressedDifferently = ircBold(ircUnderlined("abcdef".ircColour(green) ~
                "ghijkl".ircColour(red)));
            immutable expectedDifferently = "" ~ I.bold ~ I.underlined ~ I.colour ~
                "03abcdef" ~ I.colour ~ I.colour ~ "04ghijkl" ~ I.colour ~
                I.underlined ~ I.bold;
            assert((expressedDifferently == expectedDifferently), expressedDifferently);
        }
        {
            immutable account = "kameloso";
            immutable authorised = "not authorised";
            immutable line = "Account " ~ ircBold(account) ~ ": " ~ ircUnderlined(authorised) ~ "!";
            immutable expected = "Account " ~ I.bold ~ "kameloso" ~ I.bold ~ ": " ~
                I.underlined ~ "not authorised" ~ I.underlined ~ "!";
            assert((line == expected), line);
        }
    }
}


// ircColourByHash
/++
    Returns the passed string coloured with an IRC colour depending on the hash
    of the string, making for good "random" (uniformly distributed) nick colours
    in IRC messages.

    Params:
        word = String to tint.

    Returns:
        The passed string encased within IRC colour coding.
 +/
string ircColourByHash(const string word) pure
in (word.length, "Tried to apply IRC colours by hash to a string but no string was given")
{
    import lu.conv : toAlphaInto;
    import std.array : Appender;

    if (!word.length) return string.init;

    Appender!(char[]) sink;
    sink.reserve(word.length + 4);  // colour, index, word, colour

    immutable colourIndex = (hashOf(word) % ircANSIColourMap.length);
    immutable colourInteger = ircANSIColourMap[colourIndex];

    sink.put(cast(char)IRCControlCharacter.colour);
    colourInteger.toAlphaInto!(3, 2)(sink);
    sink.put(word);
    sink.put(cast(char)IRCControlCharacter.colour);

    return sink.data;
}

///
unittest
{
    alias I = IRCControlCharacter;

    // Colour based on hash

    {
        immutable actual = "kameloso".ircColourByHash;
        immutable expected = I.colour ~ "24kameloso" ~ I.colour;
        assert((actual == expected), actual);
    }
    {
        immutable actual = "kameloso^".ircColourByHash;
        immutable expected = I.colour ~ "46kameloso^" ~ I.colour;
        assert((actual == expected), actual);
    }
    {
        immutable actual = "kameloso^11".ircColourByHash;
        immutable expected = I.colour ~ "237kameloso^11" ~ I.colour;
        assert((actual == expected), actual);
    }
}


// ircBold
/++
    Returns the passed something wrapped in between IRC bold control characters.

    Params:
        something = Something [std.conv.to]-convertible to enwrap in bold.

    Returns:
        The passed something, as a string, in IRC bold.
 +/
auto ircBold(T)(T something) //pure nothrow
{
    import std.conv : text;

    alias I = IRCControlCharacter;
    return text(cast(char)I.bold, something, cast(char)I.bold);
}

///
unittest
{
    import std.conv : to;
    alias I = IRCControlCharacter;

    {
        immutable line = "kameloso: " ~ ircBold("kameloso");
        immutable expected = "kameloso: " ~ I.bold ~ "kameloso" ~ I.bold;
        assert((line == expected), line);
    }
    {
        immutable number = 1234;
        immutable line = number.ircBold;
        immutable expected = I.bold ~ number.to!string ~ I.bold;
        assert((line == expected), line);
    }
    {
        immutable b = true;
        immutable line = b.ircBold;
        immutable expected = I.bold ~ "true" ~ I.bold;
        assert((line == expected), line);
    }
}


// ircItalics
/++
    Returns the passed something wrapped in between IRC italics control characters.

    Params:
        something = Something [std.conv.to]-convertible to enwrap in italics.

    Returns:
        The passed something, as a string, in IRC italics.
 +/
auto ircItalics(T)(T something) //pure nothrow
{
    import std.conv : text;

    alias I = IRCControlCharacter;
    return text(cast(char)I.italics, something, cast(char)I.italics);
}

///
unittest
{
    import std.conv : to;
    alias I = IRCControlCharacter;

    {
        immutable line = "kameloso: " ~ ircItalics("kameloso");
        immutable expected = "kameloso: " ~ I.italics ~ "kameloso" ~ I.italics;
        assert((line == expected), line);
    }
    {
        immutable number = 1234;
        immutable line = number.ircItalics;
        immutable expected = I.italics ~ number.to!string ~ I.italics;
        assert((line == expected), line);
    }
    {
        immutable b = true;
        immutable line = b.ircItalics;
        immutable expected = I.italics ~ "true" ~ I.italics;
        assert((line == expected), line);
    }
}


// ircUnderlined
/++
    Returns the passed something wrapped in between IRC underlined control characters.

    Params:
        something = Something [std.conv.to]-convertible to enwrap in underlined.

    Returns:
        The passed something, as a string, in IRC underlined.
 +/
auto ircUnderlined(T)(T something) //pure nothrow
{
    import std.conv : text;

    alias I = IRCControlCharacter;
    return text(cast(char)I.underlined, something, cast(char)I.underlined);
}

///
unittest
{
    import std.conv : to;
    alias I = IRCControlCharacter;

    {
        immutable line = "kameloso: " ~ ircUnderlined("kameloso");
        immutable expected = "kameloso: " ~ I.underlined ~ "kameloso" ~ I.underlined;
        assert((line == expected), line);
    }
    {
        immutable number = 1234;
        immutable line = number.ircUnderlined;
        immutable expected = I.underlined ~ number.to!string ~ I.underlined;
        assert((line == expected), line);
    }
    {
        immutable b = true;
        immutable line = b.ircUnderlined;
        immutable expected = I.underlined ~ "true" ~ I.underlined;
        assert((line == expected), line);
    }
}


// ircReset
/++
    Returns an IRC formatting reset token.

    Returns:
        An IRC colour/formatting reset token.
 +/
auto ircReset() @nogc pure nothrow
{
    return cast(char)IRCControlCharacter.reset;
}


// mapEffects
/++
    Maps mIRC effect tokens (colour, bold, italics, underlined) to terminal ones.

    Example:
    ---
    string mIRCEffectString = "...";
    string TerminalFormatString = mapEffects(mIRCEffectString);
    ---

    Params:
        origLine = String line to map effects of.
        fgBase = Optional foreground base code to reset to after end colour tags.
        bgBase = Optional background base code to reset to after end colour tags.

    Returns:
        A new string based on `origLine` with mIRC tokens mapped to terminal ones.
 +/
version(Colours)
auto mapEffects(
    const string origLine,
    const TerminalForeground fgBase = TerminalForeground.default_,
    const TerminalBackground bgBase = TerminalBackground.default_) pure nothrow
{
    import lu.string : contains;

    alias I = IRCControlCharacter;
    alias TF = TerminalFormat;

    if (!origLine.length) return string.init;

    string line = origLine;  // mutable

    if (line.contains(I.colour))
    {
        // Colour is mIRC 3
        line = mapColours(line, fgBase, bgBase);
    }

    if (line.contains(I.bold))
    {
        // Bold is terminal 1, mIRC 2
        line = mapEffectsImpl!(No.strip, I.bold, TF.bold)(line);
    }

    if (line.contains(I.italics))
    {
        // Italics is terminal 3 (not really), mIRC 29
        line = mapEffectsImpl!(No.strip, I.italics, TF.italics)(line);
    }

    if (line.contains(I.underlined))
    {
        // Underlined is terminal 4, mIRC 31
        line = mapEffectsImpl!(No.strip, I.underlined, TF.underlined)(line);
    }

    return line;
}

///
version(Colours)
unittest
{
    import kameloso.terminal : TerminalToken;
    import lu.conv : toAlpha;

    alias I = IRCControlCharacter;

    enum bBold = TerminalToken.format ~ "[" ~ TerminalFormat.bold.toAlpha ~ "m";
    enum bReset = TerminalToken.format ~ "[22m";
    //enum bResetAll = TerminalToken.format ~ "[0m";

    immutable line1 = "ABC"~I.bold~"DEF"~I.bold~"GHI"~I.bold~"JKL"~I.bold~"MNO";
    immutable line2 = "ABC"~bBold~"DEF"~bReset~"GHI"~bBold~"JKL"~bReset~"MNO";//~bResetAll;
    immutable mapped = mapEffects(line1);

    assert((mapped == line2), mapped);
}


// stripEffects
/++
    Removes all form of mIRC formatting (colours, bold, italics, underlined)
    from a string.

    Params:
        line = String to strip effects from.

    Returns:
        A string devoid of effects.
 +/
auto stripEffects(const string line) pure nothrow
{
    if (!line.length) return line;

    alias I = IRCControlCharacter;

    return line
        .stripColours
        .mapEffectsImpl!(Yes.strip, I.bold, TerminalFormat.unset)
        .mapEffectsImpl!(Yes.strip, I.italics, TerminalFormat.unset)
        .mapEffectsImpl!(Yes.strip, I.underlined, TerminalFormat.unset);
}

///
unittest
{
    alias I = IRCControlCharacter;

    enum boldCode = "" ~ I.bold;
    enum italicsCode = "" ~ I.italics;

    {
        immutable withTags = "This is " ~ boldCode ~ "riddled" ~ boldCode ~ " with " ~
            italicsCode ~ "tags" ~ italicsCode;
        immutable without = stripEffects(withTags);
        assert((without == "This is riddled with tags"), without);
    }
    {
        immutable withTags = "This line has no tags.";
        immutable without = stripEffects(withTags);
        assert((without == withTags), without);
    }
    {
        string withTags;
        immutable without = stripEffects(withTags);
        assert(!without.length, without);
    }
}


// mapColours
/++
    Maps mIRC effect colour tokens to terminal ones.

    Merely calls [mapColoursImpl] with `No.strip`.

    Params:
        line = String line with IRC colours to translate.
        fgFallback = Foreground code to reset to after colour-default tokens.
        bgFallback = Background code to reset to after colour-default tokens.

    Returns:
        The passed `line`, now with terminal colouring.
 +/
version(Colours)
auto mapColours(
    const string line,
    const TerminalForeground fgFallback,
    const TerminalBackground bgFallback) pure nothrow
{
    if (!line.length) return line;
    return mapColoursImpl!(No.strip)(line, fgFallback, bgFallback);
}


// mapColoursImpl
/++
    Maps mIRC effect colour tokens to terminal ones, or strip them entirely.
    Now with less regex.

    Pass `Yes.strip` as `strip` to map colours to nothing, removing colouring.

    This function requires version `Colours` to map colours, but doesn't if
    just to strip.

    Params:
        strip = Whether or not to strip colours or to map them.
        line = String line with IRC colours to translate.
        fgFallback = Foreground code to reset to after colour-default tokens.
        bgFallback = Background code to reset to after colour-default tokens.

    Returns:
        The passed `line`, now with terminal colouring, or completely without.
 +/
private string mapColoursImpl(Flag!"strip" strip = No.strip)
    (const string line,
    const TerminalForeground fgFallback,
    const TerminalBackground bgFallback) pure nothrow
{
    import lu.conv : toAlphaInto;
    import std.array : Appender;
    import std.string : indexOf;

    version(Colours) {}
    else
    {
        static if (!strip)
        {
            static assert(0, "Tried to `mapColoursImpl!(No.strip)` outside of version `Colours`");
        }
    }

    static struct Segment
    {
        string pre;
        int fg;
        int bg;
        bool hasBackground;
        bool isReset;
    }

    string slice = line;  // mutable

    ptrdiff_t pos = slice.indexOf(IRCControlCharacter.colour);

    if (pos == -1) return line;  // Return line as is, don't allocate a new one

    Segment[] segments;
    segments.reserve(8);  // Guesstimate

    while (pos != -1)
    {
        immutable segmentIndex = segments.length;  // snapshot
        segments ~= Segment.init;
        Segment* segment = &segments[segmentIndex];

        segment.pre = slice[0..pos];
        if (slice.length == pos) break;
        slice = slice[pos+1..$];

        if (!slice.length)
        {
            segment.isReset = true;
            break;
        }

        int c = slice[0] - '0';

        if ((c >= 0) && (c <= 9))
        {
            int fg1;
            int fg2;
            bool hasFg2;

            fg1 = c;
            if (slice.length < 2) break;
            slice = slice[1..$];

            c = slice[0] - '0';

            if ((c >= 0) && (c <= 9))
            {
                fg2 = c;
                hasFg2 = true;
                if (slice.length < 2) break;
                slice = slice[1..$];
            }

            int fg = hasFg2 ? (10*fg1 + fg2) : fg1;

            if (fg > 15)
            {
                fg %= 16;
            }

            segment.fg = fg;

            if (slice[0] == ',')
            {
                if (!slice.length) break;
                slice = slice[1..$];

                c = slice[0] - '0';

                if ((c >= 0) && (c <= 9))
                {
                    segment.hasBackground = true;

                    int bg1;
                    int bg2;
                    bool hasBg2;

                    bg1 = c;
                    if (slice.length < 2) break;
                    slice = slice[1..$];

                    c = slice[0] - '0';

                    if ((c >= 0) && (c <= 9))
                    {
                        bg2 = c;
                        hasBg2 = true;
                        if (!slice.length) break;
                        slice = slice[1..$];
                    }

                    uint bg = hasBg2 ? (10*bg1 + bg2) : bg1;

                    if (bg > 15)
                    {
                        bg %= 16;
                    }

                    segment.bg = bg;
                }
            }
        }
        else
        {
            segment.isReset = true;
        }

        pos = slice.indexOf(IRCControlCharacter.colour);
    }

    immutable tail = slice;

    Appender!(char[]) sink;
    sink.reserve(line.length + segments.length * 8);

    static if (strip)
    {
        foreach (segment; segments)
        {
            sink.put(segment.pre);
        }
    }
    else
    {
        version(Colours)
        {
            alias F = TerminalForeground;
            alias B = TerminalBackground;

            static immutable TerminalForeground[16] weechatForegroundMap =
            [
                 0 : F.white,
                 1 : F.darkgrey,
                 2 : F.blue,
                 3 : F.green,
                 4 : F.lightred,
                 5 : F.red,
                 6 : F.magenta,
                 7 : F.yellow,
                 8 : F.lightyellow,
                 9 : F.lightgreen,
                10 : F.cyan,
                11 : F.lightcyan,
                12 : F.lightblue,
                13 : F.lightmagenta,
                14 : F.darkgrey,
                15 : F.lightgrey,
            ];

            static immutable TerminalBackground[16] weechatBackgroundMap =
            [
                 0 : B.white,
                 1 : B.black,
                 2 : B.blue,
                 3 : B.green,
                 4 : B.red,
                 5 : B.red,
                 6 : B.magenta,
                 7 : B.yellow,
                 8 : B.yellow,
                 9 : B.green,
                10 : B.cyan,
                11 : B.cyan,
                12 : B.blue,
                13 : B.magenta,
                14 : B.black,
                15 : B.lightgrey,
            ];

            bool open;

            foreach (segment; segments)
            {
                open = true;
                sink.put(segment.pre);
                sink.put("\033[");

                if (segment.isReset)
                {
                    fgFallback.toAlphaInto(sink);
                    sink.put(';');
                    bgFallback.toAlphaInto(sink);
                    sink.put('m');
                    open = false;
                    continue;
                }

                (cast(uint)weechatForegroundMap[segment.fg]).toAlphaInto(sink);

                if (segment.hasBackground)
                {
                    sink.put(';');
                    (cast(uint)weechatBackgroundMap[segment.bg]).toAlphaInto(sink);
                }

                sink.put("m");
            }
        }
        else
        {
            //static assert(0);
        }
    }

    sink.put(tail);

    version(Colours)
    {
        static if (!strip)
        {
            if (open)
            {
                if ((fgFallback == 39) && (bgFallback == 49))
                {
                    // Shortcut
                    sink.put("\033[39;49m");
                }
                else
                {
                    sink.put("\033[");
                    fgFallback.toAlphaInto(sink);
                    sink.put(';');
                    bgFallback.toAlphaInto(sink);
                    sink.put('m');
                }
            }
        }
    }

    return sink.data;
}

///
version(Colours)
unittest
{
    alias I = IRCControlCharacter;
    alias TF = TerminalForeground;
    alias TB = TerminalBackground;

    {
        immutable line = "This is " ~ I.colour ~ "4all red!" ~ I.colour ~ " while this is not.";
        immutable mapped = mapColours(line, TF.default_, TB.default_);
        assert((mapped == "This is \033[91mall red!\033[39;49m while this is not."), mapped);
    }
    {
        immutable line = "This time there's" ~ I.colour ~ "6 no ending token, only magenta.";
        immutable mapped = mapColours(line, TF.default_, TB.default_);
        assert((mapped == "This time there's\033[35m no ending token, only magenta.\033[39;49m"), mapped);
    }
    {
        immutable line = I.colour ~ "1,0You" ~ I.colour ~ "0,4Tube" ~ I.colour ~ " asdf";
        immutable mapped = mapColours(line, TF.default_, TB.default_);
        assert((mapped == "\033[90;107mYou\033[97;41mTube\033[39;49m asdf"), mapped);
    }
    {
        immutable line = I.colour ~ "17,0You" ~ I.colour ~ "0,21Tube" ~ I.colour ~ " asdf";
        immutable mapped = mapColours(line, TF.default_, TB.default_);
        assert((mapped == "\033[90;107mYou\033[97;41mTube\033[39;49m asdf"), mapped);
    }
    {
        immutable line = I.colour ~ "17,0You" ~ I.colour ~ "0,2" ~ I.colour;
        immutable mapped = mapColours(line, TF.default_, TB.default_);
        assert((mapped == "\033[90;107mYou\033[97;44m\033[39;49m"), mapped);
    }
    {
        immutable line = I.colour ~ "";
        immutable mapped = mapColours(line, TF.default_, TB.default_);
        assert((mapped == "\033[39;49m"), mapped);
    }
}


// stripColours
/++
    Removes IRC colouring from a passed string.

    Merely calls [mapColours] with a `Yes.strip` template parameter.

    Params:
        line = String to strip of IRC colour tags.

    Returns:
        The passed `line`, now stripped of IRC colours.
 +/
auto stripColours(const string line) pure nothrow
{
    if (!line.length) return line;
    return mapColoursImpl!(Yes.strip)(line, TerminalForeground.default_, TerminalBackground.default_);
}

///
unittest
{
    alias I = IRCControlCharacter;

    {
        immutable line = "This is " ~ I.colour ~ "4all red!" ~ I.colour ~ " while this is not.";
        immutable stripped = line.stripColours();
        assert((stripped == "This is all red! while this is not."), stripped);
    }
    {
        immutable line = "This time there's" ~ I.colour ~ "6 no ending token, only magenta.";
        immutable stripped = line.stripColours();
        assert((stripped == "This time there's no ending token, only magenta."), stripped);
    }
    {
        immutable line = "This time there's" ~ I.colour ~ "6 no ending " ~ I.colour ~
            "6token, only " ~ I.colour ~ "magenta.";
        immutable stripped = line.stripColours();
        assert((stripped == "This time there's no ending token, only magenta."), stripped);
    }
}


// mapEffectsImpl
/++
    Replaces mIRC tokens with terminal effect codes, in an alternating fashion
    so as to support repeated effects toggling behaviour. Now with less regex.

    It seems to be the case that a token for bold text will trigger bold text up
    until the next bold token. If we only naïvely replace all mIRC tokens for
    bold text then, we'll get lines that start off bold and continue as such
    until the very end.

    Instead we iterate all occcurences of the passed `mircToken`, toggling the
    effect on and off.

    Params:
        mircToken = mIRC token for a particular text effect.
        TerminalFormatCode = Terminal equivalent of the mircToken effect.
        line = The mIRC-formatted string to translate.

    Returns:
        The passed `line`, now with terminal formatting.
 +/
private string mapEffectsImpl(Flag!"strip" strip, IRCControlCharacter mircToken,
    TerminalFormat terminalFormatCode)
    (const string line) pure
{
    import lu.conv : toAlpha;
    import std.array : Appender;
    import std.string : indexOf;

    version(Colours) {}
    else
    {
        static if (!strip)
        {
            static assert(0, "Tried to call `mapEffectsImpl!(No.strip)` outside of version `Colours`");
        }
    }

    string slice = line;  // mutable
    ptrdiff_t pos = slice.indexOf(mircToken);
    if (pos == -1) return line;  // As is

    Appender!(char[]) sink;

    static if (!strip)
    {
        import kameloso.terminal : TerminalToken;
        import kameloso.terminal.colours : applyANSI;

        enum terminalToken = TerminalToken.format ~ "[" ~ toAlpha(terminalFormatCode) ~ "m";
        sink.reserve(cast(size_t)(line.length * 1.5));
        bool open;
    }
    else
    {
        sink.reserve(line.length);
    }

    while (pos != -1)
    {
        sink.put(slice[0..pos]);

        if (slice.length == pos)
        {
            // Slice away the end so it isn't added as the tail afterwards
            slice = slice[pos..$];
            break;
        }

        slice = slice[pos+1..$];

        static if (!strip)
        {
            if (!open)
            {
                sink.put(terminalToken);
                open = true;
            }
            else
            {
                static if ((terminalFormatCode == 1) || (terminalFormatCode == 2))
                {
                    // Both 1 and 2 seem to be reset by 22?
                    enum tokenstring = TerminalToken.format ~ "[22m";
                    sink.put(tokenstring);
                }
                else static if ((terminalFormatCode >= 3) && (terminalFormatCode <= 5))
                {
                    enum tokenstring = TerminalToken.format ~ "[2" ~ terminalFormatCode.toAlpha ~ "m";
                    sink.put(tokenstring);
                }
                else
                {
                    //logger.warning("Unknown terminal effect code: ", TerminalFormatCode);
                    sink.applyANSI(TerminalReset.all);
                }

                open = false;
            }
        }

        pos = slice.indexOf(mircToken);
    }

    alias tail = slice;
    sink.put(tail);

    static if (!strip)
    {
        if (open) sink.applyANSI(TerminalReset.all);
    }

    return sink.data;
}

///
version(Colours)
unittest
{
    import kameloso.terminal : TerminalToken;
    import lu.conv : toAlpha;

    alias I = IRCControlCharacter;
    alias TF = TerminalFormat;

    enum bBold = TerminalToken.format ~ "[" ~ TF.bold.toAlpha ~ "m";
    enum bReset = TerminalToken.format ~ "[22m";

    {
        enum line = "derp " ~ I.bold ~ "herp derp" ~ I.bold ~ "der dper";
        immutable mapped = mapEffectsImpl!(No.strip, I.bold, TF.bold)(line);
        assert((mapped == "derp " ~ bBold ~ "herp derp" ~ bReset ~ "der dper"), mapped);
    }
}


// expandIRCTags
/++
    Slightly more complicated, but essentially string-replaces `<tags>` in an
    outgoing IRC string with correlating formatting using
    [dialect.common.IRCControlCharacter|IRCControlCharacter]s in their syntax.
    Overload that takes an explicit `strip` [std.typecons.Flag|Flag].

    Params:
        line = String line to expand IRC tags of.
        strip = Whether to expand tags or strip them from the input line.

    Returns:
        The passed `line` but with tags expanded to formatting and colouring.
 +/
T expandIRCTags(T)(const T line, const Flag!"strip" strip) @system
{
    import std.utf : UTFException;

    try
    {
        return expandIRCTagsImpl(line, strip);
    }
    catch (UTFException _)
    {
        import std.encoding : sanitize;
        return expandIRCTagsImpl(sanitize(line), strip);
    }
}

///
@system unittest
{
    import std.typecons : Flag, No, Yes;

    // See unittests of other overloads for more No.strip tests

    {
        immutable line = "hello<b>hello<b>hello";
        immutable expanded = line.expandIRCTags(Yes.strip);
        immutable expected = "hellohellohello";
        assert((expanded == expected), expanded);
    }
    {
        immutable line = "hello<99,99<b>hiho</>";
        immutable expanded = line.expandIRCTags(Yes.strip);
        immutable expected = "hello<99,99hiho";
        assert((expanded == expected), expanded);
    }
    {
        immutable line = "hello<1>hellohello";
        immutable expanded = line.expandIRCTags(Yes.strip);
        immutable expected = "hellohellohello";
        assert((expanded == expected), expanded);
    }
    {
        immutable line = `hello\<h>hello<h>hello<h>hello`;
        immutable expanded = line.expandIRCTags(Yes.strip);
        immutable expected = "hello<h>hellohellohello";
        assert((expanded == expected), expanded);
    }
}


// expandIRCTags
/++
    Slightly more complicated, but essentially string-replaces `<tags>` in an
    outgoing IRC string with correlating formatting using
    [dialect.common.IRCControlCharacter|IRCControlCharacter]s in their syntax.
    Overload that does not take a `strip` [std.typecons.Flag|Flag].

    `<tags>` are the lowercase first letter of all
    [dialect.common.IRCControlCharacter|IRCControlCharacter] members;
    `<b>` for [dialect.common.IRCControlCharacter.bold|IRCControlCharacter.bold],
    `<c>` for [dialect.common.IRCControlCharacter.colour|IRCControlCharacter.colour],
    `<i>` for [dialect.common.IRCControlCharacter.italics|IRCControlCharacter.italics],
    `<u>` for [dialect.common.IRCControlCharacter.underlined|IRCControlCharacter.underlined],
    and the magic `</>` for [dialect.common.IRCControlCharacter.reset|IRCControlCharacter.reset],

    An additional `<h>` tag is also introduced, which invokes [ircColourByHash]
    on the content between two of them.

    If the line is not valid UTF, it is sanitised and the expansion retried.

    Example:
    ---
    // Old
    enum pattern = "Quote %s #%s saved.";
    immutable message = plugin.state.settings.colouredOutgoing ?
        pattern.format(id.ircColourByHash, index.ircBold) :
        pattern.format(id, index);
    privmsg(plugin.state, event.channel, event.sender.nickname. message);

    // New
    enum newPattern = "Quote <h>%s<h> #<b>%d<b> saved.";
    immutable newMessage = newPattern.format(id, index);
    privmsg(plugin.state, event.channel, event.sender.nickname, newMessage);
    ---

    Params:
        line = String line to expand IRC tags of.

    Returns:
        The passed `line` but with tags expanded to formatting and colouring.
 +/
T expandIRCTags(T)(const T line) @system
{
    static import kameloso.common;

    debug
    {
        if (kameloso.common.settings is null)
        {
            import std.stdio : stdout, writefln;

            // We're likely threading and forgot to initialise global settings
            kameloso.common.settings = new typeof(*kameloso.common.settings);

            writefln("-- Warning: attempted to expand IRC tags by relying on " ~
                "global `kameloso.common.settings`, and it was null");
            stdout.flush();
        }
    }

    immutable strip = cast(Flag!"strip")!kameloso.common.settings.colouredOutgoing;
    return expandIRCTags(line, strip);
}

///
@system unittest
{
    import dialect.common : I = IRCControlCharacter;
    import std.conv : text, to;
    import std.format : format;

    {
        immutable line = "hello";
        immutable expanded = line.expandIRCTags;
        assert((expanded is line), expanded);
    }
    {
        immutable line = string.init;
        immutable expanded = line.expandIRCTags;
        assert(expanded is null);
    }
    {
        immutable line = "hello<b>hello<b>hello";
        immutable expanded = line.expandIRCTags;
        immutable expected = "hello" ~ I.bold ~ "hello" ~ I.bold ~ "hello";
        assert((expanded == expected), expanded);
    }
    {
        immutable line = "hello<1>hello<c>hello";
        immutable expanded = line.expandIRCTags;
        immutable expected = "hello" ~ I.colour ~ "01hello" ~ I.colour ~ "hello";
        assert((expanded == expected), expanded);
    }
    {
        immutable line = "hello<3,4>hello<c>hello";
        immutable expanded = line.expandIRCTags;
        immutable expected = "hello" ~ I.colour ~ "03,04hello" ~ I.colour ~ "hello";
        assert((expanded == expected), expanded);
    }
    {
        immutable line = "hello<99,99<b>hiho</>";
        immutable expanded = line.expandIRCTags;
        immutable expected = "hello<99,99" ~ I.bold ~ "hiho" ~ I.reset;
        assert((expanded == expected), expanded);
    }
    {
        immutable line = "hello<99,99><b>hiho</>";
        immutable expanded = line.expandIRCTags;
        immutable expected = "hello" ~ I.colour ~ "99,99" ~ I.bold ~ "hiho" ~ I.reset;
        assert((expanded == expected), expanded);
    }
    {
        immutable line = "hello<99,999><b>hiho</>hey";
        immutable expanded = line.expandIRCTags;
        immutable expected = "hello<99,999>" ~ I.bold ~ "hiho" ~ I.reset ~ "hey";
        assert((expanded == expected), expanded);
    }
    {
        immutable line = `hello\<1,2>hiho`;
        immutable expanded = line.expandIRCTags;
        immutable expected = `hello<1,2>hiho`;
        assert((expanded == expected), expanded);
    }
    {
        immutable line = `hello\\<1,2>hiho`;
        immutable expanded = line.expandIRCTags;
        immutable expected = `hello\` ~ I.colour ~ "01,02hiho";
        assert((expanded == expected), expanded);
    }
    {
        immutable line = "hello<";
        immutable expanded = line.expandIRCTags;
        assert((expanded is line), expanded);
    }
    {
        immutable line = "hello<<<<";
        immutable expanded = line.expandIRCTags;
        assert((expanded is line), expanded);
    }
    {
        immutable line = "hello<x>hello<z>";
        immutable expanded = line.expandIRCTags;
        immutable expected = "hellohello";
        assert((expanded == expected), expanded);
    }
    {
        immutable line = "hello<h>kameloso<h>hello";
        immutable expanded = line.expandIRCTags;
        immutable expected = "hello" ~ I.colour ~ "24kameloso" ~ I.colour ~ "hello";
        assert((expanded == expected), expanded);
    }
    {
        immutable line = "hello<h>kameloso";
        immutable expanded = line.expandIRCTags;
        immutable expected = "hellokameloso";
        assert((expanded == expected), expanded);
    }
    {
        immutable line = "hello<3,4>hello<c>hello"d;
        immutable expanded = line.expandIRCTags;
        immutable expected = "hello"d ~ I.colour ~ "03,04hello"d ~ I.colour ~ "hello"d;
        assert((expanded == expected), expanded.to!string);
    }
    /*{
        immutable line = "hello<h>kameloso<h>hello"w;
        immutable expanded = line.expandIRCTags;
        immutable expected = "hello"w ~ I.colour ~ "01kameloso"w ~ I.colour ~ "hello"w;
        assert((expanded == expected), expanded.to!string);
    }*/
    {
        immutable line = "Quote <h>zorael<h> #<b>5<b> saved.";
        immutable expanded = line.expandIRCTags;
        enum pattern = "Quote %s #%s saved.";
        immutable expected = pattern.format(ircColourByHash("zorael"), "5".ircBold);
        assert((expanded == expected), expanded);
    }
    {
        immutable line = "Stopwatch stopped after <b>5 seconds<b>.";
        immutable expanded = line.expandIRCTags;
        enum pattern = "Stopwatch stopped after %s.";
        immutable expected = pattern.format("5 seconds".ircBold);
        assert((expanded == expected), expanded);
    }
    {
        immutable line = "<h>hirrsteff<h> was already <b>whitelist<b> in #garderoben.";
        immutable expanded = line.expandIRCTags;
        enum pattern = "%s was already %s in #garderoben.";
        immutable expected = pattern.format(ircColourByHash("hirrsteff"), "whitelist".ircBold);
        assert((expanded == expected), expanded);
    }
    {
        immutable line = `hello\<h>hello<h>hello<h>hello`;
        immutable expanded = line.expandIRCTags;
        immutable expected = text("hello<h>hello", ircColourByHash("hello"), "hello");
        assert((expanded == expected), expanded);
    }
}


// stripIRCTags
/++
    Removes `<tags>` in an outgoing IRC string where the tags correlate to formatting
    using [dialect.common.IRCControlCharacter|IRCControlCharacter]s.

    Params:
        line = String line to remove IRC tags from.

    Returns:
        The passed `line` but with tags removed.
 +/
T stripIRCTags(T)(const T line) @system
{
    return expandIRCTags(line, Yes.strip);
}

///
@system unittest
{
    import std.typecons : Flag, No, Yes;

    {
        immutable line = "hello<b>hello<b>hello";
        immutable expanded = line.stripIRCTags();
        immutable expected = "hellohellohello";
        assert((expanded == expected), expanded);
    }
    {
        immutable line = "hello<99,99<b>hiho</>";
        immutable expanded = line.stripIRCTags();
        immutable expected = "hello<99,99hiho";
        assert((expanded == expected), expanded);
    }
    {
        immutable line = "hello<1>hellohello";
        immutable expanded = line.stripIRCTags();
        immutable expected = "hellohellohello";
        assert((expanded == expected), expanded);
    }
    {
        immutable line = `hello\<h>hello<h>hello<h>hello`;
        immutable expanded = line.stripIRCTags();
        immutable expected = "hello<h>hellohellohello";
        assert((expanded == expected), expanded);
    }
}


// expandIRCTagsImpl
/++
    Implementation function for [expandIRCTags]. Kept separate so that
    [std.utf.UTFException|UTFException] can be neatly caught.

    Params:
        line = String line to expand IRC tags of.
        strip = Whether to expand tags or strip them from the input line.

    Returns:
        The passed `line` but with tags expanded to formatting and colouring.

    Throws:
        [std.string.indexOf] (used internally) throws [std.utf.UTFException|UTFException]
        if the starting index of a lookup doesn't represent a well-formed codepoint.
 +/
private T expandIRCTagsImpl(T)(const T line, const Flag!"strip" strip = No.strip) pure
{
    import dialect.common : IRCControlCharacter;
    import lu.string : contains;
    import std.array : Appender;
    import std.range : ElementEncodingType;
    import std.string : representation;
    import std.traits : Unqual;

    alias E = Unqual!(ElementEncodingType!T);

    if (!line.length || !line.contains('<')) return line;

    Appender!(E[]) sink;
    bool dirty;
    bool escaping;

    immutable asBytes = line.representation;
    immutable toReserve = (asBytes.length + 16);

    byteloop:
    for (size_t i; i<asBytes.length; ++i)
    {
        immutable c = asBytes[i];

        switch (c)
        {
        case '\\':
            if (escaping)
            {
                // Always dirty
                sink.put('\\');
            }
            else
            {
                if (!dirty)
                {
                    sink.reserve(toReserve);
                    sink.put(asBytes[0..i]);
                    dirty = true;
                }
            }

            escaping = !escaping;
            break;

        case '<':
            if (escaping)
            {
                // Always dirty
                sink.put('<');
                escaping = false;
            }
            else
            {
                import std.string : indexOf;

                immutable ptrdiff_t closingBracketPos = (cast(T)asBytes[i..$]).indexOf('>');

                if ((closingBracketPos == -1) || (closingBracketPos > 6))
                {
                    if (dirty)
                    {
                        sink.put(c);
                    }
                }
                else
                {
                    // Valid; dirties now if not already dirty

                    if (asBytes.length < i+2)
                    {
                        // Too close to the end to have a meaningful tag
                        // Break and return

                        if (dirty)
                        {
                            // Add rest first
                            sink.put(asBytes[i..$]);
                        }

                        break byteloop;
                    }

                    if (!dirty)
                    {
                        sink.reserve(toReserve);
                        sink.put(asBytes[0..i]);
                        dirty = true;
                    }

                    immutable slice = asBytes[i+1..i+closingBracketPos];  // mutable

                    if ((slice[0] >= '0') && (slice[0] <= '9'))
                    {
                        if (!strip)
                        {
                            static auto getColourChars(S)(S slice)
                            {
                                static struct Result
                                {
                                    immutable S fg;
                                    immutable S bg;
                                }

                                immutable commaPos = (cast(T)slice).indexOf(',');

                                if (commaPos != -1)
                                {
                                    return Result(slice[0..commaPos], slice[commaPos+1..$]);
                                }
                                else
                                {
                                    return Result(slice);
                                }
                            }

                            immutable colours = getColourChars(slice);

                            sink.put(cast(char)IRCControlCharacter.colour);
                            if (colours.fg.length == 1) sink.put('0');
                            sink.put(colours.fg);

                            if (colours.bg.length)
                            {
                                sink.put(',');
                                if (colours.bg.length == 1) sink.put('0');
                                sink.put(colours.bg);
                            }
                        }
                    }
                    else
                    {
                        if (slice.length != 1) break;

                        switch (slice[0])
                        {
                        case 'b':
                            if (!strip) sink.put(cast(char)IRCControlCharacter.bold);
                            break;

                        case 'c':
                            if (!strip) sink.put(cast(char)IRCControlCharacter.colour);
                            break;

                        case 'i':
                            if (!strip) sink.put(cast(char)IRCControlCharacter.italics);
                            break;

                        case 'u':
                            if (!strip) sink.put(cast(char)IRCControlCharacter.underlined);
                            break;

                        case '/':
                            if (!strip) sink.put(cast(char)IRCControlCharacter.reset);
                            break;

                        case 'h':
                            i += 3;  // advance past "<h>".length
                            immutable closingHashMarkPos = (cast(T)asBytes[i..$]).indexOf("<h>");

                            if (closingHashMarkPos == -1)
                            {
                                // Revert advance
                                i -= 3;
                                goto default;
                            }
                            else
                            {
                                if (!strip)
                                {
                                    sink.put(ircColourByHash(cast(string)asBytes[i..i+closingHashMarkPos]));
                                }
                                else
                                {
                                    sink.put(cast(string)asBytes[i..i+closingHashMarkPos]);
                                }

                                // Don't advance the full "<h>".length 3
                                // because the for-loop ++i will advance one ahead
                                i += (closingHashMarkPos+2);
                                continue;  // Not break
                            }

                        default:
                            // Invalid control character, just ignore
                            break;
                        }
                    }

                    i += closingBracketPos;
                }
            }
            break;

        default:
            if (dirty)
            {
                sink.put(c);
            }
            break;
        }
    }

    return dirty ? sink.data.idup : line;
}
