#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

binary="$work_root/bin/libmpv-opengl-smoke"
build="$work_root/build-mpv-macos-${MPV_COMMIT:0:12}"
[[ -x "$binary" ]] || "$script_dir/build-macos.sh"

export DYLD_LIBRARY_PATH="$build:$prefix_root/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
exec "$binary" "$@"
