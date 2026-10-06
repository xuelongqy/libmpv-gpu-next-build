#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname -- "$0")/common.sh"
cache=${IOS_DEPENDENCY_CACHE:-$ios_work/downloads}
mkdir -p "$cache" "$ios_work/deps"
while read -r repository version archive name expected; do
    if [[ ! -f $cache/$archive ]]; then
        require_command gh
        gh release download "$version" -R "mpvkit/$repository" -p "$archive" --dir "$cache"
    fi
    actual=$(shasum -a 256 "$cache/$archive")
    [[ ${actual%% *} == "$expected" ]] || { echo "digest mismatch: $archive" >&2; exit 1; }
    if [[ ! -d $ios_work/deps/$name ]]; then
        mkdir "$ios_work/deps/$name"
        unzip -q "$cache/$archive" -d "$ios_work/deps/$name"
    fi
    printf 'DEPENDENCY=%s VERSION=%s SHA256=%s\n' "$name" "$version" "$expected"
done < "$ios_dir/deps.lock"
