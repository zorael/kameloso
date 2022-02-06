
module kameloso.plugins.twitchbot.keygen;

import kameloso.plugins.twitchbot.base;

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
    writefln(`
Attempting to open a Twitch login page in your default web browser. Follow the
instructions and log in to authorise the use of this program with your account.

%1$sThen paste the address of the page you are redirected to afterwards here.%2$s

* The redirected address should start with %3$shttp://localhost%2$s.
* It will probably say "%1$sthis site can't be reached%2$s".
* If your browser is already logged in on Twitch, it will likely immediately
  lead you to this page without asking for login credentials. If you want to
  generate a key for a different account, first log out and retry.
* If you are running local web server on port %3$s80%2$s, you may have to
  temporarily disable it for this to work.
`, Tint.log, Tint.off, Tint.info);

    static immutable scopes =
    [
        

        
        
        "bits:read",
        "channel:edit:commercial",
        "channel:read:subscriptions",
        
        "user:edit",
        "user:edit:broadcast",  
        
        
        

        

        
        
        "channel_editor",
        
        
        
        
        
        
        
        
        
        "user_blocks_edit",
        "user_blocks_read",
        "user_follows_edit",
        
        
        

        

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
        "&force_verify=true" ~
        "&state=kameloso-";

    Pid browser;
    immutable url = ctBaseURL ~ plugin.state.client.nickname;

    scope(exit) if (browser !is null) wait(browser);

    void printManualURL()
    {
        enum scissors = "8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8<";

        writefln(`
%1$sCopy and paste this link manually into your browser, and log in as asked:%2$s

%3$s%4$s%2$s

%5$s

%3$s%4$s%2$s
`, Tint.log, Tint.off, Tint.info, scissors, url);
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
                    
                    enum open = "xdg-open";
                }

                immutable browserExecutable = environment.get("BROWSER", open);
                string[2] browserCommand = [ browserExecutable, url ];  
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
                
                throw new ProcessException("Unexpected platform");
            }
        }
        catch (ProcessException e)
        {
            
            logger.warning("Error: could not automatically open browser.");
            printManualURL();
        }
    }

    string key;

    while (!key.length)
    {
        import std.stdio : writef;

        writef("%1$sPaste the addresss of the page you were redirected to here (empty line exits):%2$s

> ", Tint.log, Tint.off);
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

        string slice = readURL;  
        slice.nom("access_token=");
        key = slice.nom('&');

        if (key.length != 30L)
        {
            writeln();
            logger.error("Invalid key length!");
            writeln();
            key = string.init;  
        }
    }

    plugin.state.bot.pass = key;
    plugin.state.botUpdated = true;

    writefln("
%1$sYour private authorisation key is: %2$s%3$s%4$s
It should be entered as %2$spass%4$s under %2$s[IRCBot]%4$s.
", Tint.log, Tint.info, key, Tint.off);

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
            writefln("\n* Make sure to add it to %s%s%s, then.",
                Tint.info, plugin.state.settings.configFile, Tint.off);
        }
    }

    writefln("
--------------------------------------------------------------------------------

All done! Restart the program (without %1$s--set twitchbot.keygen%2$s) and it should
just work. If it doesn't, please file an issue at:

    %1$shttps://github.com/zorael/kameloso/issues/new%2$s

%3$sNote: keys are valid for 60 days, after which this process needs to be repeated.%2$s
", Tint.info, Tint.off, Tint.log);
}
