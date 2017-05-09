module kameloso.plugins.chatbot;

import kameloso.plugins.common;
import kameloso.constants;
import kameloso.common;
import kameloso.stringutils;
import kameloso.irc;

import std.stdio  : writeln, writefln;
import std.json   : JSONValue, parseJSON, JSONException;
import std.format : format;
import std.string : indexOf, strip;
import std.concurrency;

private:

IrcPluginState state;
JSONValue quotes;


// getQuote
/++
 +  Fetches a quote for the specified nickname from the JSON list. If none is available it
 +  returns an empty string instead.
 +
 +  Params:
 +      quotes = A JSON list of quotes, in the form of string[][string] where the first key
 +               is the nickname.
 +      nickname = string nickname of the user to fetch quotes for.
 +/
string getQuote(const string nickname)
{
    try
    {
        if (auto arr = nickname in quotes)
        {
            import std.random : uniform;

            return arr.array[uniform(0,(*arr).array.length)].str;
        }
        else
        {
            // No quotes available for nickname
            return string.init;
        }
    }
    catch (JSONException e)
    {
        return string.init;
    }
}


// addQuote
/++
 +  Adds a quote to the JSON storage. It does not save it to disk; this has to be
 +  done at the calling site.
 +
 +  Params:
 +      ref quotes = The JSON list of all the quotes, in string[][string] form.
 +      nickname = The string nickname of the quoted user.
 +      line = The quote itself.
 +/
void addQuote(const string nickname, const string line)
{
    import std.format : format;

    assert((nickname.length && line.length),
        "%s was passed an empty nickname(%s) or line(%s)"
        .format(__FUNCTION__, nickname, line));

    try
    {
        if (auto arr = nickname in quotes)
        {
            quotes[nickname].array ~= JSONValue(line);
        }
        else
        {
            // No quotes for nickname
            quotes.object[nickname] = JSONValue([ line ]);
        }
    }
    catch (JSONException e)
    {
        // No quotes at all
        writeln(e);
        quotes = JSONValue("{}");
        return nickname.addQuote(nickname);
    }
}


// saveQuotes
/++
 +  Saves JSON quote list to disk, to the supplied filename. This should be done whenever a new
 +  quote is added to the database.
 +
 +  Params:
 +      filename = The string filename of the JSON storage, usually Files.quotes.
 +      quotes = The quotes in JSON form. Its .toPrettyString is what gets written.
 +/
void saveQuotes(const string filename, const JSONValue quotes)
{
    import std.stdio : File;
    import std.file  : exists, isFile, remove;

    if (filename.exists && filename.isFile)
    {
        remove(filename); // Wise?
    }

    auto f = File(filename, "a");
    scope (exit) f.close();

    f.write(quotes.toPrettyString);
    f.writeln();
}


// loadQuotes
/// Ditto but loads instead of saves
JSONValue loadQuotes(const string filename)
{
    import std.stdio  : writefln;
    import std.file   : exists, isFile, readText;
    import std.string : chomp;

    if (!filename.exists)
    {
        writefln("%s does not exist", filename);
        return JSONValue("{}");
    }
    else if (!filename.isFile)
    {
        writefln("%s is not a file", filename);
        return JSONValue("{}");
    }

    auto wholeFile = filename.readText.chomp;
    return parseJSON(wholeFile);
}

@(Label("say"))
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.friend)
@(Prefix(NickPrefixPolicy.required, "say"))
@(Prefix(NickPrefixPolicy.required, "säg"))
void onCommandSay(const IrcEvent event)
{
    if (!event.content.length)
    {
        writeln("No text to send...");
        return;
    }

    const target = (event.channel.length) ? event.channel : event.sender;
    state.mainThread.send(ThreadMessage.Sendline(),
        "PRIVMSG %s :%s".format(target, event.content));
}

@(Label("8ball"))
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.friend)
@(Prefix(NickPrefixPolicy.required, "8ball"))
void onCommand8ball(const IrcEvent event)
{
    import std.random : uniform;

    // Get a random 8ball message and send it
    const reply = eightballAnswers[uniform(0, eightballAnswers.length)];
    const target = (event.channel.length) ? event.channel : event.sender;
    state.mainThread.send(ThreadMessage.Sendline(),
        "PRIVMSG %s :%s".format(target, reply));
}


@(Label("quote"))
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.friend)
@(Prefix(NickPrefixPolicy.required, "quote"))
void onCommandQuote(const IrcEvent event)
{
    import std.string : strip, indexOf;
    import std.format : format;

    // Get a quote from the JSON list and send it
    const stripped = event.content.strip;
    if (!stripped.length)
    {
        writeln("No one to quote....");
        return;
    }
    else if (stripped.indexOf(" ") != -1)
    {
        writeln("Contains spaces, not a single nick...");
        return;
    }

    // stripModeSign to allow for quotes from @nickname and +dudebro
    const nickname = stripped.stripModeSign;
    const quote = nickname.getQuote();
    const target = (event.channel.length) ? event.channel : event.sender;

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


@(Label("addquote"))
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.friend)
@(Prefix(NickPrefixPolicy.required, "addquote"))
void onCommanAdddQuote(const IrcEvent event)
{
    string slice = event.content;  // need mutable
    const nickname = slice.nom!(Decode.yes)(' ').stripModeSign;

    if (!nickname.length || !slice.length) return;

    nickname.addQuote(slice);
    Files.quotes.saveQuotes(quotes);
    const target = (event.channel.length) ? event.channel : event.sender;

    state.mainThread.send(ThreadMessage.Sendline(),
        "PRIVMSG %s :Quote for %s saved (%d on record)"
        .format(target, nickname, quotes[nickname].array.length));
}


@(Label("printquotes"))
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@(Prefix(NickPrefixPolicy.required, "printquotes"))
void onCommandPrintQuotes(const IrcEvent event)
{
    writeln(quotes.toPrettyString);
}


@(Label("reloadquotes"))
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@(Prefix(NickPrefixPolicy.required, "reloadquotes"))
void onCommandReloadQuotes(const IrcEvent event)
{
    writeln("Reloading quotes");
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

    void initialise()
    {
        //initQuotes();

        writeln("Initialising quotess ...");
        quotes = loadQuotes(Files.quotes);
    }
}
