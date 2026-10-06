#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname -- "$0")/common.sh"
export MACOS_SDK="$sdk"
export MACOS_SDK_VERSION
MACOS_SDK_VERSION=$(xcrun --sdk "$sdk_name" --show-sdk-version)
zlib_version=$(sed -n 's/^#define ZLIB_VERSION "\(.*\)"/\1/p' "$sdk/usr/include/zlib.h")
[[ -n $zlib_version ]] || { echo 'SDK zlib version unavailable' >&2; exit 2; }
printf 'Name: zlib\nDescription: iOS SDK zlib\nVersion: %s\nLibs: -lz\n' \
    "$zlib_version" > "$prefix/lib/pkgconfig/zlib.pc"
for name in vulkan libshaderc libass libfreetype libfribidi libharfbuzz libunibreak; do
    dest="$ios_work/kit-layout/$name/$kit_platform/thin/arm64"
    mkdir -p "$dest/include" "$dest/lib/pkgconfig"
    cp -R "$ios_work/deps/$name/include/." "$dest/include"
    if [[ $name == vulkan ]]; then
        cp "$ios_work/deps/$name/lib/MoltenVK.xcframework/$molten/libMoltenVK.a" "$dest/lib/"
    else
        cp -R "$ios_work/deps/$name/lib/$kit_platform/thin/arm64/lib/." "$dest/lib"
    fi
    for pc in "$ios_work/deps/$name/pkgconfig-example/$kit_platform/arm64/"*.pc; do
        sed "s|/path/to/workdir|$ios_work/kit-layout|g" "$pc" > "$dest/lib/pkgconfig/$(basename -- "$pc")"
    done
done
subsystem=ios
[[ $platform != sim ]] || subsystem=ios-simulator
sed -e "s|@CLANG@|$(xcrun --sdk "$sdk_name" --find clang)|g" \
    -e "s|@CLANGXX@|$(xcrun --sdk "$sdk_name" --find clang++)|g" \
    -e "s|@AR@|$(xcrun --sdk "$sdk_name" --find ar)|g" \
    -e "s|@STRIP@|$(xcrun --sdk "$sdk_name" --find strip)|g" \
    -e "s|@PKG_CONFIG@|$(command -v pkg-config)|g" -e "s|@SUBSYSTEM@|$subsystem|g" \
    -e "s|@TARGET@|$target|g" -e "s|@SDK@|$sdk|g" "$ios_dir/cross.ini.in" > "$ios_work/cross.ini"
for pair in "mpv $MPV_COMMIT" "libplacebo $LIBPLACEBO_COMMIT"; do
    read -r name commit <<< "$pair"
    [[ $(git -C "$source_root/$name" rev-parse HEAD) == "$commit" && \
       -z $(git -C "$source_root/$name" status --porcelain) ]] || {
        echo "wrong or dirty source: $source_root/$name" >&2; exit 2;
    }
done
setup_meson "$source_root/libplacebo" "$ios_work/build-placebo" \
    --cross-file "$ios_work/cross.ini" --prefix "$prefix" --libdir lib \
    --buildtype release --default-library static --auto-features disabled \
    -Dvulkan=enabled -Dvk-proc-addr=enabled -Dshaderc=enabled -Dglslang=disabled \
    -Dopengl=disabled -Dd3d11=disabled \
    -Dvulkan-registry="$source_root/libplacebo/3rdparty/Vulkan-Headers/registry/vk.xml" \
    -Ddovi=enabled -Dlibdovi=disabled -Dlcms=disabled -Ddemos=false -Dtests=false \
    -Dxxhash=disabled -Dunwind=disabled
meson compile -C "$ios_work/build-placebo" -j "$jobs"
meson install -C "$ios_work/build-placebo"
setup_meson "$source_root/mpv" "$ios_work/build-mpv" --cross-file "$ios_work/cross.ini" \
    --prefix "$prefix" --libdir lib --buildtype release --default-library static \
    --auto-features disabled -Dlibmpv=true -Dcplayer=false -Dtests=false \
    -Dgl=disabled -Dplain-gl=disabled -Dvulkan=enabled -Dvideotoolbox-pl=enabled \
    -Dcocoa=disabled -Dswift-build=disabled -Dcoreaudio=disabled \
    -Daudiounit=enabled -Davfoundation=disabled -Dlua=disabled
meson compile -C "$ios_work/build-mpv" -j "$jobs"
meson install -C "$ios_work/build-mpv"
echo "IOS_LIBRARY_BUILD=PASS PLATFORM=$platform"
