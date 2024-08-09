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


// generateExpiryReminders
/++
    Generates and delays Twitch authorisation token expiry reminders.

    Params:
        plugin = The current [TwitchPlugin].
        expiresWhen = A [std.datetime.systime.SysTime|SysTime] of when the expiry occurs.
        what = The string of what kind of token is expiring.
        onExpiryDg = Delegate to call when the token expires.
 +/
void generateExpiryReminders(
    TwitchPlugin plugin,
    const SysTime expiresWhen,
    const string what,
    void delegate() onExpiryDg)
{
    import kameloso.plugins.common.scheduling : delay;
    import lu.string : plurality;
    import std.datetime.systime : Clock;
    import std.meta : AliasSeq;
    import core.time : days, hours, minutes, seconds, weeks;

    auto untilExpiry()
    {
        immutable now = Clock.currTime;
        return (expiresWhen - now) + 59.seconds;
    }

    void warnOnWeeksDg()
    {
        immutable numDays = untilExpiry.total!"days";
        if (numDays <= 0) return;

        // More than a week away, just .info
        enum pattern = "%s will expire in <l>%d days</> on <l>%4d-%02d-%02d";
        logger.infof(
            pattern,
            what,
            numDays,
            expiresWhen.year,
            cast(uint)expiresWhen.month,
            expiresWhen.day);
    }

    void warnOnDaysDg()
    {
        int numDays;
        int numHours;
        untilExpiry.split!("days", "hours")(numDays, numHours);
        if ((numDays < 0) || (numHours < 0)) return;

        // A week or less, more than a day; warning
        if (numHours > 0)
        {
            enum pattern = "Warning: %s will expire " ~
                "in <l>%d %s and %d %s</> at <l>%4d-%02d-%02d %02d:%02d";
            logger.warningf(
                pattern,
                what,
                numDays, numDays.plurality("day", "days"),
                numHours, numHours.plurality("hour", "hours"),
                expiresWhen.year, cast(uint)expiresWhen.month, expiresWhen.day,
                expiresWhen.hour, expiresWhen.minute);
        }
        else
        {
            enum pattern = "Warning: %s will expire " ~
                "in <l>%d %s</> at <l>%4d-%02d-%02d %02d:%02d";
            logger.warningf(
                pattern,
                what,
                numDays, numDays.plurality("day", "days"),
                expiresWhen.year, cast(uint)expiresWhen.month, expiresWhen.day,
                expiresWhen.hour, expiresWhen.minute);
        }
    }

    void warnOnHoursDg()
    {
        int numHours;
        int numMinutes;
        untilExpiry.split!("hours", "minutes")(numHours, numMinutes);
        if ((numHours < 0) || (numMinutes < 0)) return;

        // Less than a day; warning
        if (numMinutes > 0)
        {
            enum pattern = "WARNING: %s will expire " ~
                "in <l>%d %s and %d %s</> at <l>%02d:%02d";
            logger.warningf(
                pattern,
                what,
                numHours, numHours.plurality("hour", "hours"),
                numMinutes, numMinutes.plurality("minute", "minutes"),
                expiresWhen.hour, expiresWhen.minute);
        }
        else
        {
            enum pattern = "WARNING: %s will expire in <l>%d %s</> at <l>%02d:%02d";
            logger.warningf(
                pattern,
                what,
                numHours, numHours.plurality("hour", "hours"),
                expiresWhen.hour, expiresWhen.minute);
        }
    }

    void warnOnMinutesDg()
    {
        immutable numMinutes = untilExpiry.total!"minutes";
        if (numMinutes <= 0) return;

        // Less than an hour; warning
        enum pattern = "WARNING: %s will expire in <l>%d minutes</> at <l>%02d:%02d";
        logger.warningf(
            pattern,
            what,
            numMinutes,
            expiresWhen.hour,
            expiresWhen.minute);
    }

    void onTrueExpiry()
    {
        // Key expired
        onExpiryDg();
    }

    alias reminderPoints = AliasSeq!(
        14.days,
        7.days,
        3.days,
        1.days,
        12.hours,
        6.hours,
        1.hours,
        30.minutes,
        10.minutes,
        5.minutes,
    );

    immutable now = Clock.currTime;
    immutable trueExpiry = (expiresWhen - now);

    foreach (immutable reminderPoint; reminderPoints)
    {
        if (trueExpiry >= reminderPoint)
        {
            immutable untilPoint = (trueExpiry - reminderPoint);
            if (reminderPoint >= 1.weeks) delay(plugin, &warnOnWeeksDg, untilPoint);
            else if (reminderPoint >= 1.days) delay(plugin, &warnOnDaysDg, untilPoint);
            else if (reminderPoint >= 1.hours) delay(plugin, &warnOnHoursDg, untilPoint);
            else /*if (reminderPoint >= 1.minutes)*/ delay(plugin, &warnOnMinutesDg, untilPoint);
        }
    }

    // Notify on expiry, maybe quit
    delay(plugin, &onTrueExpiry, trueExpiry);

    // Also announce once normally how much time is left
    if (trueExpiry >= 1.weeks) warnOnWeeksDg();
    else if (trueExpiry >= 1.days) warnOnDaysDg();
    else if (trueExpiry >= 1.hours) warnOnHoursDg();
    else /*if (trueExpiry >= 1.minutes)*/ warnOnMinutesDg();
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
