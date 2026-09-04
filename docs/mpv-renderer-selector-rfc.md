# RFC: Select the libmpv video renderer independently of the graphics API

## Motivation

The Render API currently selects a backend only through
`MPV_RENDER_PARAM_API_TYPE`. For OpenGL this always selects the legacy `gpu`
renderer, so clients cannot use gpu-next features such as libplacebo's Dolby
Vision processing while retaining ownership of their OpenGL context and
presentation surface.

Encoding the renderer into the graphics API name (for example,
`opengl-next`) would conflate two independent choices and would not scale to
future Vulkan or D3D11 Render API backends.

## Proposed API

Add `MPV_RENDER_PARAM_RENDERER = 21` to `mpv_render_param_type`. Its data is a
`char *`, and it is valid only for `mpv_render_context_create()`.

Supported values are:

- `"gpu"`: require the legacy GPU renderer.
- `"gpu-next"`: require the libplacebo renderer.

When the parameter is omitted, backend probing is unchanged: OpenGL selects
the legacy renderer and the software API selects the software renderer. An
unknown name, a null pointer, or an empty string returns
`MPV_ERROR_INVALID_PARAMETER`. A known renderer that cannot implement the
requested API type returns `MPV_ERROR_NOT_IMPLEMENTED`; it is never silently
replaced by another renderer.

The client API minor version is incremented from 2.5 to 2.6. Clients must
check `mpv_client_api_version()` before supplying the new parameter.

## Initial backend

The first implementation supports `"gpu-next"` with
`MPV_RENDER_API_TYPE_OPENGL`, including desktop OpenGL and GLES. It reuses the
existing libmpv OpenGL context and target parameters rather than introducing
a second OpenGL API.

The caller continues to own the OpenGL context, framebuffer, swap/present
operation, and window-system color configuration. The context must be current
when required by the existing OpenGL Render API contract. `FLIP_Y` and
`DEPTH` retain their existing meanings; a missing or non-positive depth is
normalized to the documented 8-bit default.

The gpu-next OpenGL target defaults to an SDR monitor. HDR clients must set
the mpv target color options (for example `target-prim=bt.2020` and
`target-trc=pq`) and configure the framebuffer and presentation surface for
the same HDR color space.

## Compatibility and scope

Existing clients observe no behavioral change because the selector is
optional and the default renderer remains `gpu`. The software Render API is
unchanged. Vulkan, D3D11, Metal, and new target-color parameters are outside
this initial proposal and require separate ABI review.

The implementation shares the gpu-next video renderer with `vo_gpu_next`;
the standalone VO keeps its existing platform context and libplacebo
swapchain behavior.
