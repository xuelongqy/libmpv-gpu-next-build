#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

"$script_dir/build-libplacebo.sh"
build="$work_root/build-mpv-sanitize-${MPV_COMMIT:0:12}"
export PKG_CONFIG_PATH="$prefix_root/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
if [[ $(uname -s) == Darwin ]]; then
    export DYLD_LIBRARY_PATH="$prefix_root/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
else
    export LD_LIBRARY_PATH="$prefix_root/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
setup_meson "$source_root/mpv" "$build" \
    -Ddefault_library=shared \
    -Dlibmpv=true \
    -Dcplayer=false \
    -Dtests=true \
    -Dcocoa=disabled \
    -Dswift-build=disabled \
    -Dmacos-cocoa-cb=disabled \
    -Davfoundation=disabled \
    -Dcoreaudio=disabled \
    -Dgl=enabled \
    -Dplain-gl=enabled \
    -Dvulkan=disabled \
    -Db_sanitize=address,undefined \
    -Db_lundef=false
meson compile -C "$build" -j "$jobs"
if [[ $(uname -s) == Darwin ]]; then
    default_asan_options=detect_leaks=0
else
    default_asan_options=detect_leaks=1
fi
ASAN_OPTIONS=${ASAN_OPTIONS:-$default_asan_options} \
UBSAN_OPTIONS=${UBSAN_OPTIONS:-print_stacktrace=1:halt_on_error=1} \
    meson test -C "$build" --suite libmpv --print-errorlogs
