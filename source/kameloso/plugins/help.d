/++
    The Help plugin serves the `help` command, and nothing else at this point.

    It is used to query the bot for available commands in a tidy list.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#help,
        [kameloso.plugins.common.core],
        [kameloso.plugins.common.misc]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.help;

version(WithHelpPlugin):

private:

import kameloso.plugins;
import kameloso.plugins.common.core;
import kameloso.plugins.common.awareness : MinimalAuthentication;
import kameloso.common : logger;
import kameloso.messaging : Message;
import dialect.defs;
import std.typecons : Flag, No, Yes;


// HelpSettings
/++
    Settings for the Help plugin, to toggle it enabled or disabled.
 +/
@Settings struct HelpSettings
{
    /++
        Whether or not the Help plugin should react to events at all.
     +/
    @Enabler bool enabled = true;

    /++
        Whether or not replies are always sent in queries.
     +/
    bool repliesInQuery = true;
}


// onCommandHelp
/++
    Sends a list of all plugins' commands to the requesting user.

    Plugins don't know about other plugins; the only thing they know of the
    outside world is the thread ID of the main thread ID (stored in
    [kameloso.plugins.common.core.IRCPluginState.mainThread|IRCPluginState.mainThread]).
    As such, we can't easily query each plugin for their
    [kameloso.plugins.common.core.IRCEventHandler.Command|IRCEventHandler.Command]-annotated
    functions.

    To work around this we construct a delegate that accepts an array of
    [kameloso.plugins.common.core.IRCPlugin|IRCPlugins], and pass it to the main thread.
    It will then invoke the delegate with the client-global `plugins` array as argument.

    Once we have the list we format it nicely and send it back to the requester.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.anyone)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("help")
            .policy(PrefixPolicy.prefixed)
            .description("Shows a list of all available commands.")
            .addSyntax("$command [plugin] [command]")
            .addSyntax("$command [prefixed command]")
    )
)
void onCommandHelp(HelpPlugin plugin, const /*ref*/ IRCEvent event)
{
    import std.typecons : Tuple;

    alias Payload = Tuple!
        (IRCPlugin.CommandMetadata[string][string],
        IRCPlugin.CommandMetadata[string][string]);

    void sendHelpDg()
    {
        import kameloso.thread : CarryingFiber;
        import lu.string : splitInto, stripped;
        import core.thread : Fiber;

        auto thisFiber = cast(CarryingFiber!Payload)Fiber.getThis();
        assert(thisFiber, "Incorrectly cast fiber: " ~ typeof(thisFiber).stringof);

        string slice = event.content.stripped;  // mutable

        if (!slice.length)
        {
            // Nothing supplied, send the big list
            return sendFullPluginListing(plugin, event, thisFiber.payload[0]);
        }

        /+
            !help plugin
            !help !command
            !help b:command
            !help botname:command
            !help plugin command
            !help botname: command
         +/

        string first;  // mutable
        string second;  // as above
        cast()slice.splitInto(first, second);

        if (second.length)
        {
            import std.algorithm.searching : count;

            if (!slice.length)
            {
                /+
                    !help plugin command
                    !help botname: command
                    (no third argument)
                 +/
                immutable firstStripped = stripPrefix(plugin, first);

                if (!firstStripped.length)
                {
                    /+
                        !help botname: command
                        The entirety of the first argument was stripped away.
                     +/
                    sendOnlyCommandHelp(plugin, second, event, thisFiber.payload[0]);
                }
                else
                {
                    sendPluginCommandHelp(plugin, first, second, event, thisFiber.payload[0]);
                }
            }
            else /*if (slice.length)*/
            {
                import std.format : format;

                /+
                    !help plugin command tail
                 +/
                enum pattern = "Invalid <b>%s<b> plugin command name: <b>%s<b>";
                immutable message = pattern.format(first, second);
                sendMessage(plugin, event, message);
            }
        }
        else
        {
            /+
                !help plugin
                !help !command
                !help b:command
                !help botname:command
             +/

            immutable firstStripped = stripPrefix(plugin, first);

            if (first == firstStripped)
            {
                /+
                    !help plugin
                 +/
                sendSpecificPluginListing(plugin, first, event, thisFiber.payload[0]);
            }
            else
            {
                /+
                    !help !command
                    !help b:command
                    !help botname:command
                 +/
                sendOnlyCommandHelp(plugin, firstStripped, event, thisFiber.payload[0]);
            }
        }
    }

    defer!Payload(plugin, &sendHelpDg);
}


// sendMessage
/++
    Sends a message to the channel or user that triggered the event.
    If [kameloso.plugins.help.HelpSettings.repliesInQuery|HelpSettings.repliesInQuery]
    is set, we send the message as a query; otherwise we send it to the channel.

    If we're connected to Twitch, we use [kameloso.messaging.reply] instead to
    (possibly) send the message as a whisper, provided the
    [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin] is compiled in.

    Params:
        plugin = The current [HelpPlugin].
        event = The triggering [dialect.defs.IRCEvent|IRCEvent].
        content = Message body content to send.
        properties = Custom message properties, such as [Message.Property.quiet]
            and [Message.Property.forced].
        caller = String name of the calling function, or something else that gives context.
 +/
void sendMessage(
    HelpPlugin plugin,
    /*const*/ /*ref*/ IRCEvent event,
    const string content,
    const Message.Property properties = Message.Property.none,
    const string caller = __FUNCTION__)
{
    import kameloso.messaging : privmsg;

    version(WithTwitchPlugin)
    {
        if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
        {
            import kameloso.messaging : reply;

            event.type = plugin.helpSettings.repliesInQuery ?
                IRCEvent.Type.QUERY :
                IRCEvent.Type.CHAN;

            return reply(
                plugin.state,
                event,
                content,
                properties,
                caller);
        }
    }

    privmsg(
        plugin.state,
        (plugin.helpSettings.repliesInQuery ? string.init : event.channel),
        event.sender.nickname,
        content,
        properties,
        caller);
}


// sendCommandHelpImpl
/++
    Sends the help text for a command to the querying channel or user.

    Params:
        plugin = The current [HelpPlugin].
        otherPluginName = The name of the plugin that hosts the command we're to
            send the help text for.
        event = The triggering [dialect.defs.IRCEvent|IRCEvent].
        commandString = String of the command we're to send help text for (sans prefix).
        command = Actual [kameloso.plugins.common.core.IRCPlugin.CommandMetadata|CommandMetadata]
            of the command we're to send help text for.
 +/
void sendCommandHelpImpl(
    HelpPlugin plugin,
    const string otherPluginName,
    const ref IRCEvent event,
    const string commandString,
    const IRCPlugin.CommandMetadata command)
{
    import std.algorithm.searching : startsWith;
    import std.format : format;

    auto getHumanlyReadable(const string syntax)
    {
        import lu.string : strippedLeft;
        import std.array : replace;

        return syntax
            .replace("$command", commandString)
            .replace("$bot", plugin.state.client.nickname)
            .replace("$prefix", plugin.state.settings.prefix)
            .replace("$nickname", event.sender.nickname)
            .replace("$header", string.init)
            .strippedLeft;
    }

    enum pattern = "[<b>%s<b>] <b>%s<b>: %s";
    immutable message = pattern.format(otherPluginName, commandString, command.description);
    sendMessage(plugin, event, message);

    foreach (immutable syntax; command.syntaxes)
    {
        immutable shouldNotTouch = syntax.startsWith("$header");
        immutable humanlyReadable = getHumanlyReadable(syntax);
        string contentLine;  // mutable

        if (plugin.state.settings.prefix.length && (command.policy == PrefixPolicy.prefixed))
        {
            contentLine = (shouldNotTouch || syntax.startsWith("$prefix")) ?
                humanlyReadable :
                plugin.state.settings.prefix ~ humanlyReadable;
        }
        else if (command.policy == PrefixPolicy.direct)
        {
            contentLine = humanlyReadable;
        }
        else
        {
            // Either PrefixPolicy.nickname or no prefix
            contentLine = shouldNotTouch || syntax.startsWith("$bot") ?
                humanlyReadable :
                plugin.state.client.nickname ~ ": " ~ humanlyReadable;
        }

        immutable usage = (command.syntaxes.length == 1) ?
            "<b>Usage<b>: " ~ contentLine :
            "* " ~ contentLine;
        sendMessage(plugin, event, usage);
    }
}


// sendFullPluginListing
/++
    Sends the help list of all plugins and all commands.

    Params:
        plugin = The current [HelpPlugin].
        event = The triggering [dialect.defs.IRCEvent|IRCEvent].
        allPluginCommands = The metadata of all commands for a particular plugin.
 +/
void sendFullPluginListing(
    HelpPlugin plugin,
    const ref IRCEvent event,
    /*const*/ IRCPlugin.CommandMetadata[string][string] allPluginCommands)
{
    import kameloso.constants : KamelosoInfo;
    import std.algorithm.sorting : sort;
    import std.format : format;

    enum banner = "kameloso IRC bot <b>v" ~
        cast(string)KamelosoInfo.version_ ~
        "<b>, built " ~
        cast(string)KamelosoInfo.built;
    enum availableMessage = "Available bot commands per plugin:";

    sendMessage(plugin, event, banner);
    sendMessage(plugin, event, availableMessage);

    foreach (immutable pluginName, pluginCommands; allPluginCommands)
    {
        const nonhiddenCommands = filterHiddenCommands(pluginCommands);
        if (!nonhiddenCommands.length) continue;

        enum width = 12;
        enum pattern = "* <b>%-*s<b> %-([%s]%| %)";
        auto keys = nonhiddenCommands.keys.sort.release();

        foreach (ref key; keys)
        {
            key = addPrefix(plugin, key, nonhiddenCommands[key].policy);
        }

        immutable message = pattern.format(width, pluginName, keys);
        sendMessage(plugin, event, message);
    }

    enum pattern = "Use <b>%s%s<b> [<b>plugin<b>] [<b>command<b>] " ~
        "for information about a command.";
    immutable message = pattern.format(plugin.state.settings.prefix, event.aux[$-1]);
    sendMessage(plugin, event, message);
}


// sendSpecificPluginListing
/++
    Sends the command help listing for a specific plugin.

    Params:
        plugin = The current [HelpPlugin].
        pluginName = The name of the plugin to send the command listing for.
        event = The triggering [dialect.defs.IRCEvent|IRCEvent].
        allPluginCommands = The metadata of all commands for a particular plugin.
 +/
void sendSpecificPluginListing(
    HelpPlugin plugin,
    const string pluginName,
    const ref IRCEvent event,
    /*const*/ IRCPlugin.CommandMetadata[string][string] allPluginCommands)
{
    import lu.string : stripped;
    import std.algorithm.sorting : sort;
    import std.format : format;

    void sendNoCommandOfPlugin(const string thisPluginName)
    {
        enum pattern = "No commands available for plugin <b>%s<b>";
        immutable message = pattern.format(thisPluginName);
        sendMessage(plugin, event, message);
    }

    if (auto pluginCommands = pluginName in allPluginCommands)
    {
        const nonhiddenCommands = filterHiddenCommands(*pluginCommands);
        if (!nonhiddenCommands.length)
        {
            return sendNoCommandOfPlugin(pluginName);
        }

        enum width = 12;
        enum pattern = "* <b>%-*s<b> %-([%s]%| %)";
        auto keys = nonhiddenCommands
            .keys
            .sort
            .release();

        foreach (ref key; keys)
        {
            key = addPrefix(plugin, key, nonhiddenCommands[key].policy);
        }

        immutable message = pattern.format(width, pluginName, keys);
        sendMessage(plugin, event, message);
    }
    else
    {
        enum pattern = "No such plugin: <b>%s<b>";
        immutable message = pattern.format(pluginName);
        sendMessage(plugin, event, message);
    }
}


// sendPluginCommandHelp
/++
    Sends the help list of a single command of a specific plugin. Both were supplied.

    Params:
        plugin = The current [HelpPlugin].
        pluginName = The name of the plugin that hosts the command we're to
            send the help text for.
        commandName = String of the command we're to send help text for (sans prefix).
        event = The triggering [dialect.defs.IRCEvent|IRCEvent].
        allPluginCommands = The metadata of all commands for this particular plugin.
 +/
void sendPluginCommandHelp(
    HelpPlugin plugin,
    const string pluginName,
    const string commandName,
    const ref IRCEvent event,
    const IRCPlugin.CommandMetadata[string][string] allPluginCommands)
{
    import std.format : format;

    void sendNoHelpForCommandOfPlugin(const string specifiedPlugin, const string specifiedCommand)
    {
        enum pattern = "No help available for command <b>%s<b> of plugin <b>%s<b>";
        immutable message = pattern.format(specifiedCommand, specifiedPlugin);
        sendMessage(plugin, event, message);
    }

    if (const pluginCommands = pluginName in allPluginCommands)
    {
        if (const command = commandName in *pluginCommands)
        {
            sendCommandHelpImpl(
                plugin,
                pluginName,
                event,
                commandName,
                *command);
        }
        else
        {
            return sendNoHelpForCommandOfPlugin(pluginName, commandName);
        }
    }
    else
    {
        enum pattern = "No such plugin: <b>%s<b>";
        immutable message = pattern.format(pluginName);
        sendMessage(plugin, event, message);
    }
}


// sendOnlyCommandHelp
/++
    Sends the help list of a single command of a specific plugin. Only the command
    was supplied, prefixed with the command prefix.

    Params:
        plugin = The current [HelpPlugin].
        commandString = The command string to send help text for (sans prefix).
        event = The triggering [dialect.defs.IRCEvent|IRCEvent].
        allPluginCommands = The metadata of all commands for this particular plugin.
 +/
void sendOnlyCommandHelp(
    HelpPlugin plugin,
    const string commandString,
    const ref IRCEvent event,
    const IRCPlugin.CommandMetadata[string][string] allPluginCommands)
{
    import std.algorithm.searching : startsWith;

    void sendNoCommandSpecified()
    {
        enum message = "No command specified.";
        sendMessage(plugin, event, message);
    }

    immutable specifiedCommand = stripPrefix(plugin, commandString);

    if (!specifiedCommand.length)
    {
        // Only a prefix was supplied
        return sendNoCommandSpecified();
    }

    foreach (immutable pluginName, pluginCommands; allPluginCommands)
    {
        if (const command = specifiedCommand in pluginCommands)
        {
            return sendCommandHelpImpl(
                plugin,
                pluginName,
                event,
                specifiedCommand,
                *command);
        }
    }

    // If we're here there were no command matches
    immutable message = "No such command found: <b>" ~ specifiedCommand ~ "<b>";
    sendMessage(plugin, event, message);
}


// filterHiddenCommands
/++
    Filters out hidden commands from an associative array of [IRCPlugin.CommandMetadata].

    Params:
        aa = An unfiltered associative array of command metadata.

    Returns:
        A filtered associative array of command metadata.
 +/
auto filterHiddenCommands(IRCPlugin.CommandMetadata[string] aa)
{
    import std.algorithm.iteration : filter;
    import std.array : assocArray, byPair;

    return aa
        .byPair
        .filter!(pair => !pair[1].hidden)
        .assocArray;
}


// addPrefix
/++
    Adds a prefix to a command word; the command prefix if the passed `policy` is
    [kameloso.plugins.common.core.PrefixPolicy.prefixed], the bot nickname if it is
    [kameloso.plugins.common.core.PrefixPolicy.nickname], and as is if it is
    [kameloso.plugins.common.core.PrefixPolicy.direct].

    Params:
        plugin = The current [HelpPlugin].
        word = Command word to add a prefix to.
        policy = The prefix policy of the command `word` relates to.

    Returns:
        The passed `word`, optionally with a prefix prepended.
 +/
auto addPrefix(HelpPlugin plugin, const string word, const PrefixPolicy policy)
{
    with (PrefixPolicy)
    final switch (policy)
    {
    case direct:
        return word;

    case prefixed:
        if (!plugin.state.settings.prefix.length) goto case nickname;
        return plugin.state.settings.prefix ~ word;

    case nickname:
        return plugin.state.client.nickname[0..1] ~ ':' ~ word;
    }
}


// stripPrefix
/++
    Strips any prefixes from the passed string; prefixes being the command prefix,
    the bot's nickname, or the shorthand with only the first letter of the bot's nickname.

    Params:
        plugin = The current [HelpPlugin].
        prefixed = The prefixed string, to strip the prefix of.

    Returns:
        The passed `prefixed` string with any prefixes sliced away.
 +/
auto stripPrefix(HelpPlugin plugin, const string prefixed)
{
    import std.algorithm.searching : startsWith;

    static string sliceAwaySeparators(const string orig)
    {
        string slice = orig;  // mutable

        outer:
        while (slice.length > 0)
        {
            switch (slice[0])
            {
            case ':':
            case '!':
            case '?':
            case ' ':
                slice = slice[1..$];
                break;

            default:
                break outer;
            }
        }

        return slice;
    }

    if (prefixed.startsWith(plugin.state.settings.prefix))
    {
        return prefixed[plugin.state.settings.prefix.length..$];
    }
    else if (prefixed.startsWith(plugin.state.client.nickname))
    {
        return sliceAwaySeparators(prefixed[plugin.state.client.nickname.length..$]);
    }
    else if (prefixed.startsWith(plugin.state.client.nickname[0..1] ~ ':'))
    {
        return sliceAwaySeparators(prefixed[2..$]);
    }
    else
    {
        return prefixed;
    }
}


mixin MinimalAuthentication;
mixin PluginRegistration!HelpPlugin;

public:


// HelpPlugin
/++
    The Help plugin serves the `help` command.

    This was originally part of the Chatbot, but it was deemed important enough
    to warrant its own plugin, so that the Chatbot could be disabled while
    keeping this around.
 +/
final class HelpPlugin : IRCPlugin
{
private:
    /++
        All Help plugin settings gathered.
     +/
    HelpSettings helpSettings;

    mixin IRCPluginImpl;
}
