
module kameloso.thread;

import core.thread : Fiber;

public:

struct ScheduledFiber
{
    Fiber fiber;
    long timestamp;
}

struct ScheduledDelegate
{
    void delegate() dg;
    long timestamp;
}

struct ThreadMessage
{
    static struct Pong {}
    static struct Sendline {}
    static struct Quietline {}
    static struct Immediateline {}
    static struct Quit {}
    static struct Teardown {}
    static struct Save {}
    static struct PeekCommands {}
    static struct ChangeSetting {}
    static struct Reload {}
    static struct Reconnect {}
    static struct BusMessage {}

    enum TerminalOutput
    {
        writeln,
        trace,
        log,
        info,
        warning,
        error,
    }

    static struct WantLiveSummary {}
    static struct Abort {}
    static struct ShortenReceiveTimeout {}
}

interface Sendable {}

final class BusMessage(T) : Sendable
{
    T payload;

    auto this(T payload) shared {}
}

shared(Sendable) busMessage(T)(T payload)
{
    import std.traits : Unqual;
    return new shared BusMessage!(Unqual!T)(payload);
}

final class CarryingFiber(T) : Fiber
{
    T payload;

    this(Fn, Args...)(Fn fn, Args args)
    {
        super();
    }

    this(Fn, Args...)(T payload, Fn fn, Args args)
    {
        this.payload = payload;
        super();
    }

    void resetPayload()
    {
        payload = T.init;
    }
}

private import core.time : Duration;

void interruptibleSleep(const Duration dur, const ref bool abort) {}

void exhaustMessages() {}
