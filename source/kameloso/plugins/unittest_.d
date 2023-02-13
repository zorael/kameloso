/++
    Unit test plugin.
 +/
module kameloso.plugins.unittest_;

version(unittest):

private:

import kameloso.plugins;
import kameloso.plugins.common.core;
import kameloso.plugins.common.awareness;
import kameloso.plugins.common.mixins : MessagingProxy;
import dialect.defs;
import std.typecons : Flag, No, Yes;

mixin UserAwareness!(ChannelPolicy.any, Yes.debug_);
mixin ChannelAwareness!(ChannelPolicy.any, Yes.debug_);
mixin TwitchAwareness!(ChannelPolicy.any, Yes.debug_);
mixin PluginRegistration!(UnittestPlugin, 100.priority);


// UnittestSettings
/++
    Unit test plugin settings.
 +/
@Settings struct UnittestSettings
{
    /// Enabler.
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
void onCommand(UnittestPlugin plugin, const ref IRCEvent event)
{
    with (plugin)
    {
        chan(event.channel, event.content);
    }
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
void onRegex(UnittestPlugin _, const ref IRCEvent _2)
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

    mixin MessagingProxy;
    mixin IRCPluginImpl!(Yes.debug_);
}

///
unittest
{
    import std.conv : to;

    IRCPluginState state;
    auto plugin = new UnittestPlugin(state);

    assert((plugin.name == "unittest_"), plugin.name);

    assert(!plugin.isEnabled);
    plugin.unittestSettings.enabled = true;
    assert(plugin.isEnabled);

    assert((plugin.Introspection.allEventHandlerUDAsInModule.length > 2),
        plugin.Introspection.allEventHandlerUDAsInModule.length.to!string);
    assert((plugin.Introspection.allEventHandlerFunctionsInModule.length > 2),
        plugin.Introspection.allEventHandlerFunctionsInModule.length.to!string);
}
