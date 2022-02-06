
module kameloso.plugins.oneliners;

version(WithPlugins):
version(WithOnelinersPlugin):

private:

import kameloso.plugins.common.core;
import kameloso.plugins.common.awareness : ChannelAwareness, TwitchAwareness, UserAwareness;
import kameloso.common : logger;
import kameloso.messaging;
import dialect.defs;



@Settings struct OnelinersSettings
{
    
    @Enabler bool enabled = true;

    
    bool caseSensitiveTriggers = false;
}





void onOneliner(OnelinersPlugin plugin, const ref IRCEvent event)
{
    
}





void onCommandModifyOneliner(OnelinersPlugin plugin, const ref IRCEvent event)
{
    import lu.string : contains, nom;
    import std.format : format;
    import std.typecons : Flag, No, Yes;
    import std.uni : toLower;

    void sendUsage(const string verb = "[add|del|list]",
        const Flag!"includeText" includeText = Yes.includeText)
    {
        chan(plugin.state, event.channel, "Usage: %s%s %s [trigger]%s"
            .format(plugin.state.settings.prefix, event.aux, verb,
                includeText ? " [text]" : string.init));
    }

    if (!event.content.length) return sendUsage();

    string slice = event.content;
    immutable verb = slice.nom!(Yes.inherit, Yes.decode)(' ');

    switch (verb)
    {
    case "add":
        import kameloso.thread : ThreadMessage;
        import std.concurrency : send;

        if (!slice.contains!(Yes.decode)(' ')) return sendUsage(verb, Yes.includeText);

        string trigger = slice.nom!(Yes.decode)(' ');

        if (!trigger.length) return sendUsage(verb);

        if (!plugin.onelinersSettings.caseSensitiveTriggers) trigger = trigger.toLower;

        void dg(IRCPlugin.CommandMetadata[string][string] aa)
        {
            foreach (immutable pluginName, pluginCommands; aa)
            {
                foreach ( word, command; pluginCommands)
                {
                    if (!plugin.onelinersSettings.caseSensitiveTriggers) word = word.toLower;

                    if (word == trigger)
                    {
                        enum pattern = `Oneliner word "%s" conflicts with a command of the %s plugin.`;
                        chan(plugin.state, event.channel,
                            pattern.format(trigger, pluginName));
                        return;
                    }
                }
            }

            plugin.onelinersByChannel[event.channel][trigger] = slice;
            saveResourceToDisk(plugin.onelinersByChannel, plugin.onelinerFile);

            import std.algorithm.comparison : equal;
            import std.uni : asLowerCase;

            immutable wasMadeLowerCase = !plugin.onelinersSettings.caseSensitiveTriggers &&
                !trigger.equal(trigger.asLowerCase);

            chan(plugin.state, event.channel, "Oneliner %s%s added%s."
                .format(plugin.state.settings.prefix, trigger,
                    wasMadeLowerCase ? " (made lowercase)" : string.init));
        }

        plugin.state.mainThread.send(ThreadMessage.PeekCommands(), cast(shared)&dg);
        break;

    case "del":
        if (!slice.length) return sendUsage(verb, No.includeText);

        immutable trigger = plugin.onelinersSettings.caseSensitiveTriggers ? slice : slice.toLower;

        if (trigger !in plugin.onelinersByChannel[event.channel])
        {
            import std.conv : text;
            chan(plugin.state, event.channel,
                text("No such trigger: ", plugin.state.settings.prefix, slice));
            return;
        }

        plugin.onelinersByChannel[event.channel].remove(trigger);
        saveResourceToDisk(plugin.onelinersByChannel, plugin.onelinerFile);

        chan(plugin.state, event.channel, "Oneliner %s%s removed."
            .format(plugin.state.settings.prefix, trigger));
        break;

    case "list":
        return plugin.listCommands(event.channel);

    default:
        return sendUsage();
    }
}




@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.SELFCHAN)
    .permissionsRequired(Permissions.anyone)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("commands")
            .policy(PrefixPolicy.prefixed)
            .description("Lists all available oneliners.")
    )
)
void onCommandCommands(OnelinersPlugin plugin, const ref IRCEvent event)
{
    
}




void listCommands(OnelinersPlugin plugin, const string channelName)
{
    import std.format : format;

    auto channelOneliners = channelName in plugin.onelinersByChannel;

    if (channelOneliners && channelOneliners.length)
    {
        immutable pattern = "Available commands: %-(" ~ plugin.state.settings.prefix ~ "%s, %)";
        chan(plugin.state, channelName, pattern.format(channelOneliners.byKey));
    }
    else
    {
        chan(plugin.state, channelName, "There are no commands available right now.");
    }
}





void onWelcome(OnelinersPlugin plugin)
{
    
}




void saveResourceToDisk(const string[string][string] aa, const string filename)
in (filename.length, "Tried to save resources to an empty filename string")
{
    
}




void initResources(OnelinersPlugin plugin)
{
    
}


mixin UserAwareness;
mixin ChannelAwareness;

public:




final class OnelinersPlugin : IRCPlugin
{
private:
    
    OnelinersSettings onelinersSettings;

    
    string[string][string] onelinersByChannel;

    
    @Resource string onelinerFile = "oneliners.json";

    mixin IRCPluginImpl;
}
