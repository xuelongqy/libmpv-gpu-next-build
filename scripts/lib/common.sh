#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../../versions.env
source "$repo_root/versions.env"

work_root=${WORK_ROOT:-"$repo_root/.work"}
source_root="$work_root/src"
prefix_root="$work_root/prefix-${LIBPLACEBO_COMMIT:0:12}"
jobs=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)}

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "missing required command: $1" >&2
        exit 2
    }
}

ensure_checkout() {
    local name=$1 repository=$2 commit=$3 destination=$4
    local created=false

    if [[ ! -d "$destination/.git" ]]; then
        if [[ -e "$destination" ]]; then
            echo "$destination exists but is not a Git checkout" >&2
            exit 2
        fi
        mkdir -p "$(dirname -- "$destination")"
        git clone --filter=blob:none --no-checkout "$repository" "$destination"
        created=true
    fi

    if [[ "$created" == false &&
          -n "$(git -C "$destination" status --porcelain)" ]]; then
        echo "$name checkout is dirty: $destination" >&2
        exit 2
    fi

    git -C "$destination" remote set-url origin "$repository"
    git -C "$destination" fetch --prune --tags origin
    git -C "$destination" checkout --detach "$commit"

    local actual
    actual=$(git -C "$destination" rev-parse HEAD)
    if [[ "$actual" != "$commit" ]]; then
        echo "$name checkout mismatch: expected $commit, got $actual" >&2
        exit 2
    fi
}

setup_meson() {
    local source=$1 build=$2
    shift 2
    if [[ -f "$build/meson-private/coredata.dat" ]]; then
        meson setup --wipe "$build" "$source" "$@"
    else
        meson setup "$build" "$source" "$@"
    fi
}
