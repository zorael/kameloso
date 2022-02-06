version(WithPlugins):
version(WithPersistenceService):

private:

import kameloso.plugins.common.core;
import dialect.defs;

void initAccountResources(PersistenceService service)
{
    import lu.json : JSONStorage;
    import std.json : JSONException, JSONValue;

    JSONStorage json;
    json.reset();

    try
    {
        json.load(service.userFile);
    }
    catch (JSONException e)
    {
        import kameloso.plugins.common.misc : IRCPluginInitialisationException;
        import kameloso.common : logger;
        import std.path : baseName;

        version(PrintStacktraces) logger.trace();
        throw new IRCPluginInitialisationException(service.userFile.baseName ~ " may be malformed.");
    }

    static auto deduplicate(JSONValue before)
    {
        import std.algorithm.iteration : filter, uniq;
        import std.algorithm.sorting : sort;
        import std.array : array;

        auto after = before
            .array
            .sort!((a, b) => a.str < b.str)
            .uniq
            .filter!((a) => a.str.length > 0)
            .array;

        return JSONValue(after);
    }

    import std.range : only;

    foreach (liststring; only("staff", "operator", "whitelist", "blacklist"))
    {
        enum examplePlaceholderKey = "<#channel>";

        if (liststring !in json)
        {
            json[liststring] = null;
            json[liststring].object = null;
            json[liststring][examplePlaceholderKey] = null;
            json[liststring][examplePlaceholderKey].array = null;
            json[liststring][examplePlaceholderKey].array ~= JSONValue("<nickname1>");
            json[liststring][examplePlaceholderKey].array ~= JSONValue("<nickname2>");
        }
        else
        {
            if ((json[liststring].object.length > 1) &&
                (examplePlaceholderKey in json[liststring].object))
            {
                json[liststring].object.remove(examplePlaceholderKey);
            }

            try
            {
                foreach (immutable channelName, ref channelAccountsJSON; json[liststring].object)
                {
                    if (channelName == examplePlaceholderKey) continue;
                    channelAccountsJSON = deduplicate(json[liststring][channelName]);
                }
            }
            catch (JSONException e)
            {
                import kameloso.plugins.common.misc : IRCPluginInitialisationException;
                import kameloso.common : logger;
                import std.path : baseName;

                version(PrintStacktraces) logger.trace();
                throw new IRCPluginInitialisationException(service.userFile.baseName ~ " may be malformed.");
            }
        }
    }

    static immutable order = [ "staff", "operator", "whitelist", "blacklist" ];
    json.save!(JSONStorage.KeyOrderStrategy.inGivenOrder)(service.userFile, order);
}

public:

final class PersistenceService : IRCPlugin
{
private:
    import kameloso.constants : KamelosoFilenames;
    import core.time : seconds;

    enum timeBetweenRehashes = (3 * 3600).seconds;
    @Resource string userFile = KamelosoFilenames.users;
    @Resource string hostmasksFile = KamelosoFilenames.hostmasks;
    IRCUser.Class[string][string] channelUsers;
    IRCUser[] hostmaskUsers;
    string[string] hostmaskNicknameAccountCache;
    string[string] userClassCurrentChannelCache;

    mixin IRCPluginImpl;
}
