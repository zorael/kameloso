/++
 +  Implementation of Printer plugin functionality that concerns logging.
 +  For internal use.
 +
 +  The `dialect.defs.IRCEvent`-annotated handlers must be in the same module
 +  as the `kameloso.plugins.admin.AdminPlugin`, but these implementation
 +  functions can be offloaded here to limit module size a bit.
 +/
module kameloso.plugins.printer.logging;

version(WithPlugins):
version(WithPrinterPlugin):

private:

import kameloso.plugins.printer;

import kameloso.common : Tint, logger;
import dialect.defs;
import std.typecons : Flag, No, Yes;

package:


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
    import std.datetime.systime : SysTime;
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


// onLoggableEventImpl
/++
 +  Logs an event to disk.
 +
 +  It is set to `kameloso.plugins.core.ChannelPolicy.any`, and configuration
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
void onLoggableEventImpl(PrinterPlugin plugin, const IRCEvent event)
{
    import kameloso.plugins.printer.formatting : formatMessageMonochrome;
    import std.typecons : Flag, No, Yes;

    if (!plugin.printerSettings.logs) return;

    /// Write buffered lines.
    static void writeEventToFile(PrinterPlugin plugin, const IRCEvent event,
        const string key, const string givenPath = string.init,
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
                    plugin.formatMessageMonochrome(sink, event,
                        No.bellOnMention, No.bellOnError);
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
                    plugin.formatMessageMonochrome(file.lockingTextWriter, event,
                        No.bellOnMention, No.bellOnError);
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
                }
                else
                {
                    import std.stdio : File;

                    File(errBuffer.file, "a")
                        .lockingTextWriter
                        .formatObjects!(Yes.all, No.coloured)(No.brightTerminal, event);

                    if (event.sender.nickname.length || event.sender.address.length)
                    {
                        File(errBuffer.file, "a")
                            .lockingTextWriter
                            .formatObjects!(Yes.all, No.coloured)(No.brightTerminal, event.sender);
                    }

                    if (event.target.nickname.length || event.target.address.length)
                    {
                        File(errBuffer.file, "a")
                            .lockingTextWriter
                            .formatObjects!(Yes.all, No.coloured)(No.brightTerminal, event.target);
                    }
                }
            }
        }
        catch (FileException e)
        {
            logger.warning("File exception caught when writing to log: ", e.msg);
            version(PrintStacktraces) logger.trace(e.info);
        }
        catch (ErrnoException e)
        {
            logger.warning("Exception caught when writing to log: ", e.msg);
            version(PrintStacktraces) logger.trace(e.info);
        }
        catch (Exception e)
        {
            logger.warning("Unhandled exception caught when writing to log: ", e.msg);
            version(PrintStacktraces) logger.trace(e.toString);
        }
    }

    // Write raw (if we should) before exiting early due to not a home (if we should)
    if (plugin.printerSettings.logRaw)
    {
        writeEventToFile(plugin, event, "<raw>", "raw.log", No.extendPath, Yes.raw);
    }

    import std.algorithm.searching : canFind;

    if (!plugin.printerSettings.logAllChannels &&
        event.channel.length && !plugin.state.bot.homeChannels.canFind(event.channel))
    {
        // Not logging all channels and this is not a home.
        return;
    }

    with (IRCEvent.Type)
    with (plugin)
    with (event)
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
                writeEventToFile(plugin, event, channelName);
            }
        }

        if (sender.nickname.length && sender.nickname in plugin.buffers)
        {
            // There is an open query buffer; write to it too
            writeEventToFile(plugin, event, sender.nickname);
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
            writeEventToFile(plugin, event, channel);
        }
        else if (sender.nickname.length)
        {
            // Implicitly not a channel; query
            writeEventToFile(plugin, event, sender.nickname);
        }
        else if (printerSettings.logServer && !sender.nickname.length && sender.address.length)
        {
            // Server
            writeEventToFile(plugin, event, state.server.address, "server.log", No.extendPath);
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
        logger.logf("Created log directory: %s%s", Tint.info, logLocation);
    }

    return true;
}


// commitAllLogsImpl
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
void commitAllLogsImpl(PrinterPlugin plugin)
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
        version(PrintStacktraces) logger.trace(e.info);
    }
    catch (ErrnoException e)
    {
        logger.warning("Exception caught when committing log: ",
            e.msg, cast(char)TerminalToken.bell);
        version(PrintStacktraces) logger.trace(e.info);
    }
    catch (Exception e)
    {
        logger.warning("Unhandled exception caught when committing log: ",
            e.msg, cast(char)TerminalToken.bell);
        version(PrintStacktraces) logger.trace(e.toString);
    }
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
