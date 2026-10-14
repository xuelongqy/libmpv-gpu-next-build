#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 1 || ($1 != armv7l && $1 != arm64) ]]; then
    echo 'usage: build.sh armv7l|arm64' >&2; exit 2
fi
arch=$1
native_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
export SOURCE_LOCK_FILE=${SOURCE_LOCK_FILE:-"$native_dir/versions.env"}
export WORK_ROOT=${WORK_ROOT:-"$native_dir/../../.work/android-native"}
unset ANDROID_NDK_VERSION ANDROID_NDK_REVISION ANDROID_SDK_PLATFORM ANDROID_BUILD_TOOLS ANDROID_API
# shellcheck source=../../scripts/lib/common.sh
source "$native_dir/../../scripts/lib/common.sh"
for tool in git python3 meson ninja pkg-config make java javac shasum; do require_command "$tool"; done
if [[ $(uname -s) == Darwin ]]; then
    require_command ginstall
    require_command gsed
fi
[[ ${ANDROID_API:-} == 23 && ${ANDROID_NDK_VERSION:-} == r29 &&
   ${ANDROID_NDK_REVISION:-} == 29.0.14206865 && ${ANDROID_SDK_PLATFORM:-} == 36 &&
   ${ANDROID_BUILD_TOOLS:-} == 36.0.0 ]] || { echo 'invalid Android tool lock' >&2; exit 2; }
sdk=${ANDROID_NATIVE_SDK:-${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}}
[[ -n $sdk && -d $sdk ]] || { echo 'set ANDROID_NATIVE_SDK to the installed Android SDK' >&2; exit 2; }
sdk=$(CDPATH='' cd -- "$sdk" && pwd -P)
ndk=${ANDROID_NATIVE_NDK:-"$sdk/ndk/$ANDROID_NDK_REVISION"}
[[ -d $ndk ]] || { echo "NDK $ANDROID_NDK_VERSION is missing; set ANDROID_NATIVE_NDK" >&2; exit 2; }
ndk=$(CDPATH='' cd -- "$ndk" && pwd -P)
[[ $(sed -n 's/^Pkg.Revision[[:space:]]*=[[:space:]]*//p' "$ndk/source.properties") == "$ANDROID_NDK_REVISION" ]] || {
    echo "NDK revision mismatch: $ndk" >&2; exit 2;
}
[[ -d $sdk/platforms/android-$ANDROID_SDK_PLATFORM && -d $sdk/build-tools/$ANDROID_BUILD_TOOLS ]] || {
    echo 'the locked SDK platform/build-tools are missing; nothing was installed' >&2; exit 2;
}
build_bash=$(command -v bash)
if ! "$build_bash" -c 'declare -g value=1' 2>/dev/null; then
    require_command brew
    build_bash="$(brew --prefix bash)/bin/bash"
fi
"$build_bash" -c 'declare -g value=1' || { echo 'mpv-android needs Bash 4+' >&2; exit 2; }
export WORK_ROOT
bash "$native_dir/prepare.sh"
work_root=$(CDPATH='' cd -- "$work_root" && pwd -P)
android_root="$work_root/mpv-android"
buildscripts="$android_root/buildscripts"
os=linux
[[ $(uname -s) == Darwin ]] && os=mac
for item in "android-ndk-$ANDROID_NDK_VERSION:$ndk" "android-sdk-$os:$sdk"; do
    name=${item%%:*}; target=${item#*:}; link="$buildscripts/sdk/$name"
    if [[ -e $link || -L $link ]]; then
        [[ -L $link && $(readlink "$link") == "$target" ]] || { echo "preserving unexpected SDK path: $link" >&2; exit 2; }
    else ln -s "$target" "$link"; fi
done
export GRADLE_USER_HOME=${GRADLE_USER_HOME:-"$work_root/gradle"}
mkdir -p "$work_root/evidence"
{
    java -version 2>&1
    meson --version
    "$ndk/ndk-build" --version
    cat "$ndk/source.properties"
    shasum -a 256 "$SOURCE_LOCK_FILE" "$(dirname -- "$SOURCE_LOCK_FILE")/$DEPENDENCIES_LOCK"
    printf 'ARCH=%s SDK=%s NDK=%s API=%s\n' "$arch" "$sdk" "$ndk" "$ANDROID_API"
} > "$work_root/evidence/tools-$arch.txt"
(
    cd "$buildscripts"
    "$build_bash" -e -o pipefail ./buildall.sh --arch "$arch" --only-deps
)
bash "$native_dir/prepare.sh" --check
prefix32=; prefix64=
[[ ! -f $buildscripts/prefix/armv7l/lib/libmpv.so ]] || prefix32="$buildscripts/prefix/armv7l"
[[ ! -f $buildscripts/prefix/arm64/lib/libmpv.so ]] || prefix64="$buildscripts/prefix/arm64"
(
    cd "$android_root"
    PREFIX32="$prefix32" PREFIX64="$prefix64" PREFIX_X64='' PREFIX_X86='' \
        "$ndk/ndk-build" -B -C app/src/main -j "$jobs"
    ANDROID_HOME="$sdk" ./gradlew --no-daemon -Pandroid.builder.sdkDownload=false assembleDefaultDebug
)
abi=armeabi-v7a
[[ $arch != arm64 ]] || abi=arm64-v8a
library="$buildscripts/prefix/$arch/lib/libmpv.so"
apk="$android_root/app/build/outputs/apk/default/debug/app-default-$abi-debug.apk"
[[ -s $library && -s $apk ]] || { echo 'candidate library/APK missing' >&2; exit 1; }
bash "$native_dir/prepare.sh" --check
shasum -a 256 "$library" "$buildscripts/prefix/$arch/lib/libavcodec.so" "$apk" \
    > "$work_root/evidence/artifacts-$arch.sha256"
printf 'ANDROID_NATIVE_BUILD=PASS ARCH=%s LIBMPV=%s APK=%s\n' "$arch" "$library" "$apk"
