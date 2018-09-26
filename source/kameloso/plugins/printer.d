/++
 +  The Printer plugin takes incoming `kameloso.ircdefs.IRCEvent`s, formats them
 +  into being easily readable and prints them to the screen, optionally with
 +  colours.
 +
 +  It has no commands; all `kameloso.ircdefs.IRCEvent`s will be parsed and
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
import kameloso.ircdefs;
import kameloso.common;

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

    /// Whether to display advanced colours in RRGGBB rather than simple Bash.
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
    bool uppercaseTypes = true;

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

    with (plugin)
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
    case CAP:
    case ERR_CHANOPRIVSNEEDED:
    case USERSTATE:
    case ROOMSTATE:
        // These event types are spammy; ignore if we're configured to
        if (!printerSettings.filterVerbose) goto default;
        break;

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
                    printerSettings.bellOnMention);
                printed = true;
            }
        }

        if (!printed)
        {
            plugin.formatMessageMonochrome(stdout.lockingTextWriter, mutEvent,
                printerSettings.bellOnMention);
        }

        version(Cygwin_) stdout.flush();
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
    if (!plugin.verifyLogLocation(logLocation)) return;

    // Save raws first
    with (plugin)
    {
        if (printerSettings.logRaw)
        {
            try
            {
                immutable path = buildNormalizedPath(logLocation,
                    state.bot.server.address ~ ".raw.log");

                if (path !in buffers)
                {
                    import std.file : exists;

                    buffers[path] = LogLineBuffer(path);

                    if (path.exists)
                    {
                        buffers[path].lines.put("\n");  // two lines
                    }

                    buffers[path].lines.put(datestamp);
                }

                if (printerSettings.bufferedWrites)
                {
                    buffers[path].lines.put(event.raw);
                }
                else
                {
                    auto file = File(path, "a");
                    file.writeln(event.raw);
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
    }

    import std.algorithm.searching : canFind;

    if (!plugin.printerSettings.logAllChannels &&
        event.channel.length && !plugin.state.bot.homes.canFind(event.channel))
    {
        // Not logging all channels and this is not a home.
        return;
    }

    /// Write buffered lines.
    void writeToPath(const string path)
    {
        try
        {
            if (plugin.printerSettings.bufferedWrites)
            {
                if (path !in plugin.buffers)
                {
                    import std.file : exists;
                    plugin.buffers[path] = LogLineBuffer(path);

                    if (path.exists)
                    {
                        plugin.buffers[path].lines.put("\n");  // two lines
                    }

                    plugin.buffers[path].lines.put(datestamp);
                }

                import std.array : Appender;
                Appender!string sink;
                sink.reserve(512);
                plugin.formatMessageMonochrome(sink, event, false);  // false bell on mention
                plugin.buffers[path].lines ~= sink.data;
            }
            else
            {
                plugin.formatMessageMonochrome(File(path, "a").lockingTextWriter, event, false);
            }

            if (event.errors.length && plugin.printerSettings.logErrors)
            {
                import kameloso.printing : formatObjects;

                immutable errPath = buildNormalizedPath(logLocation, plugin.state.bot.server.address ~ ".err.log");

                if (errPath !in plugin.buffers) plugin.buffers[errPath] = LogLineBuffer(errPath);

                if (plugin.printerSettings.bufferedWrites)
                {
                    plugin.buffers[errPath].lines ~= formatObjects!(Yes.printAll, No.coloured)(event);

                    if (event.sender != IRCUser.init)
                    {
                        plugin.buffers[errPath].lines ~= formatObjects!(Yes.printAll, No.coloured)(event.sender);
                    }

                    if (event.target != IRCUser.init)
                    {
                        plugin.buffers[errPath].lines ~= formatObjects!(Yes.printAll, No.coloured)(event.target);
                    }
                }
                else
                {
                    File(errPath, "a").lockingTextWriter.formatObjects!(Yes.printAll, No.coloured)(event);

                    if (event.sender != IRCUser.init)
                    {
                        File(errPath, "a").lockingTextWriter.formatObjects!(Yes.printAll, No.coloured)(event.sender);
                    }

                    if (event.target != IRCUser.init)
                    {
                        File(errPath, "a").lockingTextWriter.formatObjects!(Yes.printAll, No.coloured)(event.target);
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
            if (!printerSettings.logAllChannels && !state.bot.homes.canFind(channelName))
            {
                // Not logging all channels and this is not a home.
                continue;
            }

            if (thisChannel.users.canFind(sender.nickname))
            {
                // Channel message
                writeToPath(buildNormalizedPath(logLocation, channelName ~ ".log"));
            }
        }

        immutable queryPath = buildNormalizedPath(logLocation, sender.nickname ~ ".log");

        if (queryPath in plugin.buffers)
        {
            // There is an open query buffer; write to it too
            writeToPath(queryPath);
        }
        break;

    default:
        if (channel.length && (sender.nickname.length || type == MODE))
        {
            // Channel message, or specialcased server-sent MODEs
            writeToPath(buildNormalizedPath(logLocation, channel ~ ".log"));
        }
        else if (sender.nickname.length)
        {
            // Implicitly not a channel; query
            writeToPath(buildNormalizedPath(logLocation, sender.nickname ~ ".log"));
        }
        else if (!sender.nickname.length && sender.address.length)
        {
            // Server
            writeToPath(buildNormalizedPath(logLocation, state.bot.server.address ~ ".log"));
        }
        else
        {
            // Don't know where to log this event; bail
            return;
        }
        break;
    }
}


// verifyLogLocation
/++
 +  Verifies that a log directory exists, complaining if it's invalid, creating
 +  it if it doesn't exist.
 +
 +  Params:
 +      logLocation = String of the location directory we want to store logs in.
 +
 +  Returns:
 +      A bool whether or not the log location is valid.
 +/
bool verifyLogLocation(PrinterPlugin plugin, const string logLocation)
{
    import std.file : exists, isDir;

    if (logLocation.exists)
    {
        if (logLocation.isDir) return true;

        if (!plugin.naggedAboutDir)
        {
            string infotint, warningtint;

            version(Colours)
            {
                if (!plugin.state.settings.monochrome)
                {
                    import kameloso.bash : colour;
                    import kameloso.logger : KamelosoLogger;
                    import std.experimental.logger : LogLevel;

                    infotint = KamelosoLogger.tint(LogLevel.info, settings.brightTerminal).colour;
                    warningtint = KamelosoLogger.tint(LogLevel.warning, settings.brightTerminal).colour;
                }
            }

            logger.warningf("Specified log directory (%s%s%s) is not a directory.",
                infotint, logLocation, warningtint);

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
            if (!plugin.state.settings.monochrome)
            {
                import kameloso.bash : colour;
                import kameloso.logger : KamelosoLogger;
                import std.experimental.logger : LogLevel;

                infotint = KamelosoLogger.tint(LogLevel.info, settings.brightTerminal).colour;
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
 +/
@(IRCEvent.Type.PING)
@(IRCEvent.Type.RPL_ENDOFMOTD)
@(IRCEvent.Type.ERR_NOMOTD)
void commitLogs(PrinterPlugin plugin)
{
    if (!plugin.printerSettings.enabled || !plugin.printerSettings.logs) return;

    import std.file : FileException;

    foreach (ref buffer; plugin.buffers)
    {
        if (!buffer.lines.data.length) continue;

        try
        {
            import std.stdio : File, writeln;

            auto file = File(buffer.path, "a");

            foreach (immutable line; buffer.lines.data)
            {
                file.writeln(line);
            }
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
    if (plugin.printedISUPPORT || !plugin.state.bot.server.network.length)
    {
        // We already printed this information, or we havent yet seen NETWORK
        return;
    }

    plugin.printedISUPPORT = true;

    with (plugin.state.bot.server)
    {
        import std.string : capitalize;
        import std.uni : isLower;

        immutable networkName = network[0].isLower ? network.capitalize() : network;
        string infotint, logtint, tintreset;

        version(Colours)
        {
            if (!settings.monochrome)
            {
                import kameloso.bash : BashReset, colour;
                import kameloso.logger : KamelosoLogger;
                import std.experimental.logger : LogLevel;

                infotint = KamelosoLogger.tint(LogLevel.info, settings.brightTerminal).colour;
                logtint = KamelosoLogger.tint(LogLevel.all, settings.brightTerminal).colour;
                tintreset = BashReset.all.colour;
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


// formatMessageMonochrome
/++
 +  Formats an `kameloso.ircdefs.IRCEvent` into an output range sink, in
 +  monochrome.
 +
 +  It formats the timestamp, the type of the event, the sender or sender alias,
 +  the channel or target, the content body, as well as auxiliary information.
 +
 +  Params:
 +      plugin = Current `PrinterPlugin`.
 +      sink = Output range to format the `kameloso.ircdefs.IRCEvent` into.
 +      event = The `kameloso.ircdefs.IRCEvent` that is to be formatted.
 +      monochrome = Whether to print text monochrome or coloured.
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

    with (plugin.state)
    with (event)
    with (event.sender)
    {
        event.content = stripEffects(event.content);

        put(sink, '[', timestamp, "] [");

        if (plugin.printerSettings.uppercaseTypes) put(sink, typestring);
        else put(sink, typestring.asLowerCase);

        put(sink, "] ");

        if (channel.length) put(sink, '[', channel, "] ");

        if (sender.isServer)
        {
            sink.put(address);
        }
        else
        {
            if (alias_.length)
            {
                sink.put(alias_);
                if (class_ == IRCUser.Class.special) sink.put('*');

                if (!alias_.asLowerCase.equal(nickname))
                {
                    put(sink, " <", nickname, '>');
                }
            }
            else if (nickname.length)
            {
                // Can be no-nick special: [PING] *2716423853
                sink.put(nickname);
                if (class_ == IRCUser.Class.special) sink.put('*');
            }

            if (badge.length)
            {
                import kameloso.string : contains, nom;
                immutable badgefront = badge.contains('/') ? badge.nom('/') : badge;
                put(sink, " [");

                if (plugin.printerSettings.uppercaseTypes) put(sink, badgefront.asUpperCase);
                else put(sink, badgefront);

                put(sink, ']');
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

            if (target.badge.length)
            {
                import kameloso.string : contains, nom;
                immutable badgefront = target.badge.contains('/') ? target.badge.nom('/') : target.badge;
                put(sink, " [");

                if (plugin.printerSettings.uppercaseTypes) put(sink, badgefront.asUpperCase);
                else put(sink, badgefront);

                put(sink, ']');
            }
        }

        if (content.length)
        {
            version(TwitchSupport)
            {
                if ((bot.server.daemon == IRCServer.Daemon.twitch) &&
                    ((event.type == IRCEvent.Type.CHAN) ||
                    (event.type == IRCEvent.Type.EMOTE) ||
                    (event.type == IRCEvent.Type.TWITCH_CHEER) ||
                    (event.type == IRCEvent.Type.SELFCHAN) ||
                    (event.type == IRCEvent.Type.SELFEMOTE)) && aux.length)
                {
                    // Here we would normally highlight emotes, but we're monochrome
                    // clear aux though; it may contain emote positions.
                    aux = string.init;
                }
            }

            if (sender.isServer || nickname.length)
            {
                import kameloso.irc : containsNickname;

                with (IRCEvent.Type)
                switch (event.type)
                {
                case CHAN:
                case EMOTE:
                    if (content.containsNickname(bot.nickname))
                    {
                        // Nick was mentioned (certain)
                        shouldBell = bellOnMention;
                    }
                    break;

                default:
                    break;
                }

                put(sink, `: "`, content, '"');
            }
            else
            {
                // PING or ERROR likely
                put(sink, content);
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
            (type == IRCEvent.Type.QUERY) && (target.nickname == bot.nickname))
        {
            import kameloso.bash : TerminalToken;
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
 +  Formats an `kameloso.ircdefs.IRCEvent` into an output range sink, coloured.
 +
 +  It formats the timestamp, the type of the event, the sender or sender alias,
 +  the channel or target, the content body, as well as auxiliary information.
 +
 +  Params:
 +      plugin = Current `PrinterPlugin`.
 +      sink = Output range to format the `kameloso.ircdefs.IRCEvent` into.
 +      event = The `kameloso.ircdefs.IRCEvent` that is to be formatted.
 +/
version(Colours)
void formatMessageColoured(Sink)(PrinterPlugin plugin, auto ref Sink sink,
    IRCEvent event, const bool bellOnMention)
{
    import kameloso.bash : BashForeground, colour;
    import kameloso.conv : Enum;
    import std.datetime : DateTime;
    import std.datetime.systime : SysTime;
    import std.format : formattedWrite;

    immutable timestamp = (cast(DateTime)SysTime
        .fromUnixTime(event.time))
        .timeOfDay
        .toString();

    immutable rawTypestring = Enum!(IRCEvent.Type).toString(event.type);
    immutable typestring = rawTypestring.withoutTypePrefix;

    bool shouldBell;

    alias BF = BashForeground;

    enum DefaultDark : BashForeground
    {
        timestamp = BF.white,
        type    = BF.lightblue,
        error   = BF.lightred,
        sender  = BF.lightgreen,
        special = BF.lightyellow,
        target  = BF.cyan,
        channel = BF.yellow,
        content = BF.default_,
        aux     = BF.white,
        count   = BF.green,
        num     = BF.darkgrey,
        badge   = BF.white,
        emote   = BF.cyan,
        highlight = BF.white,
        query   = BF.lightgreen,
    }

    enum DefaultBright : BashForeground
    {
        timestamp = BF.black,
        type    = BF.blue,
        error   = BF.red,
        sender  = BF.green,
        special = BF.yellow,
        target  = BF.cyan,
        channel = BF.yellow,
        content = BF.default_,
        aux     = BF.black,
        count   = BF.lightgreen,
        num     = BF.lightgrey,
        badge   = BF.black,
        emote   = BF.lightcyan,
        highlight = BF.black,
        query   = BF.green,
    }

    immutable bright = settings.brightTerminal;

    /++
     +  Outputs a Bash ANSI colour token based on the hash of the passed
     +  nickname.
     +
     +  It gives each user a random yet consistent colour to their name.
     +/
    BashForeground colourByHash(const string nickname)
    {
        if (plugin.printerSettings.randomNickColours)
        {
            import std.traits : EnumMembers;

            alias foregroundMembers = EnumMembers!BashForeground;
            enum lastIndex = (foregroundMembers.length - 1);
            static immutable BashForeground[foregroundMembers.length] fg = [ foregroundMembers ];

            auto colourIndex = hashOf(nickname) % lastIndex;

            // Map black to white on dark terminals, reverse on bright
            if (bright)
            {
                if (colourIndex == lastIndex) colourIndex = 1;
            }
            else
            {
                if (colourIndex == 1) colourIndex = lastIndex;
            }

            return fg[colourIndex];
        }

        return bright ? DefaultBright.sender : DefaultDark.sender;
    }

    /++
     +  Outputs a Bash truecolour token based on the #RRGGBB value stored in
     +  `user.colour`.
     +
     +  This is for Twitch servers that assign such values to users' messages.
     +  By catching it we can honour the setting by tinting users accordingly.
     +/
    void colourUserTruecolour(Sink)(auto ref Sink sink, const IRCUser user)
    {
        if (!user.isServer && user.colour.length && plugin.printerSettings.truecolour)
        {
            import kameloso.bash : truecolour;
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

    with (plugin.state)
    with (event)
    with (event.sender)
    {
        sink.colour(bright ? DefaultBright.timestamp : DefaultDark.timestamp);
        put(sink, '[', timestamp, "] ");

        import kameloso.string : beginsWith;
        if (rawTypestring.beginsWith("ERR_"))
        {
            sink.colour(bright ? DefaultBright.error : DefaultDark.error);
        }
        else
        {
            BashForeground typeColour;

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

        put(sink, '[');

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
            sink.put(address);
        }
        else
        {
            if (alias_.length)
            {
                sink.put(alias_);

                if (class_ == IRCUser.Class.special)
                {
                    sink.colour(bright ? DefaultBright.special : DefaultDark.special);
                    sink.put('*');
                }

                import std.algorithm.comparison : equal;
                import std.uni : asLowerCase;

                if (!alias_.asLowerCase.equal(nickname))
                {
                    sink.colour(BashForeground.default_);
                    sink.put(" <");
                    colourUserTruecolour(sink, event.sender);
                    sink.put(nickname);
                    sink.colour(BashForeground.default_);
                    sink.put('>');
                }
            }
            else if (nickname.length)
            {
                // Can be no-nick special: [PING] *2716423853
                sink.put(nickname);

                if (class_ == IRCUser.Class.special)
                {
                    sink.colour(bright ? DefaultBright.special : DefaultDark.special);
                    sink.put('*');
                }
            }

            if (badge.length)
            {
                import kameloso.string : contains, nom;
                import std.uni : asUpperCase;

                sink.colour(bright ? DefaultBright.badge : DefaultDark.badge);
                immutable badgefront = badge.contains('/') ? badge.nom('/') : badge;
                put(sink, " [");

                if (plugin.printerSettings.uppercaseTypes) put(sink, badgefront.asUpperCase);
                else put(sink, badgefront);

                put(sink, ']');
            }
        }

        if (target.nickname.length)
        {
            // No need to check isServer; target is never server
            sink.colour(BashForeground.default_);
            sink.put(" (");
            colourUserTruecolour(sink, event.target);

            if (target.alias_.length)
            {
                //put(sink, target.alias_, ')');
                sink.put(target.alias_);
                sink.colour(BashForeground.default_);
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
                    //sink.colour(BashForeground.default_);
                    sink.put(" <");
                    colourUserTruecolour(sink, event.target);
                    sink.put(target.nickname);
                    sink.colour(BashForeground.default_);
                    sink.put('>');
                }
            }
            else
            {
                sink.put(target.nickname);
                sink.colour(BashForeground.default_);
                sink.put(')');

                if (target.class_ == IRCUser.Class.special)
                {
                    sink.colour(bright ? DefaultBright.special : DefaultDark.special);
                    sink.put('*');
                }
            }

            if (target.badge.length)
            {
                import kameloso.string : contains, nom;
                import std.uni : asUpperCase;

                sink.colour(bright ? DefaultBright.badge : DefaultDark.badge);
                immutable badgefront = target.badge.contains('/') ? target.badge.nom('/') : target.badge;
                put(sink, " [");

                if (plugin.printerSettings.uppercaseTypes) put(sink, badgefront.asUpperCase);
                else put(sink, badgefront);

                put(sink, ']');
            }
        }

        if (content.length)
        {
            version(TwitchSupport)
            {
                if ((bot.server.daemon == IRCServer.Daemon.twitch) &&
                    ((event.type == IRCEvent.Type.CHAN) ||
                    (event.type == IRCEvent.Type.EMOTE) ||
                    (event.type == IRCEvent.Type.TWITCH_CHEER) ||
                    (event.type == IRCEvent.Type.SELFCHAN) ||
                    (event.type == IRCEvent.Type.SELFEMOTE)) && aux.length)
                {
                    import std.array : Appender;

                    Appender!string highlightSink;
                    highlightSink.reserve(content.length + 60);  // mostly +10

                    immutable BashForeground contentHighlight = bright ?
                        DefaultBright.highlight : DefaultDark.highlight;
                    immutable BashForeground contentReset = bright ?
                        DefaultBright.content : DefaultDark.content;

                    immutable BashForeground emoteHighlight = bright ?
                        DefaultBright.highlight : DefaultDark.highlight;
                    immutable BashForeground emoteReset = bright ?
                        DefaultBright.emote : DefaultDark.emote;

                    if ((event.type == IRCEvent.Type.EMOTE) || (event.type == IRCEvent.Type.TWITCH_CHEER))
                    {
                        import kameloso.string : contains;

                        if (event.tags.contains("emote-only=1"))
                        {
                            // Just highlight the whole line, make it appear as normal content
                            event.mapEffects(contentReset);
                            sink.colour(contentReset);
                            highlightSink.colour(contentHighlight);
                            highlightSink.put(content);
                            highlightSink.colour(contentReset);
                        }
                        else
                        {
                            // Emote but mixed text and emotes
                            event.mapEffects(emoteReset);
                            sink.colour(emoteReset);
                            content.highlightTwitchEmotes(highlightSink, aux, emoteHighlight, emoteReset);
                        }
                    }
                    else
                    {
                        // Normal content, normal text, normal emotes
                        sink.colour(contentReset);
                        event.mapEffects(contentReset);
                        content.highlightTwitchEmotes(highlightSink, aux, contentHighlight, contentReset);
                    }

                    content = highlightSink.data;  // mutable...
                    aux = string.init;
                }
                else
                {
                    immutable BashForeground tint = (event.type == IRCEvent.Type.EMOTE) ?
                        (bright ? DefaultBright.emote : DefaultDark.emote) :
                        (bright ? DefaultBright.content : DefaultDark.content);

                    sink.colour(tint);
                    event.mapEffects(tint);
                }
            }
            else
            {
                BashForeground tint;

                if (event.type == IRCEvent.Type.EMOTE)
                {
                    tint = bright ? DefaultBright.emote : DefaultDark.emote;
                }
                else
                {
                    tint = bright ? DefaultBright.content : DefaultDark.content;
                }

                sink.colour(tint);
                event.mapEffects(tint);
            }

            if (sender.isServer || nickname.length)
            {
                import kameloso.irc : containsNickname;

                with (IRCEvent.Type)
                switch (event.type)
                {
                case CHAN:
                case EMOTE:
                    if (content.containsNickname(bot.nickname))
                    {
                        import kameloso.bash : invert;

                        // Nick was mentioned (certain)
                        shouldBell = bellOnMention;
                        put(sink, `: "`, content.invert(bot.nickname), '"');
                        break;
                    }
                    else goto default;

                default:
                    // Normal non-highlighting channel message
                    put(sink, `: "`, content, '"');
                    break;
                }
            }
            else
            {
                // PING or ERROR likely
                put(sink, content);
            }
        }

        // Reset the background to ward off bad backgrounds bleeding out
        import kameloso.bash : BashBackground;
        sink.colour(BashBackground.default_);

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

        sink.colour(BashForeground.default_);  // same for bright and dark

        if (shouldBell || (errors.length && plugin.printerSettings.bellOnError) ||
            (type == IRCEvent.Type.QUERY) && (target.nickname == bot.nickname))
        {
            import kameloso.bash : TerminalToken;
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
 +  `kameloso.ircdefs.IRCEvent.Type`.
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
 +      typestring = The string form of a `kameloso.ircdefs.IRCEvent.Type`.
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


// mapEffects
/++
 +  Maps mIRC effect tokens (colour, bold, italics, underlined) to Bash ones.
 +
 +  Params:
 +      event = Reference to the `kameloso.ircdefs.IRCEvent` to modify.
 +/
version(Colours)
void mapEffects(ref IRCEvent event, BashForeground resetCode = BashForeground.default_)
{
    import kameloso.bash : B = BashEffect;
    import kameloso.irc : I = IRCControlCharacter;
    import kameloso.string : contains;

    with (event)
    {
        if (content.contains(I.colour))
        {
            // Colour is mIRC 3
            content = mapColours(content, resetCode);
        }

        if (content.contains(I.bold))
        {
            // Bold is bash 1, mIRC 2
            content = mapAlternatingEffectImpl!(I.bold, B.bold)(content);
        }

        if (content.contains(I.italics))
        {
            // Italics is bash 3 (not really), mIRC 29
            content = mapAlternatingEffectImpl!(I.italics, B.italics)(content);
        }

        if (content.contains(I.underlined))
        {
            // Underlined is bash 4, mIRC 31
            content = mapAlternatingEffectImpl!(I.underlined, B.underlined)(content);
        }
    }
}


// stripEffects
/++
 +  Removes all form of mIRC formatting (colours, bold, italics, underlined)
 +  from an `kameloso.ircdefs.IRCEvent`.
 +
 +  Params:
 +      content = String to strip effects from.
 +
 +  Returns:
 +      A string devoid of effects.
 +/
string stripEffects(const string content)
{
    import kameloso.irc : I = IRCControlCharacter;
    import kameloso.string : contains;
    import std.array : replace;

    enum boldCode = "" ~ I.bold;
    enum italicsCode = "" ~ I.italics;
    enum underlinedCode = "" ~ I.underlined;

    if (!content.length) return string.init;

    return content
        .stripColours
        .replace(boldCode, string.init)
        .replace(italicsCode, string.init)
        .replace(underlinedCode, string.init);
}

///
unittest
{
    import kameloso.irc : I = IRCControlCharacter;

    enum boldCode = "" ~ I.bold;
    enum italicsCode = "" ~ I.italics;

    {
        immutable withTags = "This is " ~ boldCode ~ "riddled" ~ boldCode ~ " with " ~
            italicsCode ~ "tags" ~ italicsCode;
        immutable without = stripEffects(withTags);
        assert((without == "This is riddled with tags"), without);
    }
    {
        immutable withTags = "This line has no tags.";
        immutable without = stripEffects(withTags);
        assert((without == withTags), without);
    }
    {
        string withTags;
        immutable without = stripEffects(withTags);
        assert(!without.length, without);
    }
}


// mapColours
/++
 +  Maps mIRC effect colour tokens to Bash ones.
 +
 +  Params:
 +      event = Reference to the `kameloso.ircdefs.IRCEvent` to modify.
 +/
version(Colours)
string mapColours(const string line, const uint resetCode)
{
    import kameloso.bash : BashBackground, BashForeground, BashReset, TerminalToken, colour;
    import kameloso.irc : I = IRCControlCharacter;
    import std.array : replace;
    import std.regex : matchAll, regex;

    enum colourPattern = I.colour ~ "([0-9]{1,2})(?:,([0-9]{1,2}))?";
    auto engine = colourPattern.regex;

    bool colouredSomething;

    alias F = BashForeground;
    BashForeground[16] weechatForegroundMap =
    [
         0 : F.white,
         1 : F.darkgrey,
         2 : F.blue,
         3 : F.green,
         4 : F.lightred,
         5 : F.red,
         6 : F.magenta,
         7 : F.yellow,
         8 : F.lightyellow,
         9 : F.lightgreen,
        10 : F.cyan,
        11 : F.lightcyan,
        12 : F.lightblue,
        13 : F.lightmagenta,
        14 : F.darkgrey,
        15 : F.lightgrey,
    ];

    alias B = BashBackground;
    BashBackground[16] weechatBackgroundMap =
    [
         0 : B.white,
         1 : B.black,
         2 : B.blue,
         3 : B.green,
         4 : B.red,
         5 : B.red,
         6 : B.magenta,
         7 : B.yellow,
         8 : B.yellow,
         9 : B.green,
        10 : B.cyan,
        11 : B.cyan,
        12 : B.blue,
        13 : B.magenta,
        14 : B.black,
        15 : B.lightgrey,
    ];

    string slice = line;

    foreach (hit; line.matchAll(engine))
    {
        import std.array : Appender;
        import std.conv : to;

        if (!hit[1].length) continue;

        immutable fgIndex = hit[1].to!ubyte;

        if (fgIndex > 15)
        {
            //logger.warning("mIRC foreground colour code out of bounds: ", fgIndex);
            continue;
        }

        Appender!string sink;
        sink.reserve(8);
        sink.put(TerminalToken.bashFormat ~ "[");
        sink.put((cast(ubyte)weechatForegroundMap[fgIndex]).to!string);

        if (hit[2].length)
        {
            immutable bgIndex = hit[2].to!ubyte;

            if (bgIndex > 15)
            {
                //logger.warning("mIRC background colour code out of bounds: ", bgIndex);
                continue;
            }

            sink.put(';');
            sink.put((cast(ubyte)weechatBackgroundMap[bgIndex]).to!string);
        }

        sink.put('m');
        slice = slice.replace(hit[0], sink.data);
        colouredSomething = true;
    }

    if (colouredSomething)
    {
        import std.format : format;
        enum endToken = I.colour ~ ""; // ~ "([0-9])?";
        slice = slice.replace(endToken, "%s[%dm".format(TerminalToken.bashFormat ~ "", resetCode));
    }

    return slice;
}

///
version(Colours)
unittest
{
    import kameloso.irc : I = IRCControlCharacter;

    {
        immutable line = "This is " ~ I.colour ~ "4all red!" ~ I.colour ~ " while this is not.";
        immutable mapped = mapColours(line, 0);
        assert((mapped == "This is \033[91mall red!\033[0m while this is not."), mapped);
    }
    {
        immutable line = "This time there's" ~ I.colour ~ "6 no ending token, only magenta.";
        immutable mapped = mapColours(line, 0);
        assert((mapped == "This time there's\033[35m no ending token, only magenta."), mapped);
    }
}


// stripColours
/++
 +  Removes IRC colouring from a passed string.
 +
 +  Params:
 +      line = String to strip of IRC colour tags.
 +/
string stripColours(const string line)
{
    import kameloso.irc : I = IRCControlCharacter;
    import std.array : replace;
    import std.regex : matchAll, regex, replaceAll;

    enum colourPattern = I.colour ~ "([0-9]{1,2})(?:,([0-9]{1,2}))?";
    auto engine = colourPattern.regex;

    bool strippedSomething;

    string slice = line;

    foreach (hit; line.matchAll(engine))
    {
        import std.array : Appender;
        import std.conv : to;

        if (!hit[1].length) continue;

        slice = slice.replace(hit[0], string.init);
        strippedSomething = true;
    }

    if (strippedSomething)
    {
        enum endPattern = I.colour ~ ""; // ~ "(?:[0-9])?";
        auto endEngine = endPattern.regex;

        slice = slice.replaceAll(endEngine, string.init);
    }

    return slice;
}

///
unittest
{
    import kameloso.irc : I = IRCControlCharacter;

    {
        immutable line = "This is " ~ I.colour ~ "4all red!" ~ I.colour ~ " while this is not.";
        immutable stripped = line.stripColours();
        assert((stripped == "This is all red! while this is not."), stripped);
    }
    {
        immutable line = "This time there's" ~ I.colour ~ "6 no ending token, only magenta.";
        immutable stripped = line.stripColours();
        assert((stripped == "This time there's no ending token, only magenta."), stripped);
    }
    {
        immutable line = "This time there's" ~ I.colour ~ "6 no ending " ~ I.colour ~
            "6token, only " ~ I.colour ~ "magenta.";
        immutable stripped = line.stripColours();
        assert((stripped == "This time there's no ending token, only magenta."), stripped);
    }
}


// mapAlternatingEffectImpl
/++
 +  Replaces mIRC tokens with Bash effect codes, in an alternating fashion so as
 +  to support repeated effects toggling behaviour.
 +
 +  It seems to be the case that a token for bold text will trigger bold text up
 +  until the next bold token. If we only naïvely replace all mIRC tokens for
 +  bold text then, we'll get lines that start off bold and continue as such
 +  until the very end.
 +
 +  Instead we look at it in a pairwise perspective. We use regex to replace
 +  pairs of tokens, properly alternating and toggling on and off, then once
 +  more at the end in case there was an odd token only toggling on.
 +
 +  Params:
 +      mircToken = mIRC token for a particular text effect.
 +      bashEffectCode = Bash equivalent of the mircToken effect.
 +      event = Reference to the `kameloso.ircdefs.IRCEvent` to modify.
 +/
version(Colours)
string mapAlternatingEffectImpl(ubyte mircToken, ubyte bashEffectCode)(const string line)
{
    import kameloso.bash : B = BashEffect, BashReset, TerminalToken, colour;
    import kameloso.irc : I = IRCControlCharacter;
    import std.array : Appender, replace;
    import std.conv  : to;
    import std.regex : matchAll, regex;

    enum bashToken = TerminalToken.bashFormat ~ "[" ~
        (cast(ubyte)bashEffectCode).to!string ~ "m";

    enum pattern = "(?:"~mircToken~")([^"~mircToken~"]*)(?:"~mircToken~")";
    auto engine = pattern.regex;

    Appender!string sink;
    sink.reserve(cast(size_t)(line.length * 1.1));

    auto hits = line.matchAll(engine);

    while (hits.front.length)
    {
        sink.put(hits.front.pre);
        sink.put(bashToken);
        sink.put(hits.front[1]);

        switch (bashEffectCode)
        {
        case 1:
        case 2:
            // Both 1 and 2 seem to be reset by 22?
            sink.put(TerminalToken.bashFormat ~ "[22m");
            break;

        case 3:
        ..
        case 5:
            sink.put(TerminalToken.bashFormat ~ "[2" ~
                bashEffectCode.to!string ~ "m");
            break;

        default:
            logger.warning("Unknown Bash effect code: ", bashEffectCode);
            sink.colour(BashReset.all);
            break;
        }

        hits = hits.post.matchAll(engine);
    }

    // We've gone through them pair-wise, now see if there are any singles left.
    enum singleToken = cast(char)mircToken ~ "";
    sink.put(hits.post.replace(singleToken, bashToken));

    // End tags and commit.
    sink.colour(BashReset.all);
    return sink.data;
}

///
version(Colours)
unittest
{
    import kameloso.bash : B = BashEffect, TerminalToken;
    import kameloso.irc : I = IRCControlCharacter;
    import std.conv : to;

    enum bBold = TerminalToken.bashFormat ~ "[" ~ (cast(ubyte)B.bold).to!string ~ "m";
    enum bReset = TerminalToken.bashFormat ~ "[22m";
    enum bResetAll = TerminalToken.bashFormat ~ "[0m";

    immutable line1 = "ABC"~I.bold~"DEF"~I.bold~"GHI"~I.bold~"JKL"~I.bold~"MNO";
    immutable line2 = "ABC"~bBold~"DEF"~bReset~"GHI"~bBold~"JKL"~bReset~"MNO"~bResetAll;

    IRCEvent event;
    event.content = line1;
    event.mapEffects();
    assert((event.content == line2), event.content);
}

// highlightTwitchEmotes
/++
 +  Highlights Twitch emotes in the chat by tinting them a different colour.
 +
 +  Params:
 +      line = Content line whose containing emotes should be highlit.
 +      sink = Output range to put the results into.
 +      emotes = The list of emotes and their positions as divined from the
 +          IRCv3 tags of an event.
 +      pre = Bash foreground tint to colour the emotes with.
 +      post = Bash foreground tint to reset to after colouring an emote.
 +/
version(TwitchSupport)
version(Colours)
void highlightTwitchEmotes(Sink)(const string line, auto ref Sink sink,
    const string emotes, const BashForeground pre, const BashForeground post)
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
        import kameloso.bash : colour;

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
version(TwitchSupport)
version(Colours)
unittest
{
    import std.array : Appender;

    Appender!(char[]) sink;

    {
        immutable emotes = "212612:14-22/75828:24-29";
        immutable line = "Moody the god pownyFine pownyL";
        line.highlightTwitchEmotes(sink, emotes, BashForeground.white, BashForeground.default_);
        assert((sink.data == "Moody the god \033[97mpownyFine\033[39m \033[97mpownyL\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "25:41-45";
        immutable line = "whoever plays nintendo switch whisper me Kappa";
        line.highlightTwitchEmotes(sink, emotes, BashForeground.white, BashForeground.default_);
        assert((sink.data == "whoever plays nintendo switch whisper me \033[97mKappa\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "877671:8-17,19-28,30-39";
        immutable line = "NOOOOOO camillsCry camillsCry camillsCry";
        line.highlightTwitchEmotes(sink, emotes, BashForeground.white, BashForeground.default_);
        assert((sink.data == "NOOOOOO \033[97mcamillsCry\033[39m \033[97mcamillsCry\033[39m \033[97mcamillsCry\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "822112:0-6,8-14,16-22";
        immutable line = "FortOne FortOne FortOne";
        line.highlightTwitchEmotes(sink, emotes, BashForeground.white, BashForeground.default_);
        assert((sink.data == "\033[97mFortOne\033[39m \033[97mFortOne\033[39m \033[97mFortOne\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "141844:17-24,26-33,35-42/141073:9-15";
        immutable line = "@mugs123 cohhWow cohhBoop cohhBoop cohhBoop";
        line.highlightTwitchEmotes(sink, emotes, BashForeground.white, BashForeground.default_);
        assert((sink.data == "@mugs123 \033[97mcohhWow\033[39m \033[97mcohhBoop\033[39m \033[97mcohhBoop\033[39m \033[97mcohhBoop\033[39m"), sink.data);
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
        line.highlightTwitchEmotes(sink, emotes, BashForeground.white, BashForeground.default_);
        assert((sink.data == highlitLine), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "25:32-36";
        immutable line = "@kiwiskool but you’re a sub too Kappa";
        line.highlightTwitchEmotes(sink, emotes, BashForeground.white, BashForeground.default_);
        assert((sink.data == "@kiwiskool but you’re a sub too \033[97mKappa\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "425618:6-8,16-18/1:20-21";
        immutable line = "高所恐怖症 LUL なにぬねの LUL :)";
        line.highlightTwitchEmotes(sink, emotes, BashForeground.white, BashForeground.default_);
        assert((sink.data == "高所恐怖症 \033[97mLUL\033[39m なにぬねの " ~
            "\033[97mLUL\033[39m \033[97m:)\033[39m"), sink.data);
    }
}

// datestamp
/++
 +  Returns a string with the current date.
 +
 +  Returns:
 +      A string with the current date.
 +/
string datestamp() @property
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
 +  The Printer plugin takes all `kameloso.ircdefs.IRCEvent`s and prints them to
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
