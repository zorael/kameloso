# kameloso

A command-line IRC bot.

kameloso sits and listens in the channels you specify and reacts to certain events. It is a passive thing and does not respond to keyboard input. It is only known to actually work on [Freenode](https://freenode.net), but other servers *may* work, as long as they use `NickServ` for authentication. Some of Freenode's replies are non-standard.

Current functionality includes:

* repeating text!
* storing, loading and printing quotes from users
* looking up titles of pasted URLs

Planned is a `note` feature that allows you to write a note to someone offline, and have the bot paste it when they come online again.

## Getting Started

These instructions will get you a copy of the project up and running on your local machine for development and testing purposes.

### Prerequisites

You need a D compiler and the official `dub` package manager. There are three compilers available; see [here](https://wiki.dlang.org/Compilers) for an overview.

kameloso can be built using the reference compiler [dmd](https://dlang.org/download.html) and the LLVM-based [ldc](https://github.com/ldc-developers/ldc/releases), but the GCC-based [gdc](https://gdcproject.org/downloads) comes with a version of the standard library that is too old.

It's *possible* to build it without `dub` but it's non-trivial.

### Compiling

    $ dub build


This will compile it in the default `debug` mode, which adds some extra code. You can build it in `release` mode by passing that as an argument to `dub`.

    $ dub build -b release


## Running tests

Unit tests are built into the language, but you need to compile in `unittest` mode for them to run.

    $ dub build -b unittest


The tests are run at the *start* of the program, not during compilation.

## How to use

The bot needs the `NickServ` login name of the administrator/master of the bot, and/or one of more channels to operate in. It can't work without having at least one of the two. The hardcoded defaults contain neither, so you need to create and edit a configuration file before starting.

    $ ./kameloso --writeconfig


Open the new `kameloso.conf` in a text editor and fill in the fields.

Once the bot has joined a channel trigger it with `say`, `8ball`, `quote` or by pasting a link.

         you | kameloso: say herp
    kameloso | herp
         you | kameloso: 8ball
    kameloso | It is decidedly so
         you | kameloso: quote zorael This is a quote
    kameloso | Quote saved. (1 on record)
         you | kameloso: quote zorael
    kameloso | zorael | This is a quote
         you | https://www.youtube.com/watch?v=s-mOy8VUEBk
    kameloso | [www.youtube.com] Danish language

## TODO

* `note` plugin
* rework plugin authentication logic
* add compile-time option to have everything multi-threaded
* evaluate cost of formatting `"foo%s".format(bar)` *vs* appending `"foo" ~ bar`

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
