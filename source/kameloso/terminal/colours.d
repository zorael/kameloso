/++
    A collection of enums and functions that relate to a terminal shell.

    This submodule has to do with terminal text colouring and its contents are
    therefore version `Colours`.

    Example:
    ---
    Appender!(char[]) sink;

    // Output range version
    sink.put("Hello ");
    sink.colourWith(TerminalForeground.red);
    sink.put("world!");
    sink.colourWith(TerminalForeground.default_);

    with (TerminalForeground)
    {
        // Normal string-returning version
        writeln("Hello ", red.colour, "world!", default_.colour);
    }

    // Also accepts RGB form
    sink.put(" Also");
    sink.truecolour(128, 128, 255);
    sink.put("magic");
    sink.colourWith(TerminalForeground.default_);

    with (TerminalForeground)
    {
        writeln("Also ", truecolour(128, 128, 255), "magic", default_.colour);
    }

    immutable line = "Surrounding text kameloso surrounding text";
    immutable kamelosoInverted = line.invert("kameloso");
    assert(line != kamelosoInverted);

    immutable nicknameTint = "nickname".getColourByHash(Yes.brightTerminal);
    immutable substringTint = "substring".getColourByHash(No.brightTerminal);
    ---

    It is used heavily in the Printer plugin, to format sections of its output
    in different colours, but it's generic enough to use anywhere.

    The output range versions are cumbersome but necessary to minimise the number
    of strings generated.

    See_Also:
        [kameloso.terminal]
 +/

module kameloso.terminal.colours;

private:

import kameloso.common : logger;
import kameloso.logger : LogLevel;
import std.typecons : Flag, No, Yes;

public:


// Tint
/++
    Provides an easy way to access the `*tint` members of our
    [kameloso.logger.KamelosoLogger|KamelosoLogger] instance [logger].

    It still accesses the global [kameloso.common.logger] instance, but is now
    independent of [kameloso.common.settings].

    Example:
    ---
    logger.logf("%s%s%s am a %1$s%4$s%3$s!", logger.infotint, "I", logger.logtint, "fish");
    ---

    If the inner `monochrome` member is true, `Tint.*` will just return an empty string.
 +/
struct Tint
{
    /++
        Whether or not output should be coloured at all.
     +/
    static bool monochrome;

    version(Colours)
    {
        // opDispatch
        /++
            Provides the string that corresponds to the tint of the
            [kameloso.logger.LogLevel|LogLevel] that was passed in string form
            as the `tint` `opDispatch` template parameter.

            This saves us the boilerplate of copy/pasting one function for each
            [kameloso.logger.LogLevel|LogLevel].
         +/
        pragma(inline, true)
        static string opDispatch(string tint)()
        in ((logger !is null), "`Tint." ~ tint ~ "` was called with an uninitialised `logger`")
        {
            import std.traits : isSomeFunction;

            enum tintfun = "logger." ~ tint ~ "tint";

            static if (__traits(hasMember, logger, tint ~ "tint") &&
                isSomeFunction!(mixin(tintfun)))
            {
                return monochrome ? string.init : mixin(tintfun);
            }
            else
            {
                static assert(0, "Unknown tint `" ~ tint ~ "` passed to `Tint.opDispatch`");
            }
        }
    }
    else
    {
        /++
            Returns an empty string, since we're not versioned `Colours`.
         +/
        pragma(inline, true)
        static string log()
        {
            return string.init;
        }

        alias all = log;
        alias info = log;
        alias warning = log;
        alias error = log;
        alias trace = log;
        alias critical = log;
        alias fatal = log;
        alias off = log;
    }
}

///
unittest
{
    if (logger !is null)
    {
        version(Colours)
        {
            assert(logger.logtint is logger.logtint);
            assert(logger.infotint is logger.infotint);
            assert(logger.warningtint is logger.warningtint);
            assert(logger.errortint is logger.errortint);
            assert(logger.fataltint is logger.fataltint);
            assert(logger.tracetint is logger.tracetint);
            assert(logger.offtint is logger.offtint);
        }
        else
        {
            assert(logger.logtint == string.init);
            assert(logger.infotint == string.init);
            assert(logger.warningtint == string.init);
            assert(logger.errortint == string.init);
            assert(logger.fataltint == string.init);
            assert(logger.tracetint == string.init);
            assert(logger.offtint == string.init);
        }
    }
}


// expandTags
/++
    String-replaces `<tags>` in a string with the results from calls to `Tint`.
    Also works with `dstring`s and `wstring`s.

    `<tags>` are the lowercase first letter of all
    [kameloso.logger.LogLevel|LogLevel]s; `<l>`, `<t>`, `<i>`, `<w>`
    `<e>`, `<c>` and `<f>`. `<a>` is not included.

    `</>` equals the passed `baseLevel` and is used to terminate colour sequences,
    returning to a default.

    Lastly, text between two `<h>`s are replaced with the results from a call to
    [kameloso.terminal.colours|colourByHash|colourByHash].

    This should hopefully make highlighted strings more readable.

    Example:
    ---
    enum keyPattern = "
        %1$sYour private authorisation key is: %2$s%3$s%4$s
        It should be entered as %2$spass%4$s under %2$s[IRCBot]%4$s.
        ";

    enum keyPatternWithColoured = "
        <l>Your private authorisation key is: <i>%s</>
        It should be entered as <i>pass</> under <i>[IRCBot]</>
        ";

    enum patternWithColouredNickname = "No quotes for nickname <h>%s<h>.";
    immutable message = patternWithColouredNickname.format(event.sendern.nickname);
    ---

    Params:
        line = A line of text, presumably with `<tags>`.
        baseLevel = The base [kameloso.logger.LogLevel|LogLevel] to fall back to
            on `</>` tags.
        strip = Whether to expand tags or strip them.

    Returns:
        The passsed `line` but with any `<tags>` replaced with ANSI colour sequences.
        The original string is passed back if there was nothing to replace.
 +/
auto expandTags(T)(const T line, const LogLevel baseLevel, const Flag!"strip" strip) @safe
{
    import lu.string : contains;
    import std.array : Appender;
    import std.range : ElementEncodingType;
    import std.string : representation;
    import std.traits : Unqual;

    static import kameloso.common;

    alias E = Unqual!(ElementEncodingType!T);

    if (!line.length || !line.contains('<')) return line;

    Appender!(E[]) sink;
    bool dirty;
    bool escaping;

    immutable asBytes = line.representation;
    immutable toReserve = (asBytes.length + 16);

    byteloop:
    for (size_t i = 0; i<asBytes.length; ++i)
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
                    if (slice.length != 1) break;

                    sliceswitch:
                    switch (slice[0])
                    {

                    version(Colours)
                    {
                        case 'l':
                            if (!strip) sink.put(logger.logtint);
                            break;

                        case 't':
                            if (!strip) sink.put(logger.tracetint);
                            break;

                        case 'i':
                            if (!strip) sink.put(logger.infotint);
                            break;

                        case 'w':
                            if (!strip) sink.put(logger.warningtint);
                            break;

                        case 'e':
                            if (!strip) sink.put(logger.errortint);
                            break;

                        case 'c':
                            if (!strip) sink.put(logger.criticaltint);
                            break;

                        case 'f':
                            if (!strip) sink.put(logger.fataltint);
                            break;

                        case 'o':
                            if (!strip) sink.put(logger.offtint);
                            break;

                        case '/':
                            if (!strip)
                            {
                                with (LogLevel)
                                final switch (baseLevel)
                                {
                                case all:  //log
                                    //goto case 'l';
                                    if (!strip) sink.put(logger.logtint);
                                    break sliceswitch;

                                case trace:
                                    //goto case 't';
                                    if (!strip) sink.put(logger.tracetint);
                                    break sliceswitch;

                                case info:
                                    //goto case 'i';
                                    if (!strip) sink.put(logger.infotint);
                                    break sliceswitch;

                                case warning:
                                    //goto case 'w';
                                    if (!strip) sink.put(logger.warningtint);
                                    break sliceswitch;

                                case error:
                                    //goto case 'e';
                                    if (!strip) sink.put(logger.errortint);
                                    break sliceswitch;

                                case critical:
                                    //goto case 'c';
                                    if (!strip) sink.put(logger.criticaltint);
                                    break sliceswitch;

                                case fatal:
                                    //goto case 'f';
                                    if (!strip) sink.put(logger.fataltint);
                                    break sliceswitch;

                                case off:
                                    //goto case 'o';
                                    if (!strip) sink.put(logger.offtint);
                                    break sliceswitch;
                                }
                            }
                            break;
                    }

                    case 'h':
                        i += 3;  // advance past "<h>".length
                        immutable closingHashMarkPos = (cast(T)asBytes[i..$]).indexOf("</>");

                        if (closingHashMarkPos == -1)
                        {
                            // Revert advance
                            i -= 3;
                            goto default;
                        }
                        else
                        {
                            immutable word = cast(string)asBytes[i..i+closingHashMarkPos];

                            version(Colours)
                            {
                                if (!strip)
                                {
                                    import kameloso.terminal.colours : colourByHash;

                                    immutable bright =
                                        cast(Flag!"brightTerminal")kameloso.common.settings.brightTerminal;
                                    sink.put(colourByHash(word, bright));

                                    with (LogLevel)
                                    final switch (baseLevel)
                                    {
                                    case all:  //log
                                        sink.put(logger.logtint);
                                        break;

                                    case trace:
                                        sink.put(logger.tracetint);
                                        break;

                                    case info:
                                        sink.put(logger.infotint);
                                        break;

                                    case warning:
                                        sink.put(logger.warningtint);
                                        break;

                                    case error:
                                        sink.put(logger.errortint);
                                        break;

                                    case critical:
                                        sink.put(logger.criticaltint);
                                        break;

                                    case fatal:
                                        sink.put(logger.fataltint);
                                        break;

                                    case off:
                                        sink.put(logger.offtint);
                                        break;
                                    }
                                }
                                else
                                {
                                    sink.put(word);
                                }
                            }
                            else
                            {
                                sink.put(word);
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

                    i += closingBracketPos;
                }
            }
            break;

        default:
            if (escaping)
            {
                escaping = false;
            }

            if (dirty)
            {
                sink.put(c);
            }
            break;
        }
    }

    return dirty ? sink.data.idup : line;
}

///
unittest
{
    import std.conv : text, to;
    import std.format : format;
    import std.typecons : Flag, No, Yes;

    {
        immutable line = "This is a <l>log</> line.";
        immutable replaced = line.expandTags(No.strip);
        immutable expected = text("This is a ", logger.logtint, "log", logger.offtint, " line.");
        assert((replaced == expected), replaced);
    }
    {
        import std.conv : wtext;

        immutable line = "This is a <l>log</> line."w;
        immutable replaced = line.expandTags(LogLevel.off, No.strip);
        immutable expected = wtext("This is a "w, logger.logtint, "log"w, logger.offtint, " line."w);
        assert((replaced == expected), replaced.to!string);
    }
    {
        import std.conv : dtext;

        immutable line = "This is a <l>log</> line."d;
        immutable replaced = line.expandTags(LogLevel.off, No.strip);
        immutable expected = dtext("This is a "d, logger.logtint, "log"d, logger.offtint, " line."d);
        assert((replaced == expected), replaced.to!string);
    }
    {
        immutable line = `<i>info</>nothing<c>critical</>nothing\<w>not warning`;
        immutable replaced = line.expandTags(LogLevel.off, No.strip);
        immutable expected = text(logger.infotint, "info", logger.offtint, "nothing",
            logger.criticaltint, "critical", logger.offtint, "nothing<w>not warning");
        assert((replaced == expected), replaced);
    }
    {
        immutable line = "This is a line with no tags";
        immutable replaced = line.expandTags(LogLevel.off, No.strip);
        assert(line is replaced);
    }
    {
        immutable emptyLine = string.init;
        immutable replaced = emptyLine.expandTags(LogLevel.off, No.strip);
        assert(replaced is emptyLine);
    }
    {
        immutable line = "hello<h>kameloso</>hello";
        immutable replaced = line.expandTags(LogLevel.off, Yes.strip);
        immutable expected = "hellokamelosohello";
        assert((replaced == expected), replaced);
    }
    {
        immutable line = "hello<h></>hello";
        immutable replaced = line.expandTags(LogLevel.off, Yes.strip);
        immutable expected = "hellohello";
        assert((replaced == expected), replaced);
    }
    {
        immutable line = `hello\<harbl>kameloso<h>hello</>hi`;
        immutable replaced = line.expandTags(LogLevel.off, Yes.strip);
        immutable expected = "hello<harbl>kamelosohellohi";
        assert((replaced == expected), replaced);
    }
    {
        enum pattern = "Failed to fetch, replay and clear notes for " ~
            "<l>%s<e> on <l>%s<e>: <l>%s";
        immutable line = pattern.format("nickname", "<no channel>", "error");
        immutable replaced = line.expandTags(LogLevel.off, No.strip);
        immutable expected = "Failed to fetch, replay and clear notes for " ~
            logger.logtint ~ "nickname" ~ logger.errortint ~ " on " ~ logger.logtint ~
            "<no channel>" ~ logger.errortint ~ ": " ~ logger.logtint ~ "error";
        assert((replaced == expected), replaced);
    }
    {
        enum pattern = "Failed to fetch, replay and clear notes for " ~
            "<l>%s<e> on <l>%s<e>: <l>%s";
        immutable line = pattern.format("nickname", "<no channel>", "error");
        immutable replaced = line.expandTags(LogLevel.off, Yes.strip);
        immutable expected = "Failed to fetch, replay and clear notes for " ~
            "nickname on <no channel>: error";
        assert((replaced == expected), replaced);
    }
    {
        enum pattern = "Failed to fetch, replay and clear notes for " ~
            "<l>%s</> on <l>%s</>: <l>%s";
        immutable line = pattern.format("nickname", "<no channel>", "error");
        immutable replaced = line.expandTags(LogLevel.error, No.strip);
        immutable expected = "Failed to fetch, replay and clear notes for " ~
            logger.logtint ~ "nickname" ~ logger.errortint ~ " on " ~ logger.logtint ~
            "<no channel>" ~ logger.errortint ~ ": " ~ logger.logtint ~ "error";
        assert((replaced == expected), replaced);
    }
    {
        enum pattern = "Failed to fetch, replay and clear notes for " ~
            "<l>%s</> on <l>%s</>: <l>%s";
        immutable line = pattern.format("nickname", "<no channel>", "error");
        immutable replaced = line.expandTags(LogLevel.error, Yes.strip);
        immutable expected = "Failed to fetch, replay and clear notes for " ~
            "nickname on <no channel>: error";
        assert((replaced == expected), replaced);
    }
    {
        enum origPattern = "Could not apply <i>+%s<l> <i>%s<l> in <i>%s<l> " ~
            "because we are not an operator in the channel.";
        enum newPattern = "Could not apply <i>+%s</> <i>%s</> in <i>%s</> " ~
            "because we are not an operator in the channel.";
        immutable origLine = origPattern.format("o", "nickname", "#channel").expandTags(No.strip);
        immutable newLine = newPattern.format("o", "nickname", "#channel").expandTags(LogLevel.all, No.strip);
        assert((origLine == newLine), newLine);
    }

    version(Colours)
    {
        import kameloso.terminal.colours : colourByHash;

        {
            immutable line = "hello<h>kameloso</>hello";
            immutable replaced = line.expandTags(LogLevel.off, No.strip);
            immutable expected = text("hello", colourByHash("kameloso", No.brightTerminal), logger.offtint, "hello");
            assert((replaced == expected), replaced);
        }
        {
            immutable line = `hello\<harbl>kameloso<h>hello</>hi`;
            immutable replaced = line.expandTags(LogLevel.off, No.strip);
            immutable expected = text("hello<harbl>kameloso", colourByHash("hello", No.brightTerminal), logger.offtint, "hi");
            assert((replaced == expected), replaced);
        }
        {
            immutable line = "<l>%%APPDATA%%\\\\kameloso</>.";
            immutable replaced = line.expandTags(LogLevel.off, No.strip);
            immutable expected = logger.logtint ~ "%%APPDATA%%\\kameloso" ~ logger.offtint ~ ".";
            assert((replaced == expected), replaced);
        }
        {
            immutable line = "<l>herp\\</>herp\\\\herp\\\\<l>herp</>";
            immutable replaced = line.expandTags(LogLevel.off, No.strip);
            immutable expected = logger.logtint ~ "herp</>herp\\herp\\" ~ logger.logtint ~ "herp" ~ logger.offtint;
            assert((replaced == expected), replaced);
        }
    }
}


// expandTags
/++
    String-replaces `<tags>` in a string with the results from calls to `Tint`.
    Also works with `dstring`s and `wstring`s. Overload that does not take Overload that does not take a
    `baseLevel` [kameloso.logger.LogLevel|LogLevel] but instead passes a default
    [kameloso.logger.LogLevel.off|LogLevel.off]`.

    Params:
        line = A line of text, presumably with `<tags>`.
        strip = Whether to expand tags or strip them.

    Returns:
        The passsed `line` but with any `<tags>` replaced with ANSI colour sequences.
        The original string is passed back if there was nothing to replace.
 +/
auto expandTags(T)(const T line, const Flag!"strip" strip) @safe
{
    return expandTags(line, LogLevel.off, strip);
}


// expandTags
/++
    String-replaces `<tags>` in a string with the results from calls to `Tint`.
    Also works with `dstring`s and `wstring`s. Overload that does not take a
    `strip` [std.typecons.Flag|Flag], optionally nor a `baseLevel`
    [kameloso.logger.LogLevel|LogLevel], instead passing a default
    [kameloso.logger.LogLevel.off|LogLevel.off]`.

    Params:
        line = A line of text, presumably with `<tags>`.
        baseLevel = The base [kameloso.logger.LogLevel|LogLevel] to fall back to
            on `</>` tags; default [kameloso.logger.LogLevel.off|LogLevel.off].

    Returns:
        The passsed `line` but with any `<tags>` replaced with ANSI colour sequences.
        The original string is passed back if there was nothing to replace.
 +/
auto expandTags(T)(const T line, const LogLevel baseLevel) @safe
{
    static import kameloso.common;
    immutable strip = cast(Flag!"strip")kameloso.common.settings.monochrome;
    return expandTags(line, baseLevel, strip);
}

///
unittest
{
    import std.conv : text, to;

    {
        immutable line = "This is a <l>log</> line.";
        immutable replaced = line.expandTags(LogLevel.off);
        immutable expected = text("This is a ", logger.logtint, "log", logger.offtint, " line.");
        assert((replaced == expected), replaced);
    }
}


version(Colours):

private:

import kameloso.terminal : TerminalToken;
import std.meta : allSatisfy;
import std.range.primitives : isOutputRange;

public:

@safe:

/++
    Format codes that work like terminal colouring does, except here for formats
    like bold, dim, italics, etc.
 +/
enum TerminalFormat
{
    bold        = 1,  /// Bold.
    dim         = 2,  /// Dim, darkens it a bit.
    italics     = 3,  /// Italics; usually has some other effect.
    underlined  = 4,  /// Underlined.
    blink       = 5,  /// Blinking text.
    reverse     = 7,  /// Inverts text foreground and background.
    hidden      = 8,  /// "Hidden" text.
}

/// Foreground colour codes for terminal colouring.
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

/// Background colour codes for terminal colouring.
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

/// Terminal colour/format reset codes.
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


// isAColourCode
/++
    Bool of whether or not a type is a colour code enum.
 +/
enum isAColourCode(T) =
    is(T : TerminalForeground) ||
    is(T : TerminalBackground) ||
    is(T : TerminalFormat) ||
    is(T : TerminalReset);/* ||
    is(T == int);*/


// colour
/++
    Takes a mix of a [TerminalForeground], a [TerminalBackground], a
    [TerminalFormat] and/or a [TerminalReset] and composes them into a single
    terminal format code token. Overload that creates an [std.array.Appender|Appender]
    and fills it with the return value of the output range version of `colour`.

    Example:
    ---
    string blinkOn = colour(TerminalForeground.white, TerminalBackground.yellow, TerminalFormat.blink);
    string blinkOff = colour(TerminalForeground.default_, TerminalBackground.default_, TerminalReset.blink);
    string blinkyName = blinkOn ~ "Foo" ~ blinkOff;
    ---

    Params:
        codes = Variadic list of terminal format codes.

    Returns:
        A terminal code sequence of the passed codes.
 +/
string colour(Codes...)(const Codes codes) pure nothrow
if (Codes.length && allSatisfy!(isAColourCode, Codes))
{
    import std.array : Appender;

    Appender!(char[]) sink;
    sink.reserve(16);

    sink.colourWith(codes);
    return sink.data;
}


// colourWith
/++
    Takes a mix of a [TerminalForeground], a [TerminalBackground], a
    [TerminalFormat] and/or a [TerminalReset] and composes them into a format code token.

    This is the composing overload that fills its result into an output range.

    Example:
    ---
    Appender!(char[]) sink;
    sink.colourWith(TerminalForeground.red, TerminalFormat.bold);
    sink.put("Foo");
    sink.colourWith(TerminalForeground.default_, TerminalReset.bold);
    ---

    Params:
        sink = Output range to write output to.
        codes = Variadic list of terminal format codes.
 +/
void colourWith(Sink, Codes...)(auto ref Sink sink, const Codes codes)
if (isOutputRange!(Sink, char[]) && Codes.length && allSatisfy!(isAColourCode, Codes))
{
    /*sink.put(TerminalToken.format);
    sink.put('[');*/

    enum string prelude = TerminalToken.format ~ "[";
    sink.put(prelude);

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
    Convenience function to colour or format a piece of text without an output
    buffer to fill into.

    Example:
    ---
    string foo = "Foo Bar".colour(TerminalForeground.bold, TerminalFormat.reverse);
    ---

    Params:
        text = Text to format.
        codes = Terminal formatting codes (colour, underscore, bold, ...) to apply.

    Returns:
        A terminal code sequence of the passed codes, encompassing the passed text.
 +/
string colour(Codes...)(const string text, const Codes codes) pure nothrow
if (Codes.length && allSatisfy!(isAColourCode, Codes))
{
    import std.array : Appender;

    Appender!(char[]) sink;
    sink.reserve(text.length + 15);

    sink.colourWith(codes);
    sink.put(text);
    sink.colourWith(TerminalReset.all);
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
private void normaliseColoursBright(ref uint r, ref uint g, ref uint b) pure nothrow @nogc
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
private void normaliseColours(ref uint r, ref uint g, ref uint b) pure nothrow @nogc
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


// truecolour
/++
    Produces a terminal colour token for the colour passed, expressed in terms
    of red, green and blue.

    Example:
    ---
    Appender!(char[]) sink;
    int r, g, b;
    numFromHex("3C507D", r, g, b);
    sink.truecolour(r, g, b);
    sink.put("Foo");
    sink.colourWith(TerminalReset.all);
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
void truecolour(Sink)
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


// truecolour
/++
    Convenience function to colour a piece of text without being passed an
    output sink to fill into.

    Example:
    ---
    string foo = "Foo Bar".truecolour(172, 172, 255);

    int r, g, b;
    numFromHex("003388", r, g, b);
    string bar = "Bar Foo".truecolour(r, g, b);
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
string truecolour(const string word,
    const uint r,
    const uint g,
    const uint b,
    const Flag!"brightTerminal" bright = No.brightTerminal,
    const Flag!"normalise" normalise = Yes.normalise) pure
{
    import std.array : Appender;

    Appender!(char[]) sink;
    // \033[38;2;255;255;255m<word>\033[m
    // \033[48 for background
    sink.reserve(word.length + 23);

    sink.truecolour(r, g, b, bright, normalise);
    sink.put(word);
    sink.colourWith(TerminalReset.all);
    return sink.data;
}

///
unittest
{
    import std.format : format;

    immutable name = "blarbhl".truecolour(255, 255, 255, No.brightTerminal, No.normalise);
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
    writeln(line.invert!(Yes.caseInsensitive)("EXAMPLE")); // "example" inverted as "EXAMPLE"
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

    //assert((startpos != -1), "Tried to invert nonexistent text");
    if (startpos == -1) return line;

    enum pattern = "%c[%dm%s%c[%dm";
    immutable inverted = format(pattern, TerminalToken.format, TerminalFormat.reverse,
        toInvert, TerminalToken.format, TerminalReset.invert);

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
    Hashes the passed string and picks a [TerminalForeground] colour by modulo.
    Overload that takes an array of [TerminalForeground]s, to pick between.

    Params:
        word = String to hash and base colour on.
        fgArray = Array of [TerminalForeground]s to pick a colour from.

    Returns:
        A [TerminalForeground] based on the passed string, picked from the
            passed `fgArray` array.
 +/
TerminalForeground getColourByHash(const string word, const TerminalForeground[] fgArray) pure @nogc nothrow
in (word.length, "Tried to get colour by hash but no word was given")
in (fgArray.length, "Tried to get colour by hash but with an empty colour array")
{
    size_t colourIndex = hashOf(word) % fgArray.length;
    return fgArray[colourIndex];
}

///
unittest
{
    import lu.conv : Enum;

    alias FG = TerminalForeground;

    TerminalForeground[3] fgArray =
    [
        FG.red,
        FG.green,
        FG.blue,
    ];

    {
        immutable foreground = "kameloso".getColourByHash(fgArray[]);
        assert((foreground == FG.blue), Enum!FG.toString(foreground));
    }
    {
        immutable foreground = "zorael".getColourByHash(fgArray[]);
        assert((foreground == FG.green), Enum!FG.toString(foreground));
    }
    {
        immutable foreground = "hirrsteff".getColourByHash(fgArray[]);
        assert((foreground == FG.red), Enum!FG.toString(foreground));
    }
}


// getColourByHash
/++
    Hashes the passed string and picks a [TerminalForeground] colour by modulo.
    Overload that picks any colour, taking care not to pick black or white based on
    the value of the passed `bright` bool (which signifies a bright terminal background).

    Example:
    ---
    immutable nickColour = "kameloso".getColourByHash(No.brightTerminal);
    immutable brightNickColour = "kameloso".getColourByHash(Yes.brightTerminal);
    ---

    Params:
        word = String to hash and base colour on.
        bright = Whether or not the colour should be appropriate for a bright
            terminal background.

    Returns:
        A [TerminalForeground] based on the passed string.
 +/
TerminalForeground getColourByHash(const string word,
    const Flag!"brightTerminal" bright) pure @nogc nothrow
in (word.length, "Tried to get colour by hash but no word was given")
{
    import std.traits : EnumMembers;

    alias foregroundMembers = EnumMembers!TerminalForeground;

    static immutable TerminalForeground[foregroundMembers.length+(-2)] fgBright =
        TerminalForeground.black ~ [ foregroundMembers ][2..$-1];

    static immutable TerminalForeground[foregroundMembers.length+(-2)] fgDark =
        TerminalForeground.white ~ [ foregroundMembers ][2..$-1];

    return bright ? word.getColourByHash(fgBright[]) : word.getColourByHash(fgDark[]);
}

///
unittest
{
    import lu.conv : Enum;

    alias FG = TerminalForeground;

    {
        immutable hash = getColourByHash("kameloso", No.brightTerminal);
        assert((hash == FG.lightyellow), Enum!FG.toString(hash));
    }
    {
        immutable hash = getColourByHash("kameloso^", No.brightTerminal);
        assert((hash == FG.green), Enum!FG.toString(hash));
    }
    {
        immutable hash = getColourByHash("zorael", No.brightTerminal);
        assert((hash == FG.lightgrey), Enum!FG.toString(hash));
    }
    {
        immutable hash = getColourByHash("NO", No.brightTerminal);
        assert((hash == FG.lightred), Enum!FG.toString(hash));
    }
}


// colourByHash
/++
    Shorthand function to colour a passed word by the hash of it.

    Params:
        word = String to colour.
        bright = Whether or not the colour should be adapted for a bright terminal background.

    Returns:
        `word`, now in colour based on the hash of its contents.
 +/
string colourByHash(const string word, const Flag!"brightTerminal" bright) pure nothrow
{
    return word.colour(getColourByHash(word, bright));
}

///
unittest
{
    import std.conv : text;

    {
        immutable coloured = "kameloso".colourByHash(No.brightTerminal);
        assert((coloured == "\033[93mkameloso\033[0m"),
            "kameloso".getColourByHash(No.brightTerminal).text);
    }
    {
        immutable coloured = "kameloso".colourByHash(Yes.brightTerminal);
        assert((coloured == "\033[93mkameloso\033[0m"),
            "kameloso".getColourByHash(Yes.brightTerminal).text);
    }
    {
        immutable coloured = "zorael".colourByHash(No.brightTerminal);
        assert((coloured == "\033[37mzorael\033[0m"),
            "zorael".getColourByHash(No.brightTerminal).text);
    }
    {
        immutable coloured = "NO".colourByHash(No.brightTerminal);
        assert((coloured == "\033[91mNO\033[0m"),
            "NO".getColourByHash(No.brightTerminal).text);
    }
}
