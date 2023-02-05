/++
    Bits and bobs to register plugins to be instantiated on program startup/connect.

    This should rarely have to be used manually.

    Example:
    ---
    import kameloso.plugins.common.core;

    final class MyPlugin : IRCPlugin
    {
        mixin IRCPluginImpl;
    }

    mixin ModuleRegistration;
    ---

    Example:
    ---
    import kameloso.plugins;

    IRCPluginState state;
    // state setup...

    IRCPlugin[] plugins = instantiatePlugins(state);
    ---
 +/
module kameloso.plugins;

private:

import kameloso.plugins.common.core : IRCPlugin, IRCPluginState, Priority;


// PluginRegistrationEntry
/++
    An entry in [registeredPlugins] corresponding to a plugin registered to be
    instantiated on program startup/connect.
 +/
struct PluginRegistrationEntry
{
    // priority
    /++
        Priority at which to instantiate the plugin. A lower priority makes it
        get instantiated before other plugins.
     +/
    Priority priority;

    // ctor
    /++
        Function pointer to a "constructor"/builder that instantiates the relevant plugin.
     +/
    IRCPlugin function(IRCPluginState) ctor;

    // this
    /++
        Constructor.

        Params:
            priority = [kameloso.plugins.common.core.Priority|Priority] at which
                to instantiate the plugin. A lower priority value makes it get
                instantiated before other plugins.
            ctor = Function pointer to a "constructor"/builder that instantiates
                the relevant plugin.
     +/
    this(
        const Priority priority,
        typeof(this.ctor) ctor) pure @safe nothrow @nogc
    {
        this.priority = priority;
        this.ctor = ctor;
    }
}


// registeredPlugins
/++
    Array of registered plugins, represented by [PluginRegistrationEntry]/-ies,
    to be instantiated on program startup/connect.
 +/
shared PluginRegistrationEntry[] registeredPlugins;


// module constructor
/++
    Module constructor that merely reserves space for [registeredPlugins] to grow into.

    Only include this if the compiler is based on 2.095 or later, as the call to
    [object.reserve|reserve] fails with those prior to that.
 +/
static if (__VERSION__ >= 2095L)
shared static this()
{
    enum initialSize = 64;
    (cast()registeredPlugins).reserve(initialSize);
}


public:


// registerPlugin
/++
    Registers a plugin to be instantiated on program startup/connect by creating
    a [PluginRegistrationEntry] and appending it to [registeredPlugins].

    Params:
        priority = Priority at which to instantiate the plugin. A lower priority
            makes it get instantiated before other plugins.
        ctor = Function pointer to a "constructor"/builder that instantiates
            the relevant plugin.
 +/
void registerPlugin(
    const Priority priority,
    IRCPlugin function(IRCPluginState) ctor)
{
    registeredPlugins ~= PluginRegistrationEntry(
        priority,
        ctor);
}


// instantiatePlugins
/++
    Instantiates all plugins represented by a [PluginRegistrationEntry] in
    [registeredPlugins].

    Plugin modules may register themselves by mixing in [kameloso.plugins.common.core.ModuleRegistration].

    Params:
        state = The current plugin state on which to base new plugin instances.

    Returns:
        An array of instantiated [kameloso.plugins.common.core.IRCPlugin|IRCPlugin]s.
 +/
auto instantiatePlugins(/*const*/ IRCPluginState state)
{
    import std.algorithm.sorting : sort;

    IRCPlugin[] plugins;
    plugins.length = registeredPlugins.length;
    uint i;

    auto sortedPluginRegistrations = registeredPlugins
        .sort!((a,b) => a.priority.value < b.priority.value);

    foreach (registration; sortedPluginRegistrations)
    {
        plugins[i++] = registration.ctor(state);
    }

    return plugins;
}
