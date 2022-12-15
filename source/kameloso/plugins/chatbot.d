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

    /// Enables fetching of `bash.org` quotes.
    bool bashDotOrgQuotes = true;
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


// onCommand8ball
/++
    Implements magic `8ball` (https://en.wikipedia.org/wiki/Magic_8-Ball).

    Randomises a response from the internal `eightballAnswers` table and sends
    it back to the channel in which the triggering event happened, or in a query
    if it was a private message.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.anyone)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("8ball")
            .policy(PrefixPolicy.prefixed)
            .description("Implements 8ball. Randomises a vague yes/no response.")
    )
    .addCommand(
        IRCEventHandler.Command()
            .word("eightball")
            .policy(PrefixPolicy.prefixed)
            .hidden(true)
    )
)
void onCommand8ball(ChatbotPlugin plugin, const ref IRCEvent event)
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

    Defers to the [worker] subthread.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.anyone)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("bash")
            .policy(PrefixPolicy.prefixed)
            .description("Fetch a random or specified bash.org quote.")
            .addSyntax("$command [optional bash quote number]")
    )
)
void onCommandBash(ChatbotPlugin plugin, const /*ref*/ IRCEvent event)
{
    import kameloso.thread : ThreadMessage;
    import std.concurrency : prioritySend, spawn;

    if (!plugin.chatbotSettings.bashDotOrgQuotes) return;

    plugin.state.mainThread.prioritySend(ThreadMessage.shortenReceiveTimeout());

    // Defer all work to the worker thread
    cast(void)spawn(&worker, cast(shared)plugin.state, event);
}


// worker
/++
    Looks up a `bash.org` quote and reports it to the appropriate nickname or channel.

    Supposed to be run in its own, short-lived thread.

    Params:
        sState = A `shared` [kameloso.plugins.common.core.IRCPluginState|IRCPluginState]
            containing necessary information to pass messages to send messages
            to the main thread, to send text to the server or display text on
            the screen.
        event = The [dialect.defs.IRCEvent|IRCEvent] in flight.
 +/
void worker(
    shared IRCPluginState sState,
    const ref IRCEvent event)
{
    import kameloso.constants : KamelosoInfo, Timeout;
    import arsd.dom : Document, htmlEntitiesDecode;
    import arsd.http2 : HttpClient, Uri;
    import std.algorithm.iteration : splitter;
    import std.array : replace;
    import std.exception : assumeUnique;
    import std.format : format;
    import core.time : seconds;
    static import kameloso.common;

    version(Posix)
    {
        import kameloso.thread : setThreadName;
        setThreadName("bashquotes");
    }

    auto state = cast()sState;

    // Set the global settings so messaging functions don't segfault us
    kameloso.common.settings = &state.settings;

    immutable url = !event.content.length ? "http://bash.org/?random" :
        ("http://bash.org/?" ~ event.content);

    // No need to keep a static HttpClient since this will be in a new thread every time
    auto client = new HttpClient;
    client.useHttp11 = true;
    client.keepAlive = false;
    client.acceptGzip = false;
    client.defaultTimeout = Timeout.httpGET.seconds;  // FIXME
    client.userAgent = "kameloso/" ~ cast(string)KamelosoInfo.version_;
    immutable caBundleFile = state.connSettings.caBundleFile;
    if (caBundleFile.length) client.setClientCertificate(caBundleFile, caBundleFile);

    try
    {
        auto req = client.request(Uri(url));
        const res = req.waitForCompletion();

        if (res.code == 2)
        {
            enum pattern = "Chatbot could not fetch <l>bash.org</> quote at <l>%s</>: <t>%s";
            return askToWarn(state, pattern.format(url, res.codeText));
        }

        auto doc = new Document;
        doc.parseGarbage("");  // Work around missing null check, causing segfaults on empty pages
        doc.parseGarbage(res.responseText);

        auto numBlock = doc.getElementsByClassName("quote");

        if (!numBlock.length)
        {
            enum message = "No such <b>bash.org<b> quote found.";
            return privmsg(state, event.channel, event.sender.nickname, message);
        }

        void reportLayoutError()
        {
            askToError(state, "Failed to parse <l>bash.org</> page; unexpected layout.");
        }

        auto p = numBlock[0].getElementsByTagName("p");
        if (!p.length) return reportLayoutError();  // Page changed layout

        auto b = p[0].getElementsByTagName("b");
        if (!b.length || (b[0].toString.length < 5)) return reportLayoutError();  // Page changed layout

        auto qt = doc.getElementsByClassName("qt");
        if (!qt.length) return reportLayoutError();  // Page changed layout

        auto range = qt[0]
            .toString
            .replace(`<p class="qt">`, string.init)
            .replace(`</p>`, string.init)
            .replace(`<br />`, string.init)
            .htmlEntitiesDecode
            .splitter('\n');

        immutable message = "[<b>bash.org<b>] #" ~ b[0].toString[4..$-4];
        privmsg(state, event.channel, event.sender.nickname, message);

        foreach (const line; range)
        {
            privmsg(state, event.channel, event.sender.nickname, line);
        }
    }
    catch (Exception e)
    {
        enum pattern = "Chatbot could not fetch <l>bash.org</> quote at <l>%s</>: <t>%s";
        askToWarn(state, pattern.format(url, e.msg));
        version(PrintStacktraces) askToTrace(state, e.toString);
    }
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
    The Chatbot plugin provides common chat functionality.

    Currently this includes magic 8ball, `bash.org` quotes and some other
    trivial miscellanea.
 +/
final class ChatbotPlugin : IRCPlugin
{
private:
    /// All Chatbot plugin settings gathered.
    ChatbotSettings chatbotSettings;

    mixin IRCPluginImpl;
}
