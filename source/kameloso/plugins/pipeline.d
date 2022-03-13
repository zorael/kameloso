/++
    The Pipeline plugin opens a Posix named pipe in the current directory, to
    which you can pipe text and have it be sent verbatim to the server.

    It has no commands; indeed, it doesn't listen to
    [dialect.defs.IRCEvent|IRCEvent]s at all, only to what is sent to it via the
    named FIFO pipe.

    This requires version `Posix`, which is true for UNIX-like systems (like
    Linux and macOS).

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#pipeline
        [kameloso.plugins.common.core|plugins.common.core]
        [kameloso.plugins.common.misc|plugins.common.misc]
 +/
module kameloso.plugins.pipeline;

version(Posix):
version(WithPipelinePlugin):

private:

import kameloso.plugins.common.core;
import kameloso.common : expandTags, logger;
import kameloso.logger : LogLevel;
import kameloso.messaging;
import dialect.defs;
import std.typecons : Flag, No, Yes;


/+
    For storage location of the FIFO it makes sense to default to /tmp;
    Posix defines a variable $TMPDIR, which should take precedence.
    However, this supposedly makes the file really difficult to access on macOS
    where it translates to some really long, programmatically generated path.
    macOS naturally does support /tmp though. So shrug and version it to
    default-ignore $TMPDIR on macOS but obey it on other platforms.
 +/
//version = OSXTMPDIR;


// PipelineSettings
/++
    All settings for a [PipelinePlugin], aggregated.
 +/
@Settings struct PipelineSettings
{
private:
    import lu.uda : Unserialisable;

public:
    /// Whether or not the Pipeline plugin should do anything at all.
    @Enabler bool enabled = true;

    /++
        Whether or not to place the FIFO in the working directory. If false, it
        will be saved in `/tmp` or wherever `$TMPDIR` points. If macOS, then there
        only if version `OSXTMPDIR`.
     +/
    bool fifoInWorkingDir = false;

    /// Custom, full path to use as FIFO filename, specified with --set pipeline.path.
    @Unserialisable string path;
}


// pipereader
/++
    Reads a FIFO (named pipe) and relays lines received there to the main
    thread, to send to the server.

    It is to be run in a separate thread.

    Params:
        newState = The [kameloso.plugins.common.core.IRCPluginState|IRCPluginState]
            of the original [PipelinePlugin], to provide the main thread's
            [core.thread.Tid|Tid] for concurrency messages, made `shared` to
            allow being sent between threads.
        filename = String filename of the FIFO to read from.
 +/
void pipereader(shared IRCPluginState newState,
    const string filename)
in (filename.length, "Tried to set up a pipereader with an empty filename")
{
    import kameloso.thread : ThreadMessage;
    import std.concurrency : OwnerTerminated, receiveTimeout, send;
    import std.file : exists, remove;
    import std.format : format;
    import std.stdio : File;
    import std.variant : Variant;
    static import kameloso.common;

    version(Posix)
    {
        import kameloso.thread : setThreadName;
        setThreadName("pipeline");
    }

    auto state = cast()newState;

    // Set the global settings so messaging functions don't segfault us
    kameloso.common.settings = &state.settings;

    // Creating the File struct blocks, so do it after reporting.
    enum pattern = "Pipe text to the <i>%s</> file to send raw commands to the server.";
    state.askToLog(pattern.format(filename));

    File fifo = File(filename, "r");
    scope(exit) if (filename.exists) remove(filename);

    toploop:
    while (true)
    {
        // foreach but always break after processing one line, to be responsive
        // and retaining the ability to break out of it.
        foreach (immutable line; fifo.byLineCopy)
        {
            import kameloso.messaging : raw, quit;
            import std.algorithm.searching : startsWith;
            import std.uni : asLowerCase;

            if (!line.length) break;

            if (line[0] == ':')
            {
                import kameloso.thread : sendable;
                import lu.string : contains, nom;

                if (line.contains(' '))
                {
                    string slice = line[1..$];
                    immutable header = slice.nom(' ');
                    state.mainThread.send(ThreadMessage.busMessage(header, sendable(slice)));
                }
                else
                {
                    state.mainThread.send(ThreadMessage.busMessage(line[1..$]));
                }
                break;
            }

            if (line.asLowerCase.startsWith("quit"))
            {
                if ((line.length > 6) && (line[4..6] == " :"))
                {
                    quit(state, line[6..$]);
                }
                else
                {
                    quit(state);
                }
                break toploop;
            }
            else
            {
                raw(state, line);
            }
            break;
        }

        import kameloso.thread : sendable;
        import core.time : Duration;

        static immutable instant = Duration.zero;
        bool halt;

        cast(void)receiveTimeout(instant,
            (ThreadMessage message)
            {
                if (message.type == ThreadMessage.Type.teardown)
                {
                    halt = true;
                }
            },
            (OwnerTerminated e)
            {
                halt = true;
            },
            (Variant v)
            {
                enum variantPattern = "Pipeline plugin received Variant: <l>%s";
                state.askToError(variantPattern.format(v.toString));
                state.mainThread.send(ThreadMessage.busMessage("pipeline", sendable("halted")));
                halt = true;
            }
        );

        if (halt) break toploop;

        import std.exception : ErrnoException;

        try
        {
            fifo.reopen(filename);
        }
        catch (ErrnoException e)
        {
            enum fifoPattern = "Pipeline plugin failed to reopen FIFO: <l>%s";
            state.askToError(fifoPattern.format(e.msg));
            version(PrintStacktraces) state.askToTrace(e.info.toString);
            state.mainThread.send(ThreadMessage.busMessage("pipeline", sendable("halted")));
            break toploop;
        }
        catch (Exception e)
        {
            state.askToError("Pipeline plugin saw unexpected exception");
            version(PrintStacktraces) state.askToTrace(e.toString);
            break toploop;
        }
    }
}


// createFIFO
/++
    Creates a FIFO (named pipe) in the filesystem.

    It will be named a passed filename.

    Params:
        filename = String filename of FIFO to create.

    Throws:
        [kameloso.common.ReturnValueException|ReturnValueException] if the FIFO
        could not be created.

        [kameloso.common.FileExistsException|FileExistsException] if a FIFO with
        the same filename already exists, suggesting concurrent conflicting
        instances of the program (or merely a zombie FIFO after a crash).

        [kameloso.common.FileTypeMismatchException|FileTypeMismatchException] if a file or directory
        exists with the same name as the FIFO we want to create.
 +/
void createFIFO(const string filename)
in (filename.length, "Tried to create a FIFO with an empty filename")
{
    import lu.common : FileExistsException, FileTypeMismatchException, ReturnValueException;
    import std.file : exists;

    if (!filename.exists)
    {
        import std.process : execute;

        immutable mkfifo = execute([ "mkfifo", filename ]);

        if (mkfifo.status != 0)
        {
            throw new ReturnValueException("Could not create FIFO", "mkfifo", mkfifo.status);
        }
    }
    else
    {
        import std.file : getAttributes, isDir;
        import core.sys.posix.sys.stat : S_ISFIFO;

        immutable attrs = cast(ushort)getAttributes(filename);

        if (S_ISFIFO(attrs))
        {
            throw new FileExistsException("A FIFO with that name already exists",
                filename, __FILE__, __LINE__);
        }
        else
        {
            throw new FileTypeMismatchException("Wanted to create a FIFO but a file or "
                ~ "directory with the desired name already exists",
                filename, attrs, __FILE__, __LINE__);
        }
    }
}


// onWelcome
/++
    Initialises the fifo pipe and thus the purpose of the plugin, by leveraging [initPipe].
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WELCOME)
)
void onWelcome(PipelinePlugin plugin)
{
    plugin.initPipe();
}


// reload
/++
    Reloads the plugin, initialising the fifo pipe if it was not already initialised.

    This lets us remedy the "A FIFO with that name already exists" error.
 +/
void reload(PipelinePlugin plugin)
{
    if (!plugin.workerRunning)
    {
        plugin.initPipe();
    }
}


// initPipe
/++
    Spawns the pipereader thread.

    Snapshots the filename to use, as we base it on the bot's nickname, which
    may change during the connection's lifetime.

    Params:
        plugin = The current [PipelinePlugin].
 +/
void initPipe(PipelinePlugin plugin)
in (!plugin.workerRunning, "Tried to double-initialise the pipereader")
{
    if (plugin.pipelineSettings.path.length)
    {
        // Custom filename specified with --set pipeline.path=xyz
        plugin.fifoFilename = plugin.pipelineSettings.path;
    }
    else
    {
        import std.conv : text;

        // Save the filename *once* so it persists across nick changes.
        // If !fifoInWorkingDir then in /tmp or $TMPDIR
        plugin.fifoFilename = text(plugin.state.client.nickname, '@', plugin.state.server.address);

        if (!plugin.pipelineSettings.fifoInWorkingDir)
        {
            // See notes at the top of module.
            version(OSX)
            {
                version(OSXTMPDIR)
                {
                    enum useTMPDIR = true;
                }
                else
                {
                    enum useTMPDIR = false;
                }
            }
            else // Implicitly not Windows since Posix-only plugin
            {
                enum useTMPDIR = true;
            }

            static if (useTMPDIR)
            {
                import std.process : environment;
                immutable tempdir = environment.get("TMPDIR", "/tmp");
            }
            else
            {
                enum tempdir = "/tmp";
            }

            import std.path : buildNormalizedPath;
            plugin.fifoFilename = buildNormalizedPath(tempdir, plugin.fifoFilename);
        }
    }

    import lu.common : FileExistsException, FileTypeMismatchException, ReturnValueException;

    try
    {
        import std.concurrency : spawn;

        createFIFO(plugin.fifoFilename);
        plugin.fifoThread = spawn(&pipereader, cast(shared)plugin.state, plugin.fifoFilename);
        plugin.workerRunning = true;
    }
    catch (ReturnValueException e)
    {
        enum pattern = "Failed to initialise the Pipeline plugin: <l>%s</> (<l>%s</> returned <l>%d</>)";
        logger.warningf(pattern.expandTags(LogLevel.warning), e.msg, e.command, e.retval);
        //version(PrintStacktraces) logger.trace(e.info);
    }
    catch (FileExistsException e)
    {
        enum pattern = "Failed to initialise the Pipeline plugin: <l>%s</> [<l>%s</>]";
        logger.warningf(pattern.expandTags(LogLevel.warning), e.msg, e.filename);
        //version(PrintStacktraces) logger.trace(e.info);
    }
    catch (FileTypeMismatchException e)
    {
        enum pattern = "Failed to initialise the Pipeline plugin: <l>%s</> [<l>%s</>]";
        logger.warningf(pattern.expandTags(LogLevel.warning), e.msg, e.filename);
        //version(PrintStacktraces) logger.trace(e.info);
    }

    // Let other Exceptions pass
}


// teardown
/++
    De-initialises the Pipeline plugin. Shuts down the pipereader thread.
 +/
void teardown(PipelinePlugin plugin)
{
    import kameloso.thread : ThreadMessage;
    import std.concurrency : send;
    import std.file : exists, isDir;
    import std.stdio : File;

    if (!plugin.workerRunning) return;

    plugin.fifoThread.send(ThreadMessage.teardown());

    if (plugin.fifoFilename.exists && !plugin.fifoFilename.isDir)
    {
        // Tell the reader of the pipe to exit
        auto fifo = File(plugin.fifoFilename, "w");
        fifo.writeln();
    }
}


import kameloso.thread : Sendable;

// onBusMessage
/++
    Receives a passed [kameloso.thread.BusMessage|BusMessage] with the "`pipeline`" header,
    and performs actions based on the payload message.

    This is used to let the worker thread signal the main context that it halted.

    Params:
        plugin = The current [PipelinePlugin].
        header = String header describing the passed content payload.
        content = Message content.
 +/
void onBusMessage(PipelinePlugin plugin, const string header, shared Sendable content)
{
    if (!plugin.isEnabled) return;
    if (header != "pipeline") return;

    import kameloso.thread : BusMessage;

    auto message = cast(BusMessage!string)content;
    assert(message, "Incorrectly cast message: " ~ typeof(message).stringof);

    if (message.payload == "halted")
    {
        plugin.workerRunning = false;
    }
    else
    {
        logger.error("[pipeline] Unimplemented bus message verb: <i>", message.payload);
    }
}


public:


// PipelinePlugin
/++
    The Pipeline plugin reads from a local named pipe (FIFO) for messages to
    send to the server, as well as to live-control the bot to a certain degree.
 +/
final class PipelinePlugin : IRCPlugin
{
private:
    import std.concurrency : Tid;

    /// All Pipeline settings gathered.
    PipelineSettings pipelineSettings;

    /// Thread ID of the thread reading the named pipe.
    Tid fifoThread;

    /// Filename of the created FIFO.
    string fifoFilename;

    /// Whether or not the worker is running in the background.
    bool workerRunning;

    mixin IRCPluginImpl;
}
