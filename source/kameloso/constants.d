module kameloso.constants;


/// Hardcoded default filenames
enum Files
{
    config = "kameloso.conf",
    quotes = "quotes.json",
    notes  = "notes.json",
}


/// NickServ's lines begin with these
enum NickServLines
{
    challenge = "This nickname is registered. Please choose a different nickname, or identify via /msg NickServ identify <password>.",
    acceptance = "You are now identified for",
}


// ControlCharacter
/++
 +  Various magic numbers.
 +
 +  action is the first character in a /me message.
 +  bold makes the text bold. More info needed.
 +  colour starts colour codes.
 +  termReset outputs a byte that restores the local terminal if it has entered "binary" mode.
 +/
enum ControlCharacter : ubyte { action = 1, bold = 2, colour = 3, termReset = 15 }


/// When a nickname is taken, append this to get a new name.
enum altNickSign = '^';


/// Buffer sizes in bytes
enum BufferSize
{
    socketOptionReceive = 1024,
    socketOptionSend = 1024,
    socketReceive = 1536,
    titleLookup = 8192,
}


/// Various timeouts in seconds
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


/// These are used in combination with the scopeguard function, to generate scopeguard mixins.
enum : ubyte
{
    entry   = 1 << 0,
	exit    = 1 << 1,
	success = 1 << 2,
	failure = 1 << 3,
}
