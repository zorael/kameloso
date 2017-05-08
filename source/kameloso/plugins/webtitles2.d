module kameloso.plugins.webtitles2;

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


@(Description("message", "Catch a chat message and see if it contains a URL"))
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)  // ?
@(PrivilegeLevel.friend)
@Chainable
void onMessage(const IrcEvent event)
{
    auto matches = event.content.matchAll(urlRegex);

    foreach (urlHit; matches)
    {
        if (!urlHit.length) continue;

        const url = urlHit[0];
        const target = (event.channel.length) ? event.channel : event.sender;

        writeln("url hit");
        writeln(url);
        writeln(target);

        worker.send(url, target);
        writeln("sent");
    }
}

// -------------------------------------- FIX THIS COPYPASTE

@(Description("whoislogin", "Catch a whois-login event to update the list of tracked users"))
@(IrcEvent.Type.WHOISLOGIN)
void onWhoisLogin(const IrcEvent event)
{
    state.users[event.target] = userFromEvent(event);
}


@(Description("endofwhois", "Catch an end-of-whois event to remove queued events"))
@(IrcEvent.Type.RPL_ENDOFWHOIS)
void onEndOfWhois(const IrcEvent event)
{
    state.queue.remove(event.target);
}


@(Description("part/quit", "Catch a part event to remove the nickname from the list of tracked users"))
@(IrcEvent.Type.PART)
@(IrcEvent.Type.QUIT)
void onLeave(const IrcEvent event)
{
    state.users.remove(event.sender);
}


@(Description("selfnick", "Catch a selfnick event to properly update the bot's (nickname) state"))
@(IrcEvent.Type.SELFNICK)
void onSelfNick(const IrcEvent event)
{
    // writeln("[!] on selfnick");
    if (state.bot.nickname == event.content)
    {
        writefln("%s saw SELFNICK but already had that nick...", __MODULE__);
    }
    else
    {
        state.bot.nickname = event.content;
    }
}

// -------------------------------------- FIX THIS COPYPASTE

string streamUntil(Stream_, Regex, Sink)
    (ref Stream_ stream, Regex engine, ref Sink sink)
{
    foreach (data; stream)
    {
        //writefln("Received %d bytes, total received %d from document legth %d", stream.front.length, rq.contentReceived, rq.contentLength);
        const asString = cast(string)data;
        auto hits = asString.matchFirst(engine);
        sink.put(data);

        if (hits.length)
        {
            //writefln("Found title mid-stream after %s bytes", rq.contentReceived);
            //writefln("Appender size is %d", sink.data.length);
            //writefln("capacity is %d", sink.capacity);
            return hits[1];
        }
    }

    return string.init;
}


TitleLookup lookupTitle(string url)
{
    import kameloso.stringutils : beginsWith;
    import requests;
    import std.array  : Appender, arrayReplace = replace;
    import std.string : removechars, strip;

    TitleLookup lookup;
    Appender!string pageContent;
    pageContent.reserve(BufferSize.titleLookup);

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

    writeln("code: ", rs.code);
    if (rs.code >= 400) return lookup;

    lookup.title = stream.streamUntil(titleRegex, pageContent);

    if (!pageContent.data.length)
    {
        writeln("Could not get content. Bad URL?");
        return lookup;
    }

    if (!lookup.title.length)
    {
        auto titleHits = pageContent.data.matchFirst(titleRegex);

        if (titleHits.length)
        {
            writeln("Found title in complete data (it was split)");
            lookup.title = titleHits[1];
        }
        else
        {
            writeln("No title...");
            return lookup;
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


void titleworker(shared IrcPluginState state)
{
    import core.time : seconds;

    mixin(scopeguard(entry|exit));

    Tid mainThread = cast(Tid)state.mainThread;
    TitleLookup[string] cache;
    bool halt;

    while (!halt)
    {
        receive(
            &onEvent,
            (shared IrcBot bot)
            {
                // discard
            },
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


mixin onEventImpl!__MODULE__;

public:

final class Webtitles2 : IrcPlugin
{
    mixin IrcPluginBasics2;

    void initialise()
    {
        IrcPluginState stateCopy = state;
        worker = spawn(&titleworker, cast(shared)stateCopy);
    }
}