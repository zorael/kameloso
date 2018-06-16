import kameloso.common : CoreSettings, Client;
import std.typecons : Flag, No;

Flag!"quit" handleGetopt(Client client)
{
    import kameloso.common : printObjects;

    with (client)
    {
        printObjects(bot);
    }

    return No.quit;
}
