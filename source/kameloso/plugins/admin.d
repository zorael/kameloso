import kameloso.common;
import kameloso.plugins.common;
import kameloso.ircdefs;

@(IRCEvent.Type)
@(PrivilegeLevel.admin)
void onSetCommand(AdminPlugin plugin)
{
    import std.concurrency;

    IRCEvent mutEvent;
    plugin.state.mainThread.send(ThreadMessage.PeekPlugins(),
        cast(shared IRCPlugin) plugin, mutEvent);
}

class AdminPlugin : IRCPlugin
{
    mixin IRCPluginImpl;
}
