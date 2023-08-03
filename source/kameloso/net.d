/++
    Functionality related to connecting to a server over the Internet.

    Includes [core.thread.fiber.Fiber|Fiber]s that help with resolving the
    address of, connecting to, and reading full string lines from a server.

    Having them as [core.thread.fiber.Fiber|Fiber]s means a program can do
    address resolution, connecting and reading while retaining the ability to do
    other stuff concurrently. This means you can conveniently run code in between
    each connection attempt, for instance, without breaking the program's flow.

    Example:
    ---
    import std.concurrency : Generator;

    Connection conn;
    bool abort;  // Set to true if something goes wrong

    conn.reset();

    bool useIPv6 = false;
    enum resolveAttempts = 10;

    auto resolver = new Generator!ResolveAttempt(() =>
        resolveFiber(conn, "irc.libera.chat", 6667, useIPv6, resolveAttempts, abort));

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

    auto listener = new Generator!ListenAttempt(() => listenFiber(conn, abort, timeoutSecond));

    listener.call();

    foreach (const attempt; listener)
    {
        // attempt is a yielded `ListenAttempt`
        doThingsWithLineFromServer(attempt.line);
        // program logic goes here
    }
    ---

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.net;

private:

import kameloso.constants : BufferSize, Timeout;

public:

@safe:


// Connection
/++
    Functions and state needed to maintain a connection.

    This is simply to decrease the amount of globals and to create some
    convenience functions.
 +/
struct Connection
{
private:
    import requests.ssl_adapter : SSL, SSL_CTX, openssl;
    import std.socket : Address, Socket, SocketOption;

    /++
        Real IPv4 and IPv6 sockets to connect through.
     +/
    Socket socket4, socket6;

    /++
        Private cached send timeout setting.
     +/
    uint _sendTimeout;

    /++
        Private cached received timeout setting.
     +/
    uint _receiveTimeout;

    /++
        Private SSL context.
     +/
    SSL_CTX* sslContext;

    /++
        OpenSSL [requests.ssl_adapter.SSL] instance, for use with SSL connections.
     +/
    SSL* sslInstance;

    // setTimeout
    /++
        Sets the [std.socket.SocketOption.RCVTIMEO|SocketOption.RCVTIMEO] of the
        *current* [std.socket.Socket|Socket] [socket] to the specified duration.

        Params:
            option = The [std.socket.SocketOption|SocketOption] to set.
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
        Pointer to the socket of the [std.socket.AddressFamily|AddressFamily] we
        want to connect with.
     +/
    Socket socket;

    /++
        Whether or not this [Connection] should use SSL when sending and receiving.
     +/
    bool ssl;

    /++
        IPs already resolved using [kameloso.net.resolveFiber|resolveFiber].
     +/
    Address[] ips;

    /++
        Implicitly proxies calls to the current [std.socket.Socket|Socket].
        This successfully proxies to [std.socket.Socket.receive|Socket.receive].
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
            A copy of [_sendTimeout].
     +/
    pragma(inline, true)
    auto sendTimeout() const @property pure @nogc nothrow
    {
        return _sendTimeout;
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
        _sendTimeout = dur;
    }

    // receiveTimeout
    /++
        Accessor; returns the current receive timeout.

        Returns:
            A copy of [_receiveTimeout].
     +/
    pragma(inline, true)
    auto receiveTimeout() const @property pure @nogc nothrow
    {
        return _receiveTimeout;
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
        _receiveTimeout = dur;
    }

    // reset
    /++
        (Re-)initialises the sockets and sets the IPv4 one as the active one.

        If we ever change this to a class, this should be the default constructor.
     +/
    void reset()
    {
        teardown();
        setup();
        connected = false;
    }

    // resetSSL
    /++
        Resets the SSL context and resources of this [Connection].
     +/
    void resetSSL() @system
    in (ssl, "Tried to reset SSL on a non-SSL `Connection`")
    {
        teardownSSL();
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
    auto getSSLErrorMessage(const int code) @system
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
        Sets up sockets with the [std.socket.SocketOption|SocketOption]s needed.
        These include timeouts and buffer sizes.

        Params:
            socketToSetup = Reference to the [std.socket.Socket|Socket] to modify.
     +/
    void setDefaultOptions(Socket socketToSetup)
    {
        import std.socket : SocketOption, SocketOptionLevel;
        import core.time : msecs;

        with (socketToSetup)
        with (SocketOption)
        with (SocketOptionLevel)
        {
            setOption(SOCKET, RCVBUF, BufferSize.socketOptionReceive);
            setOption(SOCKET, SNDBUF, BufferSize.socketOptionSend);
            setOption(SOCKET, RCVTIMEO, Timeout.receiveMsecs.msecs);
            setOption(SOCKET, SNDTIMEO, Timeout.sendMsecs.msecs);

            _receiveTimeout = Timeout.receiveMsecs;
            _sendTimeout = Timeout.sendMsecs;
            blocking = true;
        }
    }

    // setupSSL
    /++
        Sets up the SSL context for this connection.

        Throws:
            [SSLException] if the SSL context could not be set up.

            [SSLFileException] if any specified certificate or private key could not be found.
     +/
    void setupSSL() @system
    in (ssl, "Tried to set up SSL context on a non-SSL `Connection`")
    in (socket, "Tried to set up an SSL context on a null `Socket`")
    {
        import std.file : exists;
        import std.path : extension;
        import std.string : toStringz;

        sslContext = openssl.SSL_CTX_new(openssl.TLS_method);
        openssl.SSL_CTX_set_verify(sslContext, 0, null);

        if (certFile.length)
        {
            // Before SSL_new
            if (!certFile.exists)
            {
                enum message = "No such certificate file";
                throw new SSLFileException(
                    message,
                    certFile,
                    __FILE__,
                    __LINE__);
            }

            immutable filetype = (certFile.extension == ".pem") ? 1 : 0;
            immutable code = openssl.SSL_CTX_use_certificate_file(
                sslContext,
                toStringz(certFile),
                filetype);
            if (code != 1) throw new SSLException("Failed to set certificate", code);
        }

        if (privateKeyFile.length)
        {
            // Ditto
            if (!privateKeyFile.exists)
            {
                enum message = "No such private key file";
                throw new SSLFileException(
                    message,
                    privateKeyFile,
                    __FILE__,
                    __LINE__);
            }

            immutable filetype = (privateKeyFile.extension == ".pem") ? 1 : 0;
            immutable code = openssl.SSL_CTX_use_PrivateKey_file(
                sslContext,
                toStringz(privateKeyFile),
                filetype);
            if (code != 1) throw new SSLException("Failed to set private key", code);
        }

        sslInstance = openssl.SSL_new(sslContext);
        immutable code = openssl.SSL_set_fd(sslInstance, cast(int)socket.handle);
        if (code != 1) throw new SSLException("Failed to attach socket handle", code);
    }

    // teardownSSL
    /++
        Frees SSL context and resources.
     +/
    void teardownSSL()
    in (ssl, "Tried to teardown SSL on a non-SSL `Connection`")
    {
        if (sslInstance) openssl.SSL_free(sslInstance);
        if (sslContext) openssl.SSL_CTX_free(sslContext);
    }

    // teardown
    /++
        Shuts down and closes the internal [std.socket.Socket|Socket]s.
     +/
    void teardown()
    {
        import std.range : only;
        import std.socket : SocketShutdown;

        foreach (thisSocket; only(socket4, socket6))
        {
            if (!thisSocket) continue;

            thisSocket.shutdown(SocketShutdown.BOTH);
            thisSocket.close();
        }
    }

    // setup
    /++
        Initialises new [std.socket.Socket|Socket]s and sets their options.
     +/
    void setup()
    {
        import std.socket : TcpSocket, AddressFamily, SocketType;

        socket4 = new TcpSocket;
        socket6 = new Socket(AddressFamily.INET6, SocketType.STREAM);
        socket = socket4;

        setDefaultOptions(socket4);
        setDefaultOptions(socket6);
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
        conn.sendline(longerLine, 1024L);  // Now with custom line lengths
        ---

        Params:
            rawline = Line to send. May contain substrings separated by newline
                characters. A final linebreak is added to the end of the send.
            maxLineLength = Maximum line length before the sent message will be truncated.
            linebreak = Characters to use as linebreak, marking the end of a line to send.

        Throws:
            [SocketSendException] if the call to send data through the socket
            returns [std.socket.Socket.ERROR|Socket.ERROR].
     +/
    void sendline(
        const string rawline,
        const uint maxLineLength = 512,
        const string linebreak = "\r\n") @system
    in (connected, "Tried to send a line on an unconnected `Connection`")
    {
        import std.string : indexOf;

        if (!rawline.length) return;

        immutable maxAvailableLength = (maxLineLength - linebreak.length);

        void sendlineImpl(const string line)
        {
            import std.algorithm.comparison : min;

            immutable lineLength = min(line.length, maxAvailableLength);
            size_t totalSent;

            auto sendSubstring(const string substring)
            in (substring.length, "Tried to send empty substring to server")
            {
                immutable bytesSent = ssl ?
                    openssl.SSL_write(sslInstance, substring.ptr, cast(int)substring.length) :
                    socket.send(substring);

                if (bytesSent == Socket.ERROR)
                {
                    enum message = "Socket.ERROR returned when sending data to server";
                    throw new SocketSendException(message);
                }

                return bytesSent;
            }

            while (totalSent < lineLength)
            {
                totalSent += sendSubstring(line[totalSent..lineLength]);
            }

            // Always end the line with a linebreak
            sendSubstring(linebreak);
        }

        auto newlinePos = rawline.indexOf('\n');  // mutable

        if (newlinePos != -1)
        {
            // Line incorrectly has at least one newline, so send up until
            // the first and discard the remainder

            if ((newlinePos > 0) && (rawline[newlinePos-1] == '\r'))
            {
                // It was actually "\r\n", so omit the '\r' too
                --newlinePos;
            }

            sendlineImpl(rawline[0..newlinePos]);
        }
        else
        {
            // Plain line
            sendlineImpl(rawline);
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
        unset,      /// Init value.
        prelisten,  /// About to listen.
        isEmpty,    /// Empty result; nothing read or similar.
        hasString,  /// String read, ready for processing.
        timeout,    /// Connection read timed out.
        warning,    /// Recoverable exception thrown; warn and continue.
        error,      /// Unrecoverable exception thrown; abort.
    }

    /++
        The current state of the attempt.
     +/
    State state;

    /++
        The last read line of text sent by the server.
     +/
    string line;

    /++
        The [std.socket.lastSocketError|lastSocketError] at the last point of error.
     +/
    string error;

    /++
        [core.stdc.errno.errno|errno] at time of read.
     +/
    int errno;

    /++
        The amount of bytes received this attempt.
     +/
    long bytesReceived;
}


// listenFiber
/++
    A [std.socket.Socket|Socket]-reading [std.concurrency.Generator|Generator].
    It reads and yields full string lines.

    It maintains its own buffer into which it receives from the server, though
    not necessarily full lines. It thus keeps filling the buffer until it
    finds a newline character, yields [ListenAttempt]s back to the caller of
    the Fiber, checks for more lines to yield, and if none yields an attempt
    with a [ListenAttempt.State] denoting that nothing was read and that a new
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
            dealWithError(attempt.error);
            return;
        }
    }
    ---

    Params:
        bufferSize = What size static array to use as buffer. Defaults to twice of
            [kameloso.constants.BufferSize.socketReceive|BufferSize.socketReceive] for now.
        conn = [Connection] whose [std.socket.Socket|Socket] it reads from the server with.
        abort = Reference "abort" flag, which -- if set -- should make the
            function return and the [core.thread.fiber.Fiber|Fiber] terminate.
        connectionLost = How many seconds may pass before we consider the connection lost.
            Optional, defaults to
            [kameloso.constants.Timeout.connectionLost|Timeout.connectionLost].

    Yields:
        [ListenAttempt]s with information about the line received in its member values.
 +/
void listenFiber(size_t bufferSize = BufferSize.socketReceive*2)
    (Connection conn,
    ref bool abort,
    const int connectionLost = Timeout.connectionLost) @system
in ((conn.connected), "Tried to set up a listening fiber on a dead connection")
in ((connectionLost > 0), "Tried to set up a listening fiber with connection timeout of <= 0")
{
    import kameloso.constants : BufferSize;
    import std.concurrency : yield;
    import std.datetime.systime : Clock;
    import std.socket : Socket, lastSocketError;
    import std.string : indexOf;

    if (abort) return;

    ubyte[bufferSize] buffer;
    long timeLastReceived = Clock.currTime.toUnixTime;
    size_t start;

    alias State = ListenAttempt.State;

    /+
        The Generator we use this function with popFronts the first thing it does
        after being instantiated. To work around our main loop popping too we
        yield an initial empty value; else the first thing to happen will be a
        double pop, and the first line is missed.
     +/
    yield(ListenAttempt.init);

    /// How many consecutive warnings to allow before yielding an error.
    enum maxConsecutiveWarningsUntilError = 20;

    /// Current consecutive warnings count.
    uint consecutiveWarnings;

    while (!abort)
    {
        version(Posix)
        {
            import core.stdc.errno;

            // https://www-numi.fnal.gov/offline_software/srt_public_context/WebDocs/Errors/unix_system_errors.html

            enum Errno
            {
                timedOut = EAGAIN,
                wouldBlock = EWOULDBLOCK,
                netDown = ENETDOWN,
                netUnreachable = ENETUNREACH,
                endpointNotConnected = ENOTCONN,
                connectionReset = ECONNRESET,
                connectionAborted = ECONNABORTED,
                interrupted = EINTR,
            }
        }
        else version(Windows)
        {
            import core.sys.windows.winsock2;

            alias errno = WSAGetLastError;

            // https://www.hardhats.org/cs/broker/docs/winsock.html
            // https://infosys.beckhoff.com/english.php?content=../content/1033/tcpipserver/html/tcplclibtcpip_e_winsockerror.htm

            enum Errno
            {
                unexpectedEOF = 0,
                timedOut = WSAETIMEDOUT,
                wouldBlock = WSAEWOULDBLOCK,
                netDown = WSAENETDOWN,
                netUnreachable = WSAENETUNREACH,
                endpointNotConnected = WSAENOTCONN,
                connectionReset = WSAECONNRESET,
                connectionAborted = WSAECONNABORTED,
                interrupted = WSAEINTR,
                overlappedIO = 997,
            }
        }
        else
        {
            static assert(0, "Unsupported platform, please file a bug.");
        }

        ListenAttempt attempt;

        if (conn.ssl)
        {
            import requests.ssl_adapter : openssl;
            attempt.bytesReceived = openssl.SSL_read(
                conn.sslInstance,
                cast(void*)buffer.ptr+start,
                cast(int)(buffer.length-start));
        }
        else
        {
            attempt.bytesReceived = conn.receive(buffer[start..$]);
        }

        attempt.errno = errno;

        if (!attempt.bytesReceived)
        {
            attempt.state = State.error;
            attempt.error = lastSocketError;
            yield(attempt);
            // Should never get here
            assert(0, "Dead `listenFiber` resumed after yield (no bytes received)");
        }

        if (attempt.errno == Errno.interrupted)
        {
            // Interrupted read; try again
            // Unlucky callgrind_control -d timing
            attempt.state = State.isEmpty;
            attempt.error = lastSocketError;
            consecutiveWarnings = 0;
            yield(attempt);
            continue;
        }

        if (attempt.bytesReceived == Socket.ERROR)
        {
            if ((Clock.currTime.toUnixTime - timeLastReceived) > connectionLost)
            {
                attempt.state = State.timeout;
                yield(attempt);

                // Should never get here
                enum message = "Timed out `listenFiber` resumed after yield " ~
                    "(received error, elapsed > timeout)";
                assert(0, message);
            }

            with (Errno)
            switch (attempt.errno)
            {
            case timedOut:
                // Resource temporarily unavailable
                /*
                    A connection attempt failed because the connected party did not
                    properly respond after a period of time, or established connection
                    failed because connected host has failed to respond.
                 */
                // Timed out, nothing received
                attempt.state = State.isEmpty;
                consecutiveWarnings = 0;
                yield(attempt);
                continue;

            static if (int(timedOut) != int(wouldBlock))
            {
                case wouldBlock:
                    /+
                        Portability Note: In many older Unix systems ...
                        [EWOULDBLOCK was] a distinct error code different from
                        EAGAIN. To make your program portable, you should check
                        for both codes and treat them the same.
                     +/
                    // A non-blocking socket operation could not be completed immediately.
                    goto case timedOut;
            }

            version(Windows)
            {
                case overlappedIO:
                    // "Overlapped I/O operation is in progress."
                    // seems benign
                    goto case timedOut;

                case unexpectedEOF:
                    /+
                        If you're getting 0 from WSAGetLastError, then this is
                        most likely due to an unexpected EOF occurring on the socket,
                        i.e. the client has gracefully closed the connection
                        without sending a close_notify alert.
                     +/
                    // "The operation completed successfully."
                    goto case;
            }

            case netDown:
            case netUnreachable:
            case endpointNotConnected:
            case connectionReset:
            case connectionAborted:
                attempt.state = State.error;
                attempt.error = lastSocketError;
                yield(attempt);
                // Should never get here
                assert(0, "Dead `listenFiber` resumed after yield (`lastSocketError` error)");

            default:
                attempt.error = lastSocketError;

                if (++consecutiveWarnings >= maxConsecutiveWarningsUntilError)
                {
                    attempt.state = State.error;
                    yield(attempt);
                    // Should never get here
                    assert(0, "Dead `listenFiber` resumed after yield (exceeded max consecutive errors)");
                }
                else
                {
                    attempt.state = State.warning;
                    yield(attempt);
                    continue;
                }
            }
        }

        timeLastReceived = Clock.currTime.toUnixTime;
        consecutiveWarnings = 0;

        immutable ptrdiff_t end = cast(ptrdiff_t)(start + attempt.bytesReceived);
        ptrdiff_t newline = (cast(char[])buffer[0..end]).indexOf('\n');
        size_t pos;

        while (newline > 0)  // != -1 but we'd get a RangeError if it starts with a '\n'
        {
            attempt.state = State.hasString;
            attempt.line = (cast(char[])buffer[pos..pos+newline-1]).idup;  // eat \r before \n
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
private:
    import std.socket : Address;

public:
    /++
        The various states a connection attempt may be in.
     +/
    enum State
    {
        unset,                   /// Init value.
        preconnect,              /// About to connect.
        connected,               /// Successfully connected.
        delayThenReconnect,      /// Failed to connect; should delay and retry.
        delayThenNextIP,         /// Failed to reconnect several times; next IP.
        //noMoreIPs,             /// Exhausted all IPs and could not connect.
        ipv6Failure,             /// IPv6 connection failed.
        transientSSLFailure,     /// Transient failure establishing an SSL connection, safe to retry.
        fatalSSLFailure,         /// Fatal failure establishing an SSL connection, should abort.
        invalidConnectionError,  /// The current IP cannot be connected to.
        error,                   /// Error connecting; should abort.
    }

    /++
        The current state of the attempt.
     +/
    State state;

    /++
        The IP that the attempt is trying to connect to.
     +/
    Address ip;

    /++
        The error message as thrown by an exception.
     +/
    string error;

    /++
        [core.stdc.errno.errno|errno] at time of connect.
     +/
    int errno;

    /++
        The number of retries so far towards this [ip].
     +/
    uint retryNum;
}


// connectFiber
/++
    Fiber function that tries to connect to IPs in the `ips` array of the passed
    [Connection], yielding at certain points throughout the process to let the
    calling function do stuff in between connection attempts.

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
        conn = Reference to the current, unconnected [Connection].
        connectionRetries = How many times to attempt to connect before signalling
            that we should move on to the next IP.
        abort = Reference "abort" flag, which -- if set -- should make the
            function return and the [core.thread.fiber.Fiber|Fiber] terminate.
 +/
void connectFiber(
    ref Connection conn,
    const uint connectionRetries,
    ref bool abort) @system
in (!conn.connected, "Tried to set up a connecting fiber on an already live connection")
in ((conn.ips.length > 0), "Tried to connect to an unresolved connection")
{
    import std.concurrency : yield;
    import std.socket : AddressFamily, SocketException;

    if (abort) return;

    alias State = ConnectionAttempt.State;

    yield(ConnectionAttempt.init);

    scope(exit)
    {
        conn.teardown();
        if (conn.ssl) conn.teardownSSL();
    }

    do
    {
        iploop:
        foreach (immutable i, ip; conn.ips)
        {
            immutable isIPv6 = (ip.addressFamily == AddressFamily.INET6);

            ConnectionAttempt attempt;
            attempt.ip = ip;

            attemptloop:
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
                    attempt.errno = 0;  // reset
                    yield(attempt);

                    conn.socket.connect(ip);

                    if (conn.ssl)
                    {
                        import requests.ssl_adapter : openssl;

                        immutable code = openssl.SSL_connect(conn.sslInstance);

                        if (code != 1)
                        {
                            enum message = "Failed to establish SSL connection " ~
                                "after successful connect";
                            throw new SSLException(message, code);
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
                    version(Posix)
                    {
                        import core.stdc.errno : EAFNOSUPPORT, ECONNREFUSED,
                            EHOSTUNREACH, ENETUNREACH, errno;

                        // https://www-numi.fnal.gov/offline_software/srt_public_context/WebDocs/Errors/unix_system_errors.html

                        enum Errno
                        {
                            addressFamilyNoSupport = EAFNOSUPPORT,
                            connectionRefused = ECONNREFUSED,
                            noRouteToHost = EHOSTUNREACH,
                            networkUnreachable = ENETUNREACH,
                        }

                        attempt.errno = errno;
                    }
                    else version(Windows)
                    {
                        import core.sys.windows.winsock2 : WSAEAFNOSUPPORT, WSAECONNREFUSED,
                            WSAEHOSTUNREACH, WSAENETUNREACH, WSAGetLastError;

                        enum Errno
                        {
                            addressFamilyNoSupport = WSAEAFNOSUPPORT,
                            connectionRefused = WSAECONNREFUSED,
                            noRouteToHost = WSAEHOSTUNREACH,
                            networkUnreachable = WSAENETUNREACH,
                        }

                        attempt.errno = WSAGetLastError();
                    }
                    else
                    {
                        static assert(0, "Unsupported platform, please file a bug.");
                    }

                    with (Errno)
                    switch (attempt.errno)
                    {
                    case addressFamilyNoSupport:
                        // Address family not supported by protocol
                        // An address incompatible with the requested protocol was used.
                        if (isIPv6)
                        {
                            attempt.state = State.ipv6Failure;
                            attempt.error = e.msg;
                            yield(attempt);

                            // Remove IPv6 addresses from conn.ips
                            foreach_reverse (immutable n, const arrayIP; conn.ips)
                            {
                                if (n == i) break;  // caught up to current

                                if (arrayIP.addressFamily == AddressFamily.INET6)
                                {
                                    import std.algorithm.mutation : SwapStrategy, remove;
                                    conn.ips = conn.ips
                                        .remove!(SwapStrategy.unstable)(n);
                                }
                            }
                            continue iploop;
                        }
                        else
                        {
                            // Just treat it as a normal error
                            goto case;
                        }

                    case connectionRefused:
                        // Connection refused
                        // No connection could be made because the target machine actively refused it.
                        attempt.state = State.invalidConnectionError;
                        attempt.error = e.msg;
                        yield(attempt);
                        continue iploop;

                    //case noRouteToHost:
                        // No route to host
                        // A socket operation was attempted to an unreachable host.
                    //case networkUnreachable:
                        // Network is unreachable
                        // A socket operation was attempted to an unreachable network.
                    default:
                        // Don't delay for retrying on the last retry, drop down below
                        if (retry+1 < connectionRetries)
                        {
                            attempt.state = State.delayThenReconnect;
                            attempt.error = e.msg;
                            yield(attempt);
                        }
                        continue attemptloop;
                    }
                }
                catch (SSLException e)
                {
                    import std.format : format;

                    enum pattern = "%s (%s)";
                    attempt.state = State.transientSSLFailure;
                    attempt.error = pattern.format(e.msg, conn.getSSLErrorMessage(e.code));
                    yield(attempt);
                    continue attemptloop;
                }
                catch (SSLFileException e)
                {
                    import kameloso.string : doublyBackslashed;
                    import std.format : format;

                    enum pattern = "%s: %s";
                    attempt.state = State.fatalSSLFailure;
                    attempt.error = pattern.format(e.msg, e.filename.doublyBackslashed);
                    yield(attempt);
                    continue attemptloop;
                }
            }

            // foreach ended; connectionRetries reached.
            // Move on to next IP (or same again if only one)
            attempt.state = (conn.ips.length > 1) ?
                State.delayThenNextIP :
                State.delayThenReconnect;
            yield(attempt);
        }
    }
    while (!abort);
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
        unset,          /// Init value.
        preresolve,     /// About to resolve.
        success,        /// Successfully resolved.
        exception,      /// Failure, recoverable exception thrown.
        failure,        /// Resolution failure; should abort.
        error,          /// Failure, unrecoverable exception thrown.
    }

    /++
        The current state of the attempt.
     +/
    State state;

    /++
        The error message as thrown by an exception.
     +/
    string error;

    /++
        [core.stdc.errno.errno|errno] at time of resolve.
     +/
    int errno;

    /++
        The number of retries so far towards this address.
     +/
    uint retryNum;
}


// resolveFiber
/++
    Given an address and a port, resolves these and populates the array of unique
    [std.socket.Address|Address] IPs inside the passed [Connection].

    Example:
    ---
    import std.concurrency : Generator;

    Connection conn;
    conn.reset();

    auto resolver = new Generator!ResolveAttempt(() =>
        resolveFiber(conn, "irc.libera.chat", 6667, false, 10, abort));

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
        conn = Reference to the current [Connection].
        address = String address to look up.
        port = Remote port build into the [std.socket.Address|Address].
        useIPv6 = Whether to include resolved IPv6 addresses or not.
        abort = Reference "abort" flag, which -- if set -- should make the
            function return and the [core.thread.fiber.Fiber|Fiber] terminate.
 +/
void resolveFiber(
    ref Connection conn,
    const string address,
    const ushort port,
    const bool useIPv6,
    ref bool abort) @system
in (!conn.connected, "Tried to set up a resolving fiber on an already live connection")
in (address.length, "Tried to set up a resolving fiber on an empty address")
{
    import std.concurrency : yield;
    import std.socket : AddressFamily, SocketOSException, getAddress;

    if (abort) return;

    alias State = ResolveAttempt.State;

    yield(ResolveAttempt(State.preresolve));

    for (uint i; (i >= 0); ++i)
    {
        if (abort) return;

        ResolveAttempt attempt;
        attempt.retryNum = i;

        try
        {
            import std.algorithm.iteration : filter, uniq;
            import std.array : array;

            conn.ips = getAddress(address, port)
                .filter!(ip => (ip.addressFamily == AddressFamily.INET) ||
                    ((ip.addressFamily == AddressFamily.INET6) && useIPv6))
                .uniq!((a,b) => a.toAddrString == b.toAddrString)
                .array;

            attempt.state = State.success;
            yield(attempt);
            // Should never get here
            assert(0, "Dead `resolveFiber` resumed after yield");
        }
        catch (SocketOSException e)
        {
            attempt.errno = e.errorCode;

            version(Posix)
            {
                import core.sys.posix.netdb : EAI_AGAIN, EAI_FAIL, EAI_FAMILY,
                    EAI_NONAME, EAI_SOCKTYPE, EAI_SYSTEM;

                enum EAI_NODATA = -5;

                // https://stackoverflow.com/questions/4395919/linux-system-call-getaddrinfo-return-2

                enum AddrInfoErrors
                {
                    //badFlags   = EAI_BADFLAGS,     /** Invalid value for `ai_flags` field. */
                    noName       = EAI_NONAME,       /** NAME or SERVICE is unknown. */
                    again        = EAI_AGAIN,        /** Temporary failure in name resolution. */
                    fail         = EAI_FAIL,         /** Non-recoverable failure in name res. */
                    noData       = EAI_NODATA,       /** No address associated with NAME. (GNU) */
                    family       = EAI_FAMILY,       /** `ai_family` not supported. */
                    sockType     = EAI_SOCKTYPE,     /** `ai_socktype` not supported. */
                    //service    = EAI_SERVICE,      /** SERVICE not supported for `ai_socktype`. */
                    //addrFamily = EAI_ADDRFAMILY,   /** Address family for NAME not supported. (GNU) */
                    //memory     = EAI_MEMORY,       /** Memory allocation failure. */
                    system       = EAI_SYSTEM,       /** System error returned in `errno`. */
                    //overflow   = EAI_OVERFLOW,     /** Argument buffer overflow. */
                }
            }
            else version(Windows)
            {
                import core.sys.windows.winsock2 : WSAEAFNOSUPPORT, WSAESOCKTNOSUPPORT,
                    WSAHOST_NOT_FOUND, WSANO_DATA, WSANO_RECOVERY, WSATRY_AGAIN;

                // https://docs.microsoft.com/en-us/windows/win32/api/ws2tcpip/nf-ws2tcpip-getaddrinfo

                enum AddrInfoErrors
                {
                    //badFlags   = WSAEINVAL,            /** An invalid value was provided for the `ai_flags` member of the `pHints` parameter. */
                    noName       = WSAHOST_NOT_FOUND,    /** The name does not resolve for the supplied parameters or the `pNodeName` and `pServiceName` parameters were not provided. */
                    again        = WSATRY_AGAIN,         /** A temporary failure in name resolution occurred. */
                    fail         = WSANO_RECOVERY,       /** A nonrecoverable failure in name resolution occurred. */
                    noData       = WSANO_DATA,
                    family       = WSAEAFNOSUPPORT,      /** The 'ai_family' member of the `pHints` parameter is not supported. */
                    sockType     = WSAESOCKTNOSUPPORT,   /** The `ai_socktype` member of the `pHints` parameter is not supported. */
                    //service    = WSATYPE_NOT_FOUND,    /** The `pServiceName` parameter is not supported for the specified `ai_socktype` member of the `pHints` parameter. */
                    //addrFamily = ?,
                    //memory     = WSANOT_ENOUGH_MEMORY, /** A memory allocation failure occurred. */
                    //system     = ?,
                    //overflow   = ?,
                }
            }
            else
            {
                static assert(0, "Unsupported platform, please file a bug.");
            }

            with (AddrInfoErrors)
            switch (attempt.errno)
            {
            case noName:
            case again:
                // Assume net down, wait and try again
                attempt.state = State.exception;
                attempt.error = e.msg;
                yield(attempt);
                continue;

            version(Posix)
            {
                case system:
                    import core.stdc.errno : errno;
                    attempt.errno = errno;
                    goto default;
            }

            //case noData:
            //case fail:
            //case family:
            //case sockType:
            default:
                attempt.state = State.error;
                attempt.error = e.msg;
                yield(attempt);
                // Should never get here
                assert(0, "Dead `resolveFiber` resumed after yield");
            }
        }
    }

    // This doesn't really happen at present. Subject to change, so keep it here.
    /*ResolveAttempt endAttempt;
    endAttempt.state = State.failure;
    yield(endAttempt);*/
    assert(0, "Broke out of unending `for` loop in `resolveFiber`");
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
    /++
        SSL error code.
     +/
    int code;

    /++
        Constructor attaching an error code.
     +/
    this(
        const string msg,
        const int code,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        this.code = code;
        super(msg, file, line, nextInChain);
    }

    /++
        Passthrough constructor.
     +/
    this(
        const string msg,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(msg, file, line, nextInChain);
    }
}


// SSLFileException
/++
    Exception thrown when a certificate or a private key file could not be found.
 +/
final class SSLFileException : Exception
{
    /++
        Filename that doesn't exist.
     +/
    string filename;

    /++
        Constructor attaching an error code.
     +/
    this(
        const string msg,
        const string filename,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        this.filename = filename;
        super(msg, file, line, nextInChain);
    }

    /++
        Passthrough constructor.
     +/
    this(
        const string msg,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(msg, file, line, nextInChain);
    }
}


// SocketSendException
/++
    Exception thrown when a socket send action returned [std.socket.Socket.ERROR|Socket.ERROR].
 +/
final class SocketSendException : Exception
{
    /++
        Passthrough constructor.
     +/
    this(
        const string msg,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(msg, file, line, nextInChain);
    }
}
