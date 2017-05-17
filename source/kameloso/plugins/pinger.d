module kameloso.plugins.pinger;

import kameloso.common;
import kameloso.constants;
import kameloso.irc;
import kameloso.plugins.common;

import std.concurrency;

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

    mixin(scopeguard(entry|exit));

    register("pinger", thisTid);

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
                writeln(Foreground.lightred, "pinger received Variant: ", v);
            }
        );

        if (!halt)
        {
            mainThread.send(ThreadMessage.Ping());
        }
    }
}

@Label("onping")
@(IrcEvent.Type.PING)
void onPing(const IrcEvent event)
{
    // We don't need to ping, server is pinging
    if (pingerThread != Tid.init)
    {
        writeln(Foreground.lightcyan, "Server is pinging, don't need to ping ourselves");
        teardown();
    }

    // state.mainThread.send(ThreadMessage.Pong(), event.sender);
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
    //if (locate("pinger") == Tid.init) return;
    if (pingerThread == Tid.init) return;

    pingerThread.send(ThreadMessage.Teardown());
    pingerThread = Tid.init;
}


mixin OnEventImpl!__MODULE__;

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
