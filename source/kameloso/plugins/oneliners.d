/++
 +  The Oneliners plugin serves to provide custom commands, like `!vods`, `!youtube`,
 +  and any other static-reply `!command` (provided a prefix of "`!`").
 +
 +  More advanced commands that do more than just repeat the preset lines of text
 +  will have to be written separately.
 +/
module kameloso.plugins.oneliners;

version(WithPlugins):
version(WithOnelinersPlugin):

private:

import kameloso.plugins.common;
import kameloso.irc.defs;
import kameloso.messaging;
import kameloso.common : logger, settings;


/// All Oneliner plugin runime settings.
struct OnelinersSettings
{
    /// Toggle whether or not this plugin should do anything at all.
    @Enabler bool enabled = true;

    /++
     +  Toggle whether or not a class of `kameloso.irc.defs.IRCUser.Class.whitelist`
     +  is enough to be allowed to modify oneliners.
     +/
    bool whitelistMayModify = true;
}


// onOneliner
/++
 +  Responds to oneliners.
 +
 +  Responses are stored in `OnelinersPlugin.onelinersByChannel`.
 +/
@(Chainable)
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.ignore)
@(ChannelPolicy.home)
void onOneliner(OnelinersPlugin plugin, const IRCEvent event)
{
    import kameloso.string : beginsWith, contains, nom;

    if (!event.content.beginsWith(settings.prefix)) return;

    string slice = event.content;
    slice.nom(settings.prefix);

    if (const channelOneliners = event.channel in plugin.onelinersByChannel)
    {
        // Insert .toLower here if we want case-insensitive oneliners
        //import std.uni : toLower;
        if (const response = slice/*.toLower*/ in *channelOneliners)
        {
            chan(plugin.state, event.channel, *response);
        }
    }
}


// onCommandModifyOneliner
/++
 +  Adds or removes a oneliner to/from the list of oneliners, and saves it to disk.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.whitelist)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "oneliner")
@Description("Adds or removes a oneliner command.", "$command [add|del] [text]")
void onCommandModifyOneliner(OnelinersPlugin plugin, const IRCEvent event)
{
    import kameloso.string : contains, nom;
    import std.algorithm.searching : count;
    import std.format : format;
    import std.typecons : No, Yes;

    if (!plugin.onelinersSettings.whitelistMayModify &&
        (event.sender.class_ == IRCUser.Class.whitelist)) return;

    if (!event.content.length)
    {
        chan(plugin.state, event.channel, "Usage: [add|del] [trigger] [text]");
        return;
    }

    string slice = event.content;
    immutable verb = slice.nom!(Yes.inherit, Yes.decode)(' ');

    switch (verb)
    {
    case "add":
        if (!slice.contains!(Yes.decode)(' '))
        {
            chan(plugin.state, event.channel, "Usage: %s [trigger] [text]".format(verb));
            return;
        }

        immutable trigger = slice.nom!(Yes.decode)(' ');

        plugin.onelinersByChannel[event.channel][trigger] = slice;
        saveResourceToDisk(plugin.onelinersByChannel, plugin.onelinerFile);

        chan(plugin.state, event.channel, "Oneliner %s%s added."
            .format(settings.prefix, trigger));
        break;

    case "del":
        if (!slice.length)
        {
            chan(plugin.state, event.channel, "Usage: %s [trigger]".format(verb));
            return;
        }
        else if (slice !in plugin.onelinersByChannel[event.channel])
        {
            chan(plugin.state, event.channel, "No such trigger: %s%s"
                .format(settings.prefix, slice));
            return;
        }

        plugin.onelinersByChannel[event.channel].remove(slice);
        saveResourceToDisk(plugin.onelinersByChannel, plugin.onelinerFile);

        chan(plugin.state, event.channel, "Oneliner %s%s removed."
            .format(settings.prefix, slice));
        break;

    default:
        chan(plugin.state, event.channel, "Available actions: add, del");
        break;
    }
}


// onCommandCommands
/++
 +  Sends a list of the current oneliners to the channel.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.ignore)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "commands")
@Description("Lists all available oneliners.")
void onCommandCommands(OnelinersPlugin plugin, const IRCEvent event)
{
    import std.format : format;

    auto channelOneliners = event.channel in plugin.onelinersByChannel;

    if (channelOneliners && channelOneliners.length)
    {
        chan(plugin.state, event.channel, ("Available commands: %-(" ~ settings.prefix ~ "%s, %)")
            .format(channelOneliners.byKey));
    }
    else
    {
        chan(plugin.state, event.channel, "There are no commands available right now.");
    }
}


// onEndOfMotd
/++
 +  Populate the oneliners array after we have successfully logged onto the server.
 +/
@(IRCEvent.Type.RPL_ENDOFMOTD)
@(IRCEvent.Type.ERR_NOMOTD)
void onEndOfMotd(OnelinersPlugin plugin)
{
    import kameloso.json : JSONStorage, populateFromJSON;
    import std.typecons : Flag, No, Yes;

    with (plugin)
    {
        JSONStorage channelOnelinerJSON;
        channelOnelinerJSON.load(onelinerFile);
        //onelinersByChannel.clear();
        onelinersByChannel.populateFromJSON(channelOnelinerJSON);
        onelinersByChannel.rehash();
    }
}


// saveResourceToDisk
/++
 +  Saves the passed resource to disk, but in JSON format.
 +
 +  This is used with the associative arrays for oneliners.
 +
 +  Example:
 +  ---
 +  plugin.oneliners["#channel"]["asdf"] ~= "asdf yourself";
 +  plugin.oneliners["#channel"]["fdsa"] ~= "hirr";
 +
 +  saveResource(plugin.onelinersByChannel, plugin.onelinerFile);
 +  ---
 +
 +  Params:
 +      aa = The JSON-convertible resource to save.
 +      filename = Filename of the file to write to.
 +/
void saveResourceToDisk(const string[string][string] aa, const string filename)
{
    import std.json : JSONValue;
    import std.stdio : File, writeln;

    File(filename, "w").writeln(JSONValue(aa).toPrettyString);
}


// initResources
/++
 +  Reads and writes the file of oneliners and administrators to disk, ensuring
 +  that they're there and properly formatted.
 +/
void initResources(OnelinersPlugin plugin)
{
    import kameloso.json : JSONStorage;
    import std.json : JSONException;
    import std.path : baseName;

    JSONStorage onelinerJSON;

    try
    {
        onelinerJSON.load(plugin.onelinerFile);
    }
    catch (JSONException e)
    {
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
 +  The Oneliners plugin serves to listen to custom commands that can be added
 +  at runtime. Think `!info`.
 +/
final class OnelinersPlugin : IRCPlugin
{
    /// All Oneliners plugin settings.
    OnelinersSettings onelinersSettings;

    /// Associative array of oneliners; oneliners array keyed by channel.
    string[string][string] onelinersByChannel;

    /// Filename of file with oneliners.
    @Resource string onelinerFile = "oneliners.json";

    mixin IRCPluginImpl;
}
