/++
 +  The Bash Quotes plugin fetches quotes from `www.bash.org` and displays them
 +  in a channel (or to a private query). It can fetch a random one or one
 +  by quote ID.
 +
 +  See the GitHub wiki for more information about available commands:
 +  - https://github.com/zorael/kameloso/wiki/Current-plugins#bashquotes
 +/
module kameloso.plugins.bashquotes;

version(WithPlugins):
version(Web):
version(WithBashQuotesPlugin):

private:

import kameloso.plugins.common;
import kameloso.common : settings;
import kameloso.messaging;
import dialect.defs;

import std.typecons : Flag, No, Yes;


// BashQuotesSettings
/++
 +  All `BashQuotesPlugin` settings, gathered in a struct.
 +/
struct BashQuotesSettings
{
    /// Toggles whether or not the plugin should react to events at all.
    @Enabler bool enabled = true;
}


// onMessage
/++
 +  Fetch a random or specified `bash.org` quote.
 +
 +  Defers to the worker subthread.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.anyone)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "bash")
@Description("Fetch a random or specified bash.org quote.", "$command [optional bash quote number]")
void onMessage(BashQuotesPlugin plugin, const IRCEvent event)
{
    import std.concurrency : spawn;

    // Defer all work to the worker thread
    spawn(&worker, cast(shared)plugin.state, event, settings.colouredOutgoing);
}


// worker
/++
 +  Looks up a Bash quote and reports it to the appropriate nickname or channel.
 +
 +  Supposed to be run in its own, short-lived thread.
 +
 +  Params:
 +      sState = A `shared` `kameloso.plugins.common.IRCPluginState` containing
 +          necessary information to pass messages to send messages to the main
 +          thread, to send text to the server or display text on the screen.
 +      event = The `dialect.defs.IRCEvent` in flight.
 +      colouredOutgoing = Whether or not to tint messages going to the server
 +          with mIRC colouring.
 +/
void worker(shared IRCPluginState sState, const IRCEvent event, const bool colouredOutgoing)
{
    import kameloso.irccolours : ircBold;
    import arsd.dom : Document, htmlEntitiesDecode;
    import requests : getContent;
    import core.memory : GC;
    import std.algorithm.iteration : splitter;
    import std.array : replace;
    import std.format : format;

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
        import std.exception : assumeUnique;

        immutable content = (cast(char[])getContent(url).data).assumeUnique;
        auto doc = new Document;
        doc.parseGarbage(content);

        auto numBlock = doc.getElementsByClassName("quote");

        if (!numBlock.length)
        {
            string message;

            if (colouredOutgoing)
            {
                message = "No such bash.org quote: " ~ event.content.ircBold;
            }
            else
            {
                message = "No such bash.org quote: " ~ event.content;
            }

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
            .splitter("\n");

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
        state.askToWarn("Bashquotes could not fetch %s: %s".format(url, e.msg));
    }
}


mixin MinimalAuthentication;

public:


// BashQuotesPlugin
/++
 +  The Bash Quotes plugin fetches quotes from `www.bash.org` and displays them
 +  in a channel (or to a private query). It can fetch a random one or one
 +  by quote ID.
 +/
final class BashQuotesPlugin : IRCPlugin
{
private:
    /// All BashQuotes options gathered.
    @Settings BashQuotesSettings bashQuotesSettings;

    mixin IRCPluginImpl;
}
