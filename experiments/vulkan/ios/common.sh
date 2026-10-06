#!/usr/bin/env bash
set -euo pipefail
ios_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../common.sh
source "$ios_dir/../common.sh"
platform=${IOS_PLATFORM:-sim}
case $platform in
    sim) sdk_name=iphonesimulator; target=arm64-apple-ios15.0-simulator; kit_platform=isimulator; molten=ios-arm64_x86_64-simulator ;;
    device) sdk_name=iphoneos; target=arm64-apple-ios15.0; kit_platform=ios; molten=ios-arm64 ;;
    *) echo 'IOS_PLATFORM must be sim or device' >&2; exit 2 ;;
esac
sdk_name=${IOS_SDK:-$sdk_name}
ios_work="$work_root/ios-$platform"
prefix="$ios_work/prefix"
sdk=$(xcrun --sdk "$sdk_name" --show-sdk-path)
export sdk target molten
mkdir -p "$ios_work" "$prefix"
export PKG_CONFIG_PATH=
export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
for name in vulkan libshaderc libass libfreetype libfribidi libharfbuzz libunibreak; do
    export PKG_CONFIG_LIBDIR="$PKG_CONFIG_LIBDIR:$ios_work/kit-layout/$name/$kit_platform/thin/arm64/lib/pkgconfig"
done
