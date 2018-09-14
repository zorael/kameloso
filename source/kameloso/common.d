module kameloso.common;

CoreSettings settings;

struct CoreSettings
{
    bool ipv6;
}

struct Client
{
    import kameloso.connection;
    import kameloso.irc;

    Connection conn;
    IRCParser parser;
    bool* abort;
}
