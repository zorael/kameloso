module kameloso.plugins.pinger;

import kameloso.plugins.common;
import kameloso.constants;
import kameloso.common;
import kameloso.irc;

import std.stdio : writeln, writefln;
import std.concurrency;

private:

IrcPluginState state;
Tid pingerThread;

/// The pinging thread, spawned from Pinger
private void pinger(Tid mainThread)
{
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


void teardown()
{
    try pingerThread.send(ThreadMessage.Teardown());
    catch (Exception e)
    {
        writeln("Caught exception sending abort to pinger");
        writeln(e);
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
    mixin IrcPluginBasics;

    void initialise()
    {
        pingerThread = spawn(&pinger, state.mainThread);
    }
}
