/++
    This is an example toy plugin to showcase how one could be written to react
    to non-`!command` messages.

    In the first approach (version `MatchByStringComparison`), the function is
    annotated to be called on all channel messages, and the body has to decide
    whether or not to react to it and reply.

    In the second approach (version `MatchWithRegex`), the function is only called
    if the incoming message matched its regular expression, so the body can safely
    assume it should always react and reply.

    See_Also:
        [kameloso.plugins],
        [kameloso.plugins.common]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.same;

version(WithSamePlugin):

/+
    Pick *one*.
 +/
version = MatchByStringComparison;
//version = MatchWithRegex;

private:

import kameloso.plugins;
import kameloso.messaging;
import kameloso.thread;
import dialect.defs;
import core.time;
import core.thread;


// SameSettings
/++
    Settings for the Same plugin. These are automatically read from and written
    to disk by other parts of the program as long as it is annotated `@Settings`.

    Use it to store smaller persistent settings for the plugin. For larger things,
    consider using something like JSON files.
 +/
@Settings struct SameSettings
{
    /++
        Whether or not the Same plugin should react to events at all.
     +/
    @Enabler bool enabled = true;

    /++
        Example setting.
     +/
    string someSetting;

    /++
        Another example setting.
     +/
    int someOtherSetting;
}


// onAnyMessage
/++
    Reacts to the message "same" by agreeing with "same".

    Uses manual matching. It is up to the function to decide whether or not it
    should reply.

    Only literal matching is made, so matches are case-sensitive and may not be
    trailed by other text. Only messages whose contents are literally the characters
    "same" are matched. This can naturally be improved upon, but as a toy example
    it is kept simple.
 +/
version(MatchByStringComparison)
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.ignore)
    .channelPolicy(ChannelPolicy.home)
)
void onAnyMessage(SamePlugin plugin, const IRCEvent event)
{
    if (event.sender.class_ == IRCUser.Class.blacklist) return;

    // Reply only if we should
    if (event.content == "same")
    {
        chan(plugin.state, event.channel.name, "same");
    }
}


// onRegexMessageSame
/++
    Reacts to the messages which match the text "same" with some optional
    punctuation afterwards.

    Uses the regular expression `"^same[!.]*$"`.
 +/
version(MatchWithRegex)
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.ignore)
    .channelPolicy(ChannelPolicy.home)
    .addRegex(
        IRCEventHandler.Regex()
            .policy(PrefixPolicy.direct)
            .expression(r"^same[!.]*$")
            .description("Same.")
    )
)
void onRegexMessageSame(SamePlugin plugin, const IRCEvent event)
{
    if (event.sender.class_ == IRCUser.Class.blacklist) return;

    // Reply always, since the function wouldn't have been called if the message didn't match
    chan(plugin.state, event.channel.name, event.content);
}


// setup
/++
    Sets up the Same plugin. Think of it as a constructor.

    This is called before connection is established.
 +/
void setup(SamePlugin plugin)
in (Fiber.getThis(), "Tried to setup the Same plugin from outside a fiber")
{
    import std.random : uniform;
    plugin.settings.someOtherSetting = uniform(1, 100);
}


// initResources
/++
    Initialises the Same plugin's resources.

    This is where you'd read JSON files, reserve memory, etc. In the case of
    JSON files, one thing commonly done is to read them in and immediately write
    them out, to ensure they're valid JSON and to normalise formatting.

    This is called before connection is established but after [setup].
 +/
void initResources(SamePlugin plugin)
{
    // Allocate resources
    // Read JSON from disk, save JSON to disk
}


// initialise
/++
    Initialises the Same plugin. Do whatever you want here.

    This is called after connection is established.
 +/
void initialise(SamePlugin plugin)
in (Fiber.getThis(), "Tried to initialise the Same plugin from outside a fiber")
{
    plugin.settings.someSetting = ((plugin.settings.someOtherSetting % 2) == 0) ?
        "same" :
        "so i starve myself for energy";

    plugin.meaningOfLife = 42;
}


// postprocess
/++
    Postprocesses events.

    This is called after an [dialect.defs.IRCEvent|IRCEvent] has been parsed but
    before it is passed to plugins for handling. It allows for modifying the event
    before plugins have a chance to see it.

    Should return `true` if changes were made such that the event loop should
    check for messages; `false` otherwise.
 +/
auto postprocess(SamePlugin plugin, ref IRCEvent event)
{
    // Modify the event in some way, it is passed by ref
    return false;
}


// onBusMessage
/++
    Catches bus messages.

    These are messages sent between plugins. The value of `header` should be
    an identifier for which plugin the message is intended, and `content` is
    the message itself.
 +/
void onBusMessage(SamePlugin plugin, const string header, /*shared*/ Sendable content)
{
    if (header != "same") return;

    // Do something with the message
}


// tick
/++
    Called on each iteration of the main loop.

    This can often instead be implemented as a repeating fiber, but the option
    to use this approach is there.

    Should return `true` if the event loop should check for messages; `false` otherwise.
 +/
auto tick(SamePlugin plugin, const Duration duration)
{
    // Do something
    return false;
}


// reload
/++
    Reloads the Same plugin.

    What this does is highly plugin-specific, but generally reloads JSON files
    from disk.
 +/
void reload(SamePlugin plugin)
in (Fiber.getThis(), "Tried to reload the Same plugin from outside a fiber")
{
    import std.random : uniform;

    assert(plugin.settings.someOtherSetting > 0);  // from setup
    plugin.settings.someOtherSetting = uniform(1, 100);
}


// teardown
/++
    Tears down the Same plugin. Think of it as a destructor.

    This is called when the connection to the server has been lost and the
    program is either exiting or is getting ready to reconnect
    (which would call [setup]).
 +/
void teardown(SamePlugin plugin)
in (Fiber.getThis(), "Tried to teardown the Same plugin from outside a fiber")
{
    assert(plugin.meaningOfLife == 42);
}


mixin PluginRegistration!SamePlugin;

public:


// SamePlugin
/++
    The Same toy plugin, that replies to the text "same" with "same".
 +/
final class SamePlugin : IRCPlugin
{
    /++
        All Same plugin settings gathered.
     +/
    SameSettings settings;

    /++
        Non-settings transient state goes here and ideally not at the module-level.
     +/
    int meaningOfLife;

    /++
        Resource files may be declared here. The filename string will be expanded
        to the full path of the file as long as it is annotated `@Resource`.
     +/
    @Resource string sameFile = "same.json";

    mixin IRCPluginImpl;
}


/+
    Ensure that one and only one of the matching versions is declared.
 +/
version(MatchByStringComparison)
{
    version(MatchWithRegex)
    {
        version = MatchVersionError;
    }
}
else version(MatchWithRegex)
{
    version(MatchByStringComparison)
    {
        version = MatchVersionError;
    }
}
else
{
    version = MatchVersionError;
}


/+
    Error out during compilation if the matching versions aren't sane.
 +/
version(MatchVersionError)
{
    import std.format : format;

    enum pattern = "`%s` needs one of versions `MatchByStringComparison` and `MatchWithRegex` (but not both)";
    enum message = pattern.format(__MODULE__);
    static assert(0, message);
}
