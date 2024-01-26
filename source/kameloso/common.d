/++
    Common functions used throughout the program, generic enough to be used in
    several places, not fitting into any specific one.

    See_Also:
        [kameloso.kameloso],
        [kameloso.main]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.common;

debug version = Debug;

private:

import kameloso.pods : CoreSettings;
import kameloso.logger : KamelosoLogger;
import std.array : Appender;
import std.typecons : Flag, No, Yes;

public:

version(unittest)
static this()
{
    // This is technically before settings have been read.
    // Set some defaults for unit tests.
    .settings.colours = true;
    .settings.brightTerminal = false;
    .settings.headless = false;
    .settings.flush = true;
    .logger = new KamelosoLogger(.settings);
}


// logger
/++
    Instance of a [kameloso.logger.KamelosoLogger|KamelosoLogger], providing
    timestamped and coloured logging.

    The member functions to use are `log`, `trace`, `info`, `warning`, `error`,
    and `fatal`. It is not `__gshared`, so instantiate a thread-local
    [kameloso.logger.KamelosoLogger|KamelosoLogger] if threading.

    Having this here is unfortunate; ideally plugins should not use variables
    from other modules, but unsure of any way to fix this other than to have
    each plugin keep their own [kameloso.common.logger] pointer.
 +/
KamelosoLogger logger;


// settings
/++
    A [kameloso.pods.CoreSettings|CoreSettings] struct global, housing
    certain runtime settings.

    This will be accessed from other parts of the program, via
    [kameloso.common.settings], so they know to use coloured output or not.
    It is a problem that needs solving.
 +/
CoreSettings settings;


// globalAbort
/++
    Abort flag.

    This is set when the program is interrupted (such as via Ctrl+C). Other
    parts of the program will be monitoring it, to take the cue and abort when
    it is set.

    Must be `__gshared` or it doesn't seem to work on Windows.
 +/
__gshared Flag!"abort" globalAbort;


// globalHeadless
/++
    Headless flag.

    If this is true the program should not output anything to the terminal.
 +/
__gshared Flag!"headless" globalHeadless;


// printVersionInfo
/++
    Prints out the bot banner with the version number and GitHub URL, with the
    passed colouring.

    Example:
    ---
    printVersionInfo(Yes.colours);
    ---

    Params:
        colours = Whether or not to tint output, default yes.
 +/
void printVersionInfo(const Flag!"colours" colours = Yes.colours) @safe
{
    import kameloso.common : logger;
    import kameloso.constants : KamelosoInfo;
    import kameloso.logger : LogLevel;
    import kameloso.terminal.colours.tags : expandTags;
    import std.stdio : writefln;

    version(TwitchSupport) enum twitchSupport = " (+twitch)";
    else enum twitchSupport = string.init;

    version(DigitalMars)
    {
        enum colouredVersionPattern = "<l>kameloso IRC bot v%s%s, built with %s (%s) on %s</>";
        enum uncolouredVersionPattern = "kameloso IRC bot v%s%s, built with %s (%s) on %s";
    }
    else
    {
        // ldc or gdc
        enum colouredVersionPattern = "<l>kameloso IRC bot v%s%s, built with %s (based on dmd %s) on %s</>";
        enum uncolouredVersionPattern = "kameloso IRC bot v%s%s, built with %s (based on dmd %s) on %s";
    }

    immutable finalVersionPattern = colours ?
        colouredVersionPattern.expandTags(LogLevel.off) :
        uncolouredVersionPattern;

    writefln(
        finalVersionPattern,
        cast(string)KamelosoInfo.version_,
        twitchSupport,
        cast(string)KamelosoInfo.compiler,
        cast(string)KamelosoInfo.compilerVersion,
        cast(string)KamelosoInfo.built);

    immutable gitClonePattern = colours ?
        "$ git clone <i>%s.git</>".expandTags(LogLevel.off) :
        "$ git clone %s.git";

    writefln(gitClonePattern, cast(string)KamelosoInfo.source);
}


// printStacktrace
/++
    Prints the current stacktrace to the terminal.

    This is so we can get the stacktrace even outside a thrown Exception.
 +/
version(PrintStacktraces)
void printStacktrace() @system
{
    import std.stdio : stdout, writeln;
    import core.runtime : defaultTraceHandler;

    writeln(defaultTraceHandler);
    if (settings.flush) stdout.flush();
}


// OutgoingLine
/++
    A string to be sent to the IRC server, along with whether the message
    should be sent quietly or if it should be displayed in the terminal.
 +/
struct OutgoingLine
{
    /++
        String line to send.
     +/
    string line;

    /++
        Whether this message should be sent quietly or verbosely.
     +/
    bool quiet;

    /++
        Constructor.
     +/
    this(const string line, const Flag!"quiet" quiet = No.quiet) pure @safe nothrow @nogc
    {
        this.line = line;
        this.quiet = quiet;
    }
}


// findURLs
/++
    Finds URLs in a string, returning an array of them. Does not filter out duplicates.

    Replacement for regex matching using much less memory when compiling
    (around ~300mb).

    To consider: does this need a `dstring`?

    Example:
    ---
    // Replaces the following:
    // enum stephenhay = `\bhttps?://[^\s/$.?#].[^\s]*`;
    // static urlRegex = ctRegex!stephenhay;

    string[] urls = findURL("blah https://google.com http://facebook.com httpx://wefpokwe");
    assert(urls.length == 2);
    ---

    Params:
        line = String line to examine and find URLs in.

    Returns:
        A `string[]` array of found URLs. These include fragment identifiers.
 +/
auto findURLs(const string line) @safe pure
{
    import lu.string : advancePast, stripped, strippedRight;
    import std.string : indexOf;
    import std.typecons : Flag, No, Yes;

    enum wordBoundaryTokens = ".,!?:";
    enum minimumPossibleLinkLength = "http://a.se".length;

    string slice = line.stripped;  // mutable
    if (slice.length < minimumPossibleLinkLength) return null;

    string[] hits;
    ptrdiff_t httpPos = slice.indexOf("http");

    while (httpPos != -1)
    {
        if ((httpPos > 0) && (slice[httpPos-1] != ' '))
        {
            // Run-on http address (character before the 'h')
            slice = slice[httpPos+4..$];
            httpPos = slice.indexOf("http");
            continue;
        }

        slice = slice[httpPos..$];

        if (slice.length < minimumPossibleLinkLength)
        {
            // Too short, minimum is "http://a.se".length
            break;
        }
        else if ((slice[4] != ':') && (slice[4] != 's'))
        {
            // Not http or https, something else
            // But could still be another link after this
            slice = slice[5..$];
            httpPos = slice.indexOf("http");
            continue;
        }
        else if ((slice[7] == ' ') || (slice[8] == ' '))
        {
            slice = slice[7..$];
            httpPos = slice.indexOf("http");
            continue;
        }
        else if (
            (slice.indexOf(' ') == -1) &&
            ((slice[10..$].indexOf("http://") != -1) ||
            (slice[10..$].indexOf("https://") != -1)))
        {
            // There is a second URL in the middle of this one
            break;
        }

        // advancePast until the next space if there is one, otherwise just inherit slice
        // Also strip away common punctuation
        immutable hit = slice
            .advancePast(' ', Yes.inherit)
            .strippedRight(wordBoundaryTokens);
        if (hit.indexOf('.') != -1) hits ~= hit;
        httpPos = slice.indexOf("http");
    }

    return hits;
}

///
unittest
{
    import std.conv : to;

    {
        const urls = findURLs("http://google.com");
        assert((urls.length == 1), urls.to!string);
        assert((urls[0] == "http://google.com"), urls[0]);
    }
    {
        const urls = findURLs("blah https://a.com http://b.com shttps://c https://d.asdf.asdf.asdf        ");
        assert((urls.length == 3), urls.to!string);
        assert((urls == [ "https://a.com", "http://b.com", "https://d.asdf.asdf.asdf" ]), urls.to!string);
    }
    {
        const urls = findURLs("http:// http://asdf https:// asdfhttpasdf http://google.com");
        assert((urls.length == 1), urls.to!string);
    }
    {
        const urls = findURLs("http://a.sehttp://a.shttp://a.http://http:");
        assert(!urls.length, urls.to!string);
    }
    {
        const urls = findURLs("blahblah https://motorbörsen.se blhblah");
        assert(urls.length, urls.to!string);
    }
    {
        // Let dlang-requests attempt complex URLs, don't validate more than necessary
        const urls = findURLs("blahblah https://高所恐怖症。co.jp blhblah");
        assert(urls.length, urls.to!string);
    }
    {
        const urls = findURLs("nyaa is now at https://nyaa.si, https://nyaa.si? " ~
            "https://nyaa.si. https://nyaa.si! and you should use it https://nyaa.si:");

        foreach (immutable url; urls)
        {
            assert((url == "https://nyaa.si"), url);
        }
    }
    {
        const urls = findURLs("https://google.se httpx://google.se https://google.se");
        assert((urls == [ "https://google.se", "https://google.se" ]), urls.to!string);
    }
    {
        const urls = findURLs("https://               ");
        assert(!urls.length, urls.to!string);
    }
    {
        const urls = findURLs("http://               ");
        assert(!urls.length, urls.to!string);
    }
}


version(GCStatsOnExit) version = BuildPrintGCStats;
else version(Debug) version = BuildPrintGCStats;


// printGCStats
/++
    Prints garbage collector statistics to the local terminal.

    Gated behind either version `GCStatsOnExit` *or* `IncludeHeavyStuff`.
 +/
version(BuildPrintGCStats)
void printGCStats()
{
    import core.memory : GC;

    immutable stats = GC.stats();

    static if (__VERSION__ >= 2087L)
    {
        enum pattern = "Lifetime allocated in current thread: <l>%,d</> bytes";
        logger.infof(pattern, stats.allocatedInCurrentThread);
    }

    enum memoryUsedPattern = "Memory currently in use: <l>%,d</> bytes; " ~
        "<l>%,d</> additional bytes reserved";
    logger.infof(memoryUsedPattern, stats.usedSize, stats.freeSize);
}


// assertMultilineOpEquals
/++
    Asserts that two multiline strings are equal, with a more detailed error
    message than the default `assert`.

    Params:
        actual = Actual string.
        expected = Expected string.
 +/
version(unittest)
void assertMultilineOpEquals(
    const(char[]) actual,
    const(char[]) expected,
    const string file = __FILE__,
    const uint line = __LINE__) pure @safe
{
    import std.algorithm.iteration : splitter;
    import std.conv : text;
    import std.format : format;
    import std.range : StoppingPolicy, repeat, zip;
    import std.utf : replacementDchar;

    if (actual == expected) return;

    auto expectedRange = expected.splitter("\n");
    auto actualRange = actual.splitter("\n");
    auto lineRange = zip(StoppingPolicy.longest, expectedRange, actualRange);
    uint lineNumber;

    foreach (const expectedLine, const actualLine; lineRange)
    {
        ++lineNumber;

        auto charRange = zip(StoppingPolicy.longest, expectedLine, actualLine);
        uint linePos;

        foreach (const expectedChar, const actualChar; charRange)
        {
            ++linePos;

            if (actualChar == expectedChar) continue;

            enum EOL = 65_535;
            immutable expectedCharString = (expectedChar != EOL) ?
                text('\'', expectedChar, '\'') :
                "EOL";
            immutable expectedCharValueString = (expectedChar != EOL) ?
                text('(', cast(uint)expectedChar, ')') :
                string.init;
            immutable actualCharString = (actualChar != EOL) ?
                text('\'', actualChar, '\'') :
                "EOL";
            immutable actualCharValueString = (actualChar != EOL) ?
                text('(', cast(uint)actualChar, ')') :
                string.init;
            immutable arrow = text(' '.repeat(linePos-1), '^');

            enum pattern = `
Line mismatch at %s:%d, block %d:%d; expected %s%s was %s%s
expected:"%s"
  actual:"%s"
          %s`;
            immutable message = pattern
                .format(
                    file,
                    line,
                    lineNumber,
                    linePos,
                    expectedCharString,
                    expectedCharValueString,
                    actualCharString,
                    actualCharValueString,
                    expectedLine,
                    actualLine,
                    arrow);
            assert(0, message);
        }
    }
}

///
version(none)
unittest
{
    enum actual =
"abc
def
ghi";

    enum expected =
"abc
deF
ghi";

    assertMultilineOpEquals(actual, expected);

/+
core.exception.AssertError@file.d(123):
Line mismatch at file.d:456, block 2:3; expected 'F'(70) was 'f'(102)
expected:"deF"
  actual:"def"
            ^
 +/
}


// zero
/++
    Zeroes out the contents of an [std.array.Appender|Appender].

    Params:
        sink = The [std.array.Appender|Appender] to zero out.
        clear = (Optional) Whether to also call the `.clear()` method of the
            [std.array.Appender|Appender] sink.
        zeroValue = (Optional) The value to zero out the contents with.
 +/
void zero(Sink : Appender!(T[]), T)
    (ref Sink sink,
    const Flag!"clear" clear = Yes.clear,
    T zeroValue = T.init)
{
    foreach (ref thing; sink.data)
    {
        thing = zeroValue;
    }

    if (clear) sink.clear();
}

///
unittest
{
    {
        Appender!(char[]) sink;
        sink.put('a');
        sink.put('b');
        sink.put('c');
        assert(sink.data == ['a', 'b', 'c']);

        sink.zero(No.clear);
        assert(sink.data == [ 255, 255, 255 ]);

        sink.put('d');
        assert(sink.data == [ 255, 255, 255, 'd' ]);

        sink.zero(No.clear, 'X');
        assert(sink.data == [ 'X', 'X', 'X', 'X' ]);

        sink.zero(Yes.clear);
        assert(!sink.data.length);
    }
    {
        Appender!(string[]) sink;
        sink.put("abc");
        sink.put("def");
        sink.put("ghi");
        assert(sink.data == [ "abc", "def", "ghi" ]);

        sink.zero(No.clear, "(empty)");
        assert(sink.data == [ "(empty)", "(empty)", "(empty)" ]);

        sink.zero(No.clear);
        assert(sink.data == [ string.init, string.init, string.init ]);

        sink.zero(Yes.clear);
        assert(!sink.data.length);
    }
}
