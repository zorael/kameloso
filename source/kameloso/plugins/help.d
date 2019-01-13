/++
 +  The Help plugin serves the `help` command, and nothing else at this point.
 +/
module kameloso.plugins.help;

version(WithPlugins):

private:

import kameloso.plugins.common;
import kameloso.irc.defs;
import kameloso.messaging;
import kameloso.common : logger, settings;


// HelpSettings
/++
 +  Settings for the Help plugin, to toggle it enabled or disabled.
 +/
struct HelpSettings
{
    /// Whether or not the Help plugin should react to events at all.
    @Enabler bool enabled = true;
}


// onCommandHelp
/++
 +  Sends a list of all plugins' commands to the requesting user.
 +
 +  Plugins don't know about other plugins; the only thing they know of the
 +  outside world is the thread ID of the main thread `mainThread` (stored in
 +  `kameloso.plugins.common.IRCPluginState`). As such, we can't easily query
 +  each plugin for their `kameloso.plugins.common.BotCommand`-annotated functions.
 +
 +  To work around this we construct a `CarryingFiber!(IRCPlugin[])` and send it
 +  to the main thread. It will attach the client-global `plugins` array of
 +  `kameloso.plugins.common.IRCPlugin`s to it, and invoke the Fiber.
 +  The delegate inside will then process the list as if it had taken the array
 +  as an argument.
 +
 +  Once we have the list we format it nicely and send it back to the requester,
 +  which we remember since we saved the original `kameloso.irc.defs.IRCEvent`.
 +/
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.CHAN)
@(PrivilegeLevel.whitelist)
@BotCommand(PrefixPolicy.nickname, "help")
@Description("Shows a list of all available commands.", "$command [plugin] [command]")
void onCommandHelp(HelpPlugin plugin, const IRCEvent event)
{
    import kameloso.irc.colours : ircBold;
    import kameloso.thread : CarryingFiber, ThreadMessage;
    import std.concurrency : send;

    void dg()
    {
        import kameloso.string : contains, nom;
        import core.thread : Fiber;
        import std.algorithm.searching : endsWith;
        import std.algorithm.sorting : sort;
        import std.format : format;
        import std.typecons : No, Yes;

        auto thisFiber = cast(CarryingFiber!(IRCPlugin[]))(Fiber.getThis);
        assert(thisFiber, "Incorrectly cast fiber: " ~ typeof(thisFiber).stringof);
        const plugins = thisFiber.payload;

        with (event)
        if (content.length)
        {
            if (content.contains!(Yes.decode)(" "))
            {
                string slice = content;
                immutable specifiedPlugin = slice.nom!(Yes.decode)(" ");
                immutable specifiedCommand = slice;

                foreach (p; plugins)
                {
                    if (p.name != specifiedPlugin) continue;

                    if (auto description = specifiedCommand in p.commands)
                    {
                        string message;

                        if (settings.colouredOutgoing)
                        {
                            message = "[%s] %s: %s"
                                .format(p.name.ircBold, specifiedCommand.ircBold, description.string_);
                        }
                        else
                        {
                            message = "[%s] %s: %s"
                                .format(p.name, specifiedCommand, description.string_);
                        }

                        plugin.state.query(sender.nickname, message);

                        if (description.syntax.length)
                        {
                            import kameloso.string : beginsWith;
                            import std.array : replace;

                            immutable udaSyntax = description.syntax
                                .replace("$nickname", plugin.state.client.nickname)
                                .replace("$command", specifiedCommand);

                            // Prepend the prefix to non-PrefixPolicy.nickname commands
                            immutable prefixedSyntax = description.syntax.beginsWith("$nickname") ?
                                udaSyntax : settings.prefix ~ udaSyntax;

                            string syntax;

                            if (settings.colouredOutgoing)
                            {
                                syntax = "Usage".ircBold ~ ": " ~ prefixedSyntax;
                            }
                            else
                            {
                                syntax = "Usage: " ~ prefixedSyntax;
                            }

                            plugin.state.query(sender.nickname, syntax);
                        }
                    }
                    else
                    {
                        string message;

                        if (settings.colouredOutgoing)
                        {
                            message = "No help available for command %s of plugin %s"
                                .format(specifiedCommand.ircBold, specifiedPlugin.ircBold);
                        }
                        else
                        {
                            message = "No help available for command %s of plugin %s"
                                .format(specifiedCommand, specifiedPlugin);
                        }

                        plugin.state.query(sender.nickname, message);
                    }

                    return;
                }

                string message;

                if (settings.colouredOutgoing)
                {
                    message = "No such plugin: " ~ specifiedPlugin.ircBold;
                }
                else
                {
                    message = "No such plugin: " ~ specifiedPlugin;
                }

                plugin.state.query(sender.nickname, message);
            }
            else
            {
                foreach (p; plugins)
                {
                    if ((p.name != content) || !p.commands.length || p.name.endsWith("Service"))  continue;

                    enum width = 12;
                    enum pattern = "* %-*s %-([%s]%| %)";

                    string message;

                    if (settings.colouredOutgoing)
                    {
                        // FIXME: Can we bold the commands too?
                        message = pattern.format(width, p.name.ircBold, p.commands.keys.sort());
                    }
                    else
                    {
                        message = pattern.format(width, p.name, p.commands.keys.sort());
                    }

                    plugin.state.query(sender.nickname, message);
                    return;
                }

                string message;

                if (settings.colouredOutgoing)
                {
                    message = "No such plugin: " ~ content.ircBold;
                }
                else
                {
                    message = "No such plugin: " ~ content;
                }

                plugin.state.query(sender.nickname, message);
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

            immutable banner = settings.colouredOutgoing ? bannerColoured : bannerUncoloured;
            plugin.state.query(sender.nickname, banner);
            plugin.state.query(sender.nickname, "Available bot commands per plugin:");

            foreach (p; plugins)
            {
                if (!p.commands.length || p.name.endsWith("Service")) continue;

                enum width = 12;
                enum pattern = "* %-*s %-([%s]%| %)";

                string message;

                if (settings.colouredOutgoing)
                {
                    // FIXME: Can we bold the commands too?
                    message = pattern.format(width, p.name.ircBold, p.commands.keys.sort());
                }
                else
                {
                    message = pattern.format(width, p.name, p.commands.keys.sort());
                }

                plugin.state.query(sender.nickname, message);
            }

            string message;

            if (settings.colouredOutgoing)
            {
                message = "Use %s [%s] [%s] for information about a command."
                    .format("help".ircBold, "plugin".ircBold, "command".ircBold);
            }
            else
            {
                message = "Use help [plugin] [command] for information about a command.";
            }

            plugin.state.query(sender.nickname, message);
            plugin.state.query(sender.nickname, "Additional unlisted regex commands may be available.");
        }
    }

    auto fiber = new CarryingFiber!(IRCPlugin[])(&dg);
    plugin.state.mainThread.send(ThreadMessage.PeekPlugins(), cast(shared)fiber);
}


mixin MinimalAuthentication;

public:


// Help
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
    @Settings HelpSettings helpSettings;

    mixin IRCPluginImpl;
}
