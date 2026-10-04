#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname -- "$0")/common.sh"
case $(uname -s) in
    Darwin)
        export DYLD_LIBRARY_PATH="$prefix_root/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
        # Loader, ICD and validation-layer settings belong to the caller.
        ;;
    MINGW*|MSYS*) export PATH="$prefix_root/bin:$PATH" ;;
    *) echo "unsupported host" >&2; exit 2 ;;
esac
exec "$work_root/bin/smoke" "$@"
