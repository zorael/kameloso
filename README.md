# kameloso [![CircleCI Linux/OSX](https://img.shields.io/circleci/project/github/zorael/kameloso/master.svg?maxAge=3600&logo=circleci)](https://circleci.com/gh/zorael/kameloso) [![Travis Linux/OSX and documentation](https://img.shields.io/travis/zorael/kameloso/master.svg?maxAge=3600&logo=travis)](https://travis-ci.org/zorael/kameloso) [![Windows](https://img.shields.io/appveyor/ci/zorael/kameloso/master.svg?maxAge=3600&logo=appveyor)](https://ci.appveyor.com/project/zorael/kameloso) [![Issue 46](https://img.shields.io/github/issues/detail/s/zorael/kameloso/46.svg?maxAge=3600)](https://github.com/zorael/kameloso/issues/46) [![GitHub commits since last release](https://img.shields.io/github/commits-since/zorael/kameloso/v1.0.0-rc.4.svg?maxAge=3600&logo=github)](https://github.com/zorael/kameloso/compare/v1.0.0-rc.4...master)

**kameloso** sits and listens in the channels you specify and reacts to events, like bots generally do.

A variety of features comes bundled in the form of compile-time plugins, some of which are examples and proofs of concepts. It's designed to be easy to write your own. API documentation is [available online](https://zorael.github.io/kameloso). Any and all ideas for inclusion welcome.

It works well with the majority of server networks. IRC is standardised but servers still come in [many flavours](https://upload.wikimedia.org/wikipedia/commons/thumb/d/d5/IRCd_software_implementations3.svg/1533px-IRCd_software_implementations3.svg.png), where some [outright conflict](http://defs.ircdocs.horse/defs/numerics.html) with others. If something doesn't immediately work, most often it's because we simply haven't encountered that type of event before. It's then an easy case of creating rules for that kind of event on that particular IRC network or server daemon.

Please report bugs. Unreported bugs can only be fixed by accident.

## Current functionality includes:

* bedazzling coloured terminal output like it's the 90s
* automatic mode sets (eg. auto `+o` for op)
* looking up titles of pasted web URLs
* logs
* `sed`-replacement of the last message sent (`s/this/that/` substitution)
* saving `notes` to offline users that get played back when they come online
* [`seen`](https://github.com/zorael/kameloso/blob/master/source/kameloso/plugins/seen.d) plugin; reporting when a user was last seen, written as a rough example plugin
* user `quotes` plugin
* Reddit post lookup
* [`bash.org`](http://bash.org) quoting
* Twitch support (with default-disabled [example bot plugin](https://github.com/zorael/kameloso/blob/master/source/kameloso/plugins/twitch.d)); see [notes on connecting](#twitch) below
* piping text from the terminal to the server (Linux/OSX and other UNIX-likes only)
* mIRC colour coding and text effects (bold, underlined, ...), translated into ANSI terminal formatting
* [SASL](https://en.wikipedia.org/wiki/Simple_Authentication_and_Security_Layer) authentication (`plain`)
* configuration stored on file; generate one and edit it to get an idea of the settings available to toggle (see [notes on generating](#configuration) below)

If nothing else it makes for a good read-only terminal lurkbot.

## Current limitations:

* **the dmd and ldc compilers may segfault** if building in anything other than `debug` mode (bug [#18026](https://issues.dlang.org/show_bug.cgi?id=18026), see more on build types below).
* the stable release of the **gdc** compiler doesn't yet support `static foreach` and thus cannot be used to build this bot. The development release based on D version **2.081** segfaults upon compiling (bug [#307](https://bugzilla.gdcproject.org/show_bug.cgi?id=307))
* nicknames are case-sensitive, while channel names are not. Making all of it case-insensitive made things really gnarly, so the change was reverted. There are corner cases where things might break; please file bugs.
* missing good how-to-use guide. Use the source, Luke!
* IRC server that have not been tested against may exhibit weird behaviour if parsing goes awry. Need concrete examples to fix; please report errors and abnormalities.

Use on networks without [*services*](https://en.wikipedia.org/wiki/IRC_services) (`NickServ`/`Q`/`AuthServ`/...) may be difficult, since the bot identifies people by their account names. You will probably want to register yourself with such, where available.

Testing is primarily done on [**freenode**](https://freenode.net), so support and coverage is best there. Twitch also sees extensive testing, but mostly as a client lurking channels and less as a bot offering functionality.

# Table of contents

* [Getting started](#getting-started)
  * [Prerequisites](#prerequisites)
  * [Downloading](#downloading)
  * [Compiling](#compiling)
    * [Windows](#windows)
* [How to use](#how-to-use)
  * [Configuration](#configuration)
    * [Command-line arguments](#command-line-arguments)
    * [Display settings](#display-settings)
  * [Other files](#other-files)
  * [Example use](#example-use)
    * [Online help and commands](#online-help-and-commands)
  * [Twitch](#twitch)
  * [Use as a library](#use-as-a-library)
* [Debugging and generating unit tests](#debugging-and-generating-unit-tests)
* [Roadmap](#roadmap)
* [Built with](#built-with)
  * [License](#license)
* [Acknowledgements](#acknowledgements)

---

# Getting started

These instructions will get you a copy of the project up and running on your local machine for development and testing purposes, as well as general use.

## Prerequisites

You need a **D** compiler and the official [**dub**](https://code.dlang.org/download) package manager. There are three compilers available; see [here](https://wiki.dlang.org/Compilers) for an overview. You need one based on version **2.076** or later (released September 2017). You will also need a good chunk of RAM, as compiling requires some 4 Gb to build all features (linux, excluding tests).

**kameloso** can be built using the reference compiler [**dmd**](https://dlang.org/download.html) and the LLVM-based [**ldc**](https://github.com/ldc-developers/ldc/releases), in `debug` mode (see below). The stable release of the GCC-based [**gdc**](https://gdcproject.org/downloads) is currently too old to be used.

It's *possible* to build it manually without dub, but it is non-trivial if you want the web-related plugins to work. Your best bet is to first build it with dub in verbose mode, then copy the actual command it runs and modify it to suit your needs.

## Downloading

```bash
$ git clone https://github.com/zorael/kameloso.git
$ cd kameloso
```

Do not use `dub fetch` until we have released **v1.0.0**. It will download an ancient version.

## Compiling

```bash
$ dub build
```

This will compile it in the default `debug` *build type*, which adds some extra code and debugging symbols.

> You can automatically skip these and add some optimisations by building it in `release` mode with `dub build -b release`. Mind that build times will increase. Refer to the output of `dub build --help` for more build types.

The above might currently not work, as the compiler may crash on some build configurations under anything other than `debug` mode. [Bug reported.](https://issues.dlang.org/show_bug.cgi?id=18026)

Unit tests are built into the language, but you need to compile the project in `unittest` mode to include them.

```bash
$ dub build -b unittest
```

The tests are run at the *start* of the program, not during compilation. You can use the shorthand `dub test` to compile with tests and run them in one go. Test builds will only run the unit tests and immediately exit.

The available *build configurations* are:

* `vanilla`, builds without any specific extras
* `colours`, compiles in terminal colours
* `web`, compiles in plugins with web lookup (`webtitles`, `reddit` and `bashquotes`)
* `colours+web`, includes both of the above
* `posix`, default on Posix-like systems, equals `colours+web`
* `windows`, default on Windows, equals `web`
* `cygwin`, equals `colours+web` but with extra code needed for running it under the default Cygwin terminal (**mintty**)

List them with `dub build --print-configs`. You can specify which to compile with the `-c` switch. Not supplying one will make it build the default for your operating system.

```bash
$ dub build -c cygwin
```

## Windows

There are a few Windows caveats.

* Web URL lookup, including the web titles and Reddit plugins, will not work out of the box with secure HTTPS connections due to missing libraries. Download a "light" installer from [slproweb.com](https://slproweb.com/products/Win32OpenSSL.html) and install **to system libraries**, and it should no longer warn on program start.
* Terminal colours may also not work in the default `cmd` console, depending on your version of Windows and likely your terminal font. Unsure of how to fix this. Powershell works fine.
* Use in Cygwin terminals without compiling the aforementioned `cygwin` configuration will be unpleasant (terminal output will be broken). Here too Powershell consoles are not affected and can be used with any configuration. `cmd` also works without `cygwin`, albeit with the previously mentioned colour issues.

# How to use

## Configuration

The bot needs the services account name of one or more administrators of the bot, and/or one or more home channels to operate in. It cannot work without having at least one of the two, so you need to generate and edit a configuration file before starting.

```bash
$ ./kameloso --writeconfig
```

A new `kameloso.conf` will be created in a directory dependent on your platform.

* Linux: `~/.config/kameloso` (alternatively where `$XDG_CONFIG_HOME` points)
* OSX: `$HOME/Library/Application Support/kameloso`
* Windows: `%LOCALAPPDATA%\kameloso`
* Other unexpected platforms: fallback to current working directory

Open the file in there in a text editor and fill in the fields. Peruse it to get an idea of the features available.

### Command-line arguments

You can override some settings with arguments on the command line, listed by calling the program with `--help`. If you specify some and also add `--writeconfig` it will save these changes to the file so you don't have to repeat them, without having to manually edit the configuration file.

```bash
$ ./kameloso \
    --server irc.freenode.net \
    --nickname "kameloso" \
    --admins "you,friend,thatguy" \
    --homes "#channel,#elsewhere" \
    --channels "#d,##networking" \
    --writeconfig

Configuration file written to /home/user/.config/kameloso/kameloso.conf
```

Repeated calls of `--writeconfig` will only regenerate the file. It will never overwrite custom settings, only complement them with new ones. Mind however that it will remove any lines not corresponding to a valid setting, which includes old settings no longer in use as well as comments.

### Display settings

If you have compiled in colours and you have bright terminal background, the colours may be hard to see and the text difficult to read. If so, make sure to pass the `--bright` argument, and/or modify the configuration file; `brightTerminal` under `[Core]`. The bot uses the entire range of [8-colour ANSI](https://en.wikipedia.org/wiki/ANSI_escape_code#3/4_bit), so if one or more colours are too dark or bright even with the right `brightTerminal` setting, please see to your terminal appearance settings. This is not uncommon, especially with backgrounds that are not fully black or white. (read: Monokai, Breeze, Solaris, ...)

## Other files

More server-specific resource files will be created the first time you connect to a server. These include `users.json`, in which you whitelist which accounts get to access the bot's features. Where these are stored also depends on platform; in the case of **MacOS** and **Windows** they will be put in subdirectories of the same directory as the configuration file, listed above. On **Linux**, under `~/.local/share/kameloso` (or wherever `$XDG_DATA_HOME` points). As before it falls back to the working directory on other unknown platforms.

## Example use

Once the bot has joined a home channel, it's ready. Mind that you need to authorise yourself with services with an account listed as an administrator in the configuration file to make it listen to anything you do. Before allowing *anyone* to trigger any functionality it will look them up and compare their accounts with its white- and blacklists. Refer to the `admins` field in the configuration file, as well as your `users.json`.


```bash
$ ./kameloso
```

```
     you joined #channel
kameloso sets mode +o you
     you | !say foo
kameloso | foo
     you | foo bar baz
     you | s/bar/BAR/
kameloso | you | foo BAR baz
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
     you | !reddit https://dlang.org/blog/2018/01/04/dmd-2-078-0-has-been-released
kameloso | Reddit post: https://www.reddit.com/r/programming/comments/7o2tcw/dmd_20780_has_been_released
kameloso | [reddit.com] DMD 2.078.0 Has Been Released : programming
```

### Online help and commands

Send `help` to the bot in a *private message* for a summary of available bot commands, and `help [plugin] [command]` for a brief description of a specific one. Mind that commands defined as *regular expressions* cannot be shown, due to technical reasons.

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

`pass` is not the same as `authPassword`. It is supplied very early during login (or *registration*) to allow you to connect -- even before negotiating username and nickname, which is otherwise the very first thing to happen. `authPassword` is something that is sent to a services bot (like `NickServ` or `AuthServ`) after registration has finished and you have successfully logged onto the server. (In the case of SASL authentication, `authPassword` is used during late registration.)

Mind that in many ways Twitch does not behave as a full IRC server. Most common IRC commands go unrecognised. Joins and parts are not always advertised. Participants in a channel are not always enumerated upon joining it, and you cannot query the server for the list. You cannot query the server for information about a single user either. You cannot readily trust who is **+o** and who isn't, as it will oscillate to **-o** at irregular intervals. You also can only join channels for which a corresponding Twitch user account exists.

See [this Twitch help page on moderation](https://help.twitch.tv/customer/en/portal/articles/659095-twitch-chat-and-moderation-commands) and [this page on harassment](https://help.twitch.tv/customer/portal/articles/2329145-how-to-manage-harassment-in-chat) for available moderator commands to send as normal channel `PRIVMSG` messages.

Known limitation: a user that is in more than one observed channel can be displayed with a badge in one that he/she actually has in another. This is because a user can only have one set of badges at a time per the current implementation, and it is persistent and carries across channels.

## Use as a library

The IRC event parsing bits are largely decoupled from the bot parts of the program, needing only some common non-bot-oriented helper modules.

* [`irc/defs.d`](https://github.com/zorael/kameloso/blob/master/source/kameloso/irc/defs.d)
* [`irc/parsing.d`](https://github.com/zorael/kameloso/blob/master/source/kameloso/irc/parsing.d)
* [`irc/common.d`](https://github.com/zorael/kameloso/blob/master/source/kameloso/irc/common.d)
* [`string.d`](https://github.com/zorael/kameloso/blob/master/source/kameloso/string.d)
* [`conv.d`](https://github.com/zorael/kameloso/blob/master/source/kameloso/conv.d)
* [`meld.d`](https://github.com/zorael/kameloso/blob/master/source/kameloso/meld.d)
* [`traits.d`](https://github.com/zorael/kameloso/blob/master/source/kameloso/traits.d)
* [`uda.d`](https://github.com/zorael/kameloso/blob/master/source/kameloso/uda.d)

Feel free to copy these and drop them into your own project. Look up the structs `IRCBot` and `IRCParser` to get started. See the versions at the top of [`irc/common.d`](https://github.com/zorael/kameloso/blob/master/source/kameloso/irc/common.d). Some very basic examples can be found in [`tests/events.d`](https://github.com/zorael/kameloso/blob/master/source/tests/events.d).

# Debugging and generating unit tests

Writing an IRC bot when servers all behave differently is difficult, and you will come across unexpected events for which there are no rules on how to parse. It may be some messages silently have weird values in the wrong fields (e.g. nickname where channel should go), or be empty when they shouldn't -- or more likely there will be an error message. Please file an issue.

If you're working on developing the bot yourself, you can generate unit test assert blocks for new events by passing the command-line `--asserts` flag, specifying the server daemon and pasting the raw line. Copy the generated assert block and place it in `tests/events.d`, or wherever is appropriate.

If more state is necessary to replicate the environment, such as needing things from `RPL_ISUPPORT` or a specific resolved server address (from early `NOTICE` or `RPL_HELLO`), paste/fake the raw line for those first and it will inherit the implied changes for any following lines throughout the session. It will print the changes evoked, so you'll know if you succeeded.

# Roadmap

* pipedream zero: **no compiler segfaults**
* pipedream: DCC
* pipedream two: `ncurses`?
* `seen` doing what? channel-split? `IRCEvent`-based? (later)
* private notes (later)

# Built with

* [**D**](https://dlang.org)
* [`dub`](https://code.dlang.org)
* [`dlang-requests`](https://code.dlang.org/packages/requests)
* [`arsd`](https://github.com/adamdruppe/arsd)

## License

This project is licensed under the **MIT** license - see the [LICENSE](LICENSE) file for details.

# Acknowledgements

* [kameloso](https://www.youtube.com/watch?v=s-mOy8VUEBk) for obvious reasons
* [`README.md` template gist](https://gist.github.com/PurpleBooth/109311bb0361f32d87a2)
* [ikod](https://github.com/ikod) for [`dlang-requests`](https://github.com/ikod/dlang-requests)
* [Adam D. Ruppe](https://github.com/adamdruppe) for [`arsd`](https://github.com/adamdruppe/arsd)
* [`#d` on freenode](irc://irc.freenode.org:6667/#d)
* [IRC Definition Files](http://defs.ircdocs.horse) and [`#ircdocs` on freenode](irc://irc.freenode.org:6667/#ircdocs)
