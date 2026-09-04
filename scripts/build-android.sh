#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

"$script_dir/prepare-android.sh"
android_root="$work_root/mpv-android"
build_bash=$(command -v bash)
if ! "$build_bash" -c 'declare -g value=1' 2>/dev/null; then
    require_command brew
    build_bash="$(brew --prefix bash)/bin/bash"
    [[ -x "$build_bash" ]] || {
        echo "mpv-android requires Bash 4 or newer" >&2
        exit 2
    }
fi
(
    cd "$android_root/buildscripts"
    "$build_bash" ./buildall.sh --arch arm64
)

libmpv="$android_root/buildscripts/prefix/arm64/lib/libmpv.so"
[[ -f "$libmpv" ]] || { echo "Android arm64 libmpv was not produced" >&2; exit 2; }
apk="$android_root/app/build/outputs/apk/default/debug/app-default-arm64-v8a-debug.apk"
[[ -f "$apk" ]] || { echo "Android arm64 smoke APK was not produced" >&2; exit 2; }
printf 'Android arm64 source validation passed:\n  %s\n  %s\n' "$libmpv" "$apk"
