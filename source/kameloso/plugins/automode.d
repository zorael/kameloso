/++
 +  The Automode plugin handles automatically setting the modes of users in a
 +  channel. The common use-case is to have someone be automatically set to `+o`
 +  (operator) when joining.
 +
 +  See the GitHub wiki for more information about available commands:
 +  - https://github.com/zorael/kameloso/wiki/Current-plugins#automode
 +/
module kameloso.plugins.automode;

version(WithPlugins):
version(WithAutomodePlugin):

private:

import kameloso.plugins.ircplugin;
import kameloso.plugins.common;
import kameloso.plugins.awareness : ChannelAwareness, UserAwareness;
import kameloso.common : Tint, logger, settings;
import kameloso.irccolours : IRCColour, ircBold, ircColour, ircColourByHash;
import kameloso.messaging;
import dialect.defs;
import std.typecons : No, Yes;


// AutomodeSettings
/++
 +  All Automode settings gathered in a struct.
 +/
@Settings struct AutomodeSettings
{
    /// Toggles whether or not the plugin should react to events at all.
    @Enabler bool enabled = true;
}


// saveAutomodes
/++
 +  Saves automode definitions to disk.
 +
 +  Use JSON to get a pretty-printed list, then write it to disk.
 +
 +  Params:
 +      plugin = The current `AutomodePlugin`.
 +/
void saveAutomodes(AutomodePlugin plugin)
{
    import lu.json : JSONStorage;
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
    import lu.json : JSONStorage;
    import std.json : JSONException;

    JSONStorage json;

    try
    {
        json.load(plugin.automodeFile);
    }
    catch (JSONException e)
    {
        import std.path : baseName;
        throw new IRCPluginInitialisationException(plugin.automodeFile.baseName ~ " may be malformed.");
    }

    // Let other Exceptions pass.

    // Adjust saved JSON layout to be more easily edited
    json.save!(JSONStorage.KeyOrderStrategy.adjusted)(plugin.automodeFile);
}


// onAccountInfo
/++
 +  Potentially applies an automode, depending on the definitions and the user
 +  triggering the function.
 +
 +  Different `dialect.defs.IRCEvent.Type`s have to be handled differently,
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
    // In case of self WHOIS results, don't automode ourselves
    if (event.sender.nickname == plugin.state.client.nickname) return;

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
        import kameloso.messaging : whois;
        whois(plugin.state, event.sender.nickname);
        return;

    default:
        assert(0, "Invalid `IRCEvent.Type` annotation on `" ~ __FUNCTION__ ~ '`');
    }

    foreach (immutable channelName, const accountmodes; plugin.automodes)
    {
        if (account in accountmodes)
        {
            plugin.applyAutomodes(channelName, nickname, account);
        }
    }
}


// applyAutomodes
/++
 +  Applies automodes for a specific user in a specific channel.
 +
 +  Params:
 +      plugin = The current `AutomodePlugin`
 +      channelName = String channel to apply the modes in.
 +      nickname = String nickname of the user to apply modes to.
 +      account = String account of the user, to look up definitions for.
 +/
void applyAutomodes(AutomodePlugin plugin, const string channelName,
    const string nickname, const string account)
in (channelName.length, "Tried to apply automodes to an empty channel string")
in (nickname.length, "Tried to apply automodes to an empty nickname")
in (account.length, "Tried to apply automodes to an empty account")
{
    import std.algorithm.searching : canFind;
    import std.string : representation;

    auto accountmodes = channelName in plugin.automodes;
    if (!accountmodes) return;

    const wantedModes = account in *accountmodes;
    if (!wantedModes || !wantedModes.length) return;

    auto channel = channelName in plugin.state.channels;
    if (!channel) return;

    char[] missingModes;

    foreach (const mode; (*wantedModes).representation)
    {
        if (const usersWithThisMode = cast(char)mode in channel.mods)
        {
            if (!usersWithThisMode.length || !(*usersWithThisMode).canFind(account))
            {
                // User doesn't have this mode
                missingModes ~= mode;
            }
        }
        else
        {
            // No one has this mode, which by implication means the user doen't either
            missingModes ~= mode;
        }
    }

    if (!missingModes.length) return;

    if (!channel.ops.canFind(plugin.state.client.nickname))
    {
        logger.log("Could not apply this automode because we are not an operator in the channel:");
        logger.logf("...on %s%s%s: %1$s+%4$s%3$s %1$s%5$s",
            Tint.info, channel.name, Tint.log, missingModes, nickname);

        return;
    }

    mode(plugin.state, channel.name, "+" ~ missingModes, nickname);
}

unittest
{
    import lu.conv : Enum;
    import std.concurrency;
    import std.format : format;

    // Only tests the messenger mode call

    IRCPluginState state;
    state.mainThread = thisTid;

    mode(state, "#channel", "+ov", "mydude");
    immutable event = receiveOnly!IRCEvent;

    assert((event.type == IRCEvent.Type.MODE), Enum!(IRCEvent.Type).toString(event.type));
    assert((event.channel == "#channel"), event.channel);
    assert((event.aux == "+ov"), event.aux);
    assert((event.content == "mydude"), event.content);

    immutable line = "MODE %s %s %s".format(event.channel, event.aux, event.content);
    assert((line == "MODE #channel +ov mydude"), line);
}


// onCommandAddAutomode
/++
 +  Adds an account-channel automode pair definition and saves it to disk.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.operator)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "addmode")
@Description("Adds an automatic mode change for a user account.",
    "$command [channel] [mode] [account/nickname]")
void onCommandAddAutomode(AutomodePlugin plugin, const IRCEvent event)
{
    import dialect.common : isValidChannel, isValidNickname;
    import lu.string : beginsWith, nom;
    import std.algorithm.searching : count;
    import std.uni : toLower;

    if (event.content.count(' ') != 2)
    {
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "Usage: addmode [channel] [mode] [account/nickname]");
            //                       1      2
        return;
    }

    string line = event.content;  // need mutable

    immutable channelName = line.nom!(Yes.decode)(" ").toLower;

    while (line.beginsWith('+'))
    {
        line = line[1..$];
    }

    immutable mode = line.nom!(Yes.decode)(" ");
    immutable specified = line;

    if (!channelName.isValidChannel(plugin.state.server))
    {
        immutable message = settings.colouredOutgoing ?
            "Invalid channel: " ~ channelName.ircColour(IRCColour.red).ircBold :
            "Invalid channel: " ~ channelName;

        privmsg(plugin.state, event.channel, event.sender.nickname, message);
        return;
    }
    else if (!specified.isValidNickname(plugin.state.server))
    {
        immutable message = settings.colouredOutgoing ?
            "Invalid account or nickname: " ~ specified.ircColour(IRCColour.red).ircBold :
            "Invalid account or nickname: " ~ specified;

        privmsg(plugin.state, event.channel, event.sender.nickname, message);
        return;
    }
    else if (!mode.length)
    {
        privmsg(plugin.state, event.channel, event.sender.nickname, "You must supply a mode.");
        return;
    }

    void onSuccess(const string id)
    {
        import std.format : format;

        const accountmodes = channelName in plugin.automodes;
        immutable verb = (accountmodes && (id in *accountmodes)) ? "updated" : "added";

        plugin.automodes[channelName][id] = mode;

        string message;

        if (settings.colouredOutgoing)
        {
            immutable maybeAccount = (specified != id) ?
                " (" ~ id.ircColourByHash.ircBold ~ ')' : string.init;
            message = "Automode %s! %s%s on %s: +%s"
                .format(verb, specified.ircColourByHash.ircBold,
                maybeAccount, channelName.ircBold, mode.ircBold);
        }
        else
        {
            immutable maybeAccount = (specified != id) ?
                " (" ~ id ~ ')' : string.init;
            message = "Automode %s! %s%s on %s: +%s"
                .format(verb, specified, maybeAccount, channelName, mode);
        }

        privmsg(plugin.state, event.channel, event.sender.nickname, message);
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
@(PrivilegeLevel.operator)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "clearmodes")
@BotCommand(PrefixPolicy.prefixed, "delmodes")
@Description("Clears any automatic mode change definitions for an account in a channel.",
    "$command [channel] [account]")
void onCommandClearAutomode(AutomodePlugin plugin, const IRCEvent event)
{
    import lu.string : nom;
    import std.algorithm.searching : count;
    import std.format : format;
    import std.uni : toLower;

    if (event.content.count(' ') != 1)
    {
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "Usage: clearmode [channel] [account]");
            //                         1
        return;
    }

    string line = event.content;  // need mutable

    immutable channelName = line.nom!(Yes.decode)(" ").toLower;
    immutable account = line;

    if (auto channelAutomodes = channelName in plugin.automodes)
    {
        (*channelAutomodes).remove(account);

        enum pattern = "Automode cleared: %s on %s";

        immutable message = settings.colouredOutgoing ?

            pattern.format(account.ircColourByHash.ircBold, channelName.ircBold) :
            pattern.format(account, channelName);

        privmsg(plugin.state, event.channel, event.sender.nickname, message);
        plugin.saveAutomodes();
    }
    else
    {
        immutable message = settings.colouredOutgoing ?
            "No automodes defined for channel " ~ channelName.ircBold :
            "No automodes defined for channel " ~ channelName;

        privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }
}


// onCommandOp
/++
 +  Triggers a WHOIS of the user invoking it with bot commands.
 +
 +  The `kameloso.plugins.common.PrivilegeLevel.anyone` annotation is to
 +  force the bot to evaluate whether an automode should be applied or not.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.anyone)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "op")
@Description("Forces the bot to attempt to apply automodes.")
void onCommandOp(AutomodePlugin plugin, const IRCEvent event)
{
    if (event.sender.account.length)
    {
        plugin.applyAutomodes(event.channel, event.sender.nickname, event.sender.account);
    }
    else
    {
        import kameloso.messaging : whois;
        whois(plugin.state, event.sender.nickname);
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
    import lu.json : JSONStorage, populateFromJSON;

    with (plugin)
    {
        JSONStorage automodesJSON;
        automodesJSON.load(automodeFile);
        //automodes.clear();
        automodes.populateFromJSON(automodesJSON, Yes.lowercaseKeys);
        automodes.rehash();
    }
}


// onMode
/++
 +  Applies automodes in a channel upon being given operator privileges.
 +/
@(IRCEvent.Type.MODE)
@(ChannelPolicy.home)
void onMode(AutomodePlugin plugin, const IRCEvent event)
{
    import std.algorithm.searching : canFind;

    if (!plugin.state.channels[event.channel].ops
        .canFind(plugin.state.client.nickname)) return;

    auto accountmodes = event.channel in plugin.automodes;
    if (!accountmodes) return;

    foreach (immutable account; accountmodes.byKey)
    {
        import std.algorithm.iteration : filter;
        import std.array : array;

        auto usersWithThatAccount = plugin.state.users
            .byValue
            .filter!(user => user.account == account);

        if (usersWithThatAccount.empty) continue;

        foreach (immutable user; usersWithThatAccount)
        {
            plugin.applyAutomodes(event.channel, user.nickname, user.account);
        }
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
    import lu.objmanip : pruneAA;
    pruneAA(automodes);
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
private:
    /// All Automode options gathered.
    AutomodeSettings automodeSettings;

    /// Associative array of automodes.
    string[string][string] automodes;

    /// The file to read and save automode definitions from/to.
    @Resource string automodeFile = "automodes.json";

    mixin IRCPluginImpl;

    /++
     +  Override `kameloso.plugins.common.IRCPluginImpl.onEvent` and inject a server check, so this
     +  plugin does nothing on Twitch servers. The function to call is
     +  `kameloso.plugins.common.IRCPluginImpl.onEventImpl`.
     +
     +  Params:
     +      event = Parsed `dialect.defs.IRCEvent` to pass onto
     +          `kameloso.plugins.common.IRCPluginImpl.onEventImpl`
     +          after verifying we're not on a Twitch server.
     +/
    version(TwitchSupport)
    public void onEvent(const IRCEvent event)
    {
        if (state.server.daemon == IRCServer.Daemon.twitch)
        {
            // Daemon is known to be Twitch
            return;
        }

        return onEventImpl(event);
    }
}
