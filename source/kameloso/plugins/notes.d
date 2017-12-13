module kameloso.plugins.notes;

import kameloso.plugins.common;
import kameloso.ircdefs;
import kameloso.common;

import std.concurrency : send;
import std.json : JSONValue;

import std.stdio;

private:

/++
 +  Notes plugin settings.
 +
 +  ------------
 +  struct NotesSettings
 +  {
 +      string notesFile = "notes.json";
 +  }
 +  ------------
 +/
struct NotesSettings
{
    string notesFile = "notes.json";
}


// onJoin
/++
 +  Sends notes to a channel upon someone joining.
 +
 +  Nothing is sent if no notes are stored.
 +/
@(IRCEvent.Type.JOIN)
void onJoin(NotesPlugin plugin, const IRCEvent event)
{
    import kameloso.string : timeSince;
    import std.datetime : Clock;
    import std.format : format;
    import std.json : JSONException;

    try
    {
        const noteArray = plugin.getNotes(event.sender.nickname);

        with (plugin.state)
        {
            if (!noteArray.length) return;
            else if (noteArray.length == 1)
            {
                const note = noteArray[0];
                immutable timestamp = (Clock.currTime - note.when).timeSince;

                mainThread.send(ThreadMessage.Sendline(),
                    "PRIVMSG %s :%s! %s left note %s ago: %s"
                    .format(event.channel, event.sender.nickname, note.sender,
                        timestamp, note.line));
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
        }

        plugin.clearNotes(event.sender.nickname);
    }
    catch (const JSONException e)
    {
        logger.errorf("Could not fetch and/or replay notes for '%s': %s",
            event.sender.nickname, e.msg);
    }
}


// onNames
/++
 +  Sends notes to a channel upon joining it.
 +
 +  Only reacting to others joining would mean someone never leaving would never
 +  get notes. This may be extended to trigger when they say something, too.
 +/
@(IRCEvent.Type.RPL_NAMREPLY)
void onNames(NotesPlugin plugin, const IRCEvent event)
{
    import kameloso.irc : stripModeSign;
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : canFind;
    import std.datetime : Clock;

    if (!plugin.state.bot.homes.canFind(event.channel)) return;

    foreach (immutable prefixedNickname; event.content.splitter)
    {
        immutable nickname = prefixedNickname.stripModeSign();
        if (nickname == plugin.state.bot.nickname) continue;

        IRCEvent fakeEvent;

        with (fakeEvent)
        {
            type = IRCEvent.Type.JOIN;
            sender.nickname = nickname.stripModeSign();
            channel = event.channel;
            time = Clock.currTime.toUnixTime;
        }

        plugin.onJoin(fakeEvent);
    }
}


// onCommandAddNote
/++
 +  Adds a note to the in-memory storage, and saves it to disk.
 +/
@(IRCEvent.Type.CHAN)
@(PrivilegeLevel.friend)
@Prefix("note")
@Prefix(NickPolicy.required, "addnote")
@Prefix(NickPolicy.required, "note")
void onCommandAddNote(NotesPlugin plugin, const IRCEvent event)
{
    import std.format : format, formattedRead;
    import std.json : JSONException;

    string nickname, line;
    // formattedRead advances a slice so we need a mutable copy of event.content
    string content = event.content;
    immutable hits = content.formattedRead("%s %s", nickname, line);

    if (hits != 2) return;

    try
    {
        plugin.addNote(nickname, event.sender.nickname, line);
        plugin.state.mainThread.send(ThreadMessage.Sendline(),
            "PRIVMSG %s :Note added".format(event.channel));

        plugin.saveNotes(plugin.notesSettings.notesFile);
    }
    catch (const JSONException e)
    {
        logger.error("Failed to add note: ", e.msg);
    }
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
@Prefix(NickPolicy.required, "printnotes")
void onCommandPrintNotes(NotesPlugin plugin)
{
    writeln(plugin.notes.toPrettyString);
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
@Prefix(NickPolicy.required, "reloadnotes")
void onCommandReloadQuotes(NotesPlugin plugin)
{
    logger.log("Reloading notes");
    plugin.notes = loadNotes(plugin.notesSettings.notesFile);
}


// onCommandFakeJoin
/++
 +  Fakes the supplied user joining a channel.
 +
 +  This is for debugging purposes.
 +/
@(IRCEvent.Type.CHAN)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "fakejoin")
void onCommandFakejoin(NotesPlugin plugin, const IRCEvent event)
{
    import kameloso.string : nom;
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

    return plugin.onJoin(newEvent);  // or onEvent?
}


// getNotes
/++
 +  Fetches the notes for a specified user, from the in-memory JSON storage.
 +
 +  Params:
 +      nickname = the user whose notes to fetch.
 +
 +  Returns:
 +      a Voldemort `Note[]` array, where `Note` is a struct containing a note
 +      and metadata thereof.
 +/
auto getNotes(NotesPlugin plugin, const string nickname)
{
    import std.datetime.systime : SysTime;
    import std.json : JSON_TYPE;

    struct Note
    {
        string sender, line;
        SysTime when;
    }

    Note[] noteArray;

    if (const arr = nickname in plugin.notes)
    {
        if (arr.type != JSON_TYPE.ARRAY)
        {
            logger.warningf("Invalid notes list for %s (type is %s)",
                        nickname, arr.type);

            plugin.clearNotes(nickname);

            return noteArray;
        }

        noteArray.length = arr.array.length;

        foreach (i, note; arr.array)
        {
            noteArray[i].sender = note["sender"].str;
            noteArray[i].line = note["line"].str;
            noteArray[i].when = SysTime.fromUnixTime(note["when"].integer);
        }
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
void clearNotes(NotesPlugin plugin, const string nickname)
{
    import std.file : FileException;
    import std.exception : ErrnoException;
    import std.json : JSONException;

    try
    {
        if (nickname in plugin.notes)
        {
            logger.log("Clearing stored notes for ", nickname);
            plugin.notes.object.remove(nickname);
            plugin.saveNotes(plugin.notesSettings.notesFile);
        }
    }
    catch (const JSONException e)
    {
        logger.error("Failed to clear notes: ", e.msg);
    }
    catch (const FileException e)
    {
        logger.error("Failed to save notes: ", e.msg);
    }
    catch (const ErrnoException e)
    {
        logger.error("Failed to open/close notes file: ", e.msg);
    }
}


// addNote
/++
 +  Creates a note and saves it in the in-memory JSON storage.
 +
 +  Params:
 +      nickname = the user for whom the note is meant.
 +      sender = the originating user who places the note.
 +      line = the note text.
 +/
void addNote(NotesPlugin plugin, const string nickname, const string sender,
    const string line)
{
    import std.datetime.systime : Clock;
    import std.json : JSON_TYPE;

    if (!line.length)
    {
        logger.error("No message to create note from");
        return;
    }

    // "when" is long so can't construct a single AA and assign it in one go
    // (it wouldn't be string[string] then)
    auto senderAndLine =
    [
        "sender" : sender,
        "line"   : line,
        //"when" : Clock.currTime.toUnixTime,
    ];

    auto asJSON = JSONValue(senderAndLine);
    asJSON["when"] = Clock.currTime.toUnixTime;  // workaround to the above

    auto nicknote = nickname in plugin.notes;

    if (nicknote && ((*nicknote).type == JSON_TYPE.ARRAY))
    {
        plugin.notes[nickname].array ~= asJSON;
    }
    else
    {
        plugin.notes[nickname] = [ asJSON ];
    }
}


// saveNotes
/++
 +  Saves all notes to disk.
 +
 +  Params:
 +      filename = the filename to save to.
 +/
void saveNotes(NotesPlugin plugin, const string filename)
{
    import std.ascii : newline;
    import std.file  : exists, isFile;

    auto file = File(filename, "w");

    file.write(plugin.notes.toPrettyString);
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

    if (!filename.exists || !filename.isFile)
    {
        //logger.info(filename, " does not exist or is not a file!");
        JSONValue newJSON;
        newJSON.object = null;
        return newJSON;
    }

    immutable wholeFile = readText(filename);
    return parseJSON(wholeFile);
}


// onEndOfMotd
/++
 +  Initialises the Notes plugin. Loads the notes from disk.
 +/
@(IRCEvent.Type.RPL_ENDOFMOTD)
void onEndOfMotd(NotesPlugin plugin)
{
    plugin.notes = loadNotes(plugin.notesSettings.notesFile);
}


mixin BasicEventHandlers;

public:


// NotesPlugin
/++
 +  The Notes plugin, which allows people to leave messages to eachother,
 +  for offline communication and such.
 +/
final class NotesPlugin : IRCPlugin
{
    /// All Notes plugin settings gathered
    @Settings NotesSettings notesSettings;

    // notes
    /++
    +  The in-memory JSON storage of all stored notes.
    +
    +  It is in the JSON form of `string[][string]`, where the first key is
    +  a nickname.
    +/
    JSONValue notes;

    mixin IRCPluginImpl;
}
