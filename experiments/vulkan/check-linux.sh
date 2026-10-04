#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname -- "$0")/common.sh"
for tool in python3 ffmpeg; do require_command "$tool"; done
[[ $(uname -s) == Linux ]] || { echo "Linux software Vulkan check only" >&2; exit 2; }
mkdir -p "$work_root/evidence"
result=$(mktemp -d "$work_root/evidence/linux-software.XXXXXX")
stage=prepare
finish() {
    local code=$?
    if ((code != 0)); then
        printf 'Failed stage: %s (exit %s)\n' "$stage" "$code" >&2
        for file in "$result/$stage.log" "$result/$stage.json"; do
            if [[ -f $file ]]; then
                printf '\n%s\n' "$file" >&2
                cat "$file" >&2
            fi
        done
    fi
    {
        printf '## Experimental Linux software Vulkan\n\n'
        printf 'mpv: %s; libplacebo: %s\n\n' "$MPV_COMMIT" "$LIBPLACEBO_COMMIT"
        printf 'Final stage: %s; exit code: %s\n\n' "$stage" "$code"
        printf 'Evidence: %s\n\n' "$result"
        printf 'Software-device checks only; no physical GPU or HDR-display claim.\n'
    } | tee "$result/status.md"
    if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then cat "$result/status.md" >> "$GITHUB_STEP_SUMMARY"; fi
}
trap finish EXIT
ffmpeg -nostdin -v error -f lavfi -i testsrc2=size=320x180:rate=24 \
    -t 6 -c:v ffv1 "$result/sdr.mkv"
run_case() {
    local name=$1 deadline=$2
    shift 2
    stage=$name
    python3 "$experiment_dir/case.py" "$result/$name" "$deadline" -- \
        bash "$experiment_dir/run.sh" "$@"
    grep -Fx 'VALIDATION_ERRORS=0' "$result/$name.log"
    grep -Fx 'RESULT=PASS' "$result/$name.log"
}
run_case probe 30 --probe
run_case fault 30 --fault
run_case contexts 180 --contexts 50
for mode in timeline binary window; do
    args=()
    if [[ $mode == timeline ]]; then args+=(--timeline); fi
    if [[ $mode == window ]]; then args+=(--window); fi
    run_case "$mode" 30 "${args[@]}" --width 320 --height 180 \
        --capture "$result/$mode.ppm" --screenshot "$result/$mode.png" "$result/sdr.mkv"
    stage="$mode-pixels"
    python3 "$experiment_dir/case.py" "$result/$stage" 20 -- \
        python3 "$experiment_dir/compare-sdr.py" "$result" --pair "$mode.ppm" "$mode.png"
done
for mode in timeline window; do
    args=(--timeline)
    if [[ $mode == window ]]; then args=(--window); fi
    run_case "$mode-lifecycle" 300 "${args[@]}" --stress \
        --screenshot "$result/$mode-life.png" "$result/sdr.mkv"
    for n in {0..19}; do
        printf -v frame '%02d' "$n"
        stage="$mode-skip-$frame"
        python3 "$experiment_dir/case.py" "$result/$stage" 20 -- \
            python3 "$experiment_dir/compare-sdr.py" "$result" --pair \
            "$mode-life.png-skip-$frame.ppm" "$mode-life.png-skip-$frame.png"
    done
done
stage=complete
