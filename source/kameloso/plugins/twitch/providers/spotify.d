/++
    Bits and bobs to get Spotify API credentials for playlist management.

    See_Also:
        [kameloso.plugins.twitch],
        [kameloso.plugins.twitch.api],
        [kameloso.plugins.twitch.providers.common],
        [kameloso.plugins]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.twitch.providers.spotify;

version(TwitchSupport):
version(WithTwitchPlugin):

private:

import kameloso.plugins.twitch;
import kameloso.plugins.twitch.common;
import kameloso.plugins.twitch.providers.common;
import kameloso.common : logger;
import core.thread.fiber : Fiber;

public:


// requestSpotifyKeys
/++
    Requests a Spotify API authorisation code from Spotify servers, then uses it
    to obtain an access key and a refresh OAuth key.

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].

    Throws:
        [kameloso.plugins.twitch.common.UnexpectedJSONException|UnexpectedJSONException]
        on unexpected JSON.

        [kameloso.plugins.twitch.common.ErrorJSONException|ErrorJSONException]
        if the returned JSON has an `"error"` field.
 +/
void requestSpotifyKeys(TwitchPlugin plugin)
{
    import kameloso.logger : LogLevel;
    import kameloso.terminal.colours.tags : expandTags;
    import lu.string : advancePast, stripped;
    import std.algorithm.searching : canFind;
    import std.format : format;
    import std.process : Pid, ProcessException, wait;
    import std.stdio : File, readln, stdin, stdout, write, writeln;

    scope(exit) if (plugin.state.coreSettings.flush) stdout.flush();

    logger.trace();
    logger.log("== <w>Spotify authorisation key generation wizard</> ==");
    enum message = `
To access the Spotify API you need to create what Spotify calls an <i>app</>,
and generate a <i>client ID</> and a <i>client secret</> for it.

<l>Go here to create an app:</>

    <i>https://developer.spotify.com/dashboard</>

<i>*</> <l>Select</> <i>Create app</>
  <i>*</> <l>Input something memorable</> as <i>Name</> and <i>Description</>
  <i>*</> <l>Input</> as <i>Redirect URI</>: "<i>http://localhost</>"
  <i>*</> <l>Click</> <i>Save</>
<i>*</> <l>Click</> <i>Settings</> in the top right
<i>*</> <l>Go to</> <i>User Management</>
  <i>*</> <l>Add</> your Spotify user's <i>email</> address

It should now display a <i>Client ID</> and <i>Client secret</>.

    <w>Copy these somewhere; you'll need them soon.</>

You also need to supply a Twitch channel to which it all relates.
(Channels are Twitch lowercase account names, prepended with a '<i>#</>' sign.)

Lastly you need a <i>Spotify playlist ID</> for song requests to work.
New playlists can be created by clicking the <i>+</> next to <i>Your library</>
in the panel to the left on the home screen.

A normal URL to any playlist you can modify will work fine.
`;
    writeln(message.expandTags(LogLevel.off));

    Credentials creds;
    string channel;  // mutable
    uint numEmptyLinesEntered;

    while (!channel.length)
    {
        bool benignAbort;

        channel = readChannelName(
            numEmptyLinesEntered,
            benignAbort,
            plugin.state.abort);

        if (*plugin.state.abort || benignAbort) return;
    }

    enum readOAuthIDMessage = "<l>Copy and paste your <i>OAuth Client ID<l>:</> ";
    creds.spotifyClientID = readNamedString(
        readOAuthIDMessage,
        32L,
        passThroughEmptyString: false,
        plugin.state.abort);
    if (*plugin.state.abort) return;

    enum readOAuthSecretMessage = "<l>Copy and paste your <i>OAuth Client secret<l>:</> ";
    creds.spotifyClientSecret = readNamedString(
        readOAuthSecretMessage,
        32L,
        passThroughEmptyString: false,
        plugin.state.abort);
    if (*plugin.state.abort) return;

    while (!creds.spotifyPlaylistID.length)
    {
        enum playlistIDLength = 22;
        enum readPlaylistMessage = "<l>Copy and paste your <i>Spotify playlist URL<l>:</> ";
        immutable playlistURL = readNamedString(
            readPlaylistMessage,
            0L,
            passThroughEmptyString: false,
            plugin.state.abort);
        if (*plugin.state.abort) return;

        if (playlistURL.length == playlistIDLength)
        {
            // Likely a playlist ID
            creds.spotifyPlaylistID = playlistURL;
        }
        else if (playlistURL.canFind("spotify.com/playlist/"))
        {
            string slice = playlistURL;  // mutable
            slice.advancePast("spotify.com/playlist/");
            creds.spotifyPlaylistID = slice.advancePast('?', inherit: true);
        }
        else
        {
            writeln();
            enum invalidMessage = "Cannot recognise link as a Spotify playlist URL. " ~
                "Try copying again or file a bug.";
            logger.error(invalidMessage);
            writeln();
            continue;
        }
    }

    enum attemptToOpenMessage = `
--------------------------------------------------------------------------------

<l>Attempting to open the <i>Spotify redirect page<l> in your default web browser.</>

Click <i>Agree</> to authorise the use of this program with your account.`;

    writeln(attemptToOpenMessage.expandTags(LogLevel.off));
    writeln(pasteAddressInstructions.expandTags(LogLevel.off));
    stdout.flush();

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

    if (plugin.state.coreSettings.force)
    {
        logger.warning("Forcing; not automatically opening browser.");
        printManualURL(url);
        if (plugin.state.coreSettings.flush) stdout.flush();
    }
    else
    {
        try
        {
            import kameloso.platform : openInBrowser;
            browser = openInBrowser(url);
        }
        catch (ProcessException _)
        {
            // Probably we got some platform wrong and command was not found
            logger.warning("Error: could not automatically open browser.");
            printManualURL(url);
            if (plugin.state.coreSettings.flush) stdout.flush();
        }
        catch (Exception _)
        {
            logger.warning("Error: no graphical environment detected");
            printManualURL(url);
            if (plugin.state.coreSettings.flush) stdout.flush();
        }
    }

    string code;  // mutable
    uint numEmptyAddressLinesEntered;
    enum numEmptyAddressLinesEnteredBreakpoint = 2;

    while (!code.length)
    {
        scope(exit) if (plugin.state.coreSettings.flush) stdout.flush();

        enum pasteMessage = "<i>></> ";
        write(pasteMessage.expandTags(LogLevel.off));
        stdout.flush();
        stdin.flush();
        immutable input = readln().stripped;

        if (*plugin.state.abort)
        {
            writeln();
            logger.warning("Aborting.");
            logger.trace();
            *plugin.state.abort = true;
            return;
        }
        else if (!input.length)
        {
            if (++numEmptyAddressLinesEntered > numEmptyAddressLinesEnteredBreakpoint)
            {
                enum cancellingKeygenMessage = "Cancelling keygen.";
                logger.warning(cancellingKeygenMessage);
                logger.trace();
                return;
            }
            continue;
        }

        if (!input.canFind("code="))
        {
            import std.algorithm.searching : startsWith;

            writeln();

            if (input.startsWith(authNode))
            {
                enum wrongPageMessage = "Not that page; the empty page you're " ~
                    "lead to after clicking <l>Allow</>.";
                logger.error(wrongPageMessage);
            }
            else
            {
                logger.error("Could not make sense of URL. Try again or file a bug.");
            }

            writeln();
            continue;
        }

        string slice = input;  // mutable
        slice.advancePast("?code=");
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
    getSpotifyTokens(creds, code, plugin.state.connSettings.caBundleFile);

    writeln();
    logger.info("Validating...");

    immutable validationJSON = validateSpotifyToken(creds, plugin.state.connSettings.caBundleFile);
    if (*plugin.state.abort) return;

    scope(failure)
    {
        import std.stdio : writeln;
        writeln(validationJSON.toPrettyString);
    }

    if (immutable errorJSON = "error" in validationJSON)
    {
        throw new ErrorJSONException((*errorJSON)["message"].str, *errorJSON);
    }
    else if ("display_name" !in validationJSON)
    {
        throw new UnexpectedJSONException(
            "Unexpected JSON response from server",
            validationJSON);
    }

    logger.info("All done!");
    logger.trace();

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
}


// getSpotifyTokens
/++
    Request OAuth API tokens from Spotify.

    Params:
        creds = [kameloso.plugins.twitch.Credentials|Credentials] aggregate.
        code = Spotify authorisation code.
        caBundleFile = Path to a `cacert.pem` bundle file.

    Throws:
        [kameloso.plugins.twitch.common.UnexpectedJSONException|UnexpectedJSONException]
        on unexpected JSON.

        [kameloso.plugins.twitch.common.ErrorJSONException|ErrorJSONException]
        if the returned JSON has an `"error"` field.
 +/
private void getSpotifyTokens(
    ref Credentials creds,
    const string code,
    const string caBundleFile)
{
    import kameloso.plugins.twitch.api : sendHTTPRequestImpl;
    import kameloso.tables : HTTPVerb;
    import std.format : format;
    import std.json : JSONType, parseJSON;

    enum node = "https://accounts.spotify.com/api/token";
    enum urlPattern = node ~
        "?code=%s" ~
        "&grant_type=authorization_code" ~
        "&redirect_uri=http://localhost";
    immutable url = urlPattern.format(code);

    immutable res = sendHTTPRequestImpl(
        url,
        getSpotifyBase64Authorization(creds),
        caBundleFile,
        HTTPVerb.post,
        cast(ubyte[])null,
        "application/x-www-form-urlencoded");
    immutable json = parseJSON(res.str);

    /*
    {
        "access_token": "[redacted]",
        "token_type": "Bearer",
        "expires_in": 3600,
        "refresh_token": "[redacted]",
        "scope": "playlist-modify-private playlist-modify-public"
    }
     */

    if (json.type != JSONType.object)
    {
        throw new UnexpectedJSONException("Wrong JSON type in token request response", json);
    }

    if (immutable errorJSON = "error" in json)
    {
        throw new ErrorJSONException(errorJSON.str, *errorJSON);
    }

    creds.spotifyAccessToken = json["access_token"].str;
    creds.spotifyRefreshToken = json["refresh_token"].str;
}


// refreshSpotifyToken
/++
    Refreshes the OAuth API token in the passed Spotify credentials.

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        creds = [kameloso.plugins.twitch.Credentials|Credentials] aggregate.

    Throws:
        [kameloso.plugins.twitch.common.UnexpectedJSONException|UnexpectedJSONException]
        on unexpected JSON.

        [kameloso.plugins.twitch.common.ErrorJSONException|ErrorJSONException]
        if the returned JSON has an `"error"` field.
 +/
private void refreshSpotifyToken(TwitchPlugin plugin, ref Credentials creds)
in (Fiber.getThis(), "Tried to call `refreshSpotifyToken` from outside a fiber")
{
    import kameloso.plugins.twitch.api : sendHTTPRequest;
    import kameloso.tables : HTTPVerb;
    import std.format : format;
    import std.json : JSONType, parseJSON;

    enum node = "https://accounts.spotify.com/api/token";
    enum urlPattern = node ~
        "?refresh_token=%s" ~
        "&grant_type=refresh_token";
    immutable url = urlPattern.format(creds.spotifyRefreshToken);

    immutable res = sendHTTPRequest(
        plugin,
        url,
        __FUNCTION__,
        getSpotifyBase64Authorization(creds),
        HTTPVerb.post,
        cast(ubyte[])null,
        "application/x-www-form-urlencoded");
    immutable json = parseJSON(res.str);

    /*
    {
        "access_token": "[redacted]",
        "token_type": "Bearer",
        "expires_in": 3600,
        "scope": "playlist-modify-private playlist-modify-public"
    }
     */

    if (json.type != JSONType.object)
    {
        throw new UnexpectedJSONException("Wrong JSON type in token refresh response", json);
    }

    if (immutable errorJSON = "error" in json)
    {
        throw new ErrorJSONException(errorJSON.str, *errorJSON);
    }

    creds.spotifyAccessToken = json["access_token"].str;
    // refreshToken is not present and stays the same as before
}


// getBase64Authorization
/++
    Constructs a `Basic` OAuth authorisation string based on the Spotify client ID
    and client secret.

    Params:
        creds = [kameloso.plugins.twitch.Credentials|Credentials] aggregate.

    Returns:
        A string to be used as a `Basic` authorisation token.
 +/
private auto getSpotifyBase64Authorization(const Credentials creds)
{
    import std.base64 : Base64;
    import std.conv : text;

    auto decoded = cast(ubyte[])text(creds.spotifyClientID, ':', creds.spotifyClientSecret);
    return "Basic " ~ cast(string)Base64.encode(decoded);
}


// addTrackToSpotifyPlaylist
/++
    Adds a track to the Spotify playlist whose ID is stored in the passed
    [kameloso.plugins.twitch.Credentials|Credentials].

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        creds = [kameloso.plugins.twitch.Credentials|Credentials] aggregate.
        trackID = Spotify track ID of the track to add.
        recursing = Whether or not the function is recursing into itself.

    Returns:
        A [std.json.JSONValue|JSONValue] of the response.

    Throws:
        [kameloso.plugins.twitch.common.UnexpectedJSONException|UnexpectedJSONException]
        on unexpected JSON.

        [kameloso.plugins.twitch.common.ErrorJSONException|ErrorJSONException]
        if the returned JSON has an `"error"` field.
 +/
auto addTrackToSpotifyPlaylist(
    TwitchPlugin plugin,
    ref Credentials creds,
    const string trackID,
    const bool recursing = false)
in (Fiber.getThis(), "Tried to call `addTrackToSpotifyPlaylist` from outside a fiber")
{
    import kameloso.plugins.twitch.api : sendHTTPRequest;
    import kameloso.tables : HTTPVerb;
    import std.algorithm.searching : endsWith;
    import std.format : format;
    import std.json : JSONType, parseJSON;

    // https://api.spotify.com/v1/playlists/0nqAHNphIb3Qhh5CmD7fg5/tracks?uris=spotify:track:594WPgqPOOy0PqLvScovNO

    enum urlPattern = "https://api.spotify.com/v1/playlists/%s/tracks?uris=spotify:track:%s";
    immutable url = urlPattern.format(creds.spotifyPlaylistID, trackID);

    if (plugin.state.coreSettings.trace)
    {
        import kameloso.common : logger;
        enum pattern = "GET: <i>%s";
        logger.tracef(pattern, url);
    }

    static string authorizationBearer;

    if (!authorizationBearer.length || !authorizationBearer.endsWith(creds.spotifyAccessToken))
    {
        authorizationBearer = "Bearer " ~ creds.spotifyAccessToken;
    }

    immutable res = sendHTTPRequest(
        plugin,
        url,
        __FUNCTION__,
        authorizationBearer,
        HTTPVerb.post,
        cast(ubyte[])null,
        "application/json");
    immutable json = parseJSON(res.str);

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

    if (json.type != JSONType.object)
    {
        throw new UnexpectedJSONException("Wrong JSON type in playlist append response", json);
    }

    immutable errorJSON = "error" in json;
    if (!errorJSON) return json;  // Success

    if (immutable messageJSON = "message" in *errorJSON)
    {
        if (messageJSON.str == "The access token expired")
        {
            if (recursing)
            {
                throw new InvalidCredentialsException(messageJSON.str, *errorJSON);
            }
            else
            {
                refreshSpotifyToken(plugin, creds);
                saveSecretsToDisk(plugin.secretsByChannel, plugin.secretsFile);
                return addTrackToSpotifyPlaylist(plugin, creds, trackID, recursing: true);
            }
        }

        throw new ErrorJSONException(messageJSON.str, *errorJSON);
    }

    // If we're here, the above didn't match
    throw new ErrorJSONException(errorJSON.object["message"].str, *errorJSON);
}


// getSpotifyTrackByID
/++
    Fetches information about a Spotify track by its ID and returns the JSON response.

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        creds = [kameloso.plugins.twitch.Credentials|Credentials] aggregate.
        trackID = Spotify track ID string.

    Returns:
        A [std.json.JSONValue|JSONValue] of the response.

    Throws:
        [kameloso.plugins.twitch.common.UnexpectedJSONException|UnexpectedJSONException]
        on unexpected JSON.

        [kameloso.plugins.twitch.common.ErrorJSONException|ErrorJSONException]
        if the returned JSON has an `"error"` field.
 +/
auto getSpotifyTrackByID(
    TwitchPlugin plugin,
    const Credentials creds,
    const string trackID)
in (Fiber.getThis(), "Tried to call `getSpotifyTrackByID` from outside a fiber")
{
    import kameloso.plugins.twitch.api : sendHTTPRequest;
    import std.algorithm.searching : endsWith;
    import std.format : format;
    import std.json : JSONType, parseJSON;

    static string authorizationBearer;

    if (!authorizationBearer.length || !authorizationBearer.endsWith(creds.spotifyAccessToken))
    {
        authorizationBearer = "Bearer " ~ creds.spotifyAccessToken;
    }

    enum urlPattern = "https://api.spotify.com/v1/tracks/%s";
    immutable url = urlPattern.format(trackID);

    immutable res = sendHTTPRequest(
        plugin,
        url,
        __FUNCTION__,
        getSpotifyBase64Authorization(creds));
    immutable json = parseJSON(res.str);

    if (json.type != JSONType.object)
    {
        throw new UnexpectedJSONException("Wrong JSON type in track request response", json);
    }

    if (const errorJSON = "error" in json)
    {
        throw new ErrorJSONException(errorJSON.str, *errorJSON);
    }

    return json;
}


// validateSpotifyToken
/++
    Validates a Spotify OAuth token by issuing a simple request for user
    information, returning the JSON received.

    Params:
        creds = [kameloso.plugins.twitch.Credentials|Credentials] aggregate.
        caBundleFile = Path to a `cacert.pem` bundle file.

    Returns:
        The server [std.json.JSONValue|JSONValue] response.

    Throws:
        [kameloso.plugins.twitch.common.UnexpectedJSONException|UnexpectedJSONException]
        on unexpected JSON.

        [kameloso.plugins.twitch.common.ErrorJSONException|ErrorJSONException]
        if the returned JSON has an `"error"` field.
 +/
private auto validateSpotifyToken(ref Credentials creds, const string caBundleFile)
{
    import kameloso.plugins.twitch.api : sendHTTPRequestImpl;
    import std.json : JSONType, parseJSON;

    enum url = "https://api.spotify.com/v1/me";
    immutable authorizationBearer = "Bearer " ~ creds.spotifyAccessToken;

    immutable res = sendHTTPRequestImpl(
        url,
        authorizationBearer,
        caBundleFile);
    immutable json = parseJSON(res.str);

    /*
    {
        "error": {
            "message": "The access token expired",
            "status": 401
        }
    }
     */
    /*
    {
        "display_name": "zorael",
        "external_urls": {
            "spotify": "https:\/\/open.spotify.com\/user\/zorael"
        },
        "followers": {
            "href": null,
            "total": 0
        },
        "href": "https:\/\/api.spotify.com\/v1\/users\/zorael",
        "id": "zorael",
        "images": [],
        "type": "user",
        "uri": "spotify:user:zorael"
    }
     */

    if (json.type != JSONType.object)
    {
        throw new UnexpectedJSONException("Wrong JSON type in token validation response", json);
    }

    if (immutable errorJSON = "error" in json)
    {
        throw new ErrorJSONException(errorJSON.str, *errorJSON);
    }

    return json;
}
