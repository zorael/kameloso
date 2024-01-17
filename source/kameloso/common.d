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
    import lu.string : advancePast, strippedRight;
    import std.string : indexOf;
    import std.typecons : Flag, No, Yes;

    enum wordBoundaryTokens = ".,!?:";

    string[] hits;
    string slice = line;  // mutable

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

        if (slice.length < 11)
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
        immutable hit = slice.advancePast(' ', Yes.inherit).strippedRight(wordBoundaryTokens);
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


// errnoStrings
/++
    Reverse mapping of [core.stdc.errno.errno|errno] values to their string names.

    Automatically generated by introspecting [core.stdc.errno].

    ---
    string[134] errnoStrings;

    foreach (immutable symname; __traits(allMembers, core.stdc.errno))
    {
        static if (symname[0] == 'E')
        {
            immutable idx = __traits(getMember, core.stdc.errno, symname);

            if (errnoStrings[idx].length)
            {
                writefln("%s DUPLICATE %d", symname, idx);
            }
            else
            {
                errnoStrings[idx] = symname;
            }
        }
    }

    writeln("static immutable string[134] errnoStrings =\n[");

    foreach (immutable i, immutable e; errnoStrings)
    {
        if (!e.length) continue;
        writefln(`    %-3d : "%s",`, i, e);
    }

    writeln("];");
    ---
 +/
version(Posix)
static immutable string[134] errnoStrings =
[
    0   : "<unset>",
    1   : "EPERM",
    2   : "ENOENT",
    3   : "ESRCH",
    4   : "EINTR",
    5   : "EIO",
    6   : "ENXIO",
    7   : "E2BIG",
    8   : "ENOEXEC",
    9   : "EBADF",
    10  : "ECHILD",
    11  : "EAGAIN",  // duplicate EWOULDBLOCK
    12  : "ENOMEM",
    13  : "EACCES",
    14  : "EFAULT",
    15  : "ENOTBLK",
    16  : "EBUSY",
    17  : "EEXIST",
    18  : "EXDEV",
    19  : "ENODEV",
    20  : "ENOTDIR",
    21  : "EISDIR",
    22  : "EINVAL",
    23  : "ENFILE",
    24  : "EMFILE",
    25  : "ENOTTY",
    26  : "ETXTBSY",
    27  : "EFBIG",
    28  : "ENOSPC",
    29  : "ESPIPE",
    30  : "EROFS",
    31  : "EMLINK",
    32  : "EPIPE",
    33  : "EDOM",
    34  : "ERANGE",
    35  : "EDEADLK",  // duplicate EDEADLOCK
    36  : "ENAMETOOLONG",
    37  : "ENOLCK",
    38  : "ENOSYS",
    39  : "ENOTEMPTY",
    40  : "ELOOP",
    42  : "ENOMSG",
    43  : "EIDRM",
    44  : "ECHRNG",
    45  : "EL2NSYNC",
    46  : "EL3HLT",
    47  : "EL3RST",
    48  : "ELNRNG",
    49  : "EUNATCH",
    50  : "ENOCSI",
    51  : "EL2HLT",
    52  : "EBADE",
    53  : "EBADR",
    54  : "EXFULL",
    55  : "ENOANO",
    56  : "EBADRQC",
    57  : "EBADSLT",
    59  : "EBFONT",
    60  : "ENOSTR",
    61  : "ENODATA",
    62  : "ETIME",
    63  : "ENOSR",
    64  : "ENONET",
    65  : "ENOPKG",
    66  : "EREMOTE",
    67  : "ENOLINK",
    68  : "EADV",
    69  : "ESRMNT",
    70  : "ECOMM",
    71  : "EPROTO",
    72  : "EMULTIHOP",
    73  : "EDOTDOT",
    74  : "EBADMSG",
    75  : "EOVERFLOW",
    76  : "ENOTUNIQ",
    77  : "EBADFD",
    78  : "EREMCHG",
    79  : "ELIBACC",
    80  : "ELIBBAD",
    81  : "ELIBSCN",
    82  : "ELIBMAX",
    83  : "ELIBEXEC",
    84  : "EILSEQ",
    85  : "ERESTART",
    86  : "ESTRPIPE",
    87  : "EUSERS",
    88  : "ENOTSOCK",
    89  : "EDESTADDRREQ",
    90  : "EMSGSIZE",
    91  : "EPROTOTYPE",
    92  : "ENOPROTOOPT",
    93  : "EPROTONOSUPPORT",
    94  : "ESOCKTNOSUPPORT",
    95  : "EOPNOTSUPP",  // duplicate ENOTSUPP
    96  : "EPFNOSUPPORT",
    97  : "EAFNOSUPPORT",
    98  : "EADDRINUSE",
    99  : "EADDRNOTAVAIL",
    100 : "ENETDOWN",
    101 : "ENETUNREACH",
    102 : "ENETRESET",
    103 : "ECONNABORTED",
    104 : "ECONNRESET",
    105 : "ENOBUFS",
    106 : "EISCONN",
    107 : "ENOTCONN",
    108 : "ESHUTDOWN",
    109 : "ETOOMANYREFS",
    110 : "ETIMEDOUT",
    111 : "ECONNREFUSED",
    112 : "EHOSTDOWN",
    113 : "EHOSTUNREACH",
    114 : "EALREADY",
    115 : "EINPROGRESS",
    116 : "ESTALE",
    117 : "EUCLEAN",
    118 : "ENOTNAM",
    119 : "ENAVAIL",
    120 : "EISNAM",
    121 : "EREMOTEIO",
    122 : "EDQUOT",
    123 : "ENOMEDIUM",
    124 : "EMEDIUMTYPE",
    125 : "ECANCELED",
    126 : "ENOKEY",
    127 : "EKEYEXPIRED",
    128 : "EKEYREVOKED",
    129 : "EKEYREJECTED",
    130 : "EOWNERDEAD",
    131 : "ENOTRECOVERABLE",
    132 : "ERFKILL",
    133 : "EHWPOISON",
];


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


// getHTTPResponseCodeText
/++
    Returns the text associated with an HTTP response code.

    Params:
        code = HTTP response code.

    Returns:
        The text associated with the HTTP response code, or "(Unknown HTTP
        response)" if the code is not recognized.
 +/
auto getHTTPResponseCodeText(const uint code)
{
    switch (code)
    {
    case 0:
        return "(unset)";

    case 1:
    ..
    case 5:
        return "SSL library error";

    case 100: return "Continue";
    case 101: return "Switching Protocols";
    case 102: return "Processing";
    case 103: return "Early Hints";

    case 200: return "OK";
    case 201: return "Created";
    case 202: return "Accepted";
    case 203: return "Non-Authoritative Information";
    case 204: return "No Content";
    case 205: return "Reset Content";
    case 206: return "Partial Content";
    case 207: return "Multi-Status";
    case 208: return "Already Reported";
    case 226: return "IM Used";

    case 300: return "Multiple Choices";
    case 301: return "Moved Permanently";
    case 302: return "Found";
    case 303: return "See Other";
    case 304: return "Not Modified";
    case 305: return "Use Proxy";
    case 306: return "Switch Proxy";
    case 307: return "Temporary Redirect";
    case 308: return "Permanent Redirect";

    case 400: return "Bad Request";
    case 401: return "Unauthorized";
    case 402: return "Payment Required";
    case 403: return "Forbidden";
    case 404: return "Not Found";
    case 405: return "Method Not Allowed";
    case 406: return "Not Acceptable";
    case 407: return "Proxy Authentication Required";
    case 408: return "Request Timeout";
    case 409: return "Conflict";
    case 410: return "Gone";
    case 411: return "Length Required";
    case 412: return "Precondition Failed";
    case 413: return "Payload Too Large";
    case 414: return "URI Too Long";
    case 415: return "Unsupported Media Type";
    case 416: return "Range Not Satisfiable";
    case 417: return "Expectation Failed";
    case 418: return "I'm a teapot";
    case 421: return "Misdirected Request";
    case 422: return "Unprocessable Entity";
    case 423: return "Locked";
    case 424: return "Failed Dependency";
    case 425: return "Too Early";
    case 426: return "Upgrade Required";
    case 428: return "Precondition Required";
    case 429: return "Too Many Requests";
    case 431: return "Request Header Fields Too Large";
    case 451: return "Unavailable For Legal Reasons";

    case 500: return "Internal Server Error";
    case 501: return "Not Implemented";
    case 502: return "Bad Gateway";
    case 503: return "Service Unavailable";
    case 504: return "Gateway Timeout";
    case 505: return "HTTP Version Not Supported";
    case 506: return "Variant Also Negotiates";
    case 507: return "Insufficient Storage";
    case 508: return "Loop Detected";
    case 510: return "Not Extended";
    case 511: return "Network Authentication Required";

    case 218: return "This is fine";
    case 419: return "Page Expired";
    //case 420: return "Method Failure";
    case 420: return "Enhance your calm";
    //case 430: return "Request Header Fields Too Large";
    case 430: return "Shopify Security Rejection";
    case 450: return "Blocked by Windows Parental Controls";
    case 498: return "Invalid Token";
    case 499: return "Token Required";
    case 509: return "Bandwidth Limit Exceeded";
    case 529: return "Site is overloaded";
    //case 530: return "Site is frozen";
    case 530: return "Origin DNS Error";
    case 540: return "Temporarily Disabled";
    case 598: return "Network Rea Timeout Error";
    case 599: return "Network Connect Timeout Error";
    case 783: return "Unexpected Token";

    case 440: return "Login Timeout";
    case 449: return "Retry With";
    //case 451: return "Redirect";

    case 444: return "No Response";
    case 494: return "Request Header Too Large";
    case 495: return "SSL Certificate Error";
    case 496: return "SSL Certificate Required";
    case 497: return "HTTP Request Sent to HTTPS Port";
    //case 499: return "Client Closed Request";

    case 520: return "Web Server Returned an Unknown Error";
    case 521: return "Web Server Is Down";
    case 522: return "Connection Timed Out";
    case 523: return "Origin Is Unreachable";
    case 524: return "A Timeout Occurred";
    case 525: return "SSL Handshake Failed";
    case 526: return "Invalid SSL Certificate";
    case 527: return "Railgun Error";
    //case 530: return "(no text)";

    case 460: return "Client Closed Connection";
    case 463: return "Too Many IP Addresses";
    case 464: return "Incompatible Protocol";

    case 110: return "Response is Stale";
    case 111: return "Revalidation Failed";
    case 112: return "Disconnected Operation";
    case 113: return "Heuristic Expiration";
    case 199: return "Miscellaneous Warning";
    case 214: return "Transformation Applied";
    case 299: return "Miscellaneous Persistent Warning";

    default: return "(Unknown HTTP response)";
    }
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
