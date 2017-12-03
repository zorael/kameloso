module kameloso.plugins;

import std.meta : AliasSeq;

/// Publically import all plugins so that only kameloso.plugins need be imported.
public import kameloso.plugins.common;


/// Add plugins to this list to enable them
public alias EnabledPlugins = AliasSeq!(
    /*PrinterPlugin,
    ConnectPlugin,
    AdminPlugin,
    ChatbotPlugin,
    NotesPlugin,
    SedReplacePlugin,
    CTCPPlugin*/
);
