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

import kameloso.common : expandTags, logger;
import kameloso.logger : LogLevel;

import arsd.http2 : HttpClient;
import std.json : JSONValue;
import std.typecons : Flag, No, Yes;

package:


// GoogleCredentials
/++
    Credentials needed to access the Google Cloud API; specifically, to manage a
    YouTube playlist.

    See_Also:
        https://console.cloud.google.com/apis/credentials
 +/
struct GoogleCredentials
{
    /++
        Google client ID.
     +/
    string clientID;

    /++
        Google client secret.
     +/
    string secret;

    /++
        Google API authorisation code.
     +/
    string code;

    /++
        Google API OAuth access token.
     +/
    string accessToken;

    /++
        Google API OAuth refresh token.
     +/
    string refreshToken;

    /++
        YouTube playlist ID.
     +/
    string playlistID;

    /++
        Serialises these [GoogleCredentials] into JSON.

        Returns:
            `this` represented in JSON.
     +/
    JSONValue toJSON() const
    {
        JSONValue json;
        json = null;
        json.object = null;

        json["secret"] = this.secret;
        json["code"] = this.code;
        json["accessToken"] = this.accessToken;
        json["refreshToken"] = this.refreshToken;
        json["playlistID"] = this.playlistID;

        return json;
    }

    /++
        Deserialises a [GoogleCredentials] from JSON.

        Params:
            json = JSON representation of a [GoogleCredentials].
     +/
    static auto fromJSON(const JSONValue json)
    {
        GoogleCredentials creds;
        creds.secret = json["secret"].str;
        creds.code = json["code"].str;
        creds.accessToken = json["accessToken"].str;
        creds.refreshToken = json["refreshToken"].str;
        creds.playlistID = json["playlistID"].str;

        return creds;
    }
}


// generateGoogleCode
/++
    Requests a Google API authorisation code from Google servers.

    Params:
        plugin = The current [TwitchBotPlugin].
 +/
void generateGoogleCode(TwitchBotPlugin plugin)
{
    import kameloso.logger : LogLevel;
    import kameloso.thread : ThreadMessage;
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
    logger.info("-- Google authorisation code generation mode --");
    enum message =
"To access the Google API you need a <i>client ID</> and a <i>client secret</>.

<l>Go here to create a project and generate these credentials:</>

    <i>https://console.cloud.google.com/apis/credentials</>

Additionally you need a <i>YouTube playlist ID</> for song requests to work.
A normal URL to any playlist you can modify will work fine.
";
    writeln(message.expandTags(LogLevel.off));

    GoogleCredentials creds;

    creds.clientID = readNamedString("OAuth client ID", 72L, *plugin.state.abort);
    if (*plugin.state.abort) return;

    creds.secret = readNamedString("OAuth client secret", 35L, *plugin.state.abort);
    if (*plugin.state.abort) return;

    while (!creds.playlistID.length)
    {
        immutable playlistURL = readNamedString("YouTube playlist URL", 0L, *plugin.state.abort);  // mutable
        if (*plugin.state.abort) return;

        if (playlistURL.length == 34L)
        {
            // Likely a playlist ID
            creds.playlistID = playlistURL;
        }
        else if (playlistURL.contains("/playlist?list="))
        {
            string slice = playlistURL;  // mutable
            slice.nom("/playlist?list=");
            creds.playlistID = slice.nom!(Yes.inherit)('&');
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

    enum attemptToOpenPattern =`
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
    immutable url = urlPattern.format(creds.clientID);

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

    while (!creds.code.length)
    {
        scope(exit) if (plugin.state.settings.flush) stdout.flush();

        enum pattern = "<l>Paste the address of the page you were redirected to here (empty line exits):</>
> ";
        write(pattern.expandTags(LogLevel.off));
        stdout.flush();

        stdin.flush();
        creds.code = readln().stripped;

        if (*plugin.state.abort || !creds.code.length)
        {
            writeln();
            logger.warning("Aborting.");
            logger.trace();
            return;
        }

        if (!creds.code.contains("code="))
        {
            import lu.string : beginsWith;

            writeln();

            if (creds.code.beginsWith(authNode))
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
            creds.code = string.init;
            continue;
        }

        string slice = creds.code;  // mutable
        slice.nom("?code=");
        creds.code = slice.nom!(Yes.inherit)('&');

        if (creds.code.length != 73L)
        {
            writeln();
            logger.error("Invalid code length. Try copying again or file a bug.");
            writeln();
            creds.code = string.init;  // reset it so the while loop repeats
        }
    }

    // All done, fetch
    auto client = getHTTPClient();
    getGoogleToken(client, creds);

    plugin.googleSecretsByChannel[channel] = creds;
    saveSecretsToDisk(plugin.googleSecretsByChannel, plugin.secretsFile);

    enum issuePattern = "
--------------------------------------------------------------------------------

All done! Restart the program (without <i>--set twitch.googleKeygen</>)
and it should just work. If it doesn't, please file an issue at:

    <i>https://github.com/zorael/kameloso/issues/new</>
";
    writefln(issuePattern.expandTags(LogLevel.off), plugin.secretsFile);
    if (plugin.state.settings.flush) stdout.flush();
}


// getHTTPClient
/++
    Returns a static [arsd.http2.HttpClient|HttpClient] for reuse across function calls.

    Returns:
        A static [arsd.http2.HttpClient|HttpClient].
 +/
auto getHTTPClient()
{
    import kameloso.constants : KamelosoInfo, Timeout;
    import arsd.http2 : HttpClient, Uri;
    import core.time : seconds;

    static HttpClient client;

    if (!client)
    {
        client = new HttpClient;
        client.useHttp11 = true;
        client.keepAlive = true;
        client.acceptGzip = false;
        client.defaultTimeout = Timeout.httpGET.seconds;
        client.userAgent = "kameloso/" ~ cast(string)KamelosoInfo.version_;
    }

    return client;
}


// addVideoToYouTubePlaylist
/++
    Adds a video to the YouTube playlist whose ID is stored in the passed
    [GoogleCredentials].

    Params:
        creds = Google credentials aggregate.
        videoID = YouTube video ID of the video to add.
        recursing = Whether or not the function is recursing into iself.
 +/
JSONValue addVideoToYouTubePlaylist(
    ref GoogleCredentials creds,
    const string videoID,
    const Flag!"recursing" recursing = No.recursing)
{
    import arsd.http2 : HttpVerb, Uri;
    import std.format : format;
    import std.json : JSONValue, JSONType, parseJSON;
    import std.stdio : writeln;

    enum url = "https://www.googleapis.com/youtube/v3/playlistItems?part=snippet";
    auto client = getHTTPClient();

    if (!creds.playlistID.length)
    {
        throw new Exception("Missing YouTube playlist ID.");
    }

    if (!creds.accessToken.length)
    {
        logger.info("Requesting Google authorisation code.");
        getGoogleToken(client, creds);
    }

    if (!client.authorization.length) client.authorization = "Bearer " ~ creds.accessToken;

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

    ubyte[] data = cast(ubyte[])(pattern.format(creds.playlistID, videoID));
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
    if (json.type != JSONType.object) throw new Exception("unexpected token json");

    if (auto errorJSON = "error" in json)
    {
        if (recursing)
        {
            throw new Exception(errorJSON.object["message"].str);
        }
        else if (auto statusJSON = "status" in errorJSON.object)
        {
            if (statusJSON.str == "UNAUTHENTICATED")
            {
                refreshGoogleToken(client, creds);
                return addVideoToYouTubePlaylist(creds, videoID, Yes.recursing);
            }
        }

        throw new Exception(errorJSON.object["message"].str);
    }

    return json;
}


// getGoogleToken
/++
    Request an OAuth API token from Google.

    Params:
        client = [arsd.http2.HttpClient|HttpClient] to use.
        creds = Google credentials aggregate.
 +/
void getGoogleToken(HttpClient client, ref GoogleCredentials creds)
{
    import arsd.http2 : HttpVerb, Uri;
    import std.format : format;
    import std.json : JSONType, parseJSON;
    import std.stdio : writeln;
    import std.string : indexOf;

    if (!creds.code.length || !creds.secret.length)
    {
        throw new Exception("Missing Google API code or client secret");
    }

    enum pattern = "https://oauth2.googleapis.com/token" ~
        "?client_id=%s" ~
        "&client_secret=%s" ~
        "&code=%s" ~
        "&grant_type=authorization_code" ~
        "&redirect_uri=http://localhost";

    immutable url = pattern.format(creds.clientID, creds.secret, creds.code);
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
    if (json.type != JSONType.object) throw new Exception("unexpected token json");
    if (auto errorJSON = "error" in json) throw new Exception(errorJSON.str);

    creds.accessToken = json["access_token"].str;
    creds.refreshToken = json["refresh_token"].str;
}


// refreshGoogleToken
/++
    Refreshes the OAuth API token in the passed Google credentials.

    Params:
        client = [arsd.http2.HttpClient|HttpClient] to use.
        creds = Google credentials aggregate.
 +/
void refreshGoogleToken(HttpClient client, ref GoogleCredentials creds)
{
    import arsd.http2 : HttpVerb, Uri;
    import std.format : format;
    import std.json : JSONType, parseJSON;
    import std.stdio : writeln;

    enum pattern = "https://oauth2.googleapis.com/token" ~
        "?client_id=%s" ~
        "&client_secret=%s" ~
        "&refresh_token=%s" ~
        "&grant_type=refresh_token";

    immutable url = pattern.format(creds.clientID, creds.secret, creds.refreshToken);
    enum data = cast(ubyte[])"{}";

    auto req = client.request(Uri(url), HttpVerb.POST, data);
    auto res = req.waitForCompletion();

    const json = parseJSON(res.contentText);
    if (json.type != JSONType.object) throw new Exception("unexpected refresh json");

    creds.accessToken = json["access_token"].str;
    // refreshToken is not present and stays the same as before
}


// readNamedString
/++
    Prompts the user to enter a string.

    Params:
        name = What to call the string to input in the prompt.
        expectedLength = Optional expected length of the input string.
            A value of `0` disables checks.
        abort = Abort pointer.

    Returns:
        A string read from standard in, stripped.
 +/
string readNamedString(const string name, const size_t expectedLength, ref bool abort)
{
    import lu.string : stripped;
    import std.stdio : readln, stdin, stdout, writef, writeln;

    string string_;

    while (!string_.length)
    {
        scope(exit) stdout.flush();

        enum pattern = "<l>Copy and paste your <i>%s<l>:</> ";
        writef(pattern.expandTags(LogLevel.off), name);
        stdout.flush();

        stdin.flush();
        string_ = readln().stripped;

        if (abort)
        {
            writeln();
            logger.warning("Aborting.");
            logger.trace();
            return string.init;
        }
        else if ((expectedLength > 0) && (string_.length != expectedLength))
        {
            writeln();
            enum invalidPattern = "Invalid %s length. Try copying again or file a bug.";
            logger.errorf(invalidPattern.expandTags(LogLevel.error), name);
            writeln();
            continue;
        }
    }

    return string_;
}
