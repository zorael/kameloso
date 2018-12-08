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
 +/
void pipereader(shared IRCPluginState newState)
{
    import std.file : FileException, remove;

    auto state = cast()newState;

    /// Named pipe (FIFO) to send messages to the server through.
    File fifo;

    try
    {
        fifo = createFIFO(state);
    }
    catch (const FileException e)
    {
        state.askToError("Failed to create pipeline FIFO: " ~ e.msg);
        return;
    }
    catch (const FIFOAlreadyExistsException e)
    {
        state.askToError("Failed to create pipeline FIFO: " ~ e.msg);
        return;
    }
    catch (const Exception e)
    {
        state.askToError("Unhandled exception creating pipeline FIFO: " ~ e.msg);
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
 +/
@(IRCEvent.Type.RPL_WELCOME)
void onWelcome(PipelinePlugin plugin)
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
    import std.concurrency : Tid;

    if (plugin.fifoThread == Tid.init) return;

    plugin.fifoThread.send(ThreadMessage.Teardown());
    plugin.fifoThread = Tid.init;

    immutable filename = plugin.state.client.nickname ~ "@" ~ plugin.state.client.server.address;

    if (filename.exists && !filename.isDir)
    {
        // Tell the reader of the pipe to exit
        auto fifo = File(filename, "w");
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
