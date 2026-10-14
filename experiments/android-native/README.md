# Android native delivery experiment

This isolated candidate replaces the earlier partial client delta with three
complete, checked patches: MediaCodec DV support in official FFmpeg, its mpv
decoder opt-in, and the Android client against official mpv-android. It does not
change the stable OpenGL lock or the Apple native experiment.

## Source and tool identity

`versions.env` fixes complete commits, patch SHA256 values and the complete
patched Git trees. `dependencies.tsv` fixes the remaining Git/submodule or
release-archive sources. No FFmpeg fork or Apple VideoToolbox patch is needed.
The Android option `mc_native_dv` defaults to zero; only the native MediaCodec
bridge enables it for supported HEVC DV input. The current DV patch is limited
to single-layer Profile 5, not every Dolby Vision profile.

The locked tools are NDK r29 (`29.0.14206865`), SDK platform 36 and build-tools
36.0.0. The upstream scripts actually compile against **Android API 23**;
NDK r29 is not API 29. Install those tools separately. The entry does not install
or upgrade a SDK, driver, Java or device setting. On macOS it also needs GNU
install/sed, Bash 4+, Meson, Ninja, pkg-config, Make and Java 21.

## Build from the locked sources

From the delivery repository root:

```sh
export ANDROID_NATIVE_SDK=/path/to/Android/sdk
export ANDROID_NATIVE_NDK=/path/to/android-ndk-r29
bash experiments/android-native/build.sh armv7l
bash experiments/android-native/build.sh arm64
```

Run these serially: some upstream dependencies build in their source directory.
The default output is `.work/android-native/`. `WORK_ROOT` selects a separate
candidate directory; paths cannot contain whitespace because the upstream
scripts do not support it. Each invocation reuses the upstream dependency and
JNI/Gradle build scripts, not an old binary prefix. APKs are under
`mpv-android/app/build/outputs/apk/default/debug/`; evidence contains tool and
artifact hashes. These are debug validation APKs, not signed release products.

`prepare.sh --check` checks existing sources without fetching or applying a
patch. Preparation accepts only the locked base or the exact declared patch
result. Wrong HEAD, staged/untracked source files and modified content are
rejected, including hidden tracked edits and submodule edits. There is no
reset/clean. Normal ignored build output is allowed; edits to ignored build
files are not treated as source edits.

## Native and Render API client paths

The debug client uses `mode=wid`, `renderer=mediacodec_embed`,
`hwdec=mediacodec`, `output=sdr` for native output. Here `sdr` means **no client
colorspace override**, not SDR tone mapping: MediaCodec and the system Surface
carry the SDR/HDR/DV output. The two native Surfaces are video plus transparent
mpv subtitle overlay. Both must exist before attachment; decoder/VO shutdown
precedes releasing their Java references. Recreating either reattaches both.

`mode=render-api`, `renderer=default|gpu|gpu-next`, `hwdec=no|mediacodec` retain
the existing GL/GLES path. Native DV is not enabled there. Render API PQ retains
its explicit RGB10/PQ setup; the unrelated wid HDR experiment is not included.
The validation app's default is Render API gpu-next, while libmpv's omitted
renderer selector still chooses the old gpu renderer. There is no new auto
selection policy in this delivery.

## Targeted device checks

Use an explicit ADB serial and keep a phone unlocked during the checks. Save the installed test APK before replacing it,
install the candidate without clearing app data, and restore the original APK
when done. Put the three existing clips in an app-private folder as
`sdr-av-65s.mkv`, `hdr10-av-65s.mkv`, `dv-av-65s.mkv`; subtitle fixtures remain
`files/native-subtitles.srt|ass|sup|mks`. Media and receipts are not committed.

```sh
export SMOKE_DEVICE=DEVICE_SERIAL SMOKE_MEDIA_DIR=MEDIA_FOLDER
export SMOKE_RESULTS_DIR=/path/to/private/results
# Muted by default; Pillow/numpy are needed only for subtitle pixel checks.
SMOKE_SUBTITLE=srt SMOKE_LIFECYCLE=5 SMOKE_ROTATE=1 \
  python3 experiments/android-native/run-case.py sdr 8 native-sdr
python3 experiments/android-native/check-subtitles.py "$SMOKE_RESULTS_DIR" native-sdr
# Only after the observer is ready; this does not change system volume.
SMOKE_VOLUME=50 python3 experiments/android-native/run-case.py hdr10 60 native-hdr10-audio
```

Wrap device commands with the existing `experiments/vulkan/case.py`: 120 seconds
for short playback, 300 seconds for subtitle/lifecycle checks. `SMOKE_RENDERER`,
`SMOKE_OUTPUT` and `SMOKE_HWDEC` select the existing comparison paths. Native DV
requires independent decoder/display confirmation and explicit
`SMOKE_NATIVE_DV=1`; frames alone are not evidence of Dolby Vision display.
`SMOKE_EXPECT_HDMI=1` enables the existing Amlogic HDMI status check, only on a
device that exposes that diagnostic node. Pixel 4 must not count native DV as
supported; its existing gpu-next DV-to-PQ mapping is a different output path.

Offline protection checks: `python3 experiments/android-native/test-prepare.py`.
See `ACCEPTANCE.md` for this candidate's results and retained limits. No new CI
workflow, renderer change, source release or tag is part of this stage.
TV-box basic playback and five mixed-file lifecycle rounds are verified. Surface
completion now uses actual VO/decoder state, followed by the existing playback
and subtitle checks, rather than unreliable log markers. The earlier failed
receipts remain in the acceptance history; this is not an all-device guarantee.
