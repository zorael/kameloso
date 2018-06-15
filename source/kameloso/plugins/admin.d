import kameloso.plugins;
import kameloso.ircdefs;

void onSetCommand(AdminPlugin plugin)
{
    import kameloso.common ;
    import std.concurrency ;

    IRCEvent mutEvent ;
    plugin.state.mainThread.send(ThreadMessage.PeekPlugins(),
mutEvent);
}




class AdminPlugin {
    mixin IRCPluginImpl;
}
