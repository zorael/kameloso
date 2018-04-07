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

    sudo apt install ldc
}

build() {
    mkdir -p artifacts
    dub test --compiler="$1"
    mv kameloso artifacts/kameloso-test

    dub build --compiler="$1" -b plain
    mv kameloso artifacts/kameloso-plain
}

# execution start

case "$1" in
    install-deps)
        install_deps;
        ;;
    build)
        build dmd;
        build ldc2;
        ;;
    *)
        echo "Unknown command: $1";
        exit 1;
        ;;
esac

exit 0
