module kameloso.plugins.sedreplace;

import kameloso.plugins.common;
import kameloso.irc;
import kameloso.common;
import kameloso.constants;

import std.stdio : writeln, writefln;
import std.regex;
import std.concurrency;
import std.datetime;


private:

IrcPluginState state;
Line[string] prevlines;


enum sedPattern = `s/([^/]+)/([^/]*)(?:/g?)?`;
static sedRegex = ctRegex!sedPattern;


static string sedReplace(const string originalLine, const string expression)
{
    string result = originalLine;

    foreach (hit; expression.matchAll(sedRegex))
    {
        const changeThis = hit[1];
        const toThis = hit[2];
        result = result.replaceAll(changeThis.regex, toThis);
    }

    return result;
}


struct Line
{
    string content;
    SysTime when;
}


void sedReplaceWorker(shared IrcPluginState origState)
{
    mixin(scopeguard(entry|exit));

    bool halt;
    state = cast(IrcPluginState)origState;

    while (!halt)
    {
        receive(
            (shared IrcEvent event)
            {
                return event.onEvent();
            },
            (shared IrcBot bot)
            {
                writeln("sed replace worker got new bot");
                state.bot = cast(IrcBot)bot;
            },
            (ThreadMessage.Status)
            {
                writeln("---------------------- ", __MODULE__);
                printObject(state);
            },
            (ThreadMessage.Teardown)
            {
                writeln("sed replace worker saw Teardown");
                halt = true;
            },
            (OwnerTerminated e)
            {
                writeln("sed replace worker saw OwnerTerminated");
                halt = true;
            },
            (Variant v)
            {
                writeln("sed replace worker received Variant");
                writeln(v);
            }
        );
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


void onCommand(const IrcEvent event)
{
    import kameloso.stringutils;
    import std.format : format;

    if (!event.content.beginsWith("s/"))
    {
        Line line;
        line.content = event.content;
        line.when = Clock.currTime;
        prevlines[event.sender] = line;
        return;
    }

    if (auto line = event.sender in prevlines)
    {
        if ((Clock.currTime - line.when) > 1.minutes) return;

        string result = line.content.sedReplace(event.content);
        if ((result == event.content) || !result.length) return;

        state.mainThread.send(ThreadMessage.Sendline(),
            "PRIVMSG %s :%s | %s".format(event.channel, event.sender, result));

        prevlines.remove(event.sender);
    }
}


public:


final class SedReplacePlugin(Multithreaded multithreaded) : IrcPlugin
{
private:
    static if (multithreaded)
    {
        Tid worker;
    }

public:
    void onEvent(const IrcEvent event)
    {
        static if (multithreaded)
        {
            worker.send(cast(shared)event);
        }
        else
        {
            return event.onEvent();
        }
    }

    this(IrcPluginState origState)
    {
        state = origState;

        static if (multithreaded)
        {
            pragma(msg, "Building a multithreaded ", typeof(this).stringof);
            writeln(typeof(this).stringof, " runs in a separate thread.");
            worker = spawn(&sedReplaceWorker, cast(shared)state);
        }
    }

    void newBot(IrcBot bot)
    {
        static if (multithreaded)
        {
            worker.send(cast(shared)bot);
        }
        else
        {
            state.bot = bot;
        }
    }

    void status()
    {
        static if (multithreaded)
        {
            worker.send(ThreadMessage.Status());
        }
        else
        {
            writeln("---------------------- ", typeof(this).stringof);
            printObject(state);
        }
    }


    void teardown()
    {
        static if (multithreaded)
        {
            worker.send(ThreadMessage.Teardown());
        }
    }
}
