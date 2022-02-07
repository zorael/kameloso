module kameloso.plugins.hello;

version(none):  // Remove to enable

import kameloso.plugins.common;
import kameloso.messaging;
import dialect.defs;

@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)  // This function should be called on channel messages
    .addCommand(
        IRCEventHandler.Command()
            .word("hello")        // ...with the contents "!hello"
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
