#!/bin/bash

set -uexo pipefail

install_deps() {
    sudo apt update
    sudo apt install -y apt-transport-https

    sudo wget https://netcologne.dl.sourceforge.net/project/d-apt/files/d-apt.list \
        -O /etc/apt/sources.list.d/d-apt.list
    sudo apt update --allow-insecure-repositories

    # fingerprint 0xEBCF975E5BA24D5E
    sudo apt install -y --allow-unauthenticated --reinstall d-apt-keyring
    sudo apt update
    sudo apt install -y dmd-compiler dub

    git clone https://github.com/zorael/lu.git
    git clone https://github.com/zorael/dialect.git

    dub add-local lu
    dub add-local dialect
}

build() {
    local C A S ext

    C="--compiler=$1"
    A="--arch=$2"
    S="--build-mode=singleFile"
    [ "$2" == "x86" ] && ext="-32bit" || ext=""

    mkdir -p artifacts

    ## test
    time dub test $A $C $S
    S="$S --nodeps --force"

    time dub test $A $C $S -c vanilla


    ## debug
    time dub build $A $C $S -b debug -c vanilla
    mv kameloso artifacts/kameloso-vanilla${ext}

    time dub build $A $C $S -b debug -c full
    mv kameloso artifacts/kameloso${ext}

    time dub build $A $C $S -b debug -c dev
    mv kameloso artifacts/kameloso-dev${ext}


    ## plain
    time dub build $A $C $S -b plain -c vanilla || true
    mv kameloso artifacts/kameloso-plain-vanilla${ext} || \
        touch artifacts/kameloso-plain-vanilla${ext}.failed

    time dub build $A $C $S -b plain -c full || true
    mv kameloso artifacts/kameloso-plain${ext} || \
        touch artifacts/kameloso-plain${ext}.failed

    time dub build $A $C $S -b plain -c dev || true
    mv kameloso artifacts/kameloso-plain-dev${ext} || \
        touch artifacts/kameloso-plain-dev${ext}.failed


    ## release
    time dub build $A $C $S -b release -c vanilla || true
    mv kameloso artifacts/kameloso-release-vanilla${ext} || \
        touch artifacts/kameloso-release-vanilla${ext}.failed

    time dub build $A $C $S -b release -c full || true
    mv kameloso artifacts/kameloso-release${ext} || \
        touch artifacts/kameloso-release${ext}.failed

    time dub build $A $C $S -b release -c dev || true
    mv kameloso artifacts/kameloso-release-dev${ext} || \
        touch artifacts/kameloso-release-dev${ext}.failed
}

# execution start

case "$1" in
    install-deps)
        install_deps

        dub --version
        dmd --version
        #ldc --version
        ;;
    build)
        time build dmd x86
        time build dmd x86_64
        #time build ldc x86_64
        ;;
    *)
        echo "Unknown command: $1";
        exit 1;
        ;;
esac

exit 0
