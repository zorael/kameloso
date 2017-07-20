module kameloso.plugins;

import std.meta : AliasSeq;

/// Publically import all plugins so that only kameloso.plugins need be imported.
public import kameloso.plugins.admin;
public import kameloso.plugins.chatbot;
public import kameloso.plugins.common;
public import kameloso.plugins.connect;
public import kameloso.plugins.ctcp;
public import kameloso.plugins.notes;
public import kameloso.plugins.printer;
public import kameloso.plugins.sedreplace;

version(Posix)
{
    // Implicitly enabled if imported
    public import kameloso.plugins.pipeline;
}

version(Webtitles)
{
    // Implicitly enabled if imported
    public import kameloso.plugins.webtitles;
}

/// Add plugins to this list to enable them
public alias EnabledPlugins = AliasSeq!(
    Printer,
    ConnectPlugin,
    AdminPlugin,
    Chatbot,
    NotesPlugin,
    SedReplacePlugin,
    CTCPPlugin
);
