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
        assert(cfgd.endsWith("Library/Application Support"), cfgd);
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
