# Validation record

## gpu-next-v1.0.0 source combination

- mpv: `c30a27722bc983671e8a11ddacc9480dde29681a`
- libplacebo: `6476b2e82842c54d2fba0785bbeff83666920b72`
- immutable mpv feature snapshot: `77c48fff91df7cb470b02b83f510c342e68236d2`
- immutable libplacebo fix: `011d7e15ee4ae74ae7e79bc957f80276d740df90`

### Automated validation, 2026-09-04

On an Apple M2 Max macOS host:

- pinned libplacebo build and tests: 15 passed, 1 skipped;
- pinned mpv OpenGL build and complete Meson tests: 35 passed, 3 skipped;
- no-OpenGL libmpv build and suite: 25 passed, 3 skipped;
- ASan/UBSan libmpv build and suite: 25 passed, 3 skipped;
- Android arm64 libmpv and debug/release smoke APK assembly completed with
  NDK r29; a temporary Maven mirror was used for local dependency resolution;
- the desktop smoke client linked to the private pinned libplacebo prefix;
- both maintained commits merged cleanly with the official upstream `master`
  revisions checked on this date.

The macOS build enables libplacebo and mpv Vulkan support because the current
upstream Cocoa Swift source set references its Metal layer when compiling the
VideoToolbox OpenGL configuration. The maintained Render API feature and smoke
test remain OpenGL-only; this does not add a downstream Vulkan Render API.

### Manual platform validation

The immutable feature snapshot was exercised before the first maintenance
merge. The merge only updates the shared renderer to retain hardware mappings
for queue-owned frames, matching the corresponding upstream `vo_gpu_next`
lifetime change.

macOS, Apple M2 Max:

- legacy `gpu` and explicit `gpu-next` rendered SDR through the Render API;
- HDR10 and Dolby Vision Profile 5 decoded as VideoToolbox `p010` and rendered
  to SDR and BT.2100 PQ targets;
- the Dolby Vision input retained `dolbyvision/bt.2020/pq` metadata;
- no `textureSize(sampler2DRect, 0)`, shader compilation, or scaler-dispatch
  error occurred with the patched libplacebo;
- default and texture FBOs, flip, screenshot, resize, seek, pause, and context
  teardown were exercised.

Android Pixel 4, GLES 3.2:

- legacy `gpu` and explicit `gpu-next` rendered through an RGBA8/sRGB surface;
- HDR10 with MediaCodec rendered through an RGB10A2 BT.2020/PQ surface;
- Dolby Vision Profile 5 software decode retained Dolby Vision/PQ metadata and
  rendered to both SDR and PQ targets;
- SurfaceFlinger reported the video layer as `RGBA_1010102` with
  `BT2020_PQ` dataspace and the display dynamic range as HDR during the PQ run;
- surface recreation, rotation, background/foreground, playback end, and
  context teardown were exercised.

The maintained source combination was revalidated on the same Pixel 4 on
2026-09-04, running Android 13 (`TP1A.221005.002.B2`):

- the device reported HDR10 and HLG support with 500 nit peak luminance;
- the runtime identified mpv as `c30a27722` and libplacebo as `6476b2e8`;
- SDR rendered with both `gpu` and `gpu-next` through GLES 3.2 RGBA8/sRGB;
- HDR10 used the MediaCodec hardware decoder, retained BT.2020/PQ input
  metadata, and presented an RGB10A2 `BT2020_PQ` SurfaceFlinger layer;
- Dolby Vision Profile 5 software decoding retained
  `dolbyvision/bt.2020/pq` and rendered to both SDR and PQ targets without
  green/magenta output;
- the Dolby Vision PQ target was also reported as RGB10A2 with `BT2020_PQ`
  dataspace by SurfaceFlinger;
- rotation updated the render target from 1080x2280 to 2280x1080, and surface
  detach/attach, background/foreground, natural playback end, opening a second
  file, and native context shutdown completed without a crash or hang;
- no Render API creation, GL, shader compilation, or scaler-dispatch failure
  was present in the playback cases.

Android screenshots were inspected only for gross color failures. The
RGB10A2 format and SurfaceFlinger dataspace, rather than SDR screenshots, are
the evidence that PQ output was active.

These Dolby Vision checks validate decoding and mapping to SDR or HDR10/PQ.
They do not claim native Dolby Vision display output.
