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

    dub test --compiler="$1" --build-mode=singleFile -c pluginless
    mv kameloso* artifacts/

    dub test --compiler="$1" --build-mode=singleFile --nodeps -c vanilla
    mv kameloso* artifacts/

    dub build --compiler="$1" --build-mode=singleFile --nodeps -b debug -c pluginless
    mv kameloso* artifacts/

    dub build --compiler="$1" --build-mode=singleFile --nodeps -b debug -c vanilla
    mv kameloso* artifacts/
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
