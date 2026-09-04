#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

[[ $(uname -s) == Linux ]] || { echo "Linux is required" >&2; exit 2; }
"$script_dir/build-libplacebo.sh"

build="$work_root/build-mpv-linux-${MPV_COMMIT:0:12}"
export PKG_CONFIG_PATH="$prefix_root/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LD_LIBRARY_PATH="$prefix_root/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
setup_meson "$source_root/mpv" "$build" \
    -Ddefault_library=shared \
    -Dlibmpv=true \
    -Dcplayer=false \
    -Dtests=true \
    -Dgl=enabled \
    -Dplain-gl=enabled \
    -Dvulkan=disabled
meson compile -C "$build" -j "$jobs"
meson test -C "$build" --print-errorlogs
