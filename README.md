# kameloso

A command-line IRC bot.

kameloso sits and listens in the channels you specify and reacts to certain events, like bots generally do. It is a passive thing and does not respond to keyboard input, though text can be sent manually by other means.

It works on Freenode, Rizon and QuakeNet, with less confident support for Undernet, GameSurge, EFnet, DALnet, IRCnet, SwiftIRC, IRCHighWay, Twitch and UnrealIRCd servers.

To be honest most networks work at this point. Often a new one will just work right away, but sometimes there's a slight difference in how they behave and respond, and some changes will have to be made. It's usually fairly trivial modifications, like "does this network's `NickServ` just want a password, or a login *and* a password?".

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

## Fails to build with OpenSSL 1.1.0

The library `dlang-requests` has [not yet been updated](https://github.com/ikod/dlang-requests/issues/45) to work with the modern **1.1.0** version of OpenSSL and so this project will not fully build if you have the upgraded library. A workaround is to just not build the `webtitles` plugin that is importing the offending library, by compiling with `dub -c nowebtitles`.

A better but more involved workaround is to modify the `dlang-requests`'s project file to point to the old library. However, this assumes that you still have the old library installed.

### Linux

Ubuntu should [still](http://packages.ubuntu.com/zesty/openssl) be running with the old version.

In Arch linux and its derivatives, the package name of the old library is [`openssl-1.0`](https://www.archlinux.org/packages/extra/x86_64/openssl-1.0) and it can peacefully live next to the updated [`openssl`](https://www.archlinux.org/packages/core/x86_64/openssl).

Open `~/.dub/packages/requests-0.4.1/requests/dub.json` in a text editor, and find these lines:

            "libs-posix": [
                "ssl",
                "crypto"
            ],

Change them to look like this and the rest of this guide should work.

            "libs-posix": [
                ":libssl.so.1.0.0",
                ":libcrypto.so.1.0.0"
            ],

### Windows
Windows is equally affected but for now the easy way out is to not compile said `webtitles` plugin. The default Windows build will skip it automatically.

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
    kameloso | [www.youtube.com] Danish language

## TODO

* rethink logging - should we *really* writeln, or use our own logging functions?
* "online" help; listing of verbs/commands
* improve command-line argument handling (issues [#4](https://github.com/zorael/kameloso/issues/4) and [#5](https://github.com/zorael/kameloso/issues/5) etc)
* make webtitles parse html entities like `&mdash;`. [arsd.dom](https://github.com/adamdruppe/arsd/blob/master/dom.d)?
* add more unittests
* update documentation
* fix ctrl+c leaving behind fifos
* some functions don't honor settings and just print colours regardless
* JSON config file? but random ordering of entries, no lined-up columns
* retest everything now after the big changes
* revisit authentication events
* revisit event.special
* use PING as timeout on failed nick authentication?

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