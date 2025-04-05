/++
    Functions for importing custom 7tv emotes.

    See_Also:
        https://7tv.app,
        [kameloso.plugins.twitch],
        [kameloso.plugins.twitch.emotes]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.twitch.emotes.seventv;

version(TwitchSupport):
version(WithTwitchPlugin):

private:

import kameloso.plugins.twitch : TwitchPlugin;
import core.thread.fiber : Fiber;

package:


// get7tvEmotes
/++
    Fetches 7tv emotes for a given channel.

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        emoteMap = Pointer to the `bool[string]` associative array to store
            the fetched emotes in.
        id = Numeric Twitch user/channel ID.
        caller = Name of the calling function.

    See_Also:
        https://7tv.app
 +/
auto get7tvEmotes(
    TwitchPlugin plugin,
    bool[string]* emoteMap,
    const ulong id,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `get7tvEmotes` from outside a fiber")
in (id, "Tried to get 7tv emotes with an unset ID")
{
    import kameloso.plugins : sendHTTPRequest;
    import asdf.serialization : deserialize, serdeOptional;
    import std.algorithm.searching : startsWith;
    import std.conv : to;
    import std.typecons : Nullable;

    @serdeOptional
    static struct Response
    {
        @serdeOptional
        static struct EmoteSet
        {
            @serdeOptional
            static struct Emote
            {
                string name;
            }

            uint emote_count;
            uint capacity;
            Emote[] emotes;
        }

        /*
        {
            "display_name": "LobosJr",
            "emote_capacity": 1000,
            "emote_set": {
                "capacity": 1000,
                "emote_count": 872,
                "emotes": [
                    {
                        "actor_id": null,
                        "data": {
                            "animated": true,
                            "flags": 0,
                            "host": {
                                "files": [],
                                "url": "\/\/cdn.7tv.app\/emote\/60ae2e3db2ecb01505c6f69d"
                            },
                            "id": "60ae2e3db2ecb01505c6f69d",
                            "lifecycle": 3,
                            "listed": true,
                            "name": "ViolinTime",
                            "owner": {
                                "avatar_url": "\/\/static-cdn.jtvnw.net\/jtv_user_pictures\/583dd5ac-2fe8-4ead-a20d-e10770118c5f-profile_image-70x70.png",
                                "display_name": "heCrzy",
                                "id": "60635b50452cea4685f26b34",
                                "roles": [
                                    "62b48deb791a15a25c2a0354"
                                ],
                                "style": {},
                                "username": "hecrzy"
                            },
                            "state": [
                                "LISTED",
                                "PERSONAL"
                            ]
                        },
                        "flags": 0,
                        "id": "60ae2e3db2ecb01505c6f69d",
                        "name": "ViolinTime",
                        "timestamp": 1657657741507
                    },
                    {
                        "actor_id": null,
                        "data": {
                            "animated": false,
                            "flags": 0,
                            "host": {
                                "files": [],
                            "url": "\/\/cdn.7tv.app\/emote\/60ae3e54259ac5a73e56a426"
                            },
                            "id": "60ae3e54259ac5a73e56a426",
                            "lifecycle": 3,
                            "listed": true,
                            "name": "Hmm",
                            "owner": {
                                "avatar_url": "\/\/static-cdn.jtvnw.net\/jtv_user_pictures\/4207f38c-73f0-4487-a7b2-07ccb27667d1-profile_image-70x70.png",
                                "display_name": "LNSc",
                                "id": "60772a85a807bed00612d1ee",
                                "roles": [
                                    "62b48deb791a15a25c2a0354"
                                ],
                                "style": {},
                                "username": "lnsc"
                            },
                            "state": [
                                "LISTED",
                                "PERSONAL"
                            ]
                        },
                        "flags": 0,
                        "id": "60ae3e54259ac5a73e56a426",
                        "name": "Hmm",
                        "timestamp": 1657657741507
                    },
            [...]
         */
        /*
        {
            "display_name": "zorael",
            "emote_capacity": 1000,
            "emote_set": null,
            "emote_set_id": null,
            "id": "22216721",
            "linked_at": 1684771392706,
            "platform": "TWITCH",
            "user": {
                "avatar_url": "https:\/\/static-cdn.jtvnw.net\/jtv_user_pictures\/eafaed16-ad74-40e1-ac4a-1c40fafb78f9-profile_image-300x300.jpeg",
                "connections": [
                    {
                        "display_name": "zorael",
                        "emote_capacity": 1000,
                        "emote_set": null,
                        "emote_set_id": null,
                        "id": "22216721",
                        "linked_at": 1684771392706,
                        "platform": "TWITCH",
                        "username": "zorael"
                    }
                ],
                "created_at": 1684771392000,
                "display_name": "zorael",
                "id": "01H1236JG00005HNCSM10T04VJ",
                "roles": [
                    "01G68MMQFR0007J6GNM9E2M0TM"
                ],
                "style": {},
                "username": "zorael"
            },
            "username": "zorael"
        }
         */

        string display_name;
        string username;
        uint emote_capacity;
        @serdeOptional Nullable!EmoteSet emote_set;
    }

    static struct ErrorResponse
    {
        /*
        {
            "error": "user not found",
            "error_code": 12000,
            "status": "Not Found"
        }
         */
        /*
        {
            "error": "Unknown User",
            "error_code": 70442,
            "status": "Not Found",
            "status_code": 404
        }
         */

        string error;
        uint error_code;
        string status;

        @serdeOptional uint status_code;
    }

    immutable url = "https://7tv.io/v3/users/twitch/" ~ id.to!string;

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

    if (httpResponse.body.startsWith("error"))
    {
        enum message = `Error in response body`;
        throw new Exception(message);
    }

    switch (httpResponse.code)
    {
    case 200:
        // 200 OK
        break;

    default:
        const errorResponse = httpResponse.body.deserialize!ErrorResponse;

        switch (errorResponse.error)
        {
        case "user not found":  // User has no user-specific 7tv emotes; benign failure
        case "Unknown User":  // This should never happen but stop attempt if it does
            return size_t(0);

        default:
            throw new Exception(errorResponse.error);
        }
    }

    const response = httpResponse.body.deserialize!Response;

    if (response.emote_set.isNull) return size_t(0);

    foreach (immutable emote; response.emote_set.get.emotes)
    {
        (*emoteMap)[emote.name] = true;
    }

    // All done
    return response.emote_set.get.emotes.length;
}


// get7tvEmotesGlobal
/++
    Fetches global 7tv emotes.

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        emoteMap = Pointer to the `bool[string]` associative array to store
            the fetched emotes in.
        _ = Unused, for signature compatibility with [get7tvEmotes].
        caller = Name of the calling function.

    See_Also:
        https://7tv.app
 +/
auto get7tvEmotesGlobal(
    TwitchPlugin plugin,
    bool[string]* emoteMap,
    const ulong _ = 0,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `get7tvEmotesGlobal` from outside a fiber")
{
    import kameloso.plugins : sendHTTPRequest;
    import asdf.serialization : deserialize, serdeOptional;
    import std.algorithm.searching : startsWith;
    import std.json : JSONType, parseJSON;

    @serdeOptional
    static struct Response
    {
        @serdeOptional
        static struct Emote
        {
            string name;
        }

        /*
        {
            "capacity": 50,
            "emote_count": 40,
            "emotes": [
                {
                    "actor_id": null,
                    "data": {
                        "animated": true,
                        "flags": 256,
                        "host": {
                            "files": [],
                        "url": "\/\/cdn.7tv.app\/emote\/61159e9903dae26bc706eaa6"
                        },
                        "id": "61159e9903dae26bc706eaa6",
                        "lifecycle": 3,
                        "listed": true,
                        "name": "RainTime",
                        "owner": {
                            "avatar_url": "\/\/cdn.7tv.app\/pp\/60f06993e48dc1dc2fc7e4a3\/80feeab5d56d41e38b030857beaacd43",
                            "display_name": "eternal_pestilence",
                            "id": "60f06993e48dc1dc2fc7e4a3",
                            "roles": [
                                "62b48deb791a15a25c2a0354"
                            ],
                            "style": {},
                            "username": "eternal_pestilence"
                        },
                        "state": [
                            "LISTED",
                            "PERSONAL"
                        ]
                    },
                    "flags": 1,
                    "id": "61159e9903dae26bc706eaa6",
                    "name": "RainTime",
                    "timestamp": 1657657127639
                },
            }
        }
         */

        // "error code: 1033"

        uint capacity;
        uint emote_count;
        Emote[] emotes;
    }

    enum url = "https://7tv.io/v3/emote-sets/global";

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

    if (httpResponse.body.startsWith("error"))
    {
        enum message = `Error in response body`;
        throw new Exception(message);
    }

    const response = httpResponse.body.deserialize!Response;

    foreach (const emote; response.emotes)
    {
        (*emoteMap)[emote.name] = true;
    }

    return response.emotes.length;
}
