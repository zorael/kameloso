/++
    Functions that deal with OS- and/or platform-specifics.

    See_Also:
        [kameloso.terminal]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.platform;

private:

import std.process : Pid;

public:

@safe:


// currentEnvironment
/++
    Returns the string of the name of the current terminal environment, adjusted to include
    `Cygwin` as an alternative next to `win32` and `win64`, as well as embedded
    terminal consoles like in Visual Studio Code.

    Example:
    ---
    switch (currentEnvironment)
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
auto currentEnvironment()
{
    import lu.conv : toString;
    import std.process : environment;
    import std.system : os;

    enum osName = os.toString();

    version(Windows)
    {
        // vscode and nested Powershell
        immutable vscode = environment.get("VSCODE_INJECTION", string.init);
        if (vscode.length) return "vscode";
    }

    // Basic Unix. On Windows; Cygwin, MinGW, Git Bash, etc
    immutable termProgram = environment.get("TERM_PROGRAM", string.init);
    if (termProgram.length) return termProgram;

    // Some don't have TERM_PROGRAM, but most do have TERM
    immutable term = environment.get("TERM", string.init);
    if (term.length) return term;

    // Fallback
    return osName;
}


// configurationBaseDirectory
/++
    Divines the default configuration file base directory, depending on what
    platform we're currently running.

    On non-macOS Posix it defaults to `$XDG_CONFIG_HOME` and falls back to
    `~/.config` if no `$XDG_CONFIG_HOME` environment variable present.

    On macOS it defaults to `$HOME/Library/Preferences`.

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
        import std.algorithm.searching : startsWith;
        import std.process : environment;

        environment["XDG_DATA_HOME"] = "/tmp";
        string rbd = resourceBaseDirectory;
        assert((rbd == "/tmp"), rbd);

        environment.remove("XDG_DATA_HOME");
        rbd = resourceBaseDirectory;
        assert(rbd.startsWith("/home/") && rbd.endsWith("/.local/share"));
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
        [object.Exception|Exception] if there were no `DISPLAY` nor `WAYLAND_DISPLAY`
        environment variable on non-macOS Posix platforms, indicative of no X.org
        server or Wayland compositor running.
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


// exec
/++
    Re-executes the program.

    Filters out any `--set twitch.*` keygen terminal wizard flags from the
    arguments originally passed to the program, then calls
    [std.process.execvp|execvp].

    On Windows, the behaviour is faked using [std.process.spawnProcess|spawnProcess].

    Params:
        args = Arguments passed to the program.
        numReexecs = How many reexecutions have been done so far.
        channels = A snapshot of the channels currently joined, to pass as override
            to the new execution via an `--internal-channel-override` getopt flag.

    Returns:
        On Windows, a [std.process.Pid|Pid] of the spawned process.
        On Posix, it either exits the program or it throws.

    Throws:
        On Posix, [lu.misc.ReturnValueException|ReturnValueException] on failure.
        On Windows, [std.process.ProcessException|ProcessException] on failure.
 +/
Pid exec(
    /*const*/ string[] args,
    const uint numReexecs,
    const string[] channels) @system
{
    import kameloso.common : logger;
    import std.algorithm.comparison : among;
    import std.conv : text;

    if (args.length > 1)
    {
        size_t[] toRemove;

        for (size_t i=1; i<args.length; ++i)
        {
            import lu.string : advancePast;
            import std.algorithm.searching : startsWith;

            if (args[i] == "--set")
            {
                if (args.length <= i+1) continue;  // should never happen

                string slice = args[i+1];  // mutable

                if (slice.startsWith("twitch."))
                {
                    immutable flag = slice.advancePast('=', inherit: true);

                    if (flag.among!
                        ("twitch.keygen",
                        "twitch.superKeygen",
                        "twitch.googleKeygen",
                        "twitch.youtubeKeygen",
                        "twitch.spotifyKeygen"))
                    {
                        toRemove ~= i;
                        toRemove ~= i+1;
                        ++i;  // Skip next entry
                    }
                }
            }
            else
            {
                string slice = args[i];  // mutable
                immutable flag = slice.advancePast('=', inherit: true);

                if (flag.among!
                    ("--get-cacert",
                    "--get-openssl",
                    //"--setup-twitch",  // this sets up the config file, then exits
                    "--internal-num-reexecs",
                    "--internal-channel-override"))
                {
                    toRemove ~= i;
                }
            }
        }

        foreach_reverse (immutable i; toRemove)
        {
            import std.algorithm.mutation : SwapStrategy, remove;
            args = args.remove!(SwapStrategy.stable)(i);
        }
    }

    version(Windows)
    {
        static auto applyPlaceholders(const string input)
        {
            import kameloso.constants : KamelosoDefaultChars;
            import std.array : replace;

            return input
                .replace('"', cast(char)KamelosoDefaultChars.doublequotePlaceholder)
                .replace('#', cast(char)KamelosoDefaultChars.octothorpePlaceholder);
        }
    }

    // Add the reexec count and channel override arguments
    args ~= text("--internal-num-reexecs=", numReexecs+1);

    foreach (immutable channelName; channels)
    {
        version(Posix)
        {
            args ~= text("--internal-channel-override=", channelName);
        }
        else version(Windows)
        {
            args ~= text("--internal-channel-override=\"", applyPlaceholders(channelName), '"');
        }
        else
        {
            static assert(0, "Unsupported platform, please file a bug.");
        }
    }

    version(Posix)
    {
        import lu.misc : ReturnValueException;
        import std.process : execvp;

        immutable retval = execvp(args[0], args);

        // If we're here, the call failed
        enum message = "exec failed";
        throw new ReturnValueException(message, args[0], retval);
    }
    else version(Windows)
    {
        import std.algorithm.searching : startsWith;
        import std.array : Appender;
        import std.process : ProcessException, spawnProcess;

        Appender!(char[]) sink;
        sink.reserve(256);

        string arg0 = args[0];  // mutable
        args = args[1..$];  // pop it

        if (arg0.startsWith('.', '/', '\\'))
        {
            // Seems to be a valid path
        }
        else if ((arg0.length > 3) && (arg0[1] == ':'))
        {
            // May be C:\kameloso.exe and would as such be okay
        }
        else
        {
            // Powershell won't call binaries in the working directory without ./
            arg0 = "./" ~ arg0;
        }

        for (size_t i; i<args.length; ++i)
        {
            if (sink[].length) sink.put(' ');

            if (args[i].startsWith(
                "-H",
                "-C",
                "--homeChannels",
                "--guestChannels",
                "--set"))
            {
                import std.algorithm.searching : canFind;
                import std.format : formattedWrite;

                /+
                    Arguments to the program are passed to powershell
                    as a single string. We have to rely on quotes to separate
                    each argument, as well as to escape some things like octothorpes.

                    This does not work well with arguments that in turn contain
                    quotes, such as --set connect.sendAfterConnect="abc def".
                    It can still be made to reexec with some backslashes added,
                    but the contents will be wrong and subsequent arguments may be skipped.

                    To work around this, change all double quotes into
                    KamelosoDefaultChars.doublequotePlaceholder, and undo the
                    change early before getopt.
                 +/

                if (args[i][1].among('H', 'C') && (args[i].length > 2))
                {
                    // -C"#abc,#def"
                    immutable flag = args[i][0..2];
                    auto channelName = args[i][2..$];
                    if ((channelName.length > 1) && (channelName[0] == '=')) channelName = channelName[1..$];
                    sink.formattedWrite(`%s="%s"`, flag, applyPlaceholders(channelName));
                }
                else if (args[i].canFind('='))
                {
                    import lu.string : advancePast;
                    // --homeChannels="#abc,#def"
                    // -H="zorael"
                    auto slice = args[i];  // mutable
                    immutable flag = slice.advancePast('=');
                    sink.formattedWrite(`%s="%s"`, flag, applyPlaceholders(slice));
                }
                else if (args.length >= i+1)
                {
                    // --set connect.sendAfterConnect="abc def"
                    sink.formattedWrite(`%s "%s"`, args[i], applyPlaceholders(args[i+1]));
                    ++i;  // Skip next argument
                }
            }
            else if (args[i].startsWith("--internal-"))
            {
                sink.put(args[i]);
            }
            else
            {
                sink.put(applyPlaceholders(args[i]));
            }
        }

        const string[8] commandLine =
        [
            "cmd.exe",
            "/c",
            "start",
            "/min",
            "powershell",
            "-c"
        ] ~ arg0 ~ sink[].idup;
        return spawnProcess(commandLine[]);
    }
    else
    {
        static assert(0, "Unsupported platform, please file a bug.");
    }
}
