/++
    Functions that deal with OS- and/or platform-specifics.
 +/
module kameloso.platform;

public:

@safe:


// currentPlatform
/++
    Returns the string of the name of the current platform, adjusted to include
    `cygwin` as an alternative next to `win32` and `win64`, as well as embedded
    terminal consoles like in Visual Studio Code.

    Example:
    ---
    switch (currentPlatform)
    {
    case "Cygwin":
    case "vscode":
        // Special code for the terminal not being a conventional terminal
        // (instead acting like a pager)
        break;

    default:
        // Code for normal terminal
        break;
    }
    ---

    Returns:
        String name of the current platform.
 +/
auto currentPlatform()
{
    import lu.conv : Enum;
    import std.process : environment;
    import std.system : os;

    enum osName = Enum!(typeof(os)).toString(os);

    version(Windows)
    {
        immutable term = environment.get("TERM", string.init);

        if (term.length)
        {
            try
            {
                import std.process : execute;

                // Get the uname and strip the newline
                static immutable unameCommand = [ "uname", "-o" ];
                immutable uname = execute(unameCommand).output;
                return uname.length ? uname[0..$-1] : osName;
            }
            catch (Exception _)
            {
                return osName;
            }
        }
        else
        {
            return osName;
        }
    }
    else
    {
        return environment.get("TERM_PROGRAM", osName);
    }
}


// configurationBaseDirectory
/++
    Divines the default configuration file base directory, depending on what
    platform we're currently running.

    On non-macOS Posix it defaults to `$XDG_CONFIG_HOME` and falls back to
    `~/.config` if no `$XDG_CONFIG_HOME` environment variable present.

    On macOS it defaults to `$HOME/Library/Application Support`.

    On Windows it defaults to `%APPDATA%`.

    Returns:
        A string path to the default configuration file.
 +/
auto configurationBaseDirectory()
{
    import std.process : environment;

    version(OSX)
    {
        import std.path : buildNormalizedPath;
        return buildNormalizedPath(
            environment["HOME"],
            "Library",
            "Preferences");
    }
    else version(Posix)
    {
        import std.path : expandTilde;

        // Assume XDG
        enum defaultDir = "~/.config";
        return environment.get("XDG_CONFIG_HOME", defaultDir).expandTilde;
    }
    else version(Windows)
    {
        // Blindly assume %APPDATA% is defined
        return environment["APPDATA"];
    }
    else
    {
        static assert(0, "Unsupported platform, please file a bug.");
    }
}

///
unittest
{
    import std.algorithm.searching : endsWith;

    immutable cfgd = configurationBaseDirectory;

    version(OSX)
    {
        assert(cfgd.endsWith("Library/Preferences"), cfgd);
    }
    else version(Posix)
    {
        import std.process : environment;

        environment["XDG_CONFIG_HOME"] = "/tmp";
        immutable cfgdTmp = configurationBaseDirectory;
        assert((cfgdTmp == "/tmp"), cfgdTmp);

        environment.remove("XDG_CONFIG_HOME");
        immutable cfgdWithout = configurationBaseDirectory;
        assert(cfgdWithout.endsWith("/.config"), cfgdWithout);
    }
    else version(Windows)
    {
        assert(cfgd.endsWith("\\Roaming"), cfgd);
    }
}


// resourceBaseDirectory
/++
    Divines the default resource base directory, depending on what platform
    we're currently running.

    On non-macOS Posix it defaults to `$XDG_DATA_HOME` and falls back to
    `$HOME/.local/share` if no `$XDG_DATA_HOME` environment variable present.

    On macOS it defaults to `$HOME/Library/Application Support`.

    On Windows it defaults to `%LOCALAPPDATA%`.

    Returns:
        A string path to the default resource base directory.
 +/
auto resourceBaseDirectory()
{
    import std.process : environment;

    version(OSX)
    {
        import std.path : buildNormalizedPath;
        return buildNormalizedPath(
            environment["HOME"],
            "Library",
            "Application Support");
    }
    else version(Posix)
    {
        import std.path : expandTilde;
        enum defaultDir = "~/.local/share";
        return environment.get("XDG_DATA_HOME", defaultDir).expandTilde;
    }
    else version(Windows)
    {
        // Blindly assume %LOCALAPPDATA% is defined
        return environment["LOCALAPPDATA"];
    }
    else
    {
        static assert(0, "Unsupported platform, please file a bug.");
    }
}

///
unittest
{
    import std.algorithm.searching : endsWith;

    version(OSX)
    {
        immutable rbd = resourceBaseDirectory;
        assert(rbd.endsWith("Library/Application Support"), rbd);
    }
    else version(Posix)
    {
        import lu.string : beginsWith;
        import std.process : environment;

        environment["XDG_DATA_HOME"] = "/tmp";
        string rbd = resourceBaseDirectory;
        assert((rbd == "/tmp"), rbd);

        environment.remove("XDG_DATA_HOME");
        rbd = resourceBaseDirectory;
        assert(rbd.beginsWith("/home/") && rbd.endsWith("/.local/share"));
    }
    else version(Windows)
    {
        immutable rbd = resourceBaseDirectory;
        assert(rbd.endsWith("\\Local"), rbd);
    }
}


// openInBrowser
/++
    Opens up the passed URL in a web browser.

    Params:
        url = URL to open.

    Returns:
        A [std.process.Pid|Pid] of the spawned process. Remember to [std.process.wait|wait].

    Throws:
        [object.Exception|Exception] if there were no `DISPLAY` environment
        variable on non-macOS Posix platforms, indicative of no X.org server or
        Wayland compositor running.
 +/
auto openInBrowser(const string url)
{
    import std.stdio : File;

    version(Posix)
    {
        import std.process : ProcessException, environment, spawnProcess;

        version(OSX)
        {
            enum open = "open";
        }
        else
        {
            // Assume XDG
            enum open = "xdg-open";

            if (!environment.get("DISPLAY", string.init).length &&
                !environment.get("WAYLAND_DISPLAY", string.init).length)
            {
                throw new Exception("No graphical interface detected");
            }
        }

        immutable browserExecutable = environment.get("BROWSER", open);
        string[2] browserCommand = [ browserExecutable, url ];  // mutable
        auto devNull = File("/dev/null", "r+");

        try
        {
            return spawnProcess(browserCommand[], devNull, devNull, devNull);
        }
        catch (ProcessException e)
        {
            if (browserExecutable == open) throw e;

            browserCommand[0] = open;
            return spawnProcess(browserCommand[], devNull, devNull, devNull);
        }
    }
    else version(Windows)
    {
        import std.file : tempDir;
        import std.format : format;
        import std.path : buildPath;
        import std.process : spawnProcess;

        enum urlBasename = "kameloso-browser.url";
        immutable urlFileName = buildPath(tempDir, urlBasename);

        {
            auto urlFile = File(urlFileName, "w");
            urlFile.writeln("[InternetShortcut]\nURL=", url);
        }

        immutable string[2] browserCommand = [ "explorer", urlFileName ];
        auto nulFile = File("NUL", "r+");
        return spawnProcess(browserCommand[], nulFile, nulFile, nulFile);
    }
    else
    {
        static assert(0, "Unsupported platform, please file a bug.");
    }
}


// execvp
/++
    Re-executes the program.

    Filters out any captive `--set twitch.*` keygen settings from the
    arguments originally passed to the program, then calls
    [std.process.execvp|execvp].

    On Windows, the behaviour is faked using [std.process.spawnProcess|spawnProcess].

    Params:
        args = Arguments passed to the program.
        reexecWithPowershell = (Windows) Re-execute the program with Powershell
            used as shell, as opposed to the conventional `cmd.exe`.
 +/
void execvp(
    /*const*/ string[] args,
    const bool reexecWithPowershell = bool.init) @system
{
    import kameloso.common : logger;

    if (args.length > 1)
    {
        size_t[] toRemove;

        for (size_t i; i<args.length; ++i)
        {
            import lu.string : beginsWith, nom;
            import std.algorithm.comparison : among;

            if (i == 0) continue;

            if (args[i] == "--set")
            {
                if (args.length <= i+1) continue;  // should never happen

                string fullSetting = args[i+1];  // mutable

                if (fullSetting.beginsWith("twitch."))
                {
                    import std.typecons : Flag, No, Yes;

                    immutable setting = fullSetting.nom!(Yes.inherit)('=');

                    if (setting.among!(
                        "twitch.keygen",
                        "twitch.superKeygen",
                        "twitch.googleKeygen",
                        "twitch.spotifyKeygen"))
                    {
                        toRemove ~= i;
                        toRemove ~= i+1;
                        ++i;  // Skip next entry
                    }
                }
            }
            else if (args[i] == "--setup-twitch")
            {
                toRemove ~= i;
            }
            else
            {
                version(Windows)
                {
                    if (args[i].among!(
                    "--setup-twitch",
                    "--get-cacert",
                    "--get-openssl"))
                    {
                        toRemove ~= i;
                    }
                }
            }
        }

        foreach_reverse (immutable i; toRemove)
        {
            import std.algorithm.mutation : SwapStrategy, remove;
            args = args.remove!(SwapStrategy.stable)(i);
        }
    }

    version(Posix)
    {
        import std.process : execvp;

        immutable result = execvp(args[0], args);

        // If we're here, the call failed
        enum pattern = "Failed to <l>execvp</> with an error value of <l>%d</>.";
        logger.errorf(pattern, result);
    }
    else version(Windows)
    {
        import std.process : ProcessException, spawnProcess;

        immutable shell = reexecWithPowershell ?
            [ "powershell", "-c" ] :
            [ "cmd.exe", "/c" ];

        const commandLine =
        [
            "cmd.exe",
            "/c",
            "start",
            "/min",
        ] ~ shell ~ args[0] ~ args;

        try
        {
            import core.stdc.stdlib : exit;

            auto pid = spawnProcess(commandLine);

            // If we're here, the call succeeded
            enum pattern = "Forked into PID <l>%d</>.";
            logger.infof(pattern, pid.processID);

            //resetConsoleModeAndCodepage(); // Don't, it will be called via atexit
            exit(0);
        }
        catch (ProcessException e)
        {
            enum pattern = "Failed to spawn a new process: <t>%s</>.";
            logger.errorf(pattern, e.msg);
        }
    }
    else
    {
        static assert(0, "Unsupported platform, please file a bug.");
    }
}
