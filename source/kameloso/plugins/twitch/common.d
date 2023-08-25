/++
    Helper functions for song request modules.

    See_Also:
        [kameloso.plugins.twitch.base],
        [kameloso.plugins.twitch.api],
        [kameloso.plugins.twitch.google],
        [kameloso.plugins.twitch.spotify]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.twitch.common;

version(TwitchSupport):
version(WithTwitchPlugin):

private:

import std.typecons : Flag, No, Yes;

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
    import arsd.http2 : HttpClient;
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
    const Flag!"passThroughEmptyString" passThroughEmptyString,
    const Flag!"abort"* abort)
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
        benignAbort = out-reference benign abort flag.
        abort = Global abort pointer.

    Returns:
        A string read from standard in, stripped.
 +/
auto readChannelName(
    ref uint numEmptyLinesEntered,
    out Flag!"benignAbort" benignAbort,
    const Flag!"abort"* abort)
{
    import kameloso.common : logger;
    import lu.string : stripped;

    enum numEmptyLinesEnteredBreakpoint = 2;

    enum readChannelMessage = "<l>Enter your <i>#channel<l>:</> ";
    immutable input = readNamedString(
        readChannelMessage,
        0L,
        Yes.passThroughEmptyString,
        abort).stripped;
    if (*abort) return string.init;

    if (!input.length)
    {
        ++numEmptyLinesEntered;

        if (numEmptyLinesEntered < numEmptyLinesEnteredBreakpoint)
        {
            // benignAbort is the default No.benignAbort;
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
            benignAbort = Yes.benignAbort;
        }

        return string.init;
    }
    else if (input[0] != '#')
    {
        enum invalidChannelNameMessage = "Channels are Twitch lowercase account names, " ~
            "prepended with a '<l>#</>' sign.";
        logger.warning(invalidChannelNameMessage);
        numEmptyLinesEntered = 0;
        return string.init;
    }

    return input;
}


// printManualURL
/++
    Prints a URL for manual copy/pasting.

    Params:
        url = URL string.
 +/
void printManualURL(const string url)
{
    import kameloso.logger : LogLevel;
    import kameloso.terminal.colours.tags : expandTags;
    import std.stdio : writefln;

    enum copyPastePattern = `
<l>Copy and paste this link manually into your browser, and log in as asked:

<i>8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8\<</>

%s

<i>8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8< -- 8\<</>
`;
    writefln(copyPastePattern.expandTags(LogLevel.off), url);
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


// TwitchJSONException
/++
    Abstract class for Twitch JSON exceptions, to deduplicate catching.
 +/
abstract class TwitchJSONException : Exception
{
private:
    import std.json : JSONValue;

public:
    /++
        Accessor to a [std.json.JSONValue|JSONValue] that this exception refers to.
     +/
    JSONValue json();

    /++
        Constructor.
     +/
    this(
        const string message,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }
}


// UnexpectedJSONException
/++
    A normal [object.Exception|Exception] but where its type conveys the specific
    context of a [std.json.JSONValue|JSONValue] having unexpected contents.

    It optionally embeds the JSON.
 +/
final class UnexpectedJSONException : TwitchJSONException
{
private:
    import std.json : JSONValue;

    /++
        [std.json.JSONValue|JSONValue] in question.
     +/
    JSONValue _json;

public:
    /++
        Accessor to [_json].
     +/
    override JSONValue json()
    {
        return _json;
    }

    /++
        Create a new [UnexpectedJSONException], attaching a [std.json.JSONValue|JSONValue].
     +/
    this(
        const string message,
        const JSONValue _json,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        this._json = _json;
        super(message, file, line, nextInChain);
    }

    /++
        Constructor.
     +/
    this(
        const string message,
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
final class ErrorJSONException : TwitchJSONException
{
private:
    import std.json : JSONValue;

    /++
        [std.json.JSONValue|JSONValue] in question.
     +/
    JSONValue _json;

public:
    /++
        Accessor to [_json].
     +/
    override JSONValue json()
    {
        return _json;
    }

    /++
        Create a new [ErrorJSONException], attaching a [std.json.JSONValue|JSONValue].
     +/
    this(
        const string message,
        const JSONValue _json,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        this._json = _json;
        super(message, file, line, nextInChain);
    }

    /++
        Constructor.
     +/
    this(
        const string message,
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
final class EmptyDataJSONException : TwitchJSONException
{
private:
    import std.json : JSONValue;

    /++
        The response body that was received.
     +/
    JSONValue _json;

public:
    /++
        Accessor to [_json].
     +/
    override JSONValue json()
    {
        return _json;
    }

    /++
        Create a new [EmptyDataJSONException], attaching a response body.
     +/
    this(
        const string message,
        const JSONValue _json,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        this._json = _json;
        super(message, file, line, nextInChain);
    }

    /++
        Create a new [EmptyDataJSONException], without attaching anything.
     +/
    this(
        const string message,
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
    /++
        The response body that was received.
     +/
    string responseBody;

    /++
        The message of any thrown exception, if the query failed.
     +/
    string error;

    /++
        The HTTP code that was received.
     +/
    uint code;

    /++
        Create a new [TwitchQueryException], attaching a response body, an error
        and an HTTP status code.
     +/
    this(
        const string message,
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
    this(
        const string message,
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
    /++
        The channel name for which a broadcaster token was needed.
     +/
    string channelName;

    /++
        Create a new [MissingBroadcasterTokenException], attaching a channel name.
     +/
    this(
        const string message,
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
    this(
        const string message,
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
private:
    import std.json : JSONValue;

public:
    /++
        The response body that was received.
     +/
    JSONValue json;

    /++
        Create a new [InvalidCredentialsException], attaching a response body.
     +/
    this(
        const string message,
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
    this(
        const string message,
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
    this(
        const string message,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }
}
