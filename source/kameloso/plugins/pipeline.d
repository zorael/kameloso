module kameloso.plugins.pipeline;

version(Posix):

import kameloso.plugins.common;
import kameloso.ircdefs;
import kameloso.common;

import std.concurrency;
import std.experimental.logger : LogLevel, Logger;

import std.stdio;

private:


// pipereader
/++
 +  Reads a fifo (named pipe) and relays lines received there to the main
 +  thread, to send to the server.
 +
 +  It is to be run in a separate thread.
 +
 +  Params:
 +      newState = a shared IRCPluginState, to provide the main thread's Tid
 +                 for concurrency messages.
 +/
void pipereader(shared IRCPluginState newState)
{
    import core.time : seconds;
    import std.file  : FileException, remove;

    auto state = cast(IRCPluginState)newState;

    kameloso.common.settings = state.settings;  // FIXME
    initLogger(state.settings.monochrome, state.settings.brightTerminal);

    /// Named pipe (FIFO) to send messages to the server through
    File fifo;

    try
    {
        fifo = createFIFO(state);
    }
    catch (FileException e)
    {
        logger.error("Failed to create pipeline FIFO: ", e.msg);
        return;
    }
    catch (Exception e)
    {
        logger.error("Unhandled exception creating pipeline FIFO: ", e.msg);
    }

    scope(exit) remove(fifo.name);

    bool halt;

    with (state)
    while (!halt)
    {
        eofLoop:
        while (!fifo.eof)
        {
            foreach (const line; fifo.byLineCopy)
            {
                import kameloso.string : beginsWith;
                import std.string : toLower;

                if (!line.length) break eofLoop;

                if (line.toLower.beginsWith("quit"))
                {
                    if ((line.length > 6) && (line[4..6] == " :"))
                    {
                        mainThread.send(ThreadMessage.Quit(), line[6..$]);
                    }
                    else
                    {
                        mainThread.send(ThreadMessage.Quit());
                    }

                    break eofLoop;
                }
                else
                {
                    mainThread.send(ThreadMessage.Sendline(), line);
                }
            }
        }

        receiveTimeout(0.seconds,
            (ThreadMessage.Teardown)
            {
                halt = true;
            },
            (OwnerTerminated e)
            {
                halt = true;
            },
            (Variant v)
            {
                logger.warning("pipeline received Variant: ", v);
            }
        );

        if (!halt)
        {
            import std.exception : ErrnoException;

            try
            {
                fifo.reopen(fifo.name);
            }
            catch (const ErrnoException e)
            {
                logger.error("Failed to reopen FIFO: ", e.msg);
            }
        }
    }
}


// createFIFO
/++
 +  Creates a fifo (named pipe) in the filesystem.
 +
 +  It will be named a hardcoded <bot nickname>@<server address>.
 +/
File createFIFO(const IRCPluginState state)
{
    import kameloso.bash : BashForeground, BashReset, colour;
    import std.array : Appender;
    import std.file : FileException, exists, isDir;
    import std.format : format;
    import std.process : execute;

    immutable filename = state.bot.nickname ~ "@" ~ state.bot.server.address;

    if (!filename.exists)
    {
        immutable mkfifo = execute([ "mkfifo", filename ]);

        if (mkfifo.status != 0)
        {
            throw new FileException("Could not create FIFO (mkfio returned %d)"
                .format(mkfifo));
        }
    }
    else if (filename.isDir)
    {
        throw new FileException("Wanted to create FIFO %s but a directory " ~
            "exists with the same name"
            .format(filename));
    }

    version(Colours)
    {
        if (!state.settings.monochrome)
        {
            Appender!string sink;
            sink.reserve(128);  // ~96

            immutable BashForeground[] logcolours = state.settings.monochrome ?
                KamelosoLogger.logcoloursBright : KamelosoLogger.logcoloursDark;

            sink.colour(logcolours[LogLevel.info]);
            sink.put("Pipe text to [");
            sink.colour(logcolours[LogLevel.all]);
            sink.put(filename);
            sink.colour(logcolours[LogLevel.info]);
            sink.put("] to send raw commands to the server.");
            sink.colour(BashReset.all);

            logger.trace(sink.data);
        }
        else
        {
            logger.infof("Pipe text to [%s] to send raw commands to the server",
                filename);
        }
    }
    else
    {
        logger.infof("Pipe text to [%s] to send raw commands to the server",
            filename);
    }

    return File(filename, "r");
}


// onWelcome
/++
 +  Spawns the pipereader thread.
 +/
@(IRCEvent.Type.RPL_WELCOME)
void onWelcome(PipelinePlugin plugin, const IRCEvent event)
{
    plugin.fifoThread = spawn(&pipereader, cast(shared)plugin.state);
}


// teardown
/++
 +  Deinitialises the Pipeline plugin. Shuts down the pipereader thread.
 +/
void teardown(IRCPlugin basePlugin)
{
    import std.file  : exists, isDir;

    auto plugin = cast(PipelinePlugin)basePlugin;

    with (plugin)
    with (plugin.state)
    {
        import std.concurrency : Tid;

        if (fifoThread == Tid.init) return;

        fifoThread.send(ThreadMessage.Teardown());
        fifoThread = Tid.init;

        immutable filename = bot.nickname ~ "@" ~ bot.server.address;

        if (filename.exists && !filename.isDir)
        {
            // Tell the reader of the pipe to exit
            auto fifo = File(filename, "w");
            fifo.writeln();
            fifo.flush();
        }
    }
}


public:


// Pipeline
/++
 +  The Pipeline plugin reads from a local named pipe (FIFO) for messages to
 +  send to the server. It is for debugging purposes until such time we figure
 +  out a way to properly input lines via the terminal.
 +/
final class PipelinePlugin : IRCPlugin
{
    /// Thread ID of the thread reading the named pipe
    Tid fifoThread;

    mixin IRCPluginImpl;
}
