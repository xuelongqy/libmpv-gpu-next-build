#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 5 ]]; then
    echo "usage: $0 NAME RENDERER OUTPUT HWDEC FILE" >&2
    exit 2
fi

name=$1
renderer=$2
output=$3
hwdec=$4
file=$5
adb=${ADB:-adb}
package=is.xyz.mpv.gpunextsmoke
activity=is.xyz.mpv.MPVActivity
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
results="$repo_root/results"
mkdir -p "$results"

"$adb" shell am force-stop "$package"
"$adb" logcat -c
"$adb" shell am start -W \
    -a android.intent.action.VIEW \
    -d "file://$file" \
    -t video/x-matroska \
    -p "$package" \
    --es renderer "$renderer" \
    --es output "$output" \
    --es hwdec "$hwdec" \
    --es file "$file"
sleep 8
"$adb" logcat -d -v brief > "$results/$name.log"
"$adb" shell dumpsys SurfaceFlinger > "$results/$name-surfaceflinger.txt"
"$adb" exec-out screencap -p > "$results/$name.png"

rg -i 'Render API ready|Render API: .*failed|Using hardware decoding|Using software decoding|Decoder format|first video frame|shader.*failed|GL_INVALID|fatal' \
    "$results/$name.log" || true
