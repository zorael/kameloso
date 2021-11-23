#!/bin/bash

set -uexo pipefail

DMD_VERSION="2.098.0"
LDC_VERSION="1.28.0"
CURL_USER_AGENT="CirleCI $(curl --version | head -n 1)"

update_repos() {
    sudo apt-get update
}

install_deps() {
    sudo apt-get install g++-multilib

    # required for: "core.time.TimeException@std/datetime/timezone.d(2073): Directory /usr/share/zoneinfo/ does not exist."
    #sudo apt-get install --reinstall tzdata gdb
}

download_install_script() {
    for i in {0..4}; do
        if curl -fsS -A "$CURL_USER_AGENT" --max-time 5 https://dlang.org/install.sh -O ||
                curl -fsS -A "$CURL_USER_AGENT" --max-time 5 https://nightlies.dlang.org/install.sh -O ; then
            break
        elif [[ "$i" -ge 4 ]]; then
            sleep $((1 << i))
        else
            echo 'Failed to download install script' 1>&2
            exit 1
        fi
    done
}

install_and_activate_compiler() {
    local COMPILER=$1
    local COMPILER_VER=$2
    source "$(CURL_USER_AGENT=\"$CURL_USER_AGENT\" bash install.sh $COMPILER-$COMPILER_VER --activate)"
}

use_lu_master() {
    if [[ ! -d lu ]]; then
        git clone https://github.com/zorael/lu.git
        dub add-local lu
    fi
}

use_dialect_master() {
    if [[ ! -d dialect ]]; then
        git clone https://github.com/zorael/dialect.git
        dub add-local dialect
    fi
}

build() {
    local DC compiler_switch arch_switch build_ext arch_ext options

    DC="$1"
    [[ "$2" == "x86_64" ]] && arch_ext="" || arch_ext="-$2"
    [[ $# -gt 2 ]] && [[ "$3" ]] && build_ext="-$3" || build_ext=""
    compiler_switch="--compiler=$DC"
    arch_switch="--arch=$2"

    shift 2
    shift 1 || true
    options="$@"

    mkdir -p artifacts
    dub clean

    ## test
    time dub test $compiler_switch $arch_switch $options -c unittest${build_ext}
    options="$options --nodeps"


    ## debug
    time dub build $compiler_switch $arch_switch $options -b debug -c twitch${build_ext}
    mv kameloso "artifacts/kameloso-${DC}${arch_ext}"

    time dub build $compiler_switch $arch_switch $options -b debug -c dev${build_ext}
    mv kameloso "artifacts/kameloso-$DC-dev${arch_ext}"


    ## plain
    #time dub build $compiler_switch $arch_switch $options -b plain -c twitch${build_ext} || true
    #mv kameloso "artifacts/kameloso-$DC-plain${arch_ext}" || \
    #    touch "artifacts/kameloso-$DC-plain${arch_ext}.failed"

    time dub build $compiler_switch $arch_switch $options -b plain -c dev${build_ext} || true
    #mv kameloso "artifacts/kameloso-$DC-plain-dev${build_ext}${arch_ext}" || \
    #    touch "artifacts/kameloso-$DC-plain-dev${build_ext}${arch_ext}.failed"


    ## release
    #time dub build $compiler_switch $arch_switch $options -b release -c twitch${build_ext} || true
    #mv kameloso "artifacts/kameloso-$DC-release${arch_ext}" || \
    #    touch "artifacts/kameloso-$DC-release${arch_ext}.failed"

    time dub build $compiler_switch $arch_switch $options -b release -c dev${build_ext} || true
    #mv kameloso "artifacts/kameloso-$DC-release-dev${build_ext}${arch_ext}" || \
    #    touch "artifacts/kameloso-$DC-release-dev${build_ext}${arch_ext}.failed"
}

# execution start

case $1 in
    install-deps)
        update_repos
        install_deps
        download_install_script
        ;;

    build-dmd)
        install_and_activate_compiler dmd "$DMD_VERSION"
        dmd --version
        dub --version

        #use_lu_master
        #use_dialect_master

        #time build dmd x86 "" --build-mode=singleFile  # no 32-bit libs?
        time build dmd x86_64 "" --build-mode=singleFile
        ;;

    build-ldc)
        install_and_activate_compiler ldc "$LDC_VERSION"
        ldc --version
        dub --version

        #use_lu_master
        #use_dialect_master

        #time build ldc x86 lowmem  # no 32-bit libs?
        time build ldc x86_64 lowmem
        ;;

    *)
        echo "Unknown command: $1";
        exit 1;
        ;;
esac

exit 0
