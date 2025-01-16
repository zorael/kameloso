/++
    The Pipeline plugin opens a Posix named pipe in a temporary directory or
    the current directory, to which you can pipe text and have it be sent
    verbatim to the server. There is also syntax to manually send bus messages
    to plugins.

    It has no commands; it doesn't listen to [dialect.defs.IRCEvent|IRCEvent]s
    at all, only to what is sent to it via the named FIFO pipe.

    This requires version `Posix`, which is true for UNIX-like systems (like
    Linux and macOS).

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#pipeline,
        [kameloso.plugins.common],
        [kameloso.plugins.common.misc]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.pipeline;

version(Posix):
version(WithPipelinePlugin):

private:

import kameloso.plugins;
import kameloso.plugins.common;
import kameloso.common : logger;
import dialect.defs;
import core.time : Duration;


/+
    For storage location of the FIFO it makes sense to default to /tmp;
    Posix defines a variable `$TMPDIR`, which should take precedence.
    However, this supposedly makes the file really difficult to access on macOS
    where it translates to some really long, programmatically generated path.
    macOS naturally does support /tmp though. So shrug and version it to
    default-ignore `$TMPDIR` on macOS but obey it on other platforms.
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
    /++
        Whether or not the Pipeline plugin should do anything at all.
     +/
    @Enabler bool enabled = true;

    /++
        Whether or not to place the FIFO in the working directory. If false, it
        will be saved in `/tmp` or wherever `$TMPDIR` points. If macOS, then there
        only if version `OSXTMPDIR`.
     +/
    bool fifoInWorkingDir = false;

    /++
        Custom path to use as FIFO filename, specified with `--set pipeline.path=[...]`.
     +/
    @Unserialisable string path;
}


// onWelcome
/++
    Does three things upon [dialect.defs.IRCEvent.Type.RPL_WELCOME|RPL_WELCOME];

    1. Sets up the FIFO pipe, resolving the filename and creating it.
    2. Prints the usage text.
    3. Lastly, endlessly loops (as a [core.thread.fiber.Fiber|Fiber]) and checks once per
       hour if the FIFO has disappeared, and recreates it if so. This is to allow
       for recovery from the FIFO being deleted.

    Initialises the FIFO *here*, where we know our nickname (we don't in .initialise).
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WELCOME)
    .fiber(true)
)
void onWelcome(PipelinePlugin plugin)
{
    import kameloso.plugins.common.scheduling : delay;
    import lu.common : ReturnValueException;
    import core.time : minutes;

    void initRoutine()
    {
        plugin.transient.fifoFilename = initialiseFIFO(plugin);
        plugin.transient.fd = openFIFO(plugin.transient.fifoFilename);
        printUsageText(plugin, reinit: false);
    }

    try
    {
        initRoutine();
    }
    catch (ReturnValueException e)
    {
        enum pattern = "The <l>Pipeline</> plugin failed to start up: <l>%s";
        logger.errorf(pattern, e.msg);
        //return;
    }

    // Check once per minute is the FIFO has disappeared and recreate it if so
    static immutable discoveryPeriod = 1.minutes;

    // Delay once before entering loop
    delay(plugin, discoveryPeriod, yield: true);

    while (true)
    {
        import std.file : exists;

        if (!plugin.transient.fifoFilename.exists || !plugin.transient.fifoFilename.isFIFO)
        {
            if (plugin.transient.fd != -1) closeFD(plugin.transient.fd);

            try
            {
                initRoutine();
            }
            catch (Exception _)
            {
                // Gag errors
            }
        }

        delay(plugin, discoveryPeriod, yield: true);
    }
}


// printUsageText
/++
    Prints the usage text to screen.

    Params:
        plugin = The current [PipelinePlugin].
        reinit = Whether or not the FIFO disappeared and was recreated.
 +/
void printUsageText(PipelinePlugin plugin, const bool reinit)
{
    if (reinit)
    {
        enum message = "Pipeline FIFO disappeared, recreating.";
        logger.warning(message);
    }

    enum pattern = "Pipe text to the <i>%s</> file to send raw commands to the server.";
    logger.logf(pattern, plugin.transient.fifoFilename);
}


// resolvePath
/++
    Resolves the filename of the FIFO to use.

    Params:
        plugin = The current [PipelinePlugin].

    Returns:
        A filename to use for the FIFO.

    Throws:
        [lu.common.FileExistsException|FileExistsException] if a FIFO with
        the same filename already exists, suggesting concurrent conflicting
        instances of the program (or merely a zombie FIFO after a crash),
        and a new filename could not be invented.

        [lu.common.FileTypeMismatchException|FileTypeMismatchException] if a file or directory
        exists with the same name as the FIFO we want to create, and a new
        filename could not be invented.
 +/
auto resolvePath(PipelinePlugin plugin)
{
    import std.file : exists;

    string filename;  // mutable

    if (plugin.pipelineSettings.path.length)
    {
        filename = plugin.pipelineSettings.path;
    }
    else
    {
        import std.conv : text;
        import std.path : buildNormalizedPath;

        filename = text(plugin.state.client.nickname, '@', plugin.state.server.address);

        if (!plugin.pipelineSettings.fifoInWorkingDir)
        {
            // See notes at the top of the module.
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

            filename = buildNormalizedPath(tempdir, filename);
        }
    }

    if (filename.exists)
    {
        import std.string : succ;

        filename ~= "-1";

        while (filename.exists)
        {
            filename = filename.succ;

            if (filename[$-2..$] == "-0")
            {
                filename = filename[0..$-2] ~ "-10";
            }
            else if (filename[$-3..$] == "-00")  // beyond -99
            {
                import lu.common : FileExistsException, FileTypeMismatchException;
                import core.sys.posix.sys.stat : S_ISFIFO;

                // Don't infinitely loop, should realistically never happen though
                enum message = "Failed to find a suitable FIFO filename";

                if (filename.isFIFO)
                {
                    throw new FileExistsException(
                        message,
                        filename,
                        __FILE__,
                        __LINE__);
                }
                else
                {
                    import std.file : getAttributes;
                    throw new FileTypeMismatchException(
                        message,
                        filename,
                        cast(ushort)getAttributes(filename),
                        __FILE__,
                        __LINE__);
                }
            }
        }
    }

    return filename;
}


// initialiseFIFO
/++
    Initialises the FIFO.

    Params:
        plugin = The current [PipelinePlugin].

    Returns:
        Filename of the newly-created FIFO pipe.
 +/
auto initialiseFIFO(PipelinePlugin plugin)
{
    immutable filename = resolvePath(plugin);
    createFIFOFile(filename);
    return filename;
}


// createFIFOFile
/++
    Creates a FIFO (named pipe) in the filesystem.

    It will be named a passed filename.

    Params:
        filename = String filename of FIFO to create.

    Throws:
        [lu.common.ReturnValueException|ReturnValueException] if the FIFO
        could not be created.
 +/
void createFIFOFile(const string filename)
in (filename.length, "Tried to create a FIFO with an empty filename")
{
    import lu.common : ReturnValueException;
    import std.process : execute;

    // Try more than once in case there are competing instances of the program
    enum numRetries = 5;

    foreach (immutable i; 0..numRetries)
    {
        immutable mkfifo = execute([ "mkfifo", filename ]);
        if (mkfifo.status == 0) return;

        if (i == (numRetries-1))
        {
            // Last try, give up
            enum message = "Could not create FIFO";
            throw new ReturnValueException(
                message,
                "mkfifo",
                mkfifo.status);
        }
    }
}


// openFIFO
/++
    Opens a FIFO for reading. The file descriptor is set to non-blocking.

    Params:
        filename = The filename of the FIFO to open.

    Returns:
        The file descriptor of the opened FIFO.
 +/
auto openFIFO(const string filename)
in (filename.length, "Tried to open a FIFO with an empty filename")
{
    import std.string : toStringz;
    import core.sys.posix.fcntl : O_NONBLOCK, O_RDONLY, open;

    return open(filename.toStringz, (O_NONBLOCK | O_RDONLY));
}


// closeFD
/++
    Closes a file descriptor.

    Params:
        fd = The file descriptor to close. Taken by `ref` and set to -1 afterwards.

    Returns:
        The return value of the close() system call.
 +/
auto closeFD(ref int fd)
in ((fd != -1), "Tried to close an invalid file descriptor")
{
    import core.sys.posix.unistd;

    scope(exit) fd = -1;
    return close(fd);
}


// isFIFO
/++
    Checks if a file is a FIFO.

    Params:
        filename = The filename to check.

    Returns:
        `true` if it is; `false` otherwise.
 +/
auto isFIFO(const string filename)
{
    import std.file : getAttributes;
    import core.sys.posix.sys.stat : S_ISFIFO;

    immutable attrs = cast(ushort)getAttributes(filename);
    return S_ISFIFO(attrs);
}


// readFIFO
/++
    Reads from the FIFO and leaves a message for the main event loop based upon what was read.
    If something was indeed read, `true` is returned to signal to the caller that
    it should check for new messages.

    Params:
        plugin = The current [PipelinePlugin].

    Returns:
        `true` if messages were sent and should be read by other parts of the
        program; `false` if not.
 +/
auto readFIFO(PipelinePlugin plugin)
{
    import kameloso.constants : BufferSize;
    import std.algorithm.iteration : splitter;
    import core.sys.posix.unistd : read;

    static ubyte[] buf;
    if (!buf.length) buf = new ubyte[BufferSize.socketOptionSend];

    immutable ptrdiff_t bytesRead = read(plugin.transient.fd, buf.ptr, buf.length);
    if (bytesRead <= 0) return false;   // 0 or -1

    string slice = cast(string)buf[0..bytesRead].idup;  // mutable immutable
    bool shouldCheckMessages;

    foreach (immutable originalLine; slice.splitter("\n"))
    {
        import kameloso.thread : ThreadMessage, boxed;
        import lu.string : strippedLeft;

        string line = originalLine.strippedLeft;  // mutable
        if (!line.length) continue;

        if (line[0] == '#')
        {
            import lu.string : advancePast;

            // Bus message
            line = line[1..$];  // skip the octothorpe
            immutable header = line.advancePast(' ', inherit: true);
            if (!header.length) continue;

            plugin.state.messages ~= ThreadMessage.busMessage(header, boxed(line));
        }
        else if (line[0] == '<')
        {
            // Faked event
            plugin.state.messages ~= ThreadMessage.fakeEvent(line[1..$]);
        }
        else if (line[0] == '!')
        {
            import lu.string : advancePast;

            // Internal message, see kameloso.thread.ThreadMessage.MessageType
            string subslice = line[1..$];  // mutable
            immutable verb = subslice.advancePast(' ', inherit: true);
            if (!verb.length) continue;

            messageTypeSwitch:
            switch (verb)
            {
            static foreach (immutable memberstring; __traits(allMembers, ThreadMessage.MessageType))
            {
                case memberstring:
                    ThreadMessage message;
                    mixin("message.type = ThreadMessage.MessageType.", memberstring, ";");
                    message.content = subslice.advancePast(' ', inherit: true);
                    message.payload = boxed(subslice);
                    plugin.state.messages ~= message;
                    break messageTypeSwitch;
            }

            default:
                logger.error("Unknown message type: <l>" ~ verb);
                break;
            }
        }
        else
        {
            import kameloso.messaging : raw;

            // Send piped string to the server as-is
            raw(plugin.state, line.strippedLeft);
        }

        shouldCheckMessages = true;
    }

    return shouldCheckMessages;
}


// tick
/++
    Plugin tick function. Reads from the pipe and either issues bus messages based
    on what was read or sends the piped text to the server verbatim.

    This is executed once per main loop iteration.

    Params:
        plugin = The current [PipelinePlugin].
        elapsed = How much time has passed since the last tick.

    Returns:
        Whether or not the main loop should check for messages.
 +/
auto tick(PipelinePlugin plugin, const Duration elapsed)
{
    import core.time : msecs;

    static immutable minimumTimeBetweenReads = 250.msecs;

    if (plugin.transient.fd == -1) return false;  // ?

    if (elapsed < minimumTimeBetweenReads)
    {
        // Increment and evaluate
        plugin.transient.timeSinceLast += elapsed;
        if (plugin.transient.timeSinceLast < minimumTimeBetweenReads) return false;
    }

    plugin.transient.timeSinceLast = Duration.zero;
    return readFIFO(plugin);
}


// teardown
/++
    Tears down the [PipelinePlugin] by closing the FIFO file descriptor and
    removing the FIFO file.
 +/
void teardown(PipelinePlugin plugin)
{
    import std.file : exists;
    import std.file : remove;

    if (plugin.transient.fd == -1)  return;  // teardown before initialisation?

    closeFD(plugin.transient.fd);

    if (plugin.transient.fifoFilename.exists && plugin.transient.fifoFilename.isFIFO)
    {
        try
        {
            remove(plugin.transient.fifoFilename);
        }
        catch (Exception _)
        {
            // Gag errors
        }
    }
}


// reload
/++
    Reloads the [PipelinePlugin].

    If the FIFO seems to be in place, nothing is done, but if it has disappeared
    or is not a FIFO, it is verbosely recreated.
 +/
void reload(PipelinePlugin plugin)
{
    import lu.common : ReturnValueException;
    import std.file : exists;

    if (plugin.transient.fifoFilename.exists && plugin.transient.fifoFilename.isFIFO)
    {
        // Should still be okay.
        return;
    }

    // File doesn't exist!
    if (plugin.transient.fd != -1)
    {
        // ...yet there's an old file descriptor
        closeFD(plugin.transient.fd);
    }

    // Let exceptions fall through
    plugin.transient.fifoFilename = initialiseFIFO(plugin);
    plugin.transient.fd = openFIFO(plugin.transient.fifoFilename);
    printUsageText(plugin, reinit: true);
}


mixin PluginRegistration!PipelinePlugin;

public:


// PipelinePlugin
/++
    The Pipeline plugin reads from a local named pipe (FIFO) for messages to
    send to the server, as well as to live-control the bot to a certain degree.
 +/
final class PipelinePlugin : IRCPlugin
{
    /++
        Transient state variables, aggregated in a struct.
     +/
    struct TransientState
    {
        /++
            How much time has passed since the last tick.
         +/
        Duration timeSinceLast;

        /++
            File descriptor of the open FIFO.
         +/
        int fd = -1;

        /++
            Filename of the created FIFO.
         +/
        string fifoFilename;
    }

    /++
        All Pipeline settings gathered.
     +/
    PipelineSettings pipelineSettings;

    /++
        Transient state of this [PipelinePlugin] instance.
     +/
    TransientState transient;

    mixin IRCPluginImpl;
}
