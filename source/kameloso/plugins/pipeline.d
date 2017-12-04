module kameloso.plugins.pipeline;

version(Posix):

import kameloso.plugins.common;
import kameloso.ircdefs;
import kameloso.common;

import std.concurrency;
import std.experimental.logger : LogLevel, Logger;

import std.stdio;

private:

/// All plugin state variables gathered in a struct
IRCPluginState state;

/// Thread ID of the thread reading the named pipe
Tid fifoThread;

/// Named pipe (FIFO) to send messages to the server through
File fifo;

/// Thread-local logger
Logger tlsLogger;


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
    import std.file  : remove;

    state = cast(IRCPluginState)newState;
    tlsLogger = new KamelosoLogger(LogLevel.all, state.settings.monochrome);

    createFIFO();

    if (!fifo.isOpen)
    {
        tlsLogger.warning("Could not create FIFO. Pipereader will not function.");
        return;
    }

    scope(exit)
    {
        stdout.flush();
        tlsLogger.log("Deleting FIFO from disk");
        remove(fifo.name);
    }

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
                tlsLogger.error("pipeline received Variant: ", v);
            }
        );

        if (!halt)
        {
            import std.exception : ErrnoException;

            try fifo.reopen(fifo.name);
            catch (const ErrnoException e)
            {
                tlsLogger.error(e.msg);
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
void createFIFO()
{
    import std.file : exists, isDir;
    import std.process : execute;

    immutable filename = state.bot.nickname ~ "@" ~ state.bot.server.address;

    tlsLogger.log("Creating FIFO");

    if (!filename.exists)
    {
        immutable mkfifo = execute([ "mkfifo", filename ]);
        if (mkfifo.status != 0) return;
    }
    else if (filename.isDir)
    {
        tlsLogger.error("wanted to create FIFO ", filename,
            " but a directory exists with the same name");
        return;
    }

    tlsLogger.info("Pipe text to ./", filename,
        " to send raw commands to the server");

    fifo = File(filename, "r");
}


// onWelcome
/++
 +  Spawns the pipereader thread.
 +/
@(IRCEvent.Type.RPL_WELCOME)
void onWelcome(const IRCEvent event)
{
    with (state)
    {
        bot.nickname = event.target.nickname;
        fifoThread = spawn(&pipereader, cast(shared)state);
    }
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


// Pipeline
/++
 +  The Pipeline plugin reads from a local named pipe (FIFO) for messages to
 +  send to the server. It is for debugging purposes until such time we figure
 +  out a way to properly input lines via the terminal.
 +/
final class PipelinePlugin : IRCPlugin
{
    mixin IRCPluginBasics;
}
