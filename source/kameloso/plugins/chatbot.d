/++
    The Chatbot plugin is a collection of small, harmless functions like `8ball`
    for magic eightball, `bash` for fetching specified or random bash.org quotes,
    and `say`/`echo` for simple repeating of text.

    It's mostly legacy.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#chatbot
 +/
module kameloso.plugins.chatbot;

version(WithPlugins):
version(WithChatbotPlugin):

private:

import kameloso.plugins.common.core;
import kameloso.plugins.common.awareness : MinimalAuthentication;
import kameloso.irccolours : ircBold;
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

    version(Web)
    {
        /// Enables fetching of `bash.org` quotes.
        bool bashQuotes = true;
    }
}


// onCommandSay
/++
    Repeats text to the channel the event was sent to.

    If it was sent in a query, respond in a private message in kind.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.anyone)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "say")
@BotCommand(PrefixPolicy.prefixed, "säg", Yes.hidden)
@BotCommand(PrefixPolicy.prefixed, "echo", Yes.hidden)
@Description("Repeats text to the channel the event was sent to.", "$command [text to repeat]")
void onCommandSay(ChatbotPlugin plugin, const IRCEvent event)
{
    import std.format : format;

    if (!event.content.length)
    {
        privmsg(plugin.state, event.channel, event.sender.nickname, "Say what?");
        return;
    }

    privmsg(plugin.state, event.channel, event.sender.nickname, event.content);
}


// onCommand8ball
/++
    Implements magic `8ball` (https://en.wikipedia.org/wiki/Magic_8-Ball).

    Randomises a response from the internal `eightballAnswers` table and sends
    it back to the channel in which the triggering event happened, or in a query
    if it was a private message.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.anyone)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "8ball")
@BotCommand(PrefixPolicy.prefixed, "eightball")
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

    privmsg(plugin.state, event.channel, event.sender.nickname, reply);
}


// onCommandBash
/++
    Fetch a random or specified `bash.org` quote.

    Defers to the `worker` subthread.
 +/
version(Web)
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.anyone)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "bash")
@Description("Fetch a random or specified bash.org quote.", "$command [optional bash quote number]")
void onCommandBash(ChatbotPlugin plugin, const IRCEvent event)
{
    import std.concurrency : spawn;

    // Defer all work to the worker thread
    spawn(&worker, cast(shared)plugin.state, event,
        (plugin.state.settings.colouredOutgoing ? Yes.colouredOutgoing : No.colouredOutgoing));
}


// worker
/++
    Looks up a `bash.org` quote and reports it to the appropriate nickname or channel.

    Supposed to be run in its own, short-lived thread.

    Params:
        sState = A `shared` `kameloso.plugins.common.core.IRCPluginState` containing
            necessary information to pass messages to send messages to the main
            thread, to send text to the server or display text on the screen.
        event = The `dialect.defs.IRCEvent` in flight.
        colouredOutgoing = Whether or not to tint messages going to the server
            with mIRC colouring.
 +/
version(Web)
void worker(shared IRCPluginState sState, const IRCEvent event,
    const Flag!"colouredOutgoing" colouredOutgoing)
{
    import kameloso.constants : BufferSize, KamelosoInfo, Timeout;
    import kameloso.irccolours : ircBold;
    import arsd.dom : Document, htmlEntitiesDecode;
    import std.algorithm.iteration : splitter;
    import std.array : Appender, replace;
    import std.exception : assumeUnique;
    import std.format : format;
    import std.net.curl : HTTP;
    import core.time : seconds;

    version(Posix)
    {
        import kameloso.thread : setThreadName;
        setThreadName("bashquotes");
    }

    auto state = cast()sState;

    immutable url = !event.content.length ? "http://bash.org/?random" :
        "http://bash.org/?" ~ event.content;

    try
    {
        auto client = HTTP(url);
        client.operationTimeout = Timeout.httpGET.seconds;
        client.setUserAgent("kameloso/" ~ cast(string)KamelosoInfo.version_);
        client.addRequestHeader("Accept", "text/html");

        Document doc = new Document;
        Appender!(ubyte[]) sink;
        sink.reserve(1_048_576);  // 1M

        client.onReceive = (ubyte[] data)
        {
            sink.put(data);
            return data.length;
        };

        client.perform();

        immutable received = assumeUnique(cast(char[])sink.data);
        doc.parseGarbage(received);
        auto numBlock = doc.getElementsByClassName("quote");

        if (!numBlock.length)
        {
            immutable message = colouredOutgoing ?
                "No such bash.org quote: " ~ event.content.ircBold :
                "No such bash.org quote: " ~ event.content;

            privmsg(state, event.channel, event.sender.nickname, message);
            return;
        }

        immutable num = numBlock[0]
            .getElementsByTagName("p")[0]
            .getElementsByTagName("b")[0]
            .toString[4..$-4];

        auto range = doc
            .getElementsByClassName("qt")[0]
            .toString
            .htmlEntitiesDecode
            .replace(`<p class="qt">`, string.init)
            .replace(`</p>`, string.init)
            .replace(`<br />`, string.init)
            .splitter('\n');

        immutable message = colouredOutgoing ?
            "%s #%s".format("[bash.org]".ircBold, num) :
            "[bash.org] #%s".format(num);

        privmsg(state, event.channel, event.sender.nickname, message);

        foreach (const line; range)
        {
            privmsg(state, event.channel, event.sender.nickname, line);
        }
    }
    catch (Exception e)
    {
        askToWarn(state, "Chatbot could not fetch bash.org quote at %s: %s".format(url, e.msg));
        askToTrace(state, e.toString);
    }
}


// onDance
/++
    Does the bash.org dance emotes.

    - http://bash.org/?4281
 +/
@(Terminating)
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.anyone)
@(ChannelPolicy.home)
void onDance(ChatbotPlugin plugin, const IRCEvent event)
{
    import kameloso.thread : ScheduledFiber;
    import std.string : indexOf;
    import core.thread : Fiber;

    immutable dancePos = event.content.indexOf("DANCE");
    if (dancePos == -1) return;

    if ((dancePos > 0) && (event.content[dancePos-1] != ' '))
    {
        return;
    }
    else if (event.content.length > (dancePos+5))
    {
        immutable trailing = event.content[dancePos+5];

        switch (trailing)
        {
        case ' ':
        case '!':
        case '.':
        case '?':
            // Drop down
            break;

        default:
            return;
        }
    }

    // Should dance. Stagger it a bit with a second in between.
    enum secondsBetweenDances = 1;

    void dg()
    {
        import kameloso.plugins.common.delayawait : delay;
        import kameloso.messaging : emote;

        emote(plugin.state, event.channel, "dances :D-<");
        delay(plugin, secondsBetweenDances, Yes.yield);

        emote(plugin.state, event.channel, "dances :D|-<");
        delay(plugin, secondsBetweenDances, Yes.yield);

        emote(plugin.state, event.channel, "dances :D/-<");
    }

    Fiber fiber = new Fiber(&dg, 32_768);
    fiber.call();
}


mixin MinimalAuthentication;

public:


// Chatbot
/++
    The Chatbot plugin provides common chat functionality. Currently this includes magic
    8ball, `bash.org` quotes and some other trivial miscellanea.
 +/
final class ChatbotPlugin : IRCPlugin
{
private:
    /// All Chatbot plugin settings gathered.
    ChatbotSettings chatbotSettings;

    mixin IRCPluginImpl;
}
