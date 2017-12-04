module kameloso.plugins.bashquotes;

version(Webtitles):

import kameloso.plugins.common;
import kameloso.ircdefs;
import kameloso.common : logger;

import std.stdio;

private:

IRCPluginState state;


// onMessage
/++
 +
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(ChannelPolicy.homeOnly)
@Prefix(NickPolicy.required, "bash")
void onMessage(const IRCEvent event)
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

    static numengine = ctRegex!`href="\?([0-9]+)"`;
    static qtEngine = ctRegex!`<p class="qt">`;
    static pEngine = ctRegex!`</p>`;
    static brEngine = ctRegex!`<br />`;

    try
    {
        auto content = cast(string)(getContent(url).data);
        auto doc = new Document;
        doc.parseGarbage(content);

        /*auto num = doc.getElementsByClassName("quote")[0].toString;
        auto hits = num.matchFirst(numEngine);
        writeln(hits[1]);*/

        auto range = doc
            .getElementsByClassName("qt")[0]
            .toString
            .htmlEntitiesDecode
            .replaceAll(qtEngine, string.init)
            .replaceAll(pEngine, string.init)
            .replaceAll(brEngine, string.init)
            .splitter("\n");

        immutable target = event.channel.length ?
            event.channel : event.target.nickname;

        foreach (i; 0..10)
        foreach (line; range)
        {
            state.mainThread.send(ThreadMessage.Throttleline(),
                "PRIVMSG %s :%s".format(target, line));
        }
    }
    catch (const Exception e)
    {
        logger.error("Could not fetch ", url, ": ", e.msg);
    }
}


public:

final class BashQuotesPlugin : IRCPlugin
{
    mixin IRCPluginBasics;
}
