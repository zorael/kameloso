/++
    The Chatbot plugin is a collection of small, harmless functions like `8ball`
    for magic eightball, `bash` for fetching specified or random bash.org quotes,
    and `say`/`echo` for simple repeating of text.

    It's mostly legacy.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#chatbot
        [kameloso.plugins.common.core|plugins.common.core]
        [kameloso.plugins.common.misc|plugins.common.misc]
 +/
module kameloso.plugins.chatbot;

version(WithChatbotPlugin):

private:

import kameloso.plugins.common.core;
import kameloso.plugins.common.awareness : MinimalAuthentication;
import kameloso.messaging;
import dialect.defs;
import std.typecons : Flag, No, Yes;


// ChatbotSettings
/++
    Settings for a chatbot, to toggle its features.
 +/
@Settings struct ChatbotSettings
{
    /// Whether or not the Chatbot plugin should react to events at all.
    @Enabler bool enabled = true;
}


// onCommandSay
/++
    Repeats text to the channel the event was sent to.

    If it was sent in a query, respond in a private message in kind.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.anyone)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("say")
            .policy(PrefixPolicy.prefixed)
            .description("Repeats text to the current channel. Amazing.")
            .addSyntax("$command [text to repeat]")
    )
    .addCommand(
        IRCEventHandler.Command()
            .word("säg")
            .policy(PrefixPolicy.nickname)
            .hidden(true)
    )
    .addCommand(
        IRCEventHandler.Command()
            .word("echo")
            .policy(PrefixPolicy.prefixed)
            .hidden(true)
    )
)
void onCommandSay(ChatbotPlugin plugin, const ref IRCEvent event)
{
    immutable message = event.content.length ?
        event.content :
        "Say what?";

    privmsg(plugin.state, event.channel, event.sender.nickname, message);
}


// onDance
/++
    Does the bash.org dance emotes.

    - http://bash.org/?4281
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.anyone)
    .channelPolicy(ChannelPolicy.home)
)
void onDance(ChatbotPlugin plugin, const /*ref*/ IRCEvent event)
{
    import kameloso.plugins.common.delayawait : delay;
    import kameloso.constants : BufferSize;
    import kameloso.messaging : emote;
    import lu.string : strippedRight;
    import std.string : indexOf;
    import core.thread : Fiber;
    import core.time : seconds;

    immutable content = event.content.strippedRight;
    immutable dancePos = content.indexOf("DANCE");

    if (dancePos == -1) return;

    if ((dancePos > 0) && (content[dancePos-1] != ' '))
    {
        return;
    }
    else if (content.length > (dancePos+5))
    {
        string trailing = content[dancePos+5..$];  // mutable

        while (trailing.length)
        {
            import std.algorithm.comparison : among;
            if (!trailing[0].among!(' ', '!', '.', '?')) return;
            trailing = trailing[1..$];
        }
    }

    // Should dance. Stagger it a bit with a second in between.
    static immutable timeBetweenDances = 1.seconds;

    void danceDg()
    {
        import kameloso.plugins.common.delayawait : delay;
        import kameloso.messaging : emote;

        emote(plugin.state, event.channel, "dances :D-<");
        delay(plugin, timeBetweenDances, Yes.yield);

        emote(plugin.state, event.channel, "dances :D|-<");
        delay(plugin, timeBetweenDances, Yes.yield);

        emote(plugin.state, event.channel, "dances :D/-<");
    }

    Fiber danceFiber = new Fiber(&danceDg, BufferSize.fiberStack);
    danceFiber.call();
}


mixin MinimalAuthentication;
mixin ModuleRegistration;

public:


// Chatbot
/++
    The Chatbot plugin provides trivial chat functionality.
 +/
final class ChatbotPlugin : IRCPlugin
{
private:
    /// All Chatbot plugin settings gathered.
    ChatbotSettings chatbotSettings;

    mixin IRCPluginImpl;
}
