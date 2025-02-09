/++
    Implementation of Printer plugin functionality that concerns logging.
    For internal use.

    The [dialect.defs.IRCEvent|IRCEvent]-annotated handlers must be in the same module
    as the [kameloso.plugins.printer.PrinterPlugin|PrinterPlugin], but these implementation
    functions can be offloaded here to limit module size a bit.

    See_Also:
        [kameloso.plugins.printer],
        [kameloso.plugins.printer.formatting]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.printer.logging;

version(WithPrinterPlugin):

private:

import kameloso.plugins.printer;

import kameloso.common : logger;
import dialect.defs;

package:


// LogLineBuffer
/++
    A struct containing lines to write to a log file when next flushing such.

    This is only relevant if
    [kameloso.plugins.printer.PrinterSettings.bufferedWrites|PrinterSettings.bufferedWrites]
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
    /++
        Basename directory this buffer will be saved to.
     +/
    string dir;

    /++
        Fully qualified filename this buffer will be saved to.
     +/
    string file;

    /++
        Buffered lines that will be saved to [file], in [dir].
     +/
    Appender!(string[]) lines;

    /++
        Clears the buffer of lines.

        Uses [lu.array.zero] to zero the buffer instead of merely invoking
        [std.array.Appender.clear|Appender.clear], to reduce the number of live pointers.
     +/
    void clear() @safe nothrow
    {
        import lu.array : zero;
        lines.zero('\0');
    }

    /++
        When this buffer was created.
     +/
    SysTime creationTime;

    /++
        Constructor taking a [std.datetime.systime.SysTime|SysTime], to save as the date
        the buffer was created.
     +/
    this(const string dir, const SysTime now) /*pure @nogc*/ @safe nothrow
    {
        import std.datetime.date : Date;
        import std.path : buildNormalizedPath;

        static string yyyyMMOf(const SysTime date)
        {
            // Cut the day from the date string, keep YYYY-MM
            return (cast(Date)date).toISOExtString[0..7];
        }

        this.dir = dir;
        this.creationTime = now;
        this.file = buildNormalizedPath(this.dir, yyyyMMOf(now) ~ ".log");
    }

    /++
        Constructor not taking a [std.datetime.systime.SysTime|SysTime], for use with
        buffers that should not be dated, such as the error log and the raw log.
     +/
    this(const string dir, const string filename) pure @safe nothrow /*@nogc*/
    {
        import std.path : buildNormalizedPath;

        this.dir = dir;
        this.file = buildNormalizedPath(this.dir, filename);
    }
}


// onLoggableEventImpl
/++
    Logs an event to disk.

    It is set to [kameloso.plugins.ChannelPolicy.any|ChannelPolicy.any],
    and configuration dictates whether or not non-home events should be logged.
    Likewise whether or not raw events should be logged.

    Lines will either be saved immediately to disk, opening a [std.stdio.File|File]
    with appending privileges for each event as they occur, or buffered by
    populating arrays of lines to be written in bulk, once in a while.

    See_Also:
        [flushAllLogsImpl]
 +/
void onLoggableEventImpl(PrinterPlugin plugin, const IRCEvent event)
{
    import kameloso.plugins.printer.formatting : formatMessageMonochrome;
    import std.algorithm.searching : canFind;
    import std.typecons : Flag, No, Yes;

    /++
        Ensures a directory exists, creating it if it doesn't and return success.
     +/
    static auto ensureDir(const string dir)
    {
        import std.file : exists, isDir, mkdirRecurse;

        if (!dir.exists)
        {
            mkdirRecurse(dir);
            return true;
        }
        else if (!dir.isDir)
        {
            // Something is in the way of the log's directory
            return false;
        }
        return true;
    }

    /++
        Write buffered lines.
     +/
    static void writeEventToFile(
        PrinterPlugin plugin,
        const IRCEvent event,
        const string key,
        const string givenPath = string.init,
        const bool intoSubdir = true,
        const bool raw = false,
        const bool errors = false)
    {
        import std.exception : ErrnoException;
        import std.file : FileException;
        import std.stdio : File;

        enum separator80cLF = "/////////////////////////////////////" ~
            "///////////////////////////////////////////\n";

        immutable path = givenPath.length ? givenPath.escapedPath : key.escapedPath;

        try
        {
            /++
                Write datestamp to file immediately, bypassing any buffers.
             +/
            static void insertDatestamp(const LogLineBuffer* buffer)
            {
                import std.file : exists;

                assert(buffer, "Tried to add datestamp to null buffer");
                assert((buffer.file.length && buffer.dir.length),
                    "Tried to add datestamp to uninitialised buffer");

                if (!ensureDir(buffer.dir)) return;

                // Insert an empty space if the file exists, to separate old content from new
                // Cache .exists, because opening the file creates it
                // (and thus a non-existing file would still get the spacing writeln)
                immutable fileExists = buffer.file.exists;
                auto file = File(buffer.file, "a");
                if (fileExists) file.writeln();
                file.writeln(datestamp);
            }

            /++
                Returns a simple representation of a user.

                Only necessary outside of version IncludeHeavyStuff.
             +/
            version(IncludeHeavyStuff) {}
            else
            static auto getSimpleUserLine(const IRCUser user)
            {
                import lu.conv : toString;
                import std.conv : text;

                return text(
                    user.nickname, '!',
                    user.ident, '@',
                    user.address, ':',
                    user.account, " -- ",
                    user.class_.toString());//, "\n\n");
            }

            if (!errors)
            {
                // Normal event
                auto buffer = key in plugin.buffers;

                if (!buffer)
                {
                    if (intoSubdir)
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

                if (!ensureDir(buffer.dir)) return;

                if (!raw)
                {
                    // Normal buffers
                    scope(exit)plugin.linebuffer.clear();

                    formatMessageMonochrome(
                        plugin,
                        plugin.linebuffer,
                        event,
                        bellOnMention : false,
                        bellOnError: false);

                    if (plugin.printerSettings.bufferedWrites)
                    {
                        buffer.lines.put(plugin.linebuffer[].idup);
                        plugin.linebuffer.clear();
                    }
                    else
                    {
                        auto file = File(buffer.file, "a");
                        file.writeln(plugin.linebuffer[]);
                    }
                }
                else /*if (raw)*/
                {
                    // Raw log
                    if (plugin.printerSettings.bufferedWrites)
                    {
                        buffer.lines.put(event.raw);
                    }
                    else
                    {
                        auto file = File(buffer.file, "a");
                        file.writeln(event.raw);
                    }
                }
            }
            else /*if (errors)*/
            {
                // Error event
                auto errBuffer = key in plugin.buffers;

                if (!errBuffer)
                {
                    plugin.buffers[key] = LogLineBuffer(plugin.logDirectory, givenPath);
                    errBuffer = key in plugin.buffers;
                    insertDatestamp(errBuffer);  // New buffer, new "day"
                }

                if (!ensureDir(errBuffer.dir)) return;

                if (plugin.printerSettings.bufferedWrites)
                {
                    version(IncludeHeavyStuff)
                    {
                        import kameloso.prettyprint : prettyformat;

                        /+
                            Use the plugin's linebuffer as a scratch buffer to
                            construct the errors in.

                            Ideally we wouldn't use the linebuffer here and
                            instead keep an errlinebuffer around, but this works.
                         +/

                        scope(failure) plugin.linebuffer.clear();

                        // Adds some 220 mb to compilation memory usage
                        prettyformat!(Yes.all, No.coloured)
                            (plugin.linebuffer,
                            brightTerminal: false,
                            event);

                        errBuffer.lines.put(plugin.linebuffer[].idup);

                        if (event.sender.nickname.length || event.sender.address.length)
                        {
                            plugin.linebuffer.clear();

                            prettyformat!(Yes.all, No.coloured)
                                (plugin.linebuffer,
                                brightTerminal: false,
                                event.sender);

                            errBuffer.lines.put(plugin.linebuffer[].idup);
                        }

                        if (event.target.nickname.length || event.target.address.length)
                        {
                            plugin.linebuffer.clear();

                            prettyformat!(Yes.all, No.coloured)
                                (plugin.linebuffer,
                                brightTerminal: false,
                                event.target);

                            errBuffer.lines.put(plugin.linebuffer[].idup);
                        }
                    }
                    else /*version (!IncludeHeavyStuff)*/
                    {
                        import std.conv : text;

                        errBuffer.lines.put(text('@', event.tags, ' ', event.raw));

                        if (event.sender.nickname.length || event.sender.address.length)
                        {
                            errBuffer.lines.put(getSimpleUserLine(event.sender));
                        }

                        if (event.target.nickname.length || event.target.address.length)
                        {
                            errBuffer.lines.put(getSimpleUserLine(event.target));
                        }
                    }

                    errBuffer.lines.put(separator80cLF);
                }
                else /*if (plugin.printerSettings.bufferedWrites)*/
                {
                    auto errFile = File(errBuffer.file, "a");

                    version(IncludeHeavyStuff)
                    {
                        import kameloso.prettyprint : prettyformat;

                        /+
                            See notes above.
                         +/

                        scope(failure) plugin.linebuffer.clear();

                        prettyformat!(Yes.all, No.coloured)
                            (plugin.linebuffer,
                            brightTerminal: false,
                            event);

                        errFile.writeln(plugin.linebuffer[]);

                        if (event.sender.nickname.length || event.sender.address.length)
                        {
                            plugin.linebuffer.clear();

                            prettyformat!(Yes.all, No.coloured)
                                (plugin.linebuffer,
                                brightTerminal: false,
                                event.sender);

                            errFile.writeln(plugin.linebuffer[]);
                        }

                        if (event.target.nickname.length || event.target.address.length)
                        {
                            plugin.linebuffer.clear();

                            prettyformat!(Yes.all, No.coloured)
                                (plugin.linebuffer,
                                brightTerminal: false,
                                event.target);

                            errFile.writeln(plugin.linebuffer[]);
                        }
                    }
                    else /*version (!IncludeHeavyStuff)*/
                    {
                        errFile.writeln('@', event.tags, ' ', event.raw);

                        if (event.sender.nickname.length || event.sender.address.length)
                        {
                            errFile.writeln(getSimpleUserLine(event.sender));
                        }

                        if (event.target.nickname.length || event.target.address.length)
                        {
                            errFile.writeln(getSimpleUserLine(event.target));
                        }
                    }

                    errFile.writeln(separator80cLF);
                }
            }
        }
        catch (FileException e)
        {
            enum pattern = "File exception caught when writing to log (<l>%s</>): <t>%s%s";
            logger.warningf(pattern, key, e.msg, plugin.transient.bell);
            version(PrintStacktraces) logger.trace(e.info);
        }
        catch (ErrnoException e)
        {
            version(Posix)
            {
                import kameloso.tables : errnoMap;
                import core.stdc.errno : errno;

                enum pattern = "ErrnoException (<l>%s</>) caught when writing to log (<l>%s</>): <t>%s%s";
                logger.warningf(pattern, errnoMap[errno], key, e.msg, plugin.transient.bell);
            }
            else version(Windows)
            {
                import core.stdc.errno : errno;

                enum pattern = "ErrnoException (<l>%d</>) caught when writing to log (<l>%s</>): <t>%s%s";
                logger.warningf(pattern, errno, key, e.msg, plugin.transient.bell);
            }
            else
            {
                static assert(0, "Unsupported platform, please file a bug.");
            }

            version(PrintStacktraces) logger.trace(e.info);
        }
        catch (Exception e)
        {
            enum pattern = "Unhandled exception caught when writing to log (<l>%s</>): <t>%s%s";
            logger.warningf(pattern, key, e.msg, plugin.transient.bell);
            version(PrintStacktraces) logger.trace(e);
        }
    }

    enum rawMarker = "<raw>";
    enum errorMarker = "<error>";

    // Write raw (if we should) early, before everything else
    if (plugin.printerSettings.logRaw)
    {
        writeEventToFile(
            plugin,
            event,
            rawMarker,
            "raw.log",
            intoSubdir : false,
            raw: true);
    }

    if (event.errors.length && plugin.printerSettings.logErrors)
    {
        // This logs errors in guest channels. Consider making it configurable.
        writeEventToFile(
            plugin,
            event,
            errorMarker,
            "error.log",
            intoSubdir: false,
            raw: false,
            errors: true);

        if (plugin.printerSettings.bufferedWrites)
        {
            // Flush error buffer immediately
            flushLog(plugin, plugin.buffers[errorMarker]);
        }
    }

    if (!plugin.printerSettings.logGuestChannels &&
        event.channel.name.length &&
        !plugin.state.bot.homeChannels.canFind(event.channel.name))
    {
        // Not logging all channels and this is not a home.
        return;
    }

    with (IRCEvent.Type)
    switch (event.type)
    {
    case PING:
    case SELFMODE:
        // Not of loggable interest as formatted (raw will have been logged above)
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
                // Log it to channel
                writeEventToFile(plugin, event, channelName);
            }
        }

        if (event.sender.nickname.length)
        {
            if (auto senderBuffer = event.sender.nickname in plugin.buffers)
            {
                // There is an open query buffer; write to it too
                writeEventToFile(plugin, event, event.sender.nickname);

                if (event.type == QUIT)
                {
                    // Flush the buffer if the user quit
                    flushLog(plugin, *senderBuffer);

                    // This would cause extra datestamps on relogins
                    //plugin.buffers.remove(event.sender.nickname);
                }
            }
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
            // Also just noise as formatted
            return;
    }

    default:
        if (event.channel.name.length &&
            (event.sender.nickname.length || (event.type == MODE)))
        {
            // Channel message, or specialcased server-sent MODEs
            writeEventToFile(plugin, event, event.channel.name);
        }
        else if (event.sender.nickname.length)
        {
            // Not a channel; query or other server-wide message
            if (plugin.printerSettings.logPrivateMessages)
            {
                writeEventToFile(plugin, event, event.sender.nickname);
            }
        }
        else if (
            plugin.printerSettings.logServer &&
            !event.sender.nickname.length &&
            event.sender.address.length)
        {
            // Server message
            writeEventToFile(
                plugin,
                event,
                plugin.state.server.address,
                "server.log",
                intoSubdir: false);
        }
        else
        {
            // logServer is probably false and event shouldn't be logged
            // OR we simply don't know how to deal with this event type

            /*import kameloso.prettyprint : prettyprint;
            prettyprint(event);*/
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
    bool locationIsOkay = establishLogLocation(plugin, "~/logs");
    assert("~/logs".isDir);
    ---

    Params:
        logLocation = String of the location directory we want to store logs in.
        naggedAboutDir = Reference bool that will be set to true if we've already
            complained about the log location not being a directory.

    Returns:
        A bool whether or not the log location is valid.
 +/
auto establishLogLocation(const string logLocation, ref bool naggedAboutDir)
{
    import kameloso.string : doublyBackslashed;
    import std.file : exists, isDir;

    if (logLocation.exists)
    {
        if (logLocation.isDir) return true;

        if (!naggedAboutDir)
        {
            enum pattern = "Specified log directory (<l>%s</>) is not a directory.";
            logger.warningf(pattern, logLocation.doublyBackslashed);
            naggedAboutDir = true;
        }

        return false;
    }
    else
    {
        // Create missing log directory
        import std.file : mkdirRecurse;

        mkdirRecurse(logLocation);
        enum pattern = "Created log directory: <i>%s";
        logger.logf(pattern, logLocation.doublyBackslashed);
    }

    return true;
}


// flushAllLogsImpl
/++
    Writes all buffered log lines to disk.

    Merely wraps [flushLog] by iterating over all buffers and invoking it.

    Params:
        plugin = The current [kameloso.plugins.printer.PrinterPlugin|PrinterPlugin].

    See_Also:
        [flushLog]
 +/
void flushAllLogsImpl(PrinterPlugin plugin)
{
    if (!plugin.printerSettings.logs || !plugin.printerSettings.bufferedWrites) return;

    foreach (ref buffer; plugin.buffers)
    {
        flushLog(plugin, buffer);
    }
}


// flushLog
/++
    Writes a single log buffer to disk.

    This is a way of queuing writes so that they can be flushed seldom and
    in bulk, supposedly being nicer to the hardware at the cost of the risk of
    losing unflushed lines in a catastrophical crash.

    Params:
        plugin = The current [kameloso.plugins.printer.PrinterPlugin|PrinterPlugin].
        buffer = [LogLineBuffer] whose lines to flush to disk.

    See_Also:
        [flushAllLogsImpl]
 +/
void flushLog(PrinterPlugin plugin, ref LogLineBuffer buffer)
{
    import kameloso.string : doublyBackslashed;
    import std.exception : ErrnoException;
    import std.file : FileException;
    import std.utf : UTFException;

    if (!buffer.lines[].length) return;

    try
    {
        import std.algorithm.iteration : joiner, map;
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
            // Leave lines in place, to be flushed next time or eventually
            // discarded at a midnight update later
            return;
        }

        // Write all in one go
        auto lines = buffer.lines[]
            .map!sanitize
            .joiner("\n");

        auto file = File(buffer.file, "a");
        file.writeln(lines);

        // If we're here, no exceptions were thrown
        // Only clear if we managed to write everything, otherwise accumulate
        buffer.clear();
    }
    catch (FileException e)
    {
        enum pattern = "File exception caught when flushing log to <l>%s</>: <t>%s%s";
        logger.warningf(pattern, buffer.file.doublyBackslashed, e.msg, plugin.transient.bell);
        version(PrintStacktraces) logger.trace(e.info);
    }
    catch (ErrnoException e)
    {
        version(Posix)
        {
            import kameloso.tables : errnoMap;
            enum pattern = "ErrnoException <l>%s</> caught when flushing log to <l>%s</>: <t>%s%s";
            logger.warningf(
                pattern,
                errnoMap[e.errno],
                buffer.file.doublyBackslashed,
                e.msg,
                plugin.transient.bell);
        }
        else version(Windows)
        {
            enum pattern = "ErrnoException <l>%d</> caught when flushing log to <l>%s</>: <t>%s%s";
            logger.warningf(pattern,
                e.errno,
                buffer.file.doublyBackslashed,
                e.msg,
                plugin.transient.bell);
        }
        else
        {
            static assert(0, "Unsupported platform, please file a bug.");
        }

        version(PrintStacktraces) logger.trace(e.info);
    }
    catch (Exception e)
    {
        enum pattern = "Unexpected exception caught when flushing log <l>%s</>: <t>%s%s";
        logger.warningf(pattern, buffer.file.doublyBackslashed, e.msg, plugin.transient.bell);
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
