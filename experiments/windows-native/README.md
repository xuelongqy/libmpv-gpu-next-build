# Windows native candidate

Documentation-only archive of the private `windows-native-integration.iGgxyQ`
candidate. No candidate source, client, scripts, libraries or evidence files are
included. Paths and commands below describe that private candidate, not a
buildable entry in this repository.

Status: expansion paused by agreement on 2026-10-16. Keep this uncommitted
experimental candidate default-disabled and explicit-only, outside `auto`.
Windows' main path remains libmpv gpu-next for DV-to-HDR/SDR mapping. Earlier
PQ/scRGB results and the startup limitation are retained; see the
[maintenance decision](ACCEPTANCE.md#maintenance-decision--2026-10-16).
Private candidate source: `src/` (not included), detached at
`99177c09a62cac1cd64f8bb4065968d1edb3a046`, with uncommitted changes.
No production workspace or source lock is changed.

## Scope

Explicit `OUTPUT_MODE=native`, API `windows-native`, software-decoded single-layer
DV Profile 5. Installed system Dolby processing produces RGB10/PQ or FP16/scRGB.
This is not original DV HDMI tunneling. Default and `auto` selection are unchanged.
No FFmpeg patch, GPU-next renderer change, or bundled Dolby DLL is involved.

mpv retains demuxing, decoding, audio, playback timing, seeks, and subtitle
rendering. A small C backend connects the existing Render API to one Windows
C++ implementation for Media Foundation, D3D11, and DirectComposition.

## Window and lifetime

Use `src/include/mpv/render_win.h` from this exact candidate. It is experimental,
not installed, and is not identified by the unchanged client API 2.8 version.

The UI thread creates a dedicated child HWND with a black background. One
dedicated MTA render thread creates and owns the context; that thread serializes
update, render, reset and destruction. The update callback only wakes it.

```c
mpv_windows_native_init_params init = {
    .version = MPV_WINDOWS_NATIVE_API_VERSION,
    .window = child_hwnd,
    .output = MPV_WINDOWS_NATIVE_OUTPUT_PQ,
};
mpv_render_param create[] = {
    {MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_WINDOWS_NATIVE},
    {MPV_RENDER_PARAM_OUTPUT_MODE, "native"},
    {MPV_RENDER_PARAM_WINDOWS_NATIVE_INIT_PARAMS, &init},
    {0},
};
```

Before loading media, create successfully and query `OUTPUT_MODE`; require
`native`. Set `hwdec=no` for this experimental scope. Pass the child's actual
pixel dimensions using `MPV_RENDER_PARAM_WINDOWS_NATIVE_TARGET` on each render.
The existing render call waits for mpv's target time before backend presentation;
call `mpv_render_context_report_swap()` afterwards. Do not run another media clock.

The backend owns its device, Dolby objects, swapchains and composition tree, not
the HWND. Video and premultiplied BGRA/sRGB OSD are separate composition layers.
Text/ASS and bitmap subtitles reuse mpv's existing rendering; neither the client
nor the Dolby component has to decode subtitles. Subtitles do not modify DV input.

Stop rendering and remove callbacks, free the context on its creating thread,
then destroy the child HWND on the UI thread. Zero target dimensions suspend
presentation. Output changes or movement to another monitor require context
recreation. No automatic HDR switch, fallback, or device recreation occurs.
Filters and unsupported inputs are rejected; GPU color controls, ICC, shaders,
rotation and GPU screenshots are outside this backend's support.

## Build and checks

`build.ps1 -WorkDir <candidate>` uses the existing MSYS2 UCRT64 tools and libraries
and creates only `<candidate>/build` and `<candidate>/prefix`. It requires the
current reviewed source in `<candidate>/src`; it never restores the old initial
archive. Meson opts in with
`-Dwindows-native=enabled`; the default is disabled. `run.ps1` launches only the
candidate's own executable on the interactive desktop, with a bounded deadline,
unique logs and return values `0` pass, `1` failure, `2` usage/environment,
`3` unsupported, `124` timeout. It does not set display or audio-system settings.

Windows checks resumed with the user's authorization in a fresh
`acceptance-20261015.42A8M0` directory, after verifying the reviewed source archive.
The old executables and logs were retained. See that directory's
`ACCEPTANCE.md` for source/library identity, results and remaining limits.

When resumed, enumerate with `smoke.exe --probe` before selecting a display.
The smoke options are `--display`, `--file`, `--output pq|scrgb`, `--sub`,
`--seconds`, `--audio-device`, `--contexts`, `--lifecycle`, `--fullscreen`, and `--gpu-debug`.
`--fullscreen` uses the selected display's actual pixel bounds; default windowed
behavior is unchanged. Escape still exits, and the duration limit closes playback.
No media means context create/preload-render/free only. Sound requires an explicit
audio device; volume is 50 and system volume is not modified. `--gpu-debug` uses
the existing mpv option and requires the Windows D3D debug layer to be installed.

`processor-test.cpp` includes the same candidate adapter, not a duplicate Dolby
implementation. It contains packing/RPU self-checks, eight-frame raw output and
target comparisons, separate overlay/clear checks, and reset checks. Its new build
and GPU cases passed for PQ/scRGB, including zero D3D debug errors. Frame 1 is
still transparent and is not counted as valid first-frame content. The test is
not linked into libmpv or installed as an API.

See [REPORT.md](REPORT.md) for verified results and outstanding acceptance.
The detailed `HISTORY.md` remains in the private candidate, outside this archive;
its failures were retained separately from subsequent passes.
