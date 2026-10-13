# Apple native output experiment

Source snapshot for iOS/macOS native video and `auto` selection. It is
separate from the stable OpenGL and Vulkan source locks. `versions.env` records
the mpv/libplacebo commits and an official FFmpeg commit plus a checked-in patch.
No FFmpeg fork is required. The native mpv and delivery branches are published;
remote-only clean builds and targeted Mac/iPhone regressions passed on
2026-10-13. Native CI also passed for Mac and unsigned iOS builds (see
`ACCEPTANCE.md`); build checks do not replace device playback acceptance.

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

The complete entry builds the locked FFmpeg with its patch, libplacebo, libmpv
and the native client in an isolated `WORK_ROOT`. It reuses the Vulkan checkout
helpers, FFmpeg configuration and iOS dependency/cross-build scripts. Requires
macOS/Xcode, Git, Meson/Ninja, pkg-config, make and shasum; macOS also needs
shaderc, Vulkan and libass development files. iOS uses the existing checksum-
locked dependency archives; set `IOS_DEPENDENCY_CACHE` to reuse downloads.
iOS also requires unzip, and gh when the archives are not already cached.

```sh
WORK_ROOT="$PWD/.work/apple-native-macos" bash experiments/apple-native/build.sh macos
WORK_ROOT="$PWD/.work/apple-native-ios" bash experiments/apple-native/build.sh ios
```

The iOS entry builds arm64 devices only and produces an unsigned app. Neither
entry signs/installs apps, copies media or changes device settings. Tests and
runtime acceptance are separate from build success. Each source checkout is
checked before building; unexpected changes are rejected, never reset/cleaned.
The intentional FFmpeg patch can be reused only if its complete tree matches
the lock, its index is unstaged, and no untracked source changes are present.
This also rejects edits hidden with `assume-unchanged` or `skip-worktree`.

The locked commits are available from the repositories in `versions.env`.
A fresh `WORK_ROOT` fetches them remotely; no preseeded local checkout or Git
bundle is needed. Do not point it at an original development checkout.

For a dependency build managed separately, prepare a clean FFmpeg checkout:

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
already-patched source. `--check` validates a previously prepared checkout
without modifying it; the complete entry uses this before and after compilation.
An existing checkout at the locked official commit can be passed instead.

The complete entry enables VideoToolbox HEVC hardware decoding and builds mpv
with `apple-native` enabled against the candidate libraries. The lower-level
`build-client.sh` remains compile-only and does not apply patches to an
already-built dependency.
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

## Native subtitles

Use ordinary mpv subtitle selection (`sub-files`/`sub-add`, `sid`), visibility,
delay and style options; the client does not decode or lay out subtitles.
Native returns `target.osd` as a retained, transparent CGImage covering the
requested target dimensions, including video margins. Apply it to the existing
OSD CALayer on the UI thread and release it after use. Clear that layer when
`target.osd` is null. Do not composite subtitles into the VideoToolbox buffer:
the native video layer and its per-frame DV attachments remain unchanged.

The native-only FFmpeg configuration now includes SRT/ASS/SUP demuxers and
ASS/SubRip/PGS decoders. The default Vulkan/iOS configuration is unchanged.
The smoke client accepts `--subtitle=/path/to/subtitles.ass`; on iOS use a
Documents-relative path. Optional `--overlay-dir=/path/to/results` records the
returned OSD images, and `--subtitle-controls=yes` runs the bounded control
check. These are diagnostic outputs, not native video screenshots.

The native source lock now includes Android's optional
`mediacodec-embed-osd-surface`. It uses a second transparent Surface for mpv's
existing OSD bitmap output, without replacing the decoder's video Surface or
using gpu-next for subtitle layout. Keep the Java Surface global reference
alive until its VO has stopped, and detach the decoder/VO before releasing
either Surface. Omitting the option preserves the existing native behavior.
The reviewed five-file Android client delta is in `android/subtitles.patch`;
its separate, unpublished candidate prerequisites are documented in
`android/README.md`. It is not a complete remote-buildable Android player or
an Android native-DV source lock. See `ACCEPTANCE.md` for the actual tested scope.

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

Use `python3 experiments/apple-native/test-build.py` for the small offline
patched-source/local-edit regression checks; it uses temporary Git fixtures,
not real dependencies or devices.

## Limits

This is single-layer DV Profile 5 with the separate FFmpeg patch, not Dolby
certification, HDMI DV passthrough or all-device support. Native screenshots,
ICC, interpolation, shaders and color processing use render instead. Auto
recovery is safe but not seamless/zero-drop; non-seekable recovery is not
accepted. iOS background handling pauses/stops decoding and reopens at saved PTS.
Call-interruption recovery, DV Profile 7/8, tvOS and non-Apple native output are
not accepted. iOS fallback in this harness is static MoltenVK without a fresh
validation-layer acceptance. gpu-next renderer code is unchanged.
