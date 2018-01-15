/++
 +  The Reddit plugin allows you to query Reddit with a web URL, and if that
 +  URL has been posted there it will print the post link to the channel.
 +
 +  It has one command:
 +      `reddit`
 +
 +  It requires version `Web` as HTTP requests will have to be made.
 +
 +  It is very optional.
 +/
module kameloso.plugins.reddit;

version(Web):

import kameloso.plugins.common;
import kameloso.ircdefs;
import kameloso.common : logger;

import std.concurrency : Tid;

private:


// RedditLookup
/++
 +  A record of a Reddit post lookup.
 +
 +  Merely pairs an URL with a timestamp.
 +
 +  ------------
 +  struct RedditLookup
 +  {
 +      string url;
 +      long when;
 +  }
 +  ------------
 +/
struct RedditLookup
{
    import std.datetime.systime : SysTime;

    string url;

    /// The UNIX timestamp of when the URL was looked up
    long when;
}


// onMessage
/++
 +  On a message prefixed with "reddit", look the subsequent URL up and see if
 +  it has been posted on Reddit. If it has, report the Reddit post URL to the
 +  channel or to the private message query.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.whitelist)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.direct, "reddit")
@BotCommand(NickPolicy.required, "reddit")
@Description("Look up an URL and see if it has been posted on Reddit. Echo that link if so.")
void onMessage(RedditPlugin plugin, const IRCEvent event)
{
    import kameloso.constants : Timeout;
    import kameloso.string : has;
    import core.time : seconds;
    import std.concurrency : spawn;
    import std.datetime.systime : Clock, SysTime;
    import std.string : strip;

    immutable url = event.content.strip();

    if (!url.length || url.has(' '))
    {
        logger.error("Cannot look up Reddit post; invalid URL");
        return;
    }

    immutable target = event.channel.length ? event.channel : event.sender.nickname;

    // Garbage-collect entries too old to use
    plugin.cache.prune();

    const cachedLookup = url in plugin.cache;

    if (cachedLookup && ((Clock.currTime.toUnixTime - cachedLookup.when)
        < Timeout.titleCache))
    {
        logger.log("Found Reddit lookup in cache");
        plugin.state.mainThread.reportReddit(cachedLookup.url, event);
        return;
    }

    // There were no cached entries for this URL

    shared IRCPluginState sState = cast(shared)plugin.state;
    spawn(&worker, sState, plugin.cache, url, event);
}


// worker
/++
 +  Looks up an URL on Reddit and reports the corresponding Reddit post to the
 +  channel or in the private message query.
 +
 +  Run in it own thread, so arguments have to be value types or shared.
 +/
void worker(shared IRCPluginState sState, shared RedditLookup[string] cache,
    const string url, const IRCEvent event)
{
    import kameloso.common;
    import std.datetime.systime : Clock;

    IRCPluginState state = cast(IRCPluginState)sState;

    kameloso.common.settings = state.settings;
    initLogger(state.settings.monochrome, state.settings.brightTerminal);

    logger.info("Reddit worker spawned.");

    try
    {
        immutable redditURL = lookupReddit(url);
        state.mainThread.reportReddit(redditURL, event);

        RedditLookup lookup;
        lookup.url = redditURL;
        lookup.when = Clock.currTime.toUnixTime;
        cache[url] = lookup;
    }
    catch (const Exception e)
    {
        logger.error("Reddit worker exception: ", e.msg);
    }
}


// lookupReddit
/++
 +  Given an URL, looks it up on Reddit to see if it has been posted there.
 +/
string lookupReddit(const string url)
{
    import kameloso.constants : BufferSize;
    import requests : Request;

    Request req;
    req.useStreaming = true;  // we only want as little as possible
    req.keepAlive = false;
    req.bufferSize = BufferSize.titleLookup;

    logger.log("Checking Reddit ...");

    auto res = req.get("https://www.reddit.com/" ~ url);

    with (res.finalURI)
    {
        import kameloso.string : beginsWith;

        if (uri.beginsWith("https://www.reddit.com/login") ||
            uri.beginsWith("https://www.reddit.com/submit") ||
            uri.beginsWith("https://www.reddit.com/http"))
        {
            logger.log("No corresponding Reddit post.");
            return string.init;
        }
        else
        {
            // Has been posted to Reddit
            return res.finalURI.uri;
        }
    }
}


// reportReddit
/++
 +  Reports the result of a Reddit lookup to a channel or in a private message.
 +/
void reportReddit(Tid tid, const string reddit, const IRCEvent event)
{
    import kameloso.common : ThreadMessage;
    import kameloso.messaging : privmsg;
    import std.concurrency : send;
    import std.format : format;

    if (reddit.length)
    {
        tid.privmsg(event.channel, event.sender.nickname,
            "Reddit post: " ~ reddit);
    }
    else
    {
        tid.privmsg(event.channel, event.sender.nickname,
            "No corresponding Reddit post found.");
    }

}


// prune
/++
 +  Garbage-collects old entries in a `RedditLookup[string]` lookup cache.
 +/
void prune(shared RedditLookup[string] cache)
{
    enum expireSeconds = 600;

    string[] garbage;

    foreach (key, entry; cache)
    {
        import std.datetime : Clock;
        import core.time : minutes;

        const now = Clock.currTime.toUnixTime;

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
 +  Initialise the shared cache, else it won't retain changes.
 +
 +  Just assign it an entry and remove it.
 +/
void start(RedditPlugin plugin)
{
    plugin.cache[string.init] = RedditLookup.init;
    plugin.cache.remove(string.init);
}


public:

mixin UserAwareness;


// RedditPlugin
/++
 +  The Reddit plugin takes an URL and looks it up on Reddit, to see if it has
 +  been posted there.
 +
 +  It does this by simply appending the URL to https://www.reddit.com/, which
 +  makes Reddit either rediret you to a login page, to a submit-this-link page,
 +  or to a/the post that links to that URL.
 +/
final class RedditPlugin : IRCPlugin
{
    /// Cache of recently looked-up URLs
    shared RedditLookup[string] cache;

    mixin IRCPluginImpl;
}
