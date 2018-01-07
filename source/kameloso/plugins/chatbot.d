module kameloso.plugins.chatbot;

import kameloso.plugins.common;
import kameloso.ircdefs;
import kameloso.common : logger;
import kameloso.messaging;

import std.concurrency : send;
import std.json : JSONValue;

private:


// ChatbotSettings
/++
 +  Settings for a chatbot.
 +
 +  ------------
 +  struct ChatbotSettings
 +  {
 +      string quotesFile = "quotes.json";
 +      bool eightball = true;
 +      bool quotes = true;
 +      bool say = true;
 +  }
 +  ------------
 +/
struct ChatbotSettings
{
    string quotesFile = "quotes.json";
    bool eightball = true;
    bool quotes = true;
    bool say = true;
}


// getQuote
/++
 +  Fetches a quote for the specified nickname from the in-memory JSON storage.
 +
 +  Params:
 +      nickname = nickname of the user to fetch quotes for.
 +
 +  Returns:
 +      a random quote string. If no quote is available it returns an empty
 +      string instead.
 +/
string getQuote(ChatbotPlugin plugin, const string nickname)
{
    if (const arr = nickname in plugin.quotes)
    {
        import std.random : uniform;

        return arr.array[uniform(0, (*arr).array.length)].str;
    }
    else
    {
        return string.init;
    }
}


// addQuote
/++
 +  Adds a quote to the in-memory JSON storage.
 +
 +  It does not save it to disk; this has to be done separately.
 +
 +  Params:
 +      nickname = nickname of the quoted user.
 +      line = the quote itself.
 +/
void addQuote(ChatbotPlugin plugin, const string nickname, const string line)
{
    if (nickname in plugin.quotes)
    {
        plugin.quotes[nickname].array ~= JSONValue(line);
    }
    else
    {
        // No quotes for nickname
        plugin.quotes.object[nickname] = JSONValue([ line ]);
    }
}


// saveQuotes
/++
 +  Saves the JSON quote list to disk.
 +
 +  This should be done whenever a new quote is added to the database.
 +
 +  Params:
 +      filename = filename of the JSON storage.
 +/
void saveQuotes(ChatbotPlugin plugin, const string filename)
{
    import std.stdio : File, write, writeln;

    auto file = File(filename, "w");
    file.write(plugin.quotes.toPrettyString);
    file.writeln();
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

    if (!filename.exists || !filename.isFile)
    {
        //logger.info(filename, " does not exist or is not a file!");
        JSONValue newJSON;
        newJSON.object = null;
        return newJSON;
    }

    immutable wholeFile = readText(filename);
    return parseJSON(wholeFile);
}


// onCommandSay
/++
 +  Repeats text to the channel the event was sent to.
 +
 +  If it was sent in a query, respond in a private message in kind.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.friend)
@(ChannelPolicy.homeOnly)
@BotCommand("say")
@BotCommand("säg")
@BotCommand(NickPolicy.required, "say")
@BotCommand(NickPolicy.required, "säg")
@Description("Repeats text to the channel the event was sent to.")
void onCommandSay(ChatbotPlugin plugin, const IRCEvent event)
{
    if (!plugin.chatbotSettings.say) return;

    import std.format : format;

    if (!event.content.length)
    {
        logger.error("No text to send...");
        return;
    }

    plugin.privmsg(event.channel, event.sender.nickname, event.content);
}


// onCommand8ball
/++
 +  Implements 8ball.
 +
 +  Randomises a response from the table kameloso.constants.eightballAnswers
 +  and sends it back to the channel in which the triggering event happened,
 +  or in a query if it was a private message.
 +
 +  Params:
 +      event = the triggering IRCEvent.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.friend)
@(ChannelPolicy.homeOnly)
@BotCommand("8ball")
@BotCommand(NickPolicy.required, "8ball")
@Description("Implements 8ball. Randomises a vague yes/no response.")
void onCommand8ball(ChatbotPlugin plugin, const IRCEvent event)
{
    if (!plugin.chatbotSettings.eightball) return;

    import std.format : format;
    import std.random : uniform;

    // Fetched from wikipedia
    static immutable string[20] eightballAnswers =
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

    immutable reply = eightballAnswers[uniform(0, eightballAnswers.length)];

    plugin.privmsg(event.channel, event.sender.nickname, reply);
}


// onCommandQuote
/++
 +  Fetches and repeats a random quote of a supplied nickname.
 +
 +  The quote is read from in-memory JSON storage, and it is sent to the
 +  channel the triggering event occured in.
 +
 +  Params:
 +      event = the triggering IRCEvent.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.friend)
@(ChannelPolicy.homeOnly)
@BotCommand("quote")
@BotCommand(NickPolicy.required, "quote")
@Description("Fetches and repeats a random quote of a supplied nickname.")
void onCommandQuote(ChatbotPlugin plugin, const IRCEvent event)
{
    import std.json : JSONException;

    if (!plugin.chatbotSettings.quotes) return;

    import kameloso.irc : isValidNickname, stripModesign;
    import std.format : format;
    import std.string : strip;

    // stripModesign to allow for quotes from @nickname and +dudebro
    string nickname = event.content.strip;
    plugin.state.bot.server.stripModesign(nickname);

    if (!nickname.isValidNickname(plugin.state.bot.server))
    {
        logger.errorf("Invalid nickname: '%s'", nickname);
        return;
    }

    try
    {
        immutable quote = plugin.getQuote(nickname);

        if (quote.length)
        {
            plugin.privmsg(event.channel, event.sender.nickname,
                "%s | %s".format(nickname, quote));
        }
        else
        {
            plugin.privmsg(event.channel, event.sender.nickname,
                "No quote on record for %s".format(nickname));
        }
    }
    catch (const JSONException e)
    {
        logger.errorf("Could not quote '%s': %s", nickname, e.msg);
    }
}


// onCommandAddQuote
/++
 +  Creates a new quote.
 +
 +  It is added to the in-memory JSON storage which then gets immediately
 +  written to disk.
 +
 +  Params:
 +      event = The triggering IRCEvent.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.friend)
@(ChannelPolicy.homeOnly)
@BotCommand("addquote")
@BotCommand(NickPolicy.required, "addquote")
@Description("Creates a new quote.")
void onCommanAddQuote(ChatbotPlugin plugin, const IRCEvent event)
{
    if (!plugin.chatbotSettings.quotes) return;

    import kameloso.irc : stripModesign;
    import kameloso.string : nom;
    import std.format : format;
    import std.json : JSONException;
    import std.typecons : Yes;

    string slice = event.content;  // need mutable
    string nickname = slice.nom!(Yes.decode)(' ');
    plugin.state.bot.server.stripModesign(nickname);

    if (!nickname.length || !slice.length) return;

    try
    {
        plugin.addQuote(nickname, slice);
        plugin.saveQuotes(plugin.chatbotSettings.quotesFile);

        plugin.privmsg(event.channel, event.sender.nickname,
            "Quote for %s saved (%d on record)"
            .format(nickname, plugin.quotes[nickname].array.length));
    }
    catch (const JSONException e)
    {
        logger.errorf("Could not add quote for '%s': %s", nickname, e.msg);
    }
}


// onCommandPrintQuotes
/++
 +  Prints the in-memory quotes JSON storage to the local terminal.
 +
 +  This is for debugging purposes.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@(ChannelPolicy.homeOnly)
@BotCommand(NickPolicy.required, "printquotes")
@Description("[debug] Prints all quotes to the local terminal.")
void onCommandPrintQuotes(ChatbotPlugin plugin)
{
    import std.stdio : writeln, stdout;

    if (!plugin.chatbotSettings.quotes) return;

    writeln(plugin.quotes.toPrettyString);
    version(Cygwin_) stdout.flush();
}


// onCommandReloadQuotes
/++
 +  Reloads the JSON quotes from disk.
 +
 +  This is both for debugging purposes and to simply allow for live manual
 +  editing of quotes.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@(ChannelPolicy.homeOnly)
@BotCommand(NickPolicy.required, "reloadquotes")
@Description("[debug] Reloads quotes from disk.")
void onCommandReloadQuotes(ChatbotPlugin plugin)
{
    if (!plugin.chatbotSettings.quotes) return;

    logger.log("Reloading quotes");
    plugin.quotes = loadQuotes(plugin.chatbotSettings.quotesFile);
}


// onEndOfMotd
/++
 +  Initialises the Chatbot plugin. Loads the quotes from disk.
 +/
@(IRCEvent.Type.RPL_ENDOFMOTD)
void onEndOfMotd(ChatbotPlugin plugin)
{
    plugin.quotes = loadQuotes(plugin.chatbotSettings.quotesFile);
}


// onCommandHelp
/++
 +  Starts the process of echoing all available bot commands to a user (in a
 +  private query). A hack.
 +
 +  Plugins don't know about other plugin; the only thing they know of the
 +  outside world is the thread ID of the main thread (`state.mainThread`).
 +  As such, we can't easily query each plugin for their `BotCommand`-annotated
 +  functions.
 +
 +  To work around this we save the initial requesting `IRCEvent`, then send a
 +  concurrency message to the main thread asking for a const reference to the
 +  main `IRCPlugin[]` array. We create a function in interface `IRCPlugin` that
 +  passes said array on to the top-level `peekPlugins`, wherein we process the
 +  list and collect the bot command strings.
 +
 +  Once we have the list we format it nicely and send it back to the requester,
 +  which we remember since we saved the original `IRCEvent`.
 +/
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@BotCommand(NickPolicy.required, "help")
@BotCommand(NickPolicy.required, "hello")
@Description("Shows the command list.")
void onCommandHelp(ChatbotPlugin plugin, const IRCEvent event)
{
    import kameloso.common : ThreadMessage;

    plugin.helpEvent = event;
    plugin.state.mainThread.send(ThreadMessage.PeekPlugins(),
        cast(shared IRCPlugin)plugin);
}


// peekPlugins
/++
 +  Takes a const reference to the main `IRCPlugin[]` array and gathers and
 +  formats each plugin's list of available bot commands.
 +
 +  This does not include bot regexes.
 +/
void peekPlugins(ChatbotPlugin plugin, const IRCPlugin[] plugins)
{
    import kameloso.constants : KamelosoInfo;
    import kameloso.string : has, nom;
    import std.algorithm.sorting : sort;
    import std.format : format;

    if (plugin.helpEvent == IRCEvent.init) return;
    scope(exit) plugin.helpEvent = IRCEvent.init;

    with (plugin)
    {
        if (helpEvent.content.length)
        {
            if (helpEvent.content.has!(Yes.decode)(" "))
            {
                string slice = helpEvent.content;
                immutable specifiedPlugin = slice.nom!(Yes.decode)(" ");
                immutable specifiedCommand = slice;

                foreach (p; plugins)
                {
                    if (p.name != specifiedPlugin) continue;

                    if (auto description = specifiedCommand in p.commands)
                    {
                        throttleline(helpEvent.channel, helpEvent.sender.nickname,
                            "[%s] %s: %s".format(p.name, specifiedCommand, *description));
                        return;
                    }
                    else
                    {
                        throttleline(helpEvent.channel, helpEvent.sender.nickname,
                            "No help available for command %s of plugin %s"
                            .format(specifiedCommand, specifiedPlugin));
                        return;
                    }
                }

                throttleline(helpEvent.channel, helpEvent.sender.nickname,
                    "No such plugin: " ~ specifiedPlugin);
                return;
            }
            else
            {
                foreach (p; plugins)
                {
                    if (p.name != helpEvent.content) continue;

                    enum width = 11;

                    throttleline(helpEvent.channel, helpEvent.sender.nickname,
                        "* %-*s %-([%s]%| %)"
                        .format(width, p.name, p.commands.keys.sort()));
                    return;
                }
            }
        }
        else
        {
            enum banner = "kameloso IRC bot v%s, built %s"
                .format(cast(string)KamelosoInfo.version_,
                cast(string)KamelosoInfo.built);

            throttleline(helpEvent.channel, helpEvent.sender.nickname, banner);
            throttleline(helpEvent.channel, helpEvent.sender.nickname,
                "Available bot commands per plugin (beta):");

            foreach (p; plugins)
            {
                if (!p.commands.length) continue;

                enum width = 11;

                throttleline(helpEvent.channel, helpEvent.sender.nickname,
                    "* %-*s %-([%s]%| %)"
                    .format(width, p.name, p.commands.keys.sort()));
            }

            throttleline(helpEvent.channel, helpEvent.sender.nickname,
                "Use help [plugin] [command] for information about a command.");
            throttleline(helpEvent.channel, helpEvent.sender.nickname,
                "Additional unlisted regex commands may be available.");
        }
    }
}


mixin UserAwareness;

public:


// Chatbot
/++
 +  Chatbot plugin to provide common chat functionality.
 +
 +  Administrative actions have been broken out into a plugin of its own.
 +/
final class ChatbotPlugin : IRCPlugin
{
    /// All Chatbot plugin settings gathered
    @Settings ChatbotSettings chatbotSettings;

    // quotes
    /++
    +  The in-memory JSON storage of all user quotes.
    +
    +  It is in the JSON form of `string[][string]`, where the first key is the
    +  nickname of a user.
    +/
    JSONValue quotes;

    IRCEvent helpEvent;

    mixin IRCPluginImpl;
    mixin MessagingProxy;
}
