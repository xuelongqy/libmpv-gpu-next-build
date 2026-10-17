# Ubuntu NVIDIA acceptance — 2026-10-17

Pass for the tested `libmpv auto -> render/gpu-next` Vulkan path on Ubuntu,
RTX 2070 SUPER and TCL. This is HDR/PQ rendering, not a Linux native backend or
Dolby Vision passthrough. Default libmpv behavior and the stable OpenGL lock
are unchanged. Historical failures below remain failures.

## 1. Source and runtime identity

| Item | Tested identity |
| --- | --- |
| mpv | `99177c09a62cac1cd64f8bb4065968d1edb3a046` |
| libplacebo | `b7779734692e4b6fbd72987976aa11aad51f7ee7`, clean, 7.372.0 |
| mpv working diff | `include/mpv/render.h` comments and `test/libmpv_test_render_params.c` only; SHA-256 `b33668625e63c04a37a6b6883a840791d025ee89c68fd94080690490981e0265` |
| FFmpeg | Distribution 8.0.1, privately unpacked; no native-output patch |
| GPU / driver | RTX 2070 SUPER / NVIDIA 595.99.02; Vulkan 1.4.329 |
| Validation | Private Khronos layer 1.4.341.0, synchronization validation enabled |
| Display | Wayland; TCL 3840x2160/60, HDR active; DELL left in SDR |
| Audio | Explicit TCL ALSA HDMI endpoint, 48-kHz stereo PCM, client volume 50 |

The delivery lock now pins published mpv
`786f07561f35a51c6027e2f653aa19a7a4e26d47`, containing exactly the comments/test
diff above on the tested `99177c09` baseline. The committed source tree matches
the validated working tree; the six-policy regression is now part of the lock.
The measured library is not rebuilt or relabeled: committing those files
changes no renderer behavior. Use installed headers and the private prefix;
checkout still rejects staged, unstaged and untracked dependency changes.
The existing checkout entrypoint successfully fetches this published lock with
clean trees; receipt: `.work/ubuntu-closeout-20261017/published-source-checkout.json`.

Measured long-run SHA-256 values (not promises of bit-identical rebuilds):

| Artifact | SHA-256 |
| --- | --- |
| `libmpv.so.2.8.0` | `751305aafaa9067c410ce39f660ecdef18252078b0b7ea2208799e85b73e738b` |
| `libplacebo.so.372` | `9d39e5da4f0407e5b279772a3400d1cc34f838c3d276416e619ff11a9455c631` |
| Private smoke executable | `f11792f85c5baf1797ebfb26f3779477d39a741a3b8a3cf030e0d42951a2301b` |
| Private smoke source | `59fa575c88342f6fd84e4d8b1c47f7b73cd2047470ab5ff70027f229b81457c5` |
| Non-looped 964.624-second DV/audio input | `05fff57c8e2b4c91c99b4944b2f207a63eb394a319b59dca0ff032bb05f63fa8` |

Runtime maps identify the private `.372` library. FFmpeg's `libavfilter.so.11`
also loads system `.360`; a separate immediate-binding diagnostic resolves all
145 libmpv `pl_*` imports to private `.372`, not `.360`. That diagnostic creates
no mpv handle and is not a trace captured inside historical playback. No FFmpeg
libplacebo filter or mixed-major filter compatibility is tested.

## 2. Completed checks

| Check | Result and limits |
| --- | --- |
| Meson Render API checks | 3/3: render-params, render-sw, render-vk-abi; not a full Meson-suite run |
| Software decoding | No-window probe; SDR/HDR10/DV x SDR/PQ: 6 still cases; 3 fullscreen 4K video-only short runs; 9 target/GPU-screenshot comparisons pass |
| Software / NVDEC-copy | 6 still cases, 12 comparisons and two complete 60-second native-4K PQ voiced runs pass; actual decoder checked, no silent fallback |
| PQ NVDEC-copy long playback | 900.024 s, exit 0, validation 0; full clip, no looping, 3840x2160 drawable and swapchain images |
| Context lifetime | 50 Render API create/load/stop/free cycles on one retained Vulkan device; 100 no-video black and 150 valid-video checks |
| Window lifetime | 100 target rebuild/retire iterations, 99 size changes; 20 same-file reloads, 20 exact seek/skip/GPU-screenshot/resume cycles |
| Lifecycle pixels | Initial plus 20 seek comparisons: 21/21, maximum 1/1023, exact alternating PTS 3/2 checked |

SDR limits remain one 8-bit code and PQ one 10-bit code. No threshold changed.
The long run has 899 progressing post-unpause audio/video samples; after the
initial five seconds, maximum sampled absolute internal A/V offset is 0.000042 s.
Decoder drops remain 0, VO drops remain 1 from startup. CPU averages 35.70% on a
one-core basis; RSS peaks at 1,201,315,840 bytes, with first/last 60-sample medians
differing by about 2.83 MiB. This is not a benchmark or proof of no leaks.

The 42 two-second window recovery segments verify successful rendering
submissions and advancing audio/video PTS. They do not exercise the five-second
sustained drift/stall gates or read back every resumed frame. Those gates are
covered by the long run; paused checkpoints verify pixel content. The first
resize iteration rebuilds the same size. Reloads use the same file, not 20
different inputs.

The user separately confirms normal picture/motion for all three sample types,
corresponding sound and approximate A/V sync for both 60-second voiced runs and
the beginning of the long run. This is not a claim that all 15 minutes were
watched, a physical HDMI-latency measurement, a TV DV badge, or luminance
calibration. All windows/audio close; display/audio settings stay unchanged.

### Delivery migration review

Fresh remote checkout, including submodules, resolves both full locked SHAs
with clean trees. The installed v1 header matches that checkout (SHA-256
`d74bcd81c7476eac4a937e6d1c742f8b861c335f8f746c029e41bce4cc2b7106`);
`render_vk.h` is unchanged from the previous `498c2aa535` lock.

The migrated client is rebuilt against the identified private libraries, not
relabeled as the historical binary. Final source SHA-256:
`b647f20c55ca253add540e96757a65dfeb45a1b36f42ad5b43617ed155f46241`;
Linux executable SHA-256:
`e0f1dd71083b60f000c6ba05f53283c67a7d7ffd05fc05f2a2bfecce08bb33bc`.
All 13 targeted checks pass: three Render API test executables (including the
six output-policy cases), input controls, default/auto probes, six software/
NVDEC-copy still cases and one default SDR case. The nine Vulkan cases report
zero validation errors. All 14 target/screenshot/baseline comparisons pass
within the original one-code limits; default versus auto SDR differs by zero.

Review limits desktop display/NVDEC code to Linux excluding Android, which
also defines `__linux__`. macOS and Android NDK r29 strict C syntax checks pass;
this is not device acceptance. Offline tools, Python syntax, Bash syntax,
ShellCheck and diff checks pass. Production libraries, TV/audio settings and
the existing long-run evidence are not changed; no new full build, full Meson
suite, long playback, window/monitor test or remote CI is claimed this round.

Migration receipts remain in `.work/ubuntu-closeout-20261017/`: clean remote
checkout, initial migration, and `review-final/` after the Android guard fix.
The failed first final-image helper invocation (relative path joined twice)
is retained as `pixel-migration`; corrected `pixel-migration-r2` passes 14/14
on the same images. This private-helper repair changes no delivered comparer
or threshold. Initial host-Python Pillow unavailability was resolved by reusing
the existing comparison runtime, without installing packages.

## 3. Reproduce with the delivered client

Use the prerequisites in [README](README.md), including FFmpeg with NVDEC-copy
and ALSA development files for mpv's audio output. No script installs drivers
or changes display/HDR settings. Verify the selected display is HDR-active and
enumerate its audio endpoint with the candidate standalone mpv's
`--no-config --audio-device=help`.
The requested source pair is in `versions.env`; do not substitute system mpv
or libplacebo. Matching source does not imply matching toolchains or binaries.

```sh
export WORK_ROOT="$PWD/.work/vulkan-ubuntu"
bash experiments/vulkan/build.sh
bash experiments/vulkan/tests.sh
python3 experiments/vulkan/test-tools.py
```

Compilation and library tests are separate: retain any failure from `tests.sh`.
The historical private build enables GL/Vulkan/ALSA and disables unused CUDA
graphics interop. FFmpeg NVDEC-copy does not require that interop. Its SDK,
Meson options and complete failed/successful build receipts remain in the
private evidence; this generic entrypoint is not claimed byte-identical to it.

From the repository root, set `display` to the verified SDL index, `audio` to
the verified endpoint and `media` to a local original-audio clip longer than
902 seconds. Use fresh output prefixes; no sample, endpoint ID or raw log is
shipped in this repository. The client starts at PTS 2 by default.

```sh
display=0                         # verify on this machine, do not assume
audio=YOUR_VERIFIED_AUDIO_DEVICE
media=/absolute/path/to/long-clip.mkv
result=$(mktemp -d "$WORK_ROOT/evidence/ubuntu.XXXXXX")
runner="$PWD/experiments/vulkan/run.sh"
SMOKE_SAMPLE_RESOURCES=1 python3 experiments/vulkan/case.py "$result/long-pq" 1080 -- \
  bash "$runner" --auto-output --fullscreen --display "$display" --output pq \
  --hwdec nvdec-copy --play-seconds 900 --audio-device "$audio" --volume 50 "$media"
python3 experiments/vulkan/case.py "$result/contexts" 300 -- \
  bash "$runner" --auto-output --timeline --contexts 50 --output pq \
  --hwdec nvdec-copy "$media"
python3 experiments/vulkan/case.py "$result/window-life" 300 -- \
  bash "$runner" --auto-output --window --display "$display" --output pq \
  --hwdec nvdec-copy --stress --play-seconds 2 --audio-device "$audio" --volume 50 \
  --capture "$result/window-life.raw" --screenshot "$result/window-life.png" "$media"
```

Check actual decoder, complete duration, progressing PTS, explicit non-null
audio and `OUTPUT_POLICY=auto ACTUAL_OUTPUT=render`, `VALIDATION_ERRORS=0`,
`RESULT=PASS`. Reuse `compare-hdr.py RESULT --pair CAPTURE.raw CAPTURE.png` for
the initial/20 seek captures; retain the alternating PTS 3/2 check. Do not run
the unchanged `check-lifecycle.py` on this two-second variant: its first
segment assertion is for the earlier ten-second desktop case.

`--auto-output` is opt-in; default smoke selection remains explicit gpu-next.
The historical private client hardcodes auto and has a silent-playback
diagnostic; only the required Linux display/NVDEC and explicit auto checks are
migrated. Its old binary and logs are not overwritten or relabeled as results
from the migrated client. Migration checks are recorded separately above.

## 4. Preserved failures and limitations

The private `dmabuf-wayland`/NVIDIA VA-API composed-export candidate passes
headless checks but fails at the compositor's first real DMA-BUF import with
inconsistent arguments. Linux native remains unsupported; no bridge/VO/driver
workaround is shipped, and this is not native HDR/DV acceptance.

The first hardware-candidate build enabled unused `cuda-hwaccel` with its
graphics interop disabled and failed on undefined `cuda_gl_fn`/`cuda_vk_fn`.
Its receipt remains; the readback-only retry disables that unused option. No
production fix or pass for that failed option combination is claimed. Earlier
private toolchain setup failures, WSL lifetime/format/locale failures and
historical platform results remain distinct, not waived as current passes.

Verbose `mpv_render_context_render() not being called or stuck` messages remain:
one in the long run's initial paused phase, zero in context cycling and 42 in
paused window load/reset/stop operations; none in continuous-play segments.
`vo_libmpv.c:flip_page()` emits this after a 200-ms pending-frame wait. It is a
control-path latency observation, not declared universally harmless or a
Vulkan validation error. Existing multiple-RPU warnings are also retained.

Not covered: zero-copy, Linux native DV, other GPUs, scRGB, full-suite/sanitizer
acceptance for this pair, physical brightness or millisecond A/V calibration.
The `auto` policy does not enable OS HDR or choose an HDR target automatically.

## 5. Evidence index

Raw media, images, logs, maps, receipts and machine-specific paths remain
private under the independent smoke directory; only this summary is archived:

| Evidence directory basename | Preserved records |
| --- | --- |
| `linux-native-bridge-fix-20261017.LgSbHe` | Failed compositor import, prior failures and headless controls |
| `linux-libmpv-auto-20261017.7rZwBt` | Software report, `build*.json/log`, source archives/diff, still/window receipts and 9 comparisons |
| `linux-hwdec-av-20261017.fTAMlP` | Hardware/audio report, failed `build` and successful `build-r2`, 6 still cases, 12 comparisons, 2 voiced runs/maps |
| `linux-long-lifecycle-20261017.4RrbSq` | Reviewed `REPORT.md` and `REPORT.before-review.md`, `long-nvdec-pq`, `contexts50-nvdec-pq`, `stress-window-nvdec-pq`, 21 comparisons, separate loader binding diagnostic |

Reviewed long-run report SHA-256:
`40d4d9ad575799faa5d01ea383df9a547ede7b164fe9e551e879e9d2dfb5b65b`.
No raw evidence or failure is overwritten. Source hashes identify the measured
combination, not a promise that future full-suite or remote CI runs pass.
