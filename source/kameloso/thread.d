/++
 +  Structures and functions related to concurrency message passing, threads and
 +  `core.thread.Fiber`s.
 +/
module kameloso.thread;

public:

// ThreadMessage
/++
 +  Aggregate of thread message types.
 +
 +  This is a way to make concurrency message passing easier. You could use
 +  string literals to differentiate between messages and then have big
 +  switches inside the catching function, but with these you can actually
 +  have separate concurrency-receiving delegates for each.
 +/
struct ThreadMessage
{
    /// Concurrency message type asking for a to-server `PONG` event.
    struct Pong {}

    /// Concurrency message type asking to verbosely send a line to the server.
    struct Sendline {}

    /// Concurrency message type asking to quietly send a line to the server.
    struct Quietline {}

    /// Concurrency message type asking to immediately send a message.
    struct Immediateline {}

    /// Concurrency message type asking to quit the server and the program.
    struct Quit {}

    /// Concurrency message type asking for a plugin to shut down cleanly.
    struct Teardown {}

    /// Concurrency message type asking to have plugins' configuration saved.
    struct Save {}

    /++
     +  Concurrency message asking for a reference to the arrays of
     +  `kameloso.plugins.common.IRCPlugin`s in the current
     +  `kameloso.irc.IRCClient`'s plugin array.
     +/
    struct PeekPlugins {}

    /// Concurrency message asking plugins to "reload".
    struct Reload {}

    /// Concurrency message asking to disconnect and reconnect to the server.
    struct Reconnect {}

    /// Concurrency message meant to be sent between plugins.
    struct BusMessage {}

    /// Concurrency messages for writing text to the terminal.
    enum TerminalOutput
    {
        writeln,
        trace,
        log,
        info,
        warning,
        error,
    }
}


// Sendable
/++
 +  Interface for a message sendable through the message bus.
 +/
interface Sendable {}


// MessageContent
/++
 +  A payload of type `T` wrapped in a class implementing the `Sendable`
 +  interface.
 +
 +  Used to wrap values for sending via the message bus.
 +/
final class BusMessage(T) : Sendable
{
    /// Payload value embedded in this message.
    T payload;

    /++
     +  Constructor that adds a passed payload to the internal stored `payload`,
     +  creating a *shared* `BusMessage`.
     +/
    this(T payload) shared @safe
    {
        this.payload = cast(shared)payload;
    }
}


// busMessage
/++
 +  Constructor function to create a `shared` `BusMessage` with an unqualified
 +  template type.
 +
 +  Example:
 +  ---
 +  IRCEvent event;  // ...
 +  mainThread.send(ThreadMessage.BusMessage(), "header", busMessage(event));
 +  mainThread.send(ThreadMessage.BusMessage(), "other header", busMessage("text payload"));
 +  mainThread.send(ThreadMessage.BusMessage(), "ladida", busMessage(42));
 +  ---
 +
 +  Params:
 +      payload = Payload whose type to instantiate the `BusMessage` with, and
 +          then assign to its internal `payload`.
 +
 +  Returns:
 +      A `shared` `BusMessage!T` where `T` is the unqualified type of the
 +      payload.
 +/
shared(Sendable) busMessage(T)(T payload) @safe
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
 +  A `core.thread.Fiber` carrying a payload of type `T`.
 +
 +  Used interchangably with `core.thread.Fiber`, but allows for casting to true
 +  `CarryingFiber!T`-ness to access the `payload` member.
 +
 +  Example:
 +  ---
 +  void dg()
 +  {
 +      CarryingFiber!bool fiber = cast(CarryingFiber!bool)(Fiber.getThis);
 +      assert(fiber !is null);  // Correct cast
 +      assert(fiber.payload);
 +  }
 +
 +  Fiber fiber = new CarryingFiber!bool(true, &dg);
 +  ---
 +/
import core.thread : Fiber;
final class CarryingFiber(T) : Fiber
{
    /++
     +  Embedded payload value in this `core.thread.Fiber`, what distinguishes
     +  it from normal ones.
     +/
    T payload;

    /++
     +  Constructor function merely taking a function/delgate pointer, to call
     +  when invoking this `core.thread.Fiber` (via `.call()`).
     +/
    this(Fn, Args...)(Fn fn, Args args)
    {
        // fn is a pointer
        super(fn, args);
    }

    /++
     +  Constructor function taking a `T` `payload` to assign to its own
     +  internal `this.payload`, as well as a function/delegate pointer to call
     +  when invoking this `core.thread.Fiber` (via `.call()`).
     +/
    this(Fn, Args...)(T payload, Fn fn, Args args)
    {
        this.payload = payload;
        // fn is a pointer
        super(fn, args);
    }
}


// interruptibleSleep
/++
 +  Sleep in small periods, checking the passed `abort` bool inbetween to see
 +  if we should break and return.
 +
 +  This is useful when a different signal handler has been set up, as triggeing
 +  it won't break sleeps. This way it does, assuming the `abort` bool is the
 +  signal handler one.
 +
 +  Example:
 +  ---
 +  interruptibleSleep(1.seconds, abort);
 +  ---
 +
 +  Params:
 +      dur = Duration to sleep for.
 +      abort = Reference to the bool flag which, if set, means we should
 +          interrupt and return early.
 +/
import core.time : Duration;
void interruptibleSleep(const Duration dur, const ref bool abort) @system
{
    import core.thread : Thread, msecs, seconds;

    static immutable step = 250.msecs;
    static immutable nothing = 0.seconds;

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
