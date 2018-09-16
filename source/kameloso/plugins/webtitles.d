/++
 +  The Webtitles plugin catches URLs pasted in a channel, follows them and
 +  reports beck the title of the web page that was linked to.
 +
 +  It has no bot commands; eveything is done by automatically scanning channel
 +  and pivate query messages fo things that look like links.
 +
 +  It reqiures version `Web` for obvious reasons.
 +
 +  It is optional.
 +/
module kameloso.plugins.webtitles;

version(Web):

import kameloso.common : ThreadMessage;
import kameloso.messaging;
import kameloso.plugins.common;
import kameloso.ircdefs;

import std.concurrency;

private:

// WebtitlesSettings
/++
 +  All Webtitles settings, gathered in a struct.
 +/
struct WebtitlesSettings
{
    /// Toggles whether or not the plugin should react to events at all.
    bool enabled = true;
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
    import std.datetime.systime : SysTime;

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
 +  easier to pass it inbetween functions. It serves no greater purpose.
 +/
struct TitleRequest
{
    /// The `kameloso.ircdefs.IRCEvent` that instigated the lookup.
    IRCEvent event;

    /// URL to look up.
    string url;
}


// onMessage
/++
 +  Parses a message to see if the message contains an URL.
 +
 +  It uses a simple regex and exhaustively tries to match every URL it detects.
 +/
@(Terminating)
@(IRCEvent.Type.CHAN)
@(PrivilegeLevel.whitelist)
@(ChannelPolicy.home)
void onMessage(WebtitlesPlugin plugin, const IRCEvent event)
{
    if (!plugin.webtitlesSettings.enabled) return;

    import kameloso.common : logger;
    import kameloso.constants : Timeout;
    import kameloso.string : beginsWith, contains, nom;
    import std.datetime.systime : Clock, SysTime;
    import std.regex : ctRegex, matchAll;
    import std.typecons : No, Yes;

    // Early abort so we don't use the regex as much.
    if (!event.content.contains!(Yes.decode)("http")) return;

    /// Regex pattern to match a URL, to see if one was pasted.
    enum stephenhay = `\bhttps?://[^\s/$.?#].[^\s]*`;

    /// Regex engine to catch URLs.
    static urlRegex = ctRegex!stephenhay;

    immutable prefix = plugin.state.settings.prefix;
    if (event.content.beginsWith(prefix) && (event.content.length > prefix.length) &&
        (event.content[prefix.length] != ' '))
    {
        // Message started with a prefix followed by a run-on word
        // Ignore as it is probably a command.
        return;
    }

    auto matches = event.content.matchAll(urlRegex);

    foreach (urlHit; matches)
    {
        if (!urlHit.length) continue;

        string url = urlHit[0];  // needs mutable

        if (url.contains!(Yes.decode)('#'))
        {
            // URL contains an octorhorpe fragment identifier, like
            // https://www.google.com/index.html#this%20bit
            // Strip that.
            url = url.nom!(Yes.decode)('#');
        }

        logger.log("Caught URL: ", url);

        // Garbage-collect entries too old to use
        plugin.cache.prune();

        const cachedLookup = url in plugin.cache;

        if (cachedLookup && ((Clock.currTime.toUnixTime - cachedLookup.when) < Timeout.titleCache))
        {
            logger.log("Found title lookup in cache");
            plugin.state.reportURL(*cachedLookup, event);
            continue;
        }

        // There were no cached entries for this URL

        TitleRequest titleReq;
        titleReq.event = event;
        titleReq.url = url;

        shared IRCPluginState sState = cast(shared)plugin.state;
        spawn(&worker, sState, plugin.cache, titleReq);
    }
}


// worker
/++
 +  Looks up an URL and reports the title to the main thread, for printing in a
 +  channel.
 +
 +  Supposed to be run in its own, shortlived thread.
 +
 +  Params:
 +      sState = The `kameloso.plugins.common.IRCPluginState` of the current
 +          `WebtitlesPlugin`, `shared` so that it will persist between lookups
 +          (between multiple threads).
 +      cache = Reference to the cache of previous `TitleLookup`s.
 +      titleReq = Current title request.
 +/
void worker(shared IRCPluginState sState, ref shared TitleLookup[string] cache, TitleRequest titleReq)
{
    auto state = cast(IRCPluginState)sState;

    try
    {
        import kameloso.string : beginsWith, nom;
        import std.typecons : No, Yes;

        // imgur direct links naturally have no titles, but the normal pages do
        // Rewrite and look those up instead.

        immutable originalURL = titleReq.url;

        if (titleReq.url.beginsWith("https://i.imgur.com/"))
        {
            immutable path = titleReq.url[20..$].nom!(Yes.decode)('.');
            titleReq.url = "https://imgur.com/" ~ path;
        }
        else if (titleReq.url.beginsWith("http://i.imgur.com/"))
        {
            immutable path = titleReq.url[19..$].nom!(Yes.decode)('.');
            titleReq.url = "https://imgur.com/" ~ path;
        }

        if (titleReq.url != originalURL)
        {
            state.askToLog("direct imgur URL; rewritten");
        }

        auto lookup = state.lookupTitle(titleReq.url);
        state.reportURL(lookup, titleReq.event);
        cache[originalURL] = lookup;
    }
    catch (const Exception e)
    {
        state.askToError("Webtitles worker exception: " ~ e.msg);
    }
}


// reportURL
/++
 +  Prints the result of a web title lookup in the channel or as a message to
 +  the user specified.
 +
 +  Params:
 +      tid = Thread ID of the main thread, to report the lookup to.
 +      lookup = Finished title lookup.
 +      event = The `kameloso.ircdefs.IRCEvent` that instigated the lookup.
 +/
void reportURL(IRCPluginState state, const TitleLookup lookup, const IRCEvent event)
{
    string line;

    if (lookup.domain.length)
    {
        import std.format : format;
        line = "[%s] %s".format(lookup.domain, lookup.title);
    }
    else
    {
        line = lookup.title;
    }

    state.privmsg(event.channel, event.sender.nickname, line);
}


// lookupTitle
/++
 +  Given an URL, tries to look up the web page title of it.
 +
 +  It doesn't work well on YouTube if they decided your IP is spamming; it will
 +  want you to solve a captcha to fetch the page. We hack our way around it
 +  by rewriting the URL to be one to ListenOnRepeat with the same video ID.
 +  Then we get our YouTube title.
 +
 +  Params:
 +      titleReq = Current title request.
 +
 +  Returns:
 +      A finished `TitleLookup`.
 +/
TitleLookup lookupTitle(IRCPluginState state, const string url)
{
    import kameloso.constants : BufferSize;
    import kameloso.string : beginsWith, contains;
    import arsd.dom : Document;
    import requests : Request;
    import std.array : Appender;
    import std.datetime.systime : Clock;

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
        doc.parseGarbage(cast(string)sink.data);
        if (doc.title.length) break;
    }

    if (!doc.title.length)
    {
        throw new Exception("Could not find a title tag");
    }

    lookup.title = doc.title;

    if ((lookup.title == "YouTube") && url.contains("youtube.com/watch?"))
    {
        state.fixYoutubeTitles(lookup, url);
    }
    else
    {
        lookup.title = decodeTitle(lookup.title);
    }

    lookup.domain = res.finalURI.original_host;  // thanks to ikod

    if (lookup.domain.beginsWith("www"))
    {
        import kameloso.string : nom;
        lookup.domain.nom('.');
    }

    lookup.when = Clock.currTime.toUnixTime;
    return lookup;
}


// fixYoutubeTitles
/++
 +  If a YouTube video link resolves its title to just "YouTube", rewrites the
 +  URL to ListenOnRepeat with the same video ID and fetch its title there.
 +
 +  Params:
 +      lookup = Reference to the failing `TitleLookup`, that we want to try
 +          hacking around.
 +      titleReq = Original title request.
 +/
void fixYoutubeTitles(IRCPluginState state, ref TitleLookup lookup, const string url)
{
    import kameloso.string : contains;
    import std.regex : regex, replaceFirst;

    /// Regex pattern to match YouTube URLs.
    enum youtubePattern = `https?://(?:www.)?youtube.com/watch`;

    state.askToLog("Bland YouTube title ...");

    immutable onRepeatURL = url.replaceFirst(youtubePattern.regex, "https://www.listenonrepeat.com/watch/");
    state.askToLog("ListenOnRepeat URL: " ~ onRepeatURL);
    auto onRepeatLookup = state.lookupTitle(onRepeatURL);
    state.askToLog("ListenOnRepeat title: " ~ onRepeatLookup.title);

    if (!onRepeatLookup.title.contains(" - ListenOnRepeat"))
    {
        state.askToWarn("Failed to ListOnRepeatify YouTube title");
        return;
    }

    // Truncate away " - ListenOnRepeat"
    onRepeatLookup.title = onRepeatLookup.title[0..$-17];
    onRepeatLookup.domain = "youtube.com";
    lookup = onRepeatLookup;
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
 +  Receives and handles a bus message from another plugin.
 +
 +  So far used to let other plugins trigger lookups of web URLs.
 +/
void onBusMessage(WebtitlesPlugin plugin, const string header,
    const string content, const IRCEvent payload)
{
    logger.logf(`Webtitles received bus message: "%s : %s"`, header, content);

    if (header == "webtitle")
    {
        return plugin.onMessage(payload);
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
    /// Cache of recently looked-up web titles.
    shared TitleLookup[string] cache;

    /// All Webtitles options gathered.
    @Settings WebtitlesSettings webtitlesSettings;

    mixin IRCPluginImpl;
}
