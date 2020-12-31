/++
    Implementation of Printer plugin functionality that concerns logging.
    For internal use.

    The [dialect.defs.IRCEvent]-annotated handlers must be in the same module
    as the [kameloso.plugins.admin.base.AdminPlugin], but these implementation
    functions can be offloaded here to limit module size a bit.

    See_Also:
        [kameloso.plugins.printer.base]
        [kameloso.plugins.printer.formatting]
 +/
module kameloso.plugins.printer.logging;

version(WithPlugins):
version(WithPrinterPlugin):

private:

import kameloso.plugins.printer.base;

import dialect.defs;
import std.typecons : Flag, No, Yes;


package:


// LogLineBuffer
/++
    A struct containing lines to write to a log file when next committing such.

    This is only relevant if [kameloso.plugins.printer.base.PrinterSettings.bufferedWrites] is set.

    As a micro-optimisation an [std.array.Appender] is used to store the lines,
    instead of a normal `string[]`.
 +/
struct LogLineBuffer
{
private:
    import std.array : Appender;
    import std.datetime.systime : SysTime;

public:
    /// Basename directory this buffer will be saved to.
    string dir;

    /// Fully qualified filename this buffer will be saved to.
    string file;

    /// Buffered lines that will be saved to [file], in [dir].
    Appender!(string[]) lines;

    /++
        Constructor taking a [std.datetime.sytime.SysTime], to save as the date
        the buffer was created.
     +/
    this(const string dir, const SysTime now)
    {
        import std.datetime.date : Date;
        import std.path : buildNormalizedPath;

        static string yyyyMMOf(const SysTime date)
        {
            // Cut the day from the date string, keep YYYY-MM
            return (cast(Date)date).toISOExtString[0..7];
        }

        this.dir = dir;
        this.file = buildNormalizedPath(this.dir, yyyyMMOf(now) ~ ".log");
    }

    /++
        Constructor not taking a [std.datetime.sytime.SysTime], for use with
        buffers that should not be dated, such as the error log and the raw log.
     +/
    this(const string dir, const string filename)
    {
        import std.path : buildNormalizedPath;

        this.dir = dir;
        this.file = buildNormalizedPath(this.dir, filename);
    }
}


// onLoggableEventImpl
/++
    Logs an event to disk.

    It is set to [kameloso.plugins.common.core.ChannelPolicy.any], and configuration
    dictates whether or not non-home events should be logged. Likewise whether
    or not raw events should be logged.

    Lines will either be saved immediately to disk, opening a [std.stdio.File]
    with appending privileges for each event as they occur, or buffered by
    populating arrays of lines to be written in bulk, once in a while.

    See_Also:
        [commitAllLogsImpl]
 +/
void onLoggableEventImpl(PrinterPlugin plugin, const ref IRCEvent event)
{
    import kameloso.plugins.printer.formatting : formatMessageMonochrome;
    import kameloso.common : Tint, logger;
    import std.typecons : Flag, No, Yes;

    if (!plugin.printerSettings.logs) return;

    /// Write buffered lines.
    static void writeEventToFile(PrinterPlugin plugin, const ref IRCEvent event,
        const string key, const string givenPath = string.init,
        Flag!"extendPath" extendPath = Yes.extendPath,
        Flag!"raw" raw = No.raw,
        Flag!"errors" errors = No.errors)
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

                import std.file : exists, isDir, mkdirRecurse;
                import std.stdio : File, writeln;

                if (!buffer.dir.exists)
                {
                    mkdirRecurse(buffer.dir);
                }
                else if (!buffer.dir.isDir)
                {
                    // Something is in the way of the log's directory
                    return;
                }

                // Insert an empty space if the file exists, to separate old content from new
                immutable addLinebreak = buffer.file.exists;

                File file = File(buffer.file, "a");
                if (addLinebreak) file.writeln();
                file.writeln(datestamp);
                file.flush();
            }

            if (!errors)
            {
                LogLineBuffer* buffer = key in plugin.buffers;

                if (!buffer)
                {
                    if (extendPath)
                    {
                        import std.datetime.systime : Clock;
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
                        // Normal log
                        plugin.formatMessageMonochrome(plugin.linebuffer, event,
                            No.bellOnMention, No.bellOnError);
                        buffer.lines ~= plugin.linebuffer.data.idup;
                        plugin.linebuffer.clear();
                    }
                    else
                    {
                        import std.file : exists, isDir, mkdirRecurse;
                        import std.stdio : File;

                        if (!buffer.dir.exists)
                        {
                            mkdirRecurse(buffer.dir);
                        }
                        else if (!buffer.dir.isDir)
                        {
                            // Something is in the way of the log's directory
                            return;
                        }

                        auto file = File(buffer.file, "a");

                        plugin.formatMessageMonochrome(plugin.linebuffer, event,
                            No.bellOnMention, No.bellOnError);
                        file.writeln(plugin.linebuffer);
                        file.flush();
                        plugin.linebuffer.clear();
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
                        import std.stdio : File;

                        auto file = File(buffer.file, "a");
                        file.writeln(event.raw);
                        file.flush();
                    }
                }
            }
            else
            {
                import kameloso.printing : formatObjects;

                LogLineBuffer* errBuffer = key in plugin.buffers;

                if (!errBuffer)
                {
                    plugin.buffers[key] = LogLineBuffer(plugin.logDirectory, givenPath);
                    errBuffer = key in plugin.buffers;
                    insertDatestamp(errBuffer);  // New buffer, new "day"
                }

                if (plugin.printerSettings.bufferedWrites)
                {
                    errBuffer.lines ~= formatObjects!(Yes.all, No.coloured)
                        (No.brightTerminal, event);

                    if (event.sender.nickname.length || event.sender.address.length)
                    {
                        errBuffer.lines ~= formatObjects!(Yes.all, No.coloured)
                            (No.brightTerminal, event.sender);
                    }

                    if (event.target.nickname.length || event.target.address.length)
                    {
                        errBuffer.lines ~= formatObjects!(Yes.all, No.coloured)
                            (No.brightTerminal, event.target);
                    }

                    errBuffer.lines ~= "/////////////////////////////////////" ~
                        "///////////////////////////////////////////\n";  // 80c
                }
                else
                {
                    import std.stdio : File, writeln;

                    auto errFile = File(errBuffer.file, "a");

                    // This is an abuse of plugin.linebuffer and is pretty much
                    // guaranteed to grow it, but what do?

                    formatObjects!(Yes.all, No.coloured)(plugin.linebuffer,
                        No.brightTerminal, event);
                    errFile.writeln(plugin.linebuffer.data);
                    plugin.linebuffer.clear();

                    if (event.sender.nickname.length || event.sender.address.length)
                    {
                        formatObjects!(Yes.all, No.coloured)(plugin.linebuffer,
                            No.brightTerminal, event.sender);
                        errFile.writeln(plugin.linebuffer.data);
                        plugin.linebuffer.clear();
                    }

                    if (event.target.nickname.length || event.target.address.length)
                    {
                        formatObjects!(Yes.all, No.coloured)(plugin.linebuffer,
                            No.brightTerminal, event.target);
                        errFile.writeln(plugin.linebuffer.data);
                        plugin.linebuffer.clear();
                    }

                    errFile.writeln("/////////////////////////////////////" ~
                        "///////////////////////////////////////////\n");  // 80c
                    errFile.flush();
                }
            }
        }
        catch (FileException e)
        {
            logger.warning("File exception caught when writing to log: ", Tint.log, e.msg);
            version(PrintStacktraces) logger.trace(e.info);
        }
        catch (ErrnoException e)
        {
            version(Posix)
            {
                import kameloso.common : errnoStrings;
                import core.stdc.errno : errno;

                logger.warningf("ErrnoException (%s%s%s) caught when writing to log: %1$s%4$s",
                    Tint.log, errnoStrings[errno], Tint.warning, e.msg);
            }
            else version(Windows)
            {
                import core.stdc.errno : errno;

                logger.warningf("ErrnoException (%s%ds%s) caught when writing to log: %1$s%4$s",
                    Tint.log, errno, Tint.warning, e.msg);
            }
            else
            {
                logger.warning("ErrnoException caught when writing to log: ", Tint.log, e.msg);
            }

            version(PrintStacktraces) logger.trace(e.info);
        }
        catch (Exception e)
        {
            logger.warning("Unhandled exception caught when writing to log: ", Tint.log, e.msg);
            version(PrintStacktraces) logger.trace(e);
        }
    }

    // Write raw (if we should) before exiting early due to not a home (if we should)
    if (plugin.printerSettings.logRaw)
    {
        writeEventToFile(plugin, event, "<raw>", "raw.log", No.extendPath, Yes.raw);
    }

    if (event.errors.length && plugin.printerSettings.logErrors)
    {
        // This logs errors in guest channels. Consider making configurable.
        writeEventToFile(plugin, event, "<error>", "error.log", No.extendPath, No.raw, Yes.errors);
    }

    import std.algorithm.searching : canFind;

    if (!plugin.printerSettings.logGuestChannels &&
        event.channel.length && !plugin.state.bot.homeChannels.canFind(event.channel))
    {
        // Not logging all channels and this is not a home.
        return;
    }

    with (IRCEvent.Type)
    switch (event.type)
    {
    case PING:
    case SELFMODE:
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
        foreach (immutable channelName, const foreachChannel; plugin.state.channels)
        {
            if (!plugin.printerSettings.logGuestChannels &&
                !plugin.state.bot.homeChannels.canFind(channelName))
            {
                // Not logging all channels and this is not a home.
                continue;
            }

            if (event.sender.nickname in foreachChannel.users)
            {
                // Channel message
                writeEventToFile(plugin, event, channelName);
            }
        }

        if (event.sender.nickname.length && event.sender.nickname in plugin.buffers)
        {
            // There is an open query buffer; write to it too
            writeEventToFile(plugin, event, event.sender.nickname);
        }
        break;

    version(TwitchSupport)
    {
        case JOIN:
        case PART:
            if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
            {
                // These Twitch events are just noise.
                return;
            }
            else
            {
                goto default;
            }

        case USERSTATE:
        case GLOBALUSERSTATE:
            // Always on Twitch, no need to check plugin.state.server.daemon
            return;
    }

    default:
        if (event.channel.length && (event.sender.nickname.length || (event.type == MODE)))
        {
            // Channel message, or specialcased server-sent MODEs
            writeEventToFile(plugin, event, event.channel);
        }
        else if (event.sender.nickname.length)
        {
            // Implicitly not a channel; query
            writeEventToFile(plugin, event, event.sender.nickname);
        }
        else if (plugin.printerSettings.logServer && !event.sender.nickname.length &&
            event.sender.address.length)
        {
            // Server
            writeEventToFile(plugin, event, plugin.state.server.address, "server.log", No.extendPath);
        }
        else
        {
            // logServer is probably false and event shouldn't be logged
            // OR we don't know how to deal with this event type
            /*import kameloso.printing : printObject;
            printObject(event);*/
            return;
        }
        break;
    }
}


// establishLogLocation
/++
    Verifies that a log directory exists, complaining if it's invalid, creating
    it if it doesn't exist.

    Example:
    ---
    assert(!("~/logs".isDir));
    bool locationIsOkay = plugin.establishLogLocation("~/logs");
    assert("~/logs".isDir);
    ---

    Params:
        plugin = The current [kameloso.plugins.printer.base.PrinterPlugin].
        logLocation = String of the location directory we want to store logs in.

    Returns:
        A bool whether or not the log location is valid.
 +/
bool establishLogLocation(PrinterPlugin plugin, const string logLocation)
{
    import kameloso.common : Tint, logger;
    import std.file : exists, isDir;

    if (logLocation.exists)
    {
        if (logLocation.isDir) return true;

        if (!plugin.naggedAboutDir)
        {
            logger.warningf("Specified log directory (%s%s%s) is not a directory.",
                Tint.log, logLocation, Tint.warning);
            plugin.naggedAboutDir = true;
        }

        return false;
    }
    else
    {
        // Create missing log directory
        import std.file : mkdirRecurse;

        mkdirRecurse(logLocation);
        logger.log("Created log directory: ", Tint.info, logLocation);
    }

    return true;
}


// commitAllLogsImpl
/++
    Writes all buffered log lines to disk.

    Merely wraps [commitLog] by iterating over all buffers and invoking it.

    Params:
        plugin = The current [kameloso.plugins.printer.base.PrinterPlugin].

    See_Also:
        [commitLog]
 +/
void commitAllLogsImpl(PrinterPlugin plugin)
{
    if (!plugin.printerSettings.logs || !plugin.printerSettings.bufferedWrites) return;

    foreach (ref buffer; plugin.buffers)
    {
        commitLog(plugin, buffer);
    }
}


// commitLog
/++
    Writes a single log buffer to disk.

    This is a way of queuing writes so that they can be committed seldomly and
    in bulk, supposedly being nicer to the hardware at the cost of the risk of
    losing uncommitted lines in a catastrophical crash.

    Params:
        plugin = The current [kameloso.plugins.printer.base.PrinterPlugin].
        buffer = [LogLineBuffer] whose lines to commit to disk.

    See_Also:
        [commitAllLogsImpl]
 +/
void commitLog(PrinterPlugin plugin, ref LogLineBuffer buffer)
{
    import kameloso.common : Tint, logger;
    import std.exception : ErrnoException;
    import std.file : FileException;
    import std.utf : UTFException;

    if (!buffer.lines.data.length) return;

    try
    {
        import std.file : exists, isDir, mkdirRecurse;
        import std.stdio : File, writeln;

        if (!buffer.dir.exists)
        {
            mkdirRecurse(buffer.dir);
        }
        else if (!buffer.dir.isDir)
        {
            // Something is in the way of the log's directory
            // Discard accumulated lines
            buffer.lines.clear();
            return;
        }

        auto file = File(buffer.file, "a");

        foreach (line; buffer.lines.data)
        {
            import std.encoding : sanitize;
            file.writeln(sanitize(line));
        }

        // Only clear if we managed to write everything, otherwise accumulate
        buffer.lines.clear();
    }
    catch (FileException e)
    {
        logger.warningf("File exception caught when committing log %s%s%s: %1$s%4$s%5$s",
            Tint.log, buffer.file, Tint.warning, e.msg, plugin.bell);
        version(PrintStacktraces) logger.trace(e.info);
    }
    catch (ErrnoException e)
    {
        version(Posix)
        {
            import kameloso.common : errnoStrings;
            logger.warningf("ErrnoException %s%s%s caught when committing " ~
                "log to %1$s%4$s%3$s: %1$s%5$s%6$s",
                Tint.log, errnoStrings[e.errno], Tint.warning, buffer.file, e.msg, plugin.bell);
        }
        else
        {
            logger.warningf("ErrnoException %s%d%s caught when committing " ~
                "log to %1$s%4$s%3$s: %1$s%5$s%6$s",
                Tint.log, e.errno, Tint.warning, buffer.file, e.msg, plugin.bell);
        }

        version(PrintStacktraces) logger.trace(e.info);
    }
    catch (Exception e)
    {
        logger.warningf("Unexpected exception caught when committing log %s%s%s: %1$s%4$s%5$s",
            Tint.log, buffer.file, Tint.warning, e.msg, plugin.bell);
        version(PrintStacktraces) logger.trace(e);
    }
}


// escapedPath
/++
    Replaces some characters in a string that don't translate well to paths.

    This is platform-specific, as Windows uses backslashes as directory
    separators and percentages for environment variables, whereas Posix uses
    forward slashes and dollar signs.

    Bugs:
        Escaped paths can collide with real files named what the original path
        was escaped to. "%PATH%" may as such collide with "_PATH_", as the
        former was escaped to an already valid filename.

    Params:
        path = A filesystem path in string form.

    Returns:
        The passed path with some characters replaced.
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
