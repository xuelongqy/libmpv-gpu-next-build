#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname -- "$0")/common.sh"
export PATH="$prefix_root/bin:$PATH"
case $(uname -s) in
    Darwin) export DYLD_LIBRARY_PATH="$prefix_root/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" ;;
    Linux) export LD_LIBRARY_PATH="$prefix_root/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ;;
esac
result=$(mktemp -d "$work_root/evidence/tests.XXXXXX")
failed=0
for library in libplacebo mpv; do
    if meson test -C "$work_root/build-$library" --print-errorlogs > "$result/$library.log" 2>&1; then
        echo "$library: PASS"
    else
        echo "$library: FAIL (see $result/$library.log)"
        failed=1
    fi
done
if ! meson test -C "$work_root/build-mpv" --suite libmpv --print-errorlogs > "$result/libmpv.log" 2>&1; then failed=1; fi
if ! "$work_root/bin/test-hdr-input" > "$result/input.log" 2>&1; then failed=1; fi
printf 'RESULT_DIR=%s\n' "$result"
exit "$failed"
