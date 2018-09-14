import kameloso.common;
Next tryResolve(Client client)
{
    import kameloso.connection : ResolveAttempt, resolveFiber;
    import std.concurrency ;

new Generator!ResolveAttempt(() =>
        resolveFiber(client.conn, client.parser.bot.server.address,
        client.parser.bot.server.port, settings.ipv6, *client.abort));

    return Next.returnFailure;
}


void main()
{
    
    Client client;
    client.parser.bot.server.address = "wefpok";
    tryResolve(client);
}
