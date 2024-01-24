/++
    The Bash plugin looks up quotes from `bash.org`
    (or technically [bashforever.com](https://bashforever.com)) and reports them
    to the appropriate nickname or channel.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#bash,
        [kameloso.plugins.common],
        [kameloso.plugins.common.misc]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.bash;

version(WithBashPlugin):

private:

import kameloso.plugins;
import kameloso.plugins.common;
import kameloso.plugins.common.awareness : MinimalAuthentication;
import requests.base : Response;
import dialect.defs;
import lu.container : MutexedAA;
import std.typecons : Flag, No, Yes;
import core.thread : Fiber;

mixin MinimalAuthentication;
mixin PluginRegistration!BashPlugin;


// BashSettings
/++
    All Bash plugin settings gathered.
 +/
@Settings struct BashSettings
{
    /++
        Whether or not the Bash plugin should react to events at all.
     +/
    @Enabler bool enabled = true;

    /++
        Minimum user class required for the plugin to react to events.
     +/
    IRCUser.Class minimumPermissionsNeeded = IRCUser.Class.anyone;
}


// BashLookupResult
/++
    The result of a [bashforever.com](https://bashforever.com) lookup.
 +/
struct BashLookupResult
{
    /++
        The quote ID number, as a string.
     +/
    string quoteID;

    /++
        The quote lines, as an array of strings.
     +/
    string[] lines;

    /++
        The response code of the HTTP query.
     +/
    uint code;

    /++
        The response body of the HTTP query.
     +/
    string responseBody;

    /++
        The exception message of any such that was thrown while fetching the quote.
     +/
    string exceptionText;
}


// onCommandBash
/++
    Fetch a random or specified [bashforever.com](https://bashforever.com) quote.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.anyone)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("bash")
            .policy(PrefixPolicy.prefixed)
            .description("Fetch a random or specified bashforever.com quote.")
            .addSyntax("$command [optional bash quote number]")
    )
)
void onCommandBash(BashPlugin plugin, const /*ref*/ IRCEvent event)
{
    import std.algorithm.searching : startsWith;
    import std.string : isNumeric;

    void sendUsage()
    {
        import kameloso.messaging : privmsg;
        import std.format : format;

        enum pattern = "Usage: <b>%s%s<b> [optional bash quote number]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux[$-1]);
        privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }

    if (event.sender.class_ < plugin.bashSettings.minimumPermissionsNeeded) return;

    immutable quoteID = event.content.startsWith('#') ?
        event.content[1..$] :
        event.content;

    if (!quoteID.length || !quoteID.isNumeric) return sendUsage();

    lookupQuote(plugin, quoteID, event);
}


// onEndOfMotd
/++
    Starts the persistent querier worker thread on end of MOTD.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_ENDOFMOTD)
    .onEvent(IRCEvent.Type.ERR_NOMOTD)
)
void onEndOfMotd(BashPlugin plugin, const ref IRCEvent event)
{
    import std.concurrency : Tid, spawn;

    if (plugin.transient.workerTid == Tid.init)
    {
        plugin.transient.workerTid = spawn(
            &persistentQuerier,
            plugin.lookupBucket,
            plugin.state.connSettings.caBundleFile);
    }
}


// lookupQuote
/++
    Looks up a quote from [bashforever.com](https://bashforever.com) and sends it
    to the appropriate nickname or channel.

    Leverages the worker subthread for the heavy work.

    Params:
        plugin = The current [BashPlugin].
        quoteID = The quote ID to look up, or an empty string to look up a random quote.
        event = The [dialect.defs.IRCEvent|IRCEvent] that triggered this lookup.
 +/
void lookupQuote(
    BashPlugin plugin,
    const string quoteID,
    const /*ref*/ IRCEvent event)
{
    import kameloso.plugins.common.scheduling : delay;
    import kameloso.common : logger;
    import kameloso.constants : BufferSize;
    import kameloso.messaging : privmsg;
    import core.time : Duration;

    void sendNoQuoteFound()
    {
        enum message = "No such <b>bash.org<b> quote found.";
        privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }

    void sendFailedToFetch()
    {
        enum message = "Failed to fetch <b>bash.org<b> quote.";
        privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }

    immutable url = quoteID.length ?
        "https://bashforever.com/?" ~ quoteID :
        "https://bashforever.com/?random";

    void lookupQuoteDg()
    {
        const result = sendHTTPRequest(plugin, url);

        if (result.exceptionText.length)
        {
            logger.warning("HTTP exception: <l>", result.exceptionText);

            version(PrintStacktraces)
            {
                if (result.responseBody.length) logger.trace(result.responseBody);
            }

            return sendFailedToFetch();
        }

        if ((result.code < 200) ||
            (result.code > 299))
        {
            import kameloso.tables : getHTTPResponseCodeText;

            enum pattern = "HTTP status <l>%03d</> (%s)";
            logger.warningf(
                pattern,
                result.code,
                getHTTPResponseCodeText(result.code));

            version(PrintStacktraces)
            {
                if (result.responseBody.length) logger.trace(result.responseBody);
            }

            return sendFailedToFetch();
        }

        if (!result.quoteID.length) return sendNoQuoteFound();

        // Seems okay, send it
        immutable message = "[<b>bash.org<b>] #" ~ result.quoteID;
        privmsg(plugin.state, event.channel, event.sender.nickname, message);

        foreach (const line; result.lines)
        {
            if (!line.length) continue;  // Can technically happen

            string correctedLine;  // mutable

            version(TwitchSupport)
            {
                if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
                {
                    import std.algorithm.comparison : among;

                    if (line[0].among!('/', '.'))
                    {
                        // This has the chance to conflict with a Twitch command,
                        // so prepend a space to invalidate it
                        correctedLine = ' ' ~ line;
                    }
                }
            }

            if (!correctedLine.length) correctedLine = line;
            privmsg(plugin.state, event.channel, event.sender.nickname, correctedLine);
        }
    }

    auto lookupQuoteFiber = new Fiber(&lookupQuoteDg, BufferSize.fiberStack);
    delay(plugin, lookupQuoteFiber, Duration.zero);
}


// parseResponseIntoBashLookupResult
/++
    Parses the response body of a [requests.base.Response|Response] into a
    [BashLookupResult].

    Additionally embeds the response code into the result.

    Params:
        res = The [requests.base.Response|Response] to parse.

    Returns:
        A [BashLookupResult] with contents based on the [requests.base.Response|Response].
 +/
auto parseResponseIntoBashLookupResult(/*const*/ Response res)
{
    import arsd.dom : Document, htmlEntitiesDecode;
    import lu.string : stripped;
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : canFind, startsWith;
    import std.array : array, replace;
    import std.string : indexOf;

    BashLookupResult result;
    result.code = res.code;
    result.responseBody = cast(string)res.responseBody;  // .idup?

    auto attachErrorAndReturn()
    {
        result.exceptionText = "Failed to parse bashforever.com response: " ~
            "page has unexpected layout";
        return result;
    }

    if (!result.code || (result.code == 2) || (result.code >= 400))
    {
        // Invalid address, SSL error, 404, etc; no need to continue
        return result;
    }

    immutable endHeadPos = result.responseBody.indexOf("</head>");
    if (endHeadPos == -1) return attachErrorAndReturn();

    immutable headlessBody = result.responseBody[endHeadPos+5..$];  // slice away the </head>
    if (!headlessBody.length) return attachErrorAndReturn();

    auto doc = new Document;
    doc.parseGarbage(headlessBody);

    auto quotesElements = doc.getElementsByClassName("quotes");
    if (!quotesElements.length) return attachErrorAndReturn();

    immutable quotesHTML = quotesElements[0].toString();
    if (!quotesHTML.length) return attachErrorAndReturn();

    doc.parseGarbage(quotesHTML[20..$]);  // slice away the <div class="quotes">

    auto div = doc.getElementsByTagName("div");
    if (!div.length) return attachErrorAndReturn();

    immutable divString = div[0].toString();
    if (!divString.length) return attachErrorAndReturn();

    immutable hashPos = divString.indexOf("#");
    if (hashPos == -1) return attachErrorAndReturn();

    immutable endAPos = divString.indexOf("</a>", hashPos);
    if (endAPos == -1) return attachErrorAndReturn();

    immutable quoteID = divString[hashPos+1..endAPos];
    result.quoteID = quoteID;

    auto ps = doc.getElementsByTagName("p");
    if (!ps.length) return attachErrorAndReturn();

    immutable pString = ps[0].toString();
    if (!pString.length) return attachErrorAndReturn();

    immutable endDivPos = pString.indexOf("</div>");
    if (endDivPos == -1) return attachErrorAndReturn();

    immutable endPPos = pString.indexOf("</p>", endDivPos);
    if (endPPos == -1) return attachErrorAndReturn();

    result.lines = pString[endDivPos+6..endPPos]
        .htmlEntitiesDecode()
        .stripped
        .splitter("<br />")
        .array;

    if (result.lines.length)
    {
        import lu.string : strippedRight;
        import std.string : indexOf;

        immutable divPos = result.lines[$-1].indexOf("<div");
        if (divPos != -1) result.lines[$-1] = result.lines[$-1][0..divPos].strippedRight;
    }

    return result;
}


// sendHTTPRequestImpl
/++
    Fetches the contents of a URL, parses it into a [BashLookupResult] and returns it.

    Params:
        url = URL string to fetch.
        caBundleFile = Path to a `cacert.pem` SSL certificate bundle.

    Returns:
        A [BashLookupResult] with contents based on what was read from the URL.
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
            .parseResponseIntoBashLookupResult();
    }
    catch (Exception e)
    {
        BashLookupResult result;
        //result.url = url;
        result.exceptionText = e.msg;
        return result;
    }
}


// sendHTTPRequest
/++
    Issues an HTTP request by sending the details to the persistent querier thread,
    then returns the results after they become available in the shared associative array.

    Params:
        plugin = The current [BashPlugin].
        url = URL string to fetch.
        recursing = Whether or not this is a recursive call.
        id = Optional `int` id key to [BashPlugin.lookupBucket].
        caller = Optional name of the calling function.

    Returns:
        A [BashLookupResult] with contents based on what was read from the URL.
 +/
BashLookupResult sendHTTPRequest(
    BashPlugin plugin,
    const string url,
    const Flag!"recursing" recursing = No.recursing,
    /*const*/ int id = 0,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `sendHTTPRequest` from outside a fiber")
in (url.length, "Tried to send an HTTP request without a URL")
{
    import kameloso.plugins.common.scheduling : delay;
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
    plugin.transient.workerTid.send(url, id);

    static immutable initialDelay = 500.msecs;
    delay(plugin, initialDelay, Yes.yield);

    auto result = waitForLookupResults(plugin, id);

    if ((result.code >= 500) && !recursing)
    {
        return sendHTTPRequest(
            plugin,
            url,
            Yes.recursing,
            id,
            caller);
    }

    return result;
}


// waitForLookupResults
/++
    Given an `int` id, monitors the [BashPlugin.lookupBucket|lookupBucket]
    until a value with that key becomes available, delaying itself in between checks.

    If it resolves, it returns that value. If it doesn't resolve within
    [kameloso.constants.Timeout.httpGET|Timeout.httpGET]*2 seconds, it signals
    failure by instead returning an empty [BashLookupResult|BashLookupResult.init].

    Params:
        plugin = The current [BashPlugin].
        id = The `int` id key to monitor [BashPlugin.lookupBucket] for.

    Returns:
        A [BashLookupResult] as discovered in the [BashPlugin.lookupBucket|lookupBucket],
        or a [BashLookupResult|BashLookupResult.init] if there were none to be
        found within [kameloso.constants.Timeout.httpGET|Timeout.httpGET] seconds.
 +/
auto waitForLookupResults(BashPlugin plugin, const int id)
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
            return BashLookupResult.init;
        }

        //auto result = plugin.lookupBucket[id];  // potential range error due to TOCTTOU
        auto result = plugin.lookupBucket.get(id, BashLookupResult.init);

        if (result == BashLookupResult.init)
        {
            import kameloso.plugins.common.scheduling : delay;
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


// persistentQuerier
/++
    Persistent querier worker thread function.

    Params:
        lookupBucket = A [lu.container.MutexedAA|MutexedAA] to fill with
            [BashLookupResult|BashLookupResult]s.
        caBundleFile = Path to a `cacert.pem` SSL certificate bundle, or an
            empty string if none should be needed.
 +/
void persistentQuerier(
    MutexedAA!(BashLookupResult[int]) lookupBucket,
    const string caBundleFile)
{
    version(Posix)
    {
        import kameloso.thread : setThreadName;
        setThreadName("bashworker");
    }

    void onBashLookupRequest(string url, int id)
    {
        auto result = sendHTTPRequestImpl(url, caBundleFile);

        if (result.code == 400)
        {
            // Sometimes it claims 400 Bad Request for no reason. Retry a few times
            foreach (immutable _; 0..3)
            {
                result = sendHTTPRequestImpl(url, caBundleFile);
                if (result.code != 400) break;
            }
        }

        if (result != BashLookupResult.init)
        {
            lookupBucket[id] = result;
        }
        else
        {
            lookupBucket.remove(id);
        }
    }

    bool halt;

    void onQuitMessage(bool)
    {
        halt = true;
    }

    // This avoids the GC allocating a closure, which is fine in this case, but do this anyway
    scope onBashLookupRequestDg = &onBashLookupRequest;
    scope onQuitMessageDg = &onQuitMessage;

    while (!halt)
    {
        try
        {
            import std.concurrency : receive;
            import std.variant : Variant;

            receive(
                onBashLookupRequestDg,
                onQuitMessageDg,
                (Variant v)
                {
                    import std.stdio : stdout, writeln;
                    writeln("Bash worker received unknown Variant: ", v);
                    stdout.flush();
                }
            );
        }
        catch (Exception _)
        {
            // Probably a requests exception
            /*writeln("Bash worker caught exception: ", e.msg);
            version(PrintStacktraces) writeln(e);
            stdout.flush();*/
        }
    }
}


// setup
/++
    Initialises the lookup bucket, else its internal [core.sync.mutex.Mutex|Mutex]
    will be null and cause a segfault when trying to lock it.
 +/
void setup(BashPlugin plugin)
{
    plugin.lookupBucket.setup();
}


// teardown
/++
    Stops the persistent querier worker thread.
 +/
void teardown(BashPlugin plugin)
{
    import std.concurrency : Tid, prioritySend;

    if (plugin.transient.workerTid != Tid.init)
    {
       plugin.transient.workerTid.prioritySend(true);
    }
}


// selftest
/++
    Performs self-tests against another bot.
 +/
version(Selftests)
auto selftest(BashPlugin _, Selftester s)
{
    s.send("bash 5273");
    s.expect("[bash.org] #5273");
    s.expect("<erno> hm. I've lost a machine.. literally _lost_. it responds to ping, " ~
        "it works completely, I just can't figure out where in my apartment it is.");

    s.send("bash #4278");
    s.expect("[bash.org] #4278");
    s.expect("<BombScare> i beat the internet");
    s.expect("<BombScare> the end guy is hard");

    s.send("bash honk");
    s.expect("Usage: !bash [optional bash quote number]");

    /*s.send("bash 0");  // Produces a wall of text on the target side
    s.expect("Failed to fetch bash.org quote.");*/

    return true;
}


public:


// BashPlugin
/++
    The Bash plugin looks up quotes from `bash.org`
    (or technically [bashforever.com](https://bashforever.com)) and reports them
    to the appropriate nickname or channel.
 +/
final class BashPlugin : IRCPlugin
{
private:
    import std.concurrency : Tid;

    /++
        Transient state variables, aggregated in a struct.
     +/
    static struct TransientState
    {
        /++
            The thread ID of the persistent worker thread.
         +/
        Tid workerTid;
    }

    /++
        All Bash plugin settings gathered.
     +/
    BashSettings bashSettings;

    /++
        Transient state of this [BashPlugin] instance.
     +/
    TransientState transient;

    /++
        Lookup bucket.
     +/
    MutexedAA!(BashLookupResult[int]) lookupBucket;

    mixin IRCPluginImpl;
}
