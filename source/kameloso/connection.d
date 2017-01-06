module kameloso.connection;

import kameloso.constants;

import std.stdio : writeln, writefln;


// Connection
/++
 +  A struct containing functions and state needed to connect and maintain a connection.
 +  This is simply to decrease the amount of globals and make some convenience functions.
 +/
struct Connection
{
private:
    import std.socket;
    import core.thread : Thread;
    import core.time   : seconds;

    Socket socket;
    Address[] ips;

public:
    alias socket this;
    bool connected;

    void reset()
    {
        socket = new TcpSocket;

        with (socket)
        with (SocketOption)
        with (SocketOptionLevel)
        {
            setOption(SOCKET, RCVBUF, BufferSize.socketOptionReceive);
            setOption(SOCKET, SNDBUF, BufferSize.socketOptionSend);
            setOption(SOCKET, RCVTIMEO, Timeout.receive.seconds);
            setOption(SOCKET, SNDTIMEO, Timeout.send.seconds);
        }
    }

    void resolve(string address, ushort port)
    {
        try
        {
            ips = getAddress(address, port);
            writefln("%s resolved into %d ips.", address, ips.length);
        }
        catch (SocketException e)
        {
            // For some reason IPv6 addresses get resolved but we can't connect to them

            if (e.msg == "getaddrinfo error: Name or service not known")
            {
                // assume net down, wait and try again
                writeln(e.msg);
                writefln("Network down? Retrying in %d seconds", Timeout.resolve);
                Thread.sleep(Timeout.resolve.seconds);
                return resolve(address, port);
            }
        }
        catch (Exception e)
        {
            writeln(e);
            assert(0);
        }
    }

    void connect()
    {
        assert((ips.length > 0), "Tried to connect to an unresolved connection");

        foreach (i, ip; ips)
        {
            if (ip.addressFamily == AddressFamily.INET6)
            {
                // Unable to connect socket: Address family not supported by protocol
                writeln("Skipping IPv6 address: ", ip);
                continue;
            }
            try
            {
                writefln("Connecting to %s ...", ip);
                connect(ip);
                connected = true;
                writeln("Connected!");
                break;
            }
            catch (SocketException e)
            {
                writeln("Failed! ", e.msg);
            }
            catch (Exception e)
            {
                writeln(e);
                assert(0);
            }
            finally
            {
                // (i < ips.length-1) is dangerous as length is unsigned!
                if (!connected && (i+1 < ips.length))
                {
                    writefln("Trying next ip in %d seconds.", Timeout.retry);
                    Thread.sleep(Timeout.retry.seconds);
                }
            }
        }

        if (!connected)
        {
            writeln("failed to connect");
        }
    }

    // sendline
    /++
     +  sendline sends a line to the server.
     +
     +  Sadly the IRC server requires lines to end with a newline, so we need to chain
     +  one directly after the line itself. If several threads are allowed to write to the same
     +  socket in parallel, this would be a race condition.
     +
     +  Params:
     +      line = The string to send.
     +/
    pragma(inline, true)
    void sendline(String...)(const String lines)
    {
        // RACE CONDITION *iff* other threads are allowed to write
        foreach (i, line; lines)
        {
            socket.send(line);
        }
        socket.send("\n");

        // ALLOCATING FIX: socket.send(line ~ '\n');
    }

    /// Proxy calls to connect to Socket.connect.
    auto connect(Address to)
    {
        return socket.connect(to);
    }

    /// Ditto but Socket.receive.
    pragma(inline, true)
    auto receive(T)(T[] buffer)
    {
        return socket.receive(buffer);
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
    import std.socket   : Socket, lastSocketError;
    import std.datetime : Clock, SysTime;
    import core.time    : seconds;
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
            writefln("ZERO RECEIVED! assuming dead connection (%s)", lastSocketError);
            return;
        }
        else if (bytesReceived == Socket.ERROR)
        {
            auto elapsed = (Clock.currTime - timeLastReceived);

            if (elapsed > Timeout.keepalive.seconds)
            {
                // Too much time has passed; we can reasonably assume the socket is disconnected
                writeln("NOTHING RECEIVED FOR %s (timeout %s)", elapsed, Timeout.keepalive.seconds);
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
                writeln(lastSocketError);
                return;

            default:
                writeln("lastSocketError from Socket.ERROR:", lastSocketError);
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
                writeln("OVERFLOW! Growing buffer but data was lost");
                const old = buffer.length;
                buffer.length = cast(size_t)(buffer.length * 1.5);
                writefln("old size:%d new:%d", old, buffer.length);
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
