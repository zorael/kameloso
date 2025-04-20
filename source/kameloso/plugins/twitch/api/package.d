/++
    Basics for accessing the Twitch API. For internal use.

    See_Also:
        [kameloso.plugins.twitch.api.actions],
        [kameloso.plugins.twitch],
        [kameloso.plugins.twitch.common],
        [kameloso.plugins.twitch.providers.twitch],
        [kameloso.plugins]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.twitch.api;

version(TwitchSupport):
version(WithTwitchPlugin):

private:

import kameloso.plugins;
import kameloso.plugins.twitch;
import kameloso.plugins.twitch.common;
import core.thread.fiber : Fiber;
import core.time : Duration, seconds;

public:


// retryDelegate
/++
    Retries a passed delegate until it no longer throws or until the hardcoded
    number of retries
    ([kameloso.plugins.twitch.TwitchPlugin.delegateRetries|TwitchPlugin.delegateRetries])
    is reached, or forever if `endlessly` is passed.

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        dg = Delegate to call.
        async = Whether or not the delegate should be called asynchronously,
            scheduling attempts using [kameloso.plugins.common.scheduling.delay|delay].
        endlessly = Whether or not to endlessly retry.
        retryDelay = How long to wait between retries.

    Returns:
        Whatever the passed delegate returns.
 +/
auto retryDelegate(Dg)
    (TwitchPlugin plugin,
    Dg dg,
    const bool async = true,
    const bool endlessly = false,
    const Duration retryDelay = 4.seconds)
in ((!async || Fiber.getThis()), "Tried to call async `retryDelegate` from outside a fiber")
{
    immutable retries = endlessly ?
        size_t.max :
        TwitchPlugin.delegateRetries;

    foreach (immutable i; 0..retries)
    {
        try
        {
            if (i > 0)
            {
                if (async)
                {
                    import kameloso.plugins.common.scheduling : delay;
                    delay(plugin, retryDelay, yield: true);
                }
                else
                {
                    import core.thread : Thread;
                    Thread.sleep(retryDelay);
                }
            }
            return dg();
        }
        catch (Exception e)
        {
            handleRetryDelegateException(
                e,
                i,
                endlessly: endlessly,
                headless: plugin.state.coreSettings.headless);
            continue;  // If we're here the above didn't throw; continue
        }
    }

    assert(0, "Unreachable");
}


// handleRetryDelegateException
/++
    Handles exceptions thrown by [retryDelegate].

    Params:
        base = The exception to handle.
        i = The current retry count.
        endlessly = Whether or not to endlessly retry.
        headless = Whether or not we are running headlessly, in which case all
            terminal output will be skipped.

    Throws:
        [kameloso.plugins.twitch.common.MissingBroadcasterTokenException|MissingBroadcasterTokenException]
        if the delegate throws it.
        [kameloso.plugins.twitch.common.InvalidCredentialsException|InvalidCredentialsException]
        likewise.
        [kameloso.net.EmptyDataJSONException|EmptyDataJSONException] also.
        [kameloso.net.ErrorJSONException|ErrorJSONException] if the delegate
        throws it and the JSON embedded contains an error code in the 400-499 range.
        [object.Exception|Exception] if the delegate throws it and `endlessly` is not passed.
 +/
private auto handleRetryDelegateException(
    Exception base,
    const size_t i,
    const bool endlessly,
    const bool headless)
{
    import kameloso.net : EmptyDataJSONException,
        ErrorJSONException,
        HTTPQueryException;
    import asdf.serialization : SerdeException;
    import std.json : JSONException;

    if (auto e = cast(MissingBroadcasterTokenException) base)
    {
        // This is never a transient error
        throw e;
    }
    else if (auto e = cast(InvalidCredentialsException) base)
    {
        // Neither is this
        throw e;
    }
    else if (auto e = cast(SerdeException) base)
    {
        // Nor this
        throw e;
    }
    else if (auto e = cast(JSONException) base)
    {
        // Nor this
        throw e;
    }
    else if (auto e = cast(EmptyDataJSONException) base)
    {
        // Should never be transient?
        throw e;
    }
    else if (auto e = cast(ErrorJSONException) base)
    {
        const statusJSON = "status" in e.json;

        if (statusJSON &&
            (statusJSON.integer >= 400) &&
            (statusJSON.integer < 500))
        {
            // Also never transient
            throw e;
        }
        return;  //continue;
    }
    else if (auto e = cast(HTTPQueryException) base)
    {
        import kameloso.constants : MagicErrorStrings;

        if (e.msg == MagicErrorStrings.sslLibraryNotFoundRewritten)
        {
            // Missing OpenSSL
            throw e;
        }

        // Drop down
    }

    if (endlessly)
    {
        // Unconditionally continue, but print the exception once if it's erroring
        version(PrintStacktraces)
        {
            if (!headless)
            {
                alias printExceptionAfterNFailures = TwitchPlugin.delegateRetries;

                if (i == printExceptionAfterNFailures)
                {
                    printRetryDelegateException(base);
                }
            }
        }
        return;  //continue;
    }
    else
    {
        // Retry until we reach the retry limit, then print if we should, before rethrowing
        if (i < TwitchPlugin.delegateRetries-1) return;  //continue;

        version(PrintStacktraces)
        {
            if (!headless)
            {
                printRetryDelegateException(base);
            }
        }
        throw base;
    }
}


// printRetryDelegateException
/++
    Prints out details about exceptions passed from [retryDelegate].
    [retryDelegate] itself rethrows them when we return, so no need to do that here.

    Gated behind version `PrintStacktraces`.

    Params:
        base = The exception to print.
 +/
version(PrintStacktraces)
void printRetryDelegateException(/*const*/ Exception base)
{
    import kameloso.common : logger;
    import kameloso.net : HTTPQueryException,
        EmptyDataJSONException,
        QueryResponseJSONException,
        UnexpectedJSONException;
    import std.json : JSONException, parseJSON;
    import std.stdio : stdout, writeln;

    logger.trace(base);

    if (auto e = cast(HTTPQueryException) base)
    {
        //logger.trace(e);

        try
        {
            writeln(e.responseBody.parseJSON.toPrettyString);
        }
        catch (JSONException _)
        {
            writeln(e.responseBody);
        }

        stdout.flush();
    }
    else if (auto e = cast(EmptyDataJSONException) base)
    {
        // Must be before TwitchJSONException below
        //logger.trace(e);
    }
    else if (auto e = cast(QueryResponseJSONException) base)
    {
        // UnexpectedJSONException or ErrorJSONException
        //logger.trace(e);
        writeln(e.json.toPrettyString);
        stdout.flush();
    }
    else /*if (auto e = cast(Exception) base)*/
    {
        //logger.trace(e);
    }
}


// ErrorResponse
/++
    Generic JSON Schema of an error response from the Twitch API.
 +/
struct ErrorResponse
{
    private import asdf.serialization : serdeOptional;

    /*
    {
        "error": "Unauthorized",
        "message": "Client ID and OAuth token do not match",
        "status": 401
    }
     */
    /*
    {
        "error": "Bad Request",
        "message": "To start a commercial, the broadcaster must be streaming live.",
        "status": 400
    }
     */
    /*
    {
        "message": "invalid access token",
        "status": 401
    }
     */

    @serdeOptional
    {
        /++
            Brief error message, generally the name of the HTTP status code.
         +/
        string error;

        /++
            Longer, descriptive error message.
         +/
        string message;

        /++
            HTTP status code.
         +/
        uint status;
    }
}
