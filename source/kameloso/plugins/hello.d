module kameloso.plugins.hello;

version(none):  // Remove to enable

import kameloso.plugins.common;
import kameloso.messaging;
import dialect.defs;

@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .addCommand(
        IRCEventHandler.Command()
            .word("hello")
            .description("Says hello.")
    )
)
void onCommandHello(HelloPlugin plugin, const ref IRCEvent event)
{
    chan(plugin.state, event.channel, "Hello World!");
}

final class HelloPlugin : IRCPlugin
{
    mixin IRCPluginImpl;
}
