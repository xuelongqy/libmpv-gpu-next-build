#!/usr/bin/env bash
set -euo pipefail
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE
check=false
if [[ $# == 1 && $1 == --check ]]; then check=true
elif [[ $# != 0 ]]; then echo 'usage: prepare.sh [--check]' >&2; exit 2; fi
native_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
export SOURCE_LOCK_FILE=${SOURCE_LOCK_FILE:-"$native_dir/versions.env"}
lock_dir=$(CDPATH='' cd -- "$(dirname -- "$SOURCE_LOCK_FILE")" && pwd)
export WORK_ROOT=${WORK_ROOT:-"$native_dir/../../.work/android-native"}
for prefix in MPV FFMPEG MPV_ANDROID LIBPLACEBO; do
    for suffix in REPOSITORY COMMIT PATCH PATCH_SHA256 PATCHED_TREE; do unset "${prefix}_${suffix}"; done
done
unset DEPENDENCIES_LOCK DEPENDENCIES_LOCK_SHA256
# shellcheck source=../../scripts/lib/common.sh
source "$native_dir/../../scripts/lib/common.sh"
for tool in git shasum tar python3; do require_command "$tool"; done
[[ $work_root != *[[:space:]]* ]] || { echo 'upstream Android build paths cannot contain whitespace' >&2; exit 2; }
mkdir -p "$work_root"
work_root=$(CDPATH='' cd -- "$work_root" && pwd -P)
android_root="$work_root/mpv-android"
deps="$android_root/buildscripts/deps"

checksum() { local sum; sum=$(shasum -a 256 "$1"); [[ ${sum%% *} == "$2" ]]; }

# Reuse the native FFmpeg check: verify real contents in a separate index.
verify_tree() (
    source_dir=$1; base=$2; expected=$3
    [[ ! -L $source_dir && $(git -C "$source_dir" rev-parse --show-toplevel) == "$source_dir" ]]
    git -C "$source_dir" diff --cached --quiet --ita-visible-in-index "$base" -- || {
        echo "staged source edits: $source_dir" >&2; exit 2;
    }
    [[ -z $(git -C "$source_dir" ls-files --others --exclude-standard) ]] || {
        echo "untracked source edits: $source_dir" >&2; exit 2;
    }
    temporary=$(mktemp -d "${TMPDIR:-/tmp}/android-native-tree.XXXXXX")
    trap 'rm -f -- "$temporary/index" "$temporary/index.lock"; rmdir -- "$temporary"' EXIT
    GIT_INDEX_FILE="$temporary/index" git -C "$source_dir" read-tree "$base"
    GIT_INDEX_FILE="$temporary/index" git -C "$source_dir" add -u
    [[ $(GIT_INDEX_FILE="$temporary/index" git -C "$source_dir" write-tree) == "$expected" ]] || {
        echo "source tree mismatch; preserving local edits: $source_dir" >&2; exit 2;
    }
)

prepare_git() {
    local name=$1 repository=$2 commit=$3 destination=$4 patch=${5:-} expected=${6:-}
    [[ $commit =~ ^[0-9a-f]{40}$ ]] || { echo "invalid source SHA: $name" >&2; exit 2; }
    if [[ ! -d $destination/.git ]]; then
        [[ $check == false ]] || { echo "missing source: $destination" >&2; exit 2; }
        ensure_checkout "$name" "$repository" "$commit" "$destination"
    fi
    [[ ! -L $destination && $(git -C "$destination" rev-parse HEAD) == "$commit" ]] || {
        echo "source HEAD mismatch: $destination" >&2; exit 2;
    }
    if [[ $name == ffmpeg || $name == libass ]]; then
        # These upstream sources do not ignore mpv-android's build directories.
        for build_dir in /_build_armv7l/ /_build_arm64/; do
            if ! git -C "$destination" check-ignore -q "${build_dir#/}"; then
                printf '%s\n' "$build_dir" >> "$destination/.git/info/exclude"
            fi
        done
    fi
    local base
    base=$(git -C "$destination" rev-parse 'HEAD^{tree}')
    if [[ -z $patch ]]; then
        verify_tree "$destination" "$commit" "$base"
    elif [[ $check == false && -z $(git -C "$destination" status --porcelain) ]]; then
        verify_tree "$destination" "$commit" "$base"
        git -C "$destination" apply --check "$patch"
        # Check the declared result before changing the source.
        (
            temporary=$(mktemp -d "${TMPDIR:-/tmp}/android-native-patch.XXXXXX")
            trap 'rm -f -- "$temporary/index" "$temporary/index.lock"; rmdir -- "$temporary"' EXIT
            GIT_INDEX_FILE="$temporary/index" git -C "$destination" read-tree "$commit"
            GIT_INDEX_FILE="$temporary/index" git -C "$destination" apply --cached "$patch"
            [[ $(GIT_INDEX_FILE="$temporary/index" git -C "$destination" write-tree) == "$expected" ]] || {
                echo "declared patched tree does not match the patch: $name" >&2; exit 2;
            }
        )
        git -C "$destination" apply "$patch"
        verify_tree "$destination" "$commit" "$expected"
    else
        verify_tree "$destination" "$commit" "$expected"
    fi
    printf 'SOURCE_READY=%s HEAD=%s\n' "$name" "$commit"
}

verify_submodules() {
    local directory=$1 missing=$2
    git -C "$directory" submodule status --cached --recursive | while read -r ref path rest; do
        ref=${ref#[-+U]}
        if [[ ! -e $directory/$path/.git && $missing == allow ]]; then continue; fi
        [[ $(git -C "$directory/$path" rev-parse HEAD) == "$ref" ]] || {
            echo "submodule HEAD mismatch; preserving $directory/$path" >&2; exit 2;
        }
        verify_tree "$directory/$path" "$ref" "$(git -C "$directory/$path" rev-parse 'HEAD^{tree}')"
    done
}

for prefix in MPV FFMPEG MPV_ANDROID; do
    for suffix in REPOSITORY COMMIT PATCH PATCH_SHA256 PATCHED_TREE; do
        key="${prefix}_${suffix}"
        [[ -n ${!key:-} ]] || { echo "missing source lock: $key" >&2; exit 2; }
    done
    key="${prefix}_COMMIT"; [[ ${!key} =~ ^[0-9a-f]{40}$ ]]
    key="${prefix}_PATCHED_TREE"; [[ ${!key} =~ ^[0-9a-f]{40}$ ]]
    key="${prefix}_PATCH"; patch="$lock_dir/${!key}"
    key="${prefix}_PATCH_SHA256"; [[ ${!key} =~ ^[0-9a-f]{64}$ ]]
    checksum "$patch" "${!key}" || { echo "patch checksum mismatch: $patch" >&2; exit 2; }
done
[[ ${LIBPLACEBO_COMMIT:-} =~ ^[0-9a-f]{40}$ && -n ${LIBPLACEBO_REPOSITORY:-} &&
   ${DEPENDENCIES_LOCK_SHA256:-} =~ ^[0-9a-f]{64}$ && -n ${DEPENDENCIES_LOCK:-} ]] || {
    echo 'invalid dependency lock' >&2; exit 2;
}
dependency_lock="$lock_dir/$DEPENDENCIES_LOCK"
checksum "$dependency_lock" "$DEPENDENCIES_LOCK_SHA256" || { echo 'dependency lock checksum mismatch' >&2; exit 2; }

prepare_git mpv-android "$MPV_ANDROID_REPOSITORY" "$MPV_ANDROID_COMMIT" "$android_root" \
    "$lock_dir/$MPV_ANDROID_PATCH" "$MPV_ANDROID_PATCHED_TREE"
prepare_git mpv "$MPV_REPOSITORY" "$MPV_COMMIT" "$deps/mpv" \
    "$lock_dir/$MPV_PATCH" "$MPV_PATCHED_TREE"
prepare_git ffmpeg "$FFMPEG_REPOSITORY" "$FFMPEG_COMMIT" "$deps/ffmpeg" \
    "$lock_dir/$FFMPEG_PATCH" "$FFMPEG_PATCHED_TREE"
prepare_git libplacebo "$LIBPLACEBO_REPOSITORY" "$LIBPLACEBO_COMMIT" "$deps/libplacebo"
if [[ $check == false ]]; then verify_submodules "$deps/libplacebo" allow
else verify_submodules "$deps/libplacebo" reject; fi
if [[ $check == false ]]; then git -C "$deps/libplacebo" submodule update --init --recursive; fi
verify_submodules "$deps/libplacebo" reject

while read -r name kind url revision digest tree; do
    [[ -z $name || $name == \#* ]] && continue
    [[ $name =~ ^[a-z0-9-]+$ && $url == https://* ]] || { echo 'invalid dependency row' >&2; exit 2; }
    if [[ $kind == git ]]; then
        prepare_git "$name" "$url" "$revision" "$deps/$name"
        if [[ $check == false ]]; then verify_submodules "$deps/$name" allow
        else verify_submodules "$deps/$name" reject; fi
        if [[ $check == false ]]; then git -C "$deps/$name" submodule update --init --recursive; fi
        verify_submodules "$deps/$name" reject
        continue
    fi
    [[ $digest =~ ^[0-9a-f]{64}$ && ($kind == file || ($kind == tar && $tree =~ ^[0-9a-f]{40}$)) ]] || {
        echo "invalid archive lock: $name" >&2; exit 2;
    }
    if [[ $kind == file ]]; then
        destination="$android_root/buildscripts/sdk/bin/gas-preprocessor.pl"
        if [[ -f $destination ]]; then checksum "$destination" "$digest"; continue; fi
    else
        destination="$deps/$name"
        if [[ -d $destination/.git ]]; then verify_tree "$destination" "$tree" "$tree"; continue; fi
        [[ ! -e $destination ]] || { echo "unmanaged dependency; preserving $destination" >&2; exit 2; }
    fi
    [[ $check == false ]] || { echo "missing dependency: $destination" >&2; exit 2; }
    cache="$work_root/downloads/$name.archive"
    mkdir -p "$work_root/downloads"
    if [[ ! -f $cache ]]; then "$repo_root/scripts/curl-wget.sh" "$url" -O "$cache"; fi
    checksum "$cache" "$digest" || { echo "archive checksum mismatch: $cache" >&2; exit 2; }
    if [[ $kind == file ]]; then
        mkdir -p "$(dirname -- "$destination")"
        cp "$cache" "$destination"
        chmod +x "$destination"
        continue
    fi
    mkdir "$destination"
    tar -xf "$cache" -C "$destination" --strip-components=1
    if [[ $name == mbedtls ]]; then
        # These are the same idempotent settings as mpv-android's mbedtls.sh.
        python3 "$destination/scripts/config.py" -f "$destination/include/mbedtls/mbedtls_config.h" set MBEDTLS_AESNI_C
        python3 "$destination/scripts/config.py" -f "$destination/include/mbedtls/mbedtls_config.h" set MBEDTLS_PLATFORM_DEV_RANDOM '"/dev/urandom"'
    fi
    git -C "$destination" init -q
    git -C "$destination" add -A
    [[ $(git -C "$destination" write-tree) == "$tree" ]] || {
        echo "prepared archive tree mismatch: $destination" >&2; exit 2;
    }
    # Release archives have no HEAD; their index records only the checked source.
    printf '_build*/\n*.o\n*.a\n*.so\n*.so.*\n' >> "$destination/.git/info/exclude"
    verify_tree "$destination" "$tree" "$tree"
done < "$dependency_lock"
printf 'ANDROID_NATIVE_SOURCES=PASS ROOT=%s\n' "$android_root"
