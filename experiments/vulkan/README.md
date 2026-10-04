# Experimental Vulkan delivery

This is an opt-in, source-only desktop experiment. It does not replace the
OpenGL/GLES source combination in the root `versions.env`, install a stable
Vulkan header, or change the client API version. There are no binary releases
or new CI claims.

## Source and interface identity

- mpv: `b91f8e58e51e75f68232b720352fdcfd6929e1b3`
- libplacebo: `5101de2b9354789a019d1933bc45e43b0ee65059`
- Header: the pinned mpv checkout's `include/mpv/render_vk.h`.
  Draft version is 1; client API 2.6 does **not** identify draft revisions.
  Always use the header and library from the same experiment. Never copy this
  header into a system SDK as if its ABI were stable.

The locked commits were published to the configured forks during the 2026-09-28
sync. Checkout still verifies the exact full SHA and refuses dirty dependency
trees; do not silently fall back to another revision.

## Build prerequisites

macOS: an installed compiler/SDK supporting the client's macOS API declarations,
Meson, Ninja, pkg-config, FFmpeg and libass development files, shaderc, SDL2,
Vulkan headers/loader, MoltenVK ICD and Khronos validation layer.

Windows: run from **MSYS2 UCRT64**, with the corresponding compiler, Meson, Ninja,
Python, pkg-config, FFmpeg, libass, shaderc, SDL2, Vulkan headers/loader and a
compatible Khronos validation layer. The display probe uses recent Windows
Advanced Color declarations; keep the already validated SDK/header environment.
No script installs or upgrades packages, driver, loader, layer or SDK.

Both hosts require Python 3.11+; pixel comparisons also require NumPy, Pillow
and ffmpeg. Record installed dependency versions; source locks do not promise
bit-identical binaries across different toolchain installations.

From the repository root:

```sh
bash experiments/vulkan/build.sh
bash experiments/vulkan/tests.sh
python3 experiments/vulkan/test-tools.py
```

Builds use a fresh `.work/vulkan/` source/build/install area, including standalone
mpv and the smoke binary. No prior validation prefix is copied. Checkout refuses
staged, unstaged or untracked dependency edits; never reset/clean them to proceed.
`WORK_ROOT` can explicitly select another private work root. Only experimental
entrypoints select the experimental lock; existing root commands are unchanged.

Set loader/ICD/layer discovery variables for your installed Vulkan environment
before launching. On macOS this can include `VK_DRIVER_FILES`, `VK_LAYER_PATH`,
`SDL_VULKAN_LIBRARY` and validation-layer libraries in `DYLD_LIBRARY_PATH`.
On Windows the corresponding SDK binaries must be on PATH. No repository path,
monitor name, audio UID or SDK install path is baked into the scripts.

The smoke requires validation; absence is a setup failure, not a validation pass.
Build does not run tests implicitly. `tests.sh` retains all library test failures
and returns nonzero; it does not waive known baseline failures.

## Running

```sh
bash experiments/vulkan/run.sh --probe
bash experiments/vulkan/run.sh --window --output sdr VIDEO.mkv
bash experiments/vulkan/run.sh --window --output pq --hwdec videotoolbox-copy \
  --play-seconds 60 --audio-device YOUR_DEVICE --volume 50 VIDEO_WITH_AUDIO.mkv
```

On Windows replace hwdec with `d3d11va-copy`; use `--display N` to select a
display. Enumerate audio outputs with the candidate standalone mpv's
`--no-config --audio-device=help`. Do not assume display 0 or the default audio
endpoint is the intended TV.

The default test window is 960x540, not a native-4K playback test. Use
`--fullscreen` instead of `--window` for desktop fullscreen on the selected
display, without changing its display mode. Windows requests per-monitor DPI
awareness; the swapchain uses the actual surface/drawable pixel size. Check
`DRAWABLE_SIZE` and `TARGETS ... SIZE` in the log, not just the source resolution
or desktop mode. `--width`/`--height` set the initial window or offscreen size;
fullscreen uses the desktop size and cannot be combined with resize stress.

For the Windows native-4K voiced checks, first verify the selected display is
actually 3840x2160 with HDR active and the requested HDMI endpoint is available.
From the repository root, use fresh private result prefixes and the absolute
runner path (not an entrypoint relative to a different working directory):

```sh
python3 experiments/vulkan/case.py PRIVATE_RESULT/scrgb-4k-60 120 -- \
  bash "$PWD/experiments/vulkan/run.sh" --fullscreen --display N --output scrgb \
  --hwdec d3d11va-copy --play-seconds 60 --audio-device YOUR_DEVICE --volume 50 \
  VIDEO_WITH_AUDIO.mkv
python3 experiments/vulkan/case.py PRIVATE_RESULT/pq-4k-900 1080 -- \
  bash "$PWD/experiments/vulkan/run.sh" --fullscreen --display N --output pq \
  --hwdec d3d11va-copy --play-seconds 900 --audio-device YOUR_DEVICE --volume 50 \
  VIDEO_WITH_AUDIO.mkv
```

The long input must contain at least 900 seconds after the selected start;
do not loop a short sample. Check the complete duration, decoder, actual audio
endpoint and final validation result, not merely the case runner's exit code.
For the static scRGB pair, use the same PTS/input/options with
`--timeline --width 3840 --height 2160` and `--fullscreen`, respectively, and
compare their raw captures with `compare-hdr.py RESULT --pair fullscreen.raw
offscreen.raw --fp16`. Each static case has a 30-second external deadline.
Windows resource measurements must follow the actual `smoke.exe` PID;
the Bash-wrapper samples in case JSON are not renderer resource measurements.

`--play-seconds` uses video-sync=audio, PCM stereo, no passthrough/null fallback.
Volume defaults to the previously tested 20; physical movie listening commands
explicitly use 50. The scale is nonlinear: 20 is gain 0.008, not 20% signal gain.
The wrapper never changes OS/display volume, HDR switch or refresh rate.
Run voiced tests serially. Continuous mode cannot be combined with paused HDR
comparison; use `--compare-hdr --hold-seconds 60 --window --output pq VIDEO.mkv`
for right-click/Space switching, with Esc or window-close to exit.

SDR is BT.709/sRGB; PQ is RGB10/BT.2020/PQ, depth 10; scRGB is FP16/BT.709,
80-nit encoding with dithering disabled. The default HDR target peak of 500 nits
is a test setting, not measured monitor capability. Explicit HDR requests fail
unsupported when required presentation capabilities are missing; there is no
silent SDR fallback. The macOS PQ/scRGB brightness mismatch remains unresolved.

## Caller contract

Use the existing Render API, API type `vulkan` and renderer `gpu-next`.
Vulkan 1.2, enabled timelineSemaphore/hostQueryReset/synchronization2 and queue 0
from a graphics+compute family are required. At Vulkan 1.2, enable
VK_KHR_synchronization2. Supply the actual enabled feature chain/extensions,
not a supported-capability query.

The caller owns device, image/memory, semaphores, swapchain and presentation.
Use the same queue lock for caller submissions and libmpv callbacks; never
hold it across a Render API call or call mpv from a lock callback.
Images stay in the imported family or use compatible concurrent sharing.

Initialize target state to UNTOUCHED on every call. UNTOUCHED does not consume
acquire or signal completion; RETURNED requires waiting completion even when
render reports an error (do not present failed contents); FAILED does not
guarantee completion and requires context recovery. Never wait on a semaphore
whose signal was not guaranteed. SKIP_RENDERING does not acquire a target.

Keep image description/generation stable until explicit retirement. Retire
wrappers before destroying targets, and separately wait for caller use/present
to finish. Free Render API before device/synchronization objects. Do not call
device-wide idle every frame. Copy-back hardware decoding is not zero-copy
hardware interop. The pinned header is authoritative for complete details.

## Reproduction and evidence

```sh
python3 experiments/vulkan/check.py controls
python3 experiments/vulkan/check.py matrix --samples PRIVATE_SAMPLES --baseline PRIVATE_REFERENCE
python3 experiments/vulkan/check.py lifecycle --media PRIVATE_AV_CLIP --audio-device YOUR_DEVICE
python3 experiments/vulkan/check.py av --media PRIVATE_AV_CLIP --audio-device YOUR_DEVICE
```

Pass `--display N` for Windows when needed. Set the loader environment as above.
Samples are `sdr-20s.mkv`, `hdr10-20s.mkv`, `dv-p5-20s.mkv`; the matrix's
matching baseline uses `no-OUTPUT-SAMPLE-offscreen/window.ppm/raw` and raw JSON
sidecars. Exact PTS/options/media hashes must match; missing references fail.
The existing comparers retain one 8-bit code, one 10-bit code and one FP16 ULP.
No cross-vendor bitwise equality is claimed.

Each invocation creates a fresh result directory; individual cases refuse to
overwrite logs. Nonzero, unsupported (77) and timeout (124) stay distinct.
Reports record input hashes, commands and errors. Baseline pixel comparisons
and target reads are separate from actual display brightness/audio evidence.
See VALIDATION.md for current results and unfinished prerequisites.

The original native Metal/EDR-scale/audio-interposer diagnostics, machine-specific
launchers, recordings, logs and media stay outside this delivery. The shared
Vulkan renderer loop is reused; FILE_LOADED reset and seek-restart handling are
retained. No generic player or new test framework was introduced.
