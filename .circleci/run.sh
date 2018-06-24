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

    # try first without singleFile, watch it crash and burn
    dub test --compiler="$1" -c vanilla || true
    dub build --nodeps --compiler="$1" -b debug -c vanilla || true

    # do the rest with singleFile
    dub test --compiler="$1" --build-mode=singleFile --parallel -c vanilla
    dub test --nodeps --compiler="$1" --build-mode=singleFile --parallel -c colours+web

    dub build --nodeps --compiler="$1" --build-mode=singleFile --parallel -b debug -c colours+web
    mv kameloso artifacts/kameloso

    dub build --nodeps --compiler="$1" --build-mode=singleFile --parallel -b debug -c vanilla
    mv kameloso artifacts/kameloso-vanilla

    dub build --nodeps --compiler="$1" --build-mode=singleFile --parallel -b plain -c colours+web || true
    test -e kameloso && mv kameloso artifacts/kameloso-plain || true

    dub build --nodeps --compiler="$1" --build-mode=singleFile --parallel -b plain -c vanilla || true
    test -e kameloso && mv kameloso artifacts/kameloso-plain-vanilla || true
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
