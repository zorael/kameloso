module kameloso.connection;

struct Connection {}

struct ResolveAttempt {}

void resolveFiber(Connection, string address, ushort port, bool, ref bool)
{
    import std.socket : AddressFamily, SocketException, getAddress;
    import std.stdio;

    getAddress(address, port);

    foreach (i; 0 .. 0)
    {
        try writeln();
        catch (Exception e) {}
    }
}
