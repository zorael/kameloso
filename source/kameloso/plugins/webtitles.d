module kameloso.plugins.webtitles;

version(Webtitles):

import kameloso.common;
import kameloso.constants;
import kameloso.irc;
import kameloso.plugins.common;

import std.concurrency : send, Tid;
import std.experimental.logger;
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
    bool redditLookups = true;
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
    import std.regex : matchAll;

    auto matches = event.content.matchAll(urlRegex);

    foreach (urlHit; matches)
    {
        if (!urlHit.length) continue;

        immutable url = urlHit[0];
        immutable target = (event.channel.length) ? event.channel : event.sender.nickname;

        logger.info("Caught URL: ", url);
        plugin.workerThread.send(url, target);
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
TitleLookup lookupTitle(const string url, bool redditLookups)
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

    auto res = req.get(url);

    if (res.code >= 400)
    {
        logger.error("Response code: ", res.code);
        return lookup;
    }

    auto stream = res.receiveAsRange();

    foreach (const part; stream)
    {
        sink.put(part);
        doc.parseGarbage(cast(string)sink.data);
        if (doc.title.length) break;
    }

    if (!doc.title.length) return lookup;  // throw Exception, really

    lookup.title = doc.title;

    if ((lookup.title == "YouTube") &&
        (url.indexOf("youtube.com/watch?") != -1))
    {
        lookup.fixYoutubeTitles(url, redditLookups);
    }

    lookup.domain = res.finalURI.host;

    if (lookup.domain.beginsWith("www"))
    {
        import kameloso.string : nom;
        lookup.domain.nom('.');
    }

    if (redditLookups && !url.beginsWith("https://www.reddit.com"))
    {
        Request redditReq;
        redditReq.useStreaming = true;  // we only want as little as possible
        redditReq.keepAlive = false;
        redditReq.bufferSize = BufferSize.titleLookup;

        logger.log("Checking Reddit ...");

        auto redditRes = redditReq.get("https://www.reddit.com/" ~ url);

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

    lookup.when = Clock.currTime.toUnixTime;
    return lookup;
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
void fixYoutubeTitles(ref TitleLookup lookup, const string url, bool redditLookups)
{
    import std.regex : replaceFirst;
    import std.string : indexOf;

    logger.log("Bland YouTube title...");

    immutable onRepeatURL = url.replaceFirst(youtubeRegex,
        "https://www.listenonrepeat.com/watch/");

    logger.log("ListenOnRepeat URL: ", onRepeatURL);

    TitleLookup onRepeatLookup = lookupTitle(onRepeatURL, redditLookups);

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


// titleworker
/++
 +  Worker thread of the Webtitles plugin.
 +
 +  It sits and waits for concurrency messages of URLs to look up.
 +
 +  Params:
 +      sMainThread = a shared copy of the mainThread Tid, to which every
 +                    outgoing messages will be sent.
 +/
//void titleworker(shared Tid sMainThread, bool redditLookups)
void titleworker(shared IRCPluginState sState, bool redditLookups)
{
    import core.time : seconds;
    import std.concurrency : OwnerTerminated, receive;
    import std.datetime : Clock, SysTime;
    import std.variant : Variant;

    IRCPluginState state = cast(IRCPluginState)sState;

    kameloso.common.settings = state.settings;
    initLogger(state.settings.monochrome, state.settings.brightTerminal);

    /// Cache buffer of recently looked-up URIs
    TitleLookup[string] cache;
    bool halt;

    void catchURL(string url, string target)
    {
        import std.format : format;

        TitleLookup lookup;
        const inCache = url in cache;

        if (inCache && ((Clock.currTime - SysTime.fromUnixTime(inCache.when))
            < Timeout.titleCache.seconds))
        {
            logger.log("Found title lookup in cache");
            lookup = *inCache;
        }
        else
        {
            try lookup = lookupTitle(url, redditLookups);
            catch (const Exception e)
            {
                import kameloso.string : beginsWith;

                if (url.beginsWith("https"))
                {
                    logger.warningf("Could not look up URL '%s': %s", url, e.msg);
                    logger.log("Rewriting https to http and retrying...");
                    return catchURL(("http" ~ url[5..$]), target);
                }
                else
                {
                    logger.errorf("Could not look up URL '%s': %s", url, e.msg);
                }
            }
        }

        if (lookup == TitleLookup.init)
        {
            logger.error("Failed.");
            return;
        }

        // parseTitle to fix html entities and linebreaks
        lookup.title = parseTitle(lookup.title);
        cache[url] = lookup;

        if (lookup.domain.length)
        {
            state.mainThread.send(ThreadMessage.Sendline(),
                "PRIVMSG %s :[%s] %s"
                    .format(target, lookup.domain, lookup.title));
        }
        else
        {
            state.mainThread.send(ThreadMessage.Sendline(),
                "PRIVMSG %s :%s".format(target, lookup.title));
        }

        if (redditLookups && lookup.reddit.length)
        {
            state.mainThread.send(ThreadMessage.Sendline(),
                "PRIVMSG %s :Reddit: %s".format(target, lookup.reddit));
        }
    }

    while (!halt)
    {
        receive(
            &catchURL,
            (ThreadMessage.Teardown)
            {
                halt = true;
            },
            (OwnerTerminated o)
            {
                halt = true;
            },
            (Variant v)
            {
                logger.warning("titleworker received Variant: ", v);
            }
        );
    }
}


// onEndOfMotd
/++
 +  Initialises the Webtitles plugin. Spawns the titleworker thread.
 +/
@(IRCEvent.Type.RPL_ENDOFMOTD)
void onEndOfMotd(WebtitlesPlugin plugin, const IRCEvent event)
{
    import std.concurrency : spawn;

    plugin.workerThread = spawn(&titleworker, cast(shared)(plugin.state),
        plugin.webtitlesSettings.redditLookups);
}


// teardown
/++
 +  Deinitialises the Webtitles plugin. Shuts down the titleworker thread.
 +/
void teardown(IRCPlugin basePlugin)
{
    auto plugin = cast(WebtitlesPlugin)basePlugin;
    plugin.workerThread.send(ThreadMessage.Teardown());
}


mixin BasicEventHandlers;

public:


// Webtitles
/++
 +  The Webtitles plugin catches HTTP URI links in an IRC channel, connects to
 +  its server and and streams the web page itself, looking for the web page's
 +  title (in its <title> tags). This is then reported to the originating
 +  channel.
 +/
final class WebtitlesPlugin : IRCPlugin
{
    /// All Webtitles plugin options gathered
    @Settings WebtitlesSettings webtitlesSettings;

    /// Thread ID of the working thread that does the lookups
    Tid workerThread;

    mixin IRCPluginImpl;
}
