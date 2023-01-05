/++
    The Bash plugin looks up `bash.org` quotes and reports them to the
    appropriate nickname or channel.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#bash
        [kameloso.plugins.common.core|plugins.common.core]
        [kameloso.plugins.common.misc|plugins.common.misc]
 +/
module kameloso.plugins.bash;

version(WithBashPlugin):

private:

import kameloso.plugins.common.core;
import kameloso.plugins.common.awareness : MinimalAuthentication;
import kameloso.messaging;
import dialect.defs;
import std.typecons : Flag, No, Yes;

mixin MinimalAuthentication;
mixin ModuleRegistration;


// BashSettings
/++
    All Bash plugin settings gathered.
 +/
@Settings struct BashSettings
{
    /++
        Whether or not the Bash plugin should react to events at all.
     +/
    @Enabler bool enabled = true;
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
void onCommandBash(BashPlugin plugin, const /*ref*/ IRCEvent event)
{
    import kameloso.thread : ThreadMessage;
    import std.concurrency : prioritySend, spawn;

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
    const /*ref*/ IRCEvent event)
{
    import kameloso.constants : KamelosoInfo, Timeout;
    import lu.string : beginsWith;
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

    immutable quoteID = event.content.beginsWith('#') ?
        event.content[1..$] :
        event.content;
    immutable url = quoteID.length ?
        ("http://bash.org/?" ~ quoteID) :
        "http://bash.org/?random";

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
            enum pattern = "Bash plugin could not fetch <l>bash.org</> quote at <l>%s</>: <t>%s";
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
        enum pattern = "Bash plugin could not fetch <l>bash.org</> quote at <l>%s</>: <t>%s";
        askToWarn(state, pattern.format(url, e.msg));
        version(PrintStacktraces) askToTrace(state, e.toString);
    }
}


public:


// BashPlugin
/++
    The Bash plugin looks up `bash.org` quotes and reports them to the
    appropriate nickname or channel.
 +/
final class BashPlugin : IRCPlugin
{
    /++
        All Bash plugin settings gathered.
     +/
    BashSettings bashSettings;

    mixin IRCPluginImpl;
}
