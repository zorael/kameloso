__EOF__

module kameloso.plugins.sedreplace;

import kameloso.plugins.common;
import kameloso.irc;
import kameloso.common;
import kameloso.constants;

import std.stdio : writeln, writefln;
import std.regex;


private:
enum replacePattern = `^s/([^/])+/([^/])+/$`;
static replaceRegex = ctRegex!replacePattern;

public:


final class SedReplacePlugin : IrcPlugin
{
private:
    IrcPluginState state;

    void onCommand(const IrcEvent event)
    {
        writeln("sedreplace onCommand");
        auto hits = event.content.matchFirst(replaceRegex);
        if (!hits.length) return;

        writeln(hits);
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