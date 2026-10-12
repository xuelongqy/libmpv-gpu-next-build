#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 4 || ($1 != macos && $1 != ios) ]]; then
    echo 'usage: build-client.sh macos|ios MPV_SOURCE MPV_BUILD OUTPUT_DIRECTORY' >&2
    exit 2
fi
experiment_dir=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=versions.env
source "$experiment_dir/versions.env"
platform=$1
mpv_source=$(cd -- "$2" && pwd)
mpv_build=$(cd -- "$3" && pwd)
[[ $(git -C "$mpv_source" rev-parse HEAD) == "$MPV_COMMIT" &&
   -z $(git -C "$mpv_source" status --porcelain) ]] || {
    echo "mpv checkout is dirty or does not match the native source lock: $mpv_source" >&2
    exit 2
}
mkdir -p "$4"
output=$(cd -- "$4" && pwd)
flags=(-fobjc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations -O2
    -I"$mpv_source/include" -framework Foundation -framework AVFoundation
    -framework CoreMedia -framework CoreVideo -framework CoreGraphics -framework QuartzCore)
if [[ $platform == macos ]]; then
    test -f "$mpv_build/libmpv.2.dylib"
    xcrun clang "${flags[@]}" -mmacosx-version-min=14.4 "$experiment_dir/client/smoke.m" \
        "$mpv_build/libmpv.2.dylib" -framework Cocoa -framework OpenGL \
        -Wl,-export_dynamic -Wl,-rpath,"$mpv_build" -o "$output/native-smoke"
    otool -L "$output/native-smoke"
else
    test -f "$mpv_build/libmpv.a"
    # Use the caller's matching iOS pkg-config directories, not system libraries.
    : "${PKG_CONFIG_LIBDIR:?Set PKG_CONFIG_LIBDIR to the matching iOS static dependencies}"
    export PKG_CONFIG_PATH=
    read -r -a deps <<< "$(pkg-config --static --cflags --libs libass libavcodec libavfilter libavformat libavutil libswscale libswresample libplacebo)"
    app="$output/NativeSmoke.app"
    mkdir -p "$app"
    xcrun --sdk iphoneos clang -target arm64-apple-ios17.4 \
        -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" "${flags[@]}" \
        "$experiment_dir/client/smoke.m" "$experiment_dir/client/vk-target.m" \
        "$mpv_build/libmpv.a" "${deps[@]}" -framework UIKit -framework AudioToolbox \
        -lc++ -o "$app/NativeSmoke"
    cp "$experiment_dir/client/Info.plist" "$app/Info.plist"
    echo "Unsigned app: $app (sign and deploy separately; no media is bundled)"
fi
echo 'CLIENT_COMPILE=PASS (runtime acceptance is separate)'
