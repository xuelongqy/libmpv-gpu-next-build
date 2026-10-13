# Apple native acceptance snapshot — 2026-10-12

Source identity is recorded in `versions.env`: mpv/libplacebo commits plus the
official FFmpeg base, patch SHA-256 and accepted patched tree. The patch contains
the exact FFmpeg changes previously committed as
`0e15ad76751cf51f7d988c89a393c0c1d11c54a8`; that local commit is provenance,
not a dependency to fetch. No renderer changes were introduced. Historical
binaries were built before committing (their version strings say `dirty`);
committing those trees is not a claim of newly rebuilt/retested binaries.
`client/smoke.m` SHA256 is
`79832b77392362172682f49ce1e63d0219af9ec619bbda465d63cfa6de25eef2`.

## Accepted checks

| Check | macOS M2 Max | iPhone 14 Pro |
| --- | --- | --- |
| SDR / HDR10 / DV Profile 5 native output | Pass | Pass |
| CVPixelBuffer identity / per-frame RPU probe | 24/24 | 24/24 |
| Parameter checks, 20 context cycles, pre-load render | Pass | Pass |
| 20 seek/skip cycles, OSD, screenshot refusal, stop/reload | Pass | Pass |
| Auto native selection, safe decoder rebuild/render fallback | Pass | Pass |
| Final uninstrumented interpolation-triggered fallback | Pass | Pass |
| Manual background/foreground | Not applicable | Pass, user confirmed |
| ASan/UBSan lifecycle | Pass | Not run |
| Original-film audio | User heard matching, roughly synchronized audio | User heard matching, roughly synchronized audio in short round |
| Original-film 15-minute native long-play, no looping | Pass: 901 samples, 21,621 frames | Retry pass: 902 samples, 21,644 frames |
| Final VO / decoder drops in long-play | 0 / 0 | 0 / 0 |
| Steady internal max absolute avsync | 0.3672 ms | 0.1615 ms |

Long input: 964.624-second 3840×2160 DV Profile 5 clip with its original EAC3
track, preserving the 16-ms video/audio start offset. SHA256:
`05fff57c8e2b4c91c99b4944b2f207a63eb394a319b59dca0ff032bb05f63fa8`.
Both clients hashed the same complete input. Outputs were PCM stereo, volume 50,
AVFoundation on Mac and AudioUnit on iPhone. Measured playback intervals were
900.0002 and 900.9987 seconds respectively. Physical long-round iPhone audio was
not separately reconfirmed; prior short-round feedback is distinct from statistics.

Mac late resident memory was approximately 257 MiB; iPhone footprint was about
398–404 MiB after warm-up, with declining resident memory. These are bounded-run
observations, not a general leak proof, absolute brightness calibration or a
physical millisecond sync measurement. Test windows/audio stopped afterward.

## Historical failures and limits retained

The final complete Meson result was **24 OK / 12 FAIL / 3 SKIP**, matching the
untouched private-FFmpeg baseline by test name/status. libmpv subset:
**14 OK / 12 FAIL / 3 SKIP**. Existing track/encode fixture failures and missing
`vstack` remain failures. The Apple/GL/Vulkan-disabled build compiled; its libmpv
subset was **13 OK / 12 FAIL / 3 SKIP**. Default old gpu and explicit gpu-next
both produced valid GL FBO content. No failures were filtered or renamed as passes.

Preserve the invalid early fixtures (stale Mac binary/current-GL-context issue,
iOS static-MoltenVK portability request/helper teardown, and nonexistent ASan
input). Corrected fixtures passed. CoreAudio OSStatus -50 reproduced on both
baseline and candidate; AVFoundation/AudioUnit passed without an audio backend
patch. Upstream multiple-RPU warnings during seek remain in private logs.

The first new Mac sound confirmation was unobserved; its replay was confirmed.
The first iPhone long attempt exited 1 at PTS 218.500 after a user-confirmed
incoming call. It remains incomplete, not passed and not a confirmed native
defect. A 200→240-second replay crossed that point, then the uninterrupted
15-minute retry passed. Do not claim call-interruption recovery from these tests.

The auto color-control issue found in review is folded into the mpv commit:
non-neutral equalizer/gamma options select render rather than silently staying
native. Transition drops remain recorded; safe fallback is not promised seamless.
The long-record checker now rejects `-O`, `-OO` and `PYTHONOPTIMIZE`. Ten offline
checks passed and saved real summary values stayed unchanged.

## Private evidence index

Raw logs, screenshots, samples, device/endpoint data, certificates and build
products are intentionally not tracked. The operator's private experiment keeps
`RESULTS.md`, `identity-review.json`, the `native-long-20261012.dlrECu/REPORT.md`
and all previous failed receipts. Long case prefixes are `macos-native-900`,
`ios-native-900` (interrupted), `ios-native-stall-pts200` and `ios-native-900-r2`.
Their case/report JSON and `media-long.sha256` can be supplied to `check-long.py`.
Historical local-only receipts do not establish remote or CI reproducibility;
the later remote rebuild is recorded separately below. Stable OpenGL, Vulkan
locks, public API 2.8 and original maintenance workspaces remain unchanged.

## Local packaging check

The five copied client sources match the accepted private files byte-for-byte.
The new compile-only entry built Mac and unsigned arm64 iOS clients; the packaged
Mac client completed a silent 3-second native check (94 frames, exit 0). Ten
offline checker cases and three invalid build-argument/source-SHA cases passed;
the real long summaries are unchanged. Bash/Python syntax, ShellCheck and staged
whitespace checks pass. No device reinstall, long-play rerun or CI run is implied.
The existing newer-macOS-dylib and duplicate-static-library link warnings remain.

## FFmpeg patch packaging check

The checked-in format-patch is byte-for-byte the export of the accepted FFmpeg
commit, including author and base information. Applying it to a separate clean
checkout of official base `bf1b838f2ab88b4f8fd83443325c782ea0e0f7fa`
reconstructed all 10,422 tracked files with tree
`d4908008dca897816a37f2e1b8d9cc305e69f766`, identical to the accepted commit.
The three changed files also matched byte-for-byte, and the caller's index hash
was unchanged; no changes were staged or committed.

Two clean preparations and ten rejection checks passed: wrong checkout SHA,
repeat application, missing argument, source subdirectory, staged/unstaged/
untracked edits, bad patch hash, bad expected tree and invalid lock. Each
rejection returned nonzero and preserved source contents, HEAD and index.
Bash syntax, ShellCheck and complete candidate-diff whitespace checks passed.
These are offline packaging checks using local Git objects, not new remote
checkout, CI, compilation or playback acceptance. Existing playback evidence
and historical failures above remain unchanged.

## Patch preparation review

The initial preparation entry falsely accepted a local `libavcodec/version.h`
edit hidden with `assume-unchanged`: Git status was empty, but the actual
patched source did not match the accepted tree. The earlier success log is
retained. Preparation now checks actual tracked files against the base using
its existing temporary index before applying any source changes.

Thirteen review checks passed: clean application and the ten original rejection
paths, plus hidden edits using `assume-unchanged` and `skip-worktree`. Rejected
inputs retained their bytes, index flags and staged state. Clean application
still reproduced the accepted tree, with the caller's index hash unchanged.
The patch/hash, client helper, stable locks and historical playback results
remain unchanged. No new compilation or playback acceptance is implied.

## Complete-entry locked rebuild — 2026-10-13

The new `build.sh macos|ios` rebuilt FFmpeg, libplacebo, libmpv and the packaged
client in fresh, separate platform directories. Source identity remained
mpv `8e68ec151e8011516160a1f353a6af67da9938e5`, libplacebo
`16140c6d4ee129d79746c89755e0631e065d423c`, official FFmpeg
`bf1b838f2ab88b4f8fd83443325c782ea0e0f7fa` plus the locked patch. The complete
patched tree was checked before and after compilation and remained
`d4908008dca897816a37f2e1b8d9cc305e69f766`. Existing prepared FFmpeg sources
were reused on retries only after the same read-only check; no source edits were
reset, cleaned or staged.

Mac runtime dyld records resolved libmpv and every FFmpeg/libplacebo library to
the candidate build/prefix, not the older private installation. iOS used freshly
rebuilt static archives, a newly signed app and an installation receipt with
bundle version `2026101301`; reports were copied from that app's Documents.
Headers came from the locked mpv checkout. The existing dependency archives and
digests were reused without SDK/dependency upgrades.

| Targeted runtime check | macOS M2 Max | iPhone 14 Pro |
| --- | --- | --- |
| Native SDR / HDR10 / DV Profile 5 | 3/3 pass | 3/3 pass |
| Explicit render, default old gpu / explicit gpu-next | 2/2 pass, valid GL FBO | Vulkan gpu-next pass, valid target readback |
| Auto SDR render / auto DV native | 2/2 pass | 2/2 pass |
| Interpolation-triggered native → ordinary decoder/render fallback | Pass, 77 valid GPU frames | Pass, 98 valid GPU frames |
| Native parameters, 20 context cycles, 20 seek/skip/screenshot-refusal cycles, stop/reload | Pass | Pass |

All **9 Mac and 8 iOS runtime cases** exited zero and reported zero render
errors. Native cases reported the actual `videotoolbox` decoder; render/fallback
cases reported ordinary software decoding and valid GPU target content. Both
lifecycle reports recorded 20 seeks, 20 skips and 20 expected screenshot
refusals. The separate software default/render/auto/unsupported-native check
passed. These were silent short regressions, not a new long-play, listening,
absolute-HDR-brightness or per-frame metadata-probe acceptance. The iOS Vulkan
fallback still uses static MoltenVK without validation; zero render errors are
not a validation-layer result.

Six offline patched-source checks passed, covering clean preparation/read-only
validation, repeat-apply refusal, unpatched/extra/hidden/staged/untracked edits
and preservation of caller contents/index. The unchanged default Vulkan iOS
FFmpeg entry rejected the prepared native source with exit 2 before configure.
Bash/Python syntax, ShellCheck and diff whitespace checks passed.

The first Mac build failed because the existing dav1d include-path workaround
had not been reused; the complete entry now uses the same flags as the Vulkan
desktop builder. That failure log remains. The first iOS attempt is invalid:
the entry was edited while Bash was waiting for a child build, so its resumed
file read failed despite completed compilation. The fixed, unchanged entry's
full retry passed. Do not count either first attempt as a passed build.
Existing newer-macOS-library and duplicate-static-library link warnings,
multiple-RPU seek warnings and historical Meson failures remain visible.

Evidence is retained privately under `.work/native-build-20261013.PZYqdm`:
`build-macos-r2`, `build-ios-r2`, `macos-native-dv`, platform `targeted-*.json`,
individual case/report pairs, installation/identity receipts and the rejected
`default-ffmpeg-refusal` case. Client and library SHA-256 values are in its
`evidence/identity.txt`. Original workspaces and all source locks are unchanged;
the native mpv source was preseeded locally, so that run did not establish remote
clean checkout or CI acceptance. Tests exited and left no playback/audio process
running.

## Entry review — 2026-10-13

Two tooling regressions were reproduced and fixed without changing any source
lock, patch, renderer or client. Empty optional arrays caused `set -u` failures
on macOS system Bash 3.2; iOS now forwards positional arguments, and the native
Mac builder uses the same approach for optional dav1d flags. The patched-source
check also falsely accepted a local `git add -N` file; making intent-to-add
entries visible to the index comparison now rejects it and preserves the file
and caller index.

Eight offline tests passed, including the two new regression checks. Under
system Bash 3.2, the original and candidate default iOS Meson arguments match
exactly; native adds only `-Dapple-native=enabled`. Mac dav1d-present/absent
checks pass. Original and candidate default iOS FFmpeg entries both configured
the clean official source using the real SDK: `config_components.h` is identical,
and other feature definitions match. `make` was replaced by a diagnostic no-op,
so this is a configuration comparison, not a new complete build. Wrong patch
hash/tree and both hidden-edit flags were also rejected without index changes.

Bash syntax, ShellCheck, Python checks and whitespace checks pass. Original
workspaces and stable/experimental locks are unchanged. Earlier runtime and
failure evidence above remains intact; no GPU, listening or long-play rerun is
claimed. Review evidence is private under `.work/native-entry-review-20261013.hLW28k`.

## Remote locked clean rebuild — 2026-10-13

The native mpv branch was published at
`feat/libmpv-native-output@8e68ec151e8011516160a1f353a6af67da9938e5`, and the
delivery branch at
`feat/apple-native-experimental-delivery@0604e5617af981f4a893797193c26e256d61208c`.
Both remote tips were checked with `git ls-remote`. A fresh remote delivery clone
built each platform in separate empty source/build/prefix directories, without
local source seeding, Git bundles or previously compiled libraries.

The source combination in `versions.env` is unchanged. FFmpeg came from the
official repository plus the checked-in patch; its complete tree matched
`d4908008dca897816a37f2e1b8d9cc305e69f766` before and after both builds. iOS
reused only checksum-verified dependency downloads, not old archives built from
the native sources. Mac and iOS builds exited zero in 313.102 and 279.640 seconds.
Mac runtime dyld records resolved libmpv, FFmpeg and libplacebo to the new
candidate. iPhone used freshly rebuilt static libraries and the newly installed
app at bundle version `2026101302`; matching reports were copied from its container.

| Targeted runtime check | macOS M2 Max | iPhone 14 Pro |
| --- | --- | --- |
| Native SDR / HDR10 / DV Profile 5 | 3/3 pass, actual VideoToolbox | 3/3 pass, actual VideoToolbox |
| Explicit render SDR | Default old gpu / explicit gpu-next: 2/2 pass | Vulkan gpu-next: pass |
| Auto SDR / DV / interpolation-triggered safe fallback | 3/3 pass | 3/3 pass |
| Native parameter and lifecycle checks | Pass | Pass |

All **9 Mac and 8 iOS cases** exited zero with zero render errors. Both platforms
completed 20 context cycles, 20 seek/skip/screenshot-refusal cycles, nonempty OSD
and stop/reload checks. Auto fallback recorded `native → render`, ordinary
decoding (`hwdec-current=no`) and valid GPU target pixels. Each platform's five
recorded DV display-layer inputs retained RPU attachments (**5/5**, not an
all-frame metadata probe). The software default/render/auto/unsupported-native
check and **8/8 offline patch/local-edit protection tests** also passed.

Private evidence is under `.work/native-remote-20261013.qjdSKe`: `REPORT.md`,
`build-*.json/log`, `targeted-*.json`, unique `remote-*` case/report pairs,
`ios-install` receipts, `artifacts.sha256`, `inputs.sha256` and
`runtime-loaded-libraries.txt`. Historical failed receipts remain intact.
Tests exited with no remaining Mac/iPhone playback process.

This accepts remote clean builds and silent targeted regressions, not native CI,
a new long-play/listening run, the full Meson/pixel matrix or iOS Vulkan
validation. Prior failures and unverified capabilities remain as recorded above.
Renderer, stable source locks, tags and original workspaces are unchanged;
no additional production-code changes were needed.

## Native CI build acceptance — 2026-10-13

The native workflow built the unchanged source combination from remote locks on
`macos-15`. FFmpeg remained official source plus the checked patch; no renderer,
source lock or stable OpenGL change was needed.

| Delivery commit / run | Mac native | Unsigned iOS native |
| --- | --- | --- |
| `0737c96` / [first run](https://github.com/xuelongqy/libmpv-gpu-next-build/actions/runs/38340603140) | Pass | Build passed; artifact check failed |
| `3c93209` / [fixed run](https://github.com/xuelongqy/libmpv-gpu-next-build/actions/runs/38341166678) | Pass | Pass |

The first iOS artifact check used `lipo -verify_arch arm64` before the input
file. Xcode 16.4 interpreted the file path as another architecture and exited 1;
that run remains failed. Commit `3c93209` changed only the two commands to
`xcrun lipo "$client" -verify_arch arm64` and
`xcrun lipo "$library" -verify_arch arm64`, retaining both ARM64 checks.

The fixed run passed SDK/tool checks, all eight offline patch-protection tests,
the complete locked-source builds, library/client artifact checks and summaries
for both platforms. The iOS app was not provisioned or installed; no binaries
were published. This is build/patch acceptance only, not a new device playback,
audio, HDR-display, full Meson suite or Vulkan validation result. Earlier failed
runs and runtime limits remain recorded above.

## Native subtitle candidate — 2026-10-13

This is an **uncommitted, isolated candidate**, not a source-lock update or CI
result. Apple production code is unchanged. Native-only FFmpeg build options
enable existing SRT/ASS/SUP demuxers and ASS/SubRip/PGS decoders; its accepted
patch and source tree still match `versions.env`. The default iOS/Vulkan build
arguments are unchanged. Android adds an optional transparent OSD Surface to
`mediacodec_embed`; MediaCodec continues to own the separate video Surface.
No gpu-next renderer, decoder or FFmpeg source changes were added here.

| Check | Result |
| --- | --- |
| Mac / iPhone SRT, ASS, PGS; HDR10+ASS; DV Profile 5+PGS | 5/5 each; bitmap timing, alpha and palette checked |
| Mac / iPhone pause, seek, visibility, delay, track selection, resize and stop clear | 10 cycles each |
| Pixel 4 SDR SRT/PGS and HDR10 ASS/PGS | Pass; actual MediaCodec; overlay readback checked |
| Pixel 4 control / rotation / Surface / background / reload | 10 control cycles; 5 lifecycle cycles |
| TV box SDR+PGS, HDR10+ASS, DV+SRT/ASS/PGS | Pass; initial HDMI sampling was during the subtitle gap; visible-subtitle follow-up below |
| TV box Surface, background and reload | 3 cycles with DV+ASS; restored subtitle pixels checked |
| Android default / old gpu / gpu-next | Valid short playback; render paths do not create the native OSD Surface |

PGS palette checks preserve transparent pixels and half alpha, with white/cyan
color probes within one 8-bit code value. ASS positioning and animation passed on Apple. Android
readbacks confirm an independently transparent subtitle Surface; they are not
video/HDR screenshots or proof of absolute subtitle luminance.

Historical failures remain in the private evidence. The first Android rapid
track change left stale text; deferring OSD redraw until the VO core consumes
its request passed the unchanged 10-cycle reproducer. Raw SUP seeking into a
display set was also empty on the unchanged Apple native VO. The same PGS
segments, grouped with FFmpeg's existing `pgs_frame_merge` filter into Matroska
while preserving PTS, passed seeking on both paths; no subtitle decoder patch
was made. The first remux accidentally rebased timestamps and remains failed.
The TV launcher does not consistently call `onStop`: background checks now
require a different resumed activity and paused mpv, then verify resumed audio,
video and subtitle pixels; explicit Surface destruction is tested separately.

Eight offline build tests and syntax/diff checks passed. ShellCheck retains the
two existing dynamically-sourced-variable warnings. The available Mac Meson
run was 16 OK / 20 FAIL / 3 SKIP, identical by name/status to its unchanged
baseline; missing generated fixtures, `vstack` and encode failures are not
passes. No full sanitizer or new physical subtitle-brightness acceptance is
claimed. Private evidence is `native-subtitles-20261013.YubNVy/REPORT.md`;
all original source workspaces, locks, tags and dirty diffs remain unchanged.

The final packaged clients repeated Mac default/native and 10-cycle subtitle
checks, iPhone 10-cycle controls and DV+PGS pixel/RPU checks, and Android
gpu-next/DV+PGS checks successfully. The first final iPhone launch was denied
because the device was locked; that failed receipt is retained separately.

### Subtitle review follow-up

The new OSD initialization failure paths now release the native window, device
reference and device list before returning: VO core does not call `uninit()`
after failed `preinit()`. Five counted-resource failure checks passed; this is
an offline check, not a device-loss test. Normal native/GPU behavior is unchanged.

Pixel 4 passed two cycles and the TV box one cycle destroying/recreating the
video and subtitle Surfaces separately, followed by foreground/rotation/reload
checks as applicable. Restored subtitle pixels and playback progress passed.
The box additionally reported `DolbyVision-Std` and `HDR10-GAMMA_ST2084` while
the subtitle was actually visible. Default, gpu and gpu-next short regressions
passed on Pixel 4. No fresh user brightness or sound confirmation is implied.

Evidence checkers now reject `-O`, `-OO` and `PYTHONOPTIMIZE`, using the existing
long-check policy; 12 optimization and two corrupt-evidence checks passed.
Apple subtitle controls also retain the client's progress deadline: a stalled
SUP-seek negative case exited 1 itself in 17.018 seconds, not external timeout.
The normal ten-cycle control check and Mac/unsigned-iOS compilation passed.
Historical failed records are kept, and no renderer or source lock was changed.

### Subtitle publication — 2026-10-14

The reviewed native VO change is saved as mpv
`99177c09a62cac1cd64f8bb4065968d1edb3a046` on
`feat/libmpv-native-subtitles`, based on the accepted Apple-native snapshot.
That commit changes only `video/out/vo_mediacodec_embed.c`, including the
initialization-failure cleanup. The native experiment now locks this commit;
the stable OpenGL/Vulkan locks, FFmpeg patch/tree and libplacebo lock are unchanged.

The Android client's five-file subtitle delta is preserved in
`android/subtitles.patch`, with its exact candidate preimages documented beside
it. Earlier Android DV decoder/client changes are not folded into this commit
or source lock. Device results above used those earlier candidate prerequisites;
they are not remote-clean-build acceptance of the published Android snapshot.

Publication checks repeated the five resource-cleanup cases, twelve optimized-
Python rejections and two corrupt-evidence rejections. Earlier runtime results
and failures remain unchanged. Pixel 4 and the TV box were restored to their
pre-test APKs; the installed APK hashes matched the backups. The box temporarily
disconnected after testing, then restored successfully without clearing data,
replaying media or changing TV/network/volume settings. No full sanitizer or
additional physical iPhone test was run for publication; new CI results must be
reported separately from the earlier native build acceptance.
