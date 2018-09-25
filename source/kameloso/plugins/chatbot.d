/++
 +  The Chatbot plugin is a collection of small, harmless functions like `8ball`
 +  and repeating text, as well as providing an "online help", sending a list of
 +  all the available bot verbs to the querying nickname.
 +
 +  It has a few commands:
 +
 +  `8ball`<br>
 +  `help`<br>
 +  `say` | `säg`
 +
 +  It is very optional.
 +/
module kameloso.plugins.chatbot;

version(WithPlugins):

private:

import kameloso.plugins.common;
import kameloso.ircdefs;
import kameloso.common : logger;
import kameloso.messaging;


// ChatbotSettings
/++
 +  Settings for a chatbot, to toggle its features.
 +/
struct ChatbotSettings
{
    /// Whether the Chatbot plugin should react to events at all.
    bool enabled = true;
}


// onCommandSay
/++
 +  Repeats text to the channel the event was sent to.
 +
 +  If it was sent in a query, respond in a private message in kind.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.whitelist)
@(ChannelPolicy.home)
@BotCommand("say")
@BotCommand("säg")
@BotCommand(NickPolicy.required, "say")
@BotCommand(NickPolicy.required, "säg")
@Description("Repeats text to the channel the event was sent to.", "$command [text to repeat]")
void onCommandSay(ChatbotPlugin plugin, const IRCEvent event)
{
    if (!plugin.chatbotSettings.enabled) return;

    import std.format : format;

    if (!event.content.length)
    {
        logger.error("No text to send...");
        return;
    }

    plugin.state.privmsg(event.channel, event.sender.nickname, event.content);
}


// onCommand8ball
/++
 +  Implements magic `8ball` (https://en.wikipedia.org/wiki/Magic_8-Ball).
 +
 +  Randomises a response from the internal `eightballAnswers` table and sends
 +  it back to the channel in which the triggering event happened, or in a query
 +  if it was a private message.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.whitelist)
@(ChannelPolicy.home)
@BotCommand("8ball")
@BotCommand(NickPolicy.required, "8ball")
@Description("Implements 8ball. Randomises a vague yes/no response.")
void onCommand8ball(ChatbotPlugin plugin, const IRCEvent event)
{
    if (!plugin.chatbotSettings.enabled) return;

    import std.format : format;
    import std.random : uniform;

    // Fetched from wikipedia
    static immutable string[20] eightballAnswers =
    [
        "It is certain",
        "It is decidedly so",
        "Without a doubt",
        "Yes, definitely",
        "You may rely on it",
        "As I see it, yes",
        "Most likely",
        "Outlook good",
        "Yes",
        "Signs point to yes",
        "Reply hazy try again",
        "Ask again later",
        "Better not tell you now",
        "Cannot predict now",
        "Concentrate and ask again",
        "Don't count on it",
        "My reply is no",
        "My sources say no",
        "Outlook not so good",
        "Very doubtful",
    ];

    immutable reply = eightballAnswers[uniform(0, eightballAnswers.length)];

    plugin.state.privmsg(event.channel, event.sender.nickname, reply);
}


// onCommandHelp
/++
 +  Starts the process of echoing all available bot commands to a user (in a
 +  private query). A hack.
 +
 +  Plugins don't know about other plugins; the only thing they know of the
 +  outside world is the thread ID of the main thread `mainThread` of
 +  (`kameloso.plugins.common.IRCPluginState`). As such, we can't easily query
 +  each plugin for their `kameloso.plugins.common.BotCommand`-annotated
 +  functions.
 +
 +  To work around this we save the initial requesting
 +  `kameloso.ircdefs.IRCEvent`, then send a concurrency message to the main
 +  thread asking for a const reference to the main
 +  `kameloso.common.Client.plugins` array of
 +  `kameloso.plugins.common.IRCPlugin`s. We create a function in interface
 +  `kameloso.plugins.common.IRCPlugin` that passes said array on to the top-
 +  level `peekPlugins`, wherein we process the list and collect the bot command
 +  strings.
 +
 +  Once we have the list we format it nicely and send it back to the requester,
 +  which we remember since we saved the original `kameloso.ircdefs.IRCEvent`.
 +/
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.CHAN)
@(PrivilegeLevel.whitelist)
@BotCommand(NickPolicy.required, "help")
@Description("Shows a list of all available commands.")
void onCommandHelp(ChatbotPlugin plugin, const IRCEvent event)
{
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
                        plugin.state.query(sender.nickname, "[%s] %s: %s"
                            .format(p.name, specifiedCommand, description.string_));

                        if (description.syntax.length)
                        {
                            import std.array : replace;
                            immutable syntax = "Usage: " ~ description.syntax
                                .replace("$command", specifiedCommand);
                            plugin.state.query(sender.nickname, syntax);
                        }
                    }
                    else
                    {
                        plugin.state.query(sender.nickname, "No help available for command %s of plugin %s"
                            .format(specifiedCommand, specifiedPlugin));
                    }

                    return;
                }

                plugin.state.query(sender.nickname, "No such plugin: " ~ specifiedPlugin);
                return;
            }
            else
            {
                foreach (p; plugins)
                {
                    if (p.name != content) continue;

                    enum width = 11;

                    plugin.state.query(sender.nickname, "* %-*s %-([%s]%| %)"
                        .format(width, p.name, p.commands.keys.sort()));
                    return;
                }

                plugin.state.query(sender.nickname, "No such plugin: " ~ content);
            }
        }
        else
        {
            import kameloso.constants : KamelosoInfo;
            enum banner = "kameloso IRC bot v%s, built %s"
                .format(cast(string)KamelosoInfo.version_,
                cast(string)KamelosoInfo.built);

            plugin.state.query(sender.nickname, banner);
            plugin.state.query(sender.nickname, "Available bot commands per plugin:");

            foreach (p; plugins)
            {
                if (!p.commands.length || p.name.endsWith("Service")) continue;

                enum width = 11;

                plugin.state.query(sender.nickname, "* %-*s %-([%s]%| %)"
                    .format(width, p.name, p.commands.keys.sort()));
            }

            plugin.state.query(sender.nickname, "Use help [plugin] [command] for information about a command.");
            plugin.state.query(sender.nickname, "Additional unlisted regex commands may be available.");
        }
    }

    auto fiber = new CarryingFiber!(IRCPlugin[])(&dg);
    plugin.state.mainThread.send(ThreadMessage.PeekPlugins(), cast(shared)fiber);
}


mixin MinimalAuthentication;

public:


// Chatbot
/++
 +  The Chatbot plugin provides common chat functionality. This includes magic
 +  8ball and some other miscellanea.
 +
 +  Administrative actions have been broken out into
 +  `kameloso.plugins.admin.AdminPlugin`.
 +
 +  User quotes have been broken out into
 +  `kameloso.plugins.quotes.QuotesPlugin`.
 +/
final class ChatbotPlugin : IRCPlugin
{
    /// All Chatbot plugin settings gathered.
    @Settings ChatbotSettings chatbotSettings;

    mixin IRCPluginImpl;
}
