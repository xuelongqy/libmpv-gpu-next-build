# Windows explicit native integration — 2026-10-15

Documentation-only archive; source, scripts, logs and binaries remain in the
private candidate. Statements about uncommitted changes refer to that candidate,
not to these archived documents.

## Current state

Implementation is isolated and uncommitted. Windows validation was initially
paused when the user needed the computer, then resumed with explicit permission
after the TCL was reconnected. The new directed results are recorded separately
below; the pre-pause results remain associated only with their old binaries.

Candidate base: mpv `99177c09a62cac1cd64f8bb4065968d1edb3a046`.
Production mpv and libplacebo are untouched. FFmpeg is unmodified.
Default/auto routing remains unchanged; the Windows backend is explicit-only
and disabled by default at build time. Existing enum values and client API 2.8
are unchanged; two experimental Windows render parameters are appended.

Maintenance decision (2026-10-16): keep this default-disabled, explicit-only
candidate and pause expansion. Windows' main playback path remains gpu-next
for DV-to-HDR/SDR mapping, not original DV HDMI passthrough. See the
[decision record](ACCEPTANCE.md#maintenance-decision--2026-10-16).
This is documentation only; earlier results and failures are unchanged.

## Evidence from before Windows was paused

Remote directory:
`E:\Develop\C\libmpv-validation\windows-native-integration.iGgxyQ`.

| Check | Result |
| --- | --- |
| MSYS2 UCRT64 candidate libmpv and smoke build | Passed for the pre-pause source, OpenGL/Vulkan disabled |
| Loaded-library identity | Process module list confirms this candidate `prefix\bin\libmpv-2.dll`, system FFmpeg DLLs and installed `DolbyVisionPlugin.dll` |
| Display enumeration | DELL `DISPLAY1` SDR; TCL `DISPLAY2` HDR-active at `(3360,0)-(7200,2160)`; VDD `DISPLAY5` HDR-active |
| Explicit PQ context, render before loading, free | Passed, reported actual output mode `native` |
| PQ software DV + external ASS, 8-second smoke | Exit 0, 180 render calls, decoded PTS reached 7.458 s; subtitle text advanced first → second → third; stop/render/free completed |
| Pixel/color/physical-TV observation | Not established by that smoke; API success and subtitle text alone are not visual/pixel acceptance |

The 8-second duration was the earlier client's wall-time limit, not eight full
seconds of effective video. Its duration gate has since been corrected to start
at the first backend-present submission; that client correction is untested on
Windows. It must not retroactively change the historical result.

Successful pre-pause log:
`windows-native-pq-subtitle-fixed-f67d924d48f745dab70e705895b50337.log`.
Its receipt has client SHA256
`9b6063b61507bb57282b50bcd204b516eb9930a141cfcbf3bba9bcd39a667ad7`
and libmpv SHA256
`d8e30c726934a8505dc818e4384a6f504373d00e3bc81a0307bbe381ee9bc782`.
These identify the pre-pause binary, not the final local coding candidate.

## Local checks while Windows was paused (historical)

- macOS no-OpenGL/no-Vulkan build passed with system FFmpeg 9.0.2 and libplacebo
  7.360.1; Windows native was disabled. No system dependencies were replaced.
- Full Meson tests: **35 passed, 3 locale skips, 0 failed**. The skips return 77
  and are not counted as passes. libmpv suite: **25 passed, 3 skipped, 0 failed**.
- Expanded existing render-parameter test covers default/render/auto actual-mode
  reporting and rejects invalid or incompatible policies.
- C11 and C++20 compilation of the experimental header passed with warnings as
  errors. Client API, old selector/Vulkan/Apple enum values and 64-bit new header
  layout assertions passed. This is not Windows execution or ABI stabilization.
- `git diff --check` passed. No renderer/decoder/Apple/Vulkan implementation
  changes are present in the candidate.

Local changes since the pre-pause Windows binary included cleanup-error
propagation, filtered-input rejection, stronger client timing/control checks and
black child-window background. At that stage they still required a fresh Windows
build and regression, and the new white-box processor test and modified PowerShell
build branch had not yet been compiled/run there.

## Local review follow-up

The review found three issues in the private tools, not in the native processing
or shared renderer. They have been corrected locally:

- A window resize now requests a render even without a new video frame, so a
  paused video's geometry and subtitle target can be updated.
- Stop-command failure, stop timeout, and rendering errors during shutdown now
  fail the smoke result rather than allowing an apparent successful cleanup.
- The build script rejects a missing source directory instead of extracting
  `source-initial.tar.gz`, which predates subsequent candidate fixes.

The local macOS build and full Meson suite passed again: 35 passed, three locale
skips, zero failures. C11/C++20 header checks passed. The existing packing/RPU
self-checks were compiled directly from the adapter and processor test sources
on macOS with ASan/UBSan and passed; this does not exercise Windows APIs.
No further confirmed production defect was found in subtitle caching, serialized
cleanup, or default/auto selection. At that stage the tool fixes still required
Windows compilation and runtime regression; no Windows connection or test was
used for that review. PowerShell was unavailable locally, so its parser was not run.

## Resumed Windows directed acceptance

The reviewed source was rebuilt in a fresh private Windows directory. See the
[directed acceptance report](ACCEPTANCE.md) for exact
source and binary hashes, commands, raw captures and result receipts.

Both modes passed target readback/overlay/clear checks, 20 current-frame resets,
50 context create/free cycles, and a public-API lifecycle case with three
pause/exact-seek/skip/resume sequences, two reloads and ten resizes. Their processor
tests report zero D3D errors. The first transparent frame remains a separate limit.

The initial small-window PQ playback completed, but the user requested a larger
picture. A client-only fullscreen flag was added without changing its default.
The subsequent native 3840×2160 PQ and scRGB cases each completed 60 seconds with
the audio-bearing original clip, the freshly enumerated TCL WASAPI endpoint and
client volume 50. The user confirmed normal picture, subtitles and matching sound
in both; scRGB had no obvious abnormal difference from PQ. No physical brightness
calibration or DV HDMI signaling is claimed.

The candidate and clean base each have 24 passing libmpv tests and the same four
failures: three locale/track-selection cases and the minimal-config encoding case
with libavdevice disabled. Selector/default/auto, software rendering and lifetime
tests pass. The complete suite is not reported as passing.

The earlier TCL-red/Moonlight-normal observation is a separate unresolved display
path issue reproduced with Energy and system Media Engine. It was not observed
by the user in the new fullscreen cases, but its historical cause is not claimed
fixed. No compensation, renderer change, NVAPI DV-mode switch or DV HDMI
passthrough claim is added.

## Protected state

- Original mpv remains clean at the candidate base.
- libplacebo remains clean at `b7779734692e4b6fbd72987976aa11aad51f7ee7`.
- Original maintenance tracked-diff SHA256 remains
  `0531b98032e330b9c7bd29f5885f0dec3ebe56f587e293feca06f93fffb3ca6b`;
  its pre-existing untracked test script is untouched.
- Stable `versions.env` SHA256 remains
  `9d5a89adfe3aee2338c2da27ec9e5fdfc89b385de026608e4667c5b056e8cd63`.
- No commit, push, tag, source-lock update, system-volume change or display-setting
  change is made by this candidate work.
