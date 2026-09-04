#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
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
    local name=$1 repository=$2 upstream=$3 upstream_branch=$4 commit=$5
    local destination=$6
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
    git -C "$destination" fetch --prune upstream "$upstream_branch"
    git -C "$destination" merge --abort >/dev/null 2>&1 || true
    git -C "$destination" checkout --detach --force "$commit"

    local upstream_commit
    upstream_commit=$(git -C "$destination" rev-parse \
        "upstream/$upstream_branch")
    printf 'compat: %s pinned=%s upstream=%s\n' \
        "$name" "$commit" "$upstream_commit"

    if ! git -C "$destination" merge --no-commit --no-ff \
        "upstream/$upstream_branch"; then
        printf 'compat: %s merge=conflict\n' "$name" >&2
        git -C "$destination" diff --name-only --diff-filter=U >&2 || true
        git -C "$destination" merge --abort || true
        return 1
    fi
    printf 'compat: %s merge=passed\n' "$name"
}

compat_mode=merge-only
[[ "$build_merged" == true ]] && compat_mode=merge-and-build
printf 'compat: mode=%s\n' "$compat_mode"
merge_status=0
check_merge mpv "$MPV_REPOSITORY" "$MPV_UPSTREAM" "$MPV_UPSTREAM_BRANCH" \
    "$MPV_COMMIT" "$compat_root/mpv" || merge_status=1
check_merge libplacebo "$LIBPLACEBO_REPOSITORY" "$LIBPLACEBO_UPSTREAM" \
    "$LIBPLACEBO_UPSTREAM_BRANCH" "$LIBPLACEBO_COMMIT" \
    "$compat_root/libplacebo" || merge_status=1
[[ "$merge_status" -eq 0 ]] || exit 1

if [[ "$build_merged" == true ]]; then
    [[ $(uname -s) == Linux ]] || {
        echo "--build currently requires Linux" >&2
        exit 2
    }
    require_command meson
    require_command ninja
    require_command pkg-config
    git -C "$compat_root/libplacebo" submodule sync --recursive
    git -C "$compat_root/libplacebo" submodule update --init --recursive

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
    echo 'compat: libplacebo build-tests=passed'

    export PKG_CONFIG_PATH="$prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    export LD_LIBRARY_PATH="$prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    meson setup "$mpv_build" "$compat_root/mpv" \
        -Ddefault_library=shared \
        -Dlibmpv=true -Dcplayer=false -Dtests=true \
        -Dgl=enabled -Dplain-gl=enabled -Dvulkan=disabled
    meson compile -C "$mpv_build" -j "$jobs"
    meson test -C "$mpv_build" --print-errorlogs
    echo 'compat: mpv build-tests=passed'
else
    echo 'compat: merged-build=skipped'
fi
