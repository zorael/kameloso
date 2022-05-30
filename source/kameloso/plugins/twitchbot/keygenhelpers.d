/++
    Helper functions for keygen routines.
 +/
module kameloso.plugins.twitchbot.keygenhelpers;

private:

import kameloso.common : expandTags, logger;
import kameloso.logger : LogLevel;

package:


// getHTTPClient
/++
    Returns a static [arsd.http2.HttpClient|HttpClient] for reuse across function calls.

    Returns:
        A static [arsd.http2.HttpClient|HttpClient].
 +/
auto getHTTPClient()
{
    import kameloso.constants : KamelosoInfo, Timeout;
    import arsd.http2 : HttpClient, Uri;
    import core.time : seconds;

    static HttpClient client;

    if (!client)
    {
        client = new HttpClient;
        client.useHttp11 = true;
        client.keepAlive = true;
        client.acceptGzip = false;
        client.defaultTimeout = Timeout.httpGET.seconds;
        client.userAgent = "kameloso/" ~ cast(string)KamelosoInfo.version_;
    }

    return client;
}


// readNamedString
/++
    Prompts the user to enter a string.

    Params:
        wording = Wording to use in the prompt.
        expectedLength = Optional expected length of the input string.
            A value of `0` disables checks.
        abort = Abort pointer.

    Returns:
        A string read from standard in, stripped.
 +/
auto readNamedString(
    const string wording,
    const size_t expectedLength,
    ref bool abort)
{
    import lu.string : stripped;
    import std.stdio : readln, stdin, stdout, write, writeln;

    string string_;

    while (!string_.length)
    {
        scope(exit) stdout.flush();

        write(wording.expandTags(LogLevel.off));
        stdout.flush();

        stdin.flush();
        string_ = readln().stripped;

        if (abort)
        {
            writeln();
            logger.warning("Aborting.");
            logger.trace();
            return string.init;
        }
        else if ((expectedLength > 0) && (string_.length != expectedLength))
        {
            writeln();
            enum invalidMessage = "Invalid length. Try copying again or file a bug.";
            logger.error(invalidMessage);
            writeln();
            continue;
        }
    }

    return string_;
}
