/++
 +  The Reddit plugin allows you to query Reddit with a web URL, and if that
 +  URL has been posted there it will print the post link to the channel.
 +
 +  It has one command:
 +
 +  `reddit`
 +
 +  It requires version `Web` as HTTP requests will have to be made.
 +
 +  It is very optional.
 +/
module kameloso.plugins.reddit;

version(Web):

import kameloso.common : ThreadMessage;
import kameloso.plugins.common;
import kameloso.ircdefs;

import std.concurrency;

private:


// RedditSettings
/++
 +  All Reddit plugin settings, gathered in a struct.
 +/
struct RedditSettings
{
    /// Toggles whether or not the plugin should react to events at all.
    bool enabled = true;
}


// RedditLookup
/++
 +  A record of a Reddit post lookup.
 +
 +  Merely pairs an URL with a timestamp.
 +/
struct RedditLookup
{
    import std.datetime.systime : SysTime;

    /// Lookup result URL.
    string url;

    /// UNIX timestamp of when the URL was looked up.
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
    if (!plugin.redditSettings.enabled) return;

    import kameloso.common : logger;
    import kameloso.constants : Timeout;
    import kameloso.string : contains, stripped;
    import std.datetime.systime : Clock, SysTime;

    immutable url = event.content.stripped;

    if (!url.length || url.contains(' '))
    {
        logger.error("Cannot look up Reddit post; invalid URL");
        return;
    }

    // Garbage-collect entries too old to use
    plugin.cache.prune();

    const cachedLookup = url in plugin.cache;

    if (cachedLookup && ((Clock.currTime.toUnixTime - cachedLookup.when)
        < Timeout.titleCache))
    {
        logger.log("Found Reddit lookup in cache");
        plugin.state.reportReddit(cachedLookup.url, event);
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
 +
 +  Params:
 +      sState = The `kameloso.plugins.common.IRCPluginState` of the original
 +          `RedditPlugin`, `shared` so that it may be passed to the worker
 +          threads.
 +      cache = Cache of previous Reddit lookups, in an associative array keyed
 +          with the original URL.
 +      url = Current URL to look up.
 +      event = `kameloso.ircdefs.IRCEvent` that instigated the lookup.
 +/
void worker(shared IRCPluginState sState, shared RedditLookup[string] cache,
    const string url, const IRCEvent event)
{
    import std.datetime.systime : Clock;

    auto state = cast(IRCPluginState)sState;

    try
    {
        immutable redditURL = state.lookupReddit(url);
        state.reportReddit(redditURL, event);

        RedditLookup lookup;
        lookup.url = redditURL;
        lookup.when = Clock.currTime.toUnixTime;
        cache[url] = lookup;
    }
    catch (const Exception e)
    {
        state.mainThread.send(ThreadMessage.TerminalOutput.Error(),
            "Reddit worker exception: " ~ e.msg);
    }
}


// lookupReddit
/++
 +  Given an URL, looks it up on Reddit to see if it has been posted there.
 +
 +  Params:
 +      url = URL to query Reddit for.
 +
 +  Returns:
 +      URL to the Reddit post that links to `url`.
 +/
string lookupReddit(IRCPluginState state, const string url)
{
    import kameloso.constants : BufferSize;
    import requests : Request;

    Request req;
    req.useStreaming = true;  // we only want as little as possible
    req.keepAlive = false;
    req.bufferSize = BufferSize.titleLookup;

    state.mainThread.send(ThreadMessage.TerminalOutput.Log(), "Checking Reddit ...");

    auto res = req.get("https://www.reddit.com/" ~ url);

    with (res.finalURI)
    {
        import kameloso.string : beginsWith;

        if (uri.beginsWith("https://www.reddit.com/login") ||
            uri.beginsWith("https://www.reddit.com/submit") ||
            uri.beginsWith("https://www.reddit.com/http"))
        {
            import std.algorithm.searching : endsWith;

            // No Reddit post found but retry with a slash appended if it
            // doesn't already end with one. It apparently matters.
            if (!uri.endsWith("/")) return state.lookupReddit(url ~ '/');
            state.mainThread.send(ThreadMessage.TerminalOutput.Log(),
                "No corresponding Reddit post found.");
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
 +
 +  Params:
 +      state = The current IRC plugin state, which includes the thread ID of
 +          the main thread to send the report to, to pass onto the server.
 +      reddit = URL of the Reddit post.
 +      event = `kameloso.ircdefs.IRCEvent` that instigated the lookup.
 +/
void reportReddit(IRCPluginState state, const string reddit, const IRCEvent event)
{
    import kameloso.messaging : privmsg;

    if (reddit.length)
    {
        state.privmsg(event.channel, event.sender.nickname, "Reddit post: " ~ reddit);
    }
    else
    {
        state.privmsg(event.channel, event.sender.nickname,
            "No corresponding Reddit post found.");
    }

}


// prune
/++
 +  Garbage-collects old entries in a `RedditLookup[string]` lookup cache.
 +
 +  Params:
 +      cache = Cache of Reddit lookups, `shared` so that it can persist over
 +          multiple lookups (multiple threads).
 +/
void prune(shared RedditLookup[string] cache)
{
    enum expireSeconds = 600;

    string[] garbage;

    foreach (key, entry; cache)
    {
        import std.datetime : Clock;
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
 +  Just assigns it an entry and remove it.
 +/
void start(RedditPlugin plugin)
{
    plugin.cache[string.init] = RedditLookup.init;
    plugin.cache.remove(string.init);
}


mixin MinimalAuthentication;

public:

// RedditPlugin
/++
 +  The Reddit plugin takes an URL and looks it up on Reddit, to see if it has
 +  been posted there.
 +
 +  It does this by simply appending the URL to https://www.reddit.com/, which
 +  makes Reddit either redirect you to a login page, to a submit-this-link
 +  page, or to a/the post that links to that URL.
 +/
final class RedditPlugin : IRCPlugin
{
    /// Cache of recently looked-up URLs.
    shared RedditLookup[string] cache;

    /// All Reddit plugin options gathered.
    @Settings RedditSettings redditSettings;

    mixin IRCPluginImpl;
}
