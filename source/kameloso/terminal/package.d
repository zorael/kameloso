/++
    Helpers to set up a terminal environment.

    See_Also:
        [kameloso.terminal.colours]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.terminal;

private:

import kameloso.constants : KamelosoInfo;

enum defaultTerminalTitle = "kameloso v" ~ cast(string) KamelosoInfo.version_;

public:

@safe:

/++
    Special terminal control characters.
 +/
enum TerminalToken
{
    /++
        Character that preludes a terminal colouring code.
     +/
    format = '\033',

    /++
        Terminal bell/beep.
     +/
    bell = '\007',
}


version(Windows)
{
    // Taken from LDC: https://github.com/ldc-developers/ldc/pull/3086/commits/9626213a
    // https://github.com/ldc-developers/ldc/pull/3086/commits/9626213a

    private import core.sys.windows.wincon : SetConsoleCP, SetConsoleMode, SetConsoleOutputCP;

    /++
        Original codepage at program start.
     +/
    private __gshared uint originalCP;

    /++
        Original output codepage at program start.
     +/
    private __gshared uint originalOutputCP;

    /++
        Original console mode at program start.
     +/
    private __gshared uint originalConsoleMode;

    /++
        Sets the console codepage to display UTF-8 characters (åäö, 高所恐怖症, ...)
        and the console mode to display terminal colours.
     +/
    void setConsoleModeAndCodepage() @system
    {
        import core.stdc.stdlib : atexit;
        import core.sys.windows.winbase :
            GetStdHandle,
            INVALID_HANDLE_VALUE,
            STD_OUTPUT_HANDLE;
        import core.sys.windows.wincon :
            ENABLE_VIRTUAL_TERMINAL_PROCESSING,
            GetConsoleCP,
            GetConsoleMode,
            GetConsoleOutputCP;
        import core.sys.windows.winnls : CP_UTF8;

        originalCP = GetConsoleCP();
        originalOutputCP = GetConsoleOutputCP();

        cast(void) SetConsoleCP(CP_UTF8);
        cast(void) SetConsoleOutputCP(CP_UTF8);

        auto stdoutHandle = GetStdHandle(STD_OUTPUT_HANDLE);
        assert((stdoutHandle != INVALID_HANDLE_VALUE), "Failed to get standard output handle");

        immutable getModeRetval = GetConsoleMode(stdoutHandle, &originalConsoleMode);

        if (getModeRetval != 0)
        {
            // The console is a real terminal, not a pager (or Cygwin mintty)
            cast(void) SetConsoleMode(stdoutHandle, originalConsoleMode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
        }

        // atexit handlers are also called when exiting via exit() etc.;
        // that's the reason this isn't a RAII struct.
        atexit(&resetConsoleModeAndCodepage);
    }

    /++
        Resets the console codepage and console mode to the values they had at
        program start.
     +/
    extern(C)
    private void resetConsoleModeAndCodepage() @system
    {
        import core.sys.windows.winbase : GetStdHandle, INVALID_HANDLE_VALUE, STD_OUTPUT_HANDLE;

        auto stdoutHandle = GetStdHandle(STD_OUTPUT_HANDLE);
        assert((stdoutHandle != INVALID_HANDLE_VALUE), "Failed to get standard output handle");

        cast(void) SetConsoleCP(originalCP);
        cast(void) SetConsoleOutputCP(originalOutputCP);
        cast(void) SetConsoleMode(stdoutHandle, originalConsoleMode);
    }
}


version(Posix)
{
    // isTTY
    /++
        Determines whether or not the program is being run in a terminal (virtual TTY).

        "isatty() returns 1 if fd is an open file descriptor referring to a
        terminal; otherwise 0 is returned, and errno is set to indicate the error."

        Returns:
            `true` if the current environment appears to be a terminal;
            `false` if not (e.g. pager or certain IDEs with terminal windows).
     +/
    bool isTTY() //@safe
    {
        import core.sys.posix.unistd : STDOUT_FILENO, isatty;
        return (isatty(STDOUT_FILENO) == 1);
    }
}
else version(Windows)
{
    /// Ditto
    bool isTTY() @system
    {
        import core.sys.windows.winbase : FILE_TYPE_PIPE, GetFileType, GetStdHandle, STD_OUTPUT_HANDLE;
        auto handle = GetStdHandle(STD_OUTPUT_HANDLE);
        return (GetFileType(handle) != FILE_TYPE_PIPE);
    }
}
else
{
    static assert(0, "Unsupported platform, please file a bug.");
}


// isTerminal
/++
    Determines whether or not the program is being run in a terminal, be it a
    real TTY or a whitelisted pseudo-TTY such as those employed in IDE terminal
    emulators.

    Returns:
        `true` if the environment is either a real TTY or one of a few whitelisted
        pseudo-TTYs; `false` if not.
 +/
auto isTerminal() @system
{
    import kameloso.platform : currentEnvironment;

    if (isTTY) return true;

    switch (currentEnvironment)
    {
    case "Msys":
    case "Cygwin":
    case "vscode":
        return true;

    default:
        return false;
    }
}


// applyTerminalOverrides
/++
    Potentially sets [kameloso.pods.CoreSettings.flush|CoreSettings.flush] and/or
    [kameloso.pods.CoreSettings.colours|CoreSettings.colours] if the
    terminal seems to not truly be a terminal (such as a pager, or a non-whitelisted
    IDE terminal emulator).

    Params:
        flush = Reference to flush setting bool.
        colours = Reference to colours settings bool.
 +/
void applyTerminalOverrides(ref bool flush, ref bool colours) @system
{
    import kameloso.platform : currentEnvironment;

    if (!isTTY)
    {
        switch (currentEnvironment)
        {
        case "Msys":
            // Requires manual flushing despite setvbuf
            flush = true;
            break;

        case "Cygwin":
        case "vscode":
            // Probably no longer needs modifications
            break;

        default:
            // Unknown TTY environment, assume it's a pager
            colours = false;
            break;
        }
    }
}


// ensureAppropriateBuffering
/++
    Ensures select non-TTY environments (like Cygwin) are line-buffered.
 +/
void ensureAppropriateBuffering() @system
{
    import kameloso.constants : BufferSize;
    import kameloso.platform : currentEnvironment;
    import std.stdio : stdout;
    import core.stdc.stdio : _IOLBF;

    if (!isTTY)
    {
        switch (currentEnvironment)
        {
        case "Msys":
        case "Cygwin":
        case "vscode":
            /+
                Some terminal environments require us to flush standard out after
                writing to it, as they are likely pagers and not TTYs behind the
                scene. Whitelist some and set standard out to be line-buffered
                for those.
             +/
            stdout.setvbuf(BufferSize.vbufStdout, _IOLBF);
            break;

        default:
            // Non-whitelisted non-TTY (a pager), leave as-is.
            break;
        }
    }
}


// setTerminalTitle
/++
    Sets the terminal title to a given string. Supposedly.

    Example:
    ---
    setTitle("kameloso IRC bot");
    ---

    Params:
        title = Optional custom string to set the title to. If unset, the
            title will be set to the program name and version.
 +/
void setTerminalTitle(const string title = defaultTerminalTitle) @system
{
    version(Posix)
    {
        import std.stdio : stdout, write;

        write("\033]0;", title, "\007");
        write("\033]30;", title, "\007");  // Konsole tab name
        stdout.flush();
    }
    else version(Windows)
    {
        import std.string : toStringz;
        import core.sys.windows.wincon : SetConsoleTitleA;

        SetConsoleTitleA(title.toStringz);
    }
    else
    {
        static assert(0, "Unsupported platform, please file a bug.");
    }
}


// resetTerminalTitle
/++
    Resets the terminal title to an empty string.
 +/
void resetTerminalTitle() @system
{
    setTerminalTitle(string.init);
}
