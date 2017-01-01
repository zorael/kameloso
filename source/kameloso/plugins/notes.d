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

    void onCommand(const IrcEvent event) {}

public:
    this(IrcBot bot, Tid tid)
    {
        state.bot = bot;
        state.mainThread = tid;

        // Files.notes.loadNotes(notes);
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

    void onEvent(const IrcEvent event)
    {
        // ...
    }

    void teardown() {}
}

