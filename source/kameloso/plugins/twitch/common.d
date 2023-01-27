/++
    Helper functions for song request modules.
 +/
module kameloso.plugins.twitch.common;

version(TwitchSupport):
version(WithTwitchPlugin):

private:

import std.json : JSONValue;

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
    import kameloso.common : logger;
    import kameloso.logger : LogLevel;
    import kameloso.terminal.colours.tags : expandTags;
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


// printManualURL
/++
    Prints an URL for manual copy/pasting.

    Params:
        url = URL string.
 +/
void printManualURL(const string url)
{
    import std.stdio : writefln;

    enum copyPastePattern = `
<l>Copy and paste this link manually into your browser, and log in as asked:

<i>8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8<</>

%s

<i>8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8<</>
`;
    writefln(copyPastePattern, url);
}


// UnexpectedJSONException
/++
    A normal [object.Exception|Exception] but where its type conveys the specific
    context of a [std.json.JSONValue|JSONValue] having unexpected contents.

    It optionally embeds the JSON.
 +/
final class UnexpectedJSONException : Exception
{
private:
    import std.json : JSONValue;

public:
    /++
        [std.json.JSONValue|JSONValue] in question.
     +/
    JSONValue json;

    /++
        Create a new [UnexpectedJSONException], attaching a [std.json.JSONValue|JSONValue].
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


// ErrorJSONException
/++
    A normal [object.Exception|Exception] but where its type conveys the specific
    context of a [std.json.JSONValue|JSONValue] having an `"error"` field.

    It optionally embeds the JSON.
 +/
final class ErrorJSONException : Exception
{
    /++
        [std.json.JSONValue|JSONValue] in question.
     +/
    JSONValue json;

    /++
        Create a new [ErrorJSONException], attaching a [std.json.JSONValue|JSONValue].
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


// TwitchQueryException
/++
    Exception, to be thrown when an API query to the Twitch servers failed,
    for whatever reason.

    It is a normal [object.Exception|Exception] but with attached metadata.
 +/
final class TwitchQueryException : Exception
{
@safe:
    /// The response body that was received.
    string responseBody;

    /// The message of any thrown exception, if the query failed.
    string error;

    /// The HTTP code that was received.
    uint code;

    /++
        Create a new [TwitchQueryException], attaching a response body, an error
        and an HTTP status code.
     +/
    this(const string message,
        const string responseBody,
        const string error,
        const uint code,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        this.responseBody = responseBody;
        this.error = error;
        this.code = code;
        super(message, file, line, nextInChain);
    }

    /++
        Create a new [TwitchQueryException], without attaching anything.
     +/
    this(const string message,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }
}


// EmptyDataJSONException
/++
    Exception, to be thrown when an API query to the Twitch servers failed,
    due to having received empty JSON data.

    It is a normal [object.Exception|Exception] but with attached metadata.
 +/
final class EmptyDataJSONException : Exception
{
@safe:
    /// The response body that was received.
    JSONValue json;

    /++
        Create a new [EmptyDataException], attaching a response body.
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
        Create a new [EmptyDataException], without attaching anything.
     +/
    this(const string message,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }
}


// MissingBroadcasterTokenException
/++
    Exception, to be thrown when an API query to the Twitch servers failed,
    due to missing broadcaster-level token.
 +/
final class MissingBroadcasterTokenException : Exception
{
@safe:
    /// The channel name for which a broadcaster token was needed.
    string channelName;

    /++
        Create a new [MissingBroadcasterTokenException], attaching a channel name.
     +/
    this(const string message,
        const string channelName,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        this.channelName = channelName;
        super(message, file, line, nextInChain);
    }

    /++
        Create a new [MissingBroadcasterTokenException], without attaching anything.
     +/
    this(const string message,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }
}


// InvalidCredentialsException
/++
    Exception, to be thrown when credentials or grants are invalid.

    It is a normal [object.Exception|Exception] but with attached metadata.
 +/
final class InvalidCredentialsException : Exception
{
@safe:
    /// The response body that was received.
    JSONValue json;

    /++
        Create a new [InvalidCredentialsException], attaching a response body.
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
        Create a new [InvalidCredentialsException], without attaching anything.
     +/
    this(const string message,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }
}


// EmptyResponseException
/++
    Exception, to be thrown when an API query to the Twitch servers failed,
    with only an empty response received.
 +/
final class EmptyResponseException : Exception
{
@safe:
    /++
        Create a new [EmptyResponseException].
     +/
    this(const string message,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }
}
