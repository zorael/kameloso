# kameloso  [![Build Status](https://travis-ci.org/zorael/kameloso.svg?branch=master)](https://travis-ci.org/zorael/kameloso)

A command-line IRC bot.

kameloso sits and listens in the channels you specify and reacts to certain events, like bots generally do. It is a passive thing and does not respond to keyboard input, though text can be sent manually by other means.

It works on Freenode, Rizon and QuakeNet, with less confident support for Undernet, GameSurge, EFnet, DALnet, IRCnet, SwiftIRC, IRCHighWay, Twitch and UnrealIRCd servers. Definitions for those 12 servers exist and support varies from good to okay.

Often a new server network will just work right away, but sometimes there's a slight difference in how they behave and respond, and changes will have to be made. It's usually fairly trivial modifications, like "does this network's `NickServ` just want a password, or a login *and* a password?", or "is `NickServ` replaced with `AuthServ`?"

Current functionality includes:

* bedazzling coloured terminal output like it's the 90s
* printing of IRC events after they are parsed, all formatted and nice
* repeating text! amazing
* 8ball! because why not
* storing, loading and printing quotes from users
* saving notes to offline users that get played back when they come online
* looking up titles of pasted URLs
* sed-replacement of the last message sent (`s/this/that/` substitution)
* piping text from the terminal to the server
* mIRC colour coding

## Getting Started

These instructions will get you a copy of the project up and running on your local machine for development and testing purposes.

### Prerequisites

You need a D compiler and the official `dub` package manager. There are three compilers available; see [here](https://wiki.dlang.org/Compilers) for an overview.

kameloso can be built using the reference compiler [dmd](https://dlang.org/download.html) and the LLVM-based [ldc](https://github.com/ldc-developers/ldc/releases), but the GCC-based [gdc](https://gdcproject.org/downloads) comes with a version of the standard library that is too old, at time of writing.

It's *possible* to build it without `dub` but it is non-trivial if you want the `webtitles` functionality.

### Downloading

GitHub offers downloads in ZIP format, but it's easiest to use `git` and clone the repository that way.

    $ git clone https://github.com/zorael/kameloso.git
    $ cd kameloso

### Compiling

    $ dub build

This will compile it in the default `debug` mode, which adds some extra code and debugging symbols. You can build it in `release` mode by passing `-b release` as an argument to `dub`. Refer to the output of `dub build --help` for more build types.

Unit tests are built into the language, but you need to compile in `unittest` mode for them to run.

    $ dub build -b unittest

The tests are run at the *start* of the program, not during compilation.

## How to use

The bot needs the `NickServ`/`Q`/`AuthServ` login name of the administrator/master of the bot, and/or one of more channels to operate in. It can't work without having at least one of the two. The hardcoded defaults contain neither, so you need to create and edit a configuration file before starting.

    $ ./kameloso --writeconfig

Open the new `kameloso.conf` in a text editor and fill in the fields.

If you notice you're missing options in your configuration file, such as the new plugin-specific options, just run '--writeconfig` again and your file should be updated with all fields. Make a backup just in case.

Once the bot has joined a channel it's ready. Mind that you need to authorise yourself with NickServ and whitelist your login in the configuration file before it will listen to anything you do.

         you | kameloso: say herp
    kameloso | herp
         you | kameloso: 8ball
    kameloso | It is decidedly so
         you | kameloso: quote you This is a quote
    kameloso | Quote saved. (1 on record)
         you | kameloso: quote you
    kameloso | zorael | This is a quote
         you | kameloso: note OfflinePerson Why so offline?
    kameloso | Note added
         you | kameloso: sudo PRIVMSG #thischannel :this is a raw IRC command
    kameloso | this is a raw IRC command
         you | https://www.youtube.com/watch?v=s-mOy8VUEBk
    kameloso | [youtube.com] Danish language

## TODO

* "online" help; listing of verbs/commands
* make webtitles parse html entities like `&mdash;`. [arsd.dom](https://github.com/adamdruppe/arsd/blob/master/dom.d)?
* fix ctrl+c leaving behind fifos
* JSON config file? but random ordering of entries, no lined-up columns
* add ExamplePlugin
* non-member struct UDAs to enums? (currently structs)
* investigate inverse channel behaviour (blacklists)
* solve scope creep (almost now)
* revisit roles (badges) because this isn't working
* test IRCv3 more
* prettify configuration files; width is weird by neccessity of current design

## Built With

* [D](https://dlang.org)
* [dub](https://code.dlang.org)
* [dlang-requests](https://code.dlang.org/packages/requests)

## License

This project is licensed under the **GNU Lesser Public License v2.1** - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

* [kameloso](https://www.youtube.com/watch?v=s-mOy8VUEBk) for obvious reasons
* [README.md template gist](https://gist.github.com/PurpleBooth/109311bb0361f32d87a2)
* [dlang-requests](https://github.com/ikod/dlang-requests) for making the `webtitles` plugin possible
* [#d on freenode](irc://irc.freenode.org:6667/#d) for always answering questions
