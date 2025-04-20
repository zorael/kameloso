/++
    Functionality related to connecting to a server over the Internet.

    Includes [core.thread.fiber.Fiber|Fiber]s that help with connecting to and
    reading full string lines from a server.

    Having them as [core.thread.fiber.Fiber|Fiber]s means a program can do
    connecting and reading while retaining the ability to do
    other stuff concurrently. This means you can conveniently run code in between
    each connection attempt, for instance, without breaking the program's flow.

    Example:
    ---
    import std.concurrency : Generator;

    Connection conn;
    bool* abort;  // Set to true if something goes wrong

    conn.reset();

    void onSuccessDg(ResolveAttempt attempt)
    {
        writeln("Resolved IPs: ", conn.ips);
    }

    void onRetryDg(ResolveAttempt attempt)
    {
        writeln("Retrying...");
    }

    bool onFailureDg(ResolveAttempt attempt)
    {
        writeln("Failed to resolve!");
        return false;
    }

    immutable actionAfterResolve = delegateResolve(
        conn: conn,
        address: "example.com",
        port: 80,
        useIPv6: true,
        onSuccessDg: &onSuccessDg,
        onRetryDg: &onRetryDg,
        onFailureDg: &onFailureDg,
        abort: abort);

    if (actionAfterResolve != Next.continue_) return;

    enum connectionRetries = 10;

    auto connector = new Generator!ConnectionAttempt(() =>
        connectFiber(
            conn,
            connectionRetries,
            abort));

    connectorloop:
    foreach (const attempt; connector)
    {
        // attempt is a yielded `ConnectionAttempt`
        // as above
    }

    // Connection established

    immutable connectionLost = 600.seconds;

    auto listener = new Generator!ListenAttempt(() =>
        listenFiber(
            conn,
            abort,
            connectionLost));

    listener.call();

    foreach (const attempt; listener)
    {
        // attempt is a yielded `ListenAttempt`
        // as above
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

version(Windows) version = WindowsPlatform;
version(unittest) version = WindowsPlatform;

private:

import kameloso.constants : BufferSize, Timeout;
import core.time : Duration;

public:

@safe:


// Connection
/++
    Functions and state needed to maintain a connection.

    This is simply to decrease the amount of globals and to create some
    convenience functions.
 +/
final class Connection
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
        IPs already resolved.
     +/
    Address[] ips;

    /++
        Proxies calls to [std.socket.Socket.receive|socket.receive].

        This replaces `alias socket this`, which is deprecated for classes in
        some compiler versions.

        Params:
            buffer = Buffer to receive data into.

        Returns:
            The amount of bytes received.
     +/
    auto receive(ubyte[] buffer)
    {
        return socket.receive(buffer);
    }

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
    auto sendTimeout() const pure nothrow @nogc
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
    void sendTimeout(const uint dur)
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
    auto receiveTimeout() const pure nothrow @nogc
    {
        return _receiveTimeout;
    }

    // sendTimeout
    /++
        Mutator; sets the receive timeout socket option to the passed duration.

        Params:
            dur = The duration to assign as receive timeout, in number of milliseconds.
     +/
    pragma(inline, true)
    void receiveTimeout(const uint dur)
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
        import std.exception : assumeUnique;
        import std.string : fromStringz;

        immutable errorCode = openssl.SSL_get_error(sslInstance, code);
        return openssl.ERR_reason_error_string(errorCode)
            .fromStringz
            .assumeUnique();
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
        import kameloso.constants : Timeout;
        import std.socket : SocketOption, SocketOptionLevel;

        with (socketToSetup)
        with (SocketOption)
        with (SocketOptionLevel)
        {
            setOption(SOCKET, RCVBUF, BufferSize.socketOptionReceive);
            setOption(SOCKET, SNDBUF, BufferSize.socketOptionSend);
            setOption(SOCKET, RCVTIMEO, Timeout.receive);
            setOption(SOCKET, SNDTIMEO, Timeout.send);

            _receiveTimeout = Timeout.Integers.receiveMsecs;
            _sendTimeout = Timeout.Integers.sendMsecs;
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

        try
        {
            sslContext = openssl.SSL_CTX_new(openssl.TLS_method);
            openssl.SSL_CTX_set_verify(sslContext, 0, null);
        }
        catch (Exception e)
        {
            import kameloso.constants : MagicErrorStrings;

            if (e.msg == MagicErrorStrings.sslContextCreationFailure)
            {
                enum message = MagicErrorStrings.sslLibraryNotFoundRewritten;
                throw new SSLException(message);
            }

            // Unsure what this could be so just rethrow it
            throw e;
        }

        if (certFile.length)
        {
            // Before SSL_new
            if (!certFile.exists)
            {
                enum message = "No such certificate file";
                throw new SSLFileException(
                    message: message,
                    filename: certFile);
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
                    message: message,
                    filename: privateKeyFile);
            }

            immutable filetype = (privateKeyFile.extension == ".pem") ? 1 : 0;
            immutable code = openssl.SSL_CTX_use_PrivateKey_file(
                sslContext,
                toStringz(privateKeyFile),
                filetype);
            if (code != 1) throw new SSLException("Failed to set private key", code);
        }

        sslInstance = openssl.SSL_new(sslContext);
        immutable code = openssl.SSL_set_fd(sslInstance, cast(int) socket.handle);
        if (code != 1) throw new SSLException("Failed to attach socket handle", code);
    }

    // teardownSSL
    /++
        Frees SSL context and resources.
     +/
    void teardownSSL()
    in (ssl, "Tried to teardown SSL on a non-SSL `Connection`")
    {
        if (!this.sslInstance && !this.sslContext) return;

        version(ThreadedSSLFree)
        {
            static void freeSSL(shared SSL* sslInstance, shared SSL_CTX* sslContext)
            {
                if (sslInstance) openssl.SSL_free(cast(SSL*) sslInstance);
                if (sslContext) openssl.SSL_CTX_free(cast(SSL_CTX*) sslContext);
            }

            // Casting to and from shared is not @safe. Hopefully history will forgive me for this.
            () @trusted
            {
                import std.concurrency : spawn;
                cast(void) spawn(&freeSSL, cast(shared) this.sslInstance, cast(shared) this.sslContext);
            }();
        }
        else
        {
            if (this.sslInstance) openssl.SSL_free(this.sslInstance);
            if (this.sslContext) openssl.SSL_CTX_free(this.sslContext);
        }

        this.sslInstance = null;
        this.sslContext = null;
    }

    // teardown
    /++
        Shuts down and closes the internal [std.socket.Socket|Socket]s.
     +/
    void teardown()
    {
        import std.socket : SocketShutdown;

        Socket[2] bothSockets =
        [
            socket4,
            socket6,
        ];

        foreach (thisSocket; bothSockets[])
        {
            if (!thisSocket) continue;

            thisSocket.shutdown(SocketShutdown.BOTH);
            thisSocket.close();
        }

        if (ssl) teardownSSL();
        connected = false;
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

        Intended for servers that delimits lines by linebreaks, such as IRC servers.

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
                    openssl.SSL_write(sslInstance, substring.ptr, cast(int) substring.length) :
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
    enum ListenState
    {
        unset,      /// Init value.
        noop,       /// Nothing.
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
    ListenState state;

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
    the fiber, checks for more lines to yield, and if none yields an attempt
    with a [ListenAttempt.State] denoting that nothing was read and that a new
    attempt should be made later.

    Example:
    ---
    //Connection conn;  // Address previously connected established with

    immutable connectionLost = 600.seconds;

    auto listener = new Generator!ListenAttempt(() =>
        listenFiber(
            conn,
            abort,
            connectionLost));

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
        conn = [Connection] whose [std.socket.Socket|Socket] it reads from the server with.
        abort = Pointer to the "abort" flag, which -- if set -- should make the
            function return and the [core.thread.fiber.Fiber|Fiber] terminate.
        connectionLost = How many seconds may pass before we consider the connection lost.
            Optional, defaults to
            [kameloso.constants.Timeout.connectionLost|Timeout.connectionLost].
        bufferSize = Size of the buffer to use for reading from the server.
            Optional, defaults to
            [kameloso.constants.BufferSize.socketReceive|BufferSize.socketReceive].

    Yields:
        [ListenAttempt]s with information about the line received in its member values.
 +/
void listenFiber(
    Connection conn,
    const bool* abort,
    const Duration connectionLost = Timeout.connectionLost,
    const size_t bufferSize = BufferSize.socketReceive) @system
in (conn.connected, "Tried to set up a listening fiber on a dead connection")
in ((connectionLost > Duration.zero), "Tried to set up a listening fiber with connection timeout of <= 0")
{
    import std.concurrency : yield;
    import std.datetime.systime : Clock;
    import std.socket : Socket, lastSocketError;
    import std.string : indexOf;
    import core.time : MonoTime, seconds;

    if (*abort) return;

    scope buffer = new ubyte[bufferSize];
    auto timeLastReceived = MonoTime.currTime;
    size_t start;

    alias State = ListenAttempt.ListenState;
    yield(ListenAttempt(State.noop));

    /// How many consecutive warnings to allow before yielding an error.
    enum maxConsecutiveWarningsUntilError = 20;

    /// Current consecutive warnings count.
    uint consecutiveWarnings;

    while (!*abort)
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
                cast(void*) buffer.ptr+start,
                cast(int) (buffer.length-start));
        }
        else
        {
            attempt.bytesReceived = conn.receive(buffer[start..$]);
        }

        attempt.errno = errno;
        immutable timeReceiveAttempt = MonoTime.currTime;

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
            immutable delta = (timeReceiveAttempt - timeLastReceived);

            if (delta > connectionLost)
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

        timeLastReceived = timeReceiveAttempt;
        consecutiveWarnings = 0;

        immutable ptrdiff_t end = cast(ptrdiff_t) (start + attempt.bytesReceived);
        ptrdiff_t newline = (cast(char[]) buffer[0..end]).indexOf('\n');
        size_t pos;

        while (newline > 0)  // != -1 but we'd get a RangeError if it starts with a '\n'
        {
            attempt.state = State.hasString;
            attempt.line = (cast(char[]) buffer[pos..pos+newline-1]).idup;  // eat \r before \n
            yield(attempt);
            pos += (newline + 1); // eat remaining newline
            newline = (cast(char[]) buffer[pos..end]).indexOf('\n');
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

        // writefln("REMNANT:|%s|", cast(string) buffer[pos..end]);
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
    enum ConnectState
    {
        unset,                   /// Init value.
        noop,                    /// Nothing.
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
        exception,               /// Some other Exception was thrown.
    }

    /++
        The current state of the attempt.
     +/
    ConnectState state;

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
    //Connection conn;  // Address previously resolved

    auto connector = new Generator!ConnectionAttempt(() =>
        connectFiber(
            conn,
            10,
            abort));

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
        conn = The current, unconnected [Connection].
        connectionRetries = How many times to attempt to connect before signalling
            that we should move on to the next IP.
        abort = Pointer to the "abort" flag, which -- if set -- should make the
            function return and the [core.thread.fiber.Fiber|Fiber] terminate.
 +/
void connectFiber(
    Connection conn,
    const uint connectionRetries,
    const bool* abort) @system
in (!conn.connected, "Tried to set up a connecting fiber on an already live connection")
in ((conn.ips.length > 0), "Tried to connect to an unresolved connection")
{
    import std.concurrency : yield;
    import std.socket : AddressFamily, SocketException;

    if (*abort) return;

    alias State = ConnectionAttempt.ConnectState;
    yield(ConnectionAttempt(State.noop));

    scope(exit) conn.teardown();

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
                if (*abort) return;

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

                    try
                    {
                        conn.socket.connect(ip);
                    }
                    catch (Exception e)
                    {
                        static import core.stdc.errno;
                        attempt.state = State.exception;
                        attempt.error = e.msg;
                        attempt.errno = core.stdc.errno.errno;
                        yield(attempt);

                        // If it is an exception due to missing OpenSSL,
                        // we can't continue, but let the caller decide
                        continue attemptloop;
                    }

                    if (conn.ssl)
                    {
                        import requests.ssl_adapter : openssl;

                        immutable code = openssl.SSL_connect(conn.sslInstance);

                        if (code != 1)
                        {
                            if (code == -1)
                            {
                                // Seems to happen sometimes for no reason
                                attempt.state = State.transientSSLFailure;
                                attempt.error = "Hopefully transient SSL failure";
                                attempt.errno = code;
                                yield(attempt);
                                continue attemptloop;
                            }
                            else
                            {
                                attempt.state = State.fatalSSLFailure;
                                attempt.error = "Failed to establish SSL connection " ~
                                    "after successful connect";
                                attempt.errno = code;
                                yield(attempt);
                                // Should never get here
                                assert(0, "Finished `connectFiber` resumed after yield (SSL error)");
                            }
                        }
                    }

                    // If we're here no exception was thrown and we didn't yield
                    // out of SSL errors, so we're connected
                    attempt.state = State.connected;
                    conn.connected = true;
                    yield(attempt);
                    // Should never get here
                    assert(0, "Finished `connectFiber` resumed after yield (connected)");
                }
                catch (SocketException e)
                {
                    version(Posix)
                    {
                        import core.stdc.errno :
                            EAFNOSUPPORT,
                            ECONNREFUSED,
                            EHOSTUNREACH,
                            ENETUNREACH,
                            errno;

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
                        import core.sys.windows.winsock2 :
                            WSAEAFNOSUPPORT,
                            WSAECONNREFUSED,
                            WSAEHOSTUNREACH,
                            WSAENETUNREACH,
                            WSAGetLastError;

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
                    attempt.state = State.fatalSSLFailure;
                    attempt.error = e.msg;
                    yield(attempt);
                    // Should never get here
                    assert(0, "Finished `connectFiber` resumed after yield (SSL error)");
                }
                catch (SSLFileException e)
                {
                    import kameloso.string : doublyBackslashed;
                    import std.format : format;

                    enum pattern = "%s: %s";
                    attempt.state = State.fatalSSLFailure;
                    attempt.error = pattern.format(e.msg, e.filename.doublyBackslashed);
                    yield(attempt);
                    // Should never get here
                    assert(0, "Finished `connectFiber` resumed after yield (SSL error)");
                }
                catch (Exception e)
                {
                    // Unsure what this could be but pass on a fatal state
                    attempt.state = State.fatalSSLFailure;
                    attempt.error = e.msg;
                    yield(attempt);
                    // Should never get here
                    assert(0, "Finished `connectFiber` resumed after yield (SSL error)");
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
    while (!*abort);
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
    enum ResolveState
    {
        unset,          /// Init value.
        noop,           /// Do nothing.
        success,        /// Successfully resolved.
        exception,      /// Failure, recoverable exception thrown.
        failure,        /// Resolution failure; should abort.
        error,          /// Failure, unrecoverable exception thrown.
    }

    /++
        The current state of the attempt.
     +/
    ResolveState state;

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


// delegateResolve
/++
    Given an address and a port, resolves these and populates the array of unique
    [std.socket.Address|Address] IPs inside the passed [Connection].

    Example:
    ---
    Connection conn;

    void onSuccessDg(ResolveAttempt attempt)
    {
        writeln("Resolved IPs: ", conn.ips);
    }

    void onRetryDg(ResolveAttempt attempt)
    {
        writeln("Retrying...");
    }

    bool onFailureDg(ResolveAttempt attempt)
    {
        writeln("Failed to resolve!");
        return false;
    }

    immutable actionAfterResolve = delegateResolve(
        conn: conn,
        address: "example.com",
        port: 80,
        useIPv6: true,
        onSuccessDg: &onSuccessDg,
        onRetryDg: &onRetryDg,
        onFailureDg: &onFailureDg,
        abort: abort);
    ---

    Params:
        conn = A [Connection].
        address = String address to look up.
        port = Remote port build into the [std.socket.Address|Address].
        useIPv6 = Whether to include resolved IPv6 addresses or not.
        onSuccessDg = Delegate to call on successful resolution.
        onRetryDg = Delegate to call on recoverable resolution failure.
        onFailureDg = Delegate to call on potentially unrecoverable resolution failure.
            (The return value dictates whether to retry or not.)
        abort = Pointer to the global abort flag, which -- if set -- should make
            the function return.
 +/
auto delegateResolve(
    Connection conn,
    const string address,
    const ushort port,
    const bool useIPv6,
    scope void delegate(ResolveAttempt) onSuccessDg,
    scope void delegate(ResolveAttempt) onRetryDg,
    scope bool delegate(ResolveAttempt) onFailureDg,
    const bool* abort) @system
{
    import lu.misc : Next;
    import std.socket : AddressFamily, SocketOSException, getAddress;

    alias State = ResolveAttempt.ResolveState;

    foreach (immutable i; 0..uint.max)
    {
        if (*abort) return Next.returnFailure;

        ResolveAttempt attempt;
        attempt.retryNum = i;

        try
        {
            import std.algorithm.iteration : filter, uniq;
            import std.algorithm.sorting : sort;
            import std.array : array;
            import std.functional : lessThan;

            conn.ips = getAddress(address, port)
                .filter!
                    (ip => (ip.addressFamily == AddressFamily.INET) ||
                        ((ip.addressFamily == AddressFamily.INET6) && useIPv6))
                .array
                .sort!((a,b) => a.toAddrString.lessThan(b.toAddrString))
                .uniq!((a,b) => a.toAddrString == b.toAddrString)
                .array;

            attempt.state = State.success;
            onSuccessDg(attempt);
            return Next.continue_;
        }
        catch (SocketOSException e)
        {
            attempt.errno = e.errorCode;

            version(Posix)
            {
                import core.sys.posix.netdb :
                    EAI_AGAIN,
                    EAI_FAIL,
                    EAI_FAMILY,
                    EAI_NONAME,
                    EAI_SOCKTYPE,
                    EAI_SYSTEM;

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
                import core.sys.windows.winsock2 :
                    WSAEAFNOSUPPORT,
                    WSAESOCKTNOSUPPORT,
                    WSAHOST_NOT_FOUND,
                    WSANO_DATA,
                    WSANO_RECOVERY,
                    WSATRY_AGAIN;

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
                onRetryDg(attempt);
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
                immutable shouldContinue = onFailureDg(attempt);
                if (shouldContinue) continue;
                return Next.returnFailure;
            }
        }
    }

    // This doesn't really happen at present. Subject to change, so keep it here.
    /*ResolveAttempt endAttempt;
    endAttempt.state = State.failure;
    onFailureDg(endAttempt);
    return Next.returnFailure;*/

    assert(0, "unreachable");
}


// openSSLIsInstalled
/++
    Returns whether OpenSSL is installed on the system or not.
    Only really relevant on Windows.

    Returns:
        `true` if OpenSSL is installed, `false` if not.
 +/
version(WindowsPlatform)
auto openSSLIsInstalled() @system
{
    import requests.ssl_adapter : openssl;

    try
    {
        // This throws if OpenSSL is not installed
        cast(void) openssl.TLS_method();
        return true;
    }
    catch (Exception _)
    {
        return false;
    }
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
        const string message,
        const string filename,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        this.filename = filename;
        super(message, file, line, nextInChain);
    }

    /++
        Passthrough constructor.
     +/
    this(
        const string message,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
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


// HTTPRequest
/++
    Embodies the notion of an HTTP request.

    Values aggregated in a struct for easier passing around.
 +/
struct HTTPRequest
{
private:
    import kameloso.tables : HTTPVerb;

public:
    /++
        Unique ID of the request, in terms of an index of [Querier.responseBucket].
     +/
    int id;

    /++
        URL of the request.
     +/
    string url;

    /++
        The value of the `Authorization` header, like "`Bearer asdfasdfkljasfl"`.
     +/
    string authorisationHeader;

    /++
        The value of the `Client-ID` header.
     +/
    string clientID;

    /++
        Whether or not to verify peers, to allow it being overridden to false.
     +/
    bool verifyPeer;

    /++
        Path to a certificate bundle file.
     +/
    string caBundleFile;

    /++
        A `string[string]` associative array of custom headers.
     +/
    shared string[string] customHeaders;

    /++
        The HTTP verb of the request.
     +/
    HTTPVerb verb;

    /++
        The textual body of the request, as an `ubyte[]` array.
     +/
    immutable(ubyte)[] body;

    /++
        The HTTP content type of the request.
     +/
    string contentType;

    /++
        The name of the calling function.
     +/
    string caller;

    /++
        Constructor.

        Use named arguments to only assign values to certain parameters.

        Params:
            id = Unique ID of the request.
            url = URL of the request.
            authorisationHeader = Optional value of an `Authorization` header.
            clientID = Optional value of a `Client-ID` header.
            verifyPeer = Optionally whether or not to verify peers.
            caBundleFile = Optional path to a certificate bundle file.
            customHeaders = Optional `string[string]` associative array of custom headers.
            verb = Optional HTTP verb, default [kameloso.tables.HTTPVerb.get|get].
            body = Optional textual body.
            contentType = Optional HTTP content type of the request, default "application/json".
            caller = Name of the calling function.
     +/
    this(
        const int id,
        const string url,
        const string authorisationHeader = string.init,
        const string clientID = string.init,
        const bool verifyPeer = true,
        const string caBundleFile = string.init,
        shared string[string] customHeaders = null,
        const HTTPVerb verb = HTTPVerb.get,
        immutable(ubyte)[] body = null,
        const string contentType = "application/json",
        const string caller = __FUNCTION__)
    {
        this.id = id;
        this.url = url;
        this.authorisationHeader = authorisationHeader;
        this.clientID = clientID;
        this.verifyPeer = verifyPeer;
        this.caBundleFile = caBundleFile;
        this.customHeaders = customHeaders;
        this.verb = verb;
        this.body = body;
        this.contentType = contentType;
        this.caller = caller;
    }
}


/++
    Querier.
 +/
final class Querier
{
private:
    import lu.container : MutexedAA;
    import std.concurrency : Tid;
    import core.thread.fiber : Fiber;

    /++
        [std.concurrency.Tid|Tid] array of worker threads.
     +/
    Tid[] workers;

    /++
        Index of the next worker to use.
     +/
    size_t nextWorkerIndex;

public:
    /++
        Responses to HTTP queries.
     +/
    MutexedAA!(HTTPQueryResponse[int]) responseBucket;

    /++
        Constructor.

        Params:
            numWorkers = Number of worker threads to spawn.
     +/
    this(uint numWorkers) @system
    in ((numWorkers > 0), "Tried to spawn 0 workers")
    {
        responseBucket.setup();
        workers.length = numWorkers;

        foreach (immutable i; 0..numWorkers)
        {
            import std.concurrency : spawn;
            workers[i] = spawn(&Querier.listenInThread, responseBucket, i);
        }
    }

    /++
        Yields the [std.concurrency.Tid|Tid] of the next worker in line.

        Returns:
            The next worker [std.concurrency.Tid|Tid].
     +/
    auto nextWorker()
    in (workers.length, "No workers spawned")
    {
        if (nextWorkerIndex >= workers.length) nextWorkerIndex = 0;
        return workers[nextWorkerIndex++];
    }

    /++
        Effectively a destructor. Stops all workers.
     +/
    void teardown() @system
    {
        import std.typecons : Flag, No, Yes;

        foreach (immutable i; 0..workers.length)
        {
            import std.concurrency : prioritySend;
            workers[i].prioritySend(true);
            workers[i] = Tid.init;
        }

        workers = null;
        nextWorkerIndex = 0L;
    }

    /++
        Listens for concurrency messages to issue HTTP requests.

        Intended to be spawned in a separate thread.

        Params:
            responseBucket = The associative array into which to put responses.
            id = The ID of the worker, referring to its index in
                [Querier.workers].
     +/
    static void listenInThread(
        MutexedAA!(HTTPQueryResponse[int]) responseBucket,
        const uint id) @system
    {
        version(Posix)
        {
            import kameloso.thread : setThreadName;
            import std.conv : text;

            immutable name = text("querier-", id);
            setThreadName(name);
        }

        void onHTTPRequestDg(HTTPRequest request)
        {
            scope(failure) responseBucket.remove(request.id);

            version(BenchmarkHTTPRequests)
            {
                import core.time : MonoTime;
                immutable pre = MonoTime.currTime;
            }

            immutable response = issueSyncHTTPRequest(request);

            if (response != HTTPQueryResponse.init)
            {
                responseBucket[request.id] = response;
            }
            else
            {
                responseBucket.remove(request.id);
            }

            version(BenchmarkHTTPRequests)
            {
                import std.stdio : stdout, writefln;
                immutable post = MonoTime.currTime;
                enum pattern = "%s (%s)";
                writefln(pattern, post-pre, request.url);
                stdout.flush();
            }
        }

        bool halt;

        void onQuitMessageDg(bool quit)
        {
            halt = quit;
        }

        // This avoids the GC allocating a closure, which is fine in this case, but do this anyway
        scope scopeOnHTTPRequestDg = &onHTTPRequestDg;
        scope scopeOnQuitMessageDg = &onQuitMessageDg;

        while (!halt)
        {
            import std.concurrency : receive;
            import std.variant : Variant;

            try
            {
                receive(
                    scopeOnHTTPRequestDg,
                    scopeOnQuitMessageDg,
                    (Variant v)
                    {
                        import std.stdio : stdout, writeln;
                        writeln("Querier received unknown Variant: ", v);
                        stdout.flush();
                    }
                );
            }
            catch (Exception e)
            {
                import std.stdio : stdout, writeln;

                // Probably a requests exception
                writeln("Querier caught exception: ", e.msg);
                version(PrintStacktraces) writeln(e);
                stdout.flush();
            }
        }
    }
}


// issueSyncHTTPRequest
/++
    Issues a synchronous HTTP request.

    Params:
        request = The [HTTPRequest] to issue.

    Returns:
        The response to the request.
 +/
auto issueSyncHTTPRequest(const HTTPRequest request) @system
{
    import kameloso.constants : KamelosoInfo, Timeout;
    import requests.base : Response;
    import requests.request : Request;
    import std.range : only, zip;

    auto issueRequest(Request req)
    {
        import kameloso.tables : HTTPVerb;

        with (HTTPVerb)
        final switch (request.verb)
        {
        case get:
            return req.get(request.url);

        case post:
            return req.post(request.url, request.body, request.contentType);

        case put:
            return req.put(request.url, request.body, request.contentType);

        case patch:
            return req.patch(request.url, request.body, request.contentType);

        case delete_:
            return req.execute("DELETE", request.url);

        case unset:
        case unsupported:
            assert(0, "Unset or unsupported HTTP verb passed to issueSyncHTTPRequest");
        }
    }

    static string[string] headers;

    if (!headers.length)
    {
        headers =
        [
            "Client-ID" : request.clientID,
            "User-Agent" : "kameloso/" ~ cast(string) KamelosoInfo.version_,
            "Authorization" : request.authorisationHeader,
        ];
    }

    auto headerNames = only("Client-ID", "Authorization");
    auto headerStrings = only(&request.clientID, &request.authorisationHeader);
    auto zipped = zip(headerNames, headerStrings);

    foreach (immutable name, stringPtr; zipped)
    {
        if (!stringPtr.length)
        {
            headers.remove(name);
        }
        else if (auto header = name in headers)
        {
            if (*header != *stringPtr) *header = *stringPtr;
        }
        else
        {
            headers[name] = *stringPtr;
        }
    }

    foreach (immutable name, const value; request.customHeaders)
    {
        headers[name] = value;
    }

    scope(exit)
    {
        foreach (immutable name, const _; request.customHeaders)
        {
            headers.remove(name);
        }
    }

    auto req = Request();
    //req.verbosity = 1;
    req.keepAlive = true;
    req.timeout = Timeout.httpGET;
    req.addHeaders(headers);
    req.sslSetVerifyPeer = request.verifyPeer;
    if (request.caBundleFile.length) req.sslSetCaCert(request.caBundleFile);

    HTTPQueryResponse response;
    response.url = request.url;

    try
    {
        auto res = issueRequest(req);  // may not be const
        response.code = res.code;
        response.uri = res.uri;
        response.finalURI = res.finalURI;
        response.body = cast(string) res.responseBody;  // requires mutable

        immutable stats = res.getStats();
        response.elapsed = stats.connectTime + stats.recvTime + stats.sendTime;

        return response;
    }
    catch (Exception e)
    {
        import kameloso.constants : MagicErrorStrings;

        response.exceptionText = (e.msg == MagicErrorStrings.sslContextCreationFailure) ?
            MagicErrorStrings.sslLibraryNotFoundRewritten :
            e.msg;
        return response;
    }
}


// HTTPQueryException
/++
    Exception, to be thrown when a web request, such as an API query, failed.
 +/
final class HTTPQueryException : Exception
{
@safe:
    /++
        The response body that was received.
     +/
    string responseBody;

    /++
        The message of any thrown exception, if the query failed.
     +/
    string error;

    /++
        The HTTP code that was received.
     +/
    uint code;

    /++
        Create a new [HTTPQueryException], attaching a response body, an error
        and an HTTP status code.
     +/
    this(
        const string message,
        const string responseBody,
        const string error,
        const uint code,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        this.responseBody = responseBody;
        this.error = error;
        this.code = code;
        super(message, file, line, nextInChain);
    }

    /++
        Create a new [HTTPQueryException], without attaching anything.
     +/
    this(
        const string message,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }
}


// EmptyResponseException
/++
    Exception, to be thrown when an API query failed, with only an empty
    response received.
 +/
final class EmptyResponseException : Exception
{
@safe:
    /++
        Create a new [EmptyResponseException].
     +/
    this(
        const string message = "No response",
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }
}


// QueryResponseJSONException
/++
    Abstract class for web query JSON exceptions, to deduplicate catching.
 +/
abstract class QueryResponseJSONException : Exception
{
private:
    import std.json : JSONValue;

public:
    /++
        Accessor to a [std.json.JSONValue|JSONValue] that this exception refers to.
     +/
    JSONValue json();

    /++
        Constructor.
     +/
    this(
        const string message,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }
}


// UnexpectedJSONException
/++
    A normal [object.Exception|Exception] but where its type conveys the specific
    context of a [std.json.JSONValue|JSONValue] having unexpected contents.

    It optionally embeds the JSON.
 +/
final class UnexpectedJSONException : QueryResponseJSONException
{
private:
    import std.json : JSONValue;

    /++
        [std.json.JSONValue|JSONValue] in question.
     +/
    JSONValue _json;

public:
    /++
        Accessor to [_json].
     +/
    override JSONValue json()
    {
        return _json;
    }

    /++
        Create a new [UnexpectedJSONException], attaching a [std.json.JSONValue|JSONValue].
     +/
    this(
        const string message,
        const JSONValue _json,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        this._json = _json;
        super(message, file, line, nextInChain);
    }

    /++
        Constructor.
     +/
    this(
        const string message = "Unexpected JSON",
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }
}


// ErrorJSONException
/++
    A normal [object.Exception|Exception] but where its type conveys the specific
    context of a [std.json.JSONValue|JSONValue] having an `"error"` field.

    It optionally embeds the JSON.
 +/
final class ErrorJSONException : QueryResponseJSONException
{
private:
    import std.json : JSONValue;

    /++
        [std.json.JSONValue|JSONValue] in question.
     +/
    JSONValue _json;

public:
    /++
        Accessor to [_json].
     +/
    override JSONValue json()
    {
        return _json;
    }

    /++
        Create a new [ErrorJSONException], attaching a [std.json.JSONValue|JSONValue].
     +/
    this(
        const string message,
        const JSONValue _json,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        this._json = _json;
        super(message, file, line, nextInChain);
    }

    /++
        Constructor.
     +/
    this(
        const string message,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }
}


// EmptyDataJSONException
/++
    Exception, to be thrown when an API query failed, due to having received
    empty JSON data.

    It is a normal [object.Exception|Exception] but with attached metadata.
 +/
final class EmptyDataJSONException : QueryResponseJSONException
{
private:
    import std.json : JSONValue;

    /++
        The response body that was received.
     +/
    JSONValue _json;

public:
    /++
        Accessor to [_json].
     +/
    override JSONValue json()
    {
        return _json;
    }

    /++
        Create a new [EmptyDataJSONException], attaching a response body.
     +/
    this(
        const string message,
        const JSONValue _json,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        this._json = _json;
        super(message, file, line, nextInChain);
    }

    /++
        Create a new [EmptyDataJSONException], without attaching anything.
     +/
    this(
        const string message = "Empty JSON data",
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }
}


// HTTPQueryResponse
/++
    Embodies the notion of a response to a web request.
 +/
struct HTTPQueryResponse
{
private:
    import requests.uri : URI;
    import core.time : Duration;

public:
    /++
        The URL that was queried.
     +/
    string url;

    /++
        The URI as reported in the response.
     +/
    URI uri;

    /++
        The final URI as reported in the response, after redirects.
     +/
    URI finalURI;

    /++
        Response body, may be several lines.
     +/
    string body;

    /++
        How long the query took, from issue to response.
     +/
    Duration elapsed;

    /++
        The HTTP response code received.
     +/
    uint code;

    /++
        The message of any exception thrown while querying.
     +/
    string error;

    /++
        The message text of any exception thrown while querying.
     +/
    string exceptionText;
}
