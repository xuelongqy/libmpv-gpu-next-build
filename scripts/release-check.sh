#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/.." && pwd)
versions_file="$repo_root/versions.env"

remote=false
tag_name=

usage() {
    echo "usage: $0 [--remote] [--tag TAG]" >&2
}

environment_error() {
    echo "release-check: $*" >&2
    exit 2
}

failures=0
invariant_error() {
    echo "release-check: $*" >&2
    failures=$((failures + 1))
}

while [[ $# -gt 0 ]]; do
    case $1 in
    --remote)
        remote=true
        shift
        ;;
    --tag)
        [[ $# -ge 2 && -n $2 ]] || { usage; exit 2; }
        tag_name=$2
        shift 2
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage
        exit 2
        ;;
    esac
done

command -v git >/dev/null 2>&1 || environment_error "missing required command: git"
[[ -f "$versions_file" ]] || environment_error "missing versions.env"
cd "$repo_root"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    environment_error "repository root is not a Git worktree"

# shellcheck source=../versions.env
source "$versions_file"

sha_variables=(
    MPV_COMMIT MPV_SNAPSHOT LIBPLACEBO_COMMIT LIBPLACEBO_SNAPSHOT
    MPV_ANDROID_COMMIT
)
branch_variables=(
    MPV_BRANCH MPV_UPSTREAM_BRANCH MPV_SNAPSHOT_BRANCH
    LIBPLACEBO_BRANCH LIBPLACEBO_UPSTREAM_BRANCH
    LIBPLACEBO_SNAPSHOT_BRANCH
)
required_variables=(
    MPV_REPOSITORY MPV_UPSTREAM LIBPLACEBO_REPOSITORY
    LIBPLACEBO_UPSTREAM MPV_ANDROID_REPOSITORY ANDROID_NDK_VERSION
)
source_lock_variables=(
    MPV_REPOSITORY MPV_UPSTREAM MPV_COMMIT MPV_SNAPSHOT
    LIBPLACEBO_REPOSITORY LIBPLACEBO_UPSTREAM LIBPLACEBO_COMMIT
    LIBPLACEBO_SNAPSHOT MPV_ANDROID_REPOSITORY MPV_ANDROID_COMMIT
    ANDROID_NDK_VERSION
)

print_source_lock() {
    local name
    for name in "${source_lock_variables[@]}"; do
        printf '%s=%s\n' "$name" "${!name:-}"
    done
}

for name in "${sha_variables[@]}"; do
    value=${!name:-}
    [[ $value =~ ^[0-9a-f]{40}$ ]] ||
        invariant_error "$name must be a full lowercase commit hash"
done

for name in "${branch_variables[@]}"; do
    [[ -n ${!name:-} ]] || invariant_error "$name must not be empty"
done

for name in "${required_variables[@]}"; do
    [[ -n ${!name:-} ]] || invariant_error "$name must not be empty"
done

if ! git diff --check; then
    invariant_error "unstaged changes fail git diff --check"
fi
if ! git diff --cached --check; then
    invariant_error "staged changes fail git diff --check"
fi
if [[ -n $(git status --porcelain --untracked-files=all) ]]; then
    invariant_error "worktree is not clean"
fi

while IFS= read -r -d '' path; do
    case $path in
    .work/*|results/*|*.a|*.aar|*.apk|*.class|*.dmg|*.dll|*.dylib|*.exe|\
    *.jar|*.log|*.mkv|*.mov|*.mp4|*.o|*.obj|*.png|*.ppm|*.so|*.tar|\
    *.tar.*|*.webm|*.zip)
        invariant_error "tracked build, media, or result artifact: $path"
        ;;
    esac
done < <(git ls-files -z)

tag_commit=
tag_object=
if [[ -n $tag_name ]]; then
    if ! git show-ref --verify --quiet "refs/tags/$tag_name"; then
        invariant_error "tag does not exist locally: $tag_name"
    elif [[ $(git cat-file -t "refs/tags/$tag_name") != tag ]]; then
        invariant_error "tag is not annotated: $tag_name"
    else
        tag_object=$(git rev-parse "refs/tags/$tag_name")
        tag_commit=$(git rev-parse "$tag_name^{}")
        if ! git cat-file -e "$tag_name:versions.env" 2>/dev/null; then
            invariant_error "$tag_name does not contain versions.env"
        else
            current_source_lock=$(print_source_lock)
            if ! tag_source_lock=$(
                # shellcheck disable=SC1090
                source <(git show "$tag_name:versions.env")
                print_source_lock
            ); then
                invariant_error "cannot read versions.env from $tag_name"
            elif [[ $tag_source_lock != "$current_source_lock" ]]; then
                invariant_error "$tag_name locks a different source combination"
            fi
        fi
    fi
fi

[[ $failures -eq 0 ]] || exit 1

head_commit=$(git rev-parse HEAD)
pinned_ci_url=
compat_ci_url=
remote_sha=

remote_ref() {
    local repository=$1 ref=$2 output
    local -a fields
    if ! output=$(git ls-remote "$repository" "$ref" 2>&1); then
        echo "release-check: cannot query $repository: $output" >&2
        exit 2
    fi
    [[ -n $output ]] || return 1
    read -r -a fields <<< "$output"
    remote_sha=${fields[0]}
}

check_branch_tip() {
    local label=$1 repository=$2 branch=$3 expected=$4
    if ! remote_ref "$repository" "refs/heads/$branch"; then
        invariant_error "$label branch is missing: $branch"
    elif [[ $remote_sha != "$expected" ]]; then
        invariant_error "$label branch tip is $remote_sha, expected $expected"
    fi
}

check_branch_exists() {
    local label=$1 repository=$2 branch=$3
    if ! remote_ref "$repository" "refs/heads/$branch" >/dev/null; then
        invariant_error "$label branch is missing: $branch"
    fi
}

check_ci_run() {
    local repository=$1 workflow=$2 label=$3 result_var=$4
    local data status conclusion url sha
    if ! data=$(gh run list --repo "$repository" --workflow "$workflow" \
        --branch main --commit "$head_commit" --limit 1 \
        --json status,conclusion,url,headSha \
        --jq 'if length == 0 then "" else .[0] | [.status, .conclusion, .url, .headSha] | @tsv end' \
        2>&1); then
        environment_error "cannot query $label CI: $data"
    fi
    if [[ -z $data ]]; then
        invariant_error "$label CI has no run for $head_commit"
        return
    fi
    IFS=$'\t' read -r status conclusion url sha <<< "$data"
    if [[ $sha != "$head_commit" || $status != completed ||
          $conclusion != success ]]; then
        invariant_error "$label CI is not successful: status=$status conclusion=$conclusion"
        return
    fi
    printf -v "$result_var" '%s' "$url"
}

if [[ $remote == true ]]; then
    command -v gh >/dev/null 2>&1 ||
        environment_error "missing required command for --remote: gh"

    check_branch_tip "build main" origin main "$head_commit"
    check_branch_tip "mpv maintained" "$MPV_REPOSITORY" "$MPV_BRANCH" \
        "$MPV_COMMIT"
    check_branch_tip "mpv snapshot" "$MPV_REPOSITORY" \
        "$MPV_SNAPSHOT_BRANCH" "$MPV_SNAPSHOT"
    check_branch_tip "libplacebo maintained" "$LIBPLACEBO_REPOSITORY" \
        "$LIBPLACEBO_BRANCH" "$LIBPLACEBO_COMMIT"
    check_branch_tip "libplacebo snapshot" "$LIBPLACEBO_REPOSITORY" \
        "$LIBPLACEBO_SNAPSHOT_BRANCH" "$LIBPLACEBO_SNAPSHOT"
    check_branch_exists "mpv upstream" "$MPV_UPSTREAM" \
        "$MPV_UPSTREAM_BRANCH"
    check_branch_exists "libplacebo upstream" "$LIBPLACEBO_UPSTREAM" \
        "$LIBPLACEBO_UPSTREAM_BRANCH"

    if [[ -n $tag_name && -n $tag_object ]]; then
        if ! remote_ref origin "refs/tags/$tag_name"; then
            invariant_error "tag does not exist remotely: $tag_name"
        elif [[ $remote_sha != "$tag_object" ]]; then
            invariant_error "$tag_name differs between local and remote"
        fi
    fi

    repository=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>&1) ||
        environment_error "cannot identify GitHub repository: $repository"
    check_ci_run "$repository" ci.yml "pinned-source" pinned_ci_url
    check_ci_run "$repository" upstream-compat.yml "upstream-compat" \
        compat_ci_url
fi

[[ $failures -eq 0 ]] || exit 1

echo 'release-check: passed'
printf '  main=%s\n' "$head_commit"
printf '  mpv=%s (%s)\n' "$MPV_COMMIT" "$MPV_BRANCH"
printf '  mpv-snapshot=%s (%s)\n' "$MPV_SNAPSHOT" \
    "$MPV_SNAPSHOT_BRANCH"
printf '  libplacebo=%s (%s)\n' "$LIBPLACEBO_COMMIT" \
    "$LIBPLACEBO_BRANCH"
printf '  libplacebo-snapshot=%s (%s)\n' "$LIBPLACEBO_SNAPSHOT" \
    "$LIBPLACEBO_SNAPSHOT_BRANCH"
if [[ -n $tag_name ]]; then
    printf '  tag=%s object=%s commit=%s\n' \
        "$tag_name" "$tag_object" "$tag_commit"
fi
if [[ $remote == true ]]; then
    printf '  pinned-source-ci=%s\n' "$pinned_ci_url"
    printf '  upstream-compat-ci=%s\n' "$compat_ci_url"
fi
