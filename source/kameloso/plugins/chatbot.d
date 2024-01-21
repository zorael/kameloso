/++
    The Chatbot plugin is a diminishing collection of small, harmless features;
    like `say`/`echo` for simple repeating of text.

    It's mostly legacy.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#chatbot,
        [kameloso.plugins.common],
        [kameloso.plugins.common.misc]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.chatbot;

version(WithChatbotPlugin):

private:

import kameloso.plugins;
import kameloso.plugins.common;
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
    /++
        Whether or not the Chatbot plugin should react to events at all.
     +/
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
    string message;  // mutable

    if (event.content.length)
    {
        version(TwitchSupport)
        {
            if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
            {
                import std.algorithm.comparison : among;

                if (event.content[0].among!('/', '.'))
                {
                    // This has the chance to conflict with a Twitch command,
                    // so prepend a space to invalidate it
                    message = ' ' ~ event.content;
                }
            }
        }

        if (!message.length) message = event.content;
    }
    else
    {
        message = "Say what?";
    }

    privmsg(plugin.state, event.channel, event.sender.nickname, message);
}


// onDance
/++
    Does the bash.org dance emotes.

    This will be called on each channel message, so don't annotate it `.fiber(true)`
    and instead create a fiber manually iff we should actually go ahead and dance.

    See_Also: http://bash.org/?4281
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.anyone)
    .channelPolicy(ChannelPolicy.home)
    //.fiber(true)
)
void onDance(ChatbotPlugin plugin, const /*ref*/ IRCEvent event)
{
    import kameloso.constants : BufferSize;
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
        import kameloso.plugins.common.scheduling : delay;
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


// selftest
/++
    Performs self-tests against another bot.
 +/
version(Selftests)
auto selftest(ChatbotPlugin plugin, Selftester s)
{
    import kameloso.plugins.common.scheduling : await, unawait;

    s.send("say xoraelblarbhl");
    s.expect("xoraelblarbhl");

    await(plugin, IRCEvent.Type.EMOTE, No.yield);
    scope(exit) unawait(plugin, IRCEvent.Type.EMOTE);

    s.sendPlain("get on up and DANCE");
    s.expect("dances :D-<");
    s.expect("dances :D|-<");
    s.expect("dances :D/-<");

    return true;
}


mixin MinimalAuthentication;
mixin PluginRegistration!ChatbotPlugin;

public:


// Chatbot
/++
    The Chatbot plugin provides trivial chat functionality.
 +/
final class ChatbotPlugin : IRCPlugin
{
private:
    /++
        All Chatbot plugin settings gathered.
     +/
    ChatbotSettings chatbotSettings;

    mixin IRCPluginImpl;
}
