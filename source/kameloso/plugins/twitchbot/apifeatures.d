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
 +  plugin.delayFiberMsecs(plugin.approximateQueryTime);
 +  Fiber.yield();
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
 +          plugin.delayFiberMsecs(plugin.approximateQueryTime/retryTimeDivisor);
 +          Fiber.yield();
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
    import kameloso.plugins.common : delayFiberMsecs;
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

                    plugin.delayFiberMsecs(plugin.approximateQueryTime);
                    Fiber.yield();

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

                            plugin.delayFiberMsecs(plugin.approximateQueryTime / plugin.retryTimeDivisor);
                            Fiber.yield();
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

        // Identity ascertained; look up

        immutable roomIDString = plugin.activeChannels[event.channel].roomID.to!string;

        foreach (const followingUserJSON; getFollowsAsync(plugin, idString, Yes.from).array)
        {
            /*writefln("%s --> %s", followingUserJSON["from_name"],
                followingUserJSON["to_name"]);*/

            if (followingUserJSON["to_id"].str == roomIDString)
            {
                /*writeln("FROM");
                writeln(followingUserJSON.toPrettyString);*/
                return reportFollowAge(followingUserJSON);
            }
        }

        foreach (const followingUserJSON; getFollowsAsync(plugin, roomIDString, No.from).array)
        {
            /*writefln("%s --> %s", followingUserJSON["from_name"],
                followingUserJSON["to_name"]);*/

            if (followingUserJSON["from_id"].str == idString)
            {
                /*writeln("TO");
                writeln(followingUserJSON.toPrettyString);*/
                return reportFollowAge(followingUserJSON);
            }
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


// getFollowsAsync
/++
 +  Asynchronously gets the list of followers of a channel.
 +
 +  Warning: Must be called from within a Fiber.
 +
 +  Params:
 +      plugin = The current `TwitchBotPlugin`.
 +      idString = The room ID number as a string.
 +      from = Whether to query for followers from a channel or to a channel.
 +
 +  Params:
 +      A `std.json.JSONValue` with the list of follows.
 +/
JSONValue getFollowsAsync(TwitchBotPlugin plugin, const string idString,
    const Flag!"from" from)
{
    import kameloso.plugins.common : delayFiberMsecs;
    import std.concurrency : send, spawn;
    import std.json : JSONType, JSONValue, parseJSON;
    import core.thread : Fiber;

    assert(Fiber.getThis, "Tried to call `getFollowsAsync` from outside a Fiber");

    immutable url = from ?
        "https://api.twitch.tv/helix/users/follows?from_id=" ~ idString :
        "https://api.twitch.tv/helix/users/follows?to_id=" ~ idString;

    if (plugin.twitchBotSettings.singleWorkerThread)
    {
        plugin.persistentWorkerTid.send(url);
    }
    else
    {
        spawn(&queryTwitch, url, cast(shared)plugin.headers, plugin.bucket);
    }

    plugin.delayFiberMsecs(plugin.approximateQueryTime);
    Fiber.yield();

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
            else
            {
                // Slowly decrease it to avoid inflation
                plugin.approximateQueryTime =
                    cast(long)(plugin.approximateQueryTime *
                    plugin.approximateQueryAntiInflationMultiplier);
            }

            plugin.delayFiberMsecs(plugin.approximateQueryTime / plugin.retryTimeDivisor);
            Fiber.yield();
            continue;
        }

        plugin.bucket.remove(url);
    }

    auto followsJSON = parseJSON(*response);

    if ((followsJSON.type != JSONType.object) || ("data" !in followsJSON) ||
        (followsJSON["data"].type != JSONType.array))
    {
        /*import std.stdio : writeln;

        logger.error("Invalid Twitch response; is the API key correctly entered?");
        writeln(followsJSON.toPrettyString);*/
        return JSONValue.init;
    }

    return followsJSON["data"];
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
    import std.json : JSONType, parseJSON;
    import std.datetime.systime : Clock;

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
        logger.error("Failed to fetch broadcaster information; is the API key entered correctly?");
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

    if (!plugin.twitchBotSettings.apiKey.length)
    {
        logger.info("No Twitch Client ID API key supplied in the configuration file. " ~
            "Some commands will not work.");
        plugin.useAPIFeatures = false;
        return;
    }

    if (!plugin.headers.length)
    {
        plugin.headers =
        [
            "Client-ID" : plugin.twitchBotSettings.apiKey,
            "Authorization" : "Bearer " ~ plugin.state.bot.pass[6..$],  // Strip "oauth:"
        ];
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
