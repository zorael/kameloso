module kameloso.plugins.bashquotes;

version(Web):

import kameloso.plugins.common;
import kameloso.ircdefs;
import kameloso.common : logger;
import kameloso.messaging;

import std.stdio;

private:


// onMessage
/++
 +  Fetch a random or specified bash.org quote.
 +
 +  Defers to the worker subthread.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(ChannelPolicy.homeOnly)
@(PrivilegeLevel.friend)
@BotCommand("bash")
@BotCommand(NickPolicy.required, "bash")
void onMessage(BashQuotesPlugin plugin, const IRCEvent event)
{
    import std.concurrency : spawn;

    // Defer all work to the worker thread
    spawn(&worker, cast(shared)plugin.state, event);
}


// worker
/++
 +  Looks up a Bash quote and reports it to the appropriate nickname or
 +  channel.
 +
 +  Suppose to be run in its own, shortlived thread.
 +/
void worker(shared IRCPluginState sState, const IRCEvent event)
{
    import kameloso.common;
    import arsd.dom : Document, htmlEntitiesDecode;
    import requests : getContent;
    import std.algorithm.iteration : splitter;
    import std.format : format;
    import std.regex : ctRegex, matchFirst, replaceAll;

    IRCPluginState state = cast(IRCPluginState)sState;

    kameloso.common.settings = state.settings;
    initLogger(state.settings.monochrome, state.settings.brightTerminal);

    //logger.info("Bashquotes worker spawned.");

    immutable url = !event.content.length ? "http://bash.org/?random" :
        "http://bash.org/?" ~ event.content;

    immutable target = event.channel.length ?
        event.channel : event.sender.nickname;

    static qtEngine = ctRegex!`<p class="qt">`;
    static pEngine = ctRegex!`</p>`;
    static brEngine = ctRegex!`<br />`;

    try
    {
        import std.exception : assumeUnique;

        immutable content = (cast(char[])getContent(url).data).assumeUnique;
        auto doc = new Document;
        doc.parseGarbage(content);

        auto numBlock = doc.getElementsByClassName("quote");

        if (!numBlock.length)
        {
            state.mainThread.privmsg(event.channel, event.sender.nickname,
                "No such bash.org quote: %s".format(event.content));
            return;
        }

        immutable num = numBlock[0]
            .getElementsByTagName("p")[0]
            .getElementsByTagName("b")[0]
            .toString[4..$-4];

        auto range = doc
            .getElementsByClassName("qt")[0]
            .toString
            .htmlEntitiesDecode
            .replaceAll(qtEngine, string.init)
            .replaceAll(pEngine, string.init)
            .replaceAll(brEngine, string.init)
            .splitter("\n");

        state.mainThread.throttleline(event.channel, event.sender.nickname,
            "[bash.org] #%s".format(num));

        foreach (line; range)
        {
            state.mainThread.throttleline(event.channel,
                event.sender.nickname, line);
        }
    }
    catch (const Exception e)
    {
        logger.error("Bashquotes could not fetch ", url, ": ", e.msg);
    }
}


mixin UserAwareness;

public:


// BashQuotesPlugin
/++
 +  The Bash Quotes plugin fetches random or specified quotes from `bash.org`
 +  and echoes them to the channel.
 +/
final class BashQuotesPlugin : IRCPlugin
{
    mixin IRCPluginImpl;
}
