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


    // resolve
    /++
     +  Given an address and a port, builds an array of `Address`es into IPs.
     +
     +  Example:
     +  ---
     +  Connection conn;
     +  conn.resolve("irc.freenode.net", 6667, abort);
     +  ---
     +
     +  Params:
     +      address = String address to look up.
     +      port = Remote port build into the `Address`.
     +      useIPv6 = Whether to include resolved IPv6 addresses or not.
     +      abort = Reference bool which, if set, should make us abort and
     +          return.
     +
     +  Returns:
     +      bool of whether the resolve attempt was a success or not.
     +/
    bool resolve(const string address, const ushort port, const bool useIPv6, ref bool abort)
    {
        import std.algorithm : filter;
        import std.array : array;
        import std.socket : AddressFamily, SocketException, getAddress;

        enum resolveAttempts = 15;
        uint incrementedDelay = Timeout.resolve;
        enum incrementMultiplier = 1.5;

        foreach (immutable i; 0..resolveAttempts)
        {
            if (abort) return false;

            with (AddressFamily)
            try
            {
                ips = getAddress(address, port)
                    .filter!(ip => (ip.addressFamily == INET) || ((ip.addressFamily == INET6) && useIPv6))
                    .array;
                return true;
            }
            catch (const SocketException e)
            {
                switch (e.msg)
                {
                case "getaddrinfo error: Name or service not known":
                case "getaddrinfo error: Temporary failure in name resolution":
                    // Assume net down, wait and try again
                    logger.warning("Socket exception caught when resolving server adddress: ", e.msg);

                    if (i+1 < resolveAttempts)
                    {
                        logger.log("Network down? Retrying in ", incrementedDelay.seconds);
                        interruptibleSleep(incrementedDelay.seconds, abort);
                        incrementedDelay = cast(uint)(incrementedDelay * incrementMultiplier);
                        continue;
                    }
                    break;

                default:
                    logger.error("Socket exception caught when resolving server adddress: ", e.msg);
                    logger.log("Could not resolve address to IPs. Verify your server address.");
                    return false;
                }
            }
        }

        logger.error("Failed to resolve host");
        return false;
    }


    // connect
    /++
     +  Walks through the list of `Address`es in `ips` and attempts to connect
     +  to each until one succeeds.
     +
     +  Success is determined by whether or not an exception was thrown during
     +  the attempt, and is kept track of with the connected boolean.
     +
     +  Example:
     +  ---
     +  Connection conn;
     +
     +  conn.resolve("irc.freenode.net", 6667, abort);
     +  conn.connect(abort);
     +
     +  if (!conn.connected)
     +  {
     +      writeln("Connection failed!");
     +      return 1;
     +  }
     +  ---
     +
     +  Params:
     +      abort = Reference bool which, if set, should make us abort and
     +          return.
     +/
    void connect(ref bool abort)
    {
        import std.socket : AddressFamily, SocketException;

        assert((ips.length > 0), "Tried to connect to an unresolved connection");

        uint incrementedDelay = Timeout.retry;
        enum incrementMultiplier = 1.5;

        iploop:
        foreach (immutable i, ip; ips)
        {
            // Decide which kind of socket to use based on the AddressFamily of
            // the resolved ip; IPv4 or IPv6
            socket = (ip.addressFamily == AddressFamily.INET6) ? &socket6 : &socket4;

            enum connectionRetries = 3;

            retryloop:
            foreach (immutable retry; 0..connectionRetries)
            {
                if (abort) break iploop;

                if ((i > 0) || (retry > 0))
                {
                    import std.socket : SocketShutdown;
                    socket.shutdown(SocketShutdown.BOTH);
                    socket.close();
                    reset();
                }

                try
                {
                    if (retry == 0)
                    {
                        logger.logf("Connecting to %s ...", ip);
                    }
                    else
                    {
                        logger.logf("Connecting to %s ... (attempt %d)", ip, retry+1);
                    }

                    socket.connect(ip);

                    // If we're here no exception was thrown, so we're connected
                    connected = true;
                    logger.log("Connected!");
                    incrementedDelay = Timeout.retry;
                    return;
                }
                catch (const SocketException e)
                {
                    logger.error("Failed! ", e.msg);

                    switch (e.msg)
                    {
                    //case "Unable to connect socket: Connection refused":
                    case "Unable to connect socket: Address family not supported by protocol":
                        // Skip this IP entirely
                        break retryloop;

                    //case "Unable to connect socket: Network is unreachable":
                    default:
                        // Don't delay for retrying on the last retry
                        if (retry < (connectionRetries - 1))
                        {
                            logger.logf("Retrying same IP in %d seconds", Timeout.retry);
                            interruptibleSleep(incrementedDelay.seconds, abort);
                            incrementedDelay = cast(uint)(incrementedDelay * incrementMultiplier);
                        }
                        break;
                    }

                }
            }

            if (i < ips.length)
            {
                logger.logf("Trying next IP in %d seconds", Timeout.retry);
                interruptibleSleep(incrementedDelay.seconds, abort);
                incrementedDelay = cast(uint)(incrementedDelay * incrementMultiplier);
            }
        }

        if (!connected)
        {
            logger.error("Failed to connect!");
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
        int remainingMaxLength = 511;

        foreach (immutable string_; strings)
        {
            import std.algorithm.comparison : min;
            immutable thisLength = min(string_.length, remainingMaxLength);
            socket.send(string_[0..thisLength]);
            remainingMaxLength -= thisLength;
            if (remainingMaxLength <= 0) break;
        }

        socket.send("\n");
    }
}


// listenFiber
/++
 +  A `std.socket.Socket`-reading `std.concurrency.Generator`
 +  `core.thread.Fiber`.
 +
 +  It maintains its own buffer into which it receives from the server, though
 +  not neccessarily full lines. It thus keeps filling the buffer until it
 +  finds a newline character, yields it back to the caller of the fiber,
 +  checks for more lines to yield, and if none yields `string.init` to wait for
 +  its turn to read from the server again. The buffer logic is complex.
 +
 +  Example:
 +  ---
 +  import std.concurrency : Generator;
 +
 +  auto generator = new Generator!string(() => listenFiber(conn, abort));
 +  generator.call();
 +
 +  foreach (immutable line; generator)
 +  {
 +      // line is a yielded string
 +  }
 +  ---
 +
 +  Params:
 +      conn = `Connection` whose `std.socket.Socket` it reads from the server
 +          with.
 +      abort = Reference flag which, if set, means we should abort and return.
 +
 +  Yields:
 +      Full IRC event strings.
 +/
void listenFiber(Connection conn, ref bool abort)
{
    import core.time : seconds;
    import std.concurrency : yield;
    import std.datetime.systime : Clock;
    import std.socket : Socket, lastSocketError;
    import std.string : indexOf;

    ubyte[BufferSize.socketReceive*2] buffer;
    auto timeLastReceived = Clock.currTime;
    bool pingingToTestConnection;
    size_t start;

    // The Generator we use this function with popFronts the first thing it does
    // after being instantiated. To work around our main loop popping too we
    // yield an initial empty value; else the first thing to happen will be a
    // double pop, and the first line is missed.
    yield(string.init);

    while (!abort)
    {
        immutable ptrdiff_t bytesReceived = conn.receive(buffer[start..$]);

        if (!bytesReceived)
        {
            logger.errorf("ZERO RECEIVED! last error: '%s'", lastSocketError);
            logger.error("assuming dead and returning.");
            return;
        }
        else if (bytesReceived == Socket.ERROR)
        {
            immutable elapsed = (Clock.currTime - timeLastReceived);

            if (!pingingToTestConnection && (elapsed > Timeout.keepalive.seconds))
            {
                conn.send("PING :hello");
                pingingToTestConnection = true;
                continue;
            }

            if (elapsed > Timeout.connectionLost.seconds)
            {
                import kameloso.common : timeSince;
                // Too much time has passed; we can reasonably assume the socket is disconnected
                logger.errorf("NOTHING RECEIVED FOR %s (timeout %s)",
                    timeSince(elapsed), Timeout.connectionLost.seconds);
                return;
            }

            switch (lastSocketError)
            {
            case "Resource temporarily unavailable":
                // Nothing received
            case "Interrupted system call":
                // Unlucky callgrind_control -d timing
            case "A connection attempt failed because the connected party did not " ~
                 "properly respond after a period of time, or established connection " ~
                 "failed because connected host has failed to respond.":
                // Timed out read in Windows
                yield(string.init);
                break;

            // Others that may be benign?
            case "An established connection was aborted by the software in your host machine.":
            case "An existing connection was forcibly closed by the remote host.":
            case "Connection reset by peer":
                logger.errorf("FATAL SOCKET ERROR (%s)", lastSocketError);
                return;

            default:
                logger.warningf("Socket.ERROR and last error %s", lastSocketError);
                yield(string.init);
                break;
            }

            continue;
        }

        timeLastReceived = Clock.currTime;
        pingingToTestConnection = false;

        immutable ptrdiff_t end = (start + bytesReceived);
        auto newline = (cast(char[])buffer[0..end]).indexOf('\n');
        size_t pos;

        while (newline != -1)
        {
            yield((cast(char[])buffer[pos..pos+newline-1]).idup);
            pos += (newline + 1); // eat remaining newline
            newline = (cast(char[])buffer[pos..end]).indexOf('\n');
        }

        yield(string.init);

        if (pos >= end)
        {
            // can be end or end+1
            start = 0;
            continue;
        }

        start = (end - pos);

        // logger.logf("REMNANT:|%s|", cast(string)buffer[pos..end]);
        import core.stdc.string : memmove;
        memmove(buffer.ptr, (buffer.ptr + pos), (ubyte.sizeof * start));
    }
}
