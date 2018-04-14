/++
 +  The Chatbot plugin is a collection of small, harmless functions like `8ball`
 +  and repeating text, along with the ability to save and replay user quotes.
 +
 +  A user quote can be added by triggering the "`addquote`" bot command, by use
 +  of "`botname: addquote`" or "`!addquote`" (assuming a prefix of "`!`"). A
 +  random one can then be replayed by use o the "`quote [nickname]`" command.
 +
 +  It has a few commands:
 +
 +  `8ball`<br>
 +  `quote`<br>
 +  `addquote`<br>
 +  `help` | `hello`<br>
 +  `say` | `säg`<br>
 +  `reloadquotes`<br>
 +  `printquotes`
 +
 +  It is very optional.
 +/
module kameloso.plugins.chatbot;

import kameloso.plugins.common;
import kameloso.ircdefs;
import kameloso.common : logger;
import kameloso.messaging;

import std.json : JSONValue;

private:


// ChatbotSettings
/++
 +  Settings for a chatbot, to toggle its features.
 +/
struct ChatbotSettings
{
    /// Filename of file to save the quotes to.
    string quotesFile = "quotes.json";

    /// Enable or disable the magic eightball feature.
    bool eightball = true;

    /// Enable or disable the quote feature.
    bool quotes = true;

    /// Enable or disable the "say" feature.
    bool say = true;
}


// getQuote
/++
 +  Fetches a quote for the specified nickname from the in-memory JSON array.
 +
 +  Example:
 +  ------------
 +  string quote = plugin.getQuote(event.sender.nickame);
 +  if (!quote.length) return;
 +  // ...
 +  ------------
 +
 +  Params:
 +      plugin = Current `ChatbotPlugin`.
 +      nickname = Nickname of the user to fetch quotes for.
 +
 +  Returns:
 +      Random quote string. If no quote is available it returns an empty string
 +      instead.
 +/
string getQuote(ChatbotPlugin plugin, const string nickname)
{
    if (const arr = nickname in plugin.quotes)
    {
        import std.random : uniform;

        return arr.array[uniform(0, arr.array.length)].str;
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
 +      plugin = Current `ChatbotPlugin`.
 +      nickname = Nickname of the quoted user.
 +      line = Quote to add.
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
 +      plugin = Current `ChatbotPlugin`.
 +      filename = Filename of the JSON storage file.
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
 +      filename = Filename of the JSON storage file.
 +/
JSONValue loadQuotes(const string filename)
{
    import std.file   : exists, isFile, readText;
    import std.json   : parseJSON;

    if (!filename.exists || !filename.isFile)
    {
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
@(PrivilegeLevel.whitelist)
@(ChannelPolicy.home)
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
 +  Implements magic `8ball` (https://en.wikipedia.org/wiki/Magic_8-Ball).
 +
 +  Randomises a response from the internal `eightballAnswers` table and sends
 +  it back to the channel in which the triggering event happened, or in a query
 +  if it was a private message.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.whitelist)
@(ChannelPolicy.home)
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
 +  channel the triggering event occured in, alternatively in a private message
 +  if the request was sent in one such.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.whitelist)
@(ChannelPolicy.home)
@BotCommand("quote")
@BotCommand(NickPolicy.required, "quote")
@Description("Fetches and repeats a random quote of a supplied nickname.")
void onCommandQuote(ChatbotPlugin plugin, const IRCEvent event)
{
    import std.json : JSONException;

    if (!plugin.chatbotSettings.quotes) return;

    import kameloso.irc : isValidNickname, stripModesign;
    import kameloso.string : stripped;
    import std.format : format;

    // stripModesign to allow for quotes from @nickname and +dudebro
    immutable signed = event.content.stripped;
    immutable nickname = plugin.state.bot.server.stripModesign(signed);

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
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.whitelist)
@(ChannelPolicy.home)
@BotCommand("addquote")
@BotCommand(NickPolicy.required, "addquote")
@Description("Creates a new quote.")
void onCommandAddQuote(ChatbotPlugin plugin, const IRCEvent event)
{
    if (!plugin.chatbotSettings.quotes) return;

    import kameloso.irc : stripModesign;
    import kameloso.string : nom;
    import std.format : format;
    import std.json : JSONException;
    import std.typecons : Yes;

    string slice = event.content;  // need mutable
    immutable signed = slice.nom!(Yes.decode)(' ');
    immutable nickname = plugin.state.bot.server.stripModesign(signed);

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
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
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
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
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
 +  Initialises the passed `ChatbotPlugin`. Loads the quotes from disk.
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
 +  Plugins don't know about other plugins; the only thing they know of the
 +  outside world is the thread ID of the main thread `mainThread` of
 +  (`kameloso.plugins.common.IRCPluginState`). As such, we can't easily query
 +  each plugin for their `kameloso.plugins.common.BotCommand`-annotated
 +  functions.
 +
 +  To work around this we save the initial requesting
 +  `kameloso.ircdefs.IRCEvent`, then send a concurrency message to the main
 +  thread asking for a const reference to the main
 +  `kameloso.common.Client.plugins` array of
 +  `kameloso.plugins.common.IRCPlugin`s. We create a function in interface
 +  `kameloso.plugins.common.IRCPlugin` that passes said array on to the top-
 +  level `peekPlugins`, wherein we process the list and collect the bot command
 +  strings.
 +
 +  Once we have the list we format it nicely and send it back to the requester,
 +  which we remember since we saved the original `kameloso.ircdefs.IRCEvent`.
 +/
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@BotCommand(NickPolicy.required, "help")
@BotCommand(NickPolicy.required, "hello")
@Description("Shows the command list.")
void onCommandHelp(ChatbotPlugin plugin, const IRCEvent event)
{
    import kameloso.common : ThreadMessage;
    import std.concurrency : send;

    plugin.helpEvent = event;
    plugin.state.mainThread.send(ThreadMessage.PeekPlugins(),
        cast(shared IRCPlugin)plugin);
}


// peekPlugins
/++
 +  Takes a const reference to the main `kameloso.common.Client.plugins` array
 +  of `kameloso.plugins.common.IRCPlugin`s, and gathers and formats each
 +  plugin's list of available bot commands.
 +
 +  This does not include bot regexes, as we do not know how to extract the
 +  expression from the `std.regex.Regex` structure.
 +/
void peekPlugins(ChatbotPlugin plugin, const IRCPlugin[] plugins)
{
    import kameloso.constants : KamelosoInfo;
    import kameloso.string : has, nom;
    import std.algorithm.searching : endsWith;
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
                if (!p.commands.length || p.name.endsWith("Service")) continue;

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
 +  The Chatbot plugin provides common chat functionality. This includes magic
 +  8ball, user quotes, and some other miscellanea.
 +
 +  Administrative actions have been broken out into
 +  `kameloso.plugins.admin.AdminPlugin`.
 +/
final class ChatbotPlugin : IRCPlugin
{
    /// All Chatbot plugin settings gathered.
    @Settings ChatbotSettings chatbotSettings;

    // quotes
    /++
    +  The in-memory JSON storage of all user quotes.
    +
    +  It is in the JSON form of `string[][string]`, where the first key is the
    +  nickname of a user.
    +/
    JSONValue quotes;

    /++
    +   The event that spawned a "`help`" request. As a hack it is currently
    +   stored here, so the plugin knows what to do when the results of
    +   `kameloso.common.ThreadMessage.PeekPlugins` return.
    +/
    IRCEvent helpEvent;

    mixin IRCPluginImpl;
    mixin MessagingProxy;
}
