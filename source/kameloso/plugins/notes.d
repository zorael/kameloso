module kameloso.plugins.notes;

import kameloso.common;
import kameloso.constants;
import kameloso.irc;
import kameloso.plugins.common;

import std.concurrency : send;
import std.json   : JSONValue;

private:

/// All plugin state variables gathered in a struct
IRCPluginState state;


/++
 +  The in-memory JSON storage of all stored notes.
 +
 +  It is in the JSON form of string[][string], where the first key is
 +  a nickname.
 +/
JSONValue notes;


// onJoin
/++
 +  Sends notes to a channel upon someone joining.
 +
 +  Nothing is sent if no notes are stored.
 +
 +  Params:
 +      event = the triggering IRCEvent.
 +/
@Label("onjoin")
@(IRCEvent.Type.JOIN)
void onJoin(const IRCEvent event)
{
    import kameloso.stringutils : timeSince;
    import std.datetime : Clock;
    import std.format : format;

    const noteArray = getNotes(event.sender);

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


// onNames
/++
 +  Sends notes to a channel upon joining it.
 +
 +  Only reacting to others joinng would mean someone never leaving would never
 +  get notes. This may be extended to trigger when they say something, too.
 +
 +  Params:
 +      event = the triggering IRCEvent.
 +/
@Label("names")
@(IRCEvent.Type.RPL_NAMREPLY)
void onNames(const IRCEvent event)
{
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : canFind;
    import std.datetime : Clock;

    if (!state.bot.homes.canFind(event.channel))
    {
        return;
    }

    foreach (immutable prefixedNickname; event.content.splitter)
    {
        immutable nickname = prefixedNickname.stripModeSign();
        if (nickname == state.bot.nickname) continue;

        IRCEvent fakeEvent;

        with (fakeEvent)
        {
            type = IRCEvent.Type.JOIN;
            sender = nickname.stripModeSign();
            channel = event.channel;
            time = Clock.currTime.toUnixTime;
        }

        onJoin(fakeEvent);
    }
}


// onCommandAddNote
/++
 +  Adds a note to the in-memory storage, and saves it to disk.
 +
 +  Params:
 +      event = the triggering IRCEvent.
 +/
@Label("addnote")
@(IRCEvent.Type.CHAN)
@(PrivilegeLevel.friend)
@Prefix(NickPrefixPolicy.required, "addnote")
@Prefix(NickPrefixPolicy.required, "note")
void onCommandAddNote(const IRCEvent event)
{
    import std.format : format, formattedRead;
    import std.string : strip;

    string nickname, line;
    // formattedRead advances a slice so we need a mutable copy of event.content
    string content = event.content;
    immutable hits = content.formattedRead("%s %s", &nickname, &line);

    if (hits != 2) return;

    nickname.addNote(event.sender, line);
    state.mainThread.send(ThreadMessage.Sendline(),
        "PRIVMSG %s :Note added".format(event.channel));

    saveNotes(state.settings.notesFile);
}


// onCommandPrintNotes
/++
 +  Prints saved notes in JSON form to the local terminal.
 +
 +  This is for debugging purposes.
 +/
@Label("printnotes")
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPrefixPolicy.required, "printnotes")
void onCommandPrintNotes()
{
    writeln(notes.toPrettyString);
}


// onCommandReloadQuotes
/++
 +  Reloads quotes from disk, overwriting the in-memory storage.
 +
 +  This is for debugging purposes.
 +/
@Label("reloadnotes")
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPrefixPolicy.required, "reloadnotes")
void onCommandReloadQuotes()
{
    writeln(Foreground.lightcyan, "Reloading notes");
    notes = loadNotes(state.settings.notesFile);
}


// onCommandFakeJoin
/++
 +  Fakes the supplied user joining a channel.
 +
 +  This is for debugging purposes.
 +
 +  Params:
 +      event = the triggering IRCEvent.
 +/
@Label("fakejoin")
@(IRCEvent.Type.CHAN)
@(PrivilegeLevel.master)
@Prefix(NickPrefixPolicy.required, "fakejoin")
void onCommandFakejoin(const IRCEvent event)
{
    import kameloso.stringutils;
    import std.string : indexOf;

    writeln(Foreground.lightcyan, "Faking an event");

    IRCEvent newEvent = event;
    newEvent.type = IRCEvent.Type.JOIN;
    string nickname = event.content;

    if (nickname.indexOf(' ') != -1)
    {
        // contains more than one word
        newEvent.sender = nickname.nom!(Yes.decode)(' ');
    }
    else
    {
        newEvent.sender = event.content;
    }

    writeln(newEvent);
    return onJoin(newEvent);  // or onEvent?
}


// getNotes
/++
 +  Fetches the notes for a specified user, from the in-memory JSON storage.
 +
 +  Params:
 +      nickname = the user whose notes to fetch.
 +
 +  Returns:
 +      a Voldemort Note[] array, where Note is a struct containing a note and
 +      metadata thereof.
 +/
auto getNotes(const string nickname)
{
    import std.datetime : SysTime, Clock;
    import std.json : JSON_TYPE;

    struct Note
    {
        string sender, line;
        SysTime when;
    }

    Note[] noteArray;

    try
    {
        if (notes.isNull)
        {
            // TODO: remove me later but keep for now
            writeln(Foreground.red, "WHY IS NOTES NULL.");
            return noteArray;
        }

        if (const arr = nickname in notes)
        {
            if (arr.type != JSON_TYPE.ARRAY)
            {
                writefln(Foreground.lightred, "Invalid notes list for %s (type is %s)",
                         nickname, arr.type);

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
            writeln(Foreground.lightcyan, "No notes available for nickname ", nickname);
            return noteArray;
        }
    }
    catch (Exception e)
    {
        writeln(Foreground.lightred, "Exception when fetching notes: ", e.msg);
        return noteArray;
    }
}


// clearNotes
/++
 +  Clears the note storage of any notes pertaining to the specified user,
 +  then saves it to disk.
 +
 +  Params:
 +      nickname = the nickname whose notes to clear.
 +/
void clearNotes(const string nickname)
{
    try
    {
        if (nickname in notes)
        {
            writeln(Foreground.lightcyan, "Clearing stored notes for ", nickname);
            notes.object.remove(nickname);
            saveNotes(state.settings.notesFile);
        }
    }
    catch (Exception e)
    {
        writeln(Foreground.lightred, "Exception when clearing notes: ", e.msg);
    }
}


// addNote
/++
 +  Creates a note and saves it in the in-memory JSON storage.
 +
 +  Params:
 +      nickname: the user for whom the note is meant.
 +      sender: the originating user who places the note.
 +      line: the note text.
 +/
void addNote(const string nickname, const string sender, const string line)
{
    import std.datetime : Clock;
    import std.json : JSON_TYPE;

    if (!line.length)
    {
        writeln(Foreground.lightred, "No message to create note from...");
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
        if ((nickname in notes) && (notes[nickname].type == JSON_TYPE.ARRAY))
        {
            notes[nickname].array ~= JSONValue(lineAsAA);
        }
        else
        {
            notes[nickname] = [ lineAsAA ];
        }
    }
    catch (Exception e)
    {
        writeln(Foreground.lightred, "Exception when adding note: ", e.msg);
    }
}


// saveNotes
/++
 +  Saves all notes to disk.
 +
 +  Params:
 +      filename = the filename to save to.
 +/
void saveNotes(const string filename)
{
    import std.file  : exists, isFile, remove;
    import std.stdio : File;

    if (filename.exists && filename.isFile)
    {
        remove(filename); // Wise?
    }

    auto f = File(filename, "a");

    f.write(notes.toPrettyString);
    //f.writeln();
    f.write("\n");
}


// loadNotes
/++
 +  Loads notes from disk into the in-memory storage.
 +
 +  Params:
 +      filename = the filename to read.
 +/
JSONValue loadNotes(const string filename)
{
    import std.file   : exists, isFile, readText;
    import std.json   : parseJSON;
    import std.string : chomp;

    if (!filename.exists)
    {
        writefln(Foreground.white, "%s does not exist", filename);
        JSONValue newJSON;
        newJSON.object = null;
        return newJSON;
    }
    else if (!filename.isFile)
    {
        writefln(Foreground.lightred, "%s is not a file", filename);
        JSONValue newJSON;
        newJSON.object = null;
        return newJSON;
    }

    immutable wholeFile = filename.readText.chomp;
    return parseJSON(wholeFile);
}


// initialise
/++
 +  Initialises the Notes plugin. Loads the notes from disk.
 +
 +  This is executed immediately after a successful connect.
 +/
void initialise()
{
    writeln(Foreground.lightcyan, "Initialising notes ...");
    notes = loadNotes(state.settings.notesFile);
}


mixin BasicEventHandlers;
mixin OnEventImpl!__MODULE__;

public:


// NotesPlugin
/++
 +  The Notes plugin which allows people to leave messages to eachother,
 +  for offline communication and such.
 +/
final class NotesPlugin : IRCPlugin
{
    mixin IRCPluginBasics;
}
