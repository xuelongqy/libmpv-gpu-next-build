#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname -- "$0")/common.sh"
[[ $(uname -s) == Darwin ]] || { echo 'iOS builds require macOS/Xcode' >&2; exit 2; }
for tool in git xcrun meson ninja pkg-config make unzip shasum; do require_command "$tool"; done
bash "$ios_dir/../checkout.sh"
bash "$ios_dir/deps.sh"
bash "$ios_dir/build-ffmpeg.sh"
bash "$ios_dir/build-libs.sh"
bash "$ios_dir/build-app.sh"
