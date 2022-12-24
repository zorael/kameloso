/++
    The Quotes plugin allows for saving and replaying user quotes.

    A user quote can be added by triggering the "`quote`" bot command, by use
    of "`!quote [nickname] [quote text...]`" (assuming a prefix of "`!`").
    A random one can then be replayed by use of the "`!quote [nickname]`" command.

    On Twitch, the `!quote` command does not take a nickname parameter; instead
    the owner of the channel is assumed to be the target.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#quotes
        [kameloso.plugins.common.core|plugins.common.core]
        [kameloso.plugins.common.misc|plugins.common.misc]
 +/
module kameloso.plugins.quotes2;

version(WithQuotesPlugin):

private:

import kameloso.plugins.common.core;
import kameloso.plugins.common.awareness : UserAwareness;
import kameloso.common : logger;
import kameloso.messaging;
import dialect.defs;

mixin UserAwareness;
mixin ModuleRegistration;


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
    /++
        Quote string line.
     +/
    string line;

    /++
        When the line was uttered, expressed in UNIX time.
     +/
    long timestamp;

    // toJSON
    /++
        Serialises this [Quote] into a [std.json.JSONValue|JSONValue].

        Returns:
            A [std.json.JSONValue|JSONValue] that describes this quote.
     +/
    auto toJSON() const
    {
        JSONValue json;
        json["line"] = JSONValue(this.line);
        json["timestamp"] = JSONValue(this.timestamp);
        return json;
    }

    // fromJSON
    /++
        Deserialises a [Quote] from a [std.json.JSONValue|JSONValue].

        Params:
            json = [std.json.JSONValue|JSONValue] to deserialise.

        Returns:
            A new [quote] with values loaded from the passed JSON.
     +/
    static auto fromJSON(const JSONValue json)
    {
        Quote quote;
        quote.line = json["line"].str;
        quote.timestamp = json["timestamp"].integer;
        return quote;
    }
}


// onCommandQuote
/++
    FIXME
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.anyone)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("quote")
            .policy(PrefixPolicy.prefixed)
            .description("Repeats a random quote of a supplied nickname, " ~
                "or finds one by a search term (best-effort)")
            .addSyntax("$command [nickname]")
            .addSyntax("$command [nickname] [search term]")
            .addSyntax("$command [nickname] [#index]")
    )
)
void onCommandQuote(QuotesPlugin plugin, const ref IRCEvent event)
{
    import std.format : format;

    void sendNoQuotes()
    {
        enum message = "No quotes on record!";
        chan(plugin.state, event.channel, message);
    }

    immutable isTwitch = (plugin.state.server.daemon == IRCServer.Daemon.twitch);

    try
    {
        if (isTwitch)
        {

            immutable nickname = event.channel[1..$];
            immutable searchTerm = event.content;

            const channelQuotes = event.channel in plugin.quotes;
            if (!channelQuotes) return sendNoQuotes();

            const quotes = nickname in *channelQuotes;
            if (!quotes) return sendNoQuotes();

            size_t index;  // mutable
            immutable quote = !searchTerm.length ?
                getRandomQuote(*quotes, index) :
                (searchTerm[0] == '#') ?
                    getQuoteByIndexString(*quotes, searchTerm[1..$], index) :
                    getQuoteBySearchTerm(*quotes, searchTerm, index);

            return sendQuoteToChannel(plugin, quote, event.channel, nickname, index);
        }
        else /*if (!isTwitch)*/
        {
            import lu.string : SplitResults, splitInto;

            void sendUsage()
            {
                enum pattern = "Usage: <b>%s%s<b> [nickname] [optional search term]";
                immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
                chan(plugin.state, event.channel, message);
            }

            string slice = event.content;  // mutable
            size_t index;  // mutable
            string nickname;  // mutable
            immutable results = slice.splitInto(nickname);

            const channelQuotes = event.channel in plugin.quotes;
            if (!channelQuotes) return sendNoQuotes();

            const quotes = nickname in *channelQuotes;
            if (!quotes) return sendNoQuotes();

            with (SplitResults)
            final switch (results)
            {
            case match:
                // No search term
                immutable quote = getRandomQuote(*quotes, index);
                return sendQuoteToChannel(plugin, quote, event.channel, nickname, index);

            case overrun:
                // Search term given
                alias searchTerm = slice;
                immutable quote = getQuoteByIndexString(*quotes, searchTerm[1..$], index);
                return sendQuoteToChannel(plugin, quote, event.channel, nickname, index);

            case underrun:
                // Message was just !quote which only works on Twitch
                return sendUsage();
            }
        }
    }
    catch (NoQuotesFoundException e)
    {
        return sendNoQuotes();
    }
    catch (QuoteIndexOutOfRangeException e)
    {
        enum pattern = "Quote index out of range; %d is not less than %d.";
        immutable message = pattern.format(e.indexGiven, e.upperBound);
        chan(plugin.state, event.channel, message);
    }
    catch (NoQuotesSearchMatchException e)
    {
        enum pattern = "No quotes found for search term \"%s\"";
        immutable message = pattern.format(e.searchTerm);
        chan(plugin.state, event.channel, message);
    }
}


// onCommandAddQuote
/++
    FIXME
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.elevated)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("addquote")
            .policy(PrefixPolicy.prefixed)
            .description("Adds a new quote.")
            .addSyntax("On Twitch: $command [new quote]")
            .addSyntax("Elsewhere: $command [nickname] [new quote]")
    )
)
void onCommandAddQuote(QuotesPlugin plugin, const ref IRCEvent event)
{
    import lu.string : unquoted;
    import std.format : format;
    import std.datetime.systime : Clock;

    immutable isTwitch = (plugin.state.server.daemon == IRCServer.Daemon.twitch);

    void sendUsage()
    {
        immutable pattern = isTwitch ?
            "Usage: %s%s [new quote]" :
            "Usage: <b>%s%s<b> [nickname] [new quote]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
        chan(plugin.state, event.channel, message);
    }

    string nickname;  // mutable
    string slice = event.content;  // mutable

    if (isTwitch)
    {
        if (!event.content.length) return sendUsage();

        nickname = event.channel[1..$];
        // Drop down to create the Quote
    }
    else /*if (!isTwitch)*/
    {
        import lu.string : SplitResults, splitInto;

        immutable results = slice.splitInto(nickname);

        with (SplitResults)
        final switch (results)
        {
        case overrun:
            // Nickname plus new quote given
            // Drop down to create the Quote
            break;

        case match:
        case underrun:
            // match: Only nickname given which only works on Twitch
            // underrun: Message was just !addquote
            return sendUsage();
        }
    }

    immutable prefixSigns = cast(string)plugin.state.server.prefixchars.keys;
    immutable altered = removeWeeChatHead(slice.unquoted, nickname, prefixSigns).unquoted;
    immutable line = altered.length ? altered : slice;

    Quote quote;
    quote.line = line;
    quote.timestamp = Clock.currTime.toUnixTime();

    plugin.quotes[event.channel][nickname] ~= quote;
    immutable pos = plugin.quotes[event.channel][nickname].length+(-1);
    saveQuotes(plugin);

    enum pattern = "Quote added at index %d.";
    immutable message = pattern.format(pos);
    chan(plugin.state, event.channel, message);
}


// onCommandModQuote
/++
    FIXME
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.operator)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("modquote")
            .policy(PrefixPolicy.prefixed)
            .description("Modifies an existing quote.")
            .addSyntax("On Twitch: $command [index] [new quote text]")
            .addSyntax("Elsewhere: $command [nickname] [index] [new quote text]")
    )
)
void onCommandModQuote(QuotesPlugin plugin, const ref IRCEvent event)
{
    import lu.string : SplitResults, splitInto, unquoted;
    import std.conv : ConvException, to;
    import std.format : format;

    immutable isTwitch = (plugin.state.server.daemon == IRCServer.Daemon.twitch);

    void sendUsage()
    {
        immutable pattern = isTwitch ?
            "Usage: %s%s [index] [new quote text]" :
            "Usage: %s%s [nickname] [index] [new quote text]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
        chan(plugin.state, event.channel, message);
    }

    string slice = event.content;  // mutable
    string nickname;  // mutable
    string indexString;  // mutable
    size_t index;  // mutable

    if (isTwitch)
    {
        nickname = event.channel[1..$];
        immutable results = slice.splitInto(indexString);

        with (SplitResults)
        final switch (results)
        {
        case overrun:
            // Index and new quote line was given, drop down
            break;

        case match:
        case underrun:
            // match: Only an index was given
            // underrun: Message was just !addquote
            return sendUsage();
        }
    }
    else /*if (!isTwitch)*/
    {
        immutable results = slice.splitInto(nickname, indexString);

        with (SplitResults)
        final switch (results)
        {
        case overrun:
            // Index and new quote line was given, drop down
            break;

        case match:
        case underrun:
            // match: Only an index was given
            // underrun: Message was just !addquote
            return sendUsage();
        }
    }

    try
    {
        index = indexString.to!size_t;
    }
    catch (ConvException e)
    {
        enum message = "Quote index must be a positive number.";
        return chan(plugin.state, event.channel, message);
    }

    immutable prefixSigns = cast(string)plugin.state.server.prefixchars.keys;
    immutable altered = removeWeeChatHead(slice.unquoted, nickname, prefixSigns).unquoted;
    immutable line = altered.length ? altered : slice;

    plugin.quotes[event.channel][nickname][index].line = line;
    saveQuotes(plugin);

    enum pattern = "Quote modified at index %d; timestamp kept.";
    immutable message = pattern.format(index);
    chan(plugin.state, event.channel, message);
}


// onCommandMergeQuotes
/++
    FIXME
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.operator)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("mergequotes")
            .policy(PrefixPolicy.prefixed)
            .description("Merges the quotes of two users.")
            .addSyntax("$command [source nickname] [target nickname]")
    )
)
void onCommandMergeQuotes(QuotesPlugin plugin, const ref IRCEvent event)
{
    import lu.string : SplitResults, plurality, splitInto;
    import std.format : format;

    if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
    {
        enum message = "You cannot merge quotes on Twitch.";
        return chan(plugin.state, event.channel, message);
    }

    void sendUsage()
    {
        enum pattern = "Usage: %s%s [source nickname] [target nickname]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
        chan(plugin.state, event.channel, message);
    }

    void sendNoQuotes(const string nickname)
    {
        enum pattern = "No quotes for <h>%s<h> on record!";
        immutable message = pattern.format(nickname);
        chan(plugin.state, event.channel, message);
    }

    string slice = event.content;  // mutable
    string source;  // mutable
    string target;  // mutable

    immutable results = slice.splitInto(source, target);
    if (results != SplitResults.match) return sendUsage();

    const channelQuotes = event.channel in plugin.quotes;
    if (!channelQuotes) return sendNoQuotes(source);

    const quotes = source in *channelQuotes;
    if (!quotes) return sendNoQuotes(source);

    plugin.quotes[event.channel][target] ~= *quotes;

    enum pattern = "%d %s merged.";
    immutable message = pattern.format(
        quotes.length,
        quotes.length.plurality("quote", "quotes"));
    chan(plugin.state, event.channel, message);

    plugin.quotes[event.channel].remove(target);
    saveQuotes(plugin);
}


// onCommandDelQuote
/++
    FIXME
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.operator)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("delquote")
            .policy(PrefixPolicy.prefixed)
            .description("Deletes a quote.")
            .addSyntax("On Twitch: $command [index]")
            .addSyntax("Elsewhere: $command [nickname] [index]")
    )
)
void onCommandDelQuote(QuotesPlugin plugin, const ref IRCEvent event)
{
    import lu.string : SplitResults, splitInto;
    import std.format : format;

    immutable isTwitch = (plugin.state.server.daemon == IRCServer.Daemon.twitch);

    void sendNoQuotes(const string nickname)
    {
        immutable pattern = isTwitch ?
            "No quotes for %s on record!" :
            "No quotes for <h>%s<h> on record!";
        immutable message = pattern.format(nickname);
        chan(plugin.state, event.channel, message);
    }

    string nickname;  // mutable
    string indexString;  // mutable

    if (isTwitch)
    {
        void sendUsageTwitch()
        {
            enum pattern = "Usage: %s%s [index]";
            immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
            chan(plugin.state, event.channel, message);
        }

        if (!event.content.length) return sendUsageTwitch();

        nickname = event.channel[1..$];
        indexString = event.content;
    }
    else /*if (!isTwitch)*/
    {
        void sendUsage()
        {
            enum pattern = "Usage: %s%s [nickname] [index]";
            immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
            chan(plugin.state, event.channel, message);
        }

        string slice = event.content;  // mutable

        immutable results = slice.splitInto(nickname, indexString);
        if (results != SplitResults.match) return sendUsage();
    }

    auto channelQuotes = event.channel in plugin.quotes;  // mutable
    if (!channelQuotes) return sendNoQuotes(nickname);

    if (indexString == "*")
    {
        (*channelQuotes).remove(nickname);

        enum pattern = "All quotes for %s removed.";
        immutable message = pattern.format(nickname);
        chan(plugin.state, event.channel, message);
        // Drop down
    }
    else
    {
        import std.algorithm.mutation : SwapStrategy, remove;
        import std.conv : ConvException, to;

        auto quotes = nickname in *channelQuotes;  // mutable
        if (!quotes) return sendNoQuotes(nickname);

        size_t index;

        try
        {
            index = indexString.to!size_t;
        }
        catch (ConvException e)
        {
            enum message = "Quote index must be a positive number.";
            return chan(plugin.state, event.channel, message);
        }

        *quotes = (*quotes).remove!(SwapStrategy.stable)(index);

        enum message = "Quote removed, indexes updated.";
        chan(plugin.state, event.channel, message);
        // Drop down
    }

    saveQuotes(plugin);
}


// sendQuoteToChannel
/++
    FIXME
 +/
void sendQuoteToChannel(
    QuotesPlugin plugin,
    const Quote quote,
    const string channelName,
    const string nickname,
    const size_t index)
{
    import std.datetime.systime : SysTime;
    import std.format : format;

    const when = SysTime.fromUnixTime(quote.timestamp);
    enum pattern = "#d %s (%s %d-%d-%d)";
    immutable message = pattern.format(
        index,
        quote.line,
        nickname,
        when.year,
        when.month,
        when.day);
    chan(plugin.state, channelName, message);
}


// onWelcome
/++
    Initialises the passed [QuotesPlugin]. Loads the quotes from disk.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WELCOME)
)
void onWelcome(QuotesPlugin plugin)
{
    plugin.reload();
}


// getRandomQuote
/++
    FIXME
 +/
auto getRandomQuote(
    const Quote[] quotes,
    out size_t index)
{
    import std.random : uniform;

    if (!quotes.length)
    {
        throw new NoQuotesFoundException("No quotes found");
    }

    index = uniform(0, quotes.length);
    return quotes[index];
}


// getQuoteByIndexString
/++
    FIXME
 +/
auto getQuoteByIndexString(
    const Quote[] quotes,
    const string indexString,
    out size_t index)
{
    import std.conv : ConvException, to;

    index = indexString.to!size_t;

    if (index >= quotes.length)
    {
        throw new QuoteIndexOutOfRangeException(
            "Quote index out of range",
            index,
            quotes.length);
    }

    return quotes[index];
}


// getQuoteBySearchTerm
/++
    FIXME
 +/
Quote getQuoteBySearchTerm(
    const Quote[] quotes,
    const string searchTermCased,
    out size_t index)
{
    import std.string : indexOf;
    import std.uni : toLower;

    auto stripPunctuation(const string quotestring)
    {
        import std.array : replace;

        return quotestring
            .replace(".", " ")
            .replace("!", " ")
            .replace("?", " ")
            .replace(",", " ")
            .replace("-", " ")
            .replace("_", " ")
            .replace("\"", " ")
            .replace("/", " ");
    }

    string[] flattenedQuotes;

    foreach (immutable quote; quotes)
    {
        string flattenedQuote = quote.line.toLower();  // mutable
        size_t doubleSpacePos = flattenedQuote.indexOf("  ");  // mutable

        while (doubleSpacePos != -1)
        {
            import std.array : replace;
            flattenedQuote = flattenedQuote.replace("  ", " ");
        }

        flattenedQuotes ~= flattenedQuote;
    }

    immutable searchTerm = searchTermCased.toLower();

    foreach (immutable i, immutable flattenedQuote; flattenedQuotes)
    {
        if (flattenedQuote.indexOf(searchTerm))
        {
            index = i;
            return quotes[i];
        }
    }

    // Nothing was found; simplify and try again.
    foreach (immutable i, immutable flattenedQuote; flattenedQuotes)
    {
        if (stripPunctuation(flattenedQuote).indexOf(searchTerm))
        {
            index = i;
            return quotes[i];
        }
    }

    throw new NoQuotesSearchMatchException(
        "No quotes found for given search term",
        searchTermCased);
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
auto removeWeeChatHead(
    const string line,
    const string nickname,
    const string prefixes) pure @safe
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


// loadQuotes
/++
    FIXME
 +/
auto loadQuotes(const string quotesFile)
{
    import lu.json : JSONStorage;
    import std.json : JSONException, JSONType;

    JSONStorage json;
    Quote[][string][string] quotes;

    // No need to try-catch loading the JSON; trust in initResources
    json.load(quotesFile);

    foreach (immutable channelName, channelQuotes; json.object)
    {
        foreach (immutable nickname, nicknameQuotesJSON; channelQuotes.object)
        {
            foreach (quoteJSON; nicknameQuotesJSON.array)
            {
                quotes[channelName][nickname] ~= Quote.fromJSON(nicknameQuotesJSON);
            }
        }
    }

    foreach (ref channelQuotes; quotes)
    {
        channelQuotes = channelQuotes.rehash();
    }

    return quotes.rehash();
}


// saveQuotes
/++
    FIXME
 +/
void saveQuotes(QuotesPlugin plugin)
{
    import lu.json : JSONStorage;

    JSONStorage json;
    json.reset();
    json.object = null;

    foreach (immutable channelName, channelQuotes; plugin.quotes)
    {
        json[channelName] = null;
        json[channelName].object = null;
        //auto channelQuotesJSON = channelName in json;  // mutable

        foreach (immutable nickname, quotes; channelQuotes)
        {
            //(*channelQuotesJSON)[nickname] = null;
            //(*channelQuotesJSON)[nickname].array = null;
            //auto quotesJSON = nickname in *channelQuotesJSON;  // mutable

            json[channelName][nickname] = null;
            json[channelName][nickname].array = null;

            foreach (quote; quotes)
            {
                //quotesJSON.array ~= quote.toJSON();
                json[channelName][nickname].array ~= quote.toJSON();
            }
        }
    }

    json.save(plugin.quotesFile);
}


// NoQuotesFoundException
/++
    FIXME
 +/
final class NoQuotesFoundException : Exception
{
    /++
        Constructor.
     +/
    this(
        const string message,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }
}


// QuoteIndexOutOfRangeException
/++
    FIXME
 +/
final class QuoteIndexOutOfRangeException : Exception
{
    size_t indexGiven;

    size_t upperBound;

    /++
        Constructor.
     +/
    this(
        const string message,
        const size_t indexGiven,
        const size_t upperBound,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        this.indexGiven = indexGiven;
        this.upperBound = upperBound;
        super(message, file, line, nextInChain);
    }

    /++
        Constructor.
     +/
    this(
        const string message,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }
}


// NoQuoteSearchMatchException
/++
    FIXME
 +/
final class NoQuotesSearchMatchException : Exception
{
    string searchTerm;

    /++
        Constructor.
     +/
    this(
        const string message,
        const string searchTerm,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        this.searchTerm = searchTerm;
        super(message, file, line, nextInChain);
    }
}


// initResources
/++
    Reads and writes the file of quotes to disk, ensuring that it's there.
 +/
void initResources(QuotesPlugin plugin)
{
    import lu.json : JSONStorage;
    import lu.string : beginsWith;
    import std.json : JSONException, JSONType;

    enum placeholderChannel = "#<lost+found>";

    JSONStorage json;
    bool dirty;

    try
    {
        json.load(plugin.quotesFile);

        // Convert legacy quotes to new ones
        JSONStorage scratchJSON;

        foreach (immutable key, firstLevel; json.object)
        {
            if (key.beginsWith('#')) continue;

            scratchJSON[placeholderChannel] = null;
            scratchJSON[placeholderChannel].object = null;
            scratchJSON[placeholderChannel][key] = firstLevel;
            dirty = true;
        }

        if (dirty)
        {
            foreach (immutable key, firstLevel; json.object)
            {
                if (!key.beginsWith('#')) continue;
                scratchJSON[key] = firstLevel;
            }
        }

        json = scratchJSON;
    }
    catch (JSONException e)
    {
        import kameloso.plugins.common.misc : IRCPluginInitialisationException;

        version(PrintStacktraces) logger.trace(e);
        throw new IRCPluginInitialisationException(
            "Quotes file is malformed",
            plugin.name,
            plugin.quotesFile,
            __FILE__,
            __LINE__);
    }

    // Let other Exceptions pass.

    json.save(plugin.quotesFile);
}


// reload
/++
    Reloads the JSON quotes from disk.
 +/
void reload(QuotesPlugin plugin)
{
    plugin.quotes = loadQuotes(plugin.quotesFile);
}


public:


// QuotesPlugin
/++
    The Quotes plugin provides the ability to save and replay user quotes.

    These are not currently automatically replayed, such as when a user joins,
    but can rather be actively queried by use of the `quote` verb.

    It was historically part of [kameloso.plugins.chatbot.ChatbotPlugin|ChatbotPlugin].
 +/
final class QuotesPlugin : IRCPlugin
{
private:
    import lu.json : JSONStorage;

    /// All Quotes plugin settings gathered.
    QuotesSettings quotesSettings;

    /++
        The in-memory JSON storage of all user quotes.

        It is in the JSON form of `Quote[][string][string]`, where the first key is the
        nickname of a user.
     +/
    Quote[][string][string] quotes;

    /// Filename of file to save the quotes to.
    @Resource string quotesFile = "quotes.json";

    mixin IRCPluginImpl;
}
