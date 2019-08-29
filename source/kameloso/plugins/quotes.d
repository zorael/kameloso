/++
 +  The Quotes plugin allows for saving and replaying user quotes.
 +
 +  A user quote can be added by triggering the "`addquote`" bot command, by use
 +  of "`botname: addquote`" or "`!addquote`" (assuming a prefix of "`!`"). A
 +  random one can then be replayed by use of the "`quote [nickname]`" command.
 +
 +  See the GitHub wiki for more information about available commands:
 +  - https://github.com/zorael/kameloso/wiki/Current-plugins#quotes
 +/
module kameloso.plugins.quotes;

version(WithPlugins):
version(WithQuotesPlugin):

private:

import kameloso.plugins.common;
import kameloso.irc.defs;
import kameloso.common : logger, settings;
import kameloso.irc.colours : ircBold, ircColourByHash;
import kameloso.json : JSONStorage;
import kameloso.messaging;

import std.typecons : Flag, No, Yes;


// QuotesSettings
/++
 +  All settings for a Quotes plugin, gathered in a struct.
 +/
struct QuotesSettings
{
    /// Whether or not the Quotes plugin should react to events at all.
    @Enabler bool enabled = true;
}


// getRandomQuote
/++
 +  Fetches a quote for the specified nickname from the in-memory JSON array.
 +
 +  Example:
 +  ---
 +  string quote = plugin.getRandomQuote(event.sender.nickame);
 +  if (!quote.length) return;
 +  // ...
 +  ---
 +
 +  Params:
 +      plugin = Current `QuotesPlugin`.
 +      nickname = Nickname of the user to fetch quotes for.
 +
 +  Returns:
 +      Random quote string. If no quote is available it returns an empty string instead.
 +/
string getRandomQuote(QuotesPlugin plugin, const string nickname)
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
 +  Example:
 +  ---
 +  string nickname = "kameloso";
 +  string line = "This is a line";
 +  plugin.addQuote(nickname, line);
 +  ---
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
        // cannot modify const expression (*nickquotes).array
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
 +  channel the triggering event occurred in, alternatively in a private message
 +  if the request was sent in one such.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.whitelist)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "quote")
@Description("Fetches and repeats a random quote of a supplied nickname.",
    "$command [nickname]")
void onCommandQuote(QuotesPlugin plugin, const IRCEvent event)
{
    import kameloso.irc.common : isValidNickname, stripModesign;
    import kameloso.string : stripped;
    import std.format : format;
    import std.json : JSONException;

    // stripModesign to allow for quotes from @nickname and +dudebro
    immutable signed = event.content.stripped;
    immutable specified = plugin.state.client.server.stripModesign(signed);

    if (!specified.isValidNickname(plugin.state.client.server))
    {
        enum pattern = `"%s" is not a valid account or nickname.`;

        immutable message = settings.colouredOutgoing ?
            pattern.format(specified.ircBold) :
            pattern.format(specified);

        privmsg(plugin.state, event.channel, event.sender.nickname, message);
        return;
    }

    /// Report success to IRC
    void report(const string nickname, const string endQuote)
    {
        enum pattern = "%s | %s";

        immutable message = settings.colouredOutgoing ?
            pattern.format(nickname.ircColourByHash.ircBold, endQuote) :
            pattern.format(nickname, endQuote);

        privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }

    try
    {
        void onSuccess(const IRCUser replyUser)
        {
            immutable endAccount = replyUser.account.length ? replyUser.account : replyUser.nickname;
            immutable quote = plugin.getRandomQuote(endAccount);

            if (quote.length)
            {
                return report(endAccount, quote);
            }

            enum pattern = "No quote on record for %s";

            immutable message = settings.colouredOutgoing ?
                pattern.format(replyUser.nickname.ircColourByHash.ircBold) :
                pattern.format(replyUser.nickname);

            privmsg(plugin.state, event.channel, event.sender.nickname, message);
        }

        void onFailure(const IRCUser failureUser)
        {
            logger.log("(Assuming unauthenticated nickname or offline account was specified)");
            return onSuccess(failureUser);
        }

        version(TwitchSupport)
        {
            if (plugin.state.client.server.daemon == IRCServer.Daemon.twitch)
            {
                return onSuccess(event.sender);
            }
        }

        immutable quote = plugin.getRandomQuote(specified);

        if (quote.length)
        {
            return report(specified, quote);
        }

        mixin WHOISFiberDelegate!(onSuccess, onFailure);

        enqueueAndWHOIS(specified);
    }
    catch (JSONException e)
    {
        string logtint, errortint;

        version(Colours)
        {
            if (!settings.monochrome)
            {
                import kameloso.logger : KamelosoLogger;

                logtint = (cast(KamelosoLogger)logger).logtint;
                errortint = (cast(KamelosoLogger)logger).errortint;
            }
        }

        logger.errorf("Could not quote %s%s%s: %1$s%4$s", logtint, specified, errortint, e.msg);
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
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.whitelist)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "addquote")
@Description("Creates a new quote.", "$command [nickname] [quote text]")
void onCommandAddQuote(QuotesPlugin plugin, const IRCEvent event)
{
    import kameloso.irc.common : isValidNickname, stripModesign;
    import kameloso.string : nom;
    import std.json : JSONException;
    import std.format : format;
    import std.typecons : No, Yes;

    string slice = event.content;  // need mutable
    immutable signed = slice.nom!(Yes.decode)(' ');
    immutable specified = plugin.state.client.server.stripModesign(signed);

    if (!specified.length || !slice.length) return;

    if (!specified.isValidNickname(plugin.state.client.server))
    {
        enum pattern = `"%s" is not a valid account or nickname.`;

        immutable message = settings.colouredOutgoing ?
            pattern.format(specified.ircBold) :
            pattern.format(specified);

        privmsg(plugin.state, event.channel, event.sender.nickname, message);
        return;
    }

    void onSuccess(const string id)
    {
        try
        {
            import std.conv : text;

            plugin.addQuote(id, slice);
            plugin.quotes.save(plugin.quotesFile);

            enum pattern = "Quote for %s saved (%s on record)";

            immutable message = settings.colouredOutgoing ?
                pattern.format(id.ircColourByHash.ircBold,
                    plugin.quotes[id].array.length.text.ircBold) :
                pattern.format(id, plugin.quotes[id].array.length);

            privmsg(plugin.state, event.channel, event.sender.nickname, message);
        }
        catch (JSONException e)
        {
            string logtint, errortint;

            version(Colours)
            {
                if (!settings.monochrome)
                {
                    import kameloso.logger : KamelosoLogger;

                    logtint = (cast(KamelosoLogger)logger).logtint;
                    errortint = (cast(KamelosoLogger)logger).errortint;
                }
            }

            logger.errorf("Could not add quote for %s%s%s: %1$s%4$s", logtint, id, errortint, e.msg);
        }
    }

    void onFailure(const IRCUser failureUser)
    {
        logger.log("(Assuming unauthenticated nickname or offline account was specified)");
        return onSuccess(failureUser.nickname);
    }

    version(TwitchSupport)
    {
        if (plugin.state.client.server.daemon == IRCServer.Daemon.twitch)
        {
            return onSuccess(specified);
        }
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
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "printquotes")
@Description("[debug] Prints all quotes to the local terminal.")
void onCommandPrintQuotes(QuotesPlugin plugin)
{
    import std.stdio : stdout, writeln;

    writeln("Currently stored quotes:");
    writeln(plugin.quotes.toPrettyString);
    if (settings.flush) stdout.flush();
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
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "reloadquotes")
@Description("Reloads quotes from disk.")
void onCommandReloadQuotes(QuotesPlugin plugin, const IRCEvent event)
{
    privmsg(plugin.state, event.channel, event.sender.nickname, "Reloading quotes.");
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
    plugin.quotes.load(plugin.quotesFile);
}


// initResources
/++
 +  Reads and writes the file of quotes to disk, ensuring that it's there.
 +/
void initResources(QuotesPlugin plugin)
{
    import kameloso.json : JSONStorage;
    import std.json : JSONException;

    JSONStorage json;

    try
    {
        json.load(plugin.quotesFile);
    }
    catch (JSONException e)
    {
        import std.path : baseName;
        throw new IRCPluginInitialisationException(plugin.quotesFile.baseName ~ " may be malformed.");
    }

    // Let other Exceptions pass.

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
private:
    /// All Quotes plugin settings gathered.
    @Settings QuotesSettings quotesSettings;

    /++
     +  The in-memory JSON storage of all user quotes.
     +
     +  It is in the JSON form of `string[][string]`, where the first key is the
     +  nickname of a user.
     +/
    JSONStorage quotes;

    /// Filename of file to save the quotes to.
    @Resource string quotesFile = "quotes.json";

    mixin IRCPluginImpl;
}
