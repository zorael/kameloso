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

private:

import kameloso.thread : ThreadMessage;
import kameloso.messaging;
import kameloso.plugins.common;
import kameloso.irc.defs;
import kameloso.irc.colours : ircBold;

import std.concurrency;
import std.typecons : Flag, No, Yes;


// WebtitlesSettings
/++
 +  All Webtitles settings, gathered in a struct.
 +/
struct WebtitlesSettings
{
    /// Toggles whether or not the plugin should react to events at all.
    @Enabler bool enabled = true;
}


// TitleLookup
/++
 +  A record of a URL lookup.
 +
 +  This is both used to aggregate information about the lookup, as well as to
 +  add hysteresis to lookups, so we don't look the same one up over and over
 +  if they were pasted over and over.
 +/
struct TitleLookup
{
    /// Looked up web page title.
    string title;

    /// Domain name of the looked up URL.
    string domain;

    /// The UNIX timestamp of when the title was looked up.
    long when;
}


// TitleRequest
/++
 +  A record of an URL lookup request.
 +
 +  This is used to aggregate information about a lookup request, making it
 +  easier to pass it in between functions. It serves no greater purpose.
 +/
struct TitleRequest
{
    /// The `kameloso.irc.defs.IRCEvent` that instigated the lookup.
    IRCEvent event;

    /// URL to look up.
    string url;
}


// YouTubeVideoInfo
/++
 +  Information about a YouTube video.
 +/
struct YouTubeVideoInfo
{
    /// The title of this YouTube video.
    string title;

    /// Name of the author of this YouTube video.
    string author;
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
    import std.typecons : No, Yes;

    immutable prefix = settings.prefix;

    if (event.content.beginsWith(prefix) && (event.content.length > prefix.length) &&
        (event.content[prefix.length] != ' '))
    {
        // Message started with a prefix followed by a run-on word
        // Ignore as it is probably a command.
        return;
    }

    string infotint;

    version(Colours)
    {
        import kameloso.common : settings;

        if (!settings.monochrome)
        {
            import kameloso.logger : KamelosoLogger;
            infotint = (cast(KamelosoLogger)logger).infotint;
        }
    }

    auto matches = findURLs(event.content);

    foreach (url; matches)
    {
        if (url.contains!(Yes.decode)('#'))
        {
            import kameloso.string : nom;
            // URL contains an octothorpe fragment identifier, like
            // https://www.google.com/index.html#this%20bit
            // Strip that.
            url = url.nom!(Yes.decode)('#');
        }

        logger.log("Caught URL: ", infotint, url);

        // Garbage-collect entries too old to use
        prune(plugin.cache);

        const cachedLookup = url in plugin.cache;

        import kameloso.constants : Timeout;
        import std.datetime.systime : Clock;

        if (cachedLookup && ((Clock.currTime.toUnixTime - cachedLookup.when) < Timeout.titleCache))
        {
            logger.log("Found title lookup in cache.");
            plugin.state.reportURL(*cachedLookup, event, settings.colouredOutgoing);
            continue;
        }

        // There were no cached entries for this URL

        TitleRequest titleReq;
        titleReq.event = event;
        titleReq.url = url;

        shared IRCPluginState sState = cast(shared)plugin.state;
        spawn(&worker, sState, plugin.cache, titleReq, settings.colouredOutgoing);
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


// worker
/++
 +  Looks up an URL and reports the title to the main thread, for printing in a channel.
 +
 +  Supposed to be run in its own, short-lived thread.
 +
 +  Params:
 +      sState = The `kameloso.plugins.common.IRCPluginState` of the current
 +          `WebtitlesPlugin`, `shared` so that it will persist between lookups
 +          (between multiple threads).
 +      cache = Reference to the cache of previous `TitleLookup`s.
 +      titleReq = Current title request.
 +      colouredOutgoing = Whether or not to include mIRC colours in outgoing messages.
 +/
void worker(shared IRCPluginState sState, ref shared TitleLookup[string] cache,
    TitleRequest titleReq, const bool colouredOutgoing)
{
    auto state = cast()sState;

    try
    {
        import kameloso.string : beginsWith, contains, nom;
        import std.typecons : No, Yes;

        if (titleReq.url.contains("youtube.com/watch?v=") || titleReq.url.contains("youtu.be/"))
        {
            // Do our own slicing instead of using regexes, because footprint.
            string slice = titleReq.url;

            slice.nom!(Yes.decode)("http");
            if (slice[0] == 's') slice = slice[1..$];
            slice = slice[3..$];  // ://

            if (slice.beginsWith("www.")) slice.nom!(Yes.decode)('.');

            if (slice.beginsWith("youtube.com/watch?v=") ||
                slice.beginsWith("youtu.be/"))
            {
                // Don't cache it for now
                auto info = getYouTubeInfo(titleReq.url);
                state.reportYouTube(info, titleReq.event, colouredOutgoing);
                return;
            }
            else
            {
                // Unsure what this is really. Drop down and treat like normal link
            }
        }
        else if (titleReq.url.contains("://i.imgur.com/"))
        {
            // imgur direct links naturally have no titles, but the normal pages do.
            // Rewrite and look those up instead.

            titleReq.url = rewriteDirectImgurURL(titleReq.url);
        }

        auto lookup = lookupTitle(titleReq.url);
        state.reportURL(lookup, titleReq.event, colouredOutgoing);
        cache[titleReq.url] = lookup;
    }
    catch (Exception e)
    {
        state.askToError("Webtitles worker exception: " ~ e.msg);
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
string rewriteDirectImgurURL(const string url)
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


// reportURL
/++
 +  Prints the result of a web title lookup in the channel or as a message to
 +  the user specified.
 +
 +  Params:
 +      state = The current `kameloso.plugins.common.IRCPluginState`.
 +      lookup = Finished title lookup.
 +      event = The `kameloso.irc.defs.IRCEvent` that instigated the lookup.
 +      colouredOutput = Whether or not to include mIRC colours in outgoing messages.
 +/
void reportURL(IRCPluginState state, const TitleLookup lookup, const IRCEvent event,
    const bool colouredOutput)
{
    string line;

    if (lookup.domain.length)
    {
        import std.format : format;

        if (colouredOutput)
        {
            line = "[%s] %s".format(lookup.domain.ircBold, lookup.title);
        }
        else
        {
            line = "[%s] %s".format(lookup.domain, lookup.title);
        }
    }
    else
    {
        line = lookup.title;
    }

    state.privmsg(event.channel, event.sender.nickname, line);
}


// reportYouTube
/++
 +  Prints the result of a YouTube lookup in the channel or as a message to
 +  the user specified.
 +
 +  Params:
 +      state = The current `kameloso.plugins.common.IRCPluginState`.
 +      info = `YouTubeVideoInfo` describing the lookup results.
 +      event = The `kameloso.irc.defs.IRCEvent` that instigated the lookup.
 +      colouredOutput = Whether or not to include mIRC colours in outgoing messages.
 +/
void reportYouTube(IRCPluginState state, const YouTubeVideoInfo info, const IRCEvent event,
    const bool colouredOutput)
{
    import std.format : format;

    string line;

    if (colouredOutput)
    {
        line = "[%s] %s (uploaded by %s)".format("youtube.com".ircBold, info.title, info.author.ircBold);
    }
    else
    {
        line = "[youtube.com] %s (uploaded by %s)".format(info.title, info.author);
    }

    state.privmsg(event.channel, event.sender.nickname, line);
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
TitleLookup lookupTitle(const string url)
{
    import kameloso.constants : BufferSize;
    import arsd.dom : Document;
    import requests : Request;
    import std.array : Appender;

    TitleLookup lookup;
    auto doc = new Document;
    Appender!(ubyte[]) sink;
    sink.reserve(BufferSize.titleLookup);

    Request req;
    req.useStreaming = true;
    req.keepAlive = false;
    req.bufferSize = BufferSize.titleLookup;

    auto res = req.get(url);

    if (res.code >= 400)
    {
        import std.conv : text;
        throw new Exception("Could not fetch URL; response code: " ~ res.code.text);
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
        throw new Exception("Could not find a title tag");
    }

    lookup.title = decodeTitle(doc.title);
    lookup.domain = res.finalURI.original_host;  // thanks to ikod

    import kameloso.string : beginsWith;
    if (lookup.domain.beginsWith("www."))
    {
        import kameloso.string : nom;
        lookup.domain.nom('.');
    }

    import std.datetime.systime : Clock;
    lookup.when = Clock.currTime.toUnixTime;
    return lookup;
}


/// getYouTubeInfo
/++
 +  Fetches the JSON description of a YouTube video link, allowing us to report
 +  it the page's title without having to actually fetch the video page.
 +
 +  Example:
 +  ---
 +  YouTubeVideoInfo info = getYouTubeInfo("https://www.youtube.com/watch?v=s-mOy8VUEBk");
 +  writeln(info.title);
 +  writeln(info.author);
 +  ---
 +
 +  Params:
 +      url = A YouTube video link string.
 +
 +  Returns:
 +      A `YouTubeVideoInfo` with members describing the looked-up video.
 +
 +  Throws: `Exception` if the YouTube ID was invalid and could not be queried.
 +/
YouTubeVideoInfo getYouTubeInfo(const string url)
{
    import requests : getContent;
    import std.json : parseJSON;

    YouTubeVideoInfo info;

    immutable youtubeURL = "https://www.youtube.com/oembed?url=" ~ url ~ "&format=json";
    const data = cast(char[])getContent(youtubeURL).data;

    if (data == "Not Found")
    {
        // Invalid video ID
        throw new Exception("Invalid YouTube video ID");
    }

    auto jsonFromYouTube = parseJSON(data);

    info.title = jsonFromYouTube["title"].str;
    info.author = jsonFromYouTube["author_name"].str;
    return info;
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


// prune
/++
 +  Garbage-collects old entries in a `TitleLookup[string]` lookup cache.
 +
 +  Params:
 +      cache = Cache of previous `TitleLookup`s, `shared` so that it can be
 +          reused in further lookup (other threads).
 +/
void prune(shared TitleLookup[string] cache)
{
    enum expireSeconds = 600;

    string[] garbage;

    foreach (key, entry; cache)
    {
        import std.datetime.systime : Clock;
        immutable now = Clock.currTime.toUnixTime;

        if ((now - entry.when) > expireSeconds)
        {
            garbage ~= key;
        }
    }

    foreach (key; garbage)
    {
        cache.remove(key);
    }
}


// start
/++
 +  Initialises the shared cache, else it won't retain changes.
 +
 +  Just assign it an entry and remove it.
 +/
void start(WebtitlesPlugin plugin)
{
    plugin.cache[string.init] = TitleLookup.init;
    plugin.cache.remove(string.init);
}


// onBusMessage
/++
 +  Receives a passed `kameloso.thread.BusMessage` with the "`reddit title`"
 +  header, and calls functions based on the payload message.
 +
 +  This is used to let other plugins trigger web URL lookups.
 +
 +  Params:
 +      plugin = The current `WebtitlesPlugin`.
 +      header = String header describing the passed content payload.
 +      content = Message content.
 +/
import kameloso.thread : Sendable;
void onBusMessage(WebtitlesPlugin plugin, const string header, shared Sendable content)
{
    import kameloso.thread : BusMessage;

    if (header == "reddit title")
    {
        auto message = cast(BusMessage!IRCEvent)content;
        assert(message, "Incorrectly cast message: " ~ typeof(message).stringof);
        return plugin.onMessage(message.payload);
    }
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
    shared TitleLookup[string] cache;

    /// All Webtitles options gathered.
    @Settings WebtitlesSettings webtitlesSettings;

    mixin IRCPluginImpl;
}
