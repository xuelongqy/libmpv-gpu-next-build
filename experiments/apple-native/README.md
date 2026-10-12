# Apple native output experiment

Local source snapshot for iOS/macOS native video and `auto` selection. It is
separate from the stable OpenGL and Vulkan source locks. `versions.env` records
the mpv/libplacebo commits and an official FFmpeg commit plus a checked-in patch.
No FFmpeg fork is required. The mpv commit is **local only**, so remote checkout
and CI reproducibility are not yet accepted.

## Modes and ownership

| Output mode | Behavior |
| --- | --- |
| Omitted / `render` | Existing behavior; OpenGL still defaults to old `gpu`. |
| `native` | Apple sample-buffer display layer and direct VideoToolbox frames. Unsupported inputs fail explicitly. |
| `auto` | Supported DV uses native; other media/processing use the supplied renderer. Native failure disables native for this context and rebuilds ordinary decoding before safe fallback. |

Native is opt-in with `-Dapple-native=enabled`, macOS 14+/iOS 17+, and the
matching, **uninstalled experimental** `include/mpv/render_apple.h`. Client API
remains 2.8; it does not identify native draft revisions. Check `OUTPUT_MODE`
with `get_info()` before loading media and reject an older library.

libmpv retains demuxing, track selection, decoding, audio, playback timing,
pause/seek and OSD generation. Native wraps the same decoded CVPixelBuffer,
preserves per-frame attachments, waits for mpv's target time, then enqueues it.
Video pixels do not go through gpu-next or RGB/PQ/scRGB conversion.

The client owns/attaches one `AVSampleBufferDisplayLayer`, serializes Render API
calls, applies returned geometry/OSD on the UI thread and releases returned
CGImageRefs. Do not independently enqueue/flush, add a timebase or add a second
synchronizer. Free the render context before its layer or fallback GPU resources.

`auto` requires advanced control. Supply normal GL/Vulkan initialization plus
optional native initialization. After `update()`, query output mode before
acquiring a GPU target: use native, render, or wait during `recovering`.
Keep a configured GL context current for the required API calls even in native
mode. Unspecified renderer preference is gpu-next, gpu, then software; explicit
renderer restricts it. DV cannot fall back to old gpu/software, and HDR cannot
fall back to software. No window or swapchain is created for the caller.

## Build and reproduce

The client sources are the tested private client, copied byte-for-byte. The
compile-only helper removes private paths and signing information; it does not
build dependencies, sign/install an app, copy media or change device settings.
Prepare a clean FFmpeg checkout before compiling dependencies:

```sh
source experiments/apple-native/versions.env
git clone --no-checkout "$FFMPEG_REPOSITORY" .work/apple-native/ffmpeg
git -C .work/apple-native/ffmpeg checkout --detach "$FFMPEG_COMMIT"
bash experiments/apple-native/prepare-ffmpeg.sh .work/apple-native/ffmpeg
```

The preparation entry checks the full base SHA, patch SHA-256 and complete
patched Git tree against the accepted source, then applies the patch without
staging or committing. Dirty checkouts and mismatches fail; nothing is reset or
cleaned. Actual tracked file contents are checked in a temporary index, including
edits hidden from Git status. Run it once per fresh checkout, not again on an
already-patched source.
An existing checkout at the locked official commit can be passed instead.

Build FFmpeg from that prepared source with the existing macOS/iOS configure
options and VideoToolbox HEVC hwaccel enabled, then build the locked mpv with
`apple-native` enabled against those libraries. The client helper remains
compile-only and does not apply patches to an already-built dependency.
`vt_native_dv` remains default-off and is selected by native output, not by
ordinary gpu-next decoding. This packages the existing patch; no additional
native-disable patch or decoding behavior change is introduced.

```sh
bash experiments/apple-native/build-client.sh macos "$MPV_SOURCE" "$MPV_BUILD" \
  .work/apple-native/macos-client
.work/apple-native/macos-client/native-smoke --file=/path/to/profile5.mkv \
  --mode=native --seconds=8
```

For local sound use `--audio=yes --ao=avfoundation` on macOS, or
`--audio=yes --ao=audiounit` on iOS. The client uses volume 50 without changing
system settings. Set iOS `PKG_CONFIG_LIBDIR` to the matching arm64 static
dependencies and call the helper with `ios`; it produces an unsigned app.
Sign using a matching profile/entitlements outside the repository. Copy private
media into its Documents container and launch with `--file=Documents/name.mkv`.
No certificate, profile, device identifier or sample is included here.

Existing controls include `--start`, `--parameter-tests=yes`,
`--lifecycle=yes`, `--mode=auto --fallback=opengl|vulkan` and
`--switch-feature=yes` for interpolation-triggered safe fallback. Test observer
and `--fail-native-after` hooks apply only to the preserved instrumented builds,
not the final uninstrumented production library.

Native long runs use `--seconds=900 --audio=yes --mode=native`, without lifecycle
mode. Default duration remains 8 seconds; 1–900 seconds are accepted. Long-only
instrumentation hashes the whole input and samples playback/actual process
resources once a second. It does not read back video pixels every frame. Keep
iOS in the foreground; interrupted runs are not passes. Use the existing
`experiments/vulkan/case.py` for a 1080-second external deadline, and keep all
results outside the tracked source tree.

```sh
python3 experiments/apple-native/check-long.py /path/to/private-long-evidence
```

The checker expects the original run's `media-long.sha256`, Mac
`macos-native-900` and iPhone `ios-native-900-r2` case/report JSON pairs, as
listed in `ACCEPTANCE.md`. Python optimization is explicitly rejected.

## Limits

This is single-layer DV Profile 5 with the separate FFmpeg patch, not Dolby
certification, HDMI DV passthrough or all-device support. Native screenshots,
ICC, interpolation, shaders and color processing use render instead. Auto
recovery is safe but not seamless/zero-drop; non-seekable recovery is not
accepted. iOS background handling pauses/stops decoding and reopens at saved PTS.
Call-interruption recovery, DV Profile 7/8, tvOS and non-Apple native output are
not accepted. iOS fallback in this harness is static MoltenVK without a fresh
validation-layer acceptance. gpu-next renderer code is unchanged.
