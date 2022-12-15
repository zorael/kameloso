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

import kameloso.plugins.common.core : IRCPlugin, IRCPluginState;


// PluginRegistrationEntry
/++
    An entry in [registeredPlugins] corresponding to a plugin registered to be
    instantiated on program startup/connect.
 +/
struct PluginRegistrationEntry
{
    // Priority
    /++
        To be used instead of a magic number priority integer.
     +/
    version(none)
    static struct Priority
    {
        int value;

        auto opUnary(string op : "-")()
        {
            return Priority(-value);
        }
    }

    // priority
    /++
        Priority at which to instantiate the plugin. A lower priority makes it
        get instantiated before other plugins.
     +/
    int priority;

    // module_
    /++
        String name of the module.
     +/
    string module_;

    // ctor
    /++
        Function pointer to a "constructor"/builder that instantiates the relevant plugin.
     +/
    IRCPlugin function(IRCPluginState) ctor;

    // this
    /++
        Constructor.

        Params:
            priority = Priority at which to instantiate the plugin. A lower priority
                makes it get instantiated before other plugins.
            module_ = String name of the module.
            ctor = Function pointer to a "constructor"/builder that instantiates
                the relevant plugin.
     +/
    this(
        const int priority,
        const string module_,
        typeof(this.ctor) ctor) pure @safe nothrow @nogc
    {
        this.priority = priority;
        this.module_ = module_;
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
        module_ = String name of the module.
        ctor = Function pointer to a "constructor"/builder that instantiates
            the relevant plugin.
 +/
void registerPlugin(
    const int priority,
    const string module_,
    IRCPlugin function(IRCPluginState) ctor)
{
    registeredPlugins ~= PluginRegistrationEntry(
        priority,
        module_,
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
        .sort!((a,b) => a.priority < b.priority);

    foreach (registration; sortedPluginRegistrations)
    {
        plugins[i++] = registration.ctor(state);
    }

    return plugins;
}
