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

version(linux)
{
    version = XDG;
}
else version(FreeBSD)
{
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
 +      headers = `shared` HTTP headers to use when issuing the requests.
 +          Contains the API keys needed for Twitch to accept the queries.
 +      bucket = The shared associative array bucket to put the results in,
 +          response body values keyed by URL.
 +/
void persistentQuerier(shared QueryResponse[string] bucket)
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
            (string url, shared string[string] headers) scope
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


// onCAP
/++
 +  Start the captive key generation routine at the earliest possible moment,
 +  which are the CAP events.
 +
 +  We can't do it in `start` since the calls to save and exit would go unheard,
 +  as `start` happens before the main loop starts. It would then immediately
 +  fail to read if too much time has passed, and nothing would be saved.
 +/
void onCAPImpl(TwitchBotPlugin plugin)
{
    import kameloso.common : Tint;
    import kameloso.thread : ThreadMessage;
    import lu.string : contains, nom, stripped;
    import std.concurrency : prioritySend;
    import std.process : execute;
    import std.stdio : readln, stdin, stdout, write, writefln, writeln;

    if (!plugin.twitchBotSettings.keyGenerationMode) return;

    scope(exit)
    {
        plugin.twitchBotSettings.keyGenerationMode = false;
        plugin.state.botUpdated = true;
        plugin.state.mainThread.prioritySend(ThreadMessage.Quit(), string.init, Yes.quiet);
    }

    writeln();
    logger.info("-- Twitch authorisation key generation mode --");
    writeln();
    writefln("You are here because you passed %s--set twitchbot.keyGenerationMode%s",
        Tint.info, Tint.reset);
    writefln("or because you have %skeyGenerationMode%s persistently set to %1$strue%2$s ",
        Tint.info, Tint.reset);
    writeln("in the configuration file (which you really shouldn't have).");
    writeln();
    writeln("As of early May 2020, Twitch requires the pass you connect with");
    writeln("to be paired with the client ID of the program you use it with.");
    writeln("As such, you need to generate one for each application.");
    writeln();

    immutable url = "https://id.twitch.tv/oauth2/authorize?response_type=token" ~
        "&client_id=" ~ TwitchBotPlugin.clientID ~
        "&redirect_uri=http://localhost" ~
        "&scope=channel:moderate+chat:edit+chat:read+whispers:edit+whispers:read+" ~
        "channel:read:subscriptions+bits:read+user:edit:broadcast+channel_editor" ~
        "&state=kameloso-" ~ plugin.state.client.nickname;

    writeln("Press Enter to open a link to a Twitch login page, and follow the instructions.");
    writefln("%sThen paste the address of the page you are redirected to afterwards%s here.",
        Tint.info, Tint.reset);
    writefln("* It should start with %shttp://localhost%s.", Tint.info, Tint.reset);
    writefln(`* The page will probably say "%sthis site can't be reached%s".`, Tint.info, Tint.reset);
    writeln();
    writeln("(If you are running local web server, you may have to temporarily");
    writeln("disable it for this to work.)");
    writeln();
    writeln("Press Enter to continue.");

    readln();

    version(XDG)
    {
        immutable openBrowser = [ "xdg-open", url ];
        execute(openBrowser);
    }
    else version(OSX)
    {
        immutable openBrowser = [ "open", url ];
        execute(openBrowser);
    }
    else version(Windows)
    {
        immutable openBrowser = [ "start", url ];
        execute(openBrowser);
    }
    else
    {
        writeln("Unsupported platform! Open this link manually in your browser:");
        writeln();
        writeln("------------------------------------------------------------------");
        writeln();
        writeln(url);
        writeln();
        writeln("------------------------------------------------------------------");
    }

    string key;

    while (!key.length)
    {
        writeln(Tint.info, "Paste the resulting address here (empty line exits):", Tint.reset);
        writeln();

        immutable readURL = readln().stripped;
        stdin.flush();

        if (!readURL.length) return;

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
        Tint.info, Tint.log, key, Tint.reset);
    writefln("%sIt should be entered as %spass%1$s under %2$s[IRCBot]%1$s.%3$s",
        Tint.info, Tint.log, Tint.reset);
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
            writefln("Make sure to add it to %s%s%s, then;",
                Tint.info, plugin.state.settings.configFile, Tint.reset);
            writefln("as %spass%s under %1$s[IRCBot]%2$s.", Tint.info, Tint.reset);
        }
    }

    writeln();
    writeln("All done! Restart the program and it should just work.");
    writefln("If it doesn't, please file an issue at " ~
        "%shttps://github.com/zorael/kameloso/issues/new", Tint.info);
    writeln();
    writeln(Tint.warning, "Note: this will need to be repeated once every 60 days.", Tint.reset);
    writeln();
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
 +
 +  Returns:
 +      The `QueryResponse` that was discovered while monitoring the `bucket`
 +      as having been received from the server.
 +
 +  Throws:
 +      `object.Exception` if there were unrecoverable errors.
 +/
QueryResponse queryTwitch(TwitchBotPlugin plugin, const string url,
    const bool singleWorker, shared string[string] headers)
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
        plugin.persistentWorkerTid.send(url, headers);
    }
    else
    {
        spawn(&queryTwitchImpl, url, headers, plugin.bucket);
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

    synchronized //()
    {
        // Always remove, otherwise there'll be stale entries
        plugin.bucket.remove(url);
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
    response.str = cast(string)res.responseBody.data.idup;

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
                        plugin.twitchBotSettings.singleWorkerThread,
                        plugin.headers);

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
 +
 +  Returns:
 +      A `std.json.JSONValue` with information regarding the user in question.
 +/
JSONValue getUserImpl(Identifier)(TwitchBotPlugin plugin, const string field,
    const Identifier identifier)
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
    import kameloso.plugins.common : delay;
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

    void getDisplayNameDg()
    {
        immutable url = "https://api.twitch.tv/helix/users?id=" ~ event.aux;

        const response = queryTwitch(plugin, url,
            plugin.twitchBotSettings.singleWorkerThread,
            plugin.headers);
        const broadcasterJSON = parseUserFromResponse(response.str);
        channel.broadcasterDisplayName = broadcasterJSON["display_name"].str;
    }

    Fiber getDisplayNameFiber = new Fiber(&getDisplayNameDg);
    getDisplayNameFiber.call();

    if ((plugin.state.nextPeriodical - event.time) > 60)
    {
        // The next periodical is far away, meaning we did not just connect
        // Let the caching be done in periodically otherwise.

        void cacheFollowsDg()
        {
            channel.follows = plugin.cacheFollows(channel.roomID);
        }

        Fiber cacheFollowsFiber = new Fiber(&cacheFollowsDg);
        cacheFollowsFiber.call();
    }
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

    if (!plugin.headers.length)
    {
        plugin.resetAPIKeys();
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
        plugin.persistentWorkerTid = spawn(&persistentQuerier, plugin.bucket);
    }

    void validationDg()
    {
        import kameloso.common : Tint;
        import std.conv : to;
        import std.datetime.systime : Clock, SysTime;

        try
        {
            /*
            {
                "client_id": "tjyryd2ojnqr8a51ml19kn1yi2n0v1",
                "expires_in": 5036421,
                "login": "zorael",
                "scopes": [
                    "bits:read",
                    "channel:moderate",
                    "channel:read:subscriptions",
                    "channel_editor",
                    "chat:edit",
                    "chat:read",
                    "user:edit:broadcast",
                    "whispers:edit",
                    "whispers:read"
                ],
                "user_id": "22216721"
            }
            */

            const validation = getValidation(plugin);
            plugin.userID = validation["user_id"].str;
            immutable expiresIn = validation["expires_in"].integer;
            immutable expiresWhen = SysTime.fromUnixTime(Clock.currTime.toUnixTime + expiresIn);

            logger.infof("Your authorisation keys will expire on %s%02d-%02d-%02d %02d:%02d",
                Tint.log, expiresWhen.year, expiresWhen.month, expiresWhen.day,
                expiresWhen.hour, expiresWhen.minute);
        }
        catch (Exception e)
        {
            // Something is deeply wrong.
            logger.error("Failed to validate API keys. Disabling API features.");
            version(PrintStacktraces) logger.trace(e.toString);
            plugin.useAPIFeatures = false;
        }
    }

    Fiber validationFiber = new Fiber(&validationDg);
    validationFiber.call();
}


// resetAPIKeys
/++
 +  Resets the API keys in the HTTP headers we pass.
 +/
void resetAPIKeys(TwitchBotPlugin plugin)
{
    synchronized //()
    {
        // Can't use a literal due to https://issues.dlang.org/show_bug.cgi?id=20812
        plugin.headers["Client-ID"] = plugin.clientID,
        plugin.headers["Authorization"] = "Bearer " ~ plugin.state.bot.pass[6..$];
    }
}


// getValidation
/++
 +  Validates the current access key, retrieving information about it.
 +/
JSONValue getValidation(TwitchBotPlugin plugin)
in (Fiber.getThis, "Tried to call `getValidation` from outside a Fiber")
{
    import lu.traits : UnqualArray;
    import std.json : JSONType, JSONValue, parseJSON;

    alias UT = UnqualArray!(typeof(plugin.headers));
    auto oauthHeaders = (cast(UT)plugin.headers).dup;
    oauthHeaders["Authorization"] = "OAuth " ~ plugin.state.bot.pass[6..$];

    enum url = "https://id.twitch.tv/oauth2/validate";
    const response = queryTwitch(plugin, url,
        plugin.twitchBotSettings.singleWorkerThread, cast(shared)oauthHeaders);

    if (!response.str.length)
    {
        throw new Exception("Error validating, empty repsonse");
    }

    JSONValue validation = parseJSON(response.str);

    if ((validation.type != JSONType.object) || ("client_id" !in validation))
    {
        throw new Exception("Error validating, unknown JSON");
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
            plugin.twitchBotSettings.singleWorkerThread, plugin.headers);

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
