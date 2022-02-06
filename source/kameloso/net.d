
module kameloso.net;

public:

@safe:




struct Connection
{
private:
    
    import std.socket : Address, Socket, SocketOption;

    
    Socket socket4, socket6;

    
    uint privateSendTimeout;

    
    uint privateReceiveTimeout;

    
    

    
    


    
    
    void setTimeout(const SocketOption option, const uint dur)
    {
        
    }

public:
    
    Socket socket;

    
    bool ssl;

    
    Address[] ips;

    
    alias socket this;

    
    bool connected;

    
    string certFile;

    
    string privateKeyFile;


    
    
    pragma(inline, true)
    uint sendTimeout() const @property pure @nogc nothrow
    {
        return privateSendTimeout;
    }


    
    
    pragma(inline, true)
    void sendTimeout() @property
    {
        
    }

    
    
    pragma(inline, true)
    uint receiveTimeout() const @property pure @nogc nothrow
    {
        return privateReceiveTimeout;
    }

    
    
    void receiveTimeout(const uint dur) @property
    {
        
    }


    
    
    void reset()
    {
        
    }


    
    
    void resetSSL() @system
    in (ssl, "Tried to reset SSL on a non-SSL `Connection`")
    {
        
        
    }


    
    
    string getSSLErrorMessage(const int code) @system
    in (ssl, "Tried to get SSL error message on a non-SSL `Connection`")
    {
        

        return string.init;
    }


    
    
    void setDefaultOptions()
    {
        
    }


    
    
    void setupSSL() @system
    in (ssl, "Tried to set up SSL context on a non-SSL `Connection`")
    {
        
    }


    
    
    void teardownSSL()
    in (ssl, "Tried to teardown SSL on a non-SSL `Connection`")
    {
        
    }


    
    
    void sendline(Data...)(const Data data, const uint maxLineLength = 512) @system
    in (connected, "Tried to send a line on an unconnected `Connection`")
    {
        
    }
}




struct ListenAttempt
{
    
    enum State
    {
        prelisten,  
        isEmpty,    
        hasString,  
        timeout,    
        warning,    
        error,      
    }

    
    State state;

    
    string line;

    
    string error;

    
    int errno;

    
    long bytesReceived;
}




struct ConnectionAttempt
{
    import std.socket : Address;

    
    enum State
    {
        preconnect,              
        connected,               
        delayThenReconnect,      
        delayThenNextIP,         
        
        ipv6Failure,             
        sslFailure,              
        invalidConnectionError,  
        error,                   
    }

    
    State state;

    
    Address ip;

    
    string error;

    
    int errno;

    
    uint retryNum;
}




void connectFiber(ref Connection conn,
    const uint connectionRetries,
    ref bool abort) @system
in (!conn.connected, "Tried to set up a connecting fiber on an already live connection")
in ((conn.ips.length > 0), "Tried to connect to an unresolved connection")
{
    
}




