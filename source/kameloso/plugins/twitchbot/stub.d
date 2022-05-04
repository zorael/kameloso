/++
    Twitch bot plugin stub, to provide lines to the configuration file even when
    the bot isn't compiled in.
 +/
module kameloso.plugins.twitchbot.stub;

version(WithTwitchBotPlugin) {}
else version(WithTwitchBotPluginStub):

private:

import kameloso.plugins.common.core;

public:


// TwitchBotPlugin
/++
    TwitchBotPlugin stub.
 +/
final class TwitchBotPlugin : IRCPlugin
{
private:
    static import kameloso.plugins.twitchbot.base;

public:
    /// All Twitch Bot plugin settings.
    kameloso.plugins.twitchbot.base.TwitchBotSettings twitchBotSettings;

    mixin IRCPluginImpl;
}
