import kameloso.common;
import kameloso.irc;
import std.typecons : Flag, No, Yes;

Flag!"quit" mainLoop(Client client)
{
    import std.datetime;

    with (client)
    {
        IRCEvent mutEvent;

        try
        {
            logger.logf("Detected daemon: %s (%s)", bot);
            immutable IRCEvent event;

            try
            {
                try {}
                catch (const IRCParseException e)
                {
                    printObject(e);
                }

                printObject(event);
            }

            catch (Exception e)
            {
                logger.warningf("UTFException %s.onEvent: %s");
            }
        }
        catch (Exception e)
        {
            printObject(mutEvent);
        }
    }

    return Yes.quit;
}

int main()
{
    return 0;
}
