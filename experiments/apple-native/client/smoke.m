#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CommonCrypto/CommonDigest.h>
#include <TargetConditionals.h>
#include <stdatomic.h>
#include <math.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <sys/resource.h>
#include <errno.h>
#include <mpv/client.h>
#include <mpv/render_apple.h>

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#include "vk-target.h"
#else
#import <Cocoa/Cocoa.h>
#import <OpenGL/gl3.h>
#include <mpv/render_gl.h>
#endif

static NSString *option(NSString *name, NSString *fallback)
{
    NSString *prefix = [name stringByAppendingString:@"="];
    for (NSString *value in NSProcessInfo.processInfo.arguments)
        if ([value hasPrefix:prefix]) return [value substringFromIndex:prefix.length];
    return fallback;
}

static NSDictionary *buffer_info(CVPixelBufferRef buffer)
{
    NSDictionary *raw = CFBridgingRelease(CVBufferCopyAttachments(buffer, kCVAttachmentMode_ShouldPropagate));
    NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
    for (NSString *key in raw) {
        id value = raw[key];
        if ([value isKindOfClass:NSData.class]) {
            unsigned char digest[CC_SHA256_DIGEST_LENGTH];
            CC_SHA256([value bytes], (CC_LONG)[value length], digest);
            NSMutableString *sha = [NSMutableString string];
            for (unsigned i = 0; i < sizeof(digest); i++) [sha appendFormat:@"%02x", digest[i]];
            attrs[key] = @{@"bytes": @([value length]), @"sha256": sha};
        } else attrs[key] = [value description];
    }
    uint32_t f = CVPixelBufferGetPixelFormatType(buffer);
    return @{@"width": @(CVPixelBufferGetWidth(buffer)), @"height": @(CVPixelBufferGetHeight(buffer)),
        @"format": [NSString stringWithFormat:@"%c%c%c%c", f >> 24, (f >> 16) & 255, (f >> 8) & 255, f & 255],
        @"attachments": attrs};
}

@interface NativeSmoke : NSObject
#if TARGET_OS_IPHONE
    <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic) struct vk_target vk;
@property(nonatomic) BOOL useVulkan;
#else
    <NSApplicationDelegate, NSWindowDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSOpenGLContext *gl;
@property(nonatomic) GLuint texture, framebuffer;
#endif
@property(nonatomic, strong) AVSampleBufferDisplayLayer *display;
@property(nonatomic, strong) CALayer *overlay;
@property(nonatomic, strong) dispatch_queue_t renderQueue;
@property(nonatomic) mpv_handle *mpv;
@property(nonatomic) mpv_render_context *render;
@property(nonatomic, strong) NSMutableDictionary *properties;
@property(nonatomic, strong) NSMutableArray *displayed;
@property(nonatomic, strong) NSMutableArray *frames;
@property(nonatomic, strong) NSString *file;
@property(nonatomic) double seconds;
@property(nonatomic) double startPTS;
@property(nonatomic) double started;
@property(atomic) unsigned rendered;
@property(atomic) unsigned errors;
@property(nonatomic) BOOL audio;
@property(nonatomic) CGSize pixels;
@property(nonatomic) double scale;
@property(nonatomic) unsigned lifecyclePhase;
@property(nonatomic) unsigned seeks;
@property(nonatomic) unsigned skipped;
@property(nonatomic) unsigned screenshotFailures;
@property(atomic) unsigned overlays;
@property(nonatomic) unsigned beforeRender;
@property(nonatomic) BOOL restarting;
@property(nonatomic) BOOL lifecycle;
@property(nonatomic) double seekTarget;
@property(nonatomic) double backgroundPTS;
@property(nonatomic) BOOL backgrounded;
@property(nonatomic) unsigned resumes;
@property(atomic) BOOL suspended;
@property(nonatomic) double backgroundStarted;
@property(nonatomic) unsigned resumePhase;
@property(nonatomic) BOOL savedPaused;
@property(atomic, strong) NSString *actual;
@property(nonatomic, strong) NSMutableArray *modes;
@property(atomic) unsigned gpuFrames;
@property(nonatomic) BOOL switchedFeature;
@property(nonatomic) double firstProgressTime, firstVideoPTS, lastVideoPTS, lastAudioPTS;
@property(nonatomic) unsigned stalledVideoSeconds, stalledAudioSeconds, badSyncSeconds;
@property(nonatomic, strong) NSMutableArray *progress;
@property(nonatomic, strong) NSString *inputHash;
- (void)scheduleRender;
- (void)events;
- (void)finish:(int)code;
- (void)start;
- (void)parameterTests;
- (void)updateGeometry;
@end

#if TARGET_OS_IPHONE
@interface NativeController : UIViewController
@property(nonatomic, weak) NativeSmoke *owner;
@end
@implementation NativeController
- (void)viewDidLayoutSubviews
{ [super viewDidLayoutSubviews]; [self.owner updateGeometry]; }
@end
#endif

static NativeSmoke *probe;
static atomic_bool stopping, scheduled;

__attribute__((visibility("default")))
bool mpv_native_probe_fail_present(void)
{
    static unsigned frames;
    static BOOL failed;
    int after = option(@"--fail-native-after", @"-1").intValue;
    if (!failed && after >= 0 && frames++ >= (unsigned)after) { failed = YES; return true; }
    return false;
}

#if !TARGET_OS_IPHONE
static void *gl_proc(void *ctx, const char *name)
{ (void)ctx; return dlsym(RTLD_DEFAULT, name); }
#endif

// Test-only weak observer; not part of the candidate API or final production diff.
__attribute__((visibility("default")))
void mpv_native_probe_frame(CVPixelBufferRef buffer, CMSampleBufferRef sample, double pts, bool dv,
                            const uint8_t *data, size_t size)
{
    @synchronized (probe.frames) {
        if (probe.frames.count >= 24) return;
        NSMutableDictionary *info = [buffer_info(buffer) mutableCopy];
        info[@"pts"] = @(pts);
        info[@"dv"] = @(dv);
        NSData *rpu = (__bridge id)CVBufferGetAttachment(buffer, CFSTR("DolbyVisionRPUData"), NULL);
        info[@"rpu_matches_source"] = @(dv && rpu && data && size == rpu.length && !memcmp(data, rpu.bytes, size));
        info[@"same_buffer"] = @(CMSampleBufferGetImageBuffer(sample) == buffer);
        info[@"metadata_preserved"] = @([buffer_info(CMSampleBufferGetImageBuffer(sample)) isEqualToDictionary:buffer_info(buffer)]);
        [probe.frames addObject:info];
    }
}

static void update(void *ctx)
{
    NativeSmoke *p = (__bridge id)ctx;
    [p scheduleRender];
}

static void wakeup(void *ctx)
{
    NativeSmoke *p = (__bridge id)ctx;
    dispatch_async(dispatch_get_main_queue(), ^{ if (!atomic_load(&stopping)) [p events]; });
}

@implementation NativeSmoke
- (void)parameterTests
{
    mpv_apple_native_init_params init = {.version = 1, .display_layer = (__bridge void *)self.display};
    mpv_render_param valid[] = {{MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_APPLE_NATIVE},
        {MPV_RENDER_PARAM_OUTPUT_MODE, "native"}, {MPV_RENDER_PARAM_APPLE_NATIVE_INIT_PARAMS, &init}, {0}};
    for (unsigned index = 0; index < 20; index++) {
        mpv_render_context *ctx = NULL;
        if (mpv_render_context_create(&ctx, self.mpv, valid) < 0) exit(1);
        const char *actual = NULL;
        if (mpv_render_context_get_info(ctx, (mpv_render_param){MPV_RENDER_PARAM_OUTPUT_MODE, &actual}) ||
            !actual || strcmp(actual, "native")) exit(1);
        mpv_apple_native_target target = {.version = 1, .w = 16, .h = 16};
        mpv_render_param draw[] = {{MPV_RENDER_PARAM_APPLE_NATIVE_TARGET, &target}, {0}};
        if (mpv_render_context_render(ctx, draw) < 0 || target.osd) exit(1);
        target.version = 2;
        if (mpv_render_context_render(ctx, draw) != MPV_ERROR_INVALID_PARAMETER) exit(1);
        target.version = 1; target.w = 0;
        if (mpv_render_context_render(ctx, draw) != MPV_ERROR_INVALID_PARAMETER) exit(1);
        int skip = 1;
        mpv_render_param ignore[] = {{MPV_RENDER_PARAM_SKIP_RENDERING, &skip}, {0}};
        if (mpv_render_context_render(ctx, ignore) < 0) exit(1);
        target.w = 16;
        mpv_render_param early[] = {{MPV_RENDER_PARAM_APPLE_NATIVE_TARGET, &target},
            {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &(int){0}}, {0}};
        if (mpv_render_context_render(ctx, early) != MPV_ERROR_INVALID_PARAMETER) exit(1);
        mpv_render_context_free(ctx);
    }
    const char *modes[] = {"", "unknown", NULL, "auto", "render"};
    const int expected[] = {MPV_ERROR_INVALID_PARAMETER, MPV_ERROR_INVALID_PARAMETER,
        MPV_ERROR_INVALID_PARAMETER, MPV_ERROR_INVALID_PARAMETER, MPV_ERROR_NOT_IMPLEMENTED};
    for (unsigned i = 0; i < sizeof(modes) / sizeof(modes[0]); i++) {
        valid[1].data = (void *)modes[i];
        mpv_render_context *ctx = NULL;
        if (mpv_render_context_create(&ctx, self.mpv, valid) != expected[i] || ctx) exit(1);
    }
    valid[1].data = "native"; init.version = 2;
    mpv_render_context *ctx = NULL;
    if (mpv_render_context_create(&ctx, self.mpv, valid) != MPV_ERROR_INVALID_PARAMETER || ctx) exit(1);
    init.version = 1;
    for (unsigned i = 0; i < 2; i++) {
        mpv_render_param sw[] = {{MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_SW},
            {MPV_RENDER_PARAM_OUTPUT_MODE, "render"}, {0}};
        if (mpv_render_context_create(&ctx, self.mpv, i ? sw : (mpv_render_param[]) {
            {MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_SW}, {0}}) < 0) exit(1);
        uint8_t pixels[4 * 4 * 4] = {0};
        size_t stride = 16;
        mpv_render_param draw[] = {{MPV_RENDER_PARAM_SW_SIZE, (int[]){4,4}},
            {MPV_RENDER_PARAM_SW_FORMAT, "rgb0"}, {MPV_RENDER_PARAM_SW_STRIDE, &stride},
            {MPV_RENDER_PARAM_SW_POINTER, pixels}, {0}};
        if (mpv_render_context_render(ctx, draw) < 0) exit(1);
        mpv_render_context_free(ctx); ctx = NULL;
    }
    printf("NATIVE_PARAMETER_CHECKS=PASS CONTEXTS=20 SOFTWARE_DEFAULT=PASS\n");
}
- (void)scheduleRender
{
    bool expected = false;
    if (atomic_load(&stopping) || !atomic_compare_exchange_strong(&scheduled, &expected, true)) return;
    dispatch_async(self.renderQueue, ^{
        @autoreleasepool {
#if !TARGET_OS_IPHONE
            if (self.gl) [self.gl makeCurrentContext];
#endif
            while (!atomic_load(&stopping) && self.render &&
                   (mpv_render_context_update(self.render) & MPV_RENDER_UPDATE_FRAME)) {
                CGSize size;
                double scale;
                @synchronized (self) { size = self.pixels; scale = self.scale; }
                mpv_apple_native_target target = {.version = MPV_APPLE_NATIVE_API_VERSION,
                    .w = (int)size.width, .h = (int)size.height};
                mpv_render_param params[] = {{MPV_RENDER_PARAM_APPLE_NATIVE_TARGET, &target}, {0}};
                const char *actual = NULL;
                if (mpv_render_context_get_info(self.render,
                    (mpv_render_param){MPV_RENDER_PARAM_OUTPUT_MODE, &actual})) { [self finish:1]; break; }
                if (!self.actual || ![self.actual isEqualToString:@(actual)]) {
                    self.actual = @(actual);
                    [self.modes addObject:@{@"mode":self.actual, @"rendered":@(self.rendered)}];
                    printf("OUTPUT_MODE=%s\n", actual);
                }
                if (!strcmp(actual, "recovering")) break;
                BOOL native = !strcmp(actual, "native");
#if !TARGET_OS_IPHONE
                mpv_opengl_fbo fbo = {.fbo=(int)self.framebuffer, .w=512, .h=288};
                mpv_render_param gpu[] = {{MPV_RENDER_PARAM_OPENGL_FBO, &fbo},
                    {MPV_RENDER_PARAM_FLIP_Y, &(int){1}}, {MPV_RENDER_PARAM_DEPTH, &(int){8}}, {0}};
#else
                self->_vk.target.state=MPV_VULKAN_TARGET_UNTOUCHED;
                if (!native) self->_vk.target.completion_value++;
                mpv_render_param gpu[]={{MPV_RENDER_PARAM_VULKAN_TARGET,&self->_vk.target},{0}};
#endif
                mpv_render_param skip[] = {{MPV_RENDER_PARAM_SKIP_RENDERING, &(int){1}},
                    {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &(int){0}}, {0}};
                BOOL suspended = self.suspended;
                mpv_render_param *draw = params;
                if (!native) draw = gpu;
                int err = mpv_render_context_render(self.render, suspended ? skip : draw);
                if (err < 0) {
                    mpv_render_context_get_info(self.render, (mpv_render_param){MPV_RENDER_PARAM_OUTPUT_MODE, &actual});
                    if (actual && !strcmp(actual, "recovering")) continue;
                    self.errors++;
                    printf("NATIVE_RENDER_ERROR=%d\n", err);
                } else {
                    if (!suspended) self.rendered++;
                    mpv_render_context_report_swap(self.render);
                }
                if (suspended) continue;
#if !TARGET_OS_IPHONE
                if (!native) {
                    NSMutableData *data = [NSMutableData dataWithLength:512*288*4];
                    uint8_t *pixels = data.mutableBytes;
                    glBindFramebuffer(GL_FRAMEBUFFER, self.framebuffer);
                    glReadPixels(0,0,512,288,GL_RGBA,GL_UNSIGNED_BYTE,pixels);
                    if (glGetError()) { self.errors++; break; }
                    unsigned sum = 0;
                    for (unsigned n=0; n<data.length; n+=4) sum += pixels[n]+pixels[n+1]+pixels[n+2];
                    if (sum > 512*288) self.gpuFrames++;
                    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
                    CGColorSpaceRef color = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
                    target.osd = CGImageCreate(512,288,8,32,512*4,color,(CGBitmapInfo)kCGImageAlphaLast,
                        provider,NULL,false,kCGRenderingIntentDefault);
                    CGColorSpaceRelease(color); CGDataProviderRelease(provider);
                }
#else
                if (!native) {
                    target.osd=vk_target_read(&self->_vk);
                    unsigned sum=0;
                    for (unsigned n=0;n<512*288*4;n+=4) sum+=self->_vk.pixels[n]+self->_vk.pixels[n+1]+self->_vk.pixels[n+2];
                    if (sum>512*288) self.gpuFrames++;
                }
#endif
                if (target.osd) self.overlays++;
                CGRect video = target.video_rect;
                video.origin.x /= scale; video.origin.y /= scale;
                video.size.width /= scale; video.size.height /= scale;
                CGImageRef osd = target.osd;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!atomic_load(&stopping)) {
                        [CATransaction begin]; [CATransaction setDisableActions:YES];
                        if (video.size.width > 0 && video.size.height > 0) self.display.frame = video;
                        self.display.hidden = !native;
                        self.display.contentsRect = target.contents_rect;
                        self.overlay.contents = (__bridge id)osd;
                        [CATransaction commit];
                    }
                    if (osd) CGImageRelease(osd);
                });
                if (err < 0) { dispatch_async(dispatch_get_main_queue(), ^{ [self finish:1]; }); break; }
            }
            atomic_store(&scheduled, false);
            if (!atomic_load(&stopping) && self.render &&
                (mpv_render_context_update(self.render) & MPV_RENDER_UPDATE_FRAME)) [self scheduleRender];
#if !TARGET_OS_IPHONE
            if (self.gl) [NSOpenGLContext clearCurrentContext];
#endif
        }
    });
}

- (void)events
{
    for (;;) {
        mpv_event *event = mpv_wait_event(self.mpv, 0);
        if (event->event_id == MPV_EVENT_NONE) break;
        if (event->event_id == MPV_EVENT_LOG_MESSAGE) {
            mpv_event_log_message *log = event->data;
            printf("MPV[%s/%s] %s", log->prefix, log->level, log->text);
        } else if (event->event_id == MPV_EVENT_PROPERTY_CHANGE) {
            mpv_event_property *p = event->data;
            if (!p->data) { [self.properties removeObjectForKey:[NSString stringWithUTF8String:p->name]]; continue; }
            id value = nil;
            if (p->format == MPV_FORMAT_STRING) value = [NSString stringWithUTF8String:*(char **)p->data];
            if (p->format == MPV_FORMAT_DOUBLE) value = @(*(double *)p->data);
            if (p->format == MPV_FORMAT_FLAG) value = @(*(int *)p->data);
            if (value) self.properties[[NSString stringWithUTF8String:p->name]] = value;
        } else if (event->event_id == MPV_EVENT_END_FILE) {
            mpv_event_end_file *end = event->data;
            if (end->reason == MPV_END_FILE_REASON_ERROR) {
                printf("NATIVE_FILE_ERROR=%d\n", end->error); [self finish:1]; return;
            }
        } else if (event->event_id == MPV_EVENT_PLAYBACK_RESTART) {
            self.restarting = NO;
            if (self.resumePhase == 2) {
                self.resumePhase = 0; self.resumes++;
                mpv_command_async(self.mpv, 904, (const char *[]){"set", "pause", self.savedPaused ? "yes" : "no", NULL});
                printf("NATIVE_RESUMED=%u PTS_BEFORE=%.3f PTS_AFTER=%s\n", self.resumes,
                    self.backgroundPTS, [self.properties[@"time-pos"] description].UTF8String);
            }
        } else if (event->event_id == MPV_EVENT_FILE_LOADED && self.resumePhase == 1) {
            self.resumePhase = 2;
            char value[32]; snprintf(value, sizeof(value), "%.6f", self.backgroundPTS);
            mpv_command_async(self.mpv, 903, (const char *[]){"seek", value, "absolute+exact", NULL});
        } else if (event->event_id == MPV_EVENT_COMMAND_REPLY) {
            if (event->reply_userdata == 800) {
                if (event->error >= 0) { [self finish:1]; return; }
                self.screenshotFailures++;
            } else if (event->error < 0) {
                printf("NATIVE_COMMAND_ERROR=%d ID=%llu\n", event->error, event->reply_userdata);
                [self finish:1]; return;
            }
        }
    }
}

- (void)finish:(int)code
{
    if (atomic_exchange(&stopping, true)) return;
    dispatch_async(self.renderQueue, ^{
        @autoreleasepool {
#if !TARGET_OS_IPHONE
            if (self.gl) [self.gl makeCurrentContext];
#endif
            if (self.render) {
                mpv_render_context_set_update_callback(self.render, NULL, NULL);
                mpv_render_context_free(self.render); self.render = NULL;
            }
            mpv_set_wakeup_callback(self.mpv, NULL, NULL);
            mpv_terminate_destroy(self.mpv); self.mpv = NULL;
#if !TARGET_OS_IPHONE
            if (self.gl) { glDeleteFramebuffers(1,&self->_framebuffer); glDeleteTextures(1,&self->_texture); }
            if (self.gl) [NSOpenGLContext clearCurrentContext];
#else
            if (self.useVulkan) vk_target_destroy(&self->_vk);
#endif
            dispatch_async(dispatch_get_main_queue(), ^{
                int result = code;
                double pts = [self.properties[@"time-pos"] doubleValue];
                BOOL valid = self.rendered > 12 && pts >= self.startPTS + self.seconds - 1.5 && !self.errors;
                if ([self.actual isEqualToString:@"render"]) valid &= self.gpuFrames > 12;
                else valid &= self.displayed.count && [self.properties[@"hwdec-current"] isEqual:@"videotoolbox"];
                if (self.audio) valid &= [self.properties[@"audio-pts"] doubleValue] > 0 &&
                    [self.properties[@"current-ao"] isEqual:option(@"--ao", TARGET_OS_IPHONE ? @"audiounit" : @"coreaudio")];
                if (self.lifecycle) valid &= self.seeks == 20 && self.skipped == 20 &&
                    self.screenshotFailures == 20 && self.overlays > 0 && self.lifecyclePhase == 6;
                if ([option(@"--background-test", @"no") isEqual:@"yes"]) valid &= self.resumes > 0;
                if ([option(@"--switch-feature", @"no") isEqual:@"yes"] ||
                    option(@"--fail-native-after", @"-1").intValue >= 0)
                    valid &= [self.actual isEqualToString:@"render"] && self.gpuFrames > 12;
                if (self.seconds > 60) {
                    double elapsed = NSProcessInfo.processInfo.systemUptime - self.firstProgressTime;
                    valid &= self.firstProgressTime > 0 && elapsed >= self.seconds &&
                        pts - self.firstVideoPTS >= self.seconds - 1.5 &&
                        [self.actual isEqualToString:@"native"];
                }
                if (!valid) result = 1;
                NSDictionary *report = @{@"case_id": option(@"--case-id", @"manual"), @"exit_code": @(result),
                    @"properties": self.properties, @"displayed": self.displayed, @"frames": self.frames,
                    @"rendered": @(self.rendered), @"errors": @(self.errors), @"audio": @(self.audio),
                    @"seeks": @(self.seeks), @"skipped": @(self.skipped), @"screenshot_failures": @(self.screenshotFailures),
                    @"overlays": @(self.overlays), @"resumes": @(self.resumes),
                    @"modes":self.modes, @"gpu_frames":@(self.gpuFrames),
                    @"progress":self.progress,
                    @"input_sha256":self.inputHash ?: @"not_sampled",
                    @"requested_seconds": @(self.seconds), @"eligible_hdr": @(AVPlayer.eligibleForHDRPlayback)};
                NSString *name = [NSString stringWithFormat:@"native-%@.json", option(@"--case-id", @"manual")];
#if TARGET_OS_IPHONE
                NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:[@"Documents/" stringByAppendingString:name]];
#else
                NSString *path = option(@"--report", name);
#endif
                NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
                if (!json || ![json writeToFile:path atomically:YES]) result = 1;
                printf("NATIVE_RESULT=%s EXIT=%d RENDERED=%u CASE_ID=%s REPORT=%s\n", result ? "FAIL" : "PASS",
                    result, self.rendered, option(@"--case-id", @"manual").UTF8String, path.UTF8String);
                fflush(stdout);
#if TARGET_OS_IPHONE
                UIApplication.sharedApplication.idleTimerDisabled = NO;
#else
                [self.window orderOut:nil];
#endif
                exit(result);
            });
        }
    });
}

- (void)tick:(NSTimer *)timer
{
    (void)timer;
    if (atomic_load(&stopping)) return;
    [self events];
    if (self.backgrounded) return;
    double pts = [self.properties[@"time-pos"] doubleValue];
    if (!self.switchedFeature && self.rendered >= 20 && [self.actual isEqualToString:@"native"] &&
        [option(@"--switch-feature", @"no") isEqual:@"yes"]) {
        self.switchedFeature=YES;
        mpv_command_async(self.mpv,906,(const char *[]){"set","interpolation","yes",NULL});
    }
    AVSampleBufferVideoRenderer *renderer = self.display.sampleBufferRenderer;
    if (self.display.readyForDisplay && self.displayed.count < 24) {
        CVPixelBufferRef displayed = [renderer copyDisplayedPixelBuffer];
        if (displayed) { [self.displayed addObject:buffer_info(displayed)]; CVPixelBufferRelease(displayed); }
    }
    printf("NATIVE_PROGRESS PTS=%.3f RENDERED=%u HWDEC=%s AO=%s DISPLAY=%ld AVSYNC=%s\n", pts,
        self.rendered, [self.properties[@"hwdec-current"] description].UTF8String,
        [self.properties[@"current-ao"] description].UTF8String, (long)renderer.status,
        [self.properties[@"avsync"] description].UTF8String);
    if (self.seconds > 60 && self.rendered > 0 && self.display.readyForDisplay) {
        double now = NSProcessInfo.processInfo.systemUptime;
        if (!self.firstProgressTime) {
            self.firstProgressTime = now;
            self.firstVideoPTS = self.lastVideoPTS = pts;
            self.lastAudioPTS = [self.properties[@"audio-pts"] doubleValue];
        }
        NSMutableDictionary *sample = [self.properties mutableCopy];
        sample[@"elapsed"] = @(now - self.firstProgressTime);
        sample[@"rendered"] = @(self.rendered);
        sample[@"output_mode"] = self.actual ?: @"unavailable";
        sample[@"display_status"] = @(renderer.status);
        struct rusage usage = {0};
        if (!getrusage(RUSAGE_SELF, &usage))
            sample[@"cpu_seconds"] = @(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec +
                (usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000000.0);
        else sample[@"cpu_unavailable"] = @(errno);
        task_vm_info_data_t memory = {0};
        mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
        kern_return_t status = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&memory, &count);
        if (status == KERN_SUCCESS && count >= TASK_VM_INFO_REV1_COUNT) {
            sample[@"resident_bytes"] = @(memory.resident_size);
            sample[@"footprint_bytes"] = @(memory.phys_footprint);
        } else sample[@"memory_unavailable"] = @(status);
        [self.progress addObject:sample];
        if (now - self.firstProgressTime >= 5) {
            double audio = [self.properties[@"audio-pts"] doubleValue];
            double sync = [self.properties[@"avsync"] doubleValue];
            self.stalledVideoSeconds = pts > self.lastVideoPTS ? 0 : self.stalledVideoSeconds + 1;
            self.stalledAudioSeconds = audio > self.lastAudioPTS ? 0 : self.stalledAudioSeconds + 1;
            self.badSyncSeconds = isfinite(sync) && fabs(sync) <= .100 ? 0 : self.badSyncSeconds + 1;
            if (!self.properties[@"audio-pts"] || !self.properties[@"avsync"] ||
                ![self.actual isEqual:@"native"] ||
                ![self.properties[@"hwdec-current"] isEqual:@"videotoolbox"] ||
                self.stalledVideoSeconds >= 5 || self.stalledAudioSeconds >= 5 ||
                self.badSyncSeconds >= 5 || renderer.status == AVQueuedSampleBufferRenderingStatusFailed) {
                printf("NATIVE_LONG_ERROR=1 VIDEO_STALL=%u AUDIO_STALL=%u SYNC=%u\n",
                    self.stalledVideoSeconds, self.stalledAudioSeconds, self.badSyncSeconds);
                [self finish:1]; return;
            }
        }
        self.lastVideoPTS = pts;
        self.lastAudioPTS = [self.properties[@"audio-pts"] doubleValue];
        if (now - self.firstProgressTime >= self.seconds) { [self finish:0]; return; }
    }
    if (self.lifecycle) {
        if (self.lifecyclePhase == 0 && pts >= 1 && self.displayed.count) {
            const char *pause[] = {"set", "pause", "yes", NULL};
            mpv_command_async(self.mpv, 300, pause);
            const char *osd[] = {"show-text", "Native OSD test", "10000", NULL};
            mpv_command_async(self.mpv, 301, osd);
            self.lifecyclePhase = 1;
        } else if (self.lifecyclePhase == 1 && [self.properties[@"pause"] boolValue]) {
            self.seekTarget = self.seeks % 2 ? 6 : 2;
            self.beforeRender = self.rendered;
            self.restarting = YES;
            char value[32]; snprintf(value, sizeof(value), "%.3f", self.seekTarget);
            mpv_command_async(self.mpv, 302, (const char *[]){"seek", value, "absolute+exact", NULL});
            self.lifecyclePhase = 2;
        } else if (self.lifecyclePhase == 2 && !self.restarting &&
                   self.rendered > self.beforeRender && fabs(pts - self.seekTarget) < .1) {
            self.lifecyclePhase = 3;
            dispatch_async(self.renderQueue, ^{
                int skip = 1, block = 0;
                mpv_render_param ignore[] = {{MPV_RENDER_PARAM_SKIP_RENDERING, &skip},
                    {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block}, {0}};
                int err = mpv_render_context_render(self.render, ignore);
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (err) { [self finish:1]; return; }
                    self.skipped++;
                    mpv_command_async(self.mpv, 800, (const char *[]){"screenshot-raw", "video", NULL});
                });
            });
        } else if (self.lifecyclePhase == 3 && self.skipped == self.seeks + 1 &&
                   self.screenshotFailures == self.skipped) {
            self.seeks++;
            printf("NATIVE_SEEK_CHECK=%u PTS=%.3f SKIPPED=%u\n", self.seeks, pts, self.skipped);
            self.lifecyclePhase = self.seeks < 20 ? 1 : 4;
            if (self.lifecyclePhase == 4)
                mpv_command_async(self.mpv, 303, (const char *[]){"stop", NULL});
        } else if (self.lifecyclePhase == 4 && !self.properties[@"time-pos"]) {
            self.lifecyclePhase = 5;
            self.beforeRender = self.rendered;
            self.restarting = YES;
            dispatch_async(self.renderQueue, ^{
                mpv_apple_native_target target = {.version=1, .w=16, .h=16};
                int err = mpv_render_context_render(self.render,
                    (mpv_render_param[]){{MPV_RENDER_PARAM_APPLE_NATIVE_TARGET, &target}, {0}});
                BOOL clear = !target.osd;
                if (target.osd) CGImageRelease(target.osd);
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (err || !clear) { [self finish:1]; return; }
                    mpv_command_async(self.mpv, 304,
                        (const char *[]){"loadfile", self.file.UTF8String, NULL});
                });
            });
        } else if (self.lifecyclePhase == 5 && !self.restarting && self.rendered > self.beforeRender) {
            self.lifecyclePhase = 6;
            printf("NATIVE_LIFECYCLE=PASS SEEK=20 SKIP=20 SCREENSHOT_UNSUPPORTED=20 STOP_RENDER=PASS\n");
            // Duration is not a completion criterion for the paused lifecycle case.
            self.seconds = 1;
            [self finish:0];
        }
    } else if (self.seconds <= 60 && pts >= self.startPTS + self.seconds) [self finish:0];
    else if (NSProcessInfo.processInfo.systemUptime - self.started > self.seconds + 15) [self finish:1];
}

- (void)start
{
    setbuf(stdout, NULL);
    probe = self;
    self.properties = [NSMutableDictionary dictionary]; self.displayed = [NSMutableArray array];
    self.progress = [NSMutableArray array];
    self.modes = [NSMutableArray array];
    self.frames = [NSMutableArray array]; self.seconds = option(@"--seconds", @"8").doubleValue;
    self.startPTS = option(@"--start", @"0").doubleValue;
    self.audio = [option(@"--audio", @"no") isEqual:@"yes"];
    self.lifecycle = [option(@"--lifecycle", @"no") isEqual:@"yes"];
    self.file = option(@"--file", nil);
#if TARGET_OS_IPHONE
    if (self.file && !self.file.isAbsolutePath)
        self.file = [NSHomeDirectory() stringByAppendingPathComponent:self.file];
    if (!self.file) self.file = [NSBundle.mainBundle pathForResource:option(@"--media", @"dv-mp4")
        ofType:[@[@"dv-mkv", @"hdr10", @"dv-audio"] containsObject:option(@"--media", @"dv-mp4")] ? @"mkv" : @"mp4"];
#endif
    if (!self.file || !isfinite(self.seconds) || self.seconds < 1 || self.seconds > 900) exit(2);
    if (self.seconds > 60) {
        NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:self.file];
        [stream open];
        CC_SHA256_CTX hash;
        CC_SHA256_Init(&hash);
        uint8_t buffer[65536], digest[CC_SHA256_DIGEST_LENGTH];
        NSInteger count;
        while ((count = [stream read:buffer maxLength:sizeof(buffer)]) > 0)
            CC_SHA256_Update(&hash, buffer, (CC_LONG)count);
        [stream close];
        if (count < 0) exit(1);
        CC_SHA256_Final(digest, &hash);
        NSMutableString *value = [NSMutableString string];
        for (unsigned n = 0; n < sizeof(digest); n++) [value appendFormat:@"%02x", digest[n]];
        self.inputHash = value;
        printf("NATIVE_LONG_INPUT_SHA256=%s\n", value.UTF8String);
    }
#if TARGET_OS_IPHONE
    NSDictionary *storage = [NSFileManager.defaultManager attributesOfFileSystemForPath:NSHomeDirectory() error:nil];
    printf("NATIVE_STORAGE_FREE_BYTES=%llu\n", [storage[NSFileSystemFreeSize] unsignedLongLongValue]);
#endif
    self.renderQueue = dispatch_queue_create("native-render", DISPATCH_QUEUE_SERIAL);
    self.display = [AVSampleBufferDisplayLayer layer]; self.display.videoGravity = AVLayerVideoGravityResize;
    self.overlay = [CALayer layer];
#if TARGET_OS_IPHONE
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    NativeController *controller = [NativeController new]; controller.owner = self;
    controller.view.backgroundColor = UIColor.blackColor;
    self.window.rootViewController = controller; [self.window makeKeyAndVisible];
    CGSize points = controller.view.bounds.size; self.scale = UIScreen.mainScreen.scale;
    [controller.view.layer addSublayer:self.display]; [controller.view.layer addSublayer:self.overlay];
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    if (self.audio) {
        NSError *error = nil;
        [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback error:&error];
        if (!error) [AVAudioSession.sharedInstance setActive:YES error:&error];
        if (error) { printf("AUDIO_SESSION_ERROR=%s\n", error.description.UTF8String); exit(1); }
        printf("AUDIO_ROUTE=%s\n", AVAudioSession.sharedInstance.currentRoute.description.UTF8String);
    }
#else
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(80, 100, 960, 540)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.delegate = self; self.window.title = @"libmpv native / system video output";
    self.window.contentView.wantsLayer = YES;
    CGSize points = self.window.contentView.bounds.size; self.scale = self.window.backingScaleFactor;
    [self.window.contentView.layer addSublayer:self.display]; [self.window.contentView.layer addSublayer:self.overlay];
    [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
#endif
    self.display.frame = CGRectMake(0, 0, points.width, points.height);
    self.overlay.frame = self.display.frame;
    self.pixels = CGSizeMake(points.width * self.scale, points.height * self.scale);
    self.mpv = mpv_create(); if (!self.mpv) exit(1);
    const char *opts[][2] = {{"config","no"},{"vo","libmpv"},{"video-sync","audio"},
        {"keep-open","yes"},{"audio-channels","stereo"},{"volume","50"}};
    for (unsigned i = 0; i < sizeof(opts) / sizeof(opts[0]); i++)
        if (mpv_set_option_string(self.mpv, opts[i][0], opts[i][1]) < 0) exit(1);
    if (mpv_set_option_string(self.mpv, "start", option(@"--start", @"0").UTF8String) < 0) exit(1);
    if (mpv_set_option_string(self.mpv, "hwdec", "no") < 0) exit(1);
    if (mpv_set_option_string(self.mpv, self.audio ? "ao" : "audio",
        self.audio ? option(@"--ao", TARGET_OS_IPHONE ? @"audiounit" : @"coreaudio").UTF8String : "no") < 0) exit(1);
    if (mpv_set_option_string(self.mpv, "audio-device", option(@"--audio-device", @"auto").UTF8String) < 0) exit(1);
    mpv_request_log_messages(self.mpv, "v");
    const char *strings[] = {"hwdec-current", "current-ao", "audio-device", "video-format", NULL};
    const char *numbers[] = {"time-pos", "audio-pts", "avsync", "frame-drop-count",
        "decoder-frame-drop-count", "volume", NULL};
    for (unsigned i = 0; strings[i]; i++) mpv_observe_property(self.mpv, i, strings[i], MPV_FORMAT_STRING);
    for (unsigned i = 0; numbers[i]; i++) mpv_observe_property(self.mpv, i + 10, numbers[i], MPV_FORMAT_DOUBLE);
    mpv_observe_property(self.mpv, 30, "pause", MPV_FORMAT_FLAG);
    if (mpv_initialize(self.mpv) < 0) exit(1);
    mpv_set_wakeup_callback(self.mpv, wakeup, (__bridge void *)self);
    dispatch_sync(self.renderQueue, ^{
        if ([option(@"--parameter-tests", @"no") isEqual:@"yes"]) [self parameterTests];
        mpv_apple_native_init_params init = {.version = MPV_APPLE_NATIVE_API_VERSION,
            .display_layer = (__bridge void *)self.display};
        mpv_render_param params[] = {{MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_APPLE_NATIVE},
            {MPV_RENDER_PARAM_OUTPUT_MODE, (void *)option(@"--mode", @"native").UTF8String},
            {MPV_RENDER_PARAM_APPLE_NATIVE_INIT_PARAMS, &init},
            {MPV_RENDER_PARAM_ADVANCED_CONTROL, &(int){1}}, {0}};
#if !TARGET_OS_IPHONE
        mpv_opengl_init_params glinit = {.get_proc_address = gl_proc};
        if ([option(@"--fallback", @"none") isEqual:@"opengl"]) {
            NSOpenGLPixelFormatAttribute attrs[] = {NSOpenGLPFAOpenGLProfile,NSOpenGLProfileVersion4_1Core,
                NSOpenGLPFAAccelerated,NSOpenGLPFAAllowOfflineRenderers,NSOpenGLPFAColorSize,32,0};
            self.gl = [[NSOpenGLContext alloc] initWithFormat:[[NSOpenGLPixelFormat alloc] initWithAttributes:attrs]
                shareContext:nil];
            if (!self.gl) exit(77);
            [self.gl makeCurrentContext];
            glGenTextures(1,&self->_texture); glBindTexture(GL_TEXTURE_2D,self.texture);
            glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,512,288,0,GL_RGBA,GL_UNSIGNED_BYTE,NULL);
            glGenFramebuffers(1,&self->_framebuffer); glBindFramebuffer(GL_FRAMEBUFFER,self.framebuffer);
            glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,self.texture,0);
            if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) exit(1);
            params[0].data = MPV_RENDER_API_TYPE_OPENGL;
        }
        mpv_render_param combined[8];
        memcpy(combined,params,4*sizeof(params[0]));
        unsigned count=4;
        if (self.gl) combined[count++] = (mpv_render_param){MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,&glinit};
        NSString *renderer = option(@"--renderer",nil);
        if (renderer) combined[count++] = (mpv_render_param){MPV_RENDER_PARAM_RENDERER,(void *)renderer.UTF8String};
        combined[count] = (mpv_render_param){0};
#else
        mpv_render_param combined[7];
        memcpy(combined,params,4*sizeof(params[0]));
        unsigned count=4;
        if ([option(@"--fallback",@"none") isEqual:@"vulkan"]) {
            vk_target_create(&self->_vk); self.useVulkan=YES;
            combined[0].data=MPV_RENDER_API_TYPE_VULKAN;
            combined[count++]=(mpv_render_param){MPV_RENDER_PARAM_VULKAN_INIT_PARAMS,&self->_vk.init};
        }
        combined[count]=(mpv_render_param){0};
#endif
        int err = mpv_render_context_create(&self->_render, self.mpv,combined);
        printf("NATIVE_CREATE=%d API=%lu\n", err, mpv_client_api_version());
        if (err < 0) exit(1);
        const char *mode = NULL;
        if (mpv_render_context_get_info(self.render, (mpv_render_param){MPV_RENDER_PARAM_OUTPUT_MODE, &mode}) ||
            !mode) exit(1);
        mpv_render_context_set_update_callback(self.render, update, (__bridge void *)self);
        mpv_apple_native_target target = {.version = 1, .w = (int)self.pixels.width, .h = (int)self.pixels.height};
        mpv_render_param draw[] = {{MPV_RENDER_PARAM_APPLE_NATIVE_TARGET, &target}, {0}};
#if !TARGET_OS_IPHONE
        mpv_opengl_fbo fbo = {.fbo=(int)self.framebuffer,.w=512,.h=288};
        if (!strcmp(mode,"render")) draw[0] = (mpv_render_param){MPV_RENDER_PARAM_OPENGL_FBO,&fbo};
#else
        if (!strcmp(mode,"render")) {
            self->_vk.target.completion_value++;
            draw[0]=(mpv_render_param){MPV_RENDER_PARAM_VULKAN_TARGET,&self->_vk.target};
        }
#endif
        if (mpv_render_context_render(self.render, draw) < 0) exit(1);
#if TARGET_OS_IPHONE
        if (!strcmp(mode,"render")) {
            CGImageRef image=vk_target_read(&self->_vk); CGImageRelease(image);
        }
#endif
        if (target.osd) CGImageRelease(target.osd);
#if !TARGET_OS_IPHONE
        if (self.gl) [NSOpenGLContext clearCurrentContext];
#endif
    });
    const char *load[] = {"loadfile", self.file.UTF8String, NULL};
    if (mpv_command_async(self.mpv, 100, load) < 0) exit(1);
    self.started = NSProcessInfo.processInfo.systemUptime;
    [NSTimer scheduledTimerWithTimeInterval:self.lifecycle ? .1 : 1 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
}

#if TARGET_OS_IPHONE
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options
{ (void)application; (void)options; [self start]; return YES; }
- (void)applicationWillResignActive:(UIApplication *)application
{
    (void)application;
    if (atomic_load(&stopping)) return;
    if (self.seconds > 60 && self.firstProgressTime) {
        printf("NATIVE_LONG_INTERRUPTED=1\n"); [self finish:1]; return;
    }
    self.savedPaused = [self.properties[@"pause"] boolValue];
    self.suspended = YES;
    mpv_command_async(self.mpv, 900, (const char *[]){"set", "pause", "yes", NULL});
}
- (void)applicationDidEnterBackground:(UIApplication *)application
{
    (void)application;
    if (atomic_load(&stopping)) return;
    self.backgrounded = YES;
    self.backgroundStarted = NSProcessInfo.processInfo.systemUptime;
    self.backgroundPTS = [self.properties[@"time-pos"] doubleValue];
    mpv_command_async(self.mpv, 901, (const char *[]){"stop", NULL});
    printf("NATIVE_BACKGROUND=1 SAVED_PTS=%.3f\n", self.backgroundPTS);
}
- (void)applicationDidBecomeActive:(UIApplication *)application
{
    (void)application;
    if (atomic_load(&stopping)) return;
    self.suspended = NO;
    [self updateGeometry]; [self scheduleRender];
    if (self.backgrounded) {
        self.backgrounded = NO;
        self.started += NSProcessInfo.processInfo.systemUptime - self.backgroundStarted;
        self.resumePhase = 1;
        mpv_command_async(self.mpv, 902, (const char *[]){"loadfile", self.file.UTF8String, NULL});
    } else if (self.mpv) {
        mpv_command_async(self.mpv, 905, (const char *[]){"set", "pause", self.savedPaused ? "yes" : "no", NULL});
    }
}
#else
- (void)applicationDidFinishLaunching:(NSNotification *)notification
{ (void)notification; [self start]; }
- (BOOL)windowShouldClose:(NSWindow *)window
{ (void)window; [self finish:1]; return NO; }
- (void)windowDidResize:(NSNotification *)notification
{
    (void)notification;
    [self updateGeometry];
}
#endif
- (void)updateGeometry
{
    if (!self.window || !self.overlay) return;
#if TARGET_OS_IPHONE
    CGSize size = self.window.rootViewController.view.bounds.size;
    double scale = self.window.screen.scale;
#else
    CGSize size = self.window.contentView.bounds.size;
    double scale = self.window.backingScaleFactor;
#endif
    @synchronized (self) {
        self.scale = scale;
        self.pixels = CGSizeMake(size.width * scale, size.height * scale);
    }
    self.overlay.frame = CGRectMake(0, 0, size.width, size.height);
    [self scheduleRender];
}
@end

int main(int argc, char **argv)
{
#if TARGET_OS_IPHONE
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(NativeSmoke.class)); }
#else
    (void)argc; (void)argv;
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        NativeSmoke *delegate = [NativeSmoke new]; app.delegate = delegate;
        [app run]; return 1;
    }
#endif
}
