module kameloso.plugins.webtitles;

import kameloso.plugins.common;
import kameloso.constants;
import kameloso.common;
import kameloso.irc;

import std.stdio : writeln, writefln;
import std.datetime : Clock, SysTime, seconds;
import std.concurrency;
import std.regex;

private:

IrcPluginState state;
TitleLookup[string] cache;
Tid worker;


/// Regex to grep a web page title from the HTTP body
enum titlePattern = `<title>([^<]+)</title>`;
static titleRegex = ctRegex!(titlePattern, "i");


/// Regex to match a URI, to see if one was pasted.
enum stephenhay = `\bhttps?://[^\s/$.?#].[^\s]*`;
static urlRegex = ctRegex!stephenhay;


enum domainPattern = `(?:https?://)?([^/ ]+)/?.*`;
static domainRegex = ctRegex!domainPattern;


struct TitleLookup
{
    string title;
    string domain;
    SysTime when;
}


void onCommand(const IrcEvent event)
{
    auto matches = event.content.matchAll(urlRegex);

    foreach (urlHit; matches)
    {
        if (!urlHit.length) continue;

        const url = urlHit[0];
        const target = (event.channel.length) ? event.channel : event.sender;

        worker.send(url, target);
    }
}


void onEvent(const IrcEvent event)
{
    with (state)
    with (IrcEvent.Type)
    switch (event.type)
    {
    case CHAN:
        if (state.filterChannel!(RequirePrefix.no)(event) == FilterResult.fail)
        {
            // Invalid channel
            return;
        }
        break;

    case QUERY:
        // All queries are okay
        break;

    default:
        return state.onBasicEvent(event);
    }

    final switch (state.filterUser(event))
    {
    case FilterResult.pass:
        // It is a known good user (friend or master), but it is of any type
        return onCommand(event);

    case FilterResult.whois:
        return state.doWhois(event);

    case FilterResult.fail:
        // It is a known bad user
        return;
    }
}


string streamUntil(Stream_, Regex, Sink)
    (ref Stream_ stream, Regex engine, ref Sink sink)
{
    while (!stream.empty)
    {
        //writefln("Received %d bytes, total received %d from document legth %d", stream.front.length, rq.contentReceived, rq.contentLength);
        const asString = cast(string)(stream.front);
        auto hits = asString.matchFirst(engine);
        sink.put(stream.front);

        if (hits.length)
        {
            //writefln("Found title mid-stream after %s bytes", rq.contentReceived);
            //writefln("Appender size is %d", app.data.length);
            //writefln("capacity is %d", app.capacity);
            return hits[1];
        }

        stream.popFront();

        continue;
    }

    return string.init;
}


TitleLookup lookupTitle(string url)
{
    import kameloso.stringutils : beginsWith;
    import requests;
    import std.array  : Appender, arrayReplace = replace;
    import std.string : removechars;

    TitleLookup lookup;
    Appender!string app;
    app.reserve(BufferSize.titleLookup);

    if (!url.beginsWith("http"))
    {
        url = "http://" ~ url;
    }

    writeln("URL: ", url);

    Request rq;
    rq.useStreaming = true;
    rq.keepAlive = false;
    rq.bufferSize = BufferSize.titleLookup;

    auto rs = rq.get(url);
    auto stream = rs.receiveAsRange();

    if (rs.code == 404) return lookup;

    lookup.title = stream.streamUntil(titleRegex, app);

    if (!app.data.length)
    {
        writeln("Could not get content. Bad URL?");
        return lookup;
    }

    if (!lookup.title.length)
    {
        auto titleHits = app.data.matchFirst(titleRegex);

        if (titleHits.length)
        {
            writeln("Found title in complete data (it was split)");
            lookup.title = titleHits[1];
        }
        else
        {
            writeln("No title...");
        }
    }

    lookup.title = lookup.title
        .removechars("\r")
        .arrayReplace("\n", " ")
        .strip;

    auto domainHits = url.matchFirst(domainRegex);

    if (!domainHits.length) return lookup;

    lookup.domain = domainHits[1];
    lookup.when = Clock.currTime;

    return lookup;
}


void titleworker(Tid mainThread)
{
    import core.time : seconds;

    mixin(scopeguard(entry|exit));

    TitleLookup[string] cache;
    bool halt;

    while (!halt)
    {
        receive(
            (string url, string target)
            {
                import std.format : format;

                TitleLookup lookup;
                auto inCache = url in cache;

                if (inCache && ((Clock.currTime - inCache.when) < Timeout.titleCache.seconds))
                {
                    lookup = *inCache;
                }
                else
                {
                    try lookup = lookupTitle(url);
                    catch (Exception e)
                    {
                        writeln(e.msg);
                    }
                }

                if (lookup == TitleLookup.init) return;

                cache[url] = lookup;

                if (lookup.domain.length)
                {
                    mainThread.send(ThreadMessage.Sendline(),
                        "PRIVMSG %s :[%s] %s".format(target, lookup.domain, lookup.title));
                }
                else
                {
                    mainThread.send(ThreadMessage.Sendline(),
                        "PRIVMSG %s :%s".format(target, lookup.title));
                }
            },
            (ThreadMessage.Teardown)
            {
                writeln("Titleworker saw ThreadMessage.Teardown");
                halt = true;
            },
            (OwnerTerminated o)
            {
                writeln("Titleworker saw owner terminated!");
                halt = true;
            },
            (Variant v)
            {
                writeln("Titleworker received Variant");
                writeln(v);
            }
        );
    }
}


public:

final class Webtitles : IrcPlugin
{
    this(IrcPluginState origState)
    {
        state = origState;
        worker = spawn(&titleworker, state.mainThread);
    }

    void onEvent(const IrcEvent event)
    {
        return event.onEvent();
    }

    void status()
    {
        writeln("---------------------- ", typeof(this).stringof);
        printObject(state);
    }

    void newBot(IrcBot bot)
    {
        state.bot = bot;
    }

    void teardown() {}
}
