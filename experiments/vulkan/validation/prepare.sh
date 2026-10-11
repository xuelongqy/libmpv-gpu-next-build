#!/usr/bin/env bash
set -euo pipefail
[[ $# == 1 ]] || { echo 'usage: prepare.sh OUTPUT_DIRECTORY' >&2; exit 2; }
# shellcheck source=../common.sh
source "$(dirname -- "$0")/../common.sh"
for tool in git cmp shasum; do require_command "$tool"; done
mkdir -p "$1"
validation_dir=$(cd -- "$1" && pwd)
ensure_checkout headers https://github.com/KhronosGroup/Vulkan-Headers.git \
    e3b1eec08173d6b825cd3ac88c885a63b621504a "$validation_dir/headers"
ensure_checkout loader https://github.com/KhronosGroup/Vulkan-Loader.git \
    5f157b62e333c63260d05d81bf66faa216ab0fb8 "$validation_dir/loader"
ensure_checkout layers https://github.com/KhronosGroup/Vulkan-ValidationLayers.git \
    e4786f7ce8f1319215eff0d938f4be4651cbb85d "$validation_dir/layers"
layer_source="$validation_dir/layers-metal-import"
patch_file="$experiment_dir/validation/metal-import-sync.patch"
if [[ ! -d $layer_source/.git ]]; then
    [[ ! -e $layer_source ]] || { echo "not a Git checkout: $layer_source" >&2; exit 2; }
    git clone --no-hardlinks --no-checkout "$validation_dir/layers" "$layer_source"
    git -C "$layer_source" checkout --detach e4786f7ce8f1319215eff0d938f4be4651cbb85d
fi
[[ $(git -C "$layer_source" rev-parse HEAD) == e4786f7ce8f1319215eff0d938f4be4651cbb85d ]] &&
    git -C "$layer_source" diff --cached --quiet &&
    [[ -z $(git -C "$layer_source" ls-files --others --exclude-standard) ]] || {
        echo "unexpected layer checkout state: $layer_source" >&2; exit 2;
    }
if git -C "$layer_source" diff --quiet; then
    git -C "$layer_source" apply --check "$patch_file"
    git -C "$layer_source" apply "$patch_file"
fi
# Reuse only our exact patch; never discard another local edit.
git -C "$layer_source" diff --binary | cmp -s "$patch_file" - || {
    echo "layer diff does not match $patch_file: $layer_source" >&2; exit 2;
}
git -C "$layer_source" diff --check
shasum -a 256 "$patch_file"
echo "VALIDATION_LAYER_SOURCE=$layer_source"
