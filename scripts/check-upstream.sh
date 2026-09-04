#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

compat_root="$work_root/upstream-compat"
build_merged=false
if [[ ${1:-} == --build ]]; then
    build_merged=true
    shift
fi
[[ $# -eq 0 ]] || { echo "usage: $0 [--build]" >&2; exit 2; }

cleanup_merges() {
    git -C "$compat_root/mpv" merge --abort >/dev/null 2>&1 || true
    git -C "$compat_root/libplacebo" merge --abort >/dev/null 2>&1 || true
}
trap cleanup_merges EXIT

check_merge() {
    local name=$1 repository=$2 upstream=$3 commit=$4 destination=$5
    if [[ ! -d "$destination/.git" ]]; then
        mkdir -p "$(dirname -- "$destination")"
        git clone --filter=blob:none "$repository" "$destination"
    fi
    git -C "$destination" remote set-url origin "$repository"
    if git -C "$destination" remote get-url upstream >/dev/null 2>&1; then
        git -C "$destination" remote set-url upstream "$upstream"
    else
        git -C "$destination" remote add upstream "$upstream"
    fi
    git -C "$destination" fetch --prune origin
    git -C "$destination" fetch --prune upstream master
    git -C "$destination" merge --abort >/dev/null 2>&1 || true
    git -C "$destination" checkout --detach --force "$commit"

    if ! git -C "$destination" merge --no-commit --no-ff upstream/master; then
        git -C "$destination" merge --abort || true
        echo "$name conflicts with current upstream master" >&2
        return 1
    fi
    echo "$name can merge current upstream master"
}

check_merge mpv "$MPV_REPOSITORY" "$MPV_UPSTREAM" "$MPV_COMMIT" \
    "$compat_root/mpv"
check_merge libplacebo "$LIBPLACEBO_REPOSITORY" "$LIBPLACEBO_UPSTREAM" \
    "$LIBPLACEBO_COMMIT" "$compat_root/libplacebo"

if [[ "$build_merged" == true ]]; then
    [[ $(uname -s) == Linux ]] || {
        echo "--build currently requires Linux" >&2
        exit 2
    }
    require_command meson
    require_command ninja
    require_command pkg-config

    run_root=$(mktemp -d "$compat_root/build.XXXXXX")
    prefix="$run_root/prefix"
    placebo_build="$run_root/libplacebo"
    mpv_build="$run_root/mpv"
    meson_args=()
    if pkg-config --exists dav1d; then
        dav1d_cflags=$(pkg-config --cflags-only-I dav1d)
        meson_args+=("-Dc_args=$dav1d_cflags" "-Dcpp_args=$dav1d_cflags")
    fi

    meson setup "$placebo_build" "$compat_root/libplacebo" \
        --prefix "$prefix" --libdir lib \
        -Ddefault_library=shared \
        -Dopengl=enabled -Dvulkan=disabled -Dd3d11=disabled \
        -Ddemos=false -Dxxhash=disabled -Dtests=true \
        "${meson_args[@]}"
    meson compile -C "$placebo_build" -j "$jobs"
    meson test -C "$placebo_build" --print-errorlogs
    meson install -C "$placebo_build"

    export PKG_CONFIG_PATH="$prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    export LD_LIBRARY_PATH="$prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    meson setup "$mpv_build" "$compat_root/mpv" \
        -Ddefault_library=shared \
        -Dlibmpv=true -Dcplayer=false -Dtests=true \
        -Dgl=enabled -Dplain-gl=enabled -Dvulkan=disabled
    meson compile -C "$mpv_build" -j "$jobs"
    meson test -C "$mpv_build" --print-errorlogs
    echo "Merged upstream compatibility build passed"
fi
