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

    if (!TwitchPlugin.useAPIFeatures) return Next.returnFailure;

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
        If nothing was found, an empty [std.json.JSONValue|JSONValue].init is
        returned instead.

    Throws:
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
        else if (const dataJSON = "data" in responseJSON)
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
        If nothing was found, an empty [std.json.JSONValue|JSONValue].init is
        returned instead.

    Throws:
        [UnexpectedJSONException] on unexpected JSON.
 +/
auto getChatters(TwitchPlugin plugin, const string broadcaster)
in (Fiber.getThis, "Tried to call `getChatters` from outside a Fiber")
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
            else if (const chattersJSON = "chatters" in responseJSON)
            {
                if (chattersJSON.type != JSONType.object)
                {
                    // As above
                    if (i < TwitchPlugin.delegateRetries-1) continue;
                    enum message = "`getChatters` \"chatters\" JSON is not JSONType.object";
                    throw new UnexpectedJSONException(message, *chattersJSON);
                }
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
{
    import lu.string : beginsWith;
    import std.json : JSONType, JSONValue, parseJSON;

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
{
    import std.json : JSONValue;

    immutable url = "https://api.twitch.tv/helix/users/follows?to_id=" ~ id;

    foreach (immutable i; 0..TwitchPlugin.delegateRetries)
    {
        try
        {
            const entitiesArrayJSON = getMultipleTwitchData(plugin, url);
            JSONValue[string] allFollowsJSON;

            foreach (entityJSON; entitiesArrayJSON.array)
            {
                immutable key = entityJSON.object["from_id"].str;
                allFollowsJSON[key] = null;
                allFollowsJSON[key] = entityJSON;
            }

            return allFollowsJSON;
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
    long total;
    string after;

    do
    {
        immutable paginatedURL = after.length ?
            ("&after=" ~ after) :
            url;

        immutable response = sendHTTPRequest(plugin, paginatedURL, plugin.authorizationBearer);
        immutable responseJSON = parseJSON(response.str);
        const cursor = "cursor" in responseJSON["pagination"];

        if (!total) total = responseJSON["total"].integer;

        foreach (thisResponseJSON; responseJSON["data"].array)
        {
            allEntitiesJSON.array ~= thisResponseJSON;
        }

        after = ((allEntitiesJSON.array.length != total) && cursor) ? cursor.str : string.init;
    }
    while (after.length);

    return allEntitiesJSON;
}


// averageApproximateQueryTime
/++
    Given a query time measurement, calculate a new approximate query time based on
    the weighted averages of the old value and said new measurement.

    The old value is given a weight of
    [kameloso.plugins.twitch.base.TwitchPlugin.approximateQueryAveragingWeight|approximateQueryAveragingWeight]
    and the new measurement a weight of 1. Additionally the measurement is padded by
    [kameloso.plugins.twitch.base.TwitchPlugin.approximateQueryMeasurementPadding|approximateQueryMeasurementPadding]
    to be on the safe side.

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        responseMsecs = The new measurement of how many milliseconds the last
            query took to complete.
 +/
void averageApproximateQueryTime(TwitchPlugin plugin, const long responseMsecs)
{
    import std.algorithm.comparison : min;

    enum maxDeltaToResponse = 1000;

    immutable current = plugin.approximateQueryTime;
    alias weight = plugin.approximateQueryAveragingWeight;
    alias padding = plugin.approximateQueryMeasurementPadding;
    immutable responseAdjusted = min(responseMsecs, (current + maxDeltaToResponse));
    immutable average = ((weight * current) + (responseAdjusted + padding)) / (weight + 1);

    version(BenchmarkHTTPRequests)
    {
        import std.stdio : writefln;
        writefln("time:%s | response: %d~%d (+%d) | new average:%s",
            current, responseMsecs, responseAdjusted, padding, average);
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

            // Miss; fired too early, there is no response available yet
            accumulatingTime *= plugin.approximateQueryGrowthMultiplier;
            alias divisor = plugin.approximateQueryRetryTimeDivisor;
            immutable briefWait = cast(long)(accumulatingTime / divisor);
            delay(plugin, briefWait.msecs, Yes.yield);
            continue;
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
        "https://api.twitch.tv/helix/games?id=" ~ id :
        "https://api.twitch.tv/helix/games?name=" ~ name;

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

    int id = uniform(0, 1000);

    synchronized //()
    {
        while (id in bucket)
        {
            id = uniform(0, 1000);
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
{
    import std.array : Appender;

    const room = channelName in plugin.rooms;
    assert(room, "Tried to look up modify channel for which there existed no room");

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
            cast(void)sendHTTPRequest(plugin, url, authorizationBearer,
                HttpVerb.PATCH, cast(ubyte[])sink.data, "application/json");
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
        throw new MissingBroadcasterTokenException("Missing broadcaster key", channelName, __FILE__);
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
            cast(void)sendHTTPRequest(plugin, url, authorizationBearer,
                HttpVerb.POST, cast(ubyte[])body_, "application/json");
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
        A [std.json.JSONType.array|JSONType.array]-type [std.json.JSONValue|JSONValue]
        with all the matched polls.
 +/
auto getPolls(
    TwitchPlugin plugin,
    const string channelName,
    const string idString = string.init)
in (Fiber.getThis, "Tried to call `getPolls` from outside a Fiber")
{
    import std.json : JSONType, JSONValue, parseJSON;

    const room = channelName in plugin.rooms;
    assert(room, "Tried to get polls of a channel for which there existed no room");

    enum baseURL = "https://api.twitch.tv/helix/polls?broadcaster_id=";
    immutable authorizationBearer = getBroadcasterAuthorisation(plugin, channelName);

    string url = baseURL ~ room.id;  // mutable;
    if (idString.length) url ~= "&id=" ~ idString;

    foreach (immutable i; 0..TwitchPlugin.delegateRetries)
    {
        try
        {
            JSONValue allPollsJSON;
            allPollsJSON = null;
            allPollsJSON.array = null;
            string after;
            uint retry;

            inner:
            while (true)
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

                if ((responseJSON.type != JSONType.object) ||
                    ("data" !in responseJSON) ||
                    (responseJSON["data"].type == JSONType.null_))
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
                if (!after.length) break;
            }

            return allPollsJSON;
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
        A [std.json.JSONValue|JSONValue] [std.json.JSONType.array|array] with
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

            immutable responseJSON = parseJSON(response.str);

            if ((responseJSON.type != JSONType.object) ||
                ("data" !in responseJSON) ||
                (responseJSON["data"].type != JSONType.array))
            {
                // Invalid response in some way
                if (i < TwitchPlugin.delegateRetries-1) continue;
                enum message = "`createPoll` response has unexpected JSON";
                throw new UnexpectedJSONException(message, responseJSON);
            }

            return responseJSON["data"];
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
        A [std.json.JSONType.array|JSONType.array]-type [std.json.JSONValue|JSONValue]
        with the response returned when ending the poll.

    Throws:
        [UnexpectedJSONException] on unexpected JSON.
 +/
auto endPoll(
    TwitchPlugin plugin,
    const string channelName,
    const string voteID,
    const Flag!"terminate" terminate)
in (Fiber.getThis, "Tried to call `endPoll` from outside a Fiber")
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

            immutable responseJSON = parseJSON(response.str);

            if ((responseJSON.type != JSONType.object) ||
                ("data" !in responseJSON) ||
                (responseJSON["data"].type != JSONType.array))
            {
                // Invalid response in some way
                if (i < TwitchPlugin.delegateRetries-1) continue;
                enum message = "`endPoll` response has unexpected JSON";
                throw new UnexpectedJSONException(message, responseJSON);
            }

            return responseJSON["data"].array[0];
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

            if ((responseJSON.type != JSONType.object) ||
                ("_total" !in responseJSON) ||
                ("bots" !in responseJSON) ||
                (responseJSON["bots"].type != JSONType.array))
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
{
    import std.datetime.systime : SysTime;
    /*import std.algorithm.iteration : map;
    import std.array : array;*/

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
            //stream.tags = streamJSON["tags"].array.map!(e => e.str).array;
            return stream;
        }
        catch (EmptyDataJSONException e)
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
