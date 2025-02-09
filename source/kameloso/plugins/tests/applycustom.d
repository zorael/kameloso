/++
    Tests that must be in a file that that does not contain any
    [kameloso.plugins.IRCEventHandler|IRCEventHandler]-annotated functions.
    This is due to the way [kameloso.plugins.IRCPluginImpl|IRCPluginImpl] scans
    the module into which it is mixed in.

    This file contains tests for [kameloso.plugins.applyCustomSettings].

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.tests.applycustom;

version(unittest):

unittest
{
    import kameloso.plugins;
    import kameloso.pods : CoreSettings;
    import std.conv : to;
    import std.math : isClose;

    @Settings static struct MyPluginSettings
    {
        @Enabler bool enabled;

        string s;
        int i;
        float f;
        bool b;
        double d;
    }

    static final class MyPlugin : IRCPlugin
    {
        MyPluginSettings myPluginSettings;

        override string name(const bool _ = false, const bool __ = false) const
        {
            return "myplugin";
        }

        mixin IRCPluginImpl;
    }

    IRCPluginState state;
    IRCPlugin plugin = new MyPlugin(state);
    CoreSettings coreSettings;

    auto newSettings =
    [
        `myplugin.s="abc def ghi"`,
        "myplugin.i=42",
        "myplugin.f=3.14",
        "myplugin.b=true",
        "myplugin.d=99.99",
    ];

    cast(void)applyCustomSettings(
        [ plugin ],
        coreSettings: coreSettings,
        customSettings: newSettings,
        toPluginsOnly: true);

    const ps = (cast(MyPlugin)plugin).myPluginSettings;

    assert((ps.s == "abc def ghi"), ps.s);
    assert((ps.i == 42), ps.i.to!string);
    assert(ps.f.isClose(3.14f), ps.f.to!string);
    assert(ps.b);
    assert(ps.d.isClose(99.99), ps.d.to!string);
}
