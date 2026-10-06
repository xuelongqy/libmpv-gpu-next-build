#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname -- "$0")/common.sh"
ffmpeg_source=${IOS_FFMPEG_SOURCE:-"$source_root/ffmpeg-ios"}
if [[ -z ${IOS_FFMPEG_SOURCE:-} ]]; then
    ensure_checkout ffmpeg https://github.com/FFmpeg/FFmpeg.git \
        bf1b838f2ab88b4f8fd83443325c782ea0e0f7fa "$ffmpeg_source"
fi
[[ $(git -C "$ffmpeg_source" rev-parse HEAD) == bf1b838f2ab88b4f8fd83443325c782ea0e0f7fa &&
   -z $(git -C "$ffmpeg_source" status --porcelain) ]] || {
    echo "FFmpeg source is dirty or has the wrong commit: $ffmpeg_source" >&2
    exit 2
}
mkdir -p "$ios_work/build-ffmpeg"
cd "$ios_work/build-ffmpeg"
"$ffmpeg_source/configure" --prefix="$prefix" \
    --target-os=darwin --arch=aarch64 --enable-cross-compile \
    --cc="$(xcrun --sdk "$sdk_name" --find clang)" \
    --cxx="$(xcrun --sdk "$sdk_name" --find clang++)" \
    --ar="$(xcrun --sdk "$sdk_name" --find ar)" \
    --ranlib="$(xcrun --sdk "$sdk_name" --find ranlib)" --sysroot="$sdk" \
    --extra-cflags="-target $target -isysroot $sdk" \
    --extra-ldflags="-target $target -isysroot $sdk" \
    --disable-everything --disable-autodetect --disable-network --disable-doc \
    --disable-programs --disable-avdevice --disable-metal \
    --enable-static --disable-shared --enable-pic --enable-zlib \
    --enable-decoder=h264,hevc,png,aac,ac3,eac3,pcm_s16le \
    --enable-encoder=png --enable-parser=h264,hevc,aac,ac3 \
    --enable-demuxer=matroska,mov,image2 --enable-protocol=file \
    --enable-filter=buffer,buffersink,abuffer,abuffersink,format,scale,null,anull,aresample \
    --enable-pthreads --enable-videotoolbox \
    --enable-hwaccel=h264_videotoolbox,hevc_videotoolbox
grep -Fx '#define CONFIG_PNG_ENCODER 1' config_components.h
make -j "$jobs"
make install
