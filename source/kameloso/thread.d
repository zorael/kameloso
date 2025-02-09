/++
    Structures and functions related to message passing, threads and
    [core.thread.fiber.Fiber|Fiber]s.

    Example:
    ---
    plugin.state.messages ~= ThreadMessage.sendline("Message to send to server");
    plugin.state.priorityMessages ~= ThreadMessage.pong("irc.libera.chat");
    plugin.state.messages ~= ThreadMessage.askToWriteln("writeln this for me please");
    plugin.state.messages ~= ThreadMessage.busMessage("header", boxed("payload"));

    auto fiber = new CarryingFiber!string(&someDelegate, BufferSize.fiberStack);
    fiber.payload = "This string is carried by the fiber and can be accessed from within it";
    fiber.call();
    fiber.payload = "You can change it in between calls to pass information to it";
    fiber.call();

    // As such we can make fibers act like they're taking new arguments each call
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

import kameloso.plugins : IRCPlugin;
import std.meta : allSatisfy;
import std.traits : isNumeric, isSomeFunction;
import core.thread.fiber : Fiber;
import core.time : Duration;

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
    import core.thread.fiber : Fiber;

    void dg() { /* ... */ }

    auto scheduledFiber = ScheduledFiber(new Fiber(&dg, BufferSize.fiberStack),
        Clock.currTime.stdTime + 10 * 10_000_000);  // ten seconds in hnsecs
    ---
 +/
struct ScheduledFiber
{
    /++
        Fiber to trigger at the point in time [timestamp].
     +/
    Fiber fiber;

    /++
        When [fiber] is scheduled to be called, in hnsecs from midnight Jan 1st 1970.
     +/
    long timestamp;

    /++
        String name of the function that created this [ScheduledFiber].
     +/
    string creator;

    /++
        Constructor.

        Params:
            fiber = Fiber to trigger at the point in time [timestamp].
            timestamp = When [fiber] is scheduled to be called, in hecto-nanoseconds
                from midnight Jan 1st 1970.
            creator = String name of the function that created this [ScheduledFiber].
     +/
    this(
        Fiber fiber,
        const long timestamp,
        const string creator = __FUNCTION__)
    {
        this.fiber = fiber;
        this.timestamp = timestamp;
        this.creator = creator;
    }
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
    /++
        Delegate to trigger at the point in time [timestamp].
     +/
    void delegate() dg;

    /++
        When [dg] is scheduled to be called, in hnsecs from midnight Jan 1st 1970.
     +/
    long timestamp;

    /++
        String name of the function that created this [ScheduledDelegate].
     +/
    string creator;

    /++
        Constructor.

        Params:
            dg = Delegate to trigger at the point in time [timestamp].
            timestamp = When [dg] is scheduled to be called, in hecto-nanoseconds
                from midnight Jan 1st 1970.
            creator = String name of the function that created this [ScheduledDelegate].
     +/
    this(
        void delegate() dg,
        const long timestamp,
        const string creator = __FUNCTION__)
    {
        this.dg = dg;
        this.timestamp = timestamp;
        this.creator = creator;
    }
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
    information of different kinds yet still as one type, to be able to store them
    in arrays for later processing.

    The type of the message is defined as a [ThreadMessage.MessageType|MessageType] in
    [ThreadMessage.MessageType]. Recipients will have to do a (final) switch over that
    enum to deal with messages accordingly.
 +/
struct ThreadMessage
{
    /++
        Different thread message types.
     +/
    enum MessageType
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
            Removes an entry from the custom settings array populated at program
            start with the `--set` parameter.
         +/
        popCustomSetting,

        /++
            Request to put an [dialect.defs.IRCUser|IRCUser] into each plugin's (and service's)
            [kameloso.plugins.common.IRCPluginState.users|IRCPluginState.users]
            associative array.
         +/
        putUser,

        /++
            Request to print a message using the [kameloso.logger.KamelosoLogger|KamelosoLogger]
            at a level of [kameloso.logger.LogLevel.trace|trace].
         +/
        askToTrace,

        /++
            Request to print a message using the [kameloso.logger.KamelosoLogger|KamelosoLogger]
            at a level of [kameloso.logger.LogLevel.all|all] (log).
         +/
        askToLog,

        /++
            Request to print a message using the [kameloso.logger.KamelosoLogger|KamelosoLogger]
            at a level of [kameloso.logger.LogLevel.info|info].
         +/
        askToInfo,

        /++
            Request to print a message using the [kameloso.logger.KamelosoLogger|KamelosoLogger]
            at a level of [kameloso.logger.LogLevel.warning|warning].
         +/
        askToWarn,

        /++
            Request to print a message using the [kameloso.logger.KamelosoLogger|KamelosoLogger]
            at a level of [kameloso.logger.LogLevel.error|error].
         +/
        askToError,

        /++
            Request to print a message using the [kameloso.logger.KamelosoLogger|KamelosoLogger]
            at a level of [kameloso.logger.LogLevel.critical|critical].
         +/
        askToCritical,

        /++
            Request to print a message using the [kameloso.logger.KamelosoLogger|KamelosoLogger]
            at a level of [kameloso.logger.LogLevel.fatal|fatal].
         +/
        askToFatal,

        /++
            Request to print a message using [std.stdio.writeln|writeln].
         +/
        askToWriteln,

        /++
            Request to fake a string as having been received from the server.
         +/
        fakeEvent,
    }

    /++
        The [MessageType] of this thread message.
     +/
    MessageType type;

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
        Whether or not this message has been processed.
     +/
    bool exhausted;

    /++
        An `opDispatch`, constructing one function for each member in [MessageType].

        What the parameters functionally do is contextual to each [MessageType].

        Params:
            memberstring = String name of a member of [MessageType].
            content = Optional content string.
            payload = Optional boxed [Sendable] payload.
            quiet = Whether or not to pass a flag for the action to be done quietly.

        Returns:
            A [ThreadMessage] whose members have the passed values.
     +/
    static auto opDispatch(string memberstring)
        (const string content = string.init,
        shared Sendable payload = null,
        const bool quiet = false)
    {
        mixin("return ThreadMessage(MessageType." ~ memberstring ~ ", content, payload, quiet);");
    }
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
    /++
        Payload value embedded in this message.
     +/
    T payload;

    /++
        Constructor that adds a passed payload to the internal stored [payload],
        creating a *shared* `Boxed`.
     +/
    this(T payload) shared pure /*@safe*/ nothrow @nogc
    {
        this.payload = cast(shared)payload;
    }
}


// boxed
/++
    Constructor function to create a `shared` [Boxed] with an unqualified
    template type.

    Example:
    ---
    IRCEvent event;  // ...
    plugin.state.messages ~= ThreadMessage.busMessage("header", boxed(event));
    plugin.state.messages ~= ThreadMessage.busMessage("other header", boxed("text payload"));
    plugin.state.messages ~= ThreadMessage.busMessage("ladida", boxed(42));
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
    A [core.thread.fiber.Fiber|Fiber] carrying a payload of type `T`, along with
    some metadata.

    Used interchangeably with [core.thread.fiber.Fiber|Fiber], but allows for
    casting to true `CarryingFiber!T`-ness to access the `payload` member.

    Example:
    ---
    void dg()
    {
        auto fiber = cast(CarryingFiber!bool)Fiber.getThis();
        assert(fiber !is null);  // Correct cast

        assert(fiber.payload);
        Fiber.yield();
        assert(!fiber.payload);
    }

    auto fiber = new CarryingFiber!bool(&dg, true, BufferSize.fiberStack);
    assert(fiber.called == 0);
    fiber.call();
    assert(fiber.called == 1);
    fiber.payload = false;
    fiber.call();
    ---

    Params:
        T = Type to embed into the class as the type of [CarryingFiber.payload].
 +/
final class CarryingFiber(T) : Fiber
{
    /++
        Embedded payload value in this fiber; what distinguishes it from plain
        [core.thread.fiber.Fiber|Fiber]s.
     +/
    T payload;

    /++
        String name of the function that created this [CarryingFiber].
     +/
    string creator;

    /++
        String name of the function that last called this [CarryingFiber]
        (via [CarryingFiber.call|.call()]).
     +/
    string caller;

    /++
        How many times this [CarryingFiber] has been called (via
        [CarryingFiber.call|.call()]).
     +/
    uint called;

    /++
        Whether or not this [CarryingFiber] has been called to completion and
        should be considered expired.
     +/
    bool hasExpired;

    /++
        Constructor function merely taking a function/delegate pointer, to call
        when invoking this fiber (via [CarryingFiber.call|.call()]).

        Params:
            fnOrDg = Function/delegate pointer to call when invoking this [CarryingFiber].
            args = Arguments to pass to the [core.thread.fiber.Fiber|Fiber] `super`
                constructor. If empty, its default arguments are used.
            creator = String name of the creating function of this [CarryingFiber].
     +/
    this(FnOrDg, Args...)
        (FnOrDg fnOrDg,
        Args args,
        const string creator = __FUNCTION__)  // attributes inferred
    if (isSomeFunction!FnOrDg && (!Args.length || allSatisfy!(isNumeric, Args)))
    {
        this.creator = creator;
        super(fnOrDg, args);
    }

    /++
        Constructor function taking a `T` `payload` to assign to its own
        internal [CarryingFiber.payload|this.payload], as well as a function/delegate pointer to call
        when invoking this fiber (via [CarryingFiber.call|.call()]).

        Params:
            fnOrDg = Function/delegate pointer to call when invoking this [CarryingFiber].
            payload = Payload to assign to [CarryingFiber.payload|.payload].
            args = Arguments to pass to the [core.thread.fiber.Fiber|Fiber] `super`
                constructor. If empty, the default arguments are used.
            creator = String name of the creating function of this [CarryingFiber].
     +/
    this(FnOrDg, Args...)
        (FnOrDg fnOrDg,
        T payload,
        Args args,
        const string creator = __FUNCTION__)  // ditto
    if (isSomeFunction!FnOrDg && (!Args.length || allSatisfy!(isNumeric, Args)))
    {
        this.payload = payload;
        this.creator = creator;
        super(fnOrDg, args);
    }

    /++
        Hijacks the invocation of the [core.thread.fiber.Fiber|Fiber] and injects
        the string name of the calling function into the [CarryingFiber.caller|caller]
        member before calling the [core.thread.fiber.Fiber|Fiber]'s own `.call()`.

        Params:
            caller = String name of the function calling this [CarryingFiber]
                (via [CarryingFiber.call|.call()]).

        Returns:
            A [core.object.Throwable|Throwable] if the underlying
            [core.thread.fiber.Fiber|Fiber] threw one when called; `null` otherwise.
     +/
    auto call(const string caller = __FUNCTION__)
    {
        scope(exit)
        {
            if (this.state == Fiber.State.TERM)
            {
                this.hasExpired = true;
            }
        }

        this.caller = caller;
        ++this.called;
        return super.call();
    }

    /++
        Hijacks the invocation of the [core.thread.fiber.Fiber|Fiber] and injects
        the string name of the calling function into the [CarryingFiber.caller]
        member before calling the [core.thread.fiber.Fiber|Fiber]'s own `.call()`.

        Overload that takes a `T` `payload` to assign to its own internal
        [CarryingFiber.payload|this.payload].

        Params:
            payload = Payload to assign to [CarryingFiber.payload|.payload].
            caller = String name of the function calling this [CarryingFiber]
                (via [CarryingFiber.call|.call()]).

        Returns:
            A [core.object.Throwable|Throwable] if the underlying
            [core.thread.fiber.Fiber|Fiber] threw one when called; `null` otherwise.
     +/
    auto call(T payload, const string caller = __FUNCTION__)
    {
        this.payload = payload;
        return this.call(caller);
    }

    /++
        Resets the [CarryingFiber.payload|payload] to its `.init` value.
     +/
    void resetPayload()
    {
        payload = T.init;
    }

    /++
        Safely returns the state of the fiber, taking into consideration it may
        have been reset.

        Returns:
            [core.thread.fiber.Fiber.State.TERM|Fiber.State.TERM] if the fiber has been
            reset; the state of the underlying [core.thread.fiber.Fiber|Fiber] otherwise.
     +/
    auto state()
    {
        return this.hasExpired ?
            Fiber.State.TERM :
            super.state();
    }
}

///
unittest
{
    import std.conv : to;

    static struct Payload
    {
        string s = "Hello";
        size_t i = 42;

        static auto getCompileTimeRandomPayload()
        {
            enum randomString = __TIMESTAMP__;
            return Payload(randomString, hashOf(randomString));
        }
    }

    static auto creatorTest(void delegate() dg)
    {
        import kameloso.constants : BufferSize;

        auto fiber = new CarryingFiber!Payload
            (dg,
            Payload.getCompileTimeRandomPayload(),
            BufferSize.fiberStack);
        assert((fiber.called == 0), fiber.called.to!string);
        return fiber;
    }

    static void callerTest1(CarryingFiber!Payload fiber)
    {
        immutable payload = Payload.getCompileTimeRandomPayload();

        assert((fiber.payload.s == payload.s), fiber.payload.s);
        assert((fiber.payload.i == payload.i), fiber.payload.i.to!string);
        fiber.call();
        assert((fiber.payload.s == Payload.init.s), fiber.payload.s);
        assert((fiber.payload.i == Payload.init.i), fiber.payload.i.to!string);
    }

    static void callerTest2(CarryingFiber!Payload fiber)
    {
        fiber.call();
    }

    void dg()
    {
        auto thisFiber = cast(CarryingFiber!Payload)Fiber.getThis();
        assert(thisFiber, "Incorrectly cast fiber: " ~ typeof(thisFiber).stringof);

        // __FUNCTION__ will be something like "kameloso.thread.__unittest_L577_C1.dg"
        enum expectedFunction = __FUNCTION__[0..$-2] ~ "dg";

        static if (__FUNCTION__ == expectedFunction)
        {
            enum expectedCreator = __FUNCTION__[0..$-2] ~ "creatorTest";
            enum expectedCaller1 = __FUNCTION__[0..$-2] ~ "callerTest1";
            enum expectedCaller2 = __FUNCTION__[0..$-2] ~ "callerTest2";

            // First state
            assert((thisFiber.creator == expectedCreator), thisFiber.creator);
            assert((thisFiber.caller == expectedCaller1), thisFiber.caller);
            assert((thisFiber.called == 1), thisFiber.called.to!string);
            thisFiber.resetPayload();
            Fiber.yield();

            // Second state
            assert((thisFiber.caller == expectedCaller2), thisFiber.caller);
            assert((thisFiber.called == 2), thisFiber.called.to!string);
        }
        else
        {
            enum message = "Bad logic slicing function names in `CarryingFiber` unit test; " ~
                "please report this as a bug. (Was there a change in the compiler?)";
            pragma(msg, message);

            // Yield once so the tests still pass
            Fiber.yield();
        }
    }

    auto fiber = creatorTest(&dg);
    callerTest1(fiber);
    callerTest2(fiber);
}


// carryingFiber
/++
    Convenience function creating a new [CarryingFiber] while inferring the payload
    type `T` from the passed `payload` argument.

    Params:
        T = Type to embed into the class as the type of [CarryingFiber.payload].
        fnOrDg = Function/delegate pointer to call when invoking the resulting [CarryingFiber].
        payload = Payload to assign to the [CarryingFiber.payload|payload] member
            of the resulting [CarryingFiber].
        args = Arguments to pass to the [core.thread.fiber.Fiber|Fiber] `super`
            constructor. If empty, its default arguments are used.
        caller = String name of the calling function creating the resulting [CarryingFiber].

    Returns:
        A [CarryingFiber] with an automatically-inferred template parameter `T`,
        whose [CarryingFiber.payload|payload] is set to the passed `payload`.
 +/
auto carryingFiber(T, FnOrDg, Args...)
    (FnOrDg fnOrDg,
    T payload,
    Args args,
    const string caller = __FUNCTION__)
if (isSomeFunction!FnOrDg && (!Args.length || allSatisfy!(isNumeric, Args)))
{
    import std.traits : Unqual;
    auto fiber = new CarryingFiber!(Unqual!T)(fnOrDg, payload, args);
    fiber.creator = caller;
    return fiber;
}

///
unittest
{
    import kameloso.constants : BufferSize;

    static struct Payload
    {
        string s;
        int i;
    }

    void dg() {}

    Payload payload;
    payload.s = "Hello";
    payload.i = 42;

    auto fiber = carryingFiber(&dg, payload, BufferSize.fiberStack);
    assert(fiber.payload == payload);
    fiber.call();
    assert(fiber.called == 1);
}


// interruptibleSleep
/++
    Sleep in small periods, checking the passed `abort` flag in between to see
    if we should break and return.

    This is useful when a different signal handler has been set up, as triggering
    it won't break sleeps. This way it does, assuming the `abort` flag is the
    same one the signal handler monitors. As such, take it by `ref`.

    Example:
    ---
    interruptibleSleep(1.seconds, abort);
    ---

    Params:
        dur = Duration to sleep for.
        abort = Pointer to the "abort" bool which, if set, means we should
            interrupt and return early.
 +/
void interruptibleSleep(const Duration dur, const bool* abort) @system
{
    import core.thread : Thread, msecs;

    static immutable step = 100.msecs;
    Duration left = dur;

    while (left > Duration.zero)
    {
        if (*abort) return;

        immutable nextStep = (left > step) ? step : left;

        if (nextStep <= Duration.zero) break;

        Thread.sleep(nextStep);
        left -= step;
    }
}


// getQuitMessage
/++
    Iterates the [kameloso.plugins.common.IRCPluginState.messages|messages] and
    [kameloso.plugins.common.IRCPluginState.priorityMessages|priorityMessages] arrays
    of each plugin. If a [kameloso.thread.ThreadMessage.MessageType.quit|quit]
    message is found, its content is returned.

    Note: The message arrays are not nulled out in this function.

    Params:
        plugins = Array of plugins to iterate.

    Returns:
        The `content` of a [kameloso.thread.ThreadMessage.MessageType.quit|quit] message,
        if one was received, otherwise an empty string.
 +/
auto getQuitMessage(IRCPlugin[] plugins)
{
    string quitMessage;  // mutable

    top:
    foreach (plugin; plugins)
    {
        foreach (const message; plugin.state.priorityMessages[])
        {
            if (message.type == ThreadMessage.MessageType.quit)
            {
                quitMessage = message.content;
                break top;
            }
        }

        foreach (const message; plugin.state.priorityMessages[])
        {
            if (message.type == ThreadMessage.MessageType.quit)
            {
                quitMessage = message.content;
                break top;
            }
        }
    }

    return quitMessage;
}
