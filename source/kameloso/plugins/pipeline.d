module kameloso.plugins.pipeline;

version (Posix):

import kameloso.common;
import kameloso.constants;
import kameloso.irc;
import kameloso.plugins.common;

import std.concurrency;
import std.stdio : File;

private:

/// All plugin state variables gathered in a struct
IrcPluginState state;

/// Thread ID of the thread reading the named pipe
Tid fifoThread;

/// Named pipe (FIFO) to send messages to the server through
File fifo;


void pipereader(shared IrcPluginState newState)
{
    import core.time : seconds;
    import std.file  : remove;

    state = cast(IrcPluginState)newState;

    createFIFO();

    if (!fifo.isOpen)
    {
        writeln(Foreground.lightred, "Could not create FIFO. Pipereader will not function.");
        return;
    }

    scope(exit)
    {
        writeln(Foreground.yellow, "Deleting FIFO from disk");
        remove(fifo.name);
    }

    bool halt;

    while (!halt)
    {
        eofLoop:
        while (!fifo.eof)
        {
            foreach (const line; fifo.byLineCopy)
            {
                if (!line.length) break eofLoop;

                state.mainThread.send(ThreadMessage.Sendline(), line);
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
                writeln(Foreground.lightred, "pipeline received Variant: ", v);
            }
        );

        if (!halt)
        {
            try fifo.reopen(fifo.name);
            catch (Exception e)
            {
                writeln(Foreground.lightred, e.msg);
            }
        }
    }
}


void createFIFO()
{
    import std.file : exists, isDir;
    import std.process : execute;

    immutable filename = state.bot.nickname ~ "@" ~ state.bot.server.address;

    writeln(Foreground.yellow, "Creating FIFO: ", filename);

    if (!filename.exists)
    {
        immutable mkfifo = execute([ "mkfifo", filename ]);
        if (mkfifo.status != 0) return;
    }
    else if (filename.isDir)
    {
        writeln(Foreground.lightred, "wanted to create FIFO ", filename,
            " but a directory exists with the same name");
        return;
    }

    fifo = File(filename, "r");
}


@Label("welcome")
@(IrcEvent.Type.WELCOME)
void onWelcome(const IrcEvent event)
{
    state.bot.nickname = event.target;
    fifoThread = spawn(&pipereader, cast(shared)state);
}


// teardown
/++
 +  Deinitialises the Pipeline plugin. Shuts down the pipereader thread.
 +/
void teardown()
{
    import std.file  : exists, isDir;

    if (fifoThread == Tid.init) return;

    fifoThread.send(ThreadMessage.Teardown());
    fifoThread = Tid.init;

    immutable filename = state.bot.nickname ~ "@" ~ state.bot.server.address;

    if (filename.exists && !filename.isDir)
    {
        // Tell the reader of the pipe to exit
        fifo = File(filename, "w");
        fifo.writeln();
        fifo.flush();
    }
}


public:


mixin OnEventImpl!__MODULE__;


// Pipeline
/++
 *  The Pipeline plugin reads from a local named pipe (FIFO) for messages to send
 *  to the server. It is for debugging purposes until such time we figure out a
 *  way to properly input lines via the terminal.
 +/
final class Pipeline : IrcPlugin
{
    mixin IrcPluginBasics;
}
