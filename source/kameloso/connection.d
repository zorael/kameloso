/++
 +  Functions related to connecting to an IRC server, and reading from it.
 +/
module kameloso.connection;

import kameloso.common : interruptibleSleep, logger;
import kameloso.constants;


// Connection
/++
 +  Functions and state needed to connect and maintain a connection.
 +
 +  This is simply to decrease the amount of globals and to create some
 +  convenience functions.
 +/
struct Connection
{
private:
    import core.time : seconds;
    import std.socket : Socket, Address;

    /// Real IPv4 and IPv6 sockets to connect through.
    Socket socket4, socket6;

    /++
     +  Pointer to the socket of the `std.socket.AddressFamily` we want to
     +  connect with.
     +/
    Socket* socket;

public:
    /// IPs already resolved using `Connection.resolve`.
    Address[] ips;

    /++
     +  Implicitly proxies calls to the current `socket`. This successfully
     +  proxies to `Socket.receive`.
     +/
    alias socket this;

    /// Whether we are connected or not.
    bool connected;


    // reset
    /++
     +  (Re-)initialises the sockets and sets the IPv4 one as the active one.
     +/
    void reset()
    {
        import std.socket : TcpSocket, AddressFamily, SocketType;

        socket4 = new TcpSocket;
        socket6 = new Socket(AddressFamily.INET6, SocketType.STREAM);
        socket = &socket4;

        setOptions(socket4);
        setOptions(socket6);

        connected = false;
    }


    // setOptions
    /++
     +  Sets up sockets with the `std.socket.SocketOptions` needed. These
     +  include timeouts and buffer sizes.
     +
     +  Params:
     +      socketToSetup = Reference to the `socket` to modify.
     +/
    void setOptions(Socket socketToSetup)
    {
        import std.socket : SocketOption, SocketOptionLevel;

        with (socketToSetup)
        with (SocketOption)
        with (SocketOptionLevel)
        {
            setOption(SOCKET, RCVBUF, BufferSize.socketOptionReceive);
            setOption(SOCKET, SNDBUF, BufferSize.socketOptionSend);
            setOption(SOCKET, RCVTIMEO, Timeout.receive.seconds);
            setOption(SOCKET, SNDTIMEO, Timeout.send.seconds);
            blocking = true;
        }
    }


    // sendline
    /++
     +  Sends a line to the server.
     +
     +  Sadly the IRC server requires lines to end with a newline, so we need
     +  to chain one directly after the line itself. If several threads are
     +  allowed to write to the same socket in parallel, this would be a race
     +  condition.
     +
     +  Example:
     +  ---
     +  conn.sendline("NICK kameloso");
     +  conn.sendline("PRIVMSG #channel :text");
     +  ---
     +
     +  Params:
     +      strings = Variadic list of strings to send.
     +/
    void sendline(Strings...)(const Strings strings)
    {
    }
}


// ResolveAttempt
/++
 +  Embodies the state of an address resolution attempt.
 +/
struct ResolveAttempt
{
    /// At what state the resolution process this attempt is currently at.
    enum State
    {
        preresolve,     /// About to resolve.
        success,        /// Successfully resolved.
        exception,      /// Failure, recoverable exception thrown.
        error,          /// Failure, unrecoverable exception thrown.
        failure,        /// Resolution failure; should abort.
    }

    /// The current state of the attempt.
    State state;

    /// The error message as thrown by an exception.
    string error;

    /// The number of retries so far towards his `address`.
    uint numRetry;
}


// resolveFiber
/++
 +  Given an address and a port, resolves these and builds an array of unique
 +  `Address` IPs.
 +
 +  Params:
 +      conn = Reference to the current `Connection`.
 +      address = String address to look up.
 +      port = Remote port build into the `Address`.
 +      useIPv6 = Whether to include resolved IPv6 addresses or not.
 +      abort = Reference bool which, if set, should make us abort and return.
 +/
void resolveFiber(ref Connection conn, const string address, const ushort port,
    const bool useIPv6, ref bool abort)
{
    import std.concurrency : yield;
    import std.socket : AddressFamily, SocketException, getAddress;

    enum resolveAttempts = 15;

    alias State = ResolveAttempt.State;
    ResolveAttempt attempt;

    yield(attempt);

    foreach (immutable i; 0..resolveAttempts)
    {
        if (abort) return;

        attempt.numRetry = i;

        with (AddressFamily)
        try
        {
            import std.algorithm.iteration : filter, uniq;
            import std.array : array;

            conn.ips = getAddress(address, port)
                .filter!(ip => (ip.addressFamily == INET) || ((ip.addressFamily == INET6) && useIPv6))
                .uniq!((a,b) => a.toString == b.toString)
                .array;

            attempt.state = State.success;
            yield(attempt);
            return;  // Should never get here
        }
        catch (const SocketException e)
        {
            switch (e.msg)
            {
            case "getaddrinfo error: Name or service not known":
            case "getaddrinfo error: Temporary failure in name resolution":
                // Assume net down, wait and try again
                attempt.state = State.exception;
                attempt.error = e.msg;
                yield(attempt);
                continue;

            default:
                attempt.state = State.error;
                attempt.error = e.msg;
                yield(attempt);
                return;  // Should never get here
            }
        }
    }

    attempt.state = State.failure;
    yield(attempt);
}
