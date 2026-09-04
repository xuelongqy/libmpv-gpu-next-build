#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

require_command git
ensure_checkout mpv "$MPV_REPOSITORY" "$MPV_COMMIT" "$source_root/mpv"
ensure_checkout libplacebo "$LIBPLACEBO_REPOSITORY" "$LIBPLACEBO_COMMIT" \
    "$source_root/libplacebo"
git -C "$source_root/libplacebo" submodule update --init --recursive

printf 'mpv=%s\nlibplacebo=%s\n' \
    "$(git -C "$source_root/mpv" rev-parse HEAD)" \
    "$(git -C "$source_root/libplacebo" rev-parse HEAD)"
