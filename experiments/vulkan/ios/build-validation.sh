#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname -- "$0")/common.sh"
[[ $platform == device ]] || { echo 'iOS validation currently requires a device build' >&2; exit 2; }
for tool in cmake ninja jq; do require_command "$tool"; done
validation_dir=${IOS_VALIDATION_DIR:-"$ios_work/validation"}
mkdir -p "$validation_dir/Frameworks" "$validation_dir/vulkan/icd.d" "$validation_dir/vulkan/explicit_layer.d"
[[ $(pkg-config --modversion vulkan) == 1.4.357 ]] || {
    echo 'Validation 1.4.357 requires the matching Vulkan headers from deps.lock' >&2; exit 2;
}
bash "$experiment_dir/validation/prepare.sh" "$validation_dir"
layer_source="$validation_dir/layers-metal-import"
cmake -S "$validation_dir/headers" -B "$validation_dir/build-headers" -G Ninja \
    -DCMAKE_INSTALL_PREFIX="$validation_dir/prefix"
cmake --install "$validation_dir/build-headers"
cmake_flags=(-G Ninja -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdk" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_SYSTEM_PROCESSOR=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=OFF \
    -DCMAKE_INSTALL_PREFIX="$validation_dir/prefix")
cmake -S "$validation_dir/loader" -B "$validation_dir/build-loader" "${cmake_flags[@]}" \
    -DUPDATE_DEPS=OFF -DVulkanHeaders_DIR="$validation_dir/prefix/share/cmake/VulkanHeaders"
cmake --build "$validation_dir/build-loader" --target vulkan-framework -j "$jobs"
cmake -S "$layer_source" -B "$validation_dir/build-layers-metal-import" "${cmake_flags[@]}" -DUPDATE_DEPS=ON
cmake --build "$validation_dir/build-layers-metal-import" --target vvl -j "$jobs"
cp -R "$validation_dir/build-loader/loader/vulkan.framework" "$validation_dir/Frameworks/"
cp -R "$validation_dir/build-layers-metal-import/layers/VkLayer_khronos_validation.framework" "$validation_dir/Frameworks/"
driver="$validation_dir/Frameworks/MoltenVK.framework"
mkdir -p "$driver"
# The pinned dependency supplies a static archive; export it as a loadable ICD for this test app.
xcrun --sdk "$sdk_name" clang++ -target "$target" -isysroot "$sdk" -dynamiclib \
    -Wl,-force_load,"$ios_work/kit-layout/vulkan/$kit_platform/thin/arm64/lib/libMoltenVK.a" \
    -install_name @rpath/MoltenVK.framework/MoltenVK -framework Metal -framework IOSurface \
    -framework Foundation -framework QuartzCore -framework UIKit -framework IOKit \
    -framework CoreGraphics -o "$driver/MoltenVK"
cp "$ios_dir/validation-driver.plist" "$driver/Info.plist"
jq '.layer.library_path = "../../Frameworks/VkLayer_khronos_validation.framework/VkLayer_khronos_validation"' \
    "$validation_dir/build-layers-metal-import/layers/VkLayer_khronos_validation.framework/VkLayer_khronos_validation.json" \
    > "$validation_dir/vulkan/explicit_layer.d/VkLayer_khronos_validation.json"
jq -n '{file_format_version: "1.0.0", ICD: {library_path: "../../Frameworks/MoltenVK.framework/MoltenVK",
    api_version: "1.2.357", is_portability_driver: true}}' > "$validation_dir/vulkan/icd.d/MoltenVK.json"
shasum -a 256 "$driver/MoltenVK" "$validation_dir/Frameworks/vulkan.framework/vulkan" \
    "$validation_dir/Frameworks/VkLayer_khronos_validation.framework/VkLayer_khronos_validation"
echo "IOS_VALIDATION_DIR=$validation_dir"
