#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <OpenGL/gl3.h>
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include <SDL.h>
#include <SDL_syswm.h>
#include <mpv/client.h>
#include <mpv/render_gl.h>

struct options {
    const char *renderer;
    const char *output;
    const char *fbo;
    const char *hwdec;
    const char *flip;
    const char *video;
    const char *screenshot;
    const char *mpv_screenshot;
    const char *log;
    double start;
    int depth;
    int frames;
    bool exercise;
};

static void usage(const char *name)
{
    fprintf(stderr,
        "usage: %s [options] VIDEO\n"
        "  --renderer gpu|gpu-next\n"
        "  --output sdr|pq\n"
        "  --fbo default|texture\n"
        "  --hwdec no|videotoolbox\n"
        "  --flip default|0|1\n"
        "  --depth BITS (0 omits the parameter)\n"
        "  --start SECONDS --frames COUNT\n"
        "  --screenshot FILE.ppm --mpv-screenshot FILE.png\n"
        "  --exercise --log FILE.log\n", name);
}

static bool parse_options(int argc, char **argv, struct options *o)
{
    *o = (struct options) {
        .renderer = "gpu-next",
        .output = "sdr",
        .fbo = "default",
        .hwdec = "videotoolbox",
        .flip = "1",
        .start = 600.0,
        .depth = 0,
        .frames = 8,
    };

    for (int i = 1; i < argc; i++) {
        if (argv[i][0] != '-') {
            if (o->video)
                return false;
            o->video = argv[i];
            continue;
        }
        if (strcmp(argv[i], "--help") == 0)
            return false;
        if (strcmp(argv[i], "--exercise") == 0) {
            o->exercise = true;
            continue;
        }
        if (i + 1 >= argc)
            return false;
        const char *value = argv[++i];
#define SET_OPT(name, field) \
        if (strcmp(argv[i - 1], name) == 0) { o->field = value; continue; }
        SET_OPT("--renderer", renderer)
        SET_OPT("--output", output)
        SET_OPT("--fbo", fbo)
        SET_OPT("--hwdec", hwdec)
        SET_OPT("--flip", flip)
        SET_OPT("--screenshot", screenshot)
        SET_OPT("--mpv-screenshot", mpv_screenshot)
        SET_OPT("--log", log)
#undef SET_OPT
        if (strcmp(argv[i - 1], "--start") == 0) {
            o->start = strtod(value, NULL);
        } else if (strcmp(argv[i - 1], "--depth") == 0) {
            o->depth = atoi(value);
        } else if (strcmp(argv[i - 1], "--frames") == 0) {
            o->frames = atoi(value);
        } else {
            return false;
        }
    }

    return o->video &&
        (!strcmp(o->renderer, "gpu") || !strcmp(o->renderer, "gpu-next")) &&
        (!strcmp(o->output, "sdr") || !strcmp(o->output, "pq")) &&
        (!strcmp(o->fbo, "default") || !strcmp(o->fbo, "texture")) &&
        (!strcmp(o->hwdec, "no") || !strcmp(o->hwdec, "videotoolbox")) &&
        (!strcmp(o->flip, "default") || !strcmp(o->flip, "0") ||
         !strcmp(o->flip, "1")) && o->frames > 0;
}

static void *get_proc_address(void *ctx, const char *name)
{
    (void)ctx;
    return SDL_GL_GetProcAddress(name);
}

static bool configure_pq_window(SDL_Window *sdl_window)
{
    SDL_SysWMinfo info = {0};
    SDL_VERSION(&info.version);
    if (!SDL_GetWindowWMInfo(sdl_window, &info) ||
        info.subsystem != SDL_SYSWM_COCOA)
        return false;

    NSWindow *window = info.info.cocoa.window;
    NSView *view = window.contentView;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2100_PQ);
    if (!window || !view || !space)
        return false;

    window.colorSpace = [[NSColorSpace alloc] initWithCGColorSpace:space];
    view.wantsExtendedDynamicRangeOpenGLSurface = YES;
    if (view.layer) {
        view.layer.wantsExtendedDynamicRangeContent = YES;
        view.layer.contentsFormat = kCAContentsFormatRGBA16Float;
        if ([view.layer isKindOfClass:[CAOpenGLLayer class]])
            ((CAOpenGLLayer *)view.layer).colorspace = space;
    }
    CGColorSpaceRelease(space);
    return true;
}

static bool resize_texture_fbo(GLuint *fbo, GLuint *tex, int *old_w, int *old_h,
                               int w, int h, bool pq)
{
    if (*fbo && *old_w == w && *old_h == h) {
        glBindFramebuffer(GL_FRAMEBUFFER, *fbo);
        return true;
    }
    if (*fbo)
        glDeleteFramebuffers(1, fbo);
    if (*tex)
        glDeleteTextures(1, tex);
    *fbo = *tex = 0;

    glGenTextures(1, tex);
    glBindTexture(GL_TEXTURE_2D, *tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, pq ? GL_RGBA16F : GL_RGBA8, w, h, 0,
                 GL_RGBA, pq ? GL_HALF_FLOAT : GL_UNSIGNED_BYTE, NULL);

    glGenFramebuffers(1, fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, *fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                           *tex, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
        return false;
    *old_w = w;
    *old_h = h;
    return true;
}

static bool save_ppm(const char *path, int w, int h)
{
    if (!path)
        return true;
    unsigned char *pixels = malloc((size_t)w * h * 3);
    if (!pixels)
        return false;
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, w, h, GL_RGB, GL_UNSIGNED_BYTE, pixels);
    FILE *file = fopen(path, "wb");
    if (!file) {
        free(pixels);
        return false;
    }
    fprintf(file, "P6\n%d %d\n255\n", w, h);
    for (int y = h - 1; y >= 0; y--)
        fwrite(pixels + (size_t)y * w * 3, 1, (size_t)w * 3, file);
    fclose(file);
    free(pixels);
    return true;
}

int main(int argc, char **argv)
{
    struct options o;
    if (!parse_options(argc, argv, &o)) {
        usage(argv[0]);
        return argc > 1 && !strcmp(argv[1], "--help") ? 0 : 2;
    }
    const bool pq = !strcmp(o.output, "pq");
    const bool texture = !strcmp(o.fbo, "texture");

    if (SDL_Init(SDL_INIT_VIDEO) < 0)
        return fprintf(stderr, "SDL init: %s\n", SDL_GetError()), 1;
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 2);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
    SDL_GL_SetAttribute(SDL_GL_RED_SIZE, pq ? 16 : 8);
    SDL_GL_SetAttribute(SDL_GL_GREEN_SIZE, pq ? 16 : 8);
    SDL_GL_SetAttribute(SDL_GL_BLUE_SIZE, pq ? 16 : 8);
    SDL_GL_SetAttribute(SDL_GL_ALPHA_SIZE, pq ? 16 : 8);
    SDL_GL_SetAttribute(SDL_GL_FLOATBUFFERS, pq ? 1 : 0);

    SDL_Window *window = SDL_CreateWindow("libmpv OpenGL smoke",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, 960, 540,
        SDL_WINDOW_OPENGL | SDL_WINDOW_ALLOW_HIGHDPI | SDL_WINDOW_RESIZABLE);
    if (!window)
        return fprintf(stderr, "window: %s\n", SDL_GetError()), 1;
    if (pq && !configure_pq_window(window))
        return fprintf(stderr, "PQ target unavailable\n"), 3;
    SDL_GLContext gl = SDL_GL_CreateContext(window);
    if (!gl)
        return fprintf(stderr, "OpenGL context: %s\n", SDL_GetError()), 1;

    int r, g, b, a, fp;
    SDL_GL_GetAttribute(SDL_GL_RED_SIZE, &r);
    SDL_GL_GetAttribute(SDL_GL_GREEN_SIZE, &g);
    SDL_GL_GetAttribute(SDL_GL_BLUE_SIZE, &b);
    SDL_GL_GetAttribute(SDL_GL_ALPHA_SIZE, &a);
    SDL_GL_GetAttribute(SDL_GL_FLOATBUFFERS, &fp);
    fprintf(stderr, "renderer=%s output=%s fbo=%s hwdec=%s flip=%s depth=%d "
                    "GL=%s target=R%dG%dB%dA%d float=%d\n",
            o.renderer, o.output, o.fbo, o.hwdec, o.flip, o.depth,
            glGetString(GL_VERSION), r, g, b, a, fp);
    if (pq && (r < 10 || g < 10 || b < 10))
        return fprintf(stderr, "PQ target requires a >=10-bit buffer\n"), 3;

    mpv_handle *mpv = mpv_create();
    if (!mpv)
        return 1;
    mpv_set_option_string(mpv, "config", "no");
    mpv_set_option_string(mpv, "terminal", "yes");
    mpv_set_option_string(mpv, "msg-level", "all=v");
    if (o.log)
        mpv_set_option_string(mpv, "log-file", o.log);
    mpv_set_option_string(mpv, "vo", "libmpv");
    mpv_set_option_string(mpv, "audio", "no");
    mpv_set_option_string(mpv, "hwdec", o.hwdec);
    mpv_set_option_string(mpv, "pause", "yes");
    char start[32];
    snprintf(start, sizeof(start), "%.3f", o.start);
    mpv_set_option_string(mpv, "start", start);
    if (pq) {
        mpv_set_option_string(mpv, "target-prim", "bt.2020");
        mpv_set_option_string(mpv, "target-trc", "pq");
        mpv_set_option_string(mpv, "target-peak", "500");
        mpv_set_option_string(mpv, "icc-profile-auto", "no");
    }
    int err = mpv_initialize(mpv);
    if (err < 0)
        return fprintf(stderr, "mpv init: %s\n", mpv_error_string(err)), 1;

    char api[] = MPV_RENDER_API_TYPE_OPENGL;
    mpv_opengl_init_params gl_init = {.get_proc_address = get_proc_address};
    int advanced = 1;
    mpv_render_param create_params[] = {
        {MPV_RENDER_PARAM_API_TYPE, api},
        {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl_init},
        {MPV_RENDER_PARAM_RENDERER, (void *)o.renderer},
        {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced},
        {0},
    };
    mpv_render_context *render = NULL;
    err = mpv_render_context_create(&render, mpv, create_params);
    if (err < 0)
        return fprintf(stderr, "render context: %s (%d)\n",
                       mpv_error_string(err), err), 1;

    const char *load[] = {"loadfile", o.video, NULL};
    if ((err = mpv_command(mpv, load)) < 0)
        return fprintf(stderr, "loadfile: %s\n", mpv_error_string(err)), 1;
    if (o.exercise) {
        const char *show_text[] = {"show-text", "libmpv gpu-next smoke", "10000",
                                   NULL};
        mpv_command(mpv, show_text);
        mpv_set_property_string(mpv, "sid", "1");
    }

    GLuint target_fbo = 0, target_tex = 0;
    int target_w = 0, target_h = 0, rendered = 0;
    bool configured = false, quit = false;
    bool screenshot_done = !o.mpv_screenshot;
    Uint32 resume_at = 0;
    while (!quit) {
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_QUIT)
                quit = true;
        }
        mpv_event *mpv_event;
        while ((mpv_event = mpv_wait_event(mpv, 0))->event_id != MPV_EVENT_NONE) {
            if (mpv_event->event_id == MPV_EVENT_VIDEO_RECONFIG)
                configured = true;
            if (mpv_event->event_id == MPV_EVENT_END_FILE)
                quit = true;
            if (mpv_event->event_id == MPV_EVENT_COMMAND_REPLY &&
                mpv_event->reply_userdata == 1) {
                if (mpv_event->error < 0) {
                    fprintf(stderr, "mpv screenshot: %s (%d)\n",
                            mpv_error_string(mpv_event->error), mpv_event->error);
                    err = mpv_event->error;
                    quit = true;
                } else {
                    screenshot_done = true;
                }
            }
        }
        if (resume_at && SDL_TICKS_PASSED(SDL_GetTicks(), resume_at)) {
            int pause = 0;
            mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &pause);
            resume_at = 0;
        }
        if (!(mpv_render_context_update(render) & MPV_RENDER_UPDATE_FRAME)) {
            SDL_Delay(5);
            continue;
        }

        int w, h;
        SDL_GL_GetDrawableSize(window, &w, &h);
        glViewport(0, 0, w, h);
        if (texture && !resize_texture_fbo(&target_fbo, &target_tex,
                                           &target_w, &target_h, w, h, pq)) {
            fprintf(stderr, "texture framebuffer incomplete\n");
            break;
        }
        mpv_opengl_fbo fbo = {
            .fbo = texture ? (int)target_fbo : 0,
            .w = w,
            .h = h,
            .internal_format = texture ? (pq ? GL_RGBA16F : GL_RGBA8) : 0,
        };
        int block = 0, flip = atoi(o.flip), depth = o.depth;
        mpv_render_param params[] = {
            {MPV_RENDER_PARAM_OPENGL_FBO, &fbo},
            {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block},
            {!strcmp(o.flip, "default") ? MPV_RENDER_PARAM_INVALID
                                         : MPV_RENDER_PARAM_FLIP_Y, &flip},
            {o.depth > 0 ? MPV_RENDER_PARAM_DEPTH : MPV_RENDER_PARAM_INVALID,
             &depth},
            {0},
        };
        if ((err = mpv_render_context_render(render, params)) < 0) {
            fprintf(stderr, "render: %s (%d)\n", mpv_error_string(err), err);
            break;
        }
        if (texture) {
            glBindFramebuffer(GL_READ_FRAMEBUFFER, target_fbo);
            glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
            glBlitFramebuffer(0, 0, w, h, 0, 0, w, h,
                              GL_COLOR_BUFFER_BIT, GL_NEAREST);
            glBindFramebuffer(GL_FRAMEBUFFER, 0);
        }
        if (configured) {
            rendered++;
            if (o.mpv_screenshot && rendered == 1) {
                const char *screenshot[] = {"screenshot-to-file",
                                            o.mpv_screenshot, "video", NULL};
                if ((err = mpv_command_async(mpv, 1, screenshot)) < 0) {
                    fprintf(stderr, "mpv screenshot: %s (%d)\n",
                            mpv_error_string(err), err);
                    break;
                }
            }
            if (o.exercise && rendered == 2)
                SDL_SetWindowSize(window, 800, 450);
            if (o.exercise && rendered == 4) {
                double seek = o.start + 2.0;
                mpv_set_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &seek);
            }
            if (o.exercise && rendered == 6) {
                int pause = 0;
                mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &pause);
            }
            if (o.exercise && rendered == 10) {
                int pause = 1;
                mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &pause);
                resume_at = SDL_GetTicks() + 200;
                SDL_SetWindowSize(window, 960, 540);
            }
            if (rendered >= o.frames && screenshot_done) {
                quit = true;
                if (!save_ppm(o.screenshot, w, h))
                    err = MPV_ERROR_GENERIC;
            }
        }
        SDL_GL_SwapWindow(window);
    }

    mpv_render_context_free(render);
    if (target_fbo)
        glDeleteFramebuffers(1, &target_fbo);
    if (target_tex)
        glDeleteTextures(1, &target_tex);
    mpv_terminate_destroy(mpv);
    SDL_GL_DeleteContext(gl);
    SDL_DestroyWindow(window);
    SDL_Quit();
    fprintf(stderr, "rendered=%d result=%s\n", rendered, mpv_error_string(err));
    return err < 0 || !rendered;
}
