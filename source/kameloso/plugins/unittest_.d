/++
    Unit test plugin.

    See_Also:
        [kameloso.plugins.common],
        [kameloso.plugins.common]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.unittest_;

version(unittest):

private:

import kameloso.plugins;
import kameloso.plugins.common.awareness;
import kameloso.plugins.common.mixins;
import dialect.defs;
import std.typecons : Flag, No, Yes;

mixin UserAwareness!(ChannelPolicy.any, Yes.debug_);
mixin ChannelAwareness!(ChannelPolicy.any, Yes.debug_);
mixin PluginRegistration!(UnittestPlugin, 100.priority);

version(TwitchSupport)
{
    mixin TwitchAwareness!(ChannelPolicy.any, Yes.debug_);
}


// UnittestSettings
/++
    Unit test plugin settings.
 +/
@Settings struct UnittestSettings
{
    /++
        Enabler.
     +/
    @Enabler bool enabled = false;
}


// onCommand
/++
    Event handler command test.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.anyone)
    .channelPolicy(ChannelPolicy.any)
    .addCommand(
        IRCEventHandler.Command()
            .word("unittest")
            .policy(PrefixPolicy.direct)
            .description("Test command description")
            .addSyntax("$command test command syntax")
    )
)
void onCommand(UnittestPlugin plugin, const IRCEvent event)
{
    //with (plugin)  // https://github.com/dlang-community/D-Scanner/issues/931

    void onSuccess(IRCUser user)
    {
        with (plugin)
        {
            chan(event.channel.name, "success:" ~ user.account);
        }
    }

    void onFailure()
    {
        with (plugin)
        {
            chan(event.channel.name, "failure");
        }
    }

    mixin WHOISFiberDelegate!(onSuccess, onFailure, Yes.alwaysLookup);
    enqueueAndWHOIS(event.sender.nickname);
}


// onRegex
/++
    Event handler regex test.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.anyone)
    .channelPolicy(ChannelPolicy.any)
    .addRegex(
        IRCEventHandler.Regex()
            .expression("unit[tT]est.*")
            .description("Test regex description")
    )
)
void onRegex(UnittestPlugin _, const IRCEvent __)
{
    // ...
}


public:


// UnittestPlugin
/++
    Unit test plugin.
 +/
final class UnittestPlugin : IRCPlugin
{
    /++
        Unit test plugin settings.
     +/
    UnittestSettings unittestSettings;

    @Resource resFileWithoutSubdir = "unittest.delme";
    @Resource("unittest") resFileWithSubdir = "unittest.delme";
    @Configuration confFileWithoutSubdir = "unittest.delme";
    @Configuration("unittest") confFileWithSubdir = "unittest.delme";

    mixin MessagingProxy;
    mixin IRCPluginImpl!(Yes.debug_);
}

///
unittest
{
    import std.conv : to;
    import std.path : buildNormalizedPath;

    IRCPluginState state;
    state.coreSettings.configDirectory = "conf";
    state.coreSettings.resourceDirectory = "res";
    auto plugin = new UnittestPlugin(state);

    assert((plugin.name == "unittest"), plugin.name);

    assert(!plugin.isEnabled);
    plugin.unittestSettings.enabled = true;
    assert(plugin.isEnabled);

    assert((plugin.Introspection.allEventHandlerUDAsInModule.length > 2),
        plugin.Introspection.allEventHandlerUDAsInModule.length.to!string);
    assert((plugin.Introspection.allEventHandlerFunctionsInModule.length > 2),
        plugin.Introspection.allEventHandlerFunctionsInModule.length.to!string);

    immutable resPathWithout = buildNormalizedPath(
        plugin.state.coreSettings.resourceDirectory,
        "unittest.delme");
    immutable resPathWith = buildNormalizedPath(
        plugin.state.coreSettings.resourceDirectory,
        "unittest",
        "unittest.delme");

    assert((plugin.resFileWithoutSubdir == resPathWithout), plugin.resFileWithoutSubdir);
    assert((plugin.resFileWithSubdir == resPathWith), plugin.resFileWithSubdir);

    immutable confPathWithout = buildNormalizedPath(
        plugin.state.coreSettings.configDirectory,
        "unittest.delme");
    immutable confPathWith = buildNormalizedPath(
        plugin.state.coreSettings.configDirectory,
        "unittest",
        "unittest.delme");

    assert((plugin.confFileWithoutSubdir == confPathWithout), plugin.confFileWithoutSubdir);
    assert((plugin.confFileWithSubdir == confPathWith), plugin.confFileWithSubdir);
}
