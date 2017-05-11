module kameloso.plugins.pinger;

import kameloso.common;
import kameloso.constants;
import kameloso.irc;
import kameloso.plugins.common;

import std.concurrency;
import std.stdio : writefln, writeln;

private:

/// All plugin state variables gathered in a struct
IrcPluginState state;

/// Thread ID of the pinging thread
Tid pingerThread;


// pinger
/++
 +  Sends a ping to the main thread every Timeout.ping seconds.
 +
 +  It waits in a concurrency-receive loop until it's time to ping again.
 +
 +  Params:
 +      mainThread = the thread ID of the main thread.
 +/
void pinger(Tid mainThread)
{
    import core.time : seconds;

    bool halt;
    while (!halt)
    {
        receiveTimeout(Timeout.ping.seconds,
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
                writeln("pinger received Variant: ", v);
            }
        );

        if (!halt)
        {
            mainThread.send(ThreadMessage.Ping());
        }
    }
}


// initialise
/++
 +  Initialises the Pinger plugin. Spawns the pinger thread.
 +/
void initialise()
{
    pingerThread = spawn(&pinger, state.mainThread);
}


// teardown
/++
 +  Deinitialises the Pinger plugin. Shuts down the pinger thread.
 +/
void teardown()
{
    pingerThread.send(ThreadMessage.Teardown());
}


public:


// Pinger
/++
 +  The Pinger plugin simply sends a PING once every Timeout.ping.seconds. This is to workaround
 +  Freenode's new behaviour of not actively PINGing clients, but rather waiting to PONG.
 +/
final class Pinger : IrcPlugin
{
    mixin IrcPluginBasics;
}
