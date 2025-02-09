/++
    Various common definitions and global variables.

    See_Also:
        [kameloso.kameloso],
        [kameloso.main]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.common;

private:

import kameloso.pods : CoreSettings;
import kameloso.logger : KamelosoLogger;
import std.json : JSONValue;

public:

version(unittest)
static this()
{
    // This is technically before settings have been read.
    // Set some defaults for unit tests.
    .coreSettings.colours = true;
    .coreSettings.brightTerminal = false;
    .coreSettings.headless = false;
    .coreSettings.flush = true;
    .logger = new KamelosoLogger(.coreSettings);
}


// logger
/++
    Instance of a [kameloso.logger.KamelosoLogger|KamelosoLogger], providing
    timestamped and coloured logging.

    The member functions to use are `log`, `trace`, `info`, `warning`, `error`,
    `critical` and `fatal`. It is not `__gshared`, so instantiate a thread-local
    [kameloso.logger.KamelosoLogger|KamelosoLogger] if threading.

    Having this here is unfortunate; ideally plugins should not use variables
    from other modules, but unsure of any way to fix this other than to have
    each plugin keep their own [kameloso.common.logger] pointer.
 +/
KamelosoLogger logger;


// coreSettings
/++
    A [kameloso.pods.CoreSettings|CoreSettings] struct global, housing
    certain runtime settings.

    This will be accessed from other parts of the program, via
    [kameloso.common.coreSettings], so they know to use coloured output or not.
    It is a problem that needs solving.
 +/
CoreSettings coreSettings;


// settings
/++
    Deprecated alias to [coreSettings].
 +/
deprecated("Use `kameloso.common.coreSettings` instead.")
alias settings = coreSettings;


// globalAbort
/++
    Abort flag.

    This is set when the program is interrupted (such as via Ctrl+C). Other
    parts of the program will be monitoring it, to take the cue and abort when
    it is set.

    Must be `__gshared` or it doesn't seem to work on Windows.
 +/
__gshared bool globalAbort;


// globalHeadless
/++
    Headless flag.

    If this is true the program should not output anything to the terminal.
 +/
__gshared bool globalHeadless;


// OutgoingLine
/++
    A string to be sent to the IRC server, along with whether the message
    should be sent quietly or if it should be displayed in the terminal.
 +/
struct OutgoingLine
{
    /++
        String line to send.
     +/
    string line;

    /++
        Whether this message should be sent quietly or verbosely.
     +/
    bool quiet;

    /++
        Constructor.
     +/
    this(const string line, const bool quiet = false) pure @safe nothrow @nogc
    {
        this.line = line;
        this.quiet = quiet;
    }
}
