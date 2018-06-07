/++
 +  A collection of enums and functions that relate to a Bash shell.
 +
 +  Much of this module has to do with terminal text colouring and is therefore
 +  version `Colours`.
 +/
module kameloso.bash;

import std.range : isOutputRange;
import std.meta : allSatisfy;
import std.typecons : Flag, No, Yes;

@safe:

/// Special terminal control characters.
enum TerminalToken
{
    /// Character that preludes a Bash colouring code.
    bashFormat = '\033',

    /// Terminal bell/beep.
    bell = '\007',

    /// Character that resets a terminal that has entered "binary" mode.
    reset = 15,
}

/++
 +  Effect codes that work like Bash colouring does, except for formatting
 +  effects like bold, dim, italics, etc.
 +/
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

/// Format codes for Bash colouring.
enum BashFormat
{
    bright      = 1,
    dim         = 2,
    underlined  = 4,
    blink       = 5,
    invert      = 6,
    hidden      = 8,
}

/// Foreground colour codes for Bash colouring.
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

/// Background colour codes for Bash colouring.
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

/// Bash colour/effect reset codes.
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

/// Bool of whether a type is a colour code enum.
enum isAColourCode(T) = is(T : BashForeground) || is(T : BashBackground) ||
                        is(T : BashFormat) || is(T : BashReset) ||
                        is(T == int);  // FIXME


// colour
/++
 +  Takes a mix of a `BashForeground`, a `BashBackground`, a `BashFormat` and/or
 +  a `BashReset` and composes them into a single Bash colour code token.
 +
 +  This function creates an `std.array.Appender` and fills it with the return
 +  value of the output range version of `colour`.
 +
 +  Example:
 +  ------------
 +  string blinkOn = colour(BashForeground.white, BashBackground.yellow,
 +      BashEffect.blink);
 +  string blinkOff = colour(BashForeground.default_, BashBackground.default_,
 +      BashReset.blink);
 +  string blinkyName = blinkOn ~ "Foo" ~ blinkOff;
 +  ------------
 +
 +  Params:
 +      codes = Variadic list of Bash format codes.
 +
 +  Returns:
 +      A Bash code sequence of the passed codes.
 +/



// colour
/++
 +  Takes a mix of a `BashForeground`, a `BashBackground`, a `BashFormat` and/or
 +  a `BashReset`` and composes them into a colour code token.
 +
 +  This is the composing function that fills its result into an output range.
 +
 +  Example:
 +  ------------
 +  Appender!string sink;
 +  sink.colour(BashForeground.red, BashEffect.bold);
 +  sink.put("Foo");
 +  sink.colour(BashForeground.default_, BashReset.bold);
 +  ------------
 +
 +  Params:
 +      sink = Output range to write output to.
 +      codes = Variadic list of Bash format codes.
 +/



// colour
/++
 +  Convenience function to colour or format a piece of text without an output
 +  buffer to fill into.
 +
 +  Example:
 +  ------------
 +  string foo = "Foo Bar".colour(BashForeground.bold, BashEffect.reverse);
 +  ------------
 +
 +  Params:
 +      text = Text to format.
 +      codes = Bash formatting codes (colour, underscore, bold, ...) to apply.
 +
 +  Returns:
 +      A Bash code sequence of the passed codes, encompassing the passed text.
 +/



// normaliseColoursBright
/++
 +  Takes a colour and, if it deems it is too bright to see on a light terminal
 +  background, makes it darker.
 +
 +  Example:
 +  ------------
 +  int r = 255;
 +  int g = 128;
 +  int b = 100;
 +  normaliseColoursBright(r, g, b);
 +  assert(r != 255);
 +  assert(g != 128);
 +  assert(b != 100);
 +  ------------
 +
 +  Params:
 +      r = Reference to a red value.
 +      g = Reference to a green value.
 +      b = Reference to a blue value.
 +/


// normaliseColours
/++
 +  Takes a colour and, if it deems it is too dark to see on a black terminal
 +  background, makes it brighter.
 +
 +  Example:
 +  ------------
 +  int r = 255;
 +  int g = 128;
 +  int b = 100;
 +  normaliseColoursBright(r, g, b);
 +  assert(r != 255);
 +  assert(g != 128);
 +  assert(b != 100);
 +  ------------
 +
 +  Params:
 +      r = Reference to a red value.
 +      g = Reference to a green value.
 +      b = Reference to a blue value.
 +/


// truecolour
/++
 +  Produces a Bash colour token for the colour passed, expressed in terms of
 +  red, green and blue.
 +
 +  Example:
 +  ------------
 +  Appender!string sink;
 +  int r, g, b;
 +  numFromHex("3C507D", r, g, b);
 +  sink.truecolour(r, g, b);
 +  sink.put("Foo");
 +  sink.colour(BashReset.all);
 +  writeln(sink);  // "Foo" in #3C507D
 +  ------------
 +
 +  Params:
 +      normalise = Whether to normalise colours so that they aren't too dark.
 +      sink = Output range to write the final code into.
 +      r = Red value.
 +      g = Green value.
 +      b = Blue value.
 +      bright = Whether the terminal has a bright background or not.
 +/



// truecolour
/++
 +  Convenience function to colour a piece of text without being passed an
 +  output sink to fill into.
 +
 +  Example:
 +  ------------
 +  string foo = "Foo Bar".truecolour(172, 172, 255);
 +
 +  int r, g, b;
 +  numFromHex("003388", r, g, b);
 +  string bar = "Bar Foo".truecolour(r, g, b);
 +  ------------
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
 +      The passed string word encompassed by Bash colour tags.
 +/



// invert
/++
 +  Bash-inverts the colours of a piece of text in a string.
 +
 +  Example:
 +  ------------
 +  immutable line = "This is an example!";
 +  writeln(line.invert("example"));  // "example" substring visually inverted
 +  ------------
 +
 +  Params:
 +      line = Line to examine and invert a substring of.
 +      toInvert = Substring to invert.
 +
 +  Returns:
 +      Line with the substring in it inverted, if inversion was successful,
 +      else (a duplicate of) the line unchanged.
 +/

