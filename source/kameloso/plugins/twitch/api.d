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

import kameloso.plugins.twitch;
import kameloso.plugins.twitch.common;
import kameloso.tables : HTTPVerb;
import dialect.defs;
import lu.container : MutexedAA;
import core.thread.fiber : Fiber;
import core.time : Duration, seconds;

package:


// QueryResponse
/++
    Embodies a response from a query to the Twitch servers. A string paired with
    a millisecond count of how long the query took, and some metadata about the request.
 +/
struct QueryResponse
{
    /++
        The URL that was queried.
     +/
    string url;

    /++
        The host that was queried.
     +/
    string host;

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

    /++
        The message text of any exception thrown while querying.
     +/
    string exceptionText;
}


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
        [MissingBroadcasterTokenException] if the delegate throws it.
        [InvalidCredentialsException] likewise.
        [EmptyDataJSONException] also.
        [ErrorJSONException] if the delegate throws it and the JSON embedded
            contains an error code in the 400-499 range.
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
    else if (auto e = cast(TwitchQueryException)base)
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
    spawn(&persistentQuerier, plugin.responseBucket, caBundleFile);
    ---

    Params:
        responseBucket = The associative array to put the results in,
            response values keyed by a unique numerical ID.
        caBundleFile = Path to a `cacert.pem` SSL certificate bundle.
 +/
void persistentQuerier(
    MutexedAA!(QueryResponse[int]) responseBucket,
    const string caBundleFile)
{
    import kameloso.thread : ThreadMessage;

    version(Posix)
    {
        import kameloso.thread : setThreadName;
        setThreadName("twitchworker");
    }

    void onHTTPRequest(
        int id,
        string url,
        string authToken,
        HTTPVerb verb,
        immutable(ubyte)[] body_,
        string contentType)
    {
        scope(failure) responseBucket.remove(id);

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

        if (response != QueryResponse.init)
        {
            responseBucket[id] = response;
        }
        else
        {
            responseBucket.remove(id);
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

    bool halt;

    void onQuitMessage(bool)
    {
        halt = true;
    }

    // This avoids the GC allocating a closure, which is fine in this case, but do this anyway
    scope onHTTPRequestDg = &onHTTPRequest;
    scope onQuitMessageDg = &onQuitMessage;

    while (!halt)
    {
        import std.concurrency : receive;
        import std.variant : Variant;

        try
        {
            receive(
                onHTTPRequestDg,
                onQuitMessageDg,
                (Variant v)
                {
                    import std.stdio : stdout, writeln;
                    writeln("Twitch worker received unknown Variant: ", v);
                    stdout.flush();
                }
            );
        }
        catch (Exception _)
        {
            // Probably a requests exception
            /*writeln("Twitch worker caught exception: ", e.msg);
            version(PrintStacktraces) writeln(e);
            stdout.flush();*/
        }
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
    immutable response = sendHTTPRequest(
        plugin,
        "https://id.twitch.tv/oauth2/validate",
        __FUNCTION__,
        "OAuth 30letteroauthstring");
    ---

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        url = The URL to query.
        caller = Name of the calling function.
        authorisationHeader = Authorisation HTTP header to pass.
        verb = What [kameloso.tables.HTTPVerb|HTTPVerb] to use in the request.
        body_ = Request body to send in case of verbs like `POST` and `PATCH`.
        contentType = "Content-Type" HTTP header to pass.
        id = Numerical ID to use instead of generating a new one.
        recursing = Whether or not this is a recursive call and another one should
            not be attempted.

    Returns:
        The [QueryResponse] that was discovered while monitoring the
        [kameloso.plugins.twitch.TwitchPlugin.responseBucket|TwitchPlugin.responseBucket]
        as having been received from the server.

    Throws:
        [EmptyResponseException] if the response body was empty.
        [ErrorJSONException] if the response body was JSON but contained an `"error"` key.
        [TwitchQueryException] if there were other unrecoverable errors.
 +/
QueryResponse sendHTTPRequest(
    TwitchPlugin plugin,
    const string url,
    const string caller = __FUNCTION__,
    const string authorisationHeader = string.init,
    /*const*/ HTTPVerb verb = HTTPVerb.get,
    /*const*/ ubyte[] body_ = null,
    const string contentType = string.init,
    int id = 0,
    const bool recursing = false)
in (Fiber.getThis(), "Tried to call `sendHTTPRequest` from outside a fiber")
in (url.length, "Tried to send an HTTP request without a URL")
{
    import kameloso.plugins.common.scheduling : delay;
    import kameloso.thread : ThreadMessage;
    import std.algorithm.searching : endsWith;
    import std.concurrency : send;
    import core.time : MonoTime, msecs;

    version(TraceHTTPRequests)
    {
        import kameloso.common : logger;
        import lu.conv : toString;

        enum tracePattern = "%s: <i>%s<t> (%s)";
        logger.tracef(
            tracePattern,
            verb.toString(),
            url,
            caller);
    }

    plugin.state.priorityMessages ~= ThreadMessage.shortenReceiveTimeout;

    immutable pre = MonoTime.currTime;
    if (!id) id = plugin.responseBucket.uniqueKey;

    plugin.getNextWorkerTid().send(
        id,
        url,
        authorisationHeader,
        verb,
        body_.idup,
        contentType);

    delay(plugin, plugin.transient.approximateQueryTime.msecs, yield: true);
    immutable response = waitForQueryResponse(plugin, id);

    if (response.exceptionText.length)
    {
        throw new TwitchQueryException(
            response.exceptionText,
            response.str,
            response.error,
            response.code);
    }

    if (response.host.endsWith(".twitch.tv"))
    {
        // Only update approximate query time for Twitch queries (skip those of custom emotes)
        immutable post = MonoTime.currTime;
        immutable diff = (post - pre);
        immutable msecs_ = diff.total!"msecs";
        averageApproximateQueryTime(plugin, msecs_);
    }

    if (response == QueryResponse.init)
    {
        throw new EmptyResponseException("No response");
    }
    else if (response.code < 200)
    {
        throw new TwitchQueryException(
            response.error,
            response.str,
            response.error,
            response.code);
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
            recursing: true);
    }
    else if (response.code >= 400)
    {
        import std.format : format;
        import std.json : JSONException;

        try
        {
            import lu.json : getOrFallback;
            import lu.string : unquoted;
            import std.json : JSONValue, parseJSON;
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
            {
                "error": "Unauthorized",
                "message": "Invalid OAuth token",
                "status": 401
            }
            {
                "error": "Unauthorized",
                "message": "Missing scope: moderator:manage:chat_messages",
                "status": 401
            }
             +/

            enum genericErrorString = "Error";
            enum genericErrorMessageString = "An unspecified error occurred";

            immutable json = parseJSON(response.str);
            uint code = response.code;
            string status;
            string message;

            if (immutable statusCodeJSON = "status_code" in json)
            {
                code = cast(uint)(*statusCodeJSON).integer;
                status = json.getOrFallback("status", genericErrorString);
                message = json.getOrFallback("error", genericErrorMessageString);
            }
            else if (immutable errorJSON = "error" in json)
            {
                status = genericErrorString;
                message = (*errorJSON).str;
            }
            else if (immutable statusJSON = "status" in json)
            {
                import std.json : JSONException;

                code = cast(uint)(*statusJSON).integer;
                status = json.getOrFallback("status", genericErrorString);
                message = json.getOrFallback("error", genericErrorMessageString);
            }
            else if (immutable messageJSON = "message" in json)
            {
                status = genericErrorString;
                message = (*messageJSON).str;
            }
            else
            {
                version(PrintStacktraces)
                {
                    if (!plugin.state.coreSettings.headless)
                    {
                        import std.stdio : stdout, writeln;
                        writeln(json.toPrettyString);
                        stdout.flush();
                    }
                }

                status = genericErrorString;
                message = genericErrorMessageString;
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

            version(PrintStacktraces)
            {
                if (!plugin.state.coreSettings.headless)
                {
                    import std.stdio : stdout, writeln;
                    writeln(response.str);
                    stdout.flush();
                }
            }

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
        verb = What [kameloso.tables.HTTPVerb|HTTPVerb] to use in the request.
        body_ = Request body to send in case of verbs like `POST` and `PATCH`.
        contentType = "Content-Type" HTTP header to use.

    Returns:
        A [QueryResponse] of the response from the server.
 +/
auto sendHTTPRequestImpl(
    const string url,
    const string authHeader,
    const string caBundleFile,
    /*const*/ HTTPVerb verb = HTTPVerb.get,
    /*const*/ ubyte[] body_ = null,
    /*const*/ string contentType = string.init)
{
    import kameloso.constants : KamelosoInfo, Timeout;
    import requests.base : Response;
    import requests.request : Request;
    import core.time : seconds;

    static string[string] headers;

    if (!headers.length)
    {
        headers =
        [
            "Client-ID" : TwitchPlugin.clientID,
            "User-Agent" : "kameloso/" ~ cast(string)KamelosoInfo.version_,
            "Authorization" : string.init,
        ];
    }

    if (!authHeader.length)
    {
        headers.remove("Authorization");
    }
    else if (auto authorizationHeader = "Authorization" in headers)
    {
        if (*authorizationHeader != authHeader) *authorizationHeader = authHeader;
    }
    else
    {
        headers["Authorization"] = authHeader;
    }

    auto req = Request();
    //req.verbosity = 1;
    req.keepAlive = true;
    req.timeout = Timeout.httpGET;
    req.addHeaders(headers);
    if (caBundleFile.length) req.sslSetCaCert(caBundleFile);

    Response res;
    QueryResponse response;
    response.url = url;

    try
    {
        with (HTTPVerb)
        final switch (verb)
        {
        case get:
            res = req.get(url);
            break;

        case post:
            res = req.post(url, body_, contentType);
            break;

        case put:
            res = req.put(url, body_, contentType);
            break;

        case patch:
            res = req.patch(url, body_, contentType);
            break;

        case delete_:
            res = req.execute("DELETE", url);
            break;

        case unset:
        case unsupported:
            assert(0, "Unset or unsupported HTTP verb passed to sendHTTPRequestImpl");
        }
    }
    catch (Exception e)
    {
        import kameloso.constants : MagicErrorStrings;

        response.exceptionText = (e.msg == MagicErrorStrings.sslContextCreationFailure) ?
            MagicErrorStrings.sslLibraryNotFoundRewritten :
            e.msg;
        return response;
    }

    response.code = res.code;
    response.host = res.uri.host;
    response.str = cast(string)res.responseBody;  //.idup?

    immutable stats = res.getStats();
    immutable totalMsecs = stats.connectTime + stats.recvTime + stats.sendTime;
    response.msecs = totalMsecs.total!"msecs";
    return response;
}


// getTwitchData
/++
    By following a passed URL, queries Twitch servers for an entity (user or channel).

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
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
in (Fiber.getThis(), "Tried to call `getTwitchData` from outside a fiber")
{
    import std.json : JSONException, JSONType, parseJSON;

    // Request here outside try-catch to let exceptions fall through
    immutable response = sendHTTPRequest(
        plugin,
        url,
        caller,
        plugin.transient.authorizationBearer);

    try
    {
        immutable responseJSON = parseJSON(response.str);

        if (responseJSON.type != JSONType.object)
        {
            enum message = "`getTwitchData` response has unexpected JSON " ~
                "(wrong JSON type)";
            throw new UnexpectedJSONException(message, responseJSON);
        }

        immutable dataJSON = "data" in responseJSON;

        if (!dataJSON)
        {
            enum message = "`getTwitchData` response has unexpected JSON " ~
                `(no "data" key)`;
            throw new UnexpectedJSONException(message, responseJSON);
        }

        if (dataJSON.array.length == 1)
        {
            return dataJSON.array[0];
        }
        else if (!dataJSON.array.length)
        {
            // data exists but is empty
            enum message = "`getTwitchData` response has unexpected JSON " ~
                `(zero-length "data")`;
            throw new EmptyDataJSONException(message, responseJSON);
        }
        else
        {
            enum message = "`getTwitchData` response has unexpected JSON " ~
                `("data" value is not a 1-length array)`;
            throw new UnexpectedJSONException(message, *dataJSON);
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
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
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
in (Fiber.getThis(), "Tried to call `getChatters` from outside a fiber")
in (broadcaster.length, "Tried to get chatters with an empty broadcaster string")
{
    import std.conv : text;
    import std.json : JSONType, parseJSON;

    immutable chattersURL = text("https://tmi.twitch.tv/group/user/", broadcaster, "/chatters");

    auto getChattersDg()
    {
        immutable response = sendHTTPRequest(
            plugin,
            chattersURL,
            caller,
            plugin.transient.authorizationBearer);
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
            enum message = "`getChatters` response has unexpected JSON " ~
                "(wrong JSON type)";
            throw new UnexpectedJSONException(message, responseJSON);
        }

        immutable chattersJSON = "chatters" in responseJSON;

        if (!chattersJSON)
        {
            // For some reason we received an object that didn't contain chatters
            enum message = "`getChatters` response has unexpected JSON " ~
                `(no "chatters" key)`;
            throw new UnexpectedJSONException(message, responseJSON);
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
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        authToken = Authorisation token to validate.
        async = Whether or not the validation should be done asynchronously, using fibers.
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
    const bool async,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `getValidation` from outside a fiber")
in (authToken.length, "Tried to validate an empty Twitch authorisation token")
{
    import std.algorithm.searching : startsWith;
    import std.json : JSONType, parseJSON;

    enum url = "https://id.twitch.tv/oauth2/validate";

    // Validation needs an "Authorization: OAuth xxx" header, as opposed to the
    // "Authorization: Bearer xxx" used everywhere else.
    authToken = authToken.startsWith("oauth:") ?
        authToken[6..$] :
        authToken;
    immutable authorizationHeader = "OAuth " ~ authToken;

    auto getValidationDg()
    {
        QueryResponse response;

        if (async)
        {
            try
            {
                response = sendHTTPRequest(
                    plugin,
                    url,
                    caller,
                    authorizationHeader);
            }
            catch (ErrorJSONException e)
            {
                if (const statusJSON = "status" in e.json)
                {
                    if (statusJSON.integer == 401)
                    {
                        switch (e.json["message"].str)
                        {
                        case "invalid access token":
                            enum message = "API token has expired";
                            throw new InvalidCredentialsException(message, e.json);

                        case "missing authorization token":
                            enum message = "Missing API token";
                            throw new InvalidCredentialsException(message, e.json);

                        default:
                            //drop down
                            break;
                        }
                    }
                }
                throw e;
            }
        }
        else
        {
            version(TraceHTTPRequests)
            {
                import kameloso.common : logger;
                enum tracePattern = "get: <i>%s<t> (%s)";
                logger.tracef(tracePattern, url, __FUNCTION__);
            }

            response = sendHTTPRequestImpl(
                url,
                authorizationHeader,
                plugin.state.connSettings.caBundleFile);

            // Copy/paste error handling...
            if (response.exceptionText.length)
            {
                throw new TwitchQueryException(
                    response.exceptionText,
                    response.str,
                    response.error,
                    response.code);
            }
            else if (response == QueryResponse.init)
            {
                throw new TwitchQueryException("No response");
            }
            else if (response.code < 10)
            {
                throw new TwitchQueryException(
                    response.error,
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

        if (validationJSON.type != JSONType.object)
        {
            enum message = "`getValidation` response has unexpected JSON " ~
                "(wrong JSON type)";
            throw new UnexpectedJSONException(message, validationJSON);
        }

        if ("client_id" !in validationJSON)
        {
            enum message = "`getValidation` response has unexpected JSON " ~
                `(no "client_id" key)`;
            throw new UnexpectedJSONException(message, validationJSON);
        }

        return validationJSON;
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

    Returns:
        An associative array of [std.json.JSONValue|JSONValue]s keyed by nickname string,
        containing followers.
 +/
auto getFollowers(TwitchPlugin plugin, const ulong id)
in (Fiber.getThis(), "Tried to call `getFollowers` from outside a fiber")
in (id, "Tried to get followers with an unset ID")
{
    import std.conv : to;

    immutable url = "https://api.twitch.tv/helix/channels/followers?first=100&broadcaster_id=" ~ id.to!string;

    auto getFollowersDg()
    {
        const entitiesArrayJSON = getMultipleTwitchData(plugin, url);
        Follower[string] allFollowers;

        /+
        {
            "user_id": "11111",
            "user_name": "UserDisplayName",
            "user_login": "userloginname",
            "followed_at": "2022-05-24T22:22:08Z",
        },
         +/

        foreach (entityJSON; entitiesArrayJSON)
        {
            immutable key = entityJSON["user_name"].str;
            allFollowers[key] = Follower.fromJSON(entityJSON);
        }

        return allFollowers;
    }

    return retryDelegate(plugin, &getFollowersDg);
}


// getMultipleTwitchData
/++
    By following a passed URL, queries Twitch servers for an array of entities
    (such as users or channels).

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        url = The URL to follow.
        caller = Name of the calling function.

    Returns:
        A [std.json.JSONValue|JSONValue] of type `array` containing all returned
        entities, over all paginated queries.

    Throws:
        [UnexpectedJSONException] on unexpected JSON received.
 +/
auto getMultipleTwitchData(
    TwitchPlugin plugin,
    const string url,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `getMultipleTwitchData` from outside a fiber")
{
    import std.conv : text;
    import std.json : JSONValue, parseJSON;

    JSONValue allEntitiesJSON;
    allEntitiesJSON = null;
    allEntitiesJSON.array = null;
    string after;
    uint retry;

    do
    {
        immutable paginatedURL = after.length ?
            text(url, "&after=", after) :
            url;
        immutable response = sendHTTPRequest(
            plugin,
            paginatedURL,
            caller,
            plugin.transient.authorizationBearer);
        immutable responseJSON = parseJSON(response.str);
        immutable dataJSON = "data" in responseJSON;

        if (!dataJSON)
        {
            // Invalid response in some way, retry until we reach the limit
            if (++retry < TwitchPlugin.delegateRetries) continue;
            enum message = "`getMultipleTwitchData` response has unexpected JSON " ~
                `(no "data" key)`;
            throw new UnexpectedJSONException(message, responseJSON);
        }

        retry = 0;

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
    [kameloso.plugins.twitch.TwitchPlugin.QueryConstants.averagingWeight|averagingWeight]
    and the new measurement a weight of 1. Additionally the measurement is padded by
    [kameloso.plugins.twitch.TwitchPlugin.QueryConstants.measurementPadding|measurementPadding]
    to be on the safe side.

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        responseMsecs = The new measurement of how many milliseconds the last
            query took to complete.
 +/
void averageApproximateQueryTime(TwitchPlugin plugin, const long responseMsecs)
{
    import std.algorithm.comparison : min;

    enum maxDeltaToResponse = 5000;

    immutable current = plugin.transient.approximateQueryTime;
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

    plugin.transient.approximateQueryTime = cast(long)average;
}


// waitForQueryResponse
/++
    Common code to wait for a query response.

    Merely spins and monitors the shared
    [kameloso.plugins.twitch.TwitchPlugin.responseBucket|TwitchPlugin.responseBucket]
    associative array for when a response has arrived, and then returns it.

    Times out after a hardcoded [kameloso.constants.Timeout.httpGET|Timeout.httpGET]
    if nothing was received.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Example:
    ---
    immutable id = plugin.responseBucket.uniqueKey;
    immutable url = "https://api.twitch.tv/helix/users?login=zorael";
    plugin.getNextWorkerTid().send(
        id,
        url,
        plugin.transient.authorizationBearer,
        HTTPVerb.get,
        cast(ubyte[])null,
        string.init);

    delay(plugin, plugin.transient.approximateQueryTime.msecs, yield: true);
    immutable response = waitForQueryResponse(plugin, id, url);
    // response.str is the response body
    assert(id !in plugin.responseBucket);
    ---

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        id = Numerical ID to use as key when storing the response in the bucket AA.

    Returns:
        A [QueryResponse] as constructed by other parts of the program.
 +/
auto waitForQueryResponse(TwitchPlugin plugin, const int id)
in (Fiber.getThis(), "Tried to call `waitForQueryResponse` from outside a fiber")
{
    import std.datetime.systime : Clock;

    version(BenchmarkHTTPRequests)
    {
        import std.stdio : writefln;
        uint misses;
    }

    immutable startTimeInUnix = Clock.currTime.toUnixTime();
    double accumulatingTime = plugin.transient.approximateQueryTime;

    while (true)
    {
        immutable hasResponse = plugin.responseBucket.has(id);

        if (!hasResponse)
        {
            // Querier errored or otherwise gave up
            // No need to remove the id, it's not there
            return QueryResponse.init;
        }

        //auto response = plugin.responseBucket[id];  // potential range error due to TOCTTOU
        immutable response = plugin.responseBucket.get(id, QueryResponse.init);

        if (response == QueryResponse.init)
        {
            import kameloso.plugins.common.scheduling : delay;
            import kameloso.constants : Timeout;
            import core.time : msecs;

            immutable nowInUnix = Clock.currTime.toUnixTime();

            if ((nowInUnix - startTimeInUnix) >= Timeout.Integers.httpGETSeconds)
            {
                plugin.responseBucket.remove(id);
                return QueryResponse.init;
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

            delay(plugin, briefWait.msecs, yield: true);
            continue;
        }
        else
        {
            version(BenchmarkHTTPRequests)
            {
                enum pattern = "HIT! elapsed: %s | response: %s | misses: %d";
                immutable nowInUnix = Clock.currTime.toUnixTime();
                immutable delta = (nowInUnix - startTimeInUnix);
                writefln(pattern, delta, response.msecs, misses);
            }

            plugin.responseBucket.remove(id);
            return response;
        }
    }
}


// getTwitchUser
/++
    Fetches information about a Twitch user and returns it in the form of a
    Voldemort struct with nickname, display name and account ID members.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        givenName = Optional name of user to look up, if no `id` given.
        id = Optional numeric ID of user to look up, if no `givenName` given.
        searchByDisplayName = Whether or not to also attempt to look up `givenName`
            as a display name.

    Returns:
        Voldemort aggregate struct with `nickname`, `displayName` and `id` members.
 +/
auto getTwitchUser(
    TwitchPlugin plugin,
    const string givenName = string.init,
    const ulong id = 0,
    const bool searchByDisplayName = false)
in (Fiber.getThis(), "Tried to call `getTwitchUser` from outside a fiber")
in ((givenName.length || id),
    "Tried to get Twitch user without supplying a name nor an ID")
{
    import std.conv : to;
    import std.json : JSONType;

    static struct User
    {
        string nickname;
        string displayName;
        ulong id;
    }

    User user;

    if (const stored = givenName in plugin.state.users)
    {
        // Stored user
        user.nickname = stored.nickname;
        user.displayName = stored.displayName;
        user.id = stored.id;
        return user;
    }

    // No such luck
    if (searchByDisplayName)
    {
        foreach (const stored; plugin.state.users.aaOf)
        {
            if (stored.displayName == givenName)
            {
                // Found user by displayName
                user.nickname = stored.nickname;
                user.displayName = stored.displayName;
                user.id = stored.id;
                return user;
            }
        }
    }

    // None on record, look up
    immutable userURL = givenName.length ?
        "https://api.twitch.tv/helix/users?login=" ~ givenName :
        "https://api.twitch.tv/helix/users?id=" ~ id.to!string;

    auto getTwitchUserDg()
    {
        immutable userJSON = getTwitchData(plugin, userURL);

        if ((userJSON.type != JSONType.object) || ("id" !in userJSON))
        {
            // No such user
            return user; //User.init;
        }

        user.nickname = userJSON["login"].str;
        user.displayName = userJSON["display_name"].str;
        user.id = userJSON["id"].str.to!ulong;
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
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        name = Name of game to look up.
        id = Numerical ID of game to look up.

    Returns:
        Voldemort aggregate struct with `id` and `name` members.
 +/
auto getTwitchGame(
    TwitchPlugin plugin,
    const string name,
    const ulong id = 0)
in (Fiber.getThis(), "Tried to call `getTwitchGame` from outside a fiber")
in ((name.length || id), "Tried to call `getTwitchGame` with no game name nor game ID")
{
    import std.conv : to;

    static struct Game
    {
        ulong id;
        string name;
    }

    immutable gameURL = id ?
        "https://api.twitch.tv/helix/games?id=" ~ id.to!string :
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

        return Game(gameJSON["id"].str.to!ulong, gameJSON["name"].str);
    }

    return retryDelegate(plugin, &getTwitchGameDg);
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
 +/
void setChannelTitle(
    TwitchPlugin plugin,
    const string channelName,
    const string title,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `setChannelTitle` from outside a fiber")
in (channelName.length, "Tried to change a the channel title with an empty channel name string")
{
    modifyChannelImpl(plugin, channelName, title, 0, caller);
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
 +/
void setChannelGame(
    TwitchPlugin plugin,
    const string channelName,
    const ulong gameID,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `setChannelGame` from outside a fiber")
in (gameID, "Tried to set the channel game with an empty channel name string")
{
    modifyChannelImpl(plugin, channelName, string.init, gameID, caller);
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
 +/
private void modifyChannelImpl(
    TwitchPlugin plugin,
    const string channelName,
    const string title,
    const ulong gameID,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `modifyChannel` from outside a fiber")
in (channelName.length, "Tried to modify a channel with an empty channel name string")
in ((title.length || gameID), "Tried to modify a channel with no title nor game ID supplied")
{
    import std.array : Appender;
    import std.conv : to;

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

    void modifyChannelDg()
    {
        cast(void)sendHTTPRequest(
            plugin,
            url,
            caller,
            authorizationBearer,
            HTTPVerb.patch,
            cast(ubyte[])sink[],
            "application/json");
    }

    retryDelegate(plugin, &modifyChannelDg);
}


// getChannel
/++
    Fetches information about a channel; its title, what game is being played,
    the channel tags, etc.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        channelName = Name of channel to fetch information about.
 +/
auto getChannel(
    TwitchPlugin plugin,
    const string channelName)
in (Fiber.getThis(), "Tried to call `getChannel` from outside a fiber")
in (channelName.length, "Tried to fetch a channel with an empty channel name string")
{
    import std.algorithm.iteration : map;
    import std.array : array;
    import std.conv : to;
    import std.json : parseJSON;

    const room = channelName in plugin.rooms;
    assert(room, "Tried to look up a channel for which there existed no room");

    immutable url = "https://api.twitch.tv/helix/channels?broadcaster_id=" ~ room.id.to!string;

    static struct Channel
    {
        ulong gameID;
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
        channel.gameID = gameDataJSON["game_id"].str.to!ulong;
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
 +/
void startCommercial(
    TwitchPlugin plugin,
    const string channelName,
    const string lengthString,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `startCommercial` from outside a fiber")
in (channelName.length, "Tried to start a commercial with an empty channel name string")
{
    import std.format : format;

    const room = channelName in plugin.rooms;
    assert(room, "Tried to look up start commercial in a channel for which there existed no room");

    enum url = "https://api.twitch.tv/helix/channels/commercial";
    enum bodyPattern = `
{
    "broadcaster_id": "%d",
    "length": %s
}`;

    immutable body_ = bodyPattern.format(room.id, lengthString);
    immutable authorizationBearer = getBroadcasterAuthorisation(plugin, channelName);

    void startCommercialDg()
    {
        cast(void)sendHTTPRequest(
            plugin,
            url,
            caller,
            authorizationBearer,
            HTTPVerb.post,
            cast(ubyte[])body_,
            "application/json");
    }

    retryDelegate(plugin, &startCommercialDg);
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

        Returns:
            A new [TwitchPoll] with values derived from the passed `json`.
     +/
    static auto fromJSON(const JSONValue json)
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

        TwitchPoll poll;
        poll.pollID = json["id"].str;
        poll.title = json["title"].str;
        poll.broadcasterID = json["broadcaster_id"].str.to!ulong;
        poll.broadcasterLogin = json["broadcaster_login"].str;
        poll.broadcasterDisplayName = json["broadcaster_name"].str;
        poll.channelPointsVotingEnabled = json["channel_points_voting_enabled"].boolean;
        poll.channelPointsPerVote = json["channel_points_per_vote"].str.to!uint;
        poll.duration = cast(uint)json["duration"].integer;
        poll.startedAt = SysTime.fromISOExtString(json["started_at"].str);

        if (const endedAtJSON = "ended_at" in json)
        {
            import std.json : JSONType;

            if (endedAtJSON.type == JSONType.string)
            {
                poll.endedAt = SysTime.fromISOExtString(endedAtJSON.str);
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
            poll.status = active;
            break;

        case "COMPLETED":
            poll.status = completed;
            break;

        case "TERMINATED":
            poll.status = terminated;
            break;

        case "ARCHIVED":
            poll.status = archived;
            break;

        case "MODERATED":
            poll.status = moderated;
            break;

        //case "INVALID":
        default:
            poll.status = invalid;
            break;
        }

        foreach (const choiceJSON; json["choices"].array)
        {
            TwitchPoll.Choice choice;
            choice.id = choiceJSON["id"].str;
            choice.title = choiceJSON["title"].str;
            choice.votes = choiceJSON["votes"].str.to!uint;
            choice.channelPointsVotes = choiceJSON["channel_points_votes"].str.to!uint;
            poll.choices ~= choice;
        }

        return poll;
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
        An array of Voldemort `TwitchPoll` structs.

    Throws:
        [UnexpectedJSONException] on unexpected JSON.
        [EmptyDataJSONException] if the JSON has a `"data"` key but it is empty.
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
    import std.json : JSONType, parseJSON;
    import std.datetime.systime : SysTime;

    const room = channelName in plugin.rooms;
    assert(room, "Tried to get polls of a channel for which there existed no room");

    enum baseURL = "https://api.twitch.tv/helix/polls?broadcaster_id=";
    immutable idPart = pollIDString.length ?
        "&id=" ~ pollIDString :
        string.init;
    immutable url = text(baseURL, room.id, idPart);

    immutable authorizationBearer = getBroadcasterAuthorisation(plugin, channelName);

    auto getPollsDg()
    {
        TwitchPoll[] polls;
        string after;
        uint retry;

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
                HTTPVerb.get,
                cast(ubyte[])null,
                "application/json");
            immutable responseJSON = parseJSON(response.str);

            if (responseJSON.type != JSONType.object)
            {
                // Invalid response in some way, retry until we reach the limit
                if (++retry < TwitchPlugin.delegateRetries) continue;
                enum message = "`getPolls` response has unexpected JSON " ~
                    "(wrong JSON type)";
                throw new UnexpectedJSONException(message, responseJSON);
            }

            immutable dataJSON = "data" in responseJSON;

            if (!dataJSON)
            {
                // For some reason we received an object that didn't contain data
                // Retry as above
                if (++retry < TwitchPlugin.delegateRetries) continue;
                enum message = "`getPolls` response has unexpected JSON " ~
                    `(no "data" key)`;
                throw new UnexpectedJSONException(message, responseJSON);
            }

            if (!dataJSON.array.length)
            {
                // data exists but is empty
                enum message = "`getPolls` response has unexpected JSON " ~
                    `(zero-length "data")`;
                throw new EmptyDataJSONException(message, responseJSON);
            }

            // See TwitchPoll.fromJSON for response layout
            retry = 0;

            foreach (const pollJSON; dataJSON.array)
            {
                polls ~= TwitchPoll.fromJSON(pollJSON);
            }

            after = responseJSON["after"].str;
        }
        while (after.length);

        return polls;
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
        An array of [std.json.JSONValue|JSONValue]s with
        the response returned when creating the poll. On failure, an empty
        [std.json.JSONValue|JSONValue] is instead returned.

    Throws:
        [UnexpectedJSONException] on unexpected JSON.
        [EmptyDataJSONException] if the JSON has a `"data"` key but it is empty.
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
    import std.json : JSONType, parseJSON;

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
    immutable body_ = bodyPattern.format(
        room.id,
        escapedTitle,
        sink[],
        durationString);
    immutable authorizationBearer = getBroadcasterAuthorisation(plugin, channelName);

    auto createPollDg()
    {
        immutable response = sendHTTPRequest(
            plugin,
            url,
            caller,
            authorizationBearer,
            HTTPVerb.post,
            cast(ubyte[])body_,
            "application/json");
        immutable responseJSON = parseJSON(response.str);

        if (responseJSON.type != JSONType.object)
        {
            // Invalid response in some way
            enum message = "`createPoll` response has unexpected JSON " ~
                "(wrong JSON type)";
            throw new UnexpectedJSONException(message, responseJSON);
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

        return TwitchPoll.fromJSON(dataJSON.array[0]);
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
        The [std.json.JSONValue|JSONValue] of the first response returned when ending the poll.

    Throws:
        [UnexpectedJSONException] on unexpected JSON.
        [EmptyDataJSONException] if the JSON has a `"data"` key but it is empty.
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
    import std.json : JSONType, parseJSON;

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
    immutable body_ = bodyPattern.format(room.id, pollID, status);
    immutable authorizationBearer = getBroadcasterAuthorisation(plugin, channelName);

    auto endPollDg()
    {
        immutable response = sendHTTPRequest(
            plugin,
            url,
            caller,
            authorizationBearer,
            HTTPVerb.patch,
            cast(ubyte[])body_,
            "application/json");
        immutable responseJSON = parseJSON(response.str);

        if (responseJSON.type != JSONType.object)
        {
            // Invalid response in some way
            enum message = "`endPoll` response has unexpected JSON " ~
                "(wrong JSON type)";
            throw new UnexpectedJSONException(message, responseJSON);
        }

        immutable dataJSON = "data" in responseJSON;

        if (!dataJSON)
        {
            // For some reason we received an object that didn't contain data
            enum message = "`endPoll` response has unexpected JSON " ~
                `(no "data" key)`;
            throw new UnexpectedJSONException(message, responseJSON);
        }

        if (!dataJSON.array.length)
        {
            // data exists but is empty
            enum message = "`endPoll` response has unexpected JSON " ~
                `(zero-length "data")`;
            throw new EmptyDataJSONException(message, responseJSON);
        }

        return TwitchPoll.fromJSON(dataJSON.array[0]);
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
        [UnexpectedJSONException] on unexpected JSON.

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

        if (responseJSON.type != JSONType.object)
        {
            // Invalid response in some way, retry until we reach the limit
            enum message = "`getBotList` response has unexpected JSON";
            throw new UnexpectedJSONException(message, responseJSON);
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

        return sink[];
    }

    return retryDelegate(plugin, &getBotListDg);
}


// getStream
/++
    Fetches information about an ongoing stream.

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        loginName = Account name of user whose stream to fetch information of.

    Returns:
        A [kameloso.plugins.twitch.TwitchPlugin.Room.Stream|Room.Stream]
        populated with all (relevant) information.
 +/
auto getStream(TwitchPlugin plugin, const string loginName)
in (Fiber.getThis(), "Tried to call `getStream` from outside a fiber")
in (loginName.length, "Tried to get a stream with an empty login name string")
{
    import std.algorithm.iteration : map;
    import std.array : array;
    import std.conv : to;
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

            auto stream = TwitchPlugin.Room.Stream(streamJSON["id"].str.to!ulong);
            stream.live = true;
            stream.userID = streamJSON["user_id"].str.to!ulong;
            stream.userLogin = streamJSON["user_login"].str;
            stream.userDisplayName = streamJSON["user_name"].str;
            stream.gameID = streamJSON["game_id"].str.to!ulong;
            stream.gameName = streamJSON["game_name"].str;
            stream.title = streamJSON["title"].str;
            stream.startTime = SysTime.fromISOExtString(streamJSON["started_at"].str);
            stream.numViewers = streamJSON["viewer_count"].integer;
            stream.tags = streamJSON["tags"]
                .array
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
        An array of Voldemort subscribers.

    Throws:
        [UnexpectedJSONException] on unexpected JSON.
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
    import std.format : format;
    import std.json : JSONType, parseJSON;

    const room = channelName in plugin.rooms;
    assert(room, "Tried to get subscribers of a channel for which there existed no room");

    immutable authorizationBearer = getBroadcasterAuthorisation(plugin, channelName);

    auto getSubscribersDg()
    {
        static struct User
        {
            string name;
            string displayName;
            ulong id;
        }

        static struct Subscription
        {
            User user;
            User gifter;
            bool wasGift;
            uint number;
            uint total;
        }

        Appender!(Subscription[]) subs;
        string after;
        uint number;
        uint retry;

        immutable firstURL = "https://api.twitch.tv/helix/subscriptions?broadcaster_id=" ~ room.id.to!string;
        immutable subsequentURL = totalOnly ?
            firstURL ~ "&first=1&after=" :
            firstURL ~ "&after=";

        do
        {
            immutable url = after.length ?
                subsequentURL ~ after :
                firstURL;
            immutable response = sendHTTPRequest(
                plugin,
                url,
                caller,
                authorizationBearer);
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

            if (responseJSON.type != JSONType.object)
            {
                // Invalid response in some way, retry until we reach the limit
                if (++retry < TwitchPlugin.delegateRetries) continue;
                enum message = "`getSubscribers` response has unexpected JSON";
                throw new UnexpectedJSONException(message, responseJSON);
            }

            immutable dataJSON = "data" in responseJSON;

            if (!dataJSON)
            {
                // As above
                if (++retry < TwitchPlugin.delegateRetries) continue;
                enum message = "`getSubscribers` response has unexpected JSON " ~
                    `(no "data" key)`;
                throw new UnexpectedJSONException(message, responseJSON);
            }

            immutable total = cast(uint)responseJSON["total"].integer;

            if (totalOnly)
            {
                // We only want the total number of subscribers
                Subscription sub;
                sub.total = total;
                subs.put(sub);
                return subs[];
            }

            if (!subs[].length) subs.reserve(total);

            retry = 0;

            foreach (immutable subJSON; dataJSON.array)
            {
                Subscription sub;
                sub.user.id = subJSON["user_id"].str.to!ulong;
                sub.user.name = subJSON["user_login"].str;
                sub.user.displayName = subJSON["user_name"].str;
                sub.wasGift = subJSON["is_gift"].boolean;
                sub.gifter.id = subJSON["gifter_id"].str.to!ulong;
                sub.gifter.name = subJSON["gifter_login"].str;
                sub.gifter.displayName = subJSON["gifter_name"].str;
                if (number == 0) sub.total = total;
                sub.number = number++;
                subs.put(sub);
            }

            immutable paginationJSON = "pagination" in responseJSON;
            if (!paginationJSON) break;

            immutable cursorJSON = "cursor" in *paginationJSON;
            if (!cursorJSON) break;

            after = cursorJSON.str;
        }
        while (after.length);

        return subs[];
    }

    return retryDelegate(plugin, &getSubscribersDg);
}


// createShoutout
/++
    Prepares a `Shoutout` Voldemort struct with information needed to compose a shoutout.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        login = Login name of other streamer to prepare a shoutout for.

    Returns:
        Voldemort `Shoutout` struct.
 +/
auto createShoutout(
    TwitchPlugin plugin,
    const string login)
in (Fiber.getThis(), "Tried to call `createShoutout` from outside a fiber")
in (login.length, "Tried to create a shoutout with an empty login name string")
{
    import std.json : JSONType;

    static struct Shoutout
    {
        enum ShoutoutState
        {
            success,
            noSuchUser,
            noChannel,
            otherError,
        }

        ShoutoutState state;
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

            shoutout.state = Shoutout.ShoutoutState.success;
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
                shoutout.state = Shoutout.ShoutoutState.noSuchUser;
                return shoutout;
            }

            shoutout.state = Shoutout.ShoutoutState.otherError;
            return shoutout;
        }
        catch (EmptyDataJSONException _)
        {
            shoutout.state = Shoutout.ShoutoutState.noSuchUser;
            return shoutout;
        }
        catch (Exception e)
        {
            throw e;
        }
    }

    return retryDelegate(plugin, &shoutoutDg);
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
        return sendHTTPRequest(
            plugin,
            url,
            caller,
            plugin.transient.authorizationBearer,
            HTTPVerb.delete_);
    }

    static immutable failedDeleteRetry = 100.msecs;
    return retryDelegate(plugin, &deleteDg, async: true, endlessly: true, failedDeleteRetry);
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

    Returns:
        A Voldemort struct with information about the timeout action.

    Throws:
        [UnexpectedJSONException] on unexpected JSON.

    See_Also:
        https://dev.twitch.tv/docs/api/reference/#create-a-banned-event
 +/
auto timeoutUser(
    TwitchPlugin plugin,
    const string channelName,
    const ulong userID,
    const uint durationSeconds,
    const string reason = string.init,
    const string caller = __FUNCTION__)
in (Fiber.getThis(), "Tried to call `timeoutUser` from outside a fiber")
in (channelName.length, "Tried to timeout a user without providing a channel")
in (userID, "Tried to timeout a user with an unset user ID")
{
    import std.algorithm.comparison : min;
    import std.conv : to;
    import std.format : format;

    const room = channelName in plugin.rooms;
    assert(room, "Tried to timeout a user in a nonexistent room");

    static struct Timeout
    {
        ulong broadcasterID;
        ulong moderatorID;
        ulong userID;
        string createdAt;
        string endTime;
        uint code;
    }

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
    immutable body_ = bodyPattern.format(
        userID,
        min(durationSeconds, maxDurationSeconds),
        reason);

    auto timeoutDg()
    {
        import std.json : JSONType, parseJSON;

        immutable response = sendHTTPRequest(
            plugin,
            url,
            caller,
            plugin.transient.authorizationBearer,
            HTTPVerb.post,
            cast(ubyte[])body_,
            "application/json");
        immutable responseJSON = parseJSON(response.str);

        if (responseJSON.type != JSONType.object)
        {
            enum message = "`timeoutUser` response has unexpected JSON " ~
                "(wrong JSON type)";
            throw new UnexpectedJSONException(message, responseJSON);
        }

        immutable dataJSON = "data" in responseJSON;

        if (!dataJSON)
        {
            enum message = "`timeoutUser` response has unexpected JSON " ~
                `(no "data" key)`;
            throw new UnexpectedJSONException(message, responseJSON);
        }

        Timeout timeout;
        timeout.broadcasterID = (*dataJSON)["broadcaster_id"].str.to!ulong;
        timeout.moderatorID = (*dataJSON)["moderator_id"].str.to!ulong;
        timeout.userID = (*dataJSON)["user_id"].str.to!ulong;
        timeout.createdAt = (*dataJSON)["created_at"].str;
        timeout.endTime = (*dataJSON)["end_time"].str;
        timeout.code = response.code;
        return timeout;
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
        The HTTP response code received.

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

    enum urlPattern = "https://api.twitch.tv/helix/whispers" ~
        "?from_user_id=%d" ~
        "&to_user_id=%d";

    enum bodyPattern =
`{
    "message": "%s"
}`;

    immutable url = urlPattern.format(plugin.transient.botID, userID);
    immutable messageArgument = message.replace(`"`, `\"`);  // won't work with already escaped quotes
    immutable body_ = bodyPattern.format(messageArgument);

    auto sendWhisperDg()
    {
        import std.json : JSONValue, parseJSON;

        JSONValue responseJSON;
        uint responseCode;

        try
        {
            immutable response = sendHTTPRequest(
                plugin,
                url,caller,
                plugin.transient.authorizationBearer,
                HTTPVerb.post,
                cast(ubyte[])body_,
                "application/json");

            responseJSON = parseJSON(response.str);  // body should be empty, but in case it isn't
            responseCode = response.code;
        }
        catch (ErrorJSONException e)
        {
            responseJSON = e.json;
            responseCode = cast(uint)e.json["status"].integer;
        }

        switch (responseCode)
        {
        case 204:
            // 204 No Content
            // Successfully sent the whisper message or the message was silently dropped.
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
            /*import kameloso.common : logger;
            enum pattern = "Failed to send whisper: <l>%s";
            logger.errorf(pattern, responseJSON["message"].str);*/
            break;
        }

        return responseCode;
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
        The HTTP response code received.

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
    immutable body_ = bodyPattern.format(messageArgument, colourArgument);

    auto sendAnnouncementDg()
    {
        import std.json : JSONValue, parseJSON;

        JSONValue responseJSON;
        uint responseCode;

        try
        {
            immutable response = sendHTTPRequest(
                plugin,
                url,caller,
                plugin.transient.authorizationBearer,
                HTTPVerb.post,
                cast(ubyte[])body_,
                "application/json");

            responseJSON = parseJSON(response.str);  // body should be empty, but in case it isn't
            responseCode = response.code;
        }
        catch (ErrorJSONException e)
        {
            responseJSON = e.json;
            responseCode = cast(uint)e.json["status"].integer;
        }

        switch (responseCode)
        {
        case 204:
            // 204 No Content
            // Successfully sent the announcement
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
            /*import kameloso.common : logger;
            enum pattern = "Failed to send announcement; response code <l>%d";
            logger.errorf(pattern, responseCode);*/
            break;
        }

        return responseCode;
    }

    return retryDelegate(plugin, &sendAnnouncementDg);
}
