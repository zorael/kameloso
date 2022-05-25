/++
    Functions for generating a Twitch API key.

    See_Also:
        [kameloso.plugins.twitchbot.base|twitchbot.base]
        [kameloso.plugins.twitchbot.api|twitchbot.api]
 +/
module kameloso.plugins.twitchbot.keygen;

version(TwitchSupport):
version(WithTwitchBotPlugin):

private:

import kameloso.plugins.twitchbot.base;

package:


// generateKey
/++
    Start the captive key generation routine at the earliest possible moment,
    which are the [dialect.defs.IRCEvent.Type.CAP|CAP] events.

    Invoked by [kameloso.plugins.twitchbot.base.onCAP|onCAP] during capability negotiation.

    We can't do it in [kameloso.plugins.twitchbot.base.start|start] since the calls to
    save and exit would go unheard, as `start` happens before the main loop starts.
    It would then immediately fail to read if too much time has passed,
    and nothing would be saved.
 +/
void generateKey(TwitchBotPlugin plugin)
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
    logger.info("-- Twitch authorisation key generation mode --");
    enum attemptToOpenPattern = `
Attempting to open a Twitch login page in your default web browser. Follow the
instructions and log in to authorise the use of this program with your account.

<l>Then paste the address of the page you are redirected to afterwards here.</>

* The redirected address should start with <i>http://localhost</>.
* It will probably say "<l>this site can't be reached</>" or "<l>unable to connect</>".
* If you are logged into your main Twitch account and you want the bot to use a
  separate account, you will have to log out and log in as that first, before
  attempting this. <l>The key generated is one for the account currently logged in.</>
* If you are running local web server on port <i>80</>, you may have to temporarily
  disable it for this to work.
`;
    writeln(attemptToOpenPattern.expandTags(LogLevel.off));
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

    import std.array : join;

    enum authNode = "https://id.twitch.tv/oauth2/authorize";
    enum ctBaseURL = authNode ~
        "?response_type=token" ~
        "&client_id=" ~ TwitchBotPlugin.clientID ~
        "&redirect_uri=http://localhost" ~
        "&scope=" ~ scopes.join('+') ~
        "&force_verify=true" ~
        "&state=kameloso-";

    Pid browser;
    immutable url = ctBaseURL ~ plugin.state.client.nickname;

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
            openInBrowser(url);
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

    plugin.state.bot.pass = key;
    plugin.state.updates |= typeof(plugin.state.updates).bot;

    enum keyPattern = "
<l>Your private authorisation key is: <i>%s</>
It should be entered as <i>pass</> under <i>[IRCBot]</>.
";
    writefln(keyPattern.expandTags(LogLevel.off), key);

    if (!plugin.state.settings.saveOnExit)
    {
        write("Do you want to save it there now? [Y/*]: ");
        stdout.flush();

        stdin.flush();
        immutable input = readln().stripped;
        if (*plugin.state.abort) return;

        if (!input.length || (input == "y") || (input == "Y"))
        {
            import std.concurrency : prioritySend;
            plugin.state.mainThread.prioritySend(ThreadMessage.save());
        }
        else
        {
            enum keyAddPattern = "\n* Make sure to add it to <i>%s</>, then.";
            writefln(keyAddPattern.expandTags(LogLevel.off), plugin.state.settings.configFile);
            if (plugin.state.settings.flush) stdout.flush();
        }
    }

    enum issuePattern = "
--------------------------------------------------------------------------------

All done! Restart the program (without <i>--set twitchbot.keygen</>) and it should
just work. If it doesn't, please file an issue at:

    <i>https://github.com/zorael/kameloso/issues/new</>

<l>Note: keys are valid for 60 days, after which this process needs to be repeated.</>
";
    writeln(issuePattern.expandTags(LogLevel.off));
    if (plugin.state.settings.flush) stdout.flush();
}
