# libplacebo rectangle-sampler scaler failure on macOS

## Problem

VideoToolbox exposes decoded planes to OpenGL as rectangle textures. The
libplacebo scaler generated `textureSize(rect_sampler, 0)` for these inputs,
but Apple GLSL 4.10 does not provide the two-argument LOD overload for
`sampler2DRect`. Scaling therefore failed during shader compilation with
`Failed dispatching scaler`, even though software-decoded 2D textures worked.

## Fix

Commit `011d7e15ee4ae74ae7e79bc957f80276d740df90` derives the source coordinate
domain from the existing texel step (`vec2(1.0) / pt`) in the seven scaler
paths. This remains equal to the physical size for normalized 2D textures and
evaluates to the correct rectangle coordinate domain without an invalid
`textureSize` overload.

Dummy shader tests cover orthogonal and polar scaling with a rectangle
sampler and assert that the generated shader does not contain the invalid
call. No public libplacebo API changes are required.

Fork commit:
https://github.com/xuelongqy/libplacebo/commit/011d7e15ee4ae74ae7e79bc957f80276d740df90

Patch:
[`patches/libplacebo/0001-shaders-fix-scaling-rectangle-samplers.patch`](../patches/libplacebo/0001-shaders-fix-scaling-rectangle-samplers.patch)

## Integration evidence

The patched library was installed privately under
`/private/tmp/libplacebo-rect-fix` and used without replacing Homebrew's
libplacebo. With that build, libmpv gpu-next and standalone `vo=gpu-next`
render the Dolby Vision Profile 5 sample through VideoToolbox without shader
compile or scaler-dispatch failures. The same mpv source also compiles against
the released libplacebo 7.360.1 API.

The mpv change does not pin this fork or raise its libplacebo minimum version.
The patch must be accepted independently before the macOS VideoToolbox path
can be considered fixed for users of an unpatched libplacebo release.
