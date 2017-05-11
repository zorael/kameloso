module kameloso.plugins.chatbot;

import kameloso.common;
import kameloso.constants;
import kameloso.irc;
import kameloso.plugins.common;
import kameloso.stringutils;

import std.concurrency : send;
import std.json  : JSONValue;
import std.stdio : writefln, writeln;

private:

/// All plugin state variables gathered in a struct
IrcPluginState state;

/// The in-memory JSON storage of all user quotes. It is in the JSON form of string[][string],
/// where the first key is the nickname.
JSONValue quotes;


// getQuote
/++
 +  Fetches a quote for the specified nickname from the in-memory JSON storage.
 +
 +  Params:
 +      nickname = nickname of the user to fetch quotes for.
 +
 +  Returns:
 +      a random quote string. If no quote is available it returns an empty string instead.
 +/
string getQuote(const string nickname)
{
    try
    {
        if (const arr = nickname in quotes)
        {
            import std.random : uniform;

            return arr.array[uniform(0, (*arr).array.length)].str;
        }
        else
        {
            // No quotes available for nickname
            return string.init;
        }
    }
    catch (Exception e)
    {
        writeln("Exception when fetching quote: ", e);
        return string.init;
    }
}


// addQuote
/++
 +  Adds a quote to the in-memory JSON storage.
 +
 +  It does not save it to disk; this has to be done separately at the calling site.
 +
 +  Params:
 +      nickname = nickname of the quoted user.
 +      line = the quote itself.
 +/
void addQuote(const string nickname, const string line)
{
    try
    {
        if (nickname in quotes)
        {
            quotes[nickname].array ~= JSONValue(line);
        }
        else
        {
            // No quotes for nickname
            quotes.object[nickname] = JSONValue([ line ]);
        }
    }
    catch (Exception e)
    {
        // No quotes at all
        writeln("Exception when adding new quote: ", e);
        quotes = JSONValue("{}");
        // return nickname.addQuote(nickname); // ???
        return nickname.addQuote(line);
    }
}


// saveQuotes
/++
 +  Saves the JSON quote list to disk.
 +
 +  This should be done whenever a new quote is added to the database.
 +
 +  Params:
 +      filename = filename of the JSON storage, usually Files.quotes.
 +/
void saveQuotes(const string filename)
{
    import std.stdio : File;
    import std.file  : exists, isFile, remove;

    if (filename.exists && filename.isFile)
    {
        remove(filename); // Wise?
    }

    auto f = File(filename, "a");

    f.write(quotes.toPrettyString);
    f.writeln();
}


// loadQuotes
/++
 +  Loads JSON quote list from disk.
 +
 +  This only needs to be done at plugin (re-)initialisation.
 +
 +  Params:
 +      filename = filename of the JSON storage.
 +/
JSONValue loadQuotes(const string filename)
{
    import std.file   : exists, isFile, readText;
    import std.json   : parseJSON;
    import std.string : chomp;

    if (!filename.exists)
    {
        writeln(filename, " does not exist");
        return JSONValue("{}");
    }
    else if (!filename.isFile)
    {
        writefln(filename, " is not a file");
        return JSONValue("{}");
    }

    immutable wholeFile = filename.readText.chomp;

    return parseJSON(wholeFile);
}


// onCommandSay
/++
 +  Repeats text to the channel the event was sent to.
 +
 +  If it was sent in a query, respond in a private message in kind.
 +
 +  Params:
 +      event = the triggering IrcEvent.
 +/
@Label("say")
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.friend)
@Prefix(NickPrefixPolicy.required, "say")
@Prefix(NickPrefixPolicy.required, "säg")
void onCommandSay(const IrcEvent event)
{
    import std.format : format;

    if (!event.content.length)
    {
        writeln("No text to send...");
        return;
    }

    immutable target = (event.channel.length) ? event.channel : event.sender;

    state.mainThread.send(ThreadMessage.Sendline(),
        "PRIVMSG %s :%s".format(target, event.content));
}


// onCommand8ball
/++
 +  Implements 8ball.
 +
 +  Randomises a response from the table kameloso.constants.eightballAnswers and sends
 +  it back to the channel in which the triggering event happened, or in a query if it
 +  was a private message.
 +
 +  Params:
 +      event = the triggering IrcEvent.
 +/
@Label("8ball")
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.friend)
@Prefix(NickPrefixPolicy.required, "8ball")
void onCommand8ball(const IrcEvent event)
{
    import std.format : format;
    import std.random : uniform;

    immutable reply = eightballAnswers[uniform(0, eightballAnswers.length)];
    immutable target = (event.channel.length) ? event.channel : event.sender;

    state.mainThread.send(ThreadMessage.Sendline(),
        "PRIVMSG %s :%s".format(target, reply));
}


// onCommandQuote
/++
 +  Fetches and repeats a random quote of a supplied nickname.
 +
 +  The quote is read from in-memory JSON storage, and it is sent to the channel the triggering
 +  event occured in.
 +
 +  Params:
 +      event = the triggering IrcEvent.
 +/
@Label("quote")
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.friend)
@Prefix(NickPrefixPolicy.required, "quote")
void onCommandQuote(const IrcEvent event)
{
    import std.string : strip, indexOf;
    import std.format : format;

    immutable signedNickname = event.content.strip;

    if (!signedNickname.length)
    {
        writeln("No one to quote....");
        return;
    }
    else if (signedNickname.indexOf(" ") != -1)
    {
        writeln("Contains spaces, not a single nick...");
        return;
    }

    // stripModeSign to allow for quotes from @nickname and +dudebro
    immutable nickname = signedNickname.stripModeSign;
    immutable quote = nickname.getQuote();
    immutable target = (event.channel.length) ? event.channel : event.sender;

    if (quote.length)
    {
        state.mainThread.send(ThreadMessage.Sendline(),
            "PRIVMSG %s :%s | %s".format(target, nickname, quote));
    }
    else
    {
        state.mainThread.send(ThreadMessage.Sendline(),
            "PRIVMSG %s :No quote on record for %s".format(target, nickname));
    }
}


// onCommandAddQuote
/++
 +  Creates a new quote.
 +
 +  It is added to the in-memory JSON storage which then gets immediately written to disk.
 +
 +  Params:
 +      event = The triggering IrcEvent.
 +/
@Label("addquote")
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.friend)
@Prefix(NickPrefixPolicy.required, "addquote")
void onCommanAdddQuote(const IrcEvent event)
{
    import std.format : format;

    string slice = event.content;  // need mutable
    immutable nickname = slice.nom!(Decode.yes)(' ').stripModeSign;

    if (!nickname.length || !slice.length) return;

    nickname.addQuote(slice);
    Files.quotes.saveQuotes();

    immutable target = (event.channel.length) ? event.channel : event.sender;

    state.mainThread.send(ThreadMessage.Sendline(),
        "PRIVMSG %s :Quote for %s saved (%d on record)"
        .format(target, nickname, quotes[nickname].array.length));
}


// onCommandPrintQuotes
/++
 +  Prints the in-memory quotes JSON storage to the local terminal.
 +
 +  This is for debugging purposes.
 +/
@Label("printquotes")
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPrefixPolicy.required, "printquotes")
void onCommandPrintQuotes()
{
    writeln(quotes.toPrettyString);
}


// onCommandReloadQuotes
/++
 +  Reloads the JSON quotes from disk.
 +
 +  This is both for debugging purposes and to simply allow for live manual editing of quotes.
 +/
@Label("reloadquotes")
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPrefixPolicy.required, "reloadquotes")
void onCommandReloadQuotes()
{
    writeln("Reloading quotes");
    quotes = loadQuotes(Files.quotes);
}


// initialise
/++
 +  Initialises the Chatbot plugin. Loads the quotes from disk.
 +/
void initialise()
{
    writeln("Initialising quotes ...");
    quotes = loadQuotes(Files.quotes);
}


mixin BasicEventHandlers;
mixin OnEventImpl!__MODULE__;

public:


// Chatbot
/++
 +  Chatbot plugin to provide common chat functionality. Administrative actions have been
 +  broken out into a plugin of its own.
 +/
final class Chatbot : IrcPlugin
{
    mixin IrcPluginBasics;
}
