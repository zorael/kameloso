/++
 +  The Chatbot plugin is a collection of small, harmless functions like `8ball`
 +  and repeating text, as well as providing an "online help", sending a list of
 +  all the available bot verbs to the querying nickname.
 +
 +  It has a few commands:
 +
 +  `say`|`echo`<br>
 +  `8ball`<br>
 +  `help`
 +
 +  It is very optional.
 +/
module kameloso.plugins.chatbot;

version(WithPlugins):
version(WithChatbotPlugin):

private:

import kameloso.plugins.common;
import kameloso.irc.defs;
import kameloso.common : settings;
import kameloso.irc.colours : ircBold;
import kameloso.messaging;

import std.typecons : Flag, No, Yes;


// ChatbotSettings
/++
 +  Settings for a chatbot, to toggle its features.
 +/
struct ChatbotSettings
{
    /// Whether or not the Chatbot plugin should react to events at all.
    @Enabler bool enabled = true;
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
@BotCommand(PrefixPolicy.prefixed, "say")
@BotCommand(PrefixPolicy.prefixed, "säg")
@BotCommand(PrefixPolicy.prefixed, "echo")
@Description("Repeats text to the channel the event was sent to.", "$command [text to repeat]")
void onCommandSay(ChatbotPlugin plugin, const IRCEvent event)
{
    import std.format : format;

    if (!event.content.length)
    {
        plugin.state.privmsg(event.channel, event.sender.nickname, "Say what?");
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
@BotCommand(PrefixPolicy.prefixed, "8ball")
@Description("Implements 8ball. Randomises a vague yes/no response.")
void onCommand8ball(ChatbotPlugin plugin, const IRCEvent event)
{
    import std.format : format;
    import std.random : uniform;

    // Fetched from Wikipedia
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


mixin MinimalAuthentication;

public:


// Chatbot
/++
 +  The Chatbot plugin provides common chat functionality. This includes magic
 +  8ball and some other miscellanea.
 +
 +  Administrative actions have been broken out into `kameloso.plugins.admin.AdminPlugin`.
 +
 +  User quotes have been broken out into `kameloso.plugins.quotes.QuotesPlugin`.
 +
 +  Help listing has been broken out into `kameloso.plugins.help.HelpPlugin`.
 +/
final class ChatbotPlugin : IRCPlugin
{
private:
    /// All Chatbot plugin settings gathered.
    @Settings ChatbotSettings chatbotSettings;

    mixin IRCPluginImpl;
}
