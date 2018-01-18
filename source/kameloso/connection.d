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

    /// Pointer to the socket of the AddressFamily we want to connect with
    Socket* socket;

public:
    /// IPs already resolved using Connection.resolve.
    Address[] ips;

    /++
     +  Implicitly proxy calls to the current Socket. This successfully proxies
     +  to Socket.receive.
     +/
    alias socket this;

    /// Is the connection known to be active?
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
    }


    // setOptions
    /++
     +  Set up sockets with the SocketOptions needed. These include timeouts
     +  and buffer sizes.
     +
     +  Params:
     +      socketToSetup = ref `socket` to modify.
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
     +  Given an address and a port, build an array of `Address`es into IPs.
     +
     +  Example:
     +  ------------
     +  Connection conn;
     +  conn.resolve("irc.freenode.net", 6667, abort);
     +  ------------
     +
     +  Params:
     +      address = The string address to look up.
     +      port = The remote port build into the `Address`.
     +      abort = Reference bool which, if set, should make us abort and
     +          return.
     +
     +  Returns:
     +      bool of whether the resolve attempt was a success or not.
     +/
    bool resolve(const string address, const ushort port, ref bool abort)
    {
        import core.thread : Thread;
        import std.socket : getAddress, SocketException;

        enum resolveAttempts = 20;

        foreach (immutable i; 0..resolveAttempts)
        {
            if (abort) return false;

            try
            {
                ips = getAddress(address, port);
                return true;
            }
            catch (const SocketException e)
            {
                switch (e.msg)
                {
                case "getaddrinfo error: Name or service not known":
                case "getaddrinfo error: Temporary failure in name resolution":
                    // Assume net down, wait and try again
                    logger.warning("Socket exception: ", e.msg);
                    logger.logf("Network down? Retrying in %d seconds (attempt %d)",
                        Timeout.resolve, i+1);
                    interruptibleSleep(Timeout.resolve.seconds, abort);
                    continue;

                default:
                    logger.error(e.msg);
                    logger.log("Could not resolve address to IPs. " ~
                        "Verify your server address.");
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
     +  ------------
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
     +  ------------
     +
     +  Params:
     +      abort = Reference bool which, if set, should make us abort and
     +          return.
     +/
    void connect(ref bool abort)
    {
        import core.thread : Thread;
        import std.socket : AddressFamily, SocketException;

        assert((ips.length > 0), "Tried to connect to an unresolved connection");

        foreach (immutable i, ip; ips)
        {
            if (abort) break;

            // Decide which kind of socket to use based on the AddressFamily of
            // the resolved ip; IPv4 or IPv6
            socket = (ip.addressFamily == AddressFamily.INET6) ? &socket6 : &socket4;

            try
            {
                logger.logf("Connecting to %s ...", ip);
                socket.connect(ip);

                // If we're here no exception was thrown, so we're connected
                connected = true;
                logger.log("Connected!");
                return;
            }
            catch (const SocketException e)
            {
                logger.error("Failed! ", e.msg);

                if (i < ips.length)
                {
                    logger.infof("Trying next ip in %d seconds", Timeout.retry);
                    interruptibleSleep(Timeout.retry.seconds, abort);
                }
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
     +  ------------
     +  conn.sendline("NICK kameloso");
     +  conn.sendline("PRIVMSG #channel :text");
     +  ------------
     +
     +  Params:
     +      strings = Variadic list of strings to send.
     +/
    pragma(inline, true)
    void sendline(Strings...)(const Strings strings)
    {
        foreach (const string_; strings)
        {
            import std.algorithm.comparison : min;

            socket.send(string_[0..min(string_.length, 511)]);
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
 +  its turn to read from the sever again. The buffer logic is complex.
 +
 +  Example:
 +  ------------
 +  import std.concurrency : Generator;
 +
 +  auto generator = new Generator!string(() => listenFiber(conn, abort));
 +  generator.call();
 +
 +  foreach (immutable line; generator)
 +  {
 +      /* ... */
 +      yield(someString)
 +  }
 +  ------------
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
    import std.algorithm.searching : countUntil;
    import std.concurrency : yield;
    import std.datetime.systime : Clock, SysTime;
    import std.socket : Socket, lastSocketError;

    ubyte[BufferSize.socketReceive*2] buffer;
    long timeLastReceived = Clock.currTime.toUnixTime;
    size_t start;

    // The Generator we use this function with popFronts the first thing it does
    // after being instantiated. To work around our main loop popping too we
    // yield an initial empty value; else the first thing to happen will be a
    // double pop, and the first line is missed.
    yield(string.init);

    while (!abort)
    {
        const ptrdiff_t bytesReceived = conn.receive(buffer[start..$]);

        if (!bytesReceived)
        {
            logger.errorf("ZERO RECEIVED! last error: '%s'", lastSocketError);

            switch (lastSocketError)
            {
            // case "Resource temporarily unavailable":
            case "Success":
                logger.info("benign.");
                break;

            default:
                logger.error("assuming dead and returning");
                return;
            }
        }
        else if (bytesReceived == Socket.ERROR)
        {
            auto elapsed = (Clock.currTime.toUnixTime - timeLastReceived);

            if (elapsed > Timeout.keepalive)
            {
                // Too much time has passed; we can reasonably assume the socket is disconnected
                logger.errorf("NOTHING RECEIVED FOR %s (timeout %s)",
                              elapsed, Timeout.keepalive.seconds);
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

        timeLastReceived = Clock.currTime.toUnixTime;

        const ptrdiff_t end = (start + bytesReceived);
        auto newline = buffer[0..end].countUntil(cast(ubyte)'\n');
        size_t pos;

        while (newline != -1)
        {
            yield((cast(char[])buffer[pos..pos+newline-1]).idup);
            pos += (newline + 1); // eat remaining newline
            newline = buffer[pos..end].countUntil(cast(ubyte)'\n');
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
