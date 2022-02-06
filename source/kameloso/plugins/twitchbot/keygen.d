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
    logger.info(string.init);
    writefln(string.init, Tint.log, Tint.off, Tint.info);

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
        enum scissors = "";

        writefln(string.init, Tint.log, Tint.off, Tint.info, scissors, url);
    }

    if (plugin.state.settings.force)
    {
        logger.warning(string.init);
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
            logger.warning(string.init);
            printManualURL();
        }
    }

    string key;

    while (!key.length)
    {
        import std.stdio : writef;

        writef(string.init, Tint.log, Tint.off);
        stdout.flush();

        stdin.flush();
        immutable readURL = readln().stripped;

        if (!readURL.length || *plugin.state.abort)
        {
            writeln();
            logger.warning(string.init);
            logger.trace();
            return;
        }

        if (!readURL.contains("access_token="))
        {
            writeln();
            logger.error(string.init);
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

    writefln(string.init, Tint.log, Tint.info, key, Tint.off);

    if (!plugin.state.settings.saveOnExit)
    {
        write(string.init);
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
            writefln(string.init,
                Tint.info, plugin.state.settings.configFile, Tint.off);
        }
    }

    writefln(string.init, Tint.info, Tint.off, Tint.log);
}
