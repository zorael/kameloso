/++
    Package for the Twitch plugin modules.

    See_Also:
        [kameloso.plugins.twitch.base],
        [kameloso.plugins.twitch.keygen],
        [kameloso.plugins.twitch.api]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.twitch;

version(TwitchSupport):
version(WithTwitchPlugin):

public:

import kameloso.plugins.twitch.base;
import kameloso.plugins.twitch.api;
//import kameloso.plugins.twitch.keygen;  // Only necessary from within TwitchPlugin.start()
//import kameloso.plugins.twitch.google;
//import kameloso.plugins.twitch.spotify;
//import kameloso.plugins.twitch.common;
import kameloso.plugins.twitch.stub;
