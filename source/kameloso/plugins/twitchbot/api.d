/++
    Functions for accessing the Twitch API. For internal use.

    See_Also:
        [kameloso.plugins.twitchbot.base|twitchbot.base]
        [kameloso.plugins.twitchbot.keygen|twitchbot.keygen]
        [kameloso.plugins.twitchbot.keygen|twitchbot.google]
        [kameloso.plugins.twitchbot.keygen|twitchbot.spotify]
 +/
module kameloso.plugins.twitchbot.api;

version(TwitchSupport):
version(WithTwitchBotPlugin):

private:

import kameloso.plugins.twitchbot.base;

import arsd.http2 : HttpVerb;
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
    import kameloso.common : expandTags, logger;
    import kameloso.logger : LogLevel;

    try
    {
        dg();
    }
    catch (TwitchQueryException e)
    {
        import kameloso.constants : MagicErrorStrings;

        // Hack; don't spam about failed queries if we already know SSL doesn't work
        if (!TwitchBotPlugin.useAPIFeatures) return;

        immutable message = (e.error == MagicErrorStrings.sslLibraryNotFound) ?
            MagicErrorStrings.sslLibraryNotFoundRewritten :
            e.msg;

        enum pattern = "Failed to query Twitch: <l>%s</> <t>(%s) </>(<t>%d</>)";
        logger.errorf(pattern.expandTags(LogLevel.error), message, e.error, e.code);

        if ((e.code == 401) && (e.error == "Unauthorized"))
        {
            import kameloso.messaging : Message;
            import kameloso.thread : ThreadMessage;
            import std.concurrency : send = prioritySend;

            // API key expired.
            // Copy/paste kameloso.messaging.quit, since we don't have access to plugin.state

            enum apiPattern = "Your Twitch API key has expired. " ~
                "Run the program with <l>--set twitch.keygen</> to generate a new one.";
            logger.error(apiPattern.expandTags(LogLevel.error));

            Message m;

            m.event.type = IRCEvent.Type.QUIT;
            m.event.content = "Twitch API key expired";
            m.properties |= (Message.Property.forced | Message.Property.priority);

            (cast()TwitchBotPlugin.mainThread).send(m);
        }
    }
    catch (Exception e)
    {
        enum pattern = "Unforeseen exception thrown when querying Twitch: <l>%s";
        logger.errorf(pattern.expandTags(LogLevel.error), e.msg);
        version(PrintStacktraces) logger.trace(e);
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
void persistentQuerier(shared QueryResponse[int] bucket, const string caBundleFile)
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
            (int id, string url, string authToken, HttpVerb verb,
                immutable(ubyte)[] body_, string contentType) scope
            {
                version(BenchmarkHTTPRequests)
                {
                    import std.datetime.systime : Clock;
                    import std.stdio;
                    immutable pre = Clock.currTime;
                }

                sendHTTPRequestImpl(id, url, authToken, bucket, caBundleFile,
                    verb, cast(ubyte[])body_, contentType);

                version(BenchmarkHTTPRequests)
                {
                    immutable post = Clock.currTime;
                    writefln("%s (%s)", post-pre, url);
                }
            },
            (int id, string url, string authToken) scope
            {
                // Shorthand
                sendHTTPRequestImpl(id, url, authToken, bucket, caBundleFile,
                    HttpVerb.GET, null, string.init);
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
        plugin = The current [kameloso.plugins.twitchbot.base.TwitchBotPlugin|TwitchBotPlugin].
        url = The URL to query.
        authorisationHeader = Authorisation HTTP header to pass.
        verb = What HTTP verb to pass.
        body_ = Request body to send in case of verbs like `POST` and `PATCH`.
        contentType = "Content-Type" HTTP header to pass.
        id = Numerical ID to use instead of generating a new one.
        recursing = Whether or not this is a recursive call and another one should
            not be attempted.

    Returns:
        The [QueryResponse] that was discovered while monitoring the `bucket`
        as having been received from the server.

    Throws:
        [TwitchQueryException] if there were unrecoverable errors with the body
        describing it being in JSON Form.

        [core.object.Exception|Exception] if there were unrecoverable errors but
        where the sent body was not in JSON form.
 +/
QueryResponse sendHTTPRequest(TwitchBotPlugin plugin,
    const string url,
    const string authorisationHeader,
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
        import kameloso.common : Tint, logger;
        logger.trace("GET: ", Tint.info, url);
    }

    plugin.state.mainThread.prioritySend(ThreadMessage.shortenReceiveTimeout());

    immutable pre = Clock.currTime;
    if (id == -1) id = getUniqueNumericalID(plugin.bucket);
    plugin.persistentWorkerTid.send(id, url, authorisationHeader, verb, body_.idup, contentType);

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
        throw new TwitchQueryException(response.error, response.str, response.error, response.code);
    }
    else if (response.code == 0) //(!response.str.length)
    {
        throw new TwitchQueryException("Empty response", response.str,
            response.error, response.code);
    }
    else if ((response.code >= 500) && !recursing)
    {
        return sendHTTPRequest(plugin, url, authorisationHeader, verb,
            body_, contentType, id, Yes.recursing);
    }
    else if (response.code >= 400)
    {
        import std.format : format;
        import std.json : JSONException;

        try
        {
            import lu.string : unquoted;
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
        catch (JSONException)
        {
            enum pattern = `%3d: "%s"`;
            immutable message = pattern.format(response.code, response.str);
            throw new Exception(message);
        }
    }

    return response;
}


// sendHTTPRequestImpl
/++
    Sends a HTTP request of the passed verb to the passed URL, and "returns" the
    response by adding it to the shared `bucket` associative array.

    Callers can as such spawn this function as a new or separate thread and
    asynchronously monitor the `bucket` for when the results arrive.

    Example:
    ---
    immutable url = "https://api.twitch.tv/helix/some/api/url";

    spawn&(&sendHTTPRequestImpl, 12345, url, plugin.authorizationBearer, plugin.bucket, caBundleFile);
    delay(plugin, plugin.approximateQueryTime.msecs, Yes.yield);
    immutable response = waitForQueryResponse(plugin, 12345);
    // response.str is the response body
    ---

    Params:
        id = Unique ID to use as key when storing the returned
            value in `bucket`.
        url = URL address to look up.
        authToken = Authorisation token HTTP header to pass.
        bucket = The shared associative array to put the results in, response
            values keyed by URL.
        caBundleFile = Path to a `cacert.pem` SSL certificate bundle.
        verb = What HTTP verb to pass.
        body_ = Request body to send in case of verbs like `POST` and `PATCH`.
        contentType = "Content-Type" HTTP header to use.
 +/
void sendHTTPRequestImpl(
    const int id,
    const string url,
    const string authToken,
    shared QueryResponse[int] bucket,
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
        headers = [ "Client-ID: " ~ TwitchBotPlugin.clientID ];
        if (caBundleFile.length) client.setClientCertificate(caBundleFile, caBundleFile);
    }

    client.authorization = authToken;

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

    synchronized //()
    {
        bucket[id] = response;  // empty str if code >= 400
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

    try
    {
        immutable response = sendHTTPRequest(plugin, url, plugin.authorizationBearer);
        immutable responseJSON = parseJSON(response.str);

        if (responseJSON.type != JSONType.object)
        {
            return JSONValue.init;
        }
        else if (const dataJSON = "data" in responseJSON)
        {
            if ((dataJSON.type == JSONType.array) &&
                (dataJSON.array.length == 1))
            {
                return dataJSON.array[0];
            }
        }

        return JSONValue.init;
    }
    catch (TwitchQueryException e)
    {
        return JSONValue.init;
    }
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
        return JSONValue.init;
    }
    else if (const chattersJSON = "chatters" in responseJSON)
    {
        if (chattersJSON.type != JSONType.object)
        {
            return JSONValue.init;
        }
    }

    // Don't return `chattersJSON`, as we would lose "chatter_count".
    return responseJSON;
}


// getValidation
/++
    Validates the current access key, retrieving information about it.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

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

    immutable response = sendHTTPRequest(plugin, url, authorizationHeader);
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
    import std.json : JSONType;

    immutable url = "https://api.twitch.tv/helix/users/follows?to_id=" ~ id;
    JSONValue[string] allFollowsJSON;
    const entitiesArrayJSON = getMultipleTwitchEntities(plugin, url);

    if (entitiesArrayJSON.type != JSONType.array)
    {
        return allFollowsJSON;  // init
    }

    foreach (entityJSON; entitiesArrayJSON.array)
    {
        immutable key = entityJSON.object["from_id"].str;
        allFollowsJSON[key] = null;
        allFollowsJSON[key] = entityJSON;
    }

    return allFollowsJSON;
}


// getMultipleTwitchEntities
/++
    By following a passed URL, queries Twitch servers for an array of entities
    (such as users or channels).

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitchbot.base.TwitchBotPlugin|TwitchBotPlugin].
        url = The URL to follow.

    Returns:
        A [std.json.JSONValue|JSONValue] of type `array` containing all returned
        entities, over all paginated queries.
 +/
JSONValue getMultipleTwitchEntities(TwitchBotPlugin plugin, const string url)
in (Fiber.getThis, "Tried to call `getMultipleTwitchEntities` from outside a Fiber")
{
    import std.json : JSONValue, parseJSON;

    JSONValue allEntitiesJSON;
    allEntitiesJSON = null;
    allEntitiesJSON.array = null;
    long total;
    string after;

    do
    {
        try
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
        catch (TwitchQueryException e)
        {
            return JSONValue.init;
        }
    }
    while (after.length);

    return allEntitiesJSON;
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
    immutable id = getUniqueNumericalID(plugin.bucket);
    immutable url = "https://api.twitch.tv/helix/users?login=zorael";
    plugin.persistentWorkerTid.send(id, url, plugin.authorizationBearer);

    delay(plugin, plugin.approximateQueryTime.msecs, Yes.yield);
    immutable response = waitForQueryResponse(plugin, id, url);
    // response.str is the response body
    ---

    Params:
        plugin = The current [kameloso.plugins.twitchbot.base.TwitchBotPlugin|TwitchBotPlugin].
        id = Numerical ID to use as key when storing the response in the bucket AA.
        leaveTimingAlone = Whether or not to adjust the approximate query time.
            Enabled by default but can be disabled if the caller wants to do it.

    Returns:
        A [QueryResponse] as constructed by other parts of the program.
 +/
QueryResponse waitForQueryResponse(TwitchBotPlugin plugin, const int id)
in (Fiber.getThis, "Tried to call `waitForQueryResponse` from outside a Fiber")
{
    import kameloso.constants : Timeout;
    import kameloso.plugins.common.delayawait : delay;
    import std.datetime.systime : Clock;
    import core.time : msecs;

    immutable startTime = Clock.currTime.toUnixTime;
    shared QueryResponse* response;
    double accumulatingTime = plugin.approximateQueryTime;

    do
    {
        response = id in plugin.bucket;

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
        plugin.averageApproximateQueryTime(response.msecs);
        plugin.bucket.remove(id);
    }
    while (!response);

    return *response;
}


// getTwitchUser
/++
    Fetches information about a Twitch user and returns it in the form of a
    Voldemort struct with nickname, display name and account ID (as string) members.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitchbot.base.TwitchBotPlugin|TwitchBotPlugin].
        givenName = Name of user to look up.
        searchByDisplayName = Whether or not to also attempt to look up `givenName`
            as a display name.

    Returns:
        Voldemort aggregate struct with `nickname`, `displayName` and `idString` members.
 +/
auto getTwitchUser(
    TwitchBotPlugin plugin,
    const string givenName,
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
    immutable userURL = "https://api.twitch.tv/helix/users?login=" ~ givenName;
    immutable userJSON = getTwitchEntity(plugin, userURL);

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


// getTwitchGame
/++
    Fetches information about a game; notably its numerical ID.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitchbot.base.TwitchBotPlugin|TwitchBotPlugin].
        name = Name of game to look up.

    Returns:
        Voldemort aggregate struct with `id` and `name` members.
 +/
auto getTwitchGame(TwitchBotPlugin plugin, const string name)
in (Fiber.getThis, "Tried to call `getTwitchGame` from outside a Fiber")
{
    static struct Game
    {
        string id;
        string name;
    }

    /*
    {
        "id": "512953",
        "name": "Elden Ring",
        "box_art_url": "https://static-cdn.jtvnw.net/ttv-boxart/512953_IGDB-{width}x{height}.jpg"
    }
    */

    immutable gameURL = "https://api.twitch.tv/helix/games?name=" ~ name;
    immutable gameJSON = getTwitchEntity(plugin, gameURL);

    return (gameJSON == JSONValue.init) ?
        Game.init :
        Game(gameJSON["id"].str, gameJSON["name"].str);
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

        //bucket[id] = QueryResponse.init;  // reserve it
    }

    return id;
}


// modifyChannel
/++
    Modifies a channel's title or currently played game.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitchbot.base.TwitchBotPlugin|TwitchBotPlugin].
        channelName = Name of channel to modify.
        title = Optional channel title to set.
        gameID = Optional game ID to set the channel as playing.
 +/
void modifyChannel(
    TwitchBotPlugin plugin,
    const string channelName,
    const string title,
    const string gameID)
in (Fiber.getThis, "Tried to call `modifyChannel` from outside a Fiber")
{
    import std.array : Appender;

    const room = channelName in plugin.rooms;
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

    cast(void)sendHTTPRequest(plugin, url, authorizationBearer,
        HttpVerb.PATCH, cast(ubyte[])sink.data, "application/json");
}


// getBroadcasterAuthorisation
/++
    Returns a broadcaster-level "Bearer" authorisation token for a channel,
    where such exist.

    Params:
        plugin = The current [kameloso.plugins.twitchbot.base.TwitchBotPlugin|TwitchBotPlugin].
        channelName = Name of channel to return token for.

    Returns:
        A "Bearer" OAuth token string for use in HTTP headers.

    Throws:
        [core.object.Exception|Exception] if there were no broadcaster key for
        the supplied channel in the secrets storage.
 +/
auto getBroadcasterAuthorisation(TwitchBotPlugin plugin, const string channelName)
{
    static string[string] authorizationByChannel;

    auto authorizationBearer = channelName in authorizationByChannel;

    if (!authorizationBearer)
    {
        if (auto creds = channelName in plugin.secretsByChannel)
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
        throw new Exception("Missing broadcaster key");
    }

    return *authorizationBearer;
}


// startCommercial
/++
    Starts a commercial in the specified channel.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitchbot.base.TwitchBotPlugin|TwitchBotPlugin].
        channelName = Name of channel to run commercials for.
        lengthString = Length to play the commercial for, as a string.
 +/
void startCommercial(TwitchBotPlugin plugin, const string channelName, const string lengthString)
in (Fiber.getThis, "Tried to call `startCommercial` from outside a Fiber")
{
    import std.format : format;

    enum url = "https://api.twitch.tv/helix/channels/commercial";
    enum pattern = `
{
    "broadcaster_id": "%s",
    "length": %s
}`;

    const room = channelName in plugin.rooms;
    immutable body_ = pattern.format(room.id, lengthString);
    immutable authorizationBearer = getBroadcasterAuthorisation(plugin, channelName);

    cast(void)sendHTTPRequest(plugin, url, authorizationBearer,
        HttpVerb.POST, cast(ubyte[])body_, "application/json");
}


// getPolls
/++
    Fetches information about polls in the specified channel. If an ID string is
    supplied, it will be included in the query, otherwise all `"ACTIVE"` polls
    are included in the returned JSON.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitchbot.base.TwitchBotPlugin|TwitchBotPlugin].
        channelName = Name of channel to fetch polls for.
        idString = ID of a specific poll to get.

    Returns:
        A [std.json.JSONValue|JSONValue] [std.json.JSONType.array|array] with
        all the matched polls.
 +/
auto getPolls(
    TwitchBotPlugin plugin,
    const string channelName,
    const string idString = string.init)
in (Fiber.getThis, "Tried to call `getPolls` from outside a Fiber")
{
    import std.json : JSONType, parseJSON;

    enum baseURL = "https://api.twitch.tv/helix/polls?broadcaster_id=";
    const room = channelName in plugin.rooms;
    immutable authorizationBearer = getBroadcasterAuthorisation(plugin, channelName);

    string url = baseURL ~ room.id;  // mutable;
    if (idString.length) url ~= "id=" ~ idString;

    JSONValue allPollsJSON;
    allPollsJSON = null;
    allPollsJSON.array = null;
    string after;

    do
    {
        immutable paginatedURL = after.length ? (url ~ "&after=" ~ after) : url;
        immutable response = sendHTTPRequest(plugin, paginatedURL, authorizationBearer,
            HttpVerb.GET, cast(ubyte[])null, "application/json");
        immutable responseJSON = parseJSON(response.str);

        if ((responseJSON.type != JSONType.object) ||
            ("data" !in responseJSON) ||
            responseJSON["data"].type == JSONType.null_)
        {
            // Invalid response in some way
            break;
        }

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

    return allPollsJSON;
}


// createPoll
/++
    Creates a Twitch poll in the specified channel.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitchbot.base.TwitchBotPlugin|TwitchBotPlugin].
        channelName = Name of channel to create the poll in.
        title = Poll title.
        durationString = How long the poll should run for in seconds (as a string).
        choices = A string array of poll choices.

    Returns:
        A [std.json.JSONValue|JSONValue] [std.json.JSONType.array|array] with
        the response returned when creating the poll. On failure, an empty
        [std.json.JSONValue|JSONValue] is instead returned.
 +/
auto createPoll(
    TwitchBotPlugin plugin,
    const string channelName,
    const string title,
    const string durationString,
    const string[] choices)
in (Fiber.getThis, "Tried to call `createPoll` from outside a Fiber")
{
    import std.array : Appender, replace;
    import std.format : format;
    import std.json : JSONType, parseJSON;

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

    const room = channelName in plugin.rooms;
    immutable escapedTitle = title.replace(`"`, `\"`);
    immutable body_ = pattern.format(room.id, escapedTitle, sink.data, durationString);
    immutable authorizationBearer = getBroadcasterAuthorisation(plugin, channelName);

    immutable response = sendHTTPRequest(plugin, url, authorizationBearer,
        HttpVerb.POST, cast(ubyte[])body_, "application/json");

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

    if ((responseJSON.type != JSONType.object) || ("data" !in responseJSON))
    {
        // Invalid response in some way
        return JSONValue.init;
    }

    return responseJSON["data"];
}


// endPoll
/++
    Ends a Twitch poll, putting it in either a `"TERMINATED"` or `"ARCHIVED"` state.

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitchbot.base.TwitchBotPlugin|TwitchBotPlugin].
        channelName = Name of channel whose poll to end.
        voteID = ID of the specific vote to end.
        terminate = If set, ends the poll by putting it in a `"TERMINATED"` state.
            If unset, ends it in an `"ARCHIVED"` way.

    Returns:
        A [std.json.JSONValue|JSONValue] [std.json.JSONType.array|array] with
        the response returned when ending the poll. On failure, an empty
        [std.json.JSONValue|JSONValue] is instead returned.
 +/
auto endPoll(
    TwitchBotPlugin plugin,
    const string channelName,
    const string voteID,
    const Flag!"terminate" terminate)
in (Fiber.getThis, "Tried to call `endPoll` from outside a Fiber")
{
    import std.format : format;
    import std.json : JSONType, parseJSON;

    enum url = "https://api.twitch.tv/helix/polls";
    enum pattern = `
{
    "broadcaster_id": "%s",
    "id": "%s",
    "status": "%s"
}`;

    const room = channelName in plugin.rooms;
    immutable status = terminate ? "TERMINATED" : "ARCHIVED";
    immutable body_ = pattern.format(room.id, voteID, status);
    immutable authorizationBearer = getBroadcasterAuthorisation(plugin, channelName);

    immutable response = sendHTTPRequest(plugin, url, authorizationBearer,
        HttpVerb.PATCH, cast(ubyte[])body_, "application/json");

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

    if ((responseJSON.type != JSONType.object) || ("data" !in responseJSON))
    {
        // Invalid response in some way
        return JSONValue.init;
    }

    return responseJSON["data"].array[0];
}
