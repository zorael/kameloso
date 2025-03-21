module kameloso.plugins.hello;

version(none):  // Remove to enable

import kameloso.plugins;
import kameloso.messaging;
import dialect.defs;

@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)  // This function should be called on channel messages
    .addCommand(                  // ...that are commands (e.g. content begins with a ! or similar prefix)
        IRCEventHandler.Command()
            .word("hello")        // ...where the command is "hello" (e.g. message content is "!hello")
            .description("Says hello.")
    )
)
void onCommandHello(HelloPlugin plugin, const IRCEvent event)
{
    chan(plugin.state, event.channel, "Hello World!");
}

final class HelloPlugin : IRCPlugin
{
    mixin IRCPluginImpl;
}

mixin PluginRegistration!HelloPlugin;
