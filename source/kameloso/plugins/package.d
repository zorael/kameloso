/++
 +  This `package` file contains the lists of enabled plugins, to which you
 +  append your plugin module to have it be instantiated and included in the
 +  bot's normal routines.
 +/
module kameloso.plugins;

private:

import std.meta : AliasSeq;

public:


// PluginModules
/++
 +  A list of all plugin modules. These will be instantiated in the order listed.
 +
 +  Care has to be taken to point to `base` plugin modules in cases where the
 +  "module" is a package.
 +
 +  A plugin can be completely disabled by removing/commenting out its entry here,
 +  or by adding a `version(none):` or `__EOF__` to the top of the file.
 +  The moule declaration must be kept however, or the compiler will stop due
 +  to the below being invalid identifiers.
 +/
alias PluginModules = AliasSeq!(
    kameloso.plugins.persistence,
    kameloso.plugins.printer.base,
    kameloso.plugins.connect,
    kameloso.plugins.chanqueries,
    kameloso.plugins.ctcp,
    kameloso.plugins.admin.base,
    kameloso.plugins.chatbot,
    kameloso.plugins.notes,
    kameloso.plugins.sedreplace,
    kameloso.plugins.seen,
    kameloso.plugins.automode,
    kameloso.plugins.quotes,
    kameloso.plugins.twitchbot.base,
    kameloso.plugins.help,
    kameloso.plugins.hello,
    kameloso.plugins.oneliners,
    kameloso.plugins.votes,
    kameloso.plugins.stopwatch,
    kameloso.plugins.counter,
    kameloso.plugins.webtitles,
    kameloso.plugins.pipeline,
);
