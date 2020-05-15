/++
 +  Functions for accessing the Twitch API. For internal use.
 +/
module kameloso.plugins.twitchbot.api;

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
import std.stdio;

version(linux)
{
    version = XDG;
}
else version(FreeBSD)
{
    version = XDG;
}
else version(OpenBSD)
{
    // Is this correct?
    version = XDG;
}

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
 +      bucket = The shared associative array bucket to put the results in,
 +          response body values keyed by URL.
 +/
void persistentQuerier()//shared QueryResponse[string] bucket)
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
            (string url, string clientID, string authToken, int timeout,
                shared QueryResponse[string] bucket) scope
            {
                queryTwitchImpl(url, clientID, authToken, timeout, bucket);
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


// generateKey
/++
 +  Start the captive key generation routine at the earliest possible moment,
 +  which are the CAP events.
 +
 +  We can't do it in `start` since the calls to save and exit would go unheard,
 +  as `start` happens before the main loop starts. It would then immediately
 +  fail to read if too much time has passed, and nothing would be saved.
 +/
void generateKey(TwitchBotPlugin plugin)
{
    import kameloso.common : Tint;
    import kameloso.thread : ThreadMessage;
    import lu.string : contains, nom, stripped;
    import std.concurrency : prioritySend;
    import std.process : ProcessException, execute;
    import std.stdio : readln, stdin, stdout, write, writefln, writeln;

    if (!plugin.twitchBotSettings.keyGenerationMode) return;

    scope(exit)
    {
        plugin.twitchBotSettings.keyGenerationMode = false;
        plugin.state.botUpdated = true;
        plugin.state.mainThread.prioritySend(ThreadMessage.Quit(), string.init, Yes.quiet);
    }

    logger.trace();
    logger.info("-- Twitch authorisation key generation mode --");
    writeln();
    writefln("You are here because you passed %s--set twitchbot.keyGenerationMode%s, or because",
        Tint.info, Tint.reset);
    writefln("you have %skeyGenerationMode%s under %1$s[TwitchBot]%2$s persistently set to %1$strue%2$s in the",
        Tint.info, Tint.reset);
    writeln("configuration file (which you really shouldn't have).");
    writeln();
    writeln("As of early May 2020, the Twitch API requires your authorisation token to be");
    writeln("paired with the client ID of the program you connect with.");
    writeln();
    writeln("Press Enter to open a link to a Twitch login page, and follow the instructions.");
    writeln(Tint.log, "Then paste the address of the page you are redirected to afterwards here.", Tint.reset);
    writeln();
    writefln("* The redirected address should start with %shttp://localhost%s.", Tint.info, Tint.reset);
    writefln(`* It will probably say "%sthis site can't be reached%s".`, Tint.info, Tint.reset);
    writeln("* You may need to close the browser window if the terminal prompt to paste the");
    writeln("  URL address doesn't appear.");
    writeln("* If you are running local web server, you may have to temporarily disable it");
    writeln("  for this to work.");
    writeln();
    writeln(Tint.log, "Press Enter to continue.", Tint.reset);
    stdout.flush();

    readln();

    static immutable scopes =
    [
        // New Twitch API

        //"analytics:read:extension",
        //"analytics:read:games",
        "bits:read",
        "channel:edit:commercial",
        "channel:read:subscriptions",
        //"clips:edit",
        "user:edit",
        "user:edit:broadcast",  // implies user:read:broadcast
        //"user:edit:follows",
        //"user:read:broadcast",
        //"user:read:email",

        // Twitch APIv5

        //"channel_check_subscription",
        //"channel_commercial",
        "channel_editor",
        //"channel_feed_edit",
        //"channel_feed_read",
        //"channel_read",
        //"channel_stream",
        //"channel_subscriptions",
        //"collections_edit",
        //"communities_edit",
        //"communities_moderate",
        //"openid",
        "user_blocks_edit",
        "user_blocks_read",
        "user_follows_edit",
        //"user_read",
        //"user_subscriptions",
        //"viewing_activity_read",

        // Chat and PubSub

        "channel:moderate",
        "chat:edit",
        "chat:read",
        "whispers:edit",
        "whispers:read",
    ];

    import std.array : join;

    enum ctBaseURL = "https://id.twitch.tv/oauth2/authorize?response_type=token" ~
        "&client_id=" ~ TwitchBotPlugin.clientID ~
        "&redirect_uri=http://localhost" ~
        "&scope=" ~ scopes.join('+') ~
        /*"&scope=channel:moderate+chat:edit+chat:read+whispers:edit+whispers:read+" ~
        "channel:read:subscriptions+bits:read+user:edit:broadcast+channel_editor" ~*/
        //"&force_verify=true" ~
        "&state=kameloso-";

    immutable url = ctBaseURL ~ plugin.state.client.nickname;
    int exitcode;

    try
    {
        version(XDG)
        {
            immutable openBrowser = [ "xdg-open", url ];
            exitcode = execute(openBrowser).status;
        }
        else version(OSX)
        {
            immutable openBrowser = [ "open", url ];
            exitcode = execute(openBrowser).status;
        }
        else version(Windows)
        {
            import std.file : tempDir;
            import std.path : buildPath;

            immutable urlBasename = "kameloso-twitch-%s.url"
                .format(plugin.state.client.nickname);
            immutable urlFileName = buildPath(tempDir, urlBasename);

            auto urlFile = File(urlFileName, "w");
            scope(exit) urlFile.remove();

            urlFile.writeln("[InternetShortcut]");
            urlFile.writeln("URL=", url);

            immutable openBrowser = [ "explorer", urlFileName ];
            exitcode = execute(openBrowser).status;
        }
        else
        {
            writeln();
            writeln(Tint.error, "Unexpected platform, cannot open link automatically.", Tint.reset);
            writeln();

            exitcode = 1;
        }
    }
    catch (ProcessException e)
    {
        logger.warning("Error: could not automatically open browser.");
        writeln();
        // Probably we got some platform wrong and command was not found
        exitcode = 127;
    }

    if (exitcode > 0)
    {
        writeln(Tint.info, "Copy and paste this link manually into your browser:", Tint.reset);
        writeln();
        writeln("8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8<");
        writeln();
        writeln(url);
        writeln();
        writeln("8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8<");
        writeln();
    }

    string key;

    while (!key.length)
    {
        writeln(Tint.info, "Paste the resulting address here (empty line exits):", Tint.reset);
        writeln();
        write("> ");
        stdout.flush();

        immutable readURL = readln().stripped;
        stdin.flush();

        if (!readURL.length)
        {
            writeln();
            logger.warning("Aborting key generation.");
            return;
        }

        if (!readURL.contains("access_token="))
        {
            writeln("Could not make sense of URL. Try again or file a bug.");
            continue;
        }

        string slice = readURL;  // mutable
        slice.nom("access_token=");
        key = slice.nom('&');
    }

    plugin.state.bot.pass = "oauth:" ~ key;

    writeln();
    writefln("%sYour private authorisation key is: %s%s%s",
        Tint.info, Tint.log, plugin.state.bot.pass, Tint.reset);
    writefln("It should be entered as %spass%s under %1$s[IRCBot]%2$s.",
        Tint.info, Tint.reset);
    writeln();

    if (!plugin.state.settings.saveOnExit)
    {
        write("Do you want to save it there now? [Y/*]: ");
        stdout.flush();
        immutable input = readln().stripped;

        if (!input.length || (input == "y") || (input == "Y"))
        {
            plugin.state.mainThread.prioritySend(ThreadMessage.Save());
        }
        else
        {
            writeln();
            writefln("* Make sure to add it to %s%s%s, then;",
                Tint.info, plugin.state.settings.configFile, Tint.reset);
            writefln("  as %spass%s under %1$s[IRCBot]%2$s.", Tint.info, Tint.reset);
        }
    }

    writeln();
    writeln("-------------------------------------------------------------------------------");
    writeln();
    writefln("All done! Restart the program (without %s--set twichbot.generateKeyMode%s) and it",
        Tint.info, Tint.reset);
    writeln("should just work. If it doesn't, please file an issue, at:");
    writeln();
    writeln("    ", Tint.info, "https://github.com/zorael/kameloso/issues/new", Tint.reset);
    writeln();
    writeln(Tint.warning, "Note: this will need to be repeated once every 60 days.", Tint.reset);
    writeln();
    stdout.flush();
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
 +      singleWorker = Whether the request should be passed onto a different
 +          persistent worker thread by concurrency message, or spawned in a
 +          new thread just for the occasion.
 +      headers = `shared` HTTP headers to use when issuing the requests.
 +
 +  Returns:
 +      The `QueryResponse` that was discovered while monitoring the `bucket`
 +      as having been received from the server.
 +
 +  Throws:
 +      `object.Exception` if there were unrecoverable errors.
 +/
QueryResponse queryTwitch(TwitchBotPlugin plugin, const string url,
    const string authorisationHeader, const bool singleWorker,
    shared QueryResponse[string] bucket)
in (Fiber.getThis, "Tried to call `queryTwitch` from outside a Fiber")
{
    import kameloso.plugins.common.delayawait : delay;
    import lu.string : beginsWith;
    import std.concurrency : send, spawn;
    import std.datetime.systime : Clock, SysTime;

    SysTime pre;

    if (singleWorker)
    {
        pre = Clock.currTime;
        plugin.persistentWorkerTid.send(url, plugin.clientID, authorisationHeader,
            plugin.queryResponseTimeout, bucket);
    }
    else
    {
        spawn(&queryTwitchImpl, url, plugin.clientID, authorisationHeader,
            plugin.queryResponseTimeout, bucket);
    }

    delay(plugin, plugin.approximateQueryTime, Yes.msecs, Yes.yield);
    const response = waitForQueryResponse(plugin, url, singleWorker);

    scope(exit)
    {
        synchronized //()
        {
            // Always remove, otherwise there'll be stale entries
            plugin.bucket.remove(url);
        }
    }

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

    //writeln("repsonse:'", response.str, "'");

    if ((response.code >= 400) || !response.str.length || (response.str.beginsWith(`{"err`)))
    {
        // {"error":"Unauthorized","status":401,"message":"Must provide a valid Client-ID or OAuth token"}
        throw new TwitchQueryException("Failed to query Twitch", response.str, response.code);
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
void queryTwitchImpl(const string url, const string clientID, const string authToken,
    const uint timeout, shared QueryResponse[string] bucket)
{
    import lu.traits : UnqualArray;
    import std.net.curl : HTTP;
    import std.datetime.systime : Clock, SysTime;
    import core.time : seconds;
    import std.array : Appender;
    import std.exception : assumeUnique;

    auto client = HTTP(url);
    client.operationTimeout = timeout.seconds;
    client.addRequestHeader("Client-ID", clientID);
    client.addRequestHeader("Authorization", authToken);

    Appender!(ubyte[]) sink;

    client.onReceive = (ubyte[] data)
    {
        sink.put(data);
        return data.length;
    };

    // Refer to https://curl.haxx.se/libcurl/c/libcurl-errors.html for CURLCode

    immutable pre = Clock.currTime;
    /*immutable curlCode =*/ client.perform();//(No.throwOnError);
    immutable post = Clock.currTime;

    QueryResponse response;
    response.code = client.statusLine.code;
    immutable delta = (post - pre);
    response.msecs = delta.total!"msecs";
    response.str = assumeUnique(cast(char[])sink.data);

    synchronized //()
    {
        bucket[url] = response;  // empty str if code >= 400
    }
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
    const Identifier identifier, const string clientID, const string authToken,
    const uint timeout)
in (((field == "login") || (field == "id")), "Invalid field supplied; expected " ~
    "`login` or `id`, got `" ~ field ~ '`')
{
    import lu.string : beginsWith;
    import std.conv : to;
    import std.format : format;
    import std.net.curl : HTTP;
    import core.time : seconds;

    immutable url = "https://api.twitch.tv/helix/users?%s=%s"
        .format(field, identifier.to!string);  // String just passes through

    auto client = HTTP(url);
    client.operationTimeout = timeout.seconds;  // FIXME
    client.addRequestHeader("Client-ID", clientID);
    client.addRequestHeader("Authorization", authToken);

    string received;

    client.onReceive = (ubyte[] data)
    {
        received = (cast(const(char)[])data).idup;
        return data.length;
    };

    client.perform();
    immutable code = client.statusLine.code;

    if ((code >= 400) || !received.length || (received.beginsWith(`{"err`)))
    {
        // {"status":401,"message":"missing authorization token"}
        // {"error":"Unauthorized","status":401,"message":"Must provide a valid Client-ID or OAuth token"}
        throw new TwitchQueryException("Failed to query Twitch", received, code, __FILE__);
    }

    return parseUserFromResponse(received);
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
    return plugin.getUserImpl("login", login, plugin.clientID,
        plugin.authorizationBearer, plugin.queryResponseTimeout);
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
    return plugin.getUserImpl("id", id, plugin.clientID,
        plugin.authorizationBearer, plugin.queryResponseTimeout);
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
    return plugin.getUserImpl("id", id, plugin.clientID,
        plugin.authorizationBearer, plugin.queryResponseTimeout);
}


// getValidation
/++
 +  Validates the current access key, retrieving information about it.
 +/
JSONValue getValidation(TwitchBotPlugin plugin)
in (Fiber.getThis, "Tried to call `getValidation` from outside a Fiber")
{
    import lu.string : beginsWith;
    import lu.traits : UnqualArray;
    import std.json : JSONType, JSONValue, parseJSON;

    enum url = "https://id.twitch.tv/oauth2/validate";

    // Validation needs an "Authorization: OAuth xxx" header, as opposed to the
    // "Authorization: Bearer xxx" used everywhere else.
    immutable authorizationHeader = "OAuth " ~ plugin.state.bot.pass[6..$];

    const response = queryTwitch(plugin, url, authorizationHeader,
        plugin.twitchBotSettings.singleWorkerThread, plugin.bucket);

    if ((response.code >= 400) || !response.str.length || (response.str.beginsWith(`{"err`)))
    {
        // {"error":"Unauthorized","status":401,"message":"Must provide a valid Client-ID or OAuth token"}
        throw new TwitchQueryException("Failed to validate Twitch authorisation token",
            response.str, response.code);
    }

    JSONValue validation = parseJSON(response.str);

    if ((validation.type != JSONType.object) || ("client_id" !in validation))
    {
        throw new TwitchQueryException("Failed to validate Twitch authorisation " ~
            "token; unknown JSON", response.str, response.code);
    }

    return validation;
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
    import kameloso.plugins.common.delayawait : delay;
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
            plugin.authorizationBearer, plugin.twitchBotSettings.singleWorkerThread,
            plugin.bucket);

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

    import kameloso.plugins.common.delayawait : delay;

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
            writeln("MISS");
            stdout.flush();
            accumulatingTime *= plugin.approximateQueryGrowthMultiplier;
            alias divisor = plugin.approximateQueryRetryTimeDivisor;
            immutable briefWait = cast(long)(accumulatingTime / divisor);
            delay(plugin, briefWait, Yes.msecs, Yes.yield);
            continue;
        }

        writeln("HIT");

        // Make the new approximate query time a weighted average
        if (!leaveTimingAlone) plugin.averageApproximateQueryTime(response.msecs);
        plugin.bucket.remove(url);
    }

    return *response;
}


// TwitchQueryException
/++
 +  Exception, to be thrown when an API query to the Twitch servers failed,
 +  for whatever reason.
 +
 +  It is a normal `object.Exception` but with attached metadata.
 +/
final class TwitchQueryException : Exception
{
@safe:
    /// The response body that was received.
    string responseBody;

    /// The HTTP code that was received.
    uint code;

    /++
     +  Create a new `TwitchQueryException`, attaching a response body and a
     +  HTTP return code.
     +/
    this(const string message, const string responseBody, const uint code,
        const string file = __FILE__, const size_t line = __LINE__) pure nothrow @nogc
    {
        this.responseBody = responseBody;
        this.code = code;
        super(message, file, line);
    }

    /++
     +  Create a new `TwitchQueryException`, without attaching anything.
     +/
    this(const string message, const string file = __FILE__,
        const size_t line = __LINE__) pure nothrow @nogc
    {
        super(message, file, line);
    }
}
