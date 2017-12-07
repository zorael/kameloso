# kameloso  [![Build Status](https://travis-ci.org/zorael/kameloso.svg?branch=master)](https://travis-ci.org/zorael/kameloso)

A command-line IRC bot.

**kameloso** sits and listens in the channels you specify and reacts to events, like bots generally do.

Features are added as plugins, written as [D](https://www.dlang.org) modules.

It includes a framework that works with the vast majority of server networks. IRC servers come in many [flavours](https://upload.wikimedia.org/wikipedia/commons/thumb/d/d5/IRCd_software_implementations3.svg/1533px-IRCd_software_implementations3.svg.png) and some [conflict](http://defs.ircdocs.horse/defs/numerics.html) with others.  Where it doesn't immediately work it's often a case of specialcasing something for that particular IRC network or server daemon.

Use on networks without [*services*](https://en.wikipedia.org/wiki/IRC_services) may be difficult, since the bot identifies people by their `NickServ`/`Q`/`AuthServ` login names. As such you will probably want to register and reserve nicknames for both yourself and the bot, where available.

Current functionality includes:

* bedazzling coloured terminal output like it's the 90s
* user `quotes` service
* saving `notes` to offline users that get played back when they come online
* [`seen`](https://github.com/zorael/kameloso/blob/master/source/kameloso/plugins/seen.d) plugin; reporting when a user was last seen, written as a tutorial and a simple example of how plugins work
* looking up titles of pasted web URLs (optionally with Reddit lookup)
* Twitch events; simple Twitch chatbot is now easy
* `sed`-replacement of the last message sent (`s/this/that/` substitution)
* piping text from the terminal to the server
* mIRC colour coding and text effects (bold, underlined, ...), translated into Bash formatting
* [SASL](https://en.wikipedia.org/wiki/Simple_Authentication_and_Security_Layer) authentication (`plain`)

## Windows

There are a few Windows caveats.

* Web URL title lookup may not work out of the box with secure `HTTPS` connections, due to the default installation of `dlang-requests` not finding the correct `OpenSSL` libraries. Unsure of how to fix this.
* Terminal colours may also not work, depending on your version of Windows and likely your terminal font. Unsure of how to enable this. By default it will compile with colours *disabled*, but they can be enabled by specifying a different build configuration.
* Text output will *not* work well with the default `Cygwin` terminal, due to some nuances of how it does or doesn't present itself as a `tty`. There are some workarounds for most output, though they aren't exposed for now.

# Getting Started

These instructions will get you a copy of the project up and running on your local machine for development and testing purposes, as well as general use.

## Prerequisites

You need a **D** compiler and the official [`dub`](https://code.dlang.org/download) package manager. There are three compilers available; see [here](https://wiki.dlang.org/Compilers) for an overview.

**kameloso** can be built using the reference compiler [dmd](https://dlang.org/download.html) and the `LLVM`-based [ldc](https://github.com/ldc-developers/ldc/releases), but the `GCC`-based [gdc](https://gdcproject.org/downloads) comes with a version of the standard library that is too old, at time of writing.

It's *possible* to build it without `dub` but it is non-trivial if you want the `webtitles` functionality.

## Downloading

GitHub offers downloads in ZIP format, but it's easier to use `git` and clone the repository that way.

    $ git clone https://github.com/zorael/kameloso.git
    $ cd kameloso

## Compiling

    $ dub build

This will compile it in the default `debug` mode, which adds some extra code and debugging symbols. You can automatically strip these and add some optimisations by building it in `release` mode with `dub build -b release`. Refer to the output of `dub build --help` for more build types.

Unit tests are built into the language, but you need to compile in `unittest` mode for them to run.

    $ dub build -b unittest

The tests are run at the *start* of the program, not during compilation. You can use the shorthand `dub test` to compile with tests and run the program immediately.

# How to use

The bot needs the *services* login name of the administrator/master of the bot, and/or one of more home channels to operate in. It cannot work without having at least one of the two. The hardcoded defaults contain neither, so you need to create and edit a configuration file before starting.

    $ ./kameloso --writeconfig

Open the new `kameloso.conf` in a text editor and fill in the fields.

If you have an old configuration file and you notice missing options such as the new plugin-specific settings, just run `--writeconfig` again and your file should be updated with all fields. There are *many* more plugin-specific and less important options available than what is displayed at program start.

The colours may be hard to see and the text difficult to read if you have a bright terminal background. If so, make sure to pass the `--bright` argument, and/or modify the configuration file; `brightTerminal` under `[Core]`. The bot uses the entire range of [ANSI colours](https://en.wikipedia.org/wiki/ANSI_escape_code#3/4_bit), so if one or more are too dark or bright even with the right `brightTerminal` setting, please see to your terminal appearance settings. This is not uncommon, especially with backgrounds that are not fully black or white. (Read: Monokai, Breeze, Solaris, ...)

Once the bot has joined a channel it's ready. Mind that you need to authorise yourself with any services and whitelist your master login in the configuration file before it will listen to anything you do. It will look you up before letting you trigger any functionality.

         you | !say herp
    kameloso | herp
         you | !8ball
    kameloso | It is decidedly so
         you | !quote you This is a quote
    kameloso | Quote saved. (1 on record)
         you | !quote you
    kameloso | you | This is a quote
         you | !note OfflinePerson Why so offline?
    kameloso | Note added
         you | !seen OfflinePerson
    kameloso | I last saw OfflinePerson 1 hour and 34 minutes ago
         you | kameloso: sudo PRIVMSG #thischannel :this is a raw IRC command
    kameloso | this is a raw IRC command
         you | !bash 85514
    kameloso | <Reverend> IRC is just multiplayer notepad.
         you | https://www.youtube.com/watch?v=s-mOy8VUEBk
    kameloso | [youtube.com] Danish language
    kameloso | Reddit: https://www.reddit.com/r/languagelearning/comments/7dcxfa/norwegian_comedy_about_the_danish_language_4m15s/

The *prefix* character (here '`!`') is configurable; see your generated configuration file. Common alternatives are '`.`' and '`~`', making it `.note` and `~quote` respectively.

    [Core]
    prefix              !

It can technically be any string and not just one character. Enquote it if you want spaces inbetween, like `"please "`.

## Twitch

To connect to Twitch servers you must supply an [OAuth token](https://en.wikipedia.org/wiki/OAuth).

Generate one [here](https://twitchapps.com/tmi), then add it to your `kameloso.conf` in the `pass` field.

    [IRCBot]
    nickname            twitchaccount
    pass                oauth:the50letteroauthstringgoeshere
    homes               #twitchaccount
    channels            #streamer1,#streamer2,#streamer3

    [IRCServer]
    address             irc.chat.twitch.tv
    port                6667

# TODO

* "online" help; listing of verbs/commands
* investigate inverse channel behaviour (blacklists)
* pipedream: DCC
* pipedream two: `ncurses`
* Travis LDC tests
* logger-less `irc.d`, to act more like a headless library
* ready for channel-awareness
* more command-line flags
* disambiguate warnings and errors, consistency

# Built With

* [D](https://dlang.org)
* [dub](https://code.dlang.org)
* [dlang-requests](https://code.dlang.org/packages/requests)
* [arsd](https://github.com/adamdruppe/arsd)

## License

This project is licensed under the **MIT** license - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

* [kameloso](https://www.youtube.com/watch?v=s-mOy8VUEBk) for obvious reasons
* [README.md template gist](https://gist.github.com/PurpleBooth/109311bb0361f32d87a2)
* [dlang-requests](https://github.com/ikod/dlang-requests) for making the `webtitles` plugin possible
* [#d on Freenode](irc://irc.freenode.org:6667/#d) for always answering questions
* [Adam D. Ruppe](https://github.com/adamdruppe) for graciously allowing us to use his libraries
* [IRC Definition Files](http://defs.ircdocs.horse) and [#ircdocs on Freenode](irc://irc.freenode.org:6667/#ircdocs) for their excellent resource pages
