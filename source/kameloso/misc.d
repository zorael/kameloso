/++
    Things that don't have a better home yet.

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.misc;

debug version = Debug;


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
        max = Maximum number of URLs to find. Default is `uint.max`.

    Returns:
        A `string[]` array of found URLs. These include fragment identifiers.
 +/
auto findURLs(
    const string line,
    const uint max = uint.max) @safe pure
{
    import lu.string : advancePast, stripped, strippedRight;
    import std.algorithm.searching : canFind;
    import std.string : indexOf;

    enum wordBoundaryTokens = ".,!?:";
    enum minimumPossibleLinkLength = "http://a.se".length;

    if (max == 0) return null;

    string slice = line.stripped;  // mutable
    if (slice.length < minimumPossibleLinkLength) return null;

    string[] hits;
    ptrdiff_t httpPos = slice.indexOf("http");

    while ((httpPos != -1) && (hits.length < max))
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
            !slice.canFind(' ') &&
            slice[10..$].canFind("https://", "http://"))
        {
            // There is a second URL in the middle of this one
            break;
        }

        // advancePast until the next space if there is one, otherwise just inherit slice
        // Also strip away common punctuation
        immutable hit = slice
            .advancePast(' ', inherit: true)
            .strippedRight(wordBoundaryTokens);
        if (hit.canFind('.')) hits ~= hit;
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
        // max 2
        const urls = findURLs("blah https://a.com http://b.com shttps://c https://d.asdf.asdf.asdf        ", max: 2);
        assert((urls.length == 2), urls.to!string);
        assert((urls == [ "https://a.com", "http://b.com" ]), urls.to!string);
    }
    {
        const urls = findURLs("http:// http://asdf https:// asdfhttpasdf http://google.com");
        assert((urls.length == 1), urls.to!string);
    }
    {
        // max 0
        const urls = findURLs("http:// http://asdf https:// asdfhttpasdf http://google.com", max: 0);
        assert(!urls.length, urls.to!string);
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


// printGCStats
/++
    Prints garbage collector statistics to the local terminal.
 +/
void printGCStats()
{
    import kameloso.common : logger;
    import core.memory : GC;

    immutable stats = GC.stats();
    immutable profileStats = GC.profileStats();

    if (profileStats.numCollections == 1)
    {
        enum pausePattern = "World stopped for <l>%.1,f</> ms in <l>1</> collection";
        logger.infof(
            pausePattern,
            (profileStats.totalPauseTime.total!"hnsecs" / 10_000.0));

        enum collectionPattern = "Collection time: <l>%.1,f</> ms";
        logger.infof(
            collectionPattern,
            (profileStats.totalCollectionTime.total!"hnsecs" / 10_000.0));
    }
    else if (profileStats.numCollections > 1)
    {
        enum pausePattern = "World stopped for <l>%.1,f</> ms across <l>%d</> collections " ~
            "(longest was <l>%.1,f</> ms)";
        logger.infof(
            pausePattern,
            (profileStats.totalPauseTime.total!"hnsecs" / 10_000.0),
            profileStats.numCollections,
            (profileStats.maxPauseTime.total!"hnsecs" / 10_000.0));

        enum collectionPattern = "Sum of collection cycles: <l>%.1,f</> ms (max: <l>%.1,f</> ms)";
        logger.infof(
            collectionPattern,
            (profileStats.totalCollectionTime.total!"hnsecs" / 10_000.0),
            (profileStats.maxCollectionTime.total!"hnsecs" / 10_000.0));
    }
    /*else
    {
        enum noCollectionsMessage = "No collections have been made.";
        logger.info(noCollectionsMessage);
    }*/

    enum lifetimeAllocatedPattern = "Lifetime allocated in current thread: <l>%,d</> bytes";
    logger.infof(lifetimeAllocatedPattern, stats.allocatedInCurrentThread);

    enum memoryUsedPattern = "Memory currently in use: <l>%,d</> bytes; " ~
        "<l>%,d</> additional bytes reserved";
    logger.infof(memoryUsedPattern, stats.usedSize, stats.freeSize);
}


// printVersionInfo
/++
    Prints out the bot banner with the version number and GitHub URL, with the
    passed colouring.

    Example:
    ---
    printVersionInfo(colours: true);
    ---

    Params:
        colours = Whether or not to tint output, default true.
 +/
void printVersionInfo(const bool colours = true) @safe
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
    stdout.flush();
}
