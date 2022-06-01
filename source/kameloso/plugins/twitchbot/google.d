/++
    Bits and bobs to get Google API credentials for YouTube playlist management.

    See_Also:
        [kameloso.plugins.twitchbot.base|twitchbot.base]
        [kameloso.plugins.twitchbot.api|twitchbot.api]
 +/
module kameloso.plugins.twitchbot.google;

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


// requestGoogleKeys
/++
    Requests a Google API authorisation code from Google servers, then uses it
    to obtain an access key and a refresh OAuth key.

    Params:
        plugin = The current [kameloso.plugins.twitchbot.base.TwitchBotPlugin|TwitchBotPlugin].
 +/
package void requestGoogleKeys(TwitchBotPlugin plugin)
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
    logger.info("-- Google authorisation key generation mode --");
    enum message =
`To access the Google API you need a <i>client ID</> and a <i>client secret</>.

<l>Go here to create a project:</>

    <i>https://console.cloud.google.com/projectcreate</>

<l>OAuth consent screen</> tab (choose <i>External</>), follow instructions.
<i>*</> <l>Scopes:</> <i>https://www.googleapis.com/auth/youtube</>
<i>*</> <l>Test users:</> (your Google account)

Then pick <i>+ Create Credentials</> -> <i>OAuth client ID</>:
<i>*</> <l>Application type:</> <i>Desktop app</>

Now you should have a newly-generated client ID and client secret.

<l>Enabled APIs and Services</> tab -> <i>+ Enable APIs and Services</>
<i>--></> enter "<i>YouTube Data API v3</>", hit <i>Enable</>

You also need to supply a channel for which it all relates.
(Channels are Twitch lowercase account names, prepended with a '<i>#</>' sign.)

Lastly you need a <i>YouTube playlist ID</> for song requests to work.
A normal URL to any playlist you can modify will work fine.
`;
    writeln(message.expandTags(LogLevel.off));

    Credentials creds;

    immutable channel = readNamedString("<l>Enter your <i>#channel<l>:</> ",
        0L, *plugin.state.abort);
    if (*plugin.state.abort) return;

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
            logger.error(invalidMessage.expandTags(LogLevel.error));
            writeln();
            continue;
        }
    }

    enum attemptToOpenPattern = `
--------------------------------------------------------------------------------

<l>Attempting to open a Google login page in your default web browser.</>

Follow the instructions and log in to authorise the use of this program with your account.

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

    void printManualURL()
    {
        enum copyPastePattern = `
<l>Copy and paste this link manually into your browser, and log in as asked:

<i>8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8<</>

%s

<i>8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8<</>
`;
        writefln(copyPastePattern.expandTags(LogLevel.off), url);
        if (plugin.state.settings.flush) stdout.flush();
    }

    if (plugin.state.settings.force)
    {
        logger.warning("Forcing; not automatically opening browser.");
        printManualURL();
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
            printManualURL();
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

All done! Restart the program (without <i>--set twitch.googleKeygen</>)
and it should just work. If it doesn't, please file an issue at:

    <i>https://github.com/zorael/kameloso/issues/new</>
";
    writefln(issuePattern.expandTags(LogLevel.off), plugin.secretsFile);
    if (plugin.state.settings.flush) stdout.flush();
}


// addVideoToYouTubePlaylist
/++
    Adds a video to the YouTube playlist whose ID is stored in the passed [Credentials].

    Params:
        plugin = The current [kameloso.plugins.twitchbot.base.TwitchBotPlugin|TwitchBotPlugin].
        creds = Credentials aggregate.
        videoID = YouTube video ID of the video to add.
        recursing = Whether or not the function is recursing into iself.

    Returns:
        A [std.json.JSONValue|JSONValue] of the response.
 +/
package JSONValue addVideoToYouTubePlaylist(
    TwitchBotPlugin plugin,
    ref Credentials creds,
    const string videoID,
    const Flag!"recursing" recursing = No.recursing)
{
    import arsd.http2 : HttpVerb, Uri;
    import std.algorithm.searching : endsWith;
    import std.format : format;
    import std.json : JSONType, parseJSON;

    if (!creds.youtubePlaylistID.length)
    {
        throw new SongRequestPlaylistException("Missing YouTube playlist ID");
    }

    enum url = "https://www.googleapis.com/youtube/v3/playlistItems?part=snippet";
    auto client = getHTTPClient();

    if (!client.authorization.length || !client.authorization.endsWith(creds.googleAccessToken))
    {
        client.authorization = "Bearer " ~ creds.googleAccessToken;
    }

    //"position": 999,
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

    ubyte[] data = cast(ubyte[])(pattern.format(creds.youtubePlaylistID, videoID));
    auto req = client.request(Uri(url), HttpVerb.POST, data, "application/json");
    auto res = req.waitForCompletion();

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

    const json = parseJSON(res.contentText);

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
        else if (auto statusJSON = "status" in errorJSON.object)
        {
            if (statusJSON.str == "UNAUTHENTICATED")
            {
                refreshGoogleToken(client, creds);
                saveSecretsToDisk(plugin.secretsByChannel, plugin.secretsFile);
                return addVideoToYouTubePlaylist(plugin, creds, videoID, Yes.recursing);
            }
        }

        throw new SongRequestException(errorJSON.object["message"].str);
    }

    return json;
}


// getGoogleTokens
/++
    Request OAuth API tokens from Google.

    Params:
        client = [arsd.http2.HttpClient|HttpClient] to use.
        creds = Credentials aggregate.
        code = Google authorization code.
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
        throw new SongRequestJSONTypeMismatchException(
            "Wrong JSON type in token request response", json);
    }

    if (auto errorJSON = "error" in json) throw new SongRequestTokenException(errorJSON.str);

    creds.googleAccessToken = json["access_token"].str;
    creds.googleRefreshToken = json["refresh_token"].str;
}


// refreshGoogleToken
/++
    Refreshes the OAuth API token in the passed Google credentials.

    Params:
        client = [arsd.http2.HttpClient|HttpClient] to use.
        creds = Credentials aggregate.
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
        throw new SongRequestJSONTypeMismatchException(
            "Wrong JSON type in token refresh response", json);
    }

    if (auto errorJSON = "error" in json) throw new SongRequestTokenException(errorJSON.str);

    creds.googleAccessToken = json["access_token"].str;
    // refreshToken is not present and stays the same as before
}
