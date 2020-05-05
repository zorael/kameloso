/++
 +  The Automode plugin handles automatically setting the modes of users in a
 +  channel. The common use-case is to have someone be automatically set to `+o`
 +  (operator) when joining.
 +
 +  See the GitHub wiki for more information about available commands:<br>
 +  - https://github.com/zorael/kameloso/wiki/Current-plugins#automode
 +/
module kameloso.plugins.automode;

version(WithPlugins):
version(WithAutomodePlugin):

private:

import kameloso.plugins.core;
import kameloso.plugins.awareness : ChannelAwareness, UserAwareness;
import kameloso.common : Tint, logger;
import kameloso.irccolours : IRCColour, ircBold, ircColour, ircColourByHash;
import kameloso.messaging;
import dialect.defs;
import std.typecons : Flag, No, Yes;


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
    automodes.save!(JSONStorage.KeyOrderStrategy.adjusted)(plugin.automodeFile);
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

        version(PrintStacktraces) logger.trace(e.toString);
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
 +
 +  Additionally none of these events carry a channel, so we'll have to make
 +  manual checks to see if the user is in a home channel we're in. Otherwise
 +  there's nothing for the bot to do.
 +/
@(IRCEvent.Type.ACCOUNT)
@(IRCEvent.Type.RPL_WHOISACCOUNT)
@(IRCEvent.Type.RPL_WHOISREGNICK)
@(IRCEvent.Type.RPL_WHOISUSER)
@(PrivilegeLevel.ignore)
void onAccountInfo(AutomodePlugin plugin, const IRCEvent event)
{
    // In case of self WHOIS results, don't automode ourselves
    if (event.sender.nickname == plugin.state.client.nickname) return;

    string account;
    string nickname;

    with (IRCEvent.Type)
    switch (event.type)
    {
    case ACCOUNT:
        account = event.sender.account;
        nickname = event.sender.nickname;
        break;

    case RPL_WHOISUSER:
        if (plugin.state.settings.preferHostmasks && event.target.account.length)
        {
            // Persistence will have set the account field, if there is any to set.
            goto case RPL_WHOISACCOUNT;
        }
        return;

    case RPL_WHOISACCOUNT:
    case RPL_WHOISREGNICK:
        account = event.target.account;
        nickname = event.target.nickname;
        break;

    default:
        assert(0, "Invalid `IRCEvent.Type` annotation on `" ~ __FUNCTION__ ~ '`');
    }

    foreach (immutable homeChannel; plugin.state.bot.homeChannels)
    {
        if (const channel = homeChannel in plugin.state.channels)
        {
            if (nickname in channel.users)
            {
                plugin.applyAutomodes(homeChannel, nickname, account);
            }
        }
    }
}


// onJoin
/++
 +  Applies automodes upon someone joining a home channel.
 +
 +  `applyAutomodes` will cautiously probe whether there are any definitions to
 +  apply, so there's little sense in doing it here as well. Just pass the
 +  arguments and let it look things up.
 +/
@(IRCEvent.Type.JOIN)
@(PrivilegeLevel.anyone)
@(ChannelPolicy.home)
void onJoin(AutomodePlugin plugin, const IRCEvent event)
{
    if (event.sender.account.length)
    {
        plugin.applyAutomodes(event.channel, event.sender.nickname, event.sender.account);
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


// onCommandAutomode
/++
 +  Lists current automodes for a user in the current channel, clears them,
 +  or adds new ones depending on the verb passed.
 +/
@(IRCEvent.Type.CHAN)
@(PrivilegeLevel.operator)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "automode")
@Description("Adds, lists or removes automode definitions for the current channel.",
    "$command [add|list|clear] [account/nickname] [mode]")
void onCommandAutomode(AutomodePlugin plugin, const IRCEvent event)
{
    import dialect.common : isValidNickname;
    import lu.string : SplitResults, beginsWith, nom, splitInto;
    import std.algorithm.searching : count;

    string line = event.content;  // mutable

    immutable verb = line.nom!(Yes.inherit)(' ');

    switch (verb)
    {
    case "add":
        // !automode add nickname mode
        string nickname;
        string mode;

        immutable result = line.splitInto(nickname, mode);
        if (result != SplitResults.match) goto default;

        if (!nickname.isValidNickname(plugin.state.server))
        {
            chan(plugin.state, event.channel, "Invalid nickname.");
            return;
        }

        if (mode.beginsWith('-'))
        {
            chan(plugin.state, event.channel, "Can't add a negative automode.");
            return;
        }

        while (mode.length && (mode[0] == '+'))
        {
            mode = mode[1..$];
        }

        if (!mode.length)
        {
            chan(plugin.state, event.channel, "You must supply a valid mode.");
            return;
        }

        plugin.modifyAutomode(Yes.add, nickname, event.channel, mode);

        enum pattern = "Automode modified! %s on %s: +%s";

        immutable message = plugin.state.settings.colouredOutgoing ?
            pattern.format(nickname.ircColourByHash.ircBold,
                event.channel.ircBold, mode.ircBold) :
            pattern.format(nickname, event.channel, mode);

        chan(plugin.state, event.channel, message);
        break;

    case "clear":
    case "del":
        immutable nickname = line;

        if (!nickname.length) goto default;

        if (!nickname.isValidNickname(plugin.state.server))
        {
            chan(plugin.state, event.channel, "Invalid nickname.");
            return;
        }

        plugin.modifyAutomode(No.add, nickname, event.channel);

        enum pattern = "Automode for %s cleared.";

        immutable message = plugin.state.settings.colouredOutgoing ?
            pattern.format(nickname.ircColourByHash.ircBold) :
            pattern.format(nickname);

        chan(plugin.state, event.channel, message);
        break;

    case "list":
        const channelmodes = event.channel in plugin.automodes;

        if (channelmodes)
        {
            import std.conv : to;
            chan(plugin.state, event.channel, "Current automodes: " ~ (*channelmodes).to!string);
        }
        else
        {
            chan(plugin.state, event.channel, "No automodes defined for channel %s."
                .format(event.channel));
        }
        break;

    default:
        chan(plugin.state, event.channel, "Usage: %s%s [add|clear|list] [nickname/account] [mode]"
            .format(plugin.state.settings.prefix, event.aux));
        break;
    }
}


// modifyAutomode
/++
 +  Modifies an automode entry by adding a new one or removing a (potentially)
 +  existing one.
 +
 +  Params:
 +      plugin = The current `AutomodePlugin`.
 +      add = Whether to add or to remove the automode.
 +      nickname = The nickname of the user to add the automode for.
 +      channelName = The channel the automode should play out in.
 +      mode = The mode string, when adding a new automode.
 +/
void modifyAutomode(AutomodePlugin plugin, Flag!"add" add, const string nickname,
    const string channelName, const string mode = string.init)
in ((!add || mode.length), "Tried to add an empty automode")
{
    import kameloso.plugins.common : WHOISFiberDelegate;

    void onSuccess(const string id)
    {
        if (add)
        {
            plugin.automodes[channelName][id] = mode;
        }
        else
        {
            auto channelmodes = channelName in plugin.automodes;
            if (!channelmodes) return;

            if (id in *channelmodes)
            {
                (*channelmodes).remove(id);
            }
        }

        plugin.saveAutomodes();
    }

    void onFailure(const IRCUser failureUser)
    {
        logger.log("(Assuming unauthenticated nickname or offline account was specified)");
        return onSuccess(failureUser.nickname);
    }

    if (const userOnRecord = nickname in plugin.state.users)
    {
        if (userOnRecord.account.length)
        {
            return onSuccess(userOnRecord.account);
        }
    }

    // WHOIS the supplied nickname and get its account, then add it.
    // Assume the supplied nickname *is* the account if no match, error out if
    // there is a match but the user isn't logged onto services.

    mixin WHOISFiberDelegate!(onSuccess, onFailure);

    enqueueAndWHOIS(nickname);
}


// onCommandOp
/++
 +  Triggers a WHOIS of the user invoking it with bot commands.
 +
 +  The `kameloso.plugins.core.PrivilegeLevel.anyone` annotation is to
 +  force the bot to evaluate whether an automode should be applied or not.
 +/
@(IRCEvent.Type.CHAN)
@(PrivilegeLevel.ignore)
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

    if ((event.sender.nickname == plugin.state.client.nickname) ||
        (event.target.nickname != plugin.state.client.nickname))
    {
        // Sender is us or target is not us (e.g. it cannot possibly be us becoming +o)
        return;
    }

    if (!plugin.state.channels[event.channel].ops
        .canFind(plugin.state.client.nickname)) return;

    auto accountmodes = event.channel in plugin.automodes;
    if (!accountmodes) return;

    foreach (immutable account; accountmodes.byKey)
    {
        import std.algorithm.iteration : filter;

        auto usersWithThatAccount = plugin.state.users
            .byValue
            .filter!(user => user.account == account);

        if (usersWithThatAccount.empty) continue;

        foreach (const user; usersWithThatAccount)
        {
            // There can technically be more than one
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
     +  Override `kameloso.plugins.core.IRCPluginImpl.onEvent` and inject
     +  a server check, so this plugin does nothing on Twitch servers.
     +  The function to call is `kameloso.plugins.core.IRCPluginImpl.onEventImpl`.
     +
     +  Params:
     +      event = Parsed `dialect.defs.IRCEvent` to pass onto
     +          `kameloso.plugins.core.IRCPluginImpl.onEventImpl`
     +          after verifying we're not on a Twitch server.
     +/
    version(TwitchSupport)
    override public void onEvent(const IRCEvent event)
    {
        if (state.server.daemon == IRCServer.Daemon.twitch)
        {
            // Daemon is known to be Twitch
            return;
        }

        return onEventImpl(event);
    }
}
