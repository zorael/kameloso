module kameloso.plugins.notes;

import kameloso.plugins.common;
import kameloso.irc;
import kameloso.common;
import kameloso.constants;

import std.json;
import std.datetime;
import std.conv;
import std.string;
import std.format;
import std.stdio;


private:

public:
final class NotesPlugin : IrcPlugin
{
private:
    import std.concurrency : Tid, send;

    IrcPluginState state;
    JSONValue notes;

    void onCommand(const IrcEvent event)
    {
        import kameloso.stringutils;
        import std.string : indexOf, stripLeft, munch;
        import std.format : formattedRead;

        writeln("notes onCommand");

        with(state)
        with (IrcEvent.Type)
        switch (event.type)
        {
        case JOIN:
            writeln("Should look up notes on ", event.sender);
            return onJoin(event);

        case CHAN:
            // Line should be prefixed here
            string line;
            string slice = event.content;
            const hits = slice.formattedRead(bot.nickname ~ ":%s", &line);
            if (!hits)
            {
                writeln("NO HITS?!");
                writeln(line);
                writeln(slice);
                writeln(hits);
                return;
            }
            line.munch(" :");
            return onVerb(event, line);

        default:
            writeln("notes default");
            break;
        }
    }

    void onJoin(const IrcEvent event)
    {
        // Authorised and everything
        foreach (note; notes.getNotes(event.sender))
        {
            const timestamp = "%s %02d/%02d %02d:%02d".format(note.when.dayOfWeek,
                note.when.day, note.when.month, note.when.hour, note.when.minute);
            state.mainThread.send(ThreadMessage.Sendline(),
                "PRIVMSG %s :%s (%s): %s".format(event.channel, note.sender, timestamp, note.line));
        }
    }

    void onVerb(const IrcEvent event, string line)
    {
        import kameloso.stringutils;
        import std.uni : toLower;

        const verb = line.nom!(Decode.yes)(' ');
        writeln("VERB: ", verb);
        writeln("LINE: ", line);

        switch (verb.toLower)
        {
        case "addnote":
            writeln("should add note");
            string nickname, content;
            auto hits = line.formattedRead("%s %s", &nickname, &content);
            writeln("hits: ", hits);
            notes.addNote(nickname, event.sender, content);
            Files.notes.saveNotes(notes);
            break;

        case "getnotes":
            const nickname = (line.indexOf(' ') == -1) ? line : line.nom(' ');
            auto note = notes.getNotes(nickname);
            writeln(note);
            break;

        case "printnotes":
            writeln(notes.toPrettyString);
            break;

        case "fakejoin":
            writeln("faking an event");
            IrcEvent newEvent = event;
            newEvent.sender = line;
            newEvent.content = string.init;
            newEvent.type = IrcEvent.Type.JOIN;
            writeln(newEvent);
            return onJoin(newEvent);

        default:
            writeln("notes default");
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


static auto getNotes(ref JSONValue notes, const string nickname)
{
    struct Note
    {
        string sender, line;
        SysTime when;

        version(none)
        this(JSONValue note)
        {
            sender = note["sender"].str;
            line = note["sline"].str;
            when = SysTime.fromISOString(note["when"].str);
        }

        string toString() const
        {
            return `[NOTE] %s: "%s"`.format(sender, line);
        }
    }

    Note[] noteArr;

    try
    {
        if (auto arr = nickname in notes)
        {
            noteArr.length = arr.array.length;

            foreach (i, note; arr.array)
            {
                writeln("---------------------------------");
                writeln(note.toPrettyString);
                writeln("---------------------------------");
                noteArr[i].sender = note["sender"].str;
                noteArr[i].line = note["line"].str;
                noteArr[i].when = SysTime.fromISOString(note["when"].str);
            }

            return noteArr;
        }
        else
        {
            writeln("No notes available for nickname ", nickname);
            return noteArr;
        }
    }
    catch (JSONException e)
    {
        return noteArr;
    }
}


static void addNote(ref JSONValue notes, const string nickname, const string sender, const string line)
{
    mixin(scopeguard(entry));
    import std.format : format;

    assert((nickname.length && line.length),
        "%s was passed an empty nickname(%s) or line(%s)".format(__FUNCTION__, nickname, line));

    auto lineAsAA =
    [
        "sender" : sender,
        "when"   : Clock.currTime.toISOString,
        "line"   : line
    ];

    writeln("lineAsAA: ", lineAsAA);

    try
    {
        if (auto arr = nickname in notes)
        {
            writeln(*arr);
            notes[nickname].array ~= JSONValue(lineAsAA);

        }
        else
        {
            // No notes for nickname
            notes.object[nickname] = JSONValue([ lineAsAA ]);
        }
    }
    catch (JSONException e)
    {
        writeln(e.msg);
        // No notes at all
        notes = JSONValue("{}");
        return notes.addNote(nickname, sender, line);
    }
}


static void saveNotes(const string filename, const JSONValue notes)
{
    import std.stdio : File;
    import std.file  : exists, isFile, remove;

    if (filename.exists && filename.isFile)
    {
        remove(filename); // Wise?
    }

    auto f = File(filename, "a");
    scope (exit) f.close();

    f.write(notes.toPrettyString);
    f.writeln();
}


static void loadNotes(const string filename, ref JSONValue notes)
{
    import std.stdio  : writefln;
    import std.file   : exists, isFile, readText;
    import std.string : chomp;
    writefln("Loading notes");

    if (!filename.exists)
    {
        writefln("%s does not exist", filename);
        notes = parseJSON("{}");
        filename.saveNotes(notes);
        return;
    }
    else if (!filename.isFile)
    {
        writefln("%s is not a file", filename);
        return;
    }

    auto wholeFile = filename.readText.chomp;
    notes = parseJSON(wholeFile);
}
