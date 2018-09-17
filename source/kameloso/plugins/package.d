/++
 +  This `package` file contains the list of `EnabledPlugins`, to which you
 +  append your plugin to have it be instantiated and included in the bot's
 +  normal routines.
 +/
module kameloso.plugins;

import std.meta : AliasSeq;

/++
 +  Publically import all plugins so that only `kameloso.plugins` need be
 +  imported.
 +/
public import kameloso.plugins.admin;
public import kameloso.plugins.chatbot;
public import kameloso.plugins.common;
public import kameloso.plugins.connect;
public import kameloso.plugins.ctcp;
public import kameloso.plugins.notes;
public import kameloso.plugins.printer;
public import kameloso.plugins.sedreplace;
public import kameloso.plugins.seen;
public import kameloso.plugins.chanqueries;
public import kameloso.plugins.persistence;
public import kameloso.plugins.automode;
public import kameloso.plugins.quotes;

version(Posix)
{
    // Implicitly enabled if imported.
    public import kameloso.plugins.pipeline;
}

version(Web)
{
    // Implicitly enabled if imported.
    public import kameloso.plugins.webtitles;
    public import kameloso.plugins.bashquotes;
    public import kameloso.plugins.reddit;
}

version(TwitchSupport)
{
    // Import real TwitchService
    public import kameloso.plugins.twitch;
}
else
{
    alias TwitchService = AliasSeq!();
}

/++
 +  List of enabled plugins. Add and remove to enable and disable.
 +
 +  Note that `dub` will still compile any files in the `plugins` directory!
 +  To completely omit a plugin you will either have to compile the bot
 +  manually, or add an `__EOF__` at the top of the plugin source file.
 +/
version(WithPlugins)
{
    public alias EnabledPlugins = AliasSeq!(
        TwitchService, // Must be before PersistenceService
        PersistenceService, // Should be early
        PrinterPlugin,  // Might as well be early
        ConnectService,
        ChanQueriesService,
        CTCPService,
        AdminPlugin,
        ChatbotPlugin,
        NotesPlugin,
        SedReplacePlugin,
        SeenPlugin,
        AutomodePlugin,
        QuotesPlugin,
    );
}
else
{
    // Not compiling in any plugins, so don't list any.
    public alias EnabledPlugins = AliasSeq!();
}
