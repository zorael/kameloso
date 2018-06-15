import kameloso.common;
import kameloso.irc;
Flag!"quit" mainLoop(Client client)
{
    import std.datetime;
        with (client)
        {
            IRCEvent mutEvent;

            try
            {
                            logger.logf("Detected daemon: %s (%s)",
                                bot);
                immutable IRCEvent event ;

                    try
                        {
                                try
                                {
                                }
                                catch (const IRCParseException e)
                                    printObject(e);
                                    printObject(event);
                        }

                    catch                         logger.warningf("UTFException %s.onEvent: %s");
            }
            catch                     printObject(mutEvent);
        }

    return Yes.quit;
}




int main()
{
            return 0;
}
