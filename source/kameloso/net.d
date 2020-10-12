/++
    Functionality related to connecting to a server over the Internet.

    Includes `core.thread.fiber.Fiber`s that help with resolving the address of,
    connecting to, and reading full string lines from a server.

    Having them as `core.thread.fiber.Fiber`s means a program can do address resolution,
    connecting and reading while retaining the ability to do other stuff
    concurrently. This means you can conveniently run code inbetween each
    connection attempt, for instance, without breaking the program's flow.

    Example:
    ---
    import std.concurrency : Generator;

    Connection conn;
    bool abort;  // Set to true if something goes wrong

    conn.reset();

    bool useIPv6 = false;
    enum resolveAttempts = 10;

    auto resolver = new Generator!ResolveAttempt(() =>
        resolveFiber(conn, "irc.freenode.net", 6667, useIPv6, resolveAttempts, abort));

    resolver.call();

    resolveloop:
    foreach (const attempt; resolver)
    {
        // attempt is a yielded `ResolveAttempt`
        // switch on `attempt.state`, deal with it accordingly
    }

    // Resolution done

    enum connectionRetries = 10;

    auto connector = new Generator!ConnectionAttempt(() =>
        connectFiber(conn, false, connectionRetries, abort));

    connector.call();

    connectorloop:
    foreach (const attempt; connector)
    {
        // attempt is a yielded `ConnectionAttempt`
        // switch on `attempt.state`, deal with it accordingly
    }

    // Connection established

    enum timeoutSeconds = 600;

    auto listener = new Generator!ListenAttempt(() => listeFiber(conn, abort, timeoutSecond));

    listener.call();

    foreach (const attempt; listener)
    {
        // attempt is a yielded `ListenAttempt`
        doThingsWithLineFromServer(attempt.line);
        // program logic goes here
    }
    ---
 +/
module kameloso.net;

public:

@safe:

/++
    Default buffer sizes in bytes.
 +/
enum DefaultBufferSize
{
    /++
        The receive buffer size as set as a `std.socket.SocketOption`.
     +/
    socketOptionReceive = 2048,

    /++
        The send buffer size as set as a `std.socket.SocketOption`.
     +/
    socketOptionSend = 1024,

    /++
        The actual buffer array size used when reading from the socket.
     +/
    socketReceive = 2048,
}


/++
    Various timeouts in milliseconds.
 +/
enum DefaultTimeout
{
    /++
        The send attempt timeout as set as a `std.socket.SocketOption`, in milliseconds.
     +/
    send = 5000,

    /++
        The receive attempt timeout as set as a `std.socket.SocketOption`, in milliseconds.
     +/
    receive = 1000,

    /++
        The actual time after which, if nothing was read during that whole time,
        we decide the connection is dead. In seconds.
     +/
    connectionLost = 600,
}


// Connection
/++
    Functions and state needed to maintain a connection.

    This is simply to decrease the amount of globals and to create some convenience functions.
 +/
struct Connection
{
private:
    import requests.ssl_adapter : SSL, SSL_CTX, openssl;
    import std.socket : Address, Socket, SocketOption;

    /// Real IPv4 and IPv6 sockets to connect through.
    Socket socket4, socket6;

    /// Private cached send timeout setting.
    uint privateSendTimeout;

    /// Private cached received timeout setting.
    uint privateReceiveTimeout;

    /// Private SSL context.
    SSL_CTX* sslContext;

    /++
        OpenSSL `SSL` instance, for use with SSL connections.
     +/
    SSL* sslInstance;


    // setTimemout
    /++
        Sets the `std.socket.SocketOption.RCVTIMEO` of the *current*
        `std.socket.Socket` `socket` to the specified duration.

        Params:
            option = The `std.socket.SocketOption` to set.
            dur = The duration to assign for the option, in number of milliseconds.
     +/
    void setTimeout(const SocketOption option, const uint dur)
    {
        import std.socket : SocketOptionLevel;
        import core.time : msecs;

        with (socket)
        with (SocketOptionLevel)
        {
            setOption(SOCKET, option, dur.msecs);
        }
    }

public:
    /++
        Pointer to the socket of the `std.socket.AddressFamily` we want to connect with.
     +/
    Socket socket;

    /++
        Whether or not this `Connection` should use SSL when sending and receiving.
     +/
    bool ssl;

    /// IPs already resolved using `kameloso.net.resolveFiber`.
    Address[] ips;

    /++
        Implicitly proxies calls to the current `socket`. This successfully
        proxies to `std.socket.Socket.receive`.
     +/
    alias socket this;

    /++
        Whether we are connected or not.
     +/
    bool connected;

    /++
        Path to a (`.pem`) SSL certificate file.
     +/
    string certFile;

    /++
        Path to a private SSL key file.
     +/
    string privateKeyFile;


    // sendTimeout
    /++
        Accessor; returns the current send timeout.

        Returns:
            A copy of `privateSendTimeout`.
     +/
    pragma(inline, true)
    uint sendTimeout() const @property pure @nogc nothrow
    {
        return privateSendTimeout;
    }


    // sendTimeout
    /++
        Mutator; sets the send timeout socket option to the passed duration.

        Params:
            dur = The duration to assign as send timeout, in number of milliseconds.
     +/
    pragma(inline, true)
    void sendTimeout(const uint dur) @property
    {
        setTimeout(SocketOption.SNDTIMEO, dur);
        privateSendTimeout = dur;
    }

    // receiveTimeout
    /++
        Accessor; returns the current receive timeout.

        Returns:
            A copy of `privateReceiveTimeout`.
     +/
    pragma(inline, true)
    uint receiveTimeout() const @property pure @nogc nothrow
    {
        return privateReceiveTimeout;
    }

    // sendTimeout
    /++
        Mutator; sets the receive timeout socket option to the passed duration.

        Params:
            dur = The duration to assign as receive timeout, in number of milliseconds.
     +/
    void receiveTimeout(const uint dur) @property
    {
        setTimeout(SocketOption.RCVTIMEO, dur);
        privateReceiveTimeout = dur;
    }


    // reset
    /++
        (Re-)initialises the sockets and sets the IPv4 one as the active one.

        If we ever change this to a class, this should be the default constructor.
     +/
    void reset()
    {
        import std.socket : TcpSocket, AddressFamily, SocketShutdown, SocketType;
        import std.range : only;

        foreach (thisSocket; only(socket4, socket6))
        {
            if (!thisSocket) continue;

            thisSocket.shutdown(SocketShutdown.BOTH);
            thisSocket.close();
        }

        socket4 = new TcpSocket;
        socket6 = new Socket(AddressFamily.INET6, SocketType.STREAM);
        socket = socket4;

        setDefaultOptions(socket4);
        setDefaultOptions(socket6);

        connected = false;
    }


    // resetSSL
    /++
        Resets the SSL context and resources of this `Connection`.
     +/
    void resetSSL() @system
    in (ssl, "Tried to reset SSL on a non-SSL `Connection`")
    {
        if (sslInstance && sslContext) teardownSSL();
        setupSSL();
    }


    // getSSLErrorMessage
    /++
        Returns the SSL error message for the passed SSL error code.

        Params:
            code = SSL error code to translate to string.

        Returns:
            A string with the last SSL error code translated into humanly-readable text.
     +/
    string getSSLErrorMessage(const int code) @system
    in (ssl, "Tried to get SSL error message on a non-SSL `Connection`")
    {
        import std.string : fromStringz;

        immutable errorCode = openssl.SSL_get_error(sslInstance, code);

        return openssl.ERR_reason_error_string(errorCode)
            .fromStringz
            .idup;
    }


    // setDefaultOptions
    /++
        Sets up sockets with the `std.socket.SocketOptions` needed. These
        include timeouts and buffer sizes.

        Params:
            socketToSetup = Reference to the `socket` to modify.
     +/
    void setDefaultOptions(Socket socketToSetup)
    {
        import core.time : msecs;
        import std.socket : SocketOption, SocketOptionLevel;

        with (socketToSetup)
        with (SocketOption)
        with (SocketOptionLevel)
        {
            setOption(SOCKET, RCVBUF, DefaultBufferSize.socketOptionReceive);
            setOption(SOCKET, SNDBUF, DefaultBufferSize.socketOptionSend);
            setOption(SOCKET, RCVTIMEO, DefaultTimeout.receive.msecs);
            setOption(SOCKET, SNDTIMEO, DefaultTimeout.send.msecs);

            privateReceiveTimeout = DefaultTimeout.receive;
            privateSendTimeout = DefaultTimeout.send;
            blocking = true;
        }
    }


    // setupSSL
    /++
        Sets up the SSL context for this connection.

        Throws:
            `SSLException` if the SSL context could not be set up.
     +/
    void setupSSL() @system
    in (ssl, "Tried to set up SSL context on a non-SSL `Connection`")
    {
        import std.algorithm.searching : endsWith;
        import std.string : toStringz;
        import std.uni : toLower;

        sslContext = openssl.SSL_CTX_new(openssl.TLS_method);
        openssl.SSL_CTX_set_verify(sslContext, 0, null);

        if (certFile.length)
        {
            // Before SSL_new
            immutable filetype = certFile.toLower.endsWith(".pem") ? 1 : 0;
            immutable code = openssl.SSL_CTX_use_certificate_file(sslContext,
                toStringz(certFile), filetype);
            if (code != 1) throw new SSLException("Failed to set certificate", code);
        }

        if (privateKeyFile.length)
        {
            // Ditto
            immutable filetype = privateKeyFile.toLower.endsWith(".pem") ? 1 : 0;
            immutable code = openssl.SSL_CTX_use_PrivateKey_file(sslContext,
                toStringz(privateKeyFile), filetype);
            if (code != 1) throw new SSLException("Failed to set private key", code);
        }

        sslInstance = openssl.SSL_new(sslContext);
        immutable code = openssl.SSL_set_fd(sslInstance, cast(int)socket.handle);
        if (code != 1) throw new SSLException("Failed to attach socket handle", code);
    }


    // teardownSSL
    /++
        Resets and frees SSL context and resources.
     +/
    void teardownSSL()
    in (ssl, "Tried to teardown SSL on a non-SSL `Connection`")
    {
        openssl.SSL_free(sslInstance);
        openssl.SSL_CTX_free(sslContext);
    }


    // sendline
    /++
        Sends a line to the server.

        Intended for servers that deliminates lines by linebreaks, such as IRC servers.

        Example:
        ---
        conn.sendline("NICK foobar");
        conn.sendline("PRIVMSG #channel :text");
        conn.sendline("PRIVMSG " ~ channel ~ " :" ~ content);
        conn.sendline("PRIVMSG ", channel, " :", content);  // Identical to above
        conn.sendline!1024(longerLine);  // Now with custom line lengths
        ---

        Params:
            maxLineLength = Maximum line length before the sent message will be truncated.
            data = Variadic list of strings or characters to send. May contain
                complete substrings separated by newline characters.
     +/
    void sendline(uint maxLineLength = 512, Data...)(const Data data) @system
    in (connected, "Tried to send a line on an unconnected `Connection`")
    {
        int remainingMaxLength = (maxLineLength - 1);
        bool justSentNewline;

        foreach (immutable piece; data)
        {
            import std.range.primitives : hasLength;
            import std.traits : isSomeString;

            alias T = typeof(piece);

            static if (isSomeString!T || hasLength!T)
            {
                import std.algorithm.iteration : splitter;
                import std.string : indexOf;

                if (piece.indexOf('\n') != -1)
                {
                    // Line is made up of smaller sublines
                    foreach (immutable line; piece.splitter("\n"))
                    {
                        import std.algorithm.comparison : min;

                        immutable end = min(line.length, remainingMaxLength);

                        if (ssl)
                        {
                            openssl.SSL_write(sslInstance, cast(void*)&line[0], cast(int)end);
                            openssl.SSL_write(sslInstance, cast(void*)&"\n"[0], 1);
                        }
                        else
                        {
                            socket.send(line[0..end]);
                            socket.send("\n");
                        }

                        justSentNewline = true;
                        remainingMaxLength = (maxLineLength - 1);  // sent newline; reset
                    }
                }
                else
                {
                    // Plain line *or* part of a line
                    import std.algorithm.comparison : min;

                    immutable end = min(piece.length, remainingMaxLength);

                    if (ssl)
                    {
                        openssl.SSL_write(sslInstance, cast(void*)&piece[0], cast(int)end);
                        openssl.SSL_write(sslInstance, cast(void*)&"\n"[0], 1);
                    }
                    else
                    {
                        socket.send(piece[0..end]);
                    }

                    justSentNewline = false;
                    remainingMaxLength -= end;
                }
            }
            else
            {
                if (ssl)
                {
                    openssl.SSL_write(sslInstance, cast(void*)&piece[0], cast(int)piece.length);
                }
                else
                {
                    socket.send(piece);
                }

                justSentNewline = false;
                --remainingMaxLength;
            }

            if (remainingMaxLength <= 0) break;
        }

        if (!justSentNewline)
        {
            if (ssl)
            {
                openssl.SSL_write(sslInstance, cast(void*)&"\n"[0], 1);
            }
            else
            {
                socket.send("\n");
            }
        }
    }
}


// ListenAttempt
/++
    Embodies the idea of a listening attempt.
 +/
struct ListenAttempt
{
    /++
        The various states a listening attempt may be in.
     +/
    enum State
    {
        prelisten,  /// About to listen.
        isEmpty,    /// Empty result; nothing read or similar.
        hasString,  /// String read, ready for processing.
        timeout,    /// Connection read timed out.
        warning,    /// Recoverable exception thrown; warn and continue.
        error,      /// Unrecoverable exception thrown; abort.
    }

    /// The current state of the attempt.
    State state;

    /// The last read line of text sent by the server.
    string line;

    /// The `std.socket.lastSocketError` at the last point of error.
    string error;

    /// The amount of bytes received this attempt.
    long bytesReceived;
}


// listenFiber
/++
    A `std.socket.Socket`-reading `std.concurrency.Generator`. It reads and
    yields full string lines.

    It maintains its own buffer into which it receives from the server, though
    not necessarily full lines. It thus keeps filling the buffer until it
    finds a newline character, yields `ListenAttempt`s back to the caller of
    the Fiber, checks for more lines to yield, and if none yields an attempt
    with a `ListenAttempt.State` denoting that nothing was read and that a new
    attempt should be made later.

    Example:
    ---
    //Connection conn;  // Address previously connected established with

    enum timeoutSeconds = 600;

    auto listener = new Generator!ListenAttempt(() => listenFiber(conn, abort, timeoutSeconds));

    listener.call();

    foreach (const attempt; listener)
    {
        // attempt is a yielded `ListenAttempt`

        with (ListenAttempt.State)
        final switch (attempt.state)
        {
        case prelisten:
            assert(0, "shouldn't happen");

        case isEmpty:
        case timeout:
            // Reading timed out or nothing was read, happens
            break;

        case hasString:
            // A line was successfully read!
            // program logic goes here
            doThings(attempt.line);
            break;

        case warning:
            // Recoverable
            warnAboutSomething(attempt.error);
            break;

        case error:
            // Unrecoverable
            dealWitError(attempt.error);
            return;
        }
    }
    ---

    Params:
        conn = `Connection` whose `std.socket.Socket` it reads from the server with.
        abort = Reference "abort" flag, which -- if set -- should make the
            function return and the `core.thread.fiber.Fiber` terminate.
        connectionLost = How many seconds may pass before we consider the connection lost.
            Optional, defaults to `DefaultTimeout.connectionLost`.

    Yields:
        `ListenAttempt`s with information about the line receieved in its member values.
 +/
void listenFiber(Connection conn, ref bool abort,
    const int connectionLost = DefaultTimeout.connectionLost) @system
in ((conn.connected), "Tried to set up a listening fiber on a dead connection")
in ((connectionLost > 0), "Tried to set up a listening fiber with connection timeout of <= 0")
{
    import std.concurrency : yield;
    import std.datetime.systime : Clock;
    import std.socket : Socket, lastSocketError;
    import std.string : indexOf;

    if (abort) return;

    ubyte[DefaultBufferSize.socketReceive*2] buffer;
    long timeLastReceived = Clock.currTime.toUnixTime;
    size_t start;

    alias State = ListenAttempt.State;

    // The Generator we use this function with popFronts the first thing it does
    // after being instantiated. To work around our main loop popping too we
    // yield an initial empty value; else the first thing to happen will be a
    // double pop, and the first line is missed.
    yield(ListenAttempt.init);

    while (!abort)
    {
        ListenAttempt attempt;

        if (conn.ssl)
        {
            import requests.ssl_adapter : openssl;
            attempt.bytesReceived = openssl.SSL_read(conn.sslInstance,
                cast(void*)buffer.ptr+start, cast(int)(buffer.length-start));
        }
        else
        {
            attempt.bytesReceived = conn.receive(buffer[start..$]);
        }

        version(Posix)
        {
            import core.stdc.errno : EINTR, errno;

            if (errno == EINTR)
            {
                // Interrupted read; try again
                // Unlucky callgrind_control -d timing
                attempt.state = State.isEmpty;
                attempt.error = lastSocketError;
                yield(attempt);
                continue;
            }
        }

        if (!attempt.bytesReceived)
        {
            attempt.state = State.error;
            attempt.error = lastSocketError;
            yield(attempt);
            // Should never get here
            assert(0, "Dead `listenFiber` resumed after yield (no bytes received)");
        }
        else if (attempt.bytesReceived == Socket.ERROR)
        {
            attempt.error = lastSocketError;

            if ((Clock.currTime.toUnixTime - timeLastReceived) > connectionLost)
            {
                attempt.state = State.timeout;
                yield(attempt);
                // Should never get here
                assert(0, "Timed out `listenFiber` resumed after yield " ~
                    "(received error, elapsed > timeout)");
            }

            switch (attempt.error)
            {
            version(Windows)
            {
                case "A connection attempt failed because the connected party did not " ~
                    "properly respond after a period of time, or established connection " ~
                    "failed because connected host has failed to respond.":
                    // Timed out read in Windows
                case "A non-blocking socket operation could not be completed immediately.":
                    // Sporadic Cygwin error
            }
            case "Resource temporarily unavailable":
                // Nothing received
            //case "Interrupted system call":
                attempt.state = State.isEmpty;
                yield(attempt);
                continue;

            // Others that may be benign?
            version(Windows)
            {
                case "An established connection was aborted by the software in your host machine.":
            }
            case "An existing connection was forcibly closed by the remote host.":  // Windows-only?
            case "Connection reset by peer":
            case "Transport endpoint is not connected":  // IPv6/IPv4 connection/socket mismatch
                attempt.state = State.error;
                yield(attempt);
                // Should never get here
                assert(0, "Dead `listenFiber` resumed after yield (`lastSocketError` error)");

            default:
                attempt.state = State.warning;
                yield(attempt);
                continue;
            }
        }

        timeLastReceived = Clock.currTime.toUnixTime;

        immutable ptrdiff_t end = cast(ptrdiff_t)(start + attempt.bytesReceived);
        ptrdiff_t newline = (cast(char[])buffer[0..end]).indexOf('\n');
        size_t pos;

        while (newline != -1)
        {
            attempt.state = State.hasString;
            attempt.line = (cast(char[])buffer[pos..pos+newline-1]).idup;
            yield(attempt);
            pos += (newline + 1); // eat remaining newline
            newline = (cast(char[])buffer[pos..end]).indexOf('\n');
        }

        attempt.state = State.isEmpty;
        yield(attempt);

        if (pos >= end)
        {
            // can be end or end+1
            start = 0;
            continue;
        }

        start = (end - pos);

        // writefln("REMNANT:|%s|", cast(string)buffer[pos..end]);
        import core.stdc.string : memmove;
        memmove(buffer.ptr, (buffer.ptr + pos), (ubyte.sizeof * start));
    }
}


// ConnectionAttempt
/++
    Embodies the idea of a connection attempt.
 +/
struct ConnectionAttempt
{
    import std.socket : Address;

    /++
        The various states a connection attempt may be in.
     +/
    enum State
    {
        preconnect,         /// About to connect.
        connected,          /// Successfully connected.
        delayThenReconnect, /// Failed to connect; should delay and retry.
        delayThenNextIP,    /// Failed to reconnect several times; next IP.
        noMoreIPs,          /// Exhausted all IPs and could not connect.
        ipv6Failure,        /// IPv6 connection failed.
        sslFailure,         /// Failure establishing an SSL connection.
        error,              /// Error connecting; should abort.
    }

    /// The current state of the attempt.
    State state;

    /// The IP that the attempt is trying to connect to.
    Address ip;

    /// The error message as thrown by an exception.
    string error;

    /// The number of retries so far towards this `ip`.
    uint retryNum;
}


// connectFiber
/++
    Fiber function that tries to connect to IPs in the `ips` array of the passed
    `Connection`, yielding at certain points throughout the process to let the
    calling function do stuff inbetween connection attempts.

    Example:
    ---
    //Connection conn;  // Address previously resolved with `resolveFiber`

    auto connector = new Generator!ConnectionAttempt(() =>
        connectFiber(conn, false, 10, abort));

    connector.call();

    connectorloop:
    foreach (const attempt; connector)
    {
        // attempt is a yielded `ConnectionAttempt`

        with (ConnectionAttempt.State)
        final switch (attempt.state)
        {
        case preconnect:
            assert(0, "shouldn't happen");

        case connected:
            // Socket is connected, continue with normal routine
            break connectorloop;

        case delayThenReconnect:
        case delayThenNextIP:
            // Delay and retry
            Thread.sleep(5.seconds);
            break;

        case ipv6Failure:
            // Deal with it
            dealWithIPv6(attempt.error);
            break;

        case sslFailure:
        case error:
            // Failed to connect
            return;
        }
    }

    // Connection established
    ---

    Params:
        conn = Reference to the current, unconnected `Connection`.
        endlesslyConnect = Whether or not to endlessly try connecting.
        connectionRetries = How many times to attempt to connect before signaling
            that we should move on to the next IP.
        abort = Reference "abort" flag, which -- if set -- should make the
            function return and the `core.thread.fiber.Fiber` terminate.
 +/
void connectFiber(ref Connection conn, const bool endlesslyConnect,
    const uint connectionRetries, ref bool abort) @system
in (!conn.connected, "Tried to set up a connecting fiber on an already live connection")
in ((conn.ips.length > 0), "Tried to connect to an unresolved connection")
{
    import std.concurrency : yield;
    import std.socket : AddressFamily, Socket, SocketException;

    if (abort) return;

    alias State = ConnectionAttempt.State;

    bool ipv6IsFailing;

    yield(ConnectionAttempt.init);

    do
    {
        iploop:
        foreach (immutable i, ip; conn.ips)
        {
            immutable isIPv6 = (ip.addressFamily == AddressFamily.INET6);
            if (isIPv6 && ipv6IsFailing) continue;  // Continue until IPv4 IP

            ConnectionAttempt attempt;
            attempt.ip = ip;

            foreach (immutable retry; 0..connectionRetries)
            {
                if (abort) return;

                conn.reset();
                conn.socket = isIPv6 ? conn.socket6 : conn.socket4;

                try
                {
                    if (conn.ssl)
                    {
                        // *After* conn.socket has been changed.
                        conn.resetSSL();
                    }

                    attempt.retryNum = retry;
                    attempt.state = State.preconnect;
                    yield(attempt);

                    conn.socket.connect(ip);

                    if (conn.ssl)
                    {
                        import requests.ssl_adapter : openssl;

                        immutable code = openssl.SSL_connect(conn.sslInstance);

                        if (code != 1)
                        {
                            throw new SSLException("Failed to establish SSL connection " ~
                                "after successful connect", code);
                        }
                    }

                    // If we're here no exception was thrown and we didn't yield
                    // out of SSL errors, so we're connected

                    attempt.state = State.connected;
                    conn.connected = true;
                    yield(attempt);
                    // Should never get here
                    assert(0, "Finished `connectFiber` resumed after yield");
                }
                catch (SocketException e)
                {
                    switch (e.msg)
                    {
                    case "Unable to connect socket: Address family not supported by protocol":
                        if (isIPv6)
                        {
                            ipv6IsFailing = true;
                            attempt.state = State.ipv6Failure;
                            attempt.error = e.msg;
                            yield(attempt);
                            continue iploop;
                        }
                        else
                        {
                            // Just treat it as a normal error
                            goto case;// "Unable to connect socket: Connection refused";
                        }

                    // Add more as necessary
                    case "Unable to connect socket: Connection refused":
                        attempt.state = State.error;
                        attempt.error = e.msg;
                        yield(attempt);
                        // Should never get here
                        assert(0, "Dead `connectFiber` resumed after yield");

                    //case "Unable to connect socket: Network is unreachable":
                    default:
                        // Don't delay for retrying on the last retry, drop down below
                        if (retry+1 < connectionRetries)
                        {
                            attempt.state = State.delayThenReconnect;
                            yield(attempt);
                        }
                        break;
                    }
                }
                catch (SSLException e)
                {
                    import std.format : format;

                    attempt.state = State.sslFailure;
                    attempt.error = "%s (%s)"
                        .format(e.msg, conn.getSSLErrorMessage(e.code));
                    yield(attempt);
                    // Should never get here
                    assert(0, "Dead `connectFiber` resumed after yield");
                }
            }

            if (i+1 <= conn.ips.length)
            {
                // Not last IP
                attempt.state = State.delayThenNextIP;
                yield(attempt);
            }
        }
    }
    while (!abort && endlesslyConnect);

    // All IPs exhausted
    ConnectionAttempt endAttempt;
    endAttempt.state = State.noMoreIPs;
    yield(endAttempt);
    // Should never get here
    assert(0, "Dead `connectFiber` resumed after yield");
}


// ResolveAttempt
/++
    Embodies the idea of an address resolution attempt.
 +/
struct ResolveAttempt
{
    /++
        The various states an address resolution attempt may be in.
     +/
    enum State
    {
        preresolve,     /// About to resolve.
        success,        /// Successfully resolved.
        exception,      /// Failure, recoverable exception thrown.
        failure,        /// Resolution failure; should abort.
        error,          /// Failure, unrecoverable exception thrown.
    }

    /// The current state of the attempt.
    State state;

    /// The error message as thrown by an exception.
    string error;

    /// The number of retries so far towards this address.
    uint retryNum;
}


// resolveFiber
/++
    Given an address and a port, resolves these and populates the array of unique
    `std.socket.Address` IPs inside the passed `Connection`.

    Example:
    ---
    import std.concurrency : Generator;

    Connection conn;
    conn.reset();

    auto resolver = new Generator!ResolveAttempt(() =>
        resolveFiber(conn, "irc.freenode.net", 6667, false, 10, abort));

    resolver.call();

    resolveloop:
    foreach (const attempt; resolver)
    {
        // attempt is a yielded `ResolveAttempt`

        with (ResolveAttempt.State)
        final switch (attempt.state)
        {
        case preresolve:
            assert(0, "shouldn't happen");

        case success:
            // Address was resolved, the passed `conn` was modified
            break resolveloop;

        case exception:
            // Recoverable
            dealWithException(attempt.error);
            break;

        case failure:
            // Resolution failed without errors
            failGracefully(attempt.error);
            break;

        case error:
            // Unrecoverable
            dealWithError(attempt.error);
            return;
        }
    }

    // Address resolved
    ---

    Params:
        conn = Reference to the current `Connection`.
        address = String address to look up.
        port = Remote port build into the `std.socket.Address`.
        useIPv6 = Whether to include resolved IPv6 addresses or not.
        resolveAttempts = How many times to try resolving before giving up.
        abort = Reference "abort" flag, which -- if set -- should make the
            function return and the `core.thread.fiber.Fiber` terminate.
 +/
void resolveFiber(ref Connection conn, const string address, const ushort port,
    const bool useIPv6, const uint resolveAttempts, ref bool abort) @system
in (!conn.connected, "Tried to set up a resolving fiber on an already live connection")
in (address.length, "Tried to set up a resolving fiber on an empty address")
{
    import std.concurrency : yield;
    import std.socket : AddressFamily, SocketException, getAddress;

    if (abort) return;

    alias State = ResolveAttempt.State;

    yield(ResolveAttempt.init);

    foreach (immutable i; 0..resolveAttempts)
    {
        if (abort) return;

        ResolveAttempt attempt;
        attempt.retryNum = i;

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
            // Should never get here
            assert(0, "Dead `resolveFiber` resumed after yield");
        }
        catch (SocketException e)
        {
            switch (e.msg)
            {
            case "getaddrinfo error: Name or service not known":
            case "getaddrinfo error: Temporary failure in name resolution":
            case "getaddrinfo error: No such host is known.":
                // Assume net down, wait and try again
                attempt.state = State.exception;
                attempt.error = e.msg;
                yield(attempt);
                continue;

            default:
                attempt.state = State.error;
                attempt.error = e.msg;
                yield(attempt);
                // Should never get here
                assert(0, "Dead `resolveFiber` resumed after yield");
            }
        }
    }

    ResolveAttempt endAttempt;
    endAttempt.state = State.failure;
    yield(endAttempt);
}


// SSLException
/++
    Exception thrown when OpenSSL functions return a non-`1` error code, such as
    when the OpenSSL context could not be setup, or when it could not establish
    an SSL connection from an otherwise live connection.

    The attached `code` should be the error integer yielded from the failing SSL call.
 +/
final class SSLException : Exception
{
    /// SSL error code.
    int code;

    /// Constructor attaching an error code.
    this(const string msg, const int code, const string file = __FILE__,
        const size_t line = __LINE__, Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        this.code = code;
        super(msg, file, line, nextInChain);
    }

    /// Passthrough constructor.
    this(const string msg, const string file = __FILE__, const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(msg, file, line, nextInChain);
    }
}
