/++
    Compatibility alias to `kameloso.plugins.common.core`, since we moved it.

    Do not use. Remove when appropriate.
 +/
module kameloso.plugins.core;

public import kameloso.plugins.common.core;

deprecated("Directly import from `kameloso.plugins.common.core` instead")
alias IRCPlugin = kameloso.plugins.common.core.IRCPlugin;
