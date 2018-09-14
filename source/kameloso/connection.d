
module kameloso.connection;

struct Connection
{
}




struct ResolveAttempt
{
    
    enum State
    {
        error    }

    
    State state;

}




void resolveFiber(Connection , string address, ushort port,
bool , ref bool )
{
    import std.socket : AddressFamily, SocketException, getAddress;

    enum resolveAttempts = 15;

    alias State = ResolveAttempt.State;
    ResolveAttempt attempt;

    foreach (i; 0..resolveAttempts)
        try
getAddress(address, port)
;

        catch (SocketException e)
            switch (e.msg)
            default:
                attempt.state = State.error;
}
