/++
 +  The Notes plugin allows for storing notes to offline users, to be replayed
 +  when they next log in.
 +
 +  It has a few commands:
 +
 +  `note` | `addnote`<br>
 +  `fakejoin`<br>
 +  `fakechan`<br>
 +  `printnotes`<br>
 +  `reloadnotes`<br>
 +
 +  It is vey optional.
 +/
module kameloso.plugins.notes;

version(WithPlugins):

private:

import kameloso.plugins.common;
import kameloso.ircdefs;
import kameloso.common;
import kameloso.messaging;


// NotesSettings
/++
 +  Notes plugin settings.
 +/
struct NotesSettings
{
    /// Toggles whether or not the plugin should react to events at all.
    bool enabled = true;

    /// Whether or not to replay notes when the user joins.
    bool replayOnJoin = true;

    /// Whether or not to replay notes when the bot joins.
    bool replayOnSelfjoin = false;
}


// onReplayEvent
/++
 +  Sends notes queued for a user to a channel when they speak up, or when they
 +  join iff the `NotesSettings.replayOnJoin` setting is set.
 +
 +  Nothing is sent if no notes are stored.
 +/
@(Chainable)
@(IRCEvent.Type.JOIN)
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.EMOTE)
@(PrivilegeLevel.anyone)
@(ChannelPolicy.home)
void onReplayEvent(NotesPlugin plugin, const IRCEvent event)
{
    if (!plugin.notesSettings.enabled) return;

    import kameloso.common : timeSince;
    import std.datetime.systime : Clock;
    import std.format : format;
    import std.json : JSONException;

    if ((event.type == IRCEvent.Type.JOIN) && !plugin.notesSettings.replayOnJoin)
    {
        // It's a JOIN and we shouldn't replay on those
        return;
    }

    try
    {
        const noteArray = plugin.getNotes(event.channel, event.sender.nickname);

        with (plugin.state)
        {
            if (!noteArray.length) return;
            else if (noteArray.length == 1)
            {
                const note = noteArray[0];
                immutable timestamp = (Clock.currTime - note.when).timeSince;

                plugin.chan(event.channel, "%s! %s left note %s ago: %s"
                    .format(event.sender.nickname, note.sender, timestamp, note.line));
            }
            else
            {
                plugin.chan(event.channel, "%s! You have %d notes."
                    .format(event.sender.nickname, noteArray.length));

                foreach (const note; noteArray)
                {
                    import std.typecons : No, Yes;

                    immutable timestamp = (Clock.currTime - note.when)
                        .timeSince!(Yes.abbreviate);

                    plugin.chan(event.channel, "%s %s ago: %s"
                        .format(note.sender, timestamp, note.line));
                }
            }
        }

        plugin.clearNotes(event.sender.nickname, event.channel);
        plugin.notes.save(plugin.notesFile);
    }
    catch (const JSONException e)
    {
        logger.errorf("Could not fetch and/or replay notes for '%s' on '%s': %s",
            event.sender.nickname, event.channel, e.msg);

        if (e.msg == "JSONValue is not an object")
        {
            plugin.notes.reset();
            plugin.notes.save(plugin.notesFile);
        }
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
    if (!plugin.notesSettings.enabled) return;

    import kameloso.irc : stripModesign;
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : canFind;

    if (!plugin.notesSettings.replayOnSelfjoin) return;

    if (!plugin.state.bot.homes.canFind(event.channel)) return;

    if (event.channel !in plugin.notes) return;

    foreach (immutable signed; event.content.splitter)
    {
        immutable nickname = plugin.state.bot.server.stripModesign(signed);
        if (nickname == plugin.state.bot.nickname) continue;

        IRCEvent fakeEvent;

        with (fakeEvent)
        {
            import std.datetime.systime : Clock;

            type = IRCEvent.Type.CHAN;
            sender.nickname = nickname;
            channel = event.channel;
            time = Clock.currTime.toUnixTime;
        }

        plugin.onReplayEvent(fakeEvent);
    }
}


// onCommandAddNote
/++
 +  Adds a note to the in-memory storage, and saves it to disk.
 +/
@(IRCEvent.Type.CHAN)
@(PrivilegeLevel.whitelist)
@(ChannelPolicy.home)
@BotCommand("addnote")
@BotCommand("note")
@BotCommand(NickPolicy.required, "addnote")
@BotCommand(NickPolicy.required, "note")
@Description("Adds a note and saves it to disk.")
void onCommandAddNote(NotesPlugin plugin, const IRCEvent event)
{
    if (!plugin.notesSettings.enabled) return;

    import kameloso.string : contains, nom;
    import std.json : JSONException;
    import std.typecons : No, Yes;

    if (!event.content.contains(" ")) return;

    string slice = event.content;
    immutable nickname = slice.nom!(Yes.decode)(" ");
    immutable line = slice;

    try
    {
        plugin.addNote(nickname, event.sender.nickname, event.channel, line);
        plugin.chan(event.channel, "Note added.");
        plugin.notes.save(plugin.notesFile);
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
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "printnotes")
@Description("[debug] Prints saved notes to the local terminal.")
void onCommandPrintNotes(NotesPlugin plugin)
{
    if (!plugin.notesSettings.enabled) return;

    import std.stdio : stdout, writeln;

    writeln(plugin.notes.toPrettyString);
    version(Cygwin_) stdout.flush();
}


// onCommandReloadQuotes
/++
 +  Reloads quotes from disk, overwriting the in-memory storage.
 +
 +  This is for debugging purposes.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "reloadnotes")
@Description("[debug] Reloads quotes from disk.")
void onCommandReloadQuotes(NotesPlugin plugin)
{
    if (!plugin.notesSettings.enabled) return;

    logger.log("Reloading notes");
    plugin.notes.load(plugin.notesFile);
}


// onCommandFakeJoin
/++
 +  Fakes the supplied user joining a channel.
 +
 +  This is for debugging purposes.
 +/
@(IRCEvent.Type.CHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "fakechan")
@BotCommand(NickPolicy.required, "fakejoin")
@Description("[debug] Fakes a user being active in a channel.")
void onCommandFakejoin(NotesPlugin plugin, const IRCEvent event)
{
    if (!plugin.notesSettings.enabled) return;

    import kameloso.string : contains, nom;
    import std.typecons : No, Yes;

    logger.info("Faking an event");

    IRCEvent newEvent = event;
    newEvent.type = IRCEvent.Type.CHAN;
    string nickname = event.content;

    if (nickname.contains!(Yes.decode)(' '))
    {
        // contains more than one word
        newEvent.sender.nickname = nickname.nom!(Yes.decode)(' ');
    }
    else
    {
        newEvent.sender.nickname = event.content;
    }

    return plugin.onReplayEvent(newEvent);  // or onEvent?
}


// getNotes
/++
 +  Fetches the notes for a specified user, from the in-memory JSON storage.
 +
 +  Params:
 +      plugin = Current `NotesPlugin`.
 +      nickname = Nickname of user whose notes to fetch.
 +
 +  Returns:
 +      a Voldemort `Note[]` array, where `Note` is a struct containing a note
 +      and metadata thereto.
 +/
auto getNotes(NotesPlugin plugin, const string channel, const string nickname)
{
    import std.datetime.systime : SysTime;
    import std.format : format;
    import std.json : JSON_TYPE;

    struct Note
    {
        string sender, line;
        SysTime when;
    }

    Note[] noteArray;

    if (const channelNotes = channel in plugin.notes)
    {
        assert((channelNotes.type == JSON_TYPE.OBJECT),
            "Invalid channel notes list type for %s: %s"
            .format(channel, channelNotes.type));

        if (const nickNotes = nickname in channelNotes.object)
        {
            assert((nickNotes.type == JSON_TYPE.ARRAY),
                "Invalid notes list type for %s on %s: %s"
                .format(nickname, channel, nickNotes.type));

            noteArray.length = nickNotes.array.length;

            foreach (immutable i, note; nickNotes.array)
            {
                noteArray[i].sender = note["sender"].str;
                noteArray[i].line = note["line"].str;
                noteArray[i].when = SysTime.fromUnixTime(note["when"].integer);
            }
        }
    }

    return noteArray;
}


// clearNotes
/++
 +  Clears the note storage of any notes pertaining to the specified user, then
 +  saves it to disk.
 +
 +  Params:
 +      plugins = Current `NotesPlugin`.
 +      nickname = Nickname whose notes to clear.
 +/
void clearNotes(NotesPlugin plugin, const string nickname, const string channel)
{
    import std.file : FileException;
    import std.format : format;
    import std.exception : ErrnoException;
    import std.json : JSONException, JSON_TYPE;

    try
    {
        if (nickname in plugin.notes[channel])
        {
            assert((plugin.notes[channel].type == JSON_TYPE.OBJECT),
                "Invalid channel notes list type for %s: %s"
                .format(channel, plugin.notes[channel].type));

            logger.logf("Clearing stored notes for %s in %s", nickname, channel);
            plugin.notes[channel].object.remove(nickname);
            plugin.pruneNotes();
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


// pruneNotes
/++
 +  Prunes the notes database of empty channel entries.
 +
 +  Individual nickname entries are not touched as they are assumed to be
 +  cleared and removed after replaying its notes.
 +
 +  Params:
 +      plugin = Current `NotesPlugin`.
 +/
void pruneNotes(NotesPlugin plugin)
{
    foreach (immutable channel, channelNotes; plugin.notes.object)
    {
        if (channelNotes.object.length == 0)
        {
            // Dead channel
            plugin.notes.object.remove(channel);
        }
    }
}


// addNote
/++
 +  Creates a note and saves it in the in-memory JSON storage.
 +
 +  Params:
 +      plugin = Current `NotesPlugin`.
 +      nickname = Nickname for whom the note is meant.
 +      sender = Originating user who places the note.
 +      line = Note text.
 +/
void addNote(NotesPlugin plugin, const string nickname, const string sender,
    const string channel, const string line)
{
    import std.datetime.systime : Clock;
    import std.json : JSONValue;

    if (!line.length)
    {
        logger.warning("No message to create note from");
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

    // If there is no channel in the JSON, add it
    if (channel !in plugin.notes)
    {
        plugin.notes[channel] = null;
        plugin.notes[channel].object = null;
    }

    if (nickname !in plugin.notes[channel])
    {
        plugin.notes[channel][nickname] = null;
        plugin.notes[channel][nickname].array = null;
    }

    plugin.notes[channel][nickname].array ~= asJSON;
}


// onEndOfMotd
/++
 +  Initialises the Notes plugin. Loads the notes from disk.
 +/
@(IRCEvent.Type.RPL_ENDOFMOTD)
@(IRCEvent.Type.ERR_NOMOTD)
void onEndOfMotd(NotesPlugin plugin)
{
    if (!plugin.notesSettings.enabled) return;

    plugin.notes.load(plugin.notesFile);
}


// initResources
/++
 +  Ensures that there is a notes file, creating one if there isn't.
 +/
void initResources(NotesPlugin plugin)
{
    import kameloso.json : JSONStorage;

    JSONStorage json;
    json.load(plugin.notesFile);
    json.save(plugin.notesFile);
}


mixin MinimalAuthentication;

public:


// NotesPlugin
/++
 +  The Notes plugin, which allows people to leave messages to eachother,
 +  for offline communication and such.
 +/
final class NotesPlugin : IRCPlugin
{
    import kameloso.json : JSONStorage;

    /// All Notes plugin settings gathered.
    @Settings NotesSettings notesSettings;

    // notes
    /++
    +  The in-memory JSON storage of all stored notes.
    +
    +  It is in the JSON form of `Note[][string][string]`, where the first
    +  string key is a channel and the second a nickname.
    +/
    JSONStorage notes;

    /// Filename of file to save the notes to.
    @Resource string notesFile = "notes.json";

    mixin IRCPluginImpl;
    mixin MessagingProxy;
}
