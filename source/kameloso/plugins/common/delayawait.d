/++
    The section of [kameloso.plugins.common] that deals with delaying executing
    of [core.thread.fiber.Fiber]s and delegates to a later point in time, and registering
    such to await a specific type of [dialect.defs.IRCEvent].

    This was all in one `plugins/common.d` file that just grew too big.
 +/
module kameloso.plugins.common.delayawait;

version(WithPlugins):

private:

import kameloso.plugins.common.core : IRCPlugin;
import dialect.defs;
import std.traits : isSomeFunction;
import std.typecons : Flag, No, Yes;
import core.thread : Fiber;

public:


// delay
/++
    Queues a [core.thread.fiber.Fiber] to be called at a point `duration`
    seconds or milliseconds later, by appending it to the `plugin`'s
    [kameloso.plugins.common.core.IRCPluginState.scheduledFibers].

    Updates the [kameloso.plugins.common.core.IRCPluginState.nextScheduledTimestamp]
    timestamp so that the main loop knows when to next process the array of
    [kameloso.thread.ScheduledFiber]s.

    Params:
        plugin = The current [kameloso.plugins.common.core.IRCPlugin].
        fiber = [core.thread.fiber.Fiber] to enqueue to be executed at a later point in time.
        duration = Amount of time to delay the `fiber`.
        msecs = Whether `duration` is in milliseconds or seconds.
 +/
void delay(IRCPlugin plugin, Fiber fiber, const long duration,
    const Flag!"msecs" msecs = No.msecs)
in ((fiber !is null), "Tried to delay a null Fiber")
{
    import kameloso.thread : ScheduledFiber;
    import std.datetime.systime : Clock;

    immutable time = Clock.currStdTime + (msecs ?
        (duration * 10_000) :  // hnsecs -> msecs
        (duration * 10_000_000));  // hnsecs -> seconds
    plugin.state.scheduledFibers ~= ScheduledFiber(fiber, time);

    plugin.state.updateSchedule();
}


// delay
/++
    Queues a [core.thread.fiber.Fiber] to be called at a point `duration`
    seconds or milliseconds later, by appending it to the `plugin`'s
    [kameloso.plugins.common.core.IRCPluginState.scheduledFibers].
    Overload that implicitly queues [core.thread.fiber.Fiber.getThis].

    Params:
        plugin = The current [kameloso.plugins.common.core.IRCPlugin].
        duration = Amount of time to delay the implicit fiber in the current context.
        msecs = Whether `period` is in milliseconds or seconds.
        yield = Whether or not to immediately yield the Fiber.
 +/
void delay(IRCPlugin plugin, const long duration, const Flag!"msecs" msecs = No.msecs,
    const Flag!"yield" yield = No.yield)
in (Fiber.getThis, "Tried to delay the current Fiber outside of a Fiber")
{
    delay(plugin, Fiber.getThis, duration, msecs);
    if (yield) Fiber.yield();
}


// delay
/++
    Queues a [core.thread.fiber.Fiber] to be called at a point `duration`
    seconds later, by appending it to the `plugin`'s
    [kameloso.plugins.common.core.IRCPluginState.scheduledFibers].
    Overload that implicitly queues [core.thread.fiber.Fiber.getThis].

    Params:
        plugin = The current [kameloso.plugins.common.core.IRCPlugin].
        duration = Amount of time to delay the implicit fiber in the current context.
        yield = Whether or not to immediately yield the Fiber.
 +/
void delay(IRCPlugin plugin, const long duration, const Flag!"yield" yield)
in (Fiber.getThis, "Tried to delay the current Fiber outside of a Fiber")
{
    delay(plugin, Fiber.getThis, duration, No.msecs);
    if (yield) Fiber.yield();
}


// delay
/++
    Queues a `void delegate()` delegate to be called at a point `duration`
    seconds or milliseconds later, by appending it to the `plugin`'s
    [kameloso.plugins.common.core.IRCPluginState.scheduledDelegates].

    Updates the [kameloso.plugins.common.core.IRCPluginState.nextScheduledTimestamp]
    timestamp so that the main loop knows when to next process the array of
    [kameloso.thread.ScheduledDelegate]s.

    Params:
        plugin = The current [kameloso.plugins.common.core.IRCPlugin].
        dg = Delegate to enqueue to be executed at a later point in time.
        duration = Amount of time to delay the `fiber`.
        msecs = Whether `duration` is in milliseconds or seconds.
 +/
void delay(IRCPlugin plugin, void delegate() dg, const long duration,
    const Flag!"msecs" msecs = No.msecs)
in ((dg !is null), "Tried to delay a null delegate")
{
    import kameloso.thread : ScheduledDelegate;
    import std.datetime.systime : Clock;

    immutable time = Clock.currStdTime + (msecs ?
        (duration * 10_000) :  // hnsecs -> msecs
        (duration * 10_000_000));  // hnsecs -> seconds
    plugin.state.scheduledDelegates ~= ScheduledDelegate(dg, time);

    plugin.state.updateSchedule();
}


// removeDelayedFiber
/++
    Removes a [core.thread.fiber.Fiber] from being called at any point later.

    Updates the `nextScheduledTimestamp` UNIX timestamp so that the main loop knows
    when to process the array of [core.thread.fiber.Fiber]s.

    Params:
        plugin = The current [kameloso.plugins.common.core.IRCPlugin].
        fiber = [core.thread.fiber.Fiber] to dequeue from being executed at a later point in time.
 +/
void removeDelayedFiber(IRCPlugin plugin, Fiber fiber)
in ((fiber !is null), "Tried to remove a delayed null Fiber")
{
    import std.algorithm.mutation : SwapStrategy, remove;
    import std.algorithm.searching : countUntil;

    size_t[] toRemove;

    foreach (immutable i, scheduledFiber; plugin.state.scheduledFibers)
    {
        if (scheduledFiber.fiber is fiber)
        {
            toRemove ~= i;
        }
    }

    if (!toRemove.length) return;

    foreach_reverse (immutable i; toRemove)
    {
        plugin.state.scheduledFibers = plugin.state.scheduledFibers
            .remove!(SwapStrategy.unstable)(i);
    }

    plugin.state.updateSchedule();
}


// removeDelayedFiber
/++
    Removes a [core.thread.fiber.Fiber] from being called at any point later.
    Overload that implicitly removes [core.thread.fiber.Fiber.getThis].

    Params:
        plugin = The current [kameloso.plugins.common.core.IRCPlugin].
 +/
void removeDelayedFiber(IRCPlugin plugin)
{
    return plugin.removeDelayedFiber(Fiber.getThis);
}


// removeDelayedDelegate
/++
    Removes a `void delegate()` delegate from being called at any point later.

    Updates the `nextScheduledTimestamp` UNIX timestamp so that the main loop knows
    when to process the array of delegates.

    Params:
        plugin = The current [kameloso.plugins.common.core.IRCPlugin].
        dg = Delegate to dequeue from being executed at a later point in time.
 +/
void removeDelayedDelegate(IRCPlugin plugin, void delegate() dg)
in ((dg !is null), "Tried to remove a delayed null delegate")
{
    import std.algorithm.mutation : SwapStrategy, remove;
    import std.algorithm.searching : countUntil;

    size_t[] toRemove;

    foreach (immutable i, scheduledDg; plugin.state.scheduledDelegates)
    {
        if (scheduledDg.dg is dg)
        {
            toRemove ~= i;
        }
    }

    if (!toRemove.length) return;

    foreach_reverse (immutable i; toRemove)
    {
        plugin.state.scheduledDelegates = plugin.state.scheduledDelegates
            .remove!(SwapStrategy.unstable)(i);
    }

    plugin.state.updateSchedule();
}


// await
/++
    Queues a [core.thread.fiber.Fiber] to be called whenever the next parsed and
    triggering [dialect.defs.IRCEvent] matches the passed
    [dialect.defs.IRCEvent.Type] type.

    Params:
        plugin = The current [kameloso.plugins.common.core.IRCPlugin].
        fiber = [core.thread.fiber.Fiber] to enqueue to be executed when the next
            [dialect.defs.IRCEvent] of type `type` comes along.
        type = The kind of [dialect.defs.IRCEvent] that should trigger the
            passed awaiting fiber.
 +/
void await(IRCPlugin plugin, Fiber fiber, const IRCEvent.Type type)
in ((fiber !is null), "Tried to set up a null Fiber to await events")
in ((type != IRCEvent.Type.UNSET), "Tried to set up a Fiber to await `IRCEvent.Type.UNSET`")
{
    plugin.state.awaitingFibers[type] ~= fiber;
}


// await
/++
    Queues a [core.thread.fiber.Fiber] to be called whenever the next parsed and
    triggering [dialect.defs.IRCEvent] matches the passed
    [dialect.defs.IRCEvent.Type] type.
    Overload that implicitly queues [core.thread.fiber.Fiber.getThis].

    Params:
        plugin = The current [kameloso.plugins.common.core.IRCPlugin].
        type = The kind of [dialect.defs.IRCEvent] that should trigger this
            implicit awaiting fiber (in the current context).
        yield = Whether or not to immediately yield the Fiber.
 +/
void await(IRCPlugin plugin, const IRCEvent.Type type,
    const Flag!"yield" yield = No.yield)
in (Fiber.getThis, "Tried to `await` the current Fiber outside of a Fiber")
in ((type != IRCEvent.Type.UNSET), "Tried to set up a Fiber to await `IRCEvent.Type.UNSET`")
{
    plugin.state.awaitingFibers[type] ~= Fiber.getThis;
    if (yield) Fiber.yield();
}


// await
/++
    Queues a [core.thread.fiber.Fiber] to be called whenever the next parsed and
    triggering [dialect.defs.IRCEvent] matches any of the passed
    [dialect.defs.IRCEvent.Type] types.

    Params:
        plugin = The current [kameloso.plugins.common.core.IRCPlugin].
        fiber = [core.thread.fiber.Fiber] to enqueue to be executed when the next
            [dialect.defs.IRCEvent] of type `type` comes along.
        types = The kinds of [dialect.defs.IRCEvent] that should trigger
            the passed awaiting fiber, in an array with elements of type
            [dialect.defs.IRCEvent.Type].
 +/
void await(IRCPlugin plugin, Fiber fiber, const IRCEvent.Type[] types)
in ((fiber !is null), "Tried to set up a null Fiber to await events")
{
    foreach (immutable type; types)
    {
        assert((type != IRCEvent.Type.UNSET),
            "Tried to set up a Fiber to await `IRCEvent.Type.UNSET`");
        plugin.state.awaitingFibers[type] ~= fiber;
    }
}


// await
/++
    Queues a [core.thread.fiber.Fiber] to be called whenever the next parsed and
    triggering [dialect.defs.IRCEvent] matches any of the passed
    [dialect.defs.IRCEvent.Type] types.
    Overload that implicitly queues [core.thread.fiber.Fiber.getThis].

    Params:
        plugin = The current [kameloso.plugins.common.core.IRCPlugin].
        types = The kinds of [dialect.defs.IRCEvent] that should trigger
            this implicit awaiting fiber (in the current context), in an array
            with elements of type [dialect.defs.IRCEvent.Type].
        yield = Whether or not to immediately yield the Fiber.
 +/
void await(IRCPlugin plugin, const IRCEvent.Type[] types,
    const Flag!"yield" yield = No.yield)
in (Fiber.getThis, "Tried to `await` the current Fiber outside of a Fiber")
{
    foreach (immutable type; types)
    {
        assert((type != IRCEvent.Type.UNSET),
            "Tried to set up the current Fiber to await `IRCEvent.Type.UNSET`");
        plugin.state.awaitingFibers[type] ~= Fiber.getThis;
    }

    if (yield) Fiber.yield();
}


// await
/++
    Queues a `void delegate(const IRCEvent)` delegate to be called whenever the next parsed and
    triggering const [dialect.defs.IRCEvent] matches the passed
    [dialect.defs.IRCEvent.Type] type.

    Note: The delegate stays in the queue until a call to [unawait] it is made.

    Params:
        plugin = The current [kameloso.plugins.common.core.IRCPlugin].
        dg = Delegate to enqueue to be executed when the next const
            [dialect.defs.IRCEvent] of type `type` comes along.
        type = The kind of [dialect.defs.IRCEvent] that should trigger the
            passed awaiting delegate.
 +/
void await(IRCPlugin plugin, void delegate(const IRCEvent) dg, const IRCEvent.Type type)
in ((dg !is null), "Tried to set up a null delegate to await events")
in ((type != IRCEvent.Type.UNSET), "Tried to set up a delegate to await `IRCEvent.Type.UNSET`")
{
    plugin.state.awaitingDelegates[type] ~= dg;
}


// await
/++
    Queues a `void delegate(const IRCEvent)` delegate to be called whenever the next parsed and
    triggering const [dialect.defs.IRCEvent] matches the passed
    [dialect.defs.IRCEvent.Type] types. Overload that takes an array of types.

    Note: The delegate stays in the queue until a call to [unawait] it is made.

    Params:
        plugin = The current [kameloso.plugins.common.core.IRCPlugin].
        dg = Delegate to enqueue to be executed when the next const
            [dialect.defs.IRCEvent] of type `type` comes along.
        types = An array of the kinds of [dialect.defs.IRCEvent]s that should trigger the
            passed awaiting delegate.
 +/
void await(IRCPlugin plugin, void delegate(const IRCEvent) dg, const IRCEvent.Type[] types)
in ((dg !is null), "Tried to set up a null delegate to await events")
{
    foreach (immutable type; types)
    {
        assert((type != IRCEvent.Type.UNSET),
            "Tried to set up a delegate to await `IRCEvent.Type.UNSET`");
        plugin.state.awaitingDelegates[type] ~= dg;
    }
}


// unawaitImpl
/++
    Dequeues something from being called whenever the next parsed and
    triggering [dialect.defs.IRCEvent] matches the passed
    [dialect.defs.IRCEvent.Type] type. Implementation template.

    Params:
        plugin = The current [kameloso.plugins.common.core.IRCPlugin].
        thing = Thing to dequeue from being executed when the next
            [dialect.defs.IRCEvent] of type `type` comes along.
        type = The kind of [dialect.defs.IRCEvent] that would trigger the
            passed awaiting thing.
 +/
private void unawaitImpl(Thing, AA)(Thing thing, ref AA aa, const IRCEvent.Type type)
in ((thing !is null), "Tried to unlist a null " ~ Thing.stringof ~ " from awaiting events")
in ((type != IRCEvent.Type.UNSET), "Tried to unlist a " ~ Thing.stringof ~
    " from awaiting `IRCEvent.Type.UNSET`")
{
    import std.algorithm.mutation : SwapStrategy, remove;
    import std.algorithm.searching : countUntil;

    void removeForType(const IRCEvent.Type type)
    {
        foreach (immutable i, awaitingThing; aa[type])
        {
            if (awaitingThing is thing)
            {
                aa[type] = aa[type].remove!(SwapStrategy.unstable)(i);
                break;
            }
        }
    }

    if (type == IRCEvent.Type.ANY)
    {
        import std.traits : EnumMembers;

        static immutable allTypes = [ EnumMembers!(IRCEvent.Type) ];

        foreach (immutable thisType; allTypes)
        {
            removeForType(thisType);
        }
    }
    else
    {
        removeForType(type);
    }
}


// unawait
/++
    Dequeues a [core.thread.fiber.Fiber] from being called whenever the next parsed and
    triggering [dialect.defs.IRCEvent] matches the passed
    [dialect.defs.IRCEvent.Type] type.

    Params:
        plugin = The current [kameloso.plugins.common.core.IRCPlugin].
        fiber = [core.thread.fiber.Fiber] to dequeue from being executed when the next
            [dialect.defs.IRCEvent] of type `type` comes along.
        type = The kind of [dialect.defs.IRCEvent] that would trigger the
            passed awaiting fiber.
 +/
void unawait(IRCPlugin plugin, Fiber fiber, const IRCEvent.Type type)
{
    return unawaitImpl(fiber, plugin.state.awaitingFibers, type);
}


// unawait
/++
    Dequeues a [core.thread.fiber.Fiber] from being called whenever the next parsed and
    triggering [dialect.defs.IRCEvent] matches the passed
    [dialect.defs.IRCEvent.Type] type. Overload that implicitly dequeues
    [core.thread.fiber.Fiber.getThis].

    Params:
        plugin = The current [kameloso.plugins.common.core.IRCPlugin].
        type = The kind of [dialect.defs.IRCEvent] that would trigger this
            implicit awaiting fiber (in the current context).
 +/
void unawait(IRCPlugin plugin, const IRCEvent.Type type)
{
    return unawait(plugin, Fiber.getThis, type);
}


// unawait
/++
    Dequeues a [core.thread.fiber.Fiber] from being called whenever the next parsed and
    triggering [dialect.defs.IRCEvent] matches any of the passed
    [dialect.defs.IRCEvent.Type] types.

    Params:
        plugin = The current [kameloso.plugins.common.core.IRCPlugin].
        fiber = [core.thread.fiber.Fiber] to dequeue from being executed when the next
            [dialect.defs.IRCEvent] of type `type` comes along.
        types = The kinds of [dialect.defs.IRCEvent] that should trigger
            the passed awaiting fiber, in an array with elements of type
            [dialect.defs.IRCEvent.Type].
 +/
void unawait(IRCPlugin plugin, Fiber fiber, const IRCEvent.Type[] types)
{
    foreach (immutable type; types)
    {
        unawait(plugin, fiber, type);
    }
}


// unawait
/++
    Dequeues a [core.thread.fiber.Fiber] from being called whenever the next parsed and
    triggering [dialect.defs.IRCEvent] matches any of the passed
    [dialect.defs.IRCEvent.Type] types. Overload that implicitly dequeues
    [core.thread.fiber.Fiber.getThis].

    Params:
        plugin = The current [kameloso.plugins.common.core.IRCPlugin].
        types = The kinds of [dialect.defs.IRCEvent] that should trigger
            this implicit awaiting fiber (in the current context), in an array
            with elements of type [dialect.defs.IRCEvent.Type].
 +/
void unawait(IRCPlugin plugin, const IRCEvent.Type[] types)
{
    foreach (immutable type; types)
    {
        unawait(plugin, Fiber.getThis, type);
    }
}


// unawait
/++
    Dequeues a `void delegate(const IRCEvent)` delegate from being called whenever
    the next parsed and triggering [dialect.defs.IRCEvent] matches the passed
    [dialect.defs.IRCEvent.Type] type.

    Params:
        plugin = The current [kameloso.plugins.common.core.IRCPlugin].
        dg = Delegate to dequeue from being executed when the next
            [dialect.defs.IRCEvent] of type `type` comes along.
        type = The kind of [dialect.defs.IRCEvent] that would trigger the
            passed awaiting delegate.
 +/
void unawait(IRCPlugin plugin, void delegate(const IRCEvent) dg, const IRCEvent.Type type)
{
    return unawaitImpl(dg, plugin.state.awaitingDelegates, type);
}


// unawait
/++
    Dequeues a `void delegate(const IRCEvent)` delegate from being called whenever
    the next parsed and triggering [dialect.defs.IRCEvent] matches any of the passed
    [dialect.defs.IRCEvent.Type] types. Overload that takes a array of types.

    Params:
        plugin = The current [kameloso.plugins.common.core.IRCPlugin].
        dg = Delegate to dequeue from being executed when the next
            [dialect.defs.IRCEvent] of type `type` comes along.
        types = An array of the kinds of [dialect.defs.IRCEvent]s that would trigger the
            passed awaiting delegate.
 +/
void unawait(IRCPlugin plugin, void delegate(const IRCEvent) dg, const IRCEvent.Type[] types)
{
    foreach (immutable type; types)
    {
        unawaitImpl(dg, plugin.state.awaitingDelegates, type);
    }
}
