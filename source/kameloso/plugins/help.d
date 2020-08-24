/++
 +  The Help plugin serves the `help` command, and nothing else at this point.
 +
 +  It is used to query the bot for available commands in a tidy list.
 +
 +  See the GitHub wiki for more information about available commands:
 +  - https://github.com/zorael/kameloso/wiki/Current-plugins#help
 +/
module kameloso.plugins.help;

version(WithPlugins):
version(WithHelpPlugin):

private:

import kameloso.plugins.core;
import kameloso.plugins.awareness : MinimalAuthentication;
import kameloso.common : logger;
import kameloso.messaging;
import dialect.defs;


// HelpSettings
/++
 +  Settings for the Help plugin, to toggle it enabled or disabled.
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
 +  Sends a list of all plugins' commands to the requesting user.
 +
 +  Plugins don't know about other plugins; the only thing they know of the
 +  outside world is the thread ID of the main thread `mainThread` (stored in
 +  `kameloso.plugins.core.IRCPluginState`). As such, we can't easily query
 +  each plugin for their `kameloso.plugins.core.BotCommand`-annotated functions.
 +
 +  To work around this we construct a
 +  `kameloso.thread.CarryingFiber!(kameloso.plugins.core.IRCPlugin[])` and send it
 +  to the main thread. It will attach the client-global `plugins` array of
 +  `kameloso.plugins.core.IRCPlugin`s to it, and invoke the Fiber.
 +  The delegate inside will then process the list as if it had taken the array
 +  as an argument.
 +
 +  Once we have the list we format it nicely and send it back to the requester,
 +  which we remember since we saved the original `dialect.defs.IRCEvent`.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.anyone)
@BotCommand(PrefixPolicy.prefixed, "help")
@Description("Shows a list of all available commands.", "$command [plugin] [command]")
void onCommandHelp(HelpPlugin plugin, const IRCEvent event)
{
    import kameloso.irccolours : ircBold;
    import kameloso.thread : CarryingFiber, ThreadMessage;
    import std.concurrency : send;

    /// Get non-hidden command keys for a plugin.
    static string[] getUnhiddenCommandKeys(const IRCPlugin thisPlugin)
    {
        import std.algorithm.iteration : filter, map;
        import std.algorithm.sorting : sort;
        import std.array : array;

        return thisPlugin.commands
            .byKeyValue
            .filter!(kv => !kv.value.hidden)
            .map!(kv => kv.key)
            .array
            .sort
            .array;
    }

    void dg()
    {
        import lu.string : beginsWith, contains, nom;
        import core.thread : Fiber;
        import std.format : format;
        import std.typecons : No, Yes;

        auto thisFiber = cast(CarryingFiber!(IRCPlugin[]))(Fiber.getThis);
        assert(thisFiber, "Incorrectly cast Fiber: " ~ typeof(thisFiber).stringof);
        const plugins = thisFiber.payload;

        IRCEvent mutEvent = event;  // mutable
        if (plugin.helpSettings.repliesInQuery) mutEvent.channel = string.init;

        if (mutEvent.content.length)
        {
            if (mutEvent.content.contains!(Yes.decode)(" "))
            {
                string slice = mutEvent.content;
                immutable specifiedPlugin = slice.nom!(Yes.decode)(" ");
                immutable specifiedCommand = slice;

                foreach (p; plugins)
                {
                    if (p.name != specifiedPlugin) continue;

                    if (const command = specifiedCommand in p.commands)
                    {
                        plugin.sendCommandHelp(p, mutEvent, specifiedCommand, command.desc);
                    }
                    else
                    {
                        enum pattern = "No help available for command %s of plugin %s";

                        immutable message = plugin.state.settings.colouredOutgoing ?
                            pattern.format(specifiedCommand.ircBold, specifiedPlugin.ircBold) :
                            pattern.format(specifiedCommand, specifiedPlugin);

                        privmsg(plugin.state, mutEvent.channel, mutEvent.sender.nickname, message);
                    }

                    return;
                }

                immutable message = plugin.state.settings.colouredOutgoing ?
                    "No such plugin: " ~ specifiedPlugin.ircBold :
                    "No such plugin: " ~ specifiedPlugin;

                privmsg(plugin.state, mutEvent.channel, mutEvent.sender.nickname, message);
            }
            else
            {
                if (mutEvent.content.beginsWith(plugin.state.settings.prefix))
                {
                    // Not a plugin, just a command (probably)
                    string slice = mutEvent.content;
                    slice.nom!(Yes.decode)(plugin.state.settings.prefix);
                    immutable specifiedCommand = slice;

                    foreach (p; plugins)
                    {
                        if (const command = specifiedCommand in p.commands)
                        {
                            plugin.sendCommandHelp(p, mutEvent, specifiedCommand, command.desc);
                            return;
                        }
                    }

                    // If we're here there were no command matches
                    // Drop down and treat as normal
                }

                foreach (p; plugins)
                {
                    if (p.name != mutEvent.content)
                    {
                        continue;
                    }
                    else if (!p.commands.length)
                    {
                        immutable message = plugin.state.settings.colouredOutgoing ?
                            "No commands available for plugin " ~ mutEvent.content.ircBold :
                            "No commands available for plugin " ~ mutEvent.content;

                        privmsg(plugin.state, mutEvent.channel, mutEvent.sender.nickname, message);
                        return;
                    }

                    enum width = 12;
                    enum pattern = "* %-*s %-([%s]%| %)";
                    const keys = getUnhiddenCommandKeys(p);

                    immutable message = plugin.state.settings.colouredOutgoing ?
                        pattern.format(width, p.name.ircBold, keys) :
                        pattern.format(width, p.name, keys);

                    privmsg(plugin.state, mutEvent.channel, mutEvent.sender.nickname, message);
                    return;
                }

                immutable message = plugin.state.settings.colouredOutgoing ?
                    "No such plugin: " ~ mutEvent.content.ircBold :
                    "No such plugin: " ~ mutEvent.content;

                privmsg(plugin.state, mutEvent.channel, mutEvent.sender.nickname, message);
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

            foreach (p; plugins)
            {
                if (!p.commands.length) continue;  // command-less plugin/service

                enum width = 12;
                enum pattern = "* %-*s %-([%s]%| %)";
                const keys = getUnhiddenCommandKeys(p);

                immutable message = plugin.state.settings.colouredOutgoing ?
                    pattern.format(width, p.name.ircBold, keys) :
                    pattern.format(width, p.name, keys);

                privmsg(plugin.state, mutEvent.channel, mutEvent.sender.nickname, message);
            }

            enum pattern = "Use %s [%s] [%s] for information about a command.";
            enum colouredLine = pattern.format("help".ircBold,
                "plugin".ircBold, "command".ircBold);

            immutable message = plugin.state.settings.colouredOutgoing ?
                colouredLine :
                "Use help [plugin] [command] for information about a command.";

            privmsg(plugin.state, mutEvent.channel, mutEvent.sender.nickname, message);
        }
    }

    auto fiber = new CarryingFiber!(IRCPlugin[])(&dg, 32_768);
    plugin.state.mainThread.send(ThreadMessage.PeekPlugins(), cast(shared)fiber);
}


// sendCommandHelp
/++
 +  Sends the help text for a command to the querying channel or user.
 +
 +  Params:
 +      plugin = The current `HelpPlugin`.
 +      otherPlugin = The plugin that hosts the command we're to send the help text for.
 +      event = The triggering `dialect.defs.IRCEvent`.
 +      command = String of the command we're to send help text for (sans prefix).
 +      description = The `kameloso.plugins.core.Description` that anotates
 +          the command's function.
 +/
void sendCommandHelp(HelpPlugin plugin, const IRCPlugin otherPlugin,
    const IRCEvent event, const string command, const Description description)
{
    import kameloso.irccolours : ircBold;
    import std.format : format;

    enum pattern = "[%s] %s: %s";

    immutable message = plugin.state.settings.colouredOutgoing ?
        pattern.format(otherPlugin.name.ircBold, command.ircBold, description.line) :
        pattern.format(otherPlugin.name, command, description.line);

    privmsg(plugin.state, event.channel, event.sender.nickname, message);

    if (description.syntax.length)
    {
        import lu.string : beginsWith;
        import std.array : replace;

        immutable udaSyntax = description.syntax
            .replace("$nickname", plugin.state.client.nickname)
            .replace("$command", command);

        // Prepend the prefix to non-PrefixPolicy.nickname commands
        immutable prefixedSyntax = description.syntax.beginsWith("$nickname") ?
            udaSyntax : plugin.state.settings.prefix ~ udaSyntax;

        immutable syntax = plugin.state.settings.colouredOutgoing ?
            "Usage".ircBold ~ ": " ~ prefixedSyntax :
            "Usage: " ~ prefixedSyntax;

        privmsg(plugin.state, event.channel, event.sender.nickname, syntax);
    }
}


mixin MinimalAuthentication;

public:


// HelpPlugin
/++
 +  The Help plugin serves the `help` command.
 +
 +  This was originally part of the Chatbot, but it was deemed important enough
 +  to warrant its own plugin, so that the Chatbot could be disabled while
 +  keeping this around.
 +/
final class HelpPlugin : IRCPlugin
{
private:
    /// All Help plugin settings gathered.
    HelpSettings helpSettings;

    mixin IRCPluginImpl;
}
