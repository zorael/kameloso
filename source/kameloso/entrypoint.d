/++
    Dummy main module so all the real files get tested by dub.

    See_Also:
        [kameloso.main]
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

        Technically it just passes on execution to [kameloso.main.initBot].

        Params:
            args = Command-line arguments passed to the program.

        Returns:
            `0` on success, non-`0` on failure.
     +/
    int main(string[] args)
    {
        import kameloso.main : initBot;

        scope(exit)
        {
            import std.stdio : stdout;

            // Unsure if this is ever needed, but just in case the buffer isn't
            // flushing on linebreaks and wouldn't get flushed on exit
            stdout.flush();
        }

        return initBot(args);
    }
}
