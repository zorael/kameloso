/++
    The Quotes plugin allows for saving and replaying user quotes.

    A user quote can be added by triggering the "`quote`" bot command, by use
    of "`!quote [nickname] [quote text...]`" (assuming a prefix of "`!`").
    A random one can then be replayed by use of the "`!quote [nickname]`" command.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#quotes
 +/
module kameloso.plugins.quotes;

version(WithPlugins):
version(WithQuotesPlugin):

private:

import kameloso.plugins.common.core;
import kameloso.plugins.common.awareness : UserAwareness;
import kameloso.common : Tint, logger;
import kameloso.irccolours : ircBold, ircColourByHash;
import kameloso.messaging;
import dialect.defs;
import lu.json : JSONStorage;
import std.typecons : Flag, No, Yes;


// QuotesSettings
/++
    All settings for a Quotes plugin, gathered in a struct.
 +/
@Settings struct QuotesSettings
{
    /// Whether or not the Quotes plugin should react to events at all.
    @Enabler bool enabled = true;
}


// Quote
/++
    Embodies the notion of a quote. A string line paired with a UNIX timestamp.
 +/
struct Quote
{
private:
    import std.json : JSONValue;

public:
    /// Quote string line.
    string line;

    /// When the line was uttered, expressed in UNIX time.
    long timestamp;

    /// Constructor taking a `std.json.JSONValue`.
    this(const JSONValue json)
    {
        this.line = json["line"].str;
        this.timestamp = json["timestamp"].integer;
    }
}


// getRandomQuote
/++
    Fetches a quote for the specified nickname from the in-memory JSON array.

    Example:
    ---
    string quote = plugin.getRandomQuote(event.sender.nickame);
    if (!quote.length) return;
    // ...
    ---

    Params:
        plugin = Current `QuotesPlugin`.
        nickname = Nickname of the user to fetch quotes for.

    Returns:
        A `Quote` containing a random quote string. If no quote is available it
        returns an empty `Quote.init` instead.
 +/
Quote getRandomQuote(QuotesPlugin plugin, const string nickname)
{
    if (const quotesForNickname = nickname in plugin.quotes)
    {
        import std.random : uniform;

        immutable len = quotesForNickname.array.length;
        immutable storedQuoteJSON = quotesForNickname.array[uniform(0, len)];

        return Quote(storedQuoteJSON);
    }
    else
    {
        return Quote.init;
    }
}


// onCommandQuote
/++
    Fetches and repeats a random quote of a supplied nickname.

    On Twitch, picks a quote from the stored quotes of the current channel owner.

    The quote is read from in-memory JSON storage, and it is sent to the
    channel the triggering event occurred in, alternatively in a private message
    if the request was sent in one such.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.whitelist)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "quote")
@Description("Fetches and repeats a random quote of a supplied nickname, " ~
    "or adds a new one.", "$command [nickname] [text if adding new quote]")
void onCommandQuote(QuotesPlugin plugin, const IRCEvent event)
{
    import dialect.common : isValidNickname, stripModesign, toLowerCase;
    import lu.string : nom, stripped, strippedLeft;
    import std.format : format;
    import std.json : JSONException;

    string slice = event.content.stripped;  // mutable

    if (!slice.length && (plugin.state.server.daemon != IRCServer.Daemon.twitch))
    {
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "Usage: %s%s [nickname] [optional text to add a new quote]"
            .format(plugin.state.settings.prefix, event.aux));
        return;
    }

    version(TwitchSupport)
    {
        if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
        {
            import kameloso.plugins.common.base : nameOf;

            if ((slice == event.channel[1..$]) ||
                (slice == plugin.nameOf(event.channel[1..$])))
            {
                // Line was "!quote streamername";
                // Slice away the name so a new one-word quote isn't added
                slice = string.init;
            }
        }
    }

    immutable specified = (plugin.state.server.daemon == IRCServer.Daemon.twitch) ?
        event.channel[1..$] :
        slice.nom!(Yes.inherit)(' ').stripModesign(plugin.state.server);
    immutable trailing = slice.strippedLeft;  // Already strippedRight earlier

    if ((plugin.state.server.daemon != IRCServer.Daemon.twitch) &&
        !specified.isValidNickname(plugin.state.server))
    {
        enum pattern = `"%s" is not a valid account or nickname.`;

        immutable message = plugin.state.settings.colouredOutgoing ?
            pattern.format(specified.ircBold) :
            pattern.format(specified);

        return privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }

    /// Report success to IRC
    void report(const string nickname, const Quote quote)
    {
        import std.datetime.systime : SysTime;

        enum pattern = "[%d-%02d-%02d %02d:%02d] %s | %s";

        SysTime when = SysTime.fromUnixTime(quote.timestamp);

        immutable message = plugin.state.settings.colouredOutgoing ?
            pattern.format(when.year, when.month, when.day, when.hour, when.minute,
                nickname.ircColourByHash.ircBold, quote.line) :
            pattern.format(when.year, when.month, when.day, when.hour, when.minute,
                nickname, quote.line);

        privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }

    try
    {
        void onSuccess(const IRCUser replyUser)
        {
            import kameloso.plugins.common.base : idOf;

            immutable id = idOf(replyUser).toLowerCase(plugin.state.server.caseMapping);

            if (trailing.length)
            {
                // There is trailing text, assume it was a quote to be added
                return plugin.addQuoteAndReport(event, id, trailing);
            }

            // No point looking up if we already did before onSuccess
            if (id != specified)
            {
                immutable quote = plugin.getRandomQuote(id);

                if (quote.line.length)
                {
                    return report(id, quote);
                }
            }

            enum pattern = "No quote on record for %s";

            immutable message = plugin.state.settings.colouredOutgoing ?
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
            if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
            {
                return onSuccess(event.sender);
            }
        }

        // Try the specified nickname/account first, in case it's a nickname that
        // has quotes but resolve to a different account that doesn't.
        // But only if there's no trailing text; would mean it's a new quote
        if (!trailing.length)
        {
            immutable quote = plugin.getRandomQuote(specified);

            if (quote.line.length)
            {
                return report(specified, quote);
            }
        }

        import kameloso.plugins.common.mixins : WHOISFiberDelegate;

        mixin WHOISFiberDelegate!(onSuccess, onFailure);

        enqueueAndWHOIS(specified);
    }
    catch (JSONException e)
    {
        logger.errorf("Could not quote %s%s%s: %1$s%4$s", Tint.log, specified, Tint.error, e.msg);
        version(PrintStacktraces) logger.trace(e.info);
    }
}


// addQuoteAndReport
/++
    Adds a quote for the specified user and saves the list to disk. Reports
    success to the channel in which the command took place, or user directly
    if in a query.

    Params:
        plugin = The current `QuotesPlugin`.
        event = The instigating `dialect.defs.IRCEvent`.
        id = The specified nickname or (preferably) account.
        rawLine = The quote string to add.
 +/
void addQuoteAndReport(QuotesPlugin plugin, const IRCEvent event,
    const string id, const string rawLine)
in (id.length, "Tried to add a quote for an empty user")
in (rawLine.length, "Tried to add an empty quote")
{
    import lu.string : unquoted;
    import std.json : JSONException, JSONValue;

    immutable prefixSigns = cast(string)plugin.state.server.prefixchars.keys;
    immutable altered = removeWeeChatHead(rawLine.unquoted, id, prefixSigns).unquoted;
    immutable line = altered.length ? altered : rawLine;

    try
    {
        import std.datetime.systime : Clock;
        import std.format : format;

        JSONValue newQuote;
        newQuote["line"] = line;
        newQuote["timestamp"] = Clock.currTime.toUnixTime;

        if (id !in plugin.quotes)
        {
            // No previous quotes for nickname
            // Initialise the JSONValue as an array
            plugin.quotes[id] = null;
            plugin.quotes[id].array = null;
        }

        plugin.quotes[id].array ~= newQuote;
        plugin.quotes.save(plugin.quotesFile);

        enum pattern = "Quote for %s saved (%s on record)";

        immutable message = plugin.state.settings.colouredOutgoing ?
            pattern.format(id.ircColourByHash.ircBold,
                plugin.quotes[id].array.length.ircBold) :
            pattern.format(id, plugin.quotes[id].array.length);

        privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }
    catch (JSONException e)
    {
        logger.errorf("Could not add quote for %s%s%s: %1$s%4$s",
            Tint.log, id, Tint.error, e.msg);
        version(PrintStacktraces) logger.trace(e.info);
    }
}


// removeWeeChatHead
/++
    Removes the WeeChat timestamp and nickname from the front of a string.

    Params:
        line = Full string line as copy/pasted from WeeChat.
        nickname = The nickname to remove (along with the timestamp).
        prefixes = The available user prefixes on the current server.

    Returns:
        The original line with the WeeChat timestamp and nickname sliced away,
        or as it was passed. No new string is ever allocated.
 +/
string removeWeeChatHead(const string line, const string nickname,
    const string prefixes) pure @safe @nogc
in (nickname.length, "Tried to remove WeeChat head for a nickname but the nickname was empty")
{
    import lu.string : beginsWith, contains, nom, strippedLeft;

    static bool isN(const char c)
    {
        return ((c >= '0') && (c <= '9'));
    }

    string slice = line.strippedLeft;  // mutable

    // See if it has WeeChat timestamps at the front of the message
    // e.g. "12:34:56   @zorael | text text text"

    if (slice.length > 8)
    {
        if (isN(slice[0]) && isN(slice[1]) && (slice[2] == ':') &&
            isN(slice[3]) && isN(slice[4]) && (slice[5] == ':') &&
            isN(slice[6]) && isN(slice[7]) && (slice[8] == ' '))
        {
            // Might yet be WeeChat, keep going
            slice = slice[9..$].strippedLeft;
        }
    }

    // See if it has WeeChat nickname at the front of the message
    // e.g. "@zorael | text text text"

    if (slice.length > nickname.length)
    {
        if ((prefixes.contains(slice[0]) &&
            slice[1..$].beginsWith(nickname)) ||
            slice.beginsWith(nickname))
        {
            slice.nom(nickname);
            slice = slice.strippedLeft;

            if ((slice.length > 2) && (slice[0] == '|'))
            {
                slice = slice[1..$];

                if (slice[0] == ' ')
                {
                    slice = slice.strippedLeft;
                    // Finished
                }
                else
                {
                    // Does not match pattern; undo
                    slice = line;
                }
            }
            else
            {
                // Does not match pattern; undo
                slice = line;
            }
        }
        else
        {
            // Does not match pattern; undo
            slice = line;
        }
    }
    else
    {
        // Only matches the timestmp so don't trust it
        slice = line;
    }

    return slice;
}

///
unittest
{
    immutable prefixes = "!~&@%+";

    {
        enum line = "20:08:27 @zorael | dresing";
        immutable modified = removeWeeChatHead(line, "zorael", prefixes);
        assert((modified == "dresing"), modified);
    }
    {
        enum line = "               20:08:27                   @zorael | dresing";
        immutable modified = removeWeeChatHead(line, "zorael", prefixes);
        assert((modified == "dresing"), modified);
    }
    {
        enum line = "+zorael | dresing";
        immutable modified = removeWeeChatHead(line, "zorael", prefixes);
        assert((modified == "dresing"), modified);
    }
    {
        enum line = "2y:08:27 @zorael | dresing";
        immutable modified = removeWeeChatHead(line, "zorael", prefixes);
        assert((modified == line), modified);
    }
    {
        enum line = "16:08:27       <-- | kameloso (~kameloso@2001:41d0:2:80b4::) " ~
            "has quit (Remote host closed the connection)";
        immutable modified = removeWeeChatHead(line, "kameloso", prefixes);
        assert((modified == line), modified);
    }
}


// reload
/++
    Reloads the JSON quotes from disk.
 +/
void reload(QuotesPlugin plugin)
{
    //logger.info("Reloading quotes from disk.");
    plugin.quotes.load(plugin.quotesFile);
}


// onWelcome
/++
    Initialises the passed `QuotesPlugin`. Loads the quotes from disk.
 +/
@(IRCEvent.Type.RPL_WELCOME)
void onWelcome(QuotesPlugin plugin)
{
    plugin.quotes.load(plugin.quotesFile);
}


// initResources
/++
    Reads and writes the file of quotes to disk, ensuring that it's there.
 +/
void initResources(QuotesPlugin plugin)
{
    import lu.json : JSONStorage;
    import std.json : JSONException;

    JSONStorage json;

    try
    {
        json.load(plugin.quotesFile);
    }
    catch (JSONException e)
    {
        import std.path : baseName;

        version(PrintStacktraces) logger.trace(e);
        throw new IRCPluginInitialisationException(plugin.quotesFile.baseName ~ " may be malformed.");
    }

    // Let other Exceptions pass.

    json.save(plugin.quotesFile);
}


mixin UserAwareness;

public:

// QuotesPlugin
/++
    The Quotes plugin provides the ability to save and replay user quotes.

    These are not currently automatically replayed, such as when a user joins,
    but can rather be actively queried by use of the `quote` verb.

    It was historically part of `kameloso.plugins.chatbot.ChatbotPlugin`.
 +/
final class QuotesPlugin : IRCPlugin
{
private:
    /// All Quotes plugin settings gathered.
    QuotesSettings quotesSettings;

    /++
        The in-memory JSON storage of all user quotes.

        It is in the JSON form of `Quote[][string]`, where the first key is the
        nickname of a user.
     +/
    JSONStorage quotes;

    /// Filename of file to save the quotes to.
    @Resource string quotesFile = "quotes.json";

    mixin IRCPluginImpl;
}
