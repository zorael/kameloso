/++
 +  The Automode plugin handles automatically setting the modes of users in a
 +  channel. The common usecase is to have someone be automatically set to `+o`
 +  (operator) when joining.
 +/
module kameloso.plugins.automode;

import kameloso.plugins.common;
import kameloso.ircdefs;
import kameloso.common : logger;

import std.typecons : Flag, No, Yes;

private:


// AutomodeSettings
/++
 +  All Automode settings gathered in a struct.
 +/
struct AutomodeSettings
{
    /// Toggles whether or not the plugin should react to events at all.
    bool enabled = true;

    /// The file to read and save automode definitions from/to.
    string automodeFile = "automodes.json";
}


// populateAutomodes
/++
 +  Reads automode definitions from disk, populating a `string[string][string]`
 +  associative array; `modestring[channel][account]`.
 +
 +  It is stored in JSON form, so we read it into a `JSONValue` and then iterate
 +  it to populate a normal associative array for faster lookups.
 +/
void populateAutomodes(AutomodePlugin plugin)
{
    import kameloso.json : JSONStorage;
    import kameloso.string : has;
    import std.conv : text;
    import std.json : JSON_TYPE;

    JSONStorage automodes;
    automodes.load(plugin.automodeSettings.automodeFile);
    plugin.automodes = typeof(plugin.automodes).init;

    foreach (const channel, const modesigns; automodes.object)
    {
        foreach (const account, const modesign; modesigns.object)
        {
            plugin.automodes[channel][account] = modesign.str;
        }
    }
}


// saveAutomodes
/++
 +  Saves automode definitions to disk.
 +
 +  Use JSON to get a pretty-printed list, then write it.
 +/
void saveAutomodes(AutomodePlugin plugin)
{
    import kameloso.json : JSONStorage;
    import std.json : JSONValue;

    // Create a JSONStorage only to save it
    JSONStorage automodes;
    pruneChannels(plugin.automodes);
    automodes.storage = JSONValue(plugin.automodes);
    automodes.save(plugin.automodeSettings.automodeFile);
}


// onAccountInfo
/++
 +  Potentially applies an automode, depending on the definitions and the user
 +  triggering the function.
 +
 +  Different `kameloso.ircdefs.IRCEvent.Type`s have to be handled differently,
 +  as the triggering user may be either the sender or the target.
 +/
@(IRCEvent.Type.ACCOUNT)
@(IRCEvent.Type.RPL_WHOISACCOUNT)
@(IRCEvent.Type.JOIN)
@(PrivilegeLevel.ignore)
@(ChannelPolicy.home)
void onAccountInfo(AutomodePlugin plugin, const IRCEvent event)
{
    if (!plugin.automodeSettings.enabled) return;

    import kameloso.messaging : raw;
    import std.algorithm.searching : canFind;
    import std.array : array, join;
    import std.format : format;
    import std.range : repeat;

    string account, nickname;

    with (IRCEvent.Type)
    with (event)
    switch (event.type)
    {
    case ACCOUNT:
        account = sender.account;
        nickname = sender.nickname;
        break;

    case RPL_WHOISACCOUNT:
        account = target.account;
        nickname = target.nickname;
        break;

    case JOIN:
        if (!sender.account.length)
        {
            // Not an extended join
            // FIXME: Preemptively WHOIS?
            logger.log("Preemptively WHOIS?");
            return;
        }
        goto case ACCOUNT;

    default:
        assert(0, "Invalid IRCEvent.Type annotation on %s: %s"
            .format(__FUNCTION__, event.type));
    }

    foreach (const channel, const channelaccounts; plugin.automodes)
    {
        const modes = account in channelaccounts;
        if (!modes || !modes.length) continue;

        auto occupiedChannel = channel in plugin.state.channels;
        if (!occupiedChannel || (occupiedChannel.ops.canFind(plugin.state.bot.nickname)))
        {
            // We aren't in the channel we have this automode definition for
            continue;
        }

        plugin.state.mainThread.raw("MODE %s %s%s %s".format(event.channel,
            "+".repeat((*modes).length).join, *modes, nickname));
    }
}


// onCommandAddAutomode
/++
 +  Adds an account-channel automode pair definition and saves it to disk.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "addmode")
@Description("Adds an automatic mode change for a user account.")
void onCommandAddAutomode(AutomodePlugin plugin, const IRCEvent event)
{
    if (!plugin.automodeSettings.enabled) return;

    import kameloso.irc : isValidChannel, isValidNickname;
    import kameloso.string : beginsWith, nom;
    import std.algorithm.searching : count;

    if (event.content.count(" ") != 2)
    {
        logger.log("Usage: addmode [channel] [account] [mode]");
        return;
    }

    string line = event.content;  // need mutable

    immutable channel = line.nom!(Yes.decode)(" ");
    immutable account = line.nom!(Yes.decode)(" ");

    while (line.beginsWith("+"))
    {
        line.nom!(Yes.decode)("+");
    }

    immutable mode = line;

    if (!channel.isValidChannel(plugin.state.bot.server))
    {
        logger.log("Invalid channel: ", channel);
        return;
    }
    else if (!account.isValidNickname(plugin.state.bot.server))
    {
        logger.log("Invalid account: ", account);
        return;
    }
    else if (!mode.length)
    {
        logger.log("Empty mode");
        return;
    }

    plugin.automodes[channel][account] = mode;

    logger.logf("Automode added: %s on %s: %s", account, channel, mode);
    plugin.saveAutomodes();
}


// onCommandClearAutomode
/++
 +  Clears an automode definition for an account-channel pair.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "clearmode")
@BotCommand(NickPolicy.required, "delmode")
@Description("Clears any automatic mode change definitions for an account in a channel.")
void onCommandClearAutomode(AutomodePlugin plugin, const IRCEvent event)
{
    if (!plugin.automodeSettings.enabled) return;

    import kameloso.string : nom;
    import std.algorithm.searching : count;

    if (event.content.count(" ") != 1)
    {
        logger.log("Usage: clearmode [channel] [account]");
        return;
    }

    string line = event.content;  // need mutable

    immutable channel = line.nom!(Yes.decode)(" ");
    immutable account = line;

    if (auto channelAutomodes = channel in plugin.automodes)
    {
        (*channelAutomodes).remove(account);
        logger.logf("Automode cleared: %s on %s", account, channel);
        plugin.saveAutomodes();
    }
    else
    {
        logger.log("No such channel: ", channel);
    }
}


// onCommandPrintModes
/++
 +  Prints the current automodes associative array to the local terminal.
 +
 +  This is for debugging purposes.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "printmodes")
@Description("[debug] Prints out automodes definitions to the local terminal.")
void onCommandPrintModes(AutomodePlugin plugin, const IRCEvent event)
{
    if (!plugin.automodeSettings.enabled) return;

    import std.json : JSONValue;
    import std.stdio : writeln;

    writeln(JSONValue(plugin.automodes).toPrettyString);
}

// onCommandHello
/++
 +  Triggers a WHOIS of the user invoking it with bot commands.
 +
 +  The `PrivilegeLevel.admin` annotation is is to force the bot to evaluate
 +  whether an automode should be applied or not.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "hello")
@Description("Forces the bot to query for a user's account, to see if he/she is due an automode.")
void onCommandHello(AutomodePlugin plugin, const IRCEvent event) {}


// onUserPart
/++
 +  Removes a record of an applied automode for an account-channel pair.
 +/
@(IRCEvent.Type.PART)
@(PrivilegeLevel.ignore)
@(ChannelPolicy.home)
void onUserPart(AutomodePlugin plugin, const IRCEvent event)
{
    if (!plugin.automodeSettings.enabled) return;

    if (auto channelApplications = event.channel in plugin.appliedAutomodes)
    {
        immutable account = plugin.state.users[event.sender.nickname].account;
        (*channelApplications).remove(account);
    }
}


// onUserQuit
/++
 +  Removes a record of an applied automode for an account, in any and all
 +  channels.
 +/
@(IRCEvent.Type.QUIT)
void onUserQuit(AutomodePlugin plugin, const IRCEvent event)
{
    if (!plugin.automodeSettings.enabled) return;

    if (!event.sender.account.length) return;

    foreach (ref channelApplications; plugin.appliedAutomodes)
    {
        channelApplications.remove(event.sender.account);
    }
}


// pruneChannels
/++
 +  Prunes empty channels in the automodes definitions associative array.
 +
 +  Params:
 +      automodes = Associative array of automodes to prune.
 +/
void pruneChannels(ref string[string][string] automodes)
{
    foreach (channel, channelAutomodes; automodes)
    {
        if (!channelAutomodes.length)
        {
            automodes.remove(channel);
        }
    }
}


mixin UserAwareness;

mixin ChannelAwareness;


public:


// AutomodePlugin
/++
 +  The Automode plugin automatically changes modes of users in channels as per
 +  saved definitions.
 +
 +  Definitions are saved in a JSON file.
 +/
final class AutomodePlugin : IRCPlugin
{
    /// Associative array of automodes.
    string[string][string] automodes;

    /// Records of applied automodes so we don't repeat ourselves.
    bool[string][string] appliedAutomodes;

    /// All Automode options gathered.
    @Settings AutomodeSettings automodeSettings;

    mixin IRCPluginImpl;
}
