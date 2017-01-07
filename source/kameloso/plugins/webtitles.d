module kameloso.plugins.webtitles;

import kameloso.plugins.common;
import kameloso.irc;
import kameloso.common;
import kameloso.constants;

import std.stdio : writeln, writefln;
import std.regex;
import std.datetime : Clock, SysTime, seconds;
import std.concurrency : Tid;

private:

/// Regex to grep a web page title from the HTTP body
enum titlePattern = `<title>(.+)</title>`;
static titleRegex = ctRegex!(titlePattern, "i");

/// Regex to match a URI, to see if one was pasted.
//enum stephenhay = `\b(https?|ftp)://[^\s/$.?#].[^\s]*`;
enum stephenhay = `\bhttps?://[^\s/$.?#].[^\s]*`;
static urlRegex = ctRegex!stephenhay;

//enum domainPattern = `(?:[a-z]+://)?([^/ ]+)/?.*`;
enum domainPattern = `(?:https?://)?([^/ ]+)/?.*`;
static domainRegex = ctRegex!domainPattern;


struct TitleLookup
{
    string title;
    string domain;
    SysTime when;
}


public:

final class Webtitles : IrcPlugin
{
private:
    import std.concurrency : send;
    import requests;

    IrcPluginState state;
    TitleLookup[string] cache;
    Tid worker;

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

public:
    this(IrcBot bot, Tid tid)
    {
        import std.concurrency : spawn;

        state.bot = bot;
        state.mainThread = tid;
        worker = spawn(&titleworker, tid);
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
            state.onBasicEvent(event);
            return;
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

    void teardown() {}
}



static TitleLookup doTitleLookup(string url)
{
    import kameloso.stringutils : beginsWith;
    import std.conv : to;
    import requests;

    if (!url.beginsWith("http"))
    {
        url = "http://" ~ url;
    }

    TitleLookup lookup;

    writeln("URL: ", url);

    auto content = getContent(url);
    const httpBody = cast(char[])(content.data);

    if (!httpBody.length)
    {
        writeln("Could not fetch content. Bad URL?");
        return lookup;
    }

    writeln("Page fetched.");

    auto titleHits = httpBody.matchFirst(titleRegex);

    if (!titleHits.length)
    {
        writeln("Could not get title from page content!");
        return lookup;
    }

    writeln("Got title.");

    lookup.title = titleHits[1].idup;

    auto domainHits = url.matchFirst(domainRegex);
    if (!domainHits.length) return lookup;

    lookup.domain = domainHits[1];
    lookup.when = Clock.currTime;

    return lookup;
}


void titleworker(Tid mainThread)
{
    import std.concurrency;
    import core.time;
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
                    try lookup = doTitleLookup(url);
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
