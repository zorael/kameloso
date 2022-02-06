module kameloso.terminal;

private:

import std.meta : allSatisfy;
import std.typecons : Flag, No, Yes;

public:

@safe:

enum TerminalToken
{
    format = '\033',
    bell = '\007',
}

bool isTTY()
{
    return true;
}

void ensureAppropriateBuffering(const Flag!"override_" override_ = No.override_) @system {}

void setTitle(const string title) @system {}

version(Colours):

enum TerminalFormat
{
    bold        = 1,
    dim         = 2,
    italics     = 3,
    underlined  = 4,
    blink       = 5,
    reverse     = 7,
    hidden      = 8,
}

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

enum isAColourCode(T) =
    is(T : TerminalForeground) ||
    is(T : TerminalBackground) ||
    is(T : TerminalFormat) ||
    is(T : TerminalReset);

version(Colours)
string colour(Codes...)(const Codes codes) pure nothrow
if (Codes.length && allSatisfy!(isAColourCode, Codes))
{
    return string.init;
}

version(Colours)
void colourWith(Sink, Codes...)(auto ref Sink sink, const Codes codes) {}

version(Colours)
string invert(const string line,
    const string toInvert,
    const Flag!"caseSensitive" caseSensitive = Yes.caseSensitive) pure
{
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

    if (startpos == -1) return line;

    immutable inverted = "%c[%dm%s%c[%dm".format(TerminalToken.format,
        TerminalFormat.reverse, toInvert, TerminalToken.format, TerminalReset.invert);

    Appender!(char[]) sink;
    sink.reserve(line.length + 16);
    string slice = line;

    uint i;

    do
    {
        immutable endpos = startpos + toInvert.length;

        if ((startpos == 0) && (i > 0))
        {
            sink.put(slice[0..endpos]);
        }
        else if (endpos == slice.length)
        {
            sink.put(slice[0..startpos]);
            sink.put(inverted);

        }
        else if ((startpos > 1) && slice[startpos-1].isValidNicknameCharacter)
        {
            sink.put(slice[0..endpos]);
        }
        else if (slice[endpos].isValidNicknameCharacter)
        {
            sink.put(slice[0..endpos]);
        }
        else
        {
            sink.put(slice[0..startpos]);
            sink.put(inverted);
        }

        ++i;
        slice = slice[endpos..$];
        startpos = slice.indexOf(toInvert);
    }
    while (startpos != -1);

    sink.put(slice);

    return sink.data;
}

version(Colours)
string colourByHash(const string word, const Flag!"brightTerminal" bright)
{
    return string.init;
}
