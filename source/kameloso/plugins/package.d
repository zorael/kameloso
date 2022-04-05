/++
    This `package` file contains the lists of enabled plugins, to which you
    append your plugin module to have it be instantiated and included in the
    bot's normal routines.
 +/
module kameloso.plugins;

private:

import std.meta : AliasSeq;

public:


// PluginModules
/++
    A list of all plugin modules, by string name so they can be resolved even in
    `singleFile` mode. These will be instantiated in the order listed.

    Care has to be taken to point to `base` plugin modules in cases where the
    "module" is a package.

    A plugin can be completely disabled by removing/commenting out its entry here,
    or by adding a `version(none):` or `__EOF__` to the top of the file.
    The moule declaration *must* be kept however, or the compiler will stop due
    to the below not being possible to be resolved to valid modules.
 +/
alias PluginModules = AliasSeq!(
    "kameloso.plugins.services.persistence",
    "kameloso.plugins.printer.base",
    "kameloso.plugins.services.connect",
    "kameloso.plugins.services.chanqueries",
    "kameloso.plugins.services.ctcp",
    "kameloso.plugins.admin.base",
    "kameloso.plugins.chatbot",
    "kameloso.plugins.notes",
    "kameloso.plugins.sedreplace",
    "kameloso.plugins.seen",
    "kameloso.plugins.automode",
    "kameloso.plugins.quotes",
    "kameloso.plugins.twitchbot.base",
    "kameloso.plugins.help",
    "kameloso.plugins.hello",
    "kameloso.plugins.oneliners",
    "kameloso.plugins.votes",
    "kameloso.plugins.stopwatch",
    "kameloso.plugins.counter",
    "kameloso.plugins.webtitles",
    "kameloso.plugins.pipeline",
    "kameloso.plugins.tester",
);
