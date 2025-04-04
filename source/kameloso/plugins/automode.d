/++
    The Automode plugin handles automatically setting the modes of users in a
    channel. The common use-case is to have someone be automatically set to `+o`
    (operator) when joining.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#automode,
        [kameloso.plugins],
        [kameloso.plugins.common]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.automode;

version(WithAutomodePlugin):

private:

import kameloso.plugins;
import kameloso.plugins.common.mixins.awareness;
import kameloso.common : logger;
import kameloso.messaging;
import dialect.defs;


// AutomodeSettings
/++
    All Automode settings gathered in a struct.
 +/
@Settings struct AutomodeSettings
{
    /++
        Toggles whether or not the plugin should react to events at all.
     +/
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
    import lu.array : pruneAA;
    import std.json : JSONValue;
    import std.stdio : File, writeln;

    pruneAA(plugin.automodes);

    immutable serialised = JSONValue(plugin.automodes).toPrettyString;
    File(plugin.automodeFile, "w").writeln(serialised);
}


// initResources
/++
    Ensures that there is an automodes file, creating one if there isn't.
 +/
void initResources(AutomodePlugin plugin)
{
    import asdf.serialization : deserialize;
    import mir.serde : SerdeException;
    import std.file : readText;
    import std.json : JSONValue;
    import std.stdio : File, writeln;

    try
    {
        auto deserialised = plugin.automodeFile
            .readText
            .deserialize!(string[string][string]);

        immutable serialised = JSONValue(deserialised).toPrettyString;
        File(plugin.automodeFile, "w").writeln(serialised);
    }
    catch (SerdeException e)
    {
        version(PrintStacktraces) logger.trace(e);

        throw new IRCPluginInitialisationException(
            message: "Automodes file is malformed",
            pluginName: plugin.name,
            malformedFilename: plugin.automodeFile);
    }
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
void onAccountInfo(AutomodePlugin plugin, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);

    if (event.sender.class_ == IRCUser.Class.blacklist) return;

    // In case of self WHOIS results, don't automode ourselves
    // target for WHOIS, sender for ACCOUNT
    if ((event.target.nickname == plugin.state.client.nickname) ||
        (event.sender.nickname == plugin.state.client.nickname)) return;

    string account;  // mutable
    string nickname;  // mutable

    with (IRCEvent.Type)
    switch (event.type)
    {
    case ACCOUNT:
        if (!event.sender.account.length) return;
        account = event.sender.account;
        nickname = event.sender.nickname;
        break;

    case RPL_WHOISUSER:
        if (plugin.state.coreSettings.preferHostmasks && event.target.account.length)
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
        enum message = "Invalid `onEvent` type annotation on `" ~ __FUNCTION__ ~ '`';
        assert(0, message);
    }

    foreach (immutable homeChannel; plugin.state.bot.homeChannels)
    {
        if (const channel = homeChannel in plugin.state.channels)
        {
            if (nickname in channel.users)
            {
                applyAutomodes(plugin, homeChannel, nickname, account);
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
void onJoin(AutomodePlugin plugin, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);

    if (event.sender.account.length)
    {
        applyAutomodes(
            plugin,
            event.channel.name,
            event.sender.nickname,
            event.sender.account);
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
    import std.string : representation;

    auto accountmodes = channelName in plugin.automodes;
    if (!accountmodes || !accountmodes.length) return;

    const wantedModes = account in *accountmodes;
    if (!wantedModes || !wantedModes.length) return;

    auto channel = channelName in plugin.state.channels;
    if (!channel) return;

    char[] missingModes;

    foreach (const mode; (*wantedModes).representation)
    {
        if (const usersWithThisMode = cast(char)mode in channel.mods)
        {
            if (!usersWithThisMode.length || (nickname !in *usersWithThisMode))
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

    if (plugin.state.client.nickname !in channel.ops)
    {
        enum pattern = "Could not apply <i>+%s</> <i>%s</> in <i>%s</> " ~
            "because we are not an operator in the channel.";
        return logger.logf(pattern, missingModes, nickname, channelName);
    }

    mode(plugin.state, channel.name, "+" ~ missingModes, nickname);
}

unittest
{
    import lu.conv : toString;
    import std.format : format;

    // Only tests the messenger mode call

    IRCPluginState state;

    mode(state, "#channel", "+ov", "mydude");
    immutable m = state.outgoingMessages[][0];

    assert((m.event.type == IRCEvent.Type.MODE), m.event.type.toString);
    assert((m.event.channel.name == "#channel"), m.event.channel.name);
    assert((m.event.aux[0] == "+ov"), m.event.aux[0]);
    assert((m.event.content == "mydude"), m.event.content);
    assert(m.properties == Message.Property.init);

    immutable line = "MODE %s %s %s".format(m.event.channel.name, m.event.aux[0], m.event.content);
    assert((line == "MODE #channel +ov mydude"), line);
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
void onCommandAutomode(AutomodePlugin plugin, const IRCEvent event)
{
    import dialect.common : isValidNickname;
    import lu.string : SplitResults, advancePast, splitInto, stripped;
    import std.algorithm.searching : count, startsWith;
    import std.format : format;

    mixin(memoryCorruptionCheck);

    void sendUsage()
    {
        enum pattern = "Usage: <b>%s%s<b> [add|clear|list] [nickname/account] [mode]";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel.name, message);
    }

    void sendInvalidNickname()
    {
        enum message = "Invalid nickname.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendCannotBeNegative()
    {
        enum message = "Automodes cannot be negative.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendMustSupplyMode()
    {
        enum message = "You must supply a valid mode.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendAutomodeModified(const string nickname, const string mode)
    {
        enum pattern = "Automode modified! <h>%s<h> in <b>%s<b>: +<b>%s<b>";
        immutable message = pattern.format(nickname, event.channel.name, mode);
        chan(plugin.state, event.channel.name, message);
    }

    void sendAutomodeCleared(const string nickname)
    {
        enum pattern = "Automode for <h>%s<h> cleared.";
        immutable message = pattern.format(nickname);
        chan(plugin.state, event.channel.name, message);
    }

    void sendAutomodeList(/*const*/ string[string] channelModes)
    {
        import std.conv : text;
        immutable message = text("Current automodes: ", channelModes);
        chan(plugin.state, event.channel.name, message);
    }

    void sendNoAutomodes()
    {
        enum pattern = "No automodes defined for channel <b>%s<b>.";
        immutable message = pattern.format(event.channel.name) ;
        chan(plugin.state, event.channel.name, message);
    }

    string line = event.content.stripped;  // mutable
    immutable verb = line.advancePast(' ', inherit: true);

    switch (verb)
    {
    case "add":
        // !automode add nickname mode
        string nickname;  // mutable
        string mode;  // mutable
        immutable result = line.splitInto(nickname, mode);
        if (result != SplitResults.match) goto default;

        if (mode.startsWith('-')) return sendCannotBeNegative();
        if (nickname.startsWith('@')) nickname = nickname[1..$];
        if (!nickname.length) goto default;
        if (!nickname.isValidNickname(plugin.state.server)) return sendInvalidNickname();

        while (mode.startsWith('+')) mode = mode[1..$];
        if (!mode.length) return sendMustSupplyMode();

        modifyAutomode(plugin, add: true, nickname, event.channel.name, mode);
        return sendAutomodeModified(nickname, mode);

    case "clear":
    case "del":
        string nickname = line;  // mutable

        if (nickname.startsWith('@')) nickname = nickname[1..$];
        if (!nickname.length) goto default;
        //if (!nickname.isValidNickname(plugin.state.server)) return sendInvalidNickname();

        modifyAutomode(plugin, add: false, nickname, event.channel.name);
        return sendAutomodeCleared(nickname);

    case "list":
        if (auto channelModes = event.channel.name in plugin.automodes)
        {
            // No const to get a better std.conv.text representation of it
            return sendAutomodeList(*channelModes);
        }
        else
        {
            return sendNoAutomodes();
        }

    default:
        return sendUsage();
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
    const bool add,
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
            (*channelmodes).remove(id);
        }

        saveAutomodes(plugin);
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
void onCommandOp(AutomodePlugin plugin, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);

    //if (event.sender.class_ == IRCUser.Class.blacklist) return;

    if (event.sender.account.length)
    {
        applyAutomodes(plugin, event.channel.name, event.sender.nickname, event.sender.account);
    }
    else
    {
        import kameloso.messaging : whois;
        enum properties = Message.Property.forced;
        whois(plugin.state, event.sender.nickname, properties);
    }
}


// onWelcome
/++
    Populate automodes array after we have successfully logged onto the server.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WELCOME)
)
void onWelcome(AutomodePlugin plugin, const IRCEvent _)
{
    mixin(memoryCorruptionCheck);
    loadAutomodes(plugin);
}


// reload
/++
    Reloads automode definitions from disk.
 +/
void reload(AutomodePlugin plugin)
{
    loadAutomodes(plugin);
}


// loadAutomodes
/++
    Loads automode definitions from disk.
 +/
void loadAutomodes(AutomodePlugin plugin)
{
    import asdf.serialization : deserialize;
    import std.file : readText;

    plugin.automodes = plugin.automodeFile.readText.deserialize!(string[string][string]);
    plugin.automodes.rehash();
}


// onMode
/++
    Applies automodes in a channel upon being given operator privileges.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.MODE)
    .channelPolicy(ChannelPolicy.home)
)
void onMode(AutomodePlugin plugin, const IRCEvent event)
{
    import std.algorithm.searching : canFind;

    mixin(memoryCorruptionCheck);

    if ((event.sender.nickname == plugin.state.client.nickname) ||
        (event.target.nickname != plugin.state.client.nickname))
    {
        // Sender is us or target is not us (e.g. it cannot possibly be us becoming +o)
        return;
    }

    if (plugin.state.client.nickname !in plugin.state.channels[event.channel.name].ops) return;

    auto accountmodes = event.channel.name in plugin.automodes;
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
            applyAutomodes(plugin, event.channel.name, user.nickname, user.account);
        }
    }
}


// selftest
/++
    Performs self-tests against another bot.
 +/
version(Selftests)
auto selftest(AutomodePlugin _, Selftester s)
{
    s.send("automode list");
    s.expect("No automodes defined for channel ${channel}.");

    s.send("automode del");
    s.expect("Usage: ${prefix}automode [add|clear|list] [nickname/account] [mode]");

    s.send("automode");
    s.expect("Usage: ${prefix}automode [add|clear|list] [nickname/account] [mode]");

    s.send("automode add $¡$¡ +o");
    s.expect("Invalid nickname.");

    s.send("automode add kameloso -v");
    s.expect("Automodes cannot be negative.");

    s.send("automode add kameloso +");
    s.expect("You must supply a valid mode.");

    s.send("automode add kameloso +o");
    s.expect("Automode modified! kameloso in ${channel}: +o");

    s.send("automode add kameloso +v");
    s.expect("Automode modified! kameloso in ${channel}: +v");

    s.send("automode list");
    s.expectInBody(`"kameloso":"v"`);

    s.send("automode del $¡$¡");
    s.expect("Automode for $¡$¡ cleared.");

    s.send("automode del kameloso");
    s.expect("Automode for kameloso cleared.");

    s.send("automode list");
    s.expect("No automodes defined for channel ${channel}.");

    s.send("automode del flerrp");
    s.expect("Automode for flerrp cleared.");

    return true;
}


mixin UserAwareness;
mixin ChannelAwareness;
mixin PluginRegistration!AutomodePlugin;

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
    /++
        All Automode options gathered.
     +/
    AutomodeSettings settings;

    /++
        Associative array of automodes.
     +/
    string[string][string] automodes;

    /++
        The file to read and save automode definitions from/to.
     +/
    @Resource string automodeFile = "automodes.json";

    // isEnabled
    /++
        Override
        [kameloso.plugins.IRCPlugin.isEnabled|IRCPlugin.isEnabled]
        (effectively overriding [kameloso.plugins.IRCPluginImpl.isEnabled|IRCPluginImpl.isEnabled])
        and inject a server check, so this service does nothing on Twitch servers,
        in addition to doing nothing when [AutomodeSettings.enabled] is false.

        Returns:
            `true` if this plugin should react to events; `false` if not.
     +/
    version(TwitchSupport)
    override public bool isEnabled() const pure nothrow @nogc
    {
        return this.settings.enabled &&
            (this.state.server.daemon != IRCServer.Daemon.twitch);
    }

    mixin IRCPluginImpl;
}
