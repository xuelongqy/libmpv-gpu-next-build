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
