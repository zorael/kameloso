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
import core.thread.fiber : Fiber;

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
uint getFFZEmotes(
    TwitchPlugin plugin,
    bool[string]* emoteMap,
    const ulong id,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `getFFZEmotes` from outside a fiber")
in (id, "Tried to get FFZ emotes with an unset ID")
{
    import kameloso.plugins : sendHTTPRequest;
    import kameloso.net : ErrorJSONException, UnexpectedJSONException;
    import std.conv : to;
    import std.json : JSONType, parseJSON;

    immutable url = "https://api.frankerfacez.com/v1/room/id/" ~ id.to!string;

    immutable response = sendHTTPRequest(
        plugin: plugin,
        url: url,
        caller: caller);

    immutable responseJSON = parseJSON(response.body);

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
    /*
    {
        "error": "Not Found",
        "message": "No such room",
        "status": 404
    }
     */

    immutable setsJSON = "sets" in responseJSON;

    if (!setsJSON)
    {
        if (immutable messageJSON = "message" in responseJSON)
        {
            if (messageJSON.str == "No such room")
            {
                // Benign
                return 0;
            }
        }

        enum message = `No "sets" key`;
        throw new UnexpectedJSONException(message, responseJSON);
    }

    uint numAdded;

    foreach (immutable setJSON; (*setsJSON).object)
    {
        if (immutable emoticonsArrayJSON = "emoticons" in setJSON)
        {
            foreach (immutable emoteJSON; emoticonsArrayJSON.array)
            {
                immutable emoteName = emoteJSON["name"].str;
                (*emoteMap)[emoteName] = true;
                ++numAdded;
            }

            // Probably all done as there only seems to be one set,
            // but keep iterating in case we're wrong
            //return;
        }
    }

    // All done
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
uint getFFZEmotesGlobal(
    TwitchPlugin plugin,
    bool[string]* emoteMap,
    const ulong _ = 0,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `getFFZEmotes` from outside a fiber")
{
    import kameloso.plugins : sendHTTPRequest;
    import kameloso.net : UnexpectedJSONException;
    import std.json : JSONType, parseJSON;

    immutable url = "https://api.frankerfacez.com/v1/set/global";

    immutable response = sendHTTPRequest(
        plugin: plugin,
        url: url,
        caller: caller);

    immutable responseJSON = parseJSON(response.body);

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

    immutable setsJSON = "sets" in responseJSON;

    if (!setsJSON)
    {
        enum message = `No "sets" key`;
        throw new UnexpectedJSONException(message, responseJSON);
    }

    uint numAdded;

    foreach (immutable setJSON; (*setsJSON).object)
    {
        if (immutable emoticonsArrayJSON = "emoticons" in setJSON)
        {
            foreach (immutable emoteJSON; emoticonsArrayJSON.array)
            {
                immutable emoteName = emoteJSON["name"].str;
                (*emoteMap)[emoteName] = true;
                ++numAdded;
            }

            // Probably all done as there only seems to be one set,
            // but keep iterating in case we're wrong
            //return;
        }
    }

    return numAdded;
}
