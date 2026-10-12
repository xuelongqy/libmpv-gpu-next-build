#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 1 ]]; then
    echo 'usage: prepare-ffmpeg.sh FFMPEG_SOURCE' >&2
    exit 2
fi
experiment_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=versions.env
source "$experiment_dir/versions.env"
if [[ -z ${FFMPEG_PATCH:-} ||
      ! ${FFMPEG_COMMIT:-} =~ ^[0-9a-f]{40}$ ||
      ! ${FFMPEG_PATCH_SHA256:-} =~ ^[0-9a-f]{64}$ ||
      ! ${FFMPEG_PATCHED_TREE:-} =~ ^[0-9a-f]{40}$ ]]; then
    echo 'invalid FFmpeg source/patch lock' >&2
    exit 2
fi
ffmpeg_source=$(CDPATH='' cd -- "$1" && pwd -P)
source_top=$(git -C "$ffmpeg_source" rev-parse --show-toplevel)
if [[ "$source_top" != "$ffmpeg_source" ]]; then
    echo "expected the FFmpeg checkout root: $ffmpeg_source" >&2
    exit 2
fi
actual=$(git -C "$ffmpeg_source" rev-parse HEAD)
if [[ "$actual" != "$FFMPEG_COMMIT" ]]; then
    echo "FFmpeg checkout mismatch: expected $FFMPEG_COMMIT, got $actual" >&2
    exit 2
fi
status=$(git -C "$ffmpeg_source" status --porcelain)
if [[ -n "$status" ]]; then
    echo "FFmpeg checkout is dirty; refusing to overwrite it: $ffmpeg_source" >&2
    exit 2
fi
patch_file="$experiment_dir/$FFMPEG_PATCH"
checksum=$(shasum -a 256 "$patch_file")
if [[ "${checksum%% *}" != "$FFMPEG_PATCH_SHA256" ]]; then
    echo "FFmpeg patch checksum mismatch: $patch_file" >&2
    exit 2
fi
git -C "$ffmpeg_source" apply --check "$patch_file"

# Verify the complete result without changing the caller's index or source files.
check_dir=$(mktemp -d "${TMPDIR:-/tmp}/mpv-native-ffmpeg.XXXXXX")
trap 'rm -f -- "$check_dir/index" "$check_dir/index.lock"; rmdir -- "$check_dir"' EXIT
GIT_INDEX_FILE="$check_dir/index" git -C "$ffmpeg_source" read-tree "$FFMPEG_COMMIT"
GIT_INDEX_FILE="$check_dir/index" git -C "$ffmpeg_source" add -u
if ! GIT_INDEX_FILE="$check_dir/index" git -C "$ffmpeg_source" diff --cached --quiet "$FFMPEG_COMMIT" --; then
    echo "FFmpeg working tree differs from the locked base; refusing to overwrite it: $ffmpeg_source" >&2
    exit 2
fi
GIT_INDEX_FILE="$check_dir/index" git -C "$ffmpeg_source" apply --cached "$patch_file"
tree=$(GIT_INDEX_FILE="$check_dir/index" git -C "$ffmpeg_source" write-tree)
if [[ "$tree" != "$FFMPEG_PATCHED_TREE" ]]; then
    echo "FFmpeg patched tree mismatch: expected $FFMPEG_PATCHED_TREE, got $tree" >&2
    exit 2
fi
git -C "$ffmpeg_source" apply "$patch_file"
printf 'FFMPEG_SOURCE_READY=1 BASE=%s PATCH_SHA256=%s TREE=%s\n' \
    "$FFMPEG_COMMIT" "$FFMPEG_PATCH_SHA256" "$tree"
