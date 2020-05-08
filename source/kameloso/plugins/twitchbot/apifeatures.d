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
 +  This is used instead of a `std.typecons.Tuple` because it doesn't really
 +  work with `shared`.
 +/
struct QueryResponse
{
    /// Response body, may be several lines.
    string str;

    /// How long the query took.
    long msecs;
}


// persistentQuerier
/++
 +  Persistent worker issuing Twitch API queries based on the concurrency messages
 +  sent to it.
 +
 +  Possibly best used on Windows where threads are comparatively expensive
 +  compared to on Posix platforms.
 +
 +  Params:
 +      headers = HTTP headers to use when issuing the requests.
 +      bucket = The shared bucket to put the results in, keyed by URL.
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
 +  worker start it. Once the query returns, the response body is checked to see
 +  whether or not it's an error. If it is, an attempt to reset API keys is made
 +  and, if successful, the query is resent. If not successful, it throws an
 +  exception and disables API features.
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
 +      Exception if there were unrecoverable errors.
 +/
QueryResponse queryTwitch(TwitchBotPlugin plugin, const string url,
    const bool singleWorker, bool firstAttempt = true)
in (Fiber.getThis, "Tried to call `queryTwitch` from outside a Fiber")
{
    import kameloso.plugins.common : delay;
    import lu.string : beginsWith;
    import std.concurrency : send, spawn;

    if (singleWorker)
    {
        plugin.persistentWorkerTid.send(url);

        immutable penalty = plugin.approximateQueryConcurrencyMessagePenalty;
        immutable queryWaitTime = plugin.approximateQueryTime + penalty;

        delay(plugin, queryWaitTime, Yes.msecs, Yes.yield);
    }
    else
    {
        spawn(&queryTwitchImpl, url, plugin.headers, plugin.bucket);
        delay(plugin, plugin.approximateQueryTime, Yes.msecs, Yes.yield);
    }

    const response = waitForQueryResponse(plugin, url);

    // {"error":"Unauthorized","status":401,"message":"Must provide a valid Client-ID or OAuth token"}
    if (response.str.beginsWith(`{"err`))
    {
        if (firstAttempt)
        {
            synchronized
            {
                plugin.bucket.remove(url);
            }

            immutable success = plugin.resetAPIKeys();
            if (success) return queryTwitch(plugin, url, singleWorker, false);  // <-- second attempt
            // Else drop down
        }

        plugin.useAPIFeatures = false;
        throw new Exception("Failed to query Twitch; received error instead of data");
    }

    return response;
}


// queryTwitchImpl
/++
 +  Sends a HTTP GET to the passed URL, and returns the response by adding it
 +  to the shared `bucket`.
 +
 +  Callers can as such spawn this function as a new thread and asynchronously
 +  monitor the `bucket` for when the results arrive.
 +
 +  Example:
 +  ---
 +  immutable url = "https://api.twitch.tv/helix/users?login=" ~ givenName;
 +  spawn&(&queryTwitchImpl, url, cast(shared)plugin.headers, plugin.bucket);
 +
 +  delay(plugin, plugin.approximateQueryTime, Yes.msecs, Yes.yield);
 +
 +  shared QueryResponse* response;
 +
 +  while (!response)
 +  {
 +      synchronized
 +      {
 +          response = url in plugin.bucket;
 +      }
 +
 +      if (!response)
 +      {
 +          // Too early, sleep briefly and try again
 +          delay(plugin, plugin.approximateQueryTime/plugin.approximateQueryRetryTimeDivisor,
                Yes.msecs, Yes.yield);
 +          continue;
 +      }
 +
 +      plugin.bucket.remove(url);
 +  }
 +
 +  // response.str is the response body
 +  ---
 +
 +  Params:
 +      url = URL address to look up.
 +      headers = HTTP headers to use when issuing the requests.
 +      bucket = The shared bucket to put the results in, keyed by URL.
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

    if (res.code >= 400)
    {
        synchronized
        {
            bucket[url] = QueryResponse.init;
        }
    }
    else
    {
        QueryResponse response;
        response.str = cast(string)res.responseBody.data.idup;
        immutable delta = (post - pre);
        response.msecs = delta.total!"msecs";

        synchronized
        {
            bucket[url] = response;
        }
    }
}


// onFollowAgeImpl
/++
 +  Implements "Follow Age", or the ability to query the server how long you
 +  (or a specified user) have been a follower of the current channel.
 +
 +  Lookups are done asychronously in subthreads.
 +/
void onFollowAgeImpl(TwitchBotPlugin plugin, const IRCEvent event)
{
    import kameloso.plugins.common : delay;
    import lu.string : nom, stripped;
    import std.conv : to;
    import std.json : JSONValue;
    import core.thread : Fiber;

    if (!plugin.useAPIFeatures) return;

    void dg()
    {
        string slice = event.content.stripped;  // mutable
        immutable nameSpecified = (slice.length > 0);

        uint id;
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
                id = user.id;
                fromDisplayName = user.displayName;
            }
            else
            {
                foreach (const user; plugin.state.users)
                {
                    if (user.displayName == givenName)
                    {
                        // Found user by displayName
                        id = user.id;
                        fromDisplayName = user.displayName;
                    }
                }

                if (!id)
                {
                    // None on record, look up
                    immutable url = "https://api.twitch.tv/helix/users?login=" ~ givenName;

                    const response = queryTwitch(plugin, url,
                        plugin.twitchBotSettings.singleWorkerThread);

                    if (response.str.length)
                    {
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
                    else
                    {
                        chan(plugin.state, event.channel, "Invalid user: " ~ givenName);
                        return;
                    }
                }
            }
        }

        void reportFollowAge(const JSONValue followingUserJSON)
        {
            import kameloso.common : timeSince;
            import lu.string : plurality;
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
 +
 +  Returns:
 +      A `std.json.JSONValue` with information regarding the user in question.
 +/
JSONValue getUserImpl(Identifier)(TwitchBotPlugin plugin, const string field,
    const Identifier identifier)
in (((field == "login") || (field == "id")), "Invalid field supplied; expected " ~
    "`login` or `id`, got `" ~ field ~ '`')
{
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

    return parseUserFromResponse(cast(string)res.responseBody.data);
}


// parseUserFromResponse
/++
 +  Given a string response from the Twitch servers when queried for information
 +  of a user, verifies and parses the JSON, returning only that which relates
 +  to the user.
 +
 +  Params:
 +      jsonString = String response as read from the server. In JSON form.
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


// getUserByName
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
 +/
JSONValue getUserByID(TwitchBotPlugin plugin, const uint id)
{
    return plugin.getUserImpl("id", id);
}


// onRoomStateImpl
/++
 +  Records the room ID of a home channel, and queries the Twitch servers for
 +  the display name of its broadcaster.
 +/
void onRoomStateImpl(TwitchBotPlugin plugin, const IRCEvent event)
{
    import requests.request : Request;
    import std.datetime.systime : Clock;
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

    immutable pre = Clock.currTime;
    const broadcasterJSON = getUserByID(plugin, event.aux);
    immutable post = Clock.currTime;

    if (broadcasterJSON.type != JSONType.object)// || ("display_name" !in broadcasterJSON))
    {
        // Something is deeply wrong.
        logger.error("Failed to fetch broadcaster information; " ~
            "are the client-secret API keys and the authorization key file correctly set up?");
        logger.error("Disabling API features.");
        plugin.useAPIFeatures = false;
        return;
    }

    immutable delta = (post - pre);
    immutable newApproximateTime = cast(long)(delta.total!"msecs" * 1.1);
    plugin.approximateQueryTime = (plugin.approximateQueryTime == 0) ?
        newApproximateTime :
        (plugin.approximateQueryTime+newApproximateTime) / 2;

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
 +  Sets up the worker thread at the end of MOTD.
 +
 +  Additionally initialises the shared bucket, and sets the HTTP headers to use
 +  when querying information.
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
 +  Resets the API keys in the HTTP headers we pass.
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
        const test = getUserByLogin(plugin, "kameboto");
        return (test != JSONValue.init);
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

    plugin.headers =
    [
        "Client-ID" : plugin.twitchBotSettings.clientKey,
        "Authorization" : "Bearer " ~ key,
    ];

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
            plugin.headers["Authorization"] = "Bearer " ~ newKey;
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
 +  Requests a new bearer authorization token from Twitch servers.
 +
 +  They expire in 60 days.
 +
 +  Params:
 +      plugin = The current `TwitchBotPlugin`.
 +
 +  Returns:
 +      A new authorization token string.
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
        logger.error("Could not get a new authorization bearer token. " ~
            "Make sure that your client and secret keys are valid.");
        return string.init;
    }
}


// cacheFollows
/++
 +  Fetches a list of all follows to the passed channel and caches them in
 +  the channel's entry in `TwitchBotPlugin.activeChannels`.
 +
 +  Params:
 +      plugin = The current `TwitchBotPlugin`.
 +      roomid = The string identifier for the channel.
 +
 +  Returns:
 +      A `JSONValue` containing follows, keyed by the ID string of the follower.
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
 +  Given a query time measurement, make a new approximate query time based on
 +  the weighted averages of the old one and said measurement.
 +
 +  The old value is given a weight of `plugin.approximateQueryAveragingWeight`
 +  and the new measurement a weight of 1. Additionally the measurement is padded
 +  by `plugin.approximateQueryMeasurementPadding` to be on the safe side.
 +
 +  Params:
 +      plugin = The current `TwitchBotPlugin`.
 +      reponseMsecs = How many milliseconds the last query took.
 +/
void averageApproximateQueryTime(TwitchBotPlugin plugin, const long responseMsecs)
{
    immutable current = plugin.approximateQueryTime;
    immutable weight = plugin.approximateQueryAveragingWeight;
    immutable padding = plugin.approximateQueryMeasurementPadding;
    immutable average = ((weight * current) + (responseMsecs + padding)) / (weight + 1);

    /*import std.stdio;
    writefln("time:%s | response: %d (+%d) | new average:%s",
        current, responseMsecs, padding, average);*/

    plugin.approximateQueryTime = cast(long)average;
}


// waitForQueryResponse
/++
 +  Common code to wait for a query response. Merely spins and monitors the shared
 +  `bucket` associative array for when a response has arrived, and then returns it.
 +
 +  Note: This function currently never gives up and will keep watching until
 +      execution end if a response does not appear.
 +
 +  Params:
 +      plugin = The current `TwitchBotPlugin`.
 +      url = The URL that was queried prior to calling this function. Must match.
 +
 +  Returns:
 +      A `QueryResponse` as constructed by other parts of the program.
 +/
QueryResponse waitForQueryResponse(TwitchBotPlugin plugin, const string url)
in (Fiber.getThis, "Tried to call `waitForQueryResponse` from outside a Fiber")
{
    import kameloso.plugins.common : delay;

    shared QueryResponse* response;
    bool queryTimeLengthened;

    while (!response)
    {
        synchronized
        {
            response = url in plugin.bucket;
        }

        if (!response)
        {
            // Miss; fired too early, there is no response available yet
            if (!queryTimeLengthened)
            {
                immutable queryTime = plugin.approximateQueryTime;
                immutable multiplier = plugin.approximateQueryGrowthMultiplier;
                plugin.approximateQueryTime = cast(long)(queryTime * multiplier);
                queryTimeLengthened = true;
            }

            immutable queryTime = plugin.approximateQueryTime;
            immutable divisor = plugin.approximateQueryRetryTimeDivisor;
            immutable briefWait = (queryTime / divisor);
            delay(plugin, briefWait, Yes.msecs, Yes.yield);
            continue;
        }

        // Make the new approximate query time a weighted average
        plugin.averageApproximateQueryTime(response.msecs);
        plugin.bucket.remove(url);
    }

    return *response;
}
