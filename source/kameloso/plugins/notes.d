module kameloso.plugins.notes;

import kameloso.plugins.common;
import kameloso.irc;
import kameloso.common;
import kameloso.constants;

import std.stdio  : writeln, writefln;
import std.format : format, formattedRead;
import std.json;


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
        import std.string : indexOf, munch;

        with(state)
        with (IrcEvent.Type)
        switch (event.type)
        {
        case JOIN:
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
            break;
        }
    }

    void onJoin(const IrcEvent event)
    {
        // Authorised and everything
        auto noteArray = notes.getNotes(event.sender);
        if (!noteArray.length) return;

        foreach (note; noteArray)
        {
            const timestamp = "%s %02d/%02d %02d:%02d".format(note.when.dayOfWeek,
                note.when.day, note.when.month, note.when.hour, note.when.minute);
            state.mainThread.send(ThreadMessage.Sendline(),
                "PRIVMSG %s :%s! %s left note on %s: %s"
                .format(event.channel, event.sender, note.sender, timestamp, note.line));
        }

        notes.clearNotes(event.sender);
    }

    void onVerb(const IrcEvent event, string line)
    {
        import kameloso.stringutils;
        import std.string : indexOf;
        import std.uni : toLower;

        string verb, args;
        line.formattedRead("%s %s", &verb, &args);

        switch (verb.toLower)
        {
        case "addnote":
        case "note":
            string nickname, content;
            const hits = args.formattedRead("%s %s", &nickname, &content);
            if (hits != 2) return;
            notes.addNote(nickname, event.sender, content);
            state.mainThread.send(ThreadMessage.Sendline(),
                "PRIVMSG %s :Note added".format(event.channel));
            Files.notes.saveNotes(notes);
            break;

        case "printnotes":
            if (event.sender != state.bot.master) return;
            writeln(notes.toPrettyString);
            break;

        case "fakejoin":
            if (event.sender != state.bot.master) return;
            writeln("faking an event");
            IrcEvent newEvent = event;
            newEvent.sender = args;
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
    import std.datetime : SysTime, Clock;

    struct Note
    {
        string sender, line;
        SysTime when;
    }

    Note[] noteArray;

    try
    {
        if (notes.isNull) return noteArray;

        if (auto arr = nickname in notes)
        {
            if (arr.type != JSON_TYPE.ARRAY)
            {
                writefln("Invalid notes list for %s (type is %s)", nickname, arr.type);
                notes.clearNotes(nickname);
                return noteArray;
            }

            noteArray.length = arr.array.length;

            foreach (i, note; arr.array)
            {
                noteArray[i].sender = note["sender"].str;
                noteArray[i].line = note["line"].str;
                noteArray[i].when = SysTime.fromISOString(note["when"].str);
            }

            return noteArray;
        }
        else
        {
            writeln("No notes available for nickname ", nickname);
            return noteArray;
        }
    }
    catch (JSONException e)
    {
        writeln(e.msg);
        return noteArray;
    }
}


static void clearNotes(ref JSONValue notes, const string nickname)
{
    if (auto arr = nickname in notes)
    {
        writeln("Clearing stored notes for ", nickname);
        notes[nickname] = string[].init;
    }
}


static void addNote(ref JSONValue notes, const string nickname,
                    const string sender, const string line)
{
    import std.datetime : Clock;

    auto lineAsAA =
    [
        "sender" : sender,
        "when"   : Clock.currTime.toISOString,
        "line"   : line
    ];

    try
    {
        if (!notes.isNull && (nickname in notes) && (notes[nickname].type == JSON_TYPE.ARRAY))
        {
            notes[nickname].array ~= JSONValue(lineAsAA);
        }
        else
        {
            notes[nickname] = [ lineAsAA ];
        }
    }
    catch (JSONException e)
    {
        writeln(e.msg);
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
    import std.file   : exists, isFile, readText;
    import std.string : chomp;

    if (!filename.exists)
    {
        writefln("%s does not exist", filename);
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
