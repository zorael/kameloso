module kameloso.plugins.notes;

import kameloso.common;
import kameloso.constants;
import kameloso.irc;
import kameloso.plugins.common;

import std.array : Appender;
import std.concurrency : send;
import std.json : JSONValue;
import std.stdio;

private:

struct NotesOptions
{
    string notesFile = "notes.json";
}

/// All Notes plugin options gathered
NotesOptions notesOptions;

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
@(IRCEvent.Type.JOIN)
void onJoin(const IRCEvent event)
{
    import kameloso.stringutils : timeSince;
    import std.datetime : Clock;
    import std.format : format;

    const noteArray = getNotes(event.sender.nickname);

    with (state)
    if (!noteArray.length) return;
    else if (noteArray.length == 1)
    {
        const note = noteArray[0];
        immutable timestamp = (Clock.currTime - note.when).timeSince;

        mainThread.send(ThreadMessage.Sendline(),
            "PRIVMSG %s :%s! %s left note %s ago: %s"
            .format(event.channel, event.sender.nickname, note.sender, timestamp, note.line));
    }
    else
    {
        mainThread.send(ThreadMessage.Sendline(),
            "PRIVMSG %s :%s! You have %d notes."
            .format(event.channel, event.sender.nickname, noteArray.length));

        foreach (const note; noteArray)
        {
            immutable timestamp = (Clock.currTime - note.when).timeSince;

            mainThread.send(ThreadMessage.Sendline(),
                "PRIVMSG %s :%s left note %s ago: %s"
                .format(event.channel, note.sender, timestamp, note.line));
        }
    }

    clearNotes(event.sender.nickname);
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
@(IRCEvent.Type.RPL_NAMREPLY)
void onNames(const IRCEvent event)
{
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : canFind;
    import std.datetime : Clock;

    if (!state.bot.homes.canFind(event.channel)) return;

    foreach (immutable prefixedNickname; event.content.splitter)
    {
        immutable nickname = prefixedNickname.stripModeSign();
        if (nickname == state.bot.nickname) continue;

        IRCEvent fakeEvent;

        with (fakeEvent)
        {
            type = IRCEvent.Type.JOIN;
            sender.nickname = nickname.stripModeSign();
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
    immutable hits = content.formattedRead("%s %s", nickname, line);

    if (hits != 2) return;

    nickname.addNote(event.sender.nickname, line);
    state.mainThread.send(ThreadMessage.Sendline(),
        "PRIVMSG %s :Note added".format(event.channel));

    saveNotes(notesOptions.notesFile);
}


// onCommandPrintNotes
/++
 +  Prints saved notes in JSON form to the local terminal.
 +
 +  This is for debugging purposes.
 +/
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
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPrefixPolicy.required, "reloadnotes")
void onCommandReloadQuotes()
{
    logger.log("Reloading notes");
    notes = loadNotes(notesOptions.notesFile);
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
@(IRCEvent.Type.CHAN)
@(PrivilegeLevel.master)
@Prefix(NickPrefixPolicy.required, "fakejoin")
void onCommandFakejoin(const IRCEvent event)
{
    import kameloso.stringutils;
    import std.string : indexOf;

    logger.info("Faking an event");

    IRCEvent newEvent = event;
    newEvent.type = IRCEvent.Type.JOIN;
    string nickname = event.content;

    if (nickname.indexOf(' ') != -1)
    {
        // contains more than one word
        newEvent.sender.nickname = nickname.nom!(Yes.decode)(' ');
    }
    else
    {
        newEvent.sender.nickname = event.content;
    }

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
    import std.datetime : Clock, SysTime;
    import std.json : JSON_TYPE;

    struct Note
    {
        string sender, line;
        SysTime when;
    }

    Note[] noteArray;

    try
    {
        if (const arr = nickname in notes)
        {
            if (arr.type != JSON_TYPE.ARRAY)
            {
                logger.warningf("Invalid notes list for %s (type is %s)",
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
        }
    }
    catch (const Exception e)
    {
        logger.error(e.msg);
    }

    return noteArray;
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
            logger.log("Clearing stored notes for ", nickname);
            notes.object.remove(nickname);
            saveNotes(notesOptions.notesFile);
        }
    }
    catch (const Exception e)
    {
        logger.error(e.msg);
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
        logger.warning("No message to create note from");
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
    catch (const Exception e)
    {
        logger.error(e.msg);
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
    import std.ascii : newline;
    import std.file  : exists, isFile, remove;

    if (filename.exists && filename.isFile)
    {
        remove(filename); // Wise?
    }

    auto file = File(filename, "a");

    file.write(notes.toPrettyString);
    file.write(newline);
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
        logger.info(filename, " does not exist");
        JSONValue newJSON;
        newJSON.object = null;
        return newJSON;
    }
    else if (!filename.isFile)
    {
        logger.warning(filename, " is not a file");
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
void start()
{
    logger.log("Initialising notes ...");
    notes = loadNotes(notesOptions.notesFile);
}


void loadConfig(const string configFile)
{
    import kameloso.config2 : readConfigInto;
    configFile.readConfigInto(notesOptions);
}


void addToConfig(ref Appender!string sink)
{
    import kameloso.config2 : serialise;
    sink.serialise(notesOptions);
}


/*void present()
{
    printObject(notesOptions);
}*/


public:

mixin BasicEventHandlers;
mixin OnEventImpl;


// NotesPlugin
/++
 +  The Notes plugin which allows people to leave messages to eachother,
 +  for offline communication and such.
 +/
final class NotesPlugin : IRCPlugin
{
    mixin IRCPluginBasics;
}
