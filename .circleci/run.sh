#!/bin/bash

set -uexo pipefail

install_deps() {
    sudo apt update
    sudo apt install -y apt-transport-https
    sudo wget http://master.dl.sourceforge.net/project/d-apt/files/d-apt.list \
        -O /etc/apt/sources.list.d/d-apt.list
    sudo apt update

    # fingerprint 0xEBCF975E5BA24D5E
    sudo apt install -y --allow-unauthenticated --reinstall d-apt-keyring
    sudo apt install dmd-compiler dub

    #sudo apt install ldc
}

build() {
    mkdir -p artifacts
    ARGS="--compiler=$1 --build-mode=singleFile"

    ## test
    dub test $ARGS # -c full # not needed, unittest already includes more
    ARGS="$ARGS --nodeps --force"
    #dub test $ARGS -c pluginless
    dub test $ARGS -c vanilla


    ## debug
    dub build $ARGS -b debug -c full
    mv kameloso artifacts/kameloso

    dub build $ARGS -b debug -c twitch
    mv kameloso artifacts/kameloso-twitch

    #dub build $ARGS -b debug -c pluginless
    #mv kameloso artifacts/kameloso-pluginless

    dub build $ARGS -b debug -c vanilla
    mv kameloso artifacts/kameloso-vanilla


    ## plain
    dub build $ARGS -b plain -c full || true
    mv kameloso artifacts/kameloso-plain || true

    dub build $ARGS -b plain -c twitch || true
    mv kameloso artifacts/kameloso-plain-twitch || true

    #dub build $ARGS -b plain -c pluginless || true
    #mv kameloso artifacts/kameloso-plain-pluginless || true

    dub build $ARGS -b plain -c vanilla || true
    mv kameloso artifacts/kameloso-plain-vanilla || true


    ## release
    dub build $ARGS -b release -c full || true
    mv kameloso artifacts/kameloso-release || true

    dub build $ARGS -b release -c twitch || true
    mv kameloso artifacts/kameloso-release-twitch || true

    #dub build $ARGS -b release -c pluginless || true
    #mv kameloso artifacts/kameloso-release-pluginless || true

    dub build $ARGS -b release -c vanilla || true
    mv kameloso artifacts/kameloso-release-vanilla || true
}

# execution start

case "$1" in
    install-deps)
        install_deps;
        ;;
    build)
        build dmd;
        #build ldc2;  # 0.14.0; too old
        ;;
    *)
        echo "Unknown command: $1";
        exit 1;
        ;;
esac

exit 0
