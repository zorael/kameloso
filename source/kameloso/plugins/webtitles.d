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
enum gruberv1 = `\b(([\w-]+://?|www[.])[^\s()<>]+(?:\([\w\d]+\)|([^[:punct:]\s]|/)))`;
enum daringfireball = `(?i)\b((?:[a-z][\w-]+:(?:/{1,3}|[a-z0-9%])|www\d{0,3}[.]|[a-z0-9.\-]+[.][a-z]{2,4}/)(?:[^\s()<>]+|\(([^\s()<>]+|(\([^\s()<>]+\)))*\))+(?:\(([^\s()<>]+|(\([^\s()<>]+\)))*\)|[^\s!()\[\]{};:'".,<>?«»“”‘’]))`;
enum stephenhay = `^(https?|ftp)://[^\s/$.?#].[^\s]*$`;
static urlRegex = ctRegex!stephenhay;

enum domainPattern = `(?:[a-zA-Z]+://)?([^/ ]+)/?.*`;
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
    import std.stdio : writeln, writefln;
    import std.format : format;
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
        writefln("---------------------- %s", typeof(this).stringof);
        printObject(state);
    }

    void newBot(IrcBot bot)
    {
        state.bot = bot;
    }

    version(none)
    void onEvent(const IrcEvent event)
    {
        return state.onEventImpl(event, &onCommand);
    }

    void onEvent(const IrcEvent event)
    {
        import std.algorithm.searching : canFind;

        with (state)
        with (IrcEvent.Type)
        switch (event.type)
        {
        case CHAN:
            /*
            * Not all channel messages are of interest; only those starting with the bot's
            * nickname, those from whitelisted users, and those in channels marked as active.
            */

            if (!bot.channels.canFind(event.channel))
            {
                // Channel is not relevant
                return;
            }

            auto user = event.sender in users;

            if (!user)
            {
                // No known user, relevant channel
                return state.doWhois(event, &onCommand);
            }

            // User exists in users database
            if (user.login == bot.master)
            {
                // User is master, all is ok
                return onCommand(event);
            }
            else if (bot.friends.canFind(user.login))
            {
                // User is whitelisted, all is ok
                return onCommand(event);
            }
            else
            {
                // Known bad user
                return;
            }

        case QUERY:
            // Queries are always aimed toward the bot, but the user must be whitelisted
            auto user = event.sender in state.users;

            if (!user) return state.doWhois(event, &onCommand);
            else if ((user.login == bot.master) || bot.friends.canFind(user.login))
            {
                // master or friend
                return onCommand(event);
            }
            break;

        case WHOISLOGIN:
            // Save user to users, then replay any queued commands.
            state.users[event.target] = userFromEvent(event);
            //users[event.target].lastWhois = Clock.currTime;

            if (auto oldCommand = event.target in queue)
            {
                if ((*oldCommand)())
                {
                    // The command returned true; remove it from the queue
                    queue.remove(event.target);
                }
            }

            break;

        case RPL_ENDOFWHOIS:
            // If there's still a queued command at this point, WHOISLOGIN was never triggered
            queue.remove(event.target);
            break;

        case PART:
        case QUIT:
            users.remove(event.sender);
            break;

        default:
            break;
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
