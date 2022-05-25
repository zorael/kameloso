/++
 +/
module kameloso.plugins.twitchbot.google;

version(TwitchSupport):
version(WithTwitchBotPlugin):

private:

import kameloso.plugins.twitchbot.base;

import kameloso.common : logger;

import arsd.http2 : HttpClient;
import std.json : JSONValue;
import std.typecons : Flag, No, Yes;

package:


// GoogleCredentials
/++
    FIXME
 +/
struct GoogleCredentials
{
    enum clientID = "842883452112-rohcu5k9u7htstmfevknanvjf5lur4pc.apps.googleusercontent.com";
    string secret;
    string code;
    string accessToken;
    string refreshToken;
    string playlistID;

    JSONValue toJSON() const
    {
        JSONValue json;

        json["secret"] = this.secret;
        json["code"] = this.code;
        json["accessToken"] = this.accessToken;
        json["refreshToken"] = this.refreshToken;
        json["playlistID"] = this.playlistID;

        return json;
    }

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

    string toString() const
    {
        import std.format : format;

        enum pattern =
            "client ID:%s\n" ~
            "client secret:%s\n" ~
            "authorisation code:%s\n" ~
            "access token:%s\n" ~
            "refresh token:%s";
        immutable asString = pattern
            .format(clientID, secret, code, accessToken, refreshToken);

        return asString;
    }
}


void generateGoogleCode(TwitchBotPlugin plugin, const string channel)
{
    import kameloso.common : expandTags, logger;
    import kameloso.logger : LogLevel;
    import kameloso.thread : ThreadMessage;
    import lu.string : contains, nom, stripped;
    import std.process : Pid, ProcessException, wait;
    import std.stdio : File, readln, stdin, stdout, write, writefln, writeln;

    scope(exit)
    {
        import kameloso.messaging : quit;
        import std.typecons : Flag, No, Yes;

        quit!(Yes.priority)(plugin.state, string.init, Yes.quiet);
    }

    logger.trace();
    logger.info("-- Google authorization code generation mode --");
    enum attemptToOpenPattern = `
Attempting to open a Google login page in your default web browser. Follow the
instructions and log in to authorise the use of this program with your account.

<l>Then paste the address of the page you are redirected to afterwards here.</>

* The redirected address should start with <i>http://localhost</>.
* It will probably say "<l>this site can't be reached</>" or "<l>unable to connect</>".
* If you are running local web server on port <i>80</>, you may have to temporarily
  disable it for this to work.
`;
    writeln(attemptToOpenPattern.expandTags(LogLevel.off));
    if (plugin.state.settings.flush) stdout.flush();

    enum authNode = "https://accounts.google.com/o/oauth2/v2/auth";
    enum url = authNode ~
        "?client_id=" ~ GoogleCredentials.clientID ~
        "&redirect_uri=http://localhost" ~
        "&response_type=code" ~
        "&scope=https://www.googleapis.com/auth/youtube";

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
            version(Posix)
            {
                import std.process : environment, spawnProcess;

                version(OSX)
                {
                    enum open = "open";
                }
                else
                {
                    // Assume XDG
                    enum open = "xdg-open";
                }

                immutable browserExecutable = environment.get("BROWSER", open);
                string[2] browserCommand = [ browserExecutable, url ];  // mutable
                auto devNull = File("/dev/null", "r+");

                try
                {
                    browser = spawnProcess(browserCommand[], devNull, devNull, devNull);
                }
                catch (ProcessException e)
                {
                    if (browserExecutable == open) throw e;

                    browserCommand[0] = open;
                    browser = spawnProcess(browserCommand[], devNull, devNull, devNull);
                }
            }
            else version(Windows)
            {
                import std.file : tempDir;
                import std.format : format;
                import std.path : buildPath;
                import std.process : spawnProcess;

                enum pattern = "kameloso-google-%s.url";
                immutable urlBasename = pattern.format(plugin.state.client.nickname);
                immutable urlFileName = buildPath(tempDir, urlBasename);

                {
                    auto urlFile = File(urlFileName, "w");
                    urlFile.writeln("[InternetShortcut]\nURL=", url);
                }

                immutable string[2] browserCommand = [ "explorer", urlFileName ];
                auto nulFile = File("NUL", "r+");
                browser = spawnProcess(browserCommand[], nulFile, nulFile, nulFile);
            }
            else
            {
                static assert(0, "Unsupported platform, please file a bug.");
            }
        }
        catch (ProcessException e)
        {
            // Probably we got some platform wrong and command was not found
            logger.warning("Error: could not automatically open browser.");
            printManualURL();
        }
    }

    string key;

    while (!key.length)
    {
        import std.stdio : writef;

        scope(exit)
        {
            if (plugin.state.settings.flush) stdout.flush();
        }

        enum pattern = "<l>Paste the address of the page you were redirected to here (empty line exits):</>

> ";
        write(pattern.expandTags(LogLevel.off));
        stdout.flush();

        stdin.flush();
        immutable readURL = readln().stripped;

        if (!readURL.length || *plugin.state.abort)
        {
            writeln();
            logger.warning("Aborting key generation.");
            logger.trace();
            return;
        }

        if (!readURL.contains("code="))
        {
            import lu.string : beginsWith;

            writeln();

            if (readURL.beginsWith(authNode))
            {
                enum wrongPagePattern = "Not that page; the one you're lead to after clicking <l>Authorize</>.";
                logger.error(wrongPagePattern.expandTags(LogLevel.error));
            }
            else
            {
                logger.error("Could not make sense of URL. Try again or file a bug.");
            }

            writeln();
            continue;
        }

        string slice = readURL;  // mutable
        slice.nom("code=");
        key = slice.nom!(Yes.inherit)('&');

        if (key.length != 73L)
        {
            writeln();
            logger.error("Invalid key length!");
            writeln();
            key = string.init;  // reset it so the while loop repeats
        }
    }

    GoogleCredentials creds;
    creds.code = key;

    auto client = getHTTPClient();
    getGoogleToken(client, creds);
    writeln(creds);

    plugin.googleSecretsByChannel[channel] = creds;
    saveSecretsToDisk(plugin.googleSecretsByChannel, plugin.secretsFile);

    enum issuePattern = "
--------------------------------------------------------------------------------

All done! Restart the program (without <i>--set twitchbot.googleKeygen</>) and
it should just work. If it doesn't, please file an issue at:

    <i>https://github.com/zorael/kameloso/issues/new</>
";
    writeln(issuePattern.expandTags(LogLevel.off));
    if (plugin.state.settings.flush) stdout.flush();
}


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

    if (!creds.accessToken.length)
    {
        logger.info("Requesting Google authorisation code.");
        getGoogleToken(client, creds);
    }

    client.authorization = "Bearer " ~ creds.accessToken;

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

    writeln(res.contentText);
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


void getGoogleCode(ref GoogleCredentials creds)
{
    import std.process;
    import std.stdio : readln, stdin, stdout, writeln;
    import std.string : indexOf;

    enum authNode = "https://accounts.google.com/o/oauth2/v2/auth";
    enum url = authNode ~
        "?client_id=" ~ GoogleCredentials.clientID ~
        "&redirect_uri=http://localhost" ~
        "&response_type=code" ~
        "&scope=https://www.googleapis.com/auth/youtube";

    immutable results = execute([ "xdg-open", url ]);
    if (results.status != 0) throw new Exception("failed to open browser");

    writeln("paste address:");
    stdout.flush();
    stdin.flush();
    immutable address = readln();

    // http://localhost/?code=4/0AX4XfWi4kizlMyLEBfHL68j3GypWXyCV_znImdOgEuSoGAI4_4YaMa30Xw6-0K2COiGgGA&scope=https://www.googleapis.com/auth/youtube
    immutable codePos = address.indexOf("?code=");
    immutable scopePos = address.indexOf("&scope=");
    if ((codePos == -1) || (scopePos == -1)) throw new Exception("unexpected address");
    creds.code = address[codePos+6..scopePos];
}


void getGoogleToken(HttpClient client, ref GoogleCredentials creds)
{
    import arsd.http2 : HttpVerb, Uri;
    import std.format : format;
    import std.json : JSONType, parseJSON;
    import std.stdio : writeln;
    import std.string : indexOf;

    //https://oauth2.googleapis.com/token?client_id=842883452112-rohcu5k9u7htstmfevknanvjf5lur4pc.apps.googleusercontent.com&client_secret=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&code=4/0AX4XfWi4kizlMyLEBfHL68j3GypWXyCV_znImdOgEuSoGAI4_4YaMa30Xw6-0K2COiGgGA&grant_type=authorization_code&redirect_uri=http://localhost
    enum pattern = "https://oauth2.googleapis.com/token" ~
        "?client_id=%s" ~
        "&client_secret=%s" ~
        "&code=%s" ~
        "&grant_type=authorization_code" ~
        "&redirect_uri=http://localhost";
    immutable url = pattern.format(GoogleCredentials.clientID, creds.secret, creds.code);
    writeln("getToken: ", url);
    enum data = cast(ubyte[])"{}";
    auto req = client.request(Uri(url), HttpVerb.POST, data);
    //req.requestParameters.headers = [ "Content-Length: 0" ];
    auto res = req.waitForCompletion();
    writeln(res.contentText);

    /*
    {
        "access_token": "ya29.a0ARrdaM8rcRE8T4h_Zb8Qlroz24qyUtp87_hX07SnOalJvbsDcAGXO7V7sGlj4uyzgS-jX9kwBNrveBCPice1qI9G_gI5DfteQuRzhzY1He3aS9Yh0QuSORQ0N2pFNmGzIkAS1ZqR4WzBPtECzWGXNxl3Splb",
        "expires_in": 3599,
        "refresh_token": "1//0ckT2PuOfZLRNCgYIARAAGAwSNwF-L9IrXAZYJnqcJAE9SzADkBgGfhOxicawIGdNwvHPB8KlWzV1Cf7_XZx2x2RdDbIFLhsXxSY",
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
    immutable url = pattern.format(GoogleCredentials.clientID, creds.secret, creds.refreshToken);
    writeln("refrsehToken: ", url);

    enum data = cast(ubyte[])"{}";
    auto req = client.request(Uri(url), HttpVerb.POST, data);
    auto res = req.waitForCompletion();
    writeln(res.contentText);

    const json = parseJSON(res.contentText);
    if (json.type != JSONType.object) throw new Exception("unexpected refresh json");

    creds.accessToken = json["access_token"].str;
}
