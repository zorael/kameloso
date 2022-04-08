/++
    Functions for accessing the Twitch API. For internal use.

    See_Also:
        [kameloso.plugins.twitchbot.base|twitchbot.base]
        [kameloso.plugins.twitchbot.keygen|twitchbot.keygen]
 +/
module kameloso.plugins.twitchbot.api;

version(TwitchSupport):
version(WithTwitchBotPlugin):

private:

import kameloso.plugins.twitchbot.base;

import dialect.defs;
import std.json : JSONValue;
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
 +/
void twitchTryCatchDg(alias dg)()
if (isSomeFunction!dg)
{
    try
    {
        dg();
    }
    catch (TwitchQueryException e)
    {
        import kameloso.common : expandTags, logger;
        import kameloso.logger : LogLevel;

        enum pattern = "Failed to query Twitch: <l>%s</> (<l>%s</>) (<t>%d</>)";
        logger.errorf(pattern.expandTags(LogLevel.error), e.msg, e.error, e.code);
    }
}


// persistentQuerier
/++
    Persistent worker issuing Twitch API queries based on the concurrency messages
    sent to it.

    Possibly best used on Windows where spawning new threads is comparatively expensive
    compared to on Posix platforms.

    Example:
    ---
    spawn(&persistentQuerier, plugin.bucket, plugin.queryResponseTimeout, caBundleFile);
    ---

    Params:
        bucket = The shared associative array to put the results in, response
            values keyed by URL.
        caBundleFile = Path to a `cacert.pem` SSL certificate bundle.
 +/
void persistentQuerier(shared QueryResponse[string] bucket, const string caBundleFile)
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

    while (!halt)
    {
        receive(
            (string url, string authToken) scope
            {
                queryTwitchImpl(url, authToken, bucket, caBundleFile);
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
            /*(Variant _) scope
            {
                // It's technically an error but do nothing for now
            },*/
        );
    }
}


// queryTwitch
/++
    Wraps [queryTwitchImpl] by either starting it in a subthread, or by calling it normally.

    Once the query returns, the response body is checked to see whether or not
    an error occurred. If so, it throws an exception with a descriptive message.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Example:
    ---
    immutable QueryResponse = queryTwitch(plugin, "https://id.twitch.tv/oauth2/validate", "OAuth 30letteroauthstring");
    ---

    Params:
        plugin = The current [kameloso.plugins.twitchbot.base.TwitchBotPlugin|TwitchBotPlugin].
        url = The URL to query.
        authorisationHeader = Authorisation HTTP header to pass.
        recursing = Whether or not this is a recursive call and another one should
            not be attempted.

    Returns:
        The [QueryResponse] that was discovered while monitoring the `bucket`
        as having been received from the server.

    Throws:
        [TwitchQueryException] if there were unrecoverable errors.
 +/
QueryResponse queryTwitch(TwitchBotPlugin plugin,
    const string url,
    const string authorisationHeader,
    const Flag!"recursing" recursing = No.recursing)
in (Fiber.getThis, "Tried to call `queryTwitch` from outside a Fiber")
{
    import kameloso.plugins.common.delayawait : delay;
    import kameloso.thread : ThreadMessage;
    import std.concurrency : prioritySend, send, spawn;
    import std.datetime.systime : Clock, SysTime;
    import core.time : msecs;

    SysTime pre;

    plugin.state.mainThread.prioritySend(ThreadMessage.shortenReceiveTimeout());

    if (plugin.state.settings.trace)
    {
        import kameloso.common : Tint, logger;
        logger.trace("GET: ", Tint.info, url);
    }

    if (plugin.twitchBotSettings.singleWorkerThread)
    {
        pre = Clock.currTime;
        plugin.persistentWorkerTid.send(url, authorisationHeader);
    }
    else
    {
        spawn(&queryTwitchImpl, url, authorisationHeader,
            plugin.bucket, plugin.state.connSettings.caBundleFile);
    }

    delay(plugin, plugin.approximateQueryTime.msecs, Yes.yield);
    immutable response = waitForQueryResponse(plugin, url,
        plugin.twitchBotSettings.singleWorkerThread);

    scope(exit)
    {
        synchronized //()
        {
            // Always remove, otherwise there'll be stale entries
            plugin.bucket.remove(url);
        }
    }

    if (plugin.twitchBotSettings.singleWorkerThread)
    {
        immutable post = Clock.currTime;
        immutable diff = (post - pre);
        immutable msecs_ = diff.total!"msecs";
        plugin.averageApproximateQueryTime(msecs_);
    }
    else
    {
        plugin.averageApproximateQueryTime(response.msecs);
    }

    if (response.code == 2)
    {
        throw new TwitchQueryException(response.error, response.str, response.error, response.code);
    }
    else if (!response.str.length)
    {
        throw new TwitchQueryException("Empty response", response.str,
            response.error, response.code);
    }
    else if ((response.code >= 500) && !recursing)
    {
        return queryTwitch(plugin, url, authorisationHeader, Yes.recursing);
    }
    else if (response.code >= 400)
    {
        import lu.string : unquoted;
        import std.format : format;
        import std.json : parseJSON;

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
            errorJSON["message"].str.unquoted);

        throw new TwitchQueryException(message, response.str, response.error, response.code);
    }

    return response;
}


// queryTwitchImpl
/++
    Sends a HTTP GET request to the passed URL, and "returns" the response by
    adding it to the shared `bucket` associative array.

    Callers can as such spawn this function as a new thread and asynchronously
    monitor the `bucket` for when the results arrive.

    Example:
    ---
    immutable url = "https://api.twitch.tv/helix/some/api/url";

    spawn&(&queryTwitchImpl, url, plugin.authorizationBearer, plugin.bucket, caBundleFile);
    delay(plugin, plugin.approximateQueryTime.msecs, Yes.yield);
    immutable response = waitForQueryResponse(plugin, url);
    // response.str is the response body
    ---

    Params:
        url = URL address to look up.
        authToken = Authorisation token HTTP header to pass.
        bucket = The shared associative array to put the results in, response
            values keyed by URL.
        caBundleFile = Path to a `cacert.pem` SSL certificate bundle.
 +/
void queryTwitchImpl(
    const string url,
    const string authToken,
    shared QueryResponse[string] bucket,
    const string caBundleFile)
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
        headers = [ "Client-ID: " ~ TwitchBotPlugin.clientID ];
        client.setClientCertificate(caBundleFile, caBundleFile);
    }

    client.authorization = authToken;

    QueryResponse response;
    auto pre = Clock.currTime;

    auto req = client.request(Uri(url));
    req.requestParameters.headers = headers;
    auto res = req.waitForCompletion();

    if (res.code.among!(301, 302, 307, 308) && res.location.length)
    {
        // Moved
        pre = Clock.currTime;
        req = client.request(Uri(res.location));
        req.requestParameters.headers = headers;
        res = req.waitForCompletion();
    }

    response.code = res.code;
    response.error = res.codeText;
    response.str = res.contentText;

    immutable post = Clock.currTime;
    immutable delta = (post - pre);
    response.msecs = delta.total!"msecs";

    synchronized //()
    {
        bucket[url] = response;  // empty str if code >= 400
    }
}


// getTwitchEntity
/++
    By following a passed URL, queries Twitch servers for an entity (user or channel).

    Params:
        plugin = The current [kameloso.plugins.twitchbot.base.TwitchBotPlugin|TwitchBotPlugin].
        url = The URL to follow.

    Returns:
        A singular user or channel regardless of how many were asked for in the URL.
        If nothing was found, an empty [std.json.JSONValue|JSONValue].init is
        returned instead.
 +/
JSONValue getTwitchEntity(TwitchBotPlugin plugin, const string url)
in (Fiber.getThis, "Tried to call `getTwitchEntity` from outside a Fiber")
{
    import std.json : JSONType, parseJSON;

    immutable response = queryTwitch(plugin, url, plugin.authorizationBearer);
    immutable responseJSON = parseJSON(response.str);

    if (responseJSON.type != JSONType.object)
    {
        return JSONValue.init;
    }
    else if (const dataJSON = "data" in responseJSON)
    {
        if ((dataJSON.type == JSONType.array) ||
            (dataJSON.array.length == 1))
        {
            return dataJSON.array[0];
        }
    }

    return JSONValue.init;
}


// getChatters
/++
    Get the JSON representation of everyone currently in a broadcaster's channel.

    It is not updated in realtime, so it doesn't make sense to call this often.

    Params:
        plugin = The current [kameloso.plugins.twitchbot.base.TwitchBotPlugin|TwitchBotPlugin].
        broadcaster = The broadcaster to look up chatters for.

    Returns:
        A [std.json.JSONValue|JSONValue] with "`chatters`" and "`chatter_count`" keys.
        If nothing was found, an empty [std.json.JSONValue|JSONValue].init is
        returned instead.
 +/
JSONValue getChatters(TwitchBotPlugin plugin, const string broadcaster)
in (Fiber.getThis, "Tried to call `getChatters` from outside a Fiber")
{
    import std.conv : text;
    import std.json : JSONType, parseJSON;

    immutable chattersURL = text("https://tmi.twitch.tv/group/user/", broadcaster, "/chatters");

    immutable response = queryTwitch(plugin, chattersURL, plugin.authorizationBearer);
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
        return JSONValue.init;
    }
    else if (const chattersJSON = "chatters" in responseJSON)
    {
        if (chattersJSON.type != JSONType.object)
        {
            return JSONValue.init;
        }
    }

    // Don't return `chatterJSON`, as we would lose "chatter_count".
    return responseJSON;
}


// getValidation
/++
    Validates the current access key, retrieving information about it.

    Params:
        plugin = The current [kameloso.plugins.twitchbot.base.TwitchBotPlugin|TwitchBotPlugin].

    Returns:
        A [std.json.JSONValue|JSONValue] with the validation information JSON of the
        current authorisation header/client ID pair.

    Throws:
        [TwitchQueryException] on failure.
 +/
JSONValue getValidation(TwitchBotPlugin plugin)
in (Fiber.getThis, "Tried to call `getValidation` from outside a Fiber")
{
    import lu.string : beginsWith;
    import std.json : JSONType, JSONValue, parseJSON;

    enum url = "https://id.twitch.tv/oauth2/validate";

    // Validation needs an "Authorization: OAuth xxx" header, as opposed to the
    // "Authorization: Bearer xxx" used everywhere else.
    immutable pass = plugin.state.bot.pass.beginsWith("oauth:") ?
        plugin.state.bot.pass[6..$] :
        plugin.state.bot.pass;
    immutable authorizationHeader = "OAuth " ~ pass;

    immutable response = queryTwitch(plugin, url, authorizationHeader);
    immutable validationJSON = parseJSON(response.str);

    if ((validationJSON.type != JSONType.object) || ("client_id" !in validationJSON))
    {
        throw new TwitchQueryException("Failed to validate Twitch authorisation " ~
            "token; unknown JSON", response.str, response.error, response.code);
    }

    return validationJSON;
}


// getFollows
/++
    Fetches a list of all follows of the passed channel and caches them in
    the channel's entry in [kameloso.plugins.twitchbot.base.TwitchBotPlugin.rooms|TwitchBotPlugin.rooms].

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitchbot.base.TwitchBotPlugin|TwitchBotPlugin].
        id = The string identifier for the channel.

    Returns:
        An associative array of [std.json.JSONValue|JSONValue]s keyed by nickname string,
        containing follows.
 +/
JSONValue[string] getFollows(TwitchBotPlugin plugin, const string id)
in (Fiber.getThis, "Tried to call `getFollows` from outside a Fiber")
{
    import std.conv : text;
    import std.json : JSONValue, parseJSON;
    import core.thread : Fiber;

    immutable url = "https://api.twitch.tv/helix/users/follows?to_id=" ~ id;

    JSONValue[string] allFollows;
    long total;
    string after;

    do
    {
        immutable paginatedURL = after.length ?
            text(url, "&after=", after) : url;

        immutable response = queryTwitch(plugin, paginatedURL, plugin.authorizationBearer);
        immutable followsJSON = parseJSON(response.str);
        const cursor = "cursor" in followsJSON["pagination"];

        if (!total) total = followsJSON["total"].integer;

        foreach (thisFollowJSON; followsJSON["data"].array)
        {
            allFollows[thisFollowJSON["from_id"].str] = thisFollowJSON;
        }

        after = ((allFollows.length != total) && cursor) ? cursor.str : string.init;
    }
    while (after.length);

    return allFollows;
}


// averageApproximateQueryTime
/++
    Given a query time measurement, calculate a new approximate query time based on
    the weighted averages of the old value and said new measurement.

    The old value is given a weight of
    [kameloso.plugins.twitchbot.base.TwitchBotPlugin.approximateQueryAveragingWeight|approximateQueryAveragingWeight]
    and the new measurement a weight of 1. Additionally the measurement is padded by
    [kameloso.plugins.twitchbot.base.TwitchBotPlugin.approximateQueryMeasurementPadding|approximateQueryMeasurementPadding]
    to be on the safe side.

    Params:
        plugin = The current [kameloso.plugins.twitchbot.base.TwitchBotPlugin|TwitchBotPlugin].
        responseMsecs = The new measurement of how many milliseconds the last
            query took to complete.
 +/
void averageApproximateQueryTime(TwitchBotPlugin plugin, const long responseMsecs)
{
    import std.algorithm.comparison : min;

    enum maxDeltaToResponse = 1000;

    immutable current = plugin.approximateQueryTime;
    alias weight = plugin.approximateQueryAveragingWeight;
    alias padding = plugin.approximateQueryMeasurementPadding;
    immutable responseAdjusted = min(responseMsecs, (current + maxDeltaToResponse));
    immutable average = ((weight * current) + (responseAdjusted + padding)) / (weight + 1);

    /*import std.stdio;
    writefln("time:%s | response: %d~%d (+%d) | new average:%s",
        current, responseMsecs, responseAdjusted, padding, average);*/

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
    immutable url = "https://api.twitch.tv/helix/users?login=zorael";

    if (plugin.twitchBotSettings.singleWorkerThread)
    {
        plugin.persistentWorkerTid.send(url, plugin.authorizationBearer);
    }
    else
    {
        spawn(&queryTwitchImpl, url, plugin.authorizationBearer,
            plugin.bucket, plugin.state.connSettings.caBundleFile);
    }

    delay(plugin, plugin.approximateQueryTime.msecs, Yes.yield);
    immutable response = waitForQueryResponse(plugin, url);
    // response.str is the response body
    ---

    Params:
        plugin = The current [kameloso.plugins.twitchbot.base.TwitchBotPlugin|TwitchBotPlugin].
        url = The URL that was queried prior to calling this function. Must match precisely.
        leaveTimingAlone = Whether or not to adjust the approximate query time.
            Enabled by default but can be disabled if the caller wants to do it.

    Returns:
        A [QueryResponse] as constructed by other parts of the program.
 +/
QueryResponse waitForQueryResponse(TwitchBotPlugin plugin,
    const string url,
    const bool leaveTimingAlone = true)
in (Fiber.getThis, "Tried to call `waitForQueryResponse` from outside a Fiber")
{
    import kameloso.constants : Timeout;
    import kameloso.plugins.common.delayawait : delay;
    import std.datetime.systime : Clock;
    import core.time : msecs;

    immutable startTime = Clock.currTime.toUnixTime;
    shared QueryResponse* response;
    double accumulatingTime = plugin.approximateQueryTime;

    while (!response)
    {
        response = url in plugin.bucket;

        if (!response)
        {
            immutable now = Clock.currTime.toUnixTime;

            if ((now - startTime) >= Timeout.httpGET)
            {
                response = new shared QueryResponse;
                break;
            }

            // Miss; fired too early, there is no response available yet
            accumulatingTime *= plugin.approximateQueryGrowthMultiplier;
            alias divisor = plugin.approximateQueryRetryTimeDivisor;
            immutable briefWait = cast(long)(accumulatingTime / divisor);
            delay(plugin, briefWait.msecs, Yes.yield);
            continue;
        }

        // Make the new approximate query time a weighted average
        if (!leaveTimingAlone) plugin.averageApproximateQueryTime(response.msecs);
        plugin.bucket.remove(url);
    }

    return *response;
}


// TwitchQueryException
/++
    Exception, to be thrown when an API query to the Twitch servers failed,
    for whatever reason.

    It is a normal [object.Exception|Exception] but with attached metadata.
 +/
final class TwitchQueryException : Exception
{
@safe:
    /// The response body that was received.
    string responseBody;

    /// The message of any thrown exception, if the query failed.
    string error;

    /// The HTTP code that was received.
    uint code;

    /++
        Create a new [TwitchQueryException], attaching a response body and a
        HTTP return code.
     +/
    this(const string message,
        const string responseBody,
        const string error,
        const uint code,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        this.responseBody = responseBody;
        this.error = error;
        this.code = code;
        super(message, file, line, nextInChain);
    }

    /++
        Create a new [TwitchQueryException], without attaching anything.
     +/
    this(const string message,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }
}
