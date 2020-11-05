/++
    Package for the TwitchBot plugin modules.

    See_Also:
        $(REF kameloso.plugins.twitchbot.base),
        $(REF kameloso.plugins.twitchbot.api),
        $(REF kameloso.plugins.twitchbot.timers)
 +/
module kameloso.plugins.twitchbot;

version(WithPlugins):
version(TwitchSupport):
version(WithTwitchBotPlugin):

public:

import kameloso.plugins.twitchbot.base;
import kameloso.plugins.twitchbot.api;
import kameloso.plugins.twitchbot.timers;
