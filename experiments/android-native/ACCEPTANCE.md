# Android native candidate acceptance

## Candidate identity

This candidate starts from delivery `130ebcf4af4e69dfaac0f68bf2dfd06c13105411`.
Only `experiments/android-native/` is new; stable OpenGL, Apple native source
locks and the other workspaces are unchanged. Source and patch identities are
recorded in `versions.env`.

The complete client patch is against official mpv-android `00a3b73f…`; mpv
`99177c09a…` already contains the native subtitle VO. The additional mpv patch
only enables the default-off Android FFmpeg native DV option. The Android build
does not apply the Apple VideoToolbox patch. Unrelated wid HDR experiments and
the private Maven mirror are excluded from the client source patch.

## Current checks — 2026-10-14

| Check | Result |
| --- | --- |
| Fresh remote Git sources and fixed release archives | Pass; no old native binary prefix copied |
| Patch hashes and complete patched source trees | Pass, before and after compilation |
| Offline source protection checks | 10 passed; includes archives, submodules and hidden tracked edits |
| ARMv7 / arm64 dependency, libmpv, JNI and debug APK builds | Pass, API 23 / NDK r29 |
| Actual Gradle build-tools selection | 36.0.0; SDK download disabled by the delivery entry |
| APK libmpv versus fresh JNI library hashes | Both architectures match |
| ELF load segment alignment | Both architectures: 16 KB |
| Pixel 4 native SDR / HDR10 runtime | Pass; actual Qualcomm `c2.qti.hevc.decoder`, no software fallback |
| Native HDR10 system output | `BT2020_ITU_PQ`, HDR metadata types 3; native video buffer 3840×2160 |
| Native SRT / ASS / PGS | Pass; 226 overlay readbacks across five cases, including PGS white/cyan/half-alpha probes |
| Native lifecycle | SDR and HDR10: five rounds each of video/overlay Surface rebuilding, rotation, background/foreground and two-file reload |
| Native real audio | SDR/HDR10: 60 seconds each, actual AudioTrack PCM stereo; user confirmed picture/sound and approximate sync |
| Default / gpu / gpu-next Render API | Pass; GLES 3.2, real FBO readbacks with video content |
| gpu-next DV-to-PQ | Pass targeted software-decoding check; RGB10/PQ, depth 10, actual target readback |
| Unsupported Pixel 4 native DV | Expected refusal confirmed; codec startup failed, software fallback disabled, no Render API fallback |
| ARMv7 runtime on Pixel 4 | Pass; actual 32-bit libmpv load, MediaCodec SDR and SRT pixel/control checks |
| Pixel 4 original APK | Restored without clearing data; restored APK SHA256 matches the pre-test backup |
| ARMv7 TV-box native SDR / HDR10 / DV Profile 5 | Targeted playback and subtitle checks passed; actual MediaCodec, HDMI SDR / HDR10 / DolbyVision-Std |
| TV-box real audio / human observation | SDR/HDR10/DV: picture, corresponding sound and approximate sync confirmed; see retained capture failures below |
| TV-box Surface lifecycle | Pass with state-based completion checks: five mixed-file rounds, 20 Surface actions and 15 SDR/HDR10/DV reloads; historical log-deadline failures retained |
| TV-box APK | Earlier restoration retained; this follow-up did not replace the installed APK, and the test app is stopped |

Google Maven TLS was unavailable even through the existing proxy. The private
Gradle environment used a mirror to download Java build dependencies; source
repositories and versions were not changed. No mirror configuration is shipped.
The tested SDK, NDK and Java installation were not upgraded.

There are 12 successful Pixel 4 runs, including one explicitly requested HDR10
audio replay, plus one expected native-DV refusal. SRT and ASS each passed ten
control rounds and five lifecycle rounds. The two PGS cases and the ARMv7 SRT
case each passed one control round. Pixel checks verify the separate subtitle
Surface, not video luminance. GUI timing statistics are not acoustic calibration:
the largest sampled native audible-run `|avsync|`, after the first five samples,
was about 1.27 ms. Human feedback only confirms approximate sound/picture sync.

The first HDR10 audible run completed automatically but was not observed. The
user requested a replay and then confirmed “都正常”; the SDR response was
“没有问题”. Only these observed runs supply human acceptance. The restored test
app is stopped; no test sound or window remains.

## TV-box follow-up

The same freshly built ARMv7 APK passed five complete runs: SDR/HDR10/DV short
playback and subtitle controls, plus two 60-second native-DV runs. Four accepted
cases provide 32 overlay readbacks; SRT/ASS visibility, clearing and antialiasing
passed, and the DV PGS case passed white/cyan/half-alpha probes. HDR10 remained
`HDR10-GAMMA_ST2084` and DV remained `DolbyVision-Std` while subtitles were visible.
The actual DV decoder was `OMX.amlogic.dolby-vision.dvhe.decoder.awesome2`.

The user confirmed normal picture, corresponding sound and approximate sync
for all three formats. SDR and HDR10 completed 60 seconds, but their original
whole-case receipts remain failed because logcat collection timed out. Two
HDR10 attempts ended early for the same collection error. These are not silently
reclassified as passing runs. The first successful DV run was not observed;
its explicitly requested replay supplies the DV human acceptance.

An initial five-round lifecycle run completed two rounds before a Surface-action
deadline. A shorter-controls retry and the previous accepted subtitle APK both
failed at the first Surface-hide action, using the same driver. The old APK
SHA256 was `34609cb60d2c145d88440b546a327617ac39bc0c10663e1239a4a5c2c1ecf14c`.
This did not establish a regression from the new packaging. At that point,
client stalling versus delayed log observation was unresolved and full TV-box
lifecycle acceptance was incomplete. The independent diagnosis and state-based
follow-up below resolve this observation failure; no renderer/decoder fix was
made.

The driver now retains one unfiltered device log stream and takes snapshots
from that stream, rather than issuing simultaneous logcat readers/dumps.
Original failed receipts and independent no-player logcat probes remain in the
private `results-box/` evidence. The box stayed at 4K60; no rotation, display or
system-volume changes were made. Its original APK was restored and stopped.

### Surface deadline diagnosis — later on 2026-10-14

The unchanged candidate passed one complete single-file Surface/overlay,
background and reload round. A five-round mixed-file retry completed three
rounds before the same Surface-hide log deadline; a separate repeat reproduced
it in the first round. Both failed receipts are retained.

During that separate log wait, independent IPC returned `vid=false`, no active
`current-vo`, a valid PTS and `pause=true`. The Activity's own view dump completed:
the player was `GONE`, the Activity was resumed, and the main thread was in
`ep_poll`, not blocked in native Surface teardown. This confirms an observation
failure for that Surface-hide deadline: the action completed without the
expected log reaching the driver. The precise log-loss/delay mechanism is not
established, and the historical failures are not reclassified.

Private diagnosis receipts are in `android-native-surface-20261014.wsyTET/`,
including the independent IPC/view dump. No client, decoder, VO or renderer
change is justified by this evidence.

### State-based completion follow-up — 2026-10-14

Only `run-case.py` changed: hide requires `vid=false` and no active VO; show
requires the native VO and actual MediaCodec decoder. Existing video/audio
progress and subtitle readbacks still verify recovery. Foreground completion
checks the resumed player Activity; background checks remain based on the real
Activity and pause state. The separate rotation-size check is unchanged. Logs
are retained, but Surface completion no longer depends on their delivery.
The 15-second state deadlines and 300-second overall deadline were not raised.

The mixed-file run passed in 230.443 seconds: ten subtitle-control rounds,
five lifecycle rounds, 20 verified Surface actions, five background/foreground
transitions and 15 SDR/HDR10/DV reloads. It produced 101 accepted subtitle
readbacks. Only one of five Surface-show completion markers reached the log,
despite all five verified reattachments and subsequent frame progress.

A final one-round mixed-file regression passed in 51.587 seconds, adding
14 readbacks. The existing pixel checker accepted all **115** transparent,
visible and antialiased subtitle readbacks; PGS was not rerun. Four final
offline state checks and three existing logging-failure checks passed. Genuine
incomplete states, unexpected VO errors and IPC failure cannot count as
successful detach/reattach. All earlier failed receipts are kept unchanged.

These checks were muted and did not replace the APK or change any display,
system-volume or network settings. The app is stopped and the existing ADB
server remains running. Source locks, compiled libraries and protected original
workspaces are unchanged; nothing was committed or pushed during validation.
Private follow-up receipts are in `android-native-surface-fix-20261014.AatlL0/`.

## Retained failures and limits

The first ARMv7 post-build guard rejected generated `_build_armv7l/` output.
The guard now permits only the two named architecture build directories in
FFmpeg/libass; source edits remain rejected. The initial Google Maven TLS
failure is retained separately from the successful build.

The first device wrapper rejected its own already-opened `.log` file. It now
checks the actual result/stream receipts for reuse. The next native SDR attempt
started a real Qualcomm MediaCodec decoder, but secure keyguard moved the
Activity to the background and released the Surface. It failed its deadline;
this is **not** recorded as runtime acceptance. After the user unlocked the
phone, the separately named SDR run passed; the failed receipts are retained.

The forced native-DV negative case retains its raw failed run/deadline record.
Its separate conformance check requires the actual codec-start error and
disabled software fallback, with neither a successful decoder nor Render API
initialization. It is not a successful native-DV playback result.

Pixel 4 reports HDR10/HLG, not Dolby Vision display capability. Native DV refusal
and existing gpu-next DV-to-PQ mapping must be kept separate. Historical TV-box
DV, Apple CI and subtitle results remain in their original reports; they do not
prove this new Android candidate passes. Absolute display luminance, every DV
profile, all devices and a new Android CI workflow are outside this stage.

No new production rendering defect was confirmed in this targeted scope. The
candidate-tool fixes were generated-build-directory handling, wrapper receipt
collision handling, explicit SDK-download refusal, single-stream log
collection and state-based Surface completion. Historical TV-box lifecycle
deadlines are retained, not converted into successful receipts; the new
state-based follow-up supplies the completed five-round acceptance.
The Android sources remain experimental, not a published or
every-device native-DV guarantee.

Private evidence is indexed by the independent candidate directory's build
case logs/JSON, `work/evidence/`, `results/`, `results-box/`, source-state receipts and saved
APKs. Media, screenshots, device IDs and library binaries are not committed.
