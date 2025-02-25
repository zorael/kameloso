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

version(unittest) version = ShouldCompileTwitchStub;
else version(WithTwitchPlugin) {}  // Exempt
else version(WithTwitchPluginStub) version = ShouldCompileTwitchStub;

version(ShouldCompileTwitchStub):

private:

import kameloso.plugins;

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
    kameloso.plugins.twitch.TwitchSettings settings;

    mixin IRCPluginImpl;
}

///
unittest
{
    import kameloso.pods : CoreSettings;

    IRCPluginState state;
    IRCPlugin plugin = new TwitchPlugin(state);
    CoreSettings coreSettings;

    assert(plugin.isEnabled);

    cast(void)applyCustomSettings(
        [ plugin ],
        coreSettings: coreSettings,
        customSettings: [ "twitch.enabled=false" ],
        toPluginsOnly: true);

    assert(!plugin.isEnabled);

    cast(void)applyCustomSettings(
        [ plugin ],
        coreSettings: coreSettings,
        customSettings: [ "twitch.enabled" ],
        toPluginsOnly: true);

    assert(plugin.isEnabled);
}
