/++
    Helpers to set up a terminal environment.

    See_Also:
        [kameloso.terminal.colours]
 +/
module kameloso.terminal;

private:

import std.typecons : Flag, No, Yes;

public:

@safe:

/// Special terminal control characters.
enum TerminalToken
{
    /// Character that preludes a terminal colouring code.
    format = '\033',

    /// Terminal bell/beep.
    bell = '\007',
}


version(Windows)
{
    // Taken from LDC: https://github.com/ldc-developers/ldc/pull/3086/commits/9626213a
    // https://github.com/ldc-developers/ldc/pull/3086/commits/9626213a

    import core.sys.windows.wincon : SetConsoleCP, SetConsoleMode, SetConsoleOutputCP;

    /// Original codepage at program start.
    private __gshared uint originalCP;

    /// Original output codepage at program start.
    private __gshared uint originalOutputCP;

    /// Original console mode at program start.
    private __gshared uint originalConsoleMode;

    /++
        Sets the console codepage to display UTF-8 characters (åäö, 高所恐怖症, ...)
        and the console mode to display terminal colours.
     +/
    void setConsoleModeAndCodepage() @system
    {
        import core.stdc.stdlib : atexit;
        import core.sys.windows.winbase : GetStdHandle, INVALID_HANDLE_VALUE, STD_OUTPUT_HANDLE;
        import core.sys.windows.wincon : ENABLE_VIRTUAL_TERMINAL_PROCESSING,
            GetConsoleCP, GetConsoleMode, GetConsoleOutputCP;
        import core.sys.windows.winnls : CP_UTF8;

        originalCP = GetConsoleCP();
        originalOutputCP = GetConsoleOutputCP();

        cast(void)SetConsoleCP(CP_UTF8);
        cast(void)SetConsoleOutputCP(CP_UTF8);

        auto stdoutHandle = GetStdHandle(STD_OUTPUT_HANDLE);
        assert((stdoutHandle != INVALID_HANDLE_VALUE), "Failed to get standard output handle");

        immutable getModeRetval = GetConsoleMode(stdoutHandle, &originalConsoleMode);

        if (getModeRetval != 0)
        {
            // The console is a real terminal, not a pager (or Cygwin mintty)
            cast(void)SetConsoleMode(stdoutHandle, originalConsoleMode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
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

        cast(void)SetConsoleCP(originalCP);
        cast(void)SetConsoleOutputCP(originalOutputCP);
        cast(void)SetConsoleMode(stdoutHandle, originalConsoleMode);
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
    /// Ditto
    bool isTTY() //@safe
    {
        return true;
    }
}


// ensureAppropriateBuffering
/++
    Ensures select non-TTY environments (like Cygwin) are line-buffered.
    Allows for overriding behaviour and forcing the change in buffer mode.

    Params:
        override_ = Whether or not to override checks and always set line buffering.
 +/
void ensureAppropriateBuffering(const Flag!"override_" override_ = No.override_) @system
{
    import kameloso.platform : currentPlatform;

    if (isTTY) return;

    // Some environments require us to flush standard out after writing to it,
    // or else nothing will appear on screen (until it gets automatically flushed
    // at an indeterminate point in the future).
    // Automate this by setting standard out to be line-buffered.

    static void setLineBufferingMode()
    {
        import kameloso.constants : BufferSize;
        import std.stdio : stdout;
        import core.stdc.stdio : _IOLBF;

        stdout.setvbuf(BufferSize.vbufStdout, _IOLBF);  // FIXME
    }

    if (override_) return setLineBufferingMode();

    switch (currentPlatform)
    {
    case "Cygwin":  // No longer seems to need this?
    case "vscode":  // Now identifies itself as just "linux"
    case "Msys":
        return setLineBufferingMode();

    default:
        // Non-whitelisted non-TTY; just leave as-is.
        break;
    }
}


// setTitle
/++
    Sets the terminal title to a given string. Supposedly.

    Example:
    ---
    setTitle("kameloso IRC bot");
    ---

    Params:
        title = String to set the title to.
 +/
void setTitle(const string title) @system
{
    version(Posix)
    {
        import std.stdio : stdout, write;

        write("\033]0;", title, "\007");
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
        // Unexpected platform, do nothing
    }
}
