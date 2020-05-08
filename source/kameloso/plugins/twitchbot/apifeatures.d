/++
 +  Implementation of Twitch bot features using the Twitch API. For internal use.
 +
 +  The `dialect.defs.IRCEvent`-annotated handlers must be in the same module
 +  as the `kameloso.plugins.twitchbot.TwitchBotPlugin`, but these implementation
 +  functions can be offloaded here to limit module size a bit.
 +/
module kameloso.plugins.twitchbot.apifeatures;

version(WithPlugins):
version(TwitchSupport):
version(WithTwitchBotPlugin):
version(Web):

private:

import kameloso.plugins.twitchbot : TwitchBotPlugin, handleSelfjoin;

import kameloso.plugins.core;
import kameloso.common : logger;
import kameloso.messaging;
import dialect.defs;
import lu.json : JSONStorage;
import std.json : JSONValue;
import std.typecons : Flag, No, Yes;
import core.thread : Fiber;

package:


// QueryResponse
/++
 +  Embodies a response from a query to the Twitch servers. A string paired with
 +  a millisecond count of how long the query took.
 +
 +  This is used instead of a `std.typecons.Tuple` because it doesn't apparently
 +  work with `shared`.
 +/
struct QueryResponse
{
    /// Response body, may be several lines.
    string str;

    /// How long the query took, from issue to response.
    long msecs;

    /// The HTTP response code received.
    uint code;
}


// persistentQuerier
/++
 +  Persistent worker issuing Twitch API queries based on the concurrency messages
 +  sent to it.
 +
 +  Possibly best used on Windows where threads are comparatively expensive
 +  compared to Posix platforms.
 +
 +  Params:
 +      headers = `shared` HTTP headers to use when issuing the requests.
 +          Contains the API keys needed for Twitch to accept the queries.
 +      bucket = The shared associative array bucket to put the results in,
 +          response body values keyed by URL.
 +/
void persistentQuerier(shared string[string] headers, shared QueryResponse[string] bucket)
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
            (string url) scope
            {
                queryTwitchImpl(url, headers, bucket);
            },
            (ThreadMessage.Teardown) scope
            {
                halt = true;
            },
            (OwnerTerminated e) scope
            {
                halt = true;
            },
            (Variant v) scope
            {
                // It's technically an error but do nothing for now
            },
        );
    }
}


// queryTwitch
/++
 +  Wraps `queryTwitchImpl` by either starting it in a subthread, or having the
 +  worker start it.
 +
 +  Once the query returns, the response body is checked to see whether or not
 +  an error occured. If it did, an attempt to reset API keys is made and, if
 +  successful, the query is resent and the cycle repeated while taking care not
 +  to inifinitely loop. If not successful, it throws an exception and disables
 +  API features.
 +
 +  Note: Must be called from inside a `core.thread.Fiber`.
 +
 +  Params:
 +      plugin = The current `TwitchBotPlugin`.
 +      url = The URL to query.
 +      firstAttempt = Whether this is the first attempt or if it has recursed
 +          once after resetting API keys.
 +
 +  Returns:
 +      The `QueryResponse` that was discovered while monitoring the `bucket`
 +      as having been received from the server.
 +
 +  Throws:
 +      `object.Exception` if there were unrecoverable errors.
 +/
QueryResponse queryTwitch(TwitchBotPlugin plugin, const string url,
    const bool singleWorker, bool firstAttempt = true)
in (Fiber.getThis, "Tried to call `queryTwitch` from outside a Fiber")
{
    import kameloso.plugins.common : delay;
    import lu.string : beginsWith;
    import std.concurrency : send, spawn;
    import std.datetime.systime : Clock, SysTime;

    SysTime pre;

    if (singleWorker)
    {
        pre = Clock.currTime;
        plugin.persistentWorkerTid.send(url);
    }
    else
    {
        spawn(&queryTwitchImpl, url, plugin.headers, plugin.bucket);
    }

    delay(plugin, plugin.approximateQueryTime, Yes.msecs, Yes.yield);
    const response = waitForQueryResponse(plugin, url, singleWorker);

    if (singleWorker)
    {
        immutable post = Clock.currTime;
        immutable diff = (post - pre);
        immutable msecs = diff.total!"msecs";
        plugin.averageApproximateQueryTime(msecs);
    }
    else
    {
        plugin.averageApproximateQueryTime(response.msecs);
    }

    if (!response.str.length)
    {
        if (response.code >= 400)
        {
            import std.conv : to;
            throw new Exception("Failed to query Twitch; received code " ~ response.code.to!string);
        }
        else
        {
            throw new Exception("Failed to query Twitch; received empty string");
        }
    }
    else if (response.str.beginsWith(`{"err`))
    {
        // {"error":"Unauthorized","status":401,"message":"Must provide a valid Client-ID or OAuth token"}

        synchronized //()
        {
            // Always remove, otherwise there'll be stale entries
            plugin.bucket.remove(url);
        }

        if (firstAttempt)
        {
            immutable success = plugin.resetAPIKeys();
            if (success) return queryTwitch(plugin, url, singleWorker, false);  // <-- second attempt
            // Else drop down
        }

        throw new Exception("Failed to query Twitch; received error instead of data");
    }

    return response;
}


// queryTwitchImpl
/++
 +  Sends a HTTP GET request to the passed URL, and "returns" the response by
 +  adding it to the shared `bucket`.
 +
 +  Callers can as such spawn this function as a new thread and asynchronously
 +  monitor the `bucket` for when the results arrive.
 +
 +  Example:
 +  ---
 +  immutable url = "https://api.twitch.tv/helix/some/api/url";
 +
 +  spawn&(&queryTwitchImpl, url, plugin.headers, plugin.bucket);
 +  delay(plugin, plugin.approximateQueryTime, Yes.msecs, Yes.yield);
 +
 +  const response = waitForQueryResponse(plugin, url);
 +  // response.str is the response body
 +  ---
 +
 +  Params:
 +      url = URL address to look up.
 +      headers = `shared` HTTP headers to use when issuing the requests.
 +      bucket = The shared associative array to put the results in, response
 +          body values keyed by URL.
 +/
void queryTwitchImpl(const string url, shared string[string] headers,
    shared QueryResponse[string] bucket)
{
    import lu.traits : UnqualArray;
    import requests.request : Request;
    import std.datetime.systime : Clock;

    Request req;
    req.keepAlive = false;
    req.addHeaders(cast(UnqualArray!(typeof(headers)))headers);

    immutable pre = Clock.currTime;
    auto res = req.get(url);
    immutable post = Clock.currTime;

    QueryResponse response;
    response.code = res.code;
    immutable delta = (post - pre);
    response.msecs = delta.total!"msecs";

    if (res.code < 400)
    {
        response.str = cast(string)res.responseBody.data.idup;
    }

    synchronized //()
    {
        bucket[url] = response;  // empty str if code >= 400
    }
}


// onFollowAgeImpl
/++
 +  Implements "Follow Age", or the ability to query the server how long you have
 +  (or a specified user has) been a follower of the current channel.
 +
 +  Lookups are done asychronously in threads.
 +
 +  Note: Must be called from inside a `core.thread.Fiber`.
 +
 +  See_Also:
 +      kameloso.plugins.twitchbot.onFollowAge
 +/
void onFollowAgeImpl(TwitchBotPlugin plugin, const IRCEvent event)
in (Fiber.getThis, "Tried to call `onFollowAgeImpl` from outside a Fiber")
{
    import lu.string : nom, stripped;
    import std.conv : to;
    import std.json : JSONValue;
    import core.thread : Fiber;

    if (!plugin.useAPIFeatures) return;

    void dg()
    {
        string slice = event.content.stripped;  // mutable
        immutable nameSpecified = (slice.length > 0);

        string idString;
        string fromDisplayName;

        if (!nameSpecified)
        {
            // Assume the user is asking about itself
            idString = event.sender.id.to!string;
            fromDisplayName = event.sender.displayName;
        }
        else
        {
            immutable givenName = slice.nom!(Yes.inherit)(' ');

            if (const user = givenName in plugin.state.users)
            {
                // Stored user
                idString = user.id.to!string;
                fromDisplayName = user.displayName;
            }
            else
            {
                foreach (const user; plugin.state.users)
                {
                    if (user.displayName == givenName)
                    {
                        // Found user by displayName
                        idString = user.id.to!string;
                        fromDisplayName = user.displayName;
                        break;
                    }
                }

                if (!idString.length)
                {
                    // None on record, look up
                    immutable url = "https://api.twitch.tv/helix/users?login=" ~ givenName;

                    scope(failure) plugin.useAPIFeatures = false;

                    const response = queryTwitch(plugin, url,
                        plugin.twitchBotSettings.singleWorkerThread);

                    if (!response.str.length)
                    {
                        chan(plugin.state, event.channel, "Invalid user: " ~ givenName);
                        return;
                    }

                    // Hit
                    const user = parseUserFromResponse(cast()response.str);

                    if (user == JSONValue.init)
                    {
                        chan(plugin.state, event.channel, "Invalid user: " ~ givenName);
                        return;
                    }

                    idString = user["id"].str;
                    fromDisplayName = user["display_name"].str;
                }
            }
        }

        void reportFollowAge(const JSONValue followingUserJSON)
        {
            import kameloso.common : timeSince;
            import std.datetime.systime : Clock, SysTime;
            import std.format : format;

            static immutable string[12] months =
            [
                "January",
                "February",
                "March",
                "April",
                "May",
                "June",
                "July",
                "August",
                "September",
                "October",
                "November",
                "December",
            ];

            /*{
                "followed_at": "2019-09-13T13:07:43Z",
                "from_id": "20739840",
                "from_name": "mike_bison",
                "to_id": "22216721",
                "to_name": "Zorael"
            }*/

            immutable when = SysTime.fromISOExtString(followingUserJSON["followed_at"].str);
            immutable diff = Clock.currTime - when;
            immutable timeline = diff.timeSince;
            immutable datestamp = "%s %d"
                .format(months[cast(int)when.month-1], when.year);

            if (nameSpecified)
            {
                enum pattern = "%s has been a follower for %s, since %s.";
                chan(plugin.state, event.channel, pattern
                    .format(fromDisplayName, timeline, datestamp));
            }
            else
            {
                enum pattern = "You have been a follower for %s, since %s.";
                chan(plugin.state, event.channel, pattern.format(timeline, datestamp));
            }

        }

        assert(idString.length, "Empty idString despite lookup");

        // Identity ascertained; look up in cached list

        const follows = plugin.activeChannels[event.channel].follows;
        const thisFollow = idString in follows;

        if (thisFollow)
        {
            return reportFollowAge(*thisFollow);
        }

        // If we're here there were no matches.

        if (nameSpecified)
        {
            import std.format : format;

            enum pattern = "%s is currently not a follower.";
            chan(plugin.state, event.channel, pattern.format(fromDisplayName));
        }
        else
        {
            enum pattern = "You are currently not a follower.";
            chan(plugin.state, event.channel, pattern);
        }
    }

    Fiber fiber = new Fiber(&dg);
    fiber.call();
}


// getUserImpl
/++
 +  Synchronously queries the Twitch servers for information about a user,
 +  by name or by Twitch account ID number. Implementation function.
 +
 +  Params:
 +      plugin = The current `TwitchBotPlugin`.
 +      field = The field to access via the HTTP URL. Can be either "login"
 +          or "id".
 +      identifier = The identifier of type `field` to look up.
 +      firstAttempt = Whether this is the first attempt or if it has recursed
 +          once after resetting API keys.
 +
 +  Returns:
 +      A `std.json.JSONValue` with information regarding the user in question.
 +/
JSONValue getUserImpl(Identifier)(TwitchBotPlugin plugin, const string field,
    const Identifier identifier, bool firstAttempt = true)
in (((field == "login") || (field == "id")), "Invalid field supplied; expected " ~
    "`login` or `id`, got `" ~ field ~ '`')
{
    import lu.string : beginsWith;
    import lu.traits : UnqualArray;
    import requests.request : Request;
    import std.conv : to;
    import std.format : format;

    immutable url = "https://api.twitch.tv/helix/users?%s=%s"
        .format(field, identifier.to!string);  // String just passes through

    Request req;
    req.keepAlive = false;
    req.addHeaders(cast(UnqualArray!(typeof(plugin.headers)))plugin.headers);
    auto res = req.get(url);

    immutable data = cast(string)res.responseBody.data;

    if (data.beginsWith(`{"err`))
    {
        // {"error":"Unauthorized","status":401,"message":"Must provide a valid Client-ID or OAuth token"}

        if (firstAttempt)
        {
            immutable success = plugin.resetAPIKeys();
            if (success) return getUserImpl(plugin, field, identifier, false);  // <-- second attempt
            // Else drop down
        }

        throw new Exception("Failed to query Twitch; received error instead of data");
    }

    return parseUserFromResponse(data);
}


// parseUserFromResponse
/++
 +  Given a string response from the Twitch servers when queried for information
 +  on a user, verifies and parses the JSON, returning only that which relates
 +  to the user.
 +
 +  Note: Only deals with the first user, if several were returned.
 +
 +  Params:
 +      jsonString = String response as read from the server, in JSON form.
 +
 +  Returns:
 +      A `std.json.JSONValue` with information regarding the user in question.
 +/
JSONValue parseUserFromResponse(const string jsonString)
{
    import std.json : JSONType, JSONValue, parseJSON;

    auto json = parseJSON(jsonString);

    if ((json.type != JSONType.object) || ("data" !in json) ||
        (json["data"].type != JSONType.array) || (json["data"].array.length != 1))
    {
        return JSONValue.init;
    }

    return json["data"].array[0];
}


// getUserByLogin
/++
 +  Queries the Twitch servers for information about a user, by login.
 +  Wrapper function; merely calls `getUserImpl`. Overload that sends a query
 +  by account string name.
 +
 +  Params:
 +      plugin = The current `TwitchBotPlugin`.
 +      login = The Twitch login/account name to look up.
 +
 +  Returns:
 +      A `std.json.JSONValue` with information regarding the user in question.
 +
 +  See_Also:
 +      getUserByID
 +      getUserImpl
 +/
JSONValue getUserByLogin(TwitchBotPlugin plugin, const string login)
{
    return plugin.getUserImpl("login", login);
}


// getUserByID
/++
 +  Queries the Twitch servers for information about a user, by id.
 +  Wrapper function; merely calls `getUserImpl`. Overload that sends a query
 +  by id string.
 +
 +  Params:
 +      plugin = The current `TwitchBotPlugin`.
 +      id = The Twitch account ID to look up. Number in string form.
 +
 +  Returns:
 +      A `std.json.JSONValue` with information regarding the user in question.
 +
 +  See_Also:
 +      getUserByLogin
 +      getUserImpl
 +/
JSONValue getUserByID(TwitchBotPlugin plugin, const string id)
{
    return plugin.getUserImpl("id", id);
}


// getUserByID
/++
 +  Queries the Twitch servers for information about a user, by id.
 +  Wrapper function; merely calls `getUserImpl`. Overload that sends a query
 +  by id integer.
 +
 +  Params:
 +      plugin = The current `TwitchBotPlugin`.
 +      id = The Twitch account ID to look up. Number in integer form.
 +
 +  Returns:
 +      A `std.json.JSONValue` with information regarding the user in question.
 +
 +  See_Also:
 +      getUserByLogin
 +      getUserImpl
 +/
JSONValue getUserByID(TwitchBotPlugin plugin, const uint id)
{
    return plugin.getUserImpl("id", id);
}


// onRoomStateImpl
/++
 +  Records the room ID of a home channel, and queries the Twitch servers for
 +  the display name of its broadcaster. Implementation function.
 +
 +  See_Also:
 +      kameloso.plugins.twitchbot.onRoomState
 +/
void onRoomStateImpl(TwitchBotPlugin plugin, const IRCEvent event)
{
    import std.datetime.systime : Clock, SysTime;
    import std.json : JSONType, parseJSON;

    auto channel = event.channel in plugin.activeChannels;

    if (!channel)
    {
        // Race...
        plugin.handleSelfjoin(event.channel);
        channel = event.channel in plugin.activeChannels;
    }

    channel.roomID = event.aux;

    if (!plugin.useAPIFeatures) return;

    JSONValue broadcasterJSON;
    SysTime pre;
    SysTime post;

    try
    {
        pre = Clock.currTime;
        broadcasterJSON = getUserByID(plugin, event.aux);
        post = Clock.currTime;
    }
    catch (Exception e)
    {
        // Something is deeply wrong.
        logger.error("Failed to fetch broadcaster information; " ~
            "are the client-secret API keys and the authorization key file correctly set up?");
        logger.error("Disabling API features.");
        plugin.useAPIFeatures = false;
        return;
    }

    immutable delta = (post - pre);
    immutable responseTime = delta.total!"msecs";

    enum concurrencyPenalty = 300;  // Concurrency messages are just slower; compensate
    immutable withConcurrencyPenalty = plugin.twitchBotSettings.singleWorkerThread ?
        (responseTime + concurrencyPenalty) :
        responseTime;

    if (!plugin.approximateQueryTime)
    {
        // First reading. Pad here since averageApproximateQueryTime isn't doing it for us
        alias padding = plugin.approximateQueryMeasurementPadding;
        plugin.approximateQueryTime = withConcurrencyPenalty + padding;
    }
    else
    {
        plugin.averageApproximateQueryTime(withConcurrencyPenalty);
    }

    channel.broadcasterDisplayName = broadcasterJSON["display_name"].str;

    void dg()
    {
        channel.follows = plugin.cacheFollows(channel.roomID);
    }

    Fiber cacheFollowsFiber = new Fiber(&dg);
    cacheFollowsFiber.call();
}


// onEndOfMotdImpl
/++
 +  Sets up the worker thread at the end of MOTD. Implementation function.
 +
 +  Additionally initialises the shared bucket, sets the HTTP headers to use
 +  when querying information, and spawns the single worker thread if such is
 +  set up to be used.
 +
 +  See_Also:
 +      kameloso.plugins.twitchbot.onEndOfMotd
 +/
void onEndOfMotdImpl(TwitchBotPlugin plugin)
{
    import std.concurrency : Tid;

    if (!plugin.useAPIFeatures) return;

    if (!plugin.twitchBotSettings.clientKey.length ||
        !plugin.twitchBotSettings.secretKey.length)
    {
        logger.info("No Twitch Client ID API key pairs supplied in the configuration file. " ~
            "Some commands will not work.");
        plugin.useAPIFeatures = false;
        return;
    }

    if (!plugin.headers.length)
    {
        immutable success = plugin.resetAPIKeys();

        if (!success)
        {
            logger.error("Could not get a new authorization bearer token. " ~
                "Make sure that your client and secret keys are valid.");
            logger.info("Disabling API features due to key setup failure.");
            plugin.useAPIFeatures = false;
            return;
        }
    }

    if (plugin.bucket is null)
    {
        plugin.bucket[string.init] = QueryResponse.init;
        plugin.bucket.remove(string.init);
    }

    if (plugin.twitchBotSettings.singleWorkerThread &&
        (plugin.persistentWorkerTid == Tid.init))
    {
        import std.concurrency : spawn;
        plugin.persistentWorkerTid = spawn(&persistentQuerier,
            plugin.headers, plugin.bucket);
    }
}


// resetAPIKeys
/++
 +  Resets the API keys in the HTTP headers we pass. Additionally validates them
 +  and tries to get new authorization keys if the current ones don't seem to work.
 +
 +  Params:
 +      plugin = The current `TwitchBotPlugin`.
 +
 +  Returns:
 +      true if keys seem to work, even if it took requesting new authorization
 +      keys to make it so; false if not.
 +/
bool resetAPIKeys(TwitchBotPlugin plugin)
{
    import lu.string : strippedRight;
    import std.file : readText;

    string getNewKey()
    {
        immutable key = getNewBearerToken(plugin.twitchBotSettings.clientKey,
            plugin.twitchBotSettings.secretKey);

        if (key.length)
        {
            import std.stdio : File;

            auto keyFile = File(plugin.keyFile);
            keyFile.writeln(key);
            return key;
        }
        else
        {
            // Something's wrong.
            return string.init;
        }
    }

    bool currentKeysWork()
    {
        try
        {
            const test = getUserByLogin(plugin, "kameboto");
            return (test != JSONValue.init);
        }
        catch (Exception e)
        {
            return false;
        }
    }

    string key = readText(plugin.keyFile).strippedRight;
    bool gotNewKey;

    if (!key.length)
    {
        key = getNewKey();
        gotNewKey = true;

        if (!key.length)
        {
            return false;
        }
    }

    synchronized //()
    {
        // Can't use a literal due to https://issues.dlang.org/show_bug.cgi?id=20812
        plugin.headers["Client-ID"] = plugin.twitchBotSettings.clientKey;
        plugin.headers["Authorization"] = "Bearer " ~ key;
    }

    if (!currentKeysWork)
    {
        if (gotNewKey)
        {
            // Already got a new key and it still doesn't work.
            return false;
        }

        immutable newKey = getNewKey();

        if (newKey.length)
        {
            synchronized //()
            {
                plugin.headers["Authorization"] = "Bearer " ~ newKey;
            }
            return currentKeysWork;
        }
        else
        {
            // Could not get a new key.
            return false;
        }
    }

    return true;
}


// getNewBearerToken
/++
 +  Requests a new bearer authorization token from the Twitch servers.
 +
 +  They expire after 60 days (4680249 seconds).
 +
 +  Params:
 +      plugin = The current `TwitchBotPlugin`.
 +
 +  Returns:
 +      A new authorization token string, or an empty one if one could not be fetched.
 +/
string getNewBearerToken(const string clientKey, const string secretKey)
{
    import requests.request : Request;
    import requests.utils : queryParams;
    import requests : postContent;
    import std.json : parseJSON;

    Request req;
    req.keepAlive = false;

    /*curl -X POST "https://id.twitch.tv/oauth2/token?client_id=${C}
        &client_secret=${S}&grant_type=client_credentials"*/

    enum url = "https://id.twitch.tv/oauth2/token";

    auto response = postContent(url, queryParams(
        "client_id", clientKey,
        "client_secret", secretKey,
        "grant_type", "client_credentials"));

    /*
    {
        "access_token" : "HARBLSNARBL",
        "expires_in" : 4680249,
        "token_type" : "bearer"
    }
    */

    const asJSON = parseJSON(cast(string)response);

    if (const token = "access_token" in asJSON)
    {
        return token.str;
    }
    else
    {
        return string.init;
    }
}


// cacheFollows
/++
 +  Fetches a list of all follows of the passed channel and caches them in
 +  the channel's entry in `TwitchBotPlugin.activeChannels`.
 +
 +  Note: Must be called from inside a `core.thread.Fiber`.
 +
 +  Params:
 +      plugin = The current `TwitchBotPlugin`.
 +      roomID = The string identifier for the channel.
 +
 +  Returns:
 +      A `JSONValue` containing follows, JSON values keyed by the ID string
 +      of the follower.
 +/
JSONValue cacheFollows(TwitchBotPlugin plugin, const string roomID)
in (Fiber.getThis, "Tried to call `cacheFollows` from outside a Fiber")
{
    import kameloso.plugins.common : delay;
    import std.json : JSONValue, parseJSON;
    import core.thread : Fiber;

    immutable url = "https://api.twitch.tv/helix/users/follows?to_id=" ~ roomID;

    JSONValue allFollows;
    string after;

    do
    {
        immutable paginatedURL = after.length ?
            (url ~ "&after=" ~ after) : url;

        scope(failure) plugin.useAPIFeatures = false;

        const response = queryTwitch(plugin, paginatedURL,
            plugin.twitchBotSettings.singleWorkerThread);

        auto followsJSON = parseJSON(response.str);
        const cursor = "cursor" in followsJSON["pagination"];

        foreach (thisFollowJSON; followsJSON["data"].array)
        {
            allFollows[thisFollowJSON["from_id"].str] = thisFollowJSON;
        }

        after = cursor ? cursor.str : string.init;
    }
    while (after.length);

    return allFollows;
}


// averageApproximateQueryTime
/++
 +  Given a query time measurement, calculate a new approximate query time based on
 +  the weighted averages of the old one and said measurement.
 +
 +  The old value is given a weight of `TwitchBotPlugin.approximateQueryAveragingWeight`
 +  and the new measurement a weight of 1. Additionally the measurement is padded
 +  by `TwitchBotPlugin.approximateQueryMeasurementPadding` to be on the safe side.
 +
 +  Params:
 +      plugin = The current `TwitchBotPlugin`.
 +      reponseMsecs = How many milliseconds the last query took to complete.
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
 +  Common code to wait for a query response. Merely spins and monitors the shared
 +  `bucket` associative array for when a response has arrived, and then returns it.
 +  Times out after a hardcoded 15 seconds if nothing was received.
 +
 +  Note: Must be called from inside a `core.thread.Fiber`.
 +
 +  Params:
 +      plugin = The current `TwitchBotPlugin`.
 +      url = The URL that was queried prior to calling this function. Must match.
 +      leaveTimingAlone = Whether or not to adjust the approximate query time.
 +          Enabled by default but can be disabled if the caller wants to do it.
 +
 +  Returns:
 +      A `QueryResponse` as constructed by other parts of the program.
 +/
QueryResponse waitForQueryResponse(TwitchBotPlugin plugin, const string url,
    bool leaveTimingAlone = true)
in (Fiber.getThis, "Tried to call `waitForQueryResponse` from outside a Fiber")
{
    import std.datetime.systime : Clock;

    import kameloso.plugins.common : delay;

    immutable startTime = Clock.currTime.toUnixTime;
    shared QueryResponse* response;
    double accumulatingTime = plugin.approximateQueryTime;

    while (!response)
    {
        synchronized //()
        {
            response = url in plugin.bucket;
        }

        if (!response)
        {
            immutable now = Clock.currTime.toUnixTime;

            if ((now - startTime) >= plugin.queryResponseTimeout)
            {
                response = new shared QueryResponse;
                break;
            }

            // Miss; fired too early, there is no response available yet
            accumulatingTime *= plugin.approximateQueryGrowthMultiplier;
            alias divisor = plugin.approximateQueryRetryTimeDivisor;
            immutable briefWait = cast(long)(accumulatingTime / divisor);
            delay(plugin, briefWait, Yes.msecs, Yes.yield);
            continue;
        }

        // Make the new approximate query time a weighted average
        if (!leaveTimingAlone) plugin.averageApproximateQueryTime(response.msecs);
        plugin.bucket.remove(url);
    }

    return *response;
}
