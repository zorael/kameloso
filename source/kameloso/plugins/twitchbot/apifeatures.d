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
void persistentQuerier(shared string[string] headers, shared string[string] bucket)
{
    import kameloso.thread : ThreadMessage;
    import std.concurrency : OwnerTerminated, receive;
    import std.variant : Variant;

    version(Posix)
    {
        import kameloso.thread : setThreadName;
        setThreadName("twitchquerier");
    }

    bool halt;

    while (!halt)
    {
        receive(
            (string url) scope
            {
                queryTwitch(url, headers, bucket);
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
 +  Sends a HTTP GET to the passed URL, and returns the response by adding it
 +  to the shared `bucket`.
 +
 +  Callers can as such spawn this function as a new thread and asynchronously
 +  monitor the `bucket` for when the results arrive.
 +
 +  Example:
 +  ---
 +  immutable url = "https://api.twitch.tv/helix/users?login=" ~ givenName;
 +  spawn&(&queryTwitch, url, cast(shared)plugin.headers, plugin.bucket);
 +
 +  delay(plugin, plugin.approximateQueryTime, Yes.msecs, Yes.yield);
 +
 +  shared string* response;
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
 +          delay(plugin, plugin.approximateQueryTime/retryTimeDivisor, Yes.msecs, Yes.yield);
 +          continue;
 +      }
 +
 +      plugin.bucket.remove(url);
 +  }
 +
 +  // *response is the (shared) response body
 +  ---
 +
 +  Params:
 +      url = URL address to look up.
 +      headers = HTTP headers to use when issuing the requests.
 +      bucket = The shared bucket to put the results in, keyed by URL.
 +/
void queryTwitch(const string url, shared string[string] headers,
    shared string[string] bucket)
{
    import lu.traits : UnqualArray;
    import requests.request : Request;

    Request req;
    req.keepAlive = false;
    req.addHeaders(cast(UnqualArray!(typeof(headers)))headers);
    auto res = req.get(url);

    if (res.code >= 400)
    {
        bucket[url] = string.init;
    }
    else
    {
        bucket[url] = cast(string)res.responseBody.data.idup;
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
    import std.concurrency : send, spawn;
    import std.conv : to;
    import std.json : JSONType, JSONValue, parseJSON;
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

                    if (plugin.twitchBotSettings.singleWorkerThread)
                    {
                        plugin.persistentWorkerTid.send(url);
                    }
                    else
                    {
                        spawn(&queryTwitch, url, cast(shared)plugin.headers, plugin.bucket);
                    }

                    delay(plugin, plugin.approximateQueryTime, Yes.msecs, Yes.yield);

                    shared string* response;
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
                                plugin.approximateQueryTime =
                                    cast(long)(plugin.approximateQueryTime *
                                    plugin.approximateQueryGrowthMultiplier);
                                queryTimeLengthened = true;
                            }

                            immutable briefWait = (plugin.approximateQueryTime / plugin.retryTimeDivisor);
                            delay(plugin, briefWait, Yes.msecs, Yes.yield);
                            continue;
                        }
                        else
                        {
                            // Slowly decrease it to avoid inflation
                            plugin.approximateQueryTime =
                                cast(long)(plugin.approximateQueryTime *
                                plugin.approximateQueryAntiInflationMultiplier);
                        }

                        plugin.bucket.remove(url);
                    }

                    if (response.length)
                    {
                        // Hit
                        const user = parseUserFromResponse(cast()*response);

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

        if (idString in follows)
        {
            return reportFollowAge(follows[idString]);
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
    import requests.request : Request;
    import std.conv : to;
    import std.format : format;
    import std.json : JSONType, JSONValue, parseJSON;

    immutable url = "https://api.twitch.tv/helix/users?%s=%s"
        .format(field, identifier.to!string);  // String just passes through

    Request req;
    req.keepAlive = false;
    req.addHeaders(plugin.headers);
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
        plugin.bucket[string.init] = string.init;
        plugin.bucket.remove(string.init);
    }

    if (plugin.twitchBotSettings.singleWorkerThread &&
        (plugin.persistentWorkerTid == Tid.init))
    {
        import std.concurrency : spawn;
        plugin.persistentWorkerTid = spawn(&persistentQuerier,
            cast(shared)plugin.headers, plugin.bucket);
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


// getNewAuthKey
/++
 +  Requests a new key for use when querying the server. Does not seem to work.
 +
 +  Params:
 +      plugin = The current `TwitchBotPlugin`.
 +      scopes = The scopes (or privileges) to request authorization for.
 +/
version(none)
void getNewAuthKey(TwitchBotPlugin plugin, const string scopes = "channel:read:subscriptions")
{
    /*https://id.twitch.tv/oauth2/authorize?response_type=token&client_id=$C
        &redirect_uri=http://localhost&scope=channel:read:subscriptions
        &state=farkafrkafrk*/

    import lu.string : nom;
    import requests.request : Request;
    import std.format : format;
    import std.random : uniform;
    import std.stdio;

    // channel:read:subscriptions
    immutable pattern = "https://id.twitch.tv/oauth2/authorize?response_type=token" ~
        "&client_id=%s&redirect_uri=http://localhost&scope=%s&state=%d";
    immutable url = pattern.format(plugin.headers["Client-ID"], scopes,
        uniform(0, 100_000_000));

    writeln("URL:", url);
    writeln();
    writeln();

    Request req;
    req.keepAlive = false;
    req.maxRedirects = 0;
    //req.addHeaders(plugin.headers);
    auto res = req.get(url);

    // <a href="https://www.twitch.tv/login?client_id=<KEY>&amp;
    // redirect_params=client_id%3D<KEY>%26redirect_uri%3Dhttp%253A%252F%252Flocalhost
    // %26response_type%3Dcode%26scope%3Dchannel%253Aread%253Asubscriptions%26state%3D<state>">Found</a>.
    immutable data = cast(string)res.responseBody.data;

    import std.json;
    writeln("--------");
    writeln(data);
    writeln("--------");

    string slice = data;  // mutable
    slice.nom("client_id=");
    immutable key = slice.nom("&amp;");

    writeln("old:", plugin.headers.get("Authorization", "<empty>"));
    writeln("new:", "Bearer " ~ key);

    plugin.headers["Authorization"] = "Bearer " ~ key;
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
    import requests;
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
{
    import kameloso.plugins.common : delay;
    import std.concurrency : send, spawn;
    import std.json : JSONType, JSONValue, parseJSON;
    import core.thread : Fiber;

    assert(Fiber.getThis, "Tried to call `cacheFollows` from outside a Fiber");

    immutable url = "https://api.twitch.tv/helix/users/follows?to_id=" ~ roomID;

    JSONValue allFollows;
    string after;

    do
    {
        immutable paginatedURL = after.length ?
            (url ~ "&after=" ~ after) : url;

        if (plugin.twitchBotSettings.singleWorkerThread)
        {
            plugin.persistentWorkerTid.send(paginatedURL);
        }
        else
        {
            spawn(&queryTwitch, paginatedURL, cast(shared)plugin.headers, plugin.bucket);
        }

        delay(plugin, plugin.approximateQueryTime, Yes.msecs, Yes.yield);

        shared string* response;
        bool queryTimeLengthened;

        while (!response)
        {
            synchronized
            {
                response = paginatedURL in plugin.bucket;
            }

            if (!response)
            {
                // Miss; fired too early, there is no response available yet
                if (!queryTimeLengthened)
                {
                    plugin.approximateQueryTime =
                        cast(long)(plugin.approximateQueryTime *
                        plugin.approximateQueryGrowthMultiplier);
                    queryTimeLengthened = true;
                }
                else
                {
                    // Slowly decrease it to avoid inflation
                    plugin.approximateQueryTime =
                        cast(long)(plugin.approximateQueryTime *
                        plugin.approximateQueryAntiInflationMultiplier);
                }

                immutable briefWait = (plugin.approximateQueryTime / plugin.retryTimeDivisor);
                delay(plugin, briefWait, Yes.msecs, Yes.yield);
                continue;
            }

            plugin.bucket.remove(paginatedURL);
        }

        auto followsJSON = parseJSON(*response);
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
