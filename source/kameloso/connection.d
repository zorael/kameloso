module kameloso.connection;

import kameloso.common : logger, interruptibleSleep;
import kameloso.constants;

import core.time : seconds;
import std.socket;
import std.stdio;


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
    /// Pointer to the socket of the AddressFamily we want to connect with
    Socket* socket;

    /// IPs already resolved using Connection.resolve.
    Address[] ips;

public:
    /++
     +  Implicitly proxy calls to the current Socket.
     +  This successfully proxies to Socket.receive.
     +/
    alias socket this;

    /// Is the connection known to be active?
    bool connected;

    void reset()
    {
    }

    bool resolve(const string address, const ushort port, ref bool abort)
    {
        import core.thread : Thread;

        foreach (immutable i; 0..5)
        {
            if (abort) return false;

            try
            {
                ips = getAddress(address, port);
                logger.infof("%s resolved into %d ips.", address, ips.length);
                return true;
            }
            catch (const SocketException e)
            {
                switch (e.msg)
                {
                case "getaddrinfo error: Name or service not known":
                case "getaddrinfo error: Temporary failure in name resolution":
                    // Assume net down, wait and try again

                    logger.warning(e.msg);
                    logger.logf("Network down? Retrying in %d seconds (attempt %d)",
                        Timeout.resolve, i+1);
                    interruptibleSleep(Timeout.resolve.seconds, abort);
                    continue;

                default:
                    logger.error(e.msg);
                    logger.log("Could not connect. Verify your server address");
                    return false;
                }
            }
            catch (const Exception e)
            {
                logger.error(e.msg);
                return false;
            }
        }

        logger.warning("Failed to resolve host");
        return false;
    }

    void connect(ref bool abort)
    {
        import core.thread : Thread;

        assert((ips.length > 0), "Tried to connect to an unresolved connection");

        foreach (immutable i, ip; ips)
        {
            try
            {
                logger.logf("Connecting to %s ...", ip);
                socket.connect(ip);
                logger.log("Connected!");
                return;
            }
            finally
            {
                if (i && (i < ips.length))
                {
                }
            }
        }
    }
}
