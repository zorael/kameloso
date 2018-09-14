module kameloso.ircdefs;

struct IRCBot
{
    IRCServer server;
}

struct IRCServer
{
    string address;
    ushort port;
}
