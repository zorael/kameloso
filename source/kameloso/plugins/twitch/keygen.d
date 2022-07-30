/++
    Functions for generating a Twitch API key.

    See_Also:
        [kameloso.plugins.twitch.base|twitch.base]
        [kameloso.plugins.twitch.api|twitch.api]
 +/
module kameloso.plugins.twitch.keygen;

version(TwitchSupport):
version(WithTwitchPlugin):

private:

import kameloso.plugins.twitch.base;
import kameloso.plugins.twitch.helpers;
import kameloso.logger : LogLevel, logger;
import kameloso.terminal.colours.tags : expandTags;
import std.typecons : Flag, No, Yes;

package:


// requestTwitchKey
/++
    Start the captive key generation routine at the earliest possible moment,
    which are the [dialect.defs.IRCEvent.Type.CAP|CAP] events.

    Invoked by [kameloso.plugins.twitch.base.onCAP|onCAP] during capability negotiation.

    We can't do it in [kameloso.plugins.twitch.base.start|start] since the calls to
    save and exit would go unheard, as `start` happens before the main loop starts.
    It would then immediately fail to read if too much time has passed,
    and nothing would be saved.

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
 +/
void requestTwitchKey(TwitchPlugin plugin)
{
    import kameloso.thread : ThreadMessage;
    import std.concurrency : prioritySend;
    import std.process : Pid, ProcessException, wait;
    import std.stdio : stdout, writefln, writeln;
    import std.datetime.systime : Clock;

    scope(exit) if (plugin.state.settings.flush) stdout.flush();

    logger.trace();
    logger.info("-- Twitch authorisation key generation mode --");
    enum attemptToOpenMessage = `
Attempting to open a Twitch login page in your default web browser. Follow the
instructions and log in to authorise the use of this program with your <w>BOT</> account.

<l>Then paste the address of the page you are redirected to afterwards here.</>

* The redirected address should start with <i>http://localhost</>.
* It will probably say "<l>this site can't be reached</>" or "<l>unable to connect</>".
* <l>The key generated will be one for the account you are currently logged in as in your browser.</>
  If you are logged into your main Twitch account and you want the bot to use a
  separate account, you will have to log out and log in as that first, before
  attempting this. Use an incognito/private window.
* If you are running local web server on port <i>80</>, you may have to temporarily
  disable it for this to work.
`;
    writeln(attemptToOpenMessage.expandTags(LogLevel.off));
    if (plugin.state.settings.flush) stdout.flush();

    static immutable scopes =
    [
        // New Twitch API
        // --------------------------
        //"analytics:read:extension",
        //"analytics:read:games",
        //"bits:read",
        //"channel:edit:commercial",
        //"channel:manage:broadcast",
        //"channel:manage:extensions"
        //"channel:manage:polls",
        //"channel:manage:predictions",
        //"channel:manage:redemptions",
        //"channel:manage:schedule",
        //"channel:manage:videos",
        //"channel:read:editors",
        //"channel:read:goals",
        //"channel:read:hype_train",
        //"channel:read:polls",
        //"channel:read:predictions",
        //"channel:read:redemptions",
        //"channel:read:stream_key",
        //"channel:read:subscriptions",
        //"clips:edit",
        //"moderation:read",
        //"moderator:manage:banned_users",
        //"moderator:read:blocked_terms",
        //"moderator:manage:blocked_terms",
        //"moderator:manage:automod",
        //"moderator:read:automod_settings",
        //"moderator:manage:automod_settings",
        //"moderator:read:chat_settings",
        //"moderator:manage:chat_settings",
        //"user:edit",
        //"user:edit:follows",
        //"user:manage:blocked_users",
        //"user:read:blocked_users",
        //"user:read:broadcast",
        //"user:read:email",
        //"user:read:follows",
        //"user:read:subscriptions"
        //"user:edit:broadcast",    // removed/undocumented? implied user:read:broadcast

        // Twitch APIv5
        // --------------------------
        //"channel_check_subscription",  // removed/undocumented?
        //"channel_subscriptions",
        //"channel_commercial",
        //"channel_editor",
        //"channel_feed_edit",      // removed/undocumented?
        //"channel_feed_read",      // removed/undocumented?
        //"user_follows_edit",
        //"channel_read",
        //"channel_stream",         // removed/undocumented?
        //"collections_edit",       // removed/undocumented?
        //"communities_edit",       // removed/undocumented?
        //"communities_moderate",   // removed/undocumented?
        //"openid",                 // removed/undocumented?
        //"user_read",
        //"user_blocks_read",
        //"user_blocks_edit",
        //"user_subscriptions",     // removed/undocumented?
        //"viewing_activity_read",  // removed/undocumented?

        // Chat and PubSub
        // --------------------------
        "channel:moderate",
        "chat:edit",
        "chat:read",
        "whispers:edit",
        "whispers:read",
    ];

    Pid browser;
    scope(exit) if (browser !is null) wait(browser);

    enum authNode = "https://id.twitch.tv/oauth2/authorize";
    immutable url = buildAuthNodeURL(authNode, scopes);

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
            openInBrowser(url);
        }
        catch (ProcessException e)
        {
            // Probably we got some platform wrong and command was not found
            logger.warning("Error: could not automatically open browser.");
            printManualURL(url);
            if (plugin.state.settings.flush) stdout.flush();
        }
    }

    plugin.state.bot.pass = readURLAndParseKey(plugin, authNode);
    if (*plugin.state.abort) return;

    writeln();
    logger.info("Validating...");

    immutable expiry = getTokenExpiry(plugin, plugin.state.bot.pass);
    if (*plugin.state.abort) return;

    immutable delta = (expiry - Clock.currTime);
    immutable numDays = delta.total!"days";

    enum isValidPattern = "Your key is valid for another <l>%d</> days.";
    logger.infof(isValidPattern, numDays);
    logger.trace();

    plugin.state.updates |= typeof(plugin.state.updates).bot;
    plugin.state.mainThread.prioritySend(ThreadMessage.save());
}


// requestTwitchSuperKey
/++
    Start the captive key generation routine at the earliest possible moment,
    which are the [dialect.defs.IRCEvent.Type.CAP|CAP] events.

    Invoked by [kameloso.plugins.twitch.base.onCAP|onCAP] during capability negotiation.

    We can't do it in [kameloso.plugins.twitch.base.start|start] since the calls to
    save and exit would go unheard, as `start` happens before the main loop starts.
    It would then immediately fail to read if too much time has passed,
    and nothing would be saved.

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
 +/
void requestTwitchSuperKey(TwitchPlugin plugin)
{
    import std.process : Pid, ProcessException, wait;
    import std.stdio : stdout, writefln, writeln;
    import std.datetime.systime : Clock;

    scope(exit) if (plugin.state.settings.flush) stdout.flush();

    logger.trace();
    logger.info("-- Twitch authorisation super key generation mode --");
    enum message = `
To access certain Twitch functionality like changing channel settings
(what game is currently being played, etc), the program needs an authorisation
key that corresponds to the owner of that channel.

In the instructions that follow, it is essential that you are logged into the
<w>STREAMER</> account in your browser.

You also need to supply the channel for which it all relates.
(Channels are Twitch lowercase account names, prepended with a '<i>#</>' sign.)
`;
    writeln(message.expandTags(LogLevel.off));

    immutable channel = readNamedString("<l>Enter your <i>#channel<l>:</> ",
        0L, *plugin.state.abort);
    if (*plugin.state.abort) return;

    enum attemptToOpenMessage = `
--------------------------------------------------------------------------------

Attempting to open a Twitch login page in your default web browser. Follow the
instructions and log in to authorise the use of this program with your <w>STREAMER</> account.

<l>Then paste the address of the page you are redirected to afterwards here.</>

* The redirected address should start with <i>http://localhost</>.
* It will probably say "<l>this site can't be reached</>" or "<l>unable to connect</>".
* <l>The key generated will be one for the account you are currently logged in as in your browser.</>
  You should be logged into your main Twitch account for this key.
* If you are running local web server on port <i>80</>, you may have to temporarily
  disable it for this to work.
`;
    writeln(attemptToOpenMessage.expandTags(LogLevel.off));
    if (plugin.state.settings.flush) stdout.flush();

    static immutable scopes =
    [
        // New Twitch API
        // --------------------------
        //"analytics:read:extension",
        //"analytics:read:games",
        //"bits:read",
        "channel:edit:commercial",
        "channel:manage:broadcast",
        //"channel:manage:extensions"
        "channel:manage:polls",
        "channel:manage:predictions",
        //"channel:manage:redemptions",
        //"channel:manage:schedule",
        //"channel:manage:videos",
        "channel:read:editors",
        "channel:read:goals",
        "channel:read:hype_train",
        "channel:read:polls",
        //"channel:read:predictions",
        //"channel:read:redemptions",
        //"channel:read:stream_key",
        //"channel:read:subscriptions",
        //"clips:edit",
        "moderation:read",
        "moderator:manage:banned_users",
        "moderator:read:blocked_terms",
        "moderator:manage:blocked_terms",
        "moderator:manage:automod",
        "moderator:read:automod_settings",
        "moderator:manage:automod_settings",
        "moderator:read:chat_settings",
        "moderator:manage:chat_settings",
        //"user:edit",
        //"user:edit:follows",
        //"user:manage:blocked_users",
        //"user:read:blocked_users",
        //"user:read:broadcast",
        //"user:read:email",
        //"user:read:follows",
        //"user:read:subscriptions"
        //"user:edit:broadcast",    // removed/undocumented? implied user:read:broadcast

        // Twitch APIv5
        // --------------------------
        //"channel_check_subscription",  // removed/undocumented?
        //"channel_subscriptions",
        //"channel_commercial",
        //"channel_editor",
        //"channel_feed_edit",      // removed/undocumented?
        //"channel_feed_read",      // removed/undocumented?
        //"user_follows_edit",
        //"channel_read",
        //"channel_stream",         // removed/undocumented?
        //"collections_edit",       // removed/undocumented?
        //"communities_edit",       // removed/undocumented?
        //"communities_moderate",   // removed/undocumented?
        //"openid",                 // removed/undocumented?
        //"user_read",
        //"user_blocks_read",
        //"user_blocks_edit",
        //"user_subscriptions",     // removed/undocumented?
        //"viewing_activity_read",  // removed/undocumented?

        // Chat and PubSub
        // --------------------------
        //"channel:moderate",
        //"chat:edit",
        //"chat:read",
        //"whispers:edit",
        //"whispers:read",
    ];

    Pid browser;
    scope(exit) if (browser !is null) wait(browser);

    enum authNode = "https://id.twitch.tv/oauth2/authorize";
    immutable url = buildAuthNodeURL(authNode, scopes);

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
            openInBrowser(url);
        }
        catch (ProcessException e)
        {
            // Probably we got some platform wrong and command was not found
            logger.warning("Error: could not automatically open browser.");
            printManualURL(url);
            if (plugin.state.settings.flush) stdout.flush();
        }
    }

    Credentials creds;
    creds.broadcasterKey = readURLAndParseKey(plugin, authNode);

    if (*plugin.state.abort) return;

    if (auto storedCreds = channel in plugin.secretsByChannel)
    {
        import lu.meld : MeldingStrategy, meldInto;
        creds.meldInto!(MeldingStrategy.aggressive)(*storedCreds);
    }
    else
    {
        plugin.secretsByChannel[channel] = creds;
    }

    writeln();
    logger.info("Validating...");

    immutable expiry = getTokenExpiry(plugin, creds.broadcasterKey);
    if (*plugin.state.abort) return;

    immutable delta = (expiry - Clock.currTime);
    immutable numDays = delta.total!"days";

    enum isValidPattern = "Your key is valid for another <l>%d</> days.";
    logger.infof(isValidPattern, numDays);
    logger.trace();

    saveSecretsToDisk(plugin.secretsByChannel, plugin.secretsFile);
}


// readURLAndParseKey
/++
    Reads an URL from standard in and parses an OAuth key from it.

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        authNode = Authentication node URL, to detect whether the wrong link was pasted.

    Returns:
        An OAuth token key parsed from a pasted URL string.
 +/
private string readURLAndParseKey(TwitchPlugin plugin, const string authNode)
{
    import lu.string : contains, nom, stripped;
    import std.stdio : readln, stdin, stdout, write, writeln;

    string key;

    while (!key.length)
    {
        scope(exit) if (plugin.state.settings.flush) stdout.flush();

        enum pasteMessage = "<l>Paste the address of empty the page you were redirected to here (empty line exits):</>

> ";
        write(pasteMessage.expandTags(LogLevel.off));
        stdout.flush();

        stdin.flush();
        immutable readURL = readln().stripped;

        if (!readURL.length || *plugin.state.abort)
        {
            writeln();
            logger.warning("Aborting.");
            logger.trace();
            *plugin.state.abort = true;
            return string.init;
        }

        if (readURL.length == 30)
        {
            // As is
            key = readURL;
        }
        else if (!readURL.contains("access_token="))
        {
            import lu.string : beginsWith;

            writeln();

            if (readURL.beginsWith(authNode))
            {
                enum wrongPageMessage = "Not that page; the empty page you're " ~
                    "lead to after clicking <l>Authorize</>.";
                logger.error(wrongPageMessage);
            }
            else
            {
                logger.error("Could not make sense of URL. Try copying again or file a bug.");
            }

            writeln();
            continue;
        }

        string slice = readURL;  // mutable
        slice.nom("access_token=");
        key = slice.nom('&');

        if (key.length != 30L)
        {
            writeln();
            logger.error("Invalid key length!");
            writeln();
            key = string.init;  // reset it so the while loop repeats
        }
    }

    return key;
}


// buildAuthNodeURL
/++
    Constructs an authorisation node URL with the passed scopes.

    Params:
        authNode = Base authorisation node URL.
        scopes = OAuth scope string array.

    Returns:
        An URL string.
 +/
private string buildAuthNodeURL(const string authNode, const string[] scopes)
{
    import std.array : join;
    import std.conv : text;

    return text(
        authNode,
        "?response_type=token",
        "&client_id=", TwitchPlugin.clientID,
        "&redirect_uri=http://localhost",
        "&scope=", scopes.join('+'),
        "&force_verify=true",
        "&state=kameloso");
}


// getTokenExpiry
/++
    Validates an authorisation token and returns a [std.datetime.systime.SysTime|SysTime]
    of when it expires.

    Params:
        plugin = The current [kameloso.plugins.twitch.base.TwitchPlugin|TwitchPlugin].
        authToken = Authorisation token to validate and check expiry of.

    Returns:
        A [std.datetime.systime.SysTime|SysTime] of when the passed token expires.
 +/
auto getTokenExpiry(TwitchPlugin plugin, const string authToken)
{
    import kameloso.plugins.twitch.api : getValidation;
    import std.datetime.systime : Clock, SysTime;

    immutable validationJSON = getValidation(plugin, authToken, No.async);
    immutable expiresIn = validationJSON["expires_in"].integer;
    immutable expiresWhen = SysTime.fromUnixTime(Clock.currTime.toUnixTime + expiresIn);
    return expiresWhen;
}
