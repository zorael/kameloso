/++
 +  The Pipeline plugin opens a Posix named pipe in the current directory, to
 +  which you can pipe text and have it be sent verbatim to the server.
 +
 +  It has no commands; indeed, it doesn't listen to
 +  `kameloso.irc.defs.IRCEvent`s at all, only to what is sent to it via the
 +  named FIFO pipe.
 +
 +  This requires version `Posix`, which is true for UNIX-like systems (like
 +  Linux and OSX).
 +
 +  It is very optional.
 +/
module kameloso.plugins.pipeline;

version(WithPlugins):
version(Posix):

private:

import kameloso.common;
import kameloso.thread : ThreadMessage;
import kameloso.plugins.common;
import kameloso.irc.defs;
import kameloso.messaging;

import std.concurrency;
import std.stdio : File;


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
 +      filename = String filename if the fifo to read from.
 +/
void pipereader(shared IRCPluginState newState, const string filename)
{
    import std.file : FileException, remove;

    auto state = cast()newState;

    string infotint, logtint;

    version(Colours)
    {
        if (!settings.monochrome)
        {
            import kameloso.terminal : colour;
            import kameloso.constants : DefaultColours;
            import std.experimental.logger : LogLevel;

            // We don't have a logger instance so we have to access the
            // DefaultColours.logcolours{Bright,Dark} tables manually

            if (settings.brightTerminal)
            {
                infotint = DefaultColours.logcoloursBright[LogLevel.info].colour;
                logtint = DefaultColours.logcoloursBright[LogLevel.all].colour;
            }
            else
            {
                infotint = DefaultColours.logcoloursDark[LogLevel.info].colour;
                logtint = DefaultColours.logcoloursDark[LogLevel.all].colour;
            }
        }
    }

    import std.format : format;
    state.askToLog("Pipe text to the [%s%s%s] file to send raw commands to the server."
        .format(infotint, filename, logtint));

    // Creating the File struct blocks, so do it after reporting.
    File fifo = File(filename, "r");
    scope(exit) remove(filename);

    bool halt;

    while (!halt)
    {
        eofLoop:
        while (!fifo.eof)
        {
            foreach (immutable line; fifo.byLineCopy)
            {
                import kameloso.messaging : raw, quit;
                import kameloso.string : beginsWith;
                import std.format : format;
                import std.uni : toLower;

                if (!line.length) break eofLoop;

                debug
                {
                    if (line[0] == ':')
                    {
                        import kameloso.string : has, nom;
                        import kameloso.thread : ThreadMessage, busMessage;

                        if (line.has(' '))
                        {
                            string slice = line[1..$];
                            immutable header = slice.nom(' ');
                            state.mainThread.send(ThreadMessage.BusMessage(),
                                header, busMessage(slice));
                        }
                        else
                        {
                            state.mainThread.send(ThreadMessage.BusMessage(), line[1..$]);
                        }
                        break eofLoop;
                    }
                }

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
                }
                else
                {
                    state.raw(line);
                }

                break eofLoop;
            }
        }

        import core.time : seconds;
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
                state.askToWarn("pipeline received Variant: " ~ v.toString());
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
                state.askToError("Failed to reopen FIFO: " ~ e.msg);
            }
        }
    }
}


// createFIFO
/++
 +  Creates a FIFO (named pipe) in the filesystem.
 +
 +  It will be named a passed filename.
 +
 +  Params:
 +      state = String filename of FIFO to create.
 +
 +  Throws:
 +      `std.file.FileException` if FIFO could not be created.
 +      `kameloso.plugins.pipeline.FIFOAlreadyExistsException` if a fifo with
 +          the same filename already exists.
 +/
void createFIFO(const string filename)
{
    import std.file : FileException, exists, isDir;
    import std.format : format;

    if (!filename.exists)
    {
        import std.process : execute;

        immutable mkfifo = execute([ "mkfifo", filename ]);

        if (mkfifo.status != 0)
        {
            throw new FileException("Could not create FIFO (mkfifo returned %d)".format(mkfifo.status));
        }
    }
    else if (filename.isDir)
    {
        throw new FileException(("Wanted to create FIFO %s but a directory " ~
            "exists with the same name").format(filename));
    }
    else /* if (filename.isFile || filename.isSymlink) */
    {
        throw new FIFOAlreadyExistsException(filename ~ " already exists");
    }
}


// onWelcome
/++
 +  Spawns the pipereader thread.
 +
 +  Snapshots the filename to use, as we base it on the bot's nickname, which
 +  may change during the connection's lifetime.
 +/
@(IRCEvent.Type.RPL_WELCOME)
void onWelcome(PipelinePlugin plugin)
{
    with (plugin)
    {
        // Save the filename *once* so it persists across nick changes.
        fifoFilename = state.client.nickname ~ "@" ~ state.client.server.address;
        createFIFO(fifoFilename);

        fifoThread = spawn(&pipereader, cast(shared)state, fifoFilename);
    }
}


// teardown
/++
 +  Deinitialises the Pipeline plugin. Shuts down the pipereader thread.
 +/
void teardown(PipelinePlugin plugin)
{
    import std.file : exists, isDir;
    import std.concurrency : Tid;

    if (plugin.fifoThread == Tid.init) return;

    plugin.fifoThread.send(ThreadMessage.Teardown());
    plugin.fifoThread = Tid.init;

    if (plugin.fifoFilename.exists && !plugin.fifoFilename.isDir)
    {
        // Tell the reader of the pipe to exit
        auto fifo = File(plugin.fifoFilename, "w");
        fifo.writeln();
    }
}


// FIFOAlreadyExistsException
/++
 +  Exception, to be thrown when attempting to create a named FIFO pipe and
 +  finding that it already exists.
 +/
final class FIFOAlreadyExistsException : Exception
{
    /// Creates a new `FIFOAlreadyExistsException`.
    this(const string message, const string file = __FILE__, const size_t line = __LINE__) pure
    {
        super(message, file, line);
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

    /// Filename of the created FIFO.
    string fifoFilename;

    mixin IRCPluginImpl;
}
