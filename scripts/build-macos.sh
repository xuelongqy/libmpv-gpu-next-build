#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

[[ $(uname -s) == Darwin ]] || { echo "macOS is required" >&2; exit 2; }
require_command sdl2-config
"$script_dir/build-libplacebo.sh"

build="$work_root/build-mpv-macos-${MPV_COMMIT:0:12}"
export PKG_CONFIG_PATH="$prefix_root/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export DYLD_LIBRARY_PATH="$prefix_root/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
setup_meson "$source_root/mpv" "$build" \
    -Ddefault_library=shared \
    -Dlibmpv=true \
    -Dcplayer=false \
    -Dtests=true \
    -Dgl=enabled \
    -Dplain-gl=enabled \
    -Dvideotoolbox-gl=enabled \
    -Dcocoa=enabled \
    -Dswift-build=enabled \
    -Dmacos-cocoa-cb=disabled \
    -Dvulkan=enabled
meson compile -C "$build" -j "$jobs"
meson test -C "$build" --print-errorlogs

mkdir -p "$work_root/bin"
cc -x objective-c -std=gnu11 -Wall -Wextra \
    -I"$source_root/mpv/include" $(sdl2-config --cflags) \
    "$repo_root/smoke/desktop/main.m" \
    -L"$build" -lmpv $(sdl2-config --libs) \
    -framework Cocoa -framework QuartzCore -framework OpenGL \
    -o "$work_root/bin/libmpv-opengl-smoke"

libmpv=$(find "$build" -maxdepth 1 -name 'libmpv.*.dylib' -print -quit)
[[ -n "$libmpv" ]] || { echo "built libmpv was not found" >&2; exit 2; }
otool -L "$libmpv" | grep -F "$prefix_root" >/dev/null || {
    echo "libmpv is not linked to the pinned libplacebo prefix" >&2
    otool -L "$libmpv"
    exit 2
}
