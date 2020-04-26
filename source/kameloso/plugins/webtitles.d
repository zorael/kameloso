/++
 +  The Webtitles plugin catches URLs pasted in a channel, follows them and
 +  reports back the title of the web page that was linked to.
 +
 +  It has no bot commands; everything is done by automatically scanning channel
 +  and private query messages for things that look like links.
 +
 +  It requires version `Web` for obvious reasons.
 +/
module kameloso.plugins.webtitles;

version(WithPlugins):
version(Web):
version(WithWebtitlesPlugin):

private:

import kameloso.plugins.ircplugin;
import kameloso.plugins.common;
import kameloso.plugins.awareness : MinimalAuthentication;
import kameloso.irccolours : ircBold;
import kameloso.messaging;
import kameloso.thread : ThreadMessage;
import dialect.defs;
import requests : Request;
import std.concurrency;
import std.json : JSONValue;
import std.typecons : Flag, No, Yes;


// WebtitlesSettings
/++
 +  All Webtitles settings, gathered in a struct.
 +/
@Settings struct WebtitlesSettings
{
    /// Toggles whether or not the plugin should react to events at all.
    @Enabler bool enabled = true;

    /// Toggles whether YouTube lookups should be done for pasted URLs.
    bool youtubeLookup = true;

    /// Toggles whether Reddit lookups should be done for pasted URLs.
    bool redditLookup = false;

    /// Toggles whether or not Reddit and title are reported simultaneously. This can be slow.
    bool simultaneousReddit = false;
}


// TitleLookupResults
/++
 +  A record of a URL lookup.
 +
 +  This is both used to aggregate information about the lookup, as well as to
 +  add hysteresis to lookups, so we don't look the same one up over and over
 +  if they were pasted over and over.
 +/
struct TitleLookupResults
{
    /// Looked up web page title.
    string title;

    /// Domain name of the looked up URL.
    string domain;

    /// YouTube video title, if such a YouTube link.
    string youtubeTitle;

    /// YouTube video author, if such a YouTube link.
    string youtubeAuthor;

    /// URL to the Reddit post linking to the requested URL.
    string redditURL;

    /// The UNIX timestamp of when the title was looked up.
    long when;
}


// TitleLookupRequest
/++
 +  A record of a URL lookup request.
 +
 +  This is used to aggregate information about a lookup request, making it
 +  easier to pass it in between functions. It serves no greater purpose.
 +/
struct TitleLookupRequest
{
    /// The context state of the requesting plugin instance.
    IRCPluginState state;

    /// The `dialect.defs.IRCEvent` that instigated the lookup.
    IRCEvent event;

    /// URL to look up.
    string url;

    /// Results of the title lookup.
    TitleLookupResults results;
}


// onMessage
/++
 +  Parses a message to see if the message contains one or more URLs.
 +
 +  It uses a simple state machine in `kameloso.common.findURLs` to exhaustively
 +  try to look up every URL returned by it.
 +/
@(Terminating)
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.ignore)
@(ChannelPolicy.home)
void onMessage(WebtitlesPlugin plugin, const IRCEvent event)
{
    import kameloso.common : findURLs;
    import lu.string : beginsWith;

    if (event.content.beginsWith(plugin.state.settings.prefix)) return;

    string[] urls = findURLs(event.content);  // mutable so nom works
    if (!urls.length) return;

    return plugin.lookupURLs(event, urls);
}


// lookupURLs
/++
 +  Looks up the URLs in the passed `string[]` `urls` by spawning a worker
 +  thread to do all the work.
 +
 +  It accesses the cache of already looked up addresses to speed things up.
 +/
void lookupURLs(WebtitlesPlugin plugin, const IRCEvent event, string[] urls)
{
    import kameloso.common : Tint, logger;
    import lu.string : beginsWith, contains, nom;

    bool[string] duplicates;

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

        if (url in duplicates) continue;

        duplicates[url] = true;

        logger.info("Caught URL: ", Tint.log, url);

        TitleLookupRequest request;
        request.state = plugin.state;
        request.event = event;
        request.url = url;

        if (plugin.cache.length) prune(plugin.cache, plugin.expireSeconds);

        if (const cachedResult = url in plugin.cache)
        {
            logger.log("Found cached lookup.");
            request.results = *cachedResult;

            if (request.results.youtubeTitle.length)
            {
                reportDispatch(&reportYouTubeTitle, request,
                    plugin.webtitlesSettings, plugin.state.settings.colouredOutgoing);
            }
            else
            {
                reportDispatch(&reportTitle, request,
                    plugin.webtitlesSettings, plugin.state.settings.colouredOutgoing);
            }
            continue;
        }

        /// In the case of chained URL lookups, how much to delay each lookup by.
        enum delayMsecs = 250;

        spawn(&worker, cast(shared)request, plugin.cache, i*delayMsecs,
            plugin.webtitlesSettings, plugin.state.settings.colouredOutgoing);
    }
}


// worker
/++
 +  Looks up and reports the title of a URL.
 +
 +  Additionally supports YouTube titles and authors, as well as reporting
 +  Reddit post URLs if settings say to do such.
 +
 +  Worker to be run in its own thread.
 +
 +  Params:
 +      sRequest = Shared `TitleLookupRequest` aggregate with all the state and
 +          context needed to look up a URL and report the results to the local terminal.
 +      cache = Shared cache of previous `TitleLookupRequest`s.
 +      delayMsecs = Milliseconds to delay before doing the lookup, to allow for
 +          parallel lookups without bursting all of them at once.
 +      webtitlesSettings = Copy of the plugin's settings.
 +      colouredOutgoing = Whether or not to send coloured output to the server.
 +/
void worker(shared TitleLookupRequest sRequest, shared TitleLookupResults[string] cache,
    const ulong delayMsecs, const WebtitlesSettings webtitlesSettings, const bool colouredOutgoing)
{
    version(Posix)
    {
        import kameloso.thread : setThreadName;
        setThreadName("webtitles");
    }

    if (delayMsecs > 0)
    {
        import core.thread : Thread;
        import core.time : msecs;
        Thread.sleep(delayMsecs.msecs);
    }

    TitleLookupRequest request = cast()sRequest;

    try
    {
        import lu.string : beginsWith, contains, nom;
        import std.datetime.systime : Clock;
        import std.typecons : No, Yes;

        immutable now = Clock.currTime.toUnixTime;

        if (request.url.contains("://i.imgur.com/"))
        {
            // imgur direct links naturally have no titles, but the normal pages do.
            // Rewrite and look those up instead.
            request.url = rewriteDirectImgurURL(request.url);
        }
        else if (webtitlesSettings.youtubeLookup &&
            (request.url.contains("youtube.com/watch?v=") ||
            request.url.contains("youtu.be/")))
        {
            // Do our own slicing instead of using regexes, because footprint.
            string slice = request.url;

            slice.nom!(Yes.decode)("http");
            if (slice[0] == 's') slice = slice[1..$];
            slice = slice[3..$];  // ://

            if (slice.beginsWith("www.")) slice.nom!(Yes.decode)('.');

            if (slice.beginsWith("youtube.com/watch?v=") ||
                slice.beginsWith("youtu.be/"))
            {
                import std.json : JSONException;

                try
                {
                    immutable info = getYouTubeInfo(request.url);

                    // Let's assume all YouTube clips have titles and authors
                    // Should we decode the author too?
                    request.results.youtubeTitle = decodeTitle(info["title"].str);
                    request.results.youtubeAuthor = info["author_name"].str;

                    reportDispatch(&reportYouTubeTitle, request,
                        webtitlesSettings, colouredOutgoing);

                    request.results.when = now;
                    cache[request.url] = cast(shared)request.results;
                    return;
                }
                catch (JSONException e)
                {
                    request.state.askToWarn("Failed to parse YouTube video information: " ~ e.msg);
                    //version(PrintStacktraces) request.state.askToTrace(e.info);
                    // Drop down
                }
                catch (Exception e)
                {
                    request.state.askToError("Error parsing YouTube video information: " ~ e.msg);
                    version(PrintStacktraces) request.state.askToTrace(e.toString);
                    // Drop down
                }
            }
            else
            {
                // Unsure what this is really. Drop down and treat like normal link
            }
        }

        import core.exception : UnicodeException;

        void lookupAndReport()
        {
            request.results = lookupTitle(request.url);
            reportDispatch(&reportTitle, request, webtitlesSettings, colouredOutgoing);
            request.results.when = now;
            cache[request.url] = cast(shared)request.results;
        }

        try
        {
            lookupAndReport();
        }
        catch (UnicodeException e)
        {
            request.state.askToError("Webtitles worker Unicode exception: " ~
                e.msg ~ " (link is probably to an image or similar)");
            //version(PrintStacktraces) request.state.askToTrace(e.info);
        }
        catch (Exception e)
        {
            request.state.askToWarn("Webtitles worker exception: " ~ e.msg);
            //version(PrintStacktraces) request.state.askToTrace(e.info);
            request.state.askToLog("Rewriting URL and retrying ...");

            if (request.url[$-1] == '/')
            {
                request.url = request.url[0..$-1];
            }
            else
            {
                request.url ~= '/';
            }

            lookupAndReport();
        }
    }
    catch (Exception e)
    {
        request.state.askToError("Webtitles worker exception: " ~ e.msg);
        version(PrintStacktraces) request.state.askToTrace(e.toString);
    }
}


// reportDispatch
/++
 +  Calls the passed report function in the correct order with regards to Reddit-reporting.
 +
 +  Params:
 +      reportFun = Actual reporting function to call.
 +      request = The `TitleLookupRequest` that embodies this lookup, including
 +          its looked-up results.
 +      webtitlesSettings = A copy of the plugin's `WebtitlesPlugin.webtitlesSettings`
 +          so we know whether to and in what manner to do Reddit lookups.
 +      colouredOutgoing = Whether or not to include mIRC colours in the IRC output.
 +/
void reportDispatch(void function(TitleLookupRequest, const bool) reportFun,
    TitleLookupRequest request, const WebtitlesSettings webtitlesSettings,
    const bool colouredOutgoing)
{
    // If simultaneous, check Reddit first and report later
    if (webtitlesSettings.simultaneousReddit)
    {
        if (webtitlesSettings.redditLookup && !request.results.redditURL.length)
        {
            // This may be a cached entry, only look up if it isn't already known
            request.results.redditURL = lookupReddit(request.url);
        }

        reportFun(request, colouredOutgoing);
    }
    else
    {
        reportFun(request, colouredOutgoing);

        if (webtitlesSettings.redditLookup && !request.results.redditURL.length)
        {
            // Ditto
            request.results.redditURL = lookupReddit(request.url);
        }
    }

    if (webtitlesSettings.redditLookup) reportReddit(request);
}


// setRequestHeaders
/++
 +  Sets the HTTP request headers of a `requests.Request` to better reflect our
 +  behaviour of only downloading text files.
 +
 +  By placing it into its own function we can reuse it when downloading pages
 +  normally and when requesting Reddit links.
 +
 +  Params:
 +      req = Reference to the `requests.Request` to add headers to.
 +/
void setRequestHeaders(ref Request req)
{
    import kameloso.constants : KamelosoInfo;

    immutable headers =
    [
        "User-Agent" : "kameloso/" ~ cast(string)KamelosoInfo.version_,
        "Accept" : "text/html",
    ];

    req.addHeaders(headers);
}


// lookupTitle
/++
 +  Given a URL, tries to look up the web page title of it.
 +
 +  Params:
 +      url = URL string to look up.
 +
 +  Returns:
 +      A finished `TitleLookupResults`.
 +
 +  Throws: `object.Exception` if URL could not be fetched, or if no title could be
 +      divined from it.
 +/
TitleLookupResults lookupTitle(const string url)
{
    import kameloso.constants : BufferSize;
    import arsd.dom : Document;
    import std.array : Appender;
    import std.conv : to;

    Request req;
    req.useStreaming = true;
    req.keepAlive = false;
    req.bufferSize = BufferSize.titleLookup;
    setRequestHeaders(req);

    auto res = req.get(url);

    if (res.code >= 400)
    {
        import std.conv : text;
        throw new Exception(res.code.text ~ " fetching URL " ~ url);
    }

    Document doc = new Document;
    Appender!dstring sink;
    sink.reserve(BufferSize.titleLookup);

    auto stream = res.receiveAsRange();

    foreach (const part; stream)
    {
        sink.put((cast(char[])part).to!dstring);
        doc.parseGarbage(sink.data.to!string);
        if (doc.title.length) break;
    }

    if (!doc.title.length)
    {
        throw new Exception("No title tag found");
    }

    TitleLookupResults results;
    results.title = decodeTitle(doc.title);
    results.domain = res.finalURI.original_host;  // thanks to ikod

    import lu.string : beginsWith;
    if (results.domain.beginsWith("www."))
    {
        import lu.string : nom;
        results.domain.nom('.');
    }

    return results;
}


// reportTitle
/++
 +  Echoes the result of a web title lookup to a channel.
 +
 +  Params:
 +      request = A `TitleLookupRequest` containing the results of the lookup.
 +      colouredOutput = Whether or not to send coloured output to the server.
 +/
void reportTitle(TitleLookupRequest request, const bool colouredOutput)
{
    with (request)
    {
        string line;

        if (results.domain.length)
        {
            import std.format : format;

            line = colouredOutput ?
                "[%s] %s".format(results.domain.ircBold, results.title) :
                "[%s] %s".format(results.domain, results.title);
        }
        else
        {
            line = results.title;
        }

        chan(state, event.channel, line);
    }
}


// reportYouTubeTitle
/++
 +  Echoes the result of a YouTube lookup to a channel.
 +
 +  Params:
 +      request = A `TitleLookupRequest` containing the results of the lookup.
 +      colouredOutput = Whether or not to send coloured output to the server.
 +/
void reportYouTubeTitle(TitleLookupRequest request, const bool colouredOutput)
{
    with (request)
    {
        import kameloso.irccolours : ircColourByHash;
        import std.format : format;

        immutable line = colouredOutput ?
            "[%s] %s (uploaded by %s)"
                .format("youtube.com".ircBold, results.youtubeTitle,
                colouredOutput ?
                    results.youtubeAuthor.ircColourByHash :
                    results.youtubeAuthor.ircBold) :
            "[youtube.com] %s (uploaded by %s)"
                .format(results.youtubeTitle, results.youtubeAuthor);

        chan(state, event.channel, line);
    }
}


// reportReddit
/++
 +  Reports the Reddit post that links to the looked up URL.
 +
 +  Params:
 +      request = A `TitleLookupRequest` containing the results of the lookup.
 +/
void reportReddit(TitleLookupRequest request)
{
    with (request)
    {
        if (results.redditURL.length)
        {
            chan(state, event.channel, "Reddit: " ~ results.redditURL);
        }
    }
}


// rewriteDirectImgurURL
/++
 +  Takes a direct imgur link (one that points to an image) and rewrites it to
 +  instead point to the image's page.
 +
 +  Images (`jpg`, `png`, ...) can naturally not have titles, but the normal pages can.
 +
 +  Params:
 +      url = String link to rewrite.
 +
 +  Returns:
 +      A rewritten string if it's a compatible imgur one, else the passed `url`.
 +/
string rewriteDirectImgurURL(const string url) @safe pure
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
 +  Fetches the JSON description of a YouTube video link, allowing us to report
 +  it the page's title without having to actually fetch the video page.
 +
 +  Example:
 +  ---
 +  auto info = getYouTubeInfo("https://www.youtube.com/watch?v=s-mOy8VUEBk");
 +  writeln(info["title"].str);
 +  writeln(info["author"].str);
 +  ---
 +
 +  Params:
 +      url = A YouTube video link string.
 +
 +  Returns:
 +      A `std.json.JSONValue` with fields describing the looked-up video.
 +
 +  Throws:
 +      `core.Exception` if the YouTube ID was invalid and could not be queried.
 +      `std.json.JSONException` if the JSON response could not be parsed.
 +/
JSONValue getYouTubeInfo(const string url)
{
    import requests : getContent;
    import std.json : parseJSON;

    immutable youtubeURL = "https://www.youtube.com/oembed?url=" ~ url ~ "&format=json";
    const data = cast(char[])getContent(youtubeURL).data;

    if (data == "Not Found")
    {
        // Invalid video ID
        throw new Exception("Invalid YouTube video ID");
    }

    return parseJSON(data);
}


// decodeTitle
/++
 +  Removes unwanted characters from a title, and decodes HTML entities in it
 +  (like `&mdash;` and `&nbsp;`).
 +
 +  Params:
 +      title = Title string to decode entities and remove tags from.
 +
 +  Returns:
 +      A modified title string, with unwanted bits stripped out.
 +/
string decodeTitle(const string title)
{
    import lu.string : stripped;
    import arsd.dom : htmlEntitiesDecode;
    import std.array : replace;

    return title
        .replace("\r", string.init)
        .replace("\n", " ")
        .stripped
        .htmlEntitiesDecode();
}

///
unittest
{
    immutable t1 = "&quot;Hello&nbsp;world!&quot;";
    immutable t1p = decodeTitle(t1);
    assert((t1p == "\"Hello\u00A0world!\""), t1p);  // not a normal space

    immutable t2 = "&lt;/title&gt;";
    immutable t2p = decodeTitle(t2);
    assert((t2p == "</title>"), t2p);

    immutable t3 = "&mdash;&micro;&acute;&yen;&euro;";
    immutable t3p = decodeTitle(t3);
    assert((t3p == "—µ´¥€"), t3p);  // not a normal dash

    immutable t4 = "&quot;Se&ntilde;or &THORN;&quot; &copy;2017";
    immutable t4p = decodeTitle(t4);
    assert((t4p == `"Señor Þ" ©2017`), t4p);

    immutable t5 = "\n        Nyheter - NSD.se        \n";
    immutable t5p = decodeTitle(t5);
    assert(t5p == "Nyheter - NSD.se");
}


// lookupReddit
/++
 +  Given a URL, looks it up on Reddit to see if it has been posted there.
 +
 +  Params:
 +      url = URL to query Reddit for.
 +      modified = Whether the URL has been modified to add an extra slash at
 +          the end, or remove one if one already existed.
 +
 +  Returns:
 +      URL to the Reddit post that links to `url`.
 +/
string lookupReddit(const string url, const bool modified = false)
{
    import kameloso.constants : BufferSize;
    import lu.string : contains;

    // Don't look up Reddit URLs. Naïve match, may have false negatives.
    // Also skip YouTube links.
    if (url.contains("reddit.com/") || url.contains("youtube.com/")) return string.init;

    Request req;
    req.useStreaming = true;  // we only want as little as possible
    req.keepAlive = false;
    req.bufferSize = BufferSize.titleLookup;
    setRequestHeaders(req);

    auto res = req.get("https://www.reddit.com/" ~ url);

    with (res.finalURI)
    {
        import lu.string : beginsWith;

        if (uri.beginsWith("https://www.reddit.com/login") ||
            uri.beginsWith("https://www.reddit.com/submit") ||
            uri.beginsWith("https://www.reddit.com/http"))
        {
            import std.algorithm.searching : endsWith;

            // Whether URLs end with slashes or not seems to matter.
            // If we're here, no post could be found, so strip any trailing
            // slashes and retry, or append a slash and retry if no trailing.
            // Pass a bool flag to only do this once, so we don't infinitely recurse.

            if (modified) return string.init;

            return url.endsWith("/") ?
                lookupReddit(url[0..$-1], true) :
                lookupReddit(url ~ '/', true);
        }
        else
        {
            // Has been posted to Reddit
            return res.finalURI.uri;
        }
    }
}


// prune
/++
 +  Garbage-collects old entries in a `TitleLookupResults[string]` lookup cache.
 +
 +  Params:
 +      cache = Cache of previous `TitleLookupResults`, `shared` so that it can
 +          be reused in further lookup (other threads).
 +/
void prune(shared TitleLookupResults[string] cache, const uint expireSeconds)
{
    import lu.objmanip : pruneAA;
    import std.datetime.systime : Clock;

    if (!cache.length) return;

    immutable now = Clock.currTime.toUnixTime;

    synchronized
    {
        pruneAA!((entry) => (now - entry.when) > expireSeconds)(cache);
    }
}


// start
/++
 +  Initialises the shared cache, else it won't retain changes.
 +
 +  Just assign an entry and remove it.
 +/
void start(WebtitlesPlugin plugin)
{
    plugin.cache[string.init] = TitleLookupResults.init;
    plugin.cache.remove(string.init);
}


import kameloso.thread : Sendable;

// onBusMessage
/++
 +  Catches bus messages with the "`webtitles`" header requesting URLs to be
 +  looked up and the titles of which reported.
 +
 +  Only relevant on Twitch servers, so gate it behind version TwitchSupport.
 +  No point in checking `plugin.state.server.daemon == IRCServer.Daemon.twitch`
 +  as these messages will never be sent on other servers.
 +
 +  Params:
 +      plugin = The current `WebtitlesPlugin`.
 +      header = String header describing the passed content payload.
 +      content = Message content.
 +/
version(TwitchSupport)
void onBusMessage(WebtitlesPlugin plugin, const string header, shared Sendable content)
{
    if (header != "webtitles") return;

    import kameloso.thread : BusMessage;
    import std.typecons : Tuple;

    alias EventAndURLs = Tuple!(IRCEvent, string[]);

    auto message = cast(BusMessage!EventAndURLs)content;
    assert(message, "Incorrectly cast message: " ~ typeof(message).stringof);

    auto eventAndURLs = cast(EventAndURLs)message.payload;
    plugin.lookupURLs(eventAndURLs[0], eventAndURLs[1]);
}


mixin MinimalAuthentication;

public:


// WebtitlesPlugin
/++
 +  The Webtitles plugin catches HTTP URL links in messages, connects to
 +  their servers and and streams the web page itself, looking for the web page's
 +  title. This is then reported to the originating channel or personal query.
 +/
final class WebtitlesPlugin : IRCPlugin
{
private:
    /// All Webtitles options gathered.
    WebtitlesSettings webtitlesSettings;

    /// Cache of recently looked-up web titles.
    shared TitleLookupResults[string] cache;

    /++
     +  How long before a cached title lookup expires and its address has to be
     +  looked up anew.
     +/
    enum expireSeconds = 600;

    mixin IRCPluginImpl;

    // onEvent
    /++
     +  Override `kameloso.plugins.ircplugin.IRCPluginImpl.onEvent` and inject
     +  a server check, so this plugin does not trigger on
     +  `dialect.defs.IRCEvent`s on Twitch servers.
     +
     +  The function to call if the event *should* be processed is
     +  `kameloso.plugins.ircplugin.IRCPluginImpl.onEventImpl`.
     +
     +  Params:
     +      event = Parsed `dialect.defs.IRCEvent` to pass onto
     +          `kameloso.plugins.ircplugin.IRCPluginImpl.onEventImpl`
     +          after verifying we should process the event.
     +/
    version(TwitchSupport)
    override public void onEvent(const IRCEvent event)
    {
        if (state.server.daemon == IRCServer.Daemon.twitch) return;
        return onEventImpl(event);
    }
}
