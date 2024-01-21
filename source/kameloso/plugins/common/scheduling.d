/++
    The section of [kameloso.plugins.common] that deals with delaying executing
    of [core.thread.fiber.Fiber|Fiber]s and delegates to a later point in time,
    and registering such to await a specific type of [dialect.defs.IRCEvent|IRCEvent].

    This was all in one `plugins/common.d` file that just grew too big.

    See_Also:
        [kameloso.plugins.common],
        [kameloso.plugins.common.mixins]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.common.scheduling;

private:

import kameloso.plugins.common : IRCPlugin;
import dialect.defs;
import std.typecons : Flag, No, Yes;
import core.thread : Fiber;
import core.time : Duration;

public:


// delay
/++
    Queues a [core.thread.fiber.Fiber|Fiber] to be called at a point `duration`
    later, by appending it to the `plugin`'s
    [kameloso.plugins.common.IRCPluginState.scheduledFibers|IRCPluginState.scheduledFibers].

    Updates the
    [kameloso.plugins.common.IRCPluginState.nextScheduledTimestamp|IRCPluginState.nextScheduledFibers]
    timestamp so that the main loop knows when to next process the array of
    [kameloso.thread.ScheduledFiber|ScheduledFiber]s.

    Params:
        plugin = The current [kameloso.plugins.common.IRCPlugin|IRCPlugin].
        fiber = [core.thread.fiber.Fiber|Fiber] to enqueue to be executed at a
            later point in time.
        duration = Amount of time to delay the `fiber`.

    See_Also:
        [undelay]
 +/
void delay(
    IRCPlugin plugin,
    Fiber fiber,
    const Duration duration)
in ((fiber !is null), "Tried to delay a null fiber")
{
    import kameloso.thread : ScheduledFiber;
    import std.datetime.systime : Clock;

    immutable time = Clock.currStdTime + duration.total!"hnsecs";
    plugin.state.scheduledFibers ~= ScheduledFiber(fiber, time);
    plugin.state.updateSchedule();
}


// delay
/++
    Queues a [core.thread.fiber.Fiber|Fiber] to be called at a point `duration`
    later, by appending it to the `plugin`'s
    [kameloso.plugins.common.IRCPluginState.scheduledFibers|IRCPluginState.scheduledFibers].
    Overload that implicitly queues [core.thread.fiber.Fiber.getThis()|Fiber.getThis()].

    Params:
        plugin = The current [kameloso.plugins.common.IRCPlugin|IRCPlugin].
        duration = Amount of time to delay the implicit fiber in the current context.
        yield = Whether or not to immediately yield the fiber.

    See_Also:
        [undelay]
 +/
void delay(
    IRCPlugin plugin,
    const Duration duration,
    const Flag!"yield" yield)
in (Fiber.getThis(), "Tried to delay the current fiber outside of a fiber")
{
    delay(plugin, Fiber.getThis(), duration);
    if (yield) Fiber.yield();
}


// delay
/++
    Queues a `void delegate()` delegate to be called at a point `duration`
    later, by appending it to the `plugin`'s
    [kameloso.plugins.common.IRCPluginState.scheduledDelegates|IRCPluginState.scheduledDelegates].

    Updates the
    [kameloso.plugins.common.IRCPluginState.nextScheduledTimestamp|IRCPluginState.nextScheduledFibers]
    timestamp so that the main loop knows when to next process the array of
    [kameloso.thread.ScheduledDelegate|ScheduledDelegate]s.

    Params:
        plugin = The current [kameloso.plugins.common.IRCPlugin|IRCPlugin].
        dg = Delegate to enqueue to be executed at a later point in time.
        duration = Amount of time to delay the `fiber`.

    See_Also:
        [undelay]
 +/
void delay(
    IRCPlugin plugin,
    void delegate() dg,
    const Duration duration)
in ((dg !is null), "Tried to delay a null delegate")
{
    import kameloso.thread : ScheduledDelegate;
    import std.datetime.systime : Clock;

    immutable time = Clock.currStdTime + duration.total!"hnsecs";
    plugin.state.scheduledDelegates ~= ScheduledDelegate(dg, time);
    plugin.state.updateSchedule();
}


// undelay
/++
    Removes a [core.thread.fiber.Fiber|Fiber] from being called at any point later.

    Updates the `nextScheduledTimestamp` UNIX timestamp (by way of
    [kameloso.plugins.common.IRCPluginState.updateSchedule|IRCPluginState.updateSchedule])
    so that the main loop knows when to process the array of [core.thread.fiber.Fiber|Fiber]s.

    Do not destroy and free the removed [core.thread.fiber.Fiber|Fiber], as it may be reused.
    Simply `null` out the [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.common.IRCPlugin|IRCPlugin].
        fiber = [core.thread.fiber.Fiber|Fiber] to dequeue from being executed
            at a later point in time.

    See_Also:
        [delay]
 +/
void undelay(IRCPlugin plugin, Fiber fiber)
in ((fiber !is null), "Tried to remove a delayed null fiber")
{
    foreach (ref scheduledFiber; plugin.state.scheduledFibers)
    {
        if (scheduledFiber.fiber is fiber)
        {
            scheduledFiber.fiber = null;
        }
    }

    plugin.state.updateSchedule();
}


// undelay
/++
    Removes a [core.thread.fiber.Fiber|Fiber] from being called at any point later.
    Overload that implicitly removes [core.thread.fiber.Fiber.getThis()|Fiber.getThis()()].

    Params:
        plugin = The current [kameloso.plugins.common.IRCPlugin|IRCPlugin].

    See_Also:
        [delay]
 +/
void undelay(IRCPlugin plugin)
in (Fiber.getThis(), "Tried to call `undelay` from outside a fiber")
{
    return undelay(plugin, Fiber.getThis());
}


// undelay
/++
    Removes a `void delegate()` delegate from being called at any point later
    by nulling it.

    Updates the `nextScheduledTimestamp` UNIX timestamp so that the main loop knows
    when to process the array of delegates.

    Params:
        plugin = The current [kameloso.plugins.common.IRCPlugin|IRCPlugin].
        dg = Delegate to exempt from being executed at a later point in time.

    See_Also:
        [delay]
 +/
void undelay(IRCPlugin plugin, void delegate() dg)
in ((dg !is null), "Tried to remove a delayed null delegate")
{
    foreach (ref scheduledDg; plugin.state.scheduledDelegates)
    {
        if (scheduledDg.dg is dg)
        {
            scheduledDg.dg = null;
        }
    }

    plugin.state.updateSchedule();
}


// removeDelayedFiber
/++
    Deprecated alias for [undelay].

    Will be removed in a future release.
 +/
deprecated("Use `undelay` instead")
alias removeDelayedFiber = undelay;

/// ditto
deprecated("Use `undelay` instead")
alias removeDelayedDelegate = undelay;


// await
/++
    Queues a [core.thread.fiber.Fiber|Fiber] to be called whenever the next parsed
    and triggering [dialect.defs.IRCEvent|IRCEvent] matches the passed
    [dialect.defs.IRCEvent.Type|IRCEvent.Type] type.

    Params:
        plugin = The current [kameloso.plugins.common.IRCPlugin|IRCPlugin].
        fiber = [core.thread.fiber.Fiber|Fiber] to enqueue to be executed when the next
            [dialect.defs.IRCEvent|IRCEvent] of type `type` comes along.
        type = The kind of [dialect.defs.IRCEvent|IRCEvent] that should trigger the
            passed awaiting fiber.

    See_Also:
        [unawait]
 +/
void await(
    IRCPlugin plugin,
    Fiber fiber,
    const IRCEvent.Type type)
in ((fiber !is null), "Tried to set up a null fiber to await events")
in ((type != IRCEvent.Type.UNSET), "Tried to set up a fiber to await `IRCEvent.Type.UNSET`")
{
    plugin.state.awaitingFibers[type] ~= fiber;
}


// await
/++
    Queues a [core.thread.fiber.Fiber|Fiber] to be called whenever the next parsed
    and triggering [dialect.defs.IRCEvent|IRCEvent] matches the passed
    [dialect.defs.IRCEvent.Type|IRCEvent.Type] type.
    Overload that implicitly queues [core.thread.fiber.Fiber.getThis()|Fiber.getThis()].

    Params:
        plugin = The current [kameloso.plugins.common.IRCPlugin|IRCPlugin].
        type = The kind of [dialect.defs.IRCEvent|IRCEvent] that should trigger this
            implicit awaiting fiber (in the current context).
        yield = Whether or not to immediately yield the fiber.

    See_Also:
        [unawait]
 +/
void await(
    IRCPlugin plugin,
    const IRCEvent.Type type,
    const Flag!"yield" yield)
in (Fiber.getThis(), "Tried to `await` the current fiber outside of a fiber")
in ((type != IRCEvent.Type.UNSET), "Tried to set up a fiber to await `IRCEvent.Type.UNSET`")
{
    plugin.state.awaitingFibers[type] ~= Fiber.getThis();
    if (yield) Fiber.yield();
}


// await
/++
    Queues a [core.thread.fiber.Fiber|Fiber] to be called whenever the next parsed
    and triggering [dialect.defs.IRCEvent|IRCEvent] matches any of the passed
    [dialect.defs.IRCEvent.Type|IRCEvent.Type] types.

    Params:
        plugin = The current [kameloso.plugins.common.IRCPlugin|IRCPlugin].
        fiber = [core.thread.fiber.Fiber|Fiber] to enqueue to be executed when the next
            [dialect.defs.IRCEvent|IRCEvent] of type `type` comes along.
        types = The kinds of [dialect.defs.IRCEvent|IRCEvent] that should trigger
            the passed awaiting fiber, in an array with elements of type
            [dialect.defs.IRCEvent.Type|IRCEvent.Type].

    See_Also:
        [unawait]
 +/
void await(
    IRCPlugin plugin,
    Fiber fiber,
    const IRCEvent.Type[] types)
in ((fiber !is null), "Tried to set up a null fiber to await events")
{
    foreach (immutable type; types)
    {
        assert((type != IRCEvent.Type.UNSET),
            "Tried to set up a fiber to await `IRCEvent.Type.UNSET`");
        plugin.state.awaitingFibers[type] ~= fiber;
    }
}


// await
/++
    Queues a [core.thread.fiber.Fiber|Fiber] to be called whenever the next parsed
    and triggering [dialect.defs.IRCEvent|IRCEvent] matches any of the passed
    [dialect.defs.IRCEvent.Type|IRCEvent.Type] types.
    Overload that implicitly queues [core.thread.fiber.Fiber.getThis()|Fiber.getThis()].

    Params:
        plugin = The current [kameloso.plugins.common.IRCPlugin|IRCPlugin].
        types = The kinds of [dialect.defs.IRCEvent|IRCEvent] that should trigger
            this implicit awaiting fiber (in the current context), in an array
            with elements of type [dialect.defs.IRCEvent.Type|IRCEvent.Type].
        yield = Whether or not to immediately yield the fiber.

    See_Also:
        [unawait]
 +/
void await(
    IRCPlugin plugin,
    const IRCEvent.Type[] types,
    const Flag!"yield" yield)
in (Fiber.getThis(), "Tried to `await` the current fiber outside of a fiber")
{
    foreach (immutable type; types)
    {
        assert((type != IRCEvent.Type.UNSET),
            "Tried to set up the current fiber to await `IRCEvent.Type.UNSET`");
        plugin.state.awaitingFibers[type] ~= Fiber.getThis();
    }

    if (yield) Fiber.yield();
}


// await
/++
    Queues a `void delegate(IRCEvent)` delegate to be called whenever the
    next parsed and triggering const [dialect.defs.IRCEvent|IRCEvent] matches the
    passed [dialect.defs.IRCEvent.Type|IRCEvent.Type] type.

    Note: The delegate stays in the queue until a call to [unawait] it is made.

    Params:
        plugin = The current [kameloso.plugins.common.IRCPlugin|IRCPlugin].
        dg = Delegate to enqueue to be executed when the next const
            [dialect.defs.IRCEvent|IRCEvent] of type `type` comes along.
        type = The kind of [dialect.defs.IRCEvent|IRCEvent] that should trigger the
            passed awaiting delegate.

    See_Also:
        [unawait]
 +/
void await(
    IRCPlugin plugin,
    void delegate(IRCEvent) dg,
    const IRCEvent.Type type)
in ((dg !is null), "Tried to set up a null delegate to await events")
in ((type != IRCEvent.Type.UNSET), "Tried to set up a delegate to await `IRCEvent.Type.UNSET`")
{
    plugin.state.awaitingDelegates[type] ~= dg;
}


// await
/++
    Queues a `void delegate(IRCEvent)` delegate to be called whenever the
    next parsed and triggering const [dialect.defs.IRCEvent|IRCEvent] matches
    the passed [dialect.defs.IRCEvent.Type|IRCEvent.Type] types. Overload that
    takes an array of types.

    Note: The delegate stays in the queue until a call to [unawait] it is made.

    Params:
        plugin = The current [kameloso.plugins.common.IRCPlugin|IRCPlugin].
        dg = Delegate to enqueue to be executed when the next const
            [dialect.defs.IRCEvent|IRCEvent] of type `type` comes along.
        types = An array of the kinds of [dialect.defs.IRCEvent|IRCEvent]s that
            should trigger the passed awaiting delegate.

    See_Also:
        [unawait]
 +/
void await(
    IRCPlugin plugin,
    void delegate(IRCEvent) dg,
    const IRCEvent.Type[] types)
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
    triggering [dialect.defs.IRCEvent|IRCEvent] matches the passed
    [dialect.defs.IRCEvent.Type|IRCEvent.Type] type. Implementation template.

    Params:
        thing = Thing to dequeue from being executed when the next
            [dialect.defs.IRCEvent|IRCEvent] of type `type` comes along.
        aa = Associative array to remove entries from.
        type = The kind of [dialect.defs.IRCEvent|IRCEvent] that would trigger the
            passed awaiting thing.
        fully = Whether or not to unawait all instances of the thing.

    See_Also:
        [unawait]
 +/
private void unawaitImpl(Thing, AA)
    (Thing thing,
    ref AA aa,
    const IRCEvent.Type type,
    const Flag!"fully" fully)
in ((thing !is null), "Tried to unlist a null " ~ Thing.stringof ~ " from awaiting events")
in ((type != IRCEvent.Type.UNSET), "Tried to unlist a " ~ Thing.stringof ~
    " from awaiting `IRCEvent.Type.UNSET`")
{
    import std.algorithm.mutation : SwapStrategy, remove;

    void removeForType(const IRCEvent.Type type)
    {
        size_t[] toRemove;

        foreach (immutable i, awaitingThing; aa[type])
        {
            if (awaitingThing is thing)
            {
                toRemove ~= i;
                if (!fully) break;
            }
        }

        if (toRemove.length)
        {
            foreach_reverse (immutable i; toRemove)
            {
                aa[type] = aa[type].remove!(SwapStrategy.unstable)(i);
            }
        }
    }

    if (type == IRCEvent.Type.ANY)
    {
        import std.traits : EnumMembers;

        foreach (immutable thisType; EnumMembers!(IRCEvent.Type))
        {
            if (aa[thisType].length) removeForType(thisType);
        }
    }
    else
    {
        if (aa[type].length) removeForType(type);
    }
}


// unawait
/++
    Dequeues a [core.thread.fiber.Fiber|Fiber] from being called whenever the
    next parsed and triggering [dialect.defs.IRCEvent|IRCEvent] matches the passed
    [dialect.defs.IRCEvent.Type|IRCEvent.Type] type.

    Params:
        plugin = The current [kameloso.plugins.common.IRCPlugin|IRCPlugin].
        fiber = [core.thread.fiber.Fiber|Fiber] to dequeue from being executed
            when the next [dialect.defs.IRCEvent|IRCEvent] of type `type` comes along.
        type = The kind of [dialect.defs.IRCEvent|IRCEvent] that would trigger the
            passed awaiting fiber.
        fully = Whether or not to unawait all instances of the fiber.

    See_Also:
        [unawaitImpl]
        [await]
 +/
void unawait(
    IRCPlugin plugin,
    Fiber fiber,
    const IRCEvent.Type type,
    const Flag!"fully" fully = No.fully)
in (fiber, "Tried to call `unawait` with a null fiber")
{
    return unawaitImpl(fiber, plugin.state.awaitingFibers, type, fully);
}


// unawait
/++
    Dequeues a [core.thread.fiber.Fiber|Fiber] from being called whenever the
    next parsed and triggering [dialect.defs.IRCEvent|IRCEvent] matches the passed
    [dialect.defs.IRCEvent.Type|IRCEvent.Type] type. Overload that implicitly dequeues
    [core.thread.fiber.Fiber.getThis()|Fiber.getThis()].

    Params:
        plugin = The current [kameloso.plugins.common.IRCPlugin|IRCPlugin].
        type = The kind of [dialect.defs.IRCEvent|IRCEvent] that would trigger this
            implicit awaiting fiber (in the current context).
        fully = Whether or not to unawait all instances of the current fiber.

    See_Also:
        [unawaitImpl]
        [await]
 +/
void unawait(
    IRCPlugin plugin,
    const IRCEvent.Type type,
    const Flag!"fully" fully = No.fully)
in (Fiber.getThis(), "Tried to call `unawait` from outside a fiber")
{
    return unawait(plugin, Fiber.getThis(), type, fully);
}


// unawait
/++
    Dequeues a [core.thread.fiber.Fiber|Fiber] from being called whenever the
    next parsed and triggering [dialect.defs.IRCEvent|IRCEvent] matches any of
    the passed [dialect.defs.IRCEvent.Type|IRCEvent.Type] types.

    Params:
        plugin = The current [kameloso.plugins.common.IRCPlugin|IRCPlugin].
        fiber = [core.thread.fiber.Fiber|Fiber] to dequeue from being executed
            when the next [dialect.defs.IRCEvent|IRCEvent] of type `type` comes along.
        types = The kinds of [dialect.defs.IRCEvent|IRCEvent] that should trigger
            the passed awaiting fiber, in an array with elements of type
            [dialect.defs.IRCEvent.Type|IRCEvent.Type].
        fully = Whether or not to unawait all instances of the fiber.

    See_Also:
        [unawaitImpl]
        [await]
 +/
void unawait(
    IRCPlugin plugin,
    Fiber fiber,
    const IRCEvent.Type[] types,
    const Flag!"fully" fully = No.fully)
in (fiber, "Tried to call `unawait` with a null fiber")
{
    foreach (immutable type; types)
    {
        unawait(plugin, fiber, type, fully);
    }
}


// unawait
/++
    Dequeues a [core.thread.fiber.Fiber|Fiber] from being called whenever the
    next parsed and triggering [dialect.defs.IRCEvent|IRCEvent] matches any of the passed
    [dialect.defs.IRCEvent.Type|IRCEvent.Type] types. Overload that implicitly dequeues
    [core.thread.fiber.Fiber.getThis()|Fiber.getThis()].

    Params:
        plugin = The current [kameloso.plugins.common.IRCPlugin|IRCPlugin].
        types = The kinds of [dialect.defs.IRCEvent|IRCEvent] that should trigger
            this implicit awaiting fiber (in the current context), in an array
            with elements of type [dialect.defs.IRCEvent.Type|IRCEvent.Type].
        fully = Whether or not to unawait all instances of the current fiber.

    See_Also:
        [unawaitImpl]
        [await]
 +/
void unawait(
    IRCPlugin plugin,
    const IRCEvent.Type[] types,
    const Flag!"fully" fully = No.fully)
in (Fiber.getThis(), "Tried to call `unawait` from outside a fiber")
{
    foreach (immutable type; types)
    {
        unawait(plugin, Fiber.getThis(), type, fully);
    }
}


// unawait
/++
    Dequeues a `void delegate(IRCEvent)` delegate from being called whenever
    the next parsed and triggering [dialect.defs.IRCEvent|IRCEvent] matches the passed
    [dialect.defs.IRCEvent.Type|IRCEvent.Type] type.

    Params:
        plugin = The current [kameloso.plugins.common.IRCPlugin|IRCPlugin].
        dg = Delegate to dequeue from being executed when the next
            [dialect.defs.IRCEvent|IRCEvent] of type `type` comes along.
        type = The kind of [dialect.defs.IRCEvent|IRCEvent] that would trigger the
            passed awaiting delegate.
        fully = Whether or not to unawait all instances of the delegate.

    See_Also:
        [unawaitImpl]
        [await]
 +/
void unawait(
    IRCPlugin plugin,
    void delegate(IRCEvent) dg,
    const IRCEvent.Type type,
    const Flag!"fully" fully = No.fully)
in ((dg !is null), "Tried to call `unawait` with a null delegate")
{
    return unawaitImpl(dg, plugin.state.awaitingDelegates, type, fully);
}


// unawait
/++
    Dequeues a `void delegate(IRCEvent)` delegate from being called whenever
    the next parsed and triggering [dialect.defs.IRCEvent|IRCEvent] matches any
    of the passed [dialect.defs.IRCEvent.Type|IRCEvent.Type] types. Overload that
    takes a array of types.

    Params:
        plugin = The current [kameloso.plugins.common.IRCPlugin|IRCPlugin].
        dg = Delegate to dequeue from being executed when the next
            [dialect.defs.IRCEvent|IRCEvent] of type `type` comes along.
        types = An array of the kinds of [dialect.defs.IRCEvent|IRCEvent]s that
            would trigger the passed awaiting delegate.
        fully = Whether or not to unawait all instances of the delegate.

    See_Also:
        [unawaitImpl]
        [await]
 +/
void unawait(
    IRCPlugin plugin,
    void delegate(IRCEvent) dg,
    const IRCEvent.Type[] types,
    const Flag!"fully" fully = No.fully)
in ((dg !is null), "Tried to call `unawait` with a null delegate")
{
    foreach (immutable type; types)
    {
        unawaitImpl(dg, plugin.state.awaitingDelegates, type, fully);
    }
}
