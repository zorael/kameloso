/++
    The Webtitles plugin catches URLs pasted in a channel, follows them and
    reports back the title of the web page that was linked to.

    It has no bot commands; everything is done by automatically scanning channel
    and private query messages for things that look like links.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#webtitles
        [kameloso.plugins.common.core|plugins.common.core]
        [kameloso.plugins.common.misc|plugins.common.misc]
 +/
module kameloso.plugins.webtitles;

version(WithWebtitlesPlugin):

private:

import kameloso.plugins;
import kameloso.plugins.common.core;
import kameloso.plugins.common.awareness : MinimalAuthentication;
import kameloso.messaging;
import dialect.defs;
import std.json : JSONValue;
import std.typecons : Flag, No, Yes;


// descriptionExemptions
/++
    Hostnames explicitly exempt from having their descriptions included after the titles.

    Must be in lowercase.
 +/
static immutable descriptionExemptions =
[
    "imgur.com",
];


// WebtitlesSettings
/++
    All Webtitles settings, gathered in a struct.
 +/
@Settings struct WebtitlesSettings
{
    /// Toggles whether or not the plugin should react to events at all.
    @Enabler bool enabled = true;

    /// Toggles whether or not meta descriptions should be reported next to titles.
    bool descriptions = true;
}


// TitleLookupResults
/++
    A record of a URL lookup.

    This is both used to aggregate information about the lookup, as well as to
    add hysteresis to lookups, so we don't look the same one up over and over
    if they were pasted over and over.
 +/
struct TitleLookupResults
{
    /// Looked up web page title.
    string title;

    /// The content of the web page's `description` tag.
    string description;

    /// Domain name of the looked up URL.
    string domain;

    /// YouTube video title, if such a YouTube link.
    string youtubeTitle;

    /// YouTube video author, if such a YouTube link.
    string youtubeAuthor;

    /// The UNIX timestamp of when the title was looked up.
    long when;
}


// TitleLookupRequest
/++
    A record of a URL lookup request.

    This is used to aggregate information about a lookup request, making it
    easier to pass it in between functions. It serves no greater purpose.
 +/
struct TitleLookupRequest
{
    /// The context state of the requesting plugin instance.
    IRCPluginState state;

    /// The [dialect.defs.IRCEvent|IRCEvent] that instigated the lookup.
    IRCEvent event;

    /// URL to look up.
    string url;

    /// Results of the title lookup.
    TitleLookupResults results;
}


// onMessage
/++
    Parses a message to see if the message contains one or more URLs.

    It uses a simple state machine in [kameloso.common.findURLs|findURLs] to
    exhaustively try to look up every URL returned by it.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.ignore)
    .channelPolicy(ChannelPolicy.home)
)
void onMessage(WebtitlesPlugin plugin, const ref IRCEvent event)
{
    import kameloso.common : findURLs;
    import lu.string : beginsWith, strippedLeft;

    if (event.content.strippedLeft.beginsWith(plugin.state.settings.prefix)) return;

    string[] urls = findURLs(event.content);  // mutable so nom works
    if (!urls.length) return;

    return lookupURLs(plugin, event, urls);
}


// lookupURLs
/++
    Looks up the URLs in the passed `string[]` `urls` by spawning a worker
    thread to do all the work.

    It accesses the cache of already looked up addresses to speed things up.
 +/
void lookupURLs(WebtitlesPlugin plugin, const /*ref*/ IRCEvent event, string[] urls)
{
    import kameloso.common : logger;
    import lu.string : beginsWith, nom;
    import std.concurrency : spawn;

    bool[string] uniques;

    foreach (immutable i, url; urls)
    {
        // If the URL contains an octothorpe fragment identifier, like
        // https://www.google.com/index.html#this%20bit
        // then strip that.
        url = url.nom!(Yes.inherit, Yes.decode)('#');

        while (url[$-1] == '/')
        {
            url = url[0..$-1];
        }

        if (url in uniques) continue;

        uniques[url] = true;

        enum pattern = "Caught URL: <l>%s";
        logger.infof(pattern, url);

        TitleLookupRequest request;
        request.state = plugin.state;
        request.event = event;
        request.url = url;

        if (plugin.cache.length) prune(plugin.cache, plugin.expireSeconds);

        TitleLookupResults cachedResult;

        synchronized //()
        {
            if (const cachedResultPointer = url in plugin.cache)
            {
                cachedResult = *cachedResultPointer;
            }
        }

        if (cachedResult != TitleLookupResults.init)
        {
            logger.log("Found cached lookup.");
            request.results = cachedResult;

            if (request.results.youtubeTitle.length)
            {
                reportYouTubeTitle(request);
            }
            else
            {
                reportTitle(request);
            }
            continue;
        }

        cast(void)spawn(&worker, cast(shared)request, plugin.cache,
            (i * plugin.delayMsecs),
            cast(Flag!"descriptions")plugin.webtitlesSettings.descriptions,
            plugin.state.connSettings.caBundleFile);
    }

    import kameloso.thread : ThreadMessage;
    import std.concurrency : prioritySend;

    plugin.state.mainThread.prioritySend(ThreadMessage.shortenReceiveTimeout());
}


// worker
/++
    Looks up and reports the title of a URL.

    Additionally reports YouTube titles and authors if settings say to do such.

    Worker to be run in its own thread.

    Params:
        sRequest = Shared [TitleLookupRequest] aggregate with all the state and
            context needed to look up a URL and report the results to the local terminal.
        cache = Shared cache of previous [TitleLookupRequest]s.
        delayMsecs = Milliseconds to delay before doing the lookup, to allow for
            parallel lookups without bursting all of them at once.
        descriptions = Whether or not to look up meta descriptions.
        caBundleFile = Path to a `cacert.pem` SSL certificate bundle.
 +/
void worker(
    shared TitleLookupRequest sRequest,
    shared TitleLookupResults[string] cache,
    const ulong delayMsecs,
    const Flag!"descriptions" descriptions,
    const string caBundleFile)
{
    import lu.string : beginsWith, contains, nom;
    import std.datetime.systime : Clock;
    import std.format : format;
    import std.typecons : No, Yes;
    static import kameloso.common;

    version(Posix)
    {
        import kameloso.thread : setThreadName;
        setThreadName("webtitles");
    }

    // Set the global settings so messaging functions don't segfault us
    kameloso.common.settings = &(cast()sRequest).state.settings;

    if (delayMsecs > 0)
    {
        import core.thread : Thread;
        import core.time : msecs;
        Thread.sleep(delayMsecs.msecs);
    }

    TitleLookupRequest request = cast()sRequest;
    immutable now = Clock.currTime.toUnixTime;

    if (request.url.contains("://i.imgur.com/"))
    {
        // imgur direct links naturally have no titles, but the normal pages do.
        // Rewrite and look those up instead.
        request.url = rewriteDirectImgurURL(request.url);
    }
    else if (request.url.contains("youtube.com/watch?v=") ||
        request.url.contains("youtu.be/"))
    {
        // Do our own slicing instead of using regexes, because footprint.
        string slice = request.url;

        slice.nom!(Yes.decode)("http");
        if (slice[0] == 's') slice = slice[1..$];
        slice = slice[3..$];  // ://

        if (slice.beginsWith("www.")) slice = slice[4..$];

        if (slice.beginsWith("youtube.com/watch?v=") ||
            slice.beginsWith("youtu.be/"))
        {
            import std.json : JSONException;

            try
            {
                immutable info = getYouTubeInfo(request.url, caBundleFile);

                // Let's assume all YouTube clips have titles and authors
                // Should we decode the author too?
                request.results.youtubeTitle = decodeEntities(info["title"].str);
                request.results.youtubeAuthor = info["author_name"].str;

                reportYouTubeTitle(request);

                request.results.when = now;

                synchronized //()
                {
                    cache[request.url] = cast(shared)request.results;
                }
                return;
            }
            catch (TitleFetchException e)
            {
                if (e.code == 2)
                {
                    import kameloso.constants : MagicErrorStrings;

                    if (e.msg == MagicErrorStrings.sslLibraryNotFound)
                    {
                        enum wikiPattern = cast(string)MagicErrorStrings.visitWikiOneliner;
                        enum pattern = "Error fetching YouTube title: <l>" ~
                            MagicErrorStrings.sslLibraryNotFoundRewritten ~
                            "</> <t>(is OpenSSL installed?)";
                        request.state.askToError(pattern);
                        request.state.askToError(wikiPattern);

                        version(Windows)
                        {
                            enum getoptMessage = cast(string)MagicErrorStrings.getOpenSSLSuggestion;
                            request.state.askToError(getoptMessage);
                        }
                    }
                    else
                    {
                        enum pattern = "Error fetching YouTube title: <l>%s";
                        request.state.askToError(pattern.format(e.msg));
                    }
                    return;
                }
                else if (e.code >= 400)
                {
                    // Simply failed to fetch
                    enum pattern = "Webtitles YouTube worker saw HTTP <l>%d</>: <t>%s";
                    request.state.askToError(pattern.format(e.code, e.msg));
                }
                else
                {
                    request.state.askToError("Error fetching YouTube video information: <l>" ~ e.msg);
                    //version(PrintStacktraces) request.state.askToTrace(e.info);
                    // Drop down
                }
            }
            catch (JSONException e)
            {
                request.state.askToError("Failed to parse YouTube video information: <l>" ~ e.msg);
                //version(PrintStacktraces) request.state.askToTrace(e.info);
                // Drop down
            }
            catch (Exception e)
            {
                request.state.askToError("Unexpected exception fetching YouTube video information: <l>" ~ e.msg);
                version(PrintStacktraces) request.state.askToTrace(e.toString);
                // Drop down
            }
        }
        else
        {
            // Unsure what this is really. Drop down and treat like normal link
        }
    }

    void tryLookup()
    {
        import std.format : format;
        import std.range : only;
        import core.exception : UnicodeException;

        foreach (immutable firstTime; only(true, false))
        {
            try
            {
                request.results = lookupTitle(request.url, descriptions, caBundleFile);
                reportTitle(request);
                request.results.when = now;

                synchronized //()
                {
                    cache[request.url] = cast(shared)request.results;
                }
            }
            catch (TitleFetchException e)
            {
                if (e.code == 2)
                {
                    import kameloso.constants : MagicErrorStrings;

                    if (e.msg == MagicErrorStrings.sslLibraryNotFound)
                    {
                        enum wikiPattern = cast(string)MagicErrorStrings.visitWikiOneliner;
                        enum pattern = "Error fetching webpage title: <l>" ~
                            MagicErrorStrings.sslLibraryNotFoundRewritten ~
                            "</> <t>(is OpenSSL installed?)";
                        request.state.askToError(pattern);
                        request.state.askToError(wikiPattern);

                        version(Windows)
                        {
                            enum getoptMessage = cast(string)MagicErrorStrings.getOpenSSLSuggestion;
                            request.state.askToError(getoptMessage);
                        }
                    }
                    else
                    {
                        enum pattern = "Error fetching webpage title: <l>%s";
                        request.state.askToError(pattern.format(e.msg));
                    }
                    return;
                }
                else if (e.code >= 400)
                {
                    // Simply failed to fetch
                    enum pattern = "Webtitles worker saw HTTP <l>%d</>: <l>%s";
                    request.state.askToWarn(pattern.format(e.code, e.msg));
                }
                else
                {
                    // No title tag found
                    enum pattern = "No title tag found: <l>%s";
                    request.state.askToWarn(pattern.format(e.msg));
                }

                if (firstTime)
                {
                    request.state.askToLog("Rewriting URL and retrying...");

                    if (request.url[$-1] == '/')
                    {
                        request.url = request.url[0..$-1];
                    }
                    else
                    {
                        request.url ~= '/';
                    }
                    continue;
                }
            }
            catch (UnicodeException e)
            {
                enum pattern = "Webtitles worker Unicode exception: <l>%s</> " ~
                    "(link is probably to an image or similar)";
                request.state.askToError(pattern.format(e.msg));
                //version(PrintStacktraces) request.state.askToTrace(e.info);
            }
            catch (Exception e)
            {
                request.state.askToWarn("Webtitles saw unexpected exception: <l>" ~ e.msg);
                version(PrintStacktraces) request.state.askToTrace(e.toString);
            }

            // Dropped down; end foreach by returning
            return;
        }
    }

    tryLookup();
}


// lookupTitle
/++
    Given a URL, tries to look up the web page title of it.

    Params:
        url = URL string to look up.
        descriptions = Whether or not to look up meta descriptions.
        caBundleFile = Path to a `cacert.pem` SSL certificate bundle.

    Returns:
        A finished [TitleLookupResults].

    Throws:
        [TitleFetchException] if URL could not be fetched, or if no title
        could be divined from it.
 +/
auto lookupTitle(
    const string url,
    const Flag!"descriptions" descriptions,
    const string caBundleFile)
{
    import kameloso.constants : KamelosoInfo, Timeout;
    import lu.string : beginsWith, nom;
    import arsd.dom : Document;
    import arsd.http2 : HttpClient, Uri;
    import std.algorithm.comparison : among;
    import std.array : Appender;
    import std.uni : toLower;
    import core.time : seconds;

    // No need to keep a static HttpClient since this will be in a new thread every time
    auto client = new HttpClient;
    client.useHttp11 = true;
    client.keepAlive = false;
    client.acceptGzip = false;
    client.defaultTimeout = Timeout.httpGET.seconds;  // FIXME
    client.userAgent = "kameloso/" ~ cast(string)KamelosoInfo.version_;
    if (caBundleFile.length) client.setClientCertificate(caBundleFile, caBundleFile);

    auto req = client.request(Uri(url));
    auto res = req.waitForCompletion();

    if (res.code.among!(301, 302, 307, 308))
    {
        // Moved
        foreach (immutable i; 0..5)
        {
            req = client.request(Uri(res.location));
            res = req.waitForCompletion();
            if (!res.code.among!(301, 302, 307, 308) || !res.location.length) break;
        }
    }

    if ((res.code == 2) || (res.code >= 400) || !res.contentText.length)
    {
        // res.codeText among Bad Request, probably Not Found, ...
        throw new TitleFetchException(
            res.codeText,
            url,
            res.code,
            __FILE__,
            __LINE__);
    }

    auto doc = new Document;
    doc.parseGarbage("");  // Work around missing null check, causing segfaults on empty pages
    doc.parseGarbage(res.responseText);

    if (!doc.title.length)
    {
        enum message = "No title tag found";
        throw new TitleFetchException(
            message,
            url,
            res.code,
            __FILE__,
            __LINE__);
    }

    string slice = url;  // mutable
    slice.nom("//");
    string host = slice.nom!(Yes.inherit)('/').toLower;
    if (host.beginsWith("www.")) host = host[4..$];

    TitleLookupResults results;
    results.title = decodeEntities(doc.title);
    results.domain = host;

    if (descriptions)
    {
        import std.algorithm.searching : canFind;

        if (!descriptionExemptions.canFind(host))
        {
            auto metaTags = doc.getElementsByTagName("meta");

            foreach (tag; metaTags)
            {
                if (tag.name == "description")
                {
                    results.description = decodeEntities(tag.content);
                    break;
                }
            }
        }
    }

    return results;
}


// reportTitle
/++
    Echoes the result of a web title lookup to a channel.

    Params:
        request = A [TitleLookupRequest] containing the results of the lookup.
 +/
void reportTitle(TitleLookupRequest request)
{
    string line;

    if (request.results.domain.length)
    {
        import std.format : format;

        immutable maybePipe = request.results.description.length ? " | " : string.init;
        enum pattern = "[<b>%s<b>] %s%s%s";
        line = pattern.format(request.results.domain, request.results.title,
                maybePipe, request.results.description);
    }
    else
    {
        line = request.results.title;
    }

    // "PRIVMSG #12345678901234567890123456789012345678901234567890 :".length == 61
    enum maxLen = (510 - 61);

    if (line.length > maxLen)
    {
        // " [...]".length == 6
        line = line[0..(maxLen-6)] ~ " [...]";
    }

    chan(request.state, request.event.channel, line);
}


// reportYouTubeTitle
/++
    Echoes the result of a YouTube lookup to a channel.

    Params:
        request = A [TitleLookupRequest] containing the results of the lookup.
 +/
void reportYouTubeTitle(TitleLookupRequest request)
{
    import std.format : format;

    enum pattern = "[<b>youtube.com<b>] %s (uploaded by <h>%s<h>)";
    immutable message = pattern.format(request.results.youtubeTitle, request.results.youtubeAuthor);
    chan(request.state, request.event.channel, message);
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
    import lu.string : beginsWith, nom;
    import std.typecons : No, Yes;

    if (url.beginsWith("https://i.imgur.com/"))
    {
        immutable path = url[20..$].nom!(Yes.decode)('.');
        return "https://imgur.com/" ~ path;
    }
    else if (url.beginsWith("http://i.imgur.com/"))
    {
        immutable path = url[19..$].nom!(Yes.decode)('.');
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


// getYouTubeInfo
/++
    Fetches the JSON description of a YouTube video link, allowing us to report
    it the page's title without having to actually fetch the video page.

    Example:
    ---
    auto info = getYouTubeInfo("https://www.youtube.com/watch?v=s-mOy8VUEBk");
    writeln(info["title"].str);
    writeln(info["author"].str);
    ---

    Params:
        url = A YouTube video link string.
        caBundleFile = Path to a `cacert.pem` SSL certificate bundle.

    Returns:
        A [std.json.JSONValue|JSONValue] with fields describing the looked-up video.

    Throws:
        [TitleFetchException] if the YouTube ID was invalid and could not be queried.

        [std.json.JSONException|JSONException] if the JSON response could not be parsed.
 +/
auto getYouTubeInfo(const string url, const string caBundleFile)
{
    import kameloso.constants : KamelosoInfo, Timeout;
    import arsd.http2 : HttpClient, Uri;
    import std.algorithm.comparison : among;
    import std.array : Appender;
    import std.exception : assumeUnique;
    import std.json : parseJSON;
    import core.time : seconds;

    // No need to keep a static HttpClient since this will be in a new thread every time
    auto client = new HttpClient;
    client.useHttp11 = true;
    client.keepAlive = false;
    client.acceptGzip = false;
    client.defaultTimeout = Timeout.httpGET.seconds;  // FIXME
    client.userAgent = "kameloso/" ~ cast(string)KamelosoInfo.version_;
    if (caBundleFile.length) client.setClientCertificate(caBundleFile, caBundleFile);

    immutable youtubeURL = "https://www.youtube.com/oembed?format=json&url=" ~ url;

    auto req = client.request(Uri(youtubeURL));
    auto res = req.waitForCompletion();

    if (res.code.among!(301, 302, 307, 308))
    {
        // Moved
        foreach (immutable i; 0..5)
        {
            req = client.request(Uri(res.location));
            res = req.waitForCompletion();
            if (!res.code.among!(301, 302, 307, 308) || !res.location.length) break;
        }
    }

    if ((res.code == 2) || (res.code >= 400) || !res.contentText.length)
    {
        // res.codeText among Bad Request, probably Not Found, ...
        throw new TitleFetchException(res.codeText, url, res.code, __FILE__, __LINE__);
    }

    return parseJSON(res.contentText);
}


// TitleFetchException
/++
    A normal [object.Exception|Exception] but with an HTTP status code attached.
 +/
final class TitleFetchException : Exception
{
@safe:
    /// The URL that was attempted to fetch the title of.
    string url;

    /// The HTTP status code that was returned when attempting to fetch a title.
    uint code;

    /++
        Create a new [TitleFetchException], attaching an URL and an HTTP status code.
     +/
    this(const string message,
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
    this(const string message,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }
}


// decodeEntities
/++
    Removes unwanted characters from a string, and decodes HTML entities in it
    (like `&mdash;` and `&nbsp;`).

    Params:
        title = Title string to decode entities and remove tags from.

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


// prune
/++
    Garbage-collects old entries in a `TitleLookupResults[string]` lookup cache.

    Params:
        cache = Cache of previous [TitleLookupResults], `shared` so that it can
            be reused in further lookup (other threads).
        expireSeconds = After how many seconds a cached entry is considered to
            have expired and should no longer be used as a valid entry.
 +/
void prune(shared TitleLookupResults[string] cache, const uint expireSeconds)
{
    import lu.objmanip : pruneAA;
    import std.datetime.systime : Clock;

    if (!cache.length) return;

    immutable now = Clock.currTime.toUnixTime;

    synchronized //()
    {
        pruneAA!((entry) => (now - entry.when) > expireSeconds)(cache);
    }
}


// initialise
/++
    Initialises the shared cache, else it won't retain changes.

    Just assign an entry and remove it.
 +/
void initialise(WebtitlesPlugin plugin)
{
    // No need to synchronise this; no worker threads are running
    plugin.cache[string.init] = TitleLookupResults.init;
    plugin.cache.remove(string.init);
}


mixin MinimalAuthentication;
mixin PluginRegistration!WebtitlesPlugin;

public:


// WebtitlesPlugin
/++
    The Webtitles plugin catches HTTP URL links in messages, connects to
    their servers and and streams the web page itself, looking for the web page's
    title. This is then reported to the originating channel or personal query.
 +/
final class WebtitlesPlugin : IRCPlugin
{
private:
    /// All Webtitles options gathered.
    WebtitlesSettings webtitlesSettings;

    /// Cache of recently looked-up web titles.
    shared TitleLookupResults[string] cache;

    /++
        How long before a cached title lookup expires and its address has to be
        looked up anew.
     +/
    enum expireSeconds = 600;

    /// In the case of chained URL lookups, how many milliseconds to delay each lookup by.
    enum delayMsecs = 100;

    /++
        How big a buffer to initially allocate when downloading web pages to get
        their titles.
     +/
    enum lookupBufferSize = 8192;

    mixin IRCPluginImpl;
}
