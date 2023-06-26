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
        [kameloso.plugins.common.core],
        [kameloso.plugins.common.misc]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.same;

version(WithSamePlugin):

// Pick *one*.
version = MatchByStringComparison;
//version = MatchWithRegex;

private:

import kameloso.plugins;
import kameloso.plugins.common;
import kameloso.messaging;
import dialect.defs;


// SameSettings
/++
    Settings for the Same plugin, to toggle it on or off.
 +/
@Settings struct SameSettings
{
    /// Whether or not the Same plugin should react to events at all.
    @Enabler bool enabled = true;
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


// onAnyMessage
/++
    Reacts to the message "same" by agreeing with "same".

    Uses manual matching. It is up to the function to decide whether or not it
    should reply.

    Only literal matching is made, so matches are case-sensitive and may not be
    trailed by other text. Only messages whose contents are literally the characters
    "same" are matched.
 +/
version(MatchByStringComparison)
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.ignore)
    .channelPolicy(ChannelPolicy.home)
)
void onAnyMessage(SamePlugin plugin, const ref IRCEvent event)
{
    // Reply only if we should
    if (event.content == "same")
    {
        chan(plugin.state, event.channel, "same");
    }
}


// onAnyMessageRegex
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
void onAnyMessageRegex(SamePlugin plugin, const ref IRCEvent event)
{
    // Reply always, since the function wouldn't have been called if the message didn't match
    chan(plugin.state, event.channel, event.content);
}


mixin PluginRegistration!SamePlugin;

public:


// SamePlugin
/++
    The Same toy plugin, that replies to the text "same" with "same".
 +/
final class SamePlugin : IRCPlugin
{
    /// All Same plugin settings gathered.
    SameSettings sameSettings;

    mixin IRCPluginImpl;
}
