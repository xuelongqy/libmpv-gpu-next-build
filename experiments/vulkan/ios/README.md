# iOS device smoke (experimental)

Uses the sibling Vulkan source lock, UIKit, static MoltenVK 1.4.2 and the
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

## Acceptance limits

Static MoltenVK does not provide the Vulkan loader/layer mechanism. The client
reports `VALIDATION=NOT_ENABLED`; `--require-validation` fails with a setup error,
not a pass. A matching iOS loader/layer remains required for full synchronization
acceptance. Do not filter warnings or relabel absence as zero validation errors.

Pixel thresholds remain one 8-bit SDR / one 10-bit PQ code. Failed comparisons,
unsupported decoders, environmental failures and user feedback stay separate.
Use `run-case.py --self-check` for the offline launcher-status checks.
