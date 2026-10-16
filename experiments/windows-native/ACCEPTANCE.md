# Windows explicit native — directed acceptance, 2026-10-15

This document records the private candidate's 2026-10-15 acceptance and the
2026-10-16 maintenance decision. Source, scripts, captures and logs referenced
below are not included in this documentation-only archive.

This is the isolated, uncommitted candidate, not a stable native API release.
The path is libmpv software HEVC DV Profile 5 decode → installed Dolby effect →
RGB10/PQ or FP16/scRGB → DirectComposition, with a separate SDR subtitle layer.
It is **not** original DV/RPU HDMI tunneling. No FFmpeg patch is used.

## Maintenance decision — 2026-10-16

- Keep Windows native as a default-disabled, explicit-only experimental
  candidate. Pause expansion and productization; do not add it to `auto`.
- Windows' main playback path remains libmpv gpu-next, mapping DV to HDR or SDR
  as appropriate for the configured output. Original DV HDMI passthrough is
  not an accepted capability. Retain the native candidate as a system-Dolby
  processing reference, without claiming better quality or performance.
- Preserve the existing results, historical failures and transparent-first-frame
  limitation. This documentation decision changes no code, default/auto behavior,
  iOS/Android native path, renderer or stable OpenGL combination. No new runtime
  validation was performed for that decision; the candidate code remains
  uncommitted and unpublished.

## Source, binaries and environment

mpv base is `99177c09a62cac1cd64f8bb4065968d1edb3a046` plus the reviewed
candidate diff. Complete source archive, including the new untracked files:
`92ab197cfd23e749ce2d9137cd1aebf03c580a187296c161e2ce2c286751a9af`.
Tracked-diff SHA256 is
`81c674ef7cd58b77ec758491548e73455cb0930bb43cf96d3777c724270975d6`.

The fresh Windows directory is
`E:\Develop\C\libmpv-validation\windows-native-integration.iGgxyQ\acceptance-20261015.42A8M0`.
GCC/UCRT64 16.2.0 built the DLL and both clients; FFmpeg libraries are
avcodec 63.1.101 / avutil 61.1.101, with system libplacebo 7.360.1. OpenGL and
Vulkan are disabled in this candidate build; Windows native is explicitly enabled.

| Artifact | SHA256 |
| --- | --- |
| Candidate `libmpv-2.dll` | `45da7cb6f55643eb8570da8cd644bb598313547e5dd88cbf71a83642aae64d44` |
| Processor test | `aafcb6cb9ca27b68737f00c9096549d659446647eb81a3e7cc18370eb6d93ca4` |
| Initial windowed smoke | `bfc900c7d082c9eba2875ca36fe524df6c5d9411e6fd7055669658d73920aeb7` |
| Final fullscreen-capable smoke | `edbe7669302b524e7249b24d96b6a6ae64debd79d1236be0c9003f34f69572e7` |
| Final smoke source | `a671e254f4352000176db41ad3b0cf28062322d6ffff5ee363627e0ff4892eae` |

Process module logs confirm this exact DLL and the installed
`DolbyVisionAccess_2.20503.802.0` effect, not an older libmpv. The private runner
records binary hashes and arguments in a unique JSON receipt for every case.
Earlier executables, source and logs were retained before the client rebuild.

RTX 2070 SUPER driver is `32.0.16.1714`. A read-only interactive query confirms
TCL `DISPLAY2`, 3840×2160 at 60/1 Hz, HDR supported/enabled/active, reported HDMI
link depth 8 bpc. This is distinct from the RGB10 application target. DELL
`DISPLAY1` remains SDR; VDD is `DISPLAY5` and was not used for playback.
See `display-state.txt`, which reports `NO_SETTING_WRITE=already-enabled`.

The short DV file SHA256 is
`f0fd1f3ae2fa2d018264cc94b19860dbb27f9fddda425f41e902c406b7983c89`.
The existing 16-minute 3840×2160 HEVC/E-AC-3 clip is
`05fff57c8e2b4c91c99b4944b2f207a63eb394a319b59dca0ff032bb05f63fa8`.
`identities.json` retains paths and capture hashes locally. Neither media file is
included in source changes.

## Directed results

| Check | Result |
| --- | --- |
| Build, PowerShell parser, packing/RPU self-check | Pass |
| PQ and scRGB: eight processed frames versus real video backbuffers | All eight byte-identical in each mode; frame 1 transparent, frames 2–8 opaque |
| Separate BGRA overlay upload and transparent clear | Pass in both modes; processed video bytes unchanged |
| Dolby flush/reconfigure/redraw of the current frame | 20 resets per mode, all match the expected current-frame bytes |
| Public API context create/preload-render/free | 50 per mode, all pass with `gpu-debug=yes` |
| PQ processor D3D debug queue | Zero error/corruption messages; debug and non-debug frame-8 hashes match |
| scRGB processor D3D debug queue | Zero error/corruption messages |
| Fullscreen PQ, 60-second voiced playback with ASS | Pass, actual target 3840×2160, 1,441 processed frames, PTS 0→60, strictly increasing |
| Fullscreen scRGB, same 60-second voiced playback | Pass, same size/frame count/PTS checks |
| PQ public API lifecycle | Pass: three pause/exact-seek/skip/resume sequences, two reloads, ten resizes, stop/render/free |
| scRGB public API lifecycle | Pass: three pause/exact-seek/skip/resume sequences, two reloads, ten resizes, stop/render/free |

The fullscreen cases each present 1,442 times, sample subtitle text 60 times and
exit 0. Text changes first → second → third. Excluding the first five samples,
the largest logged absolute internal A/V difference is 0.012 ms in both cases;
this is **not** a physical audio-latency calibration. Both use the enumerated TCL
WASAPI endpoint, client volume 50, `MUTE=0`, and `HWDEC=no` throughout.

The user first reported that the 1000×640 verification window was too small;
that run is retained and is not counted as fullscreen visual acceptance.
A client-only `--fullscreen` switch was then added; its default remains windowed.
The initial source/executable were retained as `smoke-windowed-reviewed.*`.
The full-screen PQ replay received “都正常”; the scRGB replay received
“都正常，与 PQ 没有明显异常差异”, covering picture, subtitles and corresponding
sound. No color compensation or display/volume change was made.

Raw 4K captures are archived in `captures-r1.tar.gz` and extracted locally into
`captures/`; the transferred archive hash is
`50d139757a69ce65ec9572bac517c834fc4fc5ffdb3788e521a5a5c45779c01d`.
The scRGB frame-8 RGB range is approximately −0.00099468 to 2.189453125 with
alpha 1, retaining negative and above-one values. PQ frame 8 has RGB codes
0–574 and alpha 3. These checks establish encoding/storage, not physical nits.

## Foundation-test control

The candidate and a clean archive of base `99177c09` were independently built
with the same dependencies and options, with Windows native absent from the base.
Both libmpv suites have **24 passes and the same four failures**:
`locale.mkv`, `locale_forced.mkv`, `locale_complex.mkv` expect English but select
German/Polish; `libmpv-encode` reports `Unknown lavf format lavfi` with libavdevice
disabled by this minimal configuration. No assertion was skipped or changed.

The candidate's expanded default/render/auto selector test, software rendering
and libmpv lifetime test pass. `libmpv-tests.txt` and `baseline-tests.txt` retain
both complete console logs. This is not a passing full foundation suite, nor an
OpenGL playback regression run.

The first script invocation was blocked by the Windows execution policy before
building. Subsequent commands used process-local `-ExecutionPolicy Bypass` for
these reviewed scripts; the system policy was not changed. The initial console
error is recorded here, not presented as an archived disk log.

## Limits and reproduction

The transparent first processed frame remains a known, unresolved startup
limitation; historical independent system-decoder/effect probes also reproduce
it. Later valid frames and reset checks do not turn it into a first-frame pass.
The older Energy/Media Engine red-on-TCL observation is retained in the original
probe reports; it was not observed by the user in these two fullscreen cases,
but its original cause has not been identified or fixed.

These results cover only the tested software-decoded, single-layer DV Profile 5 scope,
not general SDR/HDR10 input, zero-copy, hardware decoding, native DV signaling,
absolute brightness or universal Windows device support. Default/auto selection
does not acquire this backend. The candidate production diff was not edited in
this round. All directed cases use the same newly rebuilt DLL; only the
independent client's fullscreen control and local reports were updated.
Final inspection found zero remaining candidate processes and temporary tasks;
all test windows and audio were closed. The production mpv/libplacebo workspaces
are clean at their original HEADs; the maintenance diff and stable OpenGL lock
hashes match the initial snapshot. That acceptance round made no commits or pushes.

From this candidate directory, use the existing runner in a process allowed to
execute the reviewed scripts:

```powershell
.\run.ps1 -WorkDir $PWD -Processor -Case processor-pq -TimeoutSeconds 90 -Arguments @(
  'E:\Develop\C\libmpv-validation\windows-native-20261014.CqkVvg\dv-p5.mp4',
  'pq', '\\.\DISPLAY2', "$PWD\pq-repeat", '--debug')
.\run.ps1 -WorkDir $PWD -Case lifecycle-pq -TimeoutSeconds 90 -Arguments @(
  '--display', '\\.\DISPLAY2', '--output', 'pq', '--lifecycle', '--seconds', '30',
  '--file', 'E:\Develop\C\libmpv-validation\vulkan-playback-av-20260909\dv-av-16m.mkv',
  '--sub', "$PWD\subtitles.ass", '--gpu-debug')
```

Substitute `scrgb` and distinct case/capture names for the other mode. Voiced
commands must re-enumerate and explicitly select the current TV audio endpoint;
do not reuse a historical device ID. Each static/playback case has its own bounded
runner deadline, and successful cases must have both process exit 0 and `RESULT=0`.
