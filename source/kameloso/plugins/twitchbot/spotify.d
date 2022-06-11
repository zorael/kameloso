/++
    Bits and bobs to get Spotify API credentials for playlist management.

    See_Also:
        [kameloso.plugins.twitchbot.base|twitchbot.base]
        [kameloso.plugins.twitchbot.api|twitchbot.api]
 +/
module kameloso.plugins.twitchbot.spotify;

version(TwitchSupport):
version(WithTwitchBotPlugin):

private:

import kameloso.plugins.twitchbot.base;
import kameloso.plugins.twitchbot.helpers;

import kameloso.common : expandTags, logger;
import kameloso.logger : LogLevel;
import arsd.http2 : HttpClient;
import std.json : JSONValue;
import std.typecons : Flag, No, Yes;
import core.thread : Fiber;


// requestSpotifyKeys
/++
    Requests a Spotify API authorisation code from Spotify servers, then uses it
    to obtain an access key and a refresh OAuth key.

    Params:
        plugin = The current [kameloso.plugins.twitchbot.base.TwitchBotPlugin|TwitchBotPlugin].
 +/
package void requestSpotifyKeys(TwitchBotPlugin plugin)
{
    import kameloso.logger : LogLevel;
    import lu.string : contains, nom, stripped;
    import std.format : format;
    import std.process : Pid, ProcessException, wait;
    import std.stdio : File, readln, stdin, stdout, write, writefln, writeln;

    scope(exit)
    {
        import kameloso.messaging : quit;
        import std.typecons : Flag, No, Yes;

        if (plugin.state.settings.flush) stdout.flush();
        quit!(Yes.priority)(plugin.state, string.init, Yes.quiet);
    }

    logger.trace();
    logger.info("-- Spotify authorisation key generation mode --");
    enum message =
"To access the Spotify API you need a <i>client ID</> and a <i>client secret</>.

<l>Go here to create a project and generate said credentials:</>

    <i>https://developer.spotify.com/dashboard</>

Make sure to go into <l>Edit Settings</> and add <i>http://localhost</> as a
redirect URI. (You need to press the <i>Add</> button for it to save.)
Additionally, add your user under <l>Users and Access</>.

You also need to supply a channel for which it all relates.
(Channels are Twitch lowercase account names, prepended with a '<i>#</>' sign.)

Lastly you need a <i>playlist ID</> for song requests to work.
A normal URL to any playlist you can modify will work fine.
";
    writeln(message.expandTags(LogLevel.off));

    Credentials creds;

    immutable channel = readNamedString("<l>Enter your <i>#channel<l>:</> ",
        0L, *plugin.state.abort);
    if (*plugin.state.abort) return;

    creds.spotifyClientID = readNamedString("<l>Copy and paste your <i>OAuth client ID<l>:</> ",
        32L, *plugin.state.abort);
    if (*plugin.state.abort) return;

    creds.spotifyClientSecret = readNamedString("<l>Copy and paste your <i>OAuth client secret<l>:</> ",
        32L, *plugin.state.abort);
    if (*plugin.state.abort) return;

    while (!creds.spotifyPlaylistID.length)
    {
        enum playlistIDLength = 22;

        immutable playlistURL = readNamedString("<l>Copy and paste your <i>playlist URL<l>:</> ",
            0L, *plugin.state.abort);
        if (*plugin.state.abort) return;

        if (playlistURL.length == playlistIDLength)
        {
            // Likely a playlist ID
            creds.spotifyPlaylistID = playlistURL;
        }
        else if (playlistURL.contains("spotify.com/playlist/"))
        {
            string slice = playlistURL;  // mutable
            slice.nom("spotify.com/playlist/");
            creds.spotifyPlaylistID = slice.nom!(Yes.inherit)('?');
        }
        else
        {
            writeln();
            enum invalidMessage = "Cannot recognise link as a Spotify playlist URL. " ~
                "Try copying again or file a bug.";
            logger.error(invalidMessage.expandTags(LogLevel.error));
            writeln();
            continue;
        }
    }

    enum attemptToOpenPattern = `
--------------------------------------------------------------------------------

<l>Attempting to open a Spotify login page in your default web browser.</>

Follow the instructions and log in to authorise the use of this program with your account.

<l>Then paste the address of the empty page you are redirected to afterwards here.</>

* The redirected address should start with <i>http://localhost</>.
* It will probably say "<l>this site can't be reached</>" or "<l>unable to connect</>".
* If you are running local web server on port <i>80</>, you may have to temporarily
  disable it for this to work.
`;
    writeln(attemptToOpenPattern.expandTags(LogLevel.off));
    if (plugin.state.settings.flush) stdout.flush();

    enum authNode = "https://accounts.spotify.com/authorize";
    enum urlPattern = authNode ~
        "?client_id=%s" ~
        "&client_secret=%s" ~
        "&redirect_uri=http://localhost" ~
        "&response_type=code" ~
        "&scope=playlist-modify-private playlist-modify-public";
    immutable url = urlPattern.format(creds.spotifyClientID, creds.spotifyClientSecret);

    Pid browser;
    scope(exit) if (browser !is null) wait(browser);

    if (plugin.state.settings.force)
    {
        logger.warning("Forcing; not automatically opening browser.");
        printManualURL(url);
        if (plugin.state.settings.flush) stdout.flush();
    }
    else
    {
        try
        {
            import kameloso.platform : openInBrowser;
            browser = openInBrowser(url);
        }
        catch (ProcessException e)
        {
            // Probably we got some platform wrong and command was not found
            logger.warning("Error: could not automatically open browser.");
            printManualURL(url);
            if (plugin.state.settings.flush) stdout.flush();
        }
    }

    string code;

    while (!code.length)
    {
        scope(exit) if (plugin.state.settings.flush) stdout.flush();

        enum pattern = "<l>Paste the address of the page you were redirected to here (empty line exits):</>
> ";
        write(pattern.expandTags(LogLevel.off));
        stdout.flush();

        stdin.flush();
        immutable readCode = readln().stripped;

        if (*plugin.state.abort || !readCode.length)
        {
            writeln();
            logger.warning("Aborting.");
            logger.trace();
            *plugin.state.abort = true;
            return;
        }

        if (!readCode.contains("code="))
        {
            import lu.string : beginsWith;

            writeln();

            if (readCode.beginsWith(authNode))
            {
                enum wrongPagePattern = "Not that page; the empty page you're " ~
                    "lead to after clicking <l>Allow</>.";
                logger.error(wrongPagePattern.expandTags(LogLevel.error));
            }
            else
            {
                logger.error("Could not make sense of URL. Try again or file a bug.");
            }

            writeln();
            continue;
        }

        string slice = readCode;  // mutable
        slice.nom("?code=");
        code = slice;

        if (!code.length)
        {
            writeln();
            logger.error("Invalid code length. Try copying again or file a bug.");
            writeln();
            code = string.init;  // reset it so the while loop repeats
        }
    }

    // All done, fetch
    auto client = getHTTPClient();
    getSpotifyTokens(client, creds, code);

    if (auto storedCreds = channel in plugin.secretsByChannel)
    {
        import lu.meld : MeldingStrategy, meldInto;
        creds.meldInto!(MeldingStrategy.aggressive)(*storedCreds);
    }
    else
    {
        plugin.secretsByChannel[channel] = creds;
    }

    saveSecretsToDisk(plugin.secretsByChannel, plugin.secretsFile);

    enum issuePattern = "
--------------------------------------------------------------------------------

All done! Restart the program (without <i>--set twitch.spotifyKeygen</>)
and it should just work. If it doesn't, please file an issue at:

    <i>https://github.com/zorael/kameloso/issues/new</>
";
    writefln(issuePattern.expandTags(LogLevel.off), plugin.secretsFile);
    if (plugin.state.settings.flush) stdout.flush();
}


// getSpotifyTokens
/++
    Request OAuth API tokens from Spotify.

    Params:
        client = [arsd.http2.HttpClient|HttpClient] to use.
        creds = Credentials aggregate.
        code = Spotify authorization code.
 +/
void getSpotifyTokens(HttpClient client, ref Credentials creds, const string code)
{
    import arsd.http2 : FormData, HttpVerb, Uri;
    import std.format : format;
    import std.json : JSONType, parseJSON;
    import std.string : indexOf;

    enum node = "https://accounts.spotify.com/api/token";
    enum urlPattern = node ~
        "?code=%s" ~
        "&grant_type=authorization_code" ~
        "&redirect_uri=http://localhost";
    immutable url = urlPattern.format(code);

    if (!client.authorization.length) client.authorization = getSpotifyBase64Authorization(creds);
    auto req = client.request(Uri(url), HttpVerb.POST);
    req.requestParameters.contentType = "application/x-www-form-urlencoded";
    auto res = req.waitForCompletion();

    /*
    {
        "access_token": "[redacted]",
        "token_type": "Bearer",
        "expires_in": 3600,
        "refresh_token": "[redacted]",
        "scope": "playlist-modify-private playlist-modify-public"
    }
    */

    const json = parseJSON(res.contentText);

    if (json.type != JSONType.object)
    {
        throw new SongRequestJSONTypeMismatchException(
            "Wrong JSON type in token request response", json);
    }

    if (auto errorJSON = "error" in json) throw new SongRequestTokenException(errorJSON.str);

    creds.spotifyAccessToken = json["access_token"].str;
    creds.spotifyRefreshToken = json["refresh_token"].str;
}


// refreshSpotifyToken
/++
    Refreshes the OAuth API token in the passed Spotify credentials.

    Params:
        client = [arsd.http2.HttpClient|HttpClient] to use.
        creds = Credentials aggregate.
 +/
void refreshSpotifyToken(HttpClient client, ref Credentials creds)
{
    import arsd.http2 : FormData, HttpVerb, Uri;
    import std.format : format;
    import std.json : JSONType, parseJSON;
    import std.string : indexOf;

    enum node = "https://accounts.spotify.com/api/token";
    enum urlPattern = node ~
        "?refresh_token=%s" ~
        "&grant_type=refresh_token";
    immutable url = urlPattern.format(creds.spotifyRefreshToken);

    /*if (!client.authorization.length)*/ client.authorization = getSpotifyBase64Authorization(creds);
    auto req = client.request(Uri(url), HttpVerb.POST);
    req.requestParameters.contentType = "application/x-www-form-urlencoded";
    auto res = req.waitForCompletion();

    /*
    {
        "access_token": "[redacted]",
        "token_type": "Bearer",
        "expires_in": 3600,
        "scope": "playlist-modify-private playlist-modify-public"
    }
    */

    const json = parseJSON(res.contentText);

    if (json.type != JSONType.object)
    {
        throw new SongRequestJSONTypeMismatchException(
            "Wrong JSON type in token refresh response", json);
    }

    if (auto errorJSON = "error" in json) throw new SongRequestTokenException(errorJSON.str);

    creds.spotifyAccessToken = json["access_token"].str;
    // refreshToken is not present and stays the same as before
}


// getBase64Authorization
/++
    Construts a `Basic` OAuth authorisation string based on the Spotify client ID
    and client secret.

    Params:
        creds = Credentials aggregate.

    Returns:
        A string to be used as a `Basic` authorisation token.
 +/
auto getSpotifyBase64Authorization(const Credentials creds)
{
    import std.base64 : Base64;
    import std.conv : text;

    auto decoded = cast(ubyte[])text(creds.spotifyClientID, ':', creds.spotifyClientSecret);
    return "Basic " ~ cast(string)Base64.encode(decoded);
}


// addTrackToSpotifyPlaylist
/++
    Adds a track to the Spotify playlist whose ID is stored in the passed [Credentials].

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitchbot.base.TwitchBotPlugin|TwitchBotPlugin].
        creds = Credentials aggregate.
        trackID = Spotify track ID of the track to add.
        recursing = Whether or not the function is recursing into iself.

    Returns:
        A [std.json.JSONValue|JSONValue] of the response.
 +/
package JSONValue addTrackToSpotifyPlaylist(
    TwitchBotPlugin plugin,
    ref Credentials creds,
    const string trackID,
    const Flag!"recursing" recursing = No.recursing)
in (Fiber.getThis, "Tried to call `addVideoToSpotifyPlaylist` from outside a Fiber")
{
    import kameloso.plugins.twitchbot.api : getUniqueNumericalID, waitForQueryResponse;
    import kameloso.plugins.common.delayawait : delay;
    import kameloso.thread : ThreadMessage;
    import arsd.http2 : HttpVerb;
    import std.algorithm.searching : endsWith;
    import std.concurrency : prioritySend, send;
    import std.format : format;
    import std.json : JSONType, parseJSON;
    import core.time : msecs;

    // https://api.spotify.com/v1/playlists/0nqAHNphIb3Qhh5CmD7fg5/tracks?uris=spotify:track:594WPgqPOOy0PqLvScovNO

    enum urlPattern = "https://api.spotify.com/v1/playlists/%s/tracks?uris=spotify:track:%s";
    immutable url = urlPattern.format(creds.spotifyPlaylistID, trackID);

    if (plugin.state.settings.trace)
    {
        import kameloso.common : Tint, logger;
        logger.trace("GET: ", Tint.info, url);
    }

    static string authorizationBearer;

    if (!authorizationBearer.length || !authorizationBearer.endsWith(creds.spotifyAccessToken))
    {
        authorizationBearer = "Bearer " ~ creds.spotifyAccessToken;
    }

    immutable ubyte[] data;
    /*immutable*/ int id = getUniqueNumericalID(plugin.bucket);
    plugin.state.mainThread.prioritySend(ThreadMessage.shortenReceiveTimeout());
    plugin.persistentWorkerTid.send(id, url, authorizationBearer, HttpVerb.POST, data, string.init);
    static immutable guesstimatePeriodToWaitForCompletion = 300.msecs;
    delay(plugin, guesstimatePeriodToWaitForCompletion, Yes.yield);
    immutable response = waitForQueryResponse(plugin, id);

    /*
    {
        "snapshot_id" : "[redacted]"
    }
    */
    /*
    {
        "error": {
            "status": 401,
            "message": "The access token expired"
        }
    }
    */

    const json = parseJSON(response.str);

    if (json.type != JSONType.object)
    {
        throw new SongRequestJSONTypeMismatchException(
            "Wrong JSON type in playlist append response", json);
    }

    if (auto errorJSON = "error" in json)
    {
        if (recursing)
        {
            throw new SongRequestException(errorJSON.object["message"].str);
        }
        else if (auto messageJSON = "message" in errorJSON.object)
        {
            if (messageJSON.str == "The access token expired")
            {
                refreshSpotifyToken(getHTTPClient(), creds);
                saveSecretsToDisk(plugin.secretsByChannel, plugin.secretsFile);
                return addTrackToSpotifyPlaylist(plugin, creds, trackID, Yes.recursing);
            }
        }

        throw new SongRequestException(errorJSON.object["message"].str);
    }

    return json;
}


// getSpotifyTrackByID
/++
    Fetches information about a Spotify track by its ID and returns the JSON response.

    Params:
        creds = Credentials aggregate.
        trackID = Spotify track ID string.

    Returns:
        A [std.json.JSONValue|JSONValue] of the response.
 +/
package auto getSpotifyTrackByID(Credentials creds, const string trackID)
{
    import arsd.http2 : Uri;
    import std.algorithm.searching : endsWith;
    import std.format : format;
    import std.json : JSONType, parseJSON;

    enum urlPattern = "https://api.spotify.com/v1/tracks/%s";
    immutable url = urlPattern.format(trackID);
    auto client = getHTTPClient();

    if (!client.authorization.length || !client.authorization.endsWith(creds.spotifyAccessToken))
    {
        client.authorization = "Bearer " ~ creds.spotifyAccessToken;
    }

    auto req = client.request(Uri(url));
    auto res = req.waitForCompletion();

    auto json = parseJSON(res.contentText);

    if (json.type != JSONType.object)
    {
        throw new SongRequestJSONTypeMismatchException(
            "Wrong JSON type in track request response", json);
    }

    return json;
}