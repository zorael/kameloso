/++
    The Oneliners plugin serves to provide custom commands, like `!vods`, `!youtube`,
    and any other static-reply `!command` (provided a prefix of "`!`").

    More advanced commands that do more than just repeat the preset lines of text
    will have to be written separately.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#oneliners
 +/
module kameloso.plugins.oneliners;

version(WithPlugins):
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
@Chainable
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PermissionsRequired.ignore)
@(ChannelPolicy.home)
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
            import kameloso.plugins.common.base : nameOf;
            import std.array : replace;
            import std.conv : text;
            import std.random : uniform;

            immutable line = (*response)
                .replace("$nickname", plugin.nameOf(event.sender.nickname))
                .replace("$streamer", plugin.nameOf(event.channel[1..$]))  // Twitch
                .replace("$bot", plugin.state.client.nickname)
                .replace("$channel", event.channel[1..$])
                .replace("$random", uniform!"[]"(0, 100).text);

            chan(plugin.state, event.channel, line);
        }
    }
}


// onCommandModifyOneliner
/++
    Adds or removes a oneliner to/from the list of oneliners, and saves it to disk.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PermissionsRequired.operator)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "oneliner")
@Description("Adds or removes a oneliner command.", "$command [add|del|list] [text]")
void onCommandModifyOneliner(OnelinersPlugin plugin, const ref IRCEvent event)
{
    import lu.string : contains, nom;
    import std.format : format;
    import std.typecons : Flag, No, Yes;
    import std.uni : toLower;

    void sendUsage(const string verb = "[add|del|list]",
        const Flag!"includeText" includeText = Yes.includeText)
    {
        chan(plugin.state, event.channel, "Usage: %s%s %s [trigger]%s"
            .format(plugin.state.settings.prefix, event.aux, verb,
                includeText ? " [text]" : string.init));
    }

    if (!event.content.length) return sendUsage();

    string slice = event.content;
    immutable verb = slice.nom!(Yes.inherit, Yes.decode)(' ');

    switch (verb)
    {
    case "add":
        if (!slice.contains!(Yes.decode)(' ')) return sendUsage(verb, Yes.includeText);

        string trigger = slice.nom!(Yes.decode)(' ');

        if (!trigger.length) return sendUsage(verb);

        if (!plugin.onelinersSettings.caseSensitiveTriggers) trigger = trigger.toLower;

        plugin.onelinersByChannel[event.channel][trigger] = slice;
        saveResourceToDisk(plugin.onelinersByChannel, plugin.onelinerFile);

        chan(plugin.state, event.channel, "Oneliner %s%s added%s."
            .format(plugin.state.settings.prefix, trigger,
                plugin.onelinersSettings.caseSensitiveTriggers ?
                    string.init : " (made lowercase)"));
        break;

    case "del":
        if (!slice.length) return sendUsage(verb, No.includeText);

        immutable trigger = plugin.onelinersSettings.caseSensitiveTriggers ? slice : slice.toLower;

        if (trigger !in plugin.onelinersByChannel[event.channel])
        {
            import std.conv : text;
            chan(plugin.state, event.channel,
                text("No such trigger: ", plugin.state.settings.prefix, slice));
            return;
        }

        plugin.onelinersByChannel[event.channel].remove(trigger);
        saveResourceToDisk(plugin.onelinersByChannel, plugin.onelinerFile);

        chan(plugin.state, event.channel, "Oneliner %s%s removed."
            .format(plugin.state.settings.prefix, trigger));
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
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PermissionsRequired.ignore)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "commands")
@Description("Lists all available oneliners.")
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
        immutable pattern = "Available commands: %-(" ~ plugin.state.settings.prefix ~ "%s, %)";
        chan(plugin.state, channelName, pattern.format(channelOneliners.byKey));
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
@(IRCEvent.Type.RPL_WELCOME)
void onWelcome(OnelinersPlugin plugin)
{
    import lu.json : JSONStorage, populateFromJSON;
    import std.typecons : Flag, No, Yes;

    JSONStorage channelOnelinerJSON;
    channelOnelinerJSON.load(plugin.onelinerFile);
    //plugin.onelinersByChannel.clear();
    plugin.onelinersByChannel.populateFromJSON(channelOnelinerJSON,
        plugin.onelinersSettings.caseSensitiveTriggers ?
            No.lowercaseKeys : Yes.lowercaseKeys);
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

    mixin IRCPluginImpl;
}
