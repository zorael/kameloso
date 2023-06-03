/++
    Implementation of Printer plugin functionality that concerns logging.
    For internal use.

    The [dialect.defs.IRCEvent|IRCEvent]-annotated handlers must be in the same module
    as the [kameloso.plugins.admin.base.AdminPlugin|AdminPlugin], but these implementation
    functions can be offloaded here to limit module size a bit.

    See_Also:
        [kameloso.plugins.printer.base|printer.base]
        [kameloso.plugins.printer.formatting|printer.formatting]
 +/
module kameloso.plugins.printer.logging;

version(WithPrinterPlugin):

private:

import kameloso.plugins.printer.base;

import kameloso.common : logger;
import dialect.defs;
import std.typecons : Flag, No, Yes;


package:


// LogLineBuffer
/++
    A struct containing lines to write to a log file when next committing such.

    This is only relevant if
    [kameloso.plugins.printer.base.PrinterSettings.bufferedWrites|PrinterSettings.bufferedWrites]
    is set.

    As a micro-optimisation an [std.array.Appender|Appender] is used to store the lines,
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
        Constructor taking a [std.datetime.systime.SysTime|SysTime], to save as the date
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
        Constructor not taking a [std.datetime.systime.SysTime|SysTime], for use with
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

    It is set to [kameloso.plugins.common.core.ChannelPolicy.any|ChannelPolicy.any],
    and configuration dictates whether or not non-home events should be logged.
    Likewise whether or not raw events should be logged.

    Lines will either be saved immediately to disk, opening a [std.stdio.File|File]
    with appending privileges for each event as they occur, or buffered by
    populating arrays of lines to be written in bulk, once in a while.

    See_Also:
        [commitAllLogsImpl]
 +/
void onLoggableEventImpl(PrinterPlugin plugin, const ref IRCEvent event)
{
    import kameloso.plugins.printer.formatting : formatMessageMonochrome;
    import std.typecons : Flag, No, Yes;

    if (!plugin.printerSettings.logs) return;

    /// Write buffered lines.
    static void writeEventToFile(
        PrinterPlugin plugin,
        const ref IRCEvent event,
        const string key,
        const string givenPath = string.init,
        const Flag!"extendPath" extendPath = Yes.extendPath,
        const Flag!"raw" raw = No.raw,
        const Flag!"errors" errors = No.errors)
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

                // Insert an empty space if the file exists, to separate old content from new
                // Cache .exists, because opening the file creates it
                // (and thus a non-existing file would still get the spacing writeln)
                immutable fileExists = buffer.file.exists;
                File file = File(buffer.file, "a");
                if (fileExists) file.writeln();
                file.writeln(datestamp);
                //file.flush();
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
                        plugin.formatMessageMonochrome(
                            plugin.linebuffer,
                            event,
                            No.bellOnMention,
                            No.bellOnError);
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

                        plugin.formatMessageMonochrome(
                            plugin.linebuffer,
                            event,
                            No.bellOnMention,
                            No.bellOnError);
                        scope(exit) plugin.linebuffer.clear();

                        auto file = File(buffer.file, "a");
                        file.writeln(plugin.linebuffer);
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
                        //file.flush();
                    }
                }
            }
            else
            {
                LogLineBuffer* errBuffer = key in plugin.buffers;

                if (!errBuffer)
                {
                    plugin.buffers[key] = LogLineBuffer(plugin.logDirectory, givenPath);
                    errBuffer = key in plugin.buffers;
                    insertDatestamp(errBuffer);  // New buffer, new "day"
                }

                if (plugin.printerSettings.bufferedWrites)
                {
                    version(IncludeHeavyStuff)
                    {
                        import kameloso.printing : formatObjects;

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
                        import lu.conv : Enum;
                        import std.conv : text;

                        errBuffer.lines ~= text('@', event.tags, ' ', event.raw);

                        if (event.sender.nickname.length || event.sender.address.length)
                        {
                            errBuffer.lines ~= text(
                                event.sender.nickname, '!',
                                event.sender.ident, '@',
                                event.sender.address, ':',
                                event.sender.account, " -- ",
                                Enum!(IRCUser.Class).toString(event.sender.class_), "\n\n");
                        }

                        if (event.target.nickname.length || event.target.address.length)
                        {
                            errBuffer.lines ~= text(
                                event.target.nickname, '!',
                                event.target.ident, '@',
                                event.target.address, ':',
                                event.target.account, " -- ",
                                Enum!(IRCUser.Class).toString(event.target.class_), "\n\n");
                        }
                    }

                    errBuffer.lines ~= "/////////////////////////////////////" ~
                        "///////////////////////////////////////////\n";  // 80c
                }
                else
                {
                    import std.stdio : File;

                    auto errFile = File(errBuffer.file, "a");

                    // This is an abuse of plugin.linebuffer and is pretty much
                    // guaranteed to grow it, but what do?

                    version(IncludeHeavyStuff)
                    {
                        import kameloso.printing : formatObjects;

                        formatObjects!(Yes.all, No.coloured)(plugin.linebuffer,
                            No.brightTerminal, event);
                        errFile.writeln(plugin.linebuffer.data);
                        plugin.linebuffer.clear();

                        if (event.sender.nickname.length || event.sender.address.length)
                        {
                            formatObjects!(Yes.all, No.coloured)(
                                plugin.linebuffer,
                                No.brightTerminal,
                                event.sender);
                            errFile.writeln(plugin.linebuffer.data);
                            plugin.linebuffer.clear();
                        }

                        if (event.target.nickname.length || event.target.address.length)
                        {
                            formatObjects!(Yes.all, No.coloured)(
                                plugin.linebuffer,
                                No.brightTerminal,
                                event.target);
                            errFile.writeln(plugin.linebuffer.data);
                            plugin.linebuffer.clear();
                        }
                    }
                    else
                    {
                        import lu.conv : Enum;
                        import std.conv : text;

                        errFile.writeln('@', event.tags, ' ', event.raw);

                        if (event.sender.nickname.length || event.sender.address.length)
                        {
                            errFile.writeln(
                                event.sender.nickname, '!',
                                event.sender.ident, '@',
                                event.sender.address, ':',
                                event.sender.account, " -- ",
                                Enum!(IRCUser.Class).toString(event.sender.class_), "\n\n");
                        }

                        if (event.target.nickname.length || event.target.address.length)
                        {
                            errFile.writeln(
                                event.target.nickname, '!',
                                event.target.ident, '@',
                                event.target.address, ':',
                                event.target.account, " -- ",
                                Enum!(IRCUser.Class).toString(event.target.class_), "\n\n");
                        }
                    }

                    errFile.writeln("/////////////////////////////////////" ~
                        "///////////////////////////////////////////\n");  // 80c
                    //errFile.flush();
                }
            }
        }
        catch (FileException e)
        {
            enum pattern = "File exception caught when writing to log: <t>%s";
            logger.warningf(pattern, e.msg);
            version(PrintStacktraces) logger.trace(e.info);
        }
        catch (ErrnoException e)
        {
            version(Posix)
            {
                import kameloso.common : errnoStrings;
                import core.stdc.errno : errno;

                enum pattern = "ErrnoException (<l>%s</>) caught when writing to log: <t>%s";
                logger.warningf(pattern, errnoStrings[errno], e.msg);
            }
            else version(Windows)
            {
                import core.stdc.errno : errno;

                enum pattern = "ErrnoException (<l>%d</>) caught when writing to log: <t>%s";
                logger.warningf(pattern, errno, e.msg);
            }
            else
            {
                static assert(0, "Unsupported platform, please file a bug.");
            }

            version(PrintStacktraces) logger.trace(e.info);
        }
        catch (Exception e)
        {
            enum pattern = "Unhandles exception caught when writing to log: <t>%s";
            logger.warningf(pattern, e.msg);
            version(PrintStacktraces) logger.trace(e);
        }
    }

    // Write raw (if we should) before exiting early due to not a home (if we should)
    if (plugin.printerSettings.logRaw)
    {
        writeEventToFile(
            plugin,
            event,
            "<raw>",
            "raw.log",
            No.extendPath,
            Yes.raw);
    }

    if (event.errors.length && plugin.printerSettings.logErrors)
    {
        // This logs errors in guest channels. Consider making configurable.
        writeEventToFile(
            plugin,
            event,
            "<error>",
            "error.log",
            No.extendPath,
            No.raw,
            Yes.errors);
    }

    import std.algorithm.searching : canFind;

    if (!plugin.printerSettings.logGuestChannels &&
        event.channel.length &&
        !plugin.state.bot.homeChannels.canFind(event.channel))
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
            // Not a channel; query or other server-wide message
            if (plugin.printerSettings.logPrivateMessages)
            {
                writeEventToFile(plugin, event, event.sender.nickname);
            }
        }
        else if (plugin.printerSettings.logServer &&
            !event.sender.nickname.length &&
            event.sender.address.length)
        {
            // Server
            writeEventToFile(
                plugin,
                event,
                plugin.state.server.address,
                "server.log",
                No.extendPath);
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
        logLocation = String of the location directory we want to store logs in.
        connectionID = ID of the current connection, so as not to spam error messages.

    Returns:
        A bool whether or not the log location is valid.
 +/
auto establishLogLocation(const string logLocation, const uint connectionID)
{
    import std.file : exists, isDir;

    if (logLocation.exists)
    {
        if (logLocation.isDir) return true;

        static uint idWhenNaggedAboutDir;

        if (idWhenNaggedAboutDir != connectionID)
        {
            enum pattern = "Specified log directory (<l>%s</>) is not a directory.";
            logger.warningf(pattern, logLocation);
            idWhenNaggedAboutDir = connectionID;
        }

        return false;
    }
    else
    {
        // Create missing log directory
        import std.file : mkdirRecurse;

        mkdirRecurse(logLocation);
        enum pattern = "Created log directory: <i>%s";
        logger.logf(pattern, logLocation);
    }

    return true;
}


// commitAllLogsImpl
/++
    Writes all buffered log lines to disk.

    Merely wraps [commitLog] by iterating over all buffers and invoking it.

    Params:
        plugin = The current [kameloso.plugins.printer.base.PrinterPlugin|PrinterPlugin].

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

    This is a way of queuing writes so that they can be committed seldom and
    in bulk, supposedly being nicer to the hardware at the cost of the risk of
    losing uncommitted lines in a catastrophical crash.

    Params:
        plugin = The current [kameloso.plugins.printer.base.PrinterPlugin|PrinterPlugin].
        buffer = [LogLineBuffer] whose lines to commit to disk.

    See_Also:
        [commitAllLogsImpl]
 +/
void commitLog(PrinterPlugin plugin, ref LogLineBuffer buffer)
{
    import std.exception : ErrnoException;
    import std.file : FileException;
    import std.utf : UTFException;

    if (!buffer.lines.data.length) return;

    try
    {
        import std.algorithm.iteration : map;
        import std.array : join;
        import std.encoding : sanitize;
        import std.file : exists, isDir, mkdirRecurse;
        import std.stdio : File;

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

        // Write all in one go
        const lines = buffer.lines.data
            .map!sanitize
            .join("\n");

        {
            File file = File(buffer.file, "a");
            file.writeln(lines);
        }

        // If we're here, no exceptions were thrown
        // Only clear if we managed to write everything, otherwise accumulate
        buffer.lines.clear();
    }
    catch (FileException e)
    {
        enum pattern = "File exception caught when committing log <l>%s</>: <t>%s%s";
        logger.warningf(pattern, buffer.file, e.msg, plugin.bell);
        version(PrintStacktraces) logger.trace(e.info);
    }
    catch (ErrnoException e)
    {
        version(Posix)
        {
            import kameloso.common : errnoStrings;
            enum pattern = "ErrnoException <l>%s</> caught when committing log to <l>%s</>: <t>%s%s";
            logger.warningf(pattern, errnoStrings[e.errno], buffer.file, e.msg, plugin.bell);
        }
        else version(Windows)
        {
            enum pattern = "ErrnoException <l>%d</> caught when committing log to <l>%s</>: <t>%s%s";
            logger.warningf(pattern, e.errno, buffer.file, e.msg, plugin.bell);
        }
        else
        {
            static assert(0, "Unsupported platform, please file a bug.");
        }

        version(PrintStacktraces) logger.trace(e.info);
    }
    catch (Exception e)
    {
        enum pattern = "Unexpected exception caught when committing log <l>%s</>: <t>%s%s";
        logger.warningf(pattern, buffer.file, e.msg, plugin.bell);
        version(PrintStacktraces) logger.trace(e);
    }
}


// escapedPath
/++
    Replaces some invalid filenames to something that can be stored on the filesystem.

    This is really only a problem on Windows, as the Posix
    [std.path.dirSeparator|dirSeparator] is not a valid IRC character, nor does
    it have special legacy filenames like `NUL` and `CON`.

    Params:
        path = A filesystem path in string form.

    Returns:
        The passed path with some characters potentially added or replaced.
        The original string is returned as-was if nothing no changes were needed.
 +/
auto escapedPath(/*const*/ string path)
{
    version(Windows)
    {
        import std.algorithm.comparison : among;
        import std.array : replace;
        import std.uni : toUpper;

        // Tilde is not a valid IRC nickname character, so it's safe to use as placeholder
        enum replacementCharacter = '~';
        enum alternateReplacementCharacter = ')';

        if (path.toUpper.among!("CON", "PRN", "AUX", "NUL",
            "COM0", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
            "LPT0", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"))
        {
            path ~= replacementCharacter;
        }

        return path
            .replace('\\', replacementCharacter)
            .replace('|', alternateReplacementCharacter);  // Don't collide
    }
    else version(Posix)
    {
        return path;
    }
    else
    {
        static assert(0, "Unsupported platform, please file a bug.");
    }
}

///
unittest
{
    version(Windows)
    {
        {
            immutable before = "a\\b";
            immutable after = escapedPath(before);
            immutable expected = "a~b";
            assert((after == expected), after);
        }
        {
            immutable before = "CON";
            immutable after = escapedPath(before);
            immutable expected = "CON~";
            assert((after == expected), after);
        }
        {
            immutable before = "NUL";
            immutable after = escapedPath(before);
            immutable expected = "NUL~";
            assert((after == expected), after);
        }
        {
            immutable before = "aUx";
            immutable after = escapedPath(before);
            immutable expected = "aUx~";
            assert((after == expected), after);
        }
        {
            immutable before = "con-";
            immutable after = escapedPath(before);
            assert((after is before), after);
        }
        {
            immutable before = "con|";
            immutable after = escapedPath(before);
            immutable expected = "con)";
            assert((after == expected), after);
        }
    }
    else version(Posix)
    {
        immutable before = "passthrough";
        immutable after = escapedPath(before);
        assert((after is before), after);
    }
}
