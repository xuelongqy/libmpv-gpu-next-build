#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
native_platform=
if [[ $# == 2 && $1 == --apple-native && ($2 == macos || $2 == ios) ]]; then
    native_platform=$2
elif [[ $# != 0 ]]; then
    echo 'usage: build-ffmpeg.sh [--apple-native macos|ios]' >&2; exit 2
fi
if [[ $native_platform == macos ]]; then
    # shellcheck source=../common.sh
    source "$script_dir/../common.sh"
    prefix="$work_root/macos/prefix"
    ffmpeg_build="$work_root/macos/build-ffmpeg"
    platform_args=(--enable-shared --disable-static --extra-cflags=-mmacosx-version-min=11.0)
else
    # shellcheck source=common.sh
    source "$script_dir/common.sh"
    ffmpeg_build="$ios_work/build-ffmpeg"
    platform_args=(--target-os=darwin --arch=aarch64 --enable-cross-compile
        --cc="$(xcrun --sdk "$sdk_name" --find clang)"
        --cxx="$(xcrun --sdk "$sdk_name" --find clang++)"
        --ar="$(xcrun --sdk "$sdk_name" --find ar)"
        --ranlib="$(xcrun --sdk "$sdk_name" --find ranlib)" --sysroot="$sdk"
        --extra-cflags="-target $target -isysroot $sdk"
        --extra-ldflags="-target $target -isysroot $sdk" --enable-static --disable-shared)
fi
ffmpeg_source=${IOS_FFMPEG_SOURCE:-"$source_root/ffmpeg-ios"}
if [[ -n $native_platform ]]; then
    ffmpeg_source="$source_root/ffmpeg"
    bash "$script_dir/../../apple-native/prepare-ffmpeg.sh" --check "$ffmpeg_source"
elif [[ -z ${IOS_FFMPEG_SOURCE:-} ]]; then
    ensure_checkout ffmpeg https://github.com/FFmpeg/FFmpeg.git \
        bf1b838f2ab88b4f8fd83443325c782ea0e0f7fa "$ffmpeg_source"
fi
if [[ -z $native_platform ]]; then
    [[ $(git -C "$ffmpeg_source" rev-parse HEAD) == bf1b838f2ab88b4f8fd83443325c782ea0e0f7fa &&
       -z $(git -C "$ffmpeg_source" status --porcelain) ]] || {
        echo "FFmpeg source is dirty or has the wrong commit: $ffmpeg_source" >&2
        exit 2
    }
fi
mkdir -p "$ffmpeg_build"
subtitle_args=()
if [[ -n $native_platform ]]; then
    subtitle_args=("--enable-demuxer=srt,ass,sup" "--enable-decoder=ass,subrip,pgssub")
fi
cd "$ffmpeg_build"
"$ffmpeg_source/configure" --prefix="$prefix" \
    "${platform_args[@]}" \
    --disable-everything --disable-autodetect --disable-network --disable-doc \
    --disable-programs --disable-avdevice --disable-metal \
    --enable-pic --enable-zlib \
    --enable-decoder=h264,hevc,png,aac,ac3,eac3,pcm_s16le \
    --enable-encoder=png --enable-parser=h264,hevc,aac,ac3 \
    --enable-demuxer=matroska,mov,image2 --enable-protocol=file \
    --enable-filter=buffer,buffersink,abuffer,abuffersink,format,scale,null,anull,aresample \
    --enable-pthreads --enable-videotoolbox \
    --enable-hwaccel=h264_videotoolbox,hevc_videotoolbox "${subtitle_args[@]}"
grep -Fx '#define CONFIG_PNG_ENCODER 1' config_components.h
make -j "$jobs"
make install
