module kameloso.bash;

import std.range : isOutputRange;
import std.traits : allSatisfy;
import std.typecons : Flag, No, Yes;

public import kameloso.constants : TerminalToken;


/// Effect codes that work like Bash colouring does, except for effects
enum BashEffect
{
    bold = 1,
    dim  = 2,
    italics = 3,
    underlined = 4,
    blink   = 5,
    reverse = 7,
    hidden  = 8,
}

/// Format codes for Bash colouring
enum BashFormat
{
    bright      = 1,
    dim         = 2,
    underlined  = 4,
    blink       = 5,
    invert      = 6,
    hidden      = 8,
}

/// Foreground colour codes for Bash colouring
enum BashForeground
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

/// Background colour codes for Bash colouring
enum BashBackground
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

/// Bash colour/effect reset codes
enum BashReset
{
    all         = 0,
    bright      = 21,
    dim         = 22,
    underlined  = 24,
    blink       = 25,
    invert      = 27,
    hidden      = 28,
}


/// Bool of whether a type is a colour code enum
enum isAColourCode(T) = is(T : BashForeground) || is(T : BashBackground) ||
                        is(T : BashFormat) || is(T : BashReset);


// colour
/++
 +  Takes a mix of a `BashForeground`, a `BashBackground`, a `BashFormat` and/or
 +  a `BashReset` and composes them into a colour code token.
 +
 +  This function creates an `Appender` and fills it with the return value of
 +  `colour(Sink, Codes...)`.
 +
 +  Params:
 +      codes = a variadic list of Bash format codes.
 +
 +  Returns:
 +      A Bash code sequence of the passed codes.
 +
 +  ------------
 +  string blinkOn = colour(BashForeground.white, BashBackground.yellow,
 +      BashEffect.blink);
 +  string blinkOff = colour(BashForeground.default_, BashBackground.default_,
 +      BashReset.blink);
 +  string blinkyName = blinkOn ~ "Foo" ~ blinkOff;
 +  ------------
 +/
version(Colours)
string colour(Codes...)(Codes codes)
if (Codes.length && allSatisfy!(isAColourCode, Codes))
{
    //static import kameloso.common;
    //if (kameloso.common.settings.monochrome) return string.init;

    import std.array : Appender;

    Appender!string sink;
    sink.reserve(16);

    sink.colour(codes);
    return sink.data;
}
else
/// Dummy colour for when version != Colours
string colour(Codes...)(Codes codes)
if (Codes.length && allSatisfy!(isAColourCode, Codes))
{
    return string.init;
}


// colour
/++
 +  Takes a mix of a `BashForeground`, a `BashBackground`, a `BashFormat` and/or
 +  a `BashReset`` and composes them into a colour code token.
 +
 +  This is the composing function that fills its result into an output range.
 +
 +  Params:
 +      codes = a variadic list of Bash format codes.
 +
 +  ------------
 +  Appender!string sink;
 +  sink.colour(BashForeground.red, BashEffect.bold);
 +  sink.put("Foo");
 +  sink.colour(BashForeground.default_, BashReset.bold);
 +  ------------
 +/
version(Colours)
void colour(Sink, Codes...)(auto ref Sink sink, const Codes codes)
if (isOutputRange!(Sink,string) && Codes.length && allSatisfy!(isAColourCode, Codes))
{
    sink.put(TerminalToken.bashFormat);
    sink.put('[');

    uint numCodes;

    foreach (const code; codes)
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
 +  Params:
 +      text = text to format
 +      codes = Bash formatting codes (colour, underscore, bold, ...) to apply
 +
 +  Returns:
 +      A Bash code sequence of the passed codes, encompassing the passed text.
 +
 +  ------------
 +  string foo = "Foo Bar".colour(BashForeground.bold, BashEffect.reverse);
 +  ------------
 +/
version(Colours)
string colour(Codes...)(const string text, const Codes codes)
if (Codes.length && allSatisfy!(isAColourCode, Codes))
{
    import std.array : Appender;

    Appender!string sink;
    sink.reserve(text.length + 15);

    sink.colour(codes);
    sink.put(text);
    sink.colour(BashReset.all);
    return sink.data;
}
else
deprecated("Don't use colour when version isn't Colours")
string colour(Codes...)(const string text, const Codes codes)
if (Codes.length && allSatisfy!(isAColourCode, Codes))
{
    // noop
    return text;
}


// normaliseColours
/++
 +  Takes a colour and, if it deems it is too dark to see on a black terminal
 +  background, makes it brighter.
 +
 +  Future improvements include reverse logic; making fonts darker to improve
 +  readability on bright background. The parameters are passed by `ref` and as
 +  such nothing is returned.
 +
 +  Params:
 +      r = red
 +      g = green
 +      b = blue
 +/
version(Colours)
void normaliseColours(ref uint r, ref uint g, ref uint b)
{
    enum pureBlackReplacement = 150;
    enum incrementWhenOnlyOneColour = 100;
    enum tooDarkValueThreshold = 75;
    enum highColourHighlight = 95;
    enum lowColourIncrement = 75;

    // Sanity check
    if (r > 255) r = 255;
    if (g > 255) g = 255;
    if (b > 255) b = 255;

    if ((r + g + b) == 0)
    {
        // Specialcase pure black, set to grey and return
        r = pureBlackReplacement;
        b = pureBlackReplacement;
        g = pureBlackReplacement;

        return;
    }

    if ((r + g + b) == 255)
    {
        // Precisely one colour is saturated with the rest at 0 (probably)
        // Make it more bland, can be difficult to see otherwise
        r += incrementWhenOnlyOneColour;
        b += incrementWhenOnlyOneColour;
        g += incrementWhenOnlyOneColour;

        // Sanity check
        if (r > 255) r = 255;
        if (g > 255) g = 255;
        if (b > 255) b = 255;

        return;
    }

    int rDark, gDark, bDark;

    rDark = (r < tooDarkValueThreshold);
    gDark = (g < tooDarkValueThreshold);
    bDark = (b < tooDarkValueThreshold);

    if ((rDark + gDark +bDark) > 1)
    {
        // At least two colours were below the threshold (75)

        // Highlight the colours above the threshold
        r += (rDark == 0) * highColourHighlight;
        b += (bDark == 0) * highColourHighlight;
        g += (gDark == 0) * highColourHighlight;

        // Raise all colours to make it brighter
        r += lowColourIncrement;
        b += lowColourIncrement;
        g += lowColourIncrement;

        // Sanity check
        if (r >= 255) r = 255;
        if (g >= 255) g = 255;
        if (b >= 255) b = 255;
    }
}


// truecolour
/++
 +  Produces a Bash colour token for the colour passed, expressed in terms of
 +  red, green and blue.
 +
 +  Params:
 +      normalise = normalise colours so that they aren't too dark.
 +      sink = output range to write the final code into
 +      r = red
 +      g = green
 +      b = blue
 +
 +  ------------
 +  Appender!string sink;
 +  int r, g, b;
 +  numFromHex("3C507D", r, g, b);
 +  sink.truecolour(r, g, b);
 +  sink.put("Foo");
 +  sink.colour(BashReset.all);
 +  ------------
 +/
version(Colours)
void truecolour(Flag!"normalise" normalise = Yes.normalise, Sink)
    (auto ref Sink sink, uint r, uint g, uint b)
if (isOutputRange!(Sink,string))
{
    import std.format : formattedWrite;

    // \033[
    // 38 foreground
    // 2 truecolor?
    // r;g;bm

    static if (normalise)
    {
        normaliseColours(r, g, b);
    }

    sink.formattedWrite("%c[38;2;%d;%d;%dm",
        cast(char)TerminalToken.bashFormat, r, g, b);
}
else
deprecated("Don't use truecolour when version isn't Colours")
void truecolour(Flag!"normalise" normalise = Yes.normalise, Sink)
    (auto ref Sink sink, uint r, uint g, uint b)
{
    // noop
}


// truecolour
/++
 +  Convenience function to colour a piece of text without being passed an
 +  output sink to fill into.
 +
 +  ------------
 +  string foo = "Foo Bar".truecolour(172, 172, 255);
 +
 +  int r, g, b;
 +  numFromHex("003388", r, g, b);
 +  string bar = "Bar Foo".truecolour(r, g, b);
 +  ------------
 +/
version(Colours)
string truecolour(Flag!"normalise" normalise = Yes.normalise)
    (const string word, uint r, uint g, uint b)
{
    import std.array : Appender;

    Appender!string sink;
    // \033[38;2;255;255;255m<word>\033[m
    sink.reserve(word.length + 23);

    static if (normalise)
    {
        normaliseColours(r, g, b);
    }

    sink.truecolour(r, g, b);
    sink.put(word);
    sink.put('\033'~"[0m");
    return sink.data;
}
else
deprecated("Don't use truecolour when version isn't Colours")
string truecolour(Flag!"normalise" normalise = Yes.normalise)
    (const string word, uint r, uint g, uint b)
{
    retun word;
}

///
version(Colours)
unittest
{
    import std.format : format;

    immutable name = "blarbhl".truecolour!(No.normalise)(255,255,255);
    immutable alsoName = "%c[38;2;%d;%d;%dm%s%c[0m"
        .format(cast(char)TerminalToken.bashFormat, 255, 255, 255,
        "blarbhl", cast(char)TerminalToken.bashFormat);

    assert((name == alsoName), alsoName);
}

///
version(Colours)
unittest
{
    import std.array : Appender;

    Appender!(char[]) sink;

    // LDC workaround for not taking formattedWrite sink as auto ref
    sink.reserve(16);

    sink.truecolour!(No.normalise)(0, 0, 0);
    assert(sink.data == "\033[38;2;0;0;0m", sink.data);
    sink.clear();

    sink.truecolour!(Yes.normalise)(0, 0, 0);
    assert(sink.data == "\033[38;2;150;150;150m", sink.data);
    sink.clear();

    sink.truecolour(255, 255, 255);
    assert(sink.data == "\033[38;2;255;255;255m", sink.data);
    sink.clear();

    sink.truecolour(123, 221, 0);
    assert(sink.data == "\033[38;2;123;221;0m", sink.data);
    sink.clear();

    sink.truecolour(0, 255, 0);
    assert(sink.data == "\033[38;2;100;255;100m", sink.data);
}
