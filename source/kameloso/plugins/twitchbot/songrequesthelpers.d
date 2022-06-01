/++
    Helper functions for song request modules.
 +/
module kameloso.plugins.twitchbot.songrequesthelpers;

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


// SongRequestException
/++
    A normal [object.Exception|Exception] but where its type conveys the specifi
    context of a song request failing in a generic manner.
 +/
final class SongRequestException : Exception
{
    /++
        Constructor.
     +/
    this(const string message,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }
}


// SongRequestPlaylistException
/++
    A normal [object.Exception|Exception] but where its type conveys the specifi
    context of a playlist ID being missing.
 +/
final class SongRequestPlaylistException : Exception
{
    /++
        Constructor.
     +/
    this(const string message,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }
}


// SongRequestTokenException
/++
    A normal [object.Exception|Exception] but where its type conveys the specifi
    context of an OAuth access token being missing or failing to be requested.
 +/
final class SongRequestTokenException : Exception
{
    /++
        Constructor.
     +/
    this(const string message,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }
}

// SongRequestJSONTypeMismatchException
/++
    A normal [object.Exception|Exception] but where its type conveys the specifi
    context of some JSON being of a wrong [std.json.JSONType|JSONType].

    It optionally embeds the JSON.
 +/
final class SongRequestJSONTypeMismatchException : Exception
{
private:
    import std.json : JSONValue;

public:
    /++
        [std.json.JSONValue|JSONValue] in question.
     +/
    JSONValue json;

    /++
        Create a new [SongRequesstJSONTypeMismatchException], attaching a
        [std.json.JSONValue|JSONValue].
     +/
    this(const string message,
        const JSONValue json,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        this.json = json;
        super(message, file, line, nextInChain);
    }

    /++
        Constructor.
     +/
    this(const string message,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }
}
