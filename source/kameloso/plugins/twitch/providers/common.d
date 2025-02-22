/++
    Helper functions for Twitch provider modules.

    See_Also:
        [kameloso.plugins.twitch],
        [kameloso.plugins.twitch.providers.twitch],
        [kameloso.plugins.twitch.providers.google],
        [kameloso.plugins.twitch.providers.spotify]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.twitch.providers.common;

version(TwitchSupport):
version(WithTwitchPlugin):

package:


// readNamedString
/++
    Prompts the user to enter a string.

    Params:
        wording = Wording to use in the prompt.
        expectedLength = Optional expected length of the input string.
            A value of `0` disables checks.
        passThroughEmptyString = Whether or not an empty string should be returned
            as-is, or if it should be re-read until it is non-empty.
        abort = Abort pointer.

    Returns:
        A string read from standard in, stripped.
 +/
auto readNamedString(
    const string wording,
    const size_t expectedLength,
    const bool passThroughEmptyString,
    const bool* abort)
{
    import kameloso.common : logger;
    import kameloso.logger : LogLevel;
    import kameloso.terminal.colours.tags : expandTags;
    import lu.string : stripped;
    import std.stdio : readln, stdin, stdout, write, writeln;

    string input;  // mutable

    while (!input.length)
    {
        scope(exit) stdout.flush();

        write(wording.expandTags(LogLevel.off));
        stdout.flush();
        stdin.flush();
        input = readln().stripped;

        if (*abort)
        {
            writeln();
            logger.warning("Aborting.");
            logger.trace();
            return string.init;
        }
        else if (!input.length && passThroughEmptyString)
        {
            return string.init;
        }
        else if (
            (expectedLength > 0) &&
            input.length &&
            (input.length != expectedLength))
        {
            writeln();
            enum invalidMessage = "Invalid length. Try copying again or file a bug.";
            logger.error(invalidMessage);
            writeln();
            input = string.init;
            continue;
        }
    }

    return input;
}


// readChannelName
/++
    Prompts the user to enter a channel name.

    Params:
        numEmptyLinesEntered = Number of empty lines entered so far.
        benignAbort = out-reference benign abort bool.
        abort = Global abort pointer.

    Returns:
        A string read from standard in, stripped.
 +/
auto readChannelName(
    ref uint numEmptyLinesEntered,
    out bool benignAbort,
    const bool* abort)
{
    import kameloso.plugins.twitch.common : isValidTwitchUsername;
    import kameloso.common : logger;
    import lu.string : stripped;

    enum numEmptyLinesEnteredBreakpoint = 2;

    enum readChannelMessage = "<l>Enter your <i>#channel<l>:</> ";
    immutable input = readNamedString(
        readChannelMessage,
        0L,
        passThroughEmptyString: true,
        abort).stripped;
    if (*abort) return string.init;

    if (!input.length)
    {
        ++numEmptyLinesEntered;

        if (numEmptyLinesEntered < numEmptyLinesEnteredBreakpoint)
        {
            // benignAbort is the default false;
            // Just drop down and return string.init
        }
        else if (numEmptyLinesEntered == numEmptyLinesEnteredBreakpoint)
        {
            enum onceMoreMessage = "Hit <l>Enter</> once more to cancel keygen.";
            logger.warning(onceMoreMessage);
            // as above
        }
        else if (numEmptyLinesEntered > numEmptyLinesEnteredBreakpoint)
        {
            enum cancellingKeygenMessage = "Cancelling keygen.";
            logger.warning(cancellingKeygenMessage);
            logger.trace();
            benignAbort = true;
        }
        return string.init;
    }
    else if (
        (input.length >= 4+1) &&  // 4 as minimum length, +1 for the octothorpe
        (input[0] == '#') &&
        input[1..$].isValidTwitchUsername)
    {
        // Seems correct
        return input;
    }
    else
    {
        enum invalidChannelNameMessage = "Channels are Twitch lowercase account names, " ~
            "prepended with a '<l>#</>' sign.";
        logger.warning(invalidChannelNameMessage);
        numEmptyLinesEntered = 0;
        return string.init;
    }
}


// printManualURL
/++
    Prints a URL for manual copy/pasting.

    Params:
        url = URL string.
        wording = Optional wording to use in the prompt.
 +/
void printManualURL(const string url, const string wording = string.init)
{
    import kameloso.logger : LogLevel;
    import kameloso.terminal.colours.tags : expandTags;
    import std.stdio : writefln;

    enum defaultWording = "Copy and paste this link manually into your browser:";
    enum copyPastePattern = `
<l>%s

<i>8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8\<</>

%s

<i>8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8\<</>
`;
    writefln(
        copyPastePattern.expandTags(LogLevel.off),
        wording.length ? wording : defaultWording,
        url);
}


// pasteAddressInstructions
/++
    Instructions for pasting an address into the terminal.
 +/
enum pasteAddressInstructions =
`
<l>Then paste the address of the empty page you are redirected to afterwards here.</>

<i>*</> The redirected address should begin with "<i>http://localhost</>".
<i>*</> It will probably say "<i>this site can't be reached</>" or "<i>unable to connect</>".
<i>*</> If you are running a local web server on port <i>80</>, you may have to
  temporarily disable it for this to work.
`;
