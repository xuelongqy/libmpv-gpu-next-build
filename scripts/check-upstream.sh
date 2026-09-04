#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

compat_root="$work_root/upstream-compat"

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
    git -C "$destination" checkout --detach "$commit"

    if ! git -C "$destination" merge --no-commit --no-ff upstream/master; then
        git -C "$destination" merge --abort || true
        echo "$name conflicts with current upstream master" >&2
        return 1
    fi
    git -C "$destination" merge --abort >/dev/null 2>&1 || true
    echo "$name can merge current upstream master"
}

check_merge mpv "$MPV_REPOSITORY" "$MPV_UPSTREAM" "$MPV_COMMIT" \
    "$compat_root/mpv"
check_merge libplacebo "$LIBPLACEBO_REPOSITORY" "$LIBPLACEBO_UPSTREAM" \
    "$LIBPLACEBO_COMMIT" "$compat_root/libplacebo"
