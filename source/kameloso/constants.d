/++
 +  A collection of constants used throughout the program.
 +/
module kameloso.constants;

/// Meta-information about the program.
enum KamelosoInfo
{
    version_ = "1.0.0-rc.1",
    built = __TIMESTAMP__,
    source = "https://github.com/zorael/kameloso",
}

/// When a nickname is taken, append this to get a new name.
enum altNickSign = '^';

/// Buffer sizes in bytes.
enum BufferSize
{
    socketOptionReceive = 2048,
    socketOptionSend = 1024,
    socketReceive = 2048,
    titleLookup = 8192,
}

/// Various timeouts in seconds.
enum Timeout
{
    retry = 10,
    send = 5,
    receive = 1,
    keepalive = 300,
    connectionLost = 600,
    resolve = 10,
    ping = 200,
    whois = 15,
    titleCache = 600,
}
