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
import kameloso.net : HTTPQueryException, UnexpectedJSONException;
import core.thread.fiber : Fiber;

public:


// requestSpotifyKeys
/++
    Requests a Spotify API authorisation code from Spotify servers, then uses it
    to obtain an access key and a refresh OAuth key.

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].

    Throws:
        [kameloso.net.UnexpectedJSONException|UnexpectedJSONException] on unexpected JSON.
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

    enum dashboardURL = "https://developer.spotify.com/dashboard";

    logger.trace();
    logger.log("== <w>Spotify authorisation key generation wizard</> ==");
    enum preludeMessage = `
To access the Spotify API you need to create what Spotify calls an <i>app</>,
and generate a <i>Client ID</> and a <i>Client secret</> for it.

<l>Attempting to open the <i>Spotify developer dashboard<l> in your default web browser.</>
`;
    writeln(preludeMessage.expandTags(LogLevel.off));

    if (plugin.state.coreSettings.force)
    {
        logger.warning("Forcing; not automatically opening browser.");
        printManualURL(dashboardURL);
        if (plugin.state.coreSettings.flush) stdout.flush();
    }
    else
    {
        try
        {
            import kameloso.platform : openInBrowser;
            openInBrowser(dashboardURL);
        }
        catch (ProcessException _)
        {
            // Probably we got some platform wrong and command was not found
            logger.warning("Error: could not automatically open browser.");
            printManualURL(dashboardURL);
            if (plugin.state.coreSettings.flush) stdout.flush();
        }
        catch (Exception _)
        {
            logger.warning("Error: no graphical environment detected");
            printManualURL(dashboardURL);
            if (plugin.state.coreSettings.flush) stdout.flush();
        }
    }

    enum message =
`If not already logged in...

<i>*</> <l>Log in</> to your Spotify user account
<i>*</> <l>Click</> your user badge in the top right and <l>select</> <i>Dashboard</>

Once in the dashboard...

<i>*</> <l>Select</> <i>Create app</>
  <i>*</> <l>Enter</> an <i>App name</> (anything you want)
  <i>*</> <l>Enter</> a <i>Description</> (anything you want)
  <i>*</> <l>Enter</> as <i>Redirect URIs</>: "<i>http://localhost</>" and <l>click</> <i>Add</>
    <i>*</> If you are running local web server on port <i>80</>, you may have to temporarily
      disable it for this to work.
  <i>*</> <l>Check</> <i>API/SDKs</>: <i>Web API</>
  <i>*</> <l>Agree</> to the <i>terms</>
  <i>*</> <l>Click</> <i>Save</>
<i>*</> <l>Click</> <i>Settings</> in the top right
<i>*</> <l>Select</> the <i>User Management</> tab
  <i>*</> <l>Add</> an entry with a <i>name</> and your Spotify user's <i>email</> address
<i>*</> <l>Select</> the <i>Basic Information</> tab
  <i>*</> <l>Copy</> the <i>Client ID</> by clicking the <i>clipboard icon</> next to it
    <i>*</> <l>Paste</> it somewhere, you'll need it soon
  <i>*</> <l>Click</> <i>View Client Secret</>
    <i>*</> <l>Copy</> the <i>Client secret</> by clicking the <i>cliboard icon</> next to it
      <i>*</> <l>Paste</> it next to your <i>Client ID</> so you have both ready

You also need to supply a <i>Twitch channel</> in which you would serve song requests.
(Channels are Twitch lowercase account names, prepended with a '<i>#</>' sign.)

Lastly you need a <i>Spotify playlist</> which song requests would be added to.
New playlists can be created by clicking the <i>+</> next to <i>Your library</>
in the panel to the left on the home screen.

A normal URL to any playlist your Spotify user can modify will work fine.
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

        enum pasteMessage = "<l>Paste the address of empty the page you were redirected to here:</>

<i>></> ";
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
    const getTokenResults = getSpotifyTokens(creds, code, plugin.state.connSettings.caBundleFile);

    if (!getTokenResults.success)
    {
        enum pattern = "Failed to get Spotify tokens: <l>%s";
        logger.errorf(pattern, getTokenResults.error);
        *plugin.state.abort = true;
        return;
    }

    creds.spotifyAccessToken = getTokenResults.accessToken;
    creds.spotifyRefreshToken = getTokenResults.refreshToken;

    writeln();
    logger.info("Validating...");

    const results = validateSpotifyToken(creds, plugin.state.connSettings.caBundleFile);
    if (*plugin.state.abort) return;

    if (!results.success)
    {
        enum pattern = "Failed to validate Spotify tokens: <l>%s";
        logger.errorf(pattern, results.error);
        *plugin.state.abort = true;
        return;
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

    Returns:
        A Voldemort of the results.

    Throws:
        [kameloso.net.UnexpectedJSONException|UnexpectedJSONException] on unexpected JSON.
 +/
private auto getSpotifyTokens(
    const Credentials creds,
    const string code,
    const string caBundleFile)
{
    import kameloso.net : HTTPRequest, issueSyncHTTPRequest;
    import kameloso.tables : HTTPVerb;
    import asdf.serialization : deserialize;
    import std.format : format;
    import core.time : Duration, seconds;

    alias Response = SpotifyTokenResponse;
    alias ErrorResponse = SpotifyErrorResponse;

    static struct GetTokenResults
    {
        uint code;
        string error;
        string accessToken;
        string tokenType;
        string refreshToken;
        string scope_;
        Duration expiresIn;

        auto success() const { return (code == 200); }

        this(const uint code, const Response response)
        {
            this.code = code;
            this.accessToken = response.access_token;
            this.tokenType = response.token_type;
            this.refreshToken = response.refresh_token;
            this.scope_ = response.scope_;
            this.expiresIn = response.expires_in.seconds;
        }

        this(const uint code, const ErrorResponse errorResponse)
        {
            this.code = code;
            this.error = errorResponse.error.message;
        }
    }

    enum node = "https://accounts.spotify.com/api/token";
    enum urlPattern = node ~
        "?code=%s" ~
        "&grant_type=authorization_code" ~
        "&redirect_uri=http://localhost";
    immutable url = urlPattern.format(code);

    const request = HTTPRequest(
        id: 0,
        url: url,
        authorisationHeader: getSpotifyBase64Authorization(creds),
        caBundleFile: caBundleFile,
        verb: HTTPVerb.post,
        contentType: "application/x-www-form-urlencoded");

    immutable httpResponse = issueSyncHTTPRequest(request);

    version(PrintStacktraces)
    {
        scope(failure)
        {
            import kameloso.misc : printStacktrace;
            import std.json : parseJSON;
            import std.stdio : writeln;

            writeln(httpResponse.code);
            writeln(httpResponse.body);
            try writeln(httpResponse.body.parseJSON.toPrettyString);
            catch (Exception _) {}
            printStacktrace();
        }
    }

    switch (httpResponse.code)
    {
    case 200:
        // 200 OK
        break;

    default:
        const errorResponse = httpResponse.body.deserialize!ErrorResponse;
        return GetTokenResults(httpResponse.code, errorResponse);
    }

    const response = httpResponse.body.deserialize!Response;
    return GetTokenResults(httpResponse.code, response);
}


// refreshSpotifyToken
/++
    Refreshes the OAuth API token in the passed Spotify credentials.

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        creds = [kameloso.plugins.twitch.Credentials|Credentials] aggregate.

    Returns:
        A Voldemort of the results.

    Throws:
        [kameloso.net.UnexpectedJSONException|UnexpectedJSONException] on unexpected JSON.
 +/
private auto refreshSpotifyToken(
    TwitchPlugin plugin,
    const Credentials creds)
in (Fiber.getThis(), "Tried to call `refreshSpotifyToken` from outside a fiber")
{
    import kameloso.plugins : sendHTTPRequest;
    import kameloso.tables : HTTPVerb;
    import asdf.serialization : deserialize;
    import std.format : format;
    import core.time : Duration, seconds;

    alias Response = SpotifyTokenResponse;
    alias ErrorResponse = SpotifyErrorResponse;

    static struct RefreshTokenResults
    {
        uint code;
        string error;
        string accessToken;
        string tokenType;
        string scope_;
        Duration expiresIn;

        auto success() const { return (code == 200); }

        this(const uint code, const Response response)
        {
            this.code = code;
            this.accessToken = response.access_token;
            this.tokenType = response.token_type;
            this.scope_ = response.scope_;
            this.expiresIn = response.expires_in.seconds;
        }

        this(const uint code, const ErrorResponse errorResponse)
        {
            this.code = code;
            this.error = errorResponse.error.message;
        }
    }

    enum node = "https://accounts.spotify.com/api/token";
    enum urlPattern = node ~
        "?refresh_token=%s" ~
        "&grant_type=refresh_token";

    immutable url = urlPattern.format(creds.spotifyRefreshToken);

    immutable httpResponse = sendHTTPRequest(
        plugin: plugin,
        url: url,
        authorisationHeader: getSpotifyBase64Authorization(creds),
        verb: HTTPVerb.post,
        contentType: "application/x-www-form-urlencoded");

    version(PrintStacktraces)
    {
        scope(failure)
        {
            import kameloso.misc : printStacktrace;
            import std.json : parseJSON;
            import std.stdio : writeln;

            writeln(httpResponse.code);
            writeln(httpResponse.body);
            try writeln(httpResponse.body.parseJSON.toPrettyString);
            catch (Exception _) {}
            printStacktrace();
        }
    }

    switch (httpResponse.code)
    {
    case 200:
        // 200 OK
        break;

    default:
        const errorResponse = httpResponse.body.deserialize!ErrorResponse;
        return RefreshTokenResults(httpResponse.code, errorResponse);
    }

    const response = httpResponse.body.deserialize!Response;
    return RefreshTokenResults(httpResponse.code, response);
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
        A Voldemort of the results.

    Throws:
        [kameloso.net.UnexpectedJSONException|UnexpectedJSONException] on unexpected JSON.
 +/
auto addTrackToSpotifyPlaylist(
    TwitchPlugin plugin,
    ref Credentials creds,
    const string trackID,
    const bool recursing = false)
in (Fiber.getThis(), "Tried to call `addTrackToSpotifyPlaylist` from outside a fiber")
{
    import kameloso.plugins : sendHTTPRequest;
    import kameloso.tables : HTTPVerb;
    import asdf.serialization : deserialize;
    import std.algorithm.searching : endsWith;
    import std.format : format;

    static struct Response
    {
        string snapshot_id;
    }

    alias ErrorResponse = SpotifyErrorResponse;

    static struct AddTrackResults
    {
        uint code;
        string error;
        string snapshotID;

        auto success() const { return code == 201; }

        this(const uint code, const Response response)
        {
            this.code = code;
            this.snapshotID = response.snapshot_id;
        }

        this(const uint code, const ErrorResponse errorResponse)
        {
            this.code = code;
            this.error = errorResponse.error.message;
        }
    }

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

    immutable httpResponse = sendHTTPRequest(
        plugin: plugin,
        url: url,
        caller: __FUNCTION__,
        authorisationHeader: authorizationBearer,
        verb: HTTPVerb.post);

    version(PrintStacktraces)
    {
        scope(failure)
        {
            import kameloso.misc : printStacktrace;
            import std.json : parseJSON;
            import std.stdio : writeln;

            writeln(httpResponse.code);
            writeln(httpResponse.body);
            try writeln(httpResponse.body.parseJSON.toPrettyString);
            catch (Exception _) {}
            printStacktrace();
        }
    }

    switch (httpResponse.code)
    {
    case 200:
        // 200 OK
        break;

    case 401:
        // 401 Unauthorized
        const errorResponse = httpResponse.body.deserialize!ErrorResponse;

        /*
        {
            "error": {
                "status": 401,
                "message": "The access token expired"
            }
        }
         */

        if (errorResponse.error.message == "The access token expired")
        {
            if (!recursing)
            {
                const results = refreshSpotifyToken(plugin, creds);

                if (!results.success)
                {
                    return AddTrackResults(httpResponse.code, errorResponse);
                }

                creds.spotifyAccessToken = results.accessToken;
                saveSecretsToDisk(plugin.secretsByChannel, plugin.secretsFile);
                return addTrackToSpotifyPlaylist(plugin, creds, trackID, recursing: true);
            }

            throw new InvalidCredentialsException(errorResponse.error.message);
        }

        return AddTrackResults(httpResponse.code, errorResponse);

    default:
        const errorResponse = httpResponse.body.deserialize!ErrorResponse;
        return AddTrackResults(httpResponse.code, errorResponse);
    }

    const response = httpResponse.body.deserialize!Response;
    return AddTrackResults(httpResponse.code, response);
}


// getSpotifyTrackByID
/++
    Fetches information about a Spotify track by its ID and returns the JSON response.

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        creds = [kameloso.plugins.twitch.Credentials|Credentials] aggregate.
        trackID = Spotify track ID string.
        recursing = Whether or not the function is recursing into itself.

    Returns:
        A Voldemort of the results.

    Throws:
        [kameloso.net.UnexpectedJSONException|UnexpectedJSONException] on unexpected JSON.
 +/
auto getSpotifyTrackByID(
    TwitchPlugin plugin,
    ref Credentials creds,
    const string trackID,
    bool recursing = false)
in (Fiber.getThis(), "Tried to call `getSpotifyTrackByID` from outside a fiber")
{
    import kameloso.plugins : sendHTTPRequest;
    import asdf.serialization : deserialize;
    import std.algorithm.searching : endsWith;
    import std.format : format;

    static struct Response
    {
        private import asdf.serialization : serdeIgnore, serdeOptional;

        @serdeOptional
        static struct Album
        {
            string name;
        }

        @serdeOptional
        static struct Artist
        {
            string name;
        }

        @serdeOptional
        static struct ExternalURLs
        {
            string spotify;
        }

        /*
        {
            "album": { ... },
            "artists": [ ... ],
            "available_markets": [ ... ],
            "disc_number": 1,
            "duration_ms": 52466,
            "explicit": false,
            "external_ids": {
                "isrc": "GBKBH0502201"
            },
            "external_urls": {
                "spotify": "https:\/\/open.spotify.com\/track\/70XGut7ZJrEK9h9Is1s3gt"
            },
            "href": "https:\/\/api.spotify.com\/v1\/tracks\/70XGut7ZJrEK9h9Is1s3gt",
            "id": "70XGut7ZJrEK9h9Is1s3gt",
            "is_local": false,
            "name": "Prelude",
            "popularity": 30,
            "preview_url": null,
            "track_number": 1,
            "type": "track",
            "uri": "spotify:track:70XGut7ZJrEK9h9Is1s3gt"
        }
         */

        Album album;
        Artist[] artists;
        ExternalURLs external_urls;
        string name;

        @serdeIgnore
        {
            enum available_markets = false;
            enum disc_number = false;
            enum duration_ms = false;
            enum explicit = false;
            enum external_ids = false;
            enum href = false;
            enum id = false;
            enum is_local = false;
            enum popularity = false;
            enum preview_url = false;
            enum track_number = false;
            enum type = false;
            enum uri = false;
        }
    }

    alias ErrorResponse = SpotifyErrorResponse;

    static struct GetTrackResults
    {
        uint code;
        string error;
        string album;
        string artist;
        string name;
        string url;

        auto success() const { return code == 200; }

        this(const uint code, const Response response)
        {
            this.code = code;
            this.album = response.album.name;
            this.artist = response.artists[0].name;
            this.name = response.name;
            this.url = response.external_urls.spotify;
        }

        this(const uint code, const SpotifyErrorResponse errorResponse)
        {
            this.code = code;
            this.error = errorResponse.error.message;
        }
    }

    static string authorizationBearer;

    if (!authorizationBearer.length || !authorizationBearer.endsWith(creds.spotifyAccessToken))
    {
        authorizationBearer = "Bearer " ~ creds.spotifyAccessToken;
    }

    enum urlPattern = "https://api.spotify.com/v1/tracks/%s";
    immutable url = urlPattern.format(trackID);

    immutable httpResponse = sendHTTPRequest(
        plugin: plugin,
        url: url,
        caller: __FUNCTION__,
        authorisationHeader: authorizationBearer);

    version(PrintStacktraces)
    {
        scope(failure)
        {
            import kameloso.misc : printStacktrace;
            import std.json : parseJSON;
            import std.stdio : writeln;

            writeln(httpResponse.code);
            writeln(httpResponse.body);
            try writeln(httpResponse.body.parseJSON.toPrettyString);
            catch (Exception _) {}
            printStacktrace();
        }
    }

    switch (httpResponse.code)
    {
    case 200:
        // 200 OK
        break;

    case 401:
        // 401 Unauthorized
        const errorResponse = httpResponse.body.deserialize!ErrorResponse;

        /*
        {
            "error": {
                "status": 401,
                "message": "The access token expired"
            }
        }
         */

        if (errorResponse.error.message == "The access token expired")
        {
            if (!recursing)
            {
                const results = refreshSpotifyToken(plugin, creds);

                if (!results.success)
                {
                    return GetTrackResults(httpResponse.code, errorResponse);
                }

                creds.spotifyAccessToken = results.accessToken;
                saveSecretsToDisk(plugin.secretsByChannel, plugin.secretsFile);
                return getSpotifyTrackByID(plugin, creds, trackID, recursing: true);
            }

            throw new InvalidCredentialsException(errorResponse.error.message);
        }

        return GetTrackResults(httpResponse.code, errorResponse);

    default:
        const errorResponse = httpResponse.body.deserialize!ErrorResponse;
        return GetTrackResults(httpResponse.code, errorResponse);
    }

    const response = httpResponse.body.deserialize!Response;
    return GetTrackResults(httpResponse.code, response);
}


// validateSpotifyToken
/++
    Validates a Spotify OAuth token by issuing a simple request for user
    information, returning the JSON received.

    Params:
        creds = [kameloso.plugins.twitch.Credentials|Credentials] aggregate.
        caBundleFile = Path to a `cacert.pem` bundle file.

    Returns:
        A Voldemort of the results.

    Throws:
        [kameloso.net.UnexpectedJSONException|UnexpectedJSONException] on unexpected JSON.
 +/
private auto validateSpotifyToken(ref Credentials creds, const string caBundleFile)
{
    import kameloso.net : HTTPRequest, issueSyncHTTPRequest;
    import asdf.serialization : deserialize;

    static struct Response
    {
        private import asdf.serialization : serdeIgnore, serdeOptional;

        @serdeOptional
        static struct ExternalURLs
        {
            string spotify;
        }

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

        string display_name;
        ExternalURLs external_urls;
        string href;
        string id;
        string type;
        string uri;

        @serdeIgnore
        {
            enum followers = false;
            enum images = false;
        }
    }

    alias ErrorResponse = SpotifyErrorResponse;

    static struct SpotifyValidationResults
    {
        uint code;
        string error;
        string id;
        string displayName;
        string url;

        auto success() const { return code == 200; }

        this(const uint code, const Response response)
        {
            this.code = code;
            this.id = response.id;
            this.displayName = response.display_name;
            this.url = response.external_urls.spotify;
        }

        this(const uint code, const ErrorResponse errorResponse)
        {
            this.code = code;
            this.error = errorResponse.error.message;
        }
    }

    enum url = "https://api.spotify.com/v1/me";
    immutable authorizationBearer = "Bearer " ~ creds.spotifyAccessToken;

    const request = HTTPRequest(
        id: 0,
        url: url,
        authorisationHeader: authorizationBearer,
        caBundleFile: caBundleFile);

    immutable httpResponse = issueSyncHTTPRequest(request);

    version(PrintStacktraces)
    {
        scope(failure)
        {
            import kameloso.misc : printStacktrace;
            import std.json : parseJSON;
            import std.stdio : writeln;

            writeln(httpResponse.code);
            writeln(httpResponse.body);
            try writeln(httpResponse.body.parseJSON.toPrettyString);
            catch (Exception _) {}
            printStacktrace();
        }
    }

    switch (httpResponse.code)
    {
    case 200:
        // 200 OK
        break;

    case 401:
        // 401 Unauthorized
        /*
        {
            "error": {
                "status": 401,
                "message": "The access token expired"
            }
        }
         */

        goto default;

    default:
        const errorResponse = httpResponse.body.deserialize!ErrorResponse;
        return SpotifyValidationResults(httpResponse.code, errorResponse);
    }

    const response = httpResponse.body.deserialize!Response;
    return SpotifyValidationResults(httpResponse.code, response);
}


// SpotifyTokenResponse
/++
    JSON schema for the Spotify token response.
 +/
struct SpotifyTokenResponse
{
    private import asdf.serialization : serdeOptional, serdeKeys;

    /*
    {
        "access_token": "[redacted]",
        "token_type": "Bearer",
        "expires_in": 3600,
        "refresh_token": "[redacted]",
        "scope": "playlist-modify-private playlist-modify-public"
    }
     */
    /*
    {
        "access_token": "[redacted]",
        "token_type": "Bearer",
        "expires_in": 3600,
        "scope": "playlist-modify-private playlist-modify-public"
    }
     */

    string access_token;  ///
    string token_type;  ///
    uint expires_in;  ///

    @serdeOptional string refresh_token;  ///
    @serdeKeys("scope") string scope_;  ///
}


// SpotifyErrorResponse
/++
    JSON schema for the Spotify error response.
 +/
struct SpotifyErrorResponse
{
    ///
    static struct ErrorData
    {
        uint status;  ///
        string message;  ///
    }

    /*
    {
        "error": {
            "status": 401,
            "message": "The access token expired"
        }
    }
     */

    ErrorData error;  ///
}
