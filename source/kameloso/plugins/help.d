/++
 +  The Help plugin serves the `help` command, and nothing else at this point.
 +
 +  See the GitHub wiki for more information about available commands:
 +  - https://github.com/zorael/kameloso/wiki/Current-plugins#help
 +/
module kameloso.plugins.help;

version(WithPlugins):
version(WithHelpPlugin):

private:

import kameloso.plugins.common;
import kameloso.common : logger, settings;
import kameloso.messaging;
import dialect.defs;


// HelpSettings
/++
 +  Settings for the Help plugin, to toggle it enabled or disabled.
 +/
struct HelpSettings
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
 +  `kameloso.plugins.common.IRCPluginState`). As such, we can't easily query
 +  each plugin for their `kameloso.plugins.common.BotCommand`-annotated functions.
 +
 +  To work around this we construct a
 +  `kameloso.thread.CarryingFiber!(kameloso.plugins.common.IRCPlugin[])` and send it
 +  to the main thread. It will attach the client-global `plugins` array of
 +  `kameloso.plugins.common.IRCPlugin`s to it, and invoke the Fiber.
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

    void dg()
    {
        import lu.string : contains, nom;
        import core.thread : Fiber;
        import std.algorithm.sorting : sort;
        import std.format : format;
        import std.typecons : No, Yes;

        auto thisFiber = cast(CarryingFiber!(IRCPlugin[]))(Fiber.getThis);
        assert(thisFiber, "Incorrectly cast fiber: " ~ typeof(thisFiber).stringof);
        const plugins = thisFiber.payload;

        IRCEvent mutEvent = event;  // mutable
        if (plugin.helpSettings.repliesInQuery) mutEvent.channel = string.init;

        with (mutEvent)
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

                    if (const description = specifiedCommand in p.commands)
                    {
                        enum pattern = "[%s] %s: %s";

                        immutable message = settings.colouredOutgoing ?
                            pattern.format(p.name.ircBold, specifiedCommand.ircBold, description.string_) :
                            pattern.format(p.name, specifiedCommand, description.string_);

                        privmsg(plugin.state, channel, sender.nickname, message);

                        if (description.syntax.length)
                        {
                            import lu.string : beginsWith;
                            import std.array : replace;

                            immutable udaSyntax = description.syntax
                                .replace("$nickname", plugin.state.client.nickname)
                                .replace("$command", specifiedCommand);

                            // Prepend the prefix to non-PrefixPolicy.nickname commands
                            immutable prefixedSyntax = description.syntax.beginsWith("$nickname") ?
                                udaSyntax : settings.prefix ~ udaSyntax;

                            immutable syntax = settings.colouredOutgoing ?
                                "Usage".ircBold ~ ": " ~ prefixedSyntax :
                                "Usage: " ~ prefixedSyntax;

                            privmsg(plugin.state, channel, sender.nickname, syntax);
                        }
                    }
                    else
                    {
                        enum pattern = "No help available for command %s of plugin %s";

                        immutable message = settings.colouredOutgoing ?
                            pattern.format(specifiedCommand.ircBold, specifiedPlugin.ircBold) :
                            pattern.format(specifiedCommand, specifiedPlugin);

                        privmsg(plugin.state, channel, sender.nickname, message);
                    }

                    return;
                }

                immutable message = settings.colouredOutgoing ?
                    "No such plugin: " ~ specifiedPlugin.ircBold :
                    "No such plugin: " ~ specifiedPlugin;

                privmsg(plugin.state, channel, sender.nickname, message);
            }
            else
            {
                foreach (p; plugins)
                {
                    if (p.name != content) continue;
                    else if (!p.commands.length)
                    {
                        immutable message = settings.colouredOutgoing ?
                            "No commands available for plugin " ~ content.ircBold :
                            "No commands available for plugin " ~ content;

                        privmsg(plugin.state, channel, sender.nickname, message);
                        return;
                    }

                    enum width = 12;
                    enum pattern = "* %-*s %-([%s]%| %)";

                    immutable message = settings.colouredOutgoing ?
                        pattern.format(width, p.name.ircBold, p.commands.keys.sort()) :
                        pattern.format(width, p.name, p.commands.keys.sort());

                    privmsg(plugin.state, channel, sender.nickname, message);
                    return;
                }

                immutable message = settings.colouredOutgoing ?
                    "No such plugin: " ~ content.ircBold :
                    "No such plugin: " ~ content;

                privmsg(plugin.state, channel, sender.nickname, message);
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
            privmsg(plugin.state, channel, sender.nickname, banner);
            privmsg(plugin.state, channel, sender.nickname, "Available bot commands per plugin:");

            foreach (p; plugins)
            {
                if (!p.commands.length) continue;  // command-less plugin/service

                enum width = 12;
                enum pattern = "* %-*s %-([%s]%| %)";

                immutable message = settings.colouredOutgoing ?
                    pattern.format(width, p.name.ircBold, p.commands.keys.sort()) :
                    pattern.format(width, p.name, p.commands.keys.sort());

                privmsg(plugin.state, channel, sender.nickname, message);
            }

            enum pattern = "Use %s [%s] [%s] for information about a command.";
            enum colouredLine = pattern.format("help".ircBold, "plugin".ircBold, "command".ircBold);

            immutable message = settings.colouredOutgoing ? colouredLine :
                "Use help [plugin] [command] for information about a command.";

            privmsg(plugin.state, channel, sender.nickname, message);
            //privmsg(plugin.state, channel, sender.nickname, "Additional unlisted regex commands may be available.");
        }
    }

    auto fiber = new CarryingFiber!(IRCPlugin[])(&dg, 32768);
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
 +      description = The `kameloso.plugins.common.Description` that anotates
 +          the command's function.
 +/
void sendCommandHelp(HelpPlugin plugin, const IRCPlugin otherPlugin,
    const IRCEvent event, const string command, const Description description)
{
    import kameloso.irccolours : ircBold;
    import std.format : format;

    enum pattern = "[%s] %s: %s";

    immutable message = settings.colouredOutgoing ?
        pattern.format(otherPlugin.name.ircBold, command.ircBold, description.string_) :
        pattern.format(otherPlugin.name, command, description.string_);

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
            udaSyntax : settings.prefix ~ udaSyntax;

        immutable syntax = settings.colouredOutgoing ?
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
    @Settings HelpSettings helpSettings;

    mixin IRCPluginImpl;
}
