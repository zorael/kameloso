module kameloso.connection;

import kameloso.common : writefln, writeln;
import kameloso.constants;

import std.socket;
import core.time : seconds;


// Connection
/++
 +  A struct containing functions and state needed to connect and maintain a connection.
 +  This is simply to decrease the amount of globals and make some convenience functions.
 +/
struct Connection
{
private:
    /// Real IPv4 and IPv6 sockets to connect through.
    Socket socket4, socket6;

    /// Pointer to the socket of the AddressFamily we want to connect with
    Socket* socket;

    /// IPs already resolved using Connection.resolve.
    Address[] ips;

public:
    /// Implicitly proxy calls to the current Socket. This successfully proxies to Socket.receive.
    alias socket this;

    /// Set to true if the connection is known to be active
    bool connected;

    // reset
    /++
     +  (Re-)initialises the sockets and sets the IPv4 one as the active one.
     +/
    void reset()
    {
        socket4 = new TcpSocket;
        socket6 = new Socket(AddressFamily.INET6, SocketType.STREAM);
        socket = &socket4;

        setOptions(socket4);
        setOptions(socket6);
    }

    // setOptions
    /++
     +  Set up sockets with the SocketOptions needed. These include timeouts and buffer sizes.
     +
     +  Params:
     +      socketToSetup = the (reference to the) socket to modify.
     +/
    void setOptions(Socket socketToSetup)
    {
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
     +  Given an address and a port, build an array of Addresses into ips.
     +
     +  Params:
     +      address = The string address to look up.
     +      port = The remote port build into the Address.
     +/
    void resolve(const string address, const ushort port)
    {
        import core.thread : Thread;

        try
        {
            ips = getAddress(address, port);
            writefln(Foreground.white, "%s resolved into %d ips.", address, ips.length);
        }
        catch (SocketException e)
        {
            switch (e.msg)
            {
            case "getaddrinfo error: Name or service not known":
                // Assume net down, wait and try again
                writeln(Foreground.lightred, e.msg);
                writefln(Foreground.lightred, "Network down? Retrying in %d seconds",
                    Timeout.resolve);
                Thread.sleep(Timeout.resolve.seconds);
                return resolve(address, port);

            default:
                writeln(Foreground.lightred, e.msg);
                assert(false);
            }
        }
        catch (Exception e)
        {
            writeln(Foreground.lightred, e.msg);
            assert(0);
        }
    }

    // connect
    /++
     +  Walks through the list of Addresses in ips and attempts to connect to each until
     +  one succeeds. Success is determined by whether or not an exception was thrown during
     +  the attempt, and is kept track of with the connected boolean.
     +/
    void connect()
    {
        import core.thread : Thread;

        assert((ips.length > 0), "Tried to connect to an unresolved connection");

        foreach (i, ip; ips)
        {
            // Decide which kind of socket to use based on the AddressFamily of the resolved ip
            socket = (ip.addressFamily == AddressFamily.INET6) ? &socket6 : &socket4;

            try
            {
                writefln(Foreground.white, "Connecting to %s ...", ip);
                socket.connect(ip);

                // If we're here no exception was thrown, so we're connected
                connected = true;
                writeln(Foreground.white, "Connected!");
                //break;
                return;
            }
            catch (SocketException e)
            {
                writeln(Foreground.lightred, "Failed! ", e.msg);
            }
            catch (Exception e)
            {
                writeln(Foreground.lightred, e.msg);
                assert(0);
            }
            finally
            {
                // Take care! length is unsigned

                if (i && (i < ips.length))
                {
                    writefln(Foreground.lightcyan, "Trying next ip in %d seconds.", Timeout.retry);
                    Thread.sleep(Timeout.retry.seconds);
                }
            }
        }

        if (!connected)
        {
            writeln(Foreground.lightred, "Failed to connect!");
        }
    }

    // sendline
    /++
     +  Sends a line to the server.
     +
     +  Sadly the IRC server requires lines to end with a newline, so we need to chain
     +  one directly after the line itself. If several threads are allowed to write to the same
     +  socket in parallel, this would be a race condition.
     +
     +  Params:
     +      line = The string to send.
     +/
    pragma(inline, true)
    void sendline(Strings...)(const Strings lines)
    {
        // TODO: Add throttling!

        foreach (const line; lines)
        {
            socket.send(line);
        }

        socket.send("\n");
    }
}


// listenFiber
/++
 +  A Generator fiber. It maintains its own buffer into which it receives from the server,
 +  though not neccessarily full lines. It thus keeps filling the buffer until it finds a
 +  newline character, yields it back to the caller of the fiber, checks for more lines to
 +  yield, and if none yields string.init to wait for its turn to read from the sever again.
 +  The buffer logic is complex.
 +
 +  Params:
 +      conn = A Connection struct via whose Socket it reads from the server.
 +
 +  Yields:
 +      full IRC event strings.
 +/
void listenFiber(Connection conn)
{
    import std.datetime : Clock, SysTime;
    import std.concurrency : yield;
    import std.algorithm.searching : countUntil;

    auto buffer = new ubyte[](BufferSize.socketReceive);
    SysTime timeLastReceived;
    size_t start;

    while (true)
    {
        const ptrdiff_t bytesReceived = conn.receive(buffer[start..$]);

        if (!bytesReceived)
        {
            writefln(Foreground.lightred, "ZERO RECEIVED! assuming dead connection (%s)",
                lastSocketError);
            return;
        }
        else if (bytesReceived == Socket.ERROR)
        {
            auto elapsed = (Clock.currTime - timeLastReceived);

            if (elapsed > Timeout.keepalive.seconds)
            {
                // Too much time has passed; we can reasonably assume the socket is disconnected
                writefln(Foreground.lightred, "NOTHING RECEIVED FOR %s (timeout %s)",
                    elapsed, Timeout.keepalive.seconds);
                return;
            }

            switch (lastSocketError)
            {
            case "Resource temporarily unavailable":
                // Nothing received
            case "Interrupted system call":
                // Unlucky callgrind_control -d timing
            case "A connection attempt failed because the connected party did not properly respond after a period of time, or established connection failed because connected host has failed to respond.":
                // Timed out read in Windows
                yield(string.init);
                continue;

            // Others that may be benign?
            case "An established connection was aborted by the software in your host machine.":
            case "An existing connection was forcibly closed by the remote host.":
            case "Connection reset by peer":
                writeln(Foreground.lightred, "FATAL SOCKET ERROR");
                writeln(Foreground.lightred, lastSocketError);
                return;

            default:
                writeln(Foreground.lightred, "lastSocketError from Socket.ERROR:", lastSocketError);
                yield(string.init);
            }

            continue;
        }

        timeLastReceived = Clock.currTime;

        const ptrdiff_t end = (start + bytesReceived);
        auto newline = buffer[0..end].countUntil('\n');
        size_t pos;

        while (newline != -1)
        {
            yield((cast(char[])buffer[pos..pos+newline-1]).idup);
            pos += (newline + 1); // eat remaining newline
            newline = buffer[pos..end].countUntil('\n');
        }

        yield(string.init);

        if (pos >= end)
        {
            start = 0;
            continue;
        }

        start = (end-pos);

        // writefln("REMNANT:|%s|", cast(string)buffer[pos..end]);

        if (start >= pos)
        {
            if (start == end)
            {
                writeln(Foreground.lightcyan, "OVERFLOW! Growing buffer but data was lost");
                const old = buffer.length;
                buffer.length = cast(size_t)(buffer.length * 1.5);
                writefln(Foreground.lightcyan, "old size:%d new:%d", old, buffer.length);
            }

            // writeln("OVERLAP");
            // writefln("start:%d pos:%d end:%d", start, pos, end);
            auto mirror = new typeof(buffer)(start);
            mirror[0..start] = buffer[pos..end];
            buffer[0..start] = mirror[0..start];
        }
        else
        {
            buffer[0..start] = buffer[pos..end];
        }
    }
}
