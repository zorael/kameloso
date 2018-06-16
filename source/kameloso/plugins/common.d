module kameloso.plugins.common;

struct IRCPluginState
{
    import std.concurrency;

    Tid mainThread;
}

template IRCPluginImpl()
{
    IRCPluginState privateState;

    ref state()
    {
        return this.privateState;
    }
}
