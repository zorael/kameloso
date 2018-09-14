import kameloso.common;

void main(string[] args)
{
    import kameloso.connection : ResolveAttempt, resolveFiber;
    import std.concurrency;
    import std.stdio;

    Client client;
    client.parser.bot.server.address = (args.length > 1) ? args[1] : "wefpok";
    writeln("Attempting to resolve ", client.parser.bot.server.address);

    new Generator!ResolveAttempt(() => resolveFiber(client.conn,
        client.parser.bot.server.address, client.parser.bot.server.port,
        settings.ipv6, *client.abort));

    writeln("Success");
}
