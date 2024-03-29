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
    TwitchPlugin stub.
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
