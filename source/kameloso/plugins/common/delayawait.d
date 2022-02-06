module kameloso.plugins.common.delayawait;

version(WithPlugins):

private:

import kameloso.plugins.common.core : IRCPlugin;
import dialect.defs;
import std.traits : isSomeFunction;
import std.typecons : Flag, No, Yes;
import core.thread : Fiber;
import core.time : Duration;

public:

void delay(IRCPlugin plugin, Fiber fiber, const Duration duration)
in ((fiber !is null), "Tried to delay a null Fiber")
{}

void delay(IRCPlugin plugin, const Duration duration, const Flag!"yield" yield)
in (Fiber.getThis, "Tried to delay the current Fiber outside of a Fiber")
{}

void delay(IRCPlugin plugin, void delegate() dg, const Duration duration)
in ((dg !is null), "Tried to delay a null delegate")
{}

void removeDelayedDelegate(IRCPlugin plugin, void delegate() dg)
in ((dg !is null), "Tried to remove a delayed null delegate")
{}

void await(Fiber fiber, const IRCEvent.Type type)
in ((fiber !is null), "Tried to set up a null Fiber to await events")
in ((type != IRCEvent.Type.UNSET), "Tried to set up a delegate to await `IRCEvent.Type.UNSET`")
{}

void await(void delegate(const IRCEvent) dg, const IRCEvent.Type[] types)
in ((dg !is null), "Tried to set up a null delegate to await events")
{}
