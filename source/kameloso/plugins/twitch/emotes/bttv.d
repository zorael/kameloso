/++
    Functions for importing custom BetterTTV emotes.

    See_Also:
        https://betterttv.com,
        [kameloso.plugins.twitch],
        [kameloso.plugins.twitch.emotes]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.twitch.emotes.bttv;

version(TwitchSupport):
version(WithTwitchPlugin):

private:

import kameloso.plugins.twitch : TwitchPlugin;
import core.thread.fiber : Fiber;

package:


// getBTTVEmotes
/++
    Fetches BetterTTV emotes for a given channel.

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        emoteMap = Pointer to the `bool[string]` associative array to store
            the fetched emotes in.
        id = Numeric Twitch user/channel ID.
        caller = Name of the calling function.

    See_Also:
        https://betterttv.com
 +/
auto getBTTVEmotes(
    TwitchPlugin plugin,
    bool[string]* emoteMap,
    const ulong id,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `getBTTVEmotes` from outside a fiber")
in (id, "Tried to get BTTV emotes with an unset ID")
{
    import kameloso.plugins : sendHTTPRequest;
    import asdf.serialization : deserialize, serdeOptional;
    import std.conv : to;

    @serdeOptional
    static struct Repsonse
    {
        @serdeOptional
        static struct Emote
        {
            /*static struct User
            {
                string displayName;
                string id;
                string name;
                string providerId;
            }*/

            string code;
            //string id;
            //bool animated;
            //string imageType;
            //string userId;
            //User user;
        }

        /*
        {
            "avatar": "https:\/\/static-cdn.jtvnw.net\/jtv_user_pictures\/lobosjr-profile_image-b5e3a6c3556aed54-300x300.png",
            "bots": [
                "lobotjr",
                "dumj01"
            ],
            "channelEmotes": [
                {
                    "animated": false,
                    "code": "FeelsDennyMan",
                    "id": "58a9cde206e70d0465b2b47e",
                    "imageType": "png",
                    "userId": "5575430f9cd396156bd1430c"
                },
                {
                    "animated": true,
                    "code": "lobosSHAKE",
                    "id": "5b007dc718b2f46a14d40242",
                    "imageType": "gif",
                    "userId": "5575430f9cd396156bd1430c"
                }
            ],
            "id": "5575430f9cd396156bd1430c",
            "sharedEmotes": [
                {
                    "animated": true,
                    "code": "(ditto)",
                    "id": "554da1a289d53f2d12781907",
                    "imageType": "gif",
                    "user": {
                        "displayName": "NightDev",
                        "id": "5561169bd6b9d206222a8c19",
                        "name": "nightdev",
                        "providerId": "29045896"
                    }
                },
                {
                    "animated": true,
                    "code": "WolfPls",
                    "height": 28,
                    "id": "55fdff6e7a4f04b172c506c0",
                    "imageType": "gif",
                    "user": {
                        "displayName": "bearzly",
                        "id": "5573551240fa91166bb18c67",
                        "name": "bearzly",
                        "providerId": "23239904"
                    },
                    "width": 21
                }
            ]
        }
         */

        Emote[] channelEmotes;
        Emote[] sharedEmotes;
        //string id;
    }

    static struct ResponseError
    {
        /*
        {
            "message": "user not found"
        }
         */

        string message;
    }

    immutable url = "https://api.betterttv.net/3/cached/users/twitch/" ~ id.to!string;

    immutable httpResponse = sendHTTPRequest(
        plugin: plugin,
        url: url,
        caller: caller);

    version(PrintStacktraces)
    {
        scope(failure)
        {
            import kameloso.misc : printStacktrace;
            import std.json : parseJSON;
            import std.stdio : writeln;

            writeln(httpResponse.code);
            writeln(httpResponse.body);
            writeln(httpResponse.body.parseJSON.toPrettyString);
            printStacktrace();
        }
    }

    switch (httpResponse.code)
    {
    case 200:
        // 200 OK
        break;

    default:
        const errorResponse = httpResponse.body.deserialize!ResponseError;

        if (errorResponse.message == "user not found")
        {
            // Benign
            return 0;
        }

        throw new Exception(errorResponse.message);
    }

    const response = httpResponse.body.deserialize!Repsonse;

    foreach (const emote; response.channelEmotes)
    {
        (*emoteMap)[emote.code] = true;
    }

    foreach (const emote; response.sharedEmotes)
    {
        (*emoteMap)[emote.code] = true;
    }

    return (response.channelEmotes.length + response.sharedEmotes.length);
}


// getBTTVEmotesGlobal
/++
    Fetches global BetterTTV emotes.

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        emoteMap = Pointer to the `bool[string]` associative array to store
            the fetched emotes in.
        _ = Unused, for signature compatibility with [getBTTVEmotes].
        caller = Name of the calling function.

    See_Also:
        https://betterttv.com/emotes/global
 +/
auto getBTTVEmotesGlobal(
    TwitchPlugin plugin,
    bool[string]* emoteMap,
    const ulong _ = 0,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `getBTTVEmotesGlobal` from outside a fiber")
{
    import kameloso.plugins : sendHTTPRequest;
    import asdf.serialization : deserialize, serdeOptional;
    import std.json : JSONType, parseJSON;

    @serdeOptional
    static struct Response
    {
        /*
        [
            {
                "animated": false,
                "code": ":tf:",
                "id": "54fa8f1401e468494b85b537",
                "imageType": "png",
                "userId": "5561169bd6b9d206222a8c19"
            },
            {
                "animated": false,
                "code": "CiGrip",
                "id": "54fa8fce01e468494b85b53c",
                "imageType": "png",
                "userId": "5561169bd6b9d206222a8c19"
            }
        ]
        */

        //bool animated;
        string code;
        //string id;
        //string imageType;
        //string userId;
    }

    enum url = "https://api.betterttv.net/3/cached/emotes/global";

    immutable httpResponse = sendHTTPRequest(
        plugin: plugin,
        url: url,
        caller: caller);

    const response = httpResponse.body.deserialize!(Response[]);

    foreach (const emote; response)
    {
        (*emoteMap)[emote.code] = true;
    }

    return response.length;
}
