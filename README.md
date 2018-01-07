# kameloso [![Build status](https://img.shields.io/circleci/project/zorael/kameloso/master.svg?maxAge=3600)](https://circleci.com/gh/zorael/kameloso) [![GitHub tag](https://img.shields.io/github/tag/zorael/kameloso.svg?maxAge=3600)](#)

**kameloso** sits and listens in the channels you specify and reacts to events, like bots generally do.

Features are added as plugins, written as [**D**](https://www.dlang.org) modules. A variety comes bundled but it's very easy to write your own. Ideas welcome.

It includes a framework that works with the vast majority of server networks. IRC is standardised but servers still come in [many flavours](https://upload.wikimedia.org/wikipedia/commons/thumb/d/d5/IRCd_software_implementations3.svg/1533px-IRCd_software_implementations3.svg.png), where some [conflict](http://defs.ircdocs.horse/defs/numerics.html) with others.  If something doesn't immediately work it's often merely a case of specialcasing it for that particular IRC network or server daemon.

Use on networks without [*services*](https://en.wikipedia.org/wiki/IRC_services) may be difficult, since the bot identifies people by their services (`NickServ`/`Q`/`AuthServ`/...) account names. As such you will probably want to register and reserve nicknames for both yourself and the bot, where available.

Current functionality includes:

* bedazzling coloured terminal output like it's the 90s
* user `quotes` service
* saving `notes` to offline users that get played back when they come online
* [`seen`](https://github.com/zorael/kameloso/blob/master/source/kameloso/plugins/seen.d) plugin; reporting when a user was last seen, written as a rough tutorial and a simple example of how plugins work
* looking up titles of pasted web URLs
* **Reddit** post lookup
* [`bash.org`](http://bash.org) quoting
* **Twitch** events; simple Twitch chatbot is now easy (notes on connecting below)
* `sed`-replacement of the last message sent (`s/this/that/` substitution)
* piping text from the terminal to the server
* **mIRC** colour coding and text effects (bold, underlined, ...), translated into **Bash** formatting
* [`SASL`](https://en.wikipedia.org/wiki/Simple_Authentication_and_Security_Layer) authentication (`plain`)

## Windows

There are a few Windows caveats.

* Web URL lookup, including the `bash.org` quotes and Reddit plugins, may not work out of the box with secure HTTPS connections, due to the default installation of `dlang-requests` not finding the correct libraries. Unsure of how to fix this. As such, such functionality is disabled on Windows by default.
* Terminal colours may also not work, depending on your version of Windows and likely your terminal font. Unsure of how to enable this. By default it will compile on Windows with colours disabled, but they can be enabled by specifying a different *build configuration*.

# Getting Started

These instructions will get you a copy of the project up and running on your local machine for development and testing purposes, as well as general use.

## Prerequisites

You need a **D** compiler and the official [`dub`](https://code.dlang.org/download) package manager. There are three compilers available; see [here](https://wiki.dlang.org/Compilers) for an overview.

**kameloso** can be built using the reference compiler [`dmd`](https://dlang.org/download.html) and the LLVM-based [`ldc`](https://github.com/ldc-developers/ldc/releases), but the GCC-based [`gdc`](https://gdcproject.org/downloads) comes with a version of the standard library that is too old, at time of writing.

It's *possible* to build it manually without `dub`, but it is non-trivial if you want web-related plugins to work.

## Downloading

GitHub offers downloads in ZIP format, but it's easier to use `git` and clone the repository that way.

```bash
$ git clone https://github.com/zorael/kameloso.git
$ cd kameloso
```

## Compiling

```bash
$ dub build
```

This will compile it in the default `debug` *build type*, which adds some extra code and debugging symbols. You can automatically strip these and add some optimisations by building it in `release` mode with `dub build -b release`. Refer to the output of `dub build --help` for more build types.

Unit tests are built into the language, but you need to compile the project in `unittest` mode for them to run.

```bash
$ dub build -b unittest
```

The tests are run at the *start* of the program, not during compilation. You can use the shorthand `dub test` to compile with tests and run the program in one go.

The available build configurations are:

* `vanilla`, builds without any specific extras
* `colours`, compiles in terminal colours
* `web`, compiles in plugins with web lookup (`webtitles`, `reddit` and `bashquotes`)
* `colours+web`, includes both of the above
* `posix`, default on Posix-like systems, equals `colours+web`
* `windows`, default on Windows, equals `vanilla`
* `cygwin`, equals `colours` but with extra code needed for running it under the default Cygwin terminal (*mintty*, which can display colours)

You can specify which to build with the `-c` switch.

```bash
$ dub build -b release -c vanilla
```

# How to use

The bot needs the services account name of the administrator of the bot, and/or one or more home channels to operate in. It cannot work without having at least one of the two. The hardcoded defaults contain neither, so you need to create and edit a configuration file before starting.

```bash
$ ./kameloso --writeconfig
```

Open the new `kameloso.conf` in a text editor and fill in the fields.

If you have an old configuration file and you notice missing options, such as plugin-specific settings, just run it with `--writeconfig` again and your file should be updated with all entries. There are *many* more plugin-specific and less important options available than what is displayed at program start.

The colours may be hard to see and the text difficult to read if you have a bright terminal background. If so, make sure to pass the `--bright` argument, and/or modify the configuration file; `brightTerminal` under `[Core]`. The bot uses the entire range of [8-colour ANSI](https://en.wikipedia.org/wiki/ANSI_escape_code#3/4_bit), so if one or more colours are too dark or bright even with the right `brightTerminal` setting, please see to your terminal appearance settings. This is not uncommon, especially with backgrounds that are not fully black or white. (Read: Monokai, Breeze, Solaris, ...)

Once the bot has joined a channel it's ready. Mind that you need to authorise yourself with any services and enter your administrator's account name in the configuration file before it will listen to anything you do. Before allowing *anyone* to trigger any functionality it will look them up and compare their accounts with its internal whitelist.

```
     you | !say herp
kameloso | herp
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
     you | kameloso: sudo PRIVMSG #thischannel :this is a raw IRC command
kameloso | this is a raw IRC command
     you | !bash 85514
kameloso | <Reverend> IRC is just multiplayer notepad.
     you | https://www.youtube.com/watch?v=s-mOy8VUEBk
kameloso | [youtube.com] Danish language
     you | !reddit https://dlang.org/blog/2018/01/04/dmd-2-078-0-has-been-released/
kameloso | Reddit post: https://www.reddit.com/r/programming/comments/7o2tcw/dmd_20780_has_been_released
```

Send `help` to the bot in a private query message for a summary of available bot commands, and `help [plugin] [command]` for a brief description of a specific one. Mind that commands defined as *regular expressions* will not be shown, due to technical reasons.

The *prefix* character (here `!`) is configurable; refer to your generated configuration file. Common alternatives are `.` and `~`, making it `.note` and `~quote` respectively.

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

`pass` is different from `authPassword` in that it is supplied very early during login/registration to even allow you to connect, before negotiating username and nickname, which is otherwise the very first thing to happen. `authPassword` is something that is sent to services after registration is finished and you have successfully logged onto the server. (In the case of `SASL` authentication, `authPassword` is used during late registration.)

Mind that a full Twitch bot cannot be implemented as an IRC client.

# TODO

* investigate inverse channel behaviour (blacklists)
* pipedream: DCC
* pipedream two: `ncurses`
* more modules? `uda.d`/`attribute.d`?
* merge thottling with timing
* compilation time and memory use :c
* optional formatting in IRC output?
* channel-split notes
* update wiki
* multiple masters?
* rename friends whitelist?
* add blacklist to apply to anyone? by mask?
* split up `common.d`, to better decouple

# Built With

* [**D**](https://dlang.org)
* [`dub`](https://code.dlang.org)
* [`dlang-requests`](https://code.dlang.org/packages/requests)
* [`arsd`](https://github.com/adamdruppe/arsd)

## License

This project is licensed under the **MIT** license - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

* [kameloso](https://www.youtube.com/watch?v=s-mOy8VUEBk) for obvious reasons
* [README.md template gist](https://gist.github.com/PurpleBooth/109311bb0361f32d87a2)
* [ikod](https://github.com/ikod) for [`dlang-requests`](https://github.com/ikod/dlang-requests) making the web-related plugins possible
* [Adam D. Ruppe](https://github.com/adamdruppe) for [`arsd`](https://github.com/adamdruppe/arsd), extending web functionality
* [#d on Freenode](irc://irc.freenode.org:6667/#d) for always answering questions
* [IRC Definition Files](http://defs.ircdocs.horse) and [`#ircdocs` on Freenode](irc://irc.freenode.org:6667/#ircdocs) for their excellent resource pages
