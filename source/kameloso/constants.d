module kameloso.constants;


/// Hardcoded default filenames
enum Files
{
    config = "kameloso.conf",
    quotes = "quotes.json",
}


/// NickServ's lines begin with these
enum NickServLines
{
    challenge = "This nickname is registered.",
    acceptance = "You are now identified",
}


/// Various magic numbers
enum ControlCharacter : ubyte { action = 1, bold = 2, color = 3, termReset = 15 }


/// When a nickname is taken, append this to get a new name.
enum altNickSign = '^';


/// Buffer sizes in bytes
enum BufferSize
{
    socketOptionReceive = 1024,
    socketOptionSend = 1024,
    socketReceive = 1536,
}


/// Various timeouts in seconds
enum Timeout
{
    retry = 5,
    send = 5,
    receive = 5,
    keepalive = 300,
    resolve = 10,
    ping = 200,
    whois = 10,
}


/// These are used in combination with the scopeguard function, to generate scopeguard mixins.
enum : ubyte
{
    entry   = 1 << 0,
	exit    = 1 << 1,
	success = 1 << 2,
	failure = 1 << 3,
}


/// For now, the 8ball answers that the Chatbot plugin uses.
string[20] eightballAnswers =
[
    "It is certain",
    "It is decidedly so",
    "Without a doubt",
    "Yes, definitely",
    "You may rely on it",
    "As I see it, yes",
    "Most likely",
    "Outlook good",
    "Yes",
    "Signs point to yes",
    "Reply hazy try again",
    "Ask again later",
    "Better not tell you now",
    "Cannot predict now",
    "Concentrate and ask again",
    "Don't count on it",
    "My reply is no",
    "My sources say no",
    "Outlook not so good",
    "Very doubtful",
];