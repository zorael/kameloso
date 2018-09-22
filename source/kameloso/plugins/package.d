/++
 +  This `package` file contains the lists of enabled plugins (`EnabledPlugins`,
 +  `EnabledWebPlugins` and `EnabledPosixPlugins`) to which you append your
 +  plugin to have it be instantiated and included in the bot's normal routines.
 +/
module kameloso.plugins;

public import kameloso.plugins.common;


// tryImportMixin
/++
 +  String mixin. If a module is available, import it. If it isn't available,
 +  alias the passed `alias_` to an empty `AliasSeq`.
 +
 +  This allows us to import modules if they exist but otherwise silently still
 +  let it work without them.
 +
 +  Params:
 +      module_ = Fully qualified string name of the module to evaluate and
 +          potentially import.
 +      alias_ = Name of the symbol to create that points to an empty `AliasSeq`
 +          iff the module was not imported.
 +
 +  Returns:
 +      A selectively-importing `static if`. Mix this in to use.
 +/
version(WithPlugins)
string tryImportMixin(const string module_, const string alias_)
{
    import std.format : format;

    return q{
        static if (__traits(compiles, __traits(identifier, %1$s)))
        {
            //pragma(msg, "Importing plugin: %1$s");
            public import %1$s;
        }
        else
        {
            //pragma(msg, "NOT importing: %1$s (missing or doesn't compile)");
            import std.meta : AliasSeq;
            alias %2$s = AliasSeq!();
        }
    }.format(module_, alias_);
}


version(WithPlugins)
{
    /+
     +  Selectively import the plugins that are available. If not, alias the symbol
     +  with the name of the second parameter to an empty AliasSeq.
     +/
    mixin(tryImportMixin("kameloso.plugins.admin", "AdminPlugin"));
    mixin(tryImportMixin("kameloso.plugins.chatbot", "ChatbotPlugin"));
    mixin(tryImportMixin("kameloso.plugins.connect", "ConnectService"));
    mixin(tryImportMixin("kameloso.plugins.ctcp", "CTCPService"));
    mixin(tryImportMixin("kameloso.plugins.notes", "NotesPlugin"));
    mixin(tryImportMixin("kameloso.plugins.printer", "PrinterPlugin"));
    mixin(tryImportMixin("kameloso.plugins.sedreplace", "SedReplacePlugin"));
    mixin(tryImportMixin("kameloso.plugins.seen", "SeenPlugin"));
    mixin(tryImportMixin("kameloso.plugins.chanqueries", "ChanQueriesService"));
    mixin(tryImportMixin("kameloso.plugins.persistence", "PersistenceService"));
    mixin(tryImportMixin("kameloso.plugins.automode", "AutomodePlugin"));
    mixin(tryImportMixin("kameloso.plugins.quotes", "QuotesPlugin"));


    version(Posix)
    {
        mixin(tryImportMixin("kameloso.plugins.pipeline", "PipelinePlugin"));
    }
    else
    {
        // We need to do this so as to let `EnabledPosixPlugins` below be able to
        // resolve `PipelinePlugin`.
        alias PipelinePlugin = AliasSeq!();
    }


    version(Web)
    {
        mixin(tryImportMixin("kameloso.plugins.webtitles", "WebtitlesPlugin"));
        mixin(tryImportMixin("kameloso.plugins.bashquotes", "BashQuotesPlugin"));
        mixin(tryImportMixin("kameloso.plugins.reddit", "RedditPlugin"));
    }
    else
    {
        // Likewise we need to do this so as to let `EnabledWebPlugins` below  be
        // able to resolve these plugins.
        alias WebtitlesPlugin = AliasSeq!();
        alias BashQuotesPlugin = AliasSeq!();
        alias RedditPlugin = AliasSeq!();
    }


    version(TwitchSupport)
    {
        mixin(tryImportMixin("kameloso.plugins.twitch", "TwitchService"));
    }
    else
    {
        // Likewise we need to do this so as to let `EnabledPlugins` below be able
        // to resolve `TwitchService`.
        public alias TwitchService = AliasSeq!();
    }
}


/++
 +  List of enabled plugins. Add and remove to enable and disable.
 +
 +  Due to use of `tryImportMixin` above only files actually present will have
 +  been imported.
 +
 +  Note that `dub` will still compile any files in the `plugins` directory!
 +  To completely omit a plugin you will either have to compile the bot
 +  manually, delete the source file(s) in question, or add an `__EOF__` at the
 +  top of them. (Everything a line with that text is skipped.)
 +/
import std.meta : AliasSeq;
version(WithPlugins)
{
    public alias EnabledWebPlugins = AliasSeq!(
        WebtitlesPlugin,
        RedditPlugin,
        BashQuotesPlugin,
    );

    public alias EnabledPosixPlugins = AliasSeq!(
        PipelinePlugin,
    );

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
        EnabledWebPlugins,  // Automatically expands
        EnabledPosixPlugins,  // Ditto
    );
}
else
{
    // Not compiling in any plugins, so don't list any.
    public alias EnabledPlugins = AliasSeq!();
}
