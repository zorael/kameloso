
module kameloso.constants;

private:

import kameloso.semver : KamelosoSemVer, KamelosoSemVerPrerelease;
import std.format : format;


version(DigitalMars)
{
    
    enum compiler = "dmd";
}
else version(LDC)
{
    
    enum compiler = "ldc";
}
else version(GNU)
{
    
    enum compiler = "gdc";
}
else
{
    
    enum compiler = "<unknown>";
}




enum compilerVersion = format("%d.%03d", (__VERSION__ / 1000), (__VERSION__ % 1000));


public:




enum KamelosoInfo
{
    version_ = "%d.%d.%d%s%s"
        .format(
            KamelosoSemVer.majorVersion,
            KamelosoSemVer.minorVersion,
            KamelosoSemVer.patchVersion,
            KamelosoSemVerPrerelease.length ? "-" : string.init,
            KamelosoSemVerPrerelease),  
    built = __TIMESTAMP__, 
    compiler = .compiler,  
    compilerVersion = .compilerVersion,  
    source = "https://github.com/zorael/kameloso",  
}




enum KamelosoDefaults
{
    
    user = "kameloso",

    
    serverAddress = "irc.libera.chat",

    
    realName = "kameloso IRC bot v$version",

    
    quitReason = "kameloso IRC bot v$version @ $source",

    
    partReason = quitReason,

    
    altNickSeparator = "|",
}




enum KamelosoDefaultIntegers
{
    
    port = 6667,
}




enum KamelosoFilenames
{
    
    configuration = "kameloso.conf",

    
    users = "users.json",

    
    hostmasks = "hostmasks.json",
}




enum ConnectionDefaultIntegers
{
    
    retries = 4,
}




enum ConnectionDefaultFloats : double
{
    
    delayIncrementMultiplier = 1.5,

    
    receiveShorteningMultiplier = 0.25,

    
    messageRate = 1.2,

    
    messageBurst = 3.0,

    
    messageRateTwitchFast = 3.0,

    
    messageBurstTwitchFast = 10.0,

    
    messageRateTwitchSlow = 1.0,

    
    messageBurstTwitchSlow = 1.0,
}




enum BufferSize
{
    
    socketOptionReceive = 2048,

    
    socketOptionSend = 1024,

    
    socketReceive = 2048,

    
    outbuffer = 512,

    
    priorityBuffer = 64,

    
    printObjectBufferPerObject = 1024,

    
    vbufStdout = 16_384,

    
    fiberStack = 32_768,
}




enum Timeout
{
    
    sendMsecs = 15_000,

    
    receiveMsecs = 1000,

    
    maxShortenDurationMsecs = 2000,

    
    connectionDelayCap = 600,

    
    connectionRetry = 10,

    
    whoisRetry = 30,

    
    readErrorGracePeriodMsecs = 100,

    
    connectionLost = 600,

    
    httpGET = 10,
}




struct DefaultColours
{
private:
    import kameloso.terminal : TerminalForeground;
    import std.experimental.logger : LogLevel;

    alias TF = TerminalForeground;

public:
    
    enum TimestampColour : TerminalForeground
    {
        
        dark = TF.default_,

        
        bright = TF.default_,
    }

    
    static immutable TerminalForeground[256] logcoloursDark  =
    [
        LogLevel.all      : TF.white,        
        LogLevel.trace    : TF.default_,     
        LogLevel.info     : TF.lightgreen,   
        LogLevel.warning  : TF.lightred,     
        LogLevel.error    : TF.red,          
        LogLevel.critical : TF.red,          
        LogLevel.fatal    : TF.red,          
        LogLevel.off      : TF.default_,     
    ];

    
    static immutable TerminalForeground[256] logcoloursBright  =
    [
        LogLevel.all      : TF.black,        
        LogLevel.trace    : TF.default_,     
        LogLevel.info     : TF.green,        
        LogLevel.warning  : TF.red,          
        LogLevel.error    : TF.red,          
        LogLevel.critical : TF.red,          
        LogLevel.fatal    : TF.red,          
        LogLevel.off      : TF.default_,     
    ];
}
