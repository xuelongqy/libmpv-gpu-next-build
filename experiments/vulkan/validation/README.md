# Metal-import validation (experimental)

This is a downstream **validation-layer** patch, not a renderer fix. It applies
only to Khronos VVL `e4786f7ce8f1319215eff0d938f4be4651cbb85d` (1.4.357),
with matching headers and loader. The original upstream license/copyright stays
in place. No patch is installed system-wide or applied to mpv/libplacebo.

`metal-import-sync.patch` contains 38 added lines in three VVL files. Imported
Metal images need no Vulkan memory binding; they still need synchronization
access ranges. Identical texture/plane imports with matching image descriptions
share those ranges, and destroying one wrapper preserves a surviving alias's
queue history. This does **not** track external Metal/VideoToolbox producer
operations, different texture views of one IOSurface, or general multiplanar
aliasing. Zero errors must not be read as full cross-API synchronization proof.

Patch SHA256: `546036f51c367cffa54c5258c8143902d5f2a904beba82e33bc4851b8e6b5dbc`.
`prepare.sh OUTPUT_DIRECTORY` fetches the pinned sources, retains clean official
checkouts, and patches a separate `layers-metal-import` checkout. Repeated calls
accept only the exact patch; staged, untracked or other edits are rejected,
never reset/cleaned. Use a fresh directory to retain earlier binaries/logs.

## iOS

Use the existing [device build and signing setup](../ios/README.md#opt-in-device-validation).
`ios/build-validation.sh` now builds this patched candidate explicitly.
After preparing `IOS_VALIDATION_DIR`, build the independent probe:

```sh
bash experiments/vulkan/ios/build-app.sh --metal-import-probe
xcrun devicectl device install app --device "$IOS_DEVICE" \
  "$WORK_ROOT/ios-device/IOSMetalProbe.app"
python3 experiments/vulkan/ios/run-case.py "$WORK_ROOT/results/metal-probe" 30 -- \
  --metal-import-probe
```

It links no libmpv or libplacebo. The runner requires this launch's completion
markers **and** the exact expected-error result; launcher success is not enough.
It records `validation=negative_controls`, not zero-error playback validation.
The probe shares the smoke app's bundle ID/profile; reinstall the ordinary
`IOSSmoke.app` afterward without clearing its data. No media is needed for the
probe. For ordinary playback, build without the probe flag and run with
`--require-validation`. For default static playback, unset `IOS_VALIDATION_DIR`
and use a fresh app work directory; that path does not build/load this layer.

## macOS

Use the installed MoltenVK ICD without changing system settings. The following
builds only the pinned validation environment and the same independent probe:

```sh
export VALIDATION_WORK_DIR=/absolute/path/to/fresh/validation-macos
bash experiments/vulkan/validation/prepare.sh "$VALIDATION_WORK_DIR"
cmake -S "$VALIDATION_WORK_DIR/headers" -B "$VALIDATION_WORK_DIR/build-headers" \
  -G Ninja -DCMAKE_INSTALL_PREFIX="$VALIDATION_WORK_DIR/prefix"
cmake --install "$VALIDATION_WORK_DIR/build-headers"
cmake -S "$VALIDATION_WORK_DIR/loader" -B "$VALIDATION_WORK_DIR/build-loader" \
  -G Ninja -DCMAKE_BUILD_TYPE=Release -DUPDATE_DEPS=OFF \
  -DVulkanHeaders_DIR="$VALIDATION_WORK_DIR/prefix/share/cmake/VulkanHeaders"
cmake --build "$VALIDATION_WORK_DIR/build-loader" --target vulkan
cmake -S "$VALIDATION_WORK_DIR/layers-metal-import" -B "$VALIDATION_WORK_DIR/build-layers" \
  -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=OFF -DUPDATE_DEPS=ON
cmake --build "$VALIDATION_WORK_DIR/build-layers" --target vvl
cc -Wall -Wextra -Werror -O2 -I"$VALIDATION_WORK_DIR/headers/include" \
  experiments/vulkan/smoke/test-metal-import.m \
  -L"$VALIDATION_WORK_DIR/build-loader/loader" -lvulkan \
  -Wl,-rpath,"$VALIDATION_WORK_DIR/build-loader/loader" \
  -framework Metal -framework Foundation -o "$VALIDATION_WORK_DIR/test-metal-import"
export VK_DRIVER_FILES=/absolute/path/to/MoltenVK_icd.json
export VK_LAYER_PATH="$VALIDATION_WORK_DIR/build-layers/layers"
export DYLD_LIBRARY_PATH="$VK_LAYER_PATH:$VALIDATION_WORK_DIR/build-loader/loader"
python3 experiments/vulkan/case.py "$VALIDATION_WORK_DIR/probe" 30 -- \
  "$VALIDATION_WORK_DIR/test-metal-import"
```

These paths can also be used for the existing desktop playback client. Keep
actual loaded-library paths and hashes with results; a `PATH` setting alone is
not identity evidence. The ordinary desktop build still compiles this probe,
but does not replace the system validation layer.

## Positive/negative controls

The probe requires 19 checks and exactly 11 intentional errors, by type and
count: invalid view, unbound/export-only controls, imported/bound WAW/RAW,
matching versus distinct textures, and surviving aliases. Recording-only
negatives are not submitted. The queued alias check submits valid first writes,
then requests validation to reject missing-barrier writes; an independent bound
image guarantees rejection even if Metal alias tracking regresses.

The matching six-line-only baseline fails the imported hazards. A private
mutation removing only the destruction guard also fails the queued check
(one WAW instead of two), while the guard image still prevents invalid dispatch.
Both iOS and macOS pass with the complete patch. See [acceptance records](../VALIDATION.md#2026-10-11-packaged-metal-import-validation)
for the limits, original failures and private evidence index.
