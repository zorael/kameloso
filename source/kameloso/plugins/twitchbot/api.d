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

    Possibly best used on Windows where spawning new threads is comparatively expensive
    compared to on Posix platforms.

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
            (int id, string url, string authToken, HttpVerb verb, immutable(ubyte)[] body_, string contentType) scope
            {
                sendHTTPRequestImpl(id, url, authToken, bucket, caBundleFile, verb, cast(ubyte[])body_, contentType);
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
                // It's technically an error but do nothing for now
                import std.stdio;
                writeln("Twitch worker received unknown Variant: ", v);
            }
        );
    }
}


// sendHTTPRequest
/++
    Wraps [sendHTTPRequestImpl] by either starting it in a subthread, or by calling it normally.

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
        id = Numerical ID to use instead of generating a new one.
        recursing = Whether or not this is a recursive call and another one should
            not be attempted.

    Returns:
        The [QueryResponse] that was discovered while monitoring the `bucket`
        as having been received from the server.

    Throws:
        [TwitchQueryException] if there were unrecoverable errors.
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
    Sends a HTTP GET request to the passed URL, and "returns" the response by
    adding it to the shared `bucket` associative array.

    Callers can as such spawn this function as a new thread and asynchronously
    monitor the `bucket` for when the results arrive.

    Example:
    ---
    immutable url = "https://api.twitch.tv/helix/some/api/url";

    spawn&(&sendHTTPRequestImpl, url, plugin.authorizationBearer, plugin.bucket, caBundleFile);
    delay(plugin, plugin.approximateQueryTime.msecs, Yes.yield);
    immutable response = waitForQueryResponse(plugin, url);
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
        body_ = Body contents in `POST`/`PATCH` requests.
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
    req.requestParameters.headers = headers;
    //req.requestParameters.contentType = contentType;  // necessary?
    auto res = req.waitForCompletion();

    if (res.code.among!(301, 302, 307, 308) && res.location.length)
    {
        // Moved
        foreach (immutable i; 0..5)
        {
            pre = Clock.currTime;
            req = client.request(Uri(res.location), verb, body_, contentType);
            req.requestParameters.headers = headers;
            //req.requestParameters.contentType = contentType;  // as above
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
    immutable url = "https://api.twitch.tv/helix/users?login=zorael";
    plugin.persistentWorkerTid.send(url, plugin.authorizationBearer);

    delay(plugin, plugin.approximateQueryTime.msecs, Yes.yield);
    immutable response = waitForQueryResponse(plugin, url);
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
QueryResponse waitForQueryResponse(TwitchBotPlugin plugin,
    const int id,
    const Flag!"leaveTimingAlone" leaveTimingAlone = Yes.leaveTimingAlone)
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
        if (!leaveTimingAlone) plugin.averageApproximateQueryTime(response.msecs);
        plugin.bucket.remove(id);
    }
    while (!response);

    return *response;
}


// getTwitchUser
/++
    Fetches information about a Twitch user and returns it in the form of a
    Voldemort struct with nickname, display name and account ID (as string) members.

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

    static string[string] authorizationByChannel;

    auto room = channelName in plugin.rooms;
    assert(room);
    immutable broadcasterIDString = room.id;

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

    immutable url = "https://api.twitch.tv/helix/channels?broadcaster_id=" ~ broadcasterIDString;

    Appender!(char[]) sink;
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

    cast(void)sendHTTPRequest(plugin, url, *authorizationBearer,
        HttpVerb.PATCH, cast(ubyte[])sink.data, "application/json");
}
