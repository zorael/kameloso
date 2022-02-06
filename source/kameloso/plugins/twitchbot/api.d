
module kameloso.plugins.twitchbot.api;

version(WithPlugins):
version(TwitchSupport):
version(WithTwitchBotPlugin):
version(TwitchAPIFeatures):

private:

import kameloso.plugins.twitchbot.base;

import std.json : JSONValue;
import std.traits : isSomeFunction;
import std.typecons : Flag, No, Yes;
import core.thread : Fiber;

package:




struct QueryResponse
{
    
    string str;

    
    long msecs;

    
    uint code;

    
    string error;

    
    uint errorCode;
}




void twitchTryCatchDg(alias dg)()
if (isSomeFunction!dg)
{
    
}




void persistentQuerier(shared QueryResponse[string] bucket,
    const uint timeout,
    const string caBundleFile)
{
    
}




QueryResponse queryTwitch(TwitchBotPlugin plugin,
    const string url,
    const string authorisationHeader,
    const Flag!"recursing" recursing = No.recursing)
in (Fiber.getThis, "Tried to call `queryTwitch` from outside a Fiber")
{
    import kameloso.plugins.common.delayawait : delay;
    import kameloso.thread : ThreadMessage;
    import std.concurrency : prioritySend, send, spawn;
    import std.datetime.systime : Clock, SysTime;
    import etc.c.curl : CurlError;
    import core.time : msecs;

    SysTime pre;

    plugin.state.mainThread.prioritySend(ThreadMessage.ShortenReceiveTimeout());

    if (plugin.state.settings.trace)
    {
        import kameloso.common : Tint, logger;
        logger.trace("GET: ", Tint.info, url);
    }

    if (plugin.twitchBotSettings.singleWorkerThread)
    {
        pre = Clock.currTime;
        plugin.persistentWorkerTid.send(url, authorisationHeader);
    }
    else
    {
        spawn(&queryTwitchImpl, url, authorisationHeader,
            plugin.queryResponseTimeout, plugin.bucket, plugin.state.connSettings.caBundleFile);
    }

    delay(plugin, plugin.approximateQueryTime.msecs, Yes.yield);
    immutable response = waitForQueryResponse(plugin, url,
        plugin.twitchBotSettings.singleWorkerThread);

    scope(exit)
    {
        synchronized 
        {
            
            plugin.bucket.remove(url);
        }
    }

    if (plugin.twitchBotSettings.singleWorkerThread)
    {
        immutable post = Clock.currTime;
        immutable diff = (post - pre);
        immutable msecs_ = diff.total!"msecs";
        plugin.averageApproximateQueryTime(msecs_);
    }
    else
    {
        plugin.averageApproximateQueryTime(response.msecs);
    }

    if (!response.str.length)
    {
        throw new TwitchQueryException("Empty response", response.str,
            response.error, response.code, response.errorCode);
    }
    else if ((response.code >= 500) && !recursing)
    {
        return queryTwitch(plugin, url, authorisationHeader, Yes.recursing);
    }
    else if (response.code >= 400)
    {
        import lu.string : unquoted;
        import std.format : format;
        import std.json : parseJSON;

        
        
        immutable errorJSON = parseJSON(response.str);
        enum pattern = "%s %3d: %s";

        immutable message = pattern.format(
            errorJSON["error"].str.unquoted,
            errorJSON["status"].integer,
            errorJSON["message"].str.unquoted);

        throw new TwitchQueryException(message, response.str,
            response.error, response.code, response.errorCode);
    }
    else if (response.errorCode != CurlError.ok)
    {
        throw new TwitchQueryException("cURL error", response.str,
            response.error, response.code, response.errorCode);
    }

    return response;
}




void queryTwitchImpl(const string url,
    const string authToken,
    const uint timeout,
    shared QueryResponse[string] bucket,
    const string caBundleFile)
{
    
}




JSONValue getValidation(TwitchBotPlugin plugin)
in (Fiber.getThis, "Tried to call `getValidation` from outside a Fiber")
{
    
    return JSONValue.init;
}




void averageApproximateQueryTime(TwitchBotPlugin plugin, const long responseMsecs)
{
    
}




QueryResponse waitForQueryResponse(TwitchBotPlugin plugin,
    const string url,
    const bool leaveTimingAlone = true)
in (Fiber.getThis, "Tried to call `waitForQueryResponse` from outside a Fiber")
{
    
    return QueryResponse.init;
}




final class TwitchQueryException : Exception
{
@safe:
    
    string responseBody;

    
    string error;

    
    uint code;

    
    uint errorCode;

    
    this(const string message,
        const string responseBody,
        const string error,
        const uint code,
        const uint errorCode,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        
        super(message, file, line, nextInChain);
    }

    
    this(const string message,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }
}
