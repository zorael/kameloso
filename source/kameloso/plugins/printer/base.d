/++
    The Printer plugin takes incoming [dialect.defs.IRCEvent|IRCEvent]s, formats them
    into something easily readable and prints them to the screen, optionally with colours.
    It also supports logging to disk.

    It has no commands; all [dialect.defs.IRCEvent|IRCEvent]s will be parsed and
    printed, excluding certain types that were deemed too spammy. Print them as
    well by disabling `filterMost`, in the configuration file under the header `[Printer]`.

    It is not technically necessary, but it is the main form of feedback you
    get from the plugin, so you will only want to disable it if you want a
    really "headless" environment.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#printer
        [kameloso.plugins.common.core|plugins.common.core]
        [kameloso.plugins.common.misc|plugins.common.misc]
 +/
module kameloso.plugins.printer.base;

version(WithPrinterPlugin):

private:

import kameloso.plugins.printer.formatting;
import kameloso.plugins.printer.logging;

import kameloso.plugins;
import kameloso.plugins.common.core;
import kameloso.plugins.common.awareness : ChannelAwareness, UserAwareness;
import dialect.defs;
import std.typecons : Flag, No, Yes;

version(Colours) import kameloso.terminal.colours.defs : TerminalForeground;


// PrinterSettings
/++
    All Printer plugin options gathered in a struct.
 +/
@Settings struct PrinterSettings
{
private:
    import lu.uda : Unserialisable;

public:
    /// Toggles whether or not the plugin should react to events at all.
    @Enabler bool enabled = true;

    /// Toggles whether or not the plugin should print to screen (as opposed to just log).
    bool monitor = true;

    version(Colours)
    {
        /// Whether or not to display nicks in a colour based on their nickname hash.
        bool colourfulNicknames = true;

        @Unserialisable
        {
            /// Whether or not two users on the same account should be coloured identically.
            bool colourByAccount = true;
        }
    }

    version(TwitchSupport)
    {
        @Unserialisable
        {
            /// Whether or not to display Twitch badges next to sender/target names.
            bool twitchBadges = true;

            /++
                Whether or not to display advanced colours in `RRGGBB` rather
                than simple ANSI codes, where available and appropriate.
             +/
            bool truecolour = true;

            /// Whether or not to normalise truecolours; make dark brighter and bright darker.
            bool normaliseTruecolour = true;

            /// Whether or not emotes should be highlit in colours.
            bool colourfulEmotes = true;
        }
    }

    /++
        Whether or not to show Message of the Day upon connecting.

        Warning! MOTD generally lists server rules, which might be good to read.
     +/
    bool motd = false;

    /// Whether or not to filter away most uninteresting events.
    bool filterMost = true;

    /// Whether or not to filter WHOIS queries.
    bool filterWhois = true;

    /// Whether or not to hide events from blacklisted users.
    bool hideBlacklistedUsers = false;

    /// Whether or not to log events.
    bool logs = false;

    /// Whether or not to log non-home channels.
    bool logGuestChannels = false;

    /// Whether or not to log private messages.
    bool logPrivateMessages = true;

    @Unserialisable
    {
        /// Whether or not to send a terminal bell signal when the bot is mentioned in chat.
        bool bellOnMention = false;

        /// Whether or not to bell on parsing errors.
        bool bellOnError = false;

        /// Whether or not to log server messages.
        bool logServer = false;

        /// Whether or not to log errors.
        bool logErrors = true;

        /// Whether or not to log raw events.
        bool logRaw = false;

        /// Whether or not to have the type names be in capital letters.
        bool uppercaseTypes = false;

        /// Whether or not to print a banner to the terminal at midnights, when day changes.
        bool daybreaks = true;

        /// Whether or not to buffer writes.
        bool bufferedWrites = true;
    }
}


// onPrintableEvent
/++
    Prints an event to the local terminal.

    Buffer output in an [std.array.Appender|Appender].

    Mutable [dialect.defs.IRCEvent|IRCEvent] parameter so as to make fewer internal copies
    (as this is a hotspot).
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.ANY)
    .channelPolicy(ChannelPolicy.any)
    .chainable(true)
)
void onPrintableEvent(PrinterPlugin plugin, /*const*/ IRCEvent event)
{
    if (!plugin.printerSettings.monitor || plugin.state.settings.headless) return;

    if (plugin.printerSettings.hideBlacklistedUsers && (event.sender.class_ == IRCUser.Class.blacklist)) return;

    // For many types there's no need to display the target nickname when it's the bot's
    // Clear event.target.nickname for those types.
    event.clearTargetNicknameIfUs(plugin.state);

    /++
        Return whether or not the current event should be squelched based on
        if the passed channel, sender or target nickname has a squelchstamp
        that demands it. Additionally updates the squelchstamp if so.
     +/
    static bool updateSquelchstamp(
        PrinterPlugin plugin,
        const long time,
        const string channel,
        const string sender,
        const string target)
    in ((channel.length || sender.length || target.length),
        "Tried to update squelchstamp but with no channel or user information passed")
    {
        /*import std.algorithm.comparison : either;
        immutable key = either!(s => s.length)(channel, sender, target);*/

        immutable key =
            channel.length ? channel :
            sender.length ? sender :
            /*target.length ?*/ target;

        // already in in-contract
        /*assert(key.length, "Logic error; tried to update squelchstamp but " ~
            "no `channel`, no `sender`, no `target`");*/

        auto squelchstamp = key in plugin.squelches;

        if (!squelchstamp)
        {
            plugin.hasSquelches = (plugin.squelches.length > 0);
            return false;
        }
        else if ((time - *squelchstamp) <= plugin.squelchTimeout)
        {
            *squelchstamp = time;
            return true;
        }
        else
        {
            plugin.squelches.remove(key);
            plugin.hasSquelches = (plugin.squelches.length > 0);
            return false;
        }
    }

    with (IRCEvent.Type)
    switch (event.type)
    {
    case RPL_MOTDSTART:
    case RPL_MOTD:
    case RPL_ENDOFMOTD:
    case ERR_NOMOTD:
        // Only show these if we're configured to
        if (plugin.printerSettings.motd) goto default;
        break;

    case RPL_WHOISACCOUNT:
    case RPL_WHOISACCOUNTONLY:
    case RPL_WHOISADMIN:
    case RPL_WHOISBOT:
    case RPL_WHOISCERTFP:
    case RPL_WHOISCHANNELS:
    case RPL_WHOISCHANOP:
    case RPL_WHOISHELPER:
    case RPL_WHOISHELPOP:
    case RPL_WHOISHOST:
    case RPL_WHOISIDLE:
    case RPL_ENDOFWHOIS:
    case RPL_TARGUMODEG:
    case RPL_WHOISREGNICK:
    case RPL_WHOISKEYVALUE:
    case RPL_WHOISKILL:
    case RPL_WHOISLANGUAGE:
    case RPL_WHOISMARKS:
    case RPL_WHOISMODES:
    case RPL_WHOISOPERATOR:
    case RPL_WHOISPRIVDEAF:
    case RPL_WHOISREALIP:
    case RPL_WHOISSECURE:
    case RPL_WHOISSPECIAL:
    case RPL_WHOISSSLFP:
    case RPL_WHOISSTAFF:
    case RPL_WHOISSVCMSG:
    case RPL_WHOISTEXT:
    case RPL_WHOISUSER:
    case RPL_WHOISVIRT:
    case RPL_WHOISWEBIRC:
    case RPL_WHOISYOURID:
    case RPL_WHOIS_HIDDEN:
    case RPL_WHOISACTUALLY:
    case RPL_WHOWASDETAILS:
    case RPL_WHOWASHOST:
    case RPL_WHOWASIP:
    case RPL_WHOWASREAL:
    case RPL_WHOWASUSER:
    case RPL_WHOWAS_TIME:
    case RPL_ENDOFWHOWAS:
    case RPL_WHOISSERVER:
    case RPL_CHARSET:
    case RPL_STATSRLINE:
        immutable shouldSquelch = plugin.hasSquelches &&
            updateSquelchstamp(
                plugin,
                event.time,
                event.channel,
                event.sender.nickname,
                event.target.nickname);

        if (!shouldSquelch && !plugin.printerSettings.filterWhois)
        {
            goto default;
        }
        else
        {
            break;
        }

    case RPL_NAMREPLY:
    case RPL_ENDOFNAMES:
    case RPL_YOURHOST:
    case RPL_ISUPPORT:
    case RPL_LUSERCLIENT:
    case RPL_LUSEROP:
    case RPL_LUSERCHANNELS:
    case RPL_LUSERME:
    case RPL_LUSERUNKNOWN:
    case RPL_GLOBALUSERS:
    case RPL_LOCALUSERS:
    case RPL_STATSCONN:
    case RPL_MYINFO:
    case RPL_CREATED:
    case CAP:
    case GLOBALUSERSTATE:
    //case USERSTATE:
    case ROOMSTATE:
    case SASL_AUTHENTICATE:
    case CTCP_AVATAR:
    case CTCP_CLIENTINFO:
    case CTCP_DCC:
    case CTCP_FINGER:
    case CTCP_LAG:
    case CTCP_PING:
    case CTCP_SLOTS:
    case CTCP_SOURCE:
    case CTCP_TIME:
    case CTCP_USERINFO:
    case CTCP_VERSION:
    case SELFMODE:
        // These event types are spammy and/or have low signal-to-noise ratio;
        // ignore if we're configured to
        if (plugin.printerSettings.filterMost) break;
        goto default;

    case JOIN:
    case PART:
        version(TwitchSupport)
        {
            if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
            {
                // Filter overly verbose JOINs and PARTs on Twitch if we're filtering
                if (plugin.printerSettings.filterMost) break;
            }
            goto default;
        }
        else
        {
            goto default;
        }

    version(WithConnectService)
    {
        case ERR_NICKNAMEINUSE:  // When failing to regain nickname
            goto case;
    }

    case RPL_WHOREPLY:
    case RPL_ENDOFWHO:
    case RPL_TOPICWHOTIME:
    case RPL_CHANNELMODEIS:
    case RPL_CREATIONTIME:
    case RPL_BANLIST:
    case RPL_QUIETLIST:
    case RPL_INVITELIST:
    case RPL_EXCEPTLIST:
    case RPL_REOPLIST:
    case RPL_ENDOFREOPLIST:
    case SPAMFILTERLIST:
    case RPL_ENDOFBANLIST:
    case RPL_ENDOFQUIETLIST:
    case RPL_ENDOFINVITELIST:
    case RPL_ENDOFEXCEPTLIST:
    case ENDOFEXEMPTOPSLIST:
    case ENDOFSPAMFILTERLIST:
    case ERR_CHANOPRIVSNEEDED:
    case RPL_AWAY:
    case ENDOFCHANNELACCLIST:
    case MODELIST:
    case ENDOFMODELIST:
    case RPL_ENDOFQLIST:
    case RPL_ENDOFALIST:
    case RPL_TOPIC:
    case RPL_NOTOPIC:
    case ERR_NOSUCHNICK:
    case ERR_NOSUCHCHANNEL:
        // Error: switch skips declaration of variable shouldSquelch
        {
            immutable shouldSquelch = plugin.hasSquelches &&
                updateSquelchstamp(
                    plugin,
                    event.time,
                    event.channel,
                    event.sender.nickname,
                    event.target.nickname);

            if (!shouldSquelch && !plugin.printerSettings.filterMost)
            {
                goto default;
            }
            else
            {
                break;
            }
        }

    version(TwitchSupport)
    {
        case USERSTATE: // Once per channel join? Once per message sent?
            break;
    }

    case PONG:
        break;

    case PING:
        import lu.string : contains;

        // Show the on-connect-ping-this type of events if !filterMost
        // Assume those containing dots are real pings for the server address
        if (!plugin.printerSettings.filterMost && event.content.length) goto default;
        break;

    default:
        import kameloso.terminal : TerminalToken;
        import lu.string : strippedRight;
        import std.array : replace;
        import std.stdio : stdout, writeln;

        // Strip bells so we don't get phantom noise
        // Strip right to get rid of trailing whitespace
        // Do it in this order in case bells hide whitespace.
        event.content = event.content
            .replace(cast(ubyte)TerminalToken.bell, string.init)
            .strippedRight;

        bool put;

        alias BellOnMention = Flag!"bellOnMention";
        alias BellOnError = Flag!"bellOnError";

        scope(exit) plugin.linebuffer.clear();

        version(Colours)
        {
            if (!plugin.state.settings.monochrome)
            {
                formatMessageColoured(
                    plugin,
                    plugin.linebuffer,
                    event,
                    cast(BellOnMention)plugin.printerSettings.bellOnMention,
                    cast(BellOnError)plugin.printerSettings.bellOnError);
                put = true;
            }
        }

        if (!put)
        {
            formatMessageMonochrome(
                plugin,
                plugin.linebuffer,
                event,
                cast(BellOnMention)plugin.printerSettings.bellOnMention,
                cast(BellOnError)plugin.printerSettings.bellOnError);
        }

        writeln(plugin.linebuffer.data);
        if (plugin.state.settings.flush) stdout.flush();
        break;
    }
}


// onLoggableEvent
/++
    Logs an event to disk.

    It is set to [kameloso.plugins.common.core.ChannelPolicy.any|ChannelPolicy.any],
    and configuration dictates whether or not non-home events should be logged.
    Likewise whether or not raw events should be logged.

    Lines will either be saved immediately to disk, opening a [std.stdio.File|File]
    with appending privileges for each event as they occur, or buffered by
    populating arrays of lines to be written in bulk, once in a while.

    See_Also:
        [commitAllLogs]
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.ANY)
    .channelPolicy(ChannelPolicy.any)
    .chainable(true)
)
void onLoggableEvent(PrinterPlugin plugin, const ref IRCEvent event)
{
    onLoggableEventImpl(plugin, event);
}


// commitAllLogs
/++
    Writes all buffered log lines to disk.

    Merely wraps [commitAllLogsImpl] by iterating over all buffers and invoking it.

    Params:
        plugin = The current [PrinterPlugin].

    See_Also:
        [kameloso.plugins.printer.logging.commitAllLogsImpl|printer.logging.commitAllLogsImpl]
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.PING)
)
void commitAllLogs(PrinterPlugin plugin)
{
    commitAllLogsImpl(plugin);
}


// onISUPPORT
/++
    Prints information about the current server as we gain details of it from an
    [dialect.defs.IRCEvent.Type.RPL_ISUPPORT|RPL_ISUPPORT] event.

    Set a flag so we only print this information once;
    ([dialect.defs.IRCEvent.Type.RPL_ISUPPORT|RPL_ISUPPORT] can/do stretch
    across several events.)
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_ISUPPORT)
)
void onISUPPORT(PrinterPlugin plugin)
{
    import kameloso.common : logger;

    static uint idWhenPrintedISUPPORT;

    if ((idWhenPrintedISUPPORT == plugin.state.connectionID) ||
        !plugin.state.server.network.length)
    {
        // We already printed this information, or we haven't yet seen NETWORK
        return;
    }

    idWhenPrintedISUPPORT = plugin.state.connectionID;

    enum pattern = "Detected <i>%s</> running daemon <i>%s</> (<t>%s</>)";
    logger.logf(
        pattern,
        plugin.state.server.network,
        plugin.state.server.daemon,
        plugin.state.server.daemonstring);
}


// datestamp
/++
    Returns a string with the current date.

    Example:
    ---
    writeln("Current date ", datestamp);
    ---

    Returns:
        A string with the current date.
 +/
package auto datestamp()
{
    import std.datetime.systime : Clock;
    import std.format : format;

    immutable now = Clock.currTime;
    enum pattern = "-- [%d-%02d-%02d]";
    return format(pattern, now.year, cast(int)now.month, now.day);
}


// initialise
/++
    Initialises the Printer plugin by allocating a slice of memory for the linebuffer.
 +/
void initialise(PrinterPlugin plugin)
{
    import kameloso.terminal : isTerminal;

    plugin.linebuffer.reserve(PrinterPlugin.linebufferInitialSize);

    if (!isTerminal)
    {
        // Not a TTY so replace our bell string with an empty one
        plugin.bell = string.init;
    }
}


// start
/++
    Sets up a Fiber to print the date in `YYYY-MM-DD` format to the screen and
    to any active log files upon day change.
 +/
void start(PrinterPlugin plugin)
{
    import kameloso.plugins.common.delayawait : delay;
    import kameloso.constants : BufferSize;
    import core.thread : Fiber;
    import core.time : Duration;

    static Duration untilNextMidnight()
    {
        import kameloso.time : nextMidnight;
        import std.datetime.systime : Clock;

        immutable now = Clock.currTime;
        return (now.nextMidnight - now);
    }

    void daybreakDg()
    {
        while (true)
        {
            if (plugin.isEnabled)
            {
                if (plugin.printerSettings.monitor && plugin.printerSettings.daybreaks)
                {
                    import kameloso.common : logger;
                    logger.info(datestamp);
                }

                if (plugin.printerSettings.logs)
                {
                    commitAllLogs(plugin);
                    plugin.buffers.clear();  // Uncommitted lines will be LOST. Not trivial to work around.
                }
            }

            delay(plugin, untilNextMidnight, Yes.yield);
        }
    }

    Fiber daybreakFiber = new Fiber(&daybreakDg, BufferSize.fiberStack);
    delay(plugin, daybreakFiber, untilNextMidnight);
}


// initResources
/++
    Ensures that there is a log directory.
 +/
void initResources(PrinterPlugin plugin)
{
    if (!plugin.printerSettings.logs) return;

    if (!establishLogLocation(plugin.logDirectory, plugin.state.connectionID))
    {
        import kameloso.plugins.common.misc : IRCPluginInitialisationException;

        throw new IRCPluginInitialisationException(
            "Could not create log directory",
            plugin.name,
            string.init,
            __FILE__,
            __LINE__);
    }
}


// teardown
/++
    De-initialises the plugin.

    If we're buffering writes, commit all queued lines to disk.
 +/
void teardown(PrinterPlugin plugin)
{
    if (plugin.printerSettings.bufferedWrites)
    {
        // Commit all logs before exiting
        commitAllLogs(plugin);
    }
}


import kameloso.thread : Sendable;

// onBusMessage
/++
    Receives a passed [kameloso.thread.Boxed|Boxed] instance with the "`printer`" header,
    listening for cues to ignore the next events caused by the
    [kameloso.plugins.services.chanqueries.ChanQueriesService|ChanQueriesService]
    querying current channel for information on the channels and their users.

    Params:
        plugin = The current [PrinterPlugin].
        header = String header describing the passed content payload.
        content = Message content.
 +/
void onBusMessage(PrinterPlugin plugin, const string header, shared Sendable content)
{
    import kameloso.thread : Boxed;
    import lu.string : nom;
    import std.typecons : Flag, No, Yes;

    if (header != "printer") return;

    auto message = cast(Boxed!string)content;
    assert(message, "Incorrectly cast message: " ~ typeof(message).stringof);

    string slice = message.payload;
    immutable verb = slice.nom!(Yes.inherit)(' ');
    immutable target = slice;

    switch (verb)
    {
    case "squelch":
        import std.datetime.systime : Clock;
        plugin.squelches[target] = Clock.currTime.toUnixTime;
        plugin.hasSquelches = true;
        break;

    case "unsquelch":
        plugin.squelches.remove(target);
        plugin.hasSquelches = (plugin.squelches.length > 0);
        break;

    default:
        import kameloso.common : logger;
        logger.error("[printer] Unimplemented bus message verb: ", verb);
        break;
    }
}


// clearTargetNicknameIfUs
/++
    Clears the target nickname if it matches the passed string.

    Example:
    ---
    event.clearTargetNicknameIfUs(plugin.state);
    ---
 +/
void clearTargetNicknameIfUs(ref IRCEvent event, const IRCPluginState state)
{
    if (event.target.nickname == state.client.nickname)
    {
        with (IRCEvent.Type)
        switch (event.type)
        {
        case MODE:
        case QUERY:
        case SELFNICK:
        case RPL_WHOREPLY:
        case RPL_WHOISUSER:
        case RPL_WHOISCHANNELS:
        case RPL_WHOISSERVER:
        case RPL_WHOISHOST:
        case RPL_WHOISIDLE:
        case RPL_LOGGEDIN:
        case RPL_WHOISACCOUNT:
        case RPL_WHOISREGNICK:
        case RPL_ENDOFWHOIS:
        case RPL_WELCOME:
        case RPL_WHOISSECURE:
        case RPL_WHOISCERTFP:
        case RPL_WHOISSSLFP:
        case RPL_WHOISSPECIAL:
        case RPL_WHOISSTAFF:
        case RPL_WHOISYOURID:
        case RPL_WHOISVIRT:
        case RPL_WHOISSVCMSG:
        case RPL_WHOISTEXT:
        case RPL_WHOISWEBIRC:
        case RPL_WHOISACTUALLY:
        case RPL_WHOISMODES:
        case RPL_WHOWASIP:
        case RPL_STATSRLINE:
            // Keep bot's nickname as target for these event types.
            break;

        version(TwitchSupport)
        {
            case CLEARCHAT:
            case CLEARMSG:
            case TWITCH_BAN:
            case TWITCH_GIFTCHAIN:
            case TWITCH_GIFTRECEIVED:
            case TWITCH_SUBGIFT:
            case TWITCH_TIMEOUT:
            case CHAN:
            case EMOTE:
                // Likewise
                break;
        }

        default:
            event.target.nickname = string.init;
            return;
        }
    }
    else if (event.target.nickname == "*")
    {
        /++
            Some events have an asterisk in what we consider the target nickname field. Sometimes.
            [loggedin] wolfe.freenode.net (*): "You are now logged in as kameloso." (#900)
            Clear it if so, since it conveys no information we care about.
         +/
        event.target.nickname = string.init;
    }
}

///
unittest
{
    enum us = "kameloso";
    enum notUs = "hirrsteff";

    IRCPluginState state;
    state.client.nickname = us;

    {
        IRCEvent event;
        event.type = IRCEvent.Type.MODE;
        event.target.nickname = us;
        event.clearTargetNicknameIfUs(state);
        assert((event.target.nickname == us), event.target.nickname);
    }
    {
        IRCEvent event;
        event.type = IRCEvent.Type.MODE;
        event.target.nickname = notUs;
        event.clearTargetNicknameIfUs(state);
        assert((event.target.nickname == notUs), event.target.nickname);
    }
}


mixin UserAwareness!(ChannelPolicy.any);
mixin ChannelAwareness!(ChannelPolicy.any);
mixin PluginRegistration!(PrinterPlugin, -40.priority);

public:


// PrinterPlugin
/++
    The Printer plugin takes all [dialect.defs.IRCEvent|IRCEvent]s and prints them to
    the local terminal, formatted and optionally in colour. Alternatively to disk as logs.

    This used to be part of the core program, but with UDAs it's easy to split
    off into its own plugin.
 +/
final class PrinterPlugin : IRCPlugin
{
private:
    import kameloso.terminal : TerminalToken;
    import std.array : Appender;

package:
    /// All Printer plugin options gathered.
    PrinterSettings printerSettings;

    /// How many seconds before a request to squelch list events times out.
    enum squelchTimeout = 5;  // seconds

    /// How many bytes to preallocate for the [linebuffer].
    enum linebufferInitialSize = 2048;

    /++
        Nicknames or channels, to or from which select events should be squelched.
        UNIX timestamp value.
     +/
    long[string] squelches;

    /// Whether or not at least one squelch is active; whether [squelches] is non-empty.
    bool hasSquelches;

    /// Buffers, to clump log file writes together.
    LogLineBuffer[string] buffers;

    /// Buffer to fill with the line to print to screen.
    Appender!(char[]) linebuffer;

    /// Where to save logs.
    @Resource string logDirectory = "logs";

    /// [kameloso.terminal.TerminalToken.bell|TerminalToken.bell] as string, for use as bell.
    private enum bellString = "" ~ cast(char)(TerminalToken.bell);

    /// Effective bell after [kameloso.terminal.isTerminal] checks.
    string bell = bellString;

    mixin IRCPluginImpl;
}
