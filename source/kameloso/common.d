/++
    Common functions used throughout the program, generic enough to be used in
    several places, not fitting into any specific one.

    See_Also:
        [kameloso.kameloso]
 +/
module kameloso.common;

private:

import kameloso.pods : CoreSettings;
import kameloso.logger : KamelosoLogger;
import dialect.defs : IRCClient;
import std.range.primitives : isOutputRange;
import std.stdio : stdout;
import std.typecons : Flag, No, Yes;

public:

version(unittest)
shared static this()
{
    // This is technically before settings have been read.
    // We need this for unittests.
    logger = new KamelosoLogger(
        No.monochrome,
        No.brightTerminal,
        No.headless,
        Yes.flush);

    // settings need instantiating too, for tag expansion and kameloso.printing.
    settings = new CoreSettings;
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


// initLogger
/++
    Initialises the [kameloso.logger.KamelosoLogger|KamelosoLogger] logger for
    use in this thread.

    It needs to be separately instantiated per thread, and even so there may be
    race conditions. Plugins are encouraged to use
    [kameloso.thread.ThreadMessage|ThreadMessage]s to log to screen from other threads.

    Example:
    ---
    initLogger(No.monochrome, Yes.brightTerminal);
    ---

    Params:
        monochrome = Whether the terminal is set to monochrome or not.
        bright = Whether the terminal has a bright background or not.
        headless = Whether the terminal is headless or not.
        flush = Whether the terminal needs to manually flush standard out after writing to it.
 +/
void initLogger(
    const Flag!"monochrome" monochrome,
    const Flag!"brightTerminal" bright,
    const Flag!"headless" headless,
    const Flag!"flush" flush) @safe
out (; (logger !is null), "Failed to initialise logger")
{
    import kameloso.logger : KamelosoLogger;
    logger = new KamelosoLogger(monochrome, bright, headless, flush);
}


// settings
/++
    A [kameloso.pods.CoreSettings|CoreSettings] struct global, housing
    certain runtime settings.

    This will be accessed from other parts of the program, via
    [kameloso.common.settings], so they know to use monochrome output or not.
    It is a problem that needs solving.
 +/
CoreSettings* settings;


// printVersionInfo
/++
    Prints out the bot banner with the version number and GitHub URL, with the
    passed colouring.

    Example:
    ---
    printVersionInfo(Yes.colours);
    ---

    Params:
        colours = Whether or not to tint output, default yes. A global monochrome
            setting overrides this.
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

    immutable versionPattern = colours ?
        "<l>kameloso IRC bot v%s%s, built with %s (%s) on %s</>".expandTags(LogLevel.off) :
        "kameloso IRC bot v%s%s, built with %s (%s) on %s";

    writefln(versionPattern,
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
    /// String line to send.
    string line;

    /// Whether this message should be sent quietly or verbosely.
    bool quiet;

    /// Constructor.
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
    import lu.string : contains, nom, strippedRight;
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
        else if (!slice.contains(' ') &&
            (slice[10..$].contains("http://") ||
            slice[10..$].contains("https://")))
        {
            // There is a second URL in the middle of this one
            break;
        }

        // nom until the next space if there is one, otherwise just inherit slice
        // Also strip away common punctuation
        immutable hit = slice.nom!(Yes.inherit)(' ').strippedRight(wordBoundaryTokens);
        if (hit.contains('.')) hits ~= hit;
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
        K = Key type.
        V = Value type.
 +/
struct RehashingAA(K, V)
{
private:
    /++
        Internal associative array.
     +/
    V[K] aa;

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
        takes place, with regards to the current [aa] length.

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
        Inherit a native associative array into [aa].

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
            T = Type to cast to, here the same as the type of [aa].

        Returns:
            The internal associative array.
     +/
    auto opCast(T : V[K])() inout
    {
        return aa;
    }

    // aaOf
    /++
        Returns the internal associative array, for when the wrapper is insufficient.

        Returns:
            The internal associative array.
     +/
    inout(V[K]) aaOf() inout
    {
        return aa;
    }

    // remove
    /++
        Removes a key from the [aa] associative array by merely invoking `.remove`.

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
    auto numRehashes() const
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
    auto length() const
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
    this(V[K] aa)
    {
        this.aa = aa;
    }

    // onRehashDg
    /++
        Delegate called when rehashing takes place.
     +/
    void delegate() onRehashDg;

    /++
        `alias this` with regards to [aa].
     +/
    version(none)
    alias aa this;
}

///
unittest
{
    import std.conv : to;

    RehashingAA!(string, int) aa;
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
    assert("ghi" in realAA);
    assert("jkl" !in realAA);

    auto aa2 = aa.dup;
    aa2["jkl"] = 123;
    assert("jkl" in aa2);
    assert("jkl" !in aa);
}


version(GCStatsOnExit) version = BuildPrintGCStats;
else version(IncludeHeavyStuff) version = BuildPrintGCStats;


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

    enum memoryUsedPattern = "Memory currently in use: <l>%,d</> bytes, " ~
        "<l>%,d</> additional bytes reserved";
    logger.infof(memoryUsedPattern, stats.usedSize, stats.freeSize);
}
