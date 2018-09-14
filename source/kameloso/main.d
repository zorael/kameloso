import kameloso.common;

void main()
{
    import kameloso.connection : ResolveAttempt, resolveFiber;
    import std.concurrency;

    Client client;
    client.parser.bot.server.address = "wefpok";

    new Generator!ResolveAttempt(() => resolveFiber(client.conn,
        client.parser.bot.server.address, client.parser.bot.server.port,
        settings.ipv6, *client.abort));
}
