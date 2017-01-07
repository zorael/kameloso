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

    IrcPluginState state;
    bool printAll;

    void updateBot()
    {
        with (state)
        {
            shared botCopy = cast(shared)bot;
            mainThread.send(botCopy);
        }
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
        import std.uni    : toLower;
        import std.algorithm.mutation  : remove;
        import std.algorithm.searching : countUntil;

        with (state)
        {
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
                import std.format : format;
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
                mainThread.send(ThreadMessage.Quit(), slice);
                break;

            case "addhome":
            case "addchan":
                // Add an "active" channel, in which the bot should react
                slice = slice.strip;
                if (!slice.isValidChannel) break;

                if (bot.channels.canFind(slice))
                {
                    mainThread.send(ThreadMessage.Sendline(), "JOIN :" ~ slice);
                }

                writeln("Adding channel: ", slice);
                bot.channels ~= slice;
                updateBot();
                break;

            case "delhome":
            case "delchan":
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
                mainThread.send(ThreadMessage.Sendline(), "PART :" ~ slice);
                updateBot();
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
                updateBot();
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
                updateBot();
                break;

            case "resetterm":
                // If for some reason the terminal will have gotten binary on us, reset it
                write(ControlCharacter.termReset);
                break;

            case "printall":
                // Start/stop printing all raw strings
                printAll = !printAll;
                writeln("Printing all: ", printAll);
                break;

            case "status":
                // Print out all current settings
                mainThread.send(ThreadMessage.Status());
                break;

            default:
                // writefln("admin unknown verb:%s", verb);
                break;
            }
        }
    }

public:
    this(IrcBot bot, Tid tid)
    {
        state.bot = bot;
        state.mainThread = tid;
    }

    void status()
    {
        writefln("---------------------- %s", typeof(this).stringof);
        printObject(state);
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

    /// No teardown neccessary for AdminPlugin
    void teardown() {}
}
