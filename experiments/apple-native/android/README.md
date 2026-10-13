# Android native subtitle client delta

`subtitles.patch` preserves only the five-file subtitle integration delta from
the tested Android candidate. It reuses mpv-android's existing client: one
MediaCodec video Surface plus one transparent, media-overlay subtitle Surface.
It does not contain a new decoder, renderer, FFmpeg patch or complete player.

The candidate already had Render API/native switching, debug controls and
native-DV prerequisites that are not published here. This patch does **not**
apply directly to a clean upstream mpv-android checkout. Do not import unrelated
local changes just to make it apply. The exact preimage Git blob IDs are:

| File | Preimage |
| --- | --- |
| `app/src/main/java/is/xyz/mpv/BaseMPVView.kt` | `f5b6a119dcc91aa8387ffa5a8213e3c818e0a4ba` |
| `app/src/main/java/is/xyz/mpv/MPVActivity.kt` | `610293baccca5e1a541f981ee7ba68371946f363` |
| `app/src/main/java/is/xyz/mpv/MPVLib.kt` | `6da144282fc568220ec69c1c59b032d3e098a1a2` |
| `app/src/main/jni/render.cpp` | `6d1d7805d93d773bece3396c4d44d69d92d63e32` |
| `app/src/main/res/layout/player.xml` | `b2a85e5b69f996bbcda3fb05f142bf9dfa746237` |

Compare these with `git hash-object FILE` before applying the patch to the
matching candidate; then run `git apply --check /path/to/subtitles.patch`.
No script resets, cleans or overwrites a dependency checkout.

Native creation waits for both Surfaces. Destruction stops the decoder/VO before
releasing either JNI global reference. Recreating either Surface reattaches both
and restores the selected video track. Only native output creates the overlay;
the default, old gpu and gpu-next paths remain unchanged.

The client passes its retained Java Surface via
`mediacodec-embed-osd-surface`; it must keep that reference alive until the VO
stops. Subtitle selection, timing, styles and bitmap generation remain in mpv.
The capture/debug actions are acceptance hooks, not video/HDR screenshots or
public libmpv APIs. See the subtitle section of `../ACCEPTANCE.md` for evidence
and the retained failures. Media, screenshots, APKs and machine identities are
not part of this source snapshot.
