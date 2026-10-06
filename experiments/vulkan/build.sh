#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname -- "$0")/common.sh"
for tool in git meson ninja pkg-config cc; do require_command "$tool"; done
case $(uname -s) in
    Darwin) platform=macos ;;
    Linux) platform=linux ;;
    MINGW*|MSYS*) [[ ${MSYSTEM:-} == UCRT64 ]] || { echo "UCRT64 required" >&2; exit 2; }; platform=windows ;;
    *) echo "supported build hosts: macOS, Linux, Windows UCRT64" >&2; exit 2 ;;
esac
pkg-config --exists shaderc sdl2 vulkan libass libavcodec libavformat libavutil || {
    echo "missing development dependencies; see README (no automatic installation)" >&2; exit 2;
}
"$experiment_dir/checkout.sh"
mkdir -p "$work_root/bin" "$work_root/evidence"
work_root=$(cd "$work_root" && pwd)
prefix_root="$work_root/prefix-${LIBPLACEBO_COMMIT:0:12}"
{
    uname -a
    cc --version
    meson --version
    pkg-config --modversion shaderc sdl2 vulkan libass libavcodec
    printf 'MPV=%s\nLIBPLACEBO=%s\n' "$MPV_COMMIT" "$LIBPLACEBO_COMMIT"
} > "$work_root/evidence/tools.txt"
meson_prefix=$prefix_root
if [[ $platform == windows ]]; then meson_prefix=$(cygpath -m "$prefix_root"); fi
# Keep path-list entries in MSYS form so its native-process conversion works.
export PKG_CONFIG_PATH="$prefix_root/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
pl_build="$work_root/build-libplacebo"
cflags=()
if pkg-config --exists dav1d; then
    dav1d_cflags=$(pkg-config --cflags-only-I dav1d)
    cflags+=("-Dc_args=$dav1d_cflags" "-Dcpp_args=$dav1d_cflags")
fi
setup_meson "$source_root/libplacebo" "$pl_build" --prefix "$meson_prefix" --libdir lib \
    --buildtype debugoptimized -Ddefault_library=shared -Dopengl=enabled -Dvulkan=enabled \
    -Dd3d11=disabled -Dglslang=disabled -Dshaderc=enabled -Dxxhash=disabled \
    -Dunwind=disabled -Ddemos=false -Dtests=true "${cflags[@]}"
meson compile -C "$pl_build" -j "$jobs"
meson install -C "$pl_build"
mpv_args=()
native=()
link=()
if [[ $platform == macos ]]; then
    mpv_args+=(-Dvideotoolbox-gl=enabled -Dcocoa=enabled -Dswift-build=enabled -Dmacos-cocoa-cb=disabled)
    native=("$experiment_dir/smoke/macos.m")
    link+=(-framework Cocoa -framework QuartzCore -framework Metal)
elif [[ $platform == windows ]]; then
    native=("$experiment_dir/smoke/windows.c")
elif [[ $platform == linux ]]; then
    # Resolve the private libmpv's transitive dependencies at link time.
    link+=("-Wl,-rpath-link,$prefix_root/lib")
fi
setup_meson "$source_root/mpv" "$work_root/build-mpv" --prefix "$meson_prefix" --libdir lib \
    --buildtype debugoptimized -Ddefault_library=shared -Dlibmpv=true -Dcplayer=true \
    -Dtests=true -Dgl=enabled -Dplain-gl=enabled -Dvulkan=enabled "${mpv_args[@]}"
meson compile -C "$work_root/build-mpv" -j "$jobs"
meson install -C "$work_root/build-mpv"
test -f "$prefix_root/include/mpv/render_vk.h"
library="$prefix_root/lib/libmpv.2.dylib"
if [[ $platform == windows ]]; then library="$prefix_root/lib/libmpv.dll.a"; fi
if [[ $platform == linux ]]; then library="$prefix_root/lib/libmpv.so"; fi
test -f "$library"
for source in smoke test-hdr-input; do
    # Link the exact candidate, not an unrelated mpv found through SDL's -L.
    # shellcheck disable=SC2046
    cc -std=c11 -Wall -Wextra -Werror -O1 -g "$experiment_dir/smoke/$source.c" \
        "${native[@]}" -I"$prefix_root/include" "$library" \
        $(pkg-config --cflags --libs sdl2 vulkan) "${link[@]}" -pthread -lm \
        -o "$work_root/bin/$source"
done
if [[ $platform == macos ]]; then
    # shellcheck disable=SC2046
    cc -Wall -Wextra -Werror -O1 -g "$experiment_dir/smoke/test-metal-import.m" \
        $(pkg-config --cflags --libs vulkan) -framework Metal -framework Foundation \
        -o "$work_root/bin/test-metal-import"
    otool -L "$prefix_root/lib/libmpv.2.dylib" | tee "$work_root/evidence/linkage.txt"
    grep -F "$prefix_root/lib/libplacebo" "$work_root/evidence/linkage.txt"
elif [[ $platform == linux ]]; then
    LD_LIBRARY_PATH="$prefix_root/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        ldd "$library" | tee "$work_root/evidence/linkage.txt"
    grep -F "$prefix_root/lib/libplacebo" "$work_root/evidence/linkage.txt"
else
    objdump -p "$prefix_root/bin/libmpv-2.dll" > "$work_root/evidence/linkage.txt"
    placebo_dll=("$prefix_root"/bin/libplacebo-*.dll)
    [[ ${#placebo_dll[@]} == 1 && -f ${placebo_dll[0]} ]] || {
        echo "expected exactly one candidate libplacebo DLL" >&2; exit 1;
    }
    grep -F "$(basename -- "${placebo_dll[0]}")" "$work_root/evidence/linkage.txt"
fi
echo "BUILD=PASS (tests are separate: tests.sh)"
