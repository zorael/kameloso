/++
 +  The Pipeline plugin opens a Posix named pipe in the current directory, to
 +  which you can pipe text and have it be sent verbatim to the server.
 +
 +  It has no commands; indeed, it doesn't listen to
 +  `kameloso.ircdefs.IRCEvent`s at all, only to what is sent to it via the
 +  named FIFO pipe.
 +
 +  This requires version `Posix`, which is true for UNIX-like systems (like
 +  Linux and OSX).
 +
 +  It is very optional.
 +/
module kameloso.plugins.pipeline;

version(Posix):

import kameloso.common : ThreadMessage;
import kameloso.plugins.common;
import kameloso.ircdefs;

import std.concurrency;
import std.stdio : File;

private:


// pipereader
/++
 +  Reads a FIFO (named pipe) and relays lines received there to the main
 +  thread, to send to the server.
 +
 +  It is to be run in a separate thread.
 +
 +  Params:
 +      newState = The `kameloso.plugins.common.IRCPluginState` of the original
 +          `PipelinePlugin`, to provide the main thread's `core.thread.Tid` for
 +          concurrency messages, made `shared` to allow being sent between
 +          threads.
 +/
void pipereader(shared IRCPluginState newState)
{
    import kameloso.messaging : raw, quit;
    import core.time : seconds;
    import std.file : FileException, remove;

    auto state = cast(IRCPluginState)newState;

    /// Named pipe (FIFO) to send messages to the server through.
    File fifo;

    try
    {
        fifo = createFIFO(state);
    }
    catch (const FileException e)
    {
        state.mainThread.send(ThreadMessage.TerminalOutput.Error(),
            "Failed to create pipeline FIFO: " ~ e.msg);
        return;
    }
    catch (const Exception e)
    {
        state.mainThread.send(ThreadMessage.TerminalOutput.Error(),
            "Unhandled exception creating pipeline FIFO: " ~ e.msg);
        return;
    }

    scope(exit) remove(fifo.name);

    bool halt;

    with (state)
    while (!halt)
    {
        eofLoop:
        while (!fifo.eof)
        {
            foreach (immutable line; fifo.byLineCopy)
            {
                import kameloso.string : beginsWith;
                import std.format : format;
                import std.string : toLower;

                if (!line.length) break eofLoop;

                if (line.toLower.beginsWith("quit"))
                {
                    if ((line.length > 6) && (line[4..6] == " :"))
                    {
                        state.quit(line[6..$]);
                    }
                    else
                    {
                        state.quit();
                    }

                    break eofLoop;
                }
                else
                {
                    state.raw(line);
                }
            }
        }

        static immutable instant = 0.seconds;

        receiveTimeout(instant,
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
                mainThread.send(ThreadMessage.TerminalOutput.Warning(),
                    "pipeline received Variant: " ~ v.toString());
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
                mainThread.send(ThreadMessage.TerminalOutput.Error(),
                    "Failed to reopen FIFO: " ~ e.msg);
            }
        }
    }
}


// createFIFO
/++
 +  Creates a FIFO (named pipe) in the filesystem.
 +
 +  It will be named a hardcoded [bot nickname]@[server address].
 +
 +  Params:
 +      state = The `kameloso.plugins.common.IRCPluginState` of the
 +          original `PipelinePlugin`.
 +
 +  Returns:
 +      A `std.stdio.File` repersenting the named FIFO we want to read from.
 +/
File createFIFO(IRCPluginState state)
{
    import std.file : FileException, exists, isDir;
    import std.format : format;
    import std.process : execute;

    immutable filename = state.bot.nickname ~ "@" ~ state.bot.server.address;

    if (!filename.exists)
    {
        immutable mkfifo = execute([ "mkfifo", filename ]);

        if (mkfifo.status != 0)
        {
            throw new FileException("Could not create FIFO (mkfio returned %d)".format(mkfifo));
        }
    }
    else if (filename.isDir)
    {
        throw new FileException("Wanted to create FIFO %s but a directory " ~
            "exists with the same name".format(filename));
    }

    string infotint, logtint;

    version(Colours)
    {
        if (!state.settings.monochrome)
        {
            import kameloso.bash : colour;
            import kameloso.logger : KamelosoLogger;
            import std.experimental.logger : LogLevel;

            infotint = KamelosoLogger.tint(LogLevel.info, settings.brightTerminal).colour;
            logtint = KamelosoLogger.tint(LogLevel.all, settings.brightTerminal).colour;
        }
    }

    state.mainThread.send(ThreadMessage.TerminalOutput.Log(),
        "Pipe text to %s%s%s to send raw commands to the server."
        .format(infotint.colour, filename, logtint.colour));

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
void teardown(PipelinePlugin plugin)
{
    import std.file : exists, isDir;

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
        }
    }
}


public:


// Pipeline
/++
 +  The Pipeline plugin reads from a local named pipe (FIFO) for messages to
 +  send to the server.
 +
 +  It is for debugging purposes until such time we figure out a way to properly
 +  input lines via the terminal.
 +/
final class PipelinePlugin : IRCPlugin
{
    /// Thread ID of the thread reading the named pipe.
    Tid fifoThread;

    mixin IRCPluginImpl;
}
