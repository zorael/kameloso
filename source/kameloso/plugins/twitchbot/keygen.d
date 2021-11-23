/++
    Functions for generating a Twitch API key.

    See_Also:
        [kameloso.plugins.twitchbot.base]
        [kameloso.plugins.twitchbot.api]
 +/
module kameloso.plugins.twitchbot.keygen;

version(WithPlugins):
version(TwitchSupport):
version(WithTwitchBotPlugin):
version(TwitchAPIFeatures):

private:

import kameloso.plugins.twitchbot.base;

package:


// generateKey
/++
    Start the captive key generation routine at the earliest possible moment,
    which are the CAP events.

    Invoked by [kameloso.plugins.twitchbot.base.onCAP] during capability negotiation.

    We can't do it in [kameloso.plugins.twitchbot.base.start] since the calls to
    save and exit would go unheard, as `start` happens before the main loop starts.
    It would then immediately fail to read if too much time has passed,
    and nothing would be saved.
 +/
void generateKey(TwitchBotPlugin plugin)
{
    import kameloso.common : Tint, logger;
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
    writeln();
    writeln("Attempting to open a Twitch login page in your default web browser. Follow the");
    writeln("instructions and log in to authorise the use of this program with your account.");
    writeln();
    writeln(Tint.log, "Then paste the address of the page you are redirected to afterwards here.", Tint.off);
    writeln();
    writefln("* The redirected address should start with %shttp://localhost%s.", Tint.info, Tint.off);
    writefln(`* It will probably say "%sthis site can't be reached%s".`, Tint.log, Tint.off);
    writeln("* If your browser is already logged in on Twitch, it will likely immediately");
    writeln("  lead you to this page without asking for login credentials. If you want to");
    writeln("  generate a key for a different account, first log out and retry.");
    writefln("* If you are running local web server on port %s80%s, you may have to", Tint.info, Tint.off);
    writeln("  temporarily disable it for this to work.");
    writeln();
    stdout.flush();

    static immutable scopes =
    [
        // New Twitch API

        //"analytics:read:extension",
        //"analytics:read:games",
        "bits:read",
        "channel:edit:commercial",
        "channel:read:subscriptions",
        //"clips:edit",
        "user:edit",
        "user:edit:broadcast",  // implies user:read:broadcast
        //"user:edit:follows",
        //"user:read:broadcast",
        //"user:read:email",

        // Twitch APIv5

        //"channel_check_subscription",
        //"channel_commercial",
        "channel_editor",
        //"channel_feed_edit",
        //"channel_feed_read",
        //"channel_read",
        //"channel_stream",
        //"channel_subscriptions",
        //"collections_edit",
        //"communities_edit",
        //"communities_moderate",
        //"openid",
        "user_blocks_edit",
        "user_blocks_read",
        "user_follows_edit",
        //"user_read",
        //"user_subscriptions",
        //"viewing_activity_read",

        // Chat and PubSub

        "channel:moderate",
        "chat:edit",
        "chat:read",
        "whispers:edit",
        "whispers:read",
    ];

    import std.array : join;

    enum ctBaseURL = "https://id.twitch.tv/oauth2/authorize?response_type=token" ~
        "&client_id=" ~ TwitchBotPlugin.clientID ~
        "&redirect_uri=http://localhost" ~
        "&scope=" ~ scopes.join('+') ~
        "&state=kameloso-";

    Pid browser;
    immutable url = ctBaseURL ~ plugin.state.client.nickname ~
        (plugin.state.settings.force ? "&force_verify=true" : string.init);

    scope(exit) if (browser !is null) wait(browser);

    void printManualURL()
    {
        enum scissors = "8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8<";

        writeln();
        writeln(Tint.log, "Copy and paste this link manually into your browser, " ~
            "and log in as asked:", Tint.off);
        writeln();
        writeln(Tint.info, scissors, Tint.off);
        writeln();
        writeln(url);
        writeln();
        writeln(Tint.info, scissors, Tint.off);
        writeln();
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

                immutable urlBasename = "kameloso-twitch-%s.url"
                    .format(plugin.state.client.nickname);
                immutable urlFileName = buildPath(tempDir, urlBasename);

                auto urlFile = File(urlFileName, "w");

                urlFile.writeln("[InternetShortcut]");
                urlFile.writeln("URL=", url);
                urlFile.flush();

                immutable string[2] browserCommand = [ "explorer", urlFileName ];
                auto nulFile = File("NUL", "r+");
                browser = spawnProcess(browserCommand[], nulFile, nulFile, nulFile);
            }
            else
            {
                // Jump to the catch
                throw new ProcessException("Unexpected platform");
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
        writeln(Tint.log, "Paste the address of the page you were redirected to here " ~
            "(empty line exits):", Tint.off);
        writeln();
        write("> ");
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

        if (!readURL.contains("access_token="))
        {
            writeln();
            logger.error("Could not make sense of URL. Try again or file a bug.");
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
    plugin.state.botUpdated = true;

    writeln();
    writefln("%sYour private authorisation key is: %s%s%s",
        Tint.log, Tint.info, key, Tint.off);
    writefln("It should be entered as %spass%s under %1$s[IRCBot]%2$s.",
        Tint.info, Tint.off);
    writeln();

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
            plugin.state.mainThread.prioritySend(ThreadMessage.Save());
        }
        else
        {
            writeln();
            writefln("* Make sure to add it to %s%s%s, then.",
                Tint.info, plugin.state.settings.configFile, Tint.off);
        }
    }

    writeln();
    writeln("-------------------------------------------------------------------------------");
    writeln();
    writefln("All done! Restart the program (without %s--set twitchbot.keygen%s) and it should",
        Tint.info, Tint.off);
    writeln("just work. If it doesn't, please file an issue, at:");
    writeln();
    writeln("    ", Tint.info, "https://github.com/zorael/kameloso/issues/new", Tint.off);
    writeln();
    writeln(Tint.log, "Note: this will need to be repeated once every 60 days.", Tint.off);
    writeln();
}
