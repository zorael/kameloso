module kameloso.plugins.hello;

version(none):  // Remove to enable

import kameloso.plugins.common;
import dialect.defs;
import kameloso.messaging;

@(IRCEvent.Type.CHAN)     // This function should trigger on channel messages
@(PrivilegeLevel.ignore)  // ...sent by anyone, ignoring whether they're whitelisted or not etc
@BotCommand(PrefixPolicy.nickname, "hello")  // ...on the command "[bot nickname]: hello"
void onCommandHello(HelloPlugin plugin, const IRCEvent event)
{
    chan(plugin.state, event.channel, "Hello World!");
}

final class HelloPlugin : IRCPlugin
{
    mixin IRCPluginImpl;
}
