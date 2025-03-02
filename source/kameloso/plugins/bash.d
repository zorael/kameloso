/++
    The Bash plugin looks up quotes from `bash.org`
    (or technically [bashforever.com](https://bashforever.com)) and reports them
    to the appropriate nickname or channel.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#bash,
        [kameloso.plugins],
        [kameloso.plugins.common]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.bash;

version(WithBashPlugin):

private:

import kameloso.plugins;
import kameloso.plugins.common.mixins.awareness;
import requests.base : Response;
import dialect.defs;
import core.thread.fiber : Fiber;

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

    /++
        Whether or not to ignore SSL certificate verification errors when fetching quotes.
     +/
    bool verifySSLCertificate = false;
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
void onCommandBash(BashPlugin plugin, const IRCEvent event)
{
    import std.algorithm.searching : startsWith;
    import std.string : isNumeric;

    mixin(memoryCorruptionCheck);

    void sendUsage()
    {
        import kameloso.messaging : privmsg;
        import std.format : format;

        enum pattern = "Usage: <b>%s%s<b> [optional bash quote number]";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
        privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
    }

    if (event.sender.class_ < plugin.settings.minimumPermissionsNeeded) return;

    immutable quoteID = event.content.startsWith('#') ?
        event.content[1..$] :
        event.content;

    if (quoteID.length && !quoteID.isNumeric) return sendUsage();

    lookupQuote(plugin, quoteID, event);
}


// onEndOfMotd
/++
    Warns the user if SSL certificate verification is disabled.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WELCOME)
)
void onWelcome(BashPlugin plugin, const IRCEvent _)
{
    import std.concurrency : Tid, spawn;

    mixin(memoryCorruptionCheck);

    if (!plugin.settings.verifySSLCertificate)
    {
        import kameloso.common : logger;

        enum startMessage = "The <l>bash</> plugin is configured to look up quotes " ~
            "with SSL certificate verification <l>disabled</>.";
        enum warningMessage = "Be aware that this is a security risk.";
        logger.warning(startMessage);
        logger.warning(warningMessage);
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
    const IRCEvent event)
{
    import kameloso.plugins.common.scheduling : delay;
    import kameloso.common : logger;
    import kameloso.constants : BufferSize;
    import kameloso.messaging : privmsg;
    import core.time : Duration;

    void sendNoQuoteFound()
    {
        enum message = "No such <b>bash.org<b> quote found.";
        privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
    }

    void sendFailedToFetch()
    {
        enum message = "Failed to fetch <b>bash.org<b> quote.";
        privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
    }

    immutable url = quoteID.length ?
        "https://bashforever.com/?" ~ quoteID :
        "https://bashforever.com/?random";

    void lookupQuoteDg()
    {
        immutable response = sendHTTPRequest(
            plugin: plugin,
            url: url,
            verifyPeer: plugin.settings.verifySSLCertificate);

        if (response.exceptionText.length)
        {
            logger.warning("HTTP exception: <l>", response.exceptionText);

            version(PrintStacktraces)
            {
                if (response.body.length) logger.trace(response.body);
            }

            return sendFailedToFetch();
        }

        if ((response.code < 200) ||
            (response.code > 299))
        {
            import kameloso.tables : getHTTPResponseCodeText;

            enum pattern = "HTTP status <l>%03d</> (%s)";
            logger.warningf(
                pattern,
                response.code,
                getHTTPResponseCodeText(response.code));

            version(PrintStacktraces)
            {
                if (response.body.length) logger.trace(response.body);
            }

            return sendFailedToFetch();
        }

        const result = parseResponseIntoBashLookupResult(response);
        if (!result.quoteID.length) return sendNoQuoteFound();

        // Seems okay, send it
        immutable message = "[<b>bash.org<b>] #" ~ result.quoteID;
        privmsg(plugin.state, event.channel.name, event.sender.nickname, message);

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
            privmsg(plugin.state, event.channel.name, event.sender.nickname, correctedLine);
        }
    }

    auto lookupQuoteFiber = new Fiber(&lookupQuoteDg, BufferSize.fiberStack);
    lookupQuoteFiber.call();
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
auto parseResponseIntoBashLookupResult(/*const*/ HTTPQueryResponse response)
{
    import arsd.dom : Document, htmlEntitiesDecode;
    import lu.string : stripped;
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : canFind, startsWith;
    import std.array : array, replace;
    import std.string : indexOf;

    BashLookupResult result;
    result.code = response.code;
    result.responseBody = cast(string)response.body;  // .idup?

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
    /++
        All Bash plugin settings gathered.
     +/
    BashSettings settings;

    mixin IRCPluginImpl;
}
