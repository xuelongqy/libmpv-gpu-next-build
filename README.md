# libmpv gpu-next maintained source validation

This repository pins and validates the source combination used by the
maintained libmpv `gpu-next` OpenGL/GLES fork. It publishes no prebuilt
libraries. The mpv and libplacebo forks remain the source of truth.

## Pinned sources

Exact repository URLs and commits are recorded in `versions.env`:

- mpv: `xuelongqy/mpv`, branch `feat/libmpv-gpu-next-maintained`
- libplacebo: `xuelongqy/libplacebo`, branch `feat/rect-sampler-maintained`
- Android validation shell: an uncommitted patch applied to a fixed
  `mpv-android` revision

All checkout and build output is written below `.work/`. Scripts verify the
checked-out commit before building, so an installed system libplacebo cannot
silently replace the pinned source.

## Validation commands

```sh
./scripts/checkout.sh
./scripts/build-linux.sh       # Linux
./scripts/build-macos.sh       # macOS, including the desktop smoke client
./scripts/build-no-gl.sh       # selector and software-render fallback
./scripts/build-sanitize.sh    # ASan/UBSan libmpv suite
./scripts/build-android.sh     # Android arm64, NDK r29
./scripts/check-upstream.sh    # non-mutating compatibility merge in .work
```

To run the macOS smoke client with a local video:

```sh
./scripts/run-macos-smoke.sh --renderer gpu-next --output sdr VIDEO.mkv
```

The Android patch supports only the Render API path. It deliberately excludes
the experimental `wid` HDR reconfiguration workaround. See `PATCHES.md` for
API behavior and platform boundaries, and `VALIDATION.md` for the recorded
build and device matrix.

## Source-only releases

Validated combinations are marked by annotated tags in this repository. A tag
locks the commits in `versions.env`; it does not contain or attach binaries.

Repository-authored scripts and documentation use the MIT license. Source
patches retain the licensing terms of their respective upstream projects.
