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
version(Webtitles)
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@Prefix(NickPolicy.required, "bash")
@(ChannelPolicy.homeOnly)
void onMessage(const IRCEvent event)
{
    import kameloso.common : ThreadMessage;
    import requests : getContent;
    import arsd.dom : Document, htmlEntitiesDecode;
    import core.thread : Thread;
    import core.time : msecs;
    import std.algorithm.iteration : splitter;
    import std.concurrency : send;
    import std.datetime : Clock;
    import std.regex : ctRegex, matchFirst, replaceAll;

    enum url = "http://bash.org/?random";
    static engine = ctRegex!`href="\?([0-9]+)"`;
    static qtEngine = ctRegex!`<p class="qt">`;
    static pEngine = ctRegex!`</p>`;
    static brEngine = ctRegex!`<br />`;

    auto content = cast(string)(getContent(url).data);
    auto doc = new Document;
    doc.parseGarbage(content);

    auto num = doc.getElementsByClassName("quote")[0].toString;
    auto hits = num.matchFirst(engine);
    writeln(hits[1]);

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
        state.mainThread.send(ThreadMessage.Sendline(), line);
    }
    /*{
        enum k = -2.0;
        auto x = double(Clock.currTime.toUnixTime - t0);
        auto y = k * x + m;

        if (y < 0)
        {
            m = 0;
            t0 = Clock.currTime.toUnixTime;
            x = double(Clock.currTime.toUnixTime - t0);
            y = k * x + m;
        }

        while (y >= 6)
        {
            x = double(Clock.currTime.toUnixTime - t0);
            y = k*x + m;
            //m -= 1;
            writeln("sleeping:", y);
            Thread.sleep(500.msecs);
        }
        writeln(line);
        m = y + 2;
        t0 = Clock.currTime.toUnixTime;
        //writeln(k * x + m);
    }*/
}


public:

final class BashOrgPlugin : IRCPlugin
{
    mixin IRCPluginBasics;
}
