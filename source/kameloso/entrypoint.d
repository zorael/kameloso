/++
    Dummy main module so all the real files get tested by dub.

    See_Also:
        [kameloso.main]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.entrypoint;

public:

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
