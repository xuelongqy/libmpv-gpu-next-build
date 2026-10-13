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
Local-only commits are not remote/CI reproducibility evidence. Stable OpenGL,
Vulkan locks, public API 2.8 and original maintenance workspaces remain unchanged.

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
the native mpv source was preseeded locally, so remote clean checkout and CI
remain unaccepted. Tests exited and left no playback/audio process running.

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
