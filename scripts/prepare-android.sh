#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

require_command git
android_root="$work_root/mpv-android"
patch="$repo_root/smoke/android/mpv-android-render-api.patch"

if [[ ! -d "$android_root/.git" ]]; then
    if [[ -e "$android_root" ]]; then
        echo "$android_root exists but is not a Git checkout" >&2
        exit 2
    fi
    git clone --filter=blob:none "$MPV_ANDROID_REPOSITORY" "$android_root"
fi
git -C "$android_root" fetch --prune origin
git -C "$android_root" checkout --detach "$MPV_ANDROID_COMMIT"

if git -C "$android_root" apply --check "$patch" 2>/dev/null; then
    git -C "$android_root" apply "$patch"
elif ! git -C "$android_root" apply --check --reverse "$patch" 2>/dev/null; then
    echo "Android smoke checkout has changes other than the maintained patch" >&2
    exit 2
fi

buildscripts="$android_root/buildscripts"
download_proxy=${HTTPS_PROXY:-${https_proxy:-}}
(
    cd "$buildscripts"
    env -u ALL_PROXY -u all_proxy -u HTTP_PROXY -u http_proxy \
        -u HTTPS_PROXY -u https_proxy \
        DOWNLOAD_PROXY="$download_proxy" \
        IN_CI=1 WGET="$script_dir/curl-wget.sh" ./include/download-sdk.sh
    IN_CI=1 WGET="$script_dir/curl-wget.sh" ./include/download-deps.sh
)

pin_dependency() {
    local name=$1 repository=$2 commit=$3 destination="$buildscripts/deps/$1"
    [[ -d "$destination/.git" ]] || {
        echo "mpv-android did not create $name checkout" >&2
        exit 2
    }
    git -C "$destination" remote set-url origin "$repository"
    git -C "$destination" fetch --prune --tags origin
    git -C "$destination" checkout --detach "$commit"
    [[ $(git -C "$destination" rev-parse HEAD) == "$commit" ]] || exit 2
}

pin_dependency mpv "$MPV_REPOSITORY" "$MPV_COMMIT"
pin_dependency libplacebo "$LIBPLACEBO_REPOSITORY" "$LIBPLACEBO_COMMIT"
git -C "$buildscripts/deps/libplacebo" submodule update --init --recursive
