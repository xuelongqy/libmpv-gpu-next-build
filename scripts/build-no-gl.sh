#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

"$script_dir/build-libplacebo.sh"
build="$work_root/build-mpv-no-gl-${MPV_COMMIT:0:12}"
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
    -Dgl=disabled \
    -Dvulkan=disabled
meson compile -C "$build" -j "$jobs"
meson test -C "$build" --suite libmpv --print-errorlogs
