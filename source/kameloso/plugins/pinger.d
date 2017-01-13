module kameloso.plugins.pinger;

import kameloso.irc;
import kameloso.common;
import kameloso.constants;

import std.stdio;
import std.concurrency;

private:

IrcPluginState state;


/// The pinging thread, spawned from Pinger
private void pinger(Tid mainThread)
{
    import std.concurrency;
    import core.time : seconds;

    mixin(scopeguard(failure));

    bool halt;

    while (!halt)
    {
        receiveTimeout(Timeout.ping.seconds,
            (ThreadMessage.Teardown t)
            {
                writeln("Pinger aborting due to ThreadMessage.Teardown");
                halt = true;
            },
            (OwnerTerminated e)
            {
                writeln("Pinger aborting due to owner terminated");
                halt = true;
            },
            (Variant v)
            {
                writeln("pinger received Variant: ", v);
            }
        );

        if (!halt)
        {
            mainThread.send(ThreadMessage.Ping());
        }
    }
}

public:

// Pinger
/++
 +  The Pinger plugin simply sends a PING once every Timeout.ping.seconds. This is to workaround
 +  freenode's new behaviour of not actively PINGing clients, but rather waiting to PONG.
 +/
final class Pinger : IrcPlugin
{
    import std.concurrency : spawn, send;

    Tid mainThread, pingThread;

    void onEvent(const IrcEvent) {}

    void status() {}

    void newBot(IrcBot) {}

    this(IrcPluginState origState)
    {
        // Ignore bot
        state = origState;

        // Spawn the pinger in a separate thread, to work concurrently with the rest
        pingThread = spawn(&pinger, state.mainThread);
    }

    /// Since the pinger runs in its own thread, it needs to be torn down when the plugin should reset
    void teardown()
    {
        try pingThread.send(ThreadMessage.Teardown());
        catch (Exception e)
        {
            writeln("Caught exception sending abort to pinger");
            writeln(e);
        }
    }
}
