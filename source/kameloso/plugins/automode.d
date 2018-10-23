/++
 +  The Automode plugin handles automatically setting the modes of users in a
 +  channel. The common usecase is to have someone be automatically set to `+o`
 +  (operator) when joining.
 +/
module kameloso.plugins.automode;

version(WithPlugins):

private:

import kameloso.plugins.common;
import kameloso.ircdefs;
import kameloso.common : logger;

import std.typecons : Flag, No, Yes;


// AutomodeSettings
/++
 +  All Automode settings gathered in a struct.
 +/
struct AutomodeSettings
{
    /// Toggles whether or not the plugin should react to events at all.
    bool enabled = true;
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
    import kameloso.string : contains;
    import std.conv : text;
    import std.json : JSON_TYPE;

    JSONStorage automodes;
    automodes.load(plugin.automodeFile);
    plugin.automodes = typeof(plugin.automodes).init;

    foreach (immutable channel, const modesigns; automodes.object)
    {
        foreach (immutable account, const modesign; modesigns.object)
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
    automodes.save(plugin.automodeFile);
}


// initResources
/++
 +  Ensures that there is an automodes file, creating one if there isn't.
 +/
void initResources(AutomodePlugin plugin)
{
    import kameloso.json : JSONStorage;

    JSONStorage json;
    json.load(plugin.automodeFile);
    json.save(plugin.automodeFile);
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
@(IRCEvent.Type.RPL_WHOISREGNICK)
@(IRCEvent.Type.JOIN)
@(PrivilegeLevel.ignore)
@(ChannelPolicy.home)
void onAccountInfo(AutomodePlugin plugin, const IRCEvent event)
{
    if (!plugin.automodeSettings.enabled) return;

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
    case RPL_WHOISREGNICK:
        account = target.account;
        nickname = target.nickname;
        break;

    case JOIN:
        if (sender.account.length) goto case ACCOUNT;

        // Not an extended join
        import kameloso.messaging : raw;
        plugin.state.raw("WHOIS " ~ sender.nickname);
        return;

    default:
        assert(0, "Invalid IRCEvent annotation on " ~ __FUNCTION__);
    }

    plugin.applyAutomodes(nickname, account);
}


// applyAutomodes
/++
 +  Applies automodes for a specific user.
 +
 +  It applies any and all defined modestrings for said user, in any and all
 +  channels the bot is operator in.
 +
 +  Params:
 +      plugin = The current `AutomodePlugin`
 +      nickname = String nickname of the user to apply modes to.
 +      account = String account of the user, to look up definitions for.
 +/
void applyAutomodes(AutomodePlugin plugin, const string nickname, const string account)
{
    import kameloso.messaging : raw;
    import std.algorithm.searching : canFind;
    import std.array : array, join;
    import std.format : format;
    import std.range : repeat;

    foreach (const channelaccounts; plugin.appliedAutomodes)
    {
        if (account in channelaccounts)
        {
            logger.log("Already applied modes to ", nickname);
            return;
        }
    }

    foreach (immutable channel, const channelaccounts; plugin.automodes)
    {
        if (!plugin.state.bot.homes.canFind(channel)) continue;

        const modes = account in channelaccounts;
        if (!modes || !modes.length) continue;

        auto occupiedChannel = channel in plugin.state.channels;
        if (!occupiedChannel || !occupiedChannel.ops.canFind(plugin.state.bot.nickname))
        {
            logger.log("We aren't in or we aren't op in the channel we have this automode definition for");
            logger.logf("On %s: +%s %s", channel, *modes, nickname);
            continue;
        }

        plugin.state.raw!(No.quiet)("MODE %s %s%s %s"
            .format(channel, "+".repeat((*modes).length).join, *modes, nickname));
        plugin.appliedAutomodes[channel][account] = true;
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
@Description("Adds an automatic mode change for a user account.",
    "$command [channel] [account/nickname] [mode]")
void onCommandAddAutomode(AutomodePlugin plugin, const IRCEvent event)
{
    if (!plugin.automodeSettings.enabled) return;

    import kameloso.irc : isValidChannel, isValidNickname;
    import kameloso.string : beginsWith, nom;
    import std.algorithm.searching : count;

    if (event.content.count(" ") != 2)
    {
        logger.log("Usage: addmode [channel] [account/nickname] [mode]");
        return;
    }

    string line = event.content;  // need mutable

    immutable channel = line.nom!(Yes.decode)(" ");
    immutable specified = line.nom!(Yes.decode)(" ");

    while (line.beginsWith("+"))
    {
        line.nom!(Yes.decode)("+");
    }

    immutable mode = line;

    if (!channel.isValidChannel(plugin.state.bot.server))
    {
        logger.warning("Invalid channel: ", channel);
        return;
    }
    else if (!specified.isValidNickname(plugin.state.bot.server))
    {
        logger.warning("Invalid account or nickname: ", specified);
        return;
    }
    else if (!mode.length)
    {
        logger.warning("Empty mode");
        return;
    }

    void onSuccess(const string id)
    {
        immutable verb = (channel in plugin.automodes) && (id in plugin.automodes[channel]) ? "updated" : "added";
        plugin.automodes[channel][id] = mode;
        logger.logf("Automode %s! %s on %s: +%s", verb, id, channel, mode);
        plugin.saveAutomodes();
    }

    void onFailure(const IRCUser failureUser)
    {
        logger.log("(Assuming unauthenticated nickname or offline account was specified)");
        return onSuccess(failureUser.nickname);
    }

    if (const userOnRecord = specified in plugin.state.users)
    {
        if (userOnRecord.account.length)
        {
            return onSuccess(userOnRecord.nickname);
        }
    }

    // WHOIS the supplied nickname and get its account, then add it.
    // Assume the supplied nickname *is* the account if no match, error out if
    // there is a match but the user isn't logged onto services.

    mixin WHOISFiberDelegate!(onSuccess, onFailure);

    enqueueAndWHOIS(specified);
}


// onCommandClearAutomode
/++
 +  Clears an automode definition for an account-channel pair.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "clearmodes")
@BotCommand(NickPolicy.required, "delmodes")
@Description("Clears any automatic mode change definitions for an account in a channel.",
    "$command [channel] [account]")
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
        logger.log("No automodes defined for channel ", channel);
    }
}


// onCommandPrintModes
/++
 +  Prints the current automodes associative array to the local terminal.
 +
 +  This is for debugging purposes.
 +/
debug
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "printmodes")
@Description("[debug] Prints out automodes definitions to the local terminal.")
void onCommandPrintModes(AutomodePlugin plugin)
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
@(PrivilegeLevel.whitelist)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "hello")
@Description("Forces the bot to attempt to apply automodes.")
void onCommandHello(AutomodePlugin plugin, const IRCEvent event)
{
    if (event.sender.account.length)
    {
        plugin.applyAutomodes(event.sender.nickname, event.sender.account);
    }
}


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
        (*channelApplications).remove(event.sender.account);
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


// onEndOfMotd
/++
 +  Populate automodes array after we have successfully logged onto the server.
 +/
@(IRCEvent.Type.RPL_ENDOFMOTD)
@(IRCEvent.Type.ERR_NOMOTD)
void onEndOfMotd(AutomodePlugin plugin)
{
    plugin.populateAutomodes();
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

    /// The file to read and save automode definitions from/to.
    @Resource string automodeFile = "automodes.json";

    mixin IRCPluginImpl;
}
