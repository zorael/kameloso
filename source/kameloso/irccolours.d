/++
 +  Functions related to IRC colouring and formatting, mapping it to ANSI
 +  terminal such, stripping it, etc.
 +
 +  IRC colours are not in the standard as such, but there is a de-facto standard
 +  based on the mIRC coluring syntax of `\3fg,bg...\3`, where '\3' is byte 3,
 +  `fg` is a foreground colour number (of `IRCColour`) and `bg` is a similar
 +  background colour number.
 +
 +  Example:
 +  ---
 +  immutable nameInColour = "kameloso".ircColour(IRCColour.red);
 +  immutable nameInHashedColour = "kameloso".ircColouByHash;
 +  immutable nameInBold = "kameloso".ircBold;
 +  ---
 +/
module kameloso.irccolours;

private:

import dialect.common : IRCControlCharacter;
import std.range.primitives : isOutputRange;
import std.typecons : Flag, No, Yes;

version(Colours)
{
    import kameloso.terminal : TerminalBackground, TerminalForeground;
}

public:

@safe:

/++
 +  Official mIRC colour table.
 +/
enum IRCColour
{
    unset    = -1,  /// Unset
    white    = 0,   /// White
    black    = 1,   /// Black
    blue     = 2,   /// Blue
    green    = 3,   /// Green
    red      = 4,   /// Red
    brown    = 5,   /// Brown
    purple   = 6,   /// Purple
    orange   = 7,   /// Orange
    yellow   = 8,   /// Yellow
    lightgreen = 9, /// Light green
    cyan      = 10, /// Cyan
    lightcyan = 11, /// Light cyan
    lightblue = 12, /// Light blue
    pink      = 13, /// Pink
    grey      = 14, /// Grey
    lightgrey = 15, /// Light grey
    transparent = 99, /// "Transparent"
}


// ircColourInto
/++
 +  Colour-codes the passed string with mIRC colouring, foreground and background.
 +  Takes an output range sink and writes to it instead of allocating a new string.
 +
 +  Params:
 +      line = Line to tint.
 +      sink = Output range sink to fill with the function's output.
 +      fg = Foreground `IRCColour`.
 +      bg = Optional background `IRCColour`.
 +/
void ircColourInto(Sink)(const string line, auto ref Sink sink, const IRCColour fg,
    const IRCColour bg = IRCColour.unset)
if (isOutputRange!(Sink, char[]))
in (line.length, "Tried to apply IRC colours to a string but no string was given")
{
    import lu.conv : toAlphaInto;
    import std.conv : to;
    import std.format : formattedWrite;

    assert((fg != IRCColour.unset), "Tried to IRC colour with an unset colour");

    sink.put(cast(char)IRCControlCharacter.colour);

    //sink.formattedWrite("%02d", fg);
    (cast(int)fg).toAlphaInto!(2, 2)(sink);  // So far the highest colour seems to be 99; two digits

    if (bg != IRCColour.unset)
    {
        //sink.formattedWrite(",%02d", bg);
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
 +  Colour-codes the passed string with mIRC colouring, foreground and background.
 +  Direct overload that leverages the output range version to colour an internal
 +  `std.array.Appender`, and returns the resulting string.
 +
 +  Params:
 +      line = Line to tint.
 +      fg = Foreground `IRCColour`.
 +      bg = Optional background `IRCColour`.
 +
 +  Returns:
 +      The passed line, encased within IRC colour tags.
 +/
string ircColour(const string line, const IRCColour fg, const IRCColour bg = IRCColour.unset) pure
in (line.length, "Tried to apply IRC colours to a string but no string was given")
{
    if (!line.length) return string.init;

    import std.array : Appender;

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
 +  Returns a mIRC colour code for the passed foreground and background colour.
 +  Overload that doesn't take a string to tint, only the `IRCColour`s to
 +  produce a colour code from.
 +
 +  Params:
 +      fg = Foreground `IRCColour`.
 +      bg = Optional background `IRCColour`.
 +
 +  Returns:
 +      An opening IRC colour token with the passed colours.
 +/
string ircColour(const IRCColour fg, const IRCColour bg = IRCColour.unset) pure
{
    import std.format : format;

    if (bg != IRCColour.unset)
    {
        return "%c%02d,%02d".format(cast(char)IRCControlCharacter.colour, fg, bg);
    }
    else
    {
        return "%c%02d".format(cast(char)IRCControlCharacter.colour, fg);
    }
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
 +  Returns the passed string coloured with an IRC colour depending on the hash
 +  of the string, making for good random nick colours in IRC messages.
 +
 +  Params:
 +      word = String to tint.
 +
 +  Returns:
 +      The passed string encased within IRC colour coding.
 +/
string ircColourByHash(const string word) pure
in (word.length, "Tried to apply IRC colours by hash to a string but no string was given")
{
    if (!word.length) return string.init;

    import std.format : format;

    alias I = IRCControlCharacter;

    immutable colourIndex = hashOf(word) % 16;
    return "%c%02d%s%c".format(cast(char)I.colour, colourIndex, word, cast(char)I.colour);
}

///
unittest
{
    alias I = IRCControlCharacter;

    // Colour based on hash

    {
        immutable actual = "kameloso".ircColourByHash;
        immutable expected = I.colour ~ "01kameloso" ~ I.colour;
        assert((actual == expected), actual);
    }
    {
        immutable actual = "kameloso^".ircColourByHash;
        immutable expected = I.colour ~ "09kameloso^" ~ I.colour;
        assert((actual == expected), actual);
    }
    {
        immutable actual = "kameloso^11".ircColourByHash;
        immutable expected = I.colour ~ "05kameloso^11" ~ I.colour;
        assert((actual == expected), actual);
    }
}


// ircBold
/++
 +  Returns the passed string wrapped inbetween IRC bold control characters.
 +
 +  Params:
 +      word = String word to make IRC bold.
 +
 +  Returns:
 +      The passed string, in IRC bold.
 +/
string ircBold(const string word) pure nothrow
in (word.length, "Tried to apply IRC bold to a string but no string was given")
{
    return IRCControlCharacter.bold ~ word ~ IRCControlCharacter.bold;
}

///
unittest
{
    alias I = IRCControlCharacter;

    immutable line = "kameloso: " ~ ircBold("kameloso");
    immutable expected = "kameloso: " ~ I.bold ~ "kameloso" ~ I.bold;
    assert((line == expected), line);
}


// ircItalics
/++
 +  Returns the passed string wrapped inbetween IRC italics control characters.
 +
 +  Params:
 +      word = String word to make IRC italics.
 +
 +  Returns:
 +      The passed string, in IRC italics.
 +/
string ircItalics(const string word) pure nothrow
in (word.length, "Tried to apply IRC italics to a string but no string was given")
{
    return IRCControlCharacter.italics ~ word ~ IRCControlCharacter.italics;
}

///
unittest
{
    alias I = IRCControlCharacter;

    immutable line = "kameloso: " ~ ircItalics("kameloso");
    immutable expected = "kameloso: " ~ I.italics ~ "kameloso" ~ I.italics;
    assert((line == expected), line);
}


// ircUnderlined
/++
 +  Returns the passed string wrapped inbetween IRC underlined control characters.
 +
 +  Params:
 +      word = String word to make IRC italics.
 +
 +  Returns:
 +      The passed string, in IRC italics.
 +/
string ircUnderlined(const string word) pure nothrow
in (word.length, "Tried to apply IRC underlined to a string but no string was given")
{
    return IRCControlCharacter.underlined ~ word ~ IRCControlCharacter.underlined;
}

///
unittest
{
    alias I = IRCControlCharacter;

    immutable line = "kameloso: " ~ ircUnderlined("kameloso");
    immutable expected = "kameloso: " ~ I.underlined ~ "kameloso" ~ I.underlined;
    assert((line == expected), line);
}


// ircReset
/++
 +  Returns an IRC formatting reset token.
 +
 +  Returns:
 +      An IRC colour/formatting reset token.
 +/
char ircReset() @nogc pure nothrow
{
    return cast(char)IRCControlCharacter.reset;
}


// mapEffects
/++
 +  Maps mIRC effect tokens (colour, bold, italics, underlined) to terminal ones.
 +
 +  Example:
 +  ---
 +  string mIRCEffectString = "...";
 +  string TerminalFormatString = mapEffects(mIRCEffectString);
 +  ---
 +
 +  Params:
 +      origLine = String line to map effects of.
 +      fgBase = Foreground base code to reset to after end colour tags.
 +      bgBase = Background base code to reset to after end colour tags.
 +
 +  Returns:
 +      A new string based on `origLine` with mIRC tokens mapped to terminal ones.
 +/
version(Colours)
string mapEffects(const string origLine, const uint fgBase = TerminalForeground.default_,
    const uint bgBase = TerminalBackground.default_) pure nothrow
{
    import kameloso.terminal : TF = TerminalFormat;
    import lu.string : contains;

    alias I = IRCControlCharacter;

    if (!origLine.length) return string.init;

    string line = origLine;

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
    import kameloso.terminal : TF = TerminalFormat, TerminalToken;
    import lu.conv : toAlpha;

    alias I = IRCControlCharacter;

    enum bBold = TerminalToken.format ~ "[" ~ TF.bold.toAlpha ~ "m";
    enum bReset = TerminalToken.format ~ "[22m";
    //enum bResetAll = TerminalToken.format ~ "[0m";

    immutable line1 = "ABC"~I.bold~"DEF"~I.bold~"GHI"~I.bold~"JKL"~I.bold~"MNO";
    immutable line2 = "ABC"~bBold~"DEF"~bReset~"GHI"~bBold~"JKL"~bReset~"MNO";//~bResetAll;
    immutable mapped = mapEffects(line1);

    assert((mapped == line2), mapped);
}


// stripEffects
/++
 +  Removes all form of mIRC formatting (colours, bold, italics, underlined)
 +  from a string.
 +
 +  Params:
 +      line = String to strip effects from.
 +
 +  Returns:
 +      A string devoid of effects.
 +/
string stripEffects(const string line) pure nothrow
{
    alias I = IRCControlCharacter;

    if (!line.length) return line;

    return line
        .stripColours
        .mapEffectsImpl!(Yes.strip, I.bold, 0)
        .mapEffectsImpl!(Yes.strip, I.italics, 0)
        .mapEffectsImpl!(Yes.strip, I.underlined, 0);
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
 +  Maps mIRC effect colour tokens to terminal ones.
 +
 +  Merely calls `mapColoursImpl` with `No.strip`.
 +
 +  Params:
 +      line = String line with IRC colours to translate.
 +      fgReset = Foreground code to reset to after colour-default tokens.
 +      bgReset = Background code to reset to after colour-default tokens.
 +
 +  Returns:
 +      The passed `line`, now with terminal colouring.
 +/
version(Colours)
string mapColours(const string line,
    const uint fgReset = TerminalForeground.default_,
    const uint bgReset = TerminalBackground.default_) pure nothrow
{
    if (!line.length) return line;

    return mapColoursImpl!(No.strip)(line, fgReset, bgReset);
}


// mapColoursImpl
/++
 +  Maps mIRC effect colour tokens to terminal ones, or strip them entirely.
 +  Now with less regex.
 +
 +  Pass `Yes.strip` as `strip` to map colours to nothing, removing colouring.
 +
 +  This function requires version `Colours` to map colours, but doesn't if
 +  just to strip.
 +
 +  Params:
 +      strip = Whether or not to strip colours or to map them.
 +      line = String line with IRC colours to translate.
 +      fgReset = Foreground code to reset to after colour-default tokens.
 +      bgReset = Background code to reset to after colour-default tokens.
 +
 +  Returns:
 +      The passed `line`, now with terminal colouring, or completely without.
 +/
private string mapColoursImpl(Flag!"strip" strip = No.strip)(const string line,
    const uint fgReset, const uint bgReset) pure nothrow
in ((fgReset > 0), "Tried to " ~ (strip ? "strip" : "map") ~
    " colours with a foreground reset value of 0")
in ((bgReset > 0), "Tried to " ~ (strip ? "strip" : "map") ~
    " colours with a backgroud reset value of 0")
{
    import lu.conv : toAlphaInto;
    import std.array : Appender;
    import std.string : indexOf;

    static if (!strip)
    {
        version(Colours) {}
        else
        {
            static assert(0, "`mapColoursImpl!(No.strip)` is being called " ~
                "outside of version `Colours`");
        }
    }

    struct Segment
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
                segment.hasBackground = true;

                int bg1;
                int bg2;
                bool hasBg2;

                bg1 = slice[0] - '0';
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

                int bg = hasBg2 ? (10*bg1 + bg2) : bg1;

                if (bg > 15)
                {
                    bg %= 16;
                }

                segment.bg = bg;
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
                    fgReset.toAlphaInto(sink);
                    sink.put(';');
                    bgReset.toAlphaInto(sink);
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

    static if (!strip)
    {
        version(Colours)
        {
            if (open)
            {
                sink.put("\033[39;49m");
                /*fgReset.toAlphaInto(sink);
                sink.put(';');
                bgReset.toAlphaInto(sink);
                sink.put('m');*/
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

    {
        immutable line = "This is " ~ I.colour ~ "4all red!" ~ I.colour ~ " while this is not.";
        immutable mapped = mapColours(line, 39, 49);
        assert((mapped == "This is \033[91mall red!\033[39;49m while this is not."), mapped);
    }
    {
        immutable line = "This time there's" ~ I.colour ~ "6 no ending token, only magenta.";
        immutable mapped = mapColours(line, 39, 49);
        assert((mapped == "This time there's\033[35m no ending token, only magenta.\033[39;49m"), mapped);
    }
    {
        immutable line = I.colour ~ "1,0You" ~ I.colour ~ "0,4Tube" ~ I.colour ~ " asdf";
        immutable mapped = mapColours(line, 39, 49);
        assert((mapped == "\033[90;107mYou\033[97;41mTube\033[39;49m asdf"), mapped);
    }
    {
        immutable line = I.colour ~ "17,0You" ~ I.colour ~ "0,21Tube" ~ I.colour ~ " asdf";
        immutable mapped = mapColours(line, 39, 49);
        assert((mapped == "\033[90;107mYou\033[97;41mTube\033[39;49m asdf"), mapped);
    }
    {
        immutable line = I.colour ~ "17,0You" ~ I.colour ~ "0,2" ~ I.colour;
        immutable mapped = mapColours(line, 39, 49);
        assert((mapped == "\033[90;107mYou\033[97;44m\033[39;49m"), mapped);
    }
    {
        immutable line = I.colour ~ "";
        immutable mapped = mapColours(line, 39, 49);
        assert((mapped == "\033[39;49m"), mapped);
    }
}


// stripColours
/++
 +  Removes IRC colouring from a passed string.
 +
 +  Merely calls `mapColours` with a `Yes.strip` template parameter.
 +
 +  Params:
 +      line = String to strip of IRC colour tags.
 +
 +  Returns:
 +      The passed `line`, now stripped of IRC colours.
 +/
string stripColours(const string line) pure nothrow
{
    enum fgReset = 39;
    enum bgReset = 49;

    if (!line.length) return line;

    return mapColoursImpl!(Yes.strip)(line, fgReset, bgReset);
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
 +  Replaces mIRC tokens with terminal effect codes, in an alternating fashion
 +  so as to support repeated effects toggling behaviour. Now with less regex.
 +
 +  It seems to be the case that a token for bold text will trigger bold text up
 +  until the next bold token. If we only naïvely replace all mIRC tokens for
 +  bold text then, we'll get lines that start off bold and continue as such
 +  until the very end.
 +
 +  Instead we iterate all occcurences of the pased `mircToken`, toggling the
 +  effect on and off.
 +
 +  Params:
 +      mircToken = mIRC token for a particular text effect.
 +      TerminalFormatCode = Terminal equivalent of the mircToken effect.
 +      line = The mIRC-formatted string to translate.
 +
 +  Returns:
 +      The passed `line`, now with terminal formatting.
 +/
private string mapEffectsImpl(Flag!"strip" strip, int mircToken, int terminalFormatCode)
    (const string line)
in ((mircToken > 0), "Tried to " ~ (strip ? "strip" : "map") ~ " effects with an IRC token of 0")
in ((strip || (terminalFormatCode > 0)), "Tried to map effects with terminal format code of 0")
{
    import lu.conv : toAlpha;
    import std.array : Appender;
    import std.string : indexOf;

    static if (!strip)
    {
        version(Colours) {}
        else
        {
            static assert(0, "`mapEffectsImpl!(No.strip)` is being called " ~
                "outside of version `Colours`");
        }
    }

    alias I = IRCControlCharacter;

    string slice = line;  // mutable

    ptrdiff_t pos = slice.indexOf(mircToken);

    if (pos == -1) return line;  // As is

    Appender!string sink;

    static if (!strip)
    {
        import kameloso.terminal : TF = TerminalFormat, TerminalReset, TerminalToken, colourWith;

        enum terminalToken = TerminalToken.format ~ "[" ~ toAlpha(terminalFormatCode) ~ "m";
        // enum pattern = "(?:"~mircToken~")([^"~mircToken~"]*)(?:"~mircToken~")";

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
                    sink.colourWith(TerminalReset.all);
                }

                open = false;
            }
        }

        pos = slice.indexOf(mircToken);
    }

    immutable tail = slice;

    sink.put(tail);

    static if (!strip)
    {
        if (open) sink.colourWith(TerminalReset.all);
    }

    return sink.data;
}

///
version(Colours)
unittest
{
    import kameloso.terminal : TerminalFormat, TerminalToken;
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
