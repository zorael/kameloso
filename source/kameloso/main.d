/++
 +  Dummy main module so the main `kameloso.d` gets tested by dub.
 +/
module kameloso.main;

public:

/+
    Warn about bug #18026; Stack overflow in ddmd/dtemplate.d:6241, TemplateInstance::needsCodegen()

    It may have been fixed in versions in the future at time of writing, so
    limit it to 2.086 and earlier. Update this condition as compilers are released.

    Exempt DDoc generation, as it doesn't seem to trigger the segfaults.
 +/
static if (__VERSION__ <= 2088L)
{
    debug
    {
        // Everything is fine in debug mode
    }
    else version(D_Ddoc)
    {
        // Also fine
    }
    else
    {
        pragma(msg, "NOTE: Compilation might not succeed outside of debug mode.");
        pragma(msg, "See bug #18026 at https://issues.dlang.org/show_bug.cgi?id=18026");
    }
}


/*
    Warn about bug #20562: [dmd] Memory allocation failed (ERROR: This is a compiler bug)

    It only affects Windows with DMD 2.089.0 or later, on build modes other than
    `singleFile`. Constrain with an upper major version as the issue is fixed.
 */
version(Windows)
{
    version(DigitalMars)
    {
        static if (__VERSION__ >= 2089L)
        {
            pragma(msg, "NOTE: Compilation might not succeed with dmd on Windows " ~
                "outside of single-file build mode.");
            pragma(msg, "If building fails with an `OutOfMemoryError` compiler " ~
                "error, rebuild with `dub build --build-mode=singleFile` " ~
                "or with `dub build --compiler=ldc2`.");
            pragma(msg, "See bug #20562 at https://issues.dlang.org/show_bug.cgi?id=20562");
        }
    }
}


version(unittest)
/++
 +  Unit-testing main; does nothing.
 +/
void main()
{
    import kameloso.common : logger;

    version(Windows)
    {
        import kameloso.terminal : setConsoleModeAndCodepage;

        // Set up the console to display text and colours properly.
        // It will only affect the below "All tests passed" line however...
        setConsoleModeAndCodepage();
    }

    // Compiled with -b unittest, so run the tests and exit.
    // Logger is initialised in a module constructor, don't re-init here.
    logger.info("All tests passed successfully!");
    // No need to Cygwin-flush; the logger did that already
}
else
/++
 +  Entry point of the program.
 +
 +  Technically it just passes on execution to `kameloso.kameloso.initBot`.
 +
 +  Params:
 +      args = Command-line arguments passed to the program.
 +
 +  Returns:
 +      `0` on success, non-`0` on failure.
 +/
int main(string[] args)
{
    import kameloso.kameloso : initBot;

    return initBot(args);
}
