module kameloso.constants;

/// Meta information about the program.
enum KamelosoInfo
{
    version_ = "0.9.8",
    built = __TIMESTAMP__,
    source = "https://github.com/zorael/kameloso",
}

/// Certain characters that signal specific meaning in an IRC context.
enum IRCControlCharacter
{
    ctcp = 1,
    bold = 2,
    colour = 3,
    italics = 29,
    underlined = 31,
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
    resolve = 10,
    ping = 200,
    whois = 15,
    titleCache = 600,
}

/// Bitflags used in combination with the scopeguard function, to generate scopeguard mixins.
enum : ubyte
{
    entry   = 1 << 0,  /// On entry of function
    exit    = 1 << 1,  /// On exit of function
    success = 1 << 2,  /// On successful exit of function
    failure = 1 << 3,  /// On thrown exception or error in function
}

/// Special terminal control characters
enum TerminalToken
{
    /// Character that preludes a Bash colouring code.
    bashFormat = '\033',

    /// Terminal bell/beep.
    bell = '\007',

    /// Character that resets a terminal that has entered "binary" mode.
    reset = 15,
}
