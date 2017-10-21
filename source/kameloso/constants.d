module kameloso.constants;

/// Meta information about the program.
enum KamelosoInfo
{
    version_ = "0.5.0",
    built = __TIMESTAMP__,
    source = "https://github.com/zorael/kameloso",
}

/// Certain characters that signal specific meaning in an IRC context.
enum IRCControlCharacter
{
    action = 1,
    bold = 2,
    colour = 3,
    italics = 29,
    underlined = 31,
    ctcp = 1,
}

/// A character that resets a terminal that has entered "binary" mode.
enum TerminalResetToken = 15;

/// When a nickname is taken, append this to get a new name.
enum altNickSign = '^';

/// Buffer sizes in bytes.
enum BufferSize
{
    socketOptionReceive = 1024,
    socketOptionSend = 1024,
    socketReceive = 1024,
    titleLookup = 8192,
}

/// Various timeouts in seconds.
enum Timeout
{
    retry = 5,
    send = 5,
    receive = 1,
    keepalive = 300,
    resolve = 10,
    ping = 200,
    whois = 3,
    titleCache = 600,
}

/// Bitflags used in combination with the scopeguard function, to generate scopeguard mixins.
enum : ubyte
{
    entry   = 1 << 0,
    exit    = 1 << 1,
    success = 1 << 2,
    failure = 1 << 3,
}

/// The token that preludes a Bash colouring code.
enum BashColourToken = '\033';

/// Effect codes that work like Bash colouring does, except for effects
enum BashEffectToken
{
    bold = 1,
    dim  = 2,
    italics = 3,
    underlined = 4,
    blink   = 5,
    reverse = 7,
    hidden  = 8,

}

/// Format codes for Bash colouring
enum Format
{
    bright      = "1",
    dim         = "2",
    underlined  = "4",
    blink       = "5",
    invert      = "7",
    hidden      = "8",
}

/// Foreground colour codes for Bash colouring
enum Foreground
{
    default_     = "39",
    black        = "30",
    red          = "31",
    green        = "32",
    yellow       = "33",
    blue         = "34",
    magenta      = "35",
    cyan         = "36",
    lightgrey    = "37",
    darkgrey     = "90",
    lightred     = "91",
    lightgreen   = "92",
    lightyellow  = "93",
    lightblue    = "94",
    lightmagenta = "95",
    lightcyan    = "96",
    white        = "97",
}

/// Background colour codes for Bash colouring
enum Background
{
    default_     = "49",
    black        = "40",
    red          = "41",
    green        = "42",
    yellow       = "43",
    blue         = "44",
    magenta      = "45",
    cyan         = "46",
    lightgrey    = "47",
    darkgrey     = "100",
    lightred     = "101",
    lightgreen   = "102",
    lightyellow  = "103",
    lightblue    = "104",
    lightmagenta = "105",
    lightcyan    = "106",
    white        = "107",
}

/// Bash colour/effect reset codes
enum Reset
{
    all         = "0",
    bright      = "21",
    dim         = "22",
    underlined  = "24",
    blink       = "25",
    invert      = "27",
    hidden      = "28",
}
