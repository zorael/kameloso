/++
    The Help plugin serves the `help` command, and nothing else at this point.

    It is used to query the bot for available commands in a tidy list.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#help
        [kameloso.plugins.common.core|plugins.common.core]
        [kameloso.plugins.common.misc|plugins.common.misc]
 +/
module kameloso.plugins.help;

version(WithHelpPlugin):

private:

import kameloso.plugins.common.core;
import kameloso.plugins.common.awareness : MinimalAuthentication;
import kameloso.common : logger;
import kameloso.messaging;
import dialect.defs;


// HelpSettings
/++
    Settings for the Help plugin, to toggle it enabled or disabled.
 +/
@Settings struct HelpSettings
{
    /// Whether or not the Help plugin should react to events at all.
    @Enabler bool enabled = true;

    /// Whether or not replies are always sent in queries.
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

    To work around this we construct an array of
    `kameloso.thread.CarryingFiber!(kameloso.plugins.common.core.IRCPlugin)`s and send it
    to the main thread. It will attach the client-global `plugins` array of
    [kameloso.plugins.common.core.IRCPlugin|IRCPlugin]s to it, and invoke the Fiber.
    The delegate inside will then process the list as if it had taken the array
    as an argument.

    Once we have the list we format it nicely and send it back to the requester,
    which we remember since we saved the original [dialect.defs.IRCEvent|IRCEvent].
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
            .syntax("$command [plugin] [command]")
    )
)
void onCommandHelp(HelpPlugin plugin, const /*ref*/ IRCEvent event)
{
    import kameloso.thread : ThreadMessage;
    import std.concurrency : send;

    static IRCPlugin.CommandMetadata[string] filterHiddenCommands(IRCPlugin.CommandMetadata[string] aa)
    {
        import std.algorithm.iteration : filter;
        import std.array : assocArray, byPair;

        return aa
            .byPair
            .filter!(pair => !pair[1].hidden)
            .assocArray;
    }

    void dg(IRCPlugin.CommandMetadata[string][string] allPluginCommands)
    {
        import kameloso.irccolours : ircBold;
        import lu.string : beginsWith, contains, nom;
        import std.algorithm.sorting : sort;
        import std.array : array;
        import std.format : format;
        import std.typecons : No, Yes;

        IRCEvent mutEvent = event;  // mutable
        if (plugin.helpSettings.repliesInQuery) mutEvent.channel = string.init;

        if (mutEvent.content.length)
        {
            if (mutEvent.content.beginsWith(plugin.state.settings.prefix))
            {
                // Not a plugin, just a prefixed command (probably)
                immutable specifiedCommand = mutEvent.content[plugin.state.settings.prefix.length..$];

                if (!specifiedCommand.length)
                {
                    // Only a prefix was supplied
                    enum message = "No command specified.";
                    privmsg(plugin.state, mutEvent.channel, mutEvent.sender.nickname, message);
                    return;
                }

                foreach (immutable pluginName, pluginCommands; allPluginCommands)
                {
                    if (const command = specifiedCommand in pluginCommands)
                    {
                        plugin.sendCommandHelp(pluginName, mutEvent, specifiedCommand,
                            command.description, command.syntax);
                        return;
                    }
                }

                // If we're here there were no command matches
                immutable message = plugin.state.settings.colouredOutgoing ?
                    "No such command found: " ~ specifiedCommand.ircBold :
                    "No such command found: " ~ specifiedCommand;

                privmsg(plugin.state, mutEvent.channel, mutEvent.sender.nickname, message);
            }
            else if (mutEvent.content.contains!(Yes.decode)(' '))
            {
                // Likely a plugin and a command
                string slice = mutEvent.content;
                immutable specifiedPlugin = slice.nom!(Yes.decode)(' ');
                immutable specifiedCommand = slice;

                if (const pluginCommands = specifiedPlugin in allPluginCommands)
                {
                    if (const command = specifiedCommand in *pluginCommands)
                    {
                        plugin.sendCommandHelp(specifiedPlugin, mutEvent, specifiedCommand,
                            command.description, command.syntax);
                    }
                    else
                    {
                        enum pattern = "No help available for command %s of plugin %s";

                        immutable message = plugin.state.settings.colouredOutgoing ?
                            pattern.format(specifiedCommand.ircBold, specifiedPlugin.ircBold) :
                            pattern.format(specifiedCommand, specifiedPlugin);

                        privmsg(plugin.state, mutEvent.channel, mutEvent.sender.nickname, message);
                    }
                }
                else
                {
                    immutable message = plugin.state.settings.colouredOutgoing ?
                        "No such plugin: " ~ specifiedPlugin.ircBold :
                        "No such plugin: " ~ specifiedPlugin;

                    privmsg(plugin.state, mutEvent.channel, mutEvent.sender.nickname, message);
                }
            }
            else
            {
                // Just one word; print a specified plugin's commands
                immutable specifiedPlugin = event.content;

                if (auto pluginCommands = specifiedPlugin in allPluginCommands)
                {
                    const nonhiddenCommands = filterHiddenCommands(*pluginCommands);

                    if (!nonhiddenCommands.length)
                    {
                        immutable message = plugin.state.settings.colouredOutgoing ?
                            "No commands available for plugin " ~ mutEvent.content.ircBold :
                            "No commands available for plugin " ~ mutEvent.content;

                        privmsg(plugin.state, mutEvent.channel, mutEvent.sender.nickname, message);
                        return;
                    }

                    enum width = 12;
                    enum pattern = "* %-*s %-([%s]%| %)";
                    const keys = nonhiddenCommands.keys.sort.array;

                    immutable message = plugin.state.settings.colouredOutgoing ?
                        pattern.format(width, specifiedPlugin.ircBold, keys) :
                        pattern.format(width, specifiedPlugin, keys);

                    privmsg(plugin.state, mutEvent.channel, mutEvent.sender.nickname, message);
                    return;
                }
                else
                {
                    immutable message = plugin.state.settings.colouredOutgoing ?
                        "No such plugin: " ~ mutEvent.content.ircBold :
                        "No such plugin: " ~ mutEvent.content;

                    privmsg(plugin.state, mutEvent.channel, mutEvent.sender.nickname, message);
                }
            }
        }
        else
        {
            import kameloso.constants : KamelosoInfo;

            enum bannerUncoloured = "kameloso IRC bot v%s, built %s"
                .format(cast(string)KamelosoInfo.version_,
                    cast(string)KamelosoInfo.built);

            enum bannerColoured = ("kameloso IRC bot v%s".ircBold ~ ", built %s")
                .format(cast(string)KamelosoInfo.version_,
                    cast(string)KamelosoInfo.built);

            immutable banner = plugin.state.settings.colouredOutgoing ?
                bannerColoured : bannerUncoloured;
            privmsg(plugin.state, mutEvent.channel, mutEvent.sender.nickname, banner);
            privmsg(plugin.state, mutEvent.channel, mutEvent.sender.nickname, "Available bot commands per plugin:");

            foreach (immutable pluginName, pluginCommands; allPluginCommands)
            {
                const nonhiddenCommands = filterHiddenCommands(pluginCommands);

                if (!nonhiddenCommands.length) continue;

                enum width = 12;
                enum pattern = "* %-*s %-([%s]%| %)";
                const keys = nonhiddenCommands.keys.sort.array;

                immutable message = plugin.state.settings.colouredOutgoing ?
                    pattern.format(width, pluginName.ircBold, keys) :
                    pattern.format(width, pluginName, keys);

                privmsg(plugin.state, mutEvent.channel, mutEvent.sender.nickname, message);
            }

            enum pattern = "Use %s [%s] [%s] for information about a command.";
            enum colouredLine = pattern.format("help".ircBold,
                "plugin".ircBold, "command".ircBold);
            enum uncolouredLine = "Use help [plugin] [command] for information about a command.";

            immutable message = plugin.state.settings.colouredOutgoing ?
                colouredLine : uncolouredLine;

            privmsg(plugin.state, mutEvent.channel, mutEvent.sender.nickname, message);
        }
    }

    plugin.state.mainThread.send(ThreadMessage.PeekCommands(), cast(shared)&dg);
}

// sendCommandHelp
/++
    Sends the help text for a command to the querying channel or user.

    Params:
        plugin = The current [HelpPlugin].
        otherPluginName = The name of the plugin that hosts the command we're to
            send the help text for.
        event = The triggering [dialect.defs.IRCEvent|IRCEvent].
        command = String of the command we're to send help text for (sans prefix).
        description = The description text that the event handler function is annotated with.
        syntax = The declared syntax of the command.
 +/
void sendCommandHelp(HelpPlugin plugin,
    const string otherPluginName,
    const ref IRCEvent event,
    const string command,
    const string description,
    const string syntax)
{
    import kameloso.irccolours : ircBold;
    import std.conv : text;
    import std.format : format;

    enum pattern = "[%s] %s: %s";

    immutable message = plugin.state.settings.colouredOutgoing ?
        pattern.format(otherPluginName.ircBold, command.ircBold, description) :
        pattern.format(otherPluginName, command, description);

    privmsg(plugin.state, event.channel, event.sender.nickname, message);

    if (syntax.length)
    {
        import lu.string : beginsWith;
        import std.array : replace;

        immutable udaSyntax = syntax
            .replace("$command", command)
            .replace("$nickname", plugin.state.client.nickname)
            .replace("$prefix", plugin.state.settings.prefix);

        // Prepend the prefix to non-PrefixPolicy.nickname commands
        immutable prefixedSyntax =
            (syntax.beginsWith("$nickname") || syntax.beginsWith("$prefix")) ?
                udaSyntax : plugin.state.settings.prefix ~ udaSyntax;

        immutable usage = plugin.state.settings.colouredOutgoing ?
            text("Usage".ircBold, ": ", prefixedSyntax) :
            text("Usage: ", prefixedSyntax);

        privmsg(plugin.state, event.channel, event.sender.nickname, usage);
    }
}


mixin MinimalAuthentication;

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
    /// All Help plugin settings gathered.
    HelpSettings helpSettings;

    mixin IRCPluginImpl;
}
