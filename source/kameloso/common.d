/++
    Common functions used throughout the program, generic enough to be used in
    several places, not fitting into any specific one.

    See_Also:
        [kameloso.kameloso]
 +/
module kameloso.common;

private:

import kameloso.logger : KamelosoLogger, LogLevel;
import dialect.defs : IRCClient, IRCServer;
import std.datetime.systime : SysTime;
import std.range.primitives : isOutputRange;
import std.stdio : stdout;
import std.typecons : Flag, No, Yes;
import core.time : Duration, seconds;
static import kameloso.kameloso;

public:

@safe:

version(unittest)
shared static this()
{
    // This is technically before settings have been read...
    logger = new KamelosoLogger(No.monochrome, No.brightTerminal, No.headless, Yes.flush);

    // settings needs instantiating now.
    settings = new kameloso.kameloso.CoreSettings;
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
    const Flag!"flush" flush)
out (; (logger !is null), "Failed to initialise logger")
{
    import kameloso.logger : KamelosoLogger;
    import kameloso.terminal.colours : Tint;

    logger = new KamelosoLogger(monochrome, bright, headless, flush);
    Tint.monochrome = monochrome;
}


// settings
/++
    A [kameloso.kameloso.CoreSettings|CoreSettings] struct global, housing
    certain runtime settings.

    This will be accessed from other parts of the program, via
    [kameloso.common.settings], so they know to use monochrome output or not.
    It is a problem that needs solving.
 +/
kameloso.kameloso.CoreSettings* settings;


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
    import kameloso.constants : KamelosoInfo;
    import kameloso.terminal.colours : Tint;
    import std.stdio : writefln;

    immutable logtint = colours ? Tint.log : string.init;
    immutable infotint = colours ? Tint.info : string.init;

    version(TwitchSupport) enum twitchSupport = " (+twitch)";
    else enum twitchSupport = string.init;

    enum versionPattern = "%skameloso IRC bot v%s%s, built with %s (%s) on %s%s";
    writefln(versionPattern,
        logtint,
        cast(string)KamelosoInfo.version_,
        twitchSupport,
        cast(string)KamelosoInfo.compiler,
        cast(string)KamelosoInfo.compilerVersion,
        cast(string)KamelosoInfo.built,
        Tint.off);

    enum gitClonePattern = "$ git clone %s%s.git%s";
    writefln(gitClonePattern,
        infotint,
        cast(string)KamelosoInfo.source,
        Tint.off);
}


// printStacktrace
/++
    Prints the current stacktrace to the terminal.

    This is so we can get the stacktrace even outside a thrown Exception.
 +/
version(PrintStacktraces)
void printStacktrace() @system
{
    import std.stdio : writeln;
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
    this(const string line, const Flag!"quiet" quiet = No.quiet)
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
string[] findURLs(const string line) @safe pure
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
    import std.conv : text;

    {
        const urls = findURLs("http://google.com");
        assert((urls.length == 1), urls.text);
        assert((urls[0] == "http://google.com"), urls[0]);
    }
    {
        const urls = findURLs("blah https://a.com http://b.com shttps://c https://d.asdf.asdf.asdf        ");
        assert((urls.length == 3), urls.text);
        assert((urls == [ "https://a.com", "http://b.com", "https://d.asdf.asdf.asdf" ]), urls.text);
    }
    {
        const urls = findURLs("http:// http://asdf https:// asdfhttpasdf http://google.com");
        assert((urls.length == 1), urls.text);
    }
    {
        const urls = findURLs("http://a.sehttp://a.shttp://a.http://http:");
        assert(!urls.length, urls.text);
    }
    {
        const urls = findURLs("blahblah https://motorbörsen.se blhblah");
        assert(urls.length, urls.text);
    }
    {
        // Let dlang-requests attempt complex URLs, don't validate more than necessary
        const urls = findURLs("blahblah https://高所恐怖症。co.jp blhblah");
        assert(urls.length, urls.text);
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
        assert((urls == [ "https://google.se", "https://google.se" ]), urls.text);
    }
    {
        const urls = findURLs("https://               ");
        assert(!urls.length, urls.text);
    }
    {
        const urls = findURLs("http://               ");
        assert(!urls.length, urls.text);
    }
}


// timeSinceInto
/++
    Express how much time has passed in a [core.time.Duration|Duration], in
    natural (English) language. Overload that writes the result to the passed
    output range `sink`.

    Example:
    ---
    Appender!(char[]) sink;

    immutable then = Clock.currTime;
    Thread.sleep(1.seconds);
    immutable now = Clock.currTime;

    immutable duration = (now - then);
    immutable inEnglish = duration.timeSinceInto(sink);
    ---

    Params:
        abbreviate = Whether or not to abbreviate the output, using `h` instead
            of `hours`, `m` instead of `minutes`, etc.
        numUnits = Number of units to include in the output text, where such is
            "weeks", "days", "hours", "minutes" and "seconds", a fake approximate
            unit "months", and a fake "years" based on it. Passing a `numUnits`
            of 7 will express the time difference using all units. Passing one
            of 4 will only express it in days, hours, minutes and seconds.
            Passing 1 will express it in only seconds.
        truncateUnits = Number of units to skip from output, going from least
            significant (seconds) to most significant (years).
        roundUp = Whether to round up or floor seconds, minutes and hours.
            Larger units are floored regardless of this setting.
        signedDuration = A period of time.
        sink = Output buffer sink to write to.
 +/
void timeSinceInto(uint numUnits = 7, uint truncateUnits = 0, Sink)
    (const Duration signedDuration,
    auto ref Sink sink,
    const Flag!"abbreviate" abbreviate = No.abbreviate,
    const Flag!"roundUp" roundUp = Yes.roundUp) pure
if (isOutputRange!(Sink, char[]))
{
    import lu.conv : toAlphaInto;
    import lu.string : plurality;
    import std.algorithm.comparison : min;
    import std.format : formattedWrite;
    import std.meta : AliasSeq;

    static if ((numUnits < 1) || (numUnits > 7))
    {
        import std.format : format;

        enum pattern = "Invalid number of units passed to `timeSinceInto`: " ~
            "expected `1` to `7`, got `%d`";
        static assert(0, pattern.format(numUnits));
    }

    static if ((truncateUnits < 0) || (truncateUnits > 6))
    {
        import std.format : format;

        enum pattern = "Invalid number of units to truncate passed to `timeSinceInto`: " ~
            "expected `0` to `6`, got `%d`";
        static assert(0, pattern.format(truncateUnits));
    }

    immutable duration = signedDuration < Duration.zero ? -signedDuration : signedDuration;

    alias units = AliasSeq!("weeks", "days", "hours", "minutes", "seconds");
    enum daysInAMonth = 30;  // The real average is 30.42 but we get unintuitive results.

    immutable diff = duration.split!(units[units.length-min(numUnits, 5)..$]);

    bool putSomething;

    static if (numUnits >= 1)
    {
        immutable trailingSeconds = (diff.seconds && (truncateUnits < 1));
    }

    static if (numUnits >= 2)
    {
        immutable trailingMinutes = (diff.minutes && (truncateUnits < 2));
        long minutes = diff.minutes;

        if (roundUp)
        {
            if ((diff.seconds >= 30) && (truncateUnits > 0))
            {
                ++minutes;
            }
        }
    }

    static if (numUnits >= 3)
    {
        immutable trailingHours = (diff.hours && (truncateUnits < 3));
        long hours = diff.hours;

        if (roundUp)
        {
            if (minutes == 60)
            {
                minutes = 0;
                ++hours;
            }
            else if ((minutes >= 30) && (truncateUnits > 1))
            {
                ++hours;
            }
        }
    }

    static if (numUnits >= 4)
    {
        immutable trailingDays = (diff.days && (truncateUnits < 4));
        long days = diff.days;

        if (roundUp)
        {
            if (hours == 24)
            {
                hours = 0;
                ++days;
            }
        }
    }

    static if (numUnits >= 5)
    {
        immutable trailingWeeks = (diff.weeks && (truncateUnits < 5));
        long weeks = diff.weeks;

        if (roundUp)
        {
            if (days == 7)
            {
                days = 0;
                ++weeks;
            }
        }
    }

    static if (numUnits >= 6)
    {
        uint months;

        {
            immutable totalDays = (weeks * 7) + days;
            months = cast(uint)(totalDays / daysInAMonth);
            days = cast(uint)(totalDays % daysInAMonth);
            weeks = (days / 7);
            days %= 7;
        }
    }

    static if (numUnits >= 7)
    {
        uint years;

        if (months >= 12) // && (truncateUnits < 7))
        {
            years = cast(uint)(months / 12);
            months %= 12;
        }
    }

    // -------------------------------------------------------------------------

    if (signedDuration < Duration.zero)
    {
        sink.put('-');
    }

    static if (numUnits >= 7)
    {
        if (years)
        {
            years.toAlphaInto(sink);

            if (abbreviate)
            {
                //sink.formattedWrite("%dy", years);
                sink.put('y');
            }
            else
            {
                /*sink.formattedWrite("%d %s", years,
                    years.plurality("year", "years"));*/
                sink.put(years.plurality(" year", " years"));
            }

            putSomething = true;
        }
    }

    static if (numUnits >= 6)
    {
        if (months && (!putSomething || (truncateUnits < 6)))
        {
            if (abbreviate)
            {
                static if (numUnits >= 7)
                {
                    if (putSomething) sink.put(' ');
                }

                //sink.formattedWrite("%dm", months);
                months.toAlphaInto(sink);
                sink.put('m');
            }
            else
            {
                static if (numUnits >= 7)
                {
                    if (putSomething)
                    {
                        if (trailingSeconds ||
                            trailingMinutes ||
                            trailingHours ||
                            trailingDays ||
                            trailingWeeks)
                        {
                            sink.put(", ");
                        }
                        else
                        {
                            sink.put(" and ");
                        }
                    }
                }

                /*sink.formattedWrite("%d %s", months,
                    months.plurality("month", "months"));*/
                months.toAlphaInto(sink);
                sink.put(months.plurality(" month", " months"));
            }

            putSomething = true;
        }
    }

    static if (numUnits >= 5)
    {
        if (weeks && (!putSomething || (truncateUnits < 5)))
        {
            if (abbreviate)
            {
                static if (numUnits >= 6)
                {
                    if (putSomething) sink.put(' ');
                }

                //sink.formattedWrite("%dw", weeks);
                weeks.toAlphaInto(sink);
                sink.put('w');
            }
            else
            {
                static if (numUnits >= 6)
                {
                    if (putSomething)
                    {
                        if (trailingSeconds ||
                            trailingMinutes ||
                            trailingHours ||
                            trailingDays)
                        {
                            sink.put(", ");
                        }
                        else
                        {
                            sink.put(" and ");
                        }
                    }
                }

                /*sink.formattedWrite("%d %s", weeks,
                    weeks.plurality("week", "weeks"));*/
                weeks.toAlphaInto(sink);
                sink.put(weeks.plurality(" week", " weeks"));
            }

            putSomething = true;
        }
    }

    static if (numUnits >= 4)
    {
        if (days && (!putSomething || (truncateUnits < 4)))
        {
            if (abbreviate)
            {
                static if (numUnits >= 5)
                {
                    if (putSomething) sink.put(' ');
                }

                //sink.formattedWrite("%dd", days);
                days.toAlphaInto(sink);
                sink.put('d');
            }
            else
            {
                static if (numUnits >= 5)
                {
                    if (putSomething)
                    {
                        if (trailingSeconds ||
                            trailingMinutes ||
                            trailingHours)
                        {
                            sink.put(", ");
                        }
                        else
                        {
                            sink.put(" and ");
                        }
                    }
                }

                /*sink.formattedWrite("%d %s", days,
                    days.plurality("day", "days"));*/
                days.toAlphaInto(sink);
                sink.put(days.plurality(" day", " days"));
            }

            putSomething = true;
        }
    }

    static if (numUnits >= 3)
    {
        if (hours && (!putSomething || (truncateUnits < 3)))
        {
            if (abbreviate)
            {
                static if (numUnits >= 4)
                {
                    if (putSomething) sink.put(' ');
                }

                //sink.formattedWrite("%dh", hours);
                hours.toAlphaInto(sink);
                sink.put('h');
            }
            else
            {
                static if (numUnits >= 4)
                {
                    if (putSomething)
                    {
                        if (trailingSeconds ||
                            trailingMinutes)
                        {
                            sink.put(", ");
                        }
                        else
                        {
                            sink.put(" and ");
                        }
                    }
                }

                /*sink.formattedWrite("%d %s", hours,
                    hours.plurality("hour", "hours"));*/
                hours.toAlphaInto(sink);
                sink.put(hours.plurality(" hour", " hours"));
            }

            putSomething = true;
        }
    }

    static if (numUnits >= 2)
    {
        if (minutes && (!putSomething || (truncateUnits < 2)))
        {
            if (abbreviate)
            {
                static if (numUnits >= 3)
                {
                    if (putSomething) sink.put(' ');
                }

                //sink.formattedWrite("%dm", minutes);
                minutes.toAlphaInto(sink);
                sink.put('m');
            }
            else
            {
                static if (numUnits >= 3)
                {
                    if (putSomething)
                    {
                        if (trailingSeconds)
                        {
                            sink.put(", ");
                        }
                        else
                        {
                            sink.put(" and ");
                        }
                    }
                }

                /*sink.formattedWrite("%d %s", minutes,
                    minutes.plurality("minute", "minutes"));*/
                minutes.toAlphaInto(sink);
                sink.put(minutes.plurality(" minute", " minutes"));
            }

            putSomething = true;
        }
    }

    if (trailingSeconds || !putSomething)
    {
        if (abbreviate)
        {
            if (putSomething)
            {
                sink.put(' ');
            }

            //sink.formattedWrite("%ds", diff.seconds);
            diff.seconds.toAlphaInto(sink);
            sink.put('s');
        }
        else
        {
            if (putSomething)
            {
                sink.put(" and ");
            }

            /*sink.formattedWrite("%d %s", diff.seconds,
                diff.seconds.plurality("second", "seconds"));*/
            diff.seconds.toAlphaInto(sink);
            sink.put(diff.seconds.plurality(" second", " seconds"));
        }
    }
}

///
unittest
{
    import std.array : Appender;
    import core.time;

    Appender!(char[]) sink;
    sink.reserve(64);  // workaround for formattedWrite < 2.076

    {
        immutable dur = Duration.zero;
        dur.timeSinceInto(sink);
        assert((sink.data == "0 seconds"), sink.data);
        sink.clear();
        dur.timeSinceInto(sink, Yes.abbreviate);
        assert((sink.data == "0s"), sink.data);
        sink.clear();
    }
    {
        immutable dur = 3_141_519_265.msecs;
        dur.timeSinceInto!(4, 1)(sink, No.abbreviate,  No.roundUp);
        assert((sink.data == "36 days, 8 hours and 38 minutes"), sink.data);
        sink.clear();
        dur.timeSinceInto!(4, 1)(sink, Yes.abbreviate,  No.roundUp);
        assert((sink.data == "36d 8h 38m"), sink.data);
        sink.clear();
    }
    {
        immutable dur = 3_141_519_265.msecs;
        dur.timeSinceInto!(4, 1)(sink, No.abbreviate, Yes.roundUp);
        assert((sink.data == "36 days, 8 hours and 39 minutes"), sink.data);
        sink.clear();
        dur.timeSinceInto!(4, 1)(sink, Yes.abbreviate, Yes.roundUp);
        assert((sink.data == "36d 8h 39m"), sink.data);
        sink.clear();
    }
    {
        immutable dur = 3599.seconds;
        dur.timeSinceInto!(2, 1)(sink, No.abbreviate, No.roundUp);
        assert((sink.data == "59 minutes"), sink.data);
        sink.clear();
        dur.timeSinceInto!(2, 1)(sink, Yes.abbreviate, No.roundUp);
        assert((sink.data == "59m"), sink.data);
        sink.clear();
    }
    {
        immutable dur = 3599.seconds;
        dur.timeSinceInto!(2, 1)(sink, No.abbreviate, Yes.roundUp);
        assert((sink.data == "60 minutes"), sink.data);
        sink.clear();
        dur.timeSinceInto!(2, 1)(sink, Yes.abbreviate, Yes.roundUp);
        assert((sink.data == "60m"), sink.data);
        sink.clear();
    }
    {
        immutable dur = 3599.seconds;
        dur.timeSinceInto!(3, 1)(sink, No.abbreviate, Yes.roundUp);
        assert((sink.data == "1 hour"), sink.data);
        sink.clear();
        dur.timeSinceInto!(3, 1)(sink, Yes.abbreviate, Yes.roundUp);
        assert((sink.data == "1h"), sink.data);
        sink.clear();
    }
    {
        immutable dur = 3.days + 35.minutes;
        dur.timeSinceInto!(4, 1)(sink, No.abbreviate, No.roundUp);
        assert((sink.data == "3 days and 35 minutes"), sink.data);
        sink.clear();
        dur.timeSinceInto!(4, 1)(sink, Yes.abbreviate, No.roundUp);
        assert((sink.data == "3d 35m"), sink.data);
        sink.clear();
    }
    {
        immutable dur = 3.days + 35.minutes;
        dur.timeSinceInto!(4, 2)(sink, No.abbreviate, Yes.roundUp);
        assert((sink.data == "3 days and 1 hour"), sink.data);
        sink.clear();
        dur.timeSinceInto!(4, 2)(sink, Yes.abbreviate, Yes.roundUp);
        assert((sink.data == "3d 1h"), sink.data);
        sink.clear();
    }
    {
        immutable dur = 57.weeks + 1.days + 2.hours + 3.minutes + 4.seconds;
        dur.timeSinceInto!(7, 4)(sink, No.abbreviate);
        assert((sink.data == "1 year, 1 month and 1 week"), sink.data);
        sink.clear();
        dur.timeSinceInto!(7, 4)(sink, Yes.abbreviate);
        assert((sink.data == "1y 1m 1w"), sink.data);
        sink.clear();
    }
    {
        immutable dur = 4.seconds;
        dur.timeSinceInto!(7, 4)(sink, No.abbreviate);
        assert((sink.data == "4 seconds"), sink.data);
        sink.clear();
        dur.timeSinceInto!(7, 4)(sink, Yes.abbreviate);
        assert((sink.data == "4s"), sink.data);
        sink.clear();
    }
    {
        immutable dur = 2.hours + 28.minutes + 19.seconds;
        dur.timeSinceInto!(7, 1)(sink, No.abbreviate);
        assert((sink.data == "2 hours and 28 minutes"), sink.data);
        sink.clear();
        dur.timeSinceInto!(7, 1)(sink, Yes.abbreviate);
        assert((sink.data == "2h 28m"), sink.data);
        sink.clear();
    }
    {
        immutable dur = -1.minutes + -1.seconds;
        dur.timeSinceInto!(2, 0)(sink, No.abbreviate);
        assert((sink.data == "-1 minute and 1 second"), sink.data);
        sink.clear();
        dur.timeSinceInto!(2, 0)(sink, Yes.abbreviate);
        assert((sink.data == "-1m 1s"), sink.data);
        sink.clear();
    }
    {
        immutable dur = 30.seconds;
        dur.timeSinceInto!(3, 1)(sink, No.abbreviate, No.roundUp);
        assert((sink.data == "30 seconds"), sink.data);
        sink.clear();
        dur.timeSinceInto!(3, 1)(sink, Yes.abbreviate, No.roundUp);
        assert((sink.data == "30s"), sink.data);
        sink.clear();
    }
    {
        immutable dur = 30.seconds;
        dur.timeSinceInto!(3, 1)(sink, No.abbreviate, Yes.roundUp);
        assert((sink.data == "1 minute"), sink.data);
        sink.clear();
        dur.timeSinceInto!(3, 1)(sink, Yes.abbreviate, Yes.roundUp);
        assert((sink.data == "1m"), sink.data);
        sink.clear();
    }
    {
        immutable dur = 23.hours + 59.minutes + 59.seconds;
        dur.timeSinceInto!(5, 3)(sink, No.abbreviate, Yes.roundUp);
        assert((sink.data == "1 day"), sink.data);
        sink.clear();
        dur.timeSinceInto!(5, 3)(sink, Yes.abbreviate, Yes.roundUp);
        assert((sink.data == "1d"), sink.data);
        sink.clear();
    }
    {
        immutable dur = 6.days + 23.hours + 59.minutes;
        dur.timeSinceInto!(5, 4)(sink, No.abbreviate, No.roundUp);
        assert((sink.data == "6 days"), sink.data);
        sink.clear();
        dur.timeSinceInto!(5, 4)(sink, Yes.abbreviate, No.roundUp);
        assert((sink.data == "6d"), sink.data);
        sink.clear();
    }
    {
        immutable dur = 6.days + 23.hours + 59.minutes;
        dur.timeSinceInto!(5, 4)(sink, No.abbreviate, Yes.roundUp);
        assert((sink.data == "1 week"), sink.data);
        sink.clear();
        dur.timeSinceInto!(5, 4)(sink, Yes.abbreviate, Yes.roundUp);
        assert((sink.data == "1w"), sink.data);
        sink.clear();
    }
}


// timeSince
/++
    Express how much time has passed in a [core.time.Duration|Duration], in natural
    (English) language. Overload that returns the result as a new string.

    Example:
    ---
    immutable then = Clock.currTime;
    Thread.sleep(1.seconds);
    immutable now = Clock.currTime;

    immutable duration = (now - then);
    immutable inEnglish = timeSince(duration);
    ---

    Params:
        abbreviate = Whether or not to abbreviate the output, using `h` instead
            of `hours`, `m` instead of `minutes`, etc.
        numUnits = Number of units to include in the output text, where such is
            "weeks", "days", "hours", "minutes" and "seconds", a fake approximate
            unit "months", and a fake "years" based on it. Passing a `numUnits`
            of 7 will express the time difference using all units. Passing one
            of 4 will only express it in days, hours, minutes and seconds.
            Passing 1 will express it in only seconds.
        truncateUnits = Number of units to skip from output, going from least
            significant (seconds) to most significant (years).
        roundUp = Whether to round up or floor seconds, minutes and hours.
            Larger units are floored regardless of this setting.
        duration = A period of time.

    Returns:
        A string with the passed duration expressed in natural English language.
 +/
string timeSince(uint numUnits = 7, uint truncateUnits = 0)
    (const Duration duration,
    const Flag!"abbreviate" abbreviate = No.abbreviate,
    const Flag!"roundUp" roundUp = Yes.roundUp) pure
{
    import std.array : Appender;

    Appender!(char[]) sink;
    sink.reserve(64);
    duration.timeSinceInto!(numUnits, truncateUnits)(sink, abbreviate, roundUp);
    return sink.data;
}

///
unittest
{
    import core.time;

    {
        immutable dur = 789_383.seconds;  // 1 week, 2 days, 3 hours, 16 minutes, and 23 secs
        immutable since = dur.timeSince!(4, 1)(No.abbreviate);
        immutable abbrev = dur.timeSince!(4, 1)(Yes.abbreviate);
        assert((since == "9 days, 3 hours and 16 minutes"), since);
        assert((abbrev == "9d 3h 16m"), abbrev);
    }
    {
        immutable dur = 789_383.seconds;  // 1 week, 2 days, 3 hours, 16 minutes, and 23 secs
        immutable since = dur.timeSince!(5, 1)(No.abbreviate);
        immutable abbrev = dur.timeSince!(5, 1)(Yes.abbreviate);
        assert((since == "1 week, 2 days, 3 hours and 16 minutes"), since);
        assert((abbrev == "1w 2d 3h 16m"), abbrev);
    }
    {
        immutable dur = 789_383.seconds;
        immutable since = dur.timeSince!(1)(No.abbreviate);
        immutable abbrev = dur.timeSince!(1)(Yes.abbreviate);
        assert((since == "789383 seconds"), since);
        assert((abbrev == "789383s"), abbrev);
    }
    {
        immutable dur = 789_383.seconds;
        immutable since = dur.timeSince!(2, 0)(No.abbreviate);
        immutable abbrev = dur.timeSince!(2, 0)(Yes.abbreviate);
        assert((since == "13156 minutes and 23 seconds"), since);
        assert((abbrev == "13156m 23s"), abbrev);
    }
    {
        immutable dur = 3_620.seconds;  // 1 hour and 20 secs
        immutable since = dur.timeSince!(7, 1)(No.abbreviate);
        immutable abbrev = dur.timeSince!(7, 1)(Yes.abbreviate);
        assert((since == "1 hour"), since);
        assert((abbrev == "1h"), abbrev);
    }
    {
        immutable dur = 30.seconds;  // 30 secs
        immutable since = dur.timeSince;
        immutable abbrev = dur.timeSince(Yes.abbreviate);
        assert((since == "30 seconds"), since);
        assert((abbrev == "30s"), abbrev);
    }
    {
        immutable dur = 1.seconds;
        immutable since = dur.timeSince;
        immutable abbrev = dur.timeSince(Yes.abbreviate);
        assert((since == "1 second"), since);
        assert((abbrev == "1s"), abbrev);
    }
    {
        immutable dur = 1.days + 1.minutes + 1.seconds;
        immutable since = dur.timeSince!(7, 0)(No.abbreviate);
        immutable abbrev = dur.timeSince!(7, 0)(Yes.abbreviate);
        assert((since == "1 day, 1 minute and 1 second"), since);
        assert((abbrev == "1d 1m 1s"), abbrev);
    }
    {
        immutable dur = 3.weeks + 6.days + 10.hours;
        immutable since = dur.timeSince(No.abbreviate);
        immutable abbrev = dur.timeSince(Yes.abbreviate);
        assert((since == "3 weeks, 6 days and 10 hours"), since);
        assert((abbrev == "3w 6d 10h"), abbrev);
    }
    {
        immutable dur = 377.days + 11.hours;
        immutable since = dur.timeSince!(6)(No.abbreviate);
        immutable abbrev = dur.timeSince!(6)(Yes.abbreviate);
        assert((since == "12 months, 2 weeks, 3 days and 11 hours"), since);
        assert((abbrev == "12m 2w 3d 11h"), abbrev);
    }
    {
        immutable dur = 395.days + 11.seconds;
        immutable since = dur.timeSince!(7, 1)(No.abbreviate);
        immutable abbrev = dur.timeSince!(7, 1)(Yes.abbreviate);
        assert((since == "1 year, 1 month and 5 days"), since);
        assert((abbrev == "1y 1m 5d"), abbrev);
    }
    {
        immutable dur = 1.weeks + 9.days;
        immutable since = dur.timeSince!(5)(No.abbreviate);
        immutable abbrev = dur.timeSince!(5)(Yes.abbreviate);
        assert((since == "2 weeks and 2 days"), since);
        assert((abbrev == "2w 2d"), abbrev);
    }
    {
        immutable dur = 30.days + 1.weeks;
        immutable since = dur.timeSince!(5)(No.abbreviate);
        immutable abbrev = dur.timeSince!(5)(Yes.abbreviate);
        assert((since == "5 weeks and 2 days"), since);
        assert((abbrev == "5w 2d"), abbrev);
    }
    {
        immutable dur = 30.days + 1.weeks + 1.seconds;
        immutable since = dur.timeSince!(4, 0)(No.abbreviate);
        immutable abbrev = dur.timeSince!(4, 0)(Yes.abbreviate);
        assert((since == "37 days and 1 second"), since);
        assert((abbrev == "37d 1s"), abbrev);
    }
    {
        immutable dur = 267.weeks + 4.days + 9.hours + 15.minutes + 1.seconds;
        immutable since = dur.timeSince!(7, 0)(No.abbreviate);
        immutable abbrev = dur.timeSince!(7, 0)(Yes.abbreviate);
        assert((since == "5 years, 2 months, 1 week, 6 days, 9 hours, 15 minutes and 1 second"), since);
        assert((abbrev == "5y 2m 1w 6d 9h 15m 1s"), abbrev);
    }
    {
        immutable dur = 360.days + 350.days;
        immutable since = dur.timeSince!(7, 6)(No.abbreviate);
        immutable abbrev = dur.timeSince!(7, 6)(Yes.abbreviate);
        assert((since == "1 year"), since);
        assert((abbrev == "1y"), abbrev);
    }
    {
        immutable dur = 267.weeks + 4.days + 9.hours + 15.minutes + 1.seconds;
        immutable since = dur.timeSince!(7, 3)(No.abbreviate);
        immutable abbrev = dur.timeSince!(7, 3)(Yes.abbreviate);
        assert((since == "5 years, 2 months, 1 week and 6 days"), since);
        assert((abbrev == "5y 2m 1w 6d"), abbrev);
    }
}


// stripSeparatedPrefix
/++
    Strips a prefix word from a string, optionally also stripping away some
    non-word characters (currently ":;?! ").

    This is to make a helper for stripping away bot prefixes, where such may be
    "kameloso: ".

    Example:
    ---
    string prefixed = "kameloso: sudo MODE +o #channel :user";
    string command = prefixed.stripSeparatedPrefix("kameloso");
    assert((command == "sudo MODE +o #channel :user"), command);
    ---

    Params:
        line = String line prefixed with `prefix`, potentially including
            separating characters.
        prefix = Prefix to strip.
        demandSep = Makes it a necessity that `line` is followed
            by one of the prefix letters ": !?;". If it isn't, the `line` string
            will be returned as is.

    Returns:
        The passed line with the `prefix` sliced away.
 +/
string stripSeparatedPrefix(const string line,
    const string prefix,
    const Flag!"demandSeparatingChars" demandSep = Yes.demandSeparatingChars) pure @nogc
in (prefix.length, "Tried to strip separated prefix but no prefix was given")
{
    import lu.string : nom, strippedLeft;
    import std.algorithm.comparison : among;
    import std.meta : aliasSeqOf;

    enum separatingChars = ": !?;";  // In reasonable order of likelihood

    string slice = line.strippedLeft;  // mutable

    // the onus is on the caller that slice begins with prefix, else this will throw
    slice.nom!(Yes.decode)(prefix);

    if (demandSep)
    {
        // Return the whole line, a non-match, if there are no separating characters
        // (at least one of the chars in separatingChars)
        if (!slice.length || !slice[0].among!(aliasSeqOf!separatingChars)) return line;
    }

    while (slice.length && slice[0].among!(aliasSeqOf!separatingChars))
    {
        slice = slice[1..$];
    }

    return slice.strippedLeft(separatingChars);
}

///
unittest
{
    immutable lorem = "say: lorem ipsum".stripSeparatedPrefix("say");
    assert((lorem == "lorem ipsum"), lorem);

    immutable notehello = "note!!!! zorael hello".stripSeparatedPrefix("note");
    assert((notehello == "zorael hello"), notehello);

    immutable sudoquit = "sudo quit :derp".stripSeparatedPrefix("sudo");
    assert((sudoquit == "quit :derp"), sudoquit);

    /*immutable eightball = "8ball predicate?".stripSeparatedPrefix("");
    assert((eightball == "8ball predicate?"), eightball);*/

    immutable isnotabot = "kamelosois a bot".stripSeparatedPrefix("kameloso");
    assert((isnotabot == "kamelosois a bot"), isnotabot);

    immutable isabot = "kamelosois a bot"
        .stripSeparatedPrefix("kameloso", No.demandSeparatingChars);
    assert((isabot == "is a bot"), isabot);

    immutable doubles = "kameloso            is a snek"
        .stripSeparatedPrefix("kameloso");
    assert((doubles == "is a snek"), doubles);
}


// Tint
/++
    Compatibility forwarding to `kameloso.terminal.colours.Tint`.
 +/
deprecated("Use `kameloso.terminal.colours.Tint` instead, or ideally expanding tags")
import kameloso.terminal.colours : Tint;


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
//deprecated("Use `kameloso.terminal.colours.expandTags` instead")
T expandTags(T)(const T line, const LogLevel baseLevel, const Flag!"strip" strip) @safe
{
    return line;
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
//deprecated("Use `kameloso.terminal.colours.expandTags` instead")
T expandTags(T)(const T line, const Flag!"strip" strip) @safe
{
    return line;
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
//deprecated("Use `kameloso.terminal.colours.expandTags` instead")
T expandTags(T)(const T line, const LogLevel baseLevel) @safe
{
    return line;
}


// replaceTokens
/++
    Apply some common text replacements. Used on part and quit reasons.

    Params:
        line = String to replace tokens in.
        client = The current [dialect.defs.IRCClient|IRCClient].

    Returns:
        A modified string with token occurrences replaced.
 +/
string replaceTokens(const string line, const IRCClient client) @safe pure nothrow
{
    import kameloso.constants : KamelosoInfo;
    import std.array : replace;

    return line
        .replaceTokens
        .replace("$nickname", client.nickname);
}

///
unittest
{
    import kameloso.constants : KamelosoInfo;
    import std.format : format;

    IRCClient client;
    client.nickname = "harbl";

    {
        immutable line = "asdf $nickname is kameloso version $version from $source";
        immutable expected = "asdf %s is kameloso version %s from %s"
            .format(client.nickname, cast(string)KamelosoInfo.version_,
                cast(string)KamelosoInfo.source);
        immutable actual = line.replaceTokens(client);
        assert((actual == expected), actual);
    }
    {
        immutable line = "";
        immutable expected = "";
        immutable actual = line.replaceTokens(client);
        assert((actual == expected), actual);
    }
    {
        immutable line = "blerp";
        immutable expected = "blerp";
        immutable actual = line.replaceTokens(client);
        assert((actual == expected), actual);
    }
}


// replaceTokens
/++
    Apply some common text replacements. Used on part and quit reasons.
    Overload that doesn't take an [dialect.defs.IRCClient|IRCClient] and as such can't
    replace `$nickname`.

    Params:
        line = String to replace tokens in.

    Returns:
        A modified string with token occurrences replaced.
 +/
string replaceTokens(const string line) @safe pure nothrow
{
    import kameloso.constants : KamelosoInfo;
    import std.array : replace;

    return line
        .replace("$version", cast(string)KamelosoInfo.version_)
        .replace("$source", cast(string)KamelosoInfo.source);
}


// nextMidnight
/++
    Returns a [std.datetime.systime.SysTime|SysTime] of the following midnight.

    Example:
    ---
    immutable now = Clock.currTime;
    immutable midnight = now.nextMidnight;
    writeln("Time until next midnight: ", (midnight - now));
    ---

    Params:
        now = A [std.datetime.systime.SysTime|SysTime] of the base date from
            which to proceed to the next midnight.

    Returns:
        A [std.datetime.systime.SysTime|SysTime] of the midnight following the date
        passed as argument.
 +/
SysTime nextMidnight(const SysTime now)
{
    import std.datetime : DateTime;
    import std.datetime.systime : SysTime;

    /+
        The difference between rolling and adding is that rolling does not affect
        larger units. For instance, rolling a SysTime one year's worth of days
        gets the exact same SysTime.
     +/

    auto next = SysTime(DateTime(now.year, now.month, now.day, 0, 0, 0), now.timezone)
        .roll!"days"(1);

    if (next.day == 1)
    {
        next.add!"months"(1);
    }

    return next;
}

///
unittest
{
    import std.datetime : DateTime;
    import std.datetime.systime : SysTime;
    import std.datetime.timezone : UTC;

    immutable utc = UTC();

    immutable christmasEve = SysTime(DateTime(2018, 12, 24, 12, 34, 56), utc);
    immutable nextDay = christmasEve.nextMidnight;
    immutable christmasDay = SysTime(DateTime(2018, 12, 25, 0, 0, 0), utc);
    assert(nextDay.toUnixTime == christmasDay.toUnixTime);

    immutable someDay = SysTime(DateTime(2018, 6, 30, 12, 27, 56), utc);
    immutable afterSomeDay = someDay.nextMidnight;
    immutable afterSomeDayToo = SysTime(DateTime(2018, 7, 1, 0, 0, 0), utc);
    assert(afterSomeDay == afterSomeDayToo);

    immutable newyearsEve = SysTime(DateTime(2018, 12, 31, 0, 0, 0), utc);
    immutable newyearsDay = newyearsEve.nextMidnight;
    immutable alsoNewyearsDay = SysTime(DateTime(2019, 1, 1, 0, 0, 0), utc);
    assert(newyearsDay == alsoNewyearsDay);

    immutable troubleDay = SysTime(DateTime(2018, 6, 30, 19, 14, 51), utc);
    immutable afterTrouble = troubleDay.nextMidnight;
    immutable alsoAfterTrouble = SysTime(DateTime(2018, 7, 1, 0, 0, 0), utc);
    assert(afterTrouble == alsoAfterTrouble);

    immutable novDay = SysTime(DateTime(2019, 11, 30, 12, 34, 56), utc);
    immutable decDay = novDay.nextMidnight;
    immutable alsoDecDay = SysTime(DateTime(2019, 12, 1, 0, 0, 0), utc);
    assert(decDay == alsoDecDay);

    immutable lastMarch = SysTime(DateTime(2005, 3, 31, 23, 59, 59), utc);
    immutable firstApril = lastMarch.nextMidnight;
    immutable alsoFirstApril = SysTime(DateTime(2005, 4, 1, 0, 0, 0), utc);
    assert(firstApril == alsoFirstApril);
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


// pluginFileBaseName
/++
    Returns a meaningful basename of a plugin filename.

    This is preferred over use of [std.path.baseName] because some plugins are
    nested in their own directories. The basename of `plugins/twitch/base.d` is
    `base.d`, much like that of `plugins/printer/base.d` is.

    With this we get `twitch/base.d` and `printer/base.d` instead, while still
    getting `oneliners.d`.

    Params:
        filename = Full path to a plugin file.

    Returns:
        A meaningful basename of the passed filename.
 +/
auto pluginFileBaseName(const string filename)
in (filename.length, "Empty plugin filename passed to `pluginFileBaseName`")
{
    return pluginFilenameSlicerImpl(filename, No.getPluginName);
}

///
unittest
{
    {
        version(Posix) enum filename = "plugins/oneliners.d";
        else /*version(Windows)*/ enum filename = "plugins\\oneliners.d";
        immutable expected = "oneliners.d";
        immutable actual = pluginFileBaseName(filename);
        assert((expected == actual), actual);
    }
    {
        version(Posix)
        {
            enum filename = "plugins/twitch/base.d";
            immutable expected = "twitch/base.d";
        }
        else /*version(Windows)*/
        {
            enum filename = "plugins\\twitch\\base.d";
            immutable expected = "twitch\\base.d";
        }

        immutable actual = pluginFileBaseName(filename);
        assert((expected == actual), actual);
    }
    {
        version(Posix) enum filename = "plugins/counters.d";
        else /*version(Windows)*/ enum filename = "plugins\\counters.d";
        immutable expected = "counters.d";
        immutable actual = pluginFileBaseName(filename);
        assert((expected == actual), actual);
    }
}


// pluginNameOfFilename
/++
    Returns the name of a plugin based on its filename.

    This is preferred over slicing [std.path.baseName] because some plugins are
    nested in their own directories. The basename of `plugins/twitch/base.d` is
    `base.d`, much like that of `plugins/printer/base.d` is.

    With this we get `twitch` and `printer` instead, while still getting `oneliners`.

    Params:
        filename = Full path to a plugin file.

    Returns:
        The name of the plugin, based on its filename.
 +/
auto pluginNameOfFilename(const string filename)
in (filename.length, "Empty plugin filename passed to `pluginNameOfFilename`")
{
    return pluginFilenameSlicerImpl(filename, Yes.getPluginName);
}

///
unittest
{
    {
        version(Posix) enum filename = "plugins/oneliners.d";
        else /*version(Windows)*/ enum filename = "plugins\\oneliners.d";
        immutable expected = "oneliners";
        immutable actual = pluginNameOfFilename(filename);
        assert((expected == actual), actual);
    }
    {
        version(Posix) enum filename = "plugins/twitch/base.d";
        else /*version(Windows)*/ enum filename = "plugins\\twitch\\base.d";
        immutable expected = "twitch";
        immutable actual = pluginNameOfFilename(filename);
        assert((expected == actual), actual);
    }
    {
        version(Posix) enum filename = "plugins/counters.d";
        else /*version(Windows)*/ enum filename = "plugins\\counters.d";
        immutable expected = "counters";
        immutable actual = pluginNameOfFilename(filename);
        assert((expected == actual), actual);
    }
}


// pluginFilenameSlicerImpl
/++
    Implementation function, code shared between [pluginFileBaseName] and
    [pluginNameOfFilename].

    Params:
        filename = Full path to a plugin file.
        getPluginName = Whether we want the plugin name or the plugin file "basename".

    Returns:
        The name of the plugin or its "basename", based on its filename and the
        `getPluginName` parameter.
 +/
private auto pluginFilenameSlicerImpl(const string filename, const Flag!"getPluginName" getPluginName)
in (filename.length, "Empty plugin filename passed to `pluginFilenameSlicerImpl`")
{
    import std.path : dirSeparator;
    import std.string : indexOf;

    string slice = filename;  // mutable
    size_t pos = slice.indexOf(dirSeparator);

    while (pos != -1)
    {
        if (slice[pos+1..$] == "base.d")
        {
            return getPluginName ? slice[0..pos] : slice;
        }
        slice = slice[pos+1..$];
        pos = slice.indexOf(dirSeparator);
    }

    return getPluginName ? slice[0..$-2] : slice;
}


// splitWithQuotes
/++
    Splits a string into an array of strings by whitespace, but honours quotes.

    Intended to be used with ASCII strings; may or may not work with more
    elaborate UTF-8 strings.

    TODO: Replace with [lu.string.splitWithQuotes] after its next release.

    Example:
    ---
    string s = `title "this is my title" author "john doe"`;
    immutable splitUp = splitWithQuotes(s);
    assert(splitUp == [ "title", "this is my title", "author", "john doe" ]);
    ---

    Params:
        line = Input string.

    Returns:
        A `string[]` composed of the input string split up into substrings,
        deliminated by whitespace. Quoted sections are treated as one substring.
 +/
auto splitWithQuotes(const string line)
{
    import std.array : Appender;
    import std.string : representation;

    if (!line.length) return null;

    Appender!(string[]) sink;
    sink.reserve(8);

    size_t start;
    bool betweenQuotes;
    bool escaping;
    bool escapedAQuote;
    bool escapedABackslash;

    string replaceEscaped(const string line)
    {
        import std.array : replace;

        string slice = line;  // mutable
        if (escapedABackslash) slice = slice.replace(`\\`, "\1\1");
        if (escapedAQuote) slice = slice.replace(`\"`, `"`);
        if (escapedABackslash) slice = slice.replace("\1\1", `\`);
        return slice;
    }

    foreach (immutable i, immutable c; line.representation)
    {
        if (escaping)
        {
            if (c == '\\')
            {
                escapedABackslash = true;
            }
            else if (c == '"')
            {
                escapedAQuote = true;
            }

            escaping = false;
        }
        else if (c == ' ')
        {
            if (betweenQuotes)
            {
                // do nothing
            }
            else if (i == start)
            {
                ++start;
            }
            else
            {
                // commit
                sink.put(line[start..i]);
                start = i+1;
            }
        }
        else if (c == '\\')
        {
            escaping = true;
        }
        else if (c == '"')
        {
            if (betweenQuotes)
            {
                if (escapedAQuote || escapedABackslash)
                {
                    sink.put(replaceEscaped(line[start+1..i]));
                    escapedAQuote = false;
                    escapedABackslash = false;
                }
                else if (i > start+1)
                {
                    sink.put(line[start+1..i]);
                }

                betweenQuotes = false;
                start = i+1;
            }
            else if (i > start+1)
            {
                sink.put(line[start+1..i]);
                betweenQuotes = true;
                start = i+1;
            }
            else
            {
                betweenQuotes = true;
            }
        }
    }

    if (line.length > start+1)
    {
        if (betweenQuotes)
        {
            if (escapedAQuote || escapedABackslash)
            {
                sink.put(replaceEscaped(line[start+1..$]));
            }
            else
            {
                sink.put(line[start+1..$]);
            }
        }
        else
        {
            sink.put(line[start..$]);
        }
    }

    return sink.data;
}

///
unittest
{
    import std.conv : text;

    {
        enum input = `title "this is my title" author "john doe"`;
        immutable splitUp = splitWithQuotes(input);
        immutable expected =
        [
            "title",
            "this is my title",
            "author",
            "john doe"
        ];
        assert(splitUp == expected, splitUp.text);
    }
    {
        enum input = `string without quotes`;
        immutable splitUp = splitWithQuotes(input);
        immutable expected =
        [
            "string",
            "without",
            "quotes",
        ];
        assert(splitUp == expected, splitUp.text);
    }
    {
        enum input = string.init;
        immutable splitUp = splitWithQuotes(input);
        immutable expected = (string[]).init;
        assert(splitUp == expected, splitUp.text);
    }
    {
        enum input = `title "this is \"my\" title" author "john\\" doe`;
        immutable splitUp = splitWithQuotes(input);
        immutable expected =
        [
            "title",
            `this is "my" title`,
            "author",
            `john\`,
            "doe"
        ];
        assert(splitUp == expected, splitUp.text);
    }
    {
        enum input = `title "this is \"my\" title" author "john\\\" doe`;
        immutable splitUp = splitWithQuotes(input);
        immutable expected =
        [
            "title",
            `this is "my" title`,
            "author",
            `john\" doe`
        ];
        assert(splitUp == expected, splitUp.text);
    }
    {
        enum input = `this has "unbalanced quotes`;
        immutable splitUp = splitWithQuotes(input);
        immutable expected =
        [
            "this",
            "has",
            "unbalanced quotes"
        ];
        assert(splitUp == expected, splitUp.text);
    }
    {
        enum input = `""`;
        immutable splitUp = splitWithQuotes(input);
        immutable expected = (string[]).init;
        assert(splitUp == expected, splitUp.text);
    }
    {
        enum input = `"`;
        immutable splitUp = splitWithQuotes(input);
        immutable expected = (string[]).init;
        assert(splitUp == expected, splitUp.text);
    }
    {
        enum input = `"""""""""""`;
        immutable splitUp = splitWithQuotes(input);
        immutable expected = (string[]).init;
        assert(splitUp == expected, splitUp.text);
    }
}


// abbreviatedDuration
/++
    Constructs a [core.time.Duration|Duration] from a string, assumed to be in a
    `*d*h*m*s` pattern.

    Params:
        line = Abbreviated string line.

    Returns:
        A [core.time.Duration|Duration] as described in the input string.
 +/
auto abbreviatedDuration(const string line)
{
    import lu.string : contains, nom;
    import std.conv : to;
    import core.time : days, hours, minutes, seconds;

    static int getAbbreviatedValue(ref string slice, const char c)
    {
        if (slice.contains(c))
        {
            immutable valueString = slice.nom(c);
            immutable value = valueString.length ? valueString.to!int : 0;
            if (value < 0) throw new Exception("Cannot have a negative value mid-string");
            return value;
        }
        return 0;
    }

    string slice = line; // mutable
    int sign = 1;

    if (slice.length && (slice[0] == '-'))
    {
        sign = -1;
        slice = slice[1..$];
    }

    immutable numDays = getAbbreviatedValue(slice, 'd');
    immutable numHours = getAbbreviatedValue(slice, 'h');
    immutable numMinutes = getAbbreviatedValue(slice, 'm');
    int numSeconds;

    if (slice.length)
    {
        immutable valueString = slice.nom!(Yes.inherit)('s');
        if (!valueString.length) throw new Exception("Invalid duration pattern");
        numSeconds = valueString.length ? valueString.to!int : 0;
    }

    if ((numDays < 0) || (numHours < 0) || (numMinutes < 0) || (numSeconds < 0))
    {
        throw new Exception("Time values must not be individually negative");
    }

    return sign * (numDays.days + numHours.hours + numMinutes.minutes + numSeconds.seconds);
}

///
unittest
{
    import std.conv : text;
    import std.exception : assertThrown;
    import core.time : days, hours, minutes, seconds;

    {
        enum line = "30";
        immutable actual = abbreviatedDuration(line);
        immutable expected = 30.seconds;
        assert((actual == expected), actual.text);
    }
    {
        enum line = "30s";
        immutable actual = abbreviatedDuration(line);
        immutable expected = 30.seconds;
        assert((actual == expected), actual.text);
    }
    {
        enum line = "1h30s";
        immutable actual = abbreviatedDuration(line);
        immutable expected = 1.hours + 30.seconds;
        assert((actual == expected), actual.text);
    }
    {
        enum line = "5h";
        immutable actual = abbreviatedDuration(line);
        immutable expected = 5.hours;
        assert((actual == expected), actual.text);
    }
    {
        enum line = "1d12h39m40s";
        immutable actual = abbreviatedDuration(line);
        immutable expected = 1.days + 12.hours + 39.minutes + 40.seconds;
        assert((actual == expected), actual.text);
    }
    {
        enum line = "1d4s";
        immutable actual = abbreviatedDuration(line);
        immutable expected = 1.days + 4.seconds;
        assert((actual == expected), actual.text);
    }
    {
        enum line = "30s";
        immutable actual = abbreviatedDuration(line);
        immutable expected = 30.seconds;
        assert((actual == expected), actual.text);
    }
    {
        enum line = "-30s";
        immutable actual = abbreviatedDuration(line);
        immutable expected = (-30).seconds;
        assert((actual == expected), actual.text);
    }
    {
        import core.time : Duration;
        enum line = string.init;
        immutable actual = abbreviatedDuration(line);
        immutable expected = Duration.zero;
        assert((actual == expected), actual.text);
    }
    {
        enum line = "s";
        assertThrown(abbreviatedDuration(line));
    }
    {
        enum line = "1d1h1m1z";
        assertThrown(abbreviatedDuration(line));
    }
    {
        enum line = "2h-30m";
        assertThrown(abbreviatedDuration(line));
    }
}
