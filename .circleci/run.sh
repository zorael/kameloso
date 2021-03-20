#!/bin/bash

set -uexo pipefail

get_apt_list() {
    sudo wget https://netcologne.dl.sourceforge.net/project/d-apt/files/d-apt.list \
        -O /etc/apt/sources.list.d/d-apt.list
}

install_keyring() {
    sudo apt install -y --allow-unauthenticated --reinstall d-apt-keyring
}

install_dmd_dub() {
    sudo apt install -y --allow-unauthenticated dmd-compiler dub libcurl4-openssl-dev
}

install_deps() {
    sudo apt update
    sudo apt install -y apt-transport-https

    get_apt_list || get_apt_list || get_apt_list || get_apt_list || get_apt_list
    sudo apt update --allow-insecure-repositories

    # fingerprint 0xEBCF975E5BA24D5E
    install_keyring || install_keyring || install_keyring || install_keyring || install_keyring
    sudo apt update --allow-insecure-repositories
    install_dmd_dub || install_dmd_dub || install_dmd_dub || install_dmd_dub || install_dmd_dub

    #git clone https://github.com/zorael/lu.git
    #git clone https://github.com/zorael/dialect.git

    #dub add-local lu
    #dub add-local dialect
}

build() {
    local C A S

    C="--compiler=$1"
    A="--arch=$2"
    S="--build-mode=singleFile"
    #[ "$2" == "x86" ] && ext="-32bit" || ext=""

    mkdir -p artifacts

    ## test
    time dub test $A $C $S
    S="$S --nodeps --force"


    ## debug
    time dub build $A $C $S -b debug -c twitch
    mv kameloso artifacts/kameloso

    time dub build $A $C $S -b debug -c dev
    mv kameloso artifacts/kameloso-dev


    ## plain
    #time dub build $A $C $S -b plain -c twitch || true
    #mv kameloso artifacts/kameloso-plain || \
    #    touch artifacts/kameloso-plain.failed

    time dub build $A $C $S -b plain -c dev || true
    #mv kameloso artifacts/kameloso-plain-dev || \
    #    touch artifacts/kameloso-plain-dev.failed


    ## release
    time dub build $A $C $S -b release -c twitch || true
    mv kameloso artifacts/kameloso-release || \
        touch artifacts/kameloso-release.failed

    time dub build $A $C $S -b release -c dev || true
    mv kameloso artifacts/kameloso-release-dev || \
        touch artifacts/kameloso-release-dev.failed
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
        #time build dmd x86  # CircleCI does not seem to have the needed libs
        time build dmd x86_64
        #time build ldc x86_64
        ;;
    *)
        echo "Unknown command: $1";
        exit 1;
        ;;
esac

exit 0
