#!/bin/bash

set -uexo pipefail

install_deps() {
    sudo wget http://master.dl.sourceforge.net/project/d-apt/files/d-apt.list \
        -O /etc/apt/sources.list.d/d-apt.list
    sudo apt update

    # fingerprint 0xEBCF975E5BA24D5E
    sudo apt-get -y --allow-unauthenticated install --reinstall d-apt-keyring
    sudo apt update
    sudo apt install dmd-compiler dub

    #sudo apt install ldc
}

build() {
    mkdir -p artifacts
    ARGS="--compiler=$1 --build-mode=singleFile"

    ## test
    dub test $ARGS -c colours+web
    ARGS="$ARGS --nodeps --force"
    #dub test $ARGS -c pluginless
    dub test $ARGS -c vanilla


    ## debug
    dub build $ARGS -b debug -c colours+web
    mv kameloso artifacts/kameloso-debug

    #dub build $ARGS -b debug -c pluginless
    #mv kameloso artifacts/kameloso-debug-pluginless

    dub build $ARGS -b debug -c vanilla
    mv kameloso artifacts/kameloso-debug-vanilla


    ## plain
    dub build $ARGS -b plain -c colours+web || true
    mv kameloso artifacts/kameloso-plain || true

    #dub build $ARGS -b plain -c pluginless || true
    #mv kameloso artifacts/kameloso-plain-pluginless || true

    dub build $ARGS -b plain -c vanilla || true
    mv kameloso artifacts/kameloso-plain-vanilla || true


    ## release
    dub build $ARGS -b release -c colours+web || true
    mv kameloso artifacts/kameloso-release || true

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
