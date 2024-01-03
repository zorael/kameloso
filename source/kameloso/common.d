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
import dialect.defs : IRCClient;
import std.range.primitives : isOutputRange;
import std.traits : isIntegral;
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


// RehashingAA
/++
    A wrapper around a native associative array that you can controllably set to
    automatically rehash as entries are added.

    Params:
        AA = Associative array type.
        V = Value type.
        K = Key type.
 +/
struct RehashingAA(AA : V[K], V, K)
{
private:
    /++
        Internal associative array.
     +/
    AA aa;

    /++
        The number of times this instance has rehashed itself. Private value.
     +/
    uint _numRehashes;

    /++
        The number of new entries that has been added since the last rehash. Private value.
     +/
    uint _newKeysSinceLastRehash;

    /++
        The number of keys (and length of the array) when the last rehash took place.
        Private value.
     +/
    size_t _lengthAtLastRehash;

public:
    /++
        The minimum number of additions needed before the first rehash takes place.
     +/
    uint minimumNeededForRehash = 64;

    /++
        The modifier by how much more entries must be added before another rehash
        takes place, with regards to the current [RehashingAA.aa|aa] length.

        A multiplier of `2.0` means the associative array will be rehashed as
        soon as its length doubles in size. Must be more than 1.
     +/
    double rehashThresholdMultiplier = 1.5;

    // opIndexAssign
    /++
        Assigns a value into the internal associative array. If it created a new
        entry, then call [maybeRehash] to bump the internal counter and maybe rehash.

        Params:
            value = Value.
            key = Key.
     +/
    void opIndexAssign(V value, K key)
    {
        if (auto existing = key in aa)
        {
            *existing = value;
        }
        else
        {
            aa[key] = value;
            maybeRehash();
        }
    }

    // opAssign
    /++
        Inherit a native associative array into [RehashingAA.aa|aa].

        Params:
            aa = Other associative array.
     +/
    void opAssign(V[K] aa)
    {
        this.aa = aa;
        this.rehash();
        _numRehashes = 0;
    }

    // opCast
    /++
        Allows for casting this into the base associative array type.

        Params:
            T = Type to cast to, here the same as the type of [RehashingAA.aa|aa].

        Returns:
            The internal associative array.
     +/
    auto opCast(T : AA)() inout
    {
        return aa;
    }

    // aaOf
    /++
        Returns the internal associative array, for when the wrapper is insufficient.

        Returns:
            The internal associative array.
     +/
    auto aaOf() inout
    {
        return aa;
    }

    // remove
    /++
        Removes a key from the [RehashingAA.aa|aa] associative array by merely
        invoking `.remove`.

        Params:
            key = The key to remove.

        Returns:
            Whatever `aa.remove(key)` returns.
     +/
    auto remove(K key)
    {
        //scope(exit) maybeRehash();
        return aa.remove(key);
    }

    // maybeRehash
    /++
        Bumps the internal counter of new keys since the last rehash, and depending
        on the resulting value of it, maybe rehashes.

        Returns:
            `true` if the associative array was rehashed; `false` if not.
     +/
    auto maybeRehash()
    {
        if (++_newKeysSinceLastRehash > minimumNeededForRehash)
        {
            if (aa.length > (_lengthAtLastRehash * rehashThresholdMultiplier))
            {
                this.rehash();
                return true;
            }
        }

        return false;
    }

    // clear
    /++
        Clears the internal associative array and all counters.
     +/
    void clear()
    {
        aa.clear();
        _newKeysSinceLastRehash = 0;
        _lengthAtLastRehash = 0;
        _numRehashes = 0;
    }

    // rehash
    /++
        Rehashes the internal associative array, bumping the rehash counter and
        zeroing the keys-added counter. Additionally invokes the [onRehashDg] delegate.

        Returns:
            A reference to the rehashed internal array.
     +/
    ref auto rehash()
    {
        scope(exit) if (onRehashDg) onRehashDg();
        _lengthAtLastRehash = aa.length;
        _newKeysSinceLastRehash = 0;
        ++_numRehashes;
        aa.rehash();
        return this;
    }

    // numRehashes
    /++
        The number of times this instance has rehashed itself. Accessor.

        Returns:
            The number of times this instance has rehashed itself.
     +/
    auto numRehashes() const inout
    {
        return _numRehashes;
    }

    // numKeysAddedSinceLastRehash
    /++
        The number of new entries that has been added since the last rehash. Accessor.

        Returns:
            The number of new entries that has been added since the last rehash.
     +/
    auto newKeysSinceLastRehash() const
    {
        return _newKeysSinceLastRehash;
    }

    // opBinaryRight
    /++
        Wraps `key in aa` to the internal associative array.

        Params:
            op = Operation, here "in".
            key = Key.

        Returns:
            A pointer to the value of the key passed, or `null` if it isn't in
            the associative array
     +/
    auto opBinaryRight(string op : "in")(K key) inout
    {
        return key in aa;
    }

    // length
    /++
        Returns the length of the internal associative array.

        Returns:
            The length of the internal associative array.
     +/
    auto length() const inout
    {
        return aa.length;
    }

    // dup
    /++
        Duplicates this. Explicitly copies the internal associative array.

        Returns:
            A duplicate of this object.
     +/
    auto dup()
    {
        auto copy = this;
        copy.aa = copy.aa.dup;
        return copy;
    }

    // this
    /++
        Constructor.

        Params:
            aa = Associative arary to inherit. Taken by reference for now.
     +/
    this(AA aa) pure @safe nothrow @nogc
    {
        this.aa = aa;
    }

    // onRehashDg
    /++
        Delegate called when rehashing takes place.
     +/
    void delegate() onRehashDg;
}

///
unittest
{
    import std.conv : to;

    RehashingAA!(int[string]) aa;
    aa.minimumNeededForRehash = 2;

    aa["abc"] = 123;
    aa["def"] = 456;
    assert((aa.newKeysSinceLastRehash == 2), aa.newKeysSinceLastRehash.to!string);
    assert((aa.numRehashes == 0), aa.numRehashes.to!string);
    aa["ghi"] = 789;
    assert((aa.numRehashes == 1), aa.numRehashes.to!string);
    assert((aa.newKeysSinceLastRehash == 0), aa.newKeysSinceLastRehash.to!string);
    aa.rehash();
    assert((aa.numRehashes == 2), aa.numRehashes.to!string);

    auto realAA = cast(int[string])aa;
    assert("abc" in realAA);
    assert("def" in realAA);

    auto alsoRealAA = aa.aaOf;
    assert("ghi" in realAA);
    assert("jkl" !in realAA);

    auto aa2 = aa.dup;
    aa2["jkl"] = 123;
    assert("jkl" in aa2);
    assert("jkl" !in aa);
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


// uniqueKey
/++
    Returns a unique key for the passed associative array.
    Reserves the key by assigning it a value.

    Params:
        aa = Associative array to get a unique key for.
        min = Optional minimum key value; defaults to `1``.
        max = Optional maximum key value; defaults to `K.max`, where `K` is the
            key type of the passed associative array.
        value = Optional value to assign to the key; defaults to `V.init`, where
            `V` is the value type of the passed associative array.

    Returns:
        A unique key for the passed associative array.
 +/
auto uniqueKey(AA : V[K], V, K)
    (auto ref AA aa,
    K min = 1,
    K max = K.max,
    V value = V.init)
if (isIntegral!K)
{
    import std.random : uniform;

    auto id = uniform(min, max);  // mutable
    while (id in aa) id = uniform(min, max);

    aa[id] = value;  // reserve it
    return id;
}

///
unittest
{
    import std.conv : to;

    {
        string[int] aa;
        immutable key = aa.uniqueKey;
        assert(key in aa);
    }
    {
        long[long] aa;
        immutable key = aa.uniqueKey;
        assert(key in aa);
    }
    {
        shared bool[int] aa;
        immutable key = aa.uniqueKey;
        assert(key in aa);
    }
    {
        int[int] aa;
        immutable key = aa.uniqueKey(5, 6, 42);
        assert(key == 5);
        assert((aa[5] == 42), aa[5].to!string);
    }
}


// MutexedAA
/++
    An associative array and a [core.sync.mutex.Mutex|Mutex]. Wraps associative
    array operations in mutex locks.

    Example:
    ---
    MutexedAA!(string[int]) aa;
    aa.setup();  // important!

    aa[1] = "one";
    aa[2] = "two";
    aa[3] = "three";

    auto hasOne = aa.has(1);
    assert(hasOne);
    assert(aa[1] == "one");

    assert(aa[2] == "two");

    auto three = aa.get(3);
    assert(three == "three");

    auto four = aa.get(4, "four");
    assert(four == "four");

    auto five = aa.require(5, "five");
    assert(five == "five");
    assert(aa[5] == "five");

    auto keys = aa.keys;
    assert(keys.canFind(1));
    assert(keys.canFind(5));
    assert(!keys.canFind(6));

    auto values = aa.values;
    assert(values.canFind("one"));
    assert(values.canFind("four"));
    assert(!values.canFind("six"));

    aa.rehash();
    ---

    Params:
        AA = Associative array type.
        V = Value type.
        K = Key type.
 +/
struct MutexedAA(AA : V[K], V, K)
{
private:
    import std.range.primitives : ElementEncodingType;
    import core.sync.mutex : Mutex;

    /++
        [core.sync.mutex.Mutex|Mutex] to lock the associative array with.
     +/
    shared Mutex mutex;

public:
    /++
        The internal associative array.
     +/
    shared AA aa;

    /++
        Sets up this instance. Does nothing if it has already been set up.

        Instantiates the [mutex] and minimally initialises the associative array
        by assigning and removing a dummy value.
     +/
    void setup() nothrow
    {
        if (mutex) return;

        mutex = new shared Mutex;
        mutex.lock_nothrow();

        if (K.init !in cast(AA)aa)
        {
            (cast(AA)aa)[K.init] = V.init;
            (cast(AA)aa).remove(K.init);
        }

        mutex.unlock_nothrow();
    }

    /++
        Returns whether or not this instance has been set up.

        Returns:
            Whether or not the [mutex] was instantiated, and thus whether this
            instance has been set up.
     +/
    auto isReady()
    {
        return (mutex !is null);
    }

    /++
        `aa[key] = value` array assign operation, wrapped in a mutex lock.

        Example:
        ---
        MutexedAA!(string[int]) aa;
        aa.setup();  // important!

        aa[1] = "one";
        aa[2] = "two";
        ---

        Params:
            value = Value.
            key = Key.

        Returns:
            The value assigned.
     +/
    auto opIndexAssign(V value, K key)
    in (mutex, typeof(this).stringof ~ " has null Mutex")
    {
        mutex.lock_nothrow();
        (cast(AA)aa)[key] = value;
        mutex.unlock_nothrow();
        return value;
    }

    /++
        `aa[key]` array retrieve operation, wrapped in a mutex lock.

        Example:
        ---
        MutexedAA!(string[int]) aa;
        aa.setup();  // important!

        // ...

        string one = aa[1];
        writeln(aa[2]);
        ---

        Params:
            key = Key.

        Returns:
            The value assigned.
     +/
    auto opIndex(K key)
    in (mutex, typeof(this).stringof ~ " has null Mutex")
    {
        mutex.lock_nothrow();
        auto value = (cast(AA)aa)[key];
        mutex.unlock_nothrow();
        return value;
    }

    /++
        Returns whether or not the passed key is in the associative array.

        Example:
        ---
        MutexedAA!(string[int]) aa;
        aa.setup();  // important!

        aa[1] = "one";
        assert(aa.has(1));
        ---

        Params:
            key = Key.

        Returns:
            `true` if the key is in the associative array; `false` if not.
     +/
    auto has(K key)
    in (mutex, typeof(this).stringof ~ " has null Mutex")
    {
        mutex.lock_nothrow();
        auto exists = (key in cast(AA)aa) !is null;
        mutex.unlock_nothrow();
        return exists;
    }

    /++
        `aa.remove(key)` array operation, wrapped in a mutex lock.

        Example:
        ---
        MutexedAA!(string[int]) aa;
        aa.setup();  // important!

        aa[1] = "one";
        assert(aa.has(1));

        aa.remove(1);
        assert(!aa.has(1));
        ---

        Params:
            key = Key.

        Returns:
            Whatever `aa.remove(key)` returns.
     +/
    auto remove(K key)
    in (mutex, typeof(this).stringof ~ " has null Mutex")
    {
        mutex.lock_nothrow();
        auto value = (cast(AA)aa).remove(key);
        mutex.unlock_nothrow();
        return value;
    }

    /++
        Reserves a unique key in the associative array.

        Note: The key type must be an integral type.

        Example:
        ---
        MutexedAA!(string[int]) aa;
        aa.setup();  // important!

        int i = aa.uniqueKey;
        assert(i > 0);
        assert(aa.has(i));
        assert(aa[i] == string.init);
        ---

        Params:
            min = Optional minimum key value; defaults to `1``.
            max = Optional maximum key value; defaults to `K.max`, where `K` is
                the key type of the passed associative array.
            value = Optional value to assign to the key; defaults to `V.init`,
                where `V` is the value type of the passed associative array.

        Returns:
            A unique key for the passed associative array, for which there is now
            a value of `value`.`

        See_Also:
            [uniqueKey]
     +/
    auto uniqueKey()
        (K min = 1,
        K max = K.max,
        V value = V.init)
    if (isIntegral!K)
    in (mutex, typeof(this).stringof ~ " has null Mutex")
    {
        mutex.lock_nothrow();
        auto key = .uniqueKey(cast(AA)aa, min, max, value);
        mutex.unlock_nothrow();
        return key;
    }

    /++
        Implements `opEquals` for this type, comparing the internal associative
        array with that of another `MutexedAA`.

        Example:
        ---
        MutexedAA!(string[int]) aa1;
        aa1.setup();  // important!
        aa1[1] = "one";

        MutexedAA!(string[int]) aa2;
        aa2.setup();  // as above
        aa2[1] = "one";
        assert(aa1 == aa2);

        aa2[2] = "two";
        assert(aa1 != aa2);

        aa1[2] = "two";
        assert(aa1 == aa2);
        ---

        Params:
            other = Other `MutexedAA` whose internal associative array to compare
                with the one of this instance.

        Returns:
            `true` if the internal associative arrays are equal; `false` if not.
     +/
    auto opEquals(typeof(this) other)
    in (mutex, typeof(this).stringof ~ " has null Mutex")
    {
        mutex.lock_nothrow();
        auto isEqual = (cast(AA)aa == cast(AA)(other.aa));
        mutex.unlock_nothrow();
        return isEqual;
    }

    /++
        Implements `opEquals` for this type, comparing the internal associative
        array with a different one.

        Example:
        ---
        MutexedAA!(string[int]) aa1;
        aa1.setup();  // important!
        aa1[1] = "one";
        aa1[2] = "two";

        string[int] aa2;
        aa2[1] = "one";

        assert(aa1 != aa2);

        aa2[2] = "two";
        assert(aa1 == aa2);
        ---

        Params:
            other = Other associative array to compare the internal one with.

        Returns:
            `true` if the internal associative arrays are equal; `false` if not.
     +/
    auto opEquals(AA other)
    in (mutex, typeof(this).stringof ~ " has null Mutex")
    {
        mutex.lock_nothrow();
        auto isEqual = (cast(AA)aa == other);
        mutex.unlock_nothrow();
        return isEqual;
    }

    /++
        Rehashes the internal associative array.

        Example:
        ---
        MutexedAA!(string[int]) aa;
        aa.setup();  // important!

        aa[1] = "one";
        aa[2] = "two";
        aa.rehash();
        ---

        Returns:
            A reference to the rehashed internal array.
     +/
    auto rehash()
    in (mutex, typeof(this).stringof ~ " has null Mutex")
    {
        mutex.lock_nothrow();
        auto rehashed = (cast(AA)aa).rehash();
        mutex.unlock_nothrow();
        return rehashed;
    }

    /++
        Clears the internal associative array.

        Example:
        ---
        MutexedAA!(string[int]) aa;
        aa.setup();  // important!

        aa[1] = "one";
        aa[2] = "two";
        assert(aa.has(1));

        aa.clear();
        assert(!aa.has(2));
        ---
     +/
    void clear()
    in (mutex, typeof(this).stringof ~ " has null Mutex")
    {
        mutex.lock_nothrow();
        (cast(AA)aa).clear();
        mutex.unlock_nothrow();
    }

    /++
        Returns the length of the internal associative array.

        Example:
        ---
        MutexedAA!(string[int]) aa;
        aa.setup();  // important!

        assert(aa.length == 0);
        aa[1] = "one";
        aa[2] = "two";
        assert(aa.length == 2);
        ---

        Returns:
            The length of the internal associative array.
     +/
    auto length()
    in (mutex, typeof(this).stringof ~ " has null Mutex")
    {
        mutex.lock_nothrow();
        auto length = (cast(AA)aa).length;
        mutex.unlock_nothrow();
        return length;
    }

    /++
        Returns the value for the key `key`, inserting `value` lazily if it is not present.

        Example:
        ---
        MutexedAA!(string[int]) aa;
        aa.setup();  // important!

        assert(!aa.has(42));
        string hello = aa.require(42, "hello");
        assert(hello == "hello");
        assert(aa[42] == "hello");
        ---

        Params:
            key = Key.
            value = Lazy value.

        Returns:
            The value for the key `key`, or `value` if there was no value there.
     +/
    auto require(K key, lazy V value)
    in (mutex, typeof(this).stringof ~ " has null Mutex")
    {
        V retval;

        mutex.lock_nothrow();
        if (auto existing = key in cast(AA)aa)
        {
            retval = *existing;
        }
        else
        {
            (cast(AA)aa)[key] = value;
            retval = value;
        }

        mutex.unlock_nothrow();
        return retval;
    }

    /++
        Returns a new dynamic array of all the keys in the internal associative array.

        Example:
        ---
        MutexedAA!(int[int]) aa;
        aa.setup();  // important!
        aa[1] = 42;
        aa[2] = 99;

        auto keys = aa.keys;
        assert(keys.canFind(1));
        assert(keys.canFind(2));
        assert(!keys.canFind(3));
        ---

        Returns:
            A new `K[]` of all the AA keys.
     +/
    auto keys()
    in (mutex, typeof(this).stringof ~ " has null Mutex")
    {
        mutex.lock_nothrow();
        auto keys = (cast(AA)aa).keys;  // allocates a new array
        mutex.unlock_nothrow();
        return keys;
    }

    /++
        Returns a new dynamic array of all the values in the internal associative array.

        Example:
        ---
        MutexedAA!(int[int]) aa;
        aa.setup();  // important!
        aa[1] = 42;
        aa[2] = 99;

        auto values = aa.values;
        assert(values.canFind(42));
        assert(values.canFind(99));
        assert(!values.canFind(0));
        ---

        Returns:
            A new `V[]` of all the AA values.
     +/
    auto values()
    in (mutex, typeof(this).stringof ~ " has null Mutex")
    {
        mutex.lock_nothrow();
        auto values = (cast(AA)aa).values;  // as above
        mutex.unlock_nothrow();
        return values;
    }

    /++
        Retrieves the value for the key `key`, or returns the default `value`
        if there was none.

        Example:
        ---
        MutexedAA!(int[int]) aa;
        aa.setup();  // important!
        aa[1] = 42;
        aa[2] = 99;

        assert(aa.get(1, 0) == 42);
        assert(aa.get(2, 0) == 99);
        assert(aa.get(0, 0) == 0);
        assert(aa.get(3, 999) == 999);

        assert(!aa.has(0));
        assert(!aa.has(3));
        ---

        Params:
            key = Key.
            value = Lazy default value.

        Returns:
            The value for the key `key`, or `value` if there was no value there.
     +/
    auto get(K key, lazy V value)
    in (mutex, typeof(this).stringof ~ " has null Mutex")
    {
        mutex.lock_nothrow();
        auto existing = key in cast(AA)aa;
        auto retval = existing ? *existing : value;
        mutex.unlock_nothrow();
        return retval;
    }

    /++
        Updates the value for the key `key` in the internal associative array,
        invoking the first of the passed delegate to insert a new value if it
        doesn't exist, or the second selegate to modify it in place if it does.

        Note: Doesn't compile with compilers earlier than version 2.088.

        Example:
        ---
        MutexedAA!(int[int]) aa;
        aa.setup();  // important!

        assert(!aa.has(1));

        aa.update(1,
            () => 42,
            (int i) => i + 1);
        assert(aa[1] == 42);

        aa.update(1,
            () => 42,
            (int i) => i + 1);
        assert(aa[1] == 43);
        ---

        Params:
            key = Key.
            createDg = Delegate to invoke to create a new value if it doesn't exist.
            updateDg = Delegate to invoke to update an existing value.
     +/
    static if (__VERSION__ >= 2088L)
    void update(U)
        (K key,
        scope V delegate() createDg,
        scope U delegate(K) updateDg)
    if (is(U == V) || is(U == void))
    in (mutex, typeof(this).stringof ~ " has null Mutex")
    {
        mutex.lock_nothrow();
        .object.update((*(cast(AA*)&aa)), key, createDg, updateDg);
        mutex.unlock_nothrow();
    }

    /++
        Implements unary operations by mixin strings.

        Example:
        ---
        MutexedAA!(int[int]) aa;
        aa.setup();  // important!

        aa[1] = 42;
        assert(-aa[1] == -42);
        ---

        Params:
            op = Operation, here a unary operator.
            key = Key.

        Returns:
            The result of the operation.
     +/
    auto opIndexUnary(string op)(K key)
    //if (isIntegral!V)
    in (mutex, typeof(this).stringof ~ " has null Mutex")
    {
        mutex.lock_nothrow();
        mixin("auto value = " ~ op ~ "(cast(AA)aa)[key];");
        mutex.unlock_nothrow();
        return value;
    }

    /++
        Implements index assign operations by mixin strings.

        Example:
        ---
        MutexedAA!(int[int]) aa;
        aa.setup();  // important!

        aa[1] = 42;
        aa[1] += 1;
        assert(aa[1] == 43);

        aa[1] *= 2;
        assert(aa[1] == 86);
        ---

        Params:
            op = Operation, here an index assign operator.
            value = Value.
            key = Key.
     +/
    void opIndexOpAssign(string op, U)(U value, K key)
    if (is(U == V) || is(U == ElementEncodingType!V))
    in (mutex, typeof(this).stringof ~ " has null Mutex")
    {
        mutex.lock_nothrow();
        mixin("(*(cast(AA*)&aa))[key] " ~ op ~ "= value;");
        mutex.unlock_nothrow();
    }
}

///
unittest
{
    {
        MutexedAA!(string[int]) aa1;
        assert(!aa1.isReady);
        aa1.setup();
        assert(aa1.isReady);
        aa1.setup();  // extra setups ignored

        MutexedAA!(string[int]) aa2;
        aa2.setup();

        aa1[42] = "hello";
        aa2[42] = "world";
        assert(aa1 != aa2);

        aa1[42] = "world";
        assert(aa1 == aa2);

        aa2[99] = "goodbye";
        assert(aa1 != aa2);
    }
    {
        MutexedAA!(string[int]) aa;
        aa.setup();

        assert(!aa.has(42));
        aa.require(42, "hello");
        assert((aa[42] == "hello"), aa[42]);

        bool set1;
        assert(!aa.has(99));
        string world1 = aa.require(99, { set1 = true; return "world"; }());
        assert(set1);
        assert((world1 == "world"), world1);
        assert((aa[99] == "world"), aa[99]);

        bool set2;
        string world2 = aa.require(99, { set2 = true; return "goodbye"; }());
        assert(!set2);
        assert((world2 != "goodbye"), world2);
        assert((aa[99] != "goodbye"), aa[99]);
    }
    {
        import std.concurrency : Tid, send, spawn;
        import std.conv : to;
        import core.time : MonoTime, seconds;

        static immutable timeout = 1.seconds;

        static void workerFn(MutexedAA!(string[int]) aa)
        {
            static void _assert(
                lazy bool condition,
                const string message = "unittest failure",
                const string file = __FILE__,
                const uint line = __LINE__)
            {
                if (!condition)
                {
                    import std.format : format;
                    import std.stdio : writeln;

                    enum pattern = "core.exception.AssertError@%s(%d): %s";
                    immutable assertMessage = pattern.format(file, line, message);
                    writeln(assertMessage);
                    assert(0, assertMessage);
                }
            }

            _assert(aa.isReady, "MutexedAA passed to worker was not set up properly");

            bool halt;

            while (!halt)
            {
                import std.concurrency : OwnerTerminated, receiveTimeout;
                import std.variant : Variant;

                immutable receivedSomething = receiveTimeout(timeout,
                    (bool _)
                    {
                        halt = true;
                    },
                    (int i)
                    {
                        _assert((aa.length == i-1), "Incorrect MutexedAA length before insert");
                        aa[i] = i.to!string;
                        _assert((aa.length == i), "Incorrect MutexedAA length after insert");
                    },
                    (OwnerTerminated _)
                    {
                        halt = true;
                    },
                    (Variant v)
                    {
                        import std.stdio : writeln;
                        writeln("MutexedAA unit test worker received unknown message: ", v);
                        halt = true;
                    }
                );

                if (!receivedSomething) return;
            }
        }

        MutexedAA!(string[int]) aa;
        aa.setup();

        auto worker = spawn(&workerFn, aa);
        immutable start = MonoTime.currTime;

        foreach (/*immutable*/ i; 1..10)  // start at 1 to enable length checks in worker
        {
            worker.send(i);
            aa.setup();
            auto present = aa.has(i);

            while (!present && (MonoTime.currTime - start) < timeout)
            {
                import core.thread : Thread;
                import core.time : msecs;

                static immutable briefWait = 2.msecs;
                Thread.sleep(briefWait);
                present = aa.has(i);
            }

            assert(present, "MutexedAA unit test worker timed out responding to " ~ i.to!string);
            assert((aa[i] == i.to!string), aa[i]);
        }

        worker.send(true);  // halt
    }
    {
        import std.algorithm.searching : canFind;

        MutexedAA!(int[int]) aa;
        aa.setup();

        aa[1] = 42;
        aa[2] = 99;
        assert(aa.length == 2);

        auto keys = aa.keys;
        assert(keys.canFind(1));
        assert(keys.canFind(2));
        assert(!keys.canFind(3));

        auto values = aa.values;
        assert(values.canFind(42));
        assert(values.canFind(99));
        assert(!values.canFind(0));

        assert(aa.get(1, 0) == 42);
        assert(aa.get(2, 0) == 99);
        assert(aa.get(0, 0) == 0);
        assert(aa.get(3, 999) == 999);
    }
    {
        MutexedAA!(int[int]) aa1;
        aa1.setup();

        aa1[1] = 42;
        aa1[2] = 99;

        int[int] aa2;

        aa2[1] = 42;
        assert(aa1 != aa2);

        aa2[2] = 99;
        assert(aa1 == aa2);

        ++aa2[2];
        assert(aa2[2] == 100);

        aa2[1] += 1;
        assert(aa2[1] == 43);

        aa2[1] -= 1;
        assert(aa2[1] == 42);

        aa2[1] *= 2;
        assert(aa2[1] == 84);

        int i = -aa2[1];
        assert(i == -84);
    }
    {
        MutexedAA!(char[][int]) aa;
        aa.setup();

        aa[1] ~= 'a';
        aa[1] ~= 'b';
        aa[1] ~= 'c';
        assert(aa[1] == "abc".dup);

        aa[1] ~= [ 'd', 'e', 'f' ];
        assert(aa[1] == "abcdef".dup);
    }
    static if (__VERSION__ >= 2088L)
    {
        MutexedAA!(int[int]) aa;
        aa.setup();

        assert(!aa.has(1));

        aa.update(1,
            () => 42,
            (int i) => i + 1);
        assert(aa.has(1));
        assert(aa[1] == 42);

        aa.update(1,
            () => 42,
            (int i) => i + 1);
        assert(aa[1] == 43);
    }
}


// Next
/++
    Enum of flags carrying the meaning of "what to do next".

    [lu.common.Next] extended.
 +/
enum Next
{
    /++
        Unset, invalid value.
     +/
    unset,

    /++
        Do nothing.
     +/
    noop,

    /++
        Keep doing whatever is being done, alternatively continue on to the next step.
     +/
    continue_,

    /++
        Halt what's being done and give it another attempt.
     +/
    retry,

    /++
        Exit or return with a positive return value.
     +/
    returnSuccess,

    /++
        Exit or abort with a negative return value.
     +/
    returnFailure,

    /++
        Fatally abort.
     +/
    crash,
}
