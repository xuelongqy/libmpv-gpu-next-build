# iOS device smoke (experimental)

Uses the sibling Vulkan source lock, UIKit, static MoltenVK 1.4.2 by default and the
existing miniature FFmpeg configuration. No native Metal Render API or native
Dolby Vision output: DV is mapped to SDR or PQ. scRGB/tvOS are not covered.

## Build

Requires Xcode, Meson/Ninja, pkg-config, Git, unzip and gh. No SDK/tool upgrades.
Dependency archives are checked against `deps.lock`; signing data and media
must remain outside Git. Set a fresh `WORK_ROOT` and, if using local unpublished
sources, the existing `SOURCE_LOCK_FILE` override.

```sh
export IOS_PLATFORM=device
export IOS_MEDIA_DIR=/absolute/path/to/private/samples
export IOS_PROFILE=/absolute/path/to/profile.mobileprovision
export IOS_SIGNING_IDENTITY=YOUR_SIGNING_IDENTITY
bash experiments/vulkan/ios/build.sh
```

Media directory requires `sdr-20s.mkv`, `hdr10-20s.mkv`, `dv-p5-20s.mkv`.
`IOS_PLATFORM=sim` builds arm64 simulator without device signing. Archives may
be reused through `IOS_DEPENDENCY_CACHE`; an existing **clean, SHA-matching**
FFmpeg checkout may be read through `IOS_FFMPEG_SOURCE`. Builds are out-of-tree.

## Run

Install the printed `IOSSmoke.app` with `devicectl`; select the device explicitly:

```sh
export IOS_DEVICE=YOUR_DEVICE_IDENTIFIER
python3 experiments/vulkan/ios/run-case.py /absolute/path/to/results/dv-pq 30 -- \
  --media=dv-p5 --output=pq --window --hwdec=videotoolbox
```

Decoder choices: `no`, `videotoolbox-copy`, `videotoolbox`. The last requires
Metal device export/interop; the requested decoder must actually be active.
Window targets use the real native drawable extent; offscreen targets are
640x360. Results include raw VkImage readback and a GPU screenshot, not a
software screenshot fallback. The runner requires this launch's case marker,
all requested context completions and the final loop marker, collects the app's
files, and bounds failure cleanup. Use fresh result prefixes.

`--contexts=20` checks repeated creation, rendering before load and after stop;
post-stop rendering waits for `MPV_EVENT_END_FILE` and `vo-configured=false`, not the
earlier disappearance of decoder parameters.
`--stress` runs 20 loads and seek/skip/GPU-screenshot/render cycles. With
`--window --stress --rotate`, ten native orientation changes retire/rebuild the
targets. Background/foreground events pause the worker and retire/rebuild on
resume; only that worker performs Vulkan/Render API operations. It uses asynchronous
mpv commands and observed properties while servicing advanced-control updates;
it does not call synchronous property getters/setters on the render worker.

For sound, copy a file with a real audio track into the app's Documents directory
**after installation completes**, then pass `--file=FILE.mkv --window
--play-seconds=60`. The file name is relative to Documents, not a host path.
Uses AudioUnit, PCM stereo, client volume 50, audio synchronization and target
time waiting. No per-frame readback; actual decoder, AO and progress are checked.
System volume/audio route are not changed. Listening confirmation is separate
from a successful process exit. For 600 seconds use a 720-second outer timeout.

## Opt-in device validation

After the ordinary pinned iOS libraries have been built in a fresh `WORK_ROOT`,
build the matching loader/layer package, then relink and sign the client:

```sh
export IOS_PLATFORM=device
bash experiments/vulkan/ios/build-validation.sh
export IOS_VALIDATION_DIR="$WORK_ROOT/ios-device/validation"
bash experiments/vulkan/ios/build-app.sh
```

The package uses Vulkan headers, loader and Khronos validation layer 1.4.357
with the [packaged Metal-import patch](../validation/README.md),
and exports the pinned MoltenVK archive as a loadable ICD. Requires CMake/Ninja
and jq; frameworks are bundled and signed, not installed system-wide. Install
this app, then add `--require-validation` to the ordinary `run-case.py` command.
The client enables synchronization validation, records actual loaded libraries
and fails on error-severity messages. The runner requires a zero-error validation
marker for every completed context. Warnings remain visible. Unset
`IOS_VALIDATION_DIR` and use a fresh app work directory to retain the original
static build; validation is never silently enabled or disabled.

## Acceptance limits

The default static build still reports `VALIDATION=NOT_ENABLED` and rejects
`--require-validation` with a setup error. On the tested phone, the opt-in path
completes 30 software/copy/direct SDR/PQ cases and eight playing/paused/stopped
background checks with validation enabled and no reported errors. All 58 pixel
comparisons and 33 real background transitions pass; see `../VALIDATION.md`.

Metal-import validation requires the same private six-line, matching-version
layer correction as the macOS probe. The unmodified 1.4.357 layer reports
imported Metal images as unbound even without libmpv. The private correction
preserves unbound/export-only and invalid imported-view checks; it does not
filter errors. A further negative probe finds that layer 1.4.357 misses WAW
hazards on imported Metal textures, with or without this correction. Thus zero
reported errors do not establish complete direct-mapping synchronization
acceptance; the functional/pixel results above are separate. See the validation
review in `../VALIDATION.md`.

A later private candidate adds imported-image synchronization tracking in two
layer files. Its no-libmpv negative controls catch WAW/RAW and matching-wrapper
alias hazards without submitting invalid commands. Thirteen targeted direct
VideoToolbox/SDR/PQ/recovery cases and 20 pixel comparisons pass with the final
candidate. This covers tested single-plane, matching-description imports, not
external Metal producer synchronization or general IOSurface/texture-view
aliasing. Default static compatibility is rechecked; see the candidate section
in `../VALIDATION.md`. Earlier failures remain historical evidence.
These earlier runs used private packages; `build-validation.sh` now applies the
same fixed patch to a separate checkout, keeping the official baseline clean.
The shared no-libmpv probe also tests submitted queue history after alias
destruction (19 checks, 11 expected errors); build it with
`build-app.sh --metal-import-probe` and use the [probe runner](../validation/README.md#ios).
Default static builds do not load the patch. No other-device, scRGB/tvOS or
new physical HDR/audio acceptance is claimed. Do not filter warnings or relabel
absence as zero validation errors.

Pixel thresholds remain one 8-bit SDR / one 10-bit PQ code. Failed comparisons,
unsupported decoders, environmental failures and user feedback stay separate.
Use `run-case.py --self-check` for the offline launcher-status checks.
