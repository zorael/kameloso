/++
    The Automode plugin handles automatically setting the modes of users in a
    channel. The common use-case is to have someone be automatically set to `+o`
    (operator) when joining.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#automode
        [kameloso.plugins.common.core|plugins.common.core]
        [kameloso.plugins.common.misc|plugins.common.misc]
 +/
module kameloso.plugins.automode;

version(WithAutomodePlugin):

private:

import kameloso.plugins.common.core;
import kameloso.plugins.common.awareness : ChannelAwareness, UserAwareness;
import kameloso.common : logger;
import kameloso.messaging;
import dialect.defs;
import std.typecons : Flag, No, Yes;


// AutomodeSettings
/++
    All Automode settings gathered in a struct.
 +/
@Settings struct AutomodeSettings
{
    /// Toggles whether or not the plugin should react to events at all.
    @Enabler bool enabled = true;
}


// saveAutomodes
/++
    Saves automode definitions to disk.

    Use JSON to get a pretty-printed list, then write it to disk.

    Params:
        plugin = The current [AutomodePlugin].
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
    Ensures that there is an automodes file, creating one if there isn't.
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
        import kameloso.plugins.common.misc : IRCPluginInitialisationException;

        version(PrintStacktraces) logger.trace(e);
        throw new IRCPluginInitialisationException(
            "Automodes file is malformed",
            plugin.name,
            plugin.automodeFile,
            __FILE__,
            __LINE__);
    }

    // Let other Exceptions pass.

    // Adjust saved JSON layout to be more easily edited
    json.save(plugin.automodeFile);
}


// onAccountInfo
/++
    Potentially applies an automode, depending on the definitions and the user
    triggering the function.

    Different [dialect.defs.IRCEvent.Type|IRCEvent.Type]s have to be handled differently,
    as the triggering user may be either the sender or the target.

    Additionally none of these events carry a channel, so we'll have to make
    manual checks to see if the user is in a home channel we're in. Otherwise
    there's nothing for the bot to do.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.ACCOUNT)
    .onEvent(IRCEvent.Type.RPL_WHOISACCOUNT)
    .onEvent(IRCEvent.Type.RPL_WHOISREGNICK)
    .onEvent(IRCEvent.Type.RPL_WHOISUSER)
    .permissionsRequired(Permissions.ignore)
)
void onAccountInfo(AutomodePlugin plugin, const ref IRCEvent event)
{
    // In case of self WHOIS results, don't automode ourselves
    // target for WHOIS, sender for ACCOUNT
    if ((event.target.nickname == plugin.state.client.nickname) ||
        (event.sender.nickname == plugin.state.client.nickname)) return;

    string account;
    string nickname;

    with (IRCEvent.Type)
    switch (event.type)
    {
    case ACCOUNT:
        if (!event.sender.account.length) return;
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
        assert(0, "Invalid `onEvent` type annotation on `" ~ __FUNCTION__ ~ '`');
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
    Applies automodes upon someone joining a home channel.

    [applyAutomodes] will cautiously probe whether there are any definitions to
    apply, so there's little sense in doing it here as well. Just pass the
    arguments and let it look things up.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.JOIN)
    .permissionsRequired(Permissions.anyone)
    .channelPolicy(ChannelPolicy.home)
)
void onJoin(AutomodePlugin plugin, const ref IRCEvent event)
{
    if (event.sender.account.length)
    {
        plugin.applyAutomodes(event.channel, event.sender.nickname, event.sender.account);
    }
}


// applyAutomodes
/++
    Applies automodes for a specific user in a specific channel.

    Params:
        plugin = The current [AutomodePlugin]
        channelName = String channel to apply the modes in.
        nickname = String nickname of the user to apply modes to.
        account = String account of the user, to look up definitions for.
 +/
void applyAutomodes(
    AutomodePlugin plugin,
    const string channelName,
    const string nickname,
    const string account)
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
            if (!usersWithThisMode.length || !(*usersWithThisMode).canFind(nickname))
            {
                // User doesn't have this mode
                missingModes ~= mode;
            }
        }
        else
        {
            // No one has this mode, which by implication means the user doesn't either
            missingModes ~= mode;
        }
    }

    if (!missingModes.length) return;

    if (!channel.ops.canFind(plugin.state.client.nickname))
    {
        enum pattern = "Could not apply <i>+%s</> <i>%s</> in <i>%s</> " ~
            "because we are not an operator in the channel.";
        return logger.logf(pattern, missingModes, nickname, channelName);
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

    receive(
        (Message m)
        {
            assert((m.event.type == IRCEvent.Type.MODE), Enum!(IRCEvent.Type).toString(m.event.type));
            assert((m.event.channel == "#channel"), m.event.channel);
            assert((m.event.aux == "+ov"), m.event.aux);
            assert((m.event.content == "mydude"), m.event.content);
            assert(m.properties == Message.Property.init);

            immutable line = "MODE %s %s %s".format(m.event.channel, m.event.aux, m.event.content);
            assert((line == "MODE #channel +ov mydude"), line);
        }
    );
}


// onCommandAutomode
/++
    Lists current automodes for a user in the current channel, clears them,
    or adds new ones depending on the verb passed.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.operator)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("automode")
            .policy(PrefixPolicy.prefixed)
            .description("Adds, lists or removes automode definitions for the current channel.")
            .addSyntax("$command add [account] [mode]")
            .addSyntax("$command clear [account]")
            .addSyntax("$command list")
    )
)
void onCommandAutomode(AutomodePlugin plugin, const /*ref*/ IRCEvent event)
{
    import dialect.common : isValidNickname;
    import lu.string : SplitResults, beginsWith, nom, splitInto, stripped;
    import std.algorithm.searching : count;
    import std.format : format;

    void sendInvalidNickname()
    {
        enum message = "Invalid nickname.";
        chan(plugin.state, event.channel, message);
    }

    string line = event.content.stripped;  // mutable
    immutable verb = line.nom!(Yes.inherit)(' ');

    switch (verb)
    {
    case "add":
        // !automode add nickname mode
        string nickname;
        string mode;

        immutable result = line.splitInto(nickname, mode);
        if (result != SplitResults.match) goto default;

        if (nickname.beginsWith('@')) nickname = nickname[1..$];

        if (!nickname.isValidNickname(plugin.state.server)) return sendInvalidNickname();

        if (mode.beginsWith('-'))
        {
            enum message = "Automodes cannot be negative.";
            return chan(plugin.state, event.channel, message);
        }

        while (mode.beginsWith('+'))
        {
            mode = mode[1..$];
        }

        if (!mode.length)
        {
            enum message = "You must supply a valid mode.";
            return chan(plugin.state, event.channel, message);
        }

        plugin.modifyAutomode(Yes.add, nickname, event.channel, mode);

        enum pattern = "Automode modified! <h>%s<h> in <b>%s<b>: +<b>%s<b>";
        immutable message = pattern.format(nickname, event.channel, mode);
        chan(plugin.state, event.channel, message);
        break;

    case "clear":
    case "del":
        string nickname = line;  // mutable
        if (nickname.beginsWith('@')) nickname = nickname[1..$];

        if (!nickname.length) goto default;

        if (!nickname.isValidNickname(plugin.state.server)) return sendInvalidNickname();

        plugin.modifyAutomode(No.add, nickname, event.channel);

        enum pattern = "Automode for <h>%s<h> cleared.";
        immutable message = pattern.format(nickname);
        chan(plugin.state, event.channel, message);
        break;

    case "list":
        const channelmodes = event.channel in plugin.automodes;

        if (channelmodes)
        {
            import std.conv : text;
            immutable message = text("Current automodes: ", *channelmodes);
            chan(plugin.state, event.channel, message);
        }
        else
        {
            enum pattern = "No automodes defined for channel <b>%s<b>.";
            immutable message = pattern.format(event.channel);
            chan(plugin.state, event.channel, message);
        }
        break;

    default:
        enum pattern = "Usage: <b>%s%s<b> [add|clear|list] [nickname/account] [mode]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
        chan(plugin.state, event.channel, message);
        break;
    }
}


// modifyAutomode
/++
    Modifies an automode entry by adding a new one or removing a (potentially)
    existing one.

    Params:
        plugin = The current [AutomodePlugin].
        add = Whether to add or to remove the automode.
        nickname = The nickname of the user to add the automode for.
        channelName = The channel the automode should play out in.
        mode = The mode string, when adding a new automode.
 +/
void modifyAutomode(
    AutomodePlugin plugin,
    const Flag!"add" add,
    const string nickname,
    const string channelName,
    const string mode = string.init)
in ((!add || mode.length), "Tried to add an empty automode")
{
    import kameloso.plugins.common.mixins : WHOISFiberDelegate;

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
        logger.trace("(Assuming unauthenticated nickname or offline account was specified)");
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
    Triggers a WHOIS of the user invoking it with bot commands.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.ignore)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("op")
            .policy(PrefixPolicy.prefixed)
            .description("Forces the bot to attempt to apply automodes.")
    )
)
void onCommandOp(AutomodePlugin plugin, const ref IRCEvent event)
{
    if (event.sender.account.length)
    {
        plugin.applyAutomodes(event.channel, event.sender.nickname, event.sender.account);
    }
    else
    {
        import kameloso.messaging : whois;
        whois(plugin.state, event.sender.nickname, Yes.force);
    }
}


// onWelcome
/++
    Populate automodes array after we have successfully logged onto the server.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WELCOME)
)
void onWelcome(AutomodePlugin plugin)
{
    plugin.reload();
}


// reload
/++
    Reloads automode definitions from disk.
 +/
void reload(AutomodePlugin plugin)
{
    import lu.json : JSONStorage, populateFromJSON;

    JSONStorage automodesJSON;
    automodesJSON.load(plugin.automodeFile);
    plugin.automodes.clear();
    plugin.automodes.populateFromJSON(automodesJSON, Yes.lowercaseKeys);
    plugin.automodes = plugin.automodes.rehash();
}


// onMode
/++
    Applies automodes in a channel upon being given operator privileges.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.MODE)
    .channelPolicy(ChannelPolicy.home)
)
void onMode(AutomodePlugin plugin, const ref IRCEvent event)
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
    Prunes empty channels in the automodes definitions associative array.

    Params:
        automodes = Associative array of automodes to prune.
 +/
void pruneChannels(ref string[string][string] automodes)
{
    import lu.objmanip : pruneAA;
    pruneAA(automodes);
}


mixin UserAwareness;
mixin ChannelAwareness;
mixin ModuleRegistration;

public:


// AutomodePlugin
/++
    The Automode plugin automatically changes modes of users in channels as per
    saved definitions.

    Definitions are saved in a JSON file.
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


    // isEnabled
    /++
        Override
        [kameloso.plugins.common.core.IRCPlugin.isEnabled|IRCPlugin.isEnabled]
        (effectively overriding [kameloso.plugins.common.core.IRCPluginImpl.isEnabled|IRCPluginImpl.isEnabled])
        and inject a server check, so this service does nothing on Twitch servers,
        in addition to doing nothing when [AutomodeSettings.enabled] is false.

        Returns:
            `true` if this plugin should react to events; `false` if not.
     +/
    version(TwitchSupport)
    override public bool isEnabled() const @property pure nothrow @nogc
    {
        return (state.server.daemon != IRCServer.Daemon.twitch) && automodeSettings.enabled;
    }

    mixin IRCPluginImpl;
}
