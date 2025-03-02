/++
    Common Twitch bits and bobs.

    See_Also:
        [kameloso.plugins.twitch],
        [kameloso.plugins.twitch.api]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.twitch.common;

version(TwitchSupport):
version(WithTwitchPlugin):

private:

import kameloso.plugins.twitch : TwitchPlugin;
import kameloso.common : logger;
import std.datetime.systime : SysTime;

package:


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
        The channel name for which the credentials were invalid, if applicable.
     +/
    string channelName;

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
        Create a new [InvalidCredentialsException], attaching a channel name.
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


// isValidTwitchUsername
/++
    Checks if a string is a valid Twitch username.

    They must be 4 to 25 characters and may only contain letters, numbers and underscores.

    Params:
        username = The string to check.

    Returns:
        `true` if the string is a valid Twitch username; `false` if not.
 +/
auto isValidTwitchUsername(const string username)
{
    import std.algorithm.searching : all;
    import std.ascii : isAlphaNum;

    return (
        (username.length >= 4) &&
        (username.length <= 25) &&
        username.all!(c => isAlphaNum(c) || (c == '_')));
}

///
unittest
{
    {
        enum username = "zorael";
        assert(username.isValidTwitchUsername);
    }
    {
        enum username = "zårael";
        assert(!username.isValidTwitchUsername);
    }
    {
        enum username = "zorael_";
        assert(username.isValidTwitchUsername);
    }
    {
        enum username = "zorael-";
        assert(!username.isValidTwitchUsername);
    }
    {
        enum username = "z0rael";
        assert(username.isValidTwitchUsername);
    }
    {
        enum username = "z0r";
        assert(!username.isValidTwitchUsername);
    }
    {
        enum username = string.init;
        assert(!username.isValidTwitchUsername);
    }
    {
        enum username = "1234567890123456789012345";
        assert(username.isValidTwitchUsername);
    }
    {
        enum username = "12345678901234567890123456";
        assert(!username.isValidTwitchUsername);
    }
    {
        enum username = "#zorael";
        assert(!username.isValidTwitchUsername);
    }
}
