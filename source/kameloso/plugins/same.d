/++
    This is an example toy plugin to showcase how one could be written to react
    to non-`!command` messages.

    In the first approach (version `MatchByStringComparison`), the function is
    annotated to be called on all channel messages, and the body has to decide
    whether or not to react to it and reply.

    In the second approach (version `MatchWithRegex`), the function is only called
    if the incoming message matched its regular expression, so the body can safely
    assume it should always react and reply.
 +/
module kameloso.plugins.same;

version(WithSamePlugin):

// Pick *one*.
version = MatchByStringComparison;
//version = MatchWithRegex;

private:

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
    version(MatchWithRegex)
    {
        static assert(0, "`" ~ __MODULE__ ~ "` has both version `MatchWithRegex` and `MatchByStringComparison`");
    }

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
    version(MatchByStringComparison)
    {
        static assert(0, "`" ~ __MODULE__ ~ "` has both version `MatchWithRegex` and `MatchByStringComparison`");
    }

    // Reply always, since the function wouldn't have been called if the message didn't match
    chan(plugin.state, event.channel, event.content);
}


public:


// SamePlugin
/++
    The Same toy plugin, that replies to the text "same" with "same".
 +/
@IRCPluginHook
final class SamePlugin : IRCPlugin
{
    /// All Same plugin settings gathered.
    SameSettings sameSettings;

    mixin IRCPluginImpl;
}
