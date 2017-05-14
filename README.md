# kameloso

A command-line IRC bot.

kameloso sits and listens in the channels you specify and reacts to certain events. It is a passive thing and does not respond to keyboard input. It is only known to actually work on [Freenode](https://freenode.net), but other servers *may* work, as long as they use `NickServ` for authentication. As some of Freenode's replies are non-standard, the bot may behave incorrectly on other servers.

Current functionality includes:

* printing of IRC events as they are parsed and handled, with optional colouring
* repeating text! amazing
* 8ball! because why not
* storing, loading and printing quotes from users
* saving notes to offline users that get played back when they come online
* looking up titles of pasted URLs
* sed-replacement of the last message sent (s/this/that/ replacement)

## Fails to build with OpenSSL 1.1.0

### Linux
The library `dlang-requests` has not yet been updated to work with the modern **1.1.0** version of OpenSSL, and so this project will not build unless you manually modify its project file to point to the old library. This assumes that you still have the old library installed. The package name is `openssl-1.0` in Arch linux and it can peacefully live next to the new `openssl`.

Open `~/.dub/packages/requests-0.4.1/requests/dub.json` in a text editor, and find these lines:

            "libs-posix": [
                "ssl",
                "crypto"
            ],

Change them to look like thisa and the rest of this guide should work.

            "libs-posix": [
                ":libssl.so.1.0.0",
                ":libcrypto.so.1.0.0"
            ],

## Getting Started

These instructions will get you a copy of the project up and running on your local machine for development and testing purposes.

### Prerequisites

You need a D compiler and the official `dub` package manager. There are three compilers available; see [here](https://wiki.dlang.org/Compilers) for an overview.

kameloso can be built using the reference compiler [dmd](https://dlang.org/download.html) and the LLVM-based [ldc](https://github.com/ldc-developers/ldc/releases), but the GCC-based [gdc](https://gdcproject.org/downloads) comes with a version of the standard library that is too old.

It's *possible* to build it without `dub` but it is non-trivial.

### Downloading

Github offers downloads in ZIP format, but it's easiest to use `git` and clone the repository that way.

    $ git clone https://github.com/zorael/kameloso.git
    $ cd kameloso

### Compiling

    $ dub build

This will compile it in the default `debug` mode, which adds some extra code. You can build it in `release` mode by passing that as an argument to `dub`. Ignore the deprecation messages of symbols not being visible from module traits, they're harmless.

    $ dub build -b release

Unit tests are built into the language, but you need to compile in `unittest` mode for them to run.

    $ dub build -b unittest

The tests are run at the *start* of the program, not during compilation.

## How to use

The bot needs the `NickServ` login name of the administrator/master of the bot, and/or one of more channels to operate in. It can't work without having at least one of the two. The hardcoded defaults contain neither, so you need to create and edit a configuration file before starting.

    $ ./kameloso --writeconfig


Open the new `kameloso.conf` in a text editor and fill in the fields.

Once the bot has joined a channel it's ready. Mind that you need to authorise yourself with NickServ and whitelist your login before it will listen to anything you do.

         you | kameloso: say herp
    kameloso | herp
         you | kameloso: 8ball
    kameloso | It is decidedly so
         you | kameloso: quote zorael This is a quote
    kameloso | Quote saved. (1 on record)
         you | kameloso: quote zorael
    kameloso | zorael | This is a quote
         you | kameloso: note OfflinePerson Why so offline?
    kameloso | Note added
         you | kameloso: sudo PRIVMSG #thischannel :this is a raw IRC command
    kameloso | this is a raw IRC command
         you | https://www.youtube.com/watch?v=s-mOy8VUEBk
    kameloso | [www.youtube.com] Danish language

## TODO

* rethink logging - should we writeln or use our own logging functions?
* "online" help; listing of verbs/commands
* random colours on nicks, based on their hash?
* improve command-line argument handling (issues [#4](https://github.com/zorael/kameloso/issues/4) and [#5](https://github.com/zorael/kameloso/issues/5) etc)
* make webtitles parse html entities like `&mdash;`. [arsd.dom](https://github.com/adamdruppe/arsd/blob/master/dom.d)?

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