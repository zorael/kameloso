/++
    Functions for importing custom FrankerFaceZ emotes.

    See_Also:
        https://www.frankerfacez.com,
        [kameloso.plugins.twitch],
        [kameloso.plugins.twitch.emotes]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.twitch.emotes.ffz;

version(TwitchSupport):
version(WithTwitchPlugin):

private:

import kameloso.plugins.twitch : TwitchPlugin;
import asdf.serialization : serdeOptional;
import core.thread.fiber : Fiber;


// Response
/++
    JSON schema of the response from the FrankerFaceZ API.
 +/
@serdeOptional
struct Response
{
    ///
    static struct Set
    {
        ///
        static struct Emote
        {
            string name;  ///
            /*string id;
            string url;
            string css;
            bool hidden;
            bool modifier;
            uint usage_count;

            @serdeKeys("public") bool public_;*/
        }

        Emote[] emoticons;  ///
    }

    /*
    {
        "room": {
            "_id": 366358,
            "css": null,
            "display_name": "GinoMachino",
            "id": "ginomachino",
            "is_group": false,
            "mod_urls": null,
            "moderator_badge": null,
            "set": 366370,
            "twitch_id": 148651829,
            "user_badge_ids": {
                "2": [
                    188355608
                ]
            },
            "user_badges": {
                "2": [
                    "machinobot"
                ]
            },
            "vip_badge": null,
            "youtube_id": null
        },
        "sets": {
            "366370": {
                "_type": 1,
                "css": null,
                "emoticons": [
                    {
                        "created_at": "2016-11-02T14:52:50.395Z",
                        "css": null,
                        "height": 32,
                        "hidden": false,
                        "id": 139407,
                        "last_updated": "2016-11-08T21:26:39.377Z",
                        "margins": null,
                        "modifier": false,
                        "name": "LULW",
                        "offset": null,
                        "owner": {
                            "_id": 53544,
                            "display_name": "Ian678",
                            "name": "ian678"
                        },
                        "public": true,
                        "status": 1,
                        "urls": {
                            "1": "\/\/cdn.frankerfacez.com\/emote\/139407\/1",
                            "2": "\/\/cdn.frankerfacez.com\/emote\/139407\/2",
                            "4": "\/\/cdn.frankerfacez.com\/emote\/139407\/4"
                        },
                        "usage_count": 148783,
                        "width": 28
                    },
                    {
                        "created_at": "2018-11-12T16:03:21.331Z",
                        "css": null,
                        "height": 23,
                        "hidden": false,
                        "id": 295554,
                        "last_updated": "2018-11-15T08:31:33.401Z",
                        "margins": null,
                        "modifier": false,
                        "name": "WhiteKnight",
                        "offset": null,
                        "owner": {
                            "_id": 333730,
                            "display_name": "cccclone",
                            "name": "cccclone"
                        },
                        "public": true,
                        "status": 1,
                        "urls": {
                            "1": "\/\/cdn.frankerfacez.com\/emote\/295554\/1",
                            "2": "\/\/cdn.frankerfacez.com\/emote\/295554\/2",
                            "4": "\/\/cdn.frankerfacez.com\/emote\/295554\/4"
                        },
                        "usage_count": 35,
                        "width": 20
                    }
                ],
                "icon": null,
                "id": 366370,
                "title": "Channel: GinoMachino"
            }
        }
    }
    */

    Set[string] sets;  ///
}


// ErrorResponse
/++
    JSON schema of the error response from the FrankerFaceZ API.
 +/
struct ErrorResponse
{
    /*
    {
        "error": "Not Found",
        "message": "No such room",
        "status": 404
    }
    */

    string error;  ///
    string message;  ///
    uint status;  ///
}


package:


// getFFZEmotes
/++
    Fetches FrankerFaceZ emotes for a given channel.

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        emoteMap = Pointer to the `bool[string]` associative array to store
            the fetched emotes in.
        id = Numeric Twitch user/channel ID.
        caller = Name of the calling function.

    See_Also:
        https://www.frankerfacez.com
 +/
auto getFFZEmotes(
    TwitchPlugin plugin,
    bool[string]* emoteMap,
    const ulong id,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `getFFZEmotes` from outside a fiber")
in (id, "Tried to get FFZ emotes with an unset ID")
{
    import kameloso.plugins : sendHTTPRequest;
    import asdf.serialization : deserialize;
    import std.conv : to;

    immutable url = "https://api.frankerfacez.com/v1/room/id/" ~ id.to!string;

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
            try writeln(httpResponse.body.parseJSON.toPrettyString);
            catch (Exception _) {}
            printStacktrace();
        }
    }

    switch (httpResponse.code)
    {
    case 200:
        // 200 OK
        break;

    case 404:
        // 404 Not Found
        const errorResponse = httpResponse.body.deserialize!ErrorResponse;

        if (errorResponse.message == "No such room")
        {
            // Benign
            return size_t(0);
        }

        throw new Exception(errorResponse.message);

    default:
        // Some other error
        const errorResponse = httpResponse.body.deserialize!ErrorResponse;
        throw new Exception(errorResponse.message);
    }

    const response = httpResponse.body.deserialize!Response;

    size_t numAdded;

    foreach (const emoteSet; response.sets)
    {
        foreach (const emote; emoteSet.emoticons)
        {
            (*emoteMap)[emote.name] = true;
            ++numAdded;
        }
    }

    return numAdded;
}


// getFFZEmotesGlobal
/++
    Fetches global FrankerFaceZ emotes.

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        emoteMap = Pointer to the `bool[string]` associative array to store
            the fetched emotes in.
        _ = Unused, for signature compatibility with [getFFZEmotes].
        caller = Name of the calling function.

    See_Also:
        https://www.frankerfacez.com
 +/
auto getFFZEmotesGlobal(
    TwitchPlugin plugin,
    bool[string]* emoteMap,
    const ulong _ = 0,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `getFFZEmotes` from outside a fiber")
{
    import kameloso.plugins : sendHTTPRequest;
    import asdf.serialization : deserialize, serdeOptional;

    version(none)
    @serdeOptional
    static struct Response
    {
        static struct Set
        {

        }
        /*
        {
            "default_sets": [
                3,
                1539687
            ],
            "sets": {
                "1532818": {
                    "_type": 1,
                    "css": null,
                    "emoticons": [
                        {
                            "artist": null,
                            "created_at": "2023-03-04T20:17:47.814Z",
                            "css": null,
                            "height": 32,
                            "hidden": false,
                            "id": 720507,
                            "last_updated": null,
                            "margins": null,
                            "modifier": true,
                            "modifier_flags": 12289,
                            "name": "ffzHyper",
                            "offset": null,
                            "owner": {
                                "_id": 1,
                                "display_name": "SirStendec",
                                "name": "sirstendec"
                            },
                            "public": false,
                            "status": 1,
                            "urls": {
                                [...]
                            },
                            "usage_count": 1,
                            "width": 32
                        },
                        {
                            "artist": null,
                            "created_at": "2023-03-04T20:17:47.861Z",
                            "css": null,
                            "height": 32,
                            "hidden": false,
                            "id": 720510,
                            "last_updated": null,
                            "margins": null,
                            "modifier": true,
                            "modifier_flags": 2049,
                            "name": "ffzRainbow",
                            "offset": null,
                            "owner": {
                                "_id": 1,
                                "display_name": "SirStendec",
                                "name": "sirstendec"
                            },
                            "public": false,
                            "status": 1,
                            "urls": {
                                [...]
                            },
                            "usage_count": 1,
                            "width": 32
                        },
                        [...],
                    ],
                    "icon": null,
                    "id": 3,
                    "title": "Global Emotes"
                }
            }
            "users": {
                "1532818": [...]
            }
        }
         */
    }

    immutable url = "https://api.frankerfacez.com/v1/set/global";

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
            try writeln(httpResponse.body.parseJSON.toPrettyString);
            catch (Exception _) {}
            printStacktrace();
        }
    }

    switch (httpResponse.code)
    {
    case 200:
        // 200 OK
        break;

    default:
        // Some other error
        const errorResponse = httpResponse.body.deserialize!ErrorResponse;
        throw new Exception(errorResponse.message);
    }

    const response = httpResponse.body.deserialize!Response;

    size_t numAdded;

    foreach (const emoteSet; response.sets)
    {
        foreach (const emote; emoteSet.emoticons)
        {
            (*emoteMap)[emote.name] = true;
            ++numAdded;
        }
    }

    return numAdded;
}
