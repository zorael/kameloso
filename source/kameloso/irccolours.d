/++
 +  This module contains functions for working with IRC colouring and
 +  formatting, mapping it to Bash such, stripping it, etc.
 +/
module kameloso.irccolours;

import kameloso.irc : IRCControlCharacter;

version(Colours)
{
    import kameloso.bash : BashBackground, BashForeground;
}


/// Official mIRC colour table.
enum IRCColour
{
    unset    = -1,
    white    = 0,
    black    = 1,
    blue     = 2,
    green    = 3,
    red      = 4,
    brown    = 5,
    purple   = 6,
    orange   = 7,
    yellow   = 8,
    lightgreen = 9,
    cyan      = 10,
    lightcyan = 11,
    lightblue = 12,
    pink      = 13,
    grey      = 14,
    lightgrey = 15,
    transparent = 99,
}


// ircColour
/++
 +  Colour-codes the passed string with mIRC colouring, foreground and
 +  background.
 +
 +  Output range overload that outputs to a passed auto ref sink.
 +
 +  Params:
 +      sink = Output range sink to fill with the function's output.
 +      line = Line to tint.
 +      fg = Foreground `IRCColour`.
 +      bg = Background `IRCColour`.
 +/
void ircColour(Sink)(auto ref Sink sink, const string line, const IRCColour fg,
    const IRCColour bg = IRCColour.unset)
{
    import std.conv : to;
    import std.format : formattedWrite;

    assert((fg != IRCColour.unset), "Tried to IRC colour with an unset colour");

    sink.put(cast(char)IRCControlCharacter.colour);
    sink.formattedWrite("%02d", fg);

    if (bg != IRCColour.unset)
    {
        sink.formattedWrite(",%02d", bg);
    }

    sink.put(line);
    sink.put(cast(char)IRCControlCharacter.colour);
}


// ircColour
/++
 +  Colour-codes the passed string with mIRC colouring, foreground and
 +  background.
 +
 +  Direct overload that leverages he output range version to colour an internal
 +  `std.array.Appender`, and returns the resulting string.
 +
 +  Params:
 +      line = Line to tint.
 +      fg = Foreground `IRCColour`.
 +      bg = Background `IRCColour`.
 +
 +  Returns:
 +      The passed line, encased within IRC colour tags.
 +/
string ircColour(const string line, const IRCColour fg, const IRCColour bg = IRCColour.unset)
{
    if (!line.length) return string.init;

    import std.array : Appender;

    Appender!string sink;

    sink.reserve(line.length + 7);  // Two colour tokens, four colour numbers and a comma
    sink.ircColour(line, fg, bg);

    return sink.data;
}


// ircColour
/++
 +  Returns a mIRC colour code for the passed foreground and background colour.
 +  background.
 +
 +  Overload that doesn't take a string to tint, only the `IRCColour`s to
 +  produe a colour code from.
 +
 +  Params:
 +      fg = Foreground `IRCColour`.
 +      bg = Background `IRCColour`.
 +
 +  Returns:
 +      An opening IRC colour token with the passed colours.
 +/
string ircColour(const IRCColour fg, const IRCColour bg = IRCColour.unset)
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
    import std.string;
    import std.stdio;

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


// ircColourNick
/++
 +  Returns the passed string coloured with an IRC colour depending on the hash
 +  of the string, making for good random nick colours in IRC messages.
 +
 +  Params:
 +      nickname = String nickname to tint.
 +
 +  Returns:
 +      The passed nickname encased within IRC colour coding.
 +/
string ircColourNick(const string nickname)
{
    if (!nickname.length) return string.init;

    import std.format : format;

    alias I = IRCControlCharacter;

    immutable colourIndex = hashOf(nickname) % 16;
    return "%c%02d%s%c".format(cast(char)I.colour, colourIndex, nickname, cast(char)I.colour);
}

///
unittest
{
    alias I = IRCControlCharacter;

    {
        immutable actual = "kameloso".ircColourNick;
        immutable expected = I.colour ~ "01kameloso" ~ I.colour;
        assert((actual == expected), actual);
    }
}


// ircBold
/++
 +  Returns the passed string wrapped inbetween IRC bold control characters.
 +
 +  Params:
 +      line = String line to make IRC bold.
 +
 +  Returns:
 +      The passed line, in IRC bold.
 +/
string ircBold(const string line)
{
    return IRCControlCharacter.bold ~ line ~ IRCControlCharacter.bold;
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
 +      line = String line to make IRC italics.
 +
 +  Returns:
 +      The passed line, in IRC italics.
 +/
string ircItalics(const string line)
{
    return IRCControlCharacter.italics ~ line ~ IRCControlCharacter.italics;
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
 +  Returns the passed string wrapped inbetween IRC underlined control
 +  characters.
 +
 +  Params:
 +      line = String line to make IRC italics.
 +
 +  Returns:
 +      The passed line, in IRC italics.
 +/
string ircUnderlined(const string line)
{
    return IRCControlCharacter.underlined ~ line ~ IRCControlCharacter.underlined;
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
char ircReset()
{
    return cast(char)IRCControlCharacter.reset;
}


// mapEffects
/++
 +  Maps mIRC effect tokens (colour, bold, italics, underlined) to Bash ones.
 +
 +  Params:
 +      origLine = String line to map effects of.
 +      fgBase = Foreground base code to reset to after end colour tags.
 +      bgBase = Backgrund base code to reset to after end colour tags.
 +
 +  Returns:
 +      A new string based on `origLine` with mIRC tokens mapped to Bash ones.
 +/
string mapEffects(const string origLine, const uint fgBase = BashForeground.default_,
    const uint bgBase = BashBackground.default_)
{
    import kameloso.bash : B = BashEffect;
    import kameloso.irc : I = IRCControlCharacter;
    import kameloso.string : contains;

    string line = origLine;

    if (line.contains(I.colour))
    {
        // Colour is mIRC 3
        line = mapColours(line, fgBase, bgBase);
    }

    if (line.contains(I.bold))
    {
        // Bold is bash 1, mIRC 2
        line = mapAlternatingEffectImpl!(I.bold, B.bold)(line);
    }

    if (line.contains(I.italics))
    {
        // Italics is bash 3 (not really), mIRC 29
        line = mapAlternatingEffectImpl!(I.italics, B.italics)(line);
    }

    if (line.contains(I.underlined))
    {
        // Underlined is bash 4, mIRC 31
        line = mapAlternatingEffectImpl!(I.underlined, B.underlined)(line);
    }

    return line;
}


// stripEffects
/++
 +  Removes all form of mIRC formatting (colours, bold, italics, underlined)
 +  from an `kameloso.ircdefs.IRCEvent`.
 +
 +  Params:
 +      content = String to strip effects from.
 +
 +  Returns:
 +      A string devoid of effects.
 +/
string stripEffects(const string content)
{
    import kameloso.irc : I = IRCControlCharacter;
    import kameloso.string : contains;
    import std.array : replace;

    enum boldCode = "" ~ I.bold;
    enum italicsCode = "" ~ I.italics;
    enum underlinedCode = "" ~ I.underlined;

    if (!content.length) return string.init;

    return content
        .stripColours
        .replace(boldCode, string.init)
        .replace(italicsCode, string.init)
        .replace(underlinedCode, string.init);
}

///
unittest
{
    import kameloso.irc : I = IRCControlCharacter;

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
 +  Maps mIRC effect colour tokens to Bash ones.
 +
 +  Params:
 +      event = Reference to the `kameloso.ircdefs.IRCEvent` to modify.
 +/
version(Colours)
string mapColours(const string line, const uint fgReset = BashForeground.default_,
    const uint bgReset = BashBackground.default_)
{
    import kameloso.bash : colour;
    import kameloso.irc : I = IRCControlCharacter;
    import std.array : replace;
    import std.regex : matchAll, regex;

    enum colourPattern = I.colour ~ "([0-9]{1,2})(?:,([0-9]{1,2}))?";
    auto engine = colourPattern.regex;

    alias F = BashForeground;
    BashForeground[16] weechatForegroundMap =
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

    alias B = BashBackground;
    BashBackground[16] weechatBackgroundMap =
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

    string slice = line;

    foreach (hit; line.matchAll(engine))
    {
        import std.array : Appender;
        import std.conv : to;

        /+
            Technically mIRC accepts the full number range 0 to 99. Thus N and M
            can maximally be two digits long. The way these colors are
            interpreted varies from client to client. Some map the numbers back
            to 0 to 15, others interpret numbers larger than 15 as the default
            text color.
         +/

        ubyte fgIndex = hit[1].to!ubyte;

        if (fgIndex > 15)
        {
            fgIndex %= 16;
        }

        Appender!string sink;
        sink.reserve(8);
        sink.put("\033[");
        sink.put((cast(ubyte)weechatForegroundMap[fgIndex]).to!string);

        if (hit[2].length)
        {
            ubyte bgIndex = hit[2].to!ubyte;

            if (bgIndex > 15)
            {
                bgIndex %= 16;
            }

            sink.put(';');
            sink.put((cast(ubyte)weechatBackgroundMap[bgIndex]).to!string);
        }

        sink.put('m');
        slice = slice.replace(hit[0], sink.data);
    }

    import std.format : format;
    enum endToken = I.colour ~ ""; // ~ "([0-9])?";
    slice = slice.replace(endToken, "\033[%d;%dm".format(fgReset, bgReset));

    return slice;
}

///
version(Colours)
unittest
{
    import kameloso.irc : I = IRCControlCharacter;

    {
        immutable line = "This is " ~ I.colour ~ "4all red!" ~ I.colour ~ " while this is not.";
        immutable mapped = mapColours(line, 39, 49);
        assert((mapped == "This is \033[91mall red!\033[39;49m while this is not."), mapped);
    }
    {
        immutable line = "This time there's" ~ I.colour ~ "6 no ending token, only magenta.";
        immutable mapped = mapColours(line);
        assert((mapped == "This time there's\033[35m no ending token, only magenta."), mapped);
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
}


// stripColours
/++
 +  Removes IRC colouring from a passed string.
 +
 +  Params:
 +      line = String to strip of IRC colour tags.
 +/
string stripColours(const string line)
{
    import kameloso.irc : I = IRCControlCharacter;
    import std.array : replace;
    import std.regex : matchAll, regex, replaceAll;

    enum colourPattern = I.colour ~ "([0-9]{1,2})(?:,([0-9]{1,2}))?";
    auto engine = colourPattern.regex;

    bool strippedSomething;

    string slice = line;

    foreach (hit; line.matchAll(engine))
    {
        import std.array : Appender;
        import std.conv : to;

        if (!hit[1].length) continue;

        slice = slice.replace(hit[0], string.init);
        strippedSomething = true;
    }

    if (strippedSomething)
    {
        enum endPattern = I.colour ~ ""; // ~ "(?:[0-9])?";
        auto endEngine = endPattern.regex;

        slice = slice.replaceAll(endEngine, string.init);
    }

    return slice;
}

///
unittest
{
    import kameloso.irc : I = IRCControlCharacter;

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


// mapAlternatingEffectImpl
/++
 +  Replaces mIRC tokens with Bash effect codes, in an alternating fashion so as
 +  to support repeated effects toggling behaviour.
 +
 +  It seems to be the case that a token for bold text will trigger bold text up
 +  until the next bold token. If we only naïvely replace all mIRC tokens for
 +  bold text then, we'll get lines that start off bold and continue as such
 +  until the very end.
 +
 +  Instead we look at it in a pairwise perspective. We use regex to replace
 +  pairs of tokens, properly alternating and toggling on and off, then once
 +  more at the end in case there was an odd token only toggling on.
 +
 +  Params:
 +      mircToken = mIRC token for a particular text effect.
 +      bashEffectCode = Bash equivalent of the mircToken effect.
 +      event = Reference to the `kameloso.ircdefs.IRCEvent` to modify.
 +/
version(Colours)
string mapAlternatingEffectImpl(ubyte mircToken, ubyte bashEffectCode)(const string line)
{
    import kameloso.bash : B = BashEffect, BashReset, TerminalToken, colour;
    import kameloso.irc : I = IRCControlCharacter;
    import std.array : Appender, replace;
    import std.conv  : to;
    import std.regex : matchAll, regex;

    enum bashToken = TerminalToken.bashFormat ~ "[" ~
        (cast(ubyte)bashEffectCode).to!string ~ "m";

    enum pattern = "(?:"~mircToken~")([^"~mircToken~"]*)(?:"~mircToken~")";
    auto engine = pattern.regex;

    Appender!string sink;
    sink.reserve(cast(size_t)(line.length * 1.1));

    auto hits = line.matchAll(engine);

    while (hits.front.length)
    {
        sink.put(hits.front.pre);
        sink.put(bashToken);
        sink.put(hits.front[1]);

        switch (bashEffectCode)
        {
        case 1:
        case 2:
            // Both 1 and 2 seem to be reset by 22?
            sink.put(TerminalToken.bashFormat ~ "[22m");
            break;

        case 3:
        ..
        case 5:
            sink.put(TerminalToken.bashFormat ~ "[2" ~ bashEffectCode.to!string ~ "m");
            break;

        default:
            //logger.warning("Unknown Bash effect code: ", bashEffectCode);
            sink.colour(BashReset.all);
            break;
        }

        hits = hits.post.matchAll(engine);
    }

    // We've gone through them pair-wise, now see if there are any singles left.
    enum singleToken = cast(char)mircToken ~ "";
    sink.put(hits.post.replace(singleToken, bashToken));

    // End tags and commit.
    sink.colour(BashReset.all);
    return sink.data;
}

///
version(Colours)
unittest
{
    import kameloso.bash : B = BashEffect, TerminalToken;
    import kameloso.irc : I = IRCControlCharacter;
    import std.conv : to;

    enum bBold = TerminalToken.bashFormat ~ "[" ~ (cast(ubyte)B.bold).to!string ~ "m";
    enum bReset = TerminalToken.bashFormat ~ "[22m";
    enum bResetAll = TerminalToken.bashFormat ~ "[0m";

    immutable line1 = "ABC"~I.bold~"DEF"~I.bold~"GHI"~I.bold~"JKL"~I.bold~"MNO";
    immutable line2 = "ABC"~bBold~"DEF"~bReset~"GHI"~bBold~"JKL"~bReset~"MNO"~bResetAll;
    immutable mapped = mapEffects(line1);

    assert((mapped == line2), mapped);
}
