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

    dub test --compiler="$1" --build-mode=singleFile -c vanilla
    dub test --nodeps --compiler="$1" --build-mode=singleFile -c pluginless

    dub build --nodeps --compiler="$1" --build-mode=singleFile -b debug -c vanilla || true
    mv kameloso artifacts/kameloso-vanilla || true

    dub build --nodeps --compiler="$1" --build-mode=singleFile -b debug -c pluginless || true
    mv kameloso artifacts/kameloso-pluginless || true

    dub build --nodeps --compiler="$1" --build-mode=singleFile -b plain -c vanilla || true
    test -e kameloso && mv kameloso artifacts/kameloso-plain-vanilla || true

    dub build --nodeps --compiler="$1" --build-mode=singleFile -b plain -c pluginless || true
    test -e kameloso && mv kameloso artifacts/kameloso-plain-pluginless || true
}

# execution start

case "$1" in
    install-deps)
        install_deps;
        ;;
    build)
        build dmd;
        #build ldc2;  # doesn't support single build mode
        ;;
    *)
        echo "Unknown command: $1";
        exit 1;
        ;;
esac

exit 0
