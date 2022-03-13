/++
    Structures and functions related to concurrency message passing, threads and
    [core.thread.fiber.Fiber|Fiber]s.

    Example:
    ---
    import std.concurrency;

    mainThread.send(ThreadMessage.Sendline(), "Message to send to server");
    mainThread.send(ThreadMessage.Pong(), "irc.libera.chat");
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
    A [core.thread.fiber.Fiber|Fiber] paired with a `long` UNIX timestamp.

    If we bundle the two together like this, we can associate a point in time
    with a [core.thread.fiber.Fiber|Fiber] without having to to use an associative
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
    /++
        Different thread message types.
     +/
    enum Type
    {
        /++
            Request to send a server [dialect.defs.IRCEvent.Type.PONG|PONG] response.
         +/
        pong,

        /++
            Request to send an outgoing normal line.
         +/
        sendline,

        /++
            Request to send a quiet normal line.
         +/
        quietline,

        /++
            Request to send a line immediately, bypassing queues.
         +/
        immediateline,

        /++
            Request to quit the program.
         +/
        quit,

        /++
            Request to teardown (destroy) a plugin.
         +/
        teardown,

        /++
            Request to save configuration to file.
         +/
        save,

        /++
            Request to reload resources from disk.
         +/
        reload,

        /++
            Request to disconnect and reconect to the server.
         +/
        reconnect,

        /++
            A bus message.
         +/
        busMessage,

        /++
            Request to print a connection summary to the local terminal.
         +/
        wantLiveSummary,

        /++
            Request to abort and exit the program.
         +/
        abort,

        /++
            Request to lower receive timeout briefly and improve
            responsiveness/precision during that time.
         +/
        shortenReceiveTimeout,
    }

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

    /++
        The [Type] of this thread message.
     +/
    Type type;

    /++
        String content body of message, where applicable.
     +/
    string content;

    /++
        Bundled `shared` [Sendable] payload, where applicable.
     +/
    shared Sendable payload;

    /++
        Whether or not the action requested should be done quietly.
     +/
    bool quiet;

    /++
        Concurrency message asking for an associative array of a description of
        all plugins' commands.
     +/
    static struct PeekCommands {}

    /++
        Concurrency message askin to apply an expression to change a setting of a plugin.
     +/
    static struct ChangeSetting {}

    /+
        Generate a static function for each [Type].
     +/
    static foreach (immutable memberstring; __traits(allMembers, Type))
    {
        mixin(`
            static auto ` ~ memberstring ~ `
                (const string content = string.init,
                shared Sendable payload = null,
                const bool quiet = false)
            {
                return ThreadMessage(Type.` ~ memberstring ~ `, content, payload, quiet);
            }`);
    }
}


// OutputRequest
/++
    Embodies the notion of a request to output something to the local terminal.

    Merely bundles a [ThreadMessage.TerminalOutput|TerminalOutput] log level and
    a `string` message line. What log level is picked decides what log level is
    passed to the [kameloso.logger.KamelosoLogger|KamelosoLogger] instance, and
    dictates things like what colour to tint the message with (if any).
 +/
struct OutputRequest
{
    /++
        Log level of the message.

        See_Also:
            [ThreadMessage.TerminalOutput]
            [kameloso.logger.LogLevel]
     +/
    ThreadMessage.TerminalOutput logLevel;

    /++
        String line to request to be output to the local terminal.
     +/
    string line;
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
        creating a *shared* `BusMessage`.
     +/
    auto this(T payload) shared
    {
        this.payload = cast(shared)payload;
    }
}


// busMessage
/++
    Constructor function to create a `shared` [BusMessage] with an unqualified
    template type.

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
        asCast = null;  // silence dscanner
    }
    {
        auto msg = busMessage(123_456);
        auto asCast = cast(BusMessage!int)msg;
        assert((msg !is null), "Incorrectly cast message: " ~ typeof(asCast).stringof);
        asCast = null;  // silence dscanner
    }
    {
        struct Foo {}
        auto msg = busMessage(Foo());
        auto asCast = cast(BusMessage!Foo)msg;
        assert((msg !is null), "Incorrectly cast message: " ~ typeof(asCast).stringof);
        asCast = null;  // silence dscanner
    }
}


// CarryingFiber
/++
    A [core.thread.fiber.Fiber|Fiber] carrying a payload of type `T`.

    Used interchangeably with [core.thread.fiber.Fiber|Fiber], but allows for
    casting to true `CarryingFiber!T`-ness to access the `payload` member.

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
        T = Type to embed into the class as the type of [CarryingFiber.payload].
 +/
final class CarryingFiber(T) : Fiber
{
    /++
        Embedded payload value in this Fiber; what distinguishes it from plain `Fiber`s.
     +/
    T payload;

    /++
        Constructor function merely taking a function/delegate pointer, to call
        when invoking this Fiber (via `.call()`).
     +/
    this(Fn, Args...)(Fn fn, Args args)
    {
        // fn is a pointer
        super(fn, args);
    }

    /++
        Constructor function taking a `T` `payload` to assign to its own
        internal `this.payload`, as well as a function/delegate pointer to call
        when invoking this Fiber (via `.call()`).
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
            (Variant _) scope {}
        );
    }
    while (notEmpty);
}

///
unittest
{
    import std.concurrency : receiveTimeout, send, thisTid;
    import std.variant : Variant;
    import core.time : Duration;

    foreach (immutable i; 0..10)
    {
        thisTid.send(i);
    }

    exhaustMessages();

    immutable receivedSomething = receiveTimeout(Duration.zero,
        (Variant _) {},
    );

    assert(!receivedSomething);
}
