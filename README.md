# kameloso  [![Build Status](https://travis-ci.org/zorael/kameloso.svg?branch=master)](https://travis-ci.org/zorael/kameloso)

A command-line IRC bot.

**kameloso** sits and listens in the channels you specify and reacts to certain events, like bots generally do. It is a passive thing and does not (yet) respond to keyboard input, though text can be sent manually by other means.

Features are added as plugins written as [D](https://www.dlang.org) modules.

It includes a framework that works with "all" server networks. The IRC protocol is riddled with [inconsistencies](http://defs.ircdocs.horse/defs/numerics.html), so where it doesn't immediately work it's often a case of specialcasing something for that particular IRC network or server daemon.

Networks without [*nickname services*](https://en.wikipedia.org/wiki/IRC_services) will face some issues, since the bot identifies people by their `NickServ`/`Q`/`AuthServ` login names. As such you will probably want to register and reserve nicknames for both yourself and the bot, where available.

Current functionality includes:

* bedazzling coloured terminal output like it's the 90s
* printing of IRC events after they are parsed, all formatted and nice
* repeating text! amazing
* 8ball! because why not
* storing, loading and printing quotes from users
* saving notes to offline users that get played back when they come online
* looking up titles of pasted web URLs
* `sed`-replacement of the last message sent (`s/this/that/` substitution)
* piping text from the terminal to the server
* mIRC colour coding and text effects (bold, underlined, ...), translated into Bash formatting
* [SASL](https://en.wikipedia.org/wiki/Simple_Authentication_and_Security_Layer) authentication (`plain`)
* Twitch events; simple Twitch bot is now easy

## Windows

There are a few Windows caveats.

* Web URL title lookup may not work out of the box with secure `HTTPS` connections, due to the default installation of `dlang-requests` not finding the correct `OpenSSL` libraries. Unsure of how to fix this.
* Terminal colours may also not work, depending on your version of Windows and likely your terminal font. Unsure of how to enable this. By default it will compile with colours *disabled*, but they can be enabled by specifying a different build configuration.
* Text output will *not* work well with the default `Cygwin` terminal, due to some nuances of how it does or doesn't present itself as a `tty`. There are some workarounds for most output, though they aren't exposed for now.

## Getting Started

These instructions will get you a copy of the project up and running on your local machine for development and testing purposes, as well as general use.

### Prerequisites

You need a D compiler and the official `dub` package manager. There are three compilers available; see [here](https://wiki.dlang.org/Compilers) for an overview.

**kameloso** can be built using the reference compiler [dmd](https://dlang.org/download.html) and the `LLVM`-based [ldc](https://github.com/ldc-developers/ldc/releases), but the `GCC`-based [gdc](https://gdcproject.org/downloads) comes with a version of the standard library that is too old, at time of writing.

It's *possible* to build it without `dub` but it is non-trivial if you want the `webtitles` functionality.

### Downloading

GitHub offers downloads in ZIP format, but it's easier to use `git` and clone the repository that way.

    $ git clone https://github.com/zorael/kameloso.git
    $ cd kameloso

### Compiling

    $ dub build

This will compile it in the default `debug` mode, which adds some extra code and debugging symbols. You can automatically strip these and add some optimisations by building it in `release` mode with `dub build -b release`. Refer to the output of `dub build --help` for more build types.

Unit tests are built into the language, but you need to compile in `unittest` mode for them to run.

    $ dub build -b unittest

The tests are run at the *start* of the program, not during compilation. You can use the shorthand `dub test` to compile with tests and run the program immediately.

## How to use

The bot needs the *nickname services* login name of the administrator/master of the bot, and/or one of more home channels to operate in. It cannot work without having at least one of the two. The hardcoded defaults contain neither, so you need to create and edit a configuration file before starting.

    $ ./kameloso --writeconfig

Open the new `kameloso.conf` in a text editor and fill in the fields.

If you have an old configuration file and you notice missing options, such as the new plugin-specific options, just run `--writeconfig` again and your file should be updated with all fields. There are *many* more plugin-specific and less important options available than what is displayed at program start.

Once the bot has joined a channel it's ready. Mind that you need to authorise yourself with *nickname services* and whitelist your master login in the configuration file before it will listen to anything you do.

         you | kameloso: say herp
    kameloso | herp
         you | kameloso: 8ball
    kameloso | It is decidedly so
         you | kameloso: quote you This is a quote
    kameloso | Quote saved. (1 on record)
         you | kameloso: quote you
    kameloso | you | This is a quote
         you | kameloso: note OfflinePerson Why so offline?
    kameloso | Note added
         you | kameloso: sudo PRIVMSG #thischannel :this is a raw IRC command
    kameloso | this is a raw IRC command
         you | https://www.youtube.com/watch?v=s-mOy8VUEBk
    kameloso | [youtube.com] Danish language

## TODO

* "online" help; listing of verbs/commands
* add ExamplePlugin (work in progress)
* investigate inverse channel behaviour (blacklists)
* test IRCv3 more
* sort out `main.d`
* pipedream: DCC
* update docs and wiki
* throttle sending messages, anti-flood protection
* Travis LDC tests
* logger-less `irc.d`, to act more like a headless library
* ready for channel awareness
* more command-line flags

## Built With

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
