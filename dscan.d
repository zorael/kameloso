/++
    This program builds `dscanner`, does a recursive style check with it of the
    `source` directory (or whatever is specified at the command line), builds
    documentation with `dub build -b docs`, and finally returns `0` or non-`0`,
    depending on whether all commands executed without errors.

    Each line of dscanner output is matched with the regular expressions in
    `dscan.txt`, and are culled if there is a hit. As such, the remaining output
    reflects the dscanner errors for which there are no regular expressions,
    constituting a new set of errors that should be addressed.

    If a `dscan.txt` expression did not apply to any lines in the output,
    it is printed as dead.

    This is to be run as part of a CI pipeline.

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module zorael.dscan;

private:

import std.regex : Regex;
import std.stdio;


// main
/++
    Main.

    Params:
        args = Command-line arguments passed to the program.

    Returns:
        `0` on success; non-`0` on failure.
 +/
public auto main(string[] args)
{
    import std.file : FileException;
    import std.regex : RegexException;

    enum defaultExpressionFile = "dscan.txt";
    enum defaultTarget = "source";

    immutable expressionsFile = (args.length > 1) ?
        args[1] :
        defaultExpressionFile;

    immutable target = (args.length > 2) ?
        args[2] :
        defaultTarget;

    string[] expressions;
    Regex!char[] engines;

    try
    {
        import std.algorithm.iteration : map;
        import std.array : array;
        import std.regex : regex;

        expressions = readExpressions(expressionsFile);
        engines = expressions.map!(expr => expr.regex).array;
    }
    catch (FileException e)
    {
        writeln(i"[!] failed to read expressions file; $(e.msg)");
        return 1;
    }
    catch (RegexException e)
    {
        writeln(i"[!] failed to create regex engine(s); $(e.msg)");
        return 1;
    }

    writeln(i"[*] $(expressions.length) expression(s) loaded from $(expressionsFile)");

    int retval = buildDscanner();

    if (retval != 0)
    {
        // No point continuing if dscanner failed to build
        writeln();
        writeln(i"[+] abort, return $(retval)");
        return retval;
    }

    retval |= runDscanner(engines, expressions, target);
    retval |= buildDocs();

    writeln();
    writeln(i"[+] done, return $(retval)");

    return retval;
}


// buildDscanner
/++
    Simply invokes `dub build dscanner`.

    Returns:
        The shell return value of the command run.
 +/
auto buildDscanner()
{
    import std.datetime.stopwatch : StopWatch;
    import std.process : execute;

    StopWatch sw;

    static immutable command =
    [
        "dub",
        "build",
        "dscanner",
    ];

    writeln();
    writeln("[+] building dscanner...");

    sw.start();
    const result = execute(command);
    sw.stop();

    immutable wording = (result.status == 0) ?
        "finished building" :
        "failed to build";

    writeln(i"[!] $(wording) in $(sw.peek), retval $(result.status)");

    if (result.status != 0)
    {
        import std.string : strip;

        writeln();
        writeln(result.output.strip());
    }

    return result.status;
}


// runDscanner
/++
    Simply invokes `dub run dscanner --nodeps --vquiet -- --skipTests -S $(dir)`.

    Params:
        engines = Regular expression matching engines.
        expressions = List of regular expression strings from which `engines`
            were created.
        target = Directory or file to scan, such as `source`.

    Returns:
        The shell return value of the command run.
 +/
auto runDscanner(
    const Regex!char[] engines,
    const string[] expressions,
    const string target)
{
    import std.algorithm.iteration : splitter;
    import std.array : Appender;
    import std.datetime.stopwatch : StopWatch;
    import std.process : execute;
    import std.string : strip;

    Appender!(string[]) uncaughtLines;
    StopWatch sw;

    auto engineMatches = new bool[engines.length];

    immutable command =
    [
        "dub",
        "run",
        "dscanner",
        "--nodeps",
        "--vquiet",
        "--",
        "--skipTests",
        "-S",
        target,
    ];

    writeln();
    writeln(i"[+] invoking: $(command)");

    sw.start();
    const result = execute(command);
    sw.stop();

    writeln(i"[!] finished scanning in $(sw.peek), retval irrelevant");

    auto range = result.output
        .strip()
        .splitter("\n");

    foreach (const line; range)
    {
        bool atLeastOneMatch;

        foreach (immutable i, engine; engines)
        {
            import std.regex : matchFirst;

            const regexMatches = line.matchFirst(engine);

            if (!regexMatches.empty)
            {
                engineMatches[i] = true;
                atLeastOneMatch = true;
            }
        }

        if (!atLeastOneMatch) uncaughtLines.put(line);
    }

    int retval;

    if (uncaughtLines[].length)
    {
        import std.algorithm.iteration : each;

        writeln();
        uncaughtLines[].each!writeln();
        writeln();
        writeln(i"[!] $(uncaughtLines[].length) line(s) got past regex, retval becomes $(result.status)");
        retval = result.status;
    }
    else
    {
        writeln("[!] all output caught by regex");
    }

    foreach (immutable i, engineMatched; engineMatches)
    {
        if (!engineMatched)
        {
            writeln(i`[!] dead expression: "$(expressions[i])"`);
            retval |= 1;
        }
    }

    return retval;
}


// buildDocs
/++
    Simply invokes `dub build -b docs`.`

    Returns:
        The shell return value of the command run.
 +/
auto buildDocs()
{
    import std.datetime.stopwatch : StopWatch;
    import std.process : execute;
    import std.string : strip;

    StopWatch sw;

    static immutable command =
    [
        "dub",
        "build",
        "-b",
        "docs",
        "-c",
        "dev",
        "--nodeps",
        //"--vquiet",
    ];


    writeln();
    writeln("[+] building docs...");

    sw.start();
    const result = execute(command);
    sw.stop();

    writeln(i"[!] docs built in $(sw.peek), retval $(result.status)");
    writeln();
    writeln(result.output.strip());

    return result.status;
}


// readExpressions
/++
    Reads regular expressions from a specified file.

    Params:
        expressionsFile = Filename of file to read regular expression lines from.

    Returns:
        A `string[]` array of regular expressions, read from file.
 +/
auto readExpressions(const string expressionsFile)
{
    import std.algorithm.iteration : filter, map, splitter;
    import std.algorithm.searching : startsWith;
    import std.array : array;
    import std.file : readText;
    import std.string : strip;

    return expressionsFile
        .readText()
        .splitter("\n")
        .map!(line => line.strip())
        .filter!(line => line.length && !line.startsWith("#"))
        .array;
}
