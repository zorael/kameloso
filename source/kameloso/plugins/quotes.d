/++
 +  The Quotes plugin allows for saving and replaying user quotes.
 +
 +  A user quote can be added by triggering the "`addquote`" bot command, by use
 +  of "`botname: addquote`" or "`!addquote`" (assuming a prefix of "`!`"). A
 +  random one can then be replayed by use o the "`quote [nickname]`" command.
 +
 +  It has a few commands:
 +
 +  `quote`<br>
 +  `addquote`<br>
 +  `reloadquotes`<br>
 +  `printquotes`
 +
 +  It is very optional.
 +/
module kameloso.plugins.quotes;

version(WithPlugins):

private:

import kameloso.plugins.common;
import kameloso.ircdefs;
import kameloso.common : logger;
import kameloso.messaging;


// QuotesSettings
/++
 +  All settings for a Quotes plugin, gathered in a struct.
 +/
struct QuotesSettings
{
    /// Whether the Quotes plugin should react to events at all.
    bool enabled = true;
}


// getQuote
/++
 +  Fetches a quote for the specified nickname from the in-memory JSON array.
 +
 +  Example:
 +  ---
 +  string quote = plugin.getQuote(event.sender.nickame);
 +  if (!quote.length) return;
 +  // ...
 +  ---
 +
 +  Params:
 +      plugin = Current `QuotesPlugin`.
 +      nickname = Nickname of the user to fetch quotes for.
 +
 +  Returns:
 +      Random quote string. If no quote is available it returns an empty string
 +      instead.
 +/
string getQuote(QuotesPlugin plugin, const string nickname)
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
 +      plugin = Current `QuotesPlugin`.
 +      nickname = Nickname of the quoted user.
 +      line = Quote to add.
 +/
void addQuote(QuotesPlugin plugin, const string nickname, const string line)
{
    import std.json : JSONValue;

    if (nickname in plugin.quotes)
    {
        plugin.quotes[nickname].array ~= JSONValue(line);
    }
    else
    {
        // No quotes for nickname
        plugin.quotes[nickname] = JSONValue([ line ]);
    }
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
@Description("Fetches and repeats a random quote of a supplied nickname.",
    "$command [nickname of user to quote]")
void onCommandQuote(QuotesPlugin plugin, const IRCEvent event)
{
    if (!plugin.quotesSettings.enabled) return;

    import kameloso.irc : isValidNickname, stripModesign;
    import kameloso.string : stripped;
    import std.json : JSONException;

    // stripModesign to allow for quotes from @nickname and +dudebro
    immutable signed = event.content.stripped;
    immutable specified = plugin.state.bot.server.stripModesign(signed);

    if (!specified.isValidNickname(plugin.state.bot.server))
    {
        logger.warningf("Invalid account/nickname: '%s'", specified);
        return;
    }

    void report(const string nickname, const string endQuote)
    {
        import std.format : format;
        plugin.privmsg(event.channel, event.sender.nickname,
            "%s | %s".format(nickname, endQuote));
    }

    try
    {
        void onSuccess(const IRCUser replyUser)
        {
            immutable endAccount = replyUser.account.length ? replyUser.account : replyUser.nickname;
            immutable quote = plugin.getQuote(endAccount);

            if (quote.length)
            {
                return report(endAccount, quote);
            }
            else
            {
                import std.format : format;
                plugin.privmsg(event.channel, event.sender.nickname,
                    "No quote on record for %s".format(replyUser.nickname));
            }
        }

        void onFailure(const IRCUser failureUser)
        {
            logger.log("(Assuming unauthenticated nickname or offline account was specified)");
            return onSuccess(failureUser);
        }

        immutable quote = plugin.getQuote(specified);

        if (quote.length)
        {
            return report(specified, quote);
        }

        mixin WHOISFiberDelegate!(onSuccess, onFailure);

        enqueueAndWHOIS(specified);
    }
    catch (const JSONException e)
    {
        logger.errorf("Could not quote '%s': %s", specified, e.msg);
        return;
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
@Description("Creates a new quote.", "$command [nickname] [quote text]")
void onCommandAddQuote(QuotesPlugin plugin, const IRCEvent event)
{
    if (!plugin.quotesSettings.enabled) return;

    import kameloso.irc : isValidNickname, stripModesign;
    import kameloso.string : nom;
    import std.json : JSONException;
    import std.typecons : No, Yes;

    string slice = event.content;  // need mutable
    immutable signed = slice.nom!(Yes.decode)(' ');
    immutable specified = plugin.state.bot.server.stripModesign(signed);

    if (!specified.length || !slice.length) return;

    if (!specified.isValidNickname(plugin.state.bot.server))
    {
        logger.warningf("Invalid account/nickname: '%s'", specified);
        return;
    }

    void onSuccess(const string id)
    {
        try
        {
            import std.format : format;

            plugin.addQuote(id, slice);
            plugin.quotes.save(plugin.quotesFile);

            plugin.privmsg(event.channel, event.sender.nickname,
                "Quote for %s saved (%d on record)"
                .format(event.sender.nickname, plugin.quotes[id].array.length));
        }
        catch (const JSONException e)
        {
            logger.errorf("Could not add quote for %s: %s", id, e.msg);
        }
    }

    void onFailure(const IRCUser failureUser)
    {
        logger.log("(Assuming unauthenticated nickname or offline account was specified)");
        return onSuccess(failureUser.nickname);
    }

    mixin WHOISFiberDelegate!(onSuccess, onFailure);

    enqueueAndWHOIS(specified);
}


// onCommandPrintQuotes
/++
 +  Prints the in-memory quotes JSON storage to the local terminal.
 +
 +  This is for debugging purposes.
 +/
debug
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "printquotes")
@Description("[debug] Prints all quotes to the local terminal.")
void onCommandPrintQuotes(QuotesPlugin plugin)
{
    if (!plugin.quotesSettings.enabled) return;

    import std.stdio : writeln, stdout;

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
@Description("Reloads quotes from disk.")
void onCommandReloadQuotes(QuotesPlugin plugin)
{
    if (!plugin.quotesSettings.enabled) return;

    logger.log("Reloading quotes");
    plugin.quotes.load(plugin.quotesFile);
}


// onEndOfMotd
/++
 +  Initialises the passed `QuotesPlugin`. Loads the quotes from disk.
 +/
@(IRCEvent.Type.RPL_ENDOFMOTD)
@(IRCEvent.Type.ERR_NOMOTD)
void onEndOfMotd(QuotesPlugin plugin)
{
    if (!plugin.quotesSettings.enabled) return;

    plugin.quotes.load(plugin.quotesFile);
}


// initResources
/++
 +  Reads and writes the file of quotes to disk, ensuring that it's there.
 +/
void initResources(QuotesPlugin plugin)
{
    import kameloso.json : JSONStorage;

    JSONStorage json;
    json.load(plugin.quotesFile);
    json.save(plugin.quotesFile);
}


mixin MinimalAuthentication;

public:

// QuotesPlugin
/++
 +  The Quotes plugin provides the ability to save and replay user quotes.
 +
 +  These are not currently automatically replayed, such as when a user joins,
 +  but can rather be actively queried by use of the `quote` verb.
 +
 +  It was historically part of `kameloso.plugins.chatbot.ChatbotPlugin`.
 +/
final class QuotesPlugin : IRCPlugin
{
    import kameloso.json : JSONStorage;

    // quotes
    /++
    +  The in-memory JSON storage of all user quotes.
    +
    +  It is in the JSON form of `string[][string]`, where the first key is the
    +  nickname of a user.
    +/
    JSONStorage quotes;

    /// All Quotes plugin settings gathered.
    @Settings QuotesSettings quotesSettings;

    /// Filename of file to save the quotes to.
    @Resource string quotesFile = "quotes.json";

    mixin IRCPluginImpl;
    mixin MessagingProxy;
}
