
module kameloso.kameloso;

import std.typecons : Flag, No, Yes;

public:




struct Kameloso
{
private:
    import kameloso.common : OutgoingLine, logger;
    import kameloso.constants : BufferSize;
    import kameloso.net : Connection;
    import kameloso.plugins.common.core : IRCPlugin;
    import dialect.defs : IRCClient, IRCServer;
    import dialect.parsing : IRCParser;
    import lu.container : Buffer;
    import std.datetime.systime : SysTime;


    
    
    static struct Throttle
    {
        
        SysTime t0;

        
        double m = 0.0;

        
        enum increment = 1.0;

        
        @disable this(this);
    }

public:
    
    Connection conn;

    
    IRCPlugin[] plugins;

    
    CoreSettings settings;

    
    ConnectionSettings connSettings;

    
    long[string] previousWhoisTimestamps;

    
    IRCParser parser;

    
    IRCBot bot;

    
    Throttle throttle;

    
    bool* abort;

    
    bool wantLiveSummary;

    
    Buffer!(OutgoingLine, No.dynamic, BufferSize.outbuffer) outbuffer;

    
    Buffer!(OutgoingLine, No.dynamic, BufferSize.outbuffer) backgroundBuffer;

    
    Buffer!(OutgoingLine, No.dynamic, BufferSize.priorityBuffer) priorityBuffer;

    
    Buffer!(OutgoingLine, No.dynamic, BufferSize.priorityBuffer) immediateBuffer;

    version(TwitchSupport)
    {
        
        Buffer!(OutgoingLine, No.dynamic, BufferSize.outbuffer*2) fastbuffer;
    }

    
    @disable this(this);


    
    
    double throttleline(Buffer)
        (ref Buffer buffer,
        const Flag!"dryRun" dryRun = No.dryRun,
        const Flag!"sendFaster" sendFaster = No.sendFaster,
        const Flag!"immediate" immediate = No.immediate) @system
    {
        

        return 0.0;
    }


    
    
    void initPlugins(const string[] customSettings,
        out string[][string] missingEntries,
        out string[][string] invalidEntries) @system
    {
        
    }


    
    
    void initPlugins(const string[] customSettings) @system
    {
        
    }


    
    
    void initPluginResources() @system
    {
        
    }


    
    
    void teardownPlugins() @system
    {
        
    }


    
    
    void startPlugins() @system
    {
        
    }


    
    
    void checkPluginForUpdates(IRCPlugin plugin)
    {
        
    }


    private import lu.traits : isStruct;
    private import std.meta : allSatisfy;

    
    
    
    void propagate(Thing)(Thing thing) pure nothrow @nogc
    if (allSatisfy!(isStruct, Thing))
    {
        
    }


    
    
    static struct ConnectionHistoryEntry
    {
        
        long startTime;

        
        long stopTime;

        
        long numEvents;

        
        long bytesReceived;
    }

    
    ConnectionHistoryEntry[] connectionHistory;

    
    bool wantReceiveTimeoutShortened;
}




struct CoreSettings
{
private:
    import lu.uda : CannotContainComments, Quoted, Unserialisable;

public:
    version(Colours)
    {
        bool monochrome = false;  
    }
    else
    {
        bool monochrome = true;  
    }

    
    bool brightTerminal = false;

    
    bool preferHostmasks = false;

    
    bool hideOutgoing = false;

    
    bool colouredOutgoing = true;

    
    bool saveOnExit = false;

    
    bool exitSummary = false;

    
    bool eagerLookups = false;

    
    @Quoted string prefix = "!";

    @Unserialisable
    {
        string configFile;  
        string resourceDirectory;  
        string configDirectory;  
        bool force;  
        bool flush;  
        bool trace = false;  
        bool numericAddresses;  
    }
}




struct ConnectionSettings
{
private:
    import kameloso.constants : ConnectionDefaultFloats, Timeout;
    import lu.uda : CannotContainComments, Hidden;

public:
    
    bool ipv6 = true;

    @CannotContainComments
    @Hidden
    {
        
        string privateKeyFile;

        
        string certFile;

        
        string caBundleFile;
    }

    
    bool ssl = false;

    @Hidden
    {
        
        uint receiveTimeout = Timeout.receiveMsecs;

        
        double messageRate = ConnectionDefaultFloats.messageRate;

        
        double messageBurst = ConnectionDefaultFloats.messageBurst;
    }
}




struct IRCBot
{
private:
    import lu.uda : CannotContainComments, Hidden, Separator, Unserialisable;

public:
    
    string account;

    @Hidden
    @CannotContainComments
    {
        
        string password;

        
        string pass;

        
        string quitReason;

        
        string partReason;
    }

    @Separator(",")
    @Separator(" ")
    {
        
        string[] admins;

        
        @CannotContainComments
        string[] homeChannels;

        
        @CannotContainComments
        string[] guestChannels;
    }

    
    @Unserialisable bool hasGuestNickname;
}
