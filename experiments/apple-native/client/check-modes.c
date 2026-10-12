#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "mpv/client.h"
#include "mpv/render.h"

int main(void)
{
    mpv_handle *mpv = mpv_create();
    assert(mpv && mpv_initialize(mpv) == 0);
    int advanced = 1;
    char *modes[] = {NULL, "render", "auto", "native", "invalid", ""};
    for (int i = 0; i < 6; i++) {
        mpv_render_context *ctx = NULL;
        mpv_render_param params[] = {
            {MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_SW},
            {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced},
            {MPV_RENDER_PARAM_OUTPUT_MODE, modes[i]}, {0},
        };
        if (!i)
            params[2] = (mpv_render_param){0};
        int err = mpv_render_context_create(&ctx, mpv, params);
        int expected = i < 3 ? 0 : i == 3 ? MPV_ERROR_NOT_IMPLEMENTED
                                        : MPV_ERROR_INVALID_PARAMETER;
        assert(err == expected);
        if (!err) {
            const char *mode = NULL;
            assert(mpv_render_context_get_info(ctx,
                (mpv_render_param){MPV_RENDER_PARAM_OUTPUT_MODE, &mode}) == 0);
            assert(mode && !strcmp(mode, "render"));
            mpv_render_context_free(ctx);
        } else {
            assert(!ctx);
        }
    }
    mpv_terminate_destroy(mpv);
    puts("SOFTWARE_DEFAULT_RENDER_AUTO_AND_UNSUPPORTED_NATIVE=PASS");
}
