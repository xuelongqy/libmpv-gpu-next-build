# Downstream patch inventory

## mpv

The immutable OpenGL/GLES v1 snapshot is
`77c48fff91df7cb470b02b83f510c342e68236d2`. Its logical commits are:

1. `9c604523ccc1ac83ed2676b8643b5d1ac9248b0c` — software Render API coverage
2. `1add7c7a27aa62ea92f0a62c47011e614c42ef1b` — shared gpu-next renderer
3. `c86f9a87f3ceefe069ab7fcbb01eb7e9d27cdd34` — reusable GPU contexts
4. `e419f39893f0075c09002cfafd88c17ee3599790` — runtime VO capabilities
5. `77c48fff91df7cb470b02b83f510c342e68236d2` — libmpv OpenGL backend and selector

The maintained branch additionally carries upstream merges. The first merge
ports upstream's queue-owned hwdec mapping lifetime into the shared renderer,
so standalone `vo=gpu-next` and libmpv use the same behavior.

`MPV_RENDER_PARAM_RENDERER` accepts `gpu` and `gpu-next`. Omitting it preserves
the old default. Unknown values return `MPV_ERROR_INVALID_PARAMETER`; known but
unsupported API/backend combinations return `MPV_ERROR_NOT_IMPLEMENTED`.

## libplacebo

`011d7e15ee4ae74ae7e79bc957f80276d740df90` fixes scaling shaders for rectangle
samplers by deriving the coordinate-domain size from the texel step. This is
required by the macOS VideoToolbox OpenGL path, whose decoded planes use
`sampler2DRect`. The maintained branch merges later upstream changes without
rewriting the original fix.

## Platform boundaries

- Supported downstream renderer API: desktop OpenGL and GLES3.
- macOS Dolby Vision Profile 5 is decoded and mapped by libplacebo; this is not
  native Dolby Vision passthrough.
- Android PQ requires an RGB10A2 EGL config,
  `EGL_EXT_gl_colorspace_bt2020_pq`, and successful
  `ANativeWindow_setBuffersDataSpace(ADATASPACE_BT2020_PQ)`.
- Missing HDR prerequisites must fail explicitly or use an explicit SDR run;
  they are never reported as successful HDR output.
- Vulkan, D3D11, Metal, iOS/tvOS, and Android `wid` HDR are outside this fork's
  maintained feature scope.

## Updating

Keep each fork's `master` as a fast-forward mirror of its official upstream.
Merge upstream into the corresponding maintained branch; do not rebase or
force-push published maintenance history. Resolve only conflicts that intersect
the downstream patch set, run the full validation matrix, then update
`versions.env`. If upstream gains equivalent code, remove a downstream change
only after behavior and regression tests pass with that change absent.
