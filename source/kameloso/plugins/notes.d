/++
    The Notes plugin allows for storing notes to offline users, to be replayed
    when they next join the channel.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#notes
        [kameloso.plugins.common.core|plugins.common.core]
        [kameloso.plugins.common.misc|plugins.common.misc]
 +/
module kameloso.plugins.notes;

version(WithNotesPlugin):

private:

import kameloso.plugins.common.core;
import kameloso.plugins.common.awareness : MinimalAuthentication;
import kameloso.common : logger;
import kameloso.messaging;
import dialect.defs;
import std.typecons : Flag, No, Yes;


version(WithChanQueriesService) {}
else
{
    pragma(msg, "Warning: The `Notes` plugin will work but not well without the `ChanQueries` service.");
}


// NotesSettings
/++
    Notes plugin settings.
 +/
@Settings struct NotesSettings
{
    /// Toggles whether or not the plugin should react to events at all.
    @Enabler bool enabled = true;
}


// onReplayEvent
/++
    Plays back notes upon someone joining or upon someone authenticating with services.

    There's no need to trigger each `CHAN` since we know we enumerate all
    users in a channel when querying `WHO` -- except on Twitch, where there
    is no `WHO`, no `ACCOUNT`, and where we can't trust `JOIN`.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.JOIN)
    .onEvent(IRCEvent.Type.ACCOUNT)
    .permissionsRequired(Permissions.anyone)
    .channelPolicy(ChannelPolicy.home)
)
void onReplayEvent(NotesPlugin plugin, const /*ref*/ IRCEvent event)
{
    version(TwitchSupport)
    {
        if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
        {
            // We can't really rely on JOINs on Twitch
            return;
        }
    }

    if (event.channel !in plugin.notes) return;

    return plugin.playbackNotes(event.sender, event.channel);
}


// onTwitchChannelEvent
/++
    Plays back notes upon someone speaking in a channel.

    This is the only good way we can detect participants on Twitch.
 +/
version(TwitchSupport)
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.EMOTE)
    .onEvent(IRCEvent.Type.TWITCH_SUB)
    .onEvent(IRCEvent.Type.TWITCH_SUBGIFT)
    .onEvent(IRCEvent.Type.TWITCH_CHEER)
    .onEvent(IRCEvent.Type.TWITCH_REWARDGIFT)
    .onEvent(IRCEvent.Type.TWITCH_GIFTCHAIN)
    .onEvent(IRCEvent.Type.TWITCH_BULKGIFT)
    .onEvent(IRCEvent.Type.TWITCH_SUBUPGRADE)
    .onEvent(IRCEvent.Type.TWITCH_CHARITY)
    .onEvent(IRCEvent.Type.TWITCH_BITSBADGETIER)
    .onEvent(IRCEvent.Type.TWITCH_RITUAL)
    .onEvent(IRCEvent.Type.TWITCH_EXTENDSUB)
    .onEvent(IRCEvent.Type.TWITCH_GIFTRECEIVED)
    .onEvent(IRCEvent.Type.TWITCH_PAYFORWARD)
    .onEvent(IRCEvent.Type.TWITCH_RAID)
    .permissionsRequired(Permissions.ignore)
    .channelPolicy(ChannelPolicy.home)
    .chainable(true)
)
void onTwitchChannelEvent(NotesPlugin plugin, const /*ref*/ IRCEvent event)
{
    if (plugin.state.server.daemon != IRCServer.Daemon.twitch)
    {
        // Only do stuff on Twitch
        return;
    }

    if (event.channel !in plugin.notes) return;

    return plugin.playbackNotes(event.sender, event.channel);
}


// onWhoReply
/++
    Plays back notes upon replies of a WHO query.

    These carry a sender, so it's possible we know the account without lookups.

    Do nothing if
    [kameloso.kameloso.CoreSettings.eagerLookups|CoreSettings.eagerLookups] is true,
    as we'd collide with ChanQueries' queries.

    Pass `Yes.background` to [playbackNotes] to ensure it does low-priority background
    WHOIS queries.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WHOREPLY)
    .channelPolicy(ChannelPolicy.home)
)
void onWhoReply(NotesPlugin plugin, const /*ref*/ IRCEvent event)
{
    if (plugin.state.settings.eagerLookups) return;

    if (event.channel !in plugin.notes) return;

    return plugin.playbackNotes(event.target, event.channel, Yes.background);
}


// playbackNotes
/++
    Sends notes queued for a user to a channel when they join or show activity.
    Private notes are also sent, when some exist.

    Nothing is sent if no notes are stored.

    Params:
        plugin = The current [NotesPlugin].
        givenUser = The [dialect.defs.IRCUser|IRCUser] for whom we want to replay notes.
        givenChannel = Name of the channel we want the notes related to.
        background = Whether or not to issue WHOIS queries as low-priority background messages.
 +/
void playbackNotes(
    NotesPlugin plugin,
    const IRCUser givenUser,
    const string givenChannel,
    const Flag!"background" background = No.background)
{
    import kameloso.time : timeSince;
    import dialect.common : toLowerCase;
    import std.datetime.systime : Clock;
    import std.exception : ErrnoException;
    import std.file : FileException;
    import std.format : format;
    import std.json : JSONException;
    import std.range : only;

    if (givenUser.nickname == plugin.state.client.nickname) return;

    version(TwitchSupport)
    {
        // On Twitch, prepend the nickname a message is aimed towards with a @
        // Make it a string "@" so the alternative can be string.init (and not char.init)
        immutable atSign = (plugin.state.server.daemon == IRCServer.Daemon.twitch) ?
            "@" : string.init;
    }
    else
    {
        enum atSign = string.init;
    }

    uint i;

    foreach (immutable channelName; only(givenChannel, string.init))
    {
        void onSuccess(const IRCUser user)
        {
            import kameloso.plugins.common.misc : idOf, nameOf;

            immutable id = user.nickname.toLowerCase(plugin.state.server.caseMapping);

            try
            {
                const noteArray = plugin.getNotes(channelName, id);

                if (!noteArray.length) return;

                immutable senderName = nameOf(user);
                immutable currTime = Clock.currTime;

                if (noteArray.length == 1)
                {
                    const note = noteArray[0];
                    immutable timestamp = (currTime - note.when).timeSince!(7, 1)(No.abbreviate);

                    enum pattern = "%s<h>%s<h>! <h>%s<h> left note <b>%s<b> ago: %s";
                    immutable message = pattern.format(atSign, senderName, note.sender, timestamp, note.line);
                    privmsg(plugin.state, channelName, user.nickname, message);
                }
                else
                {
                    enum pattern = "%s<h>%s<h>! You have <b>%d<b> notes.";
                    immutable message = pattern.format(atSign, senderName, noteArray.length);
                    privmsg(plugin.state, channelName, user.nickname, message);

                    foreach (const note; noteArray)
                    {
                        immutable timestamp = (currTime - note.when).timeSince!(7, 1)(Yes.abbreviate);

                        enum entryPattern = "<h>%s<h> %s ago: %s";
                        immutable report = entryPattern.format(note.sender, timestamp, note.line);
                        privmsg(plugin.state, channelName, user.nickname, report);
                    }
                }

                plugin.clearNotes(id, channelName);
                plugin.notes.save(plugin.notesFile);
            }
            catch (JSONException e)
            {
                enum pattern = "Failed to fetch, replay and clear notes for " ~
                    "<l>%s</> on <l>%s</>: <l>%s";
                logger.errorf(pattern, id,
                    (channelName.length ? channelName : "<no channel>"), e.msg);

                if (e.msg == "JSONValue is not an object")
                {
                    logger.warning("Notes file corrupt. Starting from scratch.");
                    plugin.notes.reset();
                    plugin.notes.save(plugin.notesFile);
                }

                version(PrintStacktraces) logger.trace(e.info);
            }
            catch (FileException e)
            {
                enum pattern = "Failed to save notes: <l>%s";
                logger.errorf(pattern, e.msg);
                version(PrintStacktraces) logger.trace(e.info);
            }
            catch (ErrnoException e)
            {
                enum pattern = "Failed to open/close notes file: <l>%s";
                logger.errorf(pattern, e.msg);
                version(PrintStacktraces) logger.trace(e.info);
            }
        }

        void onFailure(const IRCUser failureUser)
        {
            //logger.trace("(Assuming unauthenticated nickname or offline account was specified)");
            return onSuccess(failureUser);
        }

        // Functionally the same as the block below, since everyone has accounts on Twitch
        /*version(TwitchSupport)
        {
            if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
            {
                onSuccess(givenUser);
                continue;
            }
        }*/

        if (givenUser.account.length)
        {
            onSuccess(givenUser);
            continue;
        }

        import kameloso.plugins.common.mixins : WHOISFiberDelegate;

        // Silence warnings about no UserAwareness by passing Yes.alwaysLookup
        // (it will always look up anyway because of only MinimalAuthentication)
        // Rely on PesistenceService for account names.
        mixin WHOISFiberDelegate!(onSuccess, onFailure, Yes.alwaysLookup);

        // Only WHOIS once
        enqueueAndWHOIS(givenUser.nickname, cast(Flag!"issueWhois")(i++ == 0), background);

        // Break early if givenChannel was empty, and save us a loop and a lookup
        if (!channelName.length) break;
    }
}


// onCommandAddNote
/++
    Adds a note to the in-memory storage, and saves it to disk.

    Messages sent in a channel will become messages for the target user in that
    channel. Those sent in a private query will be private notes, sent privately
    in the same fashion as channel notes are sent publicly.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.anyone)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("note")
            .policy(PrefixPolicy.prefixed)
            .description("Adds a note to send to an offline person when they come online, " ~
                "or when they show activity if already online.")
            .addSyntax("$command [nickname] [note text...]")
    )
)
void onCommandAddNote(NotesPlugin plugin, const ref IRCEvent event)
{
    import kameloso.plugins.common.misc : nameOf;
    import dialect.common : opEqualsCaseInsensitive, toLowerCase;
    import lu.string : SplitResults, beginsWith, splitInto;
    import std.format : format;
    import std.json : JSONException;
    import std.typecons : No, Yes;

    string slice = event.content;  // mutable
    string target;

    immutable results = slice.splitInto(target);
    if (target.beginsWith('@')) target = target[1..$];

    if ((results != SplitResults.overrun) || !target.length)
    {
        enum pattern = "Usage: <b>%s%s<b> [nickname] [note text...]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
        return privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }

    if (target.opEqualsCaseInsensitive(plugin.state.client.nickname, plugin.state.server.caseMapping))
    {
        return privmsg(plugin.state, event.channel, event.sender.nickname,
            "You cannot leave the bot a message; it would never be replayed.");
    }

    target = target.toLowerCase(plugin.state.server.caseMapping);

    try
    {
        plugin.addNote(target, nameOf(event.sender), event.channel, slice);
        privmsg(plugin.state, event.channel, event.sender.nickname, "Note added.");
        plugin.notes.save(plugin.notesFile);
    }
    catch (JSONException e)
    {
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "Failed to add note; " ~ e.msg);
        /*enum pattern = "Failed to add note: <l>%s";
        logger.errorf(pattern, e.msg);*/
        version(PrintStacktraces) logger.trace(e.info);
    }
}


// reload
/++
    Reloads notes from disk.
 +/
void reload(NotesPlugin plugin)
{
    plugin.notes.load(plugin.notesFile);
}


// getNotes
/++
    Fetches the notes for a specified user, from the in-memory JSON storage.

    Params:
        plugin = Current [NotesPlugin].
        channel = Channel for which the notes were stored.
        id = Nickname or account of user whose notes to fetch.

    Returns:
        A Voldemort `Note[]` array, where `Note` is a struct containing a note
        and metadata thereto.
 +/
auto getNotes(NotesPlugin plugin, const string channel, const string id)
{
    import lu.string : decode64;
    import std.datetime.systime : SysTime;
    import std.format : format;
    import std.json : JSONType;

    static struct Note
    {
        string sender, line;
        SysTime when;
    }

    Note[] noteArray;

    if (const channelNotesJSON = channel in plugin.notes)
    {
        if (channelNotesJSON.type != JSONType.object)
        {
            enum pattern = "Invalid channel notes list type for <l>%s</>: `<l>%s</>`";
            logger.errorf(pattern, channel, channelNotesJSON.type);
        }
        else if (const nickNotes = id in channelNotesJSON.object)
        {
            if (nickNotes.type != JSONType.array)
            {
                enum pattern = "Invalid notes list type for <l>%s</> on <l>%s</>: `<l>%s</>`";
                logger.errorf(pattern, id, channel, nickNotes.type);
                return noteArray;
            }

            noteArray.length = nickNotes.array.length;

            foreach (immutable i, noteJSON; nickNotes.array)
            {
                import std.base64 : Base64Exception;
                noteArray[i].sender = noteJSON["sender"].str;
                noteArray[i].when = SysTime.fromUnixTime(noteJSON["when"].integer);

                try
                {
                    noteArray[i].line = decode64(noteJSON["line"].str);
                }
                catch (Base64Exception e)
                {
                    noteArray[i].line = "(An error occurred and the note could not be read)";
                    version(PrintStacktraces) logger.trace(e);
                }
            }
        }
    }

    return noteArray;
}


// clearNotes
/++
    Clears the note storage of any notes pertaining to the specified user, then
    saves it to disk.

    Params:
        plugin = Current [NotesPlugin].
        id = Nickname or account whose notes to clear.
        channel = Channel for which the notes were stored.
 +/
void clearNotes(NotesPlugin plugin, const string id, const string channel)
in (id.length, "Tried to clear notes for an empty id")
//in (channel.length, "Tried to clear notes with an empty channel string")
{
    import std.json : JSONType;

    if (id in plugin.notes[channel])
    {
        if (plugin.notes[channel].type != JSONType.object)
        {
            enum pattern = "Invalid channel notes list type for <l>%s</>: `<l>%s</>`";
            return logger.errorf(pattern, channel, plugin.notes[channel].type);
        }

        plugin.notes[channel].object.remove(id);
        plugin.pruneNotes();
    }
}


// pruneNotes
/++
    Prunes the notes database of empty channel entries.

    Individual nickname entries are not touched as they are assumed to be
    cleared and removed after replaying its notes.

    Params:
        plugin = Current [NotesPlugin].
 +/
void pruneNotes(NotesPlugin plugin)
{
    string[] garbageKeys;

    foreach (immutable channelName, channelNotesJSON; plugin.notes.object)
    {
        if (!channelNotesJSON.object.length)
        {
            // Dead channel
            garbageKeys ~= channelName;
        }
    }

    foreach (immutable key; garbageKeys)
    {
        plugin.notes.object.remove(key);
    }
}


// addNote
/++
    Creates a note and saves it in the in-memory JSON storage.

    Params:
        plugin = Current [NotesPlugin].
        id = Identifier (nickname/account) for whom the note is meant.
        sender = Originating user who places the note.
        channel = Channel for which we should save the note.
        line = Note text.
 +/
void addNote(
    NotesPlugin plugin,
    const string id,
    const string sender,
    const string channel,
    const string line)
in (id.length, "Tried to add a note for an empty id")
in (sender.length, "Tried to add a note from an empty sender")
//in (channel.length, "Tried to add a note with an empty channel")
in (line.length, "Tried to add an empty note")
{
    import lu.string : encode64;
    import std.datetime.systime : Clock;
    import std.json : JSONValue;

    if (!line.length)
    {
        return logger.warning("No message to create note from.");
    }

    // "when" is long so can't construct a single AA and assign it in one go
    // (it wouldn't be string[string] then)
    auto senderAndLine =
    [
        "sender" : sender,
        "line"   : encode64(line),
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

    if (id !in plugin.notes[channel])
    {
        plugin.notes[channel][id] = null;
        plugin.notes[channel][id].array = null;
    }

    plugin.notes[channel][id].array ~= asJSON;
}


// onWelcome
/++
    Initialises the Notes plugin. Loads the notes from disk.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WELCOME)
)
void onWelcome(NotesPlugin plugin)
{
    plugin.reload();
}


// initResources
/++
    Ensures that there is a notes file, creating one if there isn't.
 +/
void initResources(NotesPlugin plugin)
{
    import lu.json : JSONStorage;
    import std.json : JSONException;

    JSONStorage json;

    try
    {
        json.load(plugin.notesFile);
    }
    catch (JSONException e)
    {
        import kameloso.plugins.common.misc : IRCPluginInitialisationException;

        version(PrintStacktraces) logger.trace(e);
        throw new IRCPluginInitialisationException(
            "Notes file is malformed",
            plugin.name,
            plugin.notesFile,
            __FILE__,
            __LINE__);
    }

    // Let other Exceptions pass.

    json.save(plugin.notesFile);
}


mixin MinimalAuthentication;

public:


// NotesPlugin
/++
    The Notes plugin, which allows people to leave messages to each other,
    for offline communication and such.
 +/
@IRCPluginHook
final class NotesPlugin : IRCPlugin
{
private:
    import lu.json : JSONStorage;

    /// All Notes plugin settings gathered.
    NotesSettings notesSettings;

    // notes
    /++
        The in-memory JSON storage of all stored notes.

        It is in the JSON form of `Note[][string][string]`, where the first
        string key is a channel and the second a nickname.
     +/
    JSONStorage notes;

    /// Filename of file to save the notes to.
    @Resource string notesFile = "notes.json";

    mixin IRCPluginImpl;
}
