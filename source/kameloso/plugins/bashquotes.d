module kameloso.plugins.bashquotes;

version(Webtitles):

import kameloso.plugins.common;
import kameloso.ircdefs;
import kameloso.common : logger;

import std.stdio;

private:


// onMessage
/++
 +  Fetch a random or specified bash.org quote.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(ChannelPolicy.homeOnly)
@(PrivilegeLevel.friend)
@Prefix("bash")
@Prefix(NickPolicy.required, "bash")
void onMessage(BashQuotesPlugin plugin, const IRCEvent event)
{
    import kameloso.common : ThreadMessage;
    import arsd.dom : Document, htmlEntitiesDecode;
    import requests : getContent;
    import core.thread : Thread;
    import core.time : msecs;
    import std.algorithm.iteration : splitter;
    import std.concurrency : send;
    import std.format : format;
    import std.datetime : Clock;
    import std.regex : ctRegex, matchFirst, replaceAll;

    immutable url = !event.content.length ? "http://bash.org/?random" :
        "http://bash.org/?" ~ event.content;

    //static numEngine = ctRegex!`href="\?([0-9]+)"`;
    static qtEngine = ctRegex!`<p class="qt">`;
    static pEngine = ctRegex!`</p>`;
    static brEngine = ctRegex!`<br />`;

    immutable target = event.channel.length ?
        event.channel : event.target.nickname;

    try
    {
        auto content = cast(string)(getContent(url).data);
        auto doc = new Document;
        doc.parseGarbage(content);

        auto numBlock = doc.getElementsByClassName("quote");

        if (!numBlock.length)
        {
            plugin.state.mainThread.send(ThreadMessage.Sendline(),
                "PRIVMSG %s :No such bash.org quote: %s"
                .format(target, event.content));
            return;  // invalid quote
        }

        auto range = doc
            .getElementsByClassName("qt")[0]
            .toString
            .htmlEntitiesDecode
            .replaceAll(qtEngine, string.init)
            .replaceAll(pEngine, string.init)
            .replaceAll(brEngine, string.init)
            .splitter("\n");

        foreach (line; range)
        {
            plugin.state.mainThread.send(ThreadMessage.Throttleline(),
                "PRIVMSG %s :%s".format(target, line));
        }
    }
    catch (const Exception e)
    {
        logger.error("Could not fetch ", url, ": ", e.msg);
    }
}


mixin BasicEventHandlers;

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
