/++
    The Notes plugin allows for storing notes to offline users, to be replayed
    when they next join the channel.

    If a note is left in a channel, it is stored as a note under that channel
    and will be played back when the user joins (or optionally shows activity) there.
    If a note is left in a private message, it is stored as outside of a channel
    and will be played back in a private query, depending on the same triggers
    as those of channel notes.

    Activity in one channel will not play back notes left for another channel,
    but anything will trigger private message playback.

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

mixin MinimalAuthentication;
mixin PluginRegistration!NotesPlugin;


// NotesSettings
/++
    Notes plugin settings.
 +/
@Settings struct NotesSettings
{
    /++
        Toggles whether or not the plugin should react to events at all.
     +/
    @Enabler bool enabled = true;

    /++
        Toggles whether or not notes get played back on activity, and not just
        on [dialect.defs.IRCEvent.Type.JOIN|JOIN]s and
        [dialect.defs.IRCEvent.Type.ACCOUNT|ACCOUNT]s.

        Ignored on Twitch servers.
     +/
    bool playBackOnAnyActivity = true;
}


// Note
/++
    Embodies the notion of a note, left for an offline user.
 +/
struct Note
{
private:
    import std.json : JSONValue;

public:
    /++
        Line of text left as a note, optionally Base64-encoded.
     +/
    string line;

    /++
        String name of the sender, optionally Base64-encoded. May be a display name.
     +/
    string sender;

    /++
        UNIX timestamp of when the note was left.
     +/
    long timestamp;

    /++
        Encrypts the note, Base64-encoding [line] and [sender].
     +/
    void encrypt()
    {
        import lu.string : encode64;
        line = encode64(line);
        sender = encode64(sender);
    }

    /++
        Decrypts the note, Base64-decoding [line] and [sender].
     +/
    void decrypt()
    {
        import lu.string : decode64;
        line = decode64(line);
        sender = decode64(sender);
    }

    /++
        Converts this [Note] into a JSON representation.

        Returns:
            A [std.json.JSONValue|JSONValue] that describes this [Note].
     +/
    auto toJSON() const
    {
        JSONValue json;
        json["line"] = JSONValue(this.line);
        json["sender"] = JSONValue(this.sender);
        json["timestamp"] = JSONValue(this.timestamp);
        return json;
    }

    /++
        Creates a [Note] from a JSON representation.

        Params:
            json = [std.json.JSONValue|JSONValue] to build a [Note] from.
     +/
    static auto fromJSON(const JSONValue json)
    {
        Note note;
        note.line = json["line"].str;
        note.sender = json["sender"].str;
        note.timestamp = json["timestamp"].integer;
        return note;
    }
}


// onJoinOrAccount
/++
    Plays back notes upon someone joining or upon someone authenticating with services.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.JOIN)
    .onEvent(IRCEvent.Type.ACCOUNT)
    .permissionsRequired(Permissions.anyone)
    .channelPolicy(ChannelPolicy.home)
)
void onJoinOrAccount(NotesPlugin plugin, const ref IRCEvent event)
{
    version(TwitchSupport)
    {
        if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
        {
            // We can't really rely on JOINs on Twitch and ACCOUNTs don't happen
            return;
        }
    }

    playbackNotes(plugin, event);
}


// onChannelMessage
/++
    Plays back notes upon someone saying something in the channel, provided
    [NotesSettings.playBackOnAnyActivity] is set.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.EMOTE)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.anyone)
    .channelPolicy(ChannelPolicy.home)
    .chainable(true)
)
void onChannelMessage(NotesPlugin plugin, const ref IRCEvent event)
{
    if (plugin.notesSettings.playBackOnAnyActivity ||
        (plugin.state.server.daemon == IRCServer.Daemon.twitch))
    {
        playbackNotes(plugin, event);
    }
}


// onTwitchChannelEvent
/++
    Plays back notes upon someone performing a Twitch-specific action.
 +/
version(TwitchSupport)
@(IRCEventHandler()
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
    .onEvent(IRCEvent.Type.TWITCH_CROWDCHANT)
    .onEvent(IRCEvent.Type.TWITCH_ANNOUNCEMENT)
    .onEvent(IRCEvent.Type.TWITCH_DIRECTCHEER)
    .permissionsRequired(Permissions.ignore)
    .channelPolicy(ChannelPolicy.home)
    .chainable(true)
)
void onTwitchChannelEvent(NotesPlugin plugin, const ref IRCEvent event)
{
    // No need to check whether we're on Twitch
    playbackNotes(plugin, event);
}


// onWhoReply
/++
    Plays back notes upon replies of a WHO query.

    These carry a sender, so it's possible we know the account without lookups.

    Do nothing if
    [kameloso.pods.CoreSettings.eagerLookups|CoreSettings.eagerLookups] is true,
    as we'd collide with ChanQueries' queries.

    Passes `Yes.background` to [playbackNotes] to ensure it does low-priority
    background WHOIS queries.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WHOREPLY)
    .channelPolicy(ChannelPolicy.home)
)
void onWhoReply(NotesPlugin plugin, const ref IRCEvent event)
{
    if (plugin.state.settings.eagerLookups) return;

    playbackNotes(plugin, event, Yes.background);
}


// playbackNotes
/++
    Plays back notes. The target is assumed to be the sender of the
    [dialect.defs.IRCEvent|IRCEvent] passed.

    If the [dialect.defs.IRCEvent|IRCEvent] contains a channel, then playback
    of both channel and private message notes will be performed. If the channel
    member is empty, only private message ones.

    Params:
        plugin = The current [NotesPlugin].
        event = The triggering [dialect.defs.IRCEvent|IRCEvent].
        background = Whether or not to issue WHOIS queries as low-priority background messages.
 +/
void playbackNotes(
    NotesPlugin plugin,
    const /*ref*/ IRCEvent event,
    const Flag!"background" background = No.background)
{
    const user = event.sender.nickname.length ?
        event.sender :
        event.target;  // on RPL_WHOREPLY

    if (!user.nickname.length)
    {
        // Despite everything we don't have a user. Bad annotations on calling event handler?
        return;
    }

    if (event.channel.length)
    {
        import std.range : only;

        // Try both channel and private message notes
        foreach (immutable wouldBeChannel; only(event.channel, string.init))
        {
            playbackNotesImpl(plugin, wouldBeChannel, user, background);
        }
    }
    else
    {
        // Only private message relevant
        playbackNotesImpl(plugin, string.init, user, background);
    }
}


// playbackNotesImpl
/++
    Plays back notes. Implementation function.

    Params:
        plugin = The current [NotesPlugin].
        channelName = The name of the channel in which the playback is to take place,
            or an empty string if it's supposed to take place in a private message.
        user = [dialect.defs.IRCUser|IRCUser] to replay notes for.
        background = Whether or not to issue WHOIS queries as low-priority background messages.
 +/
void playbackNotesImpl(
    NotesPlugin plugin,
    const string channelName,
    const IRCUser user,
    const Flag!"background" background)
{
    import kameloso.plugins.common.mixins : WHOISFiberDelegate;
    import std.format : format;

    auto channelNotes = channelName in plugin.notes;
    if (!channelNotes) return;

    void onSuccess(const IRCUser user)
    {
        import std.range : only;

        foreach (immutable id; only(user.nickname, user.account))
        {
            import kameloso.plugins.common.misc : nameOf;
            import kameloso.time : timeSince;
            import std.datetime.systime : Clock, SysTime;

            auto notes = id in *channelNotes;
            if (!notes || !notes.length) continue;

            immutable maybeDisplayName = nameOf(user);
            immutable nowInUnix = Clock.currTime;

            if (notes.length == 1)
            {
                auto note = (*notes)[0];  // mutable
                immutable timestampAsSysTime = SysTime.fromUnixTime(note.timestamp);
                immutable duration = (nowInUnix - timestampAsSysTime).timeSince!(7, 1)(No.abbreviate);

                note.decrypt();
                enum pattern = "<h>%s<h>! <h>%s<h> left note <b>%s<b> ago: %s";
                immutable message = pattern.format(maybeDisplayName, note.sender, duration, note.line);
                privmsg(plugin.state, channelName, user.nickname, message);
            }
            else /*if (notes.length > 1)*/
            {
                enum pattern = "<h>%s<h>! You have <b>%d<b> notes.";
                immutable message = pattern.format(maybeDisplayName, notes.length);
                privmsg(plugin.state, channelName, user.nickname, message);

                foreach (/*const*/ note; *notes)
                {
                    immutable timestampAsSysTime = SysTime.fromUnixTime(note.timestamp);
                    immutable duration = (nowInUnix - timestampAsSysTime).timeSince!(7, 1)(Yes.abbreviate);

                    note.decrypt();
                    enum entryPattern = "<h>%s<h> %s ago: %s";
                    immutable report = entryPattern.format(note.sender, duration, note.line);
                    privmsg(plugin.state, channelName, user.nickname, report);
                }
            }

            (*channelNotes).remove(id);
            if (!channelNotes.length) plugin.notes.remove(channelName);

            // Don't run the loop twice if the nickname and the account is the same
            if (user.nickname == user.account) break;
        }

        plugin.saveNotes();
    }

    void onFailure(const IRCUser user)
    {
        // Merely failed to resolve an account, proceed with success branch
        return onSuccess(user);
    }

    if (user.account.length)
    {
        return onSuccess(user);
    }

    mixin WHOISFiberDelegate!(onSuccess, onFailure, Yes.alwaysLookup);

    enqueueAndWHOIS(user.nickname, Yes.issueWhois, background);
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
            .addSyntax("$command [nickname] [note text]")
    )
)
void onCommandAddNote(NotesPlugin plugin, const ref IRCEvent event)
{
    import kameloso.plugins.common.misc : nameOf;
    import lu.string : SplitResults, beginsWith, splitInto, stripped;
    import std.datetime.systime : Clock;

    void sendUsage()
    {
        import std.format : format;

        enum pattern = "Usage: <b>%s%s<b> [nickname] [note text]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux[0]);
        privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }

    void sendNoBotMessages()
    {
        enum message = "You cannot leave me a message; it would never be replayed.";
        privmsg(plugin.state, event.channel, event.sender.nickname, message);

    }

    string slice = event.content.stripped;  // mutable
    string target; // mutable

    immutable results = slice.splitInto(target);
    if (target.beginsWith('@')) target = target[1..$];

    if ((results != SplitResults.overrun) || !target.length) return sendUsage();
    if (target == plugin.state.client.nickname) return sendNoBotMessages();

    Note note;
    note.sender = nameOf(event.sender);
    note.timestamp = Clock.currTime.toUnixTime;
    note.line = slice;
    note.encrypt();

    plugin.notes[event.channel][target] ~= note;
    plugin.saveNotes();

    enum message = "Note saved.";
    privmsg(plugin.state, event.channel, event.sender.nickname, message);
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


// saveNotes
/++
    Saves notes to disk, to the [NotesPlugin.notesFile] JSON file.
 +/
void saveNotes(NotesPlugin plugin)
{
    import lu.json : JSONStorage;
    import std.json : JSONType;

    JSONStorage json;

    foreach (immutable channelName, channelNotes; plugin.notes)
    {
        json[channelName] = null;
        json[channelName].object = null;

        foreach (immutable nickname, notes; channelNotes)
        {
            json[channelName][nickname] = null;
            json[channelName][nickname].array = null;

            foreach (note; notes)
            {
                json[channelName][nickname].array ~= note.toJSON();
            }
        }
    }

    if (json.type == JSONType.null_) json.object = null;  // reset to type object if null_
    json.save(plugin.notesFile);
}


// loadNotes
/++
    Loads notes from disk into [NotesPlugin.notes].
 +/
void loadNotes(NotesPlugin plugin)
{
    import lu.json : JSONStorage;

    JSONStorage json;
    json.load(plugin.notesFile);
    plugin.notes.clear();

    foreach (immutable channelName, channelNotesJSON; json.object)
    {
        foreach (immutable nickname, notesJSON; channelNotesJSON.object)
        {
            foreach (noteJSON; notesJSON.array)
            {
                plugin.notes[channelName][nickname] ~= Note.fromJSON(noteJSON);
            }
        }

        plugin.notes[channelName].rehash();
    }

    plugin.notes.rehash();
}


// reload
/++
    Reloads notes from disk.
 +/
void reload(NotesPlugin plugin)
{
    return loadNotes(plugin);
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


public:


// NotesPlugin
/++
    The Notes plugin, which allows people to leave messages to each other,
    for offline communication and such.
 +/
final class NotesPlugin : IRCPlugin
{
private:
    import lu.json : JSONStorage;

    // notesSettings
    /++
        All Notes plugin settings gathered.
     +/
    NotesSettings notesSettings;

    // notes
    /++
        The in-memory JSON storage of all stored notes.

        It is in the JSON form of `Note[][string][string]`, where the first
        string key is a channel and the second a nickname.
     +/
    Note[][string][string] notes;

    // notesFile
    /++
        Filename of file to save the notes to.
     +/
    @Resource string notesFile = "notes.json";

    mixin IRCPluginImpl;
}
