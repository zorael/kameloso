/++
    The Webtitle plugin catches URLs pasted in a channel, follows them and
    reports back the title of the web page that was linked to.

    It has no bot commands; everything is done by automatically scanning channel
    and private query messages for things that look like links.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#webtitle,
        [kameloso.plugins],
        [kameloso.plugins.common]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.webtitle;

version(WithWebtitlePlugin):

private:

import kameloso.plugins;
import kameloso.net : HTTPQueryResponse;
import requests.base : Response;
import dialect.defs;
import lu.container : MutexedAA;
import core.thread.fiber : Fiber;


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
        How many URLs to look up per line in a message. Any further URLs will be ignored.
     +/
    int maxURLsPerLine = 1;

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
        The HTTP response that was received when fetching the URL.
     +/
    HTTPQueryResponse response;

    /++
        Message text if an exception was thrown during the lookup.
     +/
    string exceptionText;

    /++
        Constructor.
     +/
    this(const HTTPQueryResponse response)
    {
        import arsd.dom : Document;
        import std.algorithm.searching : canFind, startsWith;

        this.response = response;

        enum unnamedPagePlaceholder = "(Unnamed page)";

        if (!response.code || (response.code == 2) || (response.code >= 400))
        {
            // Invalid address, SSL error, 404, etc; no need to continue
            return;
        }

        try
        {
            this.domain = response.finalURI.host.startsWith("www.") ?
                response.finalURI.host[4..$] :
                response.finalURI.host;

            auto doc = new Document;
            doc.parseGarbage(response.body);

            this.title = doc.title.length ?
                decodeEntities(doc.title) :
                unnamedPagePlaceholder;

            if (!descriptionExemptions.canFind(this.domain))
            {
                auto metaTags = doc.getElementsByTagName("meta");

                foreach (/*const*/ tag; metaTags)
                {
                    if (tag.name == "description")
                    {
                        this.description = decodeEntities(tag.content);
                        break;
                    }
                }
            }
        }
        catch (Exception e)
        {
            // UnicodeException, UriException, ...
            this.exceptionText = e.msg;
        }
    }
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

    This function is annotated with
    [kameloso.plugins.Permissions.ignore|Permissions.ignore],
    but we don't mix in [kameloso.plugins.common.mixins.awareness.MinimalAuthentication|MinimalAuthentication].
    Ideally we would annotate it [kameloso.plugins.Permissions.anyone|Permissions.anyone],
    but then *any* channel message would incur a user lookup, which
    is a bit much.

    This is imprecise in the sense that a valid request *might* not be caught
    if the user's class hasn't been looked up yet. But it's a tradeoff between
    that and the bot having to look up every user showing any channel activity.

    On Libera.Chat this is a non-issue *if* the user joins the channel after the
    bot does, as account names are broadcast upon joining. Additionally, the act of
    logging in is also broadcast (with a [dialect.defs.IRCEvent.Type.ACCOUNT|ACCONUT] event).

    Revisit this if it proves to be a problem.

    See_Also:
        [onMessageImpl]
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.ignore)
    .channelPolicy(ChannelPolicy.home)
)
void onMessage(WebtitlePlugin plugin, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);

    if (event.sender.class_ == IRCUser.Class.blacklist) return;
    if (event.sender.class_ < plugin.settings.minimumPermissionsNeeded) return;

    onMessageImpl(plugin, event);
}


// onMessageImpl
/++
    Parses a message to see if the message contains one or more URLs.
    Implementation function.

    It uses a simple state machine in [kameloso.misc.findURLs|findURLs] to
    exhaustively try to look up every URL returned by it.

    Params:
        plugin = The current [WebtitlePlugin].
        event = The [dialect.defs.IRCEvent|IRCEvent] that instigated the lookup.
 +/
void onMessageImpl(WebtitlePlugin plugin, const IRCEvent event)
{
    import kameloso.misc : findURLs;
    import lu.string : strippedLeft;
    import std.algorithm.searching : startsWith;

    enum minimumPossibleLinkLength = "http://a.se".length;
    immutable content = event.content.strippedLeft;  // mutable

    if ((content.length < minimumPossibleLinkLength) ||  // duplicates check in findURLs, but shrug
        (plugin.state.coreSettings.prefix.length && content.startsWith(plugin.state.coreSettings.prefix)))
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
            demandSeparatingChars: true);

        if (nicknameStripped != content) return;
    }

    // mutable so advancePast in lookupURLs works
    auto urls = findURLs(
        line: event.content,
        max: plugin.settings.maxURLsPerLine);

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
    const IRCEvent event,
    /*const*/ string[] urls)
{
    import kameloso.plugins.common.scheduling : delay;
    import kameloso.common : logger;
    import kameloso.constants : BufferSize;
    import lu.string : advancePast;
    import core.time : Duration;

    void report(const TitleLookupResult result)
    {
        import kameloso.messaging : reply;
        import std.format : format;

        if (result.exceptionText.length)
        {
            logger.warning("HTTP exception: <l>", result.exceptionText);
            return;
        }

        if ((result.response.code < 200) ||
            (result.response.code > 299))
        {
            import kameloso.tables : getHTTPResponseCodeText;

            enum pattern = "HTTP status <l>%03d</> (%s) fetching <l>%s";
            logger.warningf(
                pattern,
                result.response.code,
                getHTTPResponseCodeText(result.response.code),
                result.response.url);
            return;
        }

        if (!result.title.length)
        {
            enum pattern = "No title found <t>(%s)";
            logger.infof(pattern, result.response.url);
            return;
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

    bool[string] uniques;

    foreach (immutable i, url; urls)
    {
        import std.algorithm.searching : canFind;

        // If the URL contains an octothorpe fragment identifier, like
        // https://www.google.com/index.html#this%20bit
        // then strip that.
        url = url.advancePast('#', inherit: true);
        while (url[$-1] == '/') url = url[0..$-1];

        if (url.canFind("://i.imgur.com/"))
        {
            // imgur direct links naturally have no titles, but the normal pages do.
            // Rewrite and look those up instead.
            url = rewriteDirectImgurURL(url);
        }

        if (url in uniques) continue;
        uniques[url] = true;
    }

    void lookupURLsDg()
    {
        foreach (immutable origURL; uniques.byKey)
        {
            import kameloso.tables : trueThenFalse;
            import lu.string : advancePast;
            import std.algorithm.searching : canFind, startsWith;

            enum caughtPattern = "Caught URL: <l>%s";
            logger.infof(caughtPattern, origURL);

            string url = origURL;  // mutable

            if (url.canFind("youtube.com/watch?v=", "youtu.be/"))
            {
                // Do our own slicing instead of using regexes, because footprint.
                string slice = url;  // mutable

                slice.advancePast("http");
                if (slice[0] == 's') slice = slice[1..$];
                slice = slice["://".length..$];

                if (slice.startsWith("www.")) slice = slice[4..$];

                immutable isYouTubeURL = slice.startsWith(
                    "youtube.com/watch?v=",
                    "youtu.be/");

                if (isYouTubeURL)
                {
                    immutable rewrittenYoutubeURL = "https://www.youtube.com/oembed?format=json&url=" ~ url;
                    immutable response = sendHTTPRequest(plugin, rewrittenYoutubeURL);
                    auto result = response.parseResponseIntoTitleLookupResult();

                    if (result.exceptionText.length ||
                        !result.title.length ||
                        (result.response.code < 200) ||
                        (result.response.code > 299))
                    {
                        // Either requests threw an exception or it's something like UnicodeException
                        // Drop down and try the original URL
                    }
                    else
                    {
                        import std.json : parseJSON;

                        // FIXME: asdf
                        immutable youtubeJSON = parseJSON(response.body);
                        result.title = decodeEntities(youtubeJSON["title"].str);
                        result.youtubeAuthor = decodeEntities(youtubeJSON["author_name"].str);
                        return report(result);
                    }
                }
            }

            // If we're here it's not a YouTube link, barring bad parsing
            foreach (immutable isFirstTime; trueThenFalse[])
            {
                immutable response = sendHTTPRequest(plugin, url);
                immutable result = TitleLookupResult(response);

                if (result.exceptionText.length ||
                    !result.title.length ||
                    (result.response.code < 200) ||
                    (result.response.code > 299))
                {
                    if (isFirstTime)
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
                        continue;
                    }
                }

                report(result);
            }
        }
    }

    auto lookupURLsFiber = new Fiber(&lookupURLsDg, BufferSize.fiberStack);
    lookupURLsFiber.call();
}


// parseResponseIntoTitleLookupResult
/++
    Parses a [requests] `Response` into a [TitleLookupResult].

    Params:
        res = [requests] `Response` to parse.

    Returns:
        A [TitleLookupResult] with contents based on what was read from the URL.
 +/
auto parseResponseIntoTitleLookupResult(const HTTPQueryResponse response)
{
    import arsd.dom : Document;
    import std.algorithm.searching : canFind, startsWith;

    TitleLookupResult result;
    result.response = response;

    enum unnamedPagePlaceholder = "(Unnamed page)";

    if (!response.code || (response.code == 2) || (response.code >= 400))
    {
        // Invalid address, SSL error, 404, etc; no need to continue
        return result;
    }

    try
    {
        result.domain = response.finalURI.host.startsWith("www.") ?
            response.finalURI.host[4..$] :
            response.finalURI.host;

        auto doc = new Document;
        doc.parseGarbage(response.body);

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

    immutable startsWithThis = url.startsWith(
        "https://i.imgur.com/",
        "http://i.imgur.com/");

    if (!startsWithThis) return url;

    immutable path = (startsWithThis == 1) ?
        url[20..$].advancePast('.') :
        url[19..$].advancePast('.');

    return "https://imgur.com/" ~ path;
}

///
unittest
{
    {
        enum directURL = "https://i.imgur.com/URHe5og.jpg";
        static immutable rewritten = rewriteDirectImgurURL(directURL);
        static assert((rewritten == "https://imgur.com/URHe5og"), rewritten);
    }
    {
        enum directURL = "http://i.imgur.com/URHe5og.jpg";
        static immutable rewritten = rewriteDirectImgurURL(directURL);
        static assert((rewritten == "https://imgur.com/URHe5og"), rewritten);
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
    /++
        All Webtitle options gathered.
     +/
    WebtitleSettings settings;

    mixin IRCPluginImpl;
}
