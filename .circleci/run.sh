#!/bin/bash

set -uexo pipefail

#DMD_VERSION="2.098.0"
#LDC_VERSION="1.28.0"
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
    local i url urls

    urls=( "https://dlang.org/install.sh" "https://nightlies.dlang.org/install.sh" )

    for i in {0..4}; do
        [[ $i = 0 ]] || sleep $((i*3))

        for url in "${urls[@]}"; do
            if curl -fsS -A "$CURL_USER_AGENT" --max-time 5 "$url" -O; then
                return
            fi
        done
    done

    echo 'Failed to download install script' 1>&2
    exit 1
}

install_and_activate_compiler() {
    local compiler compiler_version_ext compiler_build

    compiler="$1"
    [[ "$2" ]] && compiler_version_ext="-$2" || compiler_version_ext=""
    compiler_build="${compiler}${compiler_version_ext}"

    source "$(CURL_USER_AGENT=\"$CURL_USER_AGENT\" bash install.sh "$compiler_build" --activate)"
}

clone_and_add() {
    local repo;

    repo="$1"

    if [[ ! -d "$repo" ]]; then
        git clone "https://github.com/zorael/${repo}.git"
        dub add-local "$repo"
    fi
}

build() {
    local compiler_switch arch_switch build_ext

    compiler_switch="--compiler=$1"
    arch_switch="--arch=$2"
    [[ "$3" ]] && build_ext="-$3" || build_ext=""

    shift 2  # shift away compiler and arch
    shift 1 || true  # shift away build extension iff supplied

    time dub test  "$compiler_switch" "$arch_switch" "$@"                     -c "unittest${build_ext}"
    time dub build "$compiler_switch" "$arch_switch" "$@" --nodeps -b debug   -c "application${build_ext}"
    time dub build "$compiler_switch" "$arch_switch" "$@" --nodeps -b debug   -c "dev${build_ext}"
    time dub build "$compiler_switch" "$arch_switch" "$@" --nodeps -b release -c "dev${build_ext}"
}

# execution start

case $1 in
    install-deps)
        update_repos
        install_deps
        download_install_script
        ;;

    build-dmd)
        install_and_activate_compiler dmd #"$DMD_VERSION"
        dmd --version
        dub --version

        #clone_and_add lu
        #clone_and_add dialect

        time build dmd x86_64 lowmem
        ;;

    build-ldc)
        install_and_activate_compiler ldc #"$LDC_VERSION"
        ldc2 --version
        dub --version

        #clone_and_add lu
        #clone_and_add dialect

        time build ldc2 x86_64 lowmem
        ;;

    *)
        echo "Unknown command: $1";
        exit 1;
        ;;
esac

exit 0
