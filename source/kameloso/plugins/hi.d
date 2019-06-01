module kameloso.plugins.hi;

version(none):

import kameloso.plugins.common;
import kameloso.irc.defs;
import kameloso.messaging;

@(IRCEvent.Type.CHAN)
@(PrivilegeLevel.ignore)
@BotCommand(PrefixPolicy.nickname, "hi")
@Description("Says hello")
void onCommandHi(HelloPlugin plugin, const IRCEvent event)
{
    chan(plugin.state, event.channel, event.sender.nickname ~ ": Hello World!");
}

final class HelloPlugin : IRCPlugin
{
    mixin IRCPluginImpl;
}
