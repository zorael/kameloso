/++
    Functions for importing official Twitch emotes.

    See_Also:
        https://7tv.app,
        [kameloso.plugins.twitch],
        [kameloso.plugins.twitch.emotes]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.twitch.emotes.twitch;

version(TwitchSupport):
version(WithTwitchPlugin):

private:

import kameloso.plugins.twitch : TwitchPlugin;
import core.thread.fiber : Fiber;

package:


// getTwitchEmotesGlobal
/++
    Fetches global Twitch emotes.

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        emoteMap = Pointer to the `bool[string]` associative array to store
            the fetched emotes in.
        _ = Unused, for signature compatibility.
        caller = Name of the calling function.

    See_Also:
        https://dev.twitch.tv/docs/api/reference/#get-global-emotes
 +/
auto getTwitchEmotesGlobal(
    TwitchPlugin plugin,
    bool[string]* emoteMap,
    const ulong _ = 0,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `getTwitchEmotesGlobal` from outside a fiber")
{
    import kameloso.plugins : sendHTTPRequest;
    import kameloso.plugins.twitch.api : ErrorResponse, retryDelegate;
    import kameloso.misc : printStacktrace;
    import asdf.serialization : deserialize, serdeOptional;

    static struct Response
    {
        private import asdf.serialization : serdeIgnore, serdeKeys, serdeOptional;

        @serdeOptional
        static struct Emote
        {
            string name;  ///
        }

        Emote[] data;  ///

        @serdeIgnore
        @serdeKeys("template")
        enum template_ = false;  ///
    }

    static struct GetGlobalEmotesResults
    {
        uint code;
        string error;
        string[] emotes;

        auto success() const { return (code == 200); }

        this(const uint code, const Response response)
        {
            this.code = code;
            this.emotes.length = response.data.length;

            foreach (immutable i, const emote; response.data)
            {
                this.emotes[i] = emote.name;
            }
        }

        this(const uint code, const ErrorResponse errorResponse)
        {
            this.code = code;
            //this.error = errorResponse.error;
            this.error = errorResponse.message;
        }
    }

    enum url = "https://api.twitch.tv/helix/chat/emotes/global";

    auto getGlobalEmotesDg()
    {
        immutable httpResponse = sendHTTPRequest(
            plugin: plugin,
            url: url,
            caller: caller,
            authorisationHeader: plugin.transient.authorizationBearer,
            clientID: TwitchPlugin.clientID);

        version(PrintStacktraces)
        {
            scope(failure)
            {
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
            /+
                Successfully retrieved Twitch's list of global emotes.
             +/
            break;

        case 401:
            // 401 Unauthorized
            /+
                The Authorization header is required and must specify a valid
                app access token or user access token.
                The OAuth token is not valid.
                The ID in the Client-Id header must match the Client ID in the OAuth token.
             +/
            goto default;

        default:
            //const errorResponse = httpResponse.body.deserialize!ErrorResponse;
            //return GetGlobalEmotesResults(httpResponse.code, errorResponse);
            return size_t(0);
        }

        const response = httpResponse.body.deserialize!Response;

        foreach (const emote; response.data)
        {
            (*emoteMap)[emote.name] = true;
        }

        //return GetGlobalEmotesResults(httpResponse.code, response);
        return response.data.length;
    }

    return retryDelegate(plugin, &getGlobalEmotesDg);
}
