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

import kameloso.plugins.common;
import kameloso.ircdefs;
import kameloso.common;

import std.datetime.systime : SysTime;
import std.typecons : No, Yes;

private:


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

    /// Whether to print the badge field in caps (as they used to be earlier).
    bool badgesInCaps = false;

    /++
     +  Whether or not to send a terminal bell signal when the bot is mentioned
     +  in chat.
     +/
    bool bellOnMention = true;

    /// Whether to have the type names be in capital letters.
    bool typesInCaps = true;

    /// Whether to log events.
    bool saveLogs = false;

    /// Whether to log raw events.
    bool saveRaw = false;

    /// Whether to buffer writes.
    bool bufferedWrites = true;

    /// Whether to log non-home channels.
    bool logAllChannels = false;

    /// Where to save logs (absolute or relative path).
    string logLocation = "kameloso.logs";
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
        // These event types are spammy; ignore if we're configured to
        if (!printerSettings.filterVerbose) goto default;
        break;

    case PING:
    case PONG:
        break;

    default:
        import std.stdio : stdout;

        plugin.formatMessage(stdout.lockingTextWriter, mutEvent, state.settings.monochrome,
            printerSettings.bellOnMention);
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

    /++
     +  How many PINGs a buffer must be empty during to be considered dead and
     +  ripe for garbage collection.
     +/
    uint lives = 20;  // Arbitrary number

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
    if (!plugin.printerSettings.enabled) return;

    import std.algorithm.searching : canFind;
    import std.file : FileException;
    import std.path : buildNormalizedPath, expandTilde;
    import std.stdio : File, writeln;

    if (!plugin.printerSettings.saveLogs) return;

    if (!plugin.printerSettings.logAllChannels &&
        event.channel.length && plugin.state.bot.homes.canFind(event.channel))
    {
        // Not logging all channels and this is not a home.
        return;
    }

    immutable logLocation = plugin.printerSettings.logLocation.expandTilde;
    if (!plugin.verifyLogLocation(logLocation)) return;

    with (plugin)
    {
        if (printerSettings.saveRaw)
        {
            try
            {
                immutable path = buildNormalizedPath(logLocation,
                    state.bot.server.address ~ ".raw.log");

                if (path !in buffers) buffers[path] = LogLineBuffer(path);

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
                logger.warning(e.msg);
            }
            catch (const Exception e)
            {
                logger.warning(e.msg);
            }
        }
    }

    // Some events are tricky to attribute to a channel. Ignore them for now as
    // it would require channel and user awareness to properly differentiate.
    with (IRCEvent.Type)
    switch (event.type)
    {
    case QUIT:
    case NICK:
    case ACCOUNT:
    case SASL_AUTHENTICATE:
        return;

    default:
        break;
    }

    string path;

    with (plugin)
    with (event)
    {
        if (channel.length && sender.nickname.length)
        {
            // Channel message
            path = buildNormalizedPath(logLocation, channel ~ ".log");
        }
        else if (sender.nickname.length)
        {
            // Implicitly not a channel; query
            path = buildNormalizedPath(logLocation, sender.nickname ~ ".log");
        }
        else if (!sender.nickname.length && sender.address.length)
        {
            // Server
            path = buildNormalizedPath(logLocation, state.bot.server.address ~ ".log");
        }
        else
        {
            // Don't know what to do; bail
            import kameloso.common : printObject;
            logger.warning("Unsure how to log that event");
            printObject(event);
            return;
        }
    }

    try
    {
        // First bool monochrome true, second bell on mention false

        if (plugin.printerSettings.bufferedWrites)
        {
            if (path !in plugin.buffers) plugin.buffers[path] = LogLineBuffer(path);

            import std.array : Appender;

            Appender!string sink;
            sink.reserve(512);
            plugin.formatMessage(sink, event, true, false);
            plugin.buffers[path].lines ~= sink.data;
        }
        else
        {
            plugin.formatMessage(File(path, "a").lockingTextWriter, event, true, false);
        }
    }
    catch (const FileException e)
    {
        logger.warning("File exception caught when writing to log: ", e.msg);
    }
    catch (const Exception e)
    {
        logger.warning("Unhandled exception caught when writing to log: ", e.msg);
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
    import std.file : FileException, exists, isDir;

    if (logLocation.exists)
    {
        if (logLocation.isDir) return true;

        if (!plugin.naggedAboutDir)
        {
            version(Colours)
            {
                if (!plugin.state.settings.monochrome)
                {
                    import kameloso.bash : colour;
                    import kameloso.logger : KamelosoLogger;
                    import std.experimental.logger : LogLevel;

                    immutable infotint = plugin.state.settings.brightTerminal ?
                        KamelosoLogger.logcoloursBright[LogLevel.info] :
                        KamelosoLogger.logcoloursDark[LogLevel.info];

                    immutable warningtint = plugin.state.settings.brightTerminal ?
                        KamelosoLogger.logcoloursBright[LogLevel.warning] :
                        KamelosoLogger.logcoloursDark[LogLevel.warning];

                    logger.warningf("Specified log directory (%s%s%s) is not a directory.",
                        infotint.colour, logLocation, warningtint.colour);
                }
                else
                {
                    logger.warningf("Specified log directory (%s) is not a directory", logLocation);
                }
            }
            else
            {
                logger.warningf("Specified log directory (%s) is not a directory", logLocation);
            }

            plugin.naggedAboutDir = true;
        }

        return false;
    }
    else
    {
        // Create missing log directory
        import std.file : mkdirRecurse;
        mkdirRecurse(logLocation);

        version(Colours)
        {
            if (!plugin.state.settings.monochrome)
            {
                import kameloso.bash : BashForeground;

                with (plugin.state.settings)
                with (BashForeground)
                {
                    import kameloso.bash : colour;
                    import kameloso.logger : KamelosoLogger;
                    import std.experimental.logger : LogLevel;

                    immutable infotint = brightTerminal ?
                        KamelosoLogger.logcoloursBright[LogLevel.info] :
                        KamelosoLogger.logcoloursDark[LogLevel.info];

                    immutable logtint = brightTerminal ?
                        KamelosoLogger.logcoloursBright[LogLevel.all] :
                        KamelosoLogger.logcoloursDark[LogLevel.all];

                    logger.logf("Created log directory: %s%s", infotint.colour, logLocation);
                }
            }
            else
            {
                logger.log("Created log directory: ", logLocation);
            }
        }
        else
        {
            logger.log("Created log directory: ", logLocation);
        }
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
    if (!plugin.printerSettings.enabled) return;

    import std.file : FileException;

    string[] garbage;

    foreach (ref buffer; plugin.buffers)
    {
        if (!buffer.lines.data.length)
        {
            if (--buffer.lives == 0)
            {
                garbage ~= buffer.path;
            }
            continue;
        }

        buffer.lives = typeof(buffer).init.lives;

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

    foreach (deadBuffer; garbage)
    {
        plugin.buffers.remove(deadBuffer);
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
    import kameloso.string : enumToString;
    import std.string : capitalize;
    import std.uni : isLower;

    if (plugin.printedISUPPORT || !plugin.state.bot.server.network.length)
    {
        // We already printed this information, or we havent yet seen NETWORK
        return;
    }

    plugin.printedISUPPORT = true;

    with (plugin.state.bot.server)
    {
        immutable networkName = network[0].isLower ? network.capitalize() : network;

        version(Colours)
        {
            if (!settings.monochrome)
            {
                import kameloso.bash : BashReset, colour;
                import kameloso.logger : KamelosoLogger;
                import std.experimental.logger : LogLevel;

                immutable infotint = settings.brightTerminal ?
                    KamelosoLogger.logcoloursBright[LogLevel.info] :
                    KamelosoLogger.logcoloursDark[LogLevel.info];

                immutable logtint = settings.brightTerminal ?
                    KamelosoLogger.logcoloursBright[LogLevel.all] :
                    KamelosoLogger.logcoloursDark[LogLevel.all];

                logger.logf("Detected %s%s%s running daemon %s%s%s (%s)",
                    infotint.colour, networkName, logtint.colour,
                    infotint.colour, daemon.enumToString,
                    BashReset.all.colour, daemonstring);
            }
            else
            {
                logger.logf("Detected %s running %s (%s)",
                    networkName, daemon.enumToString, daemonstring);
            }
        }
        else
        {
            logger.logf("Detected %s running %s (%s)",
                networkName, daemon.enumToString, daemonstring);
        }
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


// formatMessage
/++
 +  Formats an `kameloso.ircdefs.IRCEvent` into an output range sink.
 +
 +  It formats the timestamp, the type of the event, the sender or sender alias,
 +  the channel or target, the content body, as well as auxiliary information.
 +
 +  By default output is in colours, unless on Windows. The behaviour is stored
 +  and read from the `PrinterPlugin.printerSettings` struct.
 +
 +  Params:
 +      plugin = Current `PrinterPlugin`.
 +      sink = Output range to format the `kameloso.ircdefs.IRCEvent` into.
 +      event = Reference to the `kameloso.ircdefs.IRCEvent` that is being
 +          formatted.
 +      monochrome = Whether to print text monochrome or coloured.
 +/
void formatMessage(Sink)(PrinterPlugin plugin, auto ref Sink sink, IRCEvent event,
    bool monochrome, bool bellOnMention)
{
    import kameloso.bash : BashForeground;
    import kameloso.string : enumToString, beginsWith;
    import std.algorithm : equal;
    import std.datetime : DateTime;
    import std.datetime.systime : SysTime;
    import std.string : toLower;
    import std.uni : asLowerCase;

    immutable timestamp = (cast(DateTime)SysTime
        .fromUnixTime(event.time))
        .timeOfDay
        .toString();

    string typestring = plugin.printerSettings.typesInCaps ?
        enumToString(event.type) : enumToString(event.type).toLower;

    with (BashForeground)
    with (plugin.state)
    with (event)
    with (event.sender)
    if (monochrome)
    {
        event.stripEffects();

        put(sink, '[', timestamp, "] ");

        if (typestring.beginsWith("RPL_") || typestring.beginsWith("rpl_") ||
            typestring.beginsWith("ERR_") || typestring.beginsWith("err_"))
        {
            typestring = typestring[4..$];
        }

        put(sink, '[', typestring, "] ");

        if (sender.isServer)
        {
            sink.put(address);
        }
        else
        {
            if (alias_.length)
            {
                sink.put(alias_);

                if (special && nickname.length) sink.put('*');

                if (!alias_.asLowerCase.equal(nickname))
                {
                    put(sink, " <", nickname, '>');
                }
            }
            else
            {
                sink.put(nickname);

                if (special && nickname.length) sink.put('*');
            }

            if (badge.length)
            {
                import std.string : toUpper;

                immutable badgestring = plugin.printerSettings.badgesInCaps ?
                    badge.toUpper : badge;

                put(sink, " [", badgestring, ']');
            }
        }

        if (target.nickname.length)
        {
            sink.put(" (");

            if (target.alias_.length)
            {
                put(sink, target.alias_, ')');

                if (special) sink.put('*');

                if (!target.alias_.asLowerCase.equal(target.nickname))
                {
                    put(sink, " <", target.nickname, '>');
                }
            }
            else
            {
                put(sink, target.nickname, ')');

                if (special) sink.put('*');
            }

            if ((type == IRCEvent.Type.QUERY) && (target.nickname == bot.nickname))
            {
                // Message sent to bot
                if (plugin.printerSettings.bellOnMention)
                {
                    import kameloso.bash : TerminalToken;
                    sink.put(TerminalToken.bell);
                }
            }
        }

        if (channel.length) put(sink, " [", channel, ']');

        if (content.length)
        {
            if (sender.isServer || nickname.length)
            {
                if (type == IRCEvent.Type.CHAN)
                {
                    import kameloso.string : has;

                    if (content.has!(Yes.decode)(bot.nickname))
                    {
                        // Nick was mentioned (VERY naïve guess)
                        if (plugin.printerSettings.bellOnMention)
                        {
                            import kameloso.bash : TerminalToken;
                            sink.put(TerminalToken.bell);
                        }
                    }
                    else
                    {
                        // Normal non-highlighting channel message
                        put(sink, `: "`, content, '"');
                    }
                }

                put(sink, `: "`, content, '"');
            }
            else
            {
                // PING or ERROR likely
                put(sink, content);
            }
        }

        if (aux.length) put(sink, " <", aux, '>');

        if (num > 0)
        {
            import std.format : formattedWrite;
            sink.formattedWrite(" (#%03d)", num);
        }

        static if (!__traits(hasMember, Sink, "data"))
        {
            sink.put('\n');
        }
    }
    else
    {
        version(Colours)
        {
            import kameloso.bash : colour, invert;

            event.mapEffects();

            enum DefaultDark : BashForeground
            {
                timestamp = white,
                type    = lightblue,
                error   = lightred,
                sender  = lightgreen,
                special = lightyellow,
                target  = cyan,
                channel = yellow,
                content = default_,
                aux     = white,
                num     = darkgrey,
                badge   = white,
            }

            enum DefaultBright : BashForeground
            {
                timestamp = black,
                type    = blue,
                error   = red,
                sender  = green,
                special = yellow,
                target  = cyan,
                channel = yellow,
                content = default_,
                aux     = black,
                num     = lightgrey,
                badge   = black,
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

                    static immutable BashForeground[17] fg = [ EnumMembers!BashForeground ];

                    auto colourIndex = hashOf(nickname) % 16;

                    // Map black to white on dark terminals, reverse on bright
                    if (bright)
                    {
                        if (colourIndex == 16) colourIndex = 1;
                    }
                    else
                    {
                        if (colourIndex == 1) colourIndex = 16;
                    }

                    return fg[colourIndex];
                }

                return bright ? DefaultBright.sender : DefaultDark.sender;
            }

            /++
             +  Outputs a Bash truecolour token based on the #RRGGBB value
             +  stored in `event.colour`.
             +
             +  This is for Twitch servers that assign such values to users'
             +  messages. By catching it we can honour the setting by tinting
             +  users accordingly.
             +/
            void colourUserTruecolour(Sink)(auto ref Sink sink, const IRCUser user)
            {
                if (!user.isServer && user.colour.length && plugin.printerSettings.truecolour)
                {
                    import kameloso.bash : truecolour;
                    import kameloso.string : numFromHex;

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

            BashForeground typeColour;

            if (bright)
            {
                typeColour = (type == IRCEvent.Type.QUERY) ?
                    green : DefaultBright.type;
            }
            else
            {
                typeColour = (type == IRCEvent.Type.QUERY) ?
                    lightgreen : DefaultDark.type;
            }

            sink.colour(bright ? DefaultBright.timestamp : DefaultDark.timestamp);
            put(sink, '[', timestamp, "] ");

            if (typestring.beginsWith("RPL_") || typestring.beginsWith("rpl_"))
            {
                typestring = typestring[4..$];
                sink.colour(typeColour);
            }
            else if (typestring.beginsWith("ERR_") || typestring.beginsWith("err_"))
            {
                typestring = typestring[4..$];
                sink.colour(bright ? DefaultBright.error : DefaultDark.error);
            }
            else
            {
                sink.colour(typeColour);
            }

            put(sink, '[', typestring, "] ");

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

                    if (special)
                    {
                        sink.colour(bright ? DefaultBright.special : DefaultDark.special);
                        sink.put('*');
                    }

                    if (!alias_.asLowerCase.equal(nickname))
                    {
                        sink.colour(default_);
                        sink.put(" <");
                        colourUserTruecolour(sink, event.sender);
                        sink.put(nickname);
                        sink.colour(default_);
                        sink.put('>');
                    }
                }
                else
                {
                    sink.put(nickname);

                    if (special && nickname.length)  // !isServer != nickname.length
                    {
                        sink.colour(bright ? DefaultBright.special : DefaultDark.special);
                        sink.put('*');
                    }
                }

                if (badge.length)
                {
                    import std.string : toUpper;

                    sink.colour(bright ? DefaultBright.badge : DefaultDark.badge);

                    immutable badgestring = plugin.printerSettings.badgesInCaps ?
                        badge.toUpper : badge;

                    put(sink, " [", badgestring, ']');
                }
            }

            if (target.nickname.length)
            {
                // No need to check isServer; target is never server

                sink.colour(default_);
                sink.put(" (");
                colourUserTruecolour(sink, event.target);

                if (target.alias_.length)
                {
                    //put(sink, target.alias_, ')');
                    sink.put(target.alias_);
                    sink.colour(default_);
                    sink.put(')');

                    if (target.special)
                    {
                        sink.colour(bright ? DefaultBright.special : DefaultDark.special);
                        sink.put('*');
                    }

                    if (!target.alias_.asLowerCase.equal(target.nickname))
                    {
                        //sink.colour(default_);
                        sink.put(" <");
                        colourUserTruecolour(sink, event.target);
                        sink.put(target.nickname);
                        sink.colour(default_);
                        sink.put('>');
                    }
                }
                else
                {
                    sink.put(target.nickname);
                    sink.colour(default_);
                    sink.put(')');

                    if (target.special)
                    {
                        sink.colour(bright ? DefaultBright.special : DefaultDark.special);
                        sink.put('*');
                    }
                }

                if ((type == IRCEvent.Type.QUERY) && (target.nickname == bot.nickname))
                {
                    // Message sent to bot
                    if (plugin.printerSettings.bellOnMention)
                    {
                        import kameloso.bash : TerminalToken;
                        sink.put(TerminalToken.bell);
                    }
                }

                if (target.badge.length)
                {
                    import std.string : toUpper;

                    sink.colour(bright ? DefaultBright.badge : DefaultDark.badge);

                    immutable badgestring = plugin.printerSettings.badgesInCaps ?
                        target.badge.toUpper : target.badge;

                    put(sink, " [", badgestring, ']');
                }
            }

            if (channel.length)
            {
                sink.colour(bright ? DefaultBright.channel : DefaultDark.channel);
                put(sink, " [", channel, ']');
            }

            if (content.length)
            {
                sink.colour(bright ? DefaultBright.content : DefaultDark.content);

                if (sender.isServer || nickname.length)
                {
                    if (type == IRCEvent.Type.CHAN)
                    {
                        import kameloso.string : has;

                        if (event.content.has!(Yes.decode)(bot.nickname))
                        {
                            // Nick was mentioned (naïve guess)
                            immutable inverted = content.invert(bot.nickname);

                            if ((content != inverted) && plugin.printerSettings.bellOnMention)
                            {
                                // Nick was indeed mentioned, or so the regex says
                                import kameloso.bash : TerminalToken;
                                sink.put(TerminalToken.bell);
                            }

                            put(sink, `: "`, inverted, '"');
                        }
                        else
                        {
                            // Normal non-highlighting channel message
                            put(sink, `: "`, content, '"');
                        }
                    }
                    else
                    {
                        put(sink, `: "`, content, '"');
                    }
                }
                else
                {
                    // PING or ERROR likely
                    put(sink, content);
                }
            }

            if (aux.length)
            {
                sink.colour(bright ? DefaultBright.aux : DefaultDark.aux);
                put(sink, " <", aux, '>');
            }

            if (num > 0)
            {
                import std.format : formattedWrite;

                sink.colour(bright ? DefaultBright.num : DefaultDark.num);
                sink.formattedWrite(" (#%03d)", num);
            }

            sink.colour(default_);  // same for bright and dark

            static if (!__traits(hasMember, Sink, "data"))
            {
                sink.put('\n');
            }
        }
        else
        {
            settings.monochrome = true;
            return plugin.formatMessage(sink, event, settings.monochrome,
                plugin.printerSettings.bellOnMention);
        }
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
void mapEffects(ref IRCEvent event)
{
    import kameloso.bash : B = BashEffect;
    import kameloso.irc : I = IRCControlCharacter;
    import kameloso.string : has;

    with (event)
    {
        if (content.has(I.colour))
        {
            // Colour is mIRC 3
            content = mapColours(content);
        }

        if (content.has(I.bold))
        {
            // Bold is bash 1, mIRC 2
            content = mapAlternatingEffectImpl!(I.bold, B.bold)(content);
        }

        if (content.has(I.italics))
        {
            // Italics is bash 3 (not really), mIRC 29
            content = mapAlternatingEffectImpl!(I.italics, B.italics)(content);
        }

        if (content.has(I.underlined))
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
 +      event = Reference to the `kameloso.ircdefs.IRCEvent` to modify.
 +/
void stripEffects(ref IRCEvent event)
{
    import kameloso.irc : I = IRCControlCharacter;
    import kameloso.string : has;
    import std.regex : regex, replaceAll;

    with (event)
    {
        if (content.has(cast(ubyte)I.colour))
        {
            content = stripColours(content);
        }

        if (content.has(cast(ubyte)I.bold))
        {
            auto rBold = (""~I.bold).regex;
            content = content.replaceAll(rBold, string.init);
        }

        if (content.has(cast(ubyte)I.italics))
        {
            auto rItalics = (""~I.italics).regex;
            content = content.replaceAll(rItalics, string.init);
        }

        if (content.has(cast(ubyte)I.underlined))
        {
            auto rUnderlined = (""~I.underlined).regex;
            content = content.replaceAll(rUnderlined, string.init);
        }
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
string mapColours(const string line)
{
    import kameloso.bash : BashBackground, BashForeground, BashReset, TerminalToken, colour;
    import kameloso.irc : I = IRCControlCharacter;
    import std.regex : matchAll, regex, replaceAll;

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
            logger.warning("mIRC foreground colour code out of bounds: ", fgIndex);
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
                logger.warning("mIRC background colour code out of bounds: ", bgIndex);
                continue;
            }

            sink.put(';');
            sink.put((cast(ubyte)weechatBackgroundMap[bgIndex]).to!string);
        }

        sink.put('m');
        slice = slice.replaceAll(hit[0].regex, sink.data);
        colouredSomething = true;
    }

    if (colouredSomething)
    {
        enum endPattern = I.colour ~ ""; // ~ "([0-9])?";
        auto endEngine = endPattern.regex;

        slice = slice.replaceAll(endEngine, TerminalToken.bashFormat ~ "[0m"); //$1");
        slice ~= BashReset.all.colour;
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
        immutable mapped = mapColours(line);
        assert((mapped == "This is \033[91mall red!\033[0m while this is not.\033[0m"), mapped);
    }

    {
        immutable line = "This time there's" ~ I.colour ~ "6 no ending token, only magenta.";
        immutable mapped = mapColours(line);
        assert((mapped == "This time there's\033[35m no ending token, only magenta.\033[0m"), mapped);
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

        slice = slice.replaceAll(hit[0].regex, string.init);
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
    import std.array : Appender;
    import std.conv  : to;
    import std.regex : matchAll, regex, replaceAll;

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
    auto singleTokenEngine = (cast(char)mircToken~"").regex;
    sink.put(hits.post.replaceAll(singleTokenEngine, bashToken));

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


// periodically
/++
 +  Prints the date in `YYYY-MM-DD` format to the screen and to any active log
 +  files upon day change.
 +/
void periodically(PrinterPlugin plugin)
{
    import std.format : format;
    import std.stdio : File, writeln;
    import std.datetime.systime : Clock;

    immutable now = Clock.currTime;
    immutable line = "-- [%d-%02d-%02d]".format(now.year, cast(int)now.month, now.day);
    logger.info(line);

    foreach (immutable path, ref buffer; plugin.buffers)
    {
        if (plugin.printerSettings.bufferedWrites)
        {
            buffer.lines.put(line);
        }
        else
        {
            auto file = File(path, "a");
            file.writeln(line);
        }
    }

    // Schedule the next run for the following midnight.
    plugin.state.nextPeriodical = getNextMidnight(now).toUnixTime;
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
    import core.time : msecs;
    import std.datetime : DateTime;
    import std.datetime.systime : Clock, SysTime;
    import std.datetime.timezone : LocalTime;

    return SysTime(DateTime(now.year, now.month, now.day, 0, 0, 0), now.timezone)
        .roll!"days"(1);
}

///
unittest
{
    import std.datetime : DateTime;
    import std.datetime.systime : SysTime;
    import std.datetime.timezone : LocalTime, UTC;

    immutable christmasEve = SysTime(DateTime(2018, 12, 24, 12, 34, 56), UTC());
    immutable nextDay = getNextMidnight(christmasEve);
    immutable christmasDay = SysTime(DateTime(2018, 12, 25, 0, 0, 0), UTC());
    assert(nextDay.toUnixTime == christmasDay.toUnixTime);  // 1545696000L
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


public:


// Printer
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

    mixin IRCPluginImpl;
}
