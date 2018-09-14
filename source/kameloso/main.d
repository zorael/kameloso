/++
 +  The main module, housing startup logic and the main event loop.
 +/
module kameloso.main;

import kameloso.common;
import kameloso.irc;
import kameloso.ircdefs;

// tryResolve
/++
 +  Tries to resolve the address in `client.parser.bot.server` to IPs, by
 +  leveraging `kameloso.connection.resolveFiber`, reacting on the
 +  `kameloso.connection.ResolveAttempt`s it yields to provide feedback to the
 +  user.
 +
 +  Params:
 +      client = Reference to the current `Client`.
 +
 +  Returns:
 +      `Next.continue_` if resolution succeeded, `Next.returnFaillure` if
 +      it failed and the program should exit.
 +/
Next tryResolve(ref Client client)
{
    import kameloso.connection : ResolveAttempt, resolveFiber;
    import kameloso.constants : Timeout;
    import std.concurrency : Generator;

    alias State = ResolveAttempt.State;
    auto resolver = new Generator!ResolveAttempt(() =>
        resolveFiber(client.conn, client.parser.bot.server.address,
        client.parser.bot.server.port, settings.ipv6, *(client.abort)));

    uint incrementedRetryDelay = Timeout.retry;
    enum incrementMultiplier = 1.5;

    string infotint, logtint;

    version(Colours)
    {
        if (!settings.monochrome)
        {
            import kameloso.bash : colour;
            import kameloso.logger : KamelosoLogger;
            import std.experimental.logger : LogLevel;

            infotint = KamelosoLogger.tint(LogLevel.info, settings.brightTerminal).colour;
            logtint = KamelosoLogger.tint(LogLevel.all, settings.brightTerminal).colour;
        }
    }

    resolver.call();

    with (client)
    foreach (attempt; resolver)
    {
        with (State)
        final switch (attempt.state)
        {
        case preresolve:
            // No message for this
            continue;

        case success:
            logger.infof("%s%s resolved into %s%s%2$s IPs.",
                parser.bot.server.address, logtint, infotint, conn.ips.length);
            return Next.continue_;

        case exception:
            logger.warning("Socket exception caught when resolving server adddress: ", attempt.error);

            enum resolveAttempts = 15;  // FIXME
            if (attempt.numRetry+1 < resolveAttempts)
            {
                import core.time : seconds;

                logger.logf("Network down? Retrying in %s%d%s seconds.",
                    infotint, incrementedRetryDelay, logtint);
                interruptibleSleep(incrementedRetryDelay.seconds, *abort);
                incrementedRetryDelay = cast(uint)(incrementedRetryDelay * incrementMultiplier);
            }
            continue;

        case error:
            logger.error("Socket exception caught when resolving server adddress: ", attempt.error);
            logger.log("Could not resolve address to IPs. Verify your server address.");
            return Next.returnFailure;

        case failure:
            logger.error("Failed to resolve host.");
            return Next.returnFailure;
        }
    }

    return Next.returnFailure;
}


public:

/++
 +  Entry point of the program.
 +/
void main(string[] args)
{
    // Initialise the main Client. Set its abort pointer to the global abort.
    Client client;
    client.parser.bot.server.address = "wefpok";
    tryResolve(client);
}
