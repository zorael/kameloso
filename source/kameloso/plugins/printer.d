/++
 +  The Printer plugin takes incoming `dialect.defs.IRCEvent`s, formats them
 +  into being easily readable and prints them to the screen, optionally with colours.
 +
 +  It has no commands; all `dialect.defs.IRCEvent`s will be parsed and
 +  printed, excluding certain types that were deemed too spammy. Print them as
 +  well by disabling `PrinterSettings.filterMost`.
 +
 +  It is not technically necessary, but it is the main form of feedback you
 +  get from the plugin, so you will only want to disable it if you want a
 +  really "headless" environment. There's also logging to consider.
 +/
module kameloso.plugins.printer;

version(WithPlugins):
version(WithPrinterPlugin):

private:

import kameloso.plugins.common;
import kameloso.common;
import kameloso.irccolours;
import dialect.defs;

version(Colours) import kameloso.terminal : TerminalForeground;

import std.range.primitives : isOutputRange;
import std.typecons : Flag, No, Yes;


// PrinterSettings
/++
 +  All Printer plugin options gathered in a struct.
 +/
struct PrinterSettings
{
    /// Toggles whether or not the plugin should react to events at all.
    @Enabler bool enabled = true;

    /// Toggles whether or not the plugin should print to screen (as opposed to just log).
    bool printToScreen = true;

    /// Whether or not to display advanced colours in RRGGBB rather than simple Terminal.
    bool truecolour = true;

    /// Whether or not to normalise truecolours; make dark brighter and bright darker.
    bool normaliseTruecolour = true;

    /// Whether or not to display nicks in random colour based on their nickname hash.
    bool randomNickColours = true;

    version(TwitchSupport)
    {
        /// Whether or not to display Twitch badges next to sender/target names.
        bool twitchBadges = true;

        /// Whether to show Twitch badges abbreviated into single characters or in full.
        bool abbreviatedBadges = false;

        /// Whether or not emotes should be highlit in colours.
        bool colourfulEmotes = true;
    }

    /++
     +  Whether or not to show Message of the Day upon connecting.
     +
     +  Warning! MOTD generally lists server rules, which might be good to read.
     +/
    bool motd = false;

    /// Whether or not to filter away most uninteresting events.
    bool filterMost = true;

    /// Whether or not to filter WHOIS queries.
    bool filterWhois = true;

    /// Whether or not to send a terminal bell signal when the bot is mentioned in chat.
    bool bellOnMention = true;

    /// Whether or not to bell on parsing errors.
    bool bellOnError = true;

    /// Whether or not to be silent and not print error messages in the event output.
    bool silentErrors = false;

    /// Whether or not to have the type (and badge) names be in capital letters.
    bool uppercaseTypes = false;

    /// Whether or not to print a banner to the terminal at midnights, when day changes.
    bool daybreaks = true;

    /// Whether or not to log events.
    bool logs = false;

    /// Whether or not to log non-home channels.
    bool logAllChannels = false;

    /// Whether or not to log errors.
    bool logErrors = true;

    /// Whether or not to log server messages.
    bool logServer = false;

    /// Whether or not to log raw events.
    bool logRaw = false;

    /// Whether or not to buffer writes.
    bool bufferedWrites = true;
}


// onPrintableEvent
/++
 +  Prints an event to the local terminal.
 +
 +  Avoids extra allocation by writing directly to a `std.stdio.LockingTextWriter`.
 +/
@(Chainable)
@(IRCEvent.Type.ANY)
@(ChannelPolicy.any)
void onPrintableEvent(PrinterPlugin plugin, const IRCEvent event)
{
    if (!plugin.printerSettings.printToScreen) return;

    IRCEvent mutEvent = event; // need a mutable copy

    // For many types there's no need to display the target nickname when it's the bot's
    // Clear event.target.nickname for those types.
    mutEvent.clearTargetNicknameIfUs(plugin.state);

    /++
     +  Update the squelchstamp and return whether or not the current event
     +  should be squelched.
     +/
    static bool updateSquelchstamp(PrinterPlugin plugin, const long time,
        const string channel, const string sender, const string target)
    in ((channel.length || sender.length || target.length),
        "Tried to update squelchstamp but with no channel or user information passed")
    {
        if (channel.length)
        {
            if (channel != plugin.squelchTarget) return false;
        }
        else if (sender.length)
        {
            if (sender != plugin.squelchTarget) return false;
        }
        else if (target.length)
        {
            if (target != plugin.squelchTarget) return false;
        }
        else
        {
            assert(0, "Logic error; tried to update squelchstamp but " ~
                "no `channel`, no `sender`, no `target`");
        }

        if ((time - plugin.squelchstamp) <= plugin.squelchTimeout)
        {
            plugin.squelchstamp = time;
            return true;
        }
        else
        {
            plugin.squelchstamp = 0L;
            plugin.squelchTarget = string.init;
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
        if (!plugin.printerSettings.filterWhois) goto default;
        break;

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
        if (!plugin.printerSettings.filterMost) goto default;
        break;

    case JOIN:
    case PART:
        version(TwitchSupport)
        {
            if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
            {
                // Filter overly verbose JOINs and PARTs on Twitch if we're filtering
                goto case ROOMSTATE;
            }
            else
            {
                goto default;
            }
        }
        else
        {
            goto default;
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
    case ENDOFSPAMFILTERLIST:
    case ERR_CHANOPRIVSNEEDED:
    case RPL_AWAY:
        immutable shouldSquelch = (plugin.squelchstamp > 0L) &&
            updateSquelchstamp(plugin, event.time, event.channel,
                event.sender.nickname, event.target.nickname);

        if (shouldSquelch)
        {
            return;
        }
        else
        {
            // Obey normal filterMost rules for unsquelched
            goto case RPL_NAMREPLY;
        }

    case RPL_TOPIC:
    case RPL_NOTOPIC:
        immutable shouldSquelch = (plugin.squelchstamp > 0L) &&
            updateSquelchstamp(plugin, event.time, event.channel,
                event.sender.nickname, event.target.nickname);

        if (shouldSquelch)
        {
            return;
        }
        else
        {
            // Always display unsquelched
            goto default;
        }

    case USERSTATE: // Insanely spammy, once every sent message
    case PING:
    case PONG:
        break;

    default:
        import lu.string : strippedRight;
        import std.array : replace;
        import std.stdio : stdout;

        // Strip bells so we don't get phantom noise
        // Strip right to get rid of trailing whitespace
        // Do it in this order in case bells hide whitespace.
        mutEvent.content = mutEvent.content
            .replace(cast(ubyte)7, string.init)
            .strippedRight;

        bool printed;

        version(Colours)
        {
            if (!settings.monochrome)
            {
                plugin.formatMessageColoured(stdout.lockingTextWriter, mutEvent,
                    plugin.printerSettings.bellOnMention, plugin.printerSettings.bellOnError);
                printed = true;
            }
        }

        if (!printed)
        {
            plugin.formatMessageMonochrome(stdout.lockingTextWriter, mutEvent,
                plugin.printerSettings.bellOnMention, plugin.printerSettings.bellOnError);
        }

        if (settings.flush) stdout.flush();
        break;
    }
}


// LogLineBuffer
/++
 +  A struct containing lines to write to a log file when next committing such.
 +
 +  This is only relevant if `PrinterSettings.bufferedWrites` is set.
 +
 +  As a micro-optimisation an `std.array.Appender` is used to store the lines,
 +  instead of a normal `string[]`.
 +/
struct LogLineBuffer
{
    import std.array : Appender;
    import std.path : buildNormalizedPath;

    /// Basename directory this buffer will be saved to.
    string dir;

    /// Fully qualified filename this buffer will be saved to.
    string file;

    /// Buffered lines that will be saved to `file`, in `dir`.
    Appender!(string[]) lines;

    /++
     +  Constructor taking a `std.datetime.sytime.SysTime`, to save as the date
     +  the buffer was created.
     +/
    this(const string dir, const SysTime now)
    {
        import std.datetime.date : Date;

        static string yyyyMMOf(const SysTime date)
        {
            // Cut the day from the date string, keep YYYY-MM
            return (cast(Date)date).toISOExtString[0..7];
        }

        this.dir = dir;
        this.file = buildNormalizedPath(this.dir, yyyyMMOf(now) ~ ".log");
    }

    /++
     +  Constructor not taking a `std.datetime.sytime.SysTime`, for use with
     +  buffers that should not be dated, such as the error log and the raw log.
     +/
    this(const string dir, const string filename)
    {
        this.dir = dir;
        this.file = buildNormalizedPath(this.dir, filename);
    }
}


// onLoggableEvent
/++
 +  Logs an event to disk.
 +
 +  It is set to `kameloso.plugins.common.ChannelPolicy.any`, and configuration
 +  dictates whether or not non-home events should be logged. Likewise whether
 +  or not raw events should be logged.
 +
 +  Lines will either be saved immediately to disk, opening a `std.stdio.File`
 +  with appending privileges for each event as they occur, or buffered by
 +  populating arrays of lines to be written in bulk, once in a while.
 +
 +  See_Also:
 +      `commitAllLogs`
 +/
@(Chainable)
@(ChannelPolicy.any)
@(IRCEvent.Type.ANY)
void onLoggableEvent(PrinterPlugin plugin, const IRCEvent event)
{
    if (!plugin.printerSettings.logs) return;  // Allow for disabled printer to still log

    // Ignore some types that would only show up in the log with the bot's name.
    with (IRCEvent.Type)
    switch (event.type)
    {
    case SELFMODE:
        // Add more types as they are found
        return;

    default:
        break;
    }

    import std.algorithm.searching : canFind;

    if (!plugin.printerSettings.logAllChannels &&
        event.channel.length && !plugin.state.bot.homeChannels.canFind(event.channel))
    {
        // Not logging all channels and this is not a home.
        return;
    }

    import std.typecons : Flag, No, Yes;

    /// Write buffered lines.
    void writeEventToFile(const string key, const string givenPath = string.init,
        Flag!"extendPath" extendPath = Yes.extendPath, Flag!"raw" raw = No.raw)
    {
        import std.exception : ErrnoException;
        import std.file : FileException;

        immutable path = givenPath.length ? givenPath.escapedPath : key.escapedPath;

        try
        {
            /// Write datestamp to file immediately, bypassing any buffers.
            static void insertDatestamp(const LogLineBuffer* buffer)
            {
                assert(buffer, "Tried to add datestamp to null buffer");
                assert((buffer.file.length && buffer.dir.length),
                    "Tried to add datestamp to uninitialised buffer");

                import std.file : exists, mkdirRecurse;
                import std.stdio : File, writeln;

                if (!buffer.dir.exists) mkdirRecurse(buffer.dir);

                // Insert an empty space if the file exists, to separate old content from new
                immutable addLinebreak = buffer.file.exists;

                File file = File(buffer.file, "a");

                if (addLinebreak) file.writeln();

                file.writeln(datestamp);
            }

            LogLineBuffer* buffer = key in plugin.buffers;

            if (!buffer)
            {
                if (extendPath)
                {
                    import std.datetime.systime : Clock;
                    import std.file : exists, mkdirRecurse;
                    import std.path : buildNormalizedPath;

                    immutable subdir = buildNormalizedPath(plugin.logDirectory, path);
                    plugin.buffers[key] = LogLineBuffer(subdir, Clock.currTime);
                }
                else
                {
                    plugin.buffers[key] = LogLineBuffer(plugin.logDirectory, path);
                }

                buffer = key in plugin.buffers;
                if (!raw) insertDatestamp(buffer);  // New buffer, new "day", except if raw
            }

            if (!raw)
            {
                // Normal buffers
                if (plugin.printerSettings.bufferedWrites)
                {
                    import std.array : Appender;

                    // Normal log
                    Appender!string sink;
                    sink.reserve(512);
                    // false bell on mention and errors
                    plugin.formatMessageMonochrome(sink, event, false, false);
                    buffer.lines ~= sink.data;
                }
                else
                {
                    import std.file : exists, mkdirRecurse;

                    if (!buffer.dir.exists)
                    {
                        mkdirRecurse(buffer.dir);
                    }

                    import std.stdio : File;
                    auto file = File(buffer.file, "a");
                    plugin.formatMessageMonochrome(file.lockingTextWriter, event, false, false);
                }
            }
            else
            {
                // Raw log
                if (plugin.printerSettings.bufferedWrites)
                {
                    buffer.lines ~= event.raw;
                }
                else
                {
                    import std.file : exists, mkdirRecurse;

                    if (!buffer.dir.exists)
                    {
                        mkdirRecurse(buffer.dir);
                    }

                    import std.stdio : File;
                    auto file = File(buffer.file, "a");
                    file.writeln(event.raw);
                }
            }

            // Errors
            if (plugin.printerSettings.logErrors && event.errors.length)
            {
                import kameloso.printing : formatObjects;

                enum errorLabel = "<error>";
                LogLineBuffer* errBuffer = errorLabel in plugin.buffers;

                if (!errBuffer)
                {
                    plugin.buffers[errorLabel] = LogLineBuffer(plugin.logDirectory, "error.log");
                    errBuffer = errorLabel in plugin.buffers;
                    insertDatestamp(errBuffer);  // New buffer, new "day"
                }

                if (plugin.printerSettings.bufferedWrites)
                {
                    errBuffer.lines ~= formatObjects!(Yes.printAll, No.coloured)(false, event);

                    if (event.sender.nickname.length || event.sender.address.length)
                    {
                        errBuffer.lines ~= formatObjects!(Yes.printAll, No.coloured)(false, event.sender);
                    }

                    if (event.target.nickname.length || event.target.address.length)
                    {
                        errBuffer.lines ~= formatObjects!(Yes.printAll, No.coloured)(false, event.target);
                    }
                }
                else
                {
                    import std.stdio : File;

                    File(errBuffer.file, "a")
                        .lockingTextWriter
                        .formatObjects!(Yes.printAll, No.coloured)(false, event);

                    if (event.sender.nickname.length || event.sender.address.length)
                    {
                        File(errBuffer.file, "a")
                            .lockingTextWriter
                            .formatObjects!(Yes.printAll, No.coloured)(false, event.sender);
                    }

                    if (event.target.nickname.length || event.target.address.length)
                    {
                        File(errBuffer.file, "a")
                            .lockingTextWriter
                            .formatObjects!(Yes.printAll, No.coloured)(false, event.target);
                    }
                }
            }
        }
        catch (FileException e)
        {
            logger.warning("File exception caught when writing to log: ", e.msg);
        }
        catch (ErrnoException e)
        {
            logger.warning("Exception caught when writing to log: ", e.msg);
        }
        catch (Exception e)
        {
            logger.warning("Unhandled exception caught when writing to log: ", e.msg);
        }
    }

    if (plugin.printerSettings.logRaw)
    {
        writeEventToFile("<raw>", "raw.log", No.extendPath, Yes.raw);
    }

    with (IRCEvent.Type)
    with (plugin)
    with (event)
    switch (event.type)
    {
    case PING:
        // Not of formatted loggable interest (raw will have been logged above)
        return;

    case QUIT:
    case NICK:
    case ACCOUNT:
    case AWAY:
    case BACK:
    case CHGHOST:
        // These don't carry a channel; instead have them be logged in all
        // channels this user is in (that the bot is also in)
        foreach (immutable channelName, const foreachChannel; state.channels)
        {
            if (!printerSettings.logAllChannels && !state.bot.homeChannels.canFind(channelName))
            {
                // Not logging all channels and this is not a home.
                continue;
            }

            if (sender.nickname in foreachChannel.users)
            {
                // Channel message
                writeEventToFile(channelName);
            }
        }

        if (sender.nickname.length && sender.nickname in plugin.buffers)
        {
            // There is an open query buffer; write to it too
            writeEventToFile(sender.nickname);
        }
        break;

    version(TwitchSupport)
    {
        case JOIN:
        case PART:
        case USERSTATE:
            if (state.server.daemon == IRCServer.Daemon.twitch)
            {
                // These Twitch events are just noise.
                return;
            }
            else
            {
                goto default;
            }
    }

    default:
        if (channel.length && (sender.nickname.length || type == MODE))
        {
            // Channel message, or specialcased server-sent MODEs
            writeEventToFile(channel);
        }
        else if (sender.nickname.length)
        {
            // Implicitly not a channel; query
            writeEventToFile(sender.nickname);
        }
        else if (printerSettings.logServer && !sender.nickname.length && sender.address.length)
        {
            // Server
            writeEventToFile(state.server.address, "server.log", No.extendPath);
        }
        else
        {
            // Don't know where to log this event; bail
            return;
        }
        break;
    }
}


// establishLogLocation
/++
 +  Verifies that a log directory exists, complaining if it's invalid, creating
 +  it if it doesn't exist.
 +
 +  Example:
 +  ---
 +  assert(!("~/logs".isDir));
 +  bool locationIsOkay = establishLogLocation("~/logs");
 +  assert("~/logs".isDir);
 +  ---
 +
 +  Params:
 +      plugin = The current `PrinterPlugin`.
 +      logLocation = String of the location directory we want to store logs in.
 +
 +  Returns:
 +      A bool whether or not the log location is valid.
 +/
bool establishLogLocation(PrinterPlugin plugin, const string logLocation)
{
    import std.file : exists, isDir;

    if (logLocation.exists)
    {
        if (logLocation.isDir) return true;

        if (!plugin.naggedAboutDir)
        {
            string logtint, warningtint;

            version(Colours)
            {
                if (!settings.monochrome)
                {
                    import kameloso.logger : KamelosoLogger;

                    logtint = (cast(KamelosoLogger)logger).logtint;
                    warningtint = (cast(KamelosoLogger)logger).warningtint;
                }
            }

            logger.warningf("Specified log directory (%s%s%s) is not a directory.",
                logtint, logLocation, warningtint);

            plugin.naggedAboutDir = true;
        }

        return false;
    }
    else
    {
        // Create missing log directory
        import std.file : mkdirRecurse;

        mkdirRecurse(logLocation);

        string infotint;

        version(Colours)
        {
            if (!settings.monochrome)
            {
                import kameloso.logger : KamelosoLogger;
                infotint = (cast(KamelosoLogger)logger).infotint;
            }
        }

        logger.logf("Created log directory: %s%s", infotint, logLocation);
    }

    return true;
}


// commitAllLogs
/++
 +  Writes all buffered log lines to disk.
 +
 +  Merely wraps `commitLog` by iterating over all buffers and invoking it.
 +
 +  Params:
 +      plugin = The current `PrinterPlugin`.
 +
 +  See_Also:
 +      `commitLog`
 +/
@(IRCEvent.Type.PING)
@(IRCEvent.Type.RPL_ENDOFMOTD)
@(IRCEvent.Type.ERR_NOMOTD)
void commitAllLogs(PrinterPlugin plugin)
{
    if (!plugin.printerSettings.logs || !plugin.printerSettings.bufferedWrites) return;

    import kameloso.terminal : TerminalToken;
    import std.exception : ErrnoException;
    import std.file : FileException;

    foreach (ref buffer; plugin.buffers)
    {
        commitLog(buffer);
    }
}


// commitLog
/++
 +  Writes a single log buffer to disk.
 +
 +  This is a way of queuing writes so that they can be committed seldomly and
 +  in bulk, supposedly being nicer to the hardware at the cost of the risk of
 +  losing uncommitted lines in a catastrophical crash.
 +
 +  Params:
 +      buffer = `LogLineBuffer` whose lines to commit to disk.
 +
 +  See_Also:
 +      `commitAllLogs`
 +/
void commitLog(ref LogLineBuffer buffer)
{
    import kameloso.terminal : TerminalToken;
    import std.exception : ErrnoException;
    import std.file : FileException;

    if (!buffer.lines.data.length) return;

    try
    {
        import std.array : join;
        import std.file : exists, mkdirRecurse;
        import std.stdio : File, writeln;

        if (!buffer.dir.exists)
        {
            mkdirRecurse(buffer.dir);
        }

        immutable lines = buffer.lines.data.join("\n");
        File(buffer.file, "a").writeln(lines);

        // Only clear if we managed to write everything, otherwise accumulate
        buffer.lines.clear();
    }
    catch (FileException e)
    {
        logger.warning("File exception caught when committing log: ",
            e.msg, cast(char)TerminalToken.bell);
    }
    catch (ErrnoException e)
    {
        logger.warning("Exception caught when committing log: ",
            e.msg, cast(char)TerminalToken.bell);
    }
    catch (Exception e)
    {
        logger.warning("Unhandled exception caught when committing log: ",
            e.msg, cast(char)TerminalToken.bell);
    }
}


// onISUPPORT
/++
 +  Prints information about the current server as we gain details of it from an
 +  `dialect.defs.IRCEvent.Type.RPL_ISUPPORT` event.
 +
 +  Set a flag so we only print this information once; (ISUPPORTS can/do stretch
 +  across several events.)
 +/
@(IRCEvent.Type.RPL_ISUPPORT)
void onISUPPORT(PrinterPlugin plugin)
{
    if (plugin.printedISUPPORT || !plugin.state.server.network.length)
    {
        // We already printed this information, or we haven't yet seen NETWORK
        return;
    }

    plugin.printedISUPPORT = true;

    with (plugin.state.server)
    {
        import std.string : capitalize;
        import std.uni : isLower;

        immutable networkName = network[0].isLower ? capitalize(network) : network;
        string infotint, logtint, tintreset;

        version(Colours)
        {
            if (!settings.monochrome)
            {
                import kameloso.logger : KamelosoLogger;
                import kameloso.terminal : TerminalReset, colour;

                infotint = (cast(KamelosoLogger)logger).infotint;
                logtint = (cast(KamelosoLogger)logger).logtint;
                enum tintresetColour = TerminalReset.all.colour.idup;
                tintreset = tintresetColour;
            }
        }

        import lu.conv : Enum;
        logger.logf("Detected %s%s%s running daemon %s%s%s (%s)",
            infotint, networkName, logtint,
            infotint, Enum!(IRCServer.Daemon).toString(daemon),
            tintreset, daemonstring);
    }
}


// put
/++
 +  Puts a variadic list of values into an output range sink.
 +
 +  Params:
 +      colours = Whether or not to accept terminal colour tokens and use
 +          them to tint the text.
 +      sink = Output range to sink items into.
 +      args = Variadic list of things to put into the output range.
 +/
void put(Flag!"colours" colours = No.colours, Sink, Args...)
    (auto ref Sink sink, Args args)
if (isOutputRange!(Sink, char[]))
{
    import std.conv : to;
    import std.traits : Unqual;

    foreach (arg; args)
    {
        alias T = Unqual!(typeof(arg));

        bool coloured;

        version(Colours)
        {
            import kameloso.terminal : isAColourCode;

            static if (colours && isAColourCode!T)
            {
                import kameloso.terminal : colourWith;
                sink.colourWith(arg);
                coloured = true;
            }
        }

        if (coloured) continue;

        static if (__traits(compiles, sink.put(T.init)) && !is(T == bool))
        {
            sink.put(arg);
        }
        else static if (is(T == bool))
        {
            sink.put(arg ? "true" : "false");
        }
        else static if (is(T : int))
        {
            import lu.conv : toAlphaInto;
            arg.toAlphaInto(sink);
        }
        else
        {
            sink.put(arg.to!string);
        }
    }
}

///
unittest
{
    import std.array : Appender;

    Appender!string sink;

    .put(sink, "abc", 123, "def", 456, true);
    assert((sink.data == "abc123def456true"), sink.data);

    version(Colours)
    {
        import kameloso.terminal : TerminalBackground, TerminalForeground, TerminalReset;

        sink = typeof(sink).init;

        .put!(Yes.colours)(sink, "abc", TerminalForeground.white, "def",
            TerminalBackground.red, "ghi", TerminalReset.all, "123");
        assert((sink.data == "abc\033[97mdef\033[41mghi\033[0m123"), sink.data);
    }
}


// formatMessageMonochrome
/++
 +  Formats an `dialect.defs.IRCEvent` into an output range sink, in monochrome.
 +
 +  It formats the timestamp, the type of the event, the sender or sender alias,
 +  the channel or target, the content body, as well as auxiliary information.
 +
 +  Params:
 +      plugin = Current `PrinterPlugin`.
 +      sink = Output range to format the `dialect.defs.IRCEvent` into.
 +      event = The `dialect.defs.IRCEvent` that is to be formatted.
 +      bellOnMention = Whether or not to emit a terminal bell when the bot's
 +          nickname is mentioned in chat.
 +      bellOnError = Whether or not to emit a terminal bell when an error occurred.
 +/
void formatMessageMonochrome(Sink)(PrinterPlugin plugin, auto ref Sink sink,
    IRCEvent event, const bool bellOnMention, const bool bellOnError)
if (isOutputRange!(Sink, char[]))
{
    import lu.conv : Enum;
    import std.algorithm.comparison : equal;
    import std.datetime : DateTime;
    import std.datetime.systime : SysTime;
    import std.format : formattedWrite;
    import std.uni : asLowerCase, asUpperCase;

    immutable typestring = Enum!(IRCEvent.Type).toString(event.type).withoutTypePrefix;

    bool shouldBell;

    static if (!__traits(hasMember, Sink, "data"))
    {
        scope(exit)
        {
            sink.put('\n');
        }
    }

    with (event)
    {
        void putSender()
        {
            if (sender.isServer)
            {
                sink.put(sender.address);
            }
            else
            {
                bool putAlias;

                version(TwitchSupport)
                {
                    if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) &&
                        sender.displayName.length)
                    {
                        sink.put(sender.displayName);
                        putAlias = true;

                        if ((sender.displayName != sender.nickname) &&
                            !sender.displayName.asLowerCase.equal(sender.nickname))
                        {
                            .put(sink, " <", sender.nickname, '>');
                        }
                    }
                }

                if (!putAlias && sender.nickname.length)
                {
                    // Can be no-nick special: [PING] *2716423853
                    sink.put(sender.nickname);
                }

                version(TwitchSupport)
                {
                    if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) &&
                        plugin.printerSettings.twitchBadges && sender.badges.length)
                    {
                        with (IRCEvent.Type)
                        switch (type)
                        {
                        case JOIN:
                        case SELFJOIN:
                        case PART:
                        case SELFPART:
                        case QUERY:
                        //case SELFQUERY:  // Doesn't seem to happen
                            break;

                        default:
                            sink.put(" [");
                            if (plugin.printerSettings.abbreviatedBadges)
                            {
                                sink.abbreviateBadges(sender.badges);
                            }
                            else
                            {
                                sink.put(sender.badges);
                            }
                            sink.put(']');
                        }
                    }
                }
            }
        }

        void putTarget()
        {
            sink.put(" (");

            bool putAlias;

            version(TwitchSupport)
            {
                if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) &&
                    target.displayName.length)
                {
                    .put(sink, target.displayName, ')');
                    putAlias = true;

                    if ((target.displayName != target.nickname) &&
                        !target.displayName.asLowerCase.equal(target.nickname))
                    {
                        .put(sink, " <", target.nickname, '>');
                    }
                }
            }

            if (!putAlias)
            {
                .put(sink, target.nickname, ')');
            }

            version(TwitchSupport)
            {
                if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) &&
                    plugin.printerSettings.twitchBadges && target.badges.length)
                {
                    sink.put(" [");
                    if (plugin.printerSettings.abbreviatedBadges)
                    {
                        sink.abbreviateBadges(target.badges);
                    }
                    else
                    {
                        sink.put(target.badges);
                    }
                    sink.put(']');
                }
            }
        }

        void putContent()
        {
            if (sender.isServer || sender.nickname.length)
            {
                immutable isEmote = (event.type == IRCEvent.Type.EMOTE) ||
                    (event.type == IRCEvent.Type.SELFEMOTE);

                if (isEmote)
                {
                    sink.put(' ');
                }
                else
                {
                    sink.put(`: "`);
                }

                with (IRCEvent.Type)
                switch (event.type)
                {
                case CHAN:
                case EMOTE:
                case TWITCH_SUBGIFT:
                    if (plugin.state.client.nickname.length &&
                        content.containsNickname(plugin.state.client.nickname))
                    {
                        // Nick was mentioned (certain)
                        shouldBell = bellOnMention;
                    }
                    break;

                default:
                    break;
                }

                sink.put(content);
                if (!isEmote) sink.put('"');
            }
            else
            {
                // PING or ERROR likely
                sink.put(content);  // No need for indenting space
            }
        }

        event.content = stripEffects(event.content);

        sink.put('[');

        (cast(DateTime)SysTime
            .fromUnixTime(event.time))
            .timeOfDay
            .toString(sink);

        sink.put("] [");

        if (plugin.printerSettings.uppercaseTypes) sink.put(typestring);
        else sink.put(typestring.asLowerCase);

        sink.put("] ");

        if (channel.length) .put(sink, '[', channel, "] ");

        putSender();

        if (target.nickname.length) putTarget();

        if (content.length) putContent();

        if (aux.length) .put(sink, " (", aux, ')');

        if (count != 0)
        {
            sink.put(" {");
            .put(sink, count);
            sink.put('}');
        }

        if (altcount != 0)
        {
            sink.put(" {");
            .put(sink, altcount);
            sink.put('}');
        }

        if (num > 0)
        {
            import lu.conv : toAlphaInto;

            //sink.formattedWrite(" (#%03d)", num);
            sink.put(" (#");
            num.toAlphaInto!(3, 3)(sink);
            sink.put(')');
        }

        if (errors.length && !plugin.printerSettings.silentErrors)
        {
            .put(sink, " ! ", errors, " !");
        }

        shouldBell = shouldBell || ((target.nickname == plugin.state.client.nickname) &&
            ((event.type == IRCEvent.Type.QUERY) ||
            (event.type == IRCEvent.Type.TWITCH_SUBGIFT)));
        shouldBell = shouldBell || (errors.length && bellOnError &&
            !plugin.printerSettings.silentErrors);

        if (shouldBell)
        {
            import kameloso.terminal : TerminalToken;
            sink.put(TerminalToken.bell);
        }
    }
}

///
unittest
{
    import std.array : Appender;

    Appender!string sink;

    IRCPluginState state;
    state.server.daemon = IRCServer.Daemon.twitch;
    PrinterPlugin plugin = new PrinterPlugin(state);

    IRCEvent event;

    with (event.sender)
    {
        nickname = "nickname";
        address = "127.0.0.1";
        version(TwitchSupport) displayName = "Nickname";
        //account = "n1ckn4m3";
        class_ = IRCUser.Class.whitelist;
    }

    event.type = IRCEvent.Type.JOIN;
    event.channel = "#channel";

    plugin.formatMessageMonochrome(sink, event, false, false);
    immutable joinLine = sink.data[11..$];
    version(TwitchSupport) assert((joinLine == "[join] [#channel] Nickname"), joinLine);
    else assert((joinLine == "[join] [#channel] nickname"), joinLine);
    sink = typeof(sink).init;

    event.type = IRCEvent.Type.CHAN;
    event.content = "Harbl snarbl";

    plugin.formatMessageMonochrome(sink, event, false, false);
    immutable chanLine = sink.data[11..$];
    version(TwitchSupport) assert((chanLine == `[chan] [#channel] Nickname: "Harbl snarbl"`), chanLine);
    else assert((chanLine == `[chan] [#channel] nickname: "Harbl snarbl"`), chanLine);
    sink = typeof(sink).init;

    version(TwitchSupport)
    {
        plugin.printerSettings.abbreviatedBadges = true;
        event.sender.badges = "broadcaster/0,moderator/1,subscriber/9";
        //colour = "#3c507d";

        plugin.formatMessageMonochrome(sink, event, false, false);
        immutable twitchLine = sink.data[11..$];
        version(TwitchSupport) assert((twitchLine == `[chan] [#channel] Nickname [BMS]: "Harbl snarbl"`), twitchLine);
        else assert((twitchLine == `[chan] [#channel] nickname [BMS]: "Harbl snarbl"`), twitchLine);
        sink = typeof(sink).init;
        event.sender.badges = string.init;
    }

    event.type = IRCEvent.Type.ACCOUNT;
    event.channel = string.init;
    event.content = string.init;
    event.sender.account = "n1ckn4m3";
    event.aux = "n1ckn4m3";

    plugin.formatMessageMonochrome(sink, event, false, false);
    immutable accountLine = sink.data[11..$];
    version(TwitchSupport) assert((accountLine == "[account] Nickname (n1ckn4m3)"), accountLine);
    else assert((accountLine == "[account] nickname (n1ckn4m3)"), accountLine);
    sink = typeof(sink).init;

    event.errors = "DANGER WILL ROBINSON";
    event.content = "Blah balah";
    event.num = 666;
    event.count = -42;
    event.aux = string.init;
    event.type = IRCEvent.Type.ERROR;

    plugin.formatMessageMonochrome(sink, event, false, false);
    immutable errorLine = sink.data[11..$];
    version(TwitchSupport) assert((errorLine == `[error] Nickname: "Blah balah" {-42} (#666) ` ~
        "! DANGER WILL ROBINSON !"), errorLine);
    else assert((errorLine == `[error] nickname: "Blah balah" {-42} (#666) ` ~
        "! DANGER WILL ROBINSON !"), errorLine);
    //sink = typeof(sink).init;
}


// formatMessageColoured
/++
 +  Formats an `dialect.defs.IRCEvent` into an output range sink, coloured.
 +
 +  It formats the timestamp, the type of the event, the sender or sender alias,
 +  the channel or target, the content body, as well as auxiliary information.
 +
 +  Params:
 +      plugin = Current `PrinterPlugin`.
 +      sink = Output range to format the `dialect.defs.IRCEvent` into.
 +      event = The `dialect.defs.IRCEvent` that is to be formatted.
 +      bellOnMention = Whether or not to emit a terminal bell when the bot's
 +          nickname is mentioned in chat.
 +      bellOnError = Whether or not to emit a terminal bell when an error occurred.
 +/
version(Colours)
void formatMessageColoured(Sink)(PrinterPlugin plugin, auto ref Sink sink,
    IRCEvent event, const bool bellOnMention, const bool bellOnError)
if (isOutputRange!(Sink, char[]))
{
    import kameloso.constants : DefaultColours;
    import kameloso.terminal : FG = TerminalForeground, colourWith;
    import lu.conv : Enum;
    import std.datetime : DateTime;
    import std.datetime.systime : SysTime;
    import std.format : formattedWrite;

    alias Bright = DefaultColours.EventPrintingBright;
    alias Dark = DefaultColours.EventPrintingDark;
    alias Timestamp = DefaultColours.TimestampColour;

    immutable rawTypestring = Enum!(IRCEvent.Type).toString(event.type);
    immutable typestring = rawTypestring.withoutTypePrefix;

    bool shouldBell;

    immutable bright = settings.brightTerminal;

    /++
     +  Outputs a terminal ANSI colour token based on the hash of the passed
     +  nickname.
     +
     +  It gives each user a random yet consistent colour to their name.
     +/
    FG colourByHash(const string nickname)
    {
        if (plugin.printerSettings.randomNickColours)
        {
            import kameloso.terminal : colourByHash;
            return colourByHash(nickname, bright);
        }
        else
        {
            // Don't differentiate between sender and target? Consistency?
            return bright ? Bright.sender : Dark.sender;
        }
    }

    /++
     +  Outputs a terminal truecolour token based on the #RRGGBB value stored in
     +  `user.colour`.
     +
     +  This is for Twitch servers that assign such values to users' messages.
     +  By catching it we can honour the setting by tinting users accordingly.
     +/
    void colourUserTruecolour(Sink)(auto ref Sink sink, const IRCUser user)
    if (isOutputRange!(Sink, char[]))
    {
        bool coloured;

        version(TwitchSupport)
        {
            if (!user.isServer && user.colour.length && plugin.printerSettings.truecolour)
            {
                import kameloso.terminal : truecolour;
                import lu.conv : numFromHex;

                int r, g, b;
                user.colour.numFromHex(r, g, b);

                if (plugin.printerSettings.normaliseTruecolour)
                {
                    sink.truecolour!(Yes.normalise)(r, g, b, bright);
                }
                else
                {
                    sink.truecolour!(No.normalise)(r, g, b, bright);
                }
                coloured = true;
            }
        }

        if (!coloured)
        {
            sink.colourWith(colourByHash(user.isServer ? user.address : user.nickname));
        }
    }

    static if (!__traits(hasMember, Sink, "data"))
    {
        scope(exit)
        {
            sink.put('\n');
        }
    }

    with (event)
    {
        void putSender()
        {
            colourUserTruecolour(sink, sender);

            if (sender.isServer)
            {
                sink.put(sender.address);
            }
            else
            {
                bool putAlias;

                version(TwitchSupport)
                {
                    if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) &&
                        sender.displayName.length)
                    {
                        sink.put(sender.displayName);
                        putAlias = true;

                        import std.algorithm.comparison : equal;
                        import std.uni : asLowerCase;

                        if ((sender.displayName != sender.nickname) &&
                            !sender.displayName.asLowerCase.equal(sender.nickname))
                        {
                            .put!(Yes.colours)(sink, FG.default_, " <");
                            colourUserTruecolour(sink, event.sender);
                            .put!(Yes.colours)(sink, sender.nickname, FG.default_, '>');
                        }
                    }
                }

                if (!putAlias && sender.nickname.length)
                {
                    // Can be no-nick special: [PING] *2716423853
                    sink.put(sender.nickname);
                }

                version(TwitchSupport)
                {
                    if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) &&
                        plugin.printerSettings.twitchBadges && sender.badges.length)
                    {
                        with (IRCEvent.Type)
                        switch (type)
                        {
                        case JOIN:
                        case SELFJOIN:
                        case PART:
                        case SELFPART:
                            break;

                        default:
                            .put!(Yes.colours)(sink, bright ? Bright.badge : Dark.badge, " [");
                            if (plugin.printerSettings.abbreviatedBadges)
                            {
                                sink.abbreviateBadges(sender.badges);
                            }
                            else
                            {
                                sink.put(sender.badges);
                            }
                            sink.put(']');
                        }
                    }
                }
            }
        }

        void putTarget()
        {
            // No need to check isServer; target is never server
            .put!(Yes.colours)(sink, FG.default_, " (");
            colourUserTruecolour(sink, event.target);

            bool putAlias;

            version(TwitchSupport)
            {
                if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) &&
                    target.displayName.length)
                {
                    .put!(Yes.colours)(sink, target.displayName, FG.default_, ')');
                    putAlias = true;

                    import std.algorithm.comparison : equal;
                    import std.uni : asLowerCase;

                    if ((target.displayName != target.nickname) &&
                        !target.displayName.asLowerCase.equal(target.nickname))
                    {
                        sink.put(" <");
                        colourUserTruecolour(sink, event.target);
                        .put!(Yes.colours)(sink, target.nickname, FG.default_, '>');
                    }
                }
            }

            if (!putAlias)
            {
                .put!(Yes.colours)(sink, target.nickname, FG.default_, ')');
            }

            version(TwitchSupport)
            {
                if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) &&
                    plugin.printerSettings.twitchBadges && target.badges.length)
                {
                    .put!(Yes.colours)(sink, bright ? Bright.badge : Dark.badge, " [");
                    if (plugin.printerSettings.abbreviatedBadges)
                    {
                        sink.abbreviateBadges(target.badges);
                    }
                    else
                    {
                        sink.put(target.badges);
                    }
                    sink.put(']');
                }
            }
        }

        void putContent()
        {
            immutable FG contentFgBase = bright ? Bright.content : Dark.content;
            immutable FG emoteFgBase = bright ? Bright.emote : Dark.emote;

            immutable fgBase = ((event.type == IRCEvent.Type.EMOTE) ||
                (event.type == IRCEvent.Type.SELFEMOTE)) ? emoteFgBase : contentFgBase;
            immutable isEmote = (fgBase == emoteFgBase);

            sink.colourWith(fgBase);  // Always grey colon and SASL +, prepare for emote

            if (sender.isServer || sender.nickname.length)
            {
                if (isEmote)
                {
                    sink.put(' ');
                }
                else
                {
                    sink.put(`: "`);
                }

                if (plugin.state.server.daemon != IRCServer.Daemon.twitch)
                {
                    // Twitch chat has no colours or effects, only emotes
                    content = mapEffects(content, fgBase);
                }

                version(TwitchSupport)
                {
                    if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
                    {
                        highlightEmotes(event, plugin.printerSettings.colourfulEmotes);
                    }
                }

                with (IRCEvent.Type)
                switch (event.type)
                {
                case CHAN:
                case EMOTE:
                case TWITCH_SUBGIFT:
                //case SELFCHAN:
                    import kameloso.terminal : invert;

                    /// Nick was mentioned (certain)
                    bool match;
                    string inverted = content;

                    if (content.containsNickname(plugin.state.client.nickname))
                    {
                        inverted = content.invert(plugin.state.client.nickname);
                        match = true;
                    }

                    version(TwitchSupport)
                    {
                        // On Twitch, also highlight the display name alias
                        if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) &&
                            plugin.state.client.displayName.length &&  // Should always be true but check
                            (plugin.state.client.nickname != plugin.state.client.displayName) &&
                            content.containsNickname(plugin.state.client.displayName))
                        {
                            inverted = inverted.invert(plugin.state.client.displayName);
                            match = true;
                        }
                    }

                    if (!match) goto default;

                    sink.put(inverted);
                    shouldBell = bellOnMention;
                    break;

                default:
                    // Normal non-highlighting channel message
                    sink.put(content);
                    break;
                }

                import kameloso.terminal : TerminalBackground;

                // Reset the background to ward off bad backgrounds bleeding out
                sink.colourWith(fgBase, TerminalBackground.default_);
                if (!isEmote) sink.put('"');
            }
            else
            {
                // PING or ERROR likely
                sink.put(content);  // No need for indenting space
            }
        }

        .put!(Yes.colours)(sink, bright ? Timestamp.bright : Timestamp.dark, '[');

        (cast(DateTime)SysTime
            .fromUnixTime(event.time))
            .timeOfDay
            .toString(sink);

        sink.put(']');

        import lu.string : beginsWith;

        if (rawTypestring.beginsWith("ERR_") || (event.type == IRCEvent.Type.ERROR) ||
            (event.type == IRCEvent.Type.TWITCH_ERROR))
        {
            sink.colourWith(bright ? Bright.error : Dark.error);
        }
        else
        {
            if (bright)
            {
                sink.colourWith((type == IRCEvent.Type.QUERY) ? Bright.query : Bright.type);
            }
            else
            {
                sink.colourWith((type == IRCEvent.Type.QUERY) ? Dark.query : Dark.type);
            }
        }

        import std.uni : asLowerCase;

        sink.put(" [");

        if (plugin.printerSettings.uppercaseTypes) sink.put(typestring);
        else sink.put(typestring.asLowerCase);

        sink.put("] ");

        if (channel.length)
        {
            .put!(Yes.colours)(sink, bright ? Bright.channel : Dark.channel,
                '[', channel, "] ");
        }

        putSender();

        if (target.nickname.length) putTarget();

        if (content.length) putContent();

        if (aux.length)
        {
            .put!(Yes.colours)(sink, bright ? Bright.aux : Dark.aux, " (", aux, ')');
        }

        if (count != 0)
        {
            sink.colourWith(bright ? Bright.count : Dark.count);
            sink.put(" {");
            .put(sink, count);
            sink.put('}');
        }

        if (altcount != 0)
        {
            sink.colourWith(bright ? Bright.altcount : Dark.altcount);
            sink.put(" {");
            .put(sink, altcount);
            sink.put('}');
        }

        if (num > 0)
        {
            import lu.conv : toAlphaInto;

            sink.colourWith(bright ? Bright.num : Dark.num);

            //sink.formattedWrite(" (#%03d)", num);
            sink.put(" (#");
            num.toAlphaInto!(3, 3)(sink);
            sink.put(')');
        }

        if (errors.length && !plugin.printerSettings.silentErrors)
        {
            .put!(Yes.colours)(sink, bright ? Bright.error : Dark.error,
                " ! ", errors, " !");
        }

        sink.colourWith(FG.default_);  // same for bright and dark

        shouldBell = shouldBell || ((target.nickname == plugin.state.client.nickname) &&
            ((event.type == IRCEvent.Type.QUERY) ||
            (event.type == IRCEvent.Type.TWITCH_SUBGIFT)));
        shouldBell = shouldBell || (errors.length && bellOnError &&
            !plugin.printerSettings.silentErrors);

        if (shouldBell)
        {
            import kameloso.terminal : TerminalToken;
            sink.put(TerminalToken.bell);
        }
    }
}


// withoutTypePrefix
/++
 +  Slices away any type prefixes from the string of a
 +  `dialect.defs.IRCEvent.Type`.
 +
 +  Only for shared use in `formatMessageMonochrome` and
 +  `formatMessageColoured`.
 +
 +  Example:
 +  ---
 +  immutable typestring1 = "PRIVMSG".withoutTypePrefix;
 +  assert((typestring1 == "PRIVMSG"), typestring1);  // passed through
 +
 +  immutable typestring2 = "ERR_NOSUCHNICK".withoutTypePrefix;
 +  assert((typestring2 == "NOSUCHNICK"), typestring2);
 +
 +  immutable typestring3 = "RPL_LIST".withoutTypePrefix;
 +  assert((typestring3 == "LIST"), typestring3);
 +  ---
 +
 +  Params:
 +      typestring = The string form of a `dialect.defs.IRCEvent.Type`.
 +
 +  Returns:
 +      A slice of the passed `typestring`, excluding any prefixes if present.
 +/
string withoutTypePrefix(const string typestring) @safe pure nothrow @nogc @property
{
    import lu.string : beginsWith;

    if (typestring.beginsWith("RPL_") || typestring.beginsWith("ERR_"))
    {
        return typestring[4..$];
    }
    else
    {
        version(TwitchSupport)
        {
            if (typestring.beginsWith("TWITCH_"))
            {
                return typestring[7..$];
            }
        }
    }

    return typestring;  // as is
}

///
unittest
{
    {
        immutable typestring = "RPL_ENDOFMOTD";
        immutable without = typestring.withoutTypePrefix;
        assert((without == "ENDOFMOTD"), without);
    }
    {
        immutable typestring = "ERR_CHANOPRIVSNEEDED";
        immutable without = typestring.withoutTypePrefix;
        assert((without == "CHANOPRIVSNEEDED"), without);
    }
    version(TwitchSupport)
    {{
        immutable typestring = "TWITCH_USERSTATE";
        immutable without = typestring.withoutTypePrefix;
        assert((without == "USERSTATE"), without);
    }}
    {
        immutable typestring = "PRIVMSG";
        immutable without = typestring.withoutTypePrefix;
        assert((without == "PRIVMSG"), without);
    }
}


// abbreviateBadges
/++
 +  Abbreviates a string of Twitch badges, to summarise all of them instead of
 +  picking the dominant one and just displaying that. Takes an output range.
 +
 +  Most are just summarised by the first letter in the badge (lowercase), but
 +  there would be collisions (subscriber vs sub-gifter, etc), so we make some
 +  exceptions by capitalising some common ones and rewriting others. Leave as
 +  many lowercase characters open as possible for unexpected badges.
 +
 +  It's a bit more confusing this way but it's a solid fact that users often
 +  have more than one badge, and we were singling out just one.
 +
 +  Using an associative array is an alternative approach. It's faster, but uses
 +  the heap. From the documentation:
 +
 +      The following constructs may allocate memory using the garbage collector:
 +          [...]
 +          * Any insertion, removal, or lookups in an associative array
 +
 +  It would look like the following:
 +  ---
 +  version(TwitchSupport)
 +  static immutable char[string] stringBadgeMap;
 +
 +  version(TwitchSupport)
 +  shared static this()
 +  {
 +      stringBadgeMap =
 +      [
 +          "subscriber"    : 'S',
 +          "bits"          : 'C',  // cheer
 +          "sub-gifter"    : 'G',
 +          "premium"       : 'P',  // prime
 +          "turbo"         : 'T',
 +          "moderator"     : 'M',
 +          "partner"       : 'V',  // verified
 +          "vip"           : '^',  // V taken
 +          "broadcaster"   : 'B',
 +          "twitchcon2017" : '7',
 +          "twitchcon2018" : '8',
 +          "twitchconEU2019" : '9',
 +          "twitchconNA2019" : '9',
 +          "staff"         : '*',
 +          "admin"         : '+',
 +      ];
 +  }
 + ---
 +
 +  Use the string switch for now. It's still plenty fast.
 +
 +  The result is a string with the passed badges abbreviated, one character per
 +  badge, separated into minor and major badges. Minor ones are ones that end
 +  with "`_1`", which seem to be contextual to a channel's game theme, like
 +  `overwatch_league_insider_1`, `firewatch_1`, `cuphead_1`, `H1Z1_1`, `eso_1`, ...
 +
 +  Params:
 +      sink = Output range to store the abbreviated values in.
 +      badgestring = Badges from a Twitch `badges=` IRCv3 tag.
 +/
version(TwitchSupport)
void abbreviateBadges(Sink)(auto ref Sink sink, const string badgestring)
if (isOutputRange!(Sink, char[]))
{
    import std.algorithm.iteration : splitter;
    import std.array : Appender;

    Appender!(ubyte[]) minor;

    static if (__traits(hasMember, Sink, "reserve"))
    {
        sink.reserve(8);  // reserve extra for minor badges
    }

    foreach (immutable badgeAndNum; badgestring.splitter(","))
    {
        import lu.string : nom;

        string slice = badgeAndNum;
        immutable badge = slice.nom('/');

        char badgechar;

        switch (badge)
        {
        case "subscriber":
            badgechar = 'S';
            break;

        case "bits":
        case "bits-leader":
            // rewrite to the cheer it is represented as in the normal chat
            badgechar = 'C';
            break;

        case "sub-gifter":
        case "sub-gift-leader":
            badgechar = 'G';
            break;

        case "premium":
            // prime
            badgechar = 'P';
            break;

        case "turbo":
            badgechar = 'T';
            break;

        case "moderator":
            badgechar = 'M';
            break;

        case "partner":
            // verified
            badgechar = 'V';
            break;

        case "vip":
            // V is taken, no obvious second choice
            badgechar = '^';
            break;

        case "broadcaster":
            badgechar = 'B';
            break;

        case "twitchcon2017":
            badgechar = '7';
            break;

        case "twitchcon2018":
            badgechar = '8';
            break;

        case "twitchconEU2019":
        case "twitchconNA2019":
            badgechar = '9';
            break;

        case "twitchconAmsterdam2020":
            badgechar = '0';
            break;

        case "staff":
            badgechar = '*';
            break;

        case "admin":
            badgechar = '+';
            break;

        default:
            import lu.string : beginsWith;
            import std.algorithm.searching : endsWith;

            if (badge.beginsWith("bits-"))
            {
                // bits-leader
                // bits-charity
                badgechar = badge[5];
                break;
            }
            else if (badge.endsWith("_1"))
            {
                minor.put(badge[0]);
                continue;
            }

            badgechar = badge[0];
            break;
        }

        sink.put(badgechar);
    }

    if (minor.data.length)
    {
        sink.put(':');
        sink.put(minor.data);
    }
}

///
version(TwitchSupport)
unittest
{
    import std.array : Appender;

    Appender!(char[]) sink;

    {
        immutable badges = "subscriber/24,bits/1000";
        sink.abbreviateBadges(badges);
        assert((sink.data == "SC"), sink.data);
        sink.clear();
    }
    {
        immutable badges = "moderator/1,subscriber/24";
        sink.abbreviateBadges(badges);
        assert((sink.data == "MS"), sink.data);
        sink.clear();
    }
    {
        immutable badges = "subscriber/72,premium/1,twitchcon2017/1,bits/1000";
        sink.abbreviateBadges(badges);
        assert((sink.data == "SP7C"), sink.data);
        sink.clear();
    }
    {
        immutable badges = "broadcaster/0";
        sink.abbreviateBadges(badges);
        assert((sink.data == "B"), sink.data);
        sink.clear();
    }
    {
        immutable badges = "harbl/42,snarbl/99,subscriber/4,bits/10000";
        sink.abbreviateBadges(badges);
        assert((sink.data == "hsSC"), sink.data);
        sink.clear();
    }
    {
        immutable badges = "subscriber/4,H1Z1_1/1,cuphead_1/1";
        sink.abbreviateBadges(badges);
        assert((sink.data == "S:Hc"), sink.data);
        sink.clear();
    }
    {
        immutable badges = "H1Z1_1/1";
        sink.abbreviateBadges(badges);
        assert((sink.data == ":H"), sink.data);
        sink.clear();
    }
    {
        immutable badges = "bits-charity/1";
        sink.abbreviateBadges(badges);
        assert((sink.data == "c"), sink.data);
        sink.clear();
    }
    {
        immutable badges = "bits-leader/1";
        sink.abbreviateBadges(badges);
        assert((sink.data == "C"), sink.data);
        sink.clear();
    }
}


// datestamp
/++
 +  Returns a string with the current date.
 +
 +  Example:
 +  ---
 +  writeln("Current date ", datestamp);
 +  ---
 +
 +  Returns:
 +      A string with the current date.
 +/
string datestamp()
{
    import std.format : format;
    import std.datetime.systime : Clock;

    immutable now = Clock.currTime;
    return "-- [%d-%02d-%02d]".format(now.year, cast(int)now.month, now.day);
}


// periodically
/++
 +  Prints the date in `YYYY-MM-DD` format to the screen and to any active log
 +  files upon day change.
 +/
void periodically(PrinterPlugin plugin)
{
    import std.datetime.systime : Clock;

    // Schedule the next run for the following midnight.
    plugin.state.nextPeriodical = getNextMidnight(Clock.currTime).toUnixTime;

    if (!plugin.isEnabled) return;

    if (plugin.printerSettings.printToScreen && plugin.printerSettings.daybreaks)
    {
        logger.info(datestamp);
    }

    if (plugin.printerSettings.logs)
    {
        plugin.commitAllLogs();
        plugin.buffers.clear();  // Uncommitted lines will be LOST. Not trivial to work around.
    }
}


import std.datetime.systime : SysTime;

// getNextMidnight
/++
 +  Returns a `std.datetime.systime.SysTime` of the following midnight, for use
 +  with setting the periodical timestamp.
 +
 +  Example:
 +  ---
 +  const now = Clock.currTime;
 +  const midnight = getNextMidnight(now);
 +  writeln("Time until next midnight: ", (midnight - now));
 +  ---
 +
 +  Params:
 +      now = UNIX timestamp of the base date from which to proceed to the next midnight.
 +
 +  Returns:
 +      A `std.datetime.systime.SysTime` of the midnight following the date
 +      passed as argument.
 +/
SysTime getNextMidnight(const SysTime now)
{
    import std.datetime : DateTime;
    import std.datetime.systime : SysTime;

    /+
        The difference between rolling and adding is that rolling does not affect
        larger units. For instance, rolling a SysTime one year's worth of days
        gets the exact same SysTime.
     +/

    auto next = SysTime(DateTime(now.year, now.month, now.day, 0, 0, 0), now.timezone)
        .roll!"days"(1);

    if (next.day == 1)
    {
        next.add!"months"(1);

        if (next.month == 12)
        {
            next.add!"years"(1);
        }
    }

    return next;
}

///
unittest
{
    import std.datetime : DateTime;
    import std.datetime.systime : SysTime;
    import std.datetime.timezone : UTC;

    immutable christmasEve = SysTime(DateTime(2018, 12, 24, 12, 34, 56), UTC());
    immutable nextDay = getNextMidnight(christmasEve);
    immutable christmasDay = SysTime(DateTime(2018, 12, 25, 0, 0, 0), UTC());
    assert(nextDay.toUnixTime == christmasDay.toUnixTime);

    immutable someDay = SysTime(DateTime(2018, 6, 30, 12, 27, 56), UTC());
    immutable afterSomeDay = getNextMidnight(someDay);
    immutable afterSomeDayToo = SysTime(DateTime(2018, 7, 1, 0, 0, 0), UTC());
    assert(afterSomeDay == afterSomeDayToo);

    immutable newyearsEve = SysTime(DateTime(2018, 12, 31, 0, 0, 0), UTC());
    immutable newyearsDay = getNextMidnight(newyearsEve);
    immutable alsoNewyearsDay = SysTime(DateTime(2019, 1, 1, 0, 0, 0), UTC());
    assert(newyearsDay == alsoNewyearsDay);

    immutable troubleDay = SysTime(DateTime(2018, 6, 30, 19, 14, 51), UTC());
    immutable afterTrouble = getNextMidnight(troubleDay);
    immutable alsoAfterTrouble = SysTime(DateTime(2018, 7, 1, 0, 0, 0), UTC());
    assert(afterTrouble == alsoAfterTrouble);
}


// escapedPath
/++
 +  Replaces some characters in a string that don't translate well to paths.
 +
 +  This is platform-specific, as Windows uses backslashes as directory
 +  separators and percentages for environment variables, whereas Posix uses
 +  forward slashes and dollar signs.
 +
 +  Params:
 +      path = A filesystem path in string form.
 +
 +  Returns:
 +      The passed path with some characters replaced.
 +/
auto escapedPath(const string path)
{
    import std.array : replace;

    // Replace some characters that don't translate well to paths.
    version(Windows)
    {
        return path
            .replace("\\", "_")
            .replace("%", "_");
    }
    else /*version(Posix)*/
    {
        return path
            .replace("/", "_")
            .replace("$", "_")
            .replace("{", "_")
            .replace("}", "_");
    }
}

///
unittest
{
    {
        immutable before = escapedPath("unchanged");
        immutable after = "unchanged";
        assert((before == after), after);
    }

    version(Windows)
    {
        {
            immutable before = escapedPath("a\\b");
            immutable after = "a_b";
            assert((before == after), after);
        }
        {
            immutable before = escapedPath("a%PATH%b");
            immutable after = "a_PATH_b";
            assert((before == after), after);
        }
    }
    else /*version(Posix)*/
    {
        {
            immutable before = escapedPath("a/b");
            immutable after = "a_b";
            assert((before == after), after);
        }
        {
            immutable before = escapedPath("a${PATH}b");
            immutable after = "a__PATH_b";
            assert((before == after), after);
        }
    }
}


// highlightEmotes
/++
 +  Tints emote strings and highlights Twitch emotes in a ref
 +  `dialect.defs.IRCEvent`'s `content` member.
 +
 +  Wraps `highlightEmotesImpl`.
 +
 +  Params:
 +      event = `dialect.defs.IRCEvent` whose content text to highlight.
 +      colourful = Whether or not emotes should be highlit in colours.
 +/
version(Colours)
version(TwitchSupport)
void highlightEmotes(ref IRCEvent event, const bool colourful)
{
    import kameloso.common : settings;
    import kameloso.constants : DefaultColours;
    import kameloso.terminal : colourWith;
    import lu.string : contains;
    import std.array : Appender;

    alias DefaultBright = DefaultColours.EventPrintingBright;
    alias DefaultDark = DefaultColours.EventPrintingDark;

    if (!event.emotes.length) return;

    Appender!string sink;
    sink.reserve(event.content.length + 60);  // mostly +10

    immutable TerminalForeground highlight = settings.brightTerminal ?
        DefaultBright.highlight : DefaultDark.highlight;

    with (IRCEvent.Type)
    switch (event.type)
    {
    case EMOTE:
    case SELFEMOTE:
        if (!colourful && event.tags.contains("emote-only=1"))
        {
            // Just highlight the whole line, don't worry about resetting to fgBase
            sink.colourWith(highlight);
            sink.put(event.content);
        }
        else
        {
            // Emote but mixed text and emotes OR we're doing colorful emotes
            immutable TerminalForeground emoteFgBase = settings.brightTerminal ?
                DefaultBright.emote : DefaultDark.emote;
            event.content.highlightEmotesImpl(sink, event.emotes, highlight, emoteFgBase, colourful);
        }
        break;

    case CHAN:
    case SELFCHAN:
    case TWITCH_RITUAL:
        if (!colourful && event.tags.contains("emote-only=1"))
        {
            // Emote only channel message, treat the same as an emote-only emote
            goto case EMOTE;
        }
        else
        {
            // Normal content, normal text, normal emotes
            immutable TerminalForeground contentFgBase = settings.brightTerminal ?
                DefaultBright.content : DefaultDark.content;
            event.content.highlightEmotesImpl(sink, event.emotes, highlight, contentFgBase, colourful);
        }
        break;

    default:
        return;
    }

    event.content = sink.data;
}


// highlightEmotesImpl
/++
 +  Highlights Twitch emotes in the chat by tinting them a different colour,
 +  saving the results into a passed output range sink.
 +
 +  Params:
 +      line = Content line whose containing emotes should be highlit.
 +      sink = Output range to put the results into.
 +      emotes = The list of emotes and their positions as divined from the
 +          IRCv3 tags of an event.
 +      pre = Terminal foreground tint to colour the emotes with.
 +      post = Terminal foreground tint to reset to after colouring an emote.
 +      colourful = Whether or not emotes should be highlit in colours.
 +/
version(Colours)
version(TwitchSupport)
void highlightEmotesImpl(Sink)(const string line, auto ref Sink sink,
    const string emotes, const TerminalForeground pre, const TerminalForeground post,
    const bool colourful)
if (isOutputRange!(Sink, char[]))
{
    import std.algorithm.iteration : splitter;
    import std.conv : to;

    struct Highlight
    {
        string id;
        size_t start;
        size_t end;
    }

    // max encountered emotes so far: 46
    // Severely pathological let's-crash-the-bot case: max possible ~161 emotes
    // That is a standard PRIVMSG line with ":) " repeated until 512 chars.
    // Highlight[162].sizeof == 2592, manageable stack size.
    enum maxHighlights = 162;

    Highlight[maxHighlights] highlights;

    size_t numHighlights;
    size_t pos;

    foreach (emote; emotes.splitter("/"))
    {
        import lu.string : nom;

        immutable emoteID = emote.nom(':');

        foreach (immutable location; emote.splitter(","))
        {
            import std.string : indexOf;

            if (numHighlights == maxHighlights) break;  // too many, don't go out of bounds.

            immutable dashPos = location.indexOf('-');
            immutable start = location[0..dashPos].to!size_t;
            immutable end = location[dashPos+1..$].to!size_t + 1;  // inclusive

            highlights[numHighlights++] = Highlight(emoteID, start, end);
        }
    }

    import std.algorithm.sorting : sort;
    highlights[0..numHighlights].sort!((a,b) => a.start < b.start)();

    // We need a dstring since we're slicing something that isn't necessarily ASCII
    // Without this highlights become offset a few characters depending on the text
    immutable dline = line.to!dstring;

    foreach (immutable i; 0..numHighlights)
    {
        import kameloso.terminal : colourByHash, colourWith;

        immutable id = highlights[i].id;
        immutable start = highlights[i].start;
        immutable end = highlights[i].end;

        sink.put(dline[pos..start]);
        sink.colourWith(colourful ? colourByHash(id, settings.brightTerminal) : pre);
        sink.put(dline[start..end]);
        sink.colourWith(post);

        pos = end;
    }

    // Add the remaining tail from after the last emote
    sink.put(dline[pos..$]);
}

///
version(Colours)
version(TwitchSupport)
unittest
{
    import std.array : Appender;

    Appender!(char[]) sink;

    {
        immutable emotes = "212612:14-22/75828:24-29";
        immutable line = "Moody the god pownyFine pownyL";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white, TerminalForeground.default_, false);
        assert((sink.data == "Moody the god \033[97mpownyFine\033[39m \033[97mpownyL\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "25:41-45";
        immutable line = "whoever plays nintendo switch whisper me Kappa";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white, TerminalForeground.default_, false);
        assert((sink.data == "whoever plays nintendo switch whisper me \033[97mKappa\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "877671:8-17,19-28,30-39";
        immutable line = "NOOOOOO camillsCry camillsCry camillsCry";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white, TerminalForeground.default_, false);
        assert((sink.data == "NOOOOOO \033[97mcamillsCry\033[39m " ~
            "\033[97mcamillsCry\033[39m \033[97mcamillsCry\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "822112:0-6,8-14,16-22";
        immutable line = "FortOne FortOne FortOne";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white, TerminalForeground.default_, false);
        assert((sink.data == "\033[97mFortOne\033[39m \033[97mFortOne\033[39m " ~
            "\033[97mFortOne\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "141844:17-24,26-33,35-42/141073:9-15";
        immutable line = "@mugs123 cohhWow cohhBoop cohhBoop cohhBoop";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white, TerminalForeground.default_, false);
        assert((sink.data == "@mugs123 \033[97mcohhWow\033[39m \033[97mcohhBoop\033[39m " ~
            "\033[97mcohhBoop\033[39m \033[97mcohhBoop\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "12345:81-91,93-103";
        immutable line = "Link Amazon Prime to your Twitch account and get a " ~
            "FREE SUBSCRIPTION every month courageHYPE courageHYPE " ~
            "twitch.amazon.com/prime | Click subscribe now to check if a " ~
            "free prime sub is available to use!";
        immutable highlitLine = "Link Amazon Prime to your Twitch account and get a " ~
            "FREE SUBSCRIPTION every month \033[97mcourageHYPE\033[39m \033[97mcourageHYPE\033[39m " ~
            "twitch.amazon.com/prime | Click subscribe now to check if a " ~
            "free prime sub is available to use!";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white, TerminalForeground.default_, false);
        assert((sink.data == highlitLine), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "25:32-36";
        immutable line = "@kiwiskool but you’re a sub too Kappa";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white, TerminalForeground.default_, false);
        assert((sink.data == "@kiwiskool but you’re a sub too \033[97mKappa\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "425618:6-8,16-18/1:20-21";
        immutable line = "高所恐怖症 LUL なにぬねの LUL :)";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white, TerminalForeground.default_, false);
        assert((sink.data == "高所恐怖症 \033[97mLUL\033[39m なにぬねの " ~
            "\033[97mLUL\033[39m \033[97m:)\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "425618:6-8,16-18/1:20-21";
        immutable line = "高所恐怖症 LUL なにぬねの LUL :)";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white, TerminalForeground.default_, true);
        assert((sink.data == "高所恐怖症 \033[35mLUL\033[39m なにぬねの " ~
            "\033[35mLUL\033[39m \033[36m:)\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "212612:14-22/75828:24-29";
        immutable line = "Moody the god pownyFine pownyL";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white, TerminalForeground.default_, true);
        assert((sink.data == "Moody the god \033[37mpownyFine\033[39m \033[94mpownyL\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "25:41-45";
        immutable line = "whoever plays nintendo switch whisper me Kappa";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white, TerminalForeground.default_, true);
        assert((sink.data == "whoever plays nintendo switch whisper me \033[97mKappa\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "877671:8-17,19-28,30-39";
        immutable line = "NOOOOOO camillsCry camillsCry camillsCry";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white, TerminalForeground.default_, true);
        assert((sink.data == "NOOOOOO \033[95mcamillsCry\033[39m " ~
            "\033[95mcamillsCry\033[39m \033[95mcamillsCry\033[39m"), sink.data);
    }
}


// initialise
/++
 +  Set the next periodical timestamp to midnight immediately after plugin construction.
 +/
void initialise(PrinterPlugin plugin)
{
    import std.datetime.systime : Clock;
    plugin.state.nextPeriodical = getNextMidnight(Clock.currTime).toUnixTime;
}


// initResources
/++
 +  Ensures that there is a log directory.
 +/
void initResources(PrinterPlugin plugin)
{
    if (!plugin.printerSettings.logs) return;

    if (!plugin.establishLogLocation(plugin.logDirectory))
    {
        throw new IRCPluginInitialisationException("Could not create log directory");
    }
}


// teardown
/++
 +  De-initialises the plugin.
 +
 +  If we're buffering writes, commit all queued lines to disk.
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
 +  Receives a passed `kameloso.thread.BusMessage` with the "`printer`" header,
 +  listening for cues to ignore the next events caused by the
 +  `kameloso.plugins.chanqueries.ChanQueriesService` querying current channel
 +  for information on the channels and their users.
 +
 +  Params:
 +      plugin = The current `PrinterPlugin`.
 +      header = String header describing the passed content payload.
 +      content = Message content.
 +/
void onBusMessage(PrinterPlugin plugin, const string header, shared Sendable content)
{
    import kameloso.thread : BusMessage;
    import lu.string : nom;
    import std.typecons : Flag, No, Yes;

    if (header != "printer") return;

    auto message = cast(BusMessage!string)content;
    assert(message, "Incorrectly cast message: " ~ typeof(message).stringof);

    string slice = message.payload;
    immutable verb = slice.nom!(Yes.inherit)(' ');
    immutable target = slice;

    switch (verb)
    {
    case "squelch":
        import std.datetime.systime : Clock;
        plugin.squelchstamp = Clock.currTime.toUnixTime;
        plugin.squelchTarget = target;  // May be empty
        break;

    case "resetsquelch":
        plugin.squelchstamp = 0L;
        plugin.squelchTarget = string.init;
        break;

    default:
        logger.error("[printer] Unimplemented bus message verb: ", verb);
        break;
    }
}


// clearTargetNicknameIfUs
/++
 +  Clears the target nickname if it matches the passed string.
 +
 +  Example:
 +  ---
 +  event.clearTargetNicknameIfUs(plugin.state.client.nickname);
 +  ---
 +/
void clearTargetNicknameIfUs(ref IRCEvent event, const ref IRCPluginState state)
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

        version(TwitchSupport)
        {
            case CLEARCHAT:
            case CLEARMSG:
            case TWITCH_BAN:
            case TWITCH_GIFTCHAIN:
            case TWITCH_GIFTRECEIVED:
            case TWITCH_SUBGIFT:
            case TWITCH_TIMEOUT:
            case TWITCH_HOSTSTART:
        }
            // Keep bot's nickname as target for these event types.
            break;

        default:
            event.target.nickname = string.init;
            return;
        }
    }

    if (event.target.nickname == "*")
    {
        // Some events have an asterisk in what we consider the target nickname field. Sometimes.
        // [loggedin] wolfe.freenode.net (*): "You are now logged in as kameloso." (#900)
        // Clear it if so, since it conveys no information we care about.
        // It does not appear to be wholly reproducible, suggesting there's more to it.
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
        event.type = IRCEvent.Type.CHAN;
        event.target.nickname = us;
        event.clearTargetNicknameIfUs(state);
        assert(!event.target.nickname.length, event.target.nickname);
    }
    {
        IRCEvent event;
        event.type = IRCEvent.Type.MODE;
        event.target.nickname = us;
        event.clearTargetNicknameIfUs(state);
        assert((event.target.nickname == us), event.target.nickname);
    }
    {
        IRCEvent event;
        event.type = IRCEvent.Type.CHAN;
        event.target.nickname = notUs;
        event.clearTargetNicknameIfUs(state);
        assert((event.target.nickname == notUs), event.target.nickname);
    }
    {
        IRCEvent event;
        event.type = IRCEvent.Type.MODE;
        event.target.nickname = notUs;
        event.clearTargetNicknameIfUs(state);
        assert((event.target.nickname == notUs), event.target.nickname);
    }
}


// containsNickname
/++
 +  Searches a string for a substring that isn't surrounded by characters that
 +  can be part of a nickname. This can detect a nickname in a string without
 +  getting false positives from similar nicknames.
 +
 +  Uses `std.string.indexOf` internally with hopes of being more resilient to
 +  weird UTF-8.
 +
 +  Params:
 +      haystack = A string to search for the substring nickname.
 +      needle = The nickname substring to find in `haystack`.
 +
 +  Returns:
 +      True if `haystack` contains `needle` in such a way that it is guaranteed
 +      to not be a different nickname.
 +/
bool containsNickname(const string haystack, const string needle) pure nothrow @nogc
in (needle.length, "Tried to determine whether an empty nickname was in a string")
do
{
    import dialect.common : isValidNicknameCharacter;
    import std.string : indexOf;

    if ((haystack.length == needle.length) && (haystack == needle)) return true;

    immutable pos = haystack.indexOf(needle);
    if (pos == -1) return false;

    // Allow for a prepended @, since @mention is commonplace
    if ((pos > 0) && haystack[pos-1].isValidNicknameCharacter &&
        (haystack[pos-1] != '@')) return false;

    immutable end = pos + needle.length;

    if (end > haystack.length)
    {
        return false;
    }
    else if (end == haystack.length)
    {
        return true;
    }

    return (!haystack[end].isValidNicknameCharacter);
}

///
unittest
{
    assert("kameloso".containsNickname("kameloso"));
    assert(" kameloso ".containsNickname("kameloso"));
    assert(!"kam".containsNickname("kameloso"));
    assert(!"kameloso^".containsNickname("kameloso"));
    assert(!string.init.containsNickname("kameloso"));
    //assert(!"kameloso".containsNickname(""));  // For now let this be false.
    assert("@kameloso".containsNickname("kameloso"));
}


mixin UserAwareness!(ChannelPolicy.any);
mixin ChannelAwareness!(ChannelPolicy.any);

public:


// PrinterPlugin
/++
 +  The Printer plugin takes all `dialect.defs.IRCEvent`s and prints them to
 +  the local terminal, formatted and optionally in colour.
 +
 +  This used to be part of the core program, but with UDAs it's easy to split
 +  off into its own plugin.
 +/
final class PrinterPlugin : IRCPlugin
{
private:
    /// All Printer plugin options gathered.
    @Settings PrinterSettings printerSettings;

    /// How many seconds before a request to squelch list events times out.
    enum squelchTimeout = 10;  // seconds

    /// From which channel or for which user events are being squelched.
    string squelchTarget;

    /// Whether or not we have nagged about an invalid log directory.
    bool naggedAboutDir;

    /// Whether or not we have printed daemon-network information.
    bool printedISUPPORT;

    /++
     +  UNIX timestamp of when to expect squelchable list events.
     +
     +  Note: repeated list events refresh the timer.
     +/
    long squelchstamp;

    /// Buffers, to clump log file writes together.
    LogLineBuffer[string] buffers;

    /// Where to save logs.
    @Resource string logDirectory = "logs";

    mixin IRCPluginImpl;
}
