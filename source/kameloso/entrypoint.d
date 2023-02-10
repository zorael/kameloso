/++
    Dummy main module so all the real files get tested by dub.

    See_Also:
        [kameloso.main]
 +/
module kameloso.entrypoint;

public:


/+
    Unfortunately we get memory corruption and segfaults in certain situations
    when the program was compiled with dmd in -release mode. These notably stem
    in main.d messageFiber, nested peekGetSet delegate.

    They also occur whenever a Fiber closure is created in a function that took
    an argument by ref, and was then passed off and later called elsewhere.
    Hopefully all of these cases have been caught and fixed, by taking said
    argument by value.

    They're all easy to reproduce in practice, but difficult to reduce into
    something that can be filed as an issue.

    They don't occur with dmd when compiled outside of -release mode, nor in any
    mode when compiling with ldc or gdc. Using ldc or gdc is the sane choice if you
    want optimisations anyway, so this is all unfortunate but also not a huge deal.

    Warn about it.
 +/
version(DigitalMars)
{
    version(D_Optimized)
    {
        pragma(msg, "WARNING: The program is prone to memory corruption and segfaults " ~
            "in certain parts of the code when compiled with dmd in -release mode. ");
        pragma(msg, "See issue #159: https://github.com/zorael/kameloso/issues/159");
        pragma(msg, "Use ldc or gdc for better results.");
    }
}


version(unittest)
{
    /++
        Unit-testing main; does nothing.
     +/
    void main() {}
}
else
{
    /++
        Entry point of the program.

        Technically it just passes on execution to [kameloso.main.run].

        Params:
            args = Command-line arguments passed to the program.

        Returns:
            `0` on success, non-`0` on failure.
     +/
    int main(string[] args)
    {
        import kameloso.main : run;

        scope(exit)
        {
            import std.stdio : stdout;
            import core.thread : thread_joinAll;

            // Unsure if this is ever needed, but just in case the buffer isn't
            // flushing on linebreaks and wouldn't get flushed on exit
            stdout.flush();

            // To be tidy, join threads.
            thread_joinAll();
        }

        return run(args);
    }
}
