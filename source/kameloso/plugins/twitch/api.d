/++
    Functions for accessing the Twitch API. For internal use.

    See_Also:
        [kameloso.plugins.twitch.base],
        [kameloso.plugins.twitch.keygen],
        [kameloso.plugins.common.core],
        [kameloso.plugins.common.misc]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.twitch.api;

version(TwitchSupport):
version(WithTwitchPlugin):

private:

import kameloso.plugins.twitch.base;
import kameloso.plugins.twitch.common;

import arsd.http2 : HttpVerb;
import dialect.defs;
import std.typecons : Flag, No, Yes;
import core.thread : Fiber;

package:


// QueryResponse
/++
    Embodies a response from a query to the Twitch servers. A string paired with
    a millisecond count of how long the query took, and some metadata about the request.

    This is used instead of a [std.typecons.Tuple] because it doesn't apparently
    work with `shared`.
 +/
struct QueryResponse
{
    /++
        Response body, may be several lines.
     +/
    string str;

    /++
        How long the query took, from issue to response.
     +/
    long msecs;

    /++
        The HTTP response code received.
     +/
    uint code;

    /++
        The message of any exception thrown while querying.
     +/
    string error;
}


// retryDelegate
/++
    Retries a passed delegate until it no longer throws or until the hardcoded
    number of retries
    ([kameloso.plugins.twitch.base.TwitchPlugin.delegateRetries|TwitchPlugin.delegateRetries])
    is reached.

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        dg = Delegate to call.

    Returns:
        Whatever the passed delegate returns.
 +/
auto retryDelegate(Dg)(TwitchPlugin plugin, Dg dg)
{
    foreach (immutable i; 0..TwitchPlugin.delegateRetries)
    {
        try
        {
            if (i > 0)
            {
                import kameloso.plugins.common.delayawait : delay;
                import core.time : seconds;

                static immutable retryDelay = 1.seconds;
                delay(plugin, retryDelay, Yes.yield);
            }
            return dg();
        }
        catch (MissingBroadcasterTokenException e)
        {
            // This is never a transient error
            throw e;
        }
        catch (Exception e)
        {
            // Retry until we reach the retry limit, then print if we should, before rethrowing
            if (i < TwitchPlugin.delegateRetries-1) continue;

            version(PrintStacktraces)
            {
                if (!plugin.state.settings.headless)
                {
                    printRetryDelegateException(e);
                }
            }
            throw e;
        }
    }

    assert(0, "Unreachable");
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

    if (auto e = cast(TwitchQueryException)base)
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
    else if (auto e = cast(TwitchJSONException)base)
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


// persistentQuerier
/++
    Persistent worker issuing Twitch API queries based on the concurrency messages
    sent to it.

    Example:
    ---
    spawn(&persistentQuerier, plugin.bucket, caBundleFile);
    ---

    Params:
        bucket = The shared associative array to put the results in, response
            values keyed by a unique numerical ID.
        caBundleFile = Path to a `cacert.pem` SSL certificate bundle.
 +/
void persistentQuerier(
    shared QueryResponse[int] bucket,
    const string caBundleFile)
{
    import kameloso.thread : ThreadMessage;
    import std.concurrency : OwnerTerminated, receive;
    import std.variant : Variant;

    version(Posix)
    {
        import kameloso.thread : setThreadName;
        setThreadName("twitchworker");
    }

    bool halt;

    void invokeSendHTTPRequestImpl(
        const int id,
        const string url,
        const string authToken,
        /*const*/ HttpVerb verb,
        immutable(ubyte)[] body_,
        const string contentType) scope
    {
        version(BenchmarkHTTPRequests)
        {
            import core.time : MonoTime;
            immutable pre = MonoTime.currTime;
        }

        immutable response = sendHTTPRequestImpl(
            url,
            authToken,
            caBundleFile,
            verb,
            cast(ubyte[])body_,
            contentType);

        synchronized //()
        {
            bucket[id] = response;  // empty str if code >= 400
        }

        version(BenchmarkHTTPRequests)
        {
            import std.stdio : stdout, writefln;
            immutable post = MonoTime.currTime;
            enum pattern = "%s (%s)";
            writefln(pattern, post-pre, url);
            stdout.flush();
        }
    }

    void sendWithBody(
        int id,
        string url,
        string authToken,
        HttpVerb verb,
        immutable(ubyte)[] body_,
        string contentType) scope
    {
        invokeSendHTTPRequestImpl(
            id,
            url,
            authToken,
            verb,
            body_,
            contentType);
    }

    void sendWithoutBody(
        int id,
        string url,
        string authToken) scope
    {
        // Shorthand
        invokeSendHTTPRequestImpl(
            id,
            url,
            authToken,
            HttpVerb.GET,
            cast(immutable(ubyte)[])null,
            string.init);
    }

    void onMessage(ThreadMessage message) scope
    {
        halt = (message.type == ThreadMessage.Type.teardown);
    }

    void onOwnerTerminated(OwnerTerminated _) scope
    {
        halt = true;
    }

    while (!halt)
    {
        receive(
            &sendWithBody,
            &sendWithoutBody,
            &onMessage,
            &onOwnerTerminated,
            (Variant v) scope
            {
                import std.stdio : stdout, writeln;
                writeln("Twitch worker received unknown Variant: ", v);
                stdout.flush();
            }
        );
    }
}


// sendHTTPRequest
/++
    Wraps [sendHTTPRequestImpl] by proxying calls to it via the
    [persistentQuerier] subthread.

    Once the query returns, the response body is checked to see whether or not
    an error occurred. If so, it throws an exception with a descriptive message.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Example:
    ---
    immutable QueryResponse = sendHTTPRequest(plugin, "https://id.twitch.tv/oauth2/validate", __FUNCTION__, "OAuth 30letteroauthstring");
    ---

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        url = The URL to query.
        caller = Name of the calling function.
        authorisationHeader = Authorisation HTTP header to pass.
        verb = What [arsd.http2.HttpVerb|HttpVerb] to use in the request.
        body_ = Request body to send in case of verbs like `POST` and `PATCH`.
        contentType = "Content-Type" HTTP header to pass.
        id = Numerical ID to use instead of generating a new one.
        recursing = Whether or not this is a recursive call and another one should
            not be attempted.

    Returns:
        The [QueryResponse] that was discovered while monitoring the `bucket`
        as having been received from the server.

    Throws:
        [TwitchQueryException] if there were unrecoverable errors.
 +/
QueryResponse sendHTTPRequest(
    TwitchPlugin plugin,
    const string url,
    const string caller = __FUNCTION__,
    const string authorisationHeader = string.init,
    /*const*/ HttpVerb verb = HttpVerb.GET,
    /*const*/ ubyte[] body_ = null,
    const string contentType = string.init,
    int id = -1,
    const Flag!"recursing" recursing = No.recursing)
in (Fiber.getThis, "Tried to call `sendHTTPRequest` from outside a Fiber")
in (url.length, "Tried to send an HTTP request without a URL")
{
    import kameloso.plugins.common.delayawait : delay;
    import kameloso.thread : ThreadMessage;
    import std.concurrency : prioritySend, send;
    import core.time : MonoTime, msecs;

    if (plugin.state.settings.trace)
    {
        import kameloso.common : logger;
        enum pattern = "%s: <i>%s<t> (%s)";
        logger.tracef(pattern, verb, url, caller);
    }

    plugin.state.mainThread.prioritySend(ThreadMessage.shortenReceiveTimeout);

    immutable pre = MonoTime.currTime;
    if (id == -1) id = getUniqueNumericalID(plugin.bucket);

    plugin.persistentWorkerTid.send(
        id,
        url,
        authorisationHeader,
        verb,
        body_.idup,
        contentType);

    delay(plugin, plugin.approximateQueryTime.msecs, Yes.yield);
    immutable response = waitForQueryResponse(plugin, id);

    scope(exit)
    {
        synchronized //()
        {
            // Always remove, otherwise there'll be stale entries
            plugin.bucket.remove(id);
        }
    }

    immutable post = MonoTime.currTime;
    immutable diff = (post - pre);
    immutable msecs_ = diff.total!"msecs";
    averageApproximateQueryTime(plugin, msecs_);

    if (response.code == 2)
    {
        throw new TwitchQueryException(
            response.error,
            response.str,
            response.error,
            response.code);
    }
    else if (response.code == 0) //(!response.str.length)
    {
        throw new EmptyResponseException("Empty response");
    }
    else if ((response.code >= 500) && !recursing)
    {
        return sendHTTPRequest(
            plugin,
            url,
            caller,
            authorisationHeader,
            verb,
            body_,
            contentType,
            id,
            Yes.recursing);
    }
    else if (response.code >= 400)
    {
        import std.format : format;
        import std.json : JSONException;

        try
        {
            import lu.string : unquoted;
            import std.json : parseJSON;
            import std.string : chomp;

            // {"error":"Unauthorized","status":401,"message":"Must provide a valid Client-ID or OAuth token"}
            /+
            {
                "error": "Unauthorized",
                "message": "Client ID and OAuth token do not match",
                "status": 401
            }
            {
                "error": "Unknown Emote Set",
                "error_code": 70441,
                "status": "Not Found",
                "status_code": 404
            }
            {
                "message": "user not found"
            }
             +/

            immutable json = parseJSON(response.str);
            uint code = response.code;
            string status;
            string message;

            if (immutable statusCodeJSON = "status_code" in json)
            {
                code = cast(uint)(*statusCodeJSON).integer;
                status = json["status"].str;
                message = json["error"].str;
            }
            else if (immutable statusJSON = "status" in json)
            {
                import std.json : JSONException;

                try
                {
                    code = cast(uint)(*statusJSON).integer;
                    status = json["error"].str;
                    message = json["message"].str;
                }
                catch (JSONException _)
                {
                    status = "Error";
                    message = json["message"].str;
                }
            }
            else if (immutable messageJSON = "message" in json)
            {
                status = "Error";
                message = (*messageJSON).str;
            }
            else
            {
                version(PrintStacktraces)
                {
                    if (!plugin.state.settings.headless)
                    {
                        import std.stdio : stdout, writeln;
                        writeln(json.toPrettyString);
                        stdout.flush();
                    }
                }

                status = "Error";
                message = "An unspecified error occured";
            }

            enum pattern = "%3d %s: %s";
            immutable exceptionMessage = pattern.format(
                code,
                status.chomp.unquoted,
                message.chomp.unquoted);
            throw new ErrorJSONException(exceptionMessage, json);
        }
        catch (JSONException e)
        {
            import kameloso.string : doublyBackslashed;

            throw new TwitchQueryException(
                e.msg,
                response.str,
                response.error,
                response.code,
                e.file.doublyBackslashed,
                e.line);
        }
    }

    return response;
}


// sendHTTPRequestImpl
/++
    Sends a HTTP request of the passed verb to the passed URL, and returns the response.

    Params:
        url = URL address to look up.
        authHeader = Authorisation token HTTP header to pass.
        caBundleFile = Path to a `cacert.pem` SSL certificate bundle.
        verb = What [arsd.http2.HttpVerb|HttpVerb] to use in the request.
        body_ = Request body to send in case of verbs like `POST` and `PATCH`.
        contentType = "Content-Type" HTTP header to use.

    Returns:
        A [QueryResponse] of the response from the server.
 +/
auto sendHTTPRequestImpl(
    const string url,
    const string authHeader,
    const string caBundleFile,
    /*const*/ HttpVerb verb = HttpVerb.GET,
    /*const*/ ubyte[] body_ = null,
    /*const*/ string contentType = string.init)
{
    import kameloso.constants : KamelosoInfo, Timeout;
    import arsd.http2 : HttpClient, Uri;
    import std.algorithm.comparison : among;
    import core.time : MonoTime, seconds;

    static HttpClient client;
    static string[] headers;

    if (!client)
    {
        import kameloso.constants : KamelosoInfo;

        client = new HttpClient;
        client.useHttp11 = true;
        client.keepAlive = true;
        client.acceptGzip = false;
        client.defaultTimeout = Timeout.httpGET.seconds;
        client.userAgent = "kameloso/" ~ cast(string)KamelosoInfo.version_;
        headers = [ "Client-ID: " ~ TwitchPlugin.clientID ];
        if (caBundleFile.length) client.setClientCertificate(caBundleFile, caBundleFile);
    }

    client.authorization = authHeader;

    QueryResponse response;
    auto pre = MonoTime.currTime;
    auto req = client.request(Uri(url), verb, body_, contentType);
    // The Twitch Client-ID header leaks into Google and Spotify requests. Worth dealing with?
    req.requestParameters.headers = headers;
    auto res = req.waitForCompletion();

    if (res.code.among!(301, 302, 307, 308) && res.location.length)
    {
        // Moved
        foreach (immutable i; 0..5)
        {
            pre = MonoTime.currTime;
            req = client.request(Uri(res.location), verb, body_, contentType);
            req.requestParameters.headers = headers;
            res = req.waitForCompletion();

            if (!res.code.among!(301, 302, 307, 308) || !res.location.length) break;
        }
    }

    response.code = res.code;
    response.error = res.codeText;
    response.str = res.contentText;
    immutable post = MonoTime.currTime;
    immutable delta = (post - pre);
    response.msecs = delta.total!"msecs";
    return response;
}


// getTwitchData
/++
    By following a passed URL, queries Twitch servers for an entity (user or channel).

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        url = The URL to follow.
        caller = Name of the calling function.

    Returns:
        A singular user or channel regardless of how many were asked for in the URL.
        If nothing was found, an exception is thrown instead.

    Throws:
        [EmptyDataJSONException] if the `"data"` field is empty for some reason.

        [UnexpectedJSONException] on unexpected JSON.

        [TwitchQueryException] on other JSON errors.
 +/
auto getTwitchData(
    TwitchPlugin plugin,
    const string url,
    const string caller = __FUNCTION__)
in (Fiber.getThis, "Tried to call `getTwitchData` from outside a Fiber")
{
    import std.json : JSONException, JSONType, parseJSON;

    // Request here outside try-catch to let exceptions fall through
    immutable response = sendHTTPRequest(plugin, url, caller, plugin.authorizationBearer);

    try
    {
        immutable responseJSON = parseJSON(response.str);

        if (responseJSON.type != JSONType.object)
        {
            enum message = "`getTwitchData` query response JSON is not JSONType.object";
            throw new UnexpectedJSONException(message, responseJSON);
        }
        else if (immutable dataJSON = "data" in responseJSON)
        {
            if (dataJSON.array.length == 1)
            {
                return dataJSON.array[0];
            }
            else if (!dataJSON.array.length)
            {
                enum message = "`getTwitchData` query response JSON has empty \"data\"";
                throw new EmptyDataJSONException(message, responseJSON);
            }
            else
            {
                enum message = "`getTwitchData` query response JSON \"data\" value is not a 1-length array";
                throw new UnexpectedJSONException(message, *dataJSON);
            }
        }
        else
        {
            enum message = "`getTwitchData` query response JSON does not contain a \"data\" element";
            throw new UnexpectedJSONException(message, responseJSON);
        }
    }
    catch (JSONException e)
    {
        import kameloso.string : doublyBackslashed;

        throw new TwitchQueryException(
            e.msg,
            response.str,
            response.error,
            response.code,
            e.file.doublyBackslashed,
            e.line);
    }
}


// getChatters
/++
    Get the JSON representation of everyone currently in a broadcaster's channel.

    It is not updated in realtime, so it doesn't make sense to call this often.

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        broadcaster = The broadcaster to look up chatters for.
        caller = Name of the calling function.

    Returns:
        A [std.json.JSONValue|JSONValue] with "`chatters`" and "`chatter_count`" keys.
        If nothing was found, an exception is thrown instead.

    Throws:
        [UnexpectedJSONException] on unexpected JSON.
 +/
auto getChatters(
    TwitchPlugin plugin,
    const string broadcaster,
    const string caller = __FUNCTION__)
in (Fiber.getThis, "Tried to call `getChatters` from outside a Fiber")
in (broadcaster.length, "Tried to get chatters with an empty broadcaster string")
{
    import std.conv : text;
    import std.json : JSONType, parseJSON;

    immutable chattersURL = text("https://tmi.twitch.tv/group/user/", broadcaster, "/chatters");

    auto getChattersDg()
    {
        immutable response = sendHTTPRequest(plugin, chattersURL, caller, plugin.authorizationBearer);
        immutable responseJSON = parseJSON(response.str);

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

        if (responseJSON.type != JSONType.object)
        {
            enum message = "`getChatters` response JSON is not JSONType.object";
            throw new UnexpectedJSONException(message, responseJSON);
        }

        immutable chattersJSON = "chatters" in responseJSON;
        if (!chattersJSON)
        {
            // For some reason we received an object that didn't contain chatters
            enum message = "`getChatters` \"chatters\" JSON is not JSONType.object";
            throw new UnexpectedJSONException(message, *chattersJSON);
        }

        // Don't return `chattersJSON`, as we would lose "chatter_count".
        return responseJSON;
    }

    return retryDelegate(plugin, &getChattersDg);
}


// getValidation
/++
    Validates an access key, retrieving information about it.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        authToken = Authorisation token to validate.
        async = Whether or not the validation should be done asynchronously, using Fibers.
        caller = Name of the calling function.

    Returns:
        A [std.json.JSONValue|JSONValue] with the validation information JSON of the
        current authorisation header/client ID pair.

    Throws:
        [UnexpectedJSONException] on unexpected JSON received.

        [TwitchQueryException] on other failure.
 +/
auto getValidation(
    TwitchPlugin plugin,
    /*const*/ string authToken,
    const Flag!"async" async,
    const string caller = __FUNCTION__)
in ((!async || Fiber.getThis), "Tried to call asynchronous `getValidation` from outside a Fiber")
in (authToken.length, "Tried to validate an empty Twitch authorisation token")
{
    import std.algorithm.searching : startsWith;
    import std.json : JSONType, parseJSON;

    enum url = "https://id.twitch.tv/oauth2/validate";

    // Validation needs an "Authorization: OAuth xxx" header, as opposed to the
    // "Authorization: Bearer xxx" used everywhere else.
    authToken = plugin.state.bot.pass.startsWith("oauth:") ?
        authToken[6..$] :
        authToken;
    immutable authorizationHeader = "OAuth " ~ authToken;

    auto getValidationDg()
    {
        QueryResponse response;

        if (async)
        {
            response = sendHTTPRequest(plugin, url, caller, authorizationHeader);
        }
        else
        {
            if (plugin.state.settings.trace)
            {
                import kameloso.common : logger;
                enum pattern = "GET: <i>%s<t> (%s)";
                logger.tracef(pattern, url, __FUNCTION__);
            }

            response = sendHTTPRequestImpl(
                url,
                authorizationHeader,
                plugin.state.connSettings.caBundleFile);

            // Copy/paste error handling...
            if (response.code == 2)
            {
                throw new TwitchQueryException(
                    response.error,
                    response.str,
                    response.error,
                    response.code);
            }
            else if (response.code == 0) //(!response.str.length)
            {
                throw new TwitchQueryException(
                    "Empty response",
                    response.str,
                    response.error,
                    response.code);
            }
            else if (response.code >= 400)
            {
                import std.format : format;
                import std.json : JSONException;

                try
                {
                    import lu.string : unquoted;
                    import std.json : parseJSON;
                    import std.string : chomp;

                    // {"error":"Unauthorized","status":401,"message":"Must provide a valid Client-ID or OAuth token"}
                    /*
                    {
                        "error": "Unauthorized",
                        "message": "Client ID and OAuth token do not match",
                        "status": 401
                    }
                    */
                    immutable errorJSON = parseJSON(response.str);
                    enum pattern = "%3d %s: %s";

                    immutable message = pattern.format(
                        errorJSON["status"].integer,
                        errorJSON["error"].str.unquoted,
                        errorJSON["message"].str.chomp.unquoted);

                    throw new TwitchQueryException(message, response.str, response.error, response.code);
                }
                catch (JSONException e)
                {
                    throw new TwitchQueryException(
                        e.msg,
                        response.str,
                        response.error,
                        response.code);
                }
            }
        }

        immutable validationJSON = parseJSON(response.str);

        if ((validationJSON.type != JSONType.object) || ("client_id" !in validationJSON))
        {
            enum message = "Failed to validate Twitch authorisation token; unknown JSON";
            throw new UnexpectedJSONException(message, validationJSON);
        }

        return validationJSON;
    }

    return retryDelegate(plugin, &getValidationDg);
}


// getFollows
/++
    Fetches a list of all follows of the passed channel and caches them in
    the channel's entry in [kameloso.plugins.twitch.base.TwitchPlugin.rooms|TwitchPlugin.rooms].

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        id = The string identifier for the channel.

    Returns:
        An associative array of [std.json.JSONValue|JSONValue]s keyed by nickname string,
        containing follows.
 +/
auto getFollows(TwitchPlugin plugin, const string id)
in (Fiber.getThis, "Tried to call `getFollows` from outside a Fiber")
in (id.length, "Tried to get follows with an empty ID string")
{
    immutable url = "https://api.twitch.tv/helix/users/follows?first=100&to_id=" ~ id;

    auto getFollowsDg()
    {
        const entitiesArrayJSON = getMultipleTwitchData(plugin, url);
        Follow[string] allFollows;

        foreach (entityJSON; entitiesArrayJSON)
        {
            immutable key = entityJSON["from_id"].str;
            allFollows[key] = Follow.fromJSON(entityJSON);
        }

        return allFollows;
    }

    return retryDelegate(plugin, &getFollowsDg);
}


// getMultipleTwitchData
/++
    By following a passed URL, queries Twitch servers for an array of entities
    (such as users or channels).

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        url = The URL to follow.
        caller = Name of the calling function.

    Returns:
        A [std.json.JSONValue|JSONValue] of type `array` containing all returned
        entities, over all paginated queries.
 +/
auto getMultipleTwitchData(
    TwitchPlugin plugin,
    const string url,
    const string caller = __FUNCTION__)
in (Fiber.getThis, "Tried to call `getMultipleTwitchData` from outside a Fiber")
{
    import std.conv : text;
    import std.json : JSONValue, parseJSON;

    JSONValue allEntitiesJSON;
    allEntitiesJSON = null;
    allEntitiesJSON.array = null;
    string after;

    do
    {
        immutable paginatedURL = after.length ?
            text(url, "&after=", after) :
            url;
        immutable response = sendHTTPRequest(plugin, paginatedURL, caller, plugin.authorizationBearer);
        immutable responseJSON = parseJSON(response.str);
        immutable dataJSON = "data" in responseJSON;

        if (!dataJSON)
        {
            enum message = "No data in JSON response";
            throw new UnexpectedJSONException(message, *dataJSON);
        }

        foreach (thisResponseJSON; dataJSON.array)
        {
            allEntitiesJSON.array ~= thisResponseJSON;
        }

        immutable cursor = "cursor" in responseJSON["pagination"];

        after = cursor ?
            cursor.str :
            string.init;
    }
    while (after.length);

    return allEntitiesJSON.array;
}


// averageApproximateQueryTime
/++
    Given a query time measurement, calculate a new approximate query time based on
    the weighted averages of the old value and said new measurement.

    The old value is given a weight of
    [kameloso.plugins.twitch.base.TwitchPlugin.QueryConstants.averagingWeight|averagingWeight]
    and the new measurement a weight of 1. Additionally the measurement is padded by
    [kameloso.plugins.twitch.base.TwitchPlugin.QueryConstants.measurementPadding|measurementPadding]
    to be on the safe side.

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        responseMsecs = The new measurement of how many milliseconds the last
            query took to complete.
 +/
void averageApproximateQueryTime(TwitchPlugin plugin, const long responseMsecs)
{
    import std.algorithm.comparison : min;

    enum maxDeltaToResponse = 5000;

    immutable current = plugin.approximateQueryTime;
    alias weight = TwitchPlugin.QueryConstants.averagingWeight;
    alias padding = TwitchPlugin.QueryConstants.measurementPadding;
    immutable responseAdjusted = cast(long)min(responseMsecs, (current + maxDeltaToResponse));
    immutable average = ((weight * current) + (responseAdjusted + padding)) / (weight + 1);

    version(BenchmarkHTTPRequests)
    {
        import std.stdio : writefln;
        enum pattern = "time:%s | response: %d~%d (+%d) | new average:%s";
        writefln(
            pattern,
            current,
            responseMsecs,
            responseAdjusted,
            cast(long)padding,
            average);
    }

    plugin.approximateQueryTime = cast(long)average;
}


// waitForQueryResponse
/++
    Common code to wait for a query response.

    Merely spins and monitors the shared `bucket` associative array for when a
    response has arrived, and then returns it.

    Times out after a hardcoded [kameloso.constants.Timeout.httpGET|Timeout.httpGET]
    if nothing was received.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Example:
    ---
    immutable id = getUniqueNumericalID(plugin.bucket);
    immutable url = "https://api.twitch.tv/helix/users?login=zorael";
    plugin.persistentWorkerTid.send(id, url, plugin.authorizationBearer);

    delay(plugin, plugin.approximateQueryTime.msecs, Yes.yield);
    immutable response = waitForQueryResponse(plugin, id, url);
    // response.str is the response body
    ---

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        id = Numerical ID to use as key when storing the response in the bucket AA.

    Returns:
        A [QueryResponse] as constructed by other parts of the program.
 +/
auto waitForQueryResponse(TwitchPlugin plugin, const int id)
in (Fiber.getThis, "Tried to call `waitForQueryResponse` from outside a Fiber")
{
    import kameloso.constants : Timeout;
    import kameloso.plugins.common.delayawait : delay;
    import std.datetime.systime : Clock;
    import core.time : msecs;

    version(BenchmarkHTTPRequests)
    {
        import std.stdio : writefln;
        uint misses;
    }

    immutable startTimeInUnix = Clock.currTime.toUnixTime();
    shared QueryResponse* response;
    double accumulatingTime = plugin.approximateQueryTime;

    while (true)
    {
        response = id in plugin.bucket;

        if (!response || (*response == QueryResponse.init))
        {
            immutable nowInUnix = Clock.currTime.toUnixTime();

            if ((nowInUnix - startTimeInUnix) >= Timeout.httpGET)
            {
                response = new shared QueryResponse;
                return *response;
            }

            version(BenchmarkHTTPRequests)
            {
                ++misses;
                immutable oldAccumulatingTime = accumulatingTime;
            }

            // Miss; fired too early, there is no response available yet
            alias QC = TwitchPlugin.QueryConstants;
            accumulatingTime *= QC.growthMultiplier;
            immutable briefWait = cast(long)(accumulatingTime / QC.retryTimeDivisor);

            version(BenchmarkHTTPRequests)
            {
                enum pattern = "MISS %d! elapsed: %s | old: %d --> new: %d | wait: %d";
                immutable delta = (nowInUnix - startTimeInUnix);
                writefln(
                    pattern,
                    misses,
                    delta,
                    cast(long)oldAccumulatingTime,
                    cast(long)accumulatingTime,
                    cast(long)briefWait);
            }

            delay(plugin, briefWait.msecs, Yes.yield);
            continue;
        }

        version(BenchmarkHTTPRequests)
        {
            enum pattern = "HIT! elapsed: %s | response: %s | misses: %d";
            immutable nowInUnix = Clock.currTime.toUnixTime();
            immutable delta = (nowInUnix - startTimeInUnix);
            writefln(pattern, delta, response.msecs, misses);
        }

        // Make the new approximate query time a weighted average
        averageApproximateQueryTime(plugin, response.msecs);
        plugin.bucket.remove(id);
        return *response;
    }
}


// getTwitchUser
/++
    Fetches information about a Twitch user and returns it in the form of a
    Voldemort struct with nickname, display name and account ID (as string) members.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        givenName = Name of user to look up.
        givenIDString = ID of user to look up, if no `givenName` given.
        searchByDisplayName = Whether or not to also attempt to look up `givenName`
            as a display name.

    Returns:
        Voldemort aggregate struct with `nickname`, `displayName` and `idString` members.
 +/
auto getTwitchUser(
    TwitchPlugin plugin,
    const string givenName,
    const string givenIDString,
    const Flag!"searchByDisplayName" searchByDisplayName = No.searchByDisplayName)
in (Fiber.getThis, "Tried to call `getTwitchUser` from outside a Fiber")
in ((givenName.length || givenIDString.length),
    "Tried to get Twitch user without supplying a name nor an ID")
{
    import std.conv : to;
    import std.json : JSONType;

    static struct User
    {
        string idString;
        string nickname;
        string displayName;
    }

    User user;

    if (const stored = givenName in plugin.state.users)
    {
        // Stored user
        user.idString = stored.id.to!string;
        user.nickname = stored.nickname;
        user.displayName = stored.displayName;
        return user;
    }

    // No such luck
    if (searchByDisplayName)
    {
        foreach (const stored; plugin.state.users)
        {
            if (stored.displayName == givenName)
            {
                // Found user by displayName
                user.idString = stored.id.to!string;
                user.nickname = stored.nickname;
                user.displayName = stored.displayName;
                return user;
            }
        }
    }

    // None on record, look up
    immutable userURL = givenName ?
        "https://api.twitch.tv/helix/users?login=" ~ givenName :
        "https://api.twitch.tv/helix/users?id=" ~ givenIDString;

    auto getTwitchUserDg()
    {
        immutable userJSON = getTwitchData(plugin, userURL);

        if ((userJSON.type != JSONType.object) || ("id" !in userJSON))
        {
            // No such user
            return user; //User.init;
        }

        user.idString = userJSON["id"].str;
        user.nickname = userJSON["login"].str;
        user.displayName = userJSON["display_name"].str;
        return user;
    }

    return retryDelegate(plugin, &getTwitchUserDg);
}


// getTwitchGame
/++
    Fetches information about a game; its numerical ID and full name.

    If `id` is passed, then it takes priority over `name`.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        name = Name of game to look up.
        id = ID of game to look up.

    Returns:
        Voldemort aggregate struct with `id` and `name` members.
 +/
auto getTwitchGame(TwitchPlugin plugin, const string name, const string id)
in (Fiber.getThis, "Tried to call `getTwitchGame` from outside a Fiber")
in ((name.length || id.length), "Tried to call `getTwitchGame` with no game name nor game ID")
{
    static struct Game
    {
        string id;
        string name;
    }

    immutable gameURL = id.length ?
        "https://api.twitch.tv/helix/games?id=" ~ id :
        "https://api.twitch.tv/helix/games?name=" ~ name;

    auto getTwitchGameDg()
    {
        immutable gameJSON = getTwitchData(plugin, gameURL);

        /*
        {
            "id": "512953",
            "name": "Elden Ring",
            "box_art_url": "https://static-cdn.jtvnw.net/ttv-boxart/512953_IGDB-{width}x{height}.jpg"
        }
        */

        return Game(gameJSON["id"].str, gameJSON["name"].str);
    }

    return retryDelegate(plugin, &getTwitchGameDg);
}


// getUniqueNumericalID
/++
    Generates a unique numerical ID for use as key in the passed associative array bucket.

    Params:
        bucket = Shared associative array of responses from async HTTP queries.

    Returns:
        A unique integer for use as bucket key.
 +/
auto getUniqueNumericalID(shared QueryResponse[int] bucket)
{
    import std.random : uniform;

    int id = uniform(0, int.max);

    synchronized //()
    {
        while (id in bucket)
        {
            id = uniform(0, int.max);
        }

        bucket[id] = QueryResponse.init;  // reserve it
    }

    return id;
}


// modifyChannel
/++
    Modifies a channel's title or currently played game.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        channelName = Name of channel to modify.
        title = Optional channel title to set.
        gameID = Optional game ID to set the channel as playing.
        caller = Name of the calling function.
 +/
void modifyChannel(
    TwitchPlugin plugin,
    const string channelName,
    const string title,
    const string gameID,
    const string caller = __FUNCTION__)
in (Fiber.getThis, "Tried to call `modifyChannel` from outside a Fiber")
in (channelName.length, "Tried to modify a channel with an empty channel name string")
in ((title.length || gameID.length), "Tried to modify a channel with no title nor game ID supplied")
{
    import std.array : Appender;

    const room = channelName in plugin.rooms;
    assert(room, "Tried to modify a channel for which there existed no room");

    immutable authorizationBearer = getBroadcasterAuthorisation(plugin, channelName);
    immutable url = "https://api.twitch.tv/helix/channels?broadcaster_id=" ~ room.id;

    Appender!(char[]) sink;
    sink.reserve(128);

    sink.put('{');

    if (title.length)
    {
        sink.put(`"title":"`);
        sink.put(title);
        sink.put('"');
        if (gameID.length) sink.put(',');
    }

    if (gameID.length)
    {
        sink.put(`"game_id":"`);
        sink.put(gameID);
        sink.put('"');
    }

    sink.put('}');

    void modifyChannelDg()
    {
        cast(void)sendHTTPRequest(
            plugin,
            url,
            caller,
            authorizationBearer,
            HttpVerb.PATCH,
            cast(ubyte[])sink.data,
            "application/json");
    }

    return retryDelegate(plugin, &modifyChannelDg);
}


// getChannel
/++
    Fetches information about a channel; its title, what game is being played,
    the channel tags, etc.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        channelName = Name of channel to fetch information about.
 +/
auto getChannel(
    TwitchPlugin plugin,
    const string channelName)
in (Fiber.getThis, "Tried to call `getChannel` from outside a Fiber")
in (channelName.length, "Tried to fetch a channel with an empty channel name string")
{
    import std.algorithm.iteration : map;
    import std.array : array;
    import std.json : parseJSON;

    const room = channelName in plugin.rooms;
    assert(room, "Tried to look up a channel for which there existed no room");

    immutable url = "https://api.twitch.tv/helix/channels?broadcaster_id=" ~ room.id;

    static struct Channel
    {
        string gameIDString;
        string gameName;
        string[] tags;
        string title;
    }

    auto getChannelDg()
    {
        immutable gameDataJSON = getTwitchData(plugin, url);

        /+
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
         +/

        Channel channel;
        channel.gameIDString = gameDataJSON["game_id"].str;
        channel.gameName = gameDataJSON["game_name"].str;
        channel.tags = gameDataJSON["tags"].array
            .map!(tagJSON => tagJSON.str)
            .array;
        channel.title = gameDataJSON["title"].str;
        return channel;
    }

    return retryDelegate(plugin, &getChannelDg);
}


// getBroadcasterAuthorisation
/++
    Returns a broadcaster-level "Bearer" authorisation token for a channel,
    where such exist.

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        channelName = Name of channel to return token for.

    Returns:
        A "Bearer" OAuth token string for use in HTTP headers.

    Throws:
        [MissingBroadcasterTokenException] if there were no broadcaster API token
        for the supplied channel in the secrets storage.
 +/
auto getBroadcasterAuthorisation(TwitchPlugin plugin, const string channelName)
in (channelName.length, "Tried to get broadcaster authorisation with an empty channel name string")
{
    static string[string] authorizationByChannel;

    auto authorizationBearer = channelName in authorizationByChannel;

    if (!authorizationBearer)
    {
        if (const creds = channelName in plugin.secretsByChannel)
        {
            if (creds.broadcasterKey.length)
            {
                authorizationByChannel[channelName] = "Bearer " ~ creds.broadcasterKey;
                authorizationBearer = channelName in authorizationByChannel;
            }
        }
    }

    if (!authorizationBearer)
    {
        enum message = "Missing broadcaster key";
        throw new MissingBroadcasterTokenException(
            message,
            channelName,
            __FILE__);
    }

    return *authorizationBearer;
}


// startCommercial
/++
    Starts a commercial in the specified channel.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        channelName = Name of channel to run commercials for.
        lengthString = Length to play the commercial for, as a string.
        caller = Name of the calling function.
 +/
void startCommercial(
    TwitchPlugin plugin,
    const string channelName,
    const string lengthString,
    const string caller = __FUNCTION__)
in (Fiber.getThis, "Tried to call `startCommercial` from outside a Fiber")
in (channelName.length, "Tried to start a commercial with an empty channel name string")
{
    import std.format : format;

    const room = channelName in plugin.rooms;
    assert(room, "Tried to look up start commercial in a channel for which there existed no room");

    enum url = "https://api.twitch.tv/helix/channels/commercial";
    enum pattern = `
{
    "broadcaster_id": "%s",
    "length": %s
}`;

    immutable body_ = pattern.format(room.id, lengthString);
    immutable authorizationBearer = getBroadcasterAuthorisation(plugin, channelName);

    void startCommercialDg()
    {
        cast(void)sendHTTPRequest(
            plugin,
            url,
            caller,
            authorizationBearer,
            HttpVerb.POST,
            cast(ubyte[])body_,
            "application/json");
    }

    return retryDelegate(plugin, &startCommercialDg);
}


// getPolls
/++
    Fetches information about polls in the specified channel. If an ID string is
    supplied, it will be included in the query, otherwise all `"ACTIVE"` polls
    are included in the returned JSON.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        channelName = Name of channel to fetch polls for.
        idString = ID of a specific poll to get.
        caller = Name of the calling function.

    Returns:
        An arary of [std.json.JSONValue|JSONValue]s with all the matched polls.
 +/
auto getPolls(
    TwitchPlugin plugin,
    const string channelName,
    const string idString = string.init,
    const string caller = __FUNCTION__)
in (Fiber.getThis, "Tried to call `getPolls` from outside a Fiber")
in (channelName.length, "Tried to get polls with an empty channel name string")
{
    import std.conv : text;
    import std.json : JSONType, JSONValue, parseJSON;

    const room = channelName in plugin.rooms;
    assert(room, "Tried to get polls of a channel for which there existed no room");

    enum baseURL = "https://api.twitch.tv/helix/polls?broadcaster_id=";
    string url = baseURL ~ room.id;  // mutable;
    if (idString.length) url ~= "&id=" ~ idString;

    immutable authorizationBearer = getBroadcasterAuthorisation(plugin, channelName);

    auto getPollsDg()
    {
        JSONValue allPollsJSON;
        allPollsJSON = null;
        allPollsJSON.array = null;

        string after;
        uint retry;

        inner:
        do
        {
            immutable paginatedURL = after.length ?
                text(url, "&after=", after) :
                url;
            immutable response = sendHTTPRequest(
                plugin,
                paginatedURL,
                caller,
                authorizationBearer,
                HttpVerb.GET,
                cast(ubyte[])null,
                "application/json");
            immutable responseJSON = parseJSON(response.str);

            if ((responseJSON.type != JSONType.object) || ("data" !in responseJSON))
            {
                // Invalid response in some way
                if (++retry < TwitchPlugin.delegateRetries) continue inner;
                enum message = "`getPolls` response has unexpected JSON";
                throw new UnexpectedJSONException(message, responseJSON);
            }

            retry = 0;

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

            foreach (const pollJSON; responseJSON["data"].array)
            {
                if (pollJSON["status"].str != "ACTIVE") continue;
                allPollsJSON.array ~= pollJSON;
            }

            after = responseJSON["after"].str;
        }
        while (after.length);

        return allPollsJSON.array;
    }

    return retryDelegate(plugin, &getPollsDg);
}


// createPoll
/++
    Creates a Twitch poll in the specified channel.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        channelName = Name of channel to create the poll in.
        title = Poll title.
        durationString = How long the poll should run for in seconds (as a string).
        choices = A string array of poll choices.
        caller = Name of the calling function.

    Returns:
        An array of [std.json.JSONValue|JSONValue]s with
        the response returned when creating the poll. On failure, an empty
        [std.json.JSONValue|JSONValue] is instead returned.

    Throws:
        [UnexpectedJSONException] on unexpected JSON.
 +/
auto createPoll(
    TwitchPlugin plugin,
    const string channelName,
    const string title,
    const string durationString,
    const string[] choices,
    const string caller = __FUNCTION__)
in (Fiber.getThis, "Tried to call `createPoll` from outside a Fiber")
in (channelName.length, "Tried to create a poll with an empty channel name string")
{
    import std.array : Appender, replace;
    import std.format : format;
    import std.json : JSONType, parseJSON;

    const room = channelName in plugin.rooms;
    assert(room, "Tried to create a poll in a channel for which there existed no room");

    enum url = "https://api.twitch.tv/helix/polls";
    enum pattern = `
{
    "broadcaster_id": "%s",
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
    immutable body_ = pattern.format(room.id, escapedTitle, sink.data, durationString);
    immutable authorizationBearer = getBroadcasterAuthorisation(plugin, channelName);

    auto createPollDg()
    {
        immutable response = sendHTTPRequest(
            plugin,
            url,
            caller,
            authorizationBearer,
            HttpVerb.POST,
            cast(ubyte[])body_,
            "application/json");
        immutable responseJSON = parseJSON(response.str);

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
                "status": "ACTIVE",
                "duration": 1800,
                "started_at": "2021-03-19T06:08:33.871278372Z"
                }
            ]
        }
        */

        if ((responseJSON.type != JSONType.object) || ("data" !in responseJSON))
        {
            // Invalid response in some way
            enum message = "`createPoll` response has unexpected JSON";
            throw new UnexpectedJSONException(message, responseJSON);
        }

        return responseJSON["data"].array;
    }

    return retryDelegate(plugin, &createPollDg);
}


// endPoll
/++
    Ends a Twitch poll, putting it in either a `"TERMINATED"` or `"ARCHIVED"` state.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        channelName = Name of channel whose poll to end.
        voteID = ID of the specific vote to end.
        terminate = If set, ends the poll by putting it in a `"TERMINATED"` state.
            If unset, ends it in an `"ARCHIVED"` way.
        caller = Name of the calling function.

    Returns:
        The [std.json.JSONValue|JSONValue] of the first response returned when ending the poll.

    Throws:
        [UnexpectedJSONException] on unexpected JSON.
 +/
auto endPoll(
    TwitchPlugin plugin,
    const string channelName,
    const string voteID,
    const Flag!"terminate" terminate,
    const string caller = __FUNCTION__)
in (Fiber.getThis, "Tried to call `endPoll` from outside a Fiber")
in (channelName.length, "Tried to end a poll with an empty channel name string")
{
    import std.format : format;
    import std.json : JSONType, parseJSON;

    const room = channelName in plugin.rooms;
    assert(room, "Tried to end a poll in a channel for which there existed no room");

    enum url = "https://api.twitch.tv/helix/polls";
    enum pattern = `
{
    "broadcaster_id": "%s",
    "id": "%s",
    "status": "%s"
}`;

    immutable status = terminate ? "TERMINATED" : "ARCHIVED";
    immutable body_ = pattern.format(room.id, voteID, status);
    immutable authorizationBearer = getBroadcasterAuthorisation(plugin, channelName);

    auto endPollDg()
    {
        immutable response = sendHTTPRequest(
            plugin,
            url,
            caller,
            authorizationBearer,
            HttpVerb.PATCH,
            cast(ubyte[])body_,
            "application/json");
        immutable responseJSON = parseJSON(response.str);

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

        if ((responseJSON.type != JSONType.object) || ("data" !in responseJSON))
        {
            // Invalid response in some way
            enum message = "`endPoll` response has unexpected JSON";
            throw new UnexpectedJSONException(message, responseJSON);
        }

        return responseJSON["data"].array[0];
    }

    return retryDelegate(plugin, &endPollDg);
}


// getBotList
/++
    Fetches a list of known (online) bots from TwitchInsights.net.

    With this we don't have to keep a static list of known bots to exclude when
    counting chatters.

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        caller = String name of calling function.

    Returns:
        A `string[]` array of online bot account names.

    Throws:
        [TwitchQueryException] on unexpected JSON.

    See_Also:
        https://twitchinsights.net/bots
 +/
auto getBotList(TwitchPlugin plugin, const string caller = __FUNCTION__)
{
    import std.algorithm.searching : endsWith;
    import std.array : Appender;
    import std.json : JSONType, parseJSON;

    auto getBotListDg()
    {
        enum url = "https://api.twitchinsights.net/v1/bots/online";
        immutable response = sendHTTPRequest(plugin, url, caller);
        immutable responseJSON = parseJSON(response.str);

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

        if ((responseJSON.type != JSONType.object) || ("bots" !in responseJSON))
        {
            // Invalid response in some way, retry until we reach the limit
            enum message = "`getBotList` response has unexpected JSON";
            throw new UnexpectedJSONException(message, responseJSON);
        }

        Appender!(string[]) sink;
        sink.reserve(responseJSON["_total"].integer);

        foreach (const botEntryJSON; responseJSON["bots"].array)
        {
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

        return sink.data;
    }

    return retryDelegate(plugin, &getBotListDg);
}


// getStream
/++
    Fetches information about an ongoing stream.

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        loginName = Account name of user whose stream to fetch information of.

    Returns:
        A [kameloso.plugins.twitch.base.TwitchPlugin.Room.Stream|Room.Stream]
        populated with all (relevant) information.
 +/
auto getStream(TwitchPlugin plugin, const string loginName)
in (loginName.length, "Tried to get a stream with an empty login name string")
{
    import std.algorithm.iteration : map;
    import std.array : array;
    import std.datetime.systime : SysTime;

    immutable streamURL = "https://api.twitch.tv/helix/streams?user_login=" ~ loginName;

    auto getStreamDg()
    {
        try
        {
            immutable streamJSON = getTwitchData(plugin, streamURL);

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

            auto stream = TwitchPlugin.Room.Stream(streamJSON["id"].str);
            stream.live = true;
            stream.userIDString = streamJSON["user_id"].str;
            stream.userLogin = streamJSON["user_login"].str;
            stream.userDisplayName = streamJSON["user_name"].str;
            stream.gameIDString = streamJSON["game_id"].str;
            stream.gameName = streamJSON["game_name"].str;
            stream.title = streamJSON["title"].str;
            stream.startTime = SysTime.fromISOExtString(streamJSON["started_at"].str);
            stream.numViewers = streamJSON["viewer_count"].integer;
            stream.tags = streamJSON["tags"].array
                .map!(tag => tag.str)
                .array;
            return stream;
        }
        catch (EmptyDataJSONException _)
        {
            // Stream is down
            return TwitchPlugin.Room.Stream.init;
        }
        catch (Exception e)
        {
            throw e;
        }
    }

    return retryDelegate(plugin, &getStreamDg);
}


// getBTTVEmotes
/++
    Fetches BetterTTV emotes for a given channel.

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        emoteMap = Reference to the `bool[dstring]` associative array to store
            the fetched emotes in.
        idString = Twitch user/channel ID in string form.
        caller = Name of the calling function.

    See_Also:
        https://betterttv.com
 +/
void getBTTVEmotes(
    TwitchPlugin plugin,
    ref bool[dstring] emoteMap,
    const string idString,
    const string caller = __FUNCTION__)
in (Fiber.getThis, "Tried to call `getBTTVEmotes` from outside a Fiber")
in (idString.length, "Tried to get BTTV emotes with an empty ID string")
{
    import std.conv : to;
    import std.json : JSONType, parseJSON;

    immutable url = "https://api.betterttv.net/3/cached/users/twitch/" ~ idString;

    void getBTTVEmotesDg()
    {
        try
        {
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
                    "(response is wrong type)";
                throw new UnexpectedJSONException(message, responseJSON);
            }

            immutable channelEmotesJSON = "channelEmotes" in responseJSON;
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

    return retryDelegate(plugin, &getBTTVEmotesDg);
}


// getBTTVGlobalEmotes
/++
    Fetches globalBetterTTV emotes.

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        emoteMap = Reference to the `bool[dstring]` associative array to store
            the fetched emotes in.
        caller = Name of the calling function.

    See_Also:
        https://betterttv.com/emotes/global
 +/
void getBTTVGlobalEmotes(
    TwitchPlugin plugin,
    ref bool[dstring] emoteMap,
    const string caller = __FUNCTION__)
in (Fiber.getThis, "Tried to call `getBTTVGlobalEmotes` from outside a Fiber")
{
    import std.conv : to;
    import std.json : parseJSON;

    void getBTTVGlobalEmotesDg()
    {
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

        foreach (immutable emoteJSON; responseJSON.array)
        {
            immutable emote = emoteJSON["code"].str.to!dstring;
            emoteMap[emote] = true;
        }

        // All done
    }

    return retryDelegate(plugin, &getBTTVGlobalEmotesDg);
}


// getFFZEmotes
/++
    Fetches FrankerFaceZ emotes for a given channel.

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        emoteMap = Reference to the `bool[dstring]` associative array to store
            the fetched emotes in.
        idString = Twitch user/channel ID in string form.
        caller = Name of the calling function.

    See_Also:
        https://www.frankerfacez.com
 +/
void getFFZEmotes(
    TwitchPlugin plugin,
    ref bool[dstring] emoteMap,
    const string idString,
    const string caller = __FUNCTION__)
in (Fiber.getThis, "Tried to call `getFFZEmotes` from outside a Fiber")
in (idString.length, "Tried to get FFZ emotes with an empty ID string")
{
    import std.conv : to;
    import std.json : JSONType, parseJSON;

    immutable url = "https://api.frankerfacez.com/v1/room/id/" ~ idString;

    void getFFZEmotesDg()
    {
        try
        {
            immutable response = sendHTTPRequest(plugin, url, caller);
            immutable responseJSON = parseJSON(response.str);

            /+
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
             +/

            if (responseJSON.type == JSONType.object)
            {
                if (immutable setsJSON = "sets" in responseJSON)
                {
                    foreach (immutable setJSON; (*setsJSON).object)
                    {
                        if (immutable emoticonsArrayJSON = "emoticons" in setJSON)
                        {
                            foreach (immutable emoteJSON; emoticonsArrayJSON.array)
                            {
                                immutable emote = emoteJSON["name"].str.to!dstring;
                                emoteMap[emote] = true;
                            }

                            // All done
                            return;
                        }
                    }
                }
            }

            // Invalid response in some way
            enum message = "`getFFZEmotes` response has unexpected JSON";
            throw new UnexpectedJSONException(message, responseJSON);
        }
        catch (ErrorJSONException e)
        {
            // Likely 404
            const messageJSON = "message" in e.json;

            if (messageJSON && (messageJSON.str == "No such room"))
            {
                // Benign
                return;
            }
            throw e;
        }
        catch (Exception e)
        {
            throw e;
        }
    }

    return retryDelegate(plugin, &getFFZEmotesDg);
}


// get7tvEmotes
/++
    Fetches 7tv emotes for a given channel.

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        emoteMap = Reference to the `bool[dstring]` associative array to store
            the fetched emotes in.
        idString = Twitch user/channel ID in string form.
        caller = Name of the calling function.

    See_Also:
        https://7tv.app
 +/
void get7tvEmotes(
    TwitchPlugin plugin,
    ref bool[dstring] emoteMap,
    const string idString,
    const string caller = __FUNCTION__)
in (Fiber.getThis, "Tried to call `get7tvEmotes` from outside a Fiber")
in (idString.length, "Tried to get 7tv emotes with an empty ID string")
{
    import std.conv : text, to;
    import std.json : JSONType, parseJSON;

    immutable url = text("https://api.7tv.app/v2/users/", idString, "/emotes");

    void get7tvEmotesDg()
    {
        try
        {
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

            if (responseJSON.type == JSONType.array)
            {
                foreach (immutable emoteJSON; responseJSON.array)
                {
                    immutable emote = emoteJSON["name"].str.to!dstring;
                    emoteMap[emote] = true;
                }

                // All done
                return;
            }

            // Invalid response in some way
            enum message = "`get7tvEmotes` response has unexpected JSON " ~
                "(response is not object nor array)";
            throw new UnexpectedJSONException(message, responseJSON);
        }
        catch (ErrorJSONException e)
        {
            if (const errorJSON = "error" in e.json)
            {
                if ((errorJSON.str == "No Items Found") ||
                    (errorJSON.str == "Unknown Emote Set"))
                {
                    // Benign
                    return;
                }
            }
            throw e;
        }
        catch (Exception e)
        {
            throw e;
        }
    }

    return retryDelegate(plugin, &get7tvEmotesDg);
}


// get7tvGlobalEmotes
/++
    Fetches 7tv emotes.

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        emoteMap = Reference to the `bool[dstring]` associative array to store
            the fetched emotes in.
        caller = Name of the calling function.

    See_Also:
        https://7tv.app
 +/
void get7tvGlobalEmotes(
    TwitchPlugin plugin,
    ref bool[dstring] emoteMap,
    const string caller = __FUNCTION__)
in (Fiber.getThis, "Tried to call `get7tvGlobalEmotes` from outside a Fiber")
{
    import std.conv : to;
    import std.json : parseJSON;

    void get7tvGlobalEmotesDg()
    {
        enum url = "https://api.7tv.app/v2/emotes/global";

        immutable response = sendHTTPRequest(plugin, url, caller);
        immutable responseJSON = parseJSON(response.str);

        /+
        [
            {
                "height": [],
                "id": "60421fe677137b000de9e683",
                "mime": "image\/webp",
                "name": "reckH",
                "owner": {},
                "status": 3,
                "tags": [],
                "urls": [],
                "visibility": 2,
                "visibility_simple": [],
                "width": []
            },
            [...]
        ]
         +/

        foreach (const emoteJSON; responseJSON.array)
        {
            immutable emote = emoteJSON["name"].str.to!dstring;
            emoteMap[emote] = true;
        }

        // All done
    }

    return retryDelegate(plugin, &get7tvGlobalEmotesDg);
}


// getSubscribers
/++
    Fetches a list of all subscribers of the specified channel. A broadcaster-level
    access token is required.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        channelName = Name of channel to fetch subscribers of.
        caller = Name of the calling function.

    Returns:
        An array of Voldemort subscribers.
 +/
version(none)
auto getSubscribers(
    TwitchPlugin plugin,
    const string channelName,
    const string caller = __FUNCTION__)
in (Fiber.getThis, "Tried to call `getSubscribers` from outside a Fiber")
in (channelName.length, "Tried to get subscribers with an empty channel name string")
{
    import std.array : Appender;
    import std.format : format;
    import std.json : JSONType, parseJSON;

    const room = channelName in plugin.rooms;
    assert(room, "Tried to get subscribers of a channel for which there existed no room");

    immutable authorizationBearer = getBroadcasterAuthorisation(plugin, channelName);

    auto getSubscribersDg()
    {
        static struct User
        {
            string id;
            string name;
            string displayName;
        }

        static struct Subscription
        {
            User user;
            User gifter;
            bool wasGift;
        }

        enum url = "https://api.twitch.tv/helix/subscribers";
        enum initialPattern = `
{
    "broadcaster_id": "%s",
    "first": "100"
}`;

    enum subsequentPattern = `
{
    "broadcaster_id": "%s",
    "after": "%s",
}`;

        Appender!(Subscription[]) subs;
        string after;
        uint retry;

        inner:
        do
        {
            immutable body_ = after.length ?
                subsequentPattern.format(room.id, after) :
                initialPattern.format(room.id);
            immutable response = sendHTTPRequest(
                plugin,
                url,
                caller,
                authorizationBearer,
                HttpVerb.GET,
                cast(ubyte[])body_,
                "application/json");
            immutable responseJSON = parseJSON(response.str);

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

            if ((responseJSON.type != JSONType.object) || ("data" !in responseJSON))
            {
                // Invalid response in some way
                if (++retry < TwitchPlugin.delegateRetries) continue inner;
                enum message = "`getSubscribers` response has unexpected JSON";
                throw new UnexpectedJSONException(message, responseJSON);
            }

            retry = 0;

            if (!subs.capacity)
            {
                subs.reserve(responseJSON["total"].integer);
            }

            foreach (immutable subJSON; responseJSON["data"].array)
            {
                Subscription sub;
                sub.user.id = subJSON["user_id"].str;
                sub.user.name = subJSON["user_login"].str;
                sub.user.displayName = subJSON["user_name"].str;
                sub.wasGift = subJSON["is_gift"].boolean;
                sub.gifter.id = subJSON["gifter_id"].str;
                sub.gifter.name = subJSON["gifter_login"].str;
                sub.gifter.displayName = subJSON["gifter_name"].str;
                subs.put(sub);
            }

            immutable paginationJSON = "pagination" in responseJSON;
            if (!paginationJSON) break;

            immutable cursorJSON = "cursor" in *paginationJSON;
            if (!cursorJSON) break;

            after = cursorJSON.str;
        }
        while (after.length);

        return subs;
    }

    return retryDelegate(plugin, &getSubscribersDg);
}


// createShoutout
/++
    Prepares a `Shoutout` Voldemort struct with information needed to compose a shoutout.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        login = Login name of other streamer to prepare a shoutout for.

    Returns:
        Voldemort `Shoutout` struct.
 +/
auto createShoutout(
    TwitchPlugin plugin,
    const string login)
in (Fiber.getThis, "Tried to call `createShoutout` from outside a Fiber")
in (login.length, "Tried to create a shoutout with an empty login name string")
{
    import std.json : JSONType;

    static struct Shoutout
    {
        enum State
        {
            success,
            noSuchUser,
            noChannel,
            otherError,
        }

        State state;
        string displayName;
        string gameName;
    }

    auto shoutoutDg()
    {
        Shoutout shoutout;

        try
        {
            immutable userURL = "https://api.twitch.tv/helix/users?login=" ~ login;
            immutable userJSON = getTwitchData(plugin, userURL);
            immutable id = userJSON["id"].str;
            //immutable login = userJSON["login"].str;
            immutable channelURL = "https://api.twitch.tv/helix/channels?broadcaster_id=" ~ id;
            immutable channelJSON = getTwitchData(plugin, channelURL);

            shoutout.state = Shoutout.State.success;
            shoutout.displayName = channelJSON["broadcaster_name"].str;
            shoutout.gameName = channelJSON["game_name"].str;
            return shoutout;
        }
        catch (ErrorJSONException e)
        {
            if ((e.json["status"].integer = 400) &&
                (e.json["error"].str == "Bad Request") &&
                (e.json["message"].str == "Invalid username(s), email(s), or ID(s). Bad Identifiers."))
            {
                shoutout.state = Shoutout.State.noSuchUser;
                return shoutout;
            }

            shoutout.state = Shoutout.State.otherError;
            return shoutout;
        }
        catch (EmptyDataJSONException _)
        {
            shoutout.state = Shoutout.State.noSuchUser;
            return shoutout;
        }
        catch (Exception e)
        {
            throw e;
        }
    }

    return retryDelegate(plugin, &shoutoutDg);
}
