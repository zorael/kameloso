import kameloso.common;

void main(string[] args)
{
    import kameloso.connection : ResolveAttempt, resolveFiber;
    import std.concurrency;

    Client client;
    client.parser.bot.server.address = (args.length > 1) ? args[1] : "wefpok";

    new Generator!ResolveAttempt(() => resolveFiber(client.conn,
        client.parser.bot.server.address, client.parser.bot.server.port,
        settings.ipv6, *client.abort));
}
