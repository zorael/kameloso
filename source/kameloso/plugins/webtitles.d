module kameloso.plugins.webtitles;

version(Webtitles):

pragma(msg, "Version: Webtitles");

import kameloso.common;
import kameloso.constants;
import kameloso.irc;
import kameloso.plugins.common;

import std.concurrency : send, Tid;
import std.experimental.logger;
import std.regex : ctRegex;
import std.stdio;

private:

/// All plugin state variables gathered in a struct
IRCPluginState state;

/// Thread ID of the working thread that does the lookups
Tid workerThread;

/// Regex pattern to grep a web page title from the HTTP body
enum titlePattern = `<title>([^<]+)</title>`;

/// Regex engine to catch web titles
static titleRegex = ctRegex!(titlePattern, "i");

/// Regex pattern to match a URI, to see if one was pasted
enum stephenhay = `\bhttps?://[^\s/$.?#].[^\s]*`;

/// Regex engine to catch URIs
static urlRegex = ctRegex!stephenhay;

/// Regex engine to match only the domain in a URI
enum domainPattern = `(?:https?://)(?:www\.)?([^/ ]+)/?.*`;

/// Regex engine to catch domains
static domainRegex = ctRegex!domainPattern;

/// Regex pattern to match YouTube urls
enum youtubePattern = `https?://(?:www.)?youtube.com/watch`;

/// Regex engine to match YouTube urls for replacement
static youtubeRegex = ctRegex!youtubePattern;

/// Thread-local logger
Logger tlsLogger;


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
void onMessage(const IRCEvent event)
{
    import std.regex : matchAll;

    auto matches = event.content.matchAll(urlRegex);

    foreach (urlHit; matches)
    {
        if (!urlHit.length) continue;

        immutable url = urlHit[0];
        immutable target = (event.channel.length) ? event.channel : event.sender.nickname;

        logger.info("Caught URL: ", url);
        workerThread.send(url, target);
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
TitleLookup lookupTitle(const string url)
{
    import arsd.dom : Document;
    import requests;
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
    if (res.code >= 400) return lookup;

    auto stream = res.receiveAsRange();

    foreach (const part; stream)
    {
        sink.put(part);
        doc.parseGarbage(cast(string)sink.data);
        if (doc.title.length) break;
    }

    if (!doc.title.length) return lookup;

    lookup.title = doc.title;

    if (lookup.title == "YouTube" &&
        (url.indexOf("youtube.com/watch?") != -1))
    {
        lookup.fixYoutubeTitles(url);
    }

    lookup.domain = getDomainFromURL(url);
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
void fixYoutubeTitles(ref TitleLookup lookup, const string url)
{
    import std.regex : replaceFirst;
    import std.string : indexOf;

    tlsLogger.log("Bland YouTube title...");

    immutable onRepeatURL = url.replaceFirst(youtubeRegex,
        "https://www.listenonrepeat.com/watch/");

    tlsLogger.log("ListenOnRepeat URL: ", onRepeatURL);

    TitleLookup onRepeatLookup = lookupTitle(onRepeatURL);

    tlsLogger.log("ListenOnRepeat title: ", onRepeatLookup.title);

    if (onRepeatLookup.title.indexOf(" - ListenOnRepeat") == -1)
    {
        tlsLogger.warning("Failed to ListenOnRepeatify YouTube title");
        return;
    }

    // Truncate away " - ListenOnRepeat"
    onRepeatLookup.title = onRepeatLookup.title[0..$-17];
    onRepeatLookup.domain = "youtube.com";
    lookup = onRepeatLookup;
}


// getDomainFromURL
/++
 +  Fetches the slice of the domain name from a URL.
 +
 +  Params:
 +      url = an URL string.
 +
 +  Returns:
 +      the domain part of the URL string, or an empty string if no matches.
 +/
string getDomainFromURL(const string url) @safe
{
    import std.regex : matchFirst;

    auto domainHits = url.matchFirst(domainRegex);
    return domainHits.length ? domainHits[1] : string.init;
}

@safe unittest
{
    immutable d1 = getDomainFromURL("http://www.youtube.com/watch?asoidjsd&asd=kokofruit");
    assert((d1 == "youtube.com"), d1);

    immutable d2 = getDomainFromURL("https://www.com");
    assert((d2 == "com"), d2);

    immutable d3 = getDomainFromURL("ftp://ftp.sunet.se");
    assert(!d3.length, d3);

    immutable d4 = getDomainFromURL("http://");
    assert(!d4.length, d4);

    immutable d5 = getDomainFromURL("invalid line");
    assert(!d5.length, d5);

    immutable d6 = getDomainFromURL("");
    assert(!d6.length, d6);
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
void titleworker(shared Tid sMainThread)
{
    import core.time : seconds;
    import std.concurrency : OwnerTerminated, receive;
    import std.datetime : Clock, SysTime;
    import std.variant : Variant;

    Tid mainThread = cast(Tid)sMainThread;
    tlsLogger = new KamelosoLogger(LogLevel.all);

    /// Cache buffer of recently looked-up URIs
    TitleLookup[string] cache;
    bool halt;

    while (!halt)
    {
        receive(
            (string url, string target)
            {
                import std.format : format;

                TitleLookup lookup;
                const inCache = url in cache;

                if (inCache && ((Clock.currTime - SysTime.fromUnixTime(inCache.when))
                    < Timeout.titleCache.seconds))
                {
                    lookup = *inCache;
                }
                else
                {
                    try lookup = lookupTitle(url);
                    catch (const Exception e)
                    {
                        tlsLogger.error("Could not look up title: ", e.msg);
                    }
                }

                if (lookup == TitleLookup.init) return;

                cache[url] = lookup;

                if (lookup.domain.length)
                {
                    mainThread.send(ThreadMessage.Sendline(),
                        "PRIVMSG %s :[%s] %s".format(target,
                            lookup.domain, lookup.title));
                }
                else
                {
                    mainThread.send(ThreadMessage.Sendline(),
                        "PRIVMSG %s :%s".format(target, lookup.title));
                }
            },
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
                tlsLogger.error("titleworker received Variant: ", v);
            }
        );
    }
}


// initialise
/++
 +  Initialises the Webtitles plugin. Spawns the titleworker thread.
 +/
void initialise()
{
    import std.concurrency : spawn;

    const stateCopy = state;
    workerThread = spawn(&titleworker, cast(shared)(stateCopy.mainThread));
}


// teardown
/++
 +  Deinitialises the Webtitles plugin. Shuts down the titleworker thread.
 +/
void teardown()
{
    workerThread.send(ThreadMessage.Teardown());
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
    mixin IRCPluginBasics;
}
