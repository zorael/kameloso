module kameloso.plugins.chatbot;

import kameloso.plugins.common;
import kameloso.irc;
import kameloso.stringutils;
import kameloso.constants;
import kameloso.common;

import std.json : JSONValue, parseJSON;


// Chatbot
/++
 +  Chatbot plugin to provide common chat functionality. Administrative actions have been
 +  broken out into a plugin of its own.
 +/
final class Chatbot : IrcPlugin
{
private:
    import std.stdio : writeln, writefln;
    import std.concurrency : Tid, thisTid, send;
    import std.algorithm : canFind;

    IrcPluginState state;
    JSONValue quotes;

    // doWhois
    /++
     +  Ask the main thread to do a WHOIS call. That way the plugins don't need to know of the
     +  Connection at all, at the cost of message passing overhead.
     +
     +  A big FIXME is to make this code common with AdminPlugin.
     +
     +  Params:
     +      event = A complete IrcEvent to queue for later processing.
     +/
    void doWhois(const IrcEvent event)
    {
        writefln("Missing user information on %s", event.sender);
        
        bool dg()
        {
            auto newUser = event.sender in state.users;

            if ((newUser.login == bot.master) || bot.friends.canFind(newUser.login))
            {
                writefln("Replaying old event:");
                writeln(event.toString);
                onCommand(event);
                return true;
            }
            
            return false;
        }

        state.queue[event.sender] = &dg;

        state.mainThread.send(ThreadMessage.Whois(), event.sender);
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

        // writefln("Chatbot verb:%s slice:%s", verb, slice);

        switch(verb.toLower)
        {
        case "8ball":
            import std.random : uniform;

            // Get a random 8ball message and send it
            const reply = eightballAnswers[uniform(0, eightballAnswers.length)];
            state.mainThread.send(ThreadMessage.Sendline(),
                "PRIVMSG %s :%s".format(target, reply));
            break;

        case "säg":
        case "say":
            // Simply repeat what was said
            state.mainThread.send(ThreadMessage.Sendline(),
                "PRIVMSG %s :%s".format(target, slice));
            break;

        case "quote":
            // Get a quote from the JSON list and send it
            if (!slice.length) break;

            // stripModeSign to allow for quotes from @nickname and +dudebro
            const nickname = slice.stripModeSign;
            const quote = quotes.getQuote(nickname);

            if (!quote.length) break;

            state.mainThread.send(ThreadMessage.Sendline(),
                "PRIVMSG %s :%s | %s".format(target, nickname, quote));
            break;

        case "addquote":
            // Add a quote to the JSON list and save it to disk
            const nickname = slice.nom!(Decode.yes)(' ').stripModeSign;

            if (nickname.length && slice.length)
            {
                if (auto arr = nickname in quotes)
                {
                    quotes[nickname].array ~= JSONValue(slice);
                }
                else
                {
                    quotes.object[nickname] = JSONValue([ slice ]);
                }

                Files.quotes.saveQuotes(quotes);
                state.mainThread.send("PRIVMSG %s :Quote for %s saved (%d on record)"
                    .format(target, nickname, quotes[nickname].array.length));
            }
            break;
        
        case "printquotes":
            // Print all quotes to the terminal
            writeln(quotes.toPrettyString);
            break;

        case "reloadquotes":
            // Reload quotes from disk (in case they were manually changed)
            writeln("Reloading quotes");
            Files.quotes.loadQuotes(quotes);
            break;

        default:
            // writefln("Chatbot unknown verb:%s", verb);
            // do nothing
            break;
        }
    }

public:
    this(IrcBot bot, Tid tid)
    {
        mixin(scopeguard(entry|failure));
        state.bot = bot;
        state.mainThread = tid;

        writeln("quote file:", Files.quotes);
        Files.quotes.loadQuotes(quotes);
    }

    void newBot(IrcBot bot)
    {
        state.bot = bot;
    }

    /++
     +  React to an IrcEvent from the server. At this point nothing about it is known, and only
     +  event from whitelisted users (and master) should be reacted to. So; logic to ensure
     +  the user is authorised, and that the message was aimed toward the bot.
     +
     +  Params:
     +      event = A complete IrcEvent to react to.
     +/
    void onEvent(const IrcEvent event)
    {
        with (IrcEvent.Type)
        switch (event.type)
        {
        case WHOISLOGIN:
            // Save user to users, then replay any queued commands.
            state.users[event.target] = userFromEvent(event);
            //users[event.target].lastWhois = Clock.currTime;

            if (auto oldCommand = event.target in state.queue)
            {
                if ((*oldCommand)())
                {
                   state.queue.remove(event.target);
                }
            }

            break;

        case QUERY:
            // Queries are always aimed toward the bot, but the user must be whitelisted
            auto user = event.sender in state.users;

            // if (!user) return doWhois(event);
            if (!user) return state.doWhois2(event, &onCommand);
            else if ((user.login == state.bot.master) || state.bot.friends.canFind(user.login))
            {
                // master or friend
                return onCommand(event);
            }
            break;

        case CHAN:
            /*
             * Not all channel messages are of interest; only those starting with the bot's
             * nickname, those from whitelisted users, and those in channels marked as active.
             */

            if (!state.bot.channels.canFind(event.channel))
            {
                // Channel is not relevant
                return;
            }
            else if (!event.content.beginsWith(state.bot.nickname) ||
                (event.content.length <= state.bot.nickname.length) ||
                (event.content[state.bot.nickname.length] != ':'))
            {
                // Not aimed at the bot
                return;
            }

            auto user = event.sender in state.users;

            if (user)
            {
                // User exists in users database
                if (user.login == state.bot.master)
                {
                    // User is master, all is ok
                    return onCommand(event);
                }
                else if (state.bot.friends.canFind(user.login))
                {
                    // User is whitelisted, all is ok
                    return onCommand(event);
                }
                else
                {
                    // Known bad user
                    return;
                }
            }
            else
            {
                // No known user, relevant channel
                //return doWhois(event);
                return state.doWhois2(event, &onCommand);
            }

        case PART:
        case QUIT:
            state.users.remove(event.sender);
            break;

        default:
            break;
        }
    }

    /// No teardown neccessary for Chatbot
    void teardown() {}
}


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
static string getQuote(const JSONValue quotes, const string nickname)
{
    if (quotes.object.length) return string.init;

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
}


// loadQuotes
/// Ditto but loads instead of saves
static void loadQuotes(const string filename, ref JSONValue quotes)
{
    import std.stdio  : writefln;
    import std.file   : exists, isFile, readText;
    import std.string : chomp;
    writefln("Loading quotes");

    if (!filename.exists)
    {
        writefln("%s does not exist", filename);
        quotes = parseJSON("{}");
        filename.saveQuotes(quotes);
        return;
    }
    else if (!filename.isFile)
    {
        writefln("%s is not a file", filename);
        return;
    }

    auto wholeFile = filename.readText.chomp;
    quotes = parseJSON(wholeFile);
}