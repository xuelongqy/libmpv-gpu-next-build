#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

"$script_dir/checkout.sh"
require_command meson
require_command ninja
require_command pkg-config

build="$work_root/build-libplacebo-${LIBPLACEBO_COMMIT:0:12}"
if [[ $(uname -s) == Darwin ]]; then
    default_vulkan=enabled
else
    default_vulkan=disabled
fi
libplacebo_vulkan=${LIBPLACEBO_VULKAN:-$default_vulkan}
meson_args=()
if pkg-config --exists dav1d; then
    dav1d_cflags=$(pkg-config --cflags-only-I dav1d)
    meson_args+=("-Dc_args=$dav1d_cflags" "-Dcpp_args=$dav1d_cflags")
fi
setup_meson "$source_root/libplacebo" "$build" \
    --prefix "$prefix_root" \
    --libdir lib \
    -Ddefault_library=shared \
    -Dopengl=enabled \
    -Dvulkan="$libplacebo_vulkan" \
    -Dd3d11=disabled \
    -Ddemos=false \
    -Dxxhash=disabled \
    -Dtests=true \
    "${meson_args[@]}"
meson compile -C "$build" -j "$jobs"
meson test -C "$build" --print-errorlogs
meson install -C "$build"
