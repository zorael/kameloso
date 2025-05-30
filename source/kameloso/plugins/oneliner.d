/++
    The Oneliner plugin serves to provide custom commands, like `!vods`, `!youtube`,
    and any other static-reply `!command` (provided a prefix of "`!`").

    More advanced commands that do more than just repeat the preset lines of text
    will have to be written separately.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#oneliners,
        [kameloso.plugins],
        [kameloso.plugins.common]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.oneliner;

version(WithOnelinerPlugin):

private:

import kameloso.plugins;
import kameloso.plugins.common.mixins.awareness;
import kameloso.common : logger;
import kameloso.messaging;
import dialect.defs;


// OnelinerSettings
/++
    All Oneliner plugin runtime settings.
 +/
@Settings struct OnelinerSettings
{
    /++
        Toggle whether or not this plugin should do anything at all.
     +/
    @Enabler bool enabled = true;

    /++
        Send oneliners as Twitch replies to the triggering message.

        Only affects Twitch connections.
     +/
    bool onelinersAsTwitchReplies = false;
}


/++
    Oneliner definition struct.
 +/
struct Oneliner
{
    /++
        JSON schema.
     +/
    static struct JSONSchema
    {
        private import asdf.serialization : serdeKeys, serdeOptional;

        string trigger;  ///
        int type;  ///
        string[] responses;  ///

        @serdeOptional uint cooldown;  ///
        @serdeKeys("alias") string alias_;  ///

        /++
            Returns a [std.json.JSONValue|JSONValue] representation of this [JSONSchema].
         +/
        auto asJSONValue() const
        {
            import std.json : JSONValue;

            JSONValue json;
            json["trigger"] = this.trigger;
            json["alias"] = this.alias_;
            json["type"] = cast(int) this.type;
            json["cooldown"] = this.cooldown;
            json["responses"] = this.responses.dup;
            return json;
        }
    }

    // OnelinerType
    /++
        The different kinds of [Oneliner]s. Either one that yields a
        [OnelinerType.random|random] response each time, or one that yields a
        [OnelinerType.ordered|ordered] one.
     +/
    enum OnelinerType
    {
        /++
            Responses should be yielded in a random (technically uniform) order.
         +/
        random = 0,

        /++
            Responses should be yielded in order, bumping an internal counter.
         +/
        ordered = 1,

        /++
            Oneliner is an alias and does not have lines itself.
         +/
        alias_ = 2,
    }

    // trigger
    /++
        Trigger word for this oneliner.
     +/
    string trigger;

    // alias_
    /++
        Alias of another oneliner.
     +/
    string alias_;

    // type
    /++
        What type of [Oneliner] this is.
     +/
    OnelinerType type;

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

    /++
        Constructor.
     +/
    this(const JSONSchema schema)
    {
        this.trigger = schema.trigger;
        this.alias_ = schema.alias_;
        this.type = cast(OnelinerType) schema.type;
        this.cooldown = schema.cooldown;
        this.responses = schema.responses.dup;
    }

    /++
        Returns a [JSONSchema] representation of this oneliner.
     +/
    auto asSchema() const
    {
        JSONSchema schema;

        schema.trigger = this.trigger;
        schema.alias_ = this.alias_;
        schema.type = cast(int) this.type;
        schema.cooldown = this.cooldown;
        schema.responses = this.responses.dup;

        return schema;
    }

    // getResponse
    /++
        Yields a response from the [responses] array, depending on the [type]
        of this oneliner.

        Returns:
            A response string. If the [responses] array is empty, then an empty
            string is returned instead.
     +/
    auto getResponse() /*const*/
    {
        return (type == OnelinerType.random) ?
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
    auto nextOrderedResponse() /*const*/
    in ((type == OnelinerType.ordered), "Tried to get an ordered response from a random Oneliner")
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
    //in ((type == OnelinerType.random), "Tried to get an random response from an ordered Oneliner")
    {
        import std.random : uniform;

        return responses.length ?
            responses[uniform(0, responses.length)] :
            string.init;
    }

    // resolveOnelinerTypestring
    /++
        Resolves a string to a [OnelinerType].

        Don't resolve [OnelinerType.alias_].

        Params:
            input = String to resolve.
            type = [OnelinerType] to store the resolved type in.

        Returns:
            Whether or not the string resolved to a [OnelinerType].
     +/
    static auto resolveOnelinerTypestring(
        const string input,
        out OnelinerType type)
    {
        switch (input)
        {
        case "random":
        case "rnd":
        case "rng":
            type = OnelinerType.random;
            return true;

        case "ordered":
        case "order":
        case "sequential":
        case "seq":
        case "sequence":
            type = OnelinerType.ordered;
            return true;

        /*case "alias":
            type = OnelinerType.alias_;
            return true;*/

        default:
            return false;
        }
    }

    // stripPrefix
    /++
        Strips the prefix from a trigger word.

        Params:
            trigger = Trigger word to strip the prefix from.
            prefix = Prefix to strip.

        Returns:
            The trigger word with the prefix stripped, or the original trigger
            word if it didn't start with the prefix.
     +/
    static auto stripPrefix(const string trigger, const string prefix)
    {
        import std.algorithm.searching : startsWith;
        return trigger.startsWith(prefix) ?
            trigger[prefix.length..$] :
            trigger;
    }
}


// onOneliner
/++
    Responds to oneliners.

    Responses are stored in [OnelinerPlugin.onelinersByChannel].
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.ignore)
    .channelPolicy(ChannelPolicy.home)
    .chainable(true)
)
void onOneliner(OnelinerPlugin plugin, const IRCEvent event)
{
    import kameloso.plugins.common : nameOf;
    import kameloso.string : replaceRandom;
    import lu.string : advancePast, splitWithQuotes;
    import std.algorithm.searching : startsWith;
    import std.array : replace;
    import std.conv : text, to;
    import std.uni : toLower;

    mixin(memoryCorruptionCheck);

    if (event.sender.class_ == IRCUser.Class.blacklist) return;
    if (!event.content.startsWith(plugin.state.coreSettings.prefix)) return;

    void sendEmptyOneliner(const string trigger)
    {
        import std.format : format;

        // Only operators and above can add to oneliners
        if (event.sender.class_ < IRCUser.Class.operator) return;

        enum pattern = "(Empty oneliner; use <b>%soneliner add %s<b> to add lines.)";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, trigger);
        sendOneliner(plugin, event, message);
    }

    string slice = event.content[plugin.state.coreSettings.prefix.length..$];  // mutable
    if (!slice.length) return;

    auto channelOneliners = event.channel.name in plugin.onelinersByChannel;  // mustn't be const
    if (!channelOneliners) return;

    immutable triggerCased = slice.advancePast(' ', inherit: true);  // mutable
    immutable trigger = triggerCased.toLower();

    auto oneliner = trigger in *channelOneliners;  // mustn't be const
    if (!oneliner) return;

    if (oneliner.type == Oneliner.OnelinerType.alias_)
    {
        // Alias of a different oneliner
        oneliner = oneliner.alias_ in *channelOneliners;

        if (!oneliner)
        {
            // Dangling alias, should not be
            (*channelOneliners).remove(trigger);
            return;
        }
    }

    if (!oneliner.responses.length) return sendEmptyOneliner(oneliner.trigger);

    if (oneliner.cooldown > 0)
    {
        if ((oneliner.lastTriggered + oneliner.cooldown) > event.time)
        {
            // Too soon
            return;
        }
        else
        {
            // Record time last fired and drop down
            oneliner.lastTriggered = event.time;
        }
    }

    // Gracefully deal with oneliners that have been given empty lines.
    immutable response = oneliner.getResponse();
    if (!response.length) return;

    immutable args = slice.splitWithQuotes();

    string line = response  // mutable
        .replace("$channel", event.channel.name)
        .replace("$sender", nameOf(event.sender))
        .replace("$bot", nameOf(plugin, plugin.state.client.nickname))
        .replace("$senderNickname", event.sender.nickname)
        .replace("$botNickname", plugin.state.client.nickname)
        .replace("$args", slice)
        .replace("$arg0", triggerCased)
        .replace("$arg1name", (args.length >= 1) ? nameOf(plugin, args[0]) : string.init)
        .replace("$arg2name", (args.length >= 2) ? nameOf(plugin, args[1]) : string.init)
        .replace("$arg3name", (args.length >= 3) ? nameOf(plugin, args[2]) : string.init)
        .replace("$arg4name", (args.length >= 4) ? nameOf(plugin, args[3]) : string.init)
        .replace("$arg5name", (args.length >= 5) ? nameOf(plugin, args[4]) : string.init)
        .replace("$arg6name", (args.length >= 6) ? nameOf(plugin, args[5]) : string.init)
        .replace("$arg7name", (args.length >= 7) ? nameOf(plugin, args[6]) : string.init)
        .replace("$arg8name", (args.length >= 8) ? nameOf(plugin, args[7]) : string.init)
        .replace("$arg9name", (args.length >= 9) ? nameOf(plugin, args[8]) : string.init)
        .replace("$arg1", (args.length >= 1) ? args[0] : string.init)
        .replace("$arg2", (args.length >= 2) ? args[1] : string.init)
        .replace("$arg3", (args.length >= 3) ? args[2] : string.init)
        .replace("$arg4", (args.length >= 4) ? args[3] : string.init)
        .replace("$arg5", (args.length >= 5) ? args[4] : string.init)
        .replace("$arg6", (args.length >= 6) ? args[5] : string.init)
        .replace("$arg7", (args.length >= 7) ? args[6] : string.init)
        .replace("$arg8", (args.length >= 8) ? args[7] : string.init)
        .replace("$arg9", (args.length >= 9) ? args[8] : string.init)
        .replaceRandom();

    version(TwitchSupport)
    {
        if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
        {
            line = line
                .replace("$streamer", nameOf(plugin, event.channel.name[1..$]))
                .replace("$streamerAccount", event.channel.name[1..$]);
        }
    }

    immutable target = slice.startsWith('@') ? slice[1..$] : slice;
    immutable message = target.length ?
        text('@', nameOf(plugin, target), ' ', line) :
        line;

    sendOneliner(plugin, event, message);
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
            .addSyntax("$command alias [trigger] [existing trigger to alias]")
            .addSyntax("$command modify [trigger] [type] [optional cooldown]")
            .addSyntax("$command edit [trigger] [position] [new text]")
            .addSyntax("$command insert [trigger] [position] [text]")
            .addSyntax("$command del [trigger] [optional position]")
            .addSyntax("$command list [optional trigger]")
    )
    .addCommand(
        IRCEventHandler.Command()
            .word("command")
            .policy(PrefixPolicy.prefixed)
            .hidden(true)
    )
)
void onCommandModifyOneliner(OnelinerPlugin plugin, const IRCEvent event)
{
    import lu.string : advancePast, stripped;
    import std.uni : toLower;

    mixin(memoryCorruptionCheck);

    void sendUsage()
    {
        import std.format : format;

        enum pattern = "Usage: <b>%s%s<b> [new|insert|add|alias|modify|edit|del|list] ...";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel.name, message);
    }

    if (!event.content.length) return sendUsage();

    string slice = event.content.stripped;  // mutable
    immutable verb = slice.advancePast(' ', inherit: true);

    switch (verb)
    {
    case "new":
        return handleNewOneliner(plugin, event, slice);

    case "insert":
    case "add":
    case "edit":
        return handleAddToOneliner(plugin, event, slice, verb);

    case "modify":
    case "mod":
        return handleModifyOneliner(plugin, event, slice);

    case "del":
    case "remove":
        return handleDelFromOneliner(plugin, event, slice);

    case "alias":
        return handleAliasOneliner(plugin, event, slice);

    case "list":
        return listCommands(plugin, event, includeAliases: true, slice);

    default:
        return sendUsage();
    }
}


// handleNewOneliner
/++
    Creates a new and empty oneliner.

    Params:
        plugin = The current [OnelinerPlugin].
        event = The [dialect.defs.IRCEvent|IRCEvent] that requested the creation.
        slice = Relevant slice of the original request string.
 +/
void handleNewOneliner(
    OnelinerPlugin plugin,
    const IRCEvent event,
    /*const*/ string slice)
{
    import kameloso.thread : CarryingFiber;
    import lu.string : SplitResults, splitInto;
    import std.format : format;
    import std.typecons : Tuple;
    import std.uni : toLower;
    import core.thread.fiber : Fiber;

    void sendNewUsage()
    {
        enum pattern = "Usage: <b>%s%s new<b> [trigger] [type] [optional cooldown]";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel.name, message);
    }

    void sendMustBeRandomOrOrdered()
    {
        enum message = "Oneliner type must be one of <b>random<b> or <b>ordered<b>";
        chan(plugin.state, event.channel.name, message);
    }

    void sendCooldownMustBeValidPositiveDurationString()
    {
        enum message = "Oneliner cooldown must be in the hour-minute-seconds form of <b>*h*m*s<b> " ~
            "and may not have negative values.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendOnelinerAlreadyExists(const string trigger)
    {
        enum pattern = `A oneliner with the trigger word "<b>%s<b>" already exists.`;
        immutable message = pattern.format(trigger);
        chan(plugin.state, event.channel.name, message);
    }

    string trigger;  // mutable
    string typestring;  // ditto
    string cooldownString;  // ditto
    cast(void) slice.splitInto(trigger, typestring, cooldownString);

    if (!typestring.length) return sendNewUsage();

    trigger = Oneliner.stripPrefix(trigger, plugin.state.coreSettings.prefix).toLower();

    const channelTriggers = event.channel.name in plugin.onelinersByChannel;
    if (channelTriggers && (trigger in *channelTriggers))
    {
        return sendOnelinerAlreadyExists(trigger);
    }

    Oneliner.OnelinerType type;
    immutable success = Oneliner.resolveOnelinerTypestring(typestring, type);
    if (!success) return sendMustBeRandomOrOrdered();

    int cooldownSeconds = Oneliner.init.cooldown;

    if (cooldownString.length)
    {
        import kameloso.time : DurationStringException, asAbbreviatedDuration;

        try
        {
            cooldownSeconds = cast(int) cooldownString.asAbbreviatedDuration.total!"seconds";
            if (cooldownSeconds < 0) return sendCooldownMustBeValidPositiveDurationString();
        }
        catch (DurationStringException _)
        {
            return sendCooldownMustBeValidPositiveDurationString();
        }
    }

    newOnelinerImpl(
        plugin,
        event.channel.name,
        trigger,
        type,
        cooldownSeconds);
}


// newOnelinerImpl
/++
    Creates a new and empty oneliner.

    Uses [kameloso.plugins.defer|defer] to defer the creation to
    the main event loop, so that it can supply the list of existing commands across
    all plugins and abort if the new trigger word would conflict with one.

    Params:
        plugin = The current [OnelinerPlugin].
        channelName = Name of the channel to create the oneliner in.
        trigger = Trigger word for the oneliner.
        type = [Oneliner.OnelinerType|OnelinerType] of the oneliner.
        cooldownSeconds = Cooldown in seconds for the oneliner.
        alias_ = Optional alias of another oneliner.
 +/
void newOnelinerImpl(
    OnelinerPlugin plugin,
    const string channelName,
    const string trigger,
    const Oneliner.OnelinerType type,
    const uint cooldownSeconds,
    const string alias_ = string.init)
{
    import kameloso.plugins : defer;
    import std.format : format;
    import std.typecons : Tuple;

    auto triggerConflicts(const IRCPlugin.CommandMetadata[string][string] aa)
    {
        foreach (immutable pluginName, pluginCommands; aa)
        {
            if (!pluginCommands.length || (pluginName == "oneliner"))
            {
                continue;
            }

            if (trigger in pluginCommands)
            {
                enum pattern = `Oneliner word "<b>%s<b>" conflicts with a command of the <b>%s<b> plugin.`;
                immutable message = pattern.format(trigger, pluginName);
                chan(plugin.state, channelName, message);
                return true;
            }
        }
        return false;
    }

    alias Payload = Tuple!
        (IRCPlugin.CommandMetadata[string][string],
        IRCPlugin.CommandMetadata[string][string]);

    void addNewOnelinerDg()
    {
        import kameloso.thread : CarryingFiber;
        import core.thread.fiber : Fiber;

        auto thisFiber = cast(CarryingFiber!Payload) Fiber.getThis();
        assert(thisFiber, "Incorrectly cast fiber: " ~ typeof(thisFiber).stringof);

        if (triggerConflicts(thisFiber.payload[0])) return;
        else if (triggerConflicts(thisFiber.payload[1])) return;

        Oneliner oneliner;
        oneliner.trigger = trigger;
        oneliner.alias_ = alias_;  // string.init if unset
        oneliner.type = type;
        oneliner.cooldown = cooldownSeconds;

        plugin.onelinersByChannel[channelName][trigger] = oneliner;
        saveResourceToDisk(plugin.onelinersByChannel, plugin.onelinerFile);

        if (type == Oneliner.OnelinerType.alias_)
        {
            enum pattern = "Oneliner <b>%s%s<b> created as an alias of <b>%1$s%3$s<b>.";
            immutable message = pattern.format(plugin.state.coreSettings.prefix, trigger, alias_);
            chan(plugin.state, channelName, message);
        }
        else
        {
            enum pattern = "Oneliner <b>%s%s<b> created!";// Use <b>%1$s%3$s add<b> to add lines.";
            immutable message = pattern.format(plugin.state.coreSettings.prefix, trigger);//, event.aux[$-1]);
            chan(plugin.state, channelName, message);
        }
    }

    defer!Payload(plugin, &addNewOnelinerDg, channelName);
}


// handleModifyOneliner
/++
    Modifies an existing oneliner.

    Params:
        plugin = The current [OnelinerPlugin].
        event = The [dialect.defs.IRCEvent|IRCEvent] that requested the modification.
        slice = Relevant slice of the original request string.
 +/
void handleModifyOneliner(
    OnelinerPlugin plugin,
    const IRCEvent event,
    /*const*/ string slice)
{
    import lu.conv : toString;
    import lu.string : SplitResults, splitInto;
    import std.format : format;
    import std.uni : toLower;

    void sendNewUsage()
    {
        enum pattern = "Usage: <b>%s%s modify<b> [trigger] [type] [optional cooldown]";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel.name, message);
    }

    void sendMustBeRandomOrOrdered()
    {
        enum message = "Oneliner type must be one of <b>random<b> or <b>ordered<b>";
        chan(plugin.state, event.channel.name, message);
    }

    void sendCooldownMustBeValidPositiveDurationString()
    {
        enum message = "Oneliner cooldown must be in the hour-minute-seconds form of <b>*h*m*s<b> " ~
            "and may not have negative values.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendNoSuchOneliner(const string trigger)
    {
        enum pattern = "No such oneliner: <b>%s%s<b>";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, trigger);
        chan(plugin.state, event.channel.name, message);
    }

    void sendNewDescription(const Oneliner oneliner)
    {
        enum pattern = "Oneliner <b>%s%s<b> modified to " ~
            "type <b>%s<b>, " ~
            "cooldown <b>%d<b> seconds";
        immutable message = pattern.format(
            plugin.state.coreSettings.prefix,
            oneliner.trigger,
            oneliner.type.toString,
            oneliner.cooldown);
        chan(plugin.state, event.channel.name, message);
    }

    string trigger;  // mutable
    string typestring;  // ditto
    string cooldownString;  // ditto
    cast(void) slice.splitInto(trigger, typestring, cooldownString);

    if (!typestring.length) return sendNewUsage();

    auto channelOneliners = event.channel.name in plugin.onelinersByChannel;
    if (!channelOneliners) return sendNoSuchOneliner(trigger);

    trigger = Oneliner.stripPrefix(trigger, plugin.state.coreSettings.prefix).toLower;

    auto oneliner = trigger in *channelOneliners;
    if (!oneliner) return sendNoSuchOneliner(trigger);

    Oneliner.OnelinerType type;
    immutable success = Oneliner.resolveOnelinerTypestring(typestring, type);
    if (!success) return sendMustBeRandomOrOrdered();

    if (cooldownString.length)
    {
        import kameloso.time : DurationStringException, asAbbreviatedDuration;

        try
        {
            immutable cooldown = cast(int) cooldownString.asAbbreviatedDuration.total!"seconds";
            if (cooldown < 0) return sendCooldownMustBeValidPositiveDurationString();
            oneliner.cooldown = cooldown;
        }
        catch (DurationStringException _)
        {
            return sendCooldownMustBeValidPositiveDurationString();
        }
    }

    oneliner.type = type;
    return sendNewDescription(*oneliner);
}


// handleAddToOneliner
/++
    Adds or inserts a line into a oneliner, or modifies an existing line.

    Params:
        plugin = The current [OnelinerPlugin].
        event = The [dialect.defs.IRCEvent|IRCEvent] that requested the addition (or modification).
        slice = Relevant slice of the original request string.
        verb = The string verb of what action was requested; "add", "insert" or "edit".
 +/
void handleAddToOneliner(
    OnelinerPlugin plugin,
    const IRCEvent event,
    /*const*/ string slice,
    const string verb)
{
    import lu.string : SplitResults, splitInto, unquoted;
    import std.conv : ConvException, to;
    import std.format : format;
    import std.uni : toLower;

    void sendInsertEditUsage(const string verb)
    {
        immutable pattern = (verb == "insert") ?
            "Usage: <b>%s%s insert<b> [trigger] [position] [text]" :
            "Usage: <b>%s%s edit<b> [trigger] [position] [new text]";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel.name, message);
    }

    void sendAddUsage()
    {
        enum pattern = "Usage: <b>%s%s add<b> [existing trigger] [text]";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel.name, message);
    }

    void sendNoSuchOneliner(const string trigger)
    {
        // Sent from more than one place so might as well make it a nested function
        enum pattern = "No such oneliner: <b>%s%s<b>";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, trigger);
        chan(plugin.state, event.channel.name, message);
    }

    void sendResponseIndexOutOfBounds(const size_t pos, const size_t upperBounds)
    {
        enum pattern = "Oneliner response index <b>%d<b> is out of bounds. <b>[0..%d]<b>";
        immutable message = pattern.format(pos, upperBounds);
        chan(plugin.state, event.channel.name, message);
    }

    void sendPositionNotPositive()
    {
        enum message = "Position passed is not a positive number.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendPositionNaN()
    {
        enum message = "Position passed is not a number.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendOnelinerInserted()
    {
        enum message = "Oneliner line inserted.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendOnelinerAdded()
    {
        enum message = "Oneliner line added.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendOnelinerModified()
    {
        enum message = "Oneliner line modified.";
        chan(plugin.state, event.channel.name, message);
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
        trigger = Oneliner.stripPrefix(trigger, plugin.state.coreSettings.prefix).toLower;

        auto channelOneliners = event.channel.name in plugin.onelinersByChannel;
        if (!channelOneliners) return sendNoSuchOneliner(trigger);

        auto oneliner = trigger in *channelOneliners;
        if (!oneliner) return sendNoSuchOneliner(trigger);

        if ((action != Action.appendToEnd) && (pos >= oneliner.responses.length))
        {
            return sendResponseIndexOutOfBounds(pos, oneliner.responses.length);
        }

        with (Action)
        final switch (action)
        {
        case insertAtPosition:
            import std.array : insertInPlace;

            oneliner.responses.insertInPlace(pos, line);

            if (oneliner.type == Oneliner.OnelinerType.ordered)
            {
                // Reset ordered position to 0 on insertions
                oneliner.position = 0;
            }

            sendOnelinerInserted();
            break;

        case appendToEnd:
            oneliner.responses ~= line;
            sendOnelinerAdded();
            break;

        case editExisting:
            oneliner.responses[pos] = line;
            sendOnelinerModified();
            break;
        }

        saveResourceToDisk(plugin.onelinersByChannel, plugin.onelinerFile);
    }

    if ((verb == "insert") || (verb == "edit"))
    {
        string trigger;  // mutable
        string posString;  // ditto
        ptrdiff_t pos;  // ditto
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

        immutable action = (verb == "insert") ?
            Action.insertAtPosition :
            Action.editExisting;  // verb == "edit"

        insert(trigger, slice.unquoted, action, pos);
    }
    else if (verb == "add")
    {
        string trigger;  // mutable
        immutable results = slice.splitInto(trigger);

        if (results != SplitResults.overrun)
        {
            return sendAddUsage();
        }

        insert(trigger, slice.unquoted, Action.appendToEnd);
    }
    else
    {
        assert(0, "impossible case in `handleAddToOneliner` switch");
    }
}


// handleDelFromOneliner
/++
    Deletes a oneliner entirely, alternatively a line from one.

    Params:
        plugin = The current [OnelinerPlugin].
        event = The [dialect.defs.IRCEvent|IRCEvent] that requested the deletion.
        slice = Relevant slice of the original request string.
 +/
void handleDelFromOneliner(
    OnelinerPlugin plugin,
    const IRCEvent event,
    /*const*/ string slice)
{
    import lu.string : advancePast;
    import std.conv : ConvException, to;
    import std.format : format;
    import std.uni : toLower;

    void sendDelUsage()
    {
        enum pattern = "Usage: <b>%s%s del<b> [trigger] [optional position]";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel.name, message);
    }

    void sendNoSuchOneliner(const string trigger)
    {
        // Sent from more than one place so might as well make it a nested function
        enum pattern = "No such oneliner: <b>%s%s<b>";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, trigger);
        chan(plugin.state, event.channel.name, message);
    }

    void sendOnelinerEmpty(const string trigger)
    {
        enum pattern = "Oneliner <b>%s<b> is empty and has no responses to remove.";
        immutable message = pattern.format(trigger);
        chan(plugin.state, event.channel.name, message);
    }

    void sendResponseIndexOutOfBounds(const size_t pos, const size_t upperBounds)
    {
        enum pattern = "Oneliner response index <b>%d<b> is out of bounds. <b>[0..%d]<b>";
        immutable message = pattern.format(pos, upperBounds);
        chan(plugin.state, event.channel.name, message);
    }

    void sendLineRemoved(const string trigger, const size_t pos)
    {
        enum pattern = "Oneliner response <b>%s<b>#%d removed.";
        immutable message = pattern.format(trigger, pos);
        chan(plugin.state, event.channel.name, message);
    }

    void sendRemoved(const string trigger, const bool alias_)
    {
        immutable pattern = alias_ ?
            "Oneliner alias <b>%s%s<b> removed." :
            "Oneliner <b>%s%s<b> removed.";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, trigger);
        chan(plugin.state, event.channel.name, message);
    }

    if (!slice.length) return sendDelUsage();

    immutable rawTrigger = slice.advancePast(' ', inherit: true);
    immutable trigger = Oneliner.stripPrefix(rawTrigger, plugin.state.coreSettings.prefix).toLower;

    auto channelOneliners = event.channel.name in plugin.onelinersByChannel;
    if (!channelOneliners) return sendNoSuchOneliner(trigger);

    auto oneliner = trigger in *channelOneliners;
    if (!oneliner) return sendNoSuchOneliner(trigger);

    if (slice.length)
    {
        if (!oneliner.responses.length) return sendOnelinerEmpty(trigger);

        try
        {
            import std.algorithm.mutation : SwapStrategy, remove;

            immutable pos = slice.to!size_t;

            if (pos >= oneliner.responses.length)
            {
                return sendResponseIndexOutOfBounds(pos, oneliner.responses.length);
            }

            oneliner.responses = oneliner.responses.remove!(SwapStrategy.stable)(pos);
            sendLineRemoved(trigger, pos);

            if (oneliner.type == Oneliner.OnelinerType.ordered)
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
        sendRemoved(trigger, (oneliner.alias_.length > 0));

        string[] toRemove;

        foreach (immutable otherTrigger, const otherOneliner; *channelOneliners)
        {
            if (otherOneliner.type == Oneliner.OnelinerType.alias_)
            {
                if (otherOneliner.alias_ == trigger)
                {
                    //(*channelOneliners).remove(alias_);
                    toRemove ~= otherTrigger;
                }
            }
        }

        foreach (immutable otherTrigger; toRemove)
        {
            (*channelOneliners).remove(otherTrigger);
            sendRemoved(otherTrigger, true);
        }
    }

    saveResourceToDisk(plugin.onelinersByChannel, plugin.onelinerFile);
}


// handleAliasOneliner
/++
    Creates or deletes an alias of an existing oneliner.

    Params:
        plugin = The current [OnelinerPlugin].
        event = The [dialect.defs.IRCEvent|IRCEvent] that requested the aliasing.
        slice = Relevant slice of the original request string.
 +/
void handleAliasOneliner(
    OnelinerPlugin plugin,
    const IRCEvent event,
    /*const*/ string slice)
{
    import lu.string : SplitResults, splitInto;
    import std.algorithm.comparison : among;
    import std.format : format;
    import std.uni : toLower;

    void sendAliasUsage()
    {
        enum pattern = "Usage: <b>%s%s alias<b> [trigger] [existing trigger to alias]";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel.name, message);
    }

    void sendYouMustSupplyAlias()
    {
        enum message = "You must supply a oneliner trigger word to make an alias of.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendNoSuchOneliner(const string trigger)
    {
        enum pattern = "No such oneliner: <b>%s%s<b>";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, trigger);
        chan(plugin.state, event.channel.name, message);
    }

    void sendOnelinerAlreadyExists(const string trigger)
    {
        enum pattern = `A oneliner with the trigger word "<b>%s<b>" already exists.`;
        immutable message = pattern.format(trigger);
        chan(plugin.state, event.channel.name, message);
    }

    void sendCannotAliasAlias()
    {
        enum message = "Cannot alias an alias oneliner.";
        chan(plugin.state, event.channel.name, message);
    }

    string trigger;  // mutable
    string alias_;  // as above
    cast(void) slice.splitInto(trigger, alias_);

    if (!trigger.length) return sendAliasUsage();
    if (!alias_.length) return sendYouMustSupplyAlias();

    trigger = Oneliner.stripPrefix(trigger, plugin.state.coreSettings.prefix).toLower();

    const channelTriggers = event.channel.name in plugin.onelinersByChannel;
    if (!channelTriggers) return sendNoSuchOneliner(alias_);
    if (trigger in *channelTriggers) return sendOnelinerAlreadyExists(trigger);

    const otherOneliner = alias_ in *channelTriggers;
    if (!otherOneliner) return sendNoSuchOneliner(alias_);
    if (otherOneliner.type == Oneliner.OnelinerType.alias_) return sendCannotAliasAlias();

    newOnelinerImpl(
        plugin,
        event.channel.name,
        trigger,
        Oneliner.OnelinerType.alias_,
        0,
        alias_);
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
void onCommandCommands(OnelinerPlugin plugin, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);
    listCommands(plugin, event, includeAliases: false);
}


// listCommands
/++
    Lists the current commands to the passed channel.

    Params:
        plugin = The current [OnelinerPlugin].
        event = The querying [dialect.defs.IRCEvent|IRCEvent].
        includeAliases = Whether to include oneliner aliases in the list.
        slice = Relevant slice of the original request string.
 +/
void listCommands(
    OnelinerPlugin plugin,
    const IRCEvent event,
    const bool includeAliases,
    /*const*/ string slice = string.init)
{
    import lu.string : stripped;
    import std.format : format;
    import std.uni : toLower;

    void sendNoCommandsAvailable()
    {
        enum message = "There are no commands available right now.";
        sendOneliner(plugin, event, message);
    }

    void sendNoSuchOneliner()
    {
        enum message = "There is no such oneliner defined.";
        sendOneliner(plugin, event, message);
    }

    void sendOnelinerInfo(const Oneliner oneliner)
    {
        if (oneliner.type == Oneliner.OnelinerType.alias_)
        {
            enum pattern = "Oneliner <b>%s%s<b> is an alias of <b>%1$s%3$s<b>.";
            immutable message = pattern.format(
                plugin.state.coreSettings.prefix,
                oneliner.trigger,
                oneliner.alias_);
            sendOneliner(plugin, event, message);
        }
        else
        {
            import lu.conv : toString;

            enum pattern = "Oneliner <b>%s%s<b> has %d responses and is of type <b>%s<b>.";
            immutable message = pattern.format(
                plugin.state.coreSettings.prefix,
                oneliner.trigger,
                oneliner.responses.length,
                oneliner.type.toString);
            sendOneliner(plugin, event, message);
        }
    }

    const channelOneliners = event.channel.name in plugin.onelinersByChannel;
    if (!channelOneliners || !channelOneliners.length) return sendNoCommandsAvailable();

    immutable triggerLower = slice.stripped.toLower;

    if (triggerLower.length)
    {
        const oneliner = triggerLower in *channelOneliners;
        if (!oneliner) return sendNoSuchOneliner();

        sendOnelinerInfo(*oneliner);
    }
    else
    {
        import std.algorithm.iteration : map;

        immutable rtPattern = "Available commands: %-(<b>" ~ plugin.state.coreSettings.prefix ~ "%s<b>, %)<b>";

        if (includeAliases)
        {
            import std.conv : text;

            auto range = channelOneliners
                .byValue
                .map!(o => o.alias_.length ? text(o.trigger, '*') : o.trigger);

            immutable message = rtPattern.format(range);
            sendOneliner(plugin, event, message);
        }
        else
        {
            import std.algorithm.iteration : filter;

            auto range = channelOneliners
                .byValue
                .filter!(o => !o.alias_.length)
                .map!(o => o.trigger);

            immutable message = rtPattern.format(range);
            sendOneliner(plugin, event, message);
        }
    }
}


// onWelcome
/++
    Populate the oneliners array after we have successfully logged onto the server.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WELCOME)
)
void onWelcome(OnelinerPlugin plugin, const IRCEvent _)
{
    mixin(memoryCorruptionCheck);
    loadOneliners(plugin);
}


// reload
/++
    Reloads oneliners from disk.
 +/
void reload(OnelinerPlugin plugin)
{
    loadOneliners(plugin);
}


// loadOneliners
/++
    Loads oneliners from disk.
 +/
void loadOneliners(OnelinerPlugin plugin)
{
    import lu.string : strippedRight;
    import asdf.serialization : deserialize;
    import std.file : readText;
    import std.stdio : File, writeln;

    immutable content = plugin.onelinerFile.readText.strippedRight;

    version(PrintStacktraces)
    {
        scope(failure)
        {
            import std.json : parseJSON;
            import std.stdio : writeln;

            writeln(content);
            try writeln(content.parseJSON.toPrettyString);
            catch (Exception _) {}
        }
    }

    auto json = content.deserialize!(Oneliner.JSONSchema[string][string]);

    plugin.onelinersByChannel = null;

    foreach (immutable channelName, const channelSchemas; json)
    {
        // Initialise the AA
        auto channelOneliners = channelName in plugin.onelinersByChannel;

        if (!channelOneliners)
        {
            plugin.onelinersByChannel[channelName][string.init] = Oneliner.init;
            channelOneliners = channelName in plugin.onelinersByChannel;
            (*channelOneliners).remove(string.init);
        }

        foreach (immutable trigger, const schema; channelSchemas)
        {
            (*channelOneliners)[trigger] = Oneliner(schema);
        }

        (*channelOneliners).rehash();
    }

    plugin.onelinersByChannel.rehash();
}


// sendOneliner
/++
    Sends a oneliner reply.

    If connected to a Twitch server and with version `TwitchSupport` set and
    [OnelinerSettings.onelinersAsTwitchReplies] true, sends the message as a
    Twitch [kameloso.messaging.reply|reply].

    Params:
        plugin = The current [OnelinerPlugin].
        event = The querying [dialect.defs.IRCEvent|IRCEvent].
        message = The message string to send.
 +/
void sendOneliner(
    OnelinerPlugin plugin,
    const IRCEvent event,
    const string message)
{
    version(TwitchSupport)
    {
        if ((plugin.settings.onelinersAsTwitchReplies) &&
            (plugin.state.server.daemon == IRCServer.Daemon.twitch))
        {
            return reply(plugin.state, event, message);
        }
    }

    chan(plugin.state, event.channel.name, message);
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
    import std.stdio : File;

    try
    {
        JSONValue json;
        json.object = null;

        foreach (immutable channelName, const channelOneliners; aa)
        {
            json[channelName] = null;
            json[channelName].object = null;

            foreach (immutable trigger, const oneliner; channelOneliners)
            {
                json[channelName][trigger] = oneliner.asSchema.asJSONValue;
            }
        }

        immutable serialised = json.toPrettyString;
        File(filename, "w").writeln(serialised);
    }
    catch (Exception e)
    {
        import kameloso.common : logger;
        version(PrintStacktraces) logger.trace(e);
    }
}


// initResources
/++
    Reads and writes the file of oneliners and administrators to disk, ensuring
    that they're there and properly formatted.
 +/
void initResources(OnelinerPlugin plugin)
{
    import lu.string : strippedRight;
    import asdf.serialization : deserialize;
    import mir.serde : SerdeException;
    import std.file : readText;
    import std.json : JSONValue;
    import std.stdio : File;

    immutable content = plugin.onelinerFile.readText.strippedRight;

    if (!content.length)
    {
        File(plugin.onelinerFile, "w").writeln("{}");
        return;
    }

    version(PrintStacktraces)
    {
        scope(failure)
        {
            import std.json : parseJSON;
            import std.stdio : writeln;

            writeln(content);
            try writeln(content.parseJSON.toPrettyString);
            catch (Exception _) {}
        }
    }

    try
    {
        const deserialised = content.deserialize!(Oneliner.JSONSchema[string][string]);

        JSONValue json;
        json.object = null;

        foreach (immutable channelName, const channelOneliners; deserialised)
        {
            json[channelName] = null;
            json[channelName].object = null;

            foreach (immutable trigger, const schema; channelOneliners)
            {
                json[channelName][trigger] = schema.asJSONValue;
            }
        }

        immutable serialised = json.toPrettyString;
        File(plugin.onelinerFile, "w").writeln(serialised);
    }
    catch (SerdeException e)
    {
        version(PrintStacktraces) logger.trace(e);

        throw new IRCPluginInitialisationException(
            message: "Oneliner file is malformed",
            pluginName: plugin.name,
            malformedFilename: plugin.onelinerFile);
    }
}


// selftest
/++
    Performs self-tests against another bot.
 +/
version(Selftests)
auto selftest(OnelinerPlugin plugin, Selftester s)
{
    import kameloso.plugins.common.scheduling : delay;
    import kameloso.common : logger;
    import core.time : seconds;

    s.send("commands");
    s.expect("There are no commands available right now.");

    s.send("oneliner");
    s.expect("Usage: ${prefix}oneliner [new|insert|add|alias|modify|edit|del|list] ...");

    s.send("oneliner add herp derp dirp darp");
    s.expect("No such oneliner: ${prefix}herp");

    s.send("oneliner new");
    s.expect("Usage: ${prefix}oneliner new [trigger] [type] [optional cooldown]");

    s.send("oneliner new herp ordered");
    s.expect("Oneliner ${prefix}herp created!");

    s.sendPrefixed("herp");
    s.expect("(Empty oneliner; use ${prefix}oneliner add herp to add lines.)");

    s.send("oneliner alias hirp herp");
    s.expect("Oneliner ${prefix}hirp created as an alias of ${prefix}herp.");

    s.sendPrefixed("hirp");
    s.expect("(Empty oneliner; use ${prefix}oneliner add herp to add lines.)");

    s.send("oneliner add herp 123");
    s.expect("Oneliner line added.");

    s.send("oneliner add herp 456");
    s.expect("Oneliner line added.");

    s.sendPrefixed("herp");
    s.expect("123");

    s.sendPrefixed("hirp");
    s.expect("456");

    s.sendPrefixed("herp");
    s.expect("123");

    s.send("oneliner insert herp 0 000");
    s.expect("Oneliner line inserted.");

    s.sendPrefixed("herp");
    s.expect("000");

    s.sendPrefixed("hirp");
    s.expect("123");

    s.send("oneliner list");
    s.expect("Available commands: ${prefix}herp, ${prefix}hirp*");

    s.sendPrefixed("commands");
    s.expect("Available commands: ${prefix}herp");

    s.send("oneliner del hurp");
    s.expect("No such oneliner: ${prefix}hurp");

    s.send("oneliner del herp");
    s.expect("Oneliner ${prefix}herp removed.");
    s.expect("Oneliner alias ${prefix}hirp removed.");

    s.send("oneliner list");
    s.expect("There are no commands available right now.");

    s.send("oneliner new herp random 10");
    s.expect("Oneliner ${prefix}herp created!");

    s.sendPrefixed("herp");
    s.expect("(Empty oneliner; use ${prefix}oneliner add herp to add lines.)");

    s.send("oneliner add herp abc");
    s.expect("Oneliner line added.");

    s.sendPrefixed("herp");
    s.expect("abc");

    s.sendPrefixed("herp");

    static immutable waitDuration = 10.seconds;
    logger.info("wait ", waitDuration, "...");
    delay(plugin, waitDuration, yield: true);
    s.requireTriggeredByTimer();

    s.sendPrefixed("herp");
    s.expect("abc");

    s.send("oneliner modify");
    s.expect("Usage: ${prefix}oneliner modify [trigger] [type] [optional cooldown]");

    s.send("oneliner modify herp ordered 0");
    s.expect("Oneliner ${prefix}herp modified to type ordered, cooldown 0 seconds");

    s.send("oneliner add herp def");
    s.expect("Oneliner line added.");

    s.sendPrefixed("herp");
    s.expect("abc");

    s.sendPrefixed("herp");
    s.expect("def");

    s.sendPrefixed("herp");
    s.expect("abc");

    s.send("oneliner del herp");
    s.expect("Oneliner ${prefix}herp removed.");

    s.send("commands");
    s.expect("There are no commands available right now.");

    return true;
}


mixin UserAwareness;
mixin PluginRegistration!OnelinerPlugin;

version(TwitchSupport)
{
    mixin TwitchAwareness;
}

public:


// OnelinerPlugin
/++
    The Oneliner plugin serves to listen to custom commands that can be added,
    modified and removed at runtime. Think `!info`, `!vods` and `!socials`.
 +/
final class OnelinerPlugin : IRCPlugin
{
private:
    /++
        All Oneliner plugin settings.
     +/
    OnelinerSettings settings;

    /++
        Associative array of oneliners; [Oneliner] array, keyed by trigger, keyed by channel.
     +/
    Oneliner[string][string] onelinersByChannel;

    /++
        Filename of file with oneliners.
     +/
    @Resource string onelinerFile = "oneliners.json";

    // channelSpecificCommands
    /++
        Compile a list of our runtime oneliner commands.

        Params:
            channelName = Name of channel whose commands we want to summarise.

        Returns:
            An associative array of
            [kameloso.plugins.IRCPlugin.CommandMetadata|IRCPlugin.CommandMetadata]s,
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
