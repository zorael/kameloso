/++
    Bits and bobs to get Google API credentials for YouTube playlist management.

    See_Also:
        [kameloso.plugins.twitch.base|twitch.base]
        [kameloso.plugins.twitch.api|twitch.api]
 +/
module kameloso.plugins.twitch.google;

version(TwitchSupport):
version(WithTwitchPlugin):

private:

import kameloso.plugins.twitch.base;
import kameloso.plugins.twitch.common;

import kameloso.common : logger;
import arsd.http2 : HttpClient;
import std.json : JSONValue;
import std.typecons : Flag, No, Yes;
import core.thread : Fiber;


// requestGoogleKeys
/++
    Requests a Google API authorisation code from Google servers, then uses it
    to obtain an access key and a refresh OAuth key.

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].

    Throws:
        [kameloso.plugins.twitch.common.ErrorJSONException|ErrorJSONException]
        if the returned JSON has an `"error"` field.
 +/
package void requestGoogleKeys(TwitchPlugin plugin)
{
    import kameloso.logger : LogLevel;
    import kameloso.terminal.colours.tags : expandTags;
    import kameloso.time : timeSince;
    import lu.string : contains, nom, stripped;
    import std.conv : to;
    import std.format : format;
    import std.process : Pid, ProcessException, wait;
    import std.stdio : File, readln, stdin, stdout, write, writeln;
    import core.time : seconds;

    scope(exit) if (plugin.state.settings.flush) stdout.flush();

    logger.trace();
    logger.info("-- Google authorisation key generation mode --");
    enum message = `
To access the Google API you need a <i>client ID</> and a <i>client secret</>.

<l>Go here to create a project:</>

    <i>https://console.cloud.google.com/projectcreate</>

<l>OAuth consent screen</> tab (choose <i>External</>), follow instructions.
<i>*</> <l>Scopes:</> <i>https://www.googleapis.com/auth/youtube</>
<i>*</> <l>Test users:</> (your Google account)

Then pick <i>+ Create Credentials</> -> <i>OAuth client ID</>:
<i>*</> <l>Application type:</> <i>Desktop app</>

Now you should have a newly-generated client ID and client secret.
Copy these somewhere; you'll need them soon.

<l>Enabled APIs and Services</> tab -> <i>+ Enable APIs and Services</>
<i>--></> enter "<i>YouTube Data API v3</>", hit <i>Enable</>

You also need to supply a channel for which it all relates.
(Channels are Twitch lowercase account names, prepended with a '<i>#</>' sign.)

Lastly you need a <i>YouTube playlist ID</> for song requests to work.
A normal URL to any playlist you can modify will work fine.
`;
    writeln(message.expandTags(LogLevel.off));

    Credentials creds;

    string channel;
    while (!channel.length)
    {
        immutable rawChannel = readNamedString("<l>Enter your <i>#channel<l>:</> ",
            0L, *plugin.state.abort);
        if (*plugin.state.abort) return;

        channel = rawChannel.stripped;

        if (!channel.length || channel[0] != '#')
        {
            enum channelMessage = "Channels are Twitch lowercase account names, prepended with a '<i>#</>' sign.";
            logger.warning(channelMessage);
            channel = string.init;
        }
    }

    creds.googleClientID = readNamedString("<l>Copy and paste your <i>OAuth client ID<l>:</> ",
        72L, *plugin.state.abort);
    if (*plugin.state.abort) return;

    creds.googleClientSecret = readNamedString("<l>Copy and paste your <i>OAuth client secret<l>:</> ",
        35L, *plugin.state.abort);
    if (*plugin.state.abort) return;

    while (!creds.youtubePlaylistID.length)
    {
        enum playlistIDLength = 34;

        immutable playlistURL = readNamedString("<l>Copy and paste your <i>YouTube playlist URL<l>:</> ",
            0L, *plugin.state.abort);
        if (*plugin.state.abort) return;

        if (playlistURL.length == playlistIDLength)
        {
            // Likely a playlist ID
            creds.youtubePlaylistID = playlistURL;
        }
        else if (playlistURL.contains("/playlist?list="))
        {
            string slice = playlistURL;  // mutable
            slice.nom("/playlist?list=");
            creds.youtubePlaylistID = slice.nom!(Yes.inherit)('&');
        }
        else
        {
            writeln();
            enum invalidMessage = "Cannot recognise link as a YouTube playlist URL. " ~
                "Try copying again or file a bug.";
            logger.error(invalidMessage);
            writeln();
            continue;
        }
    }

    enum attemptToOpenPattern = `
--------------------------------------------------------------------------------

<l>Attempting to open a Google login page in your default web browser.</>

Follow the instructions and log in to authorise the use of this program with your account.
Be sure to <l>select a YouTube account</> if presented with several alternatives.
(One that says <i>YouTube</> underneath it.)

<l>Then paste the address of the empty page you are redirected to afterwards here.</>

* The redirected address should start with <i>http://localhost</>.
* It will probably say "<l>this site can't be reached</>" or "<l>unable to connect</>".
* If you are running local web server on port <i>80</>, you may have to temporarily
  disable it for this to work.
`;
    writeln(attemptToOpenPattern.expandTags(LogLevel.off));
    if (plugin.state.settings.flush) stdout.flush();

    enum authNode = "https://accounts.google.com/o/oauth2/v2/auth";
    enum urlPattern = authNode ~
        "?client_id=%s" ~
        "&redirect_uri=http://localhost" ~
        "&response_type=code" ~
        "&scope=https://www.googleapis.com/auth/youtube";
    immutable url = urlPattern.format(creds.googleClientID);

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
        catch (ProcessException _)
        {
            // Probably we got some platform wrong and command was not found
            logger.warning("Error: could not automatically open browser.");
            printManualURL(url);
            if (plugin.state.settings.flush) stdout.flush();
        }
        catch (Exception _)
        {
            logger.warning("Error: no graphical environment detected");
            printManualURL(url);
            if (plugin.state.settings.flush) stdout.flush();
        }
    }

    string code;

    while (!code.length)
    {
        scope(exit) if (plugin.state.settings.flush) stdout.flush();

        enum pasteMessage = "<l>Paste the address of the page you were redirected to here (empty line exits):</>

> ";
        write(pasteMessage.expandTags(LogLevel.off));
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

        string slice = readCode;  // mutable
        slice.nom("?code=");
        code = slice.nom!(Yes.inherit)('&');

        if (code.length != 73L)
        {
            writeln();
            logger.error("Invalid code length. Try copying again or file a bug.");
            writeln();
            code = string.init;  // reset it so the while loop repeats
        }
    }

    // All done, fetch
    auto client = getHTTPClient();
    getGoogleTokens(client, creds, code);

    writeln();
    logger.info("Validating...");

    immutable validationJSON = validateGoogleToken(client, creds);
    if (*plugin.state.abort) return;

    scope(failure)
    {
        import std.stdio : writeln;
        writeln(validationJSON.toPrettyString);
    }

    if (const errorJSON = "error" in validationJSON)
    {
        throw new ErrorJSONException(validationJSON["error_description"].str, validationJSON);
    }

    // "expires_in" is a string
    immutable expiresIn = validationJSON["expires_in"].str.to!uint;

    enum isValidPattern = "Your key is valid for another <l>%s</> but will be automatically refreshed.";
    logger.infof(isValidPattern, expiresIn.seconds.timeSince!(3, 1));
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


// addVideoToYouTubePlaylist
/++
    Adds a video to the YouTube playlist whose ID is stored in the passed [Credentials].

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        creds = [Credentials] aggregate.
        videoID = YouTube video ID of the video to add.
        recursing = Whether or not the function is recursing into itself.

    Returns:
        A [std.json.JSONValue|JSONValue] of the response.

    Throws:
        [kameloso.plugins.twitch.common.UnexpectedJSONException|UnexpectedJSONException]
        on unexpected JSON.

        [kameloso.plugins.twitch.common.ErrorJSONException|ErrorJSONException]
        if the returned JSON has an `"error"` field.
 +/
package JSONValue addVideoToYouTubePlaylist(
    TwitchPlugin plugin,
    ref Credentials creds,
    const string videoID,
    const Flag!"recursing" recursing = No.recursing)
in (Fiber.getThis, "Tried to call `addVideoToYouTubePlaylist` from outside a Fiber")
{
    import kameloso.plugins.twitch.api : getUniqueNumericalID, waitForQueryResponse;
    import kameloso.plugins.common.delayawait : delay;
    import kameloso.thread : ThreadMessage;
    import arsd.http2 : HttpVerb;
    import std.algorithm.searching : endsWith;
    import std.concurrency : prioritySend, send;
    import std.format : format;
    import std.json : JSONType, parseJSON;
    import std.string : representation;
    import core.time : msecs;

    enum url = "https://www.googleapis.com/youtube/v3/playlistItems?part=snippet";

    if (plugin.state.settings.trace)
    {
        import kameloso.common : logger;
        enum pattern = "GET: <i>%s";
        logger.tracef(pattern, url);
    }

    static string authorizationBearer;

    if (!authorizationBearer.length || !authorizationBearer.endsWith(creds.googleAccessToken))
    {
        authorizationBearer = "Bearer " ~ creds.googleAccessToken;
    }

    enum pattern =
`{
  "snippet": {
    "playlistId": "%s",
    "resourceId": {
      "kind": "youtube#video",
      "videoId": "%s"
    }
  }
}`;

    immutable data = pattern.format(creds.youtubePlaylistID, videoID).representation;
    /*immutable*/ int id = getUniqueNumericalID(plugin.bucket);  // Making immutable bumps compilation memory +44mb

    foreach (immutable i; 0..TwitchPlugin.delegateRetries)
    {
        try
        {
            plugin.state.mainThread.prioritySend(ThreadMessage.shortenReceiveTimeout());

            plugin.persistentWorkerTid.send(
                id,
                url,
                authorizationBearer,
                HttpVerb.POST,
                data,
                "application/json");

            static immutable guesstimatePeriodToWaitForCompletion = 600.msecs;
            delay(plugin, guesstimatePeriodToWaitForCompletion, Yes.yield);
            immutable response = waitForQueryResponse(plugin, id);

            /*
            {
                "kind": "youtube#playlistItem",
                "etag": "QG1leAsBIlxoG2Y4MxMsV_zIaD8",
                "id": "UExNNnd5dmt2ME9GTVVfc0IwRUZyWDdUd0pZUHdkMUYwRi4xMkVGQjNCMUM1N0RFNEUx",
                "snippet": {
                    "publishedAt": "2022-05-24T22:03:44Z",
                    "channelId": "UC_iiOE42xes48ZXeQ4FkKAw",
                    "title": "How Do Sinkholes Form?",
                    "description": "CAN CONTAIN NEWLINES",
                    "thumbnails": {
                        "default": {
                            "url": "https://i.ytimg.com/vi/e-DVIQPqS8E/default.jpg",
                            "width": 120,
                            "height": 90
                        },
                    },
                    "channelTitle": "zorael",
                    "playlistId": "PLM6wyvkv0OFMU_sB0EFrX7TwJYPwd1F0F",
                    "position": 5,
                    "resourceId": {
                        "kind": "youtube#video",
                        "videoId": "e-DVIQPqS8E"
                    },
                    "videoOwnerChannelTitle": "Practical Engineering",
                    "videoOwnerChannelId": "UCMOqf8ab-42UUQIdVoKwjlQ"
                }
            }
            */

            /*
            {
                "error": {
                    "code": 401,
                    "message": "Request had invalid authentication credentials. Expected OAuth 2 access token, login cookie or other valid authentication credential. See https://developers.google.com/identity/sign-in/web/devconsole-project.",
                    "errors": [
                        {
                            "message": "Invalid Credentials",
                            "domain": "global",
                            "reason": "authError",
                            "location": "Authorization",
                            "locationType": "header"
                        }
                    ],
                    "status": "UNAUTHENTICATED"
                }
            }
            */

            const json = parseJSON(response.str);

            if (json.type != JSONType.object)
            {
                enum message = "Wrong JSON type in playlist append response";
                throw new UnexpectedJSONException(message, json);
            }

            const errorJSON = "error" in json;
            if (!errorJSON) return json;  // Success

            if (const statusJSON = "status" in errorJSON.object)
            {
                if (statusJSON.str == "UNAUTHENTICATED")
                {
                    if (recursing)
                    {
                        const errorAAJSON = "errors" in *errorJSON;

                        if (errorAAJSON &&
                            (errorAAJSON.type == JSONType.array) &&
                            (errorAAJSON.array.length > 0))
                        {
                            immutable message = errorAAJSON.array[0].object["message"].str;
                            throw new InvalidCredentialsException(message, *errorJSON);
                        }
                        else
                        {
                            enum message = "A non-specific error occurred.";
                            throw new ErrorJSONException(message, *errorJSON);
                        }
                    }
                    else
                    {
                        refreshGoogleToken(getHTTPClient(), creds);
                        saveSecretsToDisk(plugin.secretsByChannel, plugin.secretsFile);
                        return addVideoToYouTubePlaylist(plugin, creds, videoID, Yes.recursing);
                    }
                }
            }

            // If we're here, the above didn't match
            throw new ErrorJSONException(errorJSON.object["message"].str, *errorJSON);
        }
        catch (InvalidCredentialsException e)
        {
            // Immediately rethrow
            throw e;
        }
        catch (Exception e)
        {
            // Retry until we reach the retry limit, then rethrow
            if (i < TwitchPlugin.delegateRetries-1) continue;
            throw e;
        }
    }

    assert(0, "Unreachable");
}


// getGoogleTokens
/++
    Request OAuth API tokens from Google.

    Params:
        client = [arsd.http2.HttpClient|HttpClient] to use.
        creds = [Credentials] aggregate.
        code = Google authorization code.

    Throws:
        [kameloso.plugins.twitch.common.UnexpectedJSONException|UnexpectedJSONException]
        on unexpected JSON.

        [kameloso.plugins.twitch.common.ErrorJSONException|ErrorJSONException]
        if the returned JSON has an `"error"` field.
 +/
void getGoogleTokens(HttpClient client, ref Credentials creds, const string code)
{
    import arsd.http2 : HttpVerb, Uri;
    import std.format : format;
    import std.json : JSONType, parseJSON;
    import std.string : indexOf;

    enum pattern = "https://oauth2.googleapis.com/token" ~
        "?client_id=%s" ~
        "&client_secret=%s" ~
        "&code=%s" ~
        "&grant_type=authorization_code" ~
        "&redirect_uri=http://localhost";

    immutable url = pattern.format(creds.googleClientID, creds.googleClientSecret, code);
    enum data = cast(ubyte[])"{}";
    auto req = client.request(Uri(url), HttpVerb.POST, data);
    auto res = req.waitForCompletion();

    /*
    {
        "access_token": "[redacted]"
        "expires_in": 3599,
        "refresh_token": "[redacted]",
        "scope": "https://www.googleapis.com/auth/youtube",
        "token_type": "Bearer"
    }
    */

    const json = parseJSON(res.contentText);

    if (json.type != JSONType.object)
    {
        throw new UnexpectedJSONException("Wrong JSON type in token request response", json);
    }

    if (auto errorJSON = "error" in json)
    {
        throw new ErrorJSONException(errorJSON.str, *errorJSON);
    }

    creds.googleAccessToken = json["access_token"].str;
    creds.googleRefreshToken = json["refresh_token"].str;
}


// refreshGoogleToken
/++
    Refreshes the OAuth API token in the passed Google credentials.

    Params:
        client = [arsd.http2.HttpClient|HttpClient] to use.
        creds = [Credentials] aggregate.

    Throws:
        [kameloso.plugins.twitch.common.UnexpectedJSONException|UnexpectedJSONException]
        on unexpected JSON.

        [kameloso.plugins.twitch.common.ErrorJSONException|ErrorJSONException]
        if the returned JSON has an `"error"` field.
 +/
void refreshGoogleToken(HttpClient client, ref Credentials creds)
{
    import arsd.http2 : HttpVerb, Uri;
    import std.format : format;
    import std.json : JSONType, parseJSON;

    enum pattern = "https://oauth2.googleapis.com/token" ~
        "?client_id=%s" ~
        "&client_secret=%s" ~
        "&refresh_token=%s" ~
        "&grant_type=refresh_token";

    immutable url = pattern.format(creds.googleClientID, creds.googleClientSecret, creds.googleRefreshToken);
    enum data = cast(ubyte[])"{}";
    auto req = client.request(Uri(url), HttpVerb.POST, data);
    auto res = req.waitForCompletion();
    const json = parseJSON(res.contentText);

    if (json.type != JSONType.object)
    {
        throw new UnexpectedJSONException("Wrong JSON type in token refresh response", json);
    }

    if (auto errorJSON = "error" in json)
    {
        if (errorJSON.str == "invalid_grant")
        {
            enum message = "Invalid grant";
            throw new InvalidCredentialsException(message, *errorJSON);
        }
        else
        {
            throw new ErrorJSONException(errorJSON.str, *errorJSON);
        }
    }

    creds.googleAccessToken = json["access_token"].str;
    // refreshToken is not present and stays the same as before
}


// validateGoogleToken
/++
    Validates a Google OAuth token, returning the JSON received from the server.

    Params:
        client = [arsd.http2.HttpClient|HttpClient] to use.
        creds = [Credentials] aggregate.

    Returns:
        The server [std.json.JSONValue|JSONValue] response.

    Throws:
        [kameloso.plugins.twitch.common.UnexpectedJSONException|UnexpectedJSONException]
        on unexpected JSON.

        [kameloso.plugins.twitch.common.ErrorJSONException|ErrorJSONException]
        if the returned JSON has an `"error"` field.
 +/
auto validateGoogleToken(HttpClient client, ref Credentials creds)
{
    import arsd.http2 : Uri;
    import std.json : JSONType, parseJSON;

    enum urlHead = "https://www.googleapis.com/oauth2/v3/tokeninfo?access_token=";
    immutable url = urlHead ~ creds.googleAccessToken;
    auto req = client.request(Uri(url));
    auto res = req.waitForCompletion();
    const json = parseJSON(res.contentText);

    /*
    {
        "error": "invalid_token",
        "error_description": "Invalid Value"
    }
    */
    /*
    {
        "access_type": "offline",
        "aud": "[redacted]",
        "azp": "[redacted]",
        "exp": "[redacted]",
        "expires_in": "3599",
        "scope": "https:\/\/www.googleapis.com\/auth\/youtube"
    }
    */

    if (json.type != JSONType.object)
    {
        throw new UnexpectedJSONException("Wrong JSON type in token validation response", json);
    }

    if (auto errorJSON = "error" in json)
    {
        throw new ErrorJSONException(errorJSON.str, *errorJSON);
    }

    return json;
}
