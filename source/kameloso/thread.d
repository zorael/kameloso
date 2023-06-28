/++
    Structures and functions related to concurrency message passing, threads and
    [core.thread.fiber.Fiber|Fiber]s.

    Example:
    ---
    import std.concurrency;

    mainThread.send(ThreadMessage.sendline("Message to send to server"));
    mainThread.send(ThreadMessage.pong("irc.libera.chat"));
    mainThread.send(OutputRequest(ThreadMessage.TerminalOutput.writeln, "writeln this for me please"));
    mainThread.send(ThreadMessage.busMessage("header", boxed("payload")));

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

    See_Also:
        [kameloso.messaging]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
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
    Collection of static functions used to construct thread messages, for passing
    information of different kinds yet still as one type, to stop [std.concurrency.send]
    from requiring so much compilation memory.

    The type of the message is defined as a [ThreadMessage.Type|Type] in
    [ThreadMessage.type]. Recipients will have to do a (final) switch over that
    enum to deal with messages accordingly.
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
            Request to send a server [dialect.defs.IRCEvent.Type.PING|PING] query.
         +/
        ping,

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
            Request to disconnect and reconnect to the server.
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

        /++
            Removes an entry from the custom settings array popualted at program
            start with the `--set` parameter.
         +/
        popCustomSetting,

        /++
            Request to put an [dialect.defs.IRCUser|IRCUser] into each plugin's (and service's)
            [kameloso.plugins.common.core.IRCPluginState.users|IRCPluginState.users]
            associative array.
         +/
        putUser,
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
        An `opDispatch`, constructing one function for each member in [Type].

        What the parameters functionally do is contextual to each [Type].

        Params:
            memberstring = String name of a member of [Type].
            content = Optional content string.
            payload = Optional boxed [Sendable] payloda.
            quiet = Whether or not to pass a flag for the action to be done quietly.

        Returns:
            A [ThreadMessage] whose members have the passed values.
     +/
    static auto opDispatch(string memberstring)
        (const string content = string.init,
        shared Sendable payload = null,
        const bool quiet = false)
    {
        mixin("return ThreadMessage(Type." ~ memberstring ~ ", content, payload, quiet);");
    }
}


// OutputRequest
/++
    Embodies the notion of a request to output something to the local terminal.

    Merely bundles a [OutputRequest.Level|Level] log level and
    a `string` message line. What log level is picked decides what log level is
    passed to the [kameloso.logger.KamelosoLogger|KamelosoLogger] instance, and
    dictates things like what colour to tint the message with (if any).
 +/
struct OutputRequest
{
    /++
        Output log levels.

        See_Also:
            [kameloso.logger.LogLevel]
     +/
    enum Level
    {
        writeln,    /// writeln the line.
        trace,      /// Log at [kameloso.logger.LogLevel.trace].
        log,        /// Log at [kameloso.logger.LogLevel.all] (log).
        info,       /// Log at [kameloso.logger.LogLevel.info].
        warning,    /// Log at [kameloso.logger.LogLevel.warning].
        error,      /// Log at [kameloso.logger.LogLevel.error].
        critical,   /// Log at [kameloso.logger.LogLevel.critical].
        fatal,      /// Log at [kameloso.logger.LogLevel.fatal].
    }

    /++
        Log level of the message.
     +/
    Level logLevel;

    /++
        String line to request to be output to the local terminal.
     +/
    string line;
}


// Sendable
/++
    Interface for a message sendable through the message bus.
 +/
interface Sendable {}


// Boxed
/++
    A payload of type `T` wrapped in a class implementing the [Sendable] interface.
    Used to box values for sending via the message bus.

    Params:
        T = Type to embed into the [Boxed] as the type of the payload.
 +/
final class Boxed(T) : Sendable
{
    /// Payload value embedded in this message.
    T payload;

    /++
        Constructor that adds a passed payload to the internal stored [payload],
        creating a *shared* `Boxed`.
     +/
    auto this(T payload) shared
    {
        this.payload = cast(shared)payload;
    }
}


// BusMessage
/++
    Deprecated alias to [Boxed].
 +/
deprecated("Use `Boxed!T` instead")
alias BusMessage = Boxed;


// boxed
/++
    Constructor function to create a `shared` [Boxed] with an unqualified
    template type.

    Example:
    ---
    IRCEvent event;  // ...
    mainThread.send(ThreadMessage.busMessage("header", boxed(event)));
    mainThread.send(ThreadMessage.busMessage("other header", boxed("text payload")));
    mainThread.send(ThreadMessage.busMessage("ladida", boxed(42)));
    ---

    Params:
        payload = Payload whose type to instantiate the [Boxed] with, and
            then assign to its internal `payload`.

    Returns:
        A `shared` [Boxed]!T` where `T` is the unqualified type of the payload.
 +/
shared(Sendable) boxed(T)(T payload)
{
    import std.traits : Unqual;
    return new shared Boxed!(Unqual!T)(payload);
}


// sendable
/++
    Deprecated alias to [boxed].
 +/
deprecated("Use `boxed` instead")
alias sendable = boxed;

///
unittest
{
    {
        auto msg = boxed("asdf");
        auto asCast = cast(Boxed!string)msg;
        assert((msg !is null), "Incorrectly cast message: " ~ typeof(asCast).stringof);
        asCast = null;  // silence dscanner
    }
    {
        auto msg = boxed(123_456);
        auto asCast = cast(Boxed!int)msg;
        assert((msg !is null), "Incorrectly cast message: " ~ typeof(asCast).stringof);
        asCast = null;  // silence dscanner
    }
    {
        struct Foo {}
        auto msg = boxed(Foo());
        auto asCast = cast(Boxed!Foo)msg;
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

    bool receivedSomething;
    static immutable almostInstant = 10.msecs;

    do
    {
        receivedSomething = receiveTimeout(almostInstant,
            (Variant _) scope {}
        );
    }
    while (receivedSomething);
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
