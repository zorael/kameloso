module kameloso.plugins.notes;

import kameloso.plugins.common;
import kameloso.irc;
import kameloso.common;

import std.json;

private:

public:
final class NotesPlugin : IrcPlugin
{
private:
    import std.stdio : writeln, writefln;
    import std.concurrency : Tid, send;

    IrcPluginState state;
    JSONValue notes;

    void onCommand(const IrcEvent event)
    {
        writeln("notes onCommand");
        with (IrcEvent.Type)
        switch (event.type)
        {
        case JOIN:
            writeln("Should look up notes on " ~ event.sender);
            break;

        case CHAN:
            //writeln("Line should be prefixed");
            //writeln("Should react, verb addnote?");
            break;

        default:
            writeln("default");
            break;
        }
    }

public:
    this(IrcBot bot, Tid tid)
    {
        state.bot = bot;
        state.mainThread = tid;

        Files.notes.loadNotes(notes);
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
            if (state.filterChannel!(RequirePrefix.yes)(event) == FilterResult.fail)
            {
                // Invalid channel or not prefixed
                return;
            }
            break;

        case QUERY:
        case JOIN:
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

