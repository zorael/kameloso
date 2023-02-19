/++
    Functions for accessing the Twitch API. For internal use.

    See_Also:
        [kameloso.plugins.twitch.base|twitch.base]
        [kameloso.plugins.twitch.keygen|twitch.keygen]
        [kameloso.plugins.twitch.google|twitch.google]
        [kameloso.plugins.twitch.spotify|twitch.spotify]
 +/
module kameloso.plugins.twitch.api;

version(TwitchSupport):
version(WithTwitchPlugin):

private:

import kameloso.plugins.twitch.base;
import kameloso.plugins.twitch.common;

import arsd.http2 : HttpVerb;
import dialect.defs;
import lu.common : Next;
import std.traits : isSomeFunction;
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
    /// Response body, may be several lines.
    string str;

    /// How long the query took, from issue to response.
    long msecs;

    /// The HTTP response code received.
    uint code;

    /// The message of any exception thrown while querying.
    string error;
}


// twitchTryCatchDg
/++
    Calls a passed delegate in a try-catch. Allows us to have consistent error messages.

    Params:
        dg = `void delegate()` delegate to call.
 +/
version(none)
void twitchTryCatchDg(alias dg)()
if (isSomeFunction!dg)
{
    version(PrintStacktraces)
    static void printBody(const string responseBody)
    {
        import std.json : JSONException, parseJSON;
        import std.stdio : stdout, writeln;

        try
        {
            writeln(parseJSON(responseBody).toPrettyString);
        }
        catch (JSONException _)
        {
            writeln(responseBody);
        }

        stdout.flush();
    }

    foreach (immutable retryNum; 0..TwitchPlugin.delegateRetries)
    {
        try
        {
            dg();
            return;  // nothing thrown --> success
        }
        catch (Exception e)
        {
            immutable action = twitchTryCatchDgExceptionHandler(e, retries, retryNum);

            with (Next)
            final switch (action)
            {
            case continue_:
                continue;

            case returnSuccess:
            case returnFailure:
                return;

            case retry:
            case crash:
                assert(0, "Impossible case");
            }
        }
    }
}


// twitchTryCatchDgExceptionHandler
/++
    Handles exceptions thrown in [twitchTryCatchDg]. Extracted from it to reduce
    template bloat (by making this a normal function).

    Params:
        previouslyThrownException = The exception that was thrown by (the calling) [twitchTryCatchDg].
        retryNum = How any times the throwing delegate has been called so far.

    Returns:
        A [lu.common.Next|Next] dictating what action the caller should take.

    See_Also:
        [twitchTryCatchDg]
 +/
version(none)
private auto twitchTryCatchDgExceptionHandler(
    /*const*/ Exception previouslyThrownException,
    const size_t retryNum)
{
    import kameloso.common : logger;
    import std.json : JSONValue;

    version(PrintStacktraces)
    {
        static void printBody(const string responseBody)
        {
            import std.json : JSONException, parseJSON;
            import std.stdio : stdout, writeln;

            try
            {
                writeln(parseJSON(responseBody).toPrettyString);
            }
            catch (JSONException _)
            {
                writeln(responseBody);
            }

            stdout.flush();
        }

        static void printJSON(const JSONValue json)
        {
            import std.stdio : stdout, writeln;

            writeln(json.toPrettyString);
            stdout.flush();
        }
    }

    try
    {
        throw previouslyThrownException;
    }
    catch (TwitchQueryException e)
    {
        import kameloso.constants : MagicErrorStrings;

        if ((e.code == 401) && (e.error == "Unauthorized"))
        {
            import kameloso.messaging : Message;
            import kameloso.thread : ThreadMessage;
            import std.concurrency : send = prioritySend;

            // API key expired.
            // Copy/paste kameloso.messaging.quit, since we don't have access to plugin.state

            enum apiMessage = "Your Twitch API key has expired. " ~
                "Run the program with <l>--set twitch.keygen</> to generate a new one.";
            logger.error(apiMessage);

            Message m;

            m.event.type = IRCEvent.Type.QUIT;
            m.event.content = "Twitch API key expired";
            m.properties |= (Message.Property.forced | Message.Property.priority);

            (cast()TwitchPlugin.mainThread).send(m);
            return Next.returnFailure;
        }

        // Only proceed to error if all retries failed
        if (retryNum < (TwitchPlugin.delegateRetries-1)) return Next.continue_;

        immutable message = (e.error == MagicErrorStrings.sslLibraryNotFound) ?
            MagicErrorStrings.sslLibraryNotFoundRewritten :
            e.msg;

        enum pattern = "Failed to query Twitch: <l>%s</> <t>(%s) </>(<t>%d</>)";
        logger.errorf(pattern, message, e.error, e.code);
        return Next.returnFailure;
    }
    catch (MissingBroadcasterTokenException e)
    {
        enum pattern = "Missing broadcaster-level API token for channel <l>%s</>.";
        logger.errorf(pattern, e.channelName);

        enum superMessage = "Run the program with <l>--set twitch.superKeygen</> to generate a new one.";
        logger.error(superMessage);
        return Next.returnFailure;
    }
    catch (ErrorJSONException e)
    {
        enum pattern = "Received a JSON error message: <l>%s";
        logger.errorf(pattern, e.msg);

        version(PrintStacktraces)
        {
            printJSON(e.json);
            logger.trace(e.info);
        }
        return Next.returnFailure;
    }
    catch (UnexpectedJSONException e)
    {
        enum pattern = "Received unexpected JSON: <l>%s";
        logger.errorf(pattern, e.msg);

        version(PrintStacktraces)
        {
            printJSON(e.json);
            logger.trace(e.info);
        }
        return Next.returnFailure;
    }
    catch (Exception e)
    {
        enum pattern = "Unforeseen exception caught: <l>%s";
        logger.errorf(pattern, e.msg);
        version(PrintStacktraces) logger.trace(e);

        // Return immediately on unforeseen exceptions, since they're likely
        // to just repeat.
        return Next.returnFailure;
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
            import std.datetime.systime : Clock;
            immutable pre = Clock.currTime;
        }

        immutable response = sendHTTPRequestImpl(url, authToken,
            caBundleFile, verb, cast(ubyte[])body_, contentType);

        synchronized //()
        {
            bucket[id] = response;  // empty str if code >= 400
        }

        version(BenchmarkHTTPRequests)
        {
            import std.stdio : writefln;
            immutable post = Clock.currTime;
            writefln("%s (%s)", post-pre, url);
        }
    }

    bool halt;

    while (!halt)
    {
        receive(
            (int id, string url, string authToken, HttpVerb verb,
                immutable(ubyte)[] body_, string contentType) scope
            {
                invokeSendHTTPRequestImpl(
                    id,
                    url,
                    authToken,
                    verb,
                    body_,
                    contentType);
            },
            (int id, string url, string authToken) scope
            {
                // Shorthand
                invokeSendHTTPRequestImpl(
                    id,
                    url,
                    authToken,
                    HttpVerb.GET,
                    cast(immutable(ubyte)[])null,
                    string.init);
            },
            (ThreadMessage message) scope
            {
                if (message.type == ThreadMessage.Type.teardown)
                {
                    halt = true;
                }
            },
            (OwnerTerminated _) scope
            {
                halt = true;
            },
            (Variant v) scope
            {
                import std.stdio : writeln;
                writeln("Twitch worker received unknown Variant: ", v);
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
    immutable QueryResponse = sendHTTPRequest(plugin, "https://id.twitch.tv/oauth2/validate", "OAuth 30letteroauthstring");
    ---

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        url = The URL to query.
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
    const string authorisationHeader = string.init,
    /*const*/ HttpVerb verb = HttpVerb.GET,
    /*const*/ ubyte[] body_ = null,
    const string contentType = string.init,
    int id = -1,
    const Flag!"recursing" recursing = No.recursing)
in (Fiber.getThis, "Tried to call `sendHTTPRequest` from outside a Fiber")
in (url.length, "Tried to send an HTTP request without an URL")
{
    import kameloso.plugins.common.delayawait : delay;
    import kameloso.thread : ThreadMessage;
    import std.concurrency : prioritySend, send, spawn;
    import std.datetime.systime : Clock, SysTime;
    import core.time : msecs;

    if (plugin.state.settings.trace)
    {
        import kameloso.common : logger;
        enum pattern = "GET: <i>%s";
        logger.tracef(pattern, url);
    }

    plugin.state.mainThread.prioritySend(ThreadMessage.shortenReceiveTimeout());

    immutable pre = Clock.currTime;
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

    immutable post = Clock.currTime;
    immutable diff = (post - pre);
    immutable msecs_ = diff.total!"msecs";
    plugin.averageApproximateQueryTime(msecs_);

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

            throw new ErrorJSONException(message, errorJSON);
        }
        catch (JSONException e)
        {
            throw new TwitchQueryException(
                e.msg,
                response.str,
                response.error,
                response.code,
                e.file,
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
    import std.datetime.systime : Clock;
    import core.time : seconds;

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
    auto pre = Clock.currTime;
    auto req = client.request(Uri(url), verb, body_, contentType);
    // The Twitch Client-ID header leaks into Google and Spotify requests. Worth dealing with?
    req.requestParameters.headers = headers;
    auto res = req.waitForCompletion();

    if (res.code.among!(301, 302, 307, 308) && res.location.length)
    {
        // Moved
        foreach (immutable i; 0..5)
        {
            pre = Clock.currTime;
            req = client.request(Uri(res.location), verb, body_, contentType);
            req.requestParameters.headers = headers;
            res = req.waitForCompletion();

            if (!res.code.among!(301, 302, 307, 308) || !res.location.length) break;
        }
    }

    response.code = res.code;
    response.error = res.codeText;
    response.str = res.contentText;
    immutable post = Clock.currTime;
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

    Returns:
        A singular user or channel regardless of how many were asked for in the URL.
        If nothing was found, an exception is thrown instead.

    Throws:
        [EmptyDataJSONException] if the `"data"` field is empty for some reason.

        [UnexpectedJSONException] on unexpected JSON.

        [TwitchQueryException] on other JSON errors.
 +/
auto getTwitchData(TwitchPlugin plugin, const string url)
in (Fiber.getThis, "Tried to call `getTwitchData` from outside a Fiber")
{
    import std.json : JSONException, JSONType, parseJSON;

    // Request here outside try-catch to let exceptions fall through
    immutable response = sendHTTPRequest(plugin, url, plugin.authorizationBearer);

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
        throw new TwitchQueryException(
            e.msg,
            response.str,
            response.error,
            response.code,
            e.file,
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

    Returns:
        A [std.json.JSONValue|JSONValue] with "`chatters`" and "`chatter_count`" keys.
        If nothing was found, an exception is thrown instead.

    Throws:
        [UnexpectedJSONException] on unexpected JSON.
 +/
auto getChatters(TwitchPlugin plugin, const string broadcaster)
in (Fiber.getThis, "Tried to call `getChatters` from outside a Fiber")
in (broadcaster.length, "Tried to get chatters with an empty broadcaster string")
{
    import std.conv : text;
    import std.json : JSONType, parseJSON;

    immutable chattersURL = text("https://tmi.twitch.tv/group/user/", broadcaster, "/chatters");

    foreach (immutable i; 0..TwitchPlugin.delegateRetries)
    {
        try
        {
            immutable response = sendHTTPRequest(plugin, chattersURL, plugin.authorizationBearer);
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
                // Retry until we reach the limit
                if (i < TwitchPlugin.delegateRetries-1) continue;
                enum message = "`getChatters` response JSON is not JSONType.object";
                throw new UnexpectedJSONException(message, responseJSON);
            }

            immutable chattersJSON = "chatters" in responseJSON;
            if (!chattersJSON)
            {
                // For some reason we received an object that didn't contain chatters
                if (i < TwitchPlugin.delegateRetries-1) continue;
                enum message = "`getChatters` \"chatters\" JSON is not JSONType.object";
                throw new UnexpectedJSONException(message, *chattersJSON);
            }

            // Don't return `chattersJSON`, as we would lose "chatter_count".
            return responseJSON;
        }
        catch (Exception e)
        {
            // Retry until we reach the retry limit, then rethrow
            if (i < TwitchPlugin.delegateRetries-1) continue;
            throw e;
        }
    }

    assert(0, "Unreachable");
}


// getValidation
/++
    Validates an access key, retrieving information about it.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        authToken = Authorisation token to validate.
        async = Whether or not the validation should be done asynchronously, using Fibers.

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
    const Flag!"async" async)
in ((!async || Fiber.getThis), "Tried to call asynchronous `getValidation` from outside a Fiber")
in (authToken.length, "Tried to validate an empty Twitch authorisation token")
{
    import lu.string : beginsWith;
    import std.json : JSONType, parseJSON;

    enum url = "https://id.twitch.tv/oauth2/validate";

    // Validation needs an "Authorization: OAuth xxx" header, as opposed to the
    // "Authorization: Bearer xxx" used everywhere else.
    authToken = plugin.state.bot.pass.beginsWith("oauth:") ?
        authToken[6..$] :
        authToken;
    immutable authorizationHeader = "OAuth " ~ authToken;

    QueryResponse response;

    foreach (immutable i; 0..TwitchPlugin.delegateRetries)
    {
        try
        {
            if (async)
            {
                response = sendHTTPRequest(plugin, url, authorizationHeader);
            }
            else
            {
                response = sendHTTPRequestImpl(url, authorizationHeader, plugin.state.connSettings.caBundleFile);

                // Copy/paste error handling...
                if (response.code == 2)
                {
                    // Retry until we reach the retry limit, then rethrow
                    if (i < TwitchPlugin.delegateRetries-1) continue;
                    throw new TwitchQueryException(
                        response.error,
                        response.str,
                        response.error,
                        response.code);
                }
                else if (response.code == 0) //(!response.str.length)
                {
                    // As above
                    if (i < TwitchPlugin.delegateRetries-1) continue;
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

                    if (i < TwitchPlugin.delegateRetries-1) continue;

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
                        // As above
                        //if (i < TwitchPlugin.delegateRetries-1) continue;
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
                // As above
                if (i < TwitchPlugin.delegateRetries-1) continue;
                enum message = "Failed to validate Twitch authorisation token; unknown JSON";
                throw new UnexpectedJSONException(message, validationJSON);
            }

            return validationJSON;
        }
        catch (Exception e)
        {
            // Retry until we reach the retry limit, then rethrow
            if (i < TwitchPlugin.delegateRetries-1) continue;
            throw e;
        }
    }

    assert(0, "Unreachable");
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

    foreach (immutable i; 0..TwitchPlugin.delegateRetries)
    {
        try
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
        catch (Exception e)
        {
            // Retry until we reach the retry limit, then rethrow
            if (i < TwitchPlugin.delegateRetries-1) continue;
            throw e;
        }
    }

    assert(0, "Unreachable");
}


// getMultipleTwitchData
/++
    By following a passed URL, queries Twitch servers for an array of entities
    (such as users or channels).

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        url = The URL to follow.

    Returns:
        A [std.json.JSONValue|JSONValue] of type `array` containing all returned
        entities, over all paginated queries.
 +/
auto getMultipleTwitchData(TwitchPlugin plugin, const string url)
in (Fiber.getThis, "Tried to call `getMultipleTwitchData` from outside a Fiber")
{
    import std.json : JSONValue, parseJSON;

    JSONValue allEntitiesJSON;
    allEntitiesJSON = null;
    allEntitiesJSON.array = null;
    string after;

    do
    {
        immutable paginatedURL = after.length ?
            (url ~ "&after=" ~ after) :
            url;
        immutable response = sendHTTPRequest(plugin, paginatedURL, plugin.authorizationBearer);
        immutable responseJSON = parseJSON(response.str);

        immutable dataJSON = "data" in responseJSON;
        if (!dataJSON) break;  // Invalid response

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

    alias QC = TwitchPlugin.QueryConstants;
    enum maxDeltaToResponse = 1000;

    immutable current = plugin.approximateQueryTime;
    alias weight = QC.averagingWeight;
    alias padding = QC.measurementPadding;
    immutable responseAdjusted = cast(long)min(responseMsecs, (current + maxDeltaToResponse));
    immutable average = ((weight * current) + (responseAdjusted + padding)) / (weight + 1);

    version(BenchmarkHTTPRequests)
    {
        import std.stdio : writefln;
        enum pattern = "time:%s | response: %d~%d (+%d) | new average:%s";
        writefln!pattern(current, responseMsecs, responseAdjusted, cast(long)padding, average);
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
        leaveTimingAlone = Whether or not to adjust the approximate query time.
            Enabled by default but can be disabled if the caller wants to do it.

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

    immutable startTime = Clock.currTime.toUnixTime;
    shared QueryResponse* response;
    double accumulatingTime = plugin.approximateQueryTime;

    while (true)
    {
        response = id in plugin.bucket;

        if (!response || (*response == QueryResponse.init))
        {
            immutable now = Clock.currTime.toUnixTime;

            if ((now - startTime) >= Timeout.httpGET)
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
                enum pattern = "MISS! elapsed: %s | old: %d --> new: %d | wait: %d";
                writefln(pattern,
                    (now-startTime),
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
            immutable now = Clock.currTime.toUnixTime;
            writefln!pattern((now-startTime), response.msecs, misses);
        }

        // Make the new approximate query time a weighted average
        plugin.averageApproximateQueryTime(response.msecs);
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
        ("https://api.twitch.tv/helix/users?login=" ~ givenName) :
        ("https://api.twitch.tv/helix/users?login=" ~ givenIDString);

    foreach (immutable i; 0..TwitchPlugin.delegateRetries)
    {
        try
        {
            immutable userJSON = getTwitchData(plugin, userURL);

            if ((userJSON.type != JSONType.object) || ("id" !in userJSON))
            {
                // No such user
                // Retry until we reach the retry limit
                if (i < TwitchPlugin.delegateRetries-1) continue;
                return user; //User.init;
            }

            user.idString = userJSON["id"].str;
            user.nickname = userJSON["login"].str;
            user.displayName = userJSON["display_name"].str;
            return user;
        }
        catch (Exception e)
        {
            // Retry until we reach the retry limit, then rethrow
            if (i < TwitchPlugin.delegateRetries-1) continue;
            throw e;
        }
    }

    assert(0, "Unreachable");
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
        ("https://api.twitch.tv/helix/games?id=" ~ id) :
        ("https://api.twitch.tv/helix/games?name=" ~ name);

    foreach (immutable i; 0..TwitchPlugin.delegateRetries)
    {
        try
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
        catch (Exception e)
        {
            // Retry until we reach the retry limit, then rethrow
            if (i < TwitchPlugin.delegateRetries-1) continue;
            throw e;
        }
    }

    assert(0, "Unreachable");
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
 +/
void modifyChannel(
    TwitchPlugin plugin,
    const string channelName,
    const string title,
    const string gameID)
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

    foreach (immutable i; 0..TwitchPlugin.delegateRetries)
    {
        try
        {
            cast(void)sendHTTPRequest(
                plugin,
                url,
                authorizationBearer,
                HttpVerb.PATCH,
                cast(ubyte[])sink.data,
                "application/json");
            return;
        }
        catch (Exception e)
        {
            // Retry until we reach the retry limit, then rethrow
            if (i < TwitchPlugin.delegateRetries-1) continue;
            throw e;
        }
    }
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

    foreach (immutable i; 0..TwitchPlugin.delegateRetries)
    {
        try
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
        catch (Exception e)
        {
            // Retry until we reach the retry limit, then rethrow
            if (i < TwitchPlugin.delegateRetries-1) continue;
            throw e;
        }
    }

    assert(0, "Unreachable");
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
 +/
void startCommercial(TwitchPlugin plugin, const string channelName, const string lengthString)
in (Fiber.getThis, "Tried to call `startCommercial` from outside a Fiber")
in (channelName.length, "Tried to start a commercial with an empty channel name string")
{
    import std.format : format;

    const room = channelName in plugin.rooms;
    assert(room, "Tried to look up start commerical in a channel for which there existed no room");

    enum url = "https://api.twitch.tv/helix/channels/commercial";
    enum pattern = `
{
    "broadcaster_id": "%s",
    "length": %s
}`;

    immutable body_ = pattern.format(room.id, lengthString);
    immutable authorizationBearer = getBroadcasterAuthorisation(plugin, channelName);

    foreach (immutable i; 0..TwitchPlugin.delegateRetries)
    {
        try
        {
            cast(void)sendHTTPRequest(
                plugin,
                url,
                authorizationBearer,
                HttpVerb.POST,
                cast(ubyte[])body_,
                "application/json");
            return;
        }
        catch (Exception e)
        {
            // Retry until we reach the retry limit, then rethrow
            if (i < TwitchPlugin.delegateRetries-1) continue;
            throw e;
        }
    }
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

    Returns:
        An arary of [std.json.JSONValue|JSONValue]s with all the matched polls.
 +/
auto getPolls(
    TwitchPlugin plugin,
    const string channelName,
    const string idString = string.init)
in (Fiber.getThis, "Tried to call `getPolls` from outside a Fiber")
in (channelName.length, "Tried to get polls with an empty channel name string")
{
    import std.json : JSONType, JSONValue, parseJSON;

    const room = channelName in plugin.rooms;
    assert(room, "Tried to get polls of a channel for which there existed no room");

    enum baseURL = "https://api.twitch.tv/helix/polls?broadcaster_id=";
    immutable authorizationBearer = getBroadcasterAuthorisation(plugin, channelName);

    string url = baseURL ~ room.id;  // mutable;
    if (idString.length) url ~= "&id=" ~ idString;

    JSONValue allPollsJSON;
    allPollsJSON = null;
    allPollsJSON.array = null;
    string after;

    foreach (immutable i; 0..TwitchPlugin.delegateRetries)
    {
        try
        {
            uint retry;

            inner:
            do
            {
                immutable paginatedURL = after.length ?
                    (url ~ "&after=" ~ after) :
                    url;
                immutable response = sendHTTPRequest(
                    plugin,
                    paginatedURL,
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
        /*catch (MissingBroadcasterTokenException e)
        {
            throw e;
        }*/
        catch (Exception e)
        {
            // Retry until we reach the retry limit, then rethrow
            if (i < TwitchPlugin.delegateRetries-1) continue;
            throw e;
        }
    }

    assert(0, "Unreachable");
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
    const string[] choices)
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

    foreach (immutable i; 0..TwitchPlugin.delegateRetries)
    {
        try
        {
            immutable authorizationBearer = getBroadcasterAuthorisation(plugin, channelName);
            immutable response = sendHTTPRequest(
                plugin,
                url,
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
                if (i < TwitchPlugin.delegateRetries-1) continue;
                enum message = "`createPoll` response has unexpected JSON";
                throw new UnexpectedJSONException(message, responseJSON);
            }

            return responseJSON["data"].array;
        }
        catch (MissingBroadcasterTokenException e)
        {
            throw e;
        }
        catch (Exception e)
        {
            // Retry until we reach the retry limit, then rethrow
            if (i < TwitchPlugin.delegateRetries-1) continue;
            throw e;
        }
    }

    assert(0, "Unreachable");
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

    Returns:
        The [std.json.JSONValue|JSONValue] of the first response returned when ending the poll.

    Throws:
        [UnexpectedJSONException] on unexpected JSON.
 +/
auto endPoll(
    TwitchPlugin plugin,
    const string channelName,
    const string voteID,
    const Flag!"terminate" terminate)
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

    foreach (immutable i; 0..TwitchPlugin.delegateRetries)
    {
        try
        {
            immutable authorizationBearer = getBroadcasterAuthorisation(plugin, channelName);
            immutable response = sendHTTPRequest(
                plugin,
                url,
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
                if (i < TwitchPlugin.delegateRetries-1) continue;
                enum message = "`endPoll` response has unexpected JSON";
                throw new UnexpectedJSONException(message, responseJSON);
            }

            return responseJSON["data"].array[0];
        }
        catch (MissingBroadcasterTokenException e)
        {
            throw e;
        }
        catch (Exception e)
        {
            // Retry until we reach the retry limit, then rethrow
            if (i < TwitchPlugin.delegateRetries-1) continue;
            throw e;
        }
    }

    assert(0, "Unreachable");
}


// getBotList
/++
    Fetches a list of known (online) bots from TwitchInsights.net.

    With this we don't have to keep a static list of known bots to exclude when
    counting chatters.

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].

    Returns:
        A `string[]` array of online bot account names.

    Throws:
        [TwitchQueryException] on unexpected JSON.

    See_Also:
        https://twitchinsights.net/bots
 +/
auto getBotList(TwitchPlugin plugin)
{
    import std.algorithm.searching : endsWith;
    import std.array : Appender;
    import std.json : JSONType, parseJSON;

    foreach (immutable i; 0..TwitchPlugin.delegateRetries)
    {
        try
        {
            enum url = "https://api.twitchinsights.net/v1/bots/online";
            immutable response = sendHTTPRequest(plugin, url);
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
                if (i < TwitchPlugin.delegateRetries-1) continue;
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
        catch (Exception e)
        {
            // Retry until we reach the retry limit, then rethrow
            if (i < TwitchPlugin.delegateRetries-1) continue;
            throw e;
        }
    }

    assert(0, "Unreachable");
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

    foreach (immutable i; 0..TwitchPlugin.delegateRetries)
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
            stream.userIDString = streamJSON["user_id"].str;
            stream.userLogin = streamJSON["user_login"].str;
            stream.userDisplayName = streamJSON["user_name"].str;
            stream.gameIDString = streamJSON["game_id"].str;
            stream.gameName = streamJSON["game_name"].str;
            stream.title = streamJSON["title"].str;
            stream.startTime = SysTime.fromISOExtString(streamJSON["started_at"].str);
            stream.viewerCount = streamJSON["viewer_count"].integer;
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
            // Retry on all other Exceptions until we reach the retry limit, then rethrow
            if (i < TwitchPlugin.delegateRetries-1) continue;
            throw e;
        }
    }

    assert(0, "Unreachable");
}


// getBTTVEmotes
/++
    Fetches BetterTTV emotes for a given channel.

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        emoteMap = Reference to the `bool[dstring]` associative array to store
            the fetched emotes in.
        idString = Twitch user/channel ID in string form.

    See_Also:
        https://betterttv.com
 +/
void getBTTVEmotes(
    TwitchPlugin plugin,
    ref bool[dstring] emoteMap,
    const string idString)
in (Fiber.getThis, "Tried to call `getBTTVEmotes` from outside a Fiber")
in (idString.length, "Tried to get BTTV emotes with an empty ID string")
{
    import std.conv : to;
    import std.json : JSONType, parseJSON;

    immutable url = "https://api.betterttv.net/3/cached/users/twitch/" ~ idString;

    foreach (immutable i; 0..TwitchPlugin.delegateRetries)
    {
        try
        {
            immutable response = sendHTTPRequest(plugin, url);
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

            immutable channelEmotesJSON = "channelEmotes" in responseJSON;

            if (!channelEmotesJSON)
            {
                immutable messageJSON = "message" in responseJSON;
                if (messageJSON && (messageJSON.str == "user not found"))
                {
                    // Benign
                    return;
                }

                throw new TwitchQueryException(
                    `No "channelEmotes" key in JSON response`,
                    response.str);
            }

            immutable sharedEmotesJSON = "sharedEmotes" in responseJSON;
            if (!sharedEmotesJSON) throw new TwitchQueryException(
                `No "sharedEmotes" key in JSON response`,
                response.str);

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
            return;
        }
        catch (TwitchQueryException e)
        {
            immutable json = parseJSON(e.responseBody);

            if (json.type == JSONType.object)
            {
                immutable messageJSON = "message" in json;

                if (messageJSON && (messageJSON.str == "user not found"))
                {
                    // Benign
                    return;
                }
                // Drop down
            }

            if (i < TwitchPlugin.delegateRetries-1)
            {
                // Retry
                continue;
            }
            throw e;
        }
        catch (Exception e)
        {
            // Retry until we reach the retry limit, then rethrow
            if (i < TwitchPlugin.delegateRetries-1) continue;
            throw e;
        }
    }

    assert(0, "Unreachable");
}


// getBTTVGlobalEmotes
/++
    Fetches globalBetterTTV emotes.

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        emoteMap = Reference to the `bool[dstring]` associative array to store
            the fetched emotes in.

    See_Also:
        https://betterttv.com/emotes/global
 +/
void getBTTVGlobalEmotes(
    TwitchPlugin plugin,
    ref bool[dstring] emoteMap)
in (Fiber.getThis, "Tried to call `getBTTVGlobalEmotes` from outside a Fiber")
{
    import std.conv : to;
    import std.json : parseJSON;

    enum url = "https://api.betterttv.net/3/cached/emotes/global";

    foreach (immutable i; 0..TwitchPlugin.delegateRetries)
    {
        try
        {
            immutable response = sendHTTPRequest(plugin, url);
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
            return;
        }
        /*catch (TwitchQueryException e)
        {
            // Populate once we know how error messages look
        }*/
        catch (Exception e)
        {
            // Retry until we reach the retry limit, then rethrow
            if (i < TwitchPlugin.delegateRetries-1) continue;
            throw e;
        }
    }
}


// getFFZEmotes
/++
    Fetches FrankerFaceZ emotes for a given channel.

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        emoteMap = Reference to the `bool[dstring]` associative array to store
            the fetched emotes in.
        idString = Twitch user/channel ID in string form.

    See_Also:
        https://www.frankerfacez.com
 +/
void getFFZEmotes(
    TwitchPlugin plugin,
    ref bool[dstring] emoteMap,
    const string idString)
in (Fiber.getThis, "Tried to call `getFFZEmotes` from outside a Fiber")
in (idString.length, "Tried to get FFZ emotes with an empty ID string")
{
    import std.conv : to;
    import std.json : JSONType, parseJSON;

    immutable url = "https://api.frankerfacez.com/v1/room/id/" ~ idString;

    foreach (immutable i; 0..TwitchPlugin.delegateRetries)
    {
        try
        {
            immutable response = sendHTTPRequest(plugin, url);
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

            if ((responseJSON.type != JSONType.object) || ("sets" !in responseJSON))
            {
                // Invalid response in some way
                if (i < TwitchPlugin.delegateRetries-1) continue;
                enum message = "`getFFZEmotes` response has unexpected JSON";
                throw new UnexpectedJSONException(message, responseJSON);
            }

            foreach (immutable setJSON; responseJSON["sets"].object)
            {
                immutable emoticonsJSON = "emoticons" in setJSON;
                if (!emoticonsJSON) throw new TwitchQueryException(
                    `No "emoticons" key in JSON response`,
                    response.str);

                foreach (immutable emoteJSON; emoticonsJSON.array)
                {
                    immutable emote = emoteJSON["name"].str.to!dstring;
                    emoteMap[emote] = true;
                }
            }

            // All done
            return;
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
        catch (TwitchQueryException e)
        {
            // Retry until we reach the retry limit, then rethrow
            if (i < TwitchPlugin.delegateRetries-1) continue;
            throw e;
        }
        catch (Exception e)
        {
            // As above
            if (i < TwitchPlugin.delegateRetries-1) continue;
            throw e;
        }
    }
}


// get7tvEmotes
/++
    Fetches 7tv emotes for a given channel.

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        emoteMap = Reference to the `bool[dstring]` associative array to store
            the fetched emotes in.
        idString = Twitch user/channel ID in string form.

    See_Also:
        https://7tv.app
 +/
void get7tvEmotes(
    TwitchPlugin plugin,
    ref bool[dstring] emoteMap,
    const string idString)
in (Fiber.getThis, "Tried to call `get7tvEmotes` from outside a Fiber")
in (idString.length, "Tried to get 7tv emotes with an empty ID string")
{
    import std.conv : to;
    import std.json : JSONType, parseJSON;

    immutable url = "https://api.7tv.app/v2/users/" ~ idString ~ "/emotes";

    foreach (immutable i; 0..TwitchPlugin.delegateRetries)
    {
        try
        {
            immutable response = sendHTTPRequest(plugin, url);
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

            if (responseJSON.type == JSONType.object)
            {
                immutable errorJSON = "error" in responseJSON;
                if (errorJSON && (errorJSON.str == "No Items Found"))
                {
                    // Benign
                    return;
                }

                throw new TwitchQueryException(
                    "Response was not a JSON array",
                    response.str);
            }

            foreach (immutable emoteJSON; responseJSON.array)
            {
                immutable emote = emoteJSON["name"].str.to!dstring;
                emoteMap[emote] = true;
            }

            // All done
            return;
        }
        catch (TwitchQueryException e)
        {
            immutable json = parseJSON(e.responseBody);

            if (json.type == JSONType.object)
            {
                // Shouldn't this be an ErrorJSONException?
                immutable errorJSON = "error" in json;

                if (errorJSON && (errorJSON.str == "No Items Found"))
                {
                    // Benign
                    return;
                }
                // Drop down
            }

            if (i < TwitchPlugin.delegateRetries-1)
            {
                // Retry
                continue;
            }
            throw e;
        }
        catch (Exception e)
        {
            // Retry until we reach the retry limit, then rethrow
            if (i < TwitchPlugin.delegateRetries-1) continue;
            throw e;
        }
    }

    assert(0, "Unreachable");
}


// get7tvGlobalEmotes
/++
    Fetches 7tv emotes.

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        emoteMap = Reference to the `bool[dstring]` associative array to store
            the fetched emotes in.

    See_Also:
        https://7tv.app
 +/
void get7tvGlobalEmotes(
    TwitchPlugin plugin,
    ref bool[dstring] emoteMap)
in (Fiber.getThis, "Tried to call `get7tvGlobalEmotes` from outside a Fiber")
{
    import std.conv : to;
    import std.json : parseJSON;

    enum url = "https://api.7tv.app/v2/emotes/global";

    foreach (immutable i; 0..TwitchPlugin.delegateRetries)
    {
        try
        {
            immutable response = sendHTTPRequest(plugin, url);
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
            return;
        }
        /*catch (TwitchQueryException e)
        {
            // Populate once we know how error messages look
        }*/
        catch (Exception e)
        {
            // Retry until we reach the retry limit, then rethrow
            if (i < TwitchPlugin.delegateRetries-1) continue;
            throw e;
        }
    }
}


// getSubscribers
/++
    Fetches a list of all subscribers of the specified channel. A broadcaster-level
    access token is required.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        channelName = Name of channel to fetch subscribers of.

    Returns:
        An array of Voldemort subscribers.
 +/
version(none)
auto getSubscribers(
    TwitchPlugin plugin,
    const string channelName)
in (Fiber.getThis, "Tried to call `getSubscribers` from outside a Fiber")
in (channelName.length, "Tried to get subscribers with an empty channel name string")
{
    import std.array : Appender;
    import std.format : format;
    import std.json : JSONType, parseJSON;

    const room = channelName in plugin.rooms;
    assert(room, "Tried to get subscribers of a channel for which there existed no room");

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

    foreach (immutable i; 0..TwitchPlugin.delegateRetries)
    {
        try
        {
            uint retry;

            inner:
            do
            {
                immutable authorizationBearer = getBroadcasterAuthorisation(plugin, channelName);
                immutable body_ = after.length ?
                    subsequentPattern.format(room.id, after) :
                    initialPattern.format(room.id);
                immutable response = sendHTTPRequest(
                    plugin,
                    url,
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
        catch (MissingBroadcasterTokenException e)
        {
            throw e;
        }
        catch (Exception e)
        {
            // Retry until we reach the retry limit, then rethrow
            if (i < TwitchPlugin.delegateRetries-1) continue;
            throw e;
        }
    }

    assert(0, "Unreachable");
}
