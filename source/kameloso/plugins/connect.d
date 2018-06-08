import kameloso.plugins.common;
import kameloso.ircdefs;

void joinChannels(ConnectService service)
{
    with (service)
    {
        import std.algorithm;
        import std.conv;
        import std.range;

        immutable chanlist = chain(bot.homes).joiner.array.to!string;

        join(chanlist);
    }
}

class ConnectService
{
    mixin IRCPluginImpl;
    mixin MessagingProxy;
}
