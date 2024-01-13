/++
    The Webtitle plugin catches URLs pasted in a channel, follows them and
    reports back the title of the web page that was linked to.

    It has no bot commands; everything is done by automatically scanning channel
    and private query messages for things that look like links.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#webtitle,
        [kameloso.plugins.common.core],
        [kameloso.plugins.common.misc]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.webtitle;

version(WithWebtitlePlugin):

private:

import kameloso.plugins;
import kameloso.plugins.common.core;
import requests.base : Response;
import dialect.defs;
import lu.container : MutexedAA;
import std.typecons : Flag, No, Yes;
import core.thread : Fiber;


// WebtitleSettings
/++
    All Webtitle settings, gathered in a struct.
 +/
@Settings struct WebtitleSettings
{
    /++
        Toggles whether or not the plugin should react to events at all.
     +/
    @Enabler bool enabled = true;

    /++
        Minimum user class required for the plugin to scan messages for URLs.
     +/
    IRCUser.Class minimumPermissionsNeeded = IRCUser.Class.anyone;

    /++
        How many worker threads to use, to offload the HTTP requests to.
     +/
    uint workerThreads = 3;
}


// TitleLookupResult
/++
    A record of a URL lookup.

    This is both used to aggregate information about the lookup, as well as to
    add hysteresis to lookups, so we don't look the same one up over and over
    if they were pasted over and over.
 +/
struct TitleLookupResult
{
    /++
        Web page title, or YouTube video title.
     +/
    string title;

    /++
        The content of the web page's `description` tag.
     +/
    string description;

    /++
        Domain name of the looked up URL.
     +/
    string domain;

    /++
        YouTube video author, if such a YouTube link.
     +/
    string youtubeAuthor;

    /++
        URL that was looked up.
     +/
    string url;

    /++
        HTTP response status code.
     +/
    uint code;

    /++
        HTTP response body.
     +/
    string str;

    /++
        Message text if an exception was thrown during the lookup.
     +/
    string exceptionText;
}


// descriptionExemptions
/++
    Hostnames explicitly exempt from having their descriptions included after the titles.

    Must be in lowercase.
 +/
static immutable descriptionExemptions =
[
    "imgur.com",
];


// onMessage
/++
    Parses a message to see if the message contains one or more URLs.

    Merely passes the event on to [onMessageImpl].

    See_Also:
        [onMessageImpl]
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.ignore)
    .channelPolicy(ChannelPolicy.home)
)
void onMessage(WebtitlePlugin plugin, const ref IRCEvent event)
{
    if (event.sender.class_ < plugin.webtitleSettings.minimumPermissionsNeeded) return;
    onMessageImpl(plugin, event);
}


// onMessageImpl
/++
    Parses a message to see if the message contains one or more URLs.
    Implementation function.

    It uses a simple state machine in [kameloso.common.findURLs|findURLs] to
    exhaustively try to look up every URL returned by it.

    Params:
        plugin = The current [WebtitlePlugin].
        event = The [dialect.defs.IRCEvent|IRCEvent] that instigated the lookup.
 +/
void onMessageImpl(WebtitlePlugin plugin, const ref IRCEvent event)
{
    import kameloso.common : findURLs;
    import lu.string : strippedLeft;
    import std.algorithm.searching : startsWith;

    immutable content = event.content.strippedLeft;  // mutable

    if (!content.length ||
        (plugin.state.settings.prefix.length && content.startsWith(plugin.state.settings.prefix)))
    {
        return;
    }

    if (content.startsWith(plugin.state.client.nickname))
    {
        import kameloso.string : stripSeparatedPrefix;

        // If the message is a "nickname: command [url]" type of message,
        // don't catch the URL.
        immutable nicknameStripped = content.stripSeparatedPrefix(
            plugin.state.client.nickname,
            Yes.demandSeparatingChars);

        if (nicknameStripped != content) return;
    }

    auto urls = findURLs(event.content);  // mutable so advancePast in lookupURLs works

    if (urls.length)
    {
        lookupURLs(plugin, event, urls);
    }
}


// lookupURLs
/++
    Looks up the URLs in the passed `string[]` `urls` by spawning a worker
    thread to do all the work.

    Params:
        plugin = The current [WebtitlePlugin].
        event = The [dialect.defs.IRCEvent|IRCEvent] that instigated the lookup.
        urls = `string[]` of URLs to look up.
 +/
void lookupURLs(
    WebtitlePlugin plugin,
    const /*ref*/ IRCEvent event,
    /*const*/ string[] urls)
{
    import kameloso.plugins.common.delayawait : delay;
    import kameloso.common : logger;
    import kameloso.constants : BufferSize;
    import lu.array: uniqueKey;
    import lu.string : advancePast;
    import std.concurrency : send, spawn;
    import core.time : Duration;

    bool[string] uniques;

    foreach (immutable i, url; urls)
    {
        // If the URL contains an octothorpe fragment identifier, like
        // https://www.google.com/index.html#this%20bit
        // then strip that.
        url = url.advancePast('#', Yes.inherit);
        while (url[$-1] == '/') url = url[0..$-1];

        if (url in uniques) continue;
        uniques[url] = true;
    }

    void lookupURLsDg()
    {
        foreach (immutable url, _; uniques)
        {
            import kameloso.messaging : reply;
            import std.format : format;

            enum caughtPattern = "Caught URL: <l>%s";
            logger.infof(caughtPattern, url);

            const result = sendHTTPRequest(plugin, url);

            if (result.exceptionText.length)
            {
                logger.warning("HTTP exception: <l>", result.exceptionText);
                continue;
            }

            if ((result.code < 200) ||
                (result.code > 299))
            {
                import kameloso.common : getHTTPResponseCodeText;

                enum pattern = "HTTP status <l>%03d</> (%s) fetching <l>%s";
                logger.warningf(
                    pattern,
                    result.code,
                    getHTTPResponseCodeText(result.code),
                    result.url);
                continue;
            }

            if (!result.title.length)
            {
                enum pattern = "No title found <t>(%s)";
                logger.infof(pattern, url);
                continue;
            }

            if (result.youtubeAuthor.length)
            {
                enum pattern = "[<b>youtube.com<b>] %s (uploaded by <h>%s<h>)";
                immutable message = pattern.format(result.title, result.youtubeAuthor);
                reply(plugin.state, event, message);
            }
            else
            {
                enum pattern = "[<b>%s<b>] %s%s";
                immutable maybeDescription = result.description.length ?
                    " | "  ~ result.description :
                    string.init;

                string line = pattern.format(
                    result.domain,
                    result.title,
                    maybeDescription);  // mutable

                // "PRIVMSG #12345678901234567890123456789012345678901234567890 :".length == 61
                enum maxLen = (512-2-61);

                if (line.length > maxLen)
                {
                    enum endingEllipsis = " [...]";
                    line = line[0..(maxLen-endingEllipsis.length)] ~ endingEllipsis;
                }

                reply(plugin.state, event, line);
            }
        }
    }

    auto lookupURLsFiber = new Fiber(&lookupURLsDg, BufferSize.fiberStack);
    delay(plugin, lookupURLsFiber, Duration.zero);
}


// waitForLookupResults
/++
    Given an `int` id, monitors the [WebtitlePlugin.lookupBucket|lookupBucket]
    until a value with that key becomes available, delaying itself in between checks.

    If it resolves, it returns that value. If it doesn't resolve within
    [kameloso.constants.Timeout.httpGET|Timeout.httpGET]*2 seconds, it signals
    failure by instead returning an empty [TitleLookupResult|TitleLookupResult.init].

    Params:
        plugin = The current [WebtitlePlugin].
        id = `int` id key to monitor [WebtitlePlugin.lookupBucket] for.

    Returns:
        A [TitleLookupResult] as discovered in the [WebtitlePlugin.lookupBucket|lookupBucket],
        or a [TitleLookupResult|TitleLookupResult.init] if there were none to be
        found within [kameloso.constants.Timeout.httpGET|Timeout.httpGET] seconds.
 +/
auto waitForLookupResults(WebtitlePlugin plugin, const int id)
in (Fiber.getThis(), "Tried to call `waitForLookupResults` from outside a fiber")
{
    import std.datetime.systime : Clock;

    immutable startTimeInUnix = Clock.currTime.toUnixTime();
    enum timeoutMultiplier = 2;

    while (true)
    {
        immutable hasResult = plugin.lookupBucket.has(id);

        if (!hasResult)
        {
            // Querier errored or otherwise gave up
            // No need to remove the id, it's not there
            return TitleLookupResult.init;
        }

        //auto result = plugin.lookupBucket[id];  // potential range error due to TOCTTOU
        immutable result = plugin.lookupBucket.get(id, TitleLookupResult.init);

        if (result == TitleLookupResult.init)
        {
            import kameloso.plugins.common.delayawait : delay;
            import kameloso.constants : Timeout;
            import core.time : msecs;

            immutable nowInUnix = Clock.currTime.toUnixTime();

            if ((nowInUnix - startTimeInUnix) >= (Timeout.httpGET * timeoutMultiplier))
            {
                plugin.lookupBucket.remove(id);
                return result;
            }

            // Wait a bit before checking again
            static immutable checkDelay = 200.msecs;
            delay(plugin, checkDelay, Yes.yield);
            continue;
        }
        else
        {
            // Got a result; remove it from the bucket and return it
            plugin.lookupBucket.remove(id);
            return result;
        }
    }
}


// onEndOfMotd
/++
    Starts the persistent querier worker thread on end of MOTD.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_ENDOFMOTD)
    .onEvent(IRCEvent.Type.ERR_NOMOTD)
)
void onEndOfMotd(WebtitlePlugin plugin, const ref IRCEvent event)
{
    import std.algorithm.comparison : max;

    // Use a minimum of one worker thread, regardless of setting
    plugin.transient.workerTids.length =
        max(plugin.webtitleSettings.workerThreads, 1);

    foreach (ref workerTid; plugin.transient.workerTids)
    {
        import std.concurrency : Tid, spawn;

        if (workerTid != Tid.init) continue;  // to be safe

        workerTid = spawn(
            &persistentQuerier,
            plugin.lookupBucket,
            plugin.state.connSettings.caBundleFile);
    }
}


// persistentQuerier
/++
    Persistent querier worker thread function.

    Params:
        lookupBucket = Associative array to fill with [TitleLookupResult]s.
        caBundleFile = Path to `cacert.pem` file, or an empty string if none
            should be needed.
 +/
void persistentQuerier(
    MutexedAA!(TitleLookupResult[int]) lookupBucket,
    const string caBundleFile)
{
    version(Posix)
    {
        import kameloso.thread : setThreadName;
        setThreadName("webworker");
    }

    void onTitleRequest(string url, int id) scope
    {
        import lu.string : advancePast;
        import std.algorithm.searching : startsWith;
        import std.string : indexOf;

        TitleLookupResult result;

        if (url.indexOf("://i.imgur.com/") != -1)
        {
            // imgur direct links naturally have no titles, but the normal pages do.
            // Rewrite and look those up instead.
            url = rewriteDirectImgurURL(url);
        }
        else if (
            (url.indexOf("youtube.com/watch?v=") != -1) ||
            (url.indexOf("youtu.be/") != -1))
        {
            // Do our own slicing instead of using regexes, because footprint.
            string slice = url;  // mutable

            slice.advancePast("http");
            if (slice[0] == 's') slice = slice[1..$];
            slice = slice["://".length..$];

            if (slice.startsWith("www.")) slice = slice[4..$];

            if (slice.startsWith("youtube.com/watch?v=") ||
                slice.startsWith("youtu.be/"))
            {
                immutable youtubeURL = "https://www.youtube.com/oembed?format=json&url=" ~ url;
                result = sendHTTPRequestImpl(youtubeURL, caBundleFile);

                if (result.exceptionText.length)
                {
                    // Either requests threw an exception or it's something like UnicodeException
                    // Drop down and try the original URL
                }
                else if (!result.code || (result.code < 10) || (result.code >= 400))
                {
                    // Not sure when this can happen; drop down to the normal lookup
                }
                else
                {
                    import std.json : parseJSON;
                    immutable youtubeJSON = parseJSON(cast(string)result.str);
                    result.title = decodeEntities(youtubeJSON["title"].str);
                    result.youtubeAuthor = decodeEntities(youtubeJSON["author_name"].str);
                }
            }
        }

        if (!result.title.length) // && !result.exceptionText.length)
        {
            static immutable bool[2] trueThenFalse = [ true, false ];

            foreach (immutable firstTime; trueThenFalse[])
            {
                result = sendHTTPRequestImpl(url, caBundleFile);

                if (result.exceptionText.length)
                {
                    // Either requests threw an exception or it's something like UnicodeException
                    break;  // drop down to abort
                }
                else if (!result.code || (result.code < 10))
                {
                    // SSL error?
                    // Don't include >= 400; we might get a hit later by rewriting the url
                    break;  // as above
                }
                else if (result.title.length && (result.code < 400))
                {
                    // Title found
                    break;  // ditty
                }
                else if (firstTime)
                {
                    // Still the first iteration, try rewriting the URL
                    if (url[$-1] == '/')
                    {
                        url = url[0..$-1];
                    }
                    else
                    {
                        url ~= '/';
                    }
                }
            }
        }

        if (result != TitleLookupResult.init)
        {
            // Modified in some way; store it
            lookupBucket[id] = result;
        }
        else
        {
            // Signal failure by removing the key
            lookupBucket.remove(id);
        }
    }

    bool halt;

    void onQuitMessage(bool) scope
    {
        halt = true;
    }

    while (!halt)
    {
        try
        {
            import std.concurrency : receive;
            import std.variant : Variant;

            receive(
                &onTitleRequest,
                &onQuitMessage,
                (Variant v)
                {
                    import std.stdio : stdout, writeln;
                    writeln("Webtitle worker received unknown Variant: ", v);
                    stdout.flush();
                }
            );
        }
        catch (Exception _)
        {
            // Probably a requests exception
            /*writeln("Webtitle worker caught exception: ", e.msg);
            version(PrintStacktraces) writeln(e);
            stdout.flush();*/
        }
    }
}


// sendHTTPRequest
/++
    Issues an HTTP request by sending the details to the persistent querier thread,
    then returns the results after they become available in the shared associative array.

    Params:
        plugin = The current [WebtitlePlugin].
        url = URL string to fetch.
        recursing = Whether or not this is a recursive call.
        id = Optional `int` id key to [WebtitlePlugin.lookupBucket].
        caller = Optional name of the calling function.

    Returns:
        A [TitleLookupResult] with contents based on what was read from the URL.
 +/
TitleLookupResult sendHTTPRequest(
    WebtitlePlugin plugin,
    const string url,
    const Flag!"recursing" recursing = No.recursing,
    /*const*/ int id = 0,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `sendHTTPRequest` from outside a fiber")
in (url.length, "Tried to send an HTTP request without a URL")
{
    import kameloso.plugins.common.delayawait : delay;
    import kameloso.thread : ThreadMessage;
    import std.concurrency : send;
    import core.time : msecs;

    version(TraceHTTPRequests)
    {
        import kameloso.common : logger;
        import lu.conv : Enum;

        enum pattern = "get: <i>%s<t> (%s)";
        logger.tracef(
            pattern,
            url,
            caller);
    }

    plugin.state.priorityMessages ~= ThreadMessage.shortenReceiveTimeout;

    if (!id) id = plugin.lookupBucket.uniqueKey;
    plugin.getNextWorkerTid().send(url, id);

    static immutable initialDelay = 500.msecs;
    delay(plugin, initialDelay, Yes.yield);

    immutable result = waitForLookupResults(plugin, id);

    if (result.code == 0) //(!result.title.length)
    {
        // ?
    }
    else if (result.code < 10)
    {
        // ?
    }
    else if ((result.code >= 500) && !recursing)
    {
        return sendHTTPRequest(
            plugin,
            url,
            Yes.recursing,
            id,
            caller);
    }
    else if (result.code >= 400)
    {
        // ?
    }

    return result;
}


// sendHTTPRequestImpl
/++
    Fetches the contents of a URL, parses it into a [TitleLookupResult] and returns it.

    Params:
        url = URL string to fetch.
        caBundleFile = Path to a `cacert.pem` SSL certificate bundle.

    Returns:
        A [TitleLookupResult] with contents based on what was read from the URL.
 +/
auto sendHTTPRequestImpl(
    const string url,
    const string caBundleFile)
{
    import kameloso.constants : KamelosoInfo, Timeout;
    import requests.base : Response;
    import requests.request : Request;
    import core.time : seconds;

    static string[string] headers;

    if (!headers.length)
    {
        headers =
        [
            "User-Agent" : "kameloso/" ~ cast(string)KamelosoInfo.version_,
        ];
    }

    auto req = Request();
    //req.verbosity = 1;
    req.keepAlive = false;
    req.timeout = Timeout.httpGET.seconds;
    req.addHeaders(headers);
    if (caBundleFile.length) req.sslSetCaCert(caBundleFile);

    try
    {
        return req
            .get(url)
            .parseResponseIntoTitleLookupResult();
    }
    catch (Exception e)
    {
        TitleLookupResult result;
        result.url = url;
        result.exceptionText = e.msg;
        return result;
    }
}


// parseResponseIntoTitleLookupResult
/++
    Parses a [requests] `Response` into a [TitleLookupResult].

    Params:
        res = [requests] `Response` to parse.

    Returns:
        A [TitleLookupResult] with contents based on what was read from the URL.
 +/
auto parseResponseIntoTitleLookupResult(/*const*/ Response res)
{
    import arsd.dom : Document;
    import std.algorithm.searching : canFind, startsWith;

    TitleLookupResult result;
    result.code = res.code;
    result.url = res.uri.uri;
    result.str = cast(string)res.responseBody;  // .idup?

    enum unnamedPagePlaceholder = "(Unnamed page)";

    if (!result.code || (result.code == 2) || (result.code >= 400))
    {
        // Invalid address, SSL error, 404, etc; no need to continue
        return result;
    }

    try
    {
        result.domain = res.finalURI.host.startsWith("www.") ?
            res.finalURI.host[4..$] :
            res.finalURI.host;

        auto doc = new Document;
        doc.parseGarbage(result.str);

        result.title = doc.title.length ?
            decodeEntities(doc.title) :
            unnamedPagePlaceholder;

        if (!descriptionExemptions.canFind(result.domain))
        {
            auto metaTags = doc.getElementsByTagName("meta");

            foreach (tag; metaTags)
            {
                if (tag.name == "description")
                {
                    result.description = decodeEntities(tag.content);
                    break;
                }
            }
        }
    }
    catch (Exception e)
    {
        // UnicodeException, UriException, ...
        result.exceptionText = e.msg;
    }

    return result;
}


// rewriteDirectImgurURL
/++
    Takes a direct imgur link (one that points to an image) and rewrites it to
    instead point to the image's page.

    Images (`jpg`, `png`, ...) can naturally not have titles, but the normal pages can.

    Params:
        url = String link to rewrite.

    Returns:
        A rewritten string if it's a compatible imgur one, else the passed `url`.
 +/
auto rewriteDirectImgurURL(const string url) @safe pure
{
    import lu.string : advancePast;
    import std.algorithm.searching : startsWith;
    import std.typecons : No, Yes;

    if (url.startsWith("https://i.imgur.com/"))
    {
        immutable path = url[20..$].advancePast('.');
        return "https://imgur.com/" ~ path;
    }
    else if (url.startsWith("http://i.imgur.com/"))
    {
        immutable path = url[19..$].advancePast('.');
        return "https://imgur.com/" ~ path;
    }

    return url;
}

///
unittest
{
    {
        immutable directURL = "https://i.imgur.com/URHe5og.jpg";
        immutable rewritten = rewriteDirectImgurURL(directURL);
        assert((rewritten == "https://imgur.com/URHe5og"), rewritten);
    }
    {
        immutable directURL = "http://i.imgur.com/URHe5og.jpg";
        immutable rewritten = rewriteDirectImgurURL(directURL);
        assert((rewritten == "https://imgur.com/URHe5og"), rewritten);
    }
}


// decodeEntities
/++
    Removes unwanted characters from a string, and decodes HTML entities in it
    (like `&mdash;` and `&nbsp;`).

    Params:
        line = String to decode entities and remove tags from.

    Returns:
        A modified string, with unwanted bits stripped out and/or decoded.
 +/
auto decodeEntities(const string line)
{
    import lu.string : stripped;
    import arsd.dom : htmlEntitiesDecode;
    import std.array : replace;

    return line
        .replace("\r", string.init)
        .replace('\n', ' ')
        .stripped
        .htmlEntitiesDecode();
}

///
unittest
{
    immutable t1 = "&quot;Hello&nbsp;world!&quot;";
    immutable t1p = decodeEntities(t1);
    assert((t1p == "\"Hello\u00A0world!\""), t1p);  // not a normal space

    immutable t2 = "&lt;/title&gt;";
    immutable t2p = decodeEntities(t2);
    assert((t2p == "</title>"), t2p);

    immutable t3 = "&mdash;&micro;&acute;&yen;&euro;";
    immutable t3p = decodeEntities(t3);
    assert((t3p == "—µ´¥€"), t3p);  // not a normal dash

    immutable t4 = "&quot;Se&ntilde;or &THORN;&quot; &copy;2017";
    immutable t4p = decodeEntities(t4);
    assert((t4p == `"Señor Þ" ©2017`), t4p);

    immutable t5 = "\n        Nyheter - NSD.se        \n";
    immutable t5p = decodeEntities(t5);
    assert(t5p == "Nyheter - NSD.se");
}


// TitleFetchException
/++
    A normal [object.Exception|Exception] but with an HTTP status code attached.
 +/
final class TitleFetchException : Exception
{
@safe:
    /++
        The URL that was attempted to fetch the title of.
     +/
    string url;

    /++
        The HTTP status code that was returned when attempting to fetch a title.
     +/
    uint code;

    /++
        Create a new [TitleFetchException], attaching a URL and an HTTP status code.
     +/
    this(
        const string message,
        const string url,
        const uint code,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        this.code = code;
        super(message, file, line, nextInChain);
    }

    /++
        Create a new [TitleFetchException], without attaching anything.
     +/
    this(
        const string message,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }
}


// setup
/++
    Initialises the lookup bucket, else its internal [core.sync.mutex.Mutex|Mutex]
    will be null and cause a segfault when trying to lock it.
 +/
void setup(WebtitlePlugin plugin)
{
    plugin.lookupBucket.setup();
}


// teardown
/++
    Stops the persistent querier worker threads.
 +/
void teardown(WebtitlePlugin plugin)
{
    foreach (workerTid; plugin.transient.workerTids)
    {
        import std.concurrency : Tid, send;

        if (workerTid == Tid.init) continue;
        workerTid.send(true);
    }
}


mixin PluginRegistration!WebtitlePlugin;

public:


// WebtitlePlugin
/++
    The Webtitle plugin catches HTTP URL links in messages, connects to
    their servers and and streams the web page itself, looking for the web page's
    title. This is then reported to the originating channel or personal query.
 +/
final class WebtitlePlugin : IRCPlugin
{
private:
    import std.concurrency : Tid;
    import core.time : msecs;

    /++
        Transient state variables, aggregated in a struct.
     +/
    static struct TransientState
    {
        /++
            The thread IDs of the persistent worker threads.
         +/
        Tid[] workerTids;

        /++
            The index of the next worker thread to use.
         +/
        size_t currentWorkerTidIndex;
    }

    /++
        All Webtitle options gathered.
     +/
    WebtitleSettings webtitleSettings;

    /++
        Transient state of this [WebtitlePlugin] instance.
     +/
    TransientState transient;

    /++
        Lookup bucket.
     +/
    MutexedAA!(TitleLookupResult[int]) lookupBucket;

    /++
        Returns the next worker thread ID to use, cycling through them.
     +/
    auto getNextWorkerTid()
    in (transient.workerTids.length, "Tried to get a worker Tid when there were none")
    {
        if (transient.currentWorkerTidIndex >= transient.workerTids.length)
        {
            transient.currentWorkerTidIndex = 0;
        }

        return transient.workerTids[transient.currentWorkerTidIndex++];
    }

    mixin IRCPluginImpl;
}
