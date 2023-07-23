/++
    FIXME
 +/
module kameloso.plugins.pipeline2;

version(Posix):
version(WithPipelinePlugin):

private:

import kameloso.plugins.common.core;
import kameloso.plugins;
import kameloso.common : logger;
import dialect.defs;


// Pipeline2Settings
/++
 +/
@Settings struct Pipeline2Settings
{
private:
    import lu.uda : Unserialisable;

public:
    /++
        FIXME
     +/
    @Enabler bool enabled = true;

    /++
        FIXME
     +/
    bool fifoInWorkingDir = false;

    /++
        FIXME
     +/
    @Unserialisable string path;
}


// onWelcome
/++
    FIXME
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WELCOME)
)
void onWelcome(PipelinePlugin2 plugin)
{
    enum pattern = "Pipe text to the <i>%s</> file to send raw commands to the server.";
    logger.logf(pattern, plugin.fifoFilename);
}


// initialise
/++
    FIXME
 +/
void initialise(PipelinePlugin2 plugin)
{
    plugin.fifoFilename = initFIFO(plugin);
    plugin.fd = openFIFO(plugin.fifoFilename);
}


// postprocess
/++
    FIXME
 +/
void postprocess(PipelinePlugin2 plugin, ref IRCEvent event)
{
    import std.file : exists;
    import core.sys.posix.unistd : read;

    if (plugin.fd == -1) return;   // ?

    if (!plugin.fifoFilename.exists)
    {
        plugin.fifoFilename = initFIFO(plugin);
    }
    else if (!plugin.fifoFilename.isFIFO)
    {
        import std.file : getAttributes;
        import lu.common : FileTypeMismatchException;

        enum message = "A file or directory exists with the same name as the FIFO we want to create";
        throw new FileTypeMismatchException(
            message,
            plugin.fifoFilename,
            cast(ushort)getAttributes(plugin.fifoFilename),
            __FILE__,
            __LINE__);
    }

    // FIFO exists, read from the file descriptor
    enum bufferSize = 1024;  // Should be enough?
    ubyte[bufferSize] buf;
    immutable ptrdiff_t bytesRead = read(plugin.fd, buf.ptr, buf.length);

    if (bytesRead > 0)
    {
        import kameloso.thread : ThreadMessage, boxed;
        import lu.string : splitInto;
        import std.algorithm.iteration : splitter;
        import std.concurrency : send;

        string slice = cast(string)buf[0..bytesRead].idup;  // mutable

        foreach (/*immutable*/ line; slice.splitter("\n"))
        {
            string header;  // ditto
            line.splitInto(header);
            if (!header.length) return;
            plugin.state.mainThread.send(ThreadMessage.busMessage(header, boxed(line)));
        }
    }
}


// teardown
/++
    FIXME
 +/
void teardown(PipelinePlugin2 plugin)
{
    import std.file : exists;
    import std.file : remove;

    if (plugin.fd == -1)  return;  // teardown before initialisation?

    closeFD(plugin.fd);

    if (plugin.fifoFilename.exists && plugin.fifoFilename.isFIFO)
    {
        try
        {
            remove(plugin.fifoFilename);
        }
        catch (Exception _)
        {
            // Gag errors
        }
    }
}


// reload
/++
    FIXME
 +/
void reload(PipelinePlugin2 plugin)
{
    import std.file : exists;

    if (plugin.fifoFilename.exists && plugin.fifoFilename.isFIFO)
    {
        // Should still be okay.
    }

    // File doesn't exist!
    if (plugin.fd != -1)
    {
        // ...yet there's an old file descriptor
        closeFD(plugin.fd);
    }

    plugin.fifoFilename = initFIFO(plugin);
    plugin.fd = openFIFO(plugin.fifoFilename);

    enum pattern = "Pipe text to the <i>%s</> file to send raw commands to the server.";
    logger.logf(pattern, plugin.fifoFilename);
}


// initFIFO
/++
    FIXME
 +/
auto initFIFO(PipelinePlugin2 plugin)
{
    import lu.common : FileExistsException, FileTypeMismatchException, ReturnValueException;
    import std.file : exists;

    string filename;  // mutable

    if (plugin.pipeline2Settings.path.length)
    {
        filename = plugin.pipeline2Settings.path;
    }
    else
    {
        import std.conv : text;
        import std.path : buildNormalizedPath;

        filename = text(plugin.state.client.nickname, '@', plugin.state.server.address);

        if (!plugin.pipeline2Settings.fifoInWorkingDir)
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
                filename = filename[0..$-2] ~ "10";
            }
            else if (filename[$-3..$] == "-00")  // beyond -99
            {
                // Don't infinitely loop, should realistically never happen though
                enum message = "Failed to find a suitable FIFO filename";
                throw new Exception(message);
            }
        }
    }

    createFIFO(filename);
    return filename;
}


// createFIFO
/++
    Creates a FIFO (named pipe) in the filesystem.

    It will be named a passed filename.

    Params:
        filename = String filename of FIFO to create.

    Throws:
        [lu.common.ReturnValueException|ReturnValueException] if the FIFO
        could not be created.

        [lu.common.FileExistsException|FileExistsException] if a FIFO with
        the same filename already exists, suggesting concurrent conflicting
        instances of the program (or merely a zombie FIFO after a crash).

        [lu.common.FileTypeMismatchException|FileTypeMismatchException] if a file or directory
        exists with the same name as the FIFO we want to create.
 +/
void createFIFO(const string filename)
in (filename.length, "Tried to create a FIFO with an empty filename")
{
    import lu.common : FileExistsException, FileTypeMismatchException, ReturnValueException;
    import std.file : exists;
    import std.process : execute;

    if (filename.exists)
    {
        import std.file : getAttributes;
        import core.sys.posix.sys.stat : S_ISFIFO;

        if (filename.isFIFO)
        {
            enum message = "A FIFO with that name already exists";
            throw new FileExistsException(
                message,
                filename,
                __FILE__,
                __LINE__);
        }
        else
        {
            import std.file : getAttributes;

            enum message = "Wanted to create a FIFO but a file or directory " ~
                "with the desired name already exists";
            throw new FileTypeMismatchException(
                message,
                filename,
                cast(ushort)getAttributes(filename),
                __FILE__,
                __LINE__);
        }
    }

    immutable mkfifo = execute([ "mkfifo", filename ]);

    if (mkfifo.status != 0)
    {
        enum message = "Could not create FIFO";
        throw new ReturnValueException(
            message,
            "mkfifo",
            mkfifo.status);
    }
}


// openFIFO
/++
    FIXME
 +/
auto openFIFO(const string filename)
{
    import std.string : toStringz;
    import core.sys.posix.fcntl;
    import core.sys.posix.unistd;

    return open(filename.toStringz, (O_RDONLY | O_NONBLOCK));
}


// closeFD
/++
    FIXME
 +/
auto closeFD(const int fd)
{
    import core.sys.posix.unistd;
    return close(fd);
}


// isFIFO
auto isFIFO(const string filename)
{
    import std.file : getAttributes;
    import core.sys.posix.sys.stat : S_ISFIFO;

    immutable attrs = cast(ushort)getAttributes(filename);
    return S_ISFIFO(attrs);
}


public:


// PipelinePlugin2
/++
    FIXME
 +/
final class PipelinePlugin2 : IRCPlugin
{
    // pipelineSettings
    /++
        FIXME
     +/
    Pipeline2Settings pipeline2Settings;

    // fifoFilename
    /++
        FIXME
     +/
    string fifoFilename;

    // fd
    /++
        FIXME
     +/
    int fd = -1;

    mixin IRCPluginImpl;
}

mixin PluginRegistration!PipelinePlugin2;
