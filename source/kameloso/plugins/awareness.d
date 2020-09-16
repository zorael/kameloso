/++
    Compatibility alias to `kameloso.plugins.common.awarenses`, since we moved it.

    Do not use. Remove when appropriate.
 +/
module kameloso.plugins.awareness;

version(WithPlugins):

public import kameloso.plugins.common.awareness;

deprecated("Directly import from `kameloso.plugins.common.awareness` instead")
{
    alias MinimalAuthentication = kameloso.plugins.common.awareness.MinimalAuthentication;
    alias UserAwareness = kameloso.plugins.common.awareness.UserAwareness;
    alias ChannelAwareness = kameloso.plugins.common.awareness.ChannelAwareness;

    version(TwitchSupport)
    {
        alias TwitchAwareness = kameloso.plugins.common.awareness.TwitchAwareness;
    }
}
