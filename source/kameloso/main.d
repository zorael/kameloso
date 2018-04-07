import kameloso.common;
import kameloso.irc;

import std.typecons : Flag, Yes;


Flag!"quit" checkMessages()
{
    Flag!"quit" quit;

    void eventToServer(IRCEvent event)
    {
        with (event)
        switch (type)
        {
        default:
            logger.warning(type);
            break;
        }
    }

    return quit;
}


Flag!"quit" mainLoop()
{
    IRCEvent mutEvent;

    try
    {
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

    return Yes.quit;
}


int main()
{
    return 0;
}
