/++
 +  A collection of constants used throughout the program.
 +/
module kameloso.constants;

/// Meta-information about the program.
enum KamelosoInfo
{
    version_ = "1.0.0-rc.2",
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
    whoisRetry = 15,
    titleCache = 600,
}

version(Colours)
{
    import kameloso.bash : BashForeground;

    alias BF = BashForeground;

    /// Default colours for a dark terminal background.
    enum DefaultDark : BashForeground
    {
        timestamp = BF.white,
        type    = BF.lightblue,
        error   = BF.lightred,
        sender  = BF.lightgreen,
        special = BF.lightyellow,
        target  = BF.cyan,
        channel = BF.yellow,
        content = BF.default_,
        aux     = BF.white,
        count   = BF.green,
        num     = BF.darkgrey,
        badge   = BF.white,
        emote   = BF.cyan,
        highlight = BF.white,
        query   = BF.lightgreen,
    }

    /// Default colours for a bright terminal background.
    enum DefaultBright : BashForeground
    {
        timestamp = BF.black,
        type    = BF.blue,
        error   = BF.red,
        sender  = BF.green,
        special = BF.yellow,
        target  = BF.cyan,
        channel = BF.yellow,
        content = BF.default_,
        aux     = BF.black,
        count   = BF.lightgreen,
        num     = BF.lightgrey,
        badge   = BF.black,
        emote   = BF.lightcyan,
        highlight = BF.black,
        query   = BF.green,
    }
}
