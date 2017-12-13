module kameloso.plugins.reddit;

version(Webtitles):

import kameloso.plugins.common;
import kameloso.ircdefs;

private:

struct RedditLookup
{
    import std.datetime.systime : SysTime;

    string reddit;

    /// The UNI timestamp of when the URL was looked up
    size_t when;
}


struct RedditRequest
{
    string url;
    string target;
}


@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@Prefix(NickPolicy.direct, "reddit")
@Prefix(NickPolicy.required, "reddit")
void onMessage(RedditPlugin plugin, const IRCEvent event)
{
    immutable url = event.content;

    if (url.indexOf(' '))
    {
        logger.info("Invalid URL");
        return;
    }

    const inCache = url in plugin.cache;

    if (inCache && ((Clock.currTime - SysTime.fromUnixTime(inCache.when))
        < Timeout.titleCache.seconds))
    {
        logger.log("Found Reddit lookup in cache");
        plugin.state.mainThread.reportURL(*inCache, target);
        return;
    }

    RedditRequest redditReq;
    redditReq.url = url;
    redditReq.target = event.channel.length ? event.channel : event.sender.nickname;

    shared IRCPluginState sState = cast(shared)plugin.state;
    spawn(&worker, sState, redditReq);
}


void worker(shared IRCPluginState sState, const RedditRequest redditReq)
{
    import kameloso.common;

    IRCPluginState state = cast(IRCPluginState)sState;

    kameloso.common.settings = state.settings;
    initLogger(state.settings.monochrome, state.settings.brightTerminal);

    logger.info("Reddit worker spawned.");

    try
    {
        immutable reddit = lookupReddit(redditReq);
        state.mainThread.reportReddit(reddit, redditReq.target);
    }
    catch (const Exception e)
    {
        logger.error("Reddit worker exception: ", e.msg);
    }
}


string lookupReddit(const string url)
{
    import kameloso.constants : BufferSize;
    import requests : Request;

    Request req;
    req.useStreaming = true;  // we only want as little as possible
    req.keepAlive = false;
    req.bufferSize = BufferSize.titleLookup;

    logger.log("Checking Reddit ...");

    RedditLookup lookup;

    auto redditRes = req.get("https://www.reddit.com/" ~ url);

    with (redditRes.finalURI)
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
            return redditRes.finalURI.uri;
        }
    }
}


void reportReddit(Tid tid, const string reddit, const string target)
{
    import kameloso.common : ThreadMessage;
    import std.concurrency : send;
    import std.format : format;

    if (reddit.length)
    {
        tid.send(ThreadMessage.Sendline(),
            "PRIVMSG %s :Reddit: %s".format(target, reddit));
    }
}


public:

mixin BasicEventHandlers;

final class RedditPlugin : IRCPlugin
{
    /// Cache of recently looked-up URLs
    RedditLookup[string] cache;

    mixin IRCPluginImpl;
}
