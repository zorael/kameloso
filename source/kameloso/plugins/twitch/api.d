/++
    Functions for accessing the Twitch API. For internal use.

    See_Also:
        [kameloso.plugins.twitch],
        [kameloso.plugins.twitch.common],
        [kameloso.plugins.twitch.providers.twitch],
        [kameloso.plugins]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.twitch.api;

version(TwitchSupport):
version(WithTwitchPlugin):

private:

import kameloso.plugins;
import kameloso.plugins.twitch;
import kameloso.plugins.twitch.common;
import kameloso.net :
    EmptyDataJSONException,
    ErrorJSONException,
    HTTPQueryException,
    HTTPQueryResponse,
    QueryResponseJSONException,
    UnexpectedJSONException;
import kameloso.tables : HTTPVerb;
import dialect.defs;
import lu.container : MutexedAA;
import core.thread.fiber : Fiber;
import core.time : Duration, seconds;

/+
    Used to print debug information in API functions.
 +/
version(PrintStacktraces)
{
    import kameloso.misc : printStacktrace;
    import std.stdio : writeln;
}

package:


// retryDelegate
/++
    Retries a passed delegate until it no longer throws or until the hardcoded
    number of retries
    ([kameloso.plugins.twitch.TwitchPlugin.delegateRetries|TwitchPlugin.delegateRetries])
    is reached, or forever if `endlessly` is passed.

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        dg = Delegate to call.
        async = Whether or not the delegate should be called asynchronously,
            scheduling attempts using [kameloso.plugins.common.scheduling.delay|delay].
        endlessly = Whether or not to endlessly retry.
        retryDelay = How long to wait between retries.

    Returns:
        Whatever the passed delegate returns.
 +/
auto retryDelegate(Dg)
    (TwitchPlugin plugin,
    Dg dg,
    const bool async = true,
    const bool endlessly = false,
    const Duration retryDelay = 4.seconds)
in ((!async || Fiber.getThis()), "Tried to call async `retryDelegate` from outside a fiber")
{
    immutable retries = endlessly ?
        size_t.max :
        TwitchPlugin.delegateRetries;

    foreach (immutable i; 0..retries)
    {
        try
        {
            if (i > 0)
            {
                if (async)
                {
                    import kameloso.plugins.common.scheduling : delay;
                    delay(plugin, retryDelay, yield: true);
                }
                else
                {
                    import core.thread : Thread;
                    Thread.sleep(retryDelay);
                }
            }
            return dg();
        }
        catch (Exception e)
        {
            handleRetryDelegateException(
                e,
                i,
                endlessly: endlessly,
                headless: plugin.state.coreSettings.headless);
            continue;  // If we're here the above didn't throw; continue
        }
    }

    assert(0, "Unreachable");
}


// handleRetryDelegateException
/++
    Handles exceptions thrown by [retryDelegate].

    Params:
        base = The exception to handle.
        i = The current retry count.
        endlessly = Whether or not to endlessly retry.
        headless = Whether or not we are running headlessly, in which case all
            terminal output will be skipped.

    Throws:
        [kameloso.plugins.twitch.common.MissingBroadcasterTokenException|MissingBroadcasterTokenException]
        if the delegate throws it.
        [kameloso.plugins.twitch.common.InvalidCredentialsException|InvalidCredentialsException]
        likewise.
        [kameloso.net.EmptyDataJSONException|EmptyDataJSONException] also.
        [kameloso.net.ErrorJSONException|ErrorJSONExceptoin] if the delegate
        throws it and the JSON embedded contains an error code in the 400-499 range.
        [object.Exception|Exception] if the delegate throws it and `endlessly` is not passed.
 +/
private auto handleRetryDelegateException(
    Exception base,
    const size_t i,
    const bool endlessly,
    const bool headless)
{
    if (auto e = cast(MissingBroadcasterTokenException)base)
    {
        // This is never a transient error
        throw e;
    }
    else if (auto e = cast(InvalidCredentialsException)base)
    {
        // Neither is this
        throw e;
    }
    else if (auto e = cast(EmptyDataJSONException)base)
    {
        // Should never be transient?
        throw e;
    }
    else if (auto e = cast(ErrorJSONException)base)
    {
        const statusJSON = "status" in e.json;
        if ((statusJSON.integer >= 400) && (statusJSON.integer < 500))
        {
            // Also never transient
            throw e;
        }
        return;  //continue;
    }
    else if (auto e = cast(HTTPQueryException)base)
    {
        import kameloso.constants : MagicErrorStrings;

        if (e.msg == MagicErrorStrings.sslLibraryNotFoundRewritten)
        {
            // Missing OpenSSL
            throw e;
        }

        // Drop down
    }

    if (endlessly)
    {
        // Unconditionally continue, but print the exception once if it's erroring
        version(PrintStacktraces)
        {
            if (!headless)
            {
                alias printExceptionAfterNFailures = TwitchPlugin.delegateRetries;

                if (i == printExceptionAfterNFailures)
                {
                    printRetryDelegateException(base);
                }
            }
        }
        return;  //continue;
    }
    else
    {
        // Retry until we reach the retry limit, then print if we should, before rethrowing
        if (i < TwitchPlugin.delegateRetries-1) return;  //continue;

        version(PrintStacktraces)
        {
            if (!headless)
            {
                printRetryDelegateException(base);
            }
        }
        throw base;
    }
}


// printRetryDelegateException
/++
    Prints out details about exceptions passed from [retryDelegate].
    [retryDelegate] itself rethrows them when we return, so no need to do that here.

    Gated behind version `PrintStacktraces`.

    Params:
        base = The exception to print.
 +/
version(PrintStacktraces)
void printRetryDelegateException(/*const*/ Exception base)
{
    import kameloso.common : logger;
    import std.json : JSONException, parseJSON;
    import std.stdio : stdout, writeln;

    logger.trace(base);

    if (auto e = cast(HTTPQueryException)base)
    {
        //logger.trace(e);

        try
        {
            writeln(parseJSON(e.responseBody).toPrettyString);
        }
        catch (JSONException _)
        {
            writeln(e.responseBody);
        }

        stdout.flush();
    }
    else if (auto e = cast(EmptyDataJSONException)base)
    {
        // Must be before TwitchJSONException below
        //logger.trace(e);
    }
    else if (auto e = cast(QueryResponseJSONException)base)
    {
        // UnexpectedJSONException or ErrorJSONException
        //logger.trace(e);
        writeln(e.json.toPrettyString);
        stdout.flush();
    }
    else /*if (auto e = cast(Exception)base)*/
    {
        //logger.trace(e);
    }
}


// getChatters
/++
    Get the JSON representation of everyone currently in a broadcaster's channel.

    It is not updated in realtime, so it doesn't make sense to call this often.

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        broadcaster = The broadcaster to look up chatters for.
        caller = Name of the calling function.

    Returns:
        A Voldemort struct with `broadcaster`, `moderators`, `vips`, `staff`,
        `admins`, `globalMods`, `viewers` and `chatterCount` members.

    Throws:
        [UnexpectedJSONException] on unexpected JSON.

    See_Also:
        https://dev.twitch.tv/docs/api/reference/#get-chatters
 +/
auto getChatters(
    TwitchPlugin plugin,
    const string broadcaster,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `getChatters` from outside a fiber")
in (broadcaster.length, "Tried to get chatters with an empty broadcaster string")
{
    import std.conv : text;
    import std.json : parseJSON;

    static struct Chatters
    {
        private import std.json : JSONValue;

        uint code;
        string error;
        string broadcaster;
        string[] moderators;
        string[] vips;
        string[] staff;
        string[] admins;
        string[] globalMods;
        string[] viewers;
        uint chatterCount;

        auto success() const { return (code == 200); }

        this(const uint code) { this.code = code; }

        this(const uint code, const string error)
        {
            this.code = code;
            this.error = error;
        }

        this(const uint code, const JSONValue json)
        {
            static auto mapJSONArrayToStringArray(const JSONValue json)
            {
                import std.algorithm.iteration : map;
                import std.array : array;

                return json.array
                    .map!(a => a.str)
                    .array;
            }

            this.code = code;
            this.broadcaster = json["broadcster"].array[0].str;
            this.moderators = mapJSONArrayToStringArray(json["moderators"]);
            this.vips = mapJSONArrayToStringArray(json["vips"]);
            this.staff = mapJSONArrayToStringArray(json["staff"]);
            this.admins = mapJSONArrayToStringArray(json["admins"]);
            this.globalMods = mapJSONArrayToStringArray(json["global_mods"]);
            this.viewers = mapJSONArrayToStringArray(json["viewers"]);
            this.chatterCount = cast(uint)json["chatter_count"].integer;
        }
    }

    immutable chattersURL = text("https://tmi.twitch.tv/group/user/", broadcaster, "/chatters");

    auto getChattersDg()
    {
        immutable response = sendHTTPRequest(
            plugin: plugin,
            url: chattersURL,
            caller: caller,
            authorisationHeader: plugin.transient.authorizationBearer,
            clientID: TwitchPlugin.clientID);

        immutable responseJSON = parseJSON(response.body);

        switch (response.code)
        {
        case 200:
            // 200 OK
            /+
                Successfully retrieved the broadcaster’s list of chatters.
             +/
            break;

        case 400:
            // 400 Bad Request
            /+
                The broadcaster_id query parameter is required.
                The ID in the broadcaster_id query parameter is not valid.
                The moderator_id query parameter is required.
                The ID in the moderator_id query parameter is not valid.
             +/
            goto default;

        case 401:
            // 401 Unauthorized
            /+
                The ID in the moderator_id query parameter must match the
                user ID in the access token.
                The Authorization header is required and must contain a user access token.
                The user access token must include the moderator:read:chatters scope.
                The access token is not valid.
                The client ID specified in the Client-Id header does not match
                the client ID specified in the access token.
             +/
            goto default;

        case 403:
            // 403 Forbidden
            /+
                The user in the moderator_id query parameter is not one of the
                broadcaster's moderators.
             +/
            goto default;

        default:
            version(PrintStacktraces)
            {
                writeln(response.code);
                writeln(responseJSON.toPrettyString);
                printStacktrace();
            }

            if (immutable errorJSON = "error" in responseJSON)
            {
                return Chatters(response.code, errorJSON.str);
            }
            else
            {
                return Chatters(response.code);
            }
        }

        /*
        {
            "_links": {},
            "chatter_count": 93,
            "chatters": {
                "broadcaster": [
                    "streamernick"
                ],
                "vips": [],
                "moderators": [
                    "somemod"
                ],
                "staff": [],
                "admins": [],
                "global_mods": [],
                "viewers": [
                    "abc",
                    "def",
                    "ghi"
                ]
            }
        }
         */

        immutable chattersJSON = "chatters" in responseJSON;

        if (!chattersJSON)
        {
            // For some reason we received an object that didn't contain chatters
            enum message = "`getChatters` response has unexpected JSON " ~
                `(no "chatters" key)`;
            throw new UnexpectedJSONException(message, responseJSON);
        }

        return Chatters(response.code, *chattersJSON);
    }

    return retryDelegate(plugin, &getChattersDg);
}


// getValidation
/++
    Validates an access key, retrieving information about it.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        authToken = Authorisation token to validate.
        async = Whether or not the validation should be done asynchronously, using fibers.
        caller = Name of the calling function.

    Returns:
        A Voldemort struct with `clientID`, `login`, `userID` and `expiresIn` members.

    Throws:
        [kameloso.plugins.twitch.common.InvalidCredentialsException|InvalidCredentialsException]
        on invalid credentials.
        [kameloso.net.UnexpectedJSONException|UnexpectedJSONException] on unexpected JSON received.
        [kameloso.net.HTTPQueryException|HTTPQueryException] on other failure.

    See_Also:
        https://dev.twitch.tv/docs/authentication/validate-tokens
 +/
auto getValidation(
    TwitchPlugin plugin,
    /*const*/ string authToken,
    const bool async,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `getValidation` from outside a fiber")
in (authToken.length, "Tried to validate an empty Twitch authorisation token")
{
    import std.algorithm.searching : startsWith;
    import std.json : JSONValue, parseJSON;

    static struct ValidationResults
    {
        private import core.time : Duration, seconds;

        uint code;
        //string error;
        string clientID;
        string login;
        ulong userID;
        Duration expiresIn;

        auto success() const { return (code == 200); }

        this(const uint code) { this.code = code; }

        /*this(const uint code, const string error)
        {
            this.code = code;
            this.error = error;
        }*/

        this(const uint code, const JSONValue json)
        {
            import std.conv : to;

            /*
            {
                "client_id": "tjyryd2ojnqr8a51ml19kn1yi2n0v1",
                "expires_in": 5114683,
                "login": "mechawob",
                "scopes": [
                    "channel:moderate",
                    "chat:edit",
                    "chat:read",
                    "moderation:read",
                    "moderator:manage:announcements",
                    "moderator:manage:automod",
                    "moderator:manage:automod_settings",
                    "moderator:manage:banned_users",
                    "moderator:manage:blocked_terms",
                    "moderator:manage:chat_messages",
                    "moderator:manage:chat_settings",
                    "moderator:manage:shield_mode",
                    "moderator:manage:shoutouts",
                    "moderator:manage:unban_requests",
                    "moderator:manage:warnings",
                    "moderator:read:chatters",
                    "moderator:read:followers",
                    "user:manage:whispers",
                    "user:read:follows",
                    "user:read:subscriptions",
                    "user:write:chat",
                    "whispers:edit",
                    "whispers:read"
                ],
                "user_id": "790938342"
            }
             */

            this.code = code;
            this.clientID = json["client_id"].str;
            this.login = json["login"].str;
            this.userID = json["user_id"].str.to!ulong;
            this.expiresIn = json["expires_in"].integer.seconds;
        }
    }

    auto throwIfHasErrorKey(const JSONValue json)
    {
        // {"error":"Unauthorized","status":401,"message":"Must provide a valid Client-ID or OAuth token"}
        /*
        {
            "error": "Unauthorized",
            "message": "Client ID and OAuth token do not match",
            "status": 401
        }
         */

        const errorJSON = "error" in json;
        if (!errorJSON) return;

        const statusJSON = "status" in *errorJSON;
        if (!statusJSON) return;

        if (statusJSON.integer == 401)
        {
            switch ((*errorJSON)["message"].str)
            {
            case "invalid access token":
                enum message = "API token has expired";
                throw new InvalidCredentialsException(message, *errorJSON);

            case "missing authorization token":
                enum message = "Missing API token";
                throw new InvalidCredentialsException(message, *errorJSON);

            default:
                //drop down
                break;
            }
        }
    }

    enum url = "https://id.twitch.tv/oauth2/validate";

    // Validation needs an "Authorization: OAuth xxx" header, as opposed to the
    // "Authorization: Bearer xxx" used everywhere else.
    authToken = authToken.startsWith("oauth:") ?
        authToken[6..$] :
        authToken;
    immutable authorisationHeader = "OAuth " ~ authToken;

    auto getValidationDg()
    {
        HTTPQueryResponse response;

        if (async)
        {
            response = sendHTTPRequest(
                plugin: plugin,
                url: url,
                caller: caller,
                authorisationHeader: authorisationHeader);
        }
        else
        {
            import kameloso.net : HTTPRequest, issueSyncHTTPRequest;

            version(TraceHTTPRequests)
            {
                import kameloso.common : logger;
                enum tracePattern = "get: <i>%s<t> (%s)";
                logger.tracef(tracePattern, url, __FUNCTION__);
            }

            const request = HTTPRequest(
                id: 0,
                url: url,
                authorisationHeader: authorisationHeader        ,
                caBundleFile: plugin.state.connSettings.caBundleFile);

            response = issueSyncHTTPRequest(request);

            if (response.exceptionText.length || (response.code < 10))
            {
                throw new HTTPQueryException(
                    response.exceptionText,
                    response.body,
                    response.error,
                    response.code);
            }
            else if (response == HTTPQueryResponse.init)
            {
                import kameloso.net : EmptyResponseException;
                throw new EmptyResponseException;
            }
        }

        immutable responseJSON = parseJSON(response.body);

        throwIfHasErrorKey(responseJSON);

        if ("client_id" !in responseJSON)
        {
            enum message = "`getValidation` response has unexpected JSON " ~
                `(no "client_id" key)`;
            throw new UnexpectedJSONException(message, responseJSON);
        }

        return ValidationResults(response.code, responseJSON);
    }

    return retryDelegate(plugin, &getValidationDg, async: true, endlessly: true);
}


// getFollowers
/++
    Fetches a list of all followers of the passed channel and caches them in
    the channel's entry in [kameloso.plugins.twitch.TwitchPlugin.rooms|TwitchPlugin.rooms].

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        id = The numerical identifier for the channel.
        caller = Name of the calling function.

    Returns:
        An associative array of [Follower]s keyed by nickname string.

    Throws:
        [kameloso.net.UnexpectedJSONException|UnexpectedJSONException] on unexpected JSON received.

    See_Also:
        https://dev.twitch.tv/docs/api/reference/#get-channel-followers
 +/
auto getFollowers(
    TwitchPlugin plugin,
    const ulong id,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `getFollowers` from outside a fiber")
in (id, "Tried to get followers with an unset ID")
{
    import std.conv : text, to;
    import std.json : parseJSON;

    static struct GetFollowersResults
    {
        uint code;
        string error;
        Follower[string] followers;

        auto success() const { return (code == 200); }

        this(const uint code) { this.code = code; }

        this(const uint code, const string error)
        {
            this.code = code;
            this.error = error;
        }

        this(const uint code, /*const*/ Follower[string] followers)
        {
            this.code = code;
            this.followers = followers;
        }
    }

    //immutable authorizationBearer = getBroadcasterAuthorisation(plugin, id);

    immutable url = "https://api.twitch.tv/helix/channels/followers?first=100&broadcaster_id=" ~ id.to!string;
    Follower[string] followers;
    string after;
    uint responseCode;

    auto getFollowersDg()
    {
        do
        {
            immutable paginatedURL = after.length ?
                text(url, "&after=", after) :
                url;

            immutable response = sendHTTPRequest(
                plugin: plugin,
                url: paginatedURL,
                caller: caller,
                authorisationHeader: plugin.transient.authorizationBearer, //authorizationBearer,
                clientID: TwitchPlugin.clientID);

            immutable responseJSON = parseJSON(response.body);

            switch (response.code)
            {
            case 200:
                // 200 OK
                /+
                    Successfully retrieved the broadcaster’s list of followers.
                 +/
                break;

            case 400:
                // 400 Bad Request
                /+
                    Possible reasons:
                    The broadcaster_id query parameter is required.
                    The broadcaster_id query parameter is not valid.
                 +/
                goto default;

            case 401:
                // 401 Unauthorized
                /+
                    Possible reasons:
                    The ID in the broadcaster_id query parameter must match the user
                    ID in the access token or the user must be a moderator for the
                    specified broadcaster.
                    The Authorization header is required and must contain a user access token.
                    The user access token is missing the moderator:read:followers scope.
                    The OAuth token is not valid.
                    The client ID specified in the Client-Id header does not match
                    the client ID specified in the OAuth token.
                    The user_id parameter was specified but either the user access
                    token is missing the moderator:read:followers scope or the user
                    is not the broadcaster or moderator for the specified channel
                 +/
                goto default;

            default:
                version(PrintStacktraces)
                {
                    writeln(response.code);
                    writeln(responseJSON.toPrettyString);
                    printStacktrace();
                }

                if (immutable errorJSON = "error" in responseJSON)
                {
                    return GetFollowersResults(response.code, errorJSON.str);
                }
                else
                {
                    return GetFollowersResults(response.code);
                }
            }

            /*
            {
                "total": 8
                "data": [
                    {
                    "user_id": "11111",
                    "user_name": "UserDisplayName",
                    "user_login": "userloginname",
                    "followed_at": "2022-05-24T22:22:08Z",
                    },
                    ...
                ],
                "pagination": {
                    "cursor": "eyJiIjpudWxsLCJhIjp7Ik9mZnNldCI6NX19"
                }
            }
             */

            responseCode = response.code;

            immutable dataJSON = "data" in responseJSON;

            if (!dataJSON)
            {
                enum message = "`getFollowers` response has unexpected JSON " ~
                    `(no "data" key)`;
                throw new UnexpectedJSONException(message, responseJSON);
            }

            if (!dataJSON.array.length)
            {
                // No followers
                return GetFollowersResults(response.code, followers);
            }

            foreach (followerJSON; dataJSON.array)
            {
                /*
                "data": [
                    {
                    "user_id": "11111",
                    "user_name": "UserDisplayName",
                    "user_login": "userloginname",
                    "followed_at": "2022-05-24T22:22:08Z",
                    },
                    ...
                ]
                 */
                immutable key = followerJSON["user_name"].str;
                followers[key] = Follower(followerJSON);
            }

            immutable cursor = "cursor" in responseJSON["pagination"];

            after = cursor ?
                cursor.str :
                string.init;
        }
        while (after.length);

        followers.rehash();
        return GetFollowersResults(responseCode, followers);
    }

    return retryDelegate(plugin, &getFollowersDg);
}


// getUser
/++
    Fetches information about a Twitch user and returns it in the form of a
    Voldemort struct with nickname, display name and account ID members.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        name = Optional name of user to look up, if no `id` given.
        id = Optional numeric ID of user to look up, if no `name` given.
        searchByDisplayName = Whether or not to also attempt to look up `name`
            as a display name.
        caller = Name of the calling function.

    Returns:
        Voldemort aggregate struct with `nickname`, `displayName` and `id` members.

    Throws:
        [kameloso.net.UnexpectedJSONException|UnexpectedJSONException] on unexpected JSON received.

    See_Also:
        https://dev.twitch.tv/docs/api/reference/#get-users
 +/
auto getUser(
    TwitchPlugin plugin,
    const string name = string.init,
    const ulong id = 0,
    const bool searchByDisplayName = false,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `getUser` from outside a fiber")
in ((name.length || id),
    "Tried to get Twitch user without supplying a name nor an ID")
{
    import std.conv : to;
    import std.json : parseJSON;

    static struct GetUserResults
    {
        private import std.json : JSONValue;

        uint code;
        string error;
        ulong id;
        string login;
        string displayName;

        auto success() const { return (id && (code == 200)); }

        this(const uint code) { this.code = code; }

        this(const uint code, const string error)
        {
            this.code = code;
            this.error = error;
        }

        this(const uint code, const JSONValue json)
        {
            /*
            {
                "data": [
                    {
                        "id": "141981764",
                        "login": "twitchdev",
                        "display_name": "TwitchDev",
                        "type": "",
                        "broadcaster_type": "partner",
                        "description": "Supporting third-party developers building Twitch integrations from chatbots to game integrations.",
                        "profile_image_url": "https://static-cdn.jtvnw.net/jtv_user_pictures/8a6381c7-d0c0-4576-b179-38bd5ce1d6af-profile_image-300x300.png",
                        "offline_image_url": "https://static-cdn.jtvnw.net/jtv_user_pictures/3f13ab61-ec78-4fe6-8481-8682cb3b0ac2-channel_offline_image-1920x1080.png",
                        "view_count": 5980557,
                        "email": "not-real@email.com",
                        "created_at": "2016-12-14T20:32:28Z"
                    }
                ]
            }
             */

            this.code = code;
            this.id = json["id"].str.to!ulong;
            this.login = json["login"].str;
            this.displayName = json["display_name"].str;
        }

        this(const IRCUser user)
        {
            this.id = user.id;
            this.login = user.nickname;
            this.displayName = user.displayName;
            this.code = 200;  // success
        }
    }

    if (const stored = name in plugin.state.users)
    {
        // Stored user
        return GetUserResults(*stored);
    }

    // No such luck
    if (searchByDisplayName)
    {
        foreach (const stored; plugin.state.users.aaOf)
        {
            if (stored.displayName == name)
            {
                // Found user by displayName
                return GetUserResults(stored);
            }
        }
    }

    // None on record, look up
    immutable url = name.length ?
        "https://api.twitch.tv/helix/users?login=" ~ name :
        "https://api.twitch.tv/helix/users?id=" ~ id.to!string;

    auto getUserDg()
    {
        immutable response = sendHTTPRequest(
            plugin: plugin,
            url: url,
            caller: caller,
            authorisationHeader: plugin.transient.authorizationBearer,
            clientID: TwitchPlugin.clientID);

        immutable responseJSON = parseJSON(response.body);

        switch (response.code)
        {
        case 200:
            // 200 OK
            /+
                Successfully retrieved the specified users’ information.
             +/
            break;

        case 400:
            // 400 Bad Request
            /+
                The *id* or *login* query parameter is required unless the
                request uses a user access token.
                The request exceeded the maximum allowed number of *id* and/or
                *login* query parameters.
             +/
            goto default;

        case 401:
            // 401 Unauthorized
            /+
                The Authorization header is required and must contain an app
                access token or user access token.
                The access token is not valid.
                The ID specified in the Client-Id header does not match the
                client ID specified in the access token.
             +/
            goto default;

        default:
            version(PrintStacktraces)
            {
                writeln(response.code);
                writeln(responseJSON.toPrettyString);
                printStacktrace();
            }

            if (immutable errorJSON = "error" in responseJSON)
            {
                return GetUserResults(response.code, errorJSON.str);
            }
            else
            {
                return GetUserResults(response.code);
            }
        }

        immutable dataJSON = "data" in responseJSON;

        if (!dataJSON)
        {
            enum message = "`getUser` response has unexpected JSON " ~
                `(no "data" key)`;
            throw new UnexpectedJSONException(message, responseJSON);
        }

        if (!dataJSON.array.length)
        {
            // No such user
            return GetUserResults(response.code);
        }

        immutable firstUserJSON = dataJSON.array[0];

        return GetUserResults(response.code, firstUserJSON);
    }

    return retryDelegate(plugin, &getUserDg);
}


// getGame
/++
    Fetches information about a game; its numerical ID and full name.

    If `id` is passed, then it takes priority over `name`.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        name = Name of game to look up.
        id = Numerical ID of game to look up.
        caller = Name of the calling function.

    Returns:
        Voldemort aggregate struct with `id` and `name` members.

    Throws:
        [kameloso.net.UnexpectedJSONException|UnexpectedJSONException] on unexpected JSON received.

    See_Also:
        https://dev.twitch.tv/docs/api/reference/#get-games
 +/
auto getGame(
    TwitchPlugin plugin,
    const string name = string.init,
    const ulong id = 0,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `getGame` from outside a fiber")
in ((name.length || id), "Tried to call `getGame` with no game name nor game ID")
{
    import std.conv : to;
    import std.json : parseJSON;

    static struct GetGameResults
    {
        private import std.json : JSONValue;

        uint code;
        string error;
        ulong id;
        string name;

        auto success() const { return (id && (code == 200)); }

        this(const uint code) { this.code = code; }

        this(const uint code, const string error)
        {
            this.code = code;
            this.error = error;
        }

        this(const uint code, const JSONValue json)
        {
            /*
            {
                "data": [
                    {
                        "id": "33214",
                        "name": "Fortnite",
                        "box_art_url": "https://static-cdn.jtvnw.net/ttv-boxart/33214-{width}x{height}.jpg",
                        "igdb_id": "1905"
                    }
                ]
            }
             */

            this.code = code;
            this.id = json["id"].str.to!ulong;
            this.name = json["name"].str;
        }
    }

    immutable url = id ?
        "https://api.twitch.tv/helix/games?id=" ~ id.to!string :
        "https://api.twitch.tv/helix/games?name=" ~ name;

    auto getGameDg()
    {
        immutable response = sendHTTPRequest(
            plugin: plugin,
            url: url,
            caller: caller,
            authorisationHeader: plugin.transient.authorizationBearer,
            clientID: TwitchPlugin.clientID);

        immutable responseJSON = parseJSON(response.body);

        switch (response.code)
        {
        case 200:
            // 200 OK
            /+
                Successfully retrieved the specified games.
             +/
            break;

        case 400:
            // 400 Bad Request
            /+
                The request must specify the id or name or igdb_id query parameter.
                The combined number of game IDs (id and igdb_id) and game names
                that youspecify in the request must not exceed 100.
             +/
            goto default;

        case 401:
            // 401 Unauthorized
            /+
                The Authorization header is required and must specify an app
                access token or user access token.
                The access token is not valid.
                The ID in the Client-Id header must match the client ID in the access token.
             +/
            goto default;

        default:
            version(PrintStacktraces)
            {
                writeln(response.code);
                writeln(responseJSON.toPrettyString);
                printStacktrace();
            }

            if (immutable errorJSON = "error" in responseJSON)
            {
                return GetGameResults(response.code, errorJSON.str);
            }
            else
            {
                return GetGameResults(response.code);
            }
        }

        immutable dataJSON = "data" in responseJSON;

        if (!dataJSON)
        {
            enum message = "`getGame` response has unexpected JSON " ~
                `(no "data" key)`;
            throw new UnexpectedJSONException(message, responseJSON);
        }

        if (!dataJSON.array.length)
        {
            // No such game
            return GetGameResults(response.code);
        }

        immutable firstGameJSON = dataJSON.array[0];

        return GetGameResults(response.code, firstGameJSON);
    }

    return retryDelegate(plugin, &getGameDg);
}


// setChannelTitle
/++
    Changes the title of a channel.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        channelName = Name of channel to modify.
        title = Optional channel title to set.
        caller = Name of the calling function.

    Returns:
        A Voldemort with the HTTP status code of the operation.
 +/
auto setChannelTitle(
    TwitchPlugin plugin,
    const string channelName,
    const string title,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `setChannelTitle` from outside a fiber")
in (channelName.length, "Tried to change a the channel title with an empty channel name string")
{
    return modifyChannelImpl(
        plugin: plugin,
        channelName: channelName,
        title: title,
        caller: caller);
}


// setChannelGame
/++
    Changes the currently streamed game of a channel.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        channelName = Name of channel to modify.
        gameID = Optional game ID to set the channel as playing.
        caller = Name of the calling function.

    Returns:
        A Voldemort with the HTTP status code of the operation.
 +/
auto setChannelGame(
    TwitchPlugin plugin,
    const string channelName,
    const ulong gameID,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `setChannelGame` from outside a fiber")
in (gameID, "Tried to set the channel game with an empty channel name string")
{
    return modifyChannelImpl(
        plugin: plugin,
        channelName: channelName,
        gameID: gameID,
        caller: caller);
}


// modifyChannelImpl
/++
    Modifies a channel's title or currently played game. Implementation function.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        channelName = Name of channel to modify.
        title = Optional channel title to set.
        gameID = Optional game ID to set the channel as playing.
        caller = Name of the calling function.

    Returns:
        A Voldemort with the HTTP status code of the operation.

    See_Also:
        https://dev.twitch.tv/docs/api/reference/#modify-channel-information
 +/
private auto modifyChannelImpl(
    TwitchPlugin plugin,
    const string channelName,
    const string title = string.init,
    const ulong gameID = 0,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `modifyChannel` from outside a fiber")
in (channelName.length, "Tried to modify a channel with an empty channel name string")
in ((title.length || gameID), "Tried to modify a channel with no title nor game ID supplied")
{
    import std.array : Appender;
    import std.conv : to;

    static struct ModifyChannelResults
    {
        uint code;
        auto success() const { return (code == 204); }
    }

    const room = channelName in plugin.rooms;
    assert(room, "Tried to modify a channel for which there existed no room");

    immutable authorizationBearer = getBroadcasterAuthorisation(plugin, channelName);
    immutable url = "https://api.twitch.tv/helix/channels?broadcaster_id=" ~ room.id.to!string;

    Appender!(char[]) sink;
    sink.reserve(128);

    sink.put('{');

    if (title.length)
    {
        sink.put(`"title":"`);
        sink.put(title);
        sink.put('"');
        if (gameID) sink.put(',');
    }

    if (gameID)
    {
        sink.put(`"game_id":"`);
        sink.put(gameID.to!string);
        sink.put('"');
    }

    sink.put('}');

    auto modifyChannelDg()
    {
        immutable response = sendHTTPRequest(
            plugin: plugin,
            url: url,
            caller: caller,
            authorisationHeader: authorizationBearer,
            clientID: TwitchPlugin.clientID,
            verb: HTTPVerb.patch,
            body: cast(ubyte[])sink[],
            contentType: "application/json");

        switch (response.code)
        {
        case 204:
            // 204 No Content
            /+
                Successfully updated the channel’s properties.
             +/
            break;

        case 400:
            // 400 Bad Request
            /+
                The broadcaster_id query parameter is required.
                The request must update at least one property.
                The title field may not contain an empty string.
                The ID in game_id is not valid.
                To update the delay field, the broadcaster must have partner status.
                The list in the tags field exceeds the maximum number of tags allowed.
                A tag in the tags field exceeds the maximum length allowed.
                A tag in the tags field is empty.
                A tag in the tags field contains special characters or spaces.
                One or more tags in the tags field failed AutoMod review.
                Game restricted for user's age and region
             +/
            goto default;

        case 401:
            // 401 Unauthorized
            /+
                User requests CCL for a channel they don’t own
                The ID in broadcaster_id must match the user ID found in the OAuth token.
                The Authorization header is required and must specify a user access token.
                The OAuth token must include the channel:manage:broadcast scope.
                The OAuth token is not valid.
                The ID in the Client-Id header must match the Client ID in the OAuth token.
             +/
            goto default;

        case 403:
            // 403 Forbidden
            /+
                User requested gaming CCLs to be added to their channel
                Unallowed CCLs declared for underaged authorized user in a restricted country
             +/
            goto default;

        case 429:
            // 429 Too Many Requests
            /+
                User set the Branded Content flag too frequently
             +/
            goto default;

        case 500:
            // 500 Internal Server Error
            goto default;

        default:
            version(PrintStacktraces)
            {
                writeln(response.code);
                printStacktrace();
            }
            // Drop down
            break;
        }

        return ModifyChannelResults(response.code);
    }

    return retryDelegate(plugin, &modifyChannelDg);
}


// getChannel
/++
    Fetches information about a channel; its title, what game is being played,
    the channel tags, etc.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        channelName = Name of channel to fetch information about.
        channelID = Numerical ID of channel to fetch information about.
        caller = Name of the calling function.

    Returns:
        A Voldemort with the channel information.

    Throws:
        [kameloso.net.UnexpectedJSONException|UnexpectedJSONException] on unexpected JSON received.

    See_Also:
        https://dev.twitch.tv/docs/api/reference/#get-channel-information
 +/
auto getChannel(
    TwitchPlugin plugin,
    const string channelName = string.init,
    const ulong channelID = 0,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `getChannel` from outside a fiber")
in ((channelName.length || channelID), "Tried to fetch a channel with no information to query with")
{
    import std.conv : to;
    import std.json : parseJSON;

    static struct GetChannelResults
    {
        private import std.json : JSONValue;

        uint code;
        string error;
        ulong id;
        ulong gameID;
        string gameName;
        string[] tags;
        string title;

        auto success() const { return (gameID && (code == 200));  }

        this(const uint code) { this.code = code; }

        this(const uint code, const string error)
        {
            this.code = code;
            this.error = error;
        }

        this(const uint code, const JSONValue json)
        {
            import std.algorithm.iteration : map;
            import std.array : array;

            /*
            {
                "data": [
                    {
                        "broadcaster_id": "22216721",
                        "broadcaster_language": "en",
                        "broadcaster_login": "zorael",
                        "broadcaster_name": "zorael",
                        "delay": 0,
                        "game_id": "",
                        "game_name": "",
                        "tags": [],
                        "title": "bleph"
                    }
                ]
            }
             */

            this.code = code;
            this.id = json["broadcaster_id"].str.to!ulong;
            this.gameID = json["game_id"].str.to!ulong;
            this.gameName = json["game_name"].str;
            this.tags = json["tags"].array
                .map!(tagJSON => tagJSON.str)
                .array;
            this.title = json["title"].str;
        }
    }

    ulong id;

    if (channelID)
    {
        id = channelID;
    }
    else
    {
        if (const room = channelName in plugin.rooms)
        {
            id = room.id;
        }
        else
        {
            const results = getUser(
                plugin: plugin,
                name: channelName,
                caller: caller);

            if (!results.success) return GetChannelResults(results.code);

            id = results.id;
        }
    }

    immutable url = "https://api.twitch.tv/helix/channels?broadcaster_id=" ~ id.to!string;

    auto getChannelDg()
    {
        immutable response = sendHTTPRequest(
            plugin: plugin,
            url: url,
            caller: caller,
            authorisationHeader: plugin.transient.authorizationBearer,
            clientID: TwitchPlugin.clientID);

        immutable responseJSON = parseJSON(response.body);

        switch (response.code)
        {
        case 200:
            // 200 OK
            /+
                Successfully retrieved the specified games.
             +/
            break;

        case 400:
            // 400 Bad Request
            /+
                The request must specify the id or name or igdb_id query parameter.
                The combined number of game IDs (id and igdb_id) and game names
                that you specify in the request must not exceed 100.
             +/
            goto default;

        case 401:
            // 401 Unauthorized
            /+
                The Authorization header is required and must specify an app
                access token or user access token.
                The access token is not valid.
                The ID in the Client-Id header must match the client ID in the access token.
             +/
            goto default;

        default:
            version(PrintStacktraces)
            {
                writeln(response.code);
                writeln(responseJSON.toPrettyString);
                printStacktrace();
            }

            if (immutable errorJSON = "error" in responseJSON)
            {
                return GetChannelResults(response.code, errorJSON.str);
            }
            else
            {
                return GetChannelResults(response.code);
            }
        }

        immutable dataJSON = "data" in responseJSON;

        if (!dataJSON)
        {
            enum message = "`getChannel` response has unexpected JSON " ~
                `(no "data" key)`;
            throw new UnexpectedJSONException(message, responseJSON);
        }

        if (!dataJSON.array.length)
        {
            // No such channel
            return GetChannelResults(response.code);
        }

        immutable firstChannelJSON = dataJSON.array[0];

        return GetChannelResults(response.code, firstChannelJSON);
    }

    return retryDelegate(plugin, &getChannelDg);
}


// getBroadcasterAuthorisation
/++
    Returns a broadcaster-level "Bearer" authorisation token for a channel,
    where such exist.

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        channelName = Name of channel to return token for.

    Returns:
        A "Bearer" OAuth token string for use in HTTP headers.

    Throws:
        [MissingBroadcasterTokenException] if there were no broadcaster API token
        for the supplied channel in the secrets storage.
 +/
auto getBroadcasterAuthorisation(TwitchPlugin plugin, const string channelName)
in (Fiber.getThis(), "Tried to call `getBroadcasterAuthorisation` from outside a fiber")
in (channelName.length, "Tried to get broadcaster authorisation with an empty channel name string")
out (token; token.length, "`getBroadcasterAuthorisation` returned an empty string")
{
    auto creds = channelName in plugin.secretsByChannel;

    if (!creds || !creds.broadcasterBearerToken.length)
    {
        enum message = "Missing broadcaster token";
        throw new MissingBroadcasterTokenException(
            message,
            channelName,
            __FILE__);
    }

    return creds.broadcasterBearerToken;
}


// startCommercial
/++
    Starts a commercial in the specified channel.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        channelName = Name of channel to run commercials for.
        lengthString = Length to play the commercial for, as a string.
        caller = Name of the calling function.

    Returns:
        A Voldemort with information about the commercial start.

    Throws:
        [kameloso.net.UnexpectedJSONException|UnexpectedJSONException] on unexpected JSON received.
        [kameloso.net.EmptyDataJSONException|EmptyDataJSONException] if the
        response contained an empty `data` array.

    See_Also:
        https://dev.twitch.tv/docs/api/reference/#start-commercial
 +/
auto startCommercial(
    TwitchPlugin plugin,
    const string channelName,
    const string lengthString,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `startCommercial` from outside a fiber")
in (channelName.length, "Tried to start a commercial with an empty channel name string")
{
    import std.format : format;
    import std.json : parseJSON;

    static struct StartCommercialResults
    {
        private import std.json : JSONValue;

        uint code;
        string error;
        string message;
        uint durationSeconds;
        uint retryAfter;

        auto success() const { return (code == 200); }

        this(const uint code) { this.code = code; }

        this(const uint code, const string error)
        {
            this.code = code;
            this.error = error;
        }

        this(const uint code, const JSONValue json)
        {
            /*
            {
                "data": [
                    {
                        "length" : 60,
                        "message" : "",
                        "retry_after" : 480
                    }
                ]
            }
             */
            this.code = code;
            this.message = json["message"].str;
            this.durationSeconds = cast(uint)json["length"].integer;
            this.retryAfter = cast(uint)json["retry_after"].integer;
        }
    }

    const room = channelName in plugin.rooms;
    assert(room, "Tried to start commercial in a channel for which there existed no room");

    enum url = "https://api.twitch.tv/helix/channels/commercial";
    enum bodyPattern = `
{
    "broadcaster_id": "%d",
    "length": %s
}`;

    immutable body = bodyPattern.format(room.id, lengthString);
    immutable authorizationBearer = getBroadcasterAuthorisation(plugin, channelName);

    auto startCommercialDg()
    {
        immutable response = sendHTTPRequest(
            plugin: plugin,
            url: url,
            caller: caller,
            authorisationHeader: authorizationBearer,
            clientID: TwitchPlugin.clientID,
            verb: HTTPVerb.post,
            body: cast(ubyte[])body,
            contentType: "application/json");

        immutable responseJSON = parseJSON(response.body);

        switch (response.code)
        {
        case 200:
            // 200 OK
            /+
                Successfully started the commercial.
             +/
            break;

        case 400:
            // 400 Bad Request
            /+
                The broadcaster_id query parameter is required.
                The length query parameter is required.
                The ID in broadcaster_id is not valid.
                To start a commercial, the broadcaster must be streaming live.
                The broadcaster may not run another commercial until the cooldown
                period expires. The retry_after field in the previous start
                commercial response specifies the amount of time the broadcaster
                must wait between running commercials.
             +/
            goto default;

        case 401:
            // 401 Unauthorized
            /+
                The ID in broadcaster_id must match the user ID found in the request’s OAuth token.
                The Authorization header is required and must contain a user access token.
                The user access token must include the channel:edit:commercial scope.
                The OAuth token is not valid.
                The client ID specified in the Client-Id header does not match
                the client ID specified in the OAuth token.
             +/
            goto default;

        case 404:
            // 404 Not Found
            /+
                The ID in broadcaster_id was not found.
             +/
            goto default;

        case 429:
            // 429 Too Many Requests
            /+
                The broadcaster may not run another commercial until the cooldown
                period expires. The retry_after field in the previous start
                commercial response specifies the amount of time the broadcaster
                must wait between running commercials.
             +/
            goto default;

        default:
            version(PrintStacktraces)
            {
                writeln(response.code);
                writeln(responseJSON.toPrettyString);
                printStacktrace();
            }

            if (immutable errorJSON = "error" in responseJSON)
            {
                return StartCommercialResults(response.code, errorJSON.str);
            }
            else
            {
                return StartCommercialResults(response.code);
            }
        }

        immutable dataJSON = "data" in responseJSON;

        if (!dataJSON)
        {
            enum message = "`startCommercial` response has unexpected JSON " ~
                `(no "data" key)`;
            throw new UnexpectedJSONException(message, responseJSON);
        }

        if (!dataJSON.array.length)
        {
            enum message = "`startCommercial` response has unexpected JSON " ~
                `(zero-length "data")`;
            throw new EmptyDataJSONException(message, responseJSON);
        }

        immutable commercialInfoJSON = (*dataJSON).array[0];
        return StartCommercialResults(response.code, commercialInfoJSON);
    }

    return retryDelegate(plugin, &startCommercialDg);
}


// TwitchPoll
/++
    Represents a Twitch native poll (not a poll of the Poll plugin).
 +/
private struct TwitchPoll
{
private:
    import std.datetime.systime : SysTime;
    import std.json : JSONValue;

public:
    /++
        An option to vote for in the poll.
     +/
    static struct Choice
    {
        /++
            Unique choice ID string.
         +/
        string id;

        /++
            The name of the choice, e.g. "heads".
         +/
        string title;

        /++
            How many votes were placed on this choice.
         +/
        uint votes;

        /++
            How many votes were placed with channel points on this choice.
         +/
        uint channelPointsVotes;

        /++
            Constructs a new [Choice] from a passed [std.json.JSONValue|JSONValue]
            as received from API calls.

            Params:
                json = JSON to parse.
         +/
        this(const JSONValue json)
        {
            import std.conv : to;

            this.id = json["id"].str;
            this.title = json["title"].str;
            this.votes = json["votes"].str.to!uint;
            this.channelPointsVotes = json["channel_points_votes"].str.to!uint;
        }
    }

    /++
        The current state of the poll.
     +/
    enum PollStatus
    {
        /++
            Initial state.
         +/
        unset,

        /++
            The poll is running.
         +/
        active,

        /++
            The poll ended on schedule.
         +/
        completed,

        /++
            The poll was terminated before its scheduled end.
         +/
        terminated,

        /++
            The poll has been archived and is no longer visible on the channel.
         +/
        archived,

        /++
            The poll was deleted.
         +/
        moderated,

        /++
            Something went wrong while determining the state.
         +/
        invalid,
    }

    /++
        Unique poll ID string.
     +/
    string pollID;

    /++
        The current state of the poll.
     +/
    PollStatus status;

    /++
        Title of the poll, e.g. "heads or tails?".
     +/
    string title;

    /++
        Array of the [Choice]s that you can vote for in this poll.
     +/
    Choice[] choices;

    /++
        Twitch numeric ID of the broadcaster in whose channel the poll is held.
     +/
    ulong broadcasterID;

    /++
        Twitch username of broadcaster.
     +/
    string broadcasterLogin;

    /++
        Twitch display name of broadcaster.
     +/
    string broadcasterDisplayName;

    /++
        Whether voting with channel points is enabled.
     +/
    bool channelPointsVotingEnabled;

    /++
        How many channel points you have to pay for one vote.
     +/
    uint channelPointsPerVote;

    /++
        How many seconds the poll was meant to run.
     +/
    uint duration;

    /++
        Timestamp of when the poll started.
     +/
    SysTime startedAt;

    /++
        Timestamp of when the poll ended, if applicable.
     +/
    SysTime endedAt;

    /++
        Constructs a new [TwitchPoll] from a passed [std.json.JSONValue|JSONValue]
        as received from API calls.

        Params:
            json = JSON to parse.
     +/
    this(const JSONValue json)
    {
        import std.conv : to;

        /*
        {
            "data": [
                {
                "id": "ed961efd-8a3f-4cf5-a9d0-e616c590cd2a",
                "broadcaster_id": "55696719",
                "broadcaster_name": "TwitchDev",
                "broadcaster_login": "twitchdev",
                "title": "Heads or Tails?",
                "choices": [
                    {
                    "id": "4c123012-1351-4f33-84b7-43856e7a0f47",
                    "title": "Heads",
                    "votes": 0,
                    "channel_points_votes": 0,
                    "bits_votes": 0
                    },
                    {
                    "id": "279087e3-54a7-467e-bcd0-c1393fcea4f0",
                    "title": "Tails",
                    "votes": 0,
                    "channel_points_votes": 0,
                    "bits_votes": 0
                    }
                ],
                "bits_voting_enabled": false,
                "bits_per_vote": 0,
                "channel_points_voting_enabled": false,
                "channel_points_per_vote": 0,
                "status": "ACTIVE",
                "duration": 1800,
                "started_at": "2021-03-19T06:08:33.871278372Z"
                }
            ],
            "pagination": {}
        }
         */
        /*
        {
            "data": [
                {
                "id": "ed961efd-8a3f-4cf5-a9d0-e616c590cd2a",
                "broadcaster_id": "141981764",
                "broadcaster_name": "TwitchDev",
                "broadcaster_login": "twitchdev",
                "title": "Heads or Tails?",
                "choices": [
                    {
                    "id": "4c123012-1351-4f33-84b7-43856e7a0f47",
                    "title": "Heads",
                    "votes": 0,
                    "channel_points_votes": 0,
                    "bits_votes": 0
                    },
                    {
                    "id": "279087e3-54a7-467e-bcd0-c1393fcea4f0",
                    "title": "Tails",
                    "votes": 0,
                    "channel_points_votes": 0,
                    "bits_votes": 0
                    }
                ],
                "bits_voting_enabled": false,
                "bits_per_vote": 0,
                "channel_points_voting_enabled": true,
                "channel_points_per_vote": 100,
                "status": "TERMINATED",
                "duration": 1800,
                "started_at": "2021-03-19T06:08:33.871278372Z",
                "ended_at": "2021-03-19T06:11:26.746889614Z"
                }
            ]
        }
         */

        this.pollID = json["id"].str;
        this.title = json["title"].str;
        this.broadcasterID = json["broadcaster_id"].str.to!ulong;
        this.broadcasterLogin = json["broadcaster_login"].str;
        this.broadcasterDisplayName = json["broadcaster_name"].str;
        this.channelPointsVotingEnabled = json["channel_points_voting_enabled"].boolean;
        this.channelPointsPerVote = json["channel_points_per_vote"].str.to!uint;
        this.duration = cast(uint)json["duration"].integer;
        this.startedAt = SysTime.fromISOExtString(json["started_at"].str);

        if (const endedAtJSON = "ended_at" in json)
        {
            import std.json : JSONType;

            if (endedAtJSON.type == JSONType.string)
            {
                this.endedAt = SysTime.fromISOExtString(endedAtJSON.str);
            }
            else
            {
                // "If status is ACTIVE, this field is set to null."
            }
        }

        with (TwitchPoll.PollStatus)
        switch (json["status"].str)
        {
        case "ACTIVE":
            this.status = active;
            break;

        case "COMPLETED":
            this.status = completed;
            break;

        case "TERMINATED":
            this.status = terminated;
            break;

        case "ARCHIVED":
            this.status = archived;
            break;

        case "MODERATED":
            this.status = moderated;
            break;

        //case "INVALID":
        default:
            this.status = invalid;
            break;
        }

        foreach (const choiceJSON; json["choices"].array)
        {
            this.choices ~= TwitchPoll.Choice(choiceJSON);
        }
    }
}


// getPolls
/++
    Fetches information about polls in the specified channel. If an ID string is
    supplied, it will be included in the query, otherwise all `"ACTIVE"` polls
    are included in the returned Voldemorts.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        channelName = Name of channel to fetch polls for.
        pollIDString = ID of a specific poll to get.
        caller = Name of the calling function.

    Returns:
        A Voldemort containing an array of [TwitchPoll]s.

    Throws:
        [kameloso.net.UnexpectedJSONException|UnexpectedJSONException] on unexpected JSON received.

    See_Also:
        https://dev.twitch.tv/docs/api/reference/#get-polls
 +/
auto getPolls(
    TwitchPlugin plugin,
    const string channelName,
    const string pollIDString = string.init,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `getPolls` from outside a fiber")
in (channelName.length, "Tried to get polls with an empty channel name string")
{
    import std.conv : text;
    import std.json : parseJSON;

    static struct GetPollResults
    {
        uint code;
        string error;
        TwitchPoll[] polls;

        this(const uint code) { this.code = code; }

        this(const uint code, const string error)
        {
            this.code = code;
            this.error = error;
        }

        this(const uint code, /*const*/ TwitchPoll[] polls)
        {
            this.code = code;
            this.polls = polls;
        }

        auto success() const { return (polls.length && (code == 200)); }
    }

    const room = channelName in plugin.rooms;
    assert(room, "Tried to get polls of a channel for which there existed no room");

    enum baseURL = "https://api.twitch.tv/helix/polls?broadcaster_id=";
    immutable idPart = pollIDString.length ?
        "&id=" ~ pollIDString :
        string.init;
    immutable url = text(baseURL, room.id, idPart);

    immutable authorizationBearer = getBroadcasterAuthorisation(plugin, channelName);

    // Keep these outside
    TwitchPoll[] polls;
    string after;

    auto getPollsDg()
    {
        uint responseCode;

        do
        {
            immutable paginatedURL = after.length ?
                text(url, "&after=", after) :
                url;

            immutable response = sendHTTPRequest(
                plugin: plugin,
                url: paginatedURL,
                caller: caller,
                authorisationHeader: authorizationBearer,
                clientID: TwitchPlugin.clientID,
                verb: HTTPVerb.get,
                body: cast(ubyte[])null,
                contentType: "application/json");

            immutable responseJSON = parseJSON(response.body);

            switch (response.code)
            {
            case 200:
                // 200 OK
                /+
                    Successfully retrieved the broadcaster's polls.
                 +/
                break;

            case 400:
                // 400 Bad Request
                /+
                    The broadcaster_id query parameter is required.
                 +/
                goto default;

            case 401:
                // 401 Unauthorized
                /+
                    The ID in broadcaster_id must match the user ID in the access token.
                    The Authorization header is required and must contain a user access token.
                    The user access token is missing the channel:read:polls scope.
                    The access token is not valid.
                    The client ID specified in the Client-Id header must match
                    the client ID specified in the access token.
                 +/
                goto default;

            case 404:
                // 404 Not Found
                /+
                    None of the IDs in the id query parameters were found.
                 +/
                goto default;

            default:
                version(PrintStacktraces)
                {
                    writeln(response.code);
                    writeln(responseJSON.toPrettyString);
                    printStacktrace();
                }

                if (immutable errorJSON = "error" in responseJSON)
                {
                    return GetPollResults(response.code, errorJSON.str);
                }
                else
                {
                    return GetPollResults(response.code);
                }
            }

            responseCode = response.code;

            immutable dataJSON = "data" in responseJSON;

            if (!dataJSON)
            {
                // For some reason we received an object that didn't contain data
                enum message = "`getPolls` response has unexpected JSON " ~
                    `(no "data" key)`;
                throw new UnexpectedJSONException(message, responseJSON);
            }

            if (!dataJSON.array.length)
            {
                // no polls to get?
                return GetPollResults(response.code);
            }

            foreach (const pollJSON; dataJSON.array)
            {
                polls ~= TwitchPoll(pollJSON);
            }

            after = responseJSON["after"].str;
        }
        while (after.length);

        return GetPollResults(responseCode, polls);
    }

    return retryDelegate(plugin, &getPollsDg);
}


// createPoll
/++
    Creates a Twitch poll in the specified channel.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        channelName = Name of channel to create the poll in.
        title = Poll title.
        durationString = How long the poll should run for in seconds (as a string).
        choices = A string array of poll choices.
        caller = Name of the calling function.

    Returns:
        A [TwitchPoll] instance.

    Throws:
        [kameloso.net.UnexpectedJSONException|UnexpectedJSONException] on unexpected JSON received.
        [kameloso.net.EmptyDataJSONException|EmptyDataJSONException] if the
        response contained an empty `data` array.

    See_Also:
        https://dev.twitch.tv/docs/api/reference/#create-poll
 +/
auto createPoll(
    TwitchPlugin plugin,
    const string channelName,
    const string title,
    const string durationString,
    const string[] choices,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `createPoll` from outside a fiber")
in (channelName.length, "Tried to create a poll with an empty channel name string")
{
    import std.array : Appender, replace;
    import std.format : format;
    import std.json : parseJSON;

    static struct CreatePollResults
    {
        uint code;
        string error;
        TwitchPoll poll;

        auto success() const { return (code == 200); }

        this(const uint code) { this.code = code; }

        this(const uint code, const string error)
        {
            this.code = code;
            this.error = error;
        }

        this(const uint code, /*const*/ TwitchPoll poll)
        {
            this.code = code;
            this.poll = poll;
        }
    }

    const room = channelName in plugin.rooms;
    assert(room, "Tried to create a poll in a channel for which there existed no room");

    enum url = "https://api.twitch.tv/helix/polls";
    enum bodyPattern = `
{
    "broadcaster_id": "%d",
    "title": "%s",
    "choices":[
%s
    ],
    "duration": %s
}`;

    Appender!(char[]) sink;
    sink.reserve(256);

    foreach (immutable i, immutable choice; choices)
    {
        if (i > 0) sink.put(',');
        sink.put(`{"title":"`);
        sink.put(choice.replace(`"`, `\"`));
        sink.put(`"}`);
    }

    immutable escapedTitle = title.replace(`"`, `\"`);
    immutable body = bodyPattern.format(
        room.id,
        escapedTitle,
        sink[],
        durationString);
    immutable authorizationBearer = getBroadcasterAuthorisation(plugin, channelName);

    auto createPollDg()
    {
        immutable response = sendHTTPRequest(
            plugin: plugin,
            url: url,
            caller: caller,
            authorisationHeader: authorizationBearer,
            clientID: TwitchPlugin.clientID,
            verb: HTTPVerb.post,
            body: cast(ubyte[])body,
            contentType: "application/json");

        immutable responseJSON = parseJSON(response.body);

        switch (response.code)
        {
        case 200:
            // 200 OK
            /+
                Successfully created the poll.
             +/
            break;

        case 400:
            // 400 Bad Request
            /+
                The broadcaster_id field is required.
                The title field is required.
                The choices field is required.
                The duration field is required.
                The value in duration is outside the allowed range of values.
                The value in channel_points_per_vote is outside the allowed range of values.
                The value in bits_per_vote is outside the allowed range of values.
                The poll's title is too long.
                The choice's title is too long.
                The choice's title failed AutoMod checks.
                The number of choices in the poll may not be less than 2 or greater that 5.
                The broadcaster already has a poll that's running; you may not
                create another poll until the current poll completes.
             +/
            goto default;

        case 401:
            // 401 Unauthorized
            /+
                The ID in broadcaster_id must match the user ID in the access token.
                The Authorization header is required and must contain a user access token.
                The user access token is missing the channel:manage:polls scope.
                The access token is not valid.
                The client ID specified in the Client-Id header does not match
                the client ID specified in the access token.
             +/
            goto default;

        default:
            version(PrintStacktraces)
            {
                writeln(response.code);
                writeln(responseJSON.toPrettyString);
                printStacktrace();
            }

            if (immutable errorJSON = "error" in responseJSON)
            {
                return CreatePollResults(response.code, errorJSON.str);
            }
            else
            {
                return CreatePollResults(response.code);
            }
        }

        immutable dataJSON = "data" in responseJSON;

        if (!dataJSON)
        {
            // For some reason we received an object that didn't contain data
            enum message = "`createPoll` response has unexpected JSON " ~
                `(no "data" key)`;
            throw new UnexpectedJSONException(message, responseJSON);
        }

        if (!dataJSON.array.length)
        {
            // data exists but is empty
            enum message = "`createPoll` response has unexpected JSON " ~
                `(zero-length "data")`;
            throw new EmptyDataJSONException(message, responseJSON);
        }

        return CreatePollResults(response.code, TwitchPoll(dataJSON.array[0]));
    }

    return retryDelegate(plugin, &createPollDg);
}


// endPoll
/++
    Ends a Twitch poll, putting it in either a `"TERMINATED"` or `"ARCHIVED"` state.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        channelName = Name of channel whose poll to end.
        pollID = ID of the specific poll to end.
        terminate = If set, ends the poll by putting it in a `"TERMINATED"` state.
            If unset, ends it in an `"ARCHIVED"` way.
        caller = Name of the calling function.

    Returns:
        A [TwitchPoll] instance.

    Throws:
        [kameloso.net.UnexpectedJSONException|UnexpectedJSONException] on unexpected JSON received.
        [kameloso.net.EmptyDataJSONException|EmptyDataJSONException] if the
        response contained an empty `data` array.

    See_Also:
        https://dev.twitch.tv/docs/api/reference/#end-poll
 +/
auto endPoll(
    TwitchPlugin plugin,
    const string channelName,
    const string pollID,
    const bool terminate,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `endPoll` from outside a fiber")
in (channelName.length, "Tried to end a poll with an empty channel name string")
{
    import std.format : format;
    import std.json : parseJSON;

    static struct EndPollResults
    {
        uint code;
        string error;
        TwitchPoll poll;

        auto success() const { return (code == 200); }

        this(const uint code) { this.code = code; }

        this(const uint code, const string error)
        {
            this.code = code;
            this.error = error;
        }

        this(const uint code, /*const*/ TwitchPoll poll)
        {
            this.code = code;
            this.poll = poll;
        }
    }

    const room = channelName in plugin.rooms;
    assert(room, "Tried to end a poll in a channel for which there existed no room");

    enum url = "https://api.twitch.tv/helix/polls";
    enum bodyPattern = `
{
    "broadcaster_id": "%d",
    "id": "%s",
    "status": "%s"
}`;

    immutable status = terminate ? "TERMINATED" : "ARCHIVED";
    immutable body = bodyPattern.format(room.id, pollID, status);
    immutable authorizationBearer = getBroadcasterAuthorisation(plugin, channelName);

    auto endPollDg()
    {
        immutable response = sendHTTPRequest(
            plugin: plugin,
            url: url,
            caller: caller,
            authorisationHeader: authorizationBearer,
            clientID: TwitchPlugin.clientID,
            verb: HTTPVerb.patch,
            body: cast(ubyte[])body,
            contentType: "application/json");

        immutable responseJSON = parseJSON(response.body);

        switch (response.code)
        {
        case 200:
            // 200 OK
            /+
                Successfully ended the poll.
             +/
            break;

        case 400:
            // 400 Bad Request
            /+
                The broadcaster_id field is required.
                The id field is required.
                The status field is required.
                The value in the status field is not valid.
                The poll must be active to terminate or archive it.
             +/
            goto default;

        case 401:
            // 401 Unauthorized
            /+
                The ID in broadcaster_id must match the user ID in the user access token.
                The Authorization header is required and must contain a user access token.
                The user access token must include the channel:manage:polls scope.
                The access token is not valid.
                The client ID specified in the Client-Id header must match the
                client ID specified in the access token.
             +/
            goto default;

        default:
            version(PrintStacktraces)
            {
                writeln(response.code);
                writeln(responseJSON.toPrettyString);
                printStacktrace();
            }

            if (immutable errorJSON = "error" in responseJSON)
            {
                return EndPollResults(response.code, errorJSON.str);
            }
            else
            {
                return EndPollResults(response.code);
            }
        }

        /*
        {
            "data": [
                {
                    "id": "ed961efd-8a3f-4cf5-a9d0-e616c590cd2a",
                    "broadcaster_id": "141981764",
                    "broadcaster_name": "TwitchDev",
                    "broadcaster_login": "twitchdev",
                    "title": "Heads or Tails?",
                    "choices": [
                        {
                        "id": "4c123012-1351-4f33-84b7-43856e7a0f47",
                        "title": "Heads",
                        "votes": 0,
                        "channel_points_votes": 0,
                        "bits_votes": 0
                        },
                        {
                        "id": "279087e3-54a7-467e-bcd0-c1393fcea4f0",
                        "title": "Tails",
                        "votes": 0,
                        "channel_points_votes": 0,
                        "bits_votes": 0
                        }
                    ],
                    "bits_voting_enabled": false,
                    "bits_per_vote": 0,
                    "channel_points_voting_enabled": true,
                    "channel_points_per_vote": 100,
                    "status": "TERMINATED",
                    "duration": 1800,
                    "started_at": "2021-03-19T06:08:33.871278372Z",
                    "ended_at": "2021-03-19T06:11:26.746889614Z"
                }
            ]
        }
         */

        immutable dataJSON = "data" in responseJSON;

        if (!dataJSON)
        {
            enum message = "`endPoll` response has unexpected JSON " ~
                `(no "data" key)`;
            throw new UnexpectedJSONException(message, responseJSON);
        }

        if (!dataJSON.array.length)
        {
            enum message = "`endPoll` response has unexpected JSON " ~
                `(zero-length "data")`;
            throw new EmptyDataJSONException(message, responseJSON);
        }

        return EndPollResults(response.code, TwitchPoll(dataJSON.array[0]));
    }

    return retryDelegate(plugin, &endPollDg);
}


// getBotList
/++
    Fetches a list of known (online) bots from TwitchInsights.net.

    With this we don't have to keep a static list of known bots to exclude when
    counting chatters.

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        caller = String name of calling function.

    Returns:
        A `string[]` array of online bot account names.

    Throws:
        [kameloso.net.UnexpectedJSONException|UnexpectedJSONException] on unexpected JSON received.

    See_Also:
        https://twitchinsights.net/bots
 +/
auto getBotList(TwitchPlugin plugin, const string caller = __FUNCTION__)
{
    import std.array : Appender;
    import std.json : parseJSON;

    static struct GetBotListResults
    {
        uint code;
        string error;
        string[] bots;

        auto success() const { return (code == 200); }

        this(const uint code) { this.code = code; }

        this(const uint code, const string error)
        {
            this.code = code;
            this.error = error;
        }

        this(const uint code, /*const*/ string[] bots)
        {
            this.code = code;
            this.bots = bots;
        }
    }

    auto getBotListDg()
    {
        enum url = "https://api.twitchinsights.net/v1/bots/online";

        immutable response = sendHTTPRequest(
            plugin: plugin,
            url: url,
            caller: caller);

        immutable responseJSON = parseJSON(response.body);

        /*
        {
            "_total": 78,
            "bots": [
                [
                    "commanderroot",
                    55158,
                    1664543800
                ],
                [
                    "alexisthenexis",
                    54928,
                    1664543800
                ],
                [
                    "anna_banana_10",
                    54636,
                    1664543800
                ],
                [
                    "sophiafox21",
                    54587,
                    1664543800
                ]
            ]
        }
         */

        if (immutable errorJSON = "error" in responseJSON)
        {
            version(PrintStacktraces)
            {
                writeln(response.code);
                writeln(responseJSON.toPrettyString);
                printStacktrace();
            }

            return GetBotListResults(response.code, errorJSON.str);
        }

        immutable botsJSON = "bots" in responseJSON;

        if (!botsJSON)
        {
            // For some reason we received an object that didn't contain bots
            enum message = "`getBotList` response has unexpected JSON " ~
                `(no "bots" key)`;
            throw new UnexpectedJSONException(message, responseJSON);
        }

        Appender!(string[]) sink;
        sink.reserve(responseJSON["_total"].integer);

        foreach (const botEntryJSON; botsJSON.array)
        {
            import std.algorithm.searching : endsWith;

            /*
            [
                "commanderroot",
                55158,
                1664543800
            ]
             */

            immutable botAccountName = botEntryJSON.array[0].str;

            if (!botAccountName.endsWith("bot"))
            {
                // Only add bots whose names don't end with "bot", since we automatically filter those
                sink.put(botAccountName);
            }
        }

        return GetBotListResults(response.code, sink[]);
    }

    return retryDelegate(plugin, &getBotListDg);
}


// getStream
/++
    Fetches information about an ongoing stream.

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        loginName = Account name of user whose stream to fetch information of.
        caller = Name of the calling function.

    Returns:
        A [kameloso.plugins.twitch.TwitchPlugin.Room.Stream|Room.Stream]
        populated with all (relevant) information.

    Throws:
        [kameloso.net.UnexpectedJSONException|UnexpectedJSONException] on unexpected JSON received.

    See_Also:
        https://dev.twitch.tv/docs/api/reference/#get-streams
 +/
auto getStream(
    TwitchPlugin plugin,
    const string loginName,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `getStream` from outside a fiber")
in (loginName.length, "Tried to get a stream with an empty login name string")
{
    import std.json : parseJSON;

    static struct GetStreamResults
    {
        uint code;
        string error;
        TwitchPlugin.Room.Stream stream;

        auto success() const { return (code == 200); }

        this(const uint code) { this.code = code; }

        this(const uint code, const string error)
        {
            this.code = code;
            this.error = error;
        }

        this(const uint code, /*const*/ TwitchPlugin.Room.Stream stream)
        {
            this.code = code;
            this.stream = stream;
        }
    }

    immutable url = "https://api.twitch.tv/helix/streams?user_login=" ~ loginName;

    auto getStreamDg()
    {
        immutable response = sendHTTPRequest(
            plugin: plugin,
            url: url,
            caller: caller,
            authorisationHeader: plugin.transient.authorizationBearer,
            clientID: TwitchPlugin.clientID);

        immutable responseJSON = parseJSON(response.body);

        switch (response.code)
        {
        case 200:
            // 200 OK
            /+
                Successfully retrieved the list of streams.
             +/
            break;

        case 400:
            // 400 Bad Request
            /+
                The value in the type query parameter is not valid.
             +/
            goto default;

        case 401:
            // 401 Unauthorized
            /+
                The Authorization header is required and must specify an app
                access token or user access token.
                The access token is not valid.
                The ID in the Client-Id header must match the Client ID in the access token.
             +/
            goto default;

        default:
            version(PrintStacktraces)
            {
                writeln(response.code);
                writeln(responseJSON.toPrettyString);
                printStacktrace();
            }

            if (immutable errorJSON = "error" in responseJSON)
            {
                return GetStreamResults(response.code, errorJSON.str);
            }
            else
            {
                return GetStreamResults(response.code);
            }
        }

        /*
        {
            "data": [
                {
                    "game_id": "506415",
                    "game_name": "Sekiro: Shadows Die Twice",
                    "id": "47686742845",
                    "is_mature": false,
                    "language": "en",
                    "started_at": "2022-12-26T16:47:58Z",
                    "tag_ids": [
                        "6ea6bca4-4712-4ab9-a906-e3336a9d8039"
                    ],
                    "tags": [
                        "darksouls",
                        "voiceactor",
                        "challengerunner",
                        "chill",
                        "rpg",
                        "survival",
                        "creativeprofanity",
                        "simlish",
                        "English"
                    ],
                    "thumbnail_url": "https:\/\/static-cdn.jtvnw.net\/previews-ttv\/live_user_lobosjr-{width}x{height}.jpg",
                    "title": "it's been so long! | fresh run",
                    "type": "live",
                    "user_id": "28640725",
                    "user_login": "lobosjr",
                    "user_name": "LobosJr",
                    "viewer_count": 2341
                }
            ],
            "pagination": {
                "cursor": "eyJiIjp7IkN1cnNvciI6ImV5SnpJam95TXpReExqUTBOelV3T1RZMk9URXdORFFzSW1RaU9tWmhiSE5sTENKMElqcDBjblZsZlE9PSJ9LCJhIjp7IkN1cnNvciI6IiJ9fQ"
            }
        }
         */
        /*
        {
            "data": [],
            "pagination": {}
        }
         */

        immutable dataJSON = "data" in responseJSON;

        if (!dataJSON)
        {
            enum message = "`getStream` response has unexpected JSON " ~
                `(no "data" key)`;
            throw new UnexpectedJSONException(message, responseJSON);
        }

        if (!dataJSON.array.length)
        {
            // Stream is down
            return GetStreamResults(response.code);
        }

        immutable firstStreamJSON = dataJSON.array[0];
        auto stream = TwitchPlugin.Room.Stream(firstStreamJSON);
        return GetStreamResults(response.code, stream);
    }

    return retryDelegate(plugin, &getStreamDg);
}


// getSubscribers
/++
    Fetches a list of all subscribers of the specified channel. A broadcaster-level
    access token is required.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        channelName = Name of channel to fetch subscribers of.
        totalOnly = Whether or not to return all subscribers or only one stub
            entry with the total number of subscribers in its `.total` member.
        caller = Name of the calling function.

    Returns:
        A Voldemort containing an array of subscribers.

    Throws:
        [kameloso.net.UnexpectedJSONException|UnexpectedJSONException] on unexpected JSON received.

    See_Also:
        https://dev.twitch.tv/docs/api/reference/#get-broadcaster-subscriptions
 +/
auto getSubscribers(
    TwitchPlugin plugin,
    const string channelName,
    const bool totalOnly,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `getSubscribers` from outside a fiber")
in (channelName.length, "Tried to get subscribers with an empty channel name string")
{
    import std.array : Appender;
    import std.conv : to;
    import std.json : parseJSON;

    static struct GetSubscribersResults
    {
        static struct Subscription
        {
            private import std.json : JSONValue;

            static struct User
            {
                string name;
                string displayName;
                ulong id;
            }

            User user;
            User gifter;
            bool wasGift;
            uint number;

            this(const JSONValue json, const uint number)
            {
                /*
                {
                    "data": [
                        {
                            "broadcaster_id": "141981764",
                            "broadcaster_login": "twitchdev",
                            "broadcaster_name": "TwitchDev",
                            "gifter_id": "12826",
                            "gifter_login": "twitch",
                            "gifter_name": "Twitch",
                            "is_gift": true,
                            "tier": "1000",
                            "plan_name": "Channel Subscription (twitchdev)",
                            "user_id": "527115020",
                            "user_name": "twitchgaming",
                            "user_login": "twitchgaming"
                        },
                    ],
                    "pagination": {
                        "cursor": "xxxx"
                    },
                    "total": 13,
                    "points": 13
                }
                 */

                this.user.id = json["user_id"].str.to!ulong;
                this.user.name = json["user_login"].str;
                this.user.displayName = json["user_name"].str;
                this.wasGift = json["is_gift"].boolean;
                this.gifter.id = json["gifter_id"].str.to!ulong;
                this.gifter.name = json["gifter_login"].str;
                this.gifter.displayName = json["gifter_name"].str;
                this.number = number;
            }
        }

        uint code;
        string error;
        uint totalNumSubscribers;
        Subscription[] subs;

        auto success() const { return code == 200; }

        this(const uint code) { this.code = code; }

        this(const uint code, const string error)
        {
            this.code = code;
            this.error = error;
        }

        this(const uint code, const uint totalNumSubscribers)
        {
            this.code = code;
            this.totalNumSubscribers = totalNumSubscribers;
        }

        this(
            const uint code,
            const uint totalNumSubscribers,
            /*const*/ Subscription[] subs)
        {
            this.code = code;
            this.totalNumSubscribers = totalNumSubscribers;
            this.subs = subs;
        }
    }

    const room = channelName in plugin.rooms;
    assert(room, "Tried to get subscribers of a channel for which there existed no room");

    Appender!(GetSubscribersResults.Subscription[]) subs;
    string after;
    uint numberCounter;
    uint totalNumSubscribers;

    immutable authorizationBearer = getBroadcasterAuthorisation(plugin, channelName);
    immutable firstURL = "https://api.twitch.tv/helix/subscriptions?broadcaster_id=" ~ room.id.to!string;
    immutable subsequentURL = totalOnly ?
        firstURL ~ "&first=1&after=" :
        firstURL ~ "&after=";

    auto getSubscribersDg()
    {
        uint responseCode;

        do
        {
            immutable url = after.length ?
                subsequentURL ~ after :
                firstURL;

            immutable response = sendHTTPRequest(
                plugin: plugin,
                url: url,
                caller: caller,
                authorisationHeader: authorizationBearer,
                clientID: TwitchPlugin.clientID);

            immutable responseJSON = parseJSON(response.body);

            switch (response.code)
            {
            case 200:
                // 200 OK
                /+
                    Successfully retrieved the broadcaster’s list of subscribers.
                 +/
                break;

            case 400:
                // 400 Bad Request
                /+
                    The broadcaster_id query parameter is required.
                 +/
                goto default;

            case 401:
                // 401 Unauthorized
                /+
                    The ID in broadcaster_id must match the user ID found in the request’s OAuth token.
                    The Authorization header is required and must contain a user access token.
                    The user access token must include the channel:read:subscriptions scope.
                    The access token is not valid.
                    The client ID specified in the Client-Id header does not match
                    the client ID specified in the access token.
                 +/
                goto default;

            default:
                version(PrintStacktraces)
                {
                    writeln(response.code);
                    writeln(responseJSON.toPrettyString);
                    printStacktrace();
                }

                if (immutable errorJSON = "error" in responseJSON)
                {
                    return GetSubscribersResults(response.code, errorJSON.str);
                }
                else
                {
                    return GetSubscribersResults(response.code);
                }
            }

            responseCode = response.code;

            immutable dataJSON = "data" in responseJSON;

            if (!dataJSON)
            {
                enum message = "`getSubscribers` response has unexpected JSON " ~
                    `(no "data" key)`;
                throw new UnexpectedJSONException(message, responseJSON);
            }

            if (!totalNumSubscribers) totalNumSubscribers = cast(uint)responseJSON["total"].integer;

            if (totalOnly)
            {
                // We only want the total number of subscribers
                return GetSubscribersResults(response.code, totalNumSubscribers);
            }

            if (!subs[].length) subs.reserve(totalNumSubscribers);

            foreach (immutable subJSON; dataJSON.array)
            {
                subs.put(GetSubscribersResults.Subscription(subJSON, numberCounter++));
            }

            immutable paginationJSON = "pagination" in responseJSON;
            if (!paginationJSON) break;

            immutable cursorJSON = "cursor" in *paginationJSON;
            if (!cursorJSON) break;

            after = cursorJSON.str;
        }
        while (after.length);

        return GetSubscribersResults(responseCode, totalNumSubscribers, subs[]);
    }

    return retryDelegate(plugin, &getSubscribersDg);
}


// sendShoutout
/++
    Sends a native Twitch shoutout.

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        sourceChannelID = ID of the channel sending the shoutout.
        targetChannelID = ID of the channel receiving the shoutout.
        caller = Name of the calling function.

    Returns:
        A `ShoutoutResults` Voldemort struct.

    See_Also:
        https://dev.twitch.tv/docs/api/reference/#send-a-shoutout
 +/
auto sendShoutout(
    TwitchPlugin plugin,
    const ulong sourceChannelID,
    const ulong targetChannelID,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `sendShoutout` from outside a fiber")
in (sourceChannelID, "Tried to call `sendShoutout` with an unset source channel ID")
in (targetChannelID, "Tried to call `sendShoutout` with an unset target channel ID")
{
    import std.format : format;

    static struct ShoutoutResults
    {
        uint code;
        auto success() const { return (code == 204); }
    }

    enum urlPattern = "https://api.twitch.tv/helix/chat/shoutouts" ~
        "?from_broadcaster_id=%d" ~
        "&to_broadcaster_id=%d" ~
        "&moderator_id=%d";

    immutable url = urlPattern.format(sourceChannelID, targetChannelID, plugin.transient.botID);

    auto sendShoutoutDg()
    {
        immutable response = sendHTTPRequest(
            plugin: plugin,
            url: url,
            caller: caller,
            authorisationHeader: plugin.transient.authorizationBearer,
            clientID: TwitchPlugin.clientID,
            verb: HTTPVerb.post);

        switch (response.code)
        {
        case 204:
            // 204 No Content
            /+
                Successfully sent the specified broadcaster a Shoutout.
             +/
            break;

        case 400:
            // 400 Bad Request
            /+
                The from_broadcaster_id query parameter is required.
                The ID in the from_broadcaster_id query parameter is not valid.
                The to_broadcaster_id query parameter is required.
                The ID in the to_broadcaster_id query parameter is not valid.
                The broadcaster may not give themselves a Shoutout.
                The broadcaster is not streaming live or does not have one or more viewers.
             +/
            goto default;

        case 401:
            // 401 Unauthorized
            /+
                The ID in moderator_id must match the user ID in the user access token.
                The Authorization header is required and must contain a user access token.
                The user access token must include the moderator:manage:shoutouts scope.
                The access token is not valid.
                The client ID specified in the Client-Id header does not match
                the client ID specified in the access token.
             +/
            goto default;

        case 403:
            // 403 Forbidden
            /+
                The user in moderator_id is not one of the broadcaster's moderators.
                The broadcaster may not send the specified broadcaster a Shoutout.
             +/
            goto default;

        case 429:
            // 429 Too Many Requests
            /+
                The broadcaster exceeded the number of Shoutouts they may send
                within a given window. See the endpoint's Rate Limits.
                The broadcaster exceeded the number of Shoutouts they may send
                the same broadcaster within a given window. See the endpoint's Rate Limits.
             +/
            goto default;

        default:
            version(PrintStacktraces)
            {
                writeln(response.code);
                printStacktrace();
            }
            // Drop down
            break;
        }

        return ShoutoutResults(response.code);
    }

    return retryDelegate(plugin, &sendShoutoutDg);
}


// deleteMessage
/++
    Deletes a message, or all messages in a channel.

    Doesn't require broadcaster-level authorisation; the normal bot token is enough.

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        channelName = Name of channel to delete message(s) in.
        messageID = ID of message to delete. Pass an empty string to delete all messages.
        caller = Name of the calling function.

    See_Also:
        https://dev.twitch.tv/docs/api/reference/#delete-chat-messages
 +/
auto deleteMessage(
    TwitchPlugin plugin,
    const string channelName,
    const string messageID,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `deleteMessage` from outside a fiber")
in (channelName.length, "Tried to delete a message without providing a channel name")
{
    import std.algorithm.searching : startsWith;
    import std.format : format;
    import core.time : msecs;

    static struct DeleteResults
    {
        uint code;
        auto success() const { return (code == 204) || (code == 404); }
    }

    const room = channelName in plugin.rooms;
    assert(room, "Tried to delete a message in a nonexistent room");

    immutable urlPattern =
        "https://api.twitch.tv/helix/moderation/chat" ~
        "?broadcaster_id=%d" ~
        "&moderator_id=%d" ~
        (messageID.length ?
            "&message_id=%s" :
            "%s");

    immutable url = urlPattern.format(room.id, plugin.transient.botID, messageID);

    auto deleteDg()
    {
        immutable response = sendHTTPRequest(
            plugin: plugin,
            url: url,
            caller: caller,
            authorisationHeader: plugin.transient.authorizationBearer,
            clientID: TwitchPlugin.clientID,
            verb: HTTPVerb.delete_);

        switch (response.code)
        {
        case 204:
            // 204 No Content
            /+
                Successfully removed the specified messages.
             +/
            break;

        case 400:
            // 400 Bad Request
            /+
                You may not delete another moderator's messages.
                You may not delete the broadcaster's messages.
             +/
            goto default;

        case 401:
            // 401 Unauthorized
            /+
                The Authorization header is required and must contain a user access token.
                The user access token is missing the moderator:manage:chat_messages scope.
                The OAuth token is not valid.
                The client ID specified in the Client-Id header does not match
                the client ID specified in the OAuth token.
             +/
            goto default;

        case 403:
            // 403 Forbidden
            /+
                The user in moderator_id is not one of the broadcaster's moderators.
             +/
            goto default;

        case 404:
            // 404 Not Found
            /+
                The ID in message_id was not found.
                The specified message was created more than 6 hours ago.
             +/
            break;

        default:
            version(PrintStacktraces)
            {
                writeln(response.code);
                printStacktrace();
            }
            // Drop down
            break;
        }

        return DeleteResults(response.code);
    }

    static immutable failedDeleteRetry = 100.msecs;
    return retryDelegate(plugin, &deleteDg, retryDelay: failedDeleteRetry);
}


// timeoutUser
/++
    Times out a user in a channel.

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        channelName = Name of channel to timeout a user in.
        userID = Twitch ID of user to timeout.
        durationSeconds = Duration of timeout in seconds.
        reason = Timeout reason.
        caller = Name of the calling function.
        recursing = Whether or not this function is recursing into itself.

    Returns:
        A Voldemort struct with information about the timeout action.

    Throws:
        [kameloso.net.UnexpectedJSONException|UnexpectedJSONException] on unexpected JSON received.
        [kameloso.net.ErrorJSONException|ErrorJSONException] if the
        response contained an `error` object.

    See_Also:
        https://dev.twitch.tv/docs/api/reference/#create-a-banned-event
 +/
auto timeoutUser(
    TwitchPlugin plugin,
    const string channelName,
    const ulong userID,
    const uint durationSeconds,
    const string reason = string.init,
    const string caller = __FUNCTION__,
    const bool recursing = false)
in (Fiber.getThis(), "Tried to call `timeoutUser` from outside a fiber")
in (channelName.length, "Tried to timeout a user without providing a channel")
in (userID, "Tried to timeout a user with an unset user ID")
{
    import std.algorithm.comparison : min;
    import std.format : format;

    static struct TimeoutResults
    {
        private import std.datetime.systime : SysTime;
        private import std.json : JSONValue;

        uint code;
        string error;
        bool alreadyBanned;  // FIXME
        ulong broadcasterID;
        ulong moderatorID;
        ulong userID;
        SysTime createdAt;
        SysTime endTime;

        auto success() const { return (code == 200); }

        this(const uint code) { this.code = code; }

        this(const uint code, const string error)
        {
            this.code = code;
            this.error = error;
        }

        this(const uint code, const bool alreadyBanned)
        {
            this.code = code;
            this.alreadyBanned = alreadyBanned;
        }

        this(const uint code, const JSONValue json)
        {
            import std.conv : to;
            import std.json : JSONType;

            /*
            {
                "data": [
                    {
                        "broadcaster_id": "1234",
                        "moderator_id": "5678",
                        "user_id": "9876",
                        "created_at": "2021-09-28T18:22:31Z",
                        "end_time": null
                    }
                ]
            }
             */
            /*
            {
                "data": [
                    {
                        "broadcaster_id": "1234",
                        "moderator_id": "5678",
                        "user_id": "9876",
                        "created_at": "2021-09-28T19:27:31Z",
                        "end_time": "2021-09-28T19:22:31Z"
                    }
                ]
            }
             */
            /*
            {
                "error": "Bad Request",
                "status": 400,
                "message": "user is already banned"
            }
             */

            this.code = code;
            this.broadcasterID = json["broadcaster_id"].str.to!ulong;
            this.moderatorID = json["moderator_id"].str.to!ulong;
            this.userID = json["user_id"].str.to!ulong;
            this.createdAt = SysTime.fromISOExtString(json["created_at"].str);

            const endTimeJSON = "end_time" in json;

            if (endTimeJSON.type == JSONType.string)
            {
                // end_time can be JSONType.string or JSONType.null_
                // If it is null_, calling endTimeJSON.str would throw
                this.endTime = SysTime.fromISOExtString(endTimeJSON.str);
            }
        }
    }

    // Work around forward-declaration of auto return type
    if (false) return TimeoutResults.init;

    const room = channelName in plugin.rooms;
    assert(room, "Tried to timeout a user in a nonexistent room");

    enum maxDurationSeconds = 1_209_600;  // 14 days

    enum urlPattern = "https://api.twitch.tv/helix/moderation/bans" ~
        "?broadcaster_id=%d" ~
        "&moderator_id=%d";

    enum bodyPattern =
`{
    "data": {
        "user_id": "%d",
        "duration": %d,
        "reason": "%s"
    }
}`;

    immutable url = urlPattern.format(room.id, plugin.transient.botID);
    immutable body = bodyPattern.format(
        userID,
        min(durationSeconds, maxDurationSeconds),
        reason);

    auto timeoutDg()
    {
        import std.json : JSONType, parseJSON;

        immutable response = sendHTTPRequest(
            plugin: plugin,
            url: url,
            caller: caller,
            authorisationHeader: plugin.transient.authorizationBearer,
            clientID: TwitchPlugin.clientID,
            verb: HTTPVerb.post,
            body: cast(ubyte[])body,
            contentType: "application/json");

        immutable responseJSON = parseJSON(response.body);

        switch (response.code)
        {
        case 200:
            // 200 OK
            /+
                Successfully banned the user or placed them in a timeout.
             +/
            break;

        case 400:
            // 400 Bad Request
            /+
                The broadcaster_id query parameter is required.
                The moderator_id query parameter is required.
                The user_id field is required.
                The text in the reason field is too long.
                The value in the duration field is not valid.
                The user specified in the user_id field may not be banned.
                The user specified in the user_id field may not be put in a timeout.
                The user specified in the user_id field is already banned.
             +/
            goto default;

        case 401:
            // 401 Unauthorized
            /+
                The ID in moderator_id must match the user ID in the access token.
                The Authorization header is required and must contain a user access token.
                The user access token must include the moderator:manage:banned_users scope.
                The access token is not valid.
                The client ID specified in the Client-Id header does not match
                the client ID specified in the access token.
             +/
            goto default;

        case 403:
            // 403 Forbidden
            /+
                The user in moderator_id is not one of the broadcaster's moderators.
             +/
            goto default;

        case 409:
            // 409 Conflict
            /+
                You may not update the user's ban state while someone else is
                updating the state. For example, someone else is currently
                banning the user or putting them in a timeout, moving the user
                from a timeout to a ban, or removing the user from a ban or timeout.
                Please retry your request.
             +/
            if (!recursing)
            {
                // Retry once
                return timeoutUser(
                    plugin: plugin,
                    channelName: channelName,
                    userID: userID,
                    durationSeconds: durationSeconds,
                    reason: reason,
                    caller: caller,
                    recursing: true);
            }
            goto default;

        case 429:
            // 429 Too Many Requests
            /+
                The app has exceeded the number of requests it may make per
                minute for this broadcaster.
             +/
            goto default;

        default:
            version(PrintStacktraces)
            {
                writeln(response.code);
                writeln(responseJSON.toPrettyString);
                printStacktrace();
            }

            if (immutable errorJSON = "error" in responseJSON)
            {
                return TimeoutResults(response.code, errorJSON.str);
            }
            else
            {
                return TimeoutResults(response.code);
            }
        }

        immutable dataJSON = "data" in responseJSON;

        if (!dataJSON)
        {
            if (immutable errorJSON = "error" in responseJSON)
            {
                if ((*errorJSON)["message"].str == "user is already banned")
                {
                    return TimeoutResults(response.code, alreadyBanned: true);
                }
                else
                {
                    return TimeoutResults(response.code, (*errorJSON)["message"].str);
                }
            }
            else
            {
                enum message = "`timeoutUser` response has unexpected JSON " ~
                    `(no "data" key)`;
                throw new UnexpectedJSONException(message, responseJSON);
            }
        }

        return TimeoutResults(response.code, *dataJSON);
    }

    return retryDelegate(plugin, &timeoutDg);
}


// sendWhisper
/++
    Sends a whisper to a user.

    The bot user sending the whisper must have a verified phone number or the
    action will fail with a `401` response code.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        userID = Twitch ID of user to send whisper to.
        message = Message to send.
        caller = Name of the calling function.

    Returns:
        A Voldemort struct with the HTTP response code.

    See_Also:
        https://dev.twitch.tv/docs/api/reference/#send-whisper
 +/
auto sendWhisper(
    TwitchPlugin plugin,
    const ulong userID,
    const string message,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `sendWhisper` from outside a fiber")
{
    import std.array : replace;
    import std.format : format;

    static struct WhisperResult
    {
        uint code;
        auto success() const { return (code == 204); }
    }

    enum urlPattern = "https://api.twitch.tv/helix/whispers" ~
        "?from_user_id=%d" ~
        "&to_user_id=%d";

    enum bodyPattern =
`{
    "message": "%s"
}`;

    immutable url = urlPattern.format(plugin.transient.botID, userID);
    immutable messageArgument = message.replace(`"`, `\"`);  // won't work with already escaped quotes
    immutable body = bodyPattern.format(messageArgument);

    auto sendWhisperDg()
    {
        immutable response = sendHTTPRequest(
            plugin: plugin,
            url: url,
            caller: caller,
            authorisationHeader: plugin.transient.authorizationBearer,
            clientID: TwitchPlugin.clientID,
            verb: HTTPVerb.post,
            body: cast(ubyte[])body,
            contentType: "application/json");

        switch (response.code)
        {
        case 204:
            // 204 No Content
            /+
                Successfully sent the whisper message or the message was silently dropped.
             +/
            break;

        case 400:
            // 400 Bad Request
            /+
                The ID in the from_user_id and to_user_id query parameters must be different.
                The message field must not contain an empty string.
                The user that you're sending the whisper to doesn't allow whisper messages
                (see the Block Whispers from Strangers setting in your Security and Privacy settings).
                Whisper messages may not be sent to suspended users.
                The ID in the from_user_id query parameter is not valid.
                The ID in the to_user_id query parameter is not valid.
             +/
            goto default;

        case 401:
            // 401 Unauthorized
            /+
                The user in the from_user_id query parameter must have a verified phone number.
                The Authorization header is required and must contain a user access token.
                The user access token must include the user:manage:whispers scope.
                The access token is not valid.
                This ID in from_user_id must match the user ID in the user access token.
                The client ID specified in the Client-Id header does not match the
                client ID specified in the access token.
             +/
            goto default;

        case 403:
            // 403 Forbidden
            /+
                Suspended users may not send whisper messages.
                The account that's sending the message doesn't allow sending whispers.
             +/
        case 404:
            // 404 Not Found
            /+
                The ID in to_user_id was not found.
             +/
            goto default;

        case 429:
            // 429 Too Many Requests
            /+
                The sending user exceeded the number of whisper requests that they may make.

                Rate Limits: You may whisper to a maximum of 40 unique recipients per day.
                Within the per day limit, you may whisper a maximum of 3 whispers
                per second and a maximum of 100 whispers per minute.
             +/
            goto default;

        default:
            version(PrintStacktraces)
            {
                writeln(response.code);
                printStacktrace();
            }
            // Drop down
            break;
        }

        return WhisperResult(response.code);
    }

    return retryDelegate(plugin, &sendWhisperDg);
}


// sendAnnouncement
/++
    Sends a Twitch chat announcement.

    Message lengths may not exceed 500 characters; messages longer are truncated.

    Valid values for `colour` are:

    * blue
    * green
    * orange
    * purple
    * primary (default)

    Invalid values are overridden to `primary`.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        channelID = Twitch ID of channel to send announcement to.
        message = The announcement to make in the broadcaster’s chat room.
        colour = The color used to highlight the announcement.
        caller = Name of the calling function.

    Returns:
        A Voldemort struct with the HTTP response code.

    See_Also:
        https://dev.twitch.tv/docs/api/reference/#send-chat-announcement
 +/
auto sendAnnouncement(
    TwitchPlugin plugin,
    const ulong channelID,
    const string message,
    const string colour = "primary",
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `sendAnnouncement` from outside a fiber")
{
    import std.algorithm.comparison : among;
    import std.array : replace;
    import std.format : format;

    static struct AnnouncementResults
    {
        uint code;
        auto success() const { return (code == 204); }
    }

    enum urlPattern = "https://api.twitch.tv/helix/chat/announcements" ~
        "?broadcaster_id=%d" ~
        "&moderator_id=%d";

    enum bodyPattern =
`{
    "message": "%s",
    "color": "%s"
}`;

    /+
        message: The announcement to make in the broadcaster’s chat room.
            Announcements are limited to a maximum of 500 characters;
            announcements longer than 500 characters are truncated.
        color: The color used to highlight the announcement.
            Possible case-sensitive values are:
                blue
                green
                orange
                purple
                primary (default)
            If color is set to primary or is not set, the channel’s accent color
            is used to highlight the announcement (see Profile Accent Color
            under profile settings, Channel and Videos, and Brand).
     +/

    immutable colourArgument = colour.among!("primary", "blue", "green", "orange", "purple") ?
        colour :
        "primary";

    immutable url = urlPattern.format(channelID, plugin.transient.botID);
    immutable messageArgument = message.replace(`"`, `\"`);  // won't work with already escaped quotes
    immutable body = bodyPattern.format(messageArgument, colourArgument);

    auto sendAnnouncementDg()
    {
        immutable response = sendHTTPRequest(
            plugin: plugin,
            url: url,
            caller: caller,
            authorisationHeader: plugin.transient.authorizationBearer,
            clientID: TwitchPlugin.clientID,
            verb: HTTPVerb.post,
            body: cast(ubyte[])body,
            contentType: "application/json");

        switch (response.code)
        {
        case 204:
            // 204 No Content
            /+
                Successfully sent the announcement
             +/
            break;

        case 400:
            // 400 Bad Request
            /+
                The message field in the request's body is required.
                The message field may not contain an empty string.
                The string in the message field failed review.
                The specified color is not valid.
             +/
            goto default;

        case 401:
            // 401 Unauthorized
            /+
                The Authorization header is required and must contain a user access token.
                The user access token is missing the moderator:manage:announcements scope.
                The OAuth token is not valid.
                The client ID specified in the Client-Id header does not match
                the client ID specified in the OAuth token
             +/
            goto default;

        case 429:
            // 429 Too Many Requests
            /+
                The sender has exceeded the number of announcements they may
                send to this broadcaster_id within a given window.
             +/
            goto default;

        default:
            version(PrintStacktraces)
            {
                writeln(response.code);
                printStacktrace();
            }
            // Drop down
            break;
        }

        return AnnouncementResults(response.code);
    }

    return retryDelegate(plugin, &sendAnnouncementDg);
}


// warnUser
/++
    Warns a user in a channel.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        channelID = Twitch ID of channel to warn user in.
        userID = Twitch ID of user to warn.
        reason = Reason for warning the user.
        caller = Name of the calling function.

    Returns:
        A Voldemort struct with the HTTP response code.

    See_Also:
        https://dev.twitch.tv/docs/api/reference/#warn-chat-user
 +/
auto warnUser(
    TwitchPlugin plugin,
    const ulong channelID,
    const ulong userID,
    const string reason,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `warnUser` from outside a fiber")
{
    import std.array : replace;
    import std.format : format;
    import std.json : parseJSON;

    static struct WarnResults
    {
        uint code;
        string error;

        auto success() const { return (code == 200); }
    }

    enum urlPattern = "https://api.twitch.tv/helix/moderation/warnings" ~
        "?broadcaster_id=%d" ~
        "&moderator_id=%d";

    enum bodyPattern =
`{
    "data": {
        "user_id": "%d",
        "reason": "%s"
    }
}`;

    immutable url = urlPattern.format(channelID, plugin.transient.botID);
    immutable reasonArgument = reason.replace(`"`, `\"`);  // won't work with already escaped quotes
    immutable body = bodyPattern.format(userID, reasonArgument);

    auto warnUserDg()
    {
        immutable response = sendHTTPRequest(
            plugin: plugin,
            url: url,
            caller: caller,
            authorisationHeader: plugin.transient.authorizationBearer,
            clientID: TwitchPlugin.clientID,
            verb: HTTPVerb.post,
            body: cast(ubyte[])body,
            contentType: "application/json");

        immutable responseJSON = parseJSON(response.body);

        switch (response.code)
        {
        case 200:
            // 200 OK
            /+
                Successfully warned the user
             +/
            break;

        case 400:
            // 400 Bad Request
            /+
                The broadcaster_id query parameter is required.
                The moderator_id query parameter is required.
                The user_id query parameter is required.
                The reason query parameter is required.
                The text in the reason field is too long.
                The user specified in the user_id may not be warned.
             +/
            goto default;

        case 401:
            // 401 Unauthorized
            /+
                The ID in moderator_id must match the user ID in the user access token.
                The Authorization header is required and must contain a user access token.
                The user access token must include the moderator:manage:warnings scope.
                The access token is not valid.
                The client ID specified in the Client-Id header does not match the
                client ID specified in the access token.
             +/
            goto default;

        case 403:
            // 403 Forbidden
            /+
                The user in moderator_id is not one of the broadcaster’s moderators.
             +/
            goto default;

        case 409:
            // 409 Conflict
            /+
                You may not update the user’s warning state while someone else is
                updating the state. For example, someone else is currently warning
                the user or the user is acknowledging an existing warning.
                Please retry your request.
             +/
            goto default;

        case 429:
            // 429 Too Many Requests
            /+
                The app has exceeded the number of requests it may make per
                minute for this broadcaster.
             +/
            goto default;

        case 500:
            // 500 Internal Server Error
            /+
                Internal Server Error.
             +/
            goto default;

        default:
            version(PrintStacktraces)
            {
                writeln(response.code);
                writeln(responseJSON.toPrettyString);
                printStacktrace();
            }

            if (immutable errorJSON = "error" in responseJSON)
            {
                return WarnResults(response.code, errorJSON.str);
            }
            else
            {
                return WarnResults(response.code);
            }
        }

        /*
        {
            "data": [
                {
                    "broadcaster_id": "404040",
                    "user_id": "9876",
                    "moderator_id": "404041",
                    "reason": "stop doing that!"
                }
            ]
        }
         */
        return WarnResults(response.code);
    }

    return retryDelegate(plugin, &warnUserDg);
}
