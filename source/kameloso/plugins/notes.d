module kameloso.plugins.notes;

import kameloso.plugins.common;
import kameloso.constants;
import kameloso.common;
import kameloso.irc;

import std.stdio  : writeln, writefln;
import std.format : format, formattedRead;
import std.concurrency;
import std.json;

private:

IrcPluginState state;
JSONValue notes;


@(Label("onjoin"))
@(IrcEvent.Type.JOIN)
void onJoin(const IrcEvent event)
{
    import std.datetime : Clock;
    import kameloso.stringutils : timeSince;

    auto noteArray = getNotes(event.sender);

    if (!noteArray.length) return;
    else if (noteArray.length == 1)
    {
        const note = noteArray[0];
        immutable timestamp = (Clock.currTime - note.when).timeSince;

        state.mainThread.send(ThreadMessage.Sendline(),
            "PRIVMSG %s :%s! %s left note %s ago: %s"
            .format(event.channel, event.sender, note.sender, timestamp, note.line));
    }
    else
    {
        state.mainThread.send(ThreadMessage.Sendline(),
            "PRIVMSG %s :%s! You have %d notes."
            .format(event.channel, event.sender, noteArray.length));

        foreach (const note; noteArray)
        {
            immutable timestamp = (Clock.currTime - note.when).timeSince;

            state.mainThread.send(ThreadMessage.Sendline(),
                "PRIVMSG %s :%s left note %s ago: %s"
                .format(event.channel, note.sender, timestamp, note.line));
        }
    }

    clearNotes(event.sender);
}


@(Label("names"))
@(IrcEvent.Type.RPL_NAMREPLY)
void onNames(const IrcEvent event)
{
    import std.algorithm.iteration : splitter;
    import std.datetime : Clock;

    foreach (nickname; event.content.splitter)
    {
        IrcEvent fakeEvent;

        with (fakeEvent)
        {
            type = IrcEvent.Type.JOIN;
            sender = nickname.stripModeSign();
            channel = event.channel;
            time = Clock.currTime.toUnixTime;
        }

        onJoin(fakeEvent);
    }
}


@(Label("addnote"))
@(IrcEvent.Type.CHAN)
@(PrivilegeLevel.friend)
@(Prefix(NickPrefixPolicy.required, "addnote"))
@(Prefix(NickPrefixPolicy.required, "note"))
void onCommandAddNote(const IrcEvent event)
{
    import std.string : strip;

    string nickname, line;
    string content = event.content;  // BUG: needs to be mutable or formattedRead won't work
    const hits = content.formattedRead("%s %s", &nickname, &line);

    if (hits != 2) return;

    nickname.addNote(event.sender, line);
    state.mainThread.send(ThreadMessage.Sendline(),
        "PRIVMSG %s :Note added".format(event.channel));

    Files.notes.saveNotes(notes);
}


@(Label("printnotes"))
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@(Prefix(NickPrefixPolicy.required, "printnotes"))
void onCommandPrintNotes()
{
    writeln(notes.toPrettyString);
}


@(Label("reloadnotes"))
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@(Prefix(NickPrefixPolicy.required, "reloadnotes"))
void onCommandReloadQuotes()
{
    writeln("Reloading notes");
    notes = loadNotes(Files.notes);
}


@(Label("fakejoin"))
@(IrcEvent.Type.CHAN)
@(PrivilegeLevel.master)
@(Prefix(NickPrefixPolicy.required, "fakejoin"))
void onCommandFakejoin(const IrcEvent event)
{
    import kameloso.stringutils;
    import std.string : indexOf;

    writeln("faking an event");

    IrcEvent newEvent = event;
    newEvent.type = IrcEvent.Type.JOIN;
    string nickname = event.content;

    if (nickname.indexOf(' ') != -1)
    {
        // contains more than one word
        newEvent.sender = nickname.nom!(Decode.yes)(" ");
    }
    else
    {
        newEvent.sender = event.content;
    }

    writeln(newEvent);
    return onJoin(newEvent);  // or onEvent?
}


auto getNotes(const string nickname)
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
                clearNotes(nickname);

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


void clearNotes(const string nickname)
{
    if (nickname in notes)
    {
        writeln("Clearing stored notes for ", nickname);
        notes.object.remove(nickname);
        Files.notes.saveNotes(notes);
    }
}


void addNote(const string nickname, const string sender, const string line)
{
    import std.datetime : Clock;

    if (!line.length)
    {
        writeln("No message to crete note from...");
        return;
    }

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


void saveNotes(const string filename, const JSONValue notes)
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


JSONValue loadNotes(const string filename)
{
    import std.file   : exists, isFile, readText;
    import std.string : chomp;

    if (!filename.exists)
    {
        writefln("%s does not exist", filename);
        return JSONValue("{}");
    }
    else if (!filename.isFile)
    {
        writefln("%s is not a file", filename);
        return JSONValue("{}");
    }

    auto wholeFile = filename.readText.chomp;
    return parseJSON(wholeFile);
}


void initialise()
{
    writeln("Initialising notes ...");
    notes = Files.notes.loadNotes();
}


mixin BasicEventHandlers;
mixin OnEventImpl!__MODULE__;


public:

final class NotesPlugin : IrcPlugin
{
    mixin IrcPluginBasics;
}
