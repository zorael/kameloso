module kameloso.plugins.chatbot;

import kameloso.plugins.common;
import kameloso.irc;
import kameloso.stringutils;
import kameloso.constants;
import kameloso.common;

import std.stdio : writeln, writefln;
import std.json : JSONValue, parseJSON, JSONException;
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
static string getQuote(const string nickname)
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
static void addQuote(const string nickname, const string line)
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
static void saveQuotes(const string filename, const JSONValue quotes)
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
static JSONValue loadQuotes(const string filename)
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


// onCommand
/++
    +  React to a command from an IRC user. At this point it is known to be aimed toward
    +  the bot, and we know the caller to be whitelisted or master.
    +  It makes sense to split it up into different strings (verb and whatever), and then
    +  do a string switch on them. It is, however, ugly.
    +
    +  Params:
    +      event = A complete IrcEvent to react to.
    +/
void onCommand(const IrcEvent event)
{
    import std.string : munch, indexOf, stripLeft;
    import std.uni : toLower;
    import std.format : format;

    with (state)
    {
        string slice;

        if (event.type == IrcEvent.Type.QUERY)
        {
            slice = event.content.stripLeft;
        }
        else
        {
            // We know it to be aimed at us from earlier checks so remove nickname prefix
            slice = event.content.stripLeft[(bot.nickname.length+1)..$];
            slice.munch(":?! ");
        }

        string verb;

        // If we don't decode here the verb will be truncated if it contiains international characters
        if (slice.indexOf(' ') != -1)
        {
            verb = slice.nom!(Decode.yes)(' ');
        }
        else
        {
            verb = slice;
            slice = string.init;
        }

        const target = (event.channel.length) ? event.channel : event.sender;

        switch(verb.toLower)
        {
        case "8ball":
            import std.random : uniform;

            // Get a random 8ball message and send it
            const reply = eightballAnswers[uniform(0, eightballAnswers.length)];
            mainThread.send(ThreadMessage.Sendline(),
                "PRIVMSG %s :%s".format(target, reply));
            break;

        case "säg":
        case "say":
            // Simply repeat what was said
            mainThread.send(ThreadMessage.Sendline(),
                "PRIVMSG %s :%s".format(target, slice));
            break;

        case "quote":
            // Get a quote from the JSON list and send it
            if (!slice.length) break;

            // stripModeSign to allow for quotes from @nickname and +dudebro
            const nickname = slice.stripModeSign;
            const quote = nickname.getQuote();

            if (quote.length)
            {
                mainThread.send(ThreadMessage.Sendline(),
                    "PRIVMSG %s :%s | %s".format(target, nickname, quote));
            }
            else
            {
                mainThread.send(ThreadMessage.Sendline(),
                    "PRIVMSG %s :No quote on record for %s".format(target, nickname));
            }
            break;

        case "addquote":
            // Add a quote to the JSON list and save it to disk
            const nickname = slice.nom!(Decode.yes)(' ').stripModeSign;

            if (!nickname.length || !slice.length) return;

            nickname.addQuote(slice);
            Files.quotes.saveQuotes(quotes);

            mainThread.send(ThreadMessage.Sendline(),
                "PRIVMSG %s :Quote for %s saved (%d on record)"
                .format(target, nickname, quotes[nickname].array.length));
            break;

        case "printquotes":
            // Print all quotes to the terminal
            writeln(quotes.toPrettyString);
            break;

        case "reloadquotes":
            // Reload quotes from disk (in case they were manually changed)
            writeln("Reloading quotes");
            quotes = loadQuotes(Files.quotes);
            break;

        default:
            // writefln("Chatbot unknown verb:%s", verb);
            // do nothing
            break;
        }
    }
}


/++
    +  React to an IrcEvent from the server. At this point nothing about it is known, and only
    +  events from whitelisted users (and master) should be reacted to. So; logic to ensure
    +  the user is authorised, and that the message was aimed toward the bot.
    +
    +  Params:
    +      event = A complete IrcEvent to react to.
    +/
void onEvent(const IrcEvent event)
{
    with (state)
    with (IrcEvent.Type)
    switch (event.type)
    {
    case CHAN:
        if (state.filterChannel!(RequirePrefix.yes)(event) == FilterResult.fail)
        {
            // Invalid channel or not prefixed
            return;
        }
        break;

    case QUERY:
        break;

    default:
        state.onBasicEvent(event);
        return;
    }

    final switch (state.filterUser(event))
    {
    case FilterResult.pass:
        // It is a known good user (friend or master), but it is of any type
        return onCommand(event);

    case FilterResult.whois:
        return state.doWhois(event);

    case FilterResult.fail:
        // It is a known bad user
        return;
    }
}


void initQuotes()
{
    writeln("Initialising quotess ...");
    quotes = loadQuotes(Files.quotes);
}


void chatbotWorker(shared IrcPluginState origState)
{
    state = cast(IrcPluginState)origState;
    initQuotes();

    mixin ircPluginWorkerReceiveLoop!state receiveLoop;
    receiveLoop.exec();
}


public:

// Chatbot
/++
 +  Chatbot plugin to provide common chat functionality. Administrative actions have been
 +  broken out into a plugin of its own.
 +/
final class Chatbot(Multithreaded multithreaded) : IrcPlugin
{
    mixin IrcPluginBasics!(chatbotWorker, initQuotes);
}
