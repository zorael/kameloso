/++
    Package for the Twitch plugin modules.

    See_Also:
        [kameloso.plugins.twitch.base|twitch.base]
        [kameloso.plugins.twitch.api|twitch.api]
        [kameloso.plugins.twitch.keygen|twitch.keygen]
 +/
module kameloso.plugins.twitch;

version(TwitchSupport):
version(WithTwitchPlugin):

public:

import kameloso.plugins.twitch.base;
import kameloso.plugins.twitch.api;
//import kameloso.plugins.twitch.keygen;  // Only necessary from within onCAP
//import kameloso.plugins.twitch.google;
//import kameloso.plugins.twitch.spotify;
//import kameloso.plugins.twitch.common;
import kameloso.plugins.twitch.stub;
