/++
    Package for the TwitchBot plugin modules.

    See_Also:
        [kameloso.plugins.twitchbot.base|twitchbot.base]
        [kameloso.plugins.twitchbot.api|twitchbot.api]
        [kameloso.plugins.twitchbot.timers|twitchbot.timers]
        [kameloso.plugins.twitchbot.keygen|twitchbot.keygen]
 +/
module kameloso.plugins.twitchbot;

version(TwitchSupport):
version(WithTwitchBotPlugin):

public:

import kameloso.plugins.twitchbot.base;
import kameloso.plugins.twitchbot.api;
import kameloso.plugins.twitchbot.timers;
//import kameloso.plugins.twitchbot.keygen;  // Only necessary from within onCAP
