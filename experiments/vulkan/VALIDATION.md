# Delivery validation

Status: the current Vulkan source lock was revalidated on macOS after the
2026-09-28 upstream sync. Windows has not yet been rerun against this new lock;
the Windows results below are retained evidence for the previous validated lock.
This is not an all-tests-pass result, stable release/tag, or remote CI result.

Worktree base: `1245b72645002e9e284b42fcdd5588d06abc321e`, branch
`feat/vulkan-experimental-delivery`. This branch contains the experimental
delivery, separate from the stable maintained line. Production sources are
exactly the two commits in this directory's `versions.env`.

Resolution qualification: the earlier desktop matrices and voiced runs below
used a 960x540 render target unless explicitly noted. A 4K display mode and a
4K decoded source did not make those native-4K rendering tests. The Windows
native-4K follow-up is recorded separately below.

## 2026-09-28 upstream-sync revalidation

- mpv: `b91f8e58e51e75f68232b720352fdcfd6929e1b3`
- libplacebo: `5101de2b9354789a019d1933bc45e43b0ee65059`
- macOS build/install completed against the private candidate prefix.
- libplacebo tests: 14 pass, 0 fail, 2 environment skips; libmpv suite:
  25 pass, 0 fail, 3 locale skips.
- MoltenVK probe passed on Apple M2 Max with validation enabled. The DV Profile 5
  sample at PTS 600 rendered SDR, PQ and scRGB through both offscreen and window
  targets; all six runs reported `VALIDATION_ERRORS=0` and `RESULT=PASS`.

Runtime linkage confirmed the smoke client loaded the candidate libmpv, and that
libmpv loaded the candidate libplacebo. Stable root locks, tags and production
source were not changed by this revalidation.

## Previous locked delivery: macOS

The bundle-seeded sources were built into a new private prefix. Neither the old
smoke source directory nor its library prefix was used at build/runtime. Test
media and reference captures were copied separately into the ignored work root.
Runtime dyld records confirm both candidate libraries came from
`.work/vulkan/prefix-277d89841f3e/lib/`; the header came directly from
`.work/vulkan/src/mpv/include/mpv/render_vk.h`.

Environment: Apple M2 Max, MoltenVK, Vulkan device API 1.2.357, validation enabled;
Apple Clang 21.0.0, Meson 1.12.0, shaderc 2026.3.1, SDL2 2.32.70 and Vulkan
headers 1.4.357. Full tool, loader, layer, audio and display identities remain
in the private evidence, not in public machine-specific configuration.

| Check | Result |
| --- | --- |
| Fresh libplacebo, libmpv, standalone and smoke build | Pass |
| SDR/HDR10/DV × SDR/PQ/scRGB × offscreen/window | 18/18 pass; validation zero |
| Same-platform saved target comparisons | 18/18 pass; SDR maximum 1 code, PQ 0 codes, FP16 0 ULP |
| Parameter probe, submission-failure injection, 50 context cycles | Pass; validation zero |
| Copy-back PQ lifecycle | 100 resize/retire, 20 source changes, 20 seek/skip/screenshot/resume cycles pass |
| Lifecycle screenshot/target comparisons | 20/20 pass; original one-code PQ threshold |
| PQ + VideoToolbox-copy + PCM stereo, client volume 50 | 60.005 seconds completed; exit zero, validation zero |
| libplacebo Meson tests | 15 pass, 0 fail, 1 skip |
| mpv full Meson tests | 35 pass, 0 fail, 3 skip |
| libmpv suite (also included in full suite) | 25 pass, 0 fail, 3 skip |
| Right-click/Space/Esc input and volume argument checks | Pass |
| Offline lock/dirty-source/SHA/timeout/unsupported checks | Pass |
| Shell syntax, ShellCheck, Python compilation, diff whitespace | Pass |

The skipped checks are libplacebo `opengl_surfaceless.c` and mpv's three locale
cases (`locale`, `locale_forced`, `locale_complex`); skips are not passes. Media
generation was not bypassed. The initial fresh build failed because the delivery
script supplied dav1d includes to C but not C++ header tests. Applying the same
include flags to both languages fixed this tool defect; both build logs are
retained. No production code was changed. Existing auto-profile hook warnings
also occur in the saved reference logs and were not filtered or relabeled.

The new voiced run verifies the selected real endpoint, PCM audio progress and
video timing. No new physical listening feedback was obtained in this run;
historical listening/synchronization observations below remain separate. The
15-minute tests were not repeated. All local test processes and windows exited.

### Candidate identity and private evidence index

SHA-256 (local binaries, not published artifacts):

```text
smoke        ecff7d236da4c8f73974cdaad7c6a7b630cdd505af5f40b88eeaff2d6c25cd32
libmpv       e062208f9a9703e82ccab31d521c62a44a94e464fa265777765a94cfe84529c7
libplacebo   b8539b12f6aec72208997c166f42bf076b060d99a1dacb0d23fb0b583e56c853
standalone   8f8aa70f65b8927ba968403a17f85c674b0014fc6575565d8fecf5921b6c6ded
render_vk.h  9441f31b43ee8f3965cc7eab95eba69f96cdc17d29fcb082ba7de7f6c9df421e
```

Paths below are relative to the repository's ignored `.work/vulkan/evidence/`:

- `source-provenance.sha256`, `smoke-migration.diff`, `macos-migration.diff`:
  input/migration identity; `binaries.sha256`: candidate library/header hashes.
- `tools.txt`, `linkage.txt`, `build-macos-r1.log`, `build-macos-r2.log`:
  tools, linkage, retained failed build and successful retry.
- `matrix.k5g_iaa2/summary.json`: 18 cases and baseline comparisons; adjacent
  per-case JSON/logs retain commands, media hashes, actual libraries and outputs.
- `controls.v7phtwd4/summary.json`: probe, injected failure and context cycles.
- `lifecycle.ciw4omel/summary.json`: lifecycle and 20 pixel comparisons.
- `av.sh7c0fc7/summary.json`: 60-second voiced run and resource samples.
- `tests.tWx7QF/`: separate libplacebo, full mpv, libmpv and input logs.
- `input-test.log`, `volume-tests.log`: migrated input/argument checks.
- `windows-ssh-final.log`: bounded connection failure, not a build failure.

## Windows delivery status

The 2026-09-10 continuation reached the Windows host and used a new, bundle-seeded
candidate directory. libplacebo, libmpv, standalone and smoke were rebuilt from
the locked sources; no previous library prefix or smoke binary was copied.
The previously saved SSH failure remains in the evidence.

Environment: NVIDIA RTX 2070 SUPER, Vulkan device API 1.4.341, synchronization
validation layer 1.4.357; UCRT64 GCC 16.2.0, Meson 1.12.0, FFmpeg 9.0.1,
SDL2 2.32.10 and shaderc 2026.3.1. SDK headers/layer came from the previously
validated SDK, without upgrading the system. Python 3.14.7 uses NumPy 2.5.2 and
Pillow 12.3.0 unpacked into the private candidate area, not installed globally.

During the initial Windows run only one SDR monitor was connected: the read-only query reported no HDR support
and no TV HDMI audio endpoint. The user chose to connect the TV later. No display,
HDR, refresh-rate, audio endpoint or system-volume setting was changed.

| Check | Result |
| --- | --- |
| Fresh libplacebo, libmpv, standalone and smoke build | Pass after the path correction below |
| Three samples, all three outputs, offscreen targets | 9/9 pass; validation zero |
| Three samples, SDR window targets | 3/3 pass; validation zero |
| Three samples, PQ/scRGB window targets | 6 unsupported (77); not HDR presentation passes |
| Saved same-platform target comparisons | 12/12 pass, exact pixels: SDR 0 codes, PQ 0 codes, FP16 0 ULP |
| Parameter probe, submission-failure injection, 50 context cycles | Pass; validation zero |
| Copy-back PQ lifecycle and 60-second voiced playback | Not run: required HDR display and TV endpoint absent |
| libplacebo Meson tests | 14 pass, 1 skip, 1 timeout after format assertion |
| mpv full Meson tests | 26 pass, 12 fail |
| Separate libmpv suite | 15 pass, 13 fail |
| Right-click/Space/Esc input and volume argument checks | Pass (automated input checks, not a fresh TV observation) |
| Offline tools, including comparison exceptions | Pass on Windows and macOS |

All 12 successful case media hashes match their historical reference cases.
The unmodified pixel thresholds were used. The matrix exits 77, not zero, because
six cases cannot run on this display. Normal Render API cases report zero
validation errors; pre-existing overlay naming warnings remain in the logs.

The base-test failures are not integration passes. The libplacebo Vulkan test
again reaches `gpu_tests.c:1702`, `msb >> 6 == lsb` (521 vs 520), then times out.
The twelve track-selection failures have the same names and `0xffffffff` exit
codes as the saved baseline. Lifetime passes in the full suite but fails in the
separate suite with `0xc0000409` and the same
`GGML_ASSERT(prev != ggml_uncaught_exception)` message. These signatures were
compared with retained pre-delivery logs; no new baseline build or deeper cause
analysis was performed. Media generation was not skipped and `tests.sh` returns
1. The skipped test is `opengl_surfaceless.c`, not a pass.

### Windows tool corrections and runtime identity

- The initial private preparation lacked NumPy/Pillow; both were isolated as
  described above. The loader's system pkg-config entry also lacked usable SDK
  headers, so the existing SDK include directory was supplied through `CPATH`.
- With inherited MSYS pkg-config paths, the build script's native drive-letter
  prefix produced a mixed path list and selected system libplacebo 360. The final
  import check rejected the build. Keeping the prefix entry in MSYS form fixes
  native-process path-list conversion; a two-case reproduction records the
  old selection of 7.360.1 and the corrected selection of 7.371.0.
- The offline test helper's unqualified `bash` selected Windows' WSL launcher.
  It now resolves executable paths with `shutil.which`, as the case runner already
  does. The before/after shell probe and full offline tests cover this correction.

Only delivery tools were corrected; production source, renderer behavior and
pixel thresholds were unchanged. Failed preparation/build/test logs are retained.
The final build identifies `libplacebo-371.dll` in libmpv's imports. Session-1
process module snapshots confirm candidate libmpv and libplacebo paths, the actual
system Vulkan loader, NVIDIA driver and the private validation layer. FFmpeg
`avfilter-12.dll` separately imports system libplacebo 360; its presence is not
evidence that mpv used that library for rendering.

SHA-256 (private Windows binaries, not published artifacts):

```text
smoke        b3f93ae4579f88997fb3991b52f67fcda60270329fc59c19ca2477ee5a841667
libmpv       02ca907b7ce709b16ee04ba5dd8f1f1eca2342a1df5eba016cb7d925b0e0c7da
libplacebo   1b635adcb4f29ec82f3e2a8c2f2d1167a668890bbb1045494047cf4977a8f1b7
standalone   ec2d38fc6c5b179bae2b8e6a021f0927c604ff3c5bb49c1ab53371810473faeb
render_vk.h  9441f31b43ee8f3965cc7eab95eba69f96cdc17d29fcb082ba7de7f6c9df421e
```

Private evidence is copied to `.work/vulkan/windows-delivery-20260910/evidence/`:

- `identity.txt`, `tools.txt`, `linkage.txt`, `*-modules.json`: source, header,
  library, SDK and actual process identities.
- `build-r1.log` through `build-r4.log`, `pkgconfig-paths.log`, `shell-paths.log`:
  failed preparation, two failed builds, successful build and direct tool probes.
- `matrix.o04uk448/summary.json`: 12 passes/comparisons and six unsupported cases.
- `controls.6o2bmg7u/summary.json`: parameter, fault and context results.
- `tests.w2udtr/`, `libplacebo-test-detail.log`, `libmpv-test-detail.log`: all base
  test results and diagnostics, including failures.
- `offline-r1.log`, `offline-r2.log`, `inputs-r1.log`: retained pre-fix failure,
  successful tool regression and input/volume checks.
- `reference-cases/`, `reference-identities.sha256`, `tooling-final.sha256`:
  comparison inputs and exact migrated tool identity.

The transferred evidence archive SHA-256 is
`0688a40765ebfbe6b0c02d2ad9d4254ed5428ab3131db5dbf7e701b4f4a8ee1e`.
No candidate process or temporary delivery task remained at the final query.
No voiced test was started in this continuation. HDR window, copy-back PQ
lifecycle and 60-second TV playback remain required before Windows delivery
acceptance; historical TV results do not replace them.

### TV reconnect preflight (2026-09-10)

The TV and its HDMI audio endpoint are available again, but two read-only
queries report 3840x2160 at 120 Hz, HDR user preference enabled and actual
advanced color mode SDR (`ACTIVE_MODE=0`). This matches the earlier retained
120-Hz observation; previous successful TV runs used 4K60 with active HDR.
The client/library/header hashes still match the candidate identities above.
No new HDR playback or voiced test was started. Changing the TV refresh rate
requires confirmation; no display or audio settings were changed. No temporary
task or candidate process remained after the queries. Their logs are retained
under `.work/vulkan/windows-delivery-20260910/tv-reconnect/`.

### Authorized TV continuation (2026-09-10)

After user confirmation, only the TV was changed from 4K120 to 4K60. The
follow-up query confirms actual HDR active (`ACTIVE_MODE=2`), not just the HDR
preference enabled. The other monitor, HDR preference, system volume and default
audio device were not changed. The link still reports 8 bpc; the client's RGB10
target does not establish a 10-bit wire format. SDL display selection was
verified against the TV, not inferred from its primary-monitor status.

The repeated 18-case matrix now passes on the TV, including all six previously
unsupported HDR window cases. All 18 saved-platform comparisons are exact:
SDR 0 codes, PQ 0 codes and FP16 0 ULP, with zero validation errors. The candidate
binaries are unchanged; no matrix threshold or presentation compensation was
added.

The first voiced lifecycle attempt failed before exercising the stress loops.
The recorded command contained the complete WASAPI device ID, but MSYS startup
globbing removed its braces when Windows Python launched Bash. An isolated
argument-only reproduction shows the same loss without loading libmpv. The case
runner now disables MSYS startup globbing in its Windows child environment;
it does not change audio devices or fall back to null/default audio. The new
offline round-trip check covers braces, brackets, wildcard characters and spaces.
Full offline, input and volume checks pass on Windows; the offline suite also
passes on macOS. The failed lifecycle log is retained, not overwritten.

| Check | Result |
| --- | --- |
| SDR/HDR10/DV × SDR/PQ/scRGB × offscreen/window | 18/18 pass; validation zero |
| Same-platform saved target comparisons | 18/18 pass; all differences zero |
| PQ + D3D11VA-copy lifecycle | 100 resize/retire, 20 source changes, 20 seek/skip/screenshot/resume cycles pass; 160.686 seconds |
| Lifecycle target/screenshot comparisons | 20/20 pass; maximum one 10-bit code, threshold unchanged |
| PQ + D3D11VA-copy + real HDMI PCM stereo, volume 50 | 60.035 seconds completed; exit zero, validation zero |
| Load-before/stop-after no-video render and context destruction | Pass in lifecycle and playback |

The voiced run continuously reports `d3d11va-copy`, p010 Dolby Vision input,
the explicitly requested WASAPI endpoint and 48 kHz stereo float PCM. Both PTS
counters advance. After the first five seconds the maximum sampled absolute
internal `avsync` is 0.017 ms; both reported drop counters stay zero. This is
player timing, not a physical speaker/display latency measurement. The user
missed the first listening check and requested a replay with unchanged settings;
during that replay they confirmed the movie was audible. No new physical
audio/video latency or PQ/scRGB equivalence judgment was requested or inferred.
Historical synchronization/brightness observations remain separate.

Native process sampling explicitly follows the candidate `smoke.exe` path:
the 60-second run has 22 resident-memory samples ranging from 659.5 to 680.7 MiB,
with 47.47 CPU seconds between its first/last samples. Lifecycle samples and the
failed first attempt are also retained. The generic case runner's Windows
resource records sample its Bash wrapper, not the renderer; do not use them as
renderer memory/performance evidence. These short runs are not a leak proof or
a standalone performance comparison.

Current TV evidence is under the ignored
`.work/vulkan/windows-delivery-20260910/tv-final/`:

- `matrix.cwf07fvv/summary.json`: all 18 cases and comparisons.
- `lifecycle.gjm8ct_4/`: retained pre-fix endpoint failure;
  `lifecycle.j6uorcpu/summary.json`: successful retry and 20 pixel checks.
- `av.wponet1w/`: 60-second playback, commands, media hash and metrics.
- `av.5nd99bvs/`: requested listening replay, 60.034 seconds completed,
  validation zero and user-confirmed movie audibility.
- `argv-probe-r1.log`, `inputs-e42a8d07de1f43429cf6a7d7178ecc12.log`:
  isolated startup-argument reproduction and passing regressions.
- `*-modules.json`, `*-resource.json`, `tv-final-identities.json`: actual loaded
  modules, native smoke samples and unchanged binary/header identities.
- `refresh60-769575bf116040a284d640169e8f80a3.log`,
  `preflight-e685853bb43e426d8f065612110b2eea.log`: authorized display change
  and HDR-active confirmation.
- `preflight-92d4e5cb6d6d41c49dae2365b1bc7182.log`: separate post-test query;
  TV remains 4K60/HDR active, other monitor unchanged.

The TV evidence archive SHA-256 is
`3add4750dddd59bc58c48546de890bbe11472c536fe0aadb9f3d80ff7d6ababf`.
The later post-test query is stored separately, not appended to that archive.
The separate requested-replay archive SHA-256 is
`e5027b3bf508bb32a3444ff35a24163ffb6b1c9aebabfc5c7270e28771de6ae3`.
No candidate playback process or temporary task remains. The original SDR-only
archive, failed logs and base-test failures above remain intact. No production
source or library was rebuilt for the launcher fix, and no commit/push/tag was made.

### Native-4K TV follow-up (2026-09-10)

The user noticed the low-resolution image in the previous listening run. Logs
confirm that the decoded source was 3840x2160 but the target was 960x540; the
TV's 4K60 desktop mode did not change that. This was the validation client's
fixed small window, not a libmpv resolution limit.

Only the client and documentation were adjusted: Windows requests per-monitor
DPI awareness, initial window dimensions honor the existing width/height
arguments, and `--fullscreen` selects desktop fullscreen without a display-mode
change. Surface extent remains authoritative; when it is unspecified, drawable
pixels are used. Window, drawable and target sizes are logged separately. The
default small window is retained, and fullscreen with resize stress is rejected.

| Check | Result |
| --- | --- |
| Default window | Window/drawable/target 960x540; validation zero |
| Explicit window size | Window/drawable/target 1280x720; validation zero |
| Native-4K PQ offscreen and fullscreen | Both actual targets 3840x2160; validation zero |
| Fullscreen versus offscreen raw target readback | Identical at PTS 2.0; 0 ten-bit codes difference |
| Native-4K PQ + D3D11VA-copy, HDMI PCM stereo, volume 50 | 60.035 seconds completed; validation zero |
| User observation | Confirmed the fullscreen image and playback were normal |
| Client compilation | Windows and macOS pass with warnings treated as errors |
| Input/volume, offline tools and script checks | Pass; invalid fullscreen/stress combination rejected before opening a window |

The TV window, Vulkan drawable and swapchain image all report 3840x2160, with
actual HDR active. The decoded p010 Dolby Vision source remains 3840x2160. The
voiced run uses the explicit HDMI endpoint and reports 48 kHz stereo float PCM.
The render-drop counter is 1 from the first recorded sample and does not grow;
the decoder-drop counter stays zero. After five seconds the maximum sampled
absolute internal avsync is 0.009 ms, not a physical latency measurement.
This is a Windows native-4K PQ check, not a new scRGB/macOS 4K or performance matrix.

Windows client SHA-256:
`ef8e43b5b5147cac68e180c6109cf018f67dc04753a89b0dfa4dd340c47382dd`.
The prior 540p client is retained in the private candidate directory. libmpv and
libplacebo DLL hashes remain exactly those listed above; neither was rebuilt.
The macOS compile output is separate from its previous validated client.

Private evidence is under
`.work/vulkan/windows-delivery-20260910/native4k/`:

- `resolution4k.XQCLQK/`: retained first private-launch failure, before rendering.
  Using the existing runner's absolute entrypoint path resolved library loading;
  the same compiled client was used in the successful retry.
- `resolution4k.W24MYy/`: four size cases, raw readbacks, sidecars and commands.
- `resolution4k-11d1cfef651c4da0947f829b5983f4f4.log`: exact 4K pixel comparison.
- `view4k.ZoRAbC/`: full-resolution voiced playback and timing records.
- `native4k-identities.json`, `*-modules.json`, `*-resource.json`: binary/source
  identities, actual loaded modules and native smoke samples.
- `preflight-f10a9b0ddb3549d78728b2d96b2816c5.log`: separate post-test query,
  retaining TV 4K60/HDR active and the other monitor unchanged.

Archive SHA-256:
`62cac640e672e10e0b5493354865a6808a7e139d6e8089e04c8e23b4a4529872`.
The test window and temporary task exited. Production HEADs, the original
maintenance diff, source locks and tag remain unchanged; no commit or push.

### Native-4K scRGB and extended PQ checks (2026-09-10)

This continuation uses the same Windows client, source commits and DLLs as the
native-4K follow-up; nothing was rebuilt. Read-only preflight again identified
the HDR TV and the other SDR monitor separately, confirmed TV 3840x2160 at
60 Hz with actual HDR active, and found the explicit HDMI endpoint. No display,
audio-default or system-volume setting was changed. The link still reports
8 bpc, independently of the RGB10/FP16 application targets.

The scRGB offscreen/timeline and fullscreen/binary captures both contain
3840x2160 FP16 data at PTS 2.0 from the same 16-minute, 3840x2160 Dolby Vision
input. Both use D3D11VA-copy, BT.709/scRGB, the 80-nit convention, target peak
500 and disabled dithering. Their maximum RGB difference is **0 FP16 ULP**
(limit 1); both complete within the 30-second external deadline with validation
zero. Window, drawable and actual swapchain image all report 3840x2160. The raw
captures and sidecars are retained; no integer screenshot was used for this check.

The scRGB movie then played for **60.010 seconds**, with 48 kHz stereo float PCM,
the explicit HDMI endpoint and client volume 50. Exit and validation counts are
zero; all decoder samples identify D3D11VA-copy. The user confirmed normal
clarity, brightness, fluidity and audibility during this single run. After the
initial five seconds the maximum sampled internal avsync is 0.010 ms; this is
not a physical latency measurement. The render-drop counter remains 1 and the
decoder-drop counter remains 0. Native `smoke.exe` sampling records a 730.4 MiB
peak working set; this short check alone is not a leak/performance conclusion.

The PQ movie completed **900.007 seconds** without looping (909.298 seconds
including setup/cleanup, inside the 1080-second external deadline). Source,
window, drawable and target were all 3840x2160. The target was RGB10/PQ, depth
10, peak 500; all decoder and audio samples identify the required D3D11VA-copy
and explicit HDMI stereo PCM configuration, volume 50 and mute off. Exit and
validation counts are zero, including the final stop/no-video render and
context destruction. No playback error, sync hazard or progress watchdog fired.

| Native-4K metric | scRGB 60-second run | PQ 900-second run |
| --- | --- | --- |
| Internal avsync samples | 61 | 893 |
| Maximum absolute avsync after initial five seconds | 0.010 ms | 0.014 ms |
| Largest observed audio/video progress sample interval | 1.041 s | 1.044 s |
| Decoder drops | 0 throughout | 0 throughout |
| Render drops | 1 from first sample, no growth | 1 from first sample, no growth |
| Native smoke CPU, one-core basis | 84.33% | 74.64% |
| Peak working set | 730.4 MiB | 711.8 MiB |
| First / last 60-second working-set median | 729.9 / 730.3 MiB | 708.9 / 474.0 MiB |

The native process sampler retained 25 and 328 samples, respectively, with
verified executable paths and stable PIDs. CPU includes setup/teardown and
validation overhead, is normalized to one core, and is not total-machine CPU
utilization. The long-run minute medians rise slightly to about 711.8 MiB then
decline to about 474 MiB; there is no continuously increasing working set in
this observation. This is not a leak proof or standalone performance comparison.
The generic Bash process samples in case JSON are explicitly excluded from
these CPU/memory numbers. Internal synchronization is not physical latency;
the new user observation applies to scRGB, not an additional PQ listening claim.

Evidence is retained under the ignored
`.work/vulkan/windows-delivery-20260910/final4k/evidence/`:

- `scrgb4k.D3qJRz/`: offscreen/fullscreen raw FP16, sidecars, both bounded cases
  and the exact comparison result.
- `scrgbplay4k.eE7TO3/`, `pqlong4k.Ui5Zgj/`: full movie commands, media SHA-256,
  per-second metrics, elapsed times, validation and final cleanup records.
- `scrgbplay4k-5016fbaf161144d99400a322fb4693ac-*.json` and
  `pqlong4k-47166116be384115a859056666bb2ae5-*.json`: actual loaded modules and
  native smoke CPU/working-set samples, not Bash-wrapper measurements.
- `final4k-identities.json`, `run-private.sh`, `launch-private.ps1`: exact
  source/client/header/library identities and the private bounded commands.
- `preflight-ffe75aba3bb54755b3dbb066f337b5fc.log` and
  `preflight-e278fcf30e1b41fc92cc7e8a124c95ef.log`: before/after read-only
  queries; TV remains 4K60/HDR active, the other monitor remains unchanged.
- `inputs-final4k.log`, `offline-final4k-utf8.log`,
  `offline-final4k-default-locale.log`: successful input/volume/UTF-8 tool checks
  and the separate default-locale diagnostic failure discussed below.

The archive in the parent directory is `native4k-final-20260910.tar.gz`, SHA-256
`41f879746aa53b4ec954bc4f354da1fa217a4b176584f3883fb814b2c000d3a0`.
No candidate playback process or temporary delivery task remained after cleanup.
Earlier evidence, including the 540p runs and known base-test failures, is intact.
Only private commands and these experimental documents changed in this turn;
the production repositories, original maintenance diff, both locks and tag did
not change. No dependency fetch/push, production rebuild or full matrix rerun
was needed. That historical remote-availability prerequisite was closed by the
2026-09-28 sync recorded above.

## Limited review

Reviewed the locked Vulkan adapter/header and its shared-renderer call sites
for enabled device features, graphics+compute queue ownership/locking,
acquire/completion and error state, wrapper identity/retirement, destruction,
skip behavior and default-backend compatibility. Checked the client migration
against the validated original, including source-change and seek completion.
No actionable production defect was confirmed within this scope. This is not
a stable ABI approval or proof of untested devices/failure modes.

The shared maintenance helper only gained an explicit source-lock override;
its default still loads the original OpenGL lock. Offline tests confirm that
default, missing/invalid experimental locks, all three kinds of dirty dependency,
wrong SHA, timeout/unsupported handling and refusal to overwrite prior evidence.
The original maintenance diff, production HEADs, stable lock and existing tag
are unchanged. No CI workflow, commit, push or tag was created.

The native-4K continuation also reviewed the complete uncommitted delivery diff
against `1245b726`, specifically lock/path selection, timeout/start/comparison
status handling, Windows literal arguments, DPI/fullscreen/drawable sizes and
exit cleanup. No new production or rendering-integration defect was confirmed.

The previously retained Windows-locale delivery-tool issue is now fixed:
`test-tools.py` decodes child output as UTF-8 with replacement, and the offline
suite includes invalid UTF-8 output as a regression case. Fixture exit-code
assertions are unchanged. Historical default-locale failure evidence remains
retained; this fix changes no production code.

The 2026-10-04 follow-up applies the same explicit UTF-8 replacement decoding
to the actual comparison entrypoint in `check.py`. Four real-subprocess
regressions cover matrix and lifecycle comparisons, successful and failed
exits, non-ASCII UTF-8 output and invalid bytes under a simulated GBK default.
The new regression reproduced `UnicodeDecodeError` before the fix. All 21
summary scenarios now pass, including immediate disk updates and continuation
after a failed matrix comparison. The complete offline suite, Python compilation
and whitespace checks pass. No GPU cases were rerun; Windows revalidation of
the current source lock is explicitly deferred at the user's request.

Experimental shell entrypoints and the private launcher pass ShellCheck with
`-x -P SCRIPTDIR`; all selected shell files pass individual `bash -n` checks,
and Python compilation and Mac/UTF-8 Windows offline tests pass. Checking the
shared helper alone also reports SC1007/SC2034 warnings already present in
`1245b726`; these are preserved, not presented as newly introduced findings.

## Retained evidence for the source combination

The original isolated tests validated macOS/MoltenVK and Windows/NVIDIA
software and hardware-copy-back paths. They covered SDR/PQ/scRGB targets,
18 HDR main cases per platform, target reads, screenshots, explicit sync,
context creation/destruction, target retirement, pause/seek/skip, source changes,
60-second voiced runs and 15-minute PQ copy-back playback.

The latest movie listening check used client volume 50 and was audible on both
physical outputs. Earlier volume-20 long-play counters do not prove audibility.
Flash/beep feedback was roughly synchronized for software and copy-back, not
a millisecond latency measurement.

These are historical evidence for the locked production sources, not automatic
acceptance of the newly migrated tooling. Fresh results are recorded below.
Raw historical evidence stays in the private smoke directory, without rewriting
its earlier failures. Local provenance and result hashes live under
`.work/vulkan/evidence/`.

## Known limits

- The Vulkan ABI is experimental, and the draft header is not installed.
- macOS PQ/scRGB physical brightness equivalence remains unresolved.
- Windows reported an 8-bpc link during the previous TV validation; an RGB10
  application target does not prove a 10-bit wire format or Dolby Vision output.
- Hardware paths are copy-back, not zero-copy interoperability.
- No Android/native-Linux physical-GPU, complete Android Surface lifecycle,
  real device-loss or absolute luminance/latency calibration claim is made.
- Known library base-test failures remain failures, separate from Render API
  integration checks. No ignored failure is relabeled pass.
- No CI workflow is added or run by this local delivery.
