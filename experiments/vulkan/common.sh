#!/usr/bin/env bash
set -euo pipefail
experiment_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export SOURCE_LOCK_FILE=${SOURCE_LOCK_FILE:-"$experiment_dir/versions.env"}
export WORK_ROOT=${WORK_ROOT:-"$experiment_dir/../../.work/vulkan"}
# Do not inherit a missing field from a previous lock or the environment.
unset MPV_REPOSITORY MPV_COMMIT LIBPLACEBO_REPOSITORY LIBPLACEBO_COMMIT
# shellcheck source=../../scripts/lib/common.sh
source "$experiment_dir/../../scripts/lib/common.sh"
for name in MPV_REPOSITORY LIBPLACEBO_REPOSITORY; do
    [[ -n ${!name:-} ]] || { echo "missing lock field: $name" >&2; exit 2; }
done
for name in MPV_COMMIT LIBPLACEBO_COMMIT; do
    [[ ${!name:-} =~ ^[0-9a-f]{40}$ ]] || {
        echo "invalid full commit: $name" >&2; exit 2;
    }
done
