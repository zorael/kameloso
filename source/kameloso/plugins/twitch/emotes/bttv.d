/++
    Functions for importing custom BetterTTV emotes.

    See_Also:
        https://betterttv.com

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
        emoteMap = Reference to the `bool[dstring]` associative array to store
            the fetched emotes in.
        id = Numeric Twitch user/channel ID.
        caller = Name of the calling function.

    See_Also:
        https://betterttv.com
 +/
void getBTTVEmotes(
    TwitchPlugin plugin,
    ref bool[dstring] emoteMap,
    const uint id,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `getBTTVEmotes` from outside a fiber")
in (id, "Tried to get BTTV emotes with an unset ID")
{
    import kameloso.plugins.twitch.api : sendHTTPRequest;
    import kameloso.plugins.twitch.common : ErrorJSONException, UnexpectedJSONException;
    import std.conv : to;
    import std.json : JSONType, parseJSON;

    try
    {
        immutable url = "https://api.betterttv.net/3/cached/users/twitch/" ~ id.to!string;
        immutable response = sendHTTPRequest(plugin, url, caller);
        immutable responseJSON = parseJSON(response.str);

        /+
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
         +/

        if (responseJSON.type != JSONType.object)
        {
            enum message = "`getBTTVEmotes` response has unexpected JSON " ~
                "(wrong JSON type)";
            throw new UnexpectedJSONException(message, responseJSON);
        }

        immutable channelEmotesJSON = "channelEmotes" in responseJSON;

        if (!channelEmotesJSON)
        {
            enum message = "`getBTTVEmotes` response has unexpected JSON " ~
                `(no "channelEmotes" key)`;
            throw new UnexpectedJSONException(message, responseJSON);
        }

        immutable sharedEmotesJSON = "sharedEmotes" in responseJSON;

        foreach (const emoteJSON; channelEmotesJSON.array)
        {
            immutable emote = emoteJSON["code"].str.to!dstring;
            emoteMap[emote] = true;
        }

        foreach (const emoteJSON; sharedEmotesJSON.array)
        {
            immutable emote = emoteJSON["code"].str.to!dstring;
            emoteMap[emote] = true;
        }

        // All done
    }
    catch (ErrorJSONException e)
    {
        if (e.json.type == JSONType.object)
        {
            const messageJSON = "message" in e.json;

            if (messageJSON && (messageJSON.str == "user not found"))
            {
                // Benign
                return;
            }
            // Drop down
        }
        throw e;
    }
    catch (Exception e)
    {
        throw e;
    }
}


// getBTTVEmotesGlobal
/++
    Fetches global BetterTTV emotes.

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        emoteMap = Reference to the `bool[dstring]` associative array to store
            the fetched emotes in.
        _ = Unused, for signature compatibility with [getBTTVEmotes].
        caller = Name of the calling function.

    See_Also:
        https://betterttv.com/emotes/global
 +/
void getBTTVEmotesGlobal(
    TwitchPlugin plugin,
    ref bool[dstring] emoteMap,
    const uint _ = 0,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `getBTTVEmotesGlobal` from outside a fiber")
{
    import kameloso.plugins.twitch.api : sendHTTPRequest;
    import std.json : JSONType, parseJSON;

    enum url = "https://api.betterttv.net/3/cached/emotes/global";

    immutable response = sendHTTPRequest(plugin, url, caller);
    immutable responseJSON = parseJSON(response.str);

    /+
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
     +/

    if (responseJSON.type != JSONType.array)
    {
        import kameloso.plugins.twitch.common : UnexpectedJSONException;
        enum message = "`getBTTVEmotesGlobal` response has unexpected JSON " ~
            "(wrong JSON type)";
        throw new UnexpectedJSONException(message, responseJSON);
    }

    foreach (immutable emoteJSON; responseJSON.array)
    {
        import std.conv : to;
        immutable emote = emoteJSON["code"].str.to!dstring;
        emoteMap[emote] = true;
    }
}
