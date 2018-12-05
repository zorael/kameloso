/++
 +  The Printer plugin takes incoming `kameloso.irc.defs.IRCEvent`s, formats them
 +  into being easily readable and prints them to the screen, optionally with
 +  colours.
 +
 +  It has no commands; all `kameloso.irc.defs.IRCEvent`s will be parsed and
 +  pinted, excluding certain types that were deemed too spammy. Print them as
 +  well by disabling `PrinterSettings.filterVerbose`.
 +
 +  It is not technically neccessary, but it is the main form of feedback you
 +  get from the plugin, so you will only want to disable it if you want a
 +  really "headless" environment.
 +/
module kameloso.plugins.printer;

version(WithPlugins):

private:

import kameloso.plugins.common;
import kameloso.irc.defs;
import kameloso.common;
import kameloso.irc.colours;

version(Colours) import kameloso.terminal : TerminalForeground;

import std.datetime.systime : SysTime;
import std.typecons : No, Yes;


// PrinterSettings
/++
 +  All Printer plugin options gathered in a struct.
 +/
struct PrinterSettings
{
    /// Toggles whether or not the plugin should react to events at all.
    bool enabled = true;

    /// Whether to display advanced colours in RRGGBB rather than simple Terminal.
    bool truecolour = true;

    /// Whether to normalise truecolours; make dark brighter and bright darker.
    bool normaliseTruecolour = true;

    /// Whether to display nicks in random colour based on their nickname hash.
    bool randomNickColours = true;

    /// Whether to show Message of the Day upon connecting.
    bool motd = true;

    /// Whether to filter away most uninteresting events.
    bool filterVerbose = true;

    /++
     +  Whether or not to send a terminal bell signal when the bot is mentioned
     +  in chat.
     +/
    bool bellOnMention = true;

    /// Whether to bell on parsing errors.
    bool bellOnError = true;

    /// Whether to be silent and not print error messages in the event output.
    bool silentErrors = false;

    /// Whether to have the type (and badge) names be in capital letters.
    bool uppercaseTypes = false;

    /// Whether to log events.
    bool logs = false;

    /// Whether to log non-home channels.
    bool logAllChannels = false;

    /// Whether to log errors.
    bool logErrors = true;

    /// Whether to log raw events.
    bool logRaw = false;

    /// Whether to buffer writes.
    bool bufferedWrites = true;
}


// onAnyEvent
/++
 +  Prints an event to the local terminal.
 +
 +  Does not allocate, writes directly to a `std.stdio.LockingTextWriter`.
 +/
@(Chainable)
@(IRCEvent.Type.ANY)
@(ChannelPolicy.any)
void onPrintableEvent(PrinterPlugin plugin, const IRCEvent event)
{
    if (!plugin.printerSettings.enabled) return;

    IRCEvent mutEvent = event; // need a mutable copy

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

    case RPL_NAMREPLY:
    case RPL_YOURHOST:
    case RPL_ISUPPORT:
    case RPL_TOPICWHOTIME:
    case RPL_WHOISSECURE:
    case RPL_LUSERCLIENT:
    case RPL_LUSEROP:
    case RPL_LUSERCHANNELS:
    case RPL_LUSERME:
    case RPL_LUSERUNKNOWN:
    case RPL_WHOISSERVER:
    case RPL_ENDOFWHOIS:
    case RPL_ENDOFNAMES:
    case RPL_GLOBALUSERS:
    case RPL_LOCALUSERS:
    case RPL_STATSCONN:
    case RPL_CREATED:
    case RPL_CREATIONTIME:
    case RPL_MYINFO:
    case RPL_ENDOFWHO:
    case RPL_WHOREPLY:
    case RPL_CHANNELMODEIS:
    case RPL_BANLIST:
    case RPL_ENDOFBANLIST:
    case RPL_QUIETLIST:
    case RPL_ENDOFQUIETLIST:
    case RPL_INVITELIST:
    case RPL_ENDOFINVITELIST:
    case RPL_EXCEPTLIST:
    case RPL_ENDOFEXCEPTLIST:
    case SPAMFILTERLIST:
    case ENDOFSPAMFILTERLIST:
    //case CAP:
    case ERR_CHANOPRIVSNEEDED:
    case GLOBALUSERSTATE:
    case USERSTATE:
    case ROOMSTATE:
        // These event types are spammy; ignore if we're configured to
        if (!plugin.printerSettings.filterVerbose) goto default;
        break;

    case JOIN:
    case PART:
        if (plugin.state.client.server.daemon == IRCServer.Daemon.twitch)
        {
            // Filter overly verbose JOINs and PARTs on Twitch if we're filtering
            goto case ROOMSTATE;
        }
        else
        {
            goto default;
        }

    case PING:
    case PONG:
        break;

    default:
        import std.stdio : stdout;

        bool printed;

        version(Colours)
        {
            if (!settings.monochrome)
            {
                plugin.formatMessageColoured(stdout.lockingTextWriter, mutEvent,
                    plugin.printerSettings.bellOnMention);
                printed = true;
            }
        }

        if (!printed)
        {
            plugin.formatMessageMonochrome(stdout.lockingTextWriter, mutEvent,
                plugin.printerSettings.bellOnMention);
        }

        version(FlushStdout) stdout.flush();
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

    /// The filesystem path to the log file, used as an identifier.
    string path;

    /// An `std.array.Appender` housing queued lines to write.
    Appender!(string[]) lines;

    /// Create a new `LogLineBuffer` with the passed path strig as identifier.
    this(const string path)
    {
        this.path = path;
    }
}


// onLoggableEvent
/++
 +  Logs an event to disk.
 +
 +  It is set to `ChannelPolicy.any`, and configuration decides whether non-home
 +  events should be logged. Likewise whether raw events should be logged.
 +
 +  Lines will either be saved immediately to disk, opening a `std.stdio.File`
 +  with appending privileges for each event as they occur, or buffered by
 +  populating arrays of lines to be written in bulk, once in a while.
 +
 +  See_Also:
 +      commitLogs
 +/
@(Chainable)
@(ChannelPolicy.any)
@(IRCEvent.Type.ANY)
void onLoggableEvent(PrinterPlugin plugin, const IRCEvent event)
{
    if (!plugin.printerSettings.enabled || !plugin.printerSettings.logs) return;

    import std.exception : ErrnoException;
    import std.file : FileException;
    import std.path : buildNormalizedPath, expandTilde;
    import std.stdio : File, writeln;

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

    immutable logLocation = plugin.logDirectory.expandTilde;
    if (!plugin.establishLogLocation(logLocation)) return;

    import std.algorithm.searching : canFind;

    if (!plugin.printerSettings.logAllChannels &&
        event.channel.length && !plugin.state.client.homes.canFind(event.channel))
    {
        // Not logging all channels and this is not a home.
        return;
    }

    /// Write buffered lines.
    void writeToPath(const string key, const string path, bool doFormat = true)
    {
        try
        {
            LogLineBuffer* pathBuffer = key in plugin.buffers;

            if (!pathBuffer)
            {
                plugin.buffers[key] = LogLineBuffer(path);
                pathBuffer = key in plugin.buffers;

                import std.file : exists;
                if (pathBuffer.path.exists)
                {
                    if (plugin.printerSettings.bufferedWrites)
                    {
                        pathBuffer.lines.put(string.init);  // one empty line
                        pathBuffer.lines.put(datestamp);
                    }
                    else
                    {
                        auto file = File(pathBuffer.path, "a");
                        file.writeln("\n"); // likewise
                        file.writeln(datestamp);
                    }
                }
            }

            if (plugin.printerSettings.bufferedWrites)
            {
                if (doFormat)
                {
                    import std.array : Appender;
                    Appender!string sink;
                    sink.reserve(512);
                    plugin.formatMessageMonochrome(sink, event, false);  // false bell on mention
                    pathBuffer.lines ~= sink.data;
                }
                else
                {
                    pathBuffer.lines ~= event.raw;
                }
            }
            else
            {
                auto file = File(pathBuffer.path, "a");

                if (doFormat)
                {
                    plugin.formatMessageMonochrome(file.lockingTextWriter, event, false);
                }
                else
                {
                    file.writeln(event.raw);
                }
            }

            if (doFormat && event.errors.length && plugin.printerSettings.logErrors)
            {
                import kameloso.printing : formatObjects;

                enum errorLabel = "<error>";
                LogLineBuffer* errBuffer = errorLabel in plugin.buffers;

                if (!errBuffer)
                {
                    plugin.buffers[errorLabel] = LogLineBuffer(buildNormalizedPath(logLocation,
                        plugin.state.client.server.address ~ ".err.log"));
                    errBuffer = errorLabel in plugin.buffers;

                    import std.file : exists;
                    if (errBuffer.path.exists)
                    {
                        if (plugin.printerSettings.bufferedWrites)
                        {
                            errBuffer.lines.put(string.init);  // one empty line
                            errBuffer.lines.put(datestamp);
                        }
                        else
                        {
                            auto file = File(errBuffer.path, "a");
                            file.writeln("\n"); // likewise
                            file.writeln(datestamp);
                        }
                    }
                }

                if (plugin.printerSettings.bufferedWrites)
                {
                    errBuffer.lines ~= formatObjects!(Yes.printAll, No.coloured)(false, event);

                    if (event.sender != IRCUser.init)
                    {
                        errBuffer.lines ~= formatObjects!(Yes.printAll, No.coloured)(false, event.sender);
                    }

                    if (event.target != IRCUser.init)
                    {
                        errBuffer.lines ~= formatObjects!(Yes.printAll, No.coloured)(false, event.target);
                    }
                }
                else
                {
                    File(errBuffer.path, "a")
                        .lockingTextWriter
                        .formatObjects!(Yes.printAll, No.coloured)(false, event);

                    if (event.sender != IRCUser.init)
                    {
                        File(errBuffer.path, "a")
                            .lockingTextWriter
                            .formatObjects!(Yes.printAll, No.coloured)(false, event.sender);
                    }

                    if (event.target != IRCUser.init)
                    {
                        File(errBuffer.path, "a")
                            .lockingTextWriter
                            .formatObjects!(Yes.printAll, No.coloured)(false, event.target);
                    }
                }
            }
        }
        catch (const FileException e)
        {
            logger.warning("File exception caught when writing to log: ", e.msg);
        }
        catch (const ErrnoException e)
        {
            logger.warning("Exception caught when writing to log: ", e.msg);
        }
        catch (const Exception e)
        {
            logger.warning("Unhandled exception caught when writing to log: ", e.msg);
        }
    }

    if (plugin.printerSettings.logRaw)
    {
        // No need to sanitise the server address; it's ASCII
        writeToPath(string.init, buildNormalizedPath(logLocation,
            plugin.state.client.server.address ~ ".raw.log"), false);
    }

    with (IRCEvent.Type)
    with (plugin)
    with (event)
    switch (event.type)
    {
    case SASL_AUTHENTICATE:
    case PING:
        // Not of loggable interest
        return;

    case QUIT:
    case NICK:
    case ACCOUNT:
        // These don't carry a channel; instead have them be logged in all
        // channels this user is in (that the bot is also in)
        foreach (immutable channelName, const thisChannel; state.channels)
        {
            if (!printerSettings.logAllChannels && !state.client.homes.canFind(channelName))
            {
                // Not logging all channels and this is not a home.
                continue;
            }

            if (thisChannel.users.canFind(sender.nickname))
            {
                // Channel message
                writeToPath(channelName, buildNormalizedPath(logLocation, channelName.escapedPath ~ ".log"));
            }
        }

        if (sender.nickname.length && sender.nickname in plugin.buffers)
        {
            immutable queryPath = buildNormalizedPath(logLocation, sender.nickname.escapedPath ~ ".log");
            // There is an open query buffer; write to it too
            writeToPath(sender.nickname, queryPath);
        }
        break;

    default:
        if (channel.length && (sender.nickname.length || type == MODE))
        {
            // Channel message, or specialcased server-sent MODEs
            writeToPath(channel, buildNormalizedPath(logLocation, channel.escapedPath ~ ".log"));
        }
        else if (sender.nickname.length)
        {
            // Implicitly not a channel; query
            writeToPath(sender.nickname, buildNormalizedPath(logLocation,
                sender.nickname.escapedPath ~ ".log"));
        }
        else if (!sender.nickname.length && sender.address.length)
        {
            // Server
            writeToPath(state.client.server.address, buildNormalizedPath(logLocation,
                state.client.server.address.escapedPath ~ ".log"));
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


// commitLogs
/++
 +  Write buffered log lines to disk.
 +
 +  This is a way of queueing writes so that they can be committed seldomly and
 +  in bulk, supposedly being nicer to the hardware at the cost of the risk of
 +  losing uncommitted lines in a catastrophical crash.
 +
 +  In order to not accumulate a boundless amount of buffers, keep a counter of
 +  how many PINGs a buffer has been empty. When the counter reaches zero (value
 +  hardcoded in struct `LogLineBuffer`), remove the dead buffer from the array.
 +
 +  Params:
 +      plugin = The current `PrinterPlugin`.
 +/
@(IRCEvent.Type.PING)
@(IRCEvent.Type.RPL_ENDOFMOTD)
@(IRCEvent.Type.ERR_NOMOTD)
void commitLogs(PrinterPlugin plugin)
{
    if (!plugin.printerSettings.enabled || !plugin.printerSettings.logs ||
        !plugin.printerSettings.bufferedWrites) return;

    import std.file : FileException;

    foreach (ref buffer; plugin.buffers)
    {
        if (!buffer.lines.data.length) continue;

        try
        {
            import std.array : join;
            import std.stdio : File, writeln;

            immutable lines = buffer.lines.data.join("\n");
            File(buffer.path, "a").writeln(lines);
        }
        catch (const FileException e)
        {
            logger.warning("File exception caught when committing logs: ", e.msg);
        }
        catch (const Exception e)
        {
            logger.warning("Unhandled exception caught when committing logs: ", e.msg);
        }
        finally
        {
            buffer.lines.clear();
        }
    }
}


// onISUPPORT
/++
 +  Prints information about the current server as we gain details of it from an
 +  `RPL_ISUPPORT` event.
 +
 +  Set a flag so we only print this information once; (ISUPPORTS can/do stretch
 +  across several events.)
 +/
@(IRCEvent.Type.RPL_ISUPPORT)
void onISUPPORT(PrinterPlugin plugin)
{
    if (plugin.printedISUPPORT || !plugin.state.client.server.network.length)
    {
        // We already printed this information, or we havent yet seen NETWORK
        return;
    }

    plugin.printedISUPPORT = true;

    with (plugin.state.client.server)
    {
        import std.string : capitalize;
        import std.uni : isLower;

        immutable networkName = network[0].isLower ? network.capitalize() : network;
        string infotint, logtint, tintreset;

        version(Colours)
        {
            if (!settings.monochrome)
            {
                import kameloso.logger : KamelosoLogger;
                import kameloso.terminal : TerminalReset, colour;

                infotint = (cast(KamelosoLogger)logger).infotint;
                logtint = (cast(KamelosoLogger)logger).logtint;
                tintreset = TerminalReset.all.colour;
            }
        }

        import kameloso.conv : Enum;
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
 +      sink = Output range to sink items into.
 +      args = Variadic list of things to put into the output range.
 +/
void put(Sink, Args...)(auto ref Sink sink, Args args)
{
    import std.range : put;
    import std.conv : to;

    foreach (arg; args)
    {
        static if (!__traits(compiles, std.range.put(sink, typeof(arg).init)))
        {
            put(sink, arg.to!string);
        }
        else
        {
            put(sink, arg);
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
}


// formatMessageMonochrome
/++
 +  Formats an `kameloso.irc.defs.IRCEvent` into an output range sink, in
 +  monochrome.
 +
 +  It formats the timestamp, the type of the event, the sender or sender alias,
 +  the channel or target, the content body, as well as auxiliary information.
 +
 +  Params:
 +      plugin = Current `PrinterPlugin`.
 +      sink = Output range to format the `kameloso.irc.defs.IRCEvent` into.
 +      event = The `kameloso.irc.defs.IRCEvent` that is to be formatted.
 +      bellOnMention = Whether or not to emit a terminal bell when the bot's
 +          nickname is mentioned in chat.
 +/
void formatMessageMonochrome(Sink)(PrinterPlugin plugin, auto ref Sink sink,
    IRCEvent event, const bool bellOnMention)
{
    import kameloso.conv : Enum;
    import std.algorithm.comparison : equal;
    import std.datetime : DateTime;
    import std.datetime.systime : SysTime;
    import std.uni : asLowerCase, asUpperCase;

    immutable timestamp = (cast(DateTime)SysTime
        .fromUnixTime(event.time))
        .timeOfDay
        .toString();

    immutable typestring = Enum!(IRCEvent.Type).toString(event.type).withoutTypePrefix;

    bool shouldBell;

    with (event)
    {
        event.content = stripEffects(event.content);

        put(sink, '[', timestamp, "] [");

        if (plugin.printerSettings.uppercaseTypes) put(sink, typestring);
        else put(sink, typestring.asLowerCase);

        put(sink, "] ");

        if (channel.length) put(sink, '[', channel, "] ");

        if (sender.isServer)
        {
            sink.put(sender.address);
        }
        else
        {
            if (sender.alias_.length)
            {
                sink.put(sender.alias_);
                if (sender.class_ == IRCUser.Class.special) sink.put('*');

                if (!sender.alias_.asLowerCase.equal(sender.nickname))
                {
                    put(sink, " <", sender.nickname, '>');
                }
            }
            else if (sender.nickname.length)
            {
                // Can be no-nick special: [PING] *2716423853
                sink.put(sender.nickname);
                if (sender.class_ == IRCUser.Class.special) sink.put('*');
            }

            version(TwitchSupport)
            {
                if (sender.badges.length)
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
                        put(sink, " [");
                        sink.abbreviateBadges(sender.badges);
                        put(sink, ']');
                    }
                }
            }
        }

        if (target.nickname.length)
        {
            sink.put(" (");

            if (target.alias_.length)
            {
                put(sink, target.alias_, ')');

                if (target.class_ == IRCUser.Class.special) sink.put('*');

                if (!target.alias_.asLowerCase.equal(target.nickname))
                {
                    put(sink, " <", target.nickname, '>');
                }
            }
            else
            {
                put(sink, target.nickname, ')');
                if (target.class_ == IRCUser.Class.special) sink.put('*');
            }

            version(TwitchSupport)
            {
                if (target.badges.length)
                {
                    put(sink, " [");
                    sink.abbreviateBadges(target.badges);
                    put(sink, ']');
                }
            }
        }

        if (content.length)
        {
            if (sender.isServer || sender.nickname.length)
            {
                immutable isEmote = (event.type == IRCEvent.Type.EMOTE) ||
                    (event.type == IRCEvent.Type.SELFEMOTE) ||
                    (event.type == IRCEvent.Type.TWITCH_CHEER);

                if (isEmote)
                {
                    put(sink, ' ');
                }
                else
                {
                    put(sink, `: "`);
                }

                with (IRCEvent.Type)
                switch (event.type)
                {
                case CHAN:
                case EMOTE:
                case TWITCH_CHEER:
                    import kameloso.irc.common : containsNickname;
                    if (content.containsNickname(plugin.state.client.nickname))
                    {
                        // Nick was mentioned (certain)
                        shouldBell = bellOnMention;
                    }
                    break;

                default:
                    break;
                }

                put(sink, content);
                if (!isEmote) put(sink, '"');
            }
            else
            {
                // PING or ERROR likely
                put(sink, content);  // No need for indenting space
            }
        }

        if (aux.length) put(sink, " (", aux, ')');

        if (errors.length && !plugin.printerSettings.silentErrors)
        {
            put(sink, " !", errors, '!');
        }

        import std.format : formattedWrite;

        if (count != 0) sink.formattedWrite(" {%d}", count);

        if (num > 0) sink.formattedWrite(" (#%03d)", num);

        if (shouldBell || (errors.length && plugin.printerSettings.bellOnError) ||
            ((type == IRCEvent.Type.QUERY) && (target.nickname == plugin.state.client.nickname)))
        {
            import kameloso.terminal : TerminalToken;
            sink.put(TerminalToken.bell);
        }
    }

    static if (!__traits(hasMember, Sink, "data"))
    {
        sink.put('\n');
    }
}


// formatMessageColoured
/++
 +  Formats an `kameloso.irc.defs.IRCEvent` into an output range sink, coloured.
 +
 +  It formats the timestamp, the type of the event, the sender or sender alias,
 +  the channel or target, the content body, as well as auxiliary information.
 +
 +  Params:
 +      plugin = Current `PrinterPlugin`.
 +      sink = Output range to format the `kameloso.irc.defs.IRCEvent` into.
 +      event = The `kameloso.irc.defs.IRCEvent` that is to be formatted.
 +      bellOnMention = Whether or not to emit a terminal bell when the bot's
 +          nickname is mentioned in chat.
 +/
version(Colours)
void formatMessageColoured(Sink)(PrinterPlugin plugin, auto ref Sink sink,
    IRCEvent event, const bool bellOnMention)
{
    import kameloso.terminal : TerminalForeground, colour;
    import kameloso.constants : DefaultColours;
    import kameloso.conv : Enum;
    import std.datetime : DateTime;
    import std.datetime.systime : SysTime;
    import std.format : formattedWrite;

    alias DefaultBright = DefaultColours.EventPrintingBright;
    alias DefaultDark = DefaultColours.EventPrintingDark;

    immutable timestamp = (cast(DateTime)SysTime
        .fromUnixTime(event.time))
        .timeOfDay
        .toString();

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
    TerminalForeground colourByHash(const string nickname)
    {
        if (plugin.printerSettings.randomNickColours)
        {
            import std.algorithm.searching : countUntil;
            import std.traits : EnumMembers;

            alias foregroundMembers = EnumMembers!TerminalForeground;
            static immutable TerminalForeground[foregroundMembers.length] fg = [ foregroundMembers ];

            enum chancodeBright = fg[].countUntil(cast(int)DefaultBright.channel);
            enum chancodeDark = fg[].countUntil(cast(int)DefaultDark.channel);

            // Range from 2 to 15, excluding black and white and manually changing
            // the code for bright/dark channel to black/white
            size_t colourIndex = (hashOf(nickname) % 14) + 2;

            if (bright)
            {
                // Index is bright channel code, set to black
                if (colourIndex == chancodeBright) colourIndex = 1;  // black
            }
            else
            {
                // Index is dark channel code, set to white
                if (colourIndex == chancodeDark) colourIndex = 16; // white
            }

            return fg[colourIndex];
        }

        // Don't differentiate between sender and target? Consistency?
        return bright ? DefaultBright.sender : DefaultDark.sender;
    }

    /++
     +  Outputs a terminal truecolour token based on the #RRGGBB value stored in
     +  `user.colour`.
     +
     +  This is for Twitch servers that assign such values to users' messages.
     +  By catching it we can honour the setting by tinting users accordingly.
     +/
    void colourUserTruecolour(Sink)(auto ref Sink sink, const IRCUser user)
    {
        version(TwitchSupport)
        {
            if (!user.isServer && user.colour.length && plugin.printerSettings.truecolour)
            {
                import kameloso.terminal : truecolour;
                import kameloso.conv : numFromHex;

                int r, g, b;
                user.colour.numFromHex(r, g, b);

                if (plugin.printerSettings.normaliseTruecolour)
                {
                    sink.truecolour!(Yes.normalise)(r, g, b, settings.brightTerminal);
                }
                else
                {
                    sink.truecolour!(No.normalise)(r, g, b, settings.brightTerminal);
                }
            }
            else
            {
                sink.colour(colourByHash(user.isServer ? user.address : user.nickname));
            }
        }
        else
        {
            sink.colour(colourByHash(user.isServer ? user.address : user.nickname));
        }
    }

    with (event)
    {
        sink.colour(bright ? DefaultBright.timestamp : DefaultDark.timestamp);
        put(sink, '[', timestamp, ']');

        import kameloso.string : beginsWith;
        if (rawTypestring.beginsWith("ERR_"))
        {
            sink.colour(bright ? DefaultBright.error : DefaultDark.error);
        }
        else
        {
            TerminalForeground typeColour;

            if (bright)
            {
                typeColour = (type == IRCEvent.Type.QUERY) ? DefaultBright.query : DefaultBright.type;
            }
            else
            {
                typeColour = (type == IRCEvent.Type.QUERY) ? DefaultBright.query : DefaultDark.type;
            }

            sink.colour(typeColour);
        }

        import std.uni : asLowerCase;

        put(sink, " [");

        if (plugin.printerSettings.uppercaseTypes) put(sink, typestring);
        else put(sink, typestring.asLowerCase);

        put(sink, "] ");

        if (channel.length)
        {
            sink.colour(bright ? DefaultBright.channel : DefaultDark.channel);
            put(sink, '[', channel, "] ");
        }

        colourUserTruecolour(sink, event.sender);

        if (sender.isServer)
        {
            sink.put(sender.address);
        }
        else
        {
            if (sender.alias_.length)
            {
                sink.put(sender.alias_);

                if (sender.class_ == IRCUser.Class.special)
                {
                    sink.colour(bright ? DefaultBright.special : DefaultDark.special);
                    sink.put('*');
                }

                import std.algorithm.comparison : equal;
                import std.uni : asLowerCase;

                if (!sender.alias_.asLowerCase.equal(sender.nickname))
                {
                    sink.colour(TerminalForeground.default_);
                    sink.put(" <");
                    colourUserTruecolour(sink, event.sender);
                    sink.put(sender.nickname);
                    sink.colour(TerminalForeground.default_);
                    sink.put('>');
                }
            }
            else if (sender.nickname.length)
            {
                // Can be no-nick special: [PING] *2716423853
                sink.put(sender.nickname);

                if (sender.class_ == IRCUser.Class.special)
                {
                    sink.colour(bright ? DefaultBright.special : DefaultDark.special);
                    sink.put('*');
                }
            }

            version(TwitchSupport)
            {
                if (sender.badges.length)
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
                        sink.colour(bright ? DefaultBright.badge : DefaultDark.badge);
                        put(sink, " [");
                        sink.abbreviateBadges(sender.badges);
                        put(sink, ']');
                    }
                }
            }
        }

        if (target.nickname.length)
        {
            // No need to check isServer; target is never server
            sink.colour(TerminalForeground.default_);
            sink.put(" (");
            colourUserTruecolour(sink, event.target);

            if (target.alias_.length)
            {
                //put(sink, target.alias_, ')');
                sink.put(target.alias_);
                sink.colour(TerminalForeground.default_);
                sink.put(')');

                if (target.class_ == IRCUser.Class.special)
                {
                    sink.colour(bright ? DefaultBright.special : DefaultDark.special);
                    sink.put('*');
                }

                import std.algorithm.comparison : equal;
                import std.uni : asLowerCase;

                if (!target.alias_.asLowerCase.equal(target.nickname))
                {
                    //sink.colour(TerminalForeground.default_);
                    sink.put(" <");
                    colourUserTruecolour(sink, event.target);
                    sink.put(target.nickname);
                    sink.colour(TerminalForeground.default_);
                    sink.put('>');
                }
            }
            else
            {
                sink.put(target.nickname);
                sink.colour(TerminalForeground.default_);
                sink.put(')');

                if (target.class_ == IRCUser.Class.special)
                {
                    sink.colour(bright ? DefaultBright.special : DefaultDark.special);
                    sink.put('*');
                }
            }

            version(TwitchSupport)
            {
                if (target.badges.length)
                {
                    sink.colour(bright ? DefaultBright.badge : DefaultDark.badge);

                    put(sink, " [");
                    sink.abbreviateBadges(target.badges);
                    put(sink, ']');
                }
            }
        }

        if (content.length)
        {
            immutable TerminalForeground contentFgBase = bright ?
                DefaultBright.content : DefaultDark.content;
            immutable TerminalForeground emoteFgBase = bright ?
                DefaultBright.emote : DefaultDark.emote;

            immutable fgBase = ((event.type == IRCEvent.Type.EMOTE) ||
                (event.type == IRCEvent.Type.SELFEMOTE) ||
                (event.type == IRCEvent.Type.TWITCH_CHEER)) ? emoteFgBase : contentFgBase;
            immutable isEmote = (fgBase == emoteFgBase);

            sink.colour(fgBase);  // Always grey colon and SASL +, prepare for emote

            if (sender.isServer || sender.nickname.length)
            {
                if (isEmote)
                {
                    put(sink, ' ');
                }
                else
                {
                    put(sink, `: "`);
                }

                content = mapEffects(content, fgBase);

                version(TwitchSupport)
                {
                    if (plugin.state.client.server.daemon == IRCServer.Daemon.twitch)
                    {
                        highlightEmotes(event);
                    }
                }

                with (IRCEvent.Type)
                switch (event.type)
                {
                case CHAN:
                case EMOTE:
                case TWITCH_CHEER:
                    import kameloso.terminal : invert;
                    import kameloso.irc.common : containsNickname;

                    if (!content.containsNickname(plugin.state.client.nickname)) goto default;

                    // Nick was mentioned (certain)
                    shouldBell = bellOnMention;
                    put(sink, content.invert(plugin.state.client.nickname));
                    break;

                default:
                    // Normal non-highlighting channel message
                    put(sink, content);
                    break;
                }

                import kameloso.terminal : TerminalBackground;

                // Reset the background to ward off bad backgrounds bleeding out
                sink.colour(fgBase, TerminalBackground.default_);
                if (!isEmote) put(sink, '"');
            }
            else
            {
                // PING or ERROR likely
                put(sink, content);  // No need for indenting space
            }
        }

        if (aux.length)
        {
            sink.colour(bright ? DefaultBright.aux : DefaultDark.aux);
            put(sink, " (", aux, ')');
        }

        if (count != 0)
        {
            sink.colour(bright ? DefaultBright.count : DefaultDark.count);
            sink.formattedWrite(" {%d}", count);
        }

        if (num > 0)
        {
            sink.colour(bright ? DefaultBright.num : DefaultDark.num);
            sink.formattedWrite(" (#%03d)", num);
        }

        if (errors.length && !plugin.printerSettings.silentErrors)
        {
            sink.colour(bright ? DefaultBright.error : DefaultDark.error);
            put(sink, " !", errors, '!');
        }

        sink.colour(TerminalForeground.default_);  // same for bright and dark

        if (shouldBell || (errors.length && plugin.printerSettings.bellOnError) ||
            ((type == IRCEvent.Type.QUERY) && (target.nickname == plugin.state.client.nickname)))
        {
            import kameloso.terminal : TerminalToken;
            sink.put(TerminalToken.bell);
        }
    }

    static if (!__traits(hasMember, Sink, "data"))
    {
        sink.put('\n');
    }
}


// withoutTypePrefix
/++
 +  Slices away any type prefixes from the string of a
 +  `kameloso.irc.defs.IRCEvent.Type`.
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
 +      typestring = The string form of a `kameloso.irc.defs.IRCEvent.Type`.
 +
 +  Returns:
 +      A slice of the passed `typestring`, excluding any prefixes if present.
 +/
string withoutTypePrefix(const string typestring) @safe pure nothrow @nogc @property
{
    import kameloso.string : beginsWith;

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
 +      The following constructs may allocate memory using the garbage
 +      collector:
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
 +          "bits-leader"   : 'L',
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
 +  with "_1", which seem to be contextual to a channel's game theme, like
 +  overwatch_league_insider_1, firewatch_1, cuphead_1, H1Z1_1, eso_1, ...
 +
 +  Params:
 +      sink = Output range to store the abbreviated values in.
 +      badgestring = Badges from a Twitch `badges=` IRCv3 tag.
 +/
version(TwitchSupport)
void abbreviateBadges(Sink)(auto ref Sink sink, const string badgestring)
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
        import kameloso.string : nom;

        string slice = badgeAndNum;
        immutable badge = slice.nom('/');

        char badgechar;

        switch (badge)
        {
        case "subscriber":
            badgechar = 'S';
            break;

        case "bits":
            // rewrite to the cheer it is represented as in the normal chat
            badgechar = 'C';
            break;

        case "sub-gifter":
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

        case "bits-leader":
            badgechar = 'L';
            break;

        case "staff":
            badgechar = '*';
            break;

        case "admin":
            badgechar = '+';
            break;

        default:
            import std.algorithm.searching : endsWith;

            if (badge.endsWith("_1"))
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

    logger.info(datestamp);

    if (plugin.printerSettings.logs)
    {
        plugin.commitLogs();
        plugin.buffers.clear();
    }

    // Schedule the next run for the following midnight.
    plugin.state.nextPeriodical = getNextMidnight(Clock.currTime).toUnixTime;
}


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
 +      now = UNIX timestamp of the base date from which to proceed to the next
 +          midnight.
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
string escapedPath(const string path)
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
 +  `kameloso.irc.defs.IRCEvent`'s `content` member.
 +
 +  Wraps `higlightEmotesImpl`.
 +
 +  Params:
 +      event = `kameloso.irc.defs.IRCEvent` whose content text to highlight.
 +/
version(Colours)
void highlightEmotes(ref IRCEvent event)
{
    import kameloso.terminal : colour;
    import kameloso.common : settings;
    import kameloso.constants : DefaultColours;
    import kameloso.string : contains;
    import std.array : Appender;

    alias DefaultBright = DefaultColours.EventPrintingBright;
    alias DefaultDark = DefaultColours.EventPrintingDark;

    if (!event.emotes.length) return;

    Appender!string sink;
    sink.reserve(event.content.length + 60);  // mostly +10

    immutable TerminalForeground highlight = settings.brightTerminal ?
        DefaultBright.highlight : DefaultDark.highlight;
    immutable TerminalForeground contentFgBase = settings.brightTerminal ?
        DefaultBright.content : DefaultDark.content;
    immutable TerminalForeground emoteFgBase = settings.brightTerminal ?
        DefaultBright.emote : DefaultDark.emote;

    with (IRCEvent.Type)
    switch (event.type)
    {
    case EMOTE:
    case SELFEMOTE:
    case TWITCH_CHEER:
        if (event.tags.contains("emote-only=1"))
        {
            // Just highlight the whole line, don't worry about resetting to fgBase
            sink.colour(highlight);
            sink.put(event.content);
        }
        else
        {
            // Emote but mixed text and emotes
            event.content.highlightEmotesImpl(sink, event.emotes, highlight, emoteFgBase);
        }
        break;

    case CHAN:
    case SELFCHAN:
        // Normal content, normal text, normal emotes
        //sink.colour(contentFgBase);
        event.content.highlightEmotesImpl(sink, event.emotes, highlight, contentFgBase);
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
 +/
version(Colours)
void highlightEmotesImpl(Sink)(const string line, auto ref Sink sink,
    const string emotes, const TerminalForeground pre, const TerminalForeground post)
{
    import std.algorithm.iteration : splitter;
    import std.conv : to;

    struct Highlight
    {
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
        import kameloso.string : nom;
        emote.nom(':');

        foreach (location; emote.splitter(","))
        {
            import std.string : indexOf;

            if (numHighlights == maxHighlights) break;  // too many, don't go out of bounds.

            immutable dashPos = location.indexOf('-');
            immutable start = location[0..dashPos].to!size_t;
            immutable end = location[dashPos+1..$].to!size_t + 1;  // inclusive

            highlights[numHighlights++] = Highlight(start, end);
        }
    }

    import std.algorithm.sorting : sort;
    highlights[0..numHighlights].sort!((a,b) => a.start < b.start)();

    // We need a dstring since we're slicing something that isn't neccessarily ASCII
    // Without this highlights become offset a few characters depnding on the text
    immutable dline = line.to!dstring;

    foreach (immutable i; 0..numHighlights)
    {
        import kameloso.terminal : colour;

        immutable start = highlights[i].start;
        immutable end = highlights[i].end;

        sink.put(dline[pos..start]);
        sink.colour(pre);
        sink.put(dline[start..end]);
        sink.colour(post);

        pos = end;
    }

    // Add the remaining tail from after the last emote
    sink.put(dline[pos..$]);
}

///
version(Colours)
unittest
{
    import std.array : Appender;

    Appender!(char[]) sink;

    {
        immutable emotes = "212612:14-22/75828:24-29";
        immutable line = "Moody the god pownyFine pownyL";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white, TerminalForeground.default_);
        assert((sink.data == "Moody the god \033[97mpownyFine\033[39m \033[97mpownyL\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "25:41-45";
        immutable line = "whoever plays nintendo switch whisper me Kappa";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white, TerminalForeground.default_);
        assert((sink.data == "whoever plays nintendo switch whisper me \033[97mKappa\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "877671:8-17,19-28,30-39";
        immutable line = "NOOOOOO camillsCry camillsCry camillsCry";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white, TerminalForeground.default_);
        assert((sink.data == "NOOOOOO \033[97mcamillsCry\033[39m " ~
            "\033[97mcamillsCry\033[39m \033[97mcamillsCry\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "822112:0-6,8-14,16-22";
        immutable line = "FortOne FortOne FortOne";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white, TerminalForeground.default_);
        assert((sink.data == "\033[97mFortOne\033[39m \033[97mFortOne\033[39m " ~
            "\033[97mFortOne\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "141844:17-24,26-33,35-42/141073:9-15";
        immutable line = "@mugs123 cohhWow cohhBoop cohhBoop cohhBoop";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white, TerminalForeground.default_);
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
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white, TerminalForeground.default_);
        assert((sink.data == highlitLine), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "25:32-36";
        immutable line = "@kiwiskool but you’re a sub too Kappa";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white, TerminalForeground.default_);
        assert((sink.data == "@kiwiskool but you’re a sub too \033[97mKappa\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "425618:6-8,16-18/1:20-21";
        immutable line = "高所恐怖症 LUL なにぬねの LUL :)";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white, TerminalForeground.default_);
        assert((sink.data == "高所恐怖症 \033[97mLUL\033[39m なにぬねの " ~
            "\033[97mLUL\033[39m \033[97m:)\033[39m"), sink.data);
    }
}


// initialise
/++
 +  Set the next periodical timestamp to midnight immediately after plugin
 +  construction.
 +/
void initialise(PrinterPlugin plugin)
{
    import std.datetime.systime : Clock;
    plugin.state.nextPeriodical = getNextMidnight(Clock.currTime).toUnixTime;
}


// teardown
/++
 +  Deinitialises the plugin.
 +
 +  If we're buffering writes, commit all queued lines to disk.
 +/
void teardown(PrinterPlugin plugin)
{
    if (plugin.printerSettings.bufferedWrites)
    {
        // Commit all logs before exiting
        commitLogs(plugin);
    }
}


mixin UserAwareness!(ChannelPolicy.any);
mixin ChannelAwareness!(ChannelPolicy.any);

public:


// PrinterPlugin
/++
 +  The Printer plugin takes all `kameloso.irc.defs.IRCEvent`s and prints them to
 +  the local terminal, formatted and optionally in colour.
 +
 +  This used to be part of the core program, but with UDAs it's easy to split
 +  off into its own plugin.
 +/
final class PrinterPlugin : IRCPlugin
{
    /// Whether we have nagged about an invalid log directory.
    bool naggedAboutDir;

    /// Whether we have printed daemon-network information.
    bool printedISUPPORT;

    /// Buffers, to clump log file writes together.
    LogLineBuffer[string] buffers;

    /// All Printer plugin options gathered.
    @Settings PrinterSettings printerSettings;

    /// Where to save logs.
    @Resource string logDirectory = "logs";

    mixin IRCPluginImpl;
}
