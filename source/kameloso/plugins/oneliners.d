/++
    The Oneliners plugin serves to provide custom commands, like `!vods`, `!youtube`,
    and any other static-reply `!command` (provided a prefix of "`!`").

    More advanced commands that do more than just repeat the preset lines of text
    will have to be written separately.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#oneliners
        [kameloso.plugins.common.core|plugins.common.core]
        [kameloso.plugins.common.misc|plugins.common.misc]
 +/
module kameloso.plugins.oneliners;

version(WithOnelinersPlugin):

private:

import kameloso.plugins;
import kameloso.plugins.common.core;
import kameloso.plugins.common.awareness : ChannelAwareness, TwitchAwareness, UserAwareness;
import kameloso.common : logger;
import kameloso.messaging;
import dialect.defs;


/// All Oneliner plugin runtime settings.
@Settings struct OnelinersSettings
{
    /// Toggle whether or not this plugin should do anything at all.
    @Enabler bool enabled = true;
}


/++
    Oneliner definition struct.
 +/
struct Oneliner
{
private:
    import std.json : JSONValue;

public:
    // Type
    /++
        The different kinds of [Oneliner]s. Either one that yields a
        [Type.random|random] response each time, or one that yields a
        [Type.ordered|ordered] one.
     +/
    enum Type
    {
        /++
            Responses should be yielded in a random (technically uniform) order.
         +/
        random = 0,

        /++
            Responses should be yielded in order, bumping an internal counter.
         +/
        ordered = 1,
    }

    // trigger
    /++
        Trigger word for this oneliner.
     +/
    string trigger;

    // type
    /++
        What type of [Oneliner] this is.
     +/
    Type type;

    // position
    /++
        The current position, kept to keep track of what response should be
        yielded next in the case of ordered oneliners.
     +/
    size_t position;

    // cooldown
    /++
        How many seconds must pass between two invocations of a oneliner.
        Introduces an element of hysteresis.
     +/
    uint cooldown;

    // lastTriggered
    /++
        UNIX timestamp of when the oneliner last fired.
     +/
    long lastTriggered;

    // responses
    /++
        Array of responses.
     +/
    string[] responses;

    // getResponse
    /++
        Yields a response from the [responses] array, depending on the [type]
        of this oneliner.

        Returns:
            A response string. If the [responses] array is empty, then an empty
            string is returned instead.
     +/
    auto getResponse()
    {
        return (type == Type.random) ?
            randomResponse() :
            nextOrderedResponse();
    }

    // nextOrderedResponse
    /++
        Yields an ordered response from the [responses] array. Which response
        is selected depends on the value of [position].

        Returns:
            A response string. If the [responses] array is empty, then an empty
            string is returned instead.
     +/
    auto nextOrderedResponse()
    in ((type == Type.ordered), "Tried to get an ordered reponse from a random Oneliner")
    {
        if (!responses.length) return string.init;

        size_t i = position++;  // mutable

        if (position >= responses.length)
        {
            position = 0;
        }

        return responses[i];
    }


    // randomResponse
    /++
        Yields a random response from the [responses] array.

        Returns:
            A response string. If the [responses] array is empty, then an empty
            string is returned instead.
     +/
    auto randomResponse() const
    //in ((type == Type.random), "Tried to get an random reponse from an ordered Oneliner")
    {
        import std.random : uniform;

        if (!responses.length) return string.init;

        return responses[uniform(0, responses.length)];
    }

    // toJSON
    /++
        Serialises this [Oneliner] into a [std.json.JSONValue|JSONValue].

        Returns:
            A [std.json.JSONValue|JSONValue] that describes this oneliner.
     +/
    auto toJSON() const
    {
        JSONValue json;
        json = null;
        json.object = null;

        json["trigger"] = JSONValue(this.trigger);
        json["type"] = JSONValue(cast(int)this.type);
        json["responses"] = JSONValue(this.responses);
        json["cooldown"] = JSONValue(this.cooldown);

        return json;
    }

    // fromJSON
    /++
        Deserialises a [Oneliner] from a [std.json.JSONValue|JSONValue].

        Params:
            json = [std.json.JSONValue|JSONValue] to deserialise.

        Returns:
            A new [Oneliner] with values loaded from the passed JSON.
     +/
    static auto fromJSON(const JSONValue json)
    {
        Oneliner oneliner;
        oneliner.trigger = json["trigger"].str;
        oneliner.type = (json["type"].integer == cast(int)Type.random) ?
            Type.random :
            Type.ordered;

        if (const cooldownJSON = "cooldown" in json)
        {
            oneliner.cooldown = cast(uint)cooldownJSON.integer;
        }

        foreach (const responseJSON; json["responses"].array)
        {
            oneliner.responses ~= responseJSON.str;
        }

        return oneliner;
    }
}


// onOneliner
/++
    Responds to oneliners.

    Responses are stored in [OnelinersPlugin.onelinersByChannel].
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.ignore)
    .channelPolicy(ChannelPolicy.home)
    .chainable(true)
)
void onOneliner(OnelinersPlugin plugin, const ref IRCEvent event)
{
    import kameloso.plugins.common.misc : nameOf;
    import lu.string : beginsWith, contains, nom;
    import std.array : replace;
    import std.conv : text;
    import std.format : format;
    import std.random : uniform;
    import std.typecons : Flag, No, Yes;
    import std.uni : toLower;

    if (!event.content.beginsWith(plugin.state.settings.prefix)) return;

    void sendEmptyOneliner(const string trigger)
    {
        import std.format : format;

        enum pattern = "(Empty oneliner; use <b>%soneliner add %s<b> to add lines.)";
        immutable message = pattern.format(plugin.state.settings.prefix, trigger);
        chan(plugin.state, event.channel, message);
    }

    string slice = event.content[plugin.state.settings.prefix.length..$];  // mutable
    if (!slice.length) return;

    auto channelOneliners = event.channel in plugin.onelinersByChannel;  // mustn't be const
    if (!channelOneliners) return;

    immutable trigger = slice.nom!(Yes.inherit)(' ').toLower;

    auto oneliner = trigger in *channelOneliners;  // mustn't be const
    if (!oneliner) return;

    if (!oneliner.responses.length) return sendEmptyOneliner(trigger);

    if (oneliner.cooldown > 0)
    {
        if ((oneliner.lastTriggered + oneliner.cooldown) > event.time)
        {
            // Too soon
            return;
        }
        else
        {
            // Record time last fired
            oneliner.lastTriggered = event.time;
        }
    }

    immutable line = oneliner.getResponse()
        .replace("$channel", event.channel)
        .replace("$senderNickname", event.sender.nickname)
        .replace("$sender", nameOf(event.sender))
        .replace("$botNickname", plugin.state.client.nickname)
        .replace("$bot", nameOf(plugin, plugin.state.client.nickname)) // likewise
        .replace("$streamerNickname", event.channel[1..$])  // Twitch
        .replace("$streamer", nameOf(plugin, event.channel[1..$]))  // Twitch
        .replace("$random", uniform(0, 100).text);
    immutable target = slice.beginsWith('@') ? slice[1..$] : slice;

    enum atPattern = "@%s %s";
    immutable message = target.length ?
        atPattern.format(plugin.nameOf(target), line) :
        line;
    chan(plugin.state, event.channel, message);
}


// onCommandModifyOneliner
/++
    Adds, removes or modifies a oneliner, then saves the list to disk.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.operator)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("oneliner")
            .policy(PrefixPolicy.prefixed)
            .description("Manages oneliners.")
            .addSyntax("$command new [trigger] [type] [optional cooldown]")
            .addSyntax("$command add [trigger] [text]")
            .addSyntax("$command edit [trigger] [position] [new text]")
            .addSyntax("$command insert [trigger] [position] [text]")
            .addSyntax("$command del [trigger] [optional position]")
            .addSyntax("$command list")
    )
    .addCommand(
        IRCEventHandler.Command()
            .word("command")
            .policy(PrefixPolicy.prefixed)
            .hidden(true)
    )
)
void onCommandModifyOneliner(OnelinersPlugin plugin, const ref IRCEvent event)
{
    import lu.string : SplitResults, contains, nom, splitInto, stripped;
    import std.conv : ConvException, to;
    import std.format : format;
    import std.typecons : Flag, No, Yes;
    import std.uni : toLower;

    void sendUsage()
    {
        enum pattern = "Usage: <b>%s%s<b> [new|insert|add|edit|del|list] ...";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux[0]);
        chan(plugin.state, event.channel, message);
    }

    if (!event.content.length) return sendUsage();

    string slice = event.content.stripped;  // mutable
    immutable verb = slice.nom!(Yes.inherit, Yes.decode)(' ');

    switch (verb)
    {
    case "new":
        return handleNewOneliner(plugin, event, slice);

    case "insert":
    case "add":
    case "edit":
        return handleAddToOneliner(plugin, event, slice, verb);

    case "del":
    case "remove":
        return handleDelFromOneliner(plugin, event, slice);

    case "list":
        return plugin.listCommands(event.channel);

    default:
        return sendUsage();
    }
}


// handleNewOneliner
/++
    Creates a new and empty oneliner.

    Params:
        plugin = The current [OnelinersPlugin].
        event = The [dialect.defs.IRCEvent|IRCEvent] that requested the creation.
        slice = Relevant slice of the original request string.
 +/
void handleNewOneliner(
    OnelinersPlugin plugin,
    const /*ref*/ IRCEvent event,
    /*const*/ string slice)
{
    import kameloso.thread : ThreadMessage;
    import lu.string : SplitResults, splitInto;
    import std.concurrency : send;
    import std.format : format;
    import std.uni : toLower;

    // copy/pasted
    string stripPrefix(const string trigger)
    {
        import lu.string : beginsWith;
        return trigger.beginsWith(plugin.state.settings.prefix) ?
            trigger[plugin.state.settings.prefix.length..$] :
            trigger;
    }

    void sendNewUsage()
    {
        enum pattern = "Usage: <b>%s%s new<b> [trigger] [type] [optional cooldown]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux[0]);
        chan(plugin.state, event.channel, message);
    }

    void sendMustBeRandomOrOrdered()
    {
        enum message = "Oneliner type must be one of <b>random<b> or <b>ordered<b>";
        chan(plugin.state, event.channel, message);
    }

    void sendCooldownMustBeValidPositiveDurationString()
    {
        enum message = "Oneliner cooldown must be in the hour-minute-seconds form of <b>*h*m*s<b> " ~
            "and may not have negative values.";
        chan(plugin.state, event.channel, message);
    }

    string trigger;
    string typestring;
    string cooldownString;
    cast(void)slice.splitInto(trigger, typestring, cooldownString);
    if (!typestring.length) return sendNewUsage();

    Oneliner.Type type;

    switch (typestring)
    {
    case "random":
    case "rnd":
    case "rng":
        type = Oneliner.Type.random;
        break;

    case "ordered":
    case "order":
    case "sequential":
    case "seq":
    case "sequence":
        type = Oneliner.Type.ordered;
        break;

    default:
        return sendMustBeRandomOrOrdered();
    }

    trigger = stripPrefix(trigger).toLower;
    int cooldownSeconds = Oneliner.init.cooldown;

    if (cooldownString.length)
    {
        import kameloso.time : DurationStringException, abbreviatedDuration;

        try
        {
            cooldownSeconds = cast(int)abbreviatedDuration(cooldownString).total!"seconds";
            if (cooldownSeconds < 0) return sendCooldownMustBeValidPositiveDurationString();
        }
        catch (DurationStringException _)
        {
            return sendCooldownMustBeValidPositiveDurationString();
        }
    }

    /+
        We need to check both hardcoded and soft channel-specific commands
        for conflicts.
     +/
    bool triggerConflicts(const IRCPlugin.CommandMetadata[string][string] aa)
    {
        foreach (immutable pluginName, pluginCommands; aa)
        {
            if (!pluginCommands.length || (pluginName == "oneliners")) continue;

            foreach (/*mutable*/ word, command; pluginCommands)
            {
                word = word.toLower;

                if (word == trigger)
                {
                    enum pattern = `Oneliner word "<b>%s<b>" conflicts with a command of the <b>%s<b> plugin.`;
                    immutable message = pattern.format(trigger, pluginName);
                    chan(plugin.state, event.channel, message);
                    return true;
                }
            }
        }

        return false;
    }

    void channelSpecificDg(IRCPlugin.CommandMetadata[string][string] channelSpecificAA)
    {
        if (triggerConflicts(channelSpecificAA)) return;

        Oneliner oneliner;
        oneliner.trigger = trigger;
        oneliner.type = type;
        oneliner.cooldown = cooldownSeconds;
        //oneliner.responses ~= slice;

        plugin.onelinersByChannel[event.channel][trigger] = oneliner;
        saveResourceToDisk(plugin.onelinersByChannel, plugin.onelinerFile);

        enum pattern = "Oneliner <b>%s%s<b> created! Use <b>%1$s%3$s add<b> to add lines.";
        immutable message = pattern.format(plugin.state.settings.prefix, trigger, event.aux[0]);
        chan(plugin.state, event.channel, message);
    }

    void dg(IRCPlugin.CommandMetadata[string][string] aa)
    {
        if (triggerConflicts(aa)) return;

        // Arcane message used to minimise template instantiations and lower memory requirements
        plugin.state.mainThread.send(
            ThreadMessage.HandleDelegates(),
            cast(shared(void delegate(IRCPlugin.CommandMetadata[string][string]) @system))&channelSpecificDg,
            cast(shared(void delegate(string, string, string) @system))null,
            cast(shared(void delegate(bool) @system))null,
            event.channel);
    }

    // As above
    plugin.state.mainThread.send(
        ThreadMessage.HandleDelegates(),
        cast(shared(void delegate(IRCPlugin.CommandMetadata[string][string]) @system))&dg,
        cast(shared(void delegate(string, string, string) @system))null,
        cast(shared(void delegate(bool) @system))null,
        string.init);
}


// handleAddToOneliner
/++
    Adds or inserts a line into a oneliner, or modifies an existing line.

    Params:
        plugin = The current [OnelinersPlugin].
        event = The [dialect.defs.IRCEvent|IRCEvent] that requested the addition (or modification).
        slice = Relevant slice of the original request string.
        verb = The string verb of what action was requested; "add", "insert" or "edit".
 +/
void handleAddToOneliner(
    OnelinersPlugin plugin,
    const ref IRCEvent event,
    /*const*/ string slice,
    const string verb)
{
    import lu.string : SplitResults, splitInto;
    import std.conv : ConvException, to;
    import std.format : format;
    import std.uni : toLower;

    void sendInsertEditUsage(const string verb)
    {
        immutable pattern = (verb == "insert") ?
            "Usage: <b>%s%s insert<b> [trigger] [position] [text]" :
            "Usage: <b>%s%s edit<b> [trigger] [position] [new text]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux[0]);
        chan(plugin.state, event.channel, message);
    }

    void sendAddUsage()
    {
        enum pattern = "Usage: <b>%s%s add<b> [trigger] [text]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux[0]);
        chan(plugin.state, event.channel, message);
    }

    void sendNoSuchOneliner(const string trigger)
    {
        // Sent from more than one place so might as well make it a nested function
        enum pattern = "No such oneliner: <b>%s%s<b>";
        immutable message = pattern.format(plugin.state.settings.prefix, trigger);
        chan(plugin.state, event.channel, message);
    }

    void sendPositionNotPositive()
    {
        enum message = "Position passed is not a positive number.";
        chan(plugin.state, event.channel, message);
    }

    void sendPositionNaN()
    {
        enum message = "Position passed is not a number.";
        chan(plugin.state, event.channel, message);
    }

    // copy/pasted
    string stripPrefix(const string trigger)
    {
        import lu.string : beginsWith;
        return trigger.beginsWith(plugin.state.settings.prefix) ?
            trigger[plugin.state.settings.prefix.length..$] :
            trigger;
    }

    enum Action
    {
        insertAtPosition,
        appendToEnd,
        editExisting,
    }

    void insert(
        /*const*/ string trigger,
        const string line,
        const Action action,
        const ptrdiff_t pos = 0)
    {
        trigger = stripPrefix(trigger).toLower;

        auto channelOneliners = event.channel in plugin.onelinersByChannel;
        if (!channelOneliners) return sendNoSuchOneliner(trigger);

        auto oneliner = trigger in *channelOneliners;
        if (!oneliner) return sendNoSuchOneliner(trigger);

        if ((action != Action.appendToEnd) && (pos >= oneliner.responses.length))
        {
            // Send the error message here so we can include the range
            enum pattern = "Oneliner response index out of bounds. (0-<b>%d<b>)";
            immutable message = pattern.format(pos);
            chan(plugin.state, event.channel, message);
            throw new Exception("Oneliner response index out of bounds.");
        }

        with (Action)
        final switch (action)
        {
        case insertAtPosition:
            import std.array : insertInPlace;

            oneliner.responses.insertInPlace(pos, line);

            if (oneliner.type == Oneliner.Type.ordered)
            {
                // Reset ordered position to 0 on insertions
                oneliner.position = 0;
            }

            enum message = "Oneliner line inserted.";
            chan(plugin.state, event.channel, message);
            break;

        case appendToEnd:
            oneliner.responses ~= line;
            enum message = "Oneliner line added.";
            chan(plugin.state, event.channel, message);
            break;

        case editExisting:
            oneliner.responses[pos] = line;
            enum message = "Oneliner line modified.";
            chan(plugin.state, event.channel, message);
            break;
        }

        saveResourceToDisk(plugin.onelinersByChannel, plugin.onelinerFile);
    }

    if ((verb == "insert") || (verb == "edit"))
    {
        string trigger;
        string posString;
        ptrdiff_t pos;

        immutable results = slice.splitInto(trigger, posString);
        if (results != SplitResults.overrun)
        {
            return sendInsertEditUsage(verb);
        }

        try
        {
            pos = posString.to!ptrdiff_t;

            if (pos < 0)
            {
                return sendPositionNaN();
            }
        }
        catch (ConvException _)
        {
            return sendPositionNaN();
        }

        try
        {
            if (verb == "insert")
            {
                insert(trigger, slice, Action.insertAtPosition, pos);
            }
            else /*if (verb == "edit")*/
            {
                insert(trigger, slice, Action.editExisting, pos);
            }
        }
        catch (Exception _)
        {
            // Already sent error message
            //chan(plugin.state, event.channel, e.msg);
            return;
        }
    }
    else if (verb == "add")
    {
        string trigger;

        immutable results = slice.splitInto(trigger);
        if (results != SplitResults.overrun)
        {
            return sendAddUsage();
        }

        try
        {
            return insert(trigger, slice, Action.appendToEnd);
        }
        catch (Exception _)
        {
            // Already sent error message
            //chan(plugin.state, event.channel, e.msg);
            return;
        }
    }
    else
    {
        assert(0, "impossible case in onCommandOneliner switch");
    }
}


// handleDelFromOneliner
/++
    Deletes a oneliner entirely, alternatively a line from one.

    Params:
        plugin = The current [OnelinersPlugin].
        event = The [dialect.defs.IRCEvent|IRCEvent] that requested the deletion.
        slice = Relevant slice of the original request string.
 +/
void handleDelFromOneliner(
    OnelinersPlugin plugin,
    const ref IRCEvent event,
    /*const*/ string slice)
{
    import lu.string : nom;
    import std.conv : ConvException, to;
    import std.format : format;
    import std.typecons : Flag, No, Yes;
    import std.uni : toLower;

    void sendDelUsage()
    {
        enum pattern = "Usage: <b>%s%s del<b> [trigger] [optional position]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux[0]);
        chan(plugin.state, event.channel, message);
    }

    void sendNoSuchOneliner(const string trigger)
    {
        // Sent from more than one place so might as well make it a nested function
        enum pattern = "No such oneliner: <b>%s%s<b>";
        immutable message = pattern.format(plugin.state.settings.prefix, trigger);
        chan(plugin.state, event.channel, message);
    }

    void sendLineRemoved(const string trigger, const size_t pos)
    {
        enum pattern = "Oneliner response <b>%s<b>#%d removed.";
        immutable message = pattern.format(trigger, pos);
        chan(plugin.state, event.channel, message);
    }

    void sendRemoved(const string trigger)
    {
        enum pattern = "Oneliner <b>%s%s<b> removed.";
        immutable message = pattern.format(plugin.state.settings.prefix, trigger);
        chan(plugin.state, event.channel, message);
    }

    // copy/pasted
    string stripPrefix(const string trigger)
    {
        import lu.string : beginsWith;
        return trigger.beginsWith(plugin.state.settings.prefix) ?
            trigger[plugin.state.settings.prefix.length..$] :
            trigger;
    }

    if (!slice.length) return sendDelUsage();

    immutable trigger = stripPrefix(slice.nom!(Yes.inherit)(' ')).toLower;

    auto channelOneliners = event.channel in plugin.onelinersByChannel;
    if (!channelOneliners) return sendNoSuchOneliner(trigger);

    auto oneliner = trigger in *channelOneliners;
    if (!oneliner) return sendNoSuchOneliner(trigger);

    if (slice.length)
    {
        if (!oneliner.responses.length)
        {
            enum pattern = "Oneliner <b>%s<b> is empty and has no responses to remove.";
            immutable message = pattern.format(trigger);
            return chan(plugin.state, event.channel, message);
        }

        try
        {
            import std.algorithm.mutation : SwapStrategy, remove;

            immutable pos = slice.to!size_t;

            if (pos >= oneliner.responses.length)
            {
                enum pattern = "Oneliner response index out of bounds. (0-<b>%d<b>)";
                immutable message = pattern.format(pos);
                return chan(plugin.state, event.channel, message);
            }

            oneliner.responses = oneliner.responses.remove!(SwapStrategy.stable)(pos);
            sendLineRemoved(trigger, pos);

            if (oneliner.type == Oneliner.Type.ordered)
            {
                // Reset ordered position to 0 on removals
                oneliner.position = 0;
            }
        }
        catch (ConvException _)
        {
            return sendDelUsage();
        }
    }
    else
    {
        (*channelOneliners).remove(trigger);
        sendRemoved(trigger);
    }

    saveResourceToDisk(plugin.onelinersByChannel, plugin.onelinerFile);
}


// onCommandCommands
/++
    Sends a list of the current oneliners to the channel.

    Merely calls [listCommands].
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.anyone)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("commands")
            .policy(PrefixPolicy.prefixed)
            .description("Lists all available oneliners.")
    )
)
void onCommandCommands(OnelinersPlugin plugin, const ref IRCEvent event)
{
    return plugin.listCommands(event.channel);
}


// listCommands
/++
    Lists the current commands to the passed channel.

    Params:
        plugin = The current [OnelinersPlugin].
        channelName = Name of the channel to send the list to.
 +/
void listCommands(OnelinersPlugin plugin, const string channelName)
{
    import std.format : format;

    auto channelOneliners = channelName in plugin.onelinersByChannel;

    if (channelOneliners && channelOneliners.length)
    {
        immutable rtPattern = "Available commands: %-(<b>" ~ plugin.state.settings.prefix ~ "%s<b>, %)<b>";
        immutable message = rtPattern.format(channelOneliners.byKey);
        chan(plugin.state, channelName, message);
    }
    else
    {
        enum message = "There are no commands available right now.";
        chan(plugin.state, channelName, message);
    }
}


// onWelcome
/++
    Populate the oneliners array after we have successfully logged onto the server.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WELCOME)
)
void onWelcome(OnelinersPlugin plugin)
{
    plugin.reload();
}


// reload
/++
    Reloads oneliners from disk.
 +/
void reload(OnelinersPlugin plugin)
{
    import lu.json : JSONStorage;

    JSONStorage allOnelinersJSON;
    allOnelinersJSON.load(plugin.onelinerFile);

    foreach (immutable channelName, const channelOnelinersJSON; allOnelinersJSON.object)
    {
        foreach (immutable trigger, const onelinerJSON; channelOnelinersJSON.object)
        {
            import std.json : JSONException;

            try
            {
                plugin.onelinersByChannel[channelName][trigger] = Oneliner.fromJSON(onelinerJSON);
            }
            catch (JSONException _)
            {
                enum pattern = "Failed to load oneliner \"<l>%s</>\"; <l>%s</> is outdated or corrupt.";
                logger.errorf(pattern, trigger, plugin.onelinerFile);
            }
        }
    }

    plugin.onelinersByChannel = plugin.onelinersByChannel.rehash();
}


// onGlobalUserstate
/++
    On Twitch, catch the bot's display name on
    [dialect.defs.IRCEvent.Type.GLOBALUSERSTATE|GLOBALUSERSTATE], early after connecting.

    This lets us replace `$bot` in oneliners with our display name.
 +/
version(TwitchSupport)
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.GLOBALUSERSTATE)
)
void onGlobalUserstate(OnelinersPlugin plugin, const ref IRCEvent event)
{
    import kameloso.plugins.common.misc : catchUser;
    plugin.catchUser(event.target);
}


// saveResourceToDisk
/++
    Saves the passed resource to disk, but in JSON format.

    This is used with the associative arrays for oneliners.

    Example:
    ---
    plugin.oneliners["#channel"]["asdf"].responses ~= "asdf yourself";
    plugin.oneliners["#channel"]["fdsa"].responses ~= "hirr";

    saveResource(plugin.onelinersByChannel, plugin.onelinerFile);
    ---

    Params:
        aa = The JSON-convertible resource to save.
        filename = Filename of the file to write to.
 +/
void saveResourceToDisk(const Oneliner[string][string] aa, const string filename)
in (filename.length, "Tried to save resources to an empty filename string")
{
    import std.json : JSONValue;
    import std.stdio : File, writeln;

    JSONValue json;
    json = null;
    json.object = null;

    foreach (immutable channelName, const channelOneliners; aa)
    {
        json[channelName] = null;
        json[channelName].object = null;

        foreach (immutable trigger, const oneliner; channelOneliners)
        {
            json[channelName][trigger] = null;
            json[channelName][trigger].object = null;
            json[channelName][trigger] = oneliner.toJSON();
        }
    }

    File(filename, "w").writeln(json.toPrettyString);
}


// initResources
/++
    Reads and writes the file of oneliners and administrators to disk, ensuring
    that they're there and properly formatted.
 +/
void initResources(OnelinersPlugin plugin)
{
    import lu.json : JSONStorage;
    import std.json : JSONException;

    JSONStorage onelinerJSON;

    try
    {
        onelinerJSON.load(plugin.onelinerFile);
    }
    catch (JSONException e)
    {
        import kameloso.plugins.common.misc : IRCPluginInitialisationException;

        version(PrintStacktraces) logger.trace(e);
        throw new IRCPluginInitialisationException(
            "Oneliner file is malformed",
            plugin.name,
            plugin.onelinerFile,
            __FILE__,
            __LINE__);
    }

    // Let other Exceptions pass.

    onelinerJSON.save(plugin.onelinerFile);
}


mixin UserAwareness;
mixin ChannelAwareness;
mixin PluginRegistration!OnelinersPlugin;

version(TwitchSupport)
{
    mixin TwitchAwareness;
}

public:


// OnelinersPlugin
/++
    The Oneliners plugin serves to listen to custom commands that can be added,
    modified and removed at runtime. Think `!info`.
 +/
final class OnelinersPlugin : IRCPlugin
{
private:
    /// All Oneliners plugin settings.
    OnelinersSettings onelinersSettings;

    /// Associative array of oneliners; [Oneliner] array, keyed by trigger, keyed by channel.
    Oneliner[string][string] onelinersByChannel;

    /// Filename of file with oneliners.
    @Resource string onelinerFile = "oneliners.json";

    // channelSpecificCommands
    /++
        Compile a list of our runtime oneliner commands.

        Params:
            channelName = Name of channel whose commands we want to summarise.

        Returns:
            An associative array of
            [kameloso.plugins.common.core.IRCPlugin.CommandMetadata|IRCPlugin.CommandMetadata]s,
            one for each oneliner active in the passed channel.
     +/
    override public IRCPlugin.CommandMetadata[string] channelSpecificCommands(const string channelName) @system
    {
        IRCPlugin.CommandMetadata[string] aa;

        const channelOneliners = channelName in onelinersByChannel;
        if (!channelOneliners) return aa;

        foreach (immutable trigger, const _; *channelOneliners)
        {
            IRCPlugin.CommandMetadata metadata;
            metadata.description = "A oneliner";
            aa[trigger] = metadata;
        }

        return aa;
    }

    mixin IRCPluginImpl;
}
