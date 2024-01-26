/++
    Plugins for the **kameloso** bot.

    See https://github.com/zorael/kameloso/wiki/Current-plugins for a list and
    a description of all available plugins.

    Example:
    ---
    import kameloso.plugins;
    import kameloso.plugins.common;

    final class MyPlugin : IRCPlugin
    {
        mixin IRCPluginImpl;
    }

    mixin PluginRegistration!MyPlugin;
    ---

    Example:
    ---
    import kameloso.plugins;

    IRCPluginState state;
    // state setup...

    IRCPlugin[] plugins = instantiatePlugins(state);
    ---

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins;

private:

import kameloso.plugins.common : IRCPlugin, IRCPluginState;


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
            priority = [kameloso.plugins.Priority|Priority] at which
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

    Plugin modules may register their plugin classes by mixing in [PluginRegistration].

    Params:
        state = The current plugin state on which to base new plugin instances.

    Returns:
        An array of instantiated [kameloso.plugins.common.IRCPlugin|IRCPlugin]s.
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


// PluginRegistration
/++
    Mixes in a module constructor that registers the supplied [IRCPlugin] subclass
    to be instantiated on program startup/connect.

    Params:
        Plugin = Plugin class of module.
        priority = Priority at which to instantiate the plugin. A lower priority
            makes it get instantiated before other plugins. Defaults to `0.priority`.
        module_ = String name of the module. Only used in case an error message is needed.
 +/
mixin template PluginRegistration(
    Plugin,
    Priority priority = 0.priority,
    string module_ = __MODULE__)
{
    version(unittest)
    {
        import lu.traits : MixinConstraints, MixinScope;
        mixin MixinConstraints!(MixinScope.module_, "PluginRegistration");
    }

    // module constructor
    /++
        Mixed-in module constructor that registers the passed [Plugin] class
        to be instantiated on program startup.
     +/
    shared static this()
    {
        import kameloso.plugins.common : IRCPluginState;

        static if (__traits(compiles, new Plugin(IRCPluginState.init)))
        {
            import kameloso.plugins : registerPlugin;

            static auto ctor(IRCPluginState state)
            {
                return new Plugin(state);
            }

            registerPlugin(priority, &ctor);
        }
        else
        {
            import std.format : format;

            enum pattern = "`%s.%s` constructor does not compile";
            enum message = pattern.format(module_, Plugin.stringof);
            static assert(0, message);
        }
    }
}


// Priority
/++
    Embodies the notion of a priority at which a plugin should be instantiated,
    and as such, the order in which they will be called to handle events.

    This also affects in what order they appear in the configuration file.
 +/
struct Priority
{
    /++
        Numerical priority value. Lower is higher.
     +/
    int value;

    /++
        Helper `opUnary` to allow for `-10.priority`, instead of having to do the
        (more correct) `(-10).priority`.

        Example:
        ---
        mixin PluginRegistration!(MyPlugin, -10.priority);
        ---

        Params:
            op = Operator.

        Returns:
            A new [Priority] with a [Priority.value|value] equal to the negative of this one's.
     +/
    auto opUnary(string op: "-")() const
    {
        return Priority(-value);
    }
}


// priority
/++
    Helper alias to use the proper style guide and still be able to instantiate
    [Priority] instances with UFCS.

    Example:
    ---
    mixin PluginRegistration!(MyPlugin, 50.priority);
    ---
 +/
alias priority = Priority;
