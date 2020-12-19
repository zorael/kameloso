/++
    Structures and functions related to concurrency message passing, threads and
    [core.thread.fiber.Fiber]s.

    Example:
    ---
    import std.concurrency;

    mainThread.send(ThreadMessage.Sendline(), "Message to send to server");
    mainThread.send(ThreadMessage.Pong(), "irc.freenode.net");
    mainThread.send(ThreadMessage.TerminalOutput.writeln, "writeln this for me please");
    mainThread.send(ThreadMessage.BusMessage(), "header", busMessage("payload"));

    auto fiber = new CarryingFiber!string(&someDelegate, BufferSize.fiberStack);
    fiber.payload = "This string is carried by the Fiber and can be accessed from within it";
    fiber.call();
    fiber.payload = "You can change it in between calls to pass information to it";
    fiber.call();

    // As such we can make Fibers act like they're taking new arguments each call
    auto fiber2 = new CarryingFiber!IRCEvent(&otherDelegate, BufferSize.fiberStack);
    fiber2.payload = newIncomingIRCEvent;
    fiber2.call();
    // [...]
    fiber2.payload = evenNewerIncomingIRCEvent;
    fiber2.call();
    ---
 +/
module kameloso.thread;

private:

import core.thread : Fiber;

public:


// ScheduledFiber
/++
    A [core.thread.fiber.Fiber] paired with a `long` UNIX timestamp.

    If we bundle the two together like this, we can associate a point in time
    with a [core.thread.fiber.Fiber] without having to to use an associative
    array (with UNIX timestamp keys).

    Example:
    ---
    import std.datetime.systime : Clock;
    import core.thread : Fiber;

    void dg() { /* ... */ }

    auto scheduledFiber = ScheduledFiber(new Fiber(&dg, BufferSize.fiberStack),
        Clock.currTime.stdTime + 10 * 10_000_000);  // ten seconds in hnsecs
    ---
 +/
struct ScheduledFiber
{
    /// Fiber to trigger at the point in time [timestamp].
    Fiber fiber;

    /// When [fiber] is scheduled to be called, in hnsecs from midnight Jan 1st 1970.
    long timestamp;
}


// ScheduledDelegate
/++
    A delegate paired with a `long` UNIX timestamp.

    If we bundle the two together like this, we can associate a point in time
    with a delegate without having to to use an associative array (with UNIX
    timestamp keys).

    Example:
    ---
    import std.datetime.systime : Clock;

    void dg() { /* ... */ }

    auto scheduledDg = ScheduledDelegate(&dg, Clock.currTime.stdTime + 10 * 10_000_000);
    ---
 +/
struct ScheduledDelegate
{
    /// Delegate to trigger at the point in time [timestamp].
    void delegate() dg;

    /// When [dg] is scheduled to be called, in hnsecs from midnight Jan 1st 1970.
    long timestamp;
}


version(Posix)
{
    private import core.sys.posix.pthread : pthread_t;

    // pthread_setname_np
    /++
        Prototype to allow linking to `pthread`'s function for naming threads.
     +/
    extern(C) private int pthread_setname_np(pthread_t, const char*);


    // setThreadName
    /++
        Sets the thread name of the current thread, so they will show up named
        in process managers (like `top`).

        Params:
            name = String name to assign to the current thread.
     +/
    void setThreadName(const string name)
    {
        import std.string : toStringz;
        import core.thread : Thread;

        cast(void)pthread_setname_np(Thread.getThis().id, name.toStringz);
    }
}


// ThreadMessage
/++
    Aggregate of thread message types.

    This is a way to make concurrency message passing easier. You could use
    string literals to differentiate between messages and then have big
    switches inside the catching function, but with these you can actually
    have separate concurrency-receiving delegates for each.
 +/
struct ThreadMessage
{
    /// Concurrency message type asking for a to-server [dialect.defs.IRCEvent.Type.PONG] event.
    static struct Pong {}

    /// Concurrency message type asking to verbosely send a line to the server.
    static struct Sendline {}

    /// Concurrency message type asking to quietly send a line to the server.
    static struct Quietline {}

    /// Concurrency message type asking to immediately send a line to the server.
    static struct Immediateline {}

    /// Concurrency message type asking to quit the server and exit the program.
    static struct Quit {}

    /// Concurrency message type asking for a plugin's worker thread to shut down cleanly.
    static struct Teardown {}

    /// Concurrency message type asking to have plugins' configuration saved.
    static struct Save {}

    /++
        Concurrency message asking for a reference to the arrays of
        [kameloso.plugins.common.core.IRCPlugin]s in the current
        [kameloso.kameloso.Kameloso] instance's `plugin` array.
     +/
    static struct PeekPlugins {}

    /// Concurrency message asking plugins to "reload".
    static struct Reload {}

    /// Concurrency message asking to disconnect and reconnect to the server.
    static struct Reconnect {}

    /// Concurrency message meant to be sent between plugins.
    static struct BusMessage {}

    /// Concurrency message for writing text to the terminal.
    enum TerminalOutput
    {
        writeln,
        trace,
        log,
        info,
        warning,
        error,
    }

    /// Concurrency message asking the main thread to print a connection summary.
    static struct WantLiveSummary {}

    /// Concurrency message asking the main thread to set the `abort` flag.
    static struct Abort {}

    /++
        Concurrency message asking for the Socket receive timeout to be lowered
        temporarily, for increased responsiveness.
     +/
    static struct ShortenReceiveTimeout {}
}


/++
    Interface for a message sendable through the message bus.
 +/
interface Sendable {}


// BusMessage
/++
    A payload of type `T` wrapped in a class implementing the [Sendable] interface.
    Used to box values for sending via the message bus.

    Params:
        T = Type to embed into the [BusMessage] as the type of the payload.
 +/
final class BusMessage(T) : Sendable
{
    /// Payload value embedded in this message.
    T payload;

    /++
        Constructor that adds a passed payload to the internal stored [payload],
        creating a *shared* [BusMessage].
     +/
    auto this(T payload) shared
    {
        this.payload = cast(shared)payload;
    }
}


// busMessage
/++
    Constructor function to create a `shared` [BusMessage] with an unqualified template type.

    Example:
    ---
    IRCEvent event;  // ...
    mainThread.send(ThreadMessage.BusMessage(), "header", busMessage(event));
    mainThread.send(ThreadMessage.BusMessage(), "other header", busMessage("text payload"));
    mainThread.send(ThreadMessage.BusMessage(), "ladida", busMessage(42));
    ---

    Params:
        payload = Payload whose type to instantiate the [BusMessage] with, and
            then assign to its internal `payload`.

    Returns:
        A `shared` `BusMessage!T` where `T` is the unqualified type of the payload.
 +/
shared(Sendable) busMessage(T)(T payload)
{
    import std.traits : Unqual;
    return new shared BusMessage!(Unqual!T)(payload);
}

///
unittest
{
    {
        auto msg = busMessage("asdf");
        auto asCast = cast(BusMessage!string)msg;
        assert((msg !is null), "Incorrectly cast message: " ~ typeof(asCast).stringof);
    }
    {
        auto msg = busMessage(12345);
        auto asCast = cast(BusMessage!int)msg;
        assert((msg !is null), "Incorrectly cast message: " ~ typeof(asCast).stringof);
    }
    {
        struct Foo {}
        auto msg = busMessage(Foo());
        auto asCast = cast(BusMessage!Foo)msg;
        assert((msg !is null), "Incorrectly cast message: " ~ typeof(asCast).stringof);
    }
}


// CarryingFiber
/++
    A [core.thread.fiber.Fiber] carrying a payload of type `T`.

    Used interchangeably with [core.thread.fiber.Fiber], but allows for casting to true
    `CarryingFiber!T`-ness to access the `payload` member.

    Example:
    ---
    void dg()
    {
        CarryingFiber!bool fiber = cast(CarryingFiber!bool)(Fiber.getThis);
        assert(fiber !is null);  // Correct cast

        assert(fiber.payload);
        Fiber.yield();
        assert(!fiber.payload);
    }

    auto fiber = new CarryingFiber!bool(true, &dg, BufferSize.fiberStack);
    fiber.call();
    fiber.payload = false;
    fiber.call();
    ---

    Params:
        T = Type to embed into the [CarryingFiber] as the type of [CarryingFiber.payload].
 +/
final class CarryingFiber(T) : Fiber
{
    /++
        Embedded payload value in this [core.thread.fiber.Fiber]; what distinguishes
        it from plain [core.thread.fiber.Fiber]s.
     +/
    T payload;

    /++
        Constructor function merely taking a function/delegate pointer, to call
        when invoking this [core.thread.fiber.Fiber] (via `.call()`).
     +/
    this(Fn, Args...)(Fn fn, Args args)
    {
        // fn is a pointer
        super(fn, args);
    }

    /++
        Constructor function taking a `T` [payload] to assign to its own
        internal `this.payload`, as well as a function/delegate pointer to call
        when invoking this [core.thread.fiber.Fiber] (via `.call()`).
     +/
    this(Fn, Args...)(T payload, Fn fn, Args args)
    {
        this.payload = payload;
        // fn is a pointer
        super(fn, args);
    }

    /++
        Resets the payload to its initial value.
     +/
    void resetPayload()
    {
        payload = T.init;
    }
}


private import core.time : Duration;

// interruptibleSleep
/++
    Sleep in small periods, checking the passed `abort` bool in between to see
    if we should break and return.

    This is useful when a different signal handler has been set up, as triggering
    it won't break sleeps. This way it does, assuming the `abort` bool is the
    same one the signal handler monitors. As such, take it by `ref`.

    Example:
    ---
    interruptibleSleep(1.seconds, abort);
    ---

    Params:
        dur = Duration to sleep for.
        abort = Reference to the bool flag which, if set, means we should
            interrupt and return early.
 +/
void interruptibleSleep(const Duration dur, const ref bool abort) @system
{
    import core.thread : Thread, msecs;

    static immutable step = 100.msecs;
    static immutable nothing = 0.msecs;

    Duration left = dur;

    while (left > nothing)
    {
        if (abort) return;

        immutable nextStep = (left > step) ? step : left;

        if (nextStep <= nothing) break;

        Thread.sleep(nextStep);
        left -= step;
    }
}


// exhaustMessages
/++
    Exhausts the concurrency message mailbox.

    This is done between connection attempts to get a fresh start.
 +/
void exhaustMessages()
{
    import std.concurrency : receiveTimeout, thisTid;
    import std.variant : Variant;
    import core.time : msecs;

    // core.exception.AssertError@std/concurrency.d(910): Cannot receive a message
    // until a thread was spawned or thisTid was passed to a running thread.
    cast(void)thisTid;

    bool notEmpty;
    static immutable almostInstant = 10.msecs;

    do
    {
        notEmpty = receiveTimeout(almostInstant,
            (Variant v) scope {}
        );
    }
    while (notEmpty);
}

///
unittest
{
    import std.concurrency : receiveTimeout, send, thisTid;
    import std.variant : Variant;
    import core.time : seconds;

    foreach (immutable i; 0..10)
    {
        thisTid.send(i);
    }

    exhaustMessages();

    immutable receivedSomething = receiveTimeout((-1).seconds,
        (Variant v) {},
    );

    assert(!receivedSomething);
}
