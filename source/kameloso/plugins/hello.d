module kameloso.plugins.hello;

version(none):  // Remove to enable

import kameloso.plugins.common;
import kameloso.messaging;
import dialect.defs;

@(IRCEvent.Type.CHAN)     // This function should be automatically called on incoming channel messages
@(PrivilegeLevel.ignore)  // ...sent by anyone...
@BotCommand("hello")      // ...saying "!hello"
void onCommandHello(HelloPlugin plugin, const ref IRCEvent event)
{
    chan(plugin.state, event.channel, "Hello World!");
}

final class HelloPlugin : IRCPlugin
{
    mixin IRCPluginImpl;
}
