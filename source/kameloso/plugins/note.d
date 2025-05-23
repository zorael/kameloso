/++
    The Note plugin allows for storing notes to offline users, to be replayed
    when they next join the channel.

    If a note is left in a channel, it is stored as a note under that channel
    and will be played back when the user joins (or optionally shows activity) there.
    If a note is left in a private message, it is stored as outside of a channel
    and will be played back in a private query, depending on the same triggers
    as those of channel notes.

    Activity in one channel will not play back notes left for another channel,
    but anything will trigger private message playback.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#note,
        [kameloso.plugins],
        [kameloso.plugins.common]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.note;

version(WithNotePlugin):

private:

import kameloso.plugins;
import kameloso.plugins.common.mixins.awareness;
import kameloso.common : logger;
import kameloso.messaging;
import dialect.defs;

version(WithChanQueryService) {}
else
{
    enum chanQueriesMessage1 = "Warning: The `Note` plugin will work but not " ~
        "well without the `ChanQuery` service.";
    enum chanQueriesMessage2 = "Consider enabling it by declaring " ~
        "version `WithChanQueryService` in your build configuration.";
    pragma(msg, chanQueriesMessage1);
    pragma(msg, chanQueriesMessage2);
}

mixin MinimalAuthentication;
mixin PluginRegistration!NotePlugin;


// NoteSettings
/++
    Note plugin settings.
 +/
@Settings struct NoteSettings
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
    /++
        JSON schema.
     +/
    static struct JSONSchema
    {
        string line;  ///
        string sender;  ///
        long timestamp;  ///

        /++
            Returns a [std.json.JSONValue|JSONValue] of this [JSONSchema].
         +/
        auto asJSONValue() const
        {
            import std.json : JSONValue;

            JSONValue json;
            json["line"] = this.line;
            json["sender"] = this.sender;
            json["timestamp"] = this.timestamp;
            return json;
        }
    }

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
        Constructor.
     +/
    this(const JSONSchema schema)
    {
        this.line = schema.line;
        this.sender = schema.sender;
        this.timestamp = schema.timestamp;
    }

    /++
        Returns a [JSONSchema] of the note, for serialisation.
     +/
    auto asSchema() const
    {
        JSONSchema schema;
        schema.line = line;
        schema.sender = sender;
        schema.timestamp = timestamp;
        return schema;
    }

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
void onJoinOrAccount(NotePlugin plugin, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);

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
    [NoteSettings.playBackOnAnyActivity] is set.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.EMOTE)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.anyone)
    .channelPolicy(ChannelPolicy.home)
    .chainable(true)
)
void onChannelMessage(NotePlugin plugin, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);

    if (plugin.settings.playBackOnAnyActivity ||
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
void onTwitchChannelEvent(NotePlugin plugin, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);

    if (event.sender.class_ == IRCUser.Class.blacklist) return;

    // No need to check whether we're on Twitch
    playbackNotes(plugin, event);
}


// onWhoReply
/++
    Plays back notes upon replies of a WHO query.

    These carry a sender, so it's possible we know the account without lookups.

    Do nothing if
    [kameloso.pods.CoreSettings.eagerLookups|CoreSettings.eagerLookups] is true,
    as we'd collide with ChanQuery queries.

    Passes `background: true` to [playbackNotes] to ensure it does low-priority
    background WHOIS queries.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WHOREPLY)
    .channelPolicy(ChannelPolicy.home)
)
void onWhoReply(NotePlugin plugin, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);

    if (plugin.state.coreSettings.eagerLookups) return;
    playbackNotes(plugin, event, background: true);
}


// playbackNotes
/++
    Plays back notes. The target is assumed to be the sender of the
    [dialect.defs.IRCEvent|IRCEvent] passed.

    If the [dialect.defs.IRCEvent|IRCEvent] contains a channel, then playback
    of both channel and private message notes will be performed. If the channel
    member is empty, only private message ones.

    Params:
        plugin = The current [NotePlugin].
        event = The triggering [dialect.defs.IRCEvent|IRCEvent].
        background = Whether or not to issue WHOIS queries as low-priority background messages.
 +/
void playbackNotes(
    NotePlugin plugin,
    const IRCEvent event,
    const bool background = false)
{
    const user = event.sender.nickname.length ?
        event.sender :
        event.target;  // on RPL_WHOREPLY

    if (!user.nickname.length)
    {
        // Despite everything we don't have a user. Bad annotations on calling event handler?
        return;
    }

    if (event.channel.name.length)
    {
        // Try channel notes first, then drop down to private notes
        playbackNotesImpl(
            plugin: plugin,
            channelName: event.channel.name,
            user: user,
            background: background);
    }

    // Private notes
    playbackNotesImpl(
        plugin: plugin,
        channelName: string.init,
        user: user,
        background: background);
}


// playbackNotesImpl
/++
    Plays back notes. Implementation function.

    Params:
        plugin = The current [NotePlugin].
        channelName = The name of the channel in which the playback is to take place,
            or an empty string if it's supposed to take place in a private message.
        user = [dialect.defs.IRCUser|IRCUser] to replay notes for.
        background = Whether or not to issue WHOIS queries as low-priority background messages.
 +/
void playbackNotesImpl(
    NotePlugin plugin,
    const string channelName,
    const IRCUser user,
    const bool background)
{
    import kameloso.plugins.common.mixins : WHOISFiberDelegate;
    import std.format : format;
    import std.typecons : Flag, No, Yes;

    auto channelNotes = channelName in plugin.notes;
    if (!channelNotes) return;

    void onSuccess(const IRCUser user)
    {
        import std.datetime.systime : Clock;

        immutable now = Clock.currTime;

        const string[2] nicknameAndAccount =
        [
            user.nickname,
            user.account,
        ];

        foreach (const id; nicknameAndAccount[])
        {
            import kameloso.plugins.common : nameOf;
            import kameloso.time : timeSince;
            import std.datetime.systime : SysTime;

            auto notes = id in *channelNotes;
            if (!notes || !notes.length) continue;

            if (notes.length == 1)
            {
                auto note = (*notes)[0];  // mutable
                immutable timestampAsSysTime = SysTime.fromUnixTime(note.timestamp);
                immutable duration = (now - timestampAsSysTime).timeSince!(7, 1)(abbreviate: false);

                note.decrypt();
                enum pattern = `<h>%s<h>! <h>%s<h> left note <b>%s<b> ago: "%s"`;
                immutable message = pattern.format(nameOf(user), note.sender, duration, note.line);
                privmsg(plugin.state, channelName, user.nickname, message);
            }
            else /*if (notes.length > 1)*/
            {
                enum pattern = "<h>%s<h>! You have <b>%d<b> notes.";
                immutable message = pattern.format(nameOf(user), notes.length);
                privmsg(plugin.state, channelName, user.nickname, message);

                foreach (/*const*/ note; *notes)
                {
                    immutable timestampAsSysTime = SysTime.fromUnixTime(note.timestamp);
                    immutable duration = (now - timestampAsSysTime).timeSince!(7, 1)(abbreviate: true);

                    note.decrypt();
                    enum entryPattern = `<h>%s<h> %s ago: "%s"`;
                    immutable report = entryPattern.format(note.sender, duration, note.line);
                    privmsg(plugin.state, channelName, user.nickname, report);
                }
            }

            (*channelNotes).remove(id);
            if (!channelNotes.length) plugin.notes.remove(channelName);

            // Don't run the loop twice if the nickname and the account is the same
            if (user.nickname == user.account) break;
        }

        saveNotes(plugin);
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
    enqueueAndWHOIS(user.nickname, issueWhois: true, background);
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
void onCommandAddNote(NotePlugin plugin, const IRCEvent event)
{
    import kameloso.plugins.common : nameOf;
    import lu.string : SplitResults, splitInto, stripped;
    import std.algorithm.searching : startsWith;

    mixin(memoryCorruptionCheck);

    void sendUsage()
    {
        import std.format : format;

        enum pattern = "Usage: <b>%s%s<b> [nickname] [note text]";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
        privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
    }

    void sendNoBotMessages()
    {
        enum message = "You cannot leave me a message; it would never be replayed.";
        privmsg(plugin.state, event.channel.name, event.sender.nickname, message);

    }

    string slice = event.content.stripped;  // mutable
    string target; // ditto
    immutable results = slice.splitInto(target);

    if (target.startsWith('@')) target = target[1..$];
    if ((results != SplitResults.overrun) || !target.length) return sendUsage();
    if (target == plugin.state.client.nickname) return sendNoBotMessages();

    Note note;
    note.sender = nameOf(event.sender);
    note.timestamp = event.time;
    note.line = slice;
    note.encrypt();

    plugin.notes[event.channel.name][target] ~= note;
    saveNotes(plugin);

    enum message = "Note saved.";
    privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
}


// onWelcome
/++
    Initialises the Note plugin. Loads the notes from disk.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WELCOME)
)
void onWelcome(NotePlugin plugin, const IRCEvent _)
{
    mixin(memoryCorruptionCheck);
    loadNotes(plugin);
}


// saveNotes
/++
    Saves notes to disk, to the [NotePlugin.notesFile] JSON file.
 +/
void saveNotes(NotePlugin plugin)
{
    import std.json : JSONValue;
    import std.stdio : File;

    JSONValue json;
    json.object = null;

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
                json[channelName][nickname].array ~= note.asSchema.asJSONValue;
            }
        }
    }

    immutable serialised = json.toPrettyString;
    File(plugin.notesFile, "w").writeln(serialised);
}


// loadNotes
/++
    Loads notes from disk into [NotePlugin.notes].
 +/
void loadNotes(NotePlugin plugin)
{
    import lu.string : strippedRight;
    import asdf.serialization : deserialize;
    import std.file : readText;
    import std.stdio : File, writeln;

    immutable content = plugin.notesFile.readText.strippedRight;

    version(PrintStacktraces)
    {
        scope(failure)
        {
            import std.json : parseJSON;
            import std.stdio : writeln;

            writeln(content);
            try writeln(content.parseJSON.toPrettyString);
            catch (Exception _) {}
        }
    }

    const json = content.deserialize!(Note.JSONSchema[][string][string]);

    plugin.notes = null;

    foreach (immutable channelName, const channelSchemas; json)
    {
        foreach (immutable nickname, const schemas; channelSchemas)
        {
            foreach (const schema; schemas)
            {
                plugin.notes[channelName][nickname] ~= Note(schema);
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
void reload(NotePlugin plugin)
{
    loadNotes(plugin);
}


// initResources
/++
    Ensures that there is a notes file, creating one if there isn't.
 +/
void initResources(NotePlugin plugin)
{
    import lu.string : strippedRight;
    import asdf.serialization : deserialize;
    import mir.serde : SerdeException;
    import std.file : readText;
    import std.json : JSONValue;
    import std.stdio : File;

    immutable content = plugin.notesFile.readText.strippedRight;

    if (!content.length)
    {
        File(plugin.notesFile, "w").writeln("{}");
        return;
    }

    version(PrintStacktraces)
    {
        scope(failure)
        {
            import std.json : parseJSON;
            import std.stdio : writeln;

            writeln(content);
            try writeln(content.parseJSON.toPrettyString);
            catch (Exception _) {}
        }
    }

    try
    {
        const deserialised = content.deserialize!(Note.JSONSchema[][string][string]);

        JSONValue json;
        json.object = null;

        foreach (immutable channelName, const channelNotes; deserialised)
        {
            json[channelName].object = null;

            foreach (immutable nickname, const schemas; channelNotes)
            {
                json[channelName][nickname] = null;
                json[channelName][nickname].array = null;

                foreach (schema; schemas)
                {
                    json[channelName][nickname].array ~= schema.asJSONValue;
                }
            }
        }

        immutable serialised = json.toPrettyString;
        File(plugin.notesFile, "w").writeln(serialised);
    }
    catch (SerdeException e)
    {
        version(PrintStacktraces) logger.trace(e);

        throw new IRCPluginInitialisationException(
            message: "Notes file is malformed",
            pluginName: plugin.name,
            malformedFilename: plugin.notesFile);
    }
}


// selftest
/++
    Performs self-tests against another bot.
 +/
version(Selftests)
auto selftest(NotePlugin plugin, Selftester s)
{
    void cycle()
    {
        import kameloso.plugins.common.scheduling : await, unawait;
        import core.thread.fiber : Fiber;

        part(plugin.state, s.channelName);
        await(plugin, IRCEvent.Type.SELFPART, yield: true);

        while (
            (s.fiber.payload.type != IRCEvent.Type.SELFPART) ||
            (s.fiber.payload.channel.name != s.channelName))
        {
            Fiber.yield();
        }

        unawait(plugin, IRCEvent.Type.SELFPART);

        join(plugin.state, s.channelName);
        await(plugin, IRCEvent.Type.SELFJOIN, yield: true);

        while (
            (s.fiber.payload.type != IRCEvent.Type.SELFJOIN) ||
            (s.fiber.payload.channel.name != s.channelName))
        {
            Fiber.yield();
        }

        unawait(plugin, IRCEvent.Type.SELFJOIN);
    }

    // ------------ !note

    s.send("note ${target} test");
    s.expect("You cannot leave me a message; it would never be replayed.");

    s.send("note ${bot} test");
    s.expect("Note saved.");

    cycle();

    s.awaitReply();
    {
        import std.format : format;

        enum pattern = "%s! %1$s left note";
        immutable head = pattern.format(plugin.state.client.nickname);
        enum tail = "ago: test";
        s.requireHead(head);
        s.requireTail(tail);
    }

    s.send("set note.playBackOnAnyActivity=false");
    s.expect("Setting changed.");

    s.send("note ${bot} abc def ghi");
    s.expect("Note saved.");

    s.send("note ${bot} 123 456 789");
    s.expect("Note saved.");

    cycle();

    s.expect("${bot}! You have 2 notes.");
    s.expectTail("ago: abc def ghi");
    s.expectTail("ago: 123 456 789");

    return true;
}


public:


// NotePlugin
/++
    The Note plugin, which allows people to leave messages to each other,
    for offline communication and such.
 +/
final class NotePlugin : IRCPlugin
{
    // settings
    /++
        All Note plugin settings gathered.
     +/
    NoteSettings settings;

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
