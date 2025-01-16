/++
    Functions for importing custom 7tv emotes.

    See_Also:
        https://7tv.app

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
        emoteMap = Reference to the `bool[dstring]` associative array to store
            the fetched emotes in.
        id = Numeric Twitch user/channel ID.
        caller = Name of the calling function.

    See_Also:
        https://7tv.app
 +/
uint get7tvEmotes(
    TwitchPlugin plugin,
    ref bool[dstring] emoteMap,
    const uint id,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `get7tvEmotes` from outside a fiber")
in (id, "Tried to get 7tv emotes with an unset ID")
{
    import kameloso.plugins.twitch.api : sendHTTPRequest;
    import kameloso.plugins.twitch.common : ErrorJSONException, UnexpectedJSONException;
    import std.conv : to;
    import std.json : JSONType, parseJSON;

    try
    {
        immutable url = "https://7tv.io/v3/users/twitch/" ~ id.to!string;
        immutable response = sendHTTPRequest(plugin, url, caller);
        immutable responseJSON = parseJSON(response.str);

        /+
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
         +/

        if (responseJSON.type != JSONType.object)
        {
            enum message = "`get7tvEmotes` response has unexpected JSON " ~
                "(wrong JSON type)";
            throw new UnexpectedJSONException(message, responseJSON);
        }

        immutable emoteSetJSON = "emote_set" in responseJSON;

        if (!emoteSetJSON)
        {
            enum message = "`get7tvEmotes` response has unexpected JSON " ~
                `(no "emote_set" key)`;
            throw new UnexpectedJSONException(message, responseJSON);
        }

        if (emoteSetJSON.type != JSONType.object) return 0;  // No emotes

        immutable emotesJSON = "emotes" in *emoteSetJSON;
        uint numAdded;

        foreach (immutable emoteJSON; emotesJSON.array)
        {
            import std.conv : to;
            immutable emoteName = emoteJSON["name"].str.to!dstring;
            emoteMap[emoteName] = true;
            ++numAdded;
        }

        // All done
        return numAdded;
    }
    catch (ErrorJSONException e)
    {
        /+
        {
            "error": "Unknown User",
            "error_code": 70442,
            "status": "Not Found",
            "status_code": 404
        }
         +/

        const errorJSON = "error" in e.json;

        if (errorJSON)
        {
            switch (errorJSON.str)
            {
            case "Unknown User":
                // This should never happen but stop attempt if it does
                return 0;

            case "user not found":
                // User has no user-specific 7tv emotes; benign failure
                return 0;

            default:
                break;
            }
        }

        throw e;
    }
    catch (Exception e)
    {
        throw e;
    }
}


// get7tvEmotesGlobal
/++
    Fetches global 7tv emotes.

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        emoteMap = Reference to the `bool[dstring]` associative array to store
            the fetched emotes in.
        _ = Unused, for signature compatibility with [get7tvEmotes].
        caller = Name of the calling function.

    See_Also:
        https://7tv.app
 +/
uint get7tvEmotesGlobal(
    TwitchPlugin plugin,
    ref bool[dstring] emoteMap,
    const uint _ = 0,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `get7tvEmotesGlobal` from outside a fiber")
{
    import kameloso.plugins.twitch.api : sendHTTPRequest;
    import kameloso.plugins.twitch.common : UnexpectedJSONException;
    import std.json : JSONType, parseJSON;

    enum url = "https://7tv.io/v3/emote-sets/global";
    immutable response = sendHTTPRequest(plugin, url, caller);
    immutable responseJSON = parseJSON(response.str);

    /+
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
     +/

    if (responseJSON.type != JSONType.object)
    {
        enum message = "`get7tvEmotesGlobal` response has unexpected JSON " ~
            "(wrong JSON type)";
        throw new UnexpectedJSONException(message, responseJSON);
    }

    immutable emotesJSON = "emotes" in responseJSON;

    if (!emotesJSON)
    {
        enum message = "`get7tvEmotesGlobal` response has unexpected JSON " ~
            `(no "emotes" key)`;
        throw new UnexpectedJSONException(message, responseJSON);
    }

    uint numAdded;

    foreach (const emoteJSON; emotesJSON.array)
    {
        import std.conv : to;
        immutable emoteName = emoteJSON["name"].str.to!dstring;
        emoteMap[emoteName] = true;
        ++numAdded;
    }

    return numAdded;
}
