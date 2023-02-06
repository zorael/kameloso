/++
    Twitch plugin stub, to provide lines to the configuration file even when
    the bot isn't compiled in.
 +/
module kameloso.plugins.twitch.stub;

version(WithTwitchPlugin) {}
else version(WithTwitchPluginStub):

private:

import kameloso.plugins;
import kameloso.plugins.common.core;

mixin PluginRegistration!TwitchPlugin;

public:


// TwitchPlugin
/++
    TwitchPlugin stub.
 +/
final class TwitchPlugin : IRCPlugin
{
private:
    static import kameloso.plugins.twitch.base;

public:
    /// All Twitch plugin settings.
    kameloso.plugins.twitch.base.TwitchSettings twitchSettings;

    mixin IRCPluginImpl;
}
