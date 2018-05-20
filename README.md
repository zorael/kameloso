# kameloso [![CircleCI Linux/OSX](https://img.shields.io/circleci/project/zorael/kameloso/master.svg?maxAge=3600)](https://circleci.com/gh/zorael/kameloso) [![Travis Linux/OSX](https://img.shields.io/travis/zorael/kameloso.svg?logo=travis)](https://travis-ci.org/zorael/kameloso) [![Windows](https://img.shields.io/appveyor/ci/zorael/kameloso.svg?maxAge=3600&logo=appveyor)](https://ci.appveyor.com/project/zorael/kameloso) [![GitHub tag](https://img.shields.io/github/tag/zorael/kameloso.svg?maxAge=3600&logo=github)](#)

**kameloso** sits and listens in the channels you specify and reacts to events, like bots generally do.

Features are added as plugins, written as [**D**](https://www.dlang.org) modules. A variety comes bundled but it's very easy to write your own. API documentation is [available online](https://zorael.github.io/kameloso). Any and all ideas welcome.

Included is a framework that works with the majority of server networks. IRC is standardised but servers still come in [many flavours](https://upload.wikimedia.org/wikipedia/commons/thumb/d/d5/IRCd_software_implementations3.svg/1533px-IRCd_software_implementations3.svg.png), where some outright [conflict](http://defs.ircdocs.horse/defs/numerics.html) with others.  If something doesn't immediately work it's often mostly a case of specialcasing for that particular IRC network or server daemon.

### Current functionality includes:

* bedazzling coloured terminal output like it's the 90s
* automatic mode sets (eg. auto `+o` for op)
* user `quotes` service
* saving `notes` to offline users that get played back when they come online
* [`seen`](https://github.com/zorael/kameloso/blob/master/source/kameloso/plugins/seen.d) plugin; reporting when a user was last seen, written as a rough tutorial and a simple example of how plugins work
* looking up titles of pasted web URLs
* Reddit post lookup
* [`bash.org`](http://bash.org) quoting
* Twitch events; simple Twitch chatbot is now easy (see notes on connecting below)
* `sed`-replacement of the last message sent (`s/this/that/` substitution)
* piping text from the terminal to the server (Posix-like only)
* mIRC colour coding and text effects (bold, underlined, ...), translated into Bash terminal formatting
* [SASL](https://en.wikipedia.org/wiki/Simple_Authentication_and_Security_Layer) authentication (`plain`)

### Current limitations:

* building **may segfault the dmd compiler** if compiling in `plain` or `release` modes with dmd **up to version 2.079.0**; in some cases only `debug` works (bug [#18026](https://issues.dlang.org/show_bug.cgi?id=18026)); fixed in 2.079.1?
* some plugins don't yet differentiate between different home channels if there is more than one
* quirky IRC server daemons that haven't been tested against can exhibit weird behaviour when parsing goes awry (need concrete examples to fix, please report abnormalities)

Use on networks without [*services*](https://en.wikipedia.org/wiki/IRC_services) may be difficult, since the bot identifies people by their services (`NickServ`/`Q`/`AuthServ`/...) account names. You will probably want to register yourself with such, where available.

Testing is mainly done on [freenode](https://freenode.net), so support and coverage is best there.


# Table of contents

* [News](#news)
* [Getting started](#getting-started)
    * [Prerequisites](#prerequisites)
    * [Downloading](#downloading)
    * [Compiling](#compiling)
        * [Windows](#windows)
* [How to use](#how-to-use)
    * [Twitch](#twitch)
    * [Use as a library](#use-as-a-library)
* [Roadmap](#roadmap)
* [Built with](#built-with)
    * [License](#license)
    * [Acknowledgements](#acknowledgements)
---

# News

* Readme now has a news section!
* segfault seems gone in 2.079.1?
* experimental `automodes` plugin, please test
* the `printer` plugin can now save logs to disk. Regenerate your configuration file and enable it with `saveLogs` set to `true`. It can either write lines as they are received, or buffer writes to write with a cadence of once every PING, configured with `bufferedWrites`. By default only homes are logged; configurable with the `logAllChannels` knob. Needs testing and feedback
* direct **imgur** links are now rewritten (to the non-direct HTML page) so we can get a meaningful page title, like stale YouTube ones are
* remember to `dub upgrade` to get a fresh `dlang-requests` (~>0.7.0)
* all* (non-service) plugins can now be toggled as enabled or disabled in the configuration file. Regenerate it to get the configuration file entries
* New `whitelist`/`blacklist` handling needs testing
* plugins can now mixin `MinimalAuthentification` rather than the full `UserAwareness` if they don't need `ChannelAwareness` and/or access to the `state.users` array

# Getting started

These instructions will get you a copy of the project up and running on your local machine for development and testing purposes, as well as general use.

## Prerequisites

You need a **D** compiler and the official [`dub`](https://code.dlang.org/download) package manager. There are three compilers available; see [here](https://wiki.dlang.org/Compilers) for an overview.

**kameloso** can be built using the reference compiler [`dmd`](https://dlang.org/download.html) and the LLVM-based [`ldc`](https://github.com/ldc-developers/ldc/releases), but the GCC-based [`gdc`](https://gdcproject.org/downloads) comes with a version of the standard library that is too old, at time of writing.

It's *possible* to build it manually without `dub`, but it is non-trivial if you want the web-related plugins to work.

## Downloading

GitHub offers downloads in [ZIP format](https://github.com/zorael/kameloso/archive/master.zip), but it's arguably easier to use `git` and clone a copy of the source that way.

```bash
$ git clone https://github.com/zorael/kameloso.git
$ cd kameloso
```

## Compiling

```bash
$ dub build
```

This will compile it in the default `debug` *build type*, which adds some extra code and debugging symbols.

You can automatically strip these and add some optimisations by building it in `release` mode with `dub build -b release`. Mind that build times will increase. Refer to the output of `dub build --help` for more build types.

Unit tests are built into the language, but you need to compile the project in `unittest` mode to include them.

```bash
$ dub build -b unittest
```

The tests are run at the *start* of the program, not during compilation. You can use the shorthand `dub test` to compile with tests and run them in one go. `unittest` builds will only run the unit tests and immediately exit.

The available *build configurations* are:

* `vanilla`, builds without any specific extras
* `colours`, compiles in terminal colours
* `web`, compiles in plugins with web lookup (`webtitles`, `reddit` and `bashquotes`)
* `colours+web`, includes both of the above
* `posix`, default on Posix-like systems, equals `colours+web`
* `windows`, default on Windows, equals `web`
* `cygwin`, equals `colours+web` but with extra code needed for running it under the default Cygwin terminal (*mintty*)

You can specify which to compile with the `-c` switch. Not supplying one will make it build the default for your operating system.

```bash
$ dub build -b release -c cygwin
```

## Windows

There are a few Windows caveats.

* Web URL lookup, including the web titles and Reddit plugins, may not work out of the box with secure HTTPS connections, due to the default installation of `dlang-requests` not finding the correct libraries. Unsure of how to fix this. Normal HTTP access should work fine.
* Terminal colours may also not work, depending on your version of Windows and likely your terminal font. Unsure of how to enable this.
* Use in Cygwin terminals without compiling the aforementioned `cygwin` build configuration will be unpleasant. Normal `cmd` and Powershell consoles are not affected.

# How to use

The bot needs the services account name of the administrator(s) of the bot, and/or one or more home channels to operate in. It cannot work without having at least one of the two, so you need to create and edit a configuration file before starting.

```bash
$ ./kameloso --writeconfig
```

Open the new `kameloso.conf` in a text editor and fill in the fields.

If you have compiled in colours, they may be hard to see and the text difficult to read if you have a bright terminal background. If so, make sure to pass the `--bright` argument, and/or modify the configuration file; `brightTerminal` under `[Core]`. The bot uses the entire range of [8-colour ANSI](https://en.wikipedia.org/wiki/ANSI_escape_code#3/4_bit), so if one or more colours are too dark or bright even with the right `brightTerminal` setting, please see to your terminal appearance settings. This is not uncommon, especially with backgrounds that are not fully black or white. (read: Monokai, Breeze, Solaris, ...)

Once the bot has joined a channel it's ready. Mind that you need to authorise yourself with any services (with an account listed as an adminisrator in the configuration file) to make it listen to anything you do. Before allowing *anyone* to trigger any functionality it will look them up and compare their accounts with its internal whitelists.

```
     you joined #channel
kameloso sets mode +o you
     you | !say herp
kameloso | herp
     you | s/herp/actually blarp/
kameloso | you | actually blarp
     you | !8ball
kameloso | It is decidedly so
     you | !addquote you This is a quote
kameloso | Quote saved. (1 on record)
     you | !quote you
kameloso | you | This is a quote
     you | !note OfflinePerson Why so offline?
kameloso | Note added.
     you | !seen OfflinePerson
kameloso | I last saw OfflinePerson 1 hour and 34 minutes ago.
     you | kameloso: sudo PRIVMSG #channel :this is a raw IRC command
kameloso | this is a raw IRC command
     you | !bash 85514
kameloso | <Reverend> IRC is just multiplayer notepad.
     you | https://www.youtube.com/watch?v=s-mOy8VUEBk
kameloso | [youtube.com] Danish language
     you | !reddit https://dlang.org/blog/2018/01/04/dmd-2-078-0-has-been-released/
kameloso | Reddit post: https://www.reddit.com/r/programming/comments/7o2tcw/dmd_20780_has_been_released
```

Send `help` to the bot in a private query message for a summary of available bot commands, and `help [plugin] [command]` for a brief description of a specific one. Mind that commands defined as *regular expressions* will not be shown, due to technical reasons.

The *prefix* character (here "`!`") is configurable; refer to your generated configuration file. Common alternatives are `.` and `~`, making it `.note` and `~quote` respectively.

```ini
[Core]
prefix              !
```

It can technically be any string and not just one character. Enquote it if you want any spaces as part of the prefix token, like `"please "`.

## Twitch

To connect to Twitch servers you must supply an [*OAuth token*](https://en.wikipedia.org/wiki/OAuth). Generate one [here](https://twitchapps.com/tmi), then add it to your `kameloso.conf` in the `pass` field.

```ini
[IRCBot]
nickname            twitchaccount
pass                oauth:the50letteroauthstringgoeshere
homes               #twitchaccount
channels            #streamer1,#streamer2,#streamer3

[IRCServer]
address             irc.chat.twitch.tv
port                6667
```

`pass` is not the same as `authPassword`. It is supplied very early during login (or *registration*) to even allow you to connect, even before negotiating username and nickname, which is otherwise the very first thing to happen. `authPassword` is something that is sent to services after registration is finished and you have successfully logged onto the server. (In the case of SASL authentication, `authPassword` is used during late registration.)

Mind that a full Twitch bot cannot be implemented as an IRC client.

## Use as a library

The IRC server string-parsing modules are largely decoupled from the rest of the program, needing only some helper modules.

* [`irc.d`](https://github.com/zorael/kameloso/blob/master/source/kameloso/irc.d)
* [`ircdefs.d`](https://github.com/zorael/kameloso/blob/master/source/kameloso/ircdefs.d)
* [`string.d`](https://github.com/zorael/kameloso/blob/master/source/kameloso/string.d)
* [`meld.d`](https://github.com/zorael/kameloso/blob/master/source/kameloso/meld.d)

The big exception is one function that warns the user of abnormalities after parsing, which uses a *Logger* to inform the user when something seems wrong. The Logger in turn imports more. Comment the `version = PostParseSanityCheck` [at the top of `irc.d`](https://github.com/zorael/kameloso/blob/master/source/kameloso/irc.d#L19) to opt out of these messages and remove this dependency.

# Roadmap

* pipedream: DCC
* pipedream two: `ncurses`
* optional formatting in IRC output? (later if at all)
* notes triggers? (later)
* `seen` doing what? channel-split? `IRCEvent`-based? (later)
* update wiki
* set up a real configuration home like `~/.kameloso`? what of Windows?

# Built with

* [**D**](https://dlang.org)
* [`dub`](https://code.dlang.org)
* [`dlang-requests`](https://code.dlang.org/packages/requests)
* [`arsd`](https://github.com/adamdruppe/arsd)

## License

This project is licensed under the **MIT** license - see the [LICENSE](LICENSE) file for details.

## Acknowledgements

* [kameloso](https://www.youtube.com/watch?v=s-mOy8VUEBk) for obvious reasons
* [`README.md` template gist](https://gist.github.com/PurpleBooth/109311bb0361f32d87a2)
* [ikod](https://github.com/ikod) for [`dlang-requests`](https://github.com/ikod/dlang-requests) making the web-related plugins possible
* [Adam D. Ruppe](https://github.com/adamdruppe) for [`arsd`](https://github.com/adamdruppe/arsd), extending web functionality
* [`#d` on Freenode](irc://irc.freenode.org:6667/#d) for always answering questions
* [IRC Definition Files](http://defs.ircdocs.horse) and [`#ircdocs` on Freenode](irc://irc.freenode.org:6667/#ircdocs) for their excellent resource pages
