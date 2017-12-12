module kameloso.plugins.webtitles;

version(Webtitles):

import kameloso.common;
import kameloso.constants;
import kameloso.irc;
import kameloso.plugins.common;

import std.experimental.logger;
import std.concurrency : Tid;
import std.regex : ctRegex;

import std.stdio;

private:


// WebtitlesSettings
/++
 +  All Webtitles plugin options gathered in a struct.
 +
 +/
struct WebtitlesSettings
{
    /// Flag to look up URLs on Reddit to see if they've been posted there
    bool redditLookups = false;
}

/// Regex pattern to match a URI, to see if one was pasted
enum stephenhay = `\bhttps?://[^\s/$.?#].[^\s]*`;

/// Regex engine to catch URIs
static urlRegex = ctRegex!stephenhay;

/// Regex pattern to match YouTube urls
enum youtubePattern = `https?://(?:www.)?youtube.com/watch`;

/// Regex engine to match YouTube urls for replacement
static youtubeRegex = ctRegex!youtubePattern;


// TitleLookup
/++
 +  A record of a URI lookup.
 +
 +  This is both used to aggregate information about the lookup, as well as to
 +  add hysteresis to lookups, so we don't look the same one up over and over
 +  if they were pasted over and over.
 +
 +  ------------
 +  struct TitleLookup
 +  {
 +      string title;
 +      string domain;
 +      size_t when;
 +  }
 +  ------------
 +/
struct TitleLookup
{
    import std.datetime : SysTime;

    string title;
    string domain;
    string reddit;

    /// The UNIX timestamp of when the title was looked up
    size_t when;
}


// TitleRequest
/++
 +  A record of an URI lookup request.
 +
 +  This is used to aggregate information about a lookup request, making it
 +  easier to pass it inbetween functions. It serves no greater purpose.
 +
 +  ------------
 +  struct TitleRequest
 +  {
 +      string url;
 +      string target;
 +      bool redditLookup;
 +  }
 +  ------------
 +/
struct TitleRequest
{
    string url;
    string target;
    bool redditLookup;
}


// onMessage
/++
 +  Parses a message to see if the message contains an URI.
 +
 +  It uses a simple regex and exhaustively tries to match every URI it detects.
 +/
@(IRCEvent.Type.CHAN)
@(PrivilegeLevel.friend)
void onMessage(WebtitlesPlugin plugin, const IRCEvent event)
{
    import core.time : seconds;
    import std.concurrency : spawn;
    import std.datetime.systime : Clock, SysTime;
    import std.regex : matchAll;

    auto matches = event.content.matchAll(urlRegex);

    foreach (urlHit; matches)
    {
        if (!urlHit.length) continue;

        immutable url = urlHit[0];
        immutable target = (event.channel.length) ? event.channel : event.sender.nickname;

        logger.info("Caught URL: ", url);

        // Garbage-collect entries too old to use
        plugin.cache.prune();

        const inCache = url in plugin.cache;

        if (inCache && ((Clock.currTime - SysTime.fromUnixTime(inCache.when))
            < Timeout.titleCache.seconds))
        {
            logger.log("Found title lookup in cache");
            plugin.state.mainThread.reportURL(*inCache, target);
            continue;
        }

        // There were no cached entries for this URL

        TitleRequest titleReq;
        titleReq.url = url;
        titleReq.target = target;
        titleReq.redditLookup = plugin.webtitlesSettings.redditLookups;

        shared IRCPluginState sState = cast(shared)plugin.state;
        spawn(&worker, sState, titleReq);
    }
}


// worker
/++
 +  Looks up an URL and reports the title to the main thread, for printing in a
 +  channel.
 +
 +  Supposed to be run in its own, shortlived thread.
 +/
void worker(shared IRCPluginState sState, const TitleRequest titleReq)
{
    IRCPluginState state = cast(IRCPluginState)sState;

    kameloso.common.settings = state.settings;
    initLogger(state.settings.monochrome, state.settings.brightTerminal);

    logger.info("Webtitles worker spawned.");

    try
    {
        import kameloso.string : beginsWith;

        // First look up and report the normal URL, *then* look up Reddit
        // This to make things be snappier, since Reddit can be very slow

        auto lookup = lookupTitle(titleReq);
        state.mainThread.reportURL(lookup, titleReq.target);

        if (titleReq.redditLookup &&
            !titleReq.url.beginsWith("https://www.reddit.com"))
        {
            lookupReddit(lookup, titleReq);
            state.mainThread.reportReddit(lookup, titleReq.target);
        }
    }
    catch (const Exception e)
    {
        logger.error("Webtitles worker exception: ", e.msg);
    }
}


// reportURL
/++
 +  Prints the result of a web title lookup in the channel or as a message to
 +  the user specified.
 +
 +  Optionally also reports the Reddit page that links to said URL.
 +/
void reportURL(Tid tid, const TitleLookup lookup, const string target)
{
    import std.concurrency : send;
    import std.format : format;

    if (lookup.domain.length)
    {
        tid.send(ThreadMessage.Sendline(),
            "PRIVMSG %s :[%s] %s"
            .format(target, lookup.domain, lookup.title));
    }
    else
    {
        tid.send(ThreadMessage.Sendline(),
            "PRIVMSG %s :%s".format(target, lookup.title));
    }
}


// reportReddit
/++
 +  Report found Reddit post to the channel or user specified.
 +/
void reportReddit(Tid tid, const TitleLookup lookup, const string target)
{
    import std.concurrency : send;
    import std.format : format;

    if (lookup.reddit.length)
    {
        tid.send(ThreadMessage.Sendline(),
            "PRIVMSG %s :Reddit: %s".format(target, lookup.reddit));
    }
}


// lookupTitle
/++
 +  Given an URL, tries to look up the web page title of it.
 +
 +  It doesn't work well on YouTube if they decided your IP is spamming; it will
 +  want you to solve a captcha to fetch the page. We hack our way around it
 +  by rewriting the URL to be one to ListenOnRepeat with the same video ID.
 +  Then we get our YouTube title.
 +/
TitleLookup lookupTitle(const TitleRequest titleReq)
{
    import kameloso.string : beginsWith;
    import arsd.dom : Document;
    import requests : Request;
    import std.array : Appender;
    import std.datetime : Clock;
    import std.string : indexOf;

    TitleLookup lookup;
    auto doc = new Document;
    Appender!(ubyte[]) sink;
    sink.reserve(BufferSize.titleLookup);

    Request req;
    req.useStreaming = true;
    req.keepAlive = false;
    req.bufferSize = BufferSize.titleLookup;

    auto res = req.get(titleReq.url);

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

    if ((lookup.title == "YouTube") &&
        (titleReq.url.indexOf("youtube.com/watch?") != -1))
    {
        fixYoutubeTitles(lookup, titleReq);
    }

    lookup.domain = res.finalURI.host; // original_host;  // thanks to ikod

    if (lookup.domain.beginsWith("www"))
    {
        import kameloso.string : nom;
        lookup.domain.nom('.');
    }

    lookup.when = Clock.currTime.toUnixTime;
    return lookup;
}


// lookupReddit
/++
 +  Look up an URL on Reddit, see if it has been posted there. If so, get the
 +  link and modify the passed ref `TitleLookup` to contain it.
 +/
void lookupReddit(ref TitleLookup lookup, const TitleRequest titleReq)
{
    import kameloso.string : beginsWith;
    import requests : Request;

    Request redditReq;
    redditReq.useStreaming = true;  // we only want as little as possible
    redditReq.keepAlive = false;
    redditReq.bufferSize = BufferSize.titleLookup;

    logger.log("Checking Reddit ...");

    auto redditRes = redditReq.get("https://www.reddit.com/" ~ titleReq.url);

    with (redditRes.finalURI)
    {
        if (uri.beginsWith("https://www.reddit.com/login") ||
            uri.beginsWith("https://www.reddit.com/submit") ||
            uri.beginsWith("https://www.reddit.com/http"))
        {
            logger.log("No corresponding Reddit post.");
        }
        else
        {
            // Has been posted to Reddit
            lookup.reddit = uri;
        }
    }
}


// fixYoutubeTitles
/++
 +  If a YouTube video link resolves its title to just "YouTube", rewrite the
 +  URL to ListenOnRepeat with the same video ID and fetch its title there.
 +
 +  Params:
 +      ref lookup = the failing TitleLookup that we want to try hacking around
 +      url = the original URL string
 +/
void fixYoutubeTitles(ref TitleLookup lookup, TitleRequest titleReq)
{
    import std.regex : replaceFirst;
    import std.string : indexOf;

    logger.log("Bland YouTube title ...");

    immutable onRepeatURL = titleReq.url.replaceFirst(youtubeRegex,
        "https://www.listenonrepeat.com/watch/");

    logger.log("ListenOnRepeat URL: ", onRepeatURL);
    titleReq.url = onRepeatURL;

    auto onRepeatLookup = lookupTitle(titleReq);

    logger.log("ListenOnRepeat title: ", onRepeatLookup.title);

    if (onRepeatLookup.title.indexOf(" - ListenOnRepeat") == -1)
    {
        logger.error("Failed to ListenOnRepeatify YouTube title");
        return;
    }

    // Truncate away " - ListenOnRepeat"
    onRepeatLookup.title = onRepeatLookup.title[0..$-17];
    onRepeatLookup.domain = "youtube.com";
    lookup = onRepeatLookup;
}


// parseTitle
/++
 +  Remove unwanted characters from a title, and decode HTML entities in it
 +  (like &mdash; and &nbsp;).
 +/
string parseTitle(const string title)
{
    import arsd.dom : htmlEntitiesDecode;
    import std.regex : ctRegex, replaceAll;
    import std.string : strip;

    enum rPattern = "\r";
    enum nPattern = "\n";
    static rEngine = ctRegex!rPattern;
    static nEngine = ctRegex!nPattern;

    // replaceAll takes about 4.48x as long as removechars does
    // but that's micro-optimising; we're still in the µsec range

    return title
        .replaceAll(rEngine, string.init)
        .replaceAll(nEngine, " ")
        .strip
        .htmlEntitiesDecode();
}

///
unittest
{
    immutable t1 = "&quot;Hello&nbsp;world!&quot;";
    immutable t1p = parseTitle(t1);
    assert((t1p == "\"Hello\u00A0world!\""), t1p);  // not a normal space

    immutable t2 = "&lt;/title&gt;";
    immutable t2p = parseTitle(t2);
    assert((t2p == "</title>"), t2p);

    immutable t3 = "&mdash;&micro;&acute;&yen;&euro;";
    immutable t3p = parseTitle(t3);
    assert((t3p == "—µ´¥€"), t3p);  // not a normal dash

    immutable t4 = "&quot;Se&ntilde;or &THORN;&quot; &copy;2017";
    immutable t4p = parseTitle(t4);
    assert((t4p == `"Señor Þ" ©2017`), t4p);
}


// prune
/++
 +  Garbage-collects old entries in a `TitleLookup[string]` lookup cache.
 +/
void prune(TitleLookup[string] cache)
{
    enum expireSeconds = 600;

    string[] garbage;

    foreach (key, entry; cache)
    {
        import std.datetime : Clock;
        import core.time : minutes;

        const now = Clock.currTime;

        if ((now.toUnixTime - entry.when) > expireSeconds)
        {
            garbage ~= key;
        }
    }

    foreach (key; garbage)
    {
        cache.remove(key);
    }
}


mixin BasicEventHandlers;

public:


// Webtitles
/++
 +  The Webtitles plugin catches HTTP URI links in an IRC channel, connects to
 +  its server and and streams the web page itself, looking for the web page's
 +  title. This is then reported to the originating channel or personal query.
 +/
final class WebtitlesPlugin : IRCPlugin
{
    /// All Webtitles plugin options gathered
    @Settings WebtitlesSettings webtitlesSettings;

    /// Thread ID of the working thread that does the lookups
    Tid workerThread;

    /// Cache of recently looked-up web titles
    TitleLookup[string] cache;

    mixin IRCPluginImpl;
}
