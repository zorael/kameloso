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


enum sedPattern = `s/([^/]+)/([^/]*)(?:/g?)?`;
static sedRegex = ctRegex!sedPattern;


string sedReplace(const string originalLine, const string expression)
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


public:


final class SedReplacePlugin : IrcPlugin
{
private:
    IrcPluginState state;
    Line[string] prevlines;

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
            writeln(line.content);
            writeln(event.content);

            if ((Clock.currTime - line.when) > 1.minutes) return;

            string result = line.content.sedReplace(event.content);
            if ((result == event.content) || !result.length) return;

            state.mainThread.send(ThreadMessage.Sendline(),
                "PRIVMSG %s :%s | %s".format(event.channel, event.sender, result));

            prevlines.remove(event.sender);
        }
    }

public:
    this(IrcBot bot, Tid tid)
    {
        state.bot = bot;
        state.mainThread = tid;
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