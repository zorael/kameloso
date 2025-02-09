/++
    Twitch plugin stub, to provide lines to the configuration file even when
    the bot isn't compiled in.

    See_Also:
        [kameloso.plugins.twitch]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.twitch.stub;

version(WithTwitchPlugin) {}
else version(WithTwitchPluginStub):

private:

import kameloso.plugins;
import kameloso.plugins.common;

mixin PluginRegistration!(TwitchPlugin, -5.priority);

public:


// TwitchPlugin
/++
    Stub for the [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin], compiled
    when the bot is built without Twitch support.

    This provides lines to the configuration file even when the bot isn't compiled in.
 +/
final class TwitchPlugin : IRCPlugin
{
private:
    static import kameloso.plugins.twitch;

    /++
        All Twitch plugin settings.
     +/
    kameloso.plugins.twitch.TwitchSettings twitchSettings;

    mixin IRCPluginImpl;
}

///
unittest
{
    pragma(msg, "blarp");
    import kameloso.pods : CoreSettings;
    import kameloso.plugins.common.misc : applyCustomSettings;

    IRCPluginState state;
    IRCPlugin plugin = new TwitchPlugin(state);
    CoreSettings coreSettings;

    const newSettings =
    [
        "twitch.enabled=false",
    ];

    assert(plugin.isEnabled);

    cast(void)applyCustomSettings(
        [ plugin ],
        coreSettings: coreSettings,
        customSettings: newSettings,
        toPluginsOnly: true);

    assert(!plugin.isEnabled);
}
