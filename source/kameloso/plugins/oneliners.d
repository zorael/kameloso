/++
    The Oneliners plugin serves to provide custom commands, like `!vods`, `!youtube`,
    and any other static-reply `!command` (provided a prefix of "`!`").

    More advanced commands that do more than just repeat the preset lines of text
    will have to be written separately.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#oneliners
        [kameloso.plugins.common.core|plugins.common.core]
        [kameloso.plugins.common.misc|plugins.common.misc]
 +/
module kameloso.plugins.oneliners;

version(WithOnelinersPlugin):

private:

import kameloso.plugins.common.core;
import kameloso.plugins.common.awareness : ChannelAwareness, TwitchAwareness, UserAwareness;
import kameloso.common : logger;
import kameloso.messaging;
import dialect.defs;


/// All Oneliner plugin runtime settings.
@Settings struct OnelinersSettings
{
    /// Toggle whether or not this plugin should do anything at all.
    @Enabler bool enabled = true;

    /// Whether or not trigger words should be matched case-sensitively.
    bool caseSensitiveTriggers = false;
}


// onOneliner
/++
    Responds to oneliners.

    Responses are stored in [OnelinersPlugin.onelinersByChannel].
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.ignore)
    .channelPolicy(ChannelPolicy.home)
    .chainable(true)
)
void onOneliner(OnelinersPlugin plugin, const ref IRCEvent event)
{
    import lu.string : beginsWith, contains, nom;

    if (!event.content.beginsWith(plugin.state.settings.prefix)) return;

    immutable slice = event.content[plugin.state.settings.prefix.length..$];

    // An empty command is invalid, as is one containing spaces
    if (!slice.length || slice.contains(' ')) return;

    if (const channelOneliners = event.channel in plugin.onelinersByChannel)
    {
        import std.uni : toLower;

        immutable key = plugin.onelinersSettings.caseSensitiveTriggers ? slice : slice.toLower;

        if (const response = key in *channelOneliners)
        {
            import kameloso.plugins.common.misc : nameOf;
            import std.array : replace;
            import std.conv : text;
            import std.random : uniform;

            immutable line = (*response)
                .replace("$nickname", nameOf(event.sender))
                .replace("$streamer", plugin.nameOf(event.channel[1..$]))  // Twitch
                .replace("$bot", plugin.state.client.nickname)
                .replace("$channel", event.channel[1..$])
                .replace("$random", uniform!"(]"(0, 100).text);

            chan(plugin.state, event.channel, line);
        }
    }
}


// onCommandModifyOneliner
/++
    Adds or removes a oneliner to/from the list of oneliners, and saves it to disk.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.operator)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("oneliner")
            .policy(PrefixPolicy.prefixed)
            .description("Adds or removes a oneliner command.")
            .syntax("$command [add|del|list] [text]")
    )
)
void onCommandModifyOneliner(OnelinersPlugin plugin, const ref IRCEvent event)
{
    import lu.string : contains, nom;
    import std.format : format;
    import std.typecons : Flag, No, Yes;
    import std.uni : toLower;

    void sendUsage(const string verb = "[add|del|list]",
        const Flag!"includeText" includeText = Yes.includeText)
    {
        enum pattern = "Usage: <b>%s%s<b> %s [trigger]%s";
        immutable message = pattern.format(plugin.state.settings.prefix,
            event.aux, verb, (includeText ? " [text]" : string.init));
        chan(plugin.state, event.channel, message);
    }

    if (!event.content.length) return sendUsage();

    string slice = event.content;
    immutable verb = slice.nom!(Yes.inherit, Yes.decode)(' ');

    switch (verb)
    {
    case "add":
        import kameloso.thread : ThreadMessage;
        import std.concurrency : send;

        /+
            We need to check both hardcoded and soft channel-specific commands
            for conflicts.
         +/

        if (!slice.contains!(Yes.decode)(' ')) return sendUsage(verb, Yes.includeText);

        string trigger = slice.nom!(Yes.decode)(' ');
        if (!trigger.length) return sendUsage(verb);

        if (!plugin.onelinersSettings.caseSensitiveTriggers) trigger = trigger.toLower;

        bool triggerConflicts(const IRCPlugin.CommandMetadata[string][string] aa)
        {
            foreach (immutable pluginName, pluginCommands; aa)
            {
                if (!pluginCommands.length || (pluginName == "oneliners")) continue;

                foreach (/*mutable*/ word, command; pluginCommands)
                {
                    if (!plugin.onelinersSettings.caseSensitiveTriggers) word = word.toLower;

                    if (word == trigger)
                    {
                        enum pattern = `Oneliner word "<b>%s<b>" conflicts with a command of the <b>%s<b> plugin.`;
                        immutable message = pattern.format(trigger, pluginName);
                        chan(plugin.state, event.channel, message);
                        return true;
                    }
                }
            }
            return false;
        }

        void channelSpecificDg(IRCPlugin.CommandMetadata[string][string] channelSpecificAA)
        {
            if (triggerConflicts(channelSpecificAA)) return;

            plugin.onelinersByChannel[event.channel][trigger] = slice;
            saveResourceToDisk(plugin.onelinersByChannel, plugin.onelinerFile);

            import std.algorithm.comparison : equal;
            import std.uni : asLowerCase;

            immutable wasMadeLowerCase = !plugin.onelinersSettings.caseSensitiveTriggers &&
                !trigger.equal(trigger.asLowerCase);

            enum pattern = "Oneliner <b>%s%s<b> added%s.";
            immutable message = pattern.format(plugin.state.settings.prefix,
                trigger, (wasMadeLowerCase ? " (made lowercase)" : string.init));
            chan(plugin.state, event.channel, message);
        }

        void dg(IRCPlugin.CommandMetadata[string][string] aa)
        {
            if (triggerConflicts(aa)) return;
            plugin.state.mainThread.send(ThreadMessage.PeekCommands(),
                cast(shared)&channelSpecificDg, event.channel);
        }

        plugin.state.mainThread.send(ThreadMessage.PeekCommands(), cast(shared)&dg, string.init);
        break;

    case "del":
        if (!slice.length) return sendUsage(verb, No.includeText);

        immutable trigger = plugin.onelinersSettings.caseSensitiveTriggers ? slice : slice.toLower;

        if (trigger !in plugin.onelinersByChannel[event.channel])
        {
            enum pattern = "No such trigger: <b>%s%s<b>";
            immutable message = pattern.format(plugin.state.settings.prefix, slice);
            chan(plugin.state, event.channel, message);
            return;
        }

        plugin.onelinersByChannel[event.channel].remove(trigger);
        saveResourceToDisk(plugin.onelinersByChannel, plugin.onelinerFile);

        enum pattern = "Oneliner <b>%s%s<b> removed.";
        immutable message = pattern.format(plugin.state.settings.prefix, trigger);
        chan(plugin.state, event.channel, message);
        break;

    case "list":
        return plugin.listCommands(event.channel);

    default:
        return sendUsage();
    }
}


// onCommandCommands
/++
    Sends a list of the current oneliners to the channel.

    Merely calls [listCommands].
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.anyone)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("commands")
            .policy(PrefixPolicy.prefixed)
            .description("Lists all available oneliners.")
    )
)
void onCommandCommands(OnelinersPlugin plugin, const ref IRCEvent event)
{
    return plugin.listCommands(event.channel);
}


// listCommands
/++
    Lists the current commands to the passed channel.

    Params:
        plugin = The current [OnelinersPlugin].
        channelName = Name of the channel to send the list to.
 +/
void listCommands(OnelinersPlugin plugin, const string channelName)
{
    import std.format : format;

    auto channelOneliners = channelName in plugin.onelinersByChannel;

    if (channelOneliners && channelOneliners.length)
    {
        immutable rtPattern = "Available commands: %-(<b>" ~ plugin.state.settings.prefix ~ "%s<b>, %)";
        immutable message = rtPattern.format(channelOneliners.byKey);
        chan(plugin.state, channelName, message);
    }
    else
    {
        chan(plugin.state, channelName, "There are no commands available right now.");
    }
}


// onWelcome
/++
    Populate the oneliners array after we have successfully logged onto the server.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WELCOME)
)
void onWelcome(OnelinersPlugin plugin)
{
    import lu.json : JSONStorage, populateFromJSON;
    import std.typecons : Flag, No, Yes;

    JSONStorage channelOnelinerJSON;
    channelOnelinerJSON.load(plugin.onelinerFile);
    //plugin.onelinersByChannel.clear();
    plugin.onelinersByChannel.populateFromJSON(channelOnelinerJSON,
        cast(Flag!"lowercaseKeys")(!plugin.onelinersSettings.caseSensitiveTriggers));  // invert it
    plugin.onelinersByChannel = plugin.onelinersByChannel.rehash();
}


// saveResourceToDisk
/++
    Saves the passed resource to disk, but in JSON format.

    This is used with the associative arrays for oneliners.

    Example:
    ---
    plugin.oneliners["#channel"]["asdf"] ~= "asdf yourself";
    plugin.oneliners["#channel"]["fdsa"] ~= "hirr";

    saveResource(plugin.onelinersByChannel, plugin.onelinerFile);
    ---

    Params:
        aa = The JSON-convertible resource to save.
        filename = Filename of the file to write to.
 +/
void saveResourceToDisk(const string[string][string] aa, const string filename)
in (filename.length, "Tried to save resources to an empty filename string")
{
    import std.json : JSONValue;
    import std.stdio : File, writeln;

    File(filename, "w").writeln(JSONValue(aa).toPrettyString);
}


// initResources
/++
    Reads and writes the file of oneliners and administrators to disk, ensuring
    that they're there and properly formatted.
 +/
void initResources(OnelinersPlugin plugin)
{
    import lu.json : JSONStorage;
    import std.json : JSONException;
    import std.path : baseName;

    JSONStorage onelinerJSON;

    try
    {
        onelinerJSON.load(plugin.onelinerFile);
    }
    catch (JSONException e)
    {
        import kameloso.plugins.common.misc : IRCPluginInitialisationException;

        version(PrintStacktraces) logger.trace(e);
        throw new IRCPluginInitialisationException(plugin.onelinerFile.baseName ~ " may be malformed.");
    }

    // Let other Exceptions pass.

    onelinerJSON.save(plugin.onelinerFile);
}


mixin UserAwareness;
mixin ChannelAwareness;

version(TwitchSupport)
{
    mixin TwitchAwareness;
}


public:


// OnelinersPlugin
/++
    The Oneliners plugin serves to listen to custom commands that can be added,
    modified and removed at runtime. Think `!info`.
 +/
final class OnelinersPlugin : IRCPlugin
{
private:
    /// All Oneliners plugin settings.
    OnelinersSettings onelinersSettings;

    /// Associative array of oneliners; oneliners array keyed by channel.
    string[string][string] onelinersByChannel;

    /// Filename of file with oneliners.
    @Resource string onelinerFile = "oneliners.json";

    // channelSpecificCommands
    /++
        Compile a list of our runtime oneliner commands.

        Params:
            channelName = Name of channel whose commands we want to summarise.

        Returns:
            An associative array of
            [kameloso.plugins.common.core.IRCPlugin.CommandMetadata|IRCPlugin.CommandMetadata]s,
            one for each oneliner active in the passed channel.
     +/
    override public IRCPlugin.CommandMetadata[string] channelSpecificCommands(const string channelName) @system
    {
        IRCPlugin.CommandMetadata[string] aa;

        const channelOneliners = channelName in onelinersByChannel;
        if (!channelOneliners) return aa;

        foreach (immutable trigger, immutable _; *channelOneliners)
        {
            IRCPlugin.CommandMetadata metadata;
            metadata.description = "A oneliner";
            aa[trigger] = metadata;
        }

        return aa;
    }

    mixin IRCPluginImpl;
}
