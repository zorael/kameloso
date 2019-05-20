/++
 +  The Webtitles plugin catches URLs pasted in a channel, follows them and
 +  reports beck the title of the web page that was linked to.
 +
 +  It has no bot commands; everything is done by automatically scanning channel
 +  and private query messages for things that look like links.
 +
 +  It requires version `Web` for obvious reasons.
 +
 +  It is optional.
 +/
module kameloso.plugins.webtitles;

version(WithPlugins):
version(Web):
version(WithWebtitlesPlugin):

private:

import kameloso.thread : ThreadMessage;
import kameloso.messaging;
import kameloso.plugins.common;
import kameloso.irc.defs;
import kameloso.irc.colours : ircBold;

import requests : Request;

import std.concurrency;
import std.json : JSONValue;
import std.typecons : Flag, No, Yes;


// WebtitlesSettings
/++
 +  All Webtitles settings, gathered in a struct.
 +/
struct WebtitlesSettings
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
 +  A record of an URL lookup request.
 +
 +  This is used to aggregate information about a lookup request, making it
 +  easier to pass it in between functions. It serves no greater purpose.
 +/
struct TitleLookupRequest
{
    /// The context state of the requesting plugin instance.
    IRCPluginState state;

    /// The `kameloso.irc.defs.IRCEvent` that instigated the lookup.
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
 +  It uses a simple state machine in `findURLs` to exhaustively try to look up
 +  every URL returned by it. It accesses the cache of already looked up
 +  addresses to lessen the amount of work.
 +/
@(Terminating)
@(IRCEvent.Type.CHAN)
@(PrivilegeLevel.ignore)
@(ChannelPolicy.home)
void onMessage(WebtitlesPlugin plugin, const IRCEvent event)
{
    import kameloso.common : logger, settings;
    import kameloso.string : beginsWith, contains;

    if (event.content.beginsWith(settings.prefix)) return;

    string infotint;

    foreach (immutable i, url; findURLs(event.content))
    {
        version(Colours)
        {
            import kameloso.common : settings;

            if (!settings.monochrome && !infotint.length)
            {
                import kameloso.logger : KamelosoLogger;
                infotint = (cast(KamelosoLogger)logger).infotint;
            }
        }

        if (url.contains!(Yes.decode)('#'))
        {
            import kameloso.string : nom;
            // URL contains an octothorpe fragment identifier, like
            // https://www.google.com/index.html#this%20bit
            // Strip that.
            url = url.nom!(Yes.decode)('#');
        }

        logger.log("Caught URL: ", infotint, url);

        TitleLookupRequest request;
        request.state = plugin.state;
        request.event = event;
        request.url = url;

        prune(plugin.cache);

        if (auto cachedResult = url in plugin.cache)
        {
            logger.log("Found cached lookup.");
            request.results = *cachedResult;
            reportTitle(request, settings.colouredOutgoing);
            if (plugin.webtitlesSettings.redditLookup) reportReddit(request);
            continue;
        }

        /// In the case of chained URL lookups, how much to delay each lookup by.
        enum delayMsecs = 250;

        spawn(&worker, cast(shared)request, plugin.cache, i*delayMsecs,
            plugin.webtitlesSettings, settings.colouredOutgoing);
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
    ulong delayMsecs, WebtitlesSettings webtitlesSettings, bool colouredOutgoing)
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
        import kameloso.string : beginsWith, contains, nom;
        import std.datetime.systime : Clock;
        import std.typecons : No, Yes;

        /// Calls the passed report function in the correct order with regards to Reddit-reporting.
        void reportDispatch(alias reportImpl)()
        {
            // If simultaneous, check Reddit first and report later
            if (webtitlesSettings.simultaneousReddit)
            {
                if (webtitlesSettings.redditLookup) request.results.redditURL = lookupReddit(request.url);
                reportImpl(request, colouredOutgoing);
            }
            else
            {
                reportImpl(request, colouredOutgoing);
                if (webtitlesSettings.redditLookup) request.results.redditURL = lookupReddit(request.url);
            }

            if (webtitlesSettings.redditLookup) reportReddit(request);
        }

        if (request.url.contains("://i.imgur.com/"))
        {
            // imgur direct links naturally have no titles, but the normal pages do.
            // Rewrite and look those up instead.
            request.url = rewriteDirectImgurURL(request.url);
        }
        else if (webtitlesSettings.youtubeLookup &&
            request.url.contains("youtube.com/watch?v=") ||
            request.url.contains("youtu.be/"))
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

                    reportDispatch!reportYouTubeTitle();

                    request.results.when = Clock.currTime.toUnixTime;
                    cache[request.url] = cast(shared)request.results;
                    return;
                }
                catch (JSONException e)
                {
                    request.state.askToWarn("Failed to parse YouTube video information: " ~ e.msg);
                    // Drop down
                }
                catch (Exception e)
                {
                    request.state.askToError("Error parsing YouTube video information: " ~ e.msg);
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
            reportDispatch!reportTitle();
            request.results.when = Clock.currTime.toUnixTime;
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
        }
        catch (Exception e)
        {
            request.state.askToWarn("Webtitles worker exception: " ~ e.msg);
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
    }
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
 +  Given an URL, tries to look up the web page title of it.
 +
 +  Params:
 +      url = URL string to look up.
 +
 +  Returns:
 +      A finished `TitleLookup`.
 +
 +  Throws: `Exception` if URL could not be fetched, or if no title could be
 +      divined from it.
 +/
TitleLookupResults lookupTitle(const string url)
{
    import kameloso.constants : BufferSize;
    import arsd.dom : Document;
    import std.array : Appender;

    TitleLookupResults results;
    auto doc = new Document;
    Appender!(ubyte[]) sink;
    sink.reserve(BufferSize.titleLookup);

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

    auto stream = res.receiveAsRange();

    foreach (const part; stream)
    {
        sink.put(part);
        doc.parseGarbage(cast(string)sink.data.idup);
        if (doc.title.length) break;
    }

    if (!doc.title.length)
    {
        throw new Exception("No title tag found");
    }

    results.title = decodeTitle(doc.title);
    results.domain = res.finalURI.original_host;  // thanks to ikod

    import kameloso.string : beginsWith;
    if (results.domain.beginsWith("www."))
    {
        import kameloso.string : nom;
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
        import std.format : format;

        string line;

        if (results.domain.length)
        {
            if (colouredOutput)
            {
                line = "[%s] %s".format(results.domain.ircBold, results.title);
            }
            else
            {
                line = "[%s] %s".format(results.domain, results.title);
            }
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
        import std.format : format;

        string line;

        if (colouredOutput)
        {
            line = "[%s] %s (uploaded by %s)".format("youtube.com".ircBold,
                results.youtubeTitle, results.youtubeAuthor.ircBold);
        }
        else
        {
            line = "[youtube.com] %s (uploaded by %s)"
                .format(results.youtubeTitle, results.youtubeAuthor);
        }

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


// findURLs
/++
 +  Finds URLs in a string, returning an array of them.
 +
 +  Replacement for regex matching using much less memory when compiling
 +  (around ~300mb).
 +
 +  To consider: does this need a `dstring`?
 +
 +  Example:
 +  ---
 +  // Replaces the following:
 +  // enum stephenhay = `\bhttps?://[^\s/$.?#].[^\s]*`;
 +  // static urlRegex = ctRegex!stephenhay;
 +
 +  string[] urls = findURL("blah https://google.com http://facebook.com httpx://wefpokwe");
 +  assert(urls.length == 2);
 +  ---
 +
 +  Params:
 +      line = String line to examine and find URLs in.
 +
 +  Returns:
 +      A `string[]` array of found URLs. These include fragment identifiers.
 +/
string[] findURLs(const string line) @safe pure
{
    import kameloso.string : contains;
    import std.string : indexOf;

    string[] hits;
    string slice = line;

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
            break;  // "http://a.se".length
        }
        else if ((slice[4] != ':') && (slice[4] != 's'))
        {
            // Not http or https, something else
            break;
        }
        else if (!slice[8..$].contains('.'))
        {
            break;
        }

        if (!slice.contains(' '))
        {
            // Check if there's a second URL in the middle of this one
            if (slice[10..$].indexOf("http") != -1) break;
            // Line finishes with the URL
            hits ~= slice;
            break;
        }
        else
        {
            import kameloso.string : nom;
            // The URL is followed by a space
            // Advance past this URL so we can look for the next
            hits ~= slice.nom(' ');
        }

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
        const urls = findURLs("http:// http://asdf https:// asdfhttpasdf http");
        assert(!urls.length, urls.text);
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
}


// rewriteDirectImgurURL
/++
 +  Takes a direct imgur link (one that points to an image) and rewrites it to
 +  instead point to the image's page.
 +
 +  Images (jpg, png, ...) can naturally not have titles, but the normal pages can.
 +
 +  Params:
 +      url = String link to rewrite.
 +
 +  Returns:
 +      A rewritten string if it's a compatible imgur one, else the passed `url`.
 +/
string rewriteDirectImgurURL(const string url) @safe pure
{
    import kameloso.string : beginsWith, nom;
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


/// getYouTubeInfo
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
 +      A `JSONValue` with fields describing the looked-up video.
 +
 +  Throws:
 +      `Exception` if the YouTube ID was invalid and could not be queried.
 +      `JSONException` if the JSON response could not be parsed.
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
    import kameloso.string : stripped;
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
 +  Given an URL, looks it up on Reddit to see if it has been posted there.
 +
 +  Params:
 +      state = The current plugin instance's `kameloso.plugin.common.IRCPluginState`,
 +          for use to send text to the local terminal.
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
    import kameloso.string : contains;

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
        import kameloso.string : beginsWith;

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
void prune(shared TitleLookupResults[string] cache)
{
    import kameloso.common : pruneAA;
    import std.datetime.systime : Clock;

    if (!cache.length) return;

    enum expireSeconds = 600;
    immutable now = Clock.currTime.toUnixTime;

    pruneAA!((entry) => (now - entry.when) > expireSeconds)(cache);
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


mixin MinimalAuthentication;

public:


// Webtitles
/++
 +  The Webtitles plugin catches HTTP URL links in an IRC channel, connects to
 +  its server and and streams the web page itself, looking for the web page's
 +  title. This is then reported to the originating channel or personal query.
 +/
final class WebtitlesPlugin : IRCPlugin
{
private:
    /// Cache of recently looked-up web titles.
    shared TitleLookupResults[string] cache;

    /// All Webtitles options gathered.
    @Settings WebtitlesSettings webtitlesSettings;

    mixin IRCPluginImpl;
}
