/++
    Bits and bobs to get Google API credentials and for YouTube playlist management.

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
module kameloso.plugins.twitch.providers.google;

version(TwitchSupport):
version(WithTwitchPlugin):

private:

import kameloso.plugins.twitch;
import kameloso.plugins.twitch.common;
import kameloso.plugins.twitch.providers.common;
import kameloso.common : logger;
import kameloso.net :
    ErrorJSONException,
    HTTPQueryException,
    UnexpectedJSONException;
import core.thread.fiber : Fiber;

public:


// requestGoogleKeys
/++
    Requests a Google API authorisation code from Google servers, then uses it
    to obtain an access key and a refresh OAuth key.

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].

    Throws:
        [kameloso.net.ErrorJSONException|ErrorJSONException]
        if the returned JSON has an `"error"` field.
 +/
void requestGoogleKeys(TwitchPlugin plugin)
{
    import kameloso.logger : LogLevel;
    import kameloso.terminal.colours.tags : expandTags;
    import kameloso.time : timeSince;
    import lu.string : advancePast, stripped;
    import std.algorithm.searching : canFind;
    import std.conv : to;
    import std.format : format;
    import std.process : Pid, ProcessException, wait;
    import std.stdio : File, readln, stdin, stdout, write, writeln;
    import core.time : seconds;

    scope(exit) if (plugin.state.coreSettings.flush) stdout.flush();

    enum dashboardURL = "https://console.cloud.google.com/projectcreate";

    logger.trace();
    logger.log("== <w>Google authorisation key generation wizard</> ==");
    enum preludeMessage = `
To access the YouTube API you need to create a <i>Google application</> and generate a
<i>Client ID</> and a <i>Client secret</> for it.

<l>Attempting to open the <i>Google Cloud Dashboard<l> in your default web browser.</>
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
`In the <i>New Project</> dialog...

<i>*</> <l>Enter</> a <i>Project name</> (anything you want)
<i>*</> <l>Click</> <i>Create</>

If you have several Google projects, <w>make sure</> your project is now selected in
the <i>top bar</>; if not, <l>click</> the <i>project name box</> and <l>select</> it from the list.

<i>*</> <l>Click</> <i>APIs and Services</> in the left menu
<i>*</> <l>Click</> <i>Get Started</>
  <i>*</> <l>Enter</> an <i>App name</> (anything you want)
  <i>*</> <l>Enter</> your <i>email address</> as <i>User support email</>
  <i>*</> <l>Click</> <i>Next</>
  <i>*</> <l>Set</> <i>Audience</> to <i>External</>, then <l>click</> <i>Next</>
  <i>*</> <l>Enter</> your <i>email address</> as <i>Contact information</>
  <i>*</> <l>Agree</> to the <i>terms</>
  <i>*</> <l>Click</> <i>Continue</> and then <i>Create</>
<i>*</> <l>Select</> <i>Audience</> in the left menu
  <i>*</> <l>Add</> a <i>test user</> by pressing <i>+ Add users</>
    <i>*</> <l>Enter</> your <i>Google account email</> and <l>click</> <i>Save</>
<i>*</> <l>Select</> <i>Clients</> in the left menu
  <i>*</> <l>Click</> <i>+ Create Client</> up top
    <i>*</> <l>Choose</> <i>Desktop</> as <i>Application type</>
    <i>*</> <l>Enter</> a <i>Name</> (anything you want)
  <i>*</> <l>Copy</> the <i>Client ID</> by pressing the clipboard icon next to it,
    in the middle of the screen
    <i>*</> <l>Paste</> it somewhere, you'll need it soon
  <i>*</> <l>Click</> the name of the project in the same list to view its <i>additional information</>
  <i>*</> <l>Copy</> the <i>Client secret</> by pressing the clipboard icon next to it
    <i>*</> <l>Paste</> it next to your <i>Client ID</> so you have both ready
<i>*</> <l>Select</> <i>Data access</> in the left menu
  <i>*</> <l>Click</> <i>Add or remove scopes</>
    <i>*</> <l>Enter</> a <i>manual scope</>: "<i>https://www.googleapis.com/auth/youtube</>"
    <i>*</> <l>Click</> <i>Add to table</>, then <i>Update</>
      <i>*</> <l>Confirm</> that <i>Your sensitive scopes</> now includes "<i>../auth/youtube</>"
    <i>*</> <l>Click</> <i>Save</>
<i>*</> <l>Click</> the <i>navigation menu</> in the very top left (the three horizontal lines)
  <i>*</> <l>Click</> <i>APIs and Services</>
    <i>*</> <l>Click</> <i>+ Enable APIs and Services</>
      <i>*</> <l>Search</> for "<i>YouTube Data API v3</>", <l>select</> it, then <l>click</> <i>Enable</>

You also need to supply a <i>Twitch channel</> in which you would serve song requests.
(Channels are Twitch lowercase account names, prepended with a '<i>#</>' sign.)

Lastly you need a <i>YouTube playlist</> which songs would be added to.
Your current playlists can be found by clicking <i>Show More</> to the left
in the normal YouTube home screen. New playlists can be created by opening any
YouTube video page, clicking the <i>...</> button beneath the video, clicking
<i>Save</> and then <i>+ Create a new playlist</>.

A normal URL to any playlist you can modify will work fine. They do not have to be public.
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
    creds.googleClientID = readNamedString(
        readOAuthIDMessage,
        0, //72L,
        passThroughEmptyString: false,
        plugin.state.abort);
    if (*plugin.state.abort) return;

    enum readOAuthSecretMessage = "<l>Copy and paste your <i>OAuth Client secret<l>:</> ";
    creds.googleClientSecret = readNamedString(
        readOAuthSecretMessage,
        35L,
        passThroughEmptyString: false,
        plugin.state.abort);
    if (*plugin.state.abort) return;

    while (!creds.youtubePlaylistID.length)
    {
        enum playlistIDLength = 34;
        enum readPlaylistMessage = "<l>Copy and paste your <i>YouTube playlist URL<l>:</> ";
        immutable playlistURL = readNamedString(
            readPlaylistMessage,
            0L,
            passThroughEmptyString: false,
            plugin.state.abort);
        if (*plugin.state.abort) return;

        if (playlistURL.length == playlistIDLength)
        {
            // Likely a playlist ID
            creds.youtubePlaylistID = playlistURL;
        }
        else if (playlistURL.canFind("list="))
        {
            string slice = playlistURL;  // mutable
            slice.advancePast("list=");
            creds.youtubePlaylistID = slice.advancePast('&', inherit: true);
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

<l>Attempting to open a <i>Google authorisation page<l> in your default web browser.</>

Follow the instructions and log in to authorise the use of this program with your account.

It should ask you for an account twice;

<i>*</> ...once to select an account "<i>if you want to proceed to [project name]</>"
<i>*</> ...once to <i>choose your account or brand account</>

For the <i>brand account</>, <w>be sure</> to select a <i>YouTube-specific account</>
if presented with several alternatives. (One that says <i>YouTube</> underneath it
instead of your email address.)

<i>*</> <l>Click</> <i>Continue</> when you get to "<i>Google hasn't verified this app</>"
<i>*</> <l>Click</> <i>Continue</> when you get to "<i>[your app] wants access to your Google account</>"`;

    writeln(attemptToOpenPattern.expandTags(LogLevel.off));
    writeln(pasteAddressInstructions.expandTags(LogLevel.off));
    stdout.flush();

    enum authNode = "https://accounts.google.com/o/oauth2/v2/auth";
    enum urlPattern = authNode ~
        "?client_id=%s" ~
        "&redirect_uri=http://localhost" ~
        "&response_type=code" ~
        "&scope=https://www.googleapis.com/auth/youtube";
    immutable url = urlPattern.format(creds.googleClientID);

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
        code = slice.advancePast('&', inherit: true);

        if (code.length != 73L)
        {
            writeln();
            logger.error("Invalid code length. Try copying again or file a bug.");
            writeln();
            code = string.init;  // reset it so the while loop repeats
        }
    }

    // All done, fetch
    getGoogleTokens(creds, code, plugin.state.connSettings.caBundleFile);

    writeln();
    logger.info("Validating...");

    const results = validateGoogleToken(creds, plugin.state.connSettings.caBundleFile);
    if (*plugin.state.abort) return;

    if (!results.success)
    {
        throw new Exception(results.error);
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


// addVideoToYouTubePlaylist
/++
    Adds a video to the YouTube playlist whose ID is stored in the passed
    [kameloso.plugins.twitch.Credentials|Credentials].

    Note: Must be called from inside a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        creds = [kameloso.plugins.twitch.Credentials|Credentials] aggregate.
        videoID = YouTube video ID of the video to add.
        recursing = Whether or not the function is recursing into itself.

    Returns:
        A Voldemort of the results.

    Throws:
        [kameloso.net.UnexpectedJSONException|UnexpectedJSONException]
        on unexpected JSON.

        [kameloso.net.ErrorJSONException|ErrorJSONException]
        if the returned JSON has an `"error"` field.
 +/
auto addVideoToYouTubePlaylist(
    TwitchPlugin plugin,
    ref Credentials creds,
    const string videoID,
    const bool recursing = false)
in (Fiber.getThis(), "Tried to call `addVideoToYouTubePlaylist` from outside a fiber")
{
    import kameloso.plugins : sendHTTPRequest;
    import kameloso.tables : HTTPVerb;
    import std.algorithm.searching : endsWith;
    import std.format : format;
    import std.json : JSONValue, parseJSON;

    static struct AddVideoResults
    {
        uint code;
        string title;
        string description;
        string ownerChannelTitle;
        uint position;

        auto success() const { return (code == 200); }

        this(const uint code, const JSONValue json)
        {
            import std.array : replace;

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

            this.code = code;
            const snippetJSON = "snippet" in json;
            this.title = (*snippetJSON)["title"].str;
            this.ownerChannelTitle = (*snippetJSON)["videoOwnerChannelTitle"].str;
            this.position = cast(uint)(*snippetJSON)["position"].integer;
            this.description = (*snippetJSON)["description"].str
                .replace('\r', ' ')
                .replace('\n', ' ');
        }
    }

    enum url = "https://www.googleapis.com/youtube/v3/playlistItems?part=snippet";

    if (plugin.state.coreSettings.trace)
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

    enum dataPattern =
`{
  "snippet": {
    "playlistId": "%s",
    "resourceId": {
      "kind": "youtube#video",
      "videoId": "%s"
    }
  }
}`;

    auto data = cast(ubyte[])dataPattern.format(creds.youtubePlaylistID, videoID);

    immutable response = sendHTTPRequest(
        plugin: plugin,
        url: url,
        authorisationHeader: authorizationBearer,
        verb: HTTPVerb.post,
        body: data,
        contentType: "application/json");

    immutable responseJSON = parseJSON(response.body);

    if (response.code == 200) // ("id" in responseJSON)
    {
        // Seems to have worked
        return AddVideoResults(response.code, responseJSON);
    }

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

    immutable errorJSON = "error" in responseJSON;

    if (!errorJSON)
    {
        enum message = "Unexpected JSON when handling error after failing " ~
            "to add a video to a YouTube playlist";
        throw new UnexpectedJSONException(message, responseJSON);
    }

    immutable statusJSON = "status" in *errorJSON;

    if (statusJSON.str == "UNAUTHENTICATED")
    {
        if (!recursing)
        {
            refreshGoogleToken(plugin, creds);
            saveSecretsToDisk(plugin.secretsByChannel, plugin.secretsFile);
            return addVideoToYouTubePlaylist(plugin, creds, videoID, recursing: true);
        }

        immutable errorAAJSON = "errors" in *errorJSON;

        if (errorAAJSON && (errorAAJSON.array.length > 0))
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

    // If we're here, the above didn't match
    throw new ErrorJSONException((*errorJSON)["message"].str, *errorJSON);
}


// getGoogleTokens
/++
    Request OAuth API tokens from Google.

    Params:
        creds = [kameloso.plugins.twitch.Credentials|Credentials] aggregate.
        code = Google authorisation code.
        caBundleFile = Path to a `cacert.pem` bundle file.

    Throws:
        [kameloso.net.UnexpectedJSONException|UnexpectedJSONException]
        on unexpected JSON.

        [kameloso.net.ErrorJSONException|ErrorJSONException]
        if the returned JSON has an `"error"` field.
 +/
private void getGoogleTokens(
    ref Credentials creds,
    const string code,
    const string caBundleFile)
{
    import kameloso.net : HTTPRequest, issueSyncHTTPRequest;
    import kameloso.tables : HTTPVerb;
    import std.format : format;
    import std.json : parseJSON;

    enum urlPattern = "https://oauth2.googleapis.com/token" ~
        "?client_id=%s" ~
        "&client_secret=%s" ~
        "&code=%s" ~
        "&grant_type=authorization_code" ~
        "&redirect_uri=http://localhost";

    immutable url = urlPattern.format(creds.googleClientID, creds.googleClientSecret, code);

    const request = HTTPRequest(
        id: 0,
        url: url,
        caBundleFile: caBundleFile,
        verb: HTTPVerb.post);

    immutable response = issueSyncHTTPRequest(request);
    immutable responseJSON = parseJSON(response.body);

    /*
    {
        "access_token": "[redacted]"
        "expires_in": 3599,
        "refresh_token": "[redacted]",
        "scope": "https://www.googleapis.com/auth/youtube",
        "token_type": "Bearer"
    }
     */

    if (immutable errorJSON = "error" in responseJSON)
    {
        throw new ErrorJSONException(errorJSON.str, *errorJSON);
    }

    creds.googleAccessToken = responseJSON["access_token"].str;
    creds.googleRefreshToken = responseJSON["refresh_token"].str;
}


// refreshGoogleToken
/++
    Refreshes the OAuth API token in the passed Google credentials.

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        creds = [kameloso.plugins.twitch.Credentials|Credentials] aggregate.

    Throws:
        [kameloso.net.UnexpectedJSONException|UnexpectedJSONException]
        on unexpected JSON.

        [kameloso.net.ErrorJSONException|ErrorJSONException]
        if the returned JSON has an `"error"` field.
 +/
private void refreshGoogleToken(TwitchPlugin plugin, ref Credentials creds)
in (Fiber.getThis(), "Tried to call `refreshGoogleToken` from outside a fiber")
{
    import kameloso.plugins : sendHTTPRequest;
    import kameloso.tables : HTTPVerb;
    import std.format : format;
    import std.json : parseJSON;

    enum urlPattern = "https://oauth2.googleapis.com/token" ~
        "?client_id=%s" ~
        "&client_secret=%s" ~
        "&refresh_token=%s" ~
        "&grant_type=refresh_token";

    immutable url = urlPattern.format(
        creds.googleClientID,
        creds.googleClientSecret,
        creds.googleRefreshToken);

    immutable response = sendHTTPRequest(
        plugin: plugin,
        url: url,
        verb: HTTPVerb.post);

    immutable responseJSON = parseJSON(response.body);

    if (immutable errorJSON = "error" in responseJSON)
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

    creds.googleAccessToken = responseJSON["access_token"].str;
    // refreshToken is not present and stays the same as before
}


// validateGoogleToken
/++
    Validates a Google OAuth token, returning the JSON received from the server.

    Params:
        creds = [kameloso.plugins.twitch.Credentials|Credentials] aggregate.
        caBundleFile = Path to a `cacert.pem` bundle file.

    Returns:
        A Voldemort of the results.

    Throws:
        [kameloso.net.UnexpectedJSONException|UnexpectedJSONException]
        on unexpected JSON.

        [kameloso.net.ErrorJSONException|ErrorJSONException]
        if the returned JSON has an `"error"` field.
 +/
private auto validateGoogleToken(const Credentials creds, const string caBundleFile)
{
    import kameloso.net: HTTPRequest, issueSyncHTTPRequest;
    import std.json : JSONValue, parseJSON;
    import core.time : Duration, seconds;

    static struct GoogleValidationResults
    {
        uint code;
        string error;
        Duration expiresIn;

        auto success() const { return (code == 200); }

        this(const uint code, const string error)
        {
            this.code = code;
            this.error = error;
        }

        this(const uint code, const JSONValue json)
        {
            this.code = code;
            this.expiresIn = json["expires_in"].integer.seconds;
        }
    }

    enum urlHead = "https://www.googleapis.com/oauth2/v3/tokeninfo?access_token=";
    immutable url = urlHead ~ creds.googleAccessToken;

    const request = HTTPRequest(
        id: 0,
        url: url,
        caBundleFile: caBundleFile);

    immutable response = issueSyncHTTPRequest(request);
    immutable responseJSON = parseJSON(response.body);

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

    if ("expires_in" in responseJSON)
    {
        return GoogleValidationResults(response.code, responseJSON);
    }
    else if (immutable errorDescriptionJSON = "error_description" in responseJSON)
    {
        return GoogleValidationResults(response.code, *errorDescriptionJSON);
    }
    else
    {
        enum message = "Unexpected JSON response from server";
        throw new UnexpectedJSONException(message, responseJSON);
    }
}
