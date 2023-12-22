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
import kameloso.messaging;
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

    /++
        Whether or not to include prefix in command listing.
     +/
    bool includePrefix = true;
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
    )
)
void onCommandHelp(HelpPlugin plugin, const /*ref*/ IRCEvent event)
{
    import kameloso.thread : CarryingFiber;
    import std.typecons : Tuple;
    import core.thread : Fiber;

    alias Payload = Tuple!(IRCPlugin.CommandMetadata[string][string]);

    void sendHelpDg()
    {
        import lu.string : stripped;
        import std.algorithm.searching : startsWith;
        import std.string : indexOf;

        auto thisFiber = cast(CarryingFiber!Payload)Fiber.getThis;
        assert(thisFiber, "Incorrectly cast Fiber: " ~ typeof(thisFiber).stringof);

        IRCPlugin.CommandMetadata[string][string] allPluginCommands = thisFiber.payload[0];

        IRCEvent mutEvent = event;  // mutable
        mutEvent.content = mutEvent.content.stripped;

        if (plugin.helpSettings.repliesInQuery) mutEvent.channel = string.init;

        if (!mutEvent.content.length)
        {
            // Nothing supplied, send the big list
            return sendFullPluginListing(plugin, mutEvent, allPluginCommands);
        }

        immutable shorthandNicknamePrefix = plugin.state.client.nickname[0..1] ~ ':';
        immutable startsWithPrefix = plugin.state.settings.prefix.length &&
            mutEvent.content.startsWith(plugin.state.settings.prefix);

        if (startsWithPrefix ||
            mutEvent.content.startsWith(plugin.state.client.nickname) ||
            mutEvent.content.startsWith(shorthandNicknamePrefix))
        {
            // Not a plugin, just a prefixed command (probably)
            sendOnlyCommandHelp(plugin, mutEvent, allPluginCommands);
        }
        else if (mutEvent.content.indexOf(' ') != -1)
        {
            import std.algorithm.searching : count;

            if (mutEvent.content.count(' ') == 1)
            {
                // Likely a plugin and a command
                sendPluginCommandHelp(plugin, mutEvent, allPluginCommands);
            }
            else /*if (mutEvent.content.count(' ') > 1)*/
            {
                import lu.string : advancePast;
                import std.format : format;

                // More than two words; too many
                string slice = mutEvent.content;  // mutable
                immutable pluginName = slice.advancePast(' ');
                enum pattern = "Invalid <b>%s<b> plugin command name: <b>%s<b>";
                immutable message = pattern.format(pluginName, slice);
                privmsg(plugin.state, mutEvent.channel, mutEvent.sender.nickname, message);
            }
        }
        else
        {
            // Just one word; print a specified plugin's commands
            sendSpecificPluginListing(plugin, mutEvent, allPluginCommands);
        }
    }

    plugin.state.specialRequests ~= specialRequest!Payload(string.init, &sendHelpDg);
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
    import std.array : replace;
    import std.conv : text;
    import std.format : format;

    auto getHumanlyReadable(const string syntax)
    {
        import lu.string : strippedLeft;

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
    privmsg(plugin.state, event.channel, event.sender.nickname, message);

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
        privmsg(plugin.state, event.channel, event.sender.nickname, usage);
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

    privmsg(plugin.state, event.channel, event.sender.nickname, banner);
    privmsg(plugin.state, event.channel, event.sender.nickname, availableMessage);

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
        privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }

    enum pattern = "Use <b>%s%s<b> [<b>plugin<b>] [<b>command<b>] " ~
        "for information about a command.";
    immutable message = pattern.format(plugin.state.settings.prefix, event.aux[$-1]);
    privmsg(plugin.state, event.channel, event.sender.nickname, message);
}


// sendSpecificPluginListing
/++
    Sends the command help listing for a specific plugin.

    Params:
        plugin = The current [HelpPlugin].
        event = The triggering [dialect.defs.IRCEvent|IRCEvent].
        allPluginCommands = The metadata of all commands for a particular plugin.
 +/
void sendSpecificPluginListing(
    HelpPlugin plugin,
    const ref IRCEvent event,
    /*const*/ IRCPlugin.CommandMetadata[string][string] allPluginCommands)
{
    import lu.string : stripped;
    import std.algorithm.sorting : sort;
    import std.format : format;

    assert(event.content.length, "`sendSpecificPluginListing` was called incorrectly; event content is empty");

    void sendNoCommandOfPlugin(const string specifiedPlugin)
    {
        immutable message = "No commands available for plugin <b>" ~ specifiedPlugin ~ "<b>";
        privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }

    // Just one word; print a specified plugin's commands
    immutable specifiedPlugin = event.content.stripped;

    if (auto pluginCommands = specifiedPlugin in allPluginCommands)
    {
        const nonhiddenCommands = filterHiddenCommands(*pluginCommands);
        if (!nonhiddenCommands.length)
        {
            return sendNoCommandOfPlugin(specifiedPlugin);
        }

        enum width = 12;
        enum pattern = "* <b>%-*s<b> %-([%s]%| %)";
        auto keys = nonhiddenCommands.keys.sort.release();

        foreach (ref key; keys)
        {
            key = addPrefix(plugin, key, nonhiddenCommands[key].policy);
        }

        immutable message = pattern.format(width, specifiedPlugin, keys);
        return privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }
    else
    {
        immutable message = "No such plugin: <b>" ~ event.content ~ "<b>";
        privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }
}


// sendPluginCommandHelp
/++
    Sends the help list of a single command of a specific plugin. Both were supplied.

    Params:
        plugin = The current [HelpPlugin].
        event = The triggering [dialect.defs.IRCEvent|IRCEvent].
        allPluginCommands = The metadata of all commands for this particular plugin.
 +/
void sendPluginCommandHelp(
    HelpPlugin plugin,
    const ref IRCEvent event,
    /*const*/ IRCPlugin.CommandMetadata[string][string] allPluginCommands)
{
    import lu.string : advancePast, stripped;
    import std.format : format;
    import std.string : indexOf;

    assert((event.content.indexOf(' ') != -1),
        "`sendPluginCommandHelp` was called incorrectly; the content does not " ~
        "have a space-separated plugin and command");

    void sendNoHelpForCommandOfPlugin(const string specifiedCommand, const string specifiedPlugin)
    {
        enum pattern = "No help available for command <b>%s<b> of plugin <b>%s<b>";
        immutable message = pattern.format(specifiedCommand, specifiedPlugin);
        privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }

    string slice = event.content.stripped;
    immutable specifiedPlugin = slice.advancePast(' ');
    immutable specifiedCommand = stripPrefix(plugin, slice);

    if (const pluginCommands = specifiedPlugin in allPluginCommands)
    {
        if (const command = specifiedCommand in *pluginCommands)
        {
            sendCommandHelpImpl(
                plugin,
                specifiedPlugin,
                event,
                specifiedCommand,
                *command);
        }
        else
        {
            return sendNoHelpForCommandOfPlugin(specifiedCommand, specifiedPlugin);
        }
    }
    else
    {
        immutable message = "No such plugin: <b>" ~ specifiedPlugin ~ "<b>";
        privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }
}


// sendOnlyCommandHelp
/++
    Sends the help list of a single command of a specific plugin. Only the command
    was supplied, prefixed with the command prefix.

    Params:
        plugin = The current [HelpPlugin].
        event = The triggering [dialect.defs.IRCEvent|IRCEvent].
        allPluginCommands = The metadata of all commands for this particular plugin.
 +/
void sendOnlyCommandHelp(
    HelpPlugin plugin,
    const ref IRCEvent event,
    /*const*/ IRCPlugin.CommandMetadata[string][string] allPluginCommands)
{
    import std.algorithm.searching : startsWith;

    void sendNoCommandSpecified()
    {
        enum message = "No command specified.";
        privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }

    immutable specifiedCommand = stripPrefix(plugin, event.content);

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
    privmsg(plugin.state, event.channel, event.sender.nickname, message);
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
        return plugin.state.settings.prefix.length ?
            plugin.state.settings.prefix ~ word :
            plugin.state.client.nickname[0..1] ~ ':' ~ word;

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
