/++
    The Quotes plugin allows for saving and replaying user quotes.

    On Twitch, the commands do not take a nickname parameter; instead
    the owner of the channel (the broadcaster) is assumed to be the target.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#quotes,
        [kameloso.plugins.common.core],
        [kameloso.plugins.common.misc]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.quotes;

version(WithQuotesPlugin):

private:

import kameloso.plugins;
import kameloso.plugins.common.core;
import kameloso.plugins.common.awareness : UserAwareness;
import kameloso.common : logger;
import kameloso.messaging;
import dialect.defs;

mixin UserAwareness;
mixin PluginRegistration!QuotesPlugin;


// QuotesSettings
/++
    All settings for a Quotes plugin, gathered in a struct.
 +/
@Settings struct QuotesSettings
{
    /++
        Whether or not the Quotes plugin should react to events at all.
     +/
    @Enabler bool enabled = true;

    /++
        Whether or not a random result should be picked in case some quote search
        terms had multiple matches.
     +/
    bool alwaysPickFirstMatch = false;
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
            A new [Quote] with values loaded from the passed JSON.
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
    Replies with a quote, either fetched randomly, by search terms or by stored index.
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
                "or finds one by search terms (best-effort)")
            .addSyntax("On Twitch: $command")
            .addSyntax("On Twitch: $command [search terms]")
            .addSyntax("On Twitch: $command [#index]")
            .addSyntax("Elsewhere: $command [nickname]")
            .addSyntax("Elsewhere: $command [nickname] [search terms]")
            .addSyntax("Elsewhere: $command [nickname] [#index]")
    )
)
void onCommandQuote(QuotesPlugin plugin, const ref IRCEvent event)
{
    import dialect.common : isValidNickname;
    import lu.string : stripped;
    import std.conv : ConvException;
    import std.format : format;
    import std.string : representation;

    immutable isTwitch = (plugin.state.server.daemon == IRCServer.Daemon.twitch);

    void sendNonTwitchUsage()
    {
        enum pattern = "Usage: <b>%s%s<b> [nickname] [optional search terms or #index]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel, message);
    }

    if (!isTwitch && !event.content.length) return sendNonTwitchUsage();

    try
    {
        if (isTwitch)
        {
            immutable nickname = event.channel[1..$];
            immutable searchTerms = event.content.stripped;

            const channelQuotes = event.channel in plugin.quotes;
            if (!channelQuotes)
            {
                return Senders.sendNoQuotesForNickname(plugin, event, nickname);
            }

            const quotes = nickname in *channelQuotes;
            if (!quotes || !quotes.length)
            {
                return Senders.sendNoQuotesForNickname(plugin, event, nickname);
            }

            size_t index;  // mutable
            immutable quote = !searchTerms.length ?
                getRandomQuote(*quotes, nickname, index) :
                (searchTerms.representation[0] == '#') ?
                    getQuoteByIndexString(*quotes, searchTerms[1..$], index) :
                    getQuoteBySearchTerms(plugin, *quotes, searchTerms, index);

            return sendQuoteToChannel(plugin, quote, event.channel, nickname, index);
        }
        else /*if (!isTwitch)*/
        {
            import lu.string : SplitResults, splitInto;

            string slice = event.content.stripped;  // mutable
            string nickname;  // mutable
            immutable results = slice.splitInto(nickname);

            if (results == SplitResults.underrun)
            {
                // Message was just !quote which only works on Twitch
                return sendNonTwitchUsage();
            }

            if (!nickname.isValidNickname(plugin.state.server))
            {
                return Senders.sendInvalidNickname(plugin, event, nickname);
            }

            const channelQuotes = event.channel in plugin.quotes;
            if (!channelQuotes)
            {
                return Senders.sendNoQuotesForNickname(plugin, event, nickname);
            }

            const quotes = nickname in *channelQuotes;
            if (!quotes || !quotes.length)
            {
                return Senders.sendNoQuotesForNickname(plugin, event, nickname);
            }

            with (SplitResults)
            final switch (results)
            {
            case match:
                // No search terms
                size_t index;  // out reference!
                immutable quote = getRandomQuote(*quotes, nickname, index);
                return sendQuoteToChannel(plugin, quote, event.channel, nickname, index);

            case overrun:
                // Search terms given
                alias searchTerms = slice;
                size_t index;  // out reference!
                immutable quote = (searchTerms.representation[0] == '#') ?
                    getQuoteByIndexString(*quotes, searchTerms[1..$], index) :
                    getQuoteBySearchTerms(plugin, *quotes, searchTerms, index);
                return sendQuoteToChannel(plugin, quote, event.channel, nickname, index);

            case underrun:
                // Handled above
                assert(0, "Impossible case hit in `onCommandQuote`");
            }
        }
    }
    catch (NoQuotesFoundException e)
    {
        Senders.sendNoQuotesForNickname(plugin, event, e.nickname);
    }
    catch (QuoteIndexOutOfRangeException e)
    {
        Senders.sendIndexOutOfRange(plugin, event, e.indexGiven, e.upperBound);
    }
    catch (NoQuotesSearchMatchException e)
    {
        enum pattern = "No quotes found for search terms \"<b>%s<b>\"";
        immutable message = pattern.format(e.searchTerms);
        chan(plugin.state, event.channel, message);
    }
    catch (ConvException _)
    {
        Senders.sendIndexMustBePositiveNumber(plugin, event);
    }
}


// onCommandAddQuote
/++
    Adds a quote to the local storage.
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
    import lu.string : stripped, strippedRight, unquoted;
    import std.format : format;
    import std.datetime.systime : Clock;

    immutable isTwitch = (plugin.state.server.daemon == IRCServer.Daemon.twitch);

    void sendUsage()
    {
        immutable pattern = isTwitch ?
            "Usage: %s%s [new quote]" :
            "Usage: <b>%s%s<b> [nickname] [new quote]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel, message);
    }

    string nickname;  // mutable
    string slice = event.content.stripped;  // mutable

    if (isTwitch)
    {
        if (!slice.length) return sendUsage();
        nickname = event.channel[1..$];
        // Drop down to create the Quote
    }
    else /*if (!isTwitch)*/
    {
        import dialect.common : isValidNickname;
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

        if (!nickname.isValidNickname(plugin.state.server))
        {
            return Senders.sendInvalidNickname(plugin, event, nickname);
        }
    }

    immutable prefixSigns = cast(string)plugin.state.server.prefixchars.keys;
    immutable altered = removeWeeChatHead(slice.unquoted, nickname, prefixSigns).unquoted;
    immutable line = altered.length ? altered : slice;

    Quote quote;
    quote.line = line.strippedRight;
    quote.timestamp = Clock.currTime.toUnixTime();

    plugin.quotes[event.channel][nickname] ~= quote;
    immutable pos = plugin.quotes[event.channel][nickname].length+(-1);
    saveQuotes(plugin);

    enum pattern = "Quote added at index <b>#%d<b>.";
    immutable message = pattern.format(pos);
    chan(plugin.state, event.channel, message);
}


// onCommandModQuote
/++
    Modifies a quote given its index in the storage.
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
    import lu.string : SplitResults, splitInto, stripped, strippedRight, unquoted;
    import std.conv : ConvException, to;
    import std.format : format;

    immutable isTwitch = (plugin.state.server.daemon == IRCServer.Daemon.twitch);

    void sendUsage()
    {
        immutable pattern = isTwitch ?
            "Usage: %s%s [index] [new quote text]" :
            "Usage: <b>%s%s<b> [nickname] [index] [new quote text]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel, message);
    }

    string slice = event.content.stripped;  // mutable
    string nickname;  // mutable
    string indexString;  // mutable
    ptrdiff_t index;  // mutable

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
        import lu.string : beginsWith;
        if (indexString.beginsWith('#')) indexString = indexString[1..$];
        index = indexString.to!ptrdiff_t;
    }
    catch (ConvException _)
    {
        return Senders.sendIndexMustBePositiveNumber(plugin, event);
    }

    if ((event.channel !in plugin.quotes) ||
        (nickname !in plugin.quotes[event.channel]))
    {
        // If there are no prior quotes, allocate an array so we can test the length below
        plugin.quotes[event.channel][nickname] = [];
    }

    auto quotes = nickname in plugin.quotes[event.channel];

    if (!quotes.length)
    {
        return Senders.sendNoQuotesForNickname(plugin, event, nickname);
    }
    else if ((index < 0) || (index >= quotes.length))
    {
        return Senders.sendIndexOutOfRange(plugin, event, index, quotes.length);
    }

    immutable prefixSigns = cast(string)plugin.state.server.prefixchars.keys;
    immutable altered = removeWeeChatHead(slice.unquoted, nickname, prefixSigns).unquoted;
    immutable line = altered.length ? altered : slice;

    (*quotes)[index].line = line.strippedRight;
    saveQuotes(plugin);

    enum message = "Quote modified.";
    chan(plugin.state, event.channel, message);
}


// onCommandMergeQuotes
/++
    Merges all quotes of one user to that of another.
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
    import dialect.common : isValidNickname;
    import lu.string : SplitResults, plurality, splitInto, stripped;
    import std.format : format;

    version(TwitchSupport)
    {
        if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
        {
            enum message = "You cannot merge quotes on Twitch.";
            return chan(plugin.state, event.channel, message);
        }
    }

    void sendUsage()
    {
        enum pattern = "Usage: <b>%s%s<b> [source nickname] [target nickname]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel, message);
    }

    string slice = event.content.stripped;  // mutable
    string source;  // mutable
    string target;  // mutable
    immutable results = slice.splitInto(source, target);

    if (results != SplitResults.match) return sendUsage();

    if (!target.isValidNickname(plugin.state.server))
    {
        return Senders.sendInvalidNickname(plugin, event, target);
    }

    const channelQuotes = event.channel in plugin.quotes;
    if (!channelQuotes)
    {
        return Senders.sendNoQuotesForNickname(plugin, event, source);
    }

    const quotes = source in *channelQuotes;
    if (!quotes || !quotes.length)
    {
        return Senders.sendNoQuotesForNickname(plugin, event, source);
    }

    plugin.quotes[event.channel][target] ~= *quotes;
    plugin.quotes[event.channel].remove(source);
    saveQuotes(plugin);

    enum pattern = "<b>%d<b> %s merged.";
    immutable message = pattern.format(
        quotes.length,
        quotes.length.plurality("quote", "quotes"));
    chan(plugin.state, event.channel, message);
}


// onCommandDelQuote
/++
    Deletes a quote, given its index in the storage.
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
    import lu.string : SplitResults, splitInto, stripped;
    import std.algorithm.mutation : SwapStrategy, remove;
    import std.conv : ConvException, to;
    import std.format : format;

    immutable isTwitch = (plugin.state.server.daemon == IRCServer.Daemon.twitch);

    void sendUsage()
    {
        immutable pattern = isTwitch ?
            "Usage: %s%s [index]" :
            "Usage: <b>%s%s<b> [nickname] [index]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel, message);
    }

    string nickname;  // mutable
    string indexString;  // mutable

    if (isTwitch)
    {
        if (!event.content.length) return sendUsage();

        nickname = event.channel[1..$];
        indexString = event.content.stripped;
    }
    else /*if (!isTwitch)*/
    {
        string slice = event.content.stripped;  // mutable

        immutable results = slice.splitInto(nickname, indexString);
        if (results != SplitResults.match) return sendUsage();
    }

    auto channelQuotes = event.channel in plugin.quotes;  // mutable
    if (!channelQuotes)
    {
        return Senders.sendNoQuotesForNickname(plugin, event, nickname);
    }

    if (indexString == "*")
    {
        (*channelQuotes).remove(nickname);
        saveQuotes(plugin);

        enum pattern = "All quotes for <h>%s<h> removed.";
        immutable message = pattern.format(nickname);
        return chan(plugin.state, event.channel, message);
    }

    auto quotes = nickname in *channelQuotes;  // mutable
    if (!quotes || !quotes.length)
    {
        return Senders.sendNoQuotesForNickname(plugin, event, nickname);
    }

    ptrdiff_t index;

    try
    {
        import lu.string : beginsWith;
        if (indexString.beginsWith('#')) indexString = indexString[1..$];
        index = indexString.to!ptrdiff_t;
    }
    catch (ConvException _)
    {
        return Senders.sendIndexMustBePositiveNumber(plugin, event);
    }

    if ((index < 0) || (index >= quotes.length))
    {
        return Senders.sendIndexOutOfRange(plugin, event, index, quotes.length);
    }

    *quotes = (*quotes).remove!(SwapStrategy.stable)(index);
    saveQuotes(plugin);

    enum message = "Quote removed, indexes updated.";
    chan(plugin.state, event.channel, message);
}


// sendQuoteToChannel
/++
    Sends a [Quote] to a channel.

    Params:
        plugin = The current [QuotesPlugin].
        quote = The [Quote] to report.
        channelName = Name of the channel to send to.
        nickname = Nickname whose quote it is.
        index = Index of the quote in the local storage.
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

    string possibleDisplayName = nickname;  // mutable

    version(TwitchSupport)
    {
        if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
        {
            import kameloso.plugins.common.misc : nameOf;
            possibleDisplayName = nameOf(plugin, nickname);
        }
    }

    const when = SysTime.fromUnixTime(quote.timestamp);
    enum pattern = "%s (<h>%s<h> #%d %d-%02d-%02d)";
    immutable message = pattern.format(
        quote.line,
        possibleDisplayName,
        index,
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
    loadQuotes(plugin);
}


// Senders
/++
    Functions that send common brief snippets of text to the server.
 +/
struct Senders
{
private:
    import std.format : format;

    // sendIndexOutOfRange
    /++
        Called when a supplied quote index was out of range.

        Params:
            plugin = The current [QuotesPlugin].
            event = The original triggering [dialect.defs.IRCEvent|IRCEvent].
            indexGiven = The index given by the triggering user.
            upperBound = The actual upper bounds that `indexGiven` failed to fall within.
     +/
    static void sendIndexOutOfRange(
        QuotesPlugin plugin,
        const ref IRCEvent event,
        const ptrdiff_t indexGiven,
        const size_t upperBound)
    {
        enum pattern = "Index <b>#%d<b> out of range; valid is <b>[0..%d]<b> (inclusive).";
        immutable message = pattern.format(indexGiven, upperBound-1);
        chan(plugin.state, event.channel, message);
    }

    // sendInvalidNickname
    /++
        Called when a passed nickname contained invalid characters (or similar).

        Params:
            plugin = The current [QuotesPlugin].
            event = The original triggering [dialect.defs.IRCEvent|IRCEvent].
            nickname = The would-be nickname given by the triggering user.
     +/
    static void sendInvalidNickname(
        QuotesPlugin plugin,
        const ref IRCEvent event,
        const string nickname)
    {
        enum pattern = "Invalid nickname: <h>%s<h>";
        immutable message = pattern.format(nickname);
        chan(plugin.state, event.channel, message);
    }

    // sendNoQuotesForNickname
    /++
        Called when there were no quotes to be found for a given nickname.

        Params:
            plugin = The current [QuotesPlugin].
            event = The original triggering [dialect.defs.IRCEvent|IRCEvent].
            nickname = The nickname given by the triggering user.
     +/
    static void sendNoQuotesForNickname(
        QuotesPlugin plugin,
        const ref IRCEvent event,
        const string nickname)
    {
        string possibleDisplayName = nickname;  // mutable

        version(TwitchSupport)
        {
            if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
            {
                import kameloso.plugins.common.misc : nameOf;
                possibleDisplayName = nameOf(plugin, nickname);
            }
        }

        enum pattern = "No quotes on record for <h>%s<h>!";
        immutable message = pattern.format(possibleDisplayName);
        chan(plugin.state, event.channel, message);
    }

    // sendIndexMustBePositiveNumber
    /++
        Called when a non-integer or negative integer was given as index.

        Params:
            plugin = The current [QuotesPlugin].
            event = The original triggering [dialect.defs.IRCEvent|IRCEvent].
     +/
    static void sendIndexMustBePositiveNumber(
        QuotesPlugin plugin,
        const ref IRCEvent event)
    {
        enum message = "Index must be a positive number.";
        chan(plugin.state, event.channel, message);
    }
}


// getRandomQuote
/++
    Fethes a random [Quote] from an array of such.

    Params:
        quotes = Array of [Quote]s to get a random one from.
        nickname = The nickname whose quotes the array contains.
        index = `out` reference index of the quote selected, in the local storage.

    Returns:
        A [Quote], randomly selected.
 +/
auto getRandomQuote(
    const Quote[] quotes,
    const string nickname,
    out size_t index)
{
    import std.random : uniform;

    if (!quotes.length)
    {
        throw new NoQuotesFoundException(
            "No quotes found",
            nickname,
            __FILE__,
            __LINE__);
    }

    index = uniform(0, quotes.length);
    return quotes[index];
}


// getQuoteByIndexString
/++
    Fetches a quote given an index.

    Params:
        quotes = Array of [Quote]s to get a random one from.
        indexString = The index of the [Quote] to fetch,
            as a string, potentially with a leading octothorpe.
        index = `out` reference index of the quote selected, in the local storage.

    Returns:
        A [Quote], selected based on its index in the internal storage.
 +/
auto getQuoteByIndexString(
    const Quote[] quotes,
    /*const*/ string indexString,
    out size_t index)
{
    import lu.string : beginsWith;
    import std.conv : to;
    import std.random : uniform;

    indexString = indexString.beginsWith('#') ?
        indexString[1..$] :
        indexString;
    index = indexString.to!size_t;

    if (index >= quotes.length)
    {
        throw new QuoteIndexOutOfRangeException(
            "Quote index out of range",
            index,
            quotes.length,
            __FILE__,
            __LINE__);
    }

    return quotes[index];
}


// getQuoteBySearchTerms
/++
    Fetches a [Quote] whose line matches the passed search terms.

    Params:
        plugin = The current [QuotesPlugin].
        quotes = Array of [Quote]s to get a specific one from based on search terms.
        searchTermsCased = Search terms to apply to the `quotes` array, with letters
            in original casing.
        index = `out` reference index of the quote selected, in the local storage.

    Returns:
        A [Quote] whose line matches the passed search terms.
 +/
Quote getQuoteBySearchTerms(
    QuotesPlugin plugin,
    const Quote[] quotes,
    const string searchTermsCased,
    out size_t index)
{
    import lu.string : contains;
    import std.random : uniform;
    import std.uni : toLower;

    auto stripPunctuation(const string inputString)
    {
        import std.array : replace;

        return inputString
            .replace(".", " ")
            .replace("!", " ")
            .replace("?", " ")
            .replace(",", " ")
            .replace("-", " ")
            .replace("_", " ")
            .replace(`"`, " ")
            .replace("/", " ")
            .replace(";", " ")
            .replace("~", " ")
            .replace(":", " ")
            .replace("<", " ")
            .replace(">", " ")
            .replace("|", " ")
            .replace("'", string.init);
    }

    auto stripDoubleSpaces(const string inputString)
    {
        string output = inputString;  // mutable

        bool hasDoubleSpace = output.contains("  ");  // mutable

        while (hasDoubleSpace)
        {
            import std.array : replace;
            output = output.replace("  ", " ");
            hasDoubleSpace = output.contains("  ");
        }

        return output;
    }

    auto stripBoth(const string inputString)
    {
        return stripDoubleSpaces(stripPunctuation(inputString));
    }

    static struct SearchHit
    {
        size_t index;
        string line;
    }

    SearchHit[] searchHits;

    // Try with the search terms that were given first (lowercased)
    string[] flattenedQuotes;  // mutable

    foreach (immutable quote; quotes)
    {
        flattenedQuotes ~= stripDoubleSpaces(quote.line).toLower;
    }

    immutable searchTerms = stripDoubleSpaces(searchTermsCased).toLower;

    foreach (immutable i, immutable flattenedQuote; flattenedQuotes)
    {
        if (!flattenedQuote.contains(searchTerms)) continue;

        if (plugin.quotesSettings.alwaysPickFirstMatch)
        {
            index = i;
            return quotes[index];
        }
        else
        {
            searchHits ~= SearchHit(i, quotes[i].line);
        }
    }

    if (searchHits.length)
    {
        immutable randomHitsIndex = uniform(0, searchHits.length);
        index = searchHits[randomHitsIndex].index;
        return quotes[index];
    }

    // Nothing was found; simplify and try again.
    immutable strippedSearchTerms = stripBoth(searchTerms);
    searchHits = null;

    foreach (immutable i, immutable flattenedQuote; flattenedQuotes)
    {
        if (!stripBoth(flattenedQuote).contains(strippedSearchTerms)) continue;

        if (plugin.quotesSettings.alwaysPickFirstMatch)
        {
            index = i;
            return quotes[index];
        }
        else
        {
            searchHits ~= SearchHit(i, quotes[i].line);
        }
    }

    if (searchHits.length)
    {
        immutable randomHitsIndex = uniform(0, searchHits.length);
        index = searchHits[randomHitsIndex].index;
        return quotes[index];
    }
    else
    {
        throw new NoQuotesSearchMatchException(
            "No quotes found for given search terms",
            searchTermsCased);
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
    Loads quotes from disk into an associative array of [Quote]s.
 +/
void loadQuotes(QuotesPlugin plugin)
{
    import lu.json : JSONStorage;
    import std.json : JSONException;

    JSONStorage json;

    // No need to try-catch loading the JSON; trust in initResources
    json.load(plugin.quotesFile);
    plugin.quotes.clear();

    foreach (immutable channelName, channelQuotes; json.object)
    {
        foreach (immutable nickname, nicknameQuotesJSON; channelQuotes.object)
        {
            foreach (quoteJSON; nicknameQuotesJSON.array)
            {
                plugin.quotes[channelName][nickname] ~= Quote.fromJSON(quoteJSON);
            }
        }
        plugin.quotes[channelName].rehash();
    }

    plugin.quotes.rehash();
}


// saveQuotes
/++
    Saves quotes to disk in JSON file format.
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
        //auto channelQuotesJSON = channelName in json;

        foreach (immutable nickname, quotes; channelQuotes)
        {
            //(*channelQuotesJSON)[nickname] = null;  // Doesn't work with older compilers
            //(*channelQuotesJSON)[nickname].array = null;  // ditto
            json[channelName][nickname] = null;
            json[channelName][nickname].array = null;
            //auto nicknameQuotesJSON = nickname in *channelQuotesJSON;

            foreach (quote; quotes)
            {
                //nicknameQuotesJSON.array ~= quote.toJSON();  // ditto
                json[channelName][nickname].array ~= quote.toJSON();
            }
        }
    }

    json.save(plugin.quotesFile);
}


// NoQuotesFoundException
/++
    Exception, to be thrown when there were no quotes found for a given user.
 +/
final class NoQuotesFoundException : Exception
{
    /++
        Nickname whose quotes could not be found.
     +/
    string nickname;

    /++
        Constructor taking an extra nickname string.
     +/
    this(
        const string message,
        const string nickname,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        this.nickname = nickname;
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


// QuoteIndexOutOfRangeException
/++
    Exception, to be thrown when a given quote index was out of bounds.
 +/
final class QuoteIndexOutOfRangeException : Exception
{
    /++
        Given index (that ended up being out of range).
     +/
    ptrdiff_t indexGiven;

    /++
        Acutal upper bound.
     +/
    size_t upperBound;

    /++
        Creates a new [QuoteIndexOutOfRangeException], attaching a given index
        and an index upper bound.
     +/
    this(
        const string message,
        const ptrdiff_t indexGiven,
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


// NoQuotesSearchMatchException
/++
    Exception, to be thrown when given search terms failed to match any stored quotes.
 +/
final class NoQuotesSearchMatchException : Exception
{
    /++
        Given search terms string.
     +/
    string searchTerms;

    /++
        Creates a new [NoQuotesSearchMatchException], attaching a search terms string.
     +/
    this(
        const string message,
        const string searchTerms,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        this.searchTerms = searchTerms;
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
    import std.json : JSONException;

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

            json = scratchJSON;
        }
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
    loadQuotes(plugin);
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

    /++
        All Quotes plugin settings gathered.
     +/
    QuotesSettings quotesSettings;

    /++
        The in-memory JSON storage of all user quotes.

        It is in the JSON form of `Quote[][string][string]`, where the first key
        is a channel name and the second a nickname.
     +/
    Quote[][string][string] quotes;

    /++
        Filename of file to save the quotes to.
     +/
    @Resource string quotesFile = "quotes.json";

    mixin IRCPluginImpl;
}
