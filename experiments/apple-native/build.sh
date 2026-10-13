#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 1 || ($1 != macos && $1 != ios) ]]; then
    echo 'usage: build.sh macos|ios' >&2; exit 2
fi
build_platform=$1
native_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
export SOURCE_LOCK_FILE="$native_dir/versions.env"
export WORK_ROOT=${WORK_ROOT:-"$native_dir/../../.work/apple-native"}
mkdir -p "$WORK_ROOT"
WORK_ROOT=$(cd -- "$WORK_ROOT" && pwd)
# shellcheck source=../vulkan/common.sh
source "$native_dir/../vulkan/common.sh"
[[ $(uname -s) == Darwin ]] || { echo 'Apple native builds require macOS/Xcode' >&2; exit 2; }
for tool in git xcrun meson ninja pkg-config make shasum; do require_command "$tool"; done
if [[ $build_platform == ios ]]; then
    export IOS_PLATFORM=${IOS_PLATFORM:-device}
    [[ $IOS_PLATFORM == device ]] || { echo 'native iOS entry requires IOS_PLATFORM=device' >&2; exit 2; }
fi
unset FFMPEG_REPOSITORY FFMPEG_COMMIT FFMPEG_PATCH FFMPEG_PATCH_SHA256 FFMPEG_PATCHED_TREE
# shellcheck source=versions.env
source "$SOURCE_LOCK_FILE"
[[ -n ${FFMPEG_REPOSITORY:-} && ${FFMPEG_COMMIT:-} =~ ^[0-9a-f]{40}$ ]] || {
    echo 'invalid FFmpeg source lock' >&2; exit 2;
}
bash "$repo_root/scripts/checkout.sh"
ffmpeg_source="$source_root/ffmpeg"
if [[ ! -e $ffmpeg_source ]]; then
    ensure_checkout ffmpeg "$FFMPEG_REPOSITORY" "$FFMPEG_COMMIT" "$ffmpeg_source"
fi
if [[ -n $(git -C "$ffmpeg_source" status --porcelain) ]]; then
    bash "$native_dir/prepare-ffmpeg.sh" --check "$ffmpeg_source"
else
    bash "$native_dir/prepare-ffmpeg.sh" "$ffmpeg_source"
fi
mkdir -p "$work_root/evidence"
{
    xcrun --show-sdk-version
    meson --version
    pkg-config --version
    printf 'MPV=%s\nLIBPLACEBO=%s\nFFMPEG_BASE=%s\nFFMPEG_PATCH_SHA256=%s\nFFMPEG_TREE=%s\n' \
        "$MPV_COMMIT" "$LIBPLACEBO_COMMIT" "$FFMPEG_COMMIT" "$FFMPEG_PATCH_SHA256" "$FFMPEG_PATCHED_TREE"
} > "$work_root/evidence/tools-$build_platform.txt"
bash "$native_dir/../vulkan/ios/build-ffmpeg.sh" --apple-native "$build_platform"
if [[ $build_platform == ios ]]; then
    bash "$native_dir/../vulkan/ios/deps.sh"
    bash "$native_dir/../vulkan/ios/build-libs.sh" --apple-native
    # shellcheck source=../vulkan/ios/common.sh
    source "$native_dir/../vulkan/ios/common.sh"
    mpv_build="$ios_work/build-mpv"
    output="$ios_work/client"
else
    prefix="$work_root/macos/prefix"
    export PKG_CONFIG_PATH="$prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    pkg-config --exists shaderc vulkan libass || { echo 'shaderc, Vulkan and libass development files required' >&2; exit 2; }
    for name in libavcodec libavformat libavutil libavfilter; do
        [[ $(pkg-config --variable=pcfiledir "$name") == "$prefix/lib/pkgconfig" ]] || {
            echo "not using candidate FFmpeg: $name" >&2; exit 2;
        }
    done
    set --
    if pkg-config --exists dav1d; then
        dav1d_cflags=$(pkg-config --cflags-only-I dav1d)
        set -- "-Dc_args=$dav1d_cflags" "-Dcpp_args=$dav1d_cflags"
    fi
    setup_meson "$source_root/libplacebo" "$work_root/macos/build-placebo" \
        --prefix "$prefix" --libdir lib --buildtype debugoptimized -Ddefault_library=shared \
        -Dopengl=enabled -Dvulkan=enabled -Dd3d11=disabled -Dglslang=disabled -Dshaderc=enabled \
        -Dxxhash=disabled -Dunwind=disabled -Ddemos=false -Dtests=true "$@"
    meson compile -C "$work_root/macos/build-placebo" -j "$jobs"
    meson install -C "$work_root/macos/build-placebo"
    mpv_build="$work_root/macos/build-mpv"
    setup_meson "$source_root/mpv" "$mpv_build" --prefix "$prefix" --libdir lib \
        --auto-features disabled --buildtype debugoptimized -Ddefault_library=shared \
        -Dlibmpv=true -Dcplayer=true -Dtests=true -Dapple-native=enabled -Dlua=disabled \
        -Dcocoa=enabled -Dswift-build=enabled -Dcoreaudio=enabled -Davfoundation=enabled \
        -Dgl=enabled -Dplain-gl=enabled -Dvulkan=enabled
    meson compile -C "$mpv_build" -j "$jobs"
    meson install -C "$mpv_build"
    output="$work_root/macos/client"
fi
bash "$native_dir/build-client.sh" "$build_platform" "$source_root/mpv" "$mpv_build" "$output"
bash "$native_dir/prepare-ffmpeg.sh" --check "$ffmpeg_source"
printf 'NATIVE_BUILD=PASS PLATFORM=%s CLIENT=%s\n' "$build_platform" "$output"
