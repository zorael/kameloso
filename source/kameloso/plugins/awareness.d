/++
    Compatibility aliases to `kameloso.plugins.common.awareness`, since we moved it.

    Do not use. Remove when appropriate.
 +/
module kameloso.plugins.awareness;

version(WithPlugins):

public import kameloso.plugins.common.awareness;

deprecated("Import from `kameloso.plugins.common.awareness` directly instead")
{
    /// Deprecated alias to `kameloso.plugins.common.awareness.MinimalAuthentication`.
    alias MinimalAuthentication = kameloso.plugins.common.awareness.MinimalAuthentication;

    /// Deprecated alias to `kameloso.plugins.common.awareness.UserAwareness`.
    alias UserAwareness = kameloso.plugins.common.awareness.UserAwareness;

    /// Deprecated alias to `kameloso.plugins.common.awareness.ChannelAwareness`.
    alias ChannelAwareness = kameloso.plugins.common.awareness.ChannelAwareness;

    version(TwitchSupport)
    {
        /// Deprecated alias to `kameloso.plugins.common.awareness.TwitchAwareness`.
        alias TwitchAwareness = kameloso.plugins.common.awareness.TwitchAwareness;
    }
}
