module kameloso.plugins.admin;

import kameloso.irc;
import kameloso.constants;
import kameloso.common;
import kameloso.stringutils;


// AdminPlugin
/++
 +  A plugin aimed for adḿinistrative use. It was historically part of Chatbot but now lives
 +  by itself, sadly with much code between them duplicated. FIXME.
 +/
final class AdminPlugin : IrcPlugin
{
private:
    import std.concurrency : Tid, send;
    import std.stdio : write, writeln, writefln;
    import std.algorithm.searching : canFind;

    IrcBot bot;
    Tid mainThread;
    IrcUser[string] users;
    bool delegate()[string] queue;
    bool printAll;

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
            auto newUser = event.sender in users;

            if ((newUser.login == bot.master) || bot.friends.canFind(newUser.login))
            {
                writefln("Replaying old event:");
                writeln(event.toString);
                onCommand(event);
                return true;
            }
            
            return false;
        }

        queue[event.sender] = &dg;

        mainThread.send(ThreadMessage.Whois(), event.sender);
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
        import std.string : munch, indexOf, stripLeft, strip;
        import std.uni : toLower;
        import std.format : format;
        import std.algorithm.mutation  : remove;
        import std.algorithm.searching : countUntil;

        if (users[event.sender].login != bot.master)
        {
            writefln("Failsafe triggered: bot is not master (%s)", event.sender);
            return;
        }

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

        // writefln("admin verb:%s slice:%s", verb, slice);

        switch(verb.toLower)
        {
        case "sudo":
            // Repeat the command as-is, raw, to the server
            if (!slice.length)
            {
                writeln("No argument given to sudo");
                break;
            }
            mainThread.send(ThreadMessage.Sendline(), slice);
            break;

        case "join":
        case "part":
            // Join/part comma-separated channels
            import std.algorithm.iteration : splitter, joiner;
            import std.uni : toUpper;

            if (!slice.length)
            {
                writeln("No channels supplied");
                break;
            }
            mainThread.send(ThreadMessage.Sendline(),
                "%s :%s".format(verb.toUpper, slice.splitter(' ').joiner(",")));
            break;
        
        case "quit":
            // By sending a concurrency message it should quit nicely
            mainThread.send(ThreadMessage.Quit());
            break;

        case "addhome":
            // Add an "active" channel, in which the bot should react
            slice = slice.strip;
            if (!slice.isValidChannel) break;

            if (bot.channels.canFind(slice))
            {
                mainThread.send(ThreadMessage.Sendline(), "JOIN :%s".format(slice));
            }

            bot.channels ~= slice;
            break;

        case "delhome":
            // Remove a channel from the active list
            slice = slice.strip;
            if (!slice.isValidChannel) break;

            auto chanIndex = bot.channels.countUntil(slice);

            if (chanIndex == -1)
            {
                writefln("Channel %s was not in bot.channels", slice);
                break;
            }

            bot.channels = bot.channels.remove(chanIndex);
            mainThread.send(ThreadMessage.Sendline(), "PART :%s".format(slice));
            break;

        case "addfriend":
            // Add a login to the whitelist, so they can access the Chatbot and such
            if (!slice.length)
            {
                writeln("No nickname given.");
                break;
            }
            else if (slice.indexOf(' ') != -1)
            {
                writeln("Nickname must not contain spaces");
                break;
            }

            bot.friends ~= slice;
            writefln("%s added to friends", slice);
            break;

        case "delfriend":
            // Remove a login from the whitelist
            if (!slice.length)
            {
                writeln("No nickname given.");
                break;
            }

            auto friendIndex = bot.friends.countUntil(slice);

            if (friendIndex == -1)
            {
                writefln("No such friend");
                break;
            }

            bot.friends = bot.friends.remove(friendIndex);
            writefln("%s removed from friends", slice);
            break;

        case "resetterm":
            // If for some reason the terminal will have gotten binary on us, reset it
            write(ControlCharacter.termReset);
            break;

        case "printall":
            // Start/stop printing all raw strings
            if (!printAll)
            {
                printAll = true;
                writeln("Now printing everything");
            }
            else
            {
                printAll = false;
                writeln("No longer printing everything");
            }
            break;

        case "status":
            // Print out all current settings
            writeln("I am kameloso");
            printObject(bot);
            break;

        default:
            // writefln("admin unknown verb:%s", verb);
            break;
        }
    
    }

public:
    this(IrcBot bot, Tid tid)
    {
        mixin(scopeguard(entry|failure));
        this.bot = bot;
        mainThread = tid;
    }

    void newBot(IrcBot bot)
    {
        this.bot = bot;
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
        if (printAll)
        {
            writeln(event.raw);
            writeln();
        }

        with (IrcEvent.Type)
        switch (event.type)
        {
        case WHOISLOGIN:
            // Save user to users, then replay any queued commands.
            users[event.target] = userFromEvent(event);
            //users[event.target].lastWhois = Clock.currTime;

            if (auto oldCommand = event.target in queue)
            {
                if ((*oldCommand)())
                {
                    queue.remove(event.target);
                }
            }

            break;

        case QUERY:
            // Queries are always aimed toward the bot, but the user must be whitelisted
            auto user = event.sender in users;

            // if (!user) return doWhois(event);
            if (!user) return doWhois(event);
            else if ((user.login == bot.master)) // || bot.friends.canFind(user.login))
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

            if (!bot.channels.canFind(event.channel))
            {
                // Channel is not relevant
                return;
            }
            else if (!event.content.beginsWith(bot.nickname) ||
                (event.content.length <= bot.nickname.length) ||
                (event.content[bot.nickname.length] != ':'))
            {
                // Not aimed at the bot
                return;
            }

            auto user = event.sender in users;

            /+ if (user)
            {
                // User exists in users database
                if (user.login == bot.master)
                {
                    // User is master, all is ok
                    return onCommand(event);
                }
                /*else if (bot.friends.canFind(user.login))
                {
                    // User is whitelisted, all is ok
                    return onCommand(event);
                }*/
                else
                {
                    // Known bad user
                    return;
                }
            }
            else
            {
                // No known user, relevant channel
                return doWhois(event);
            } +/
            if (!user)
            {
                // No known user, relevant channel
                return doWhois(event);
            }

            // User exists in users database
            if (user.login == bot.master)
            {
                // User is master, all is ok
                return onCommand(event);
            }
            /*else if (bot.friends.canFind(user.login))
            {
                // User is whitelisted, all is ok
                return onCommand(event);
            }*/
            else
            {
                // Known bad user
                return;
            }

        case PART:
        case QUIT:
            users.remove(event.sender);
            break;

        default:
            break;
        }
    }

    /// No teardown neccessary for AdminPlugin
    void teardown() {}
}


