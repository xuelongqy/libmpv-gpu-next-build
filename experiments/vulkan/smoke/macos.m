#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <SDL.h>
#include <SDL_metal.h>
#include <SDL_syswm.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <stdlib.h>

static CAMetalLayer *find_layer(NSView *view)
{
    if ([view.layer isKindOfClass:CAMetalLayer.class])
        return (CAMetalLayer *)view.layer;
    for (NSView *child in view.subviews) {
        CAMetalLayer *layer = find_layer(child);
        if (layer) return layer;
    }
    return nil;
}

static NSWindow *native_window(SDL_Window *window)
{
    SDL_SysWMinfo info = {0};
    SDL_VERSION(&info.version);
    if (!SDL_GetWindowWMInfo(window, &info) || info.subsystem != SDL_SYSWM_COCOA)
        return nil;
    return info.info.cocoa.window;
}

double smoke_macos_report(SDL_Window *window)
{
    @autoreleasepool {
        NSWindow *native = native_window(window);
        CAMetalLayer *layer = find_layer(native.contentView);
        CFStringRef name = layer.colorspace ? CGColorSpaceCopyName(layer.colorspace) : NULL;
        fprintf(stderr, "LAYER_FORMAT=%lu COLORSPACE=%s EDR_REQUESTED=%d EDR_METADATA=%d CURRENT=%.6f POTENTIAL=%.6f REFERENCE=%.6f\n",
            (unsigned long)layer.pixelFormat,
            name ? [(__bridge NSString *)name UTF8String] : "none",
            layer.wantsExtendedDynamicRangeContent, layer.EDRMetadata != nil,
            native.screen.maximumExtendedDynamicRangeColorComponentValue,
            native.screen.maximumPotentialExtendedDynamicRangeColorComponentValue,
            native.screen.maximumReferenceExtendedDynamicRangeColorComponentValue);
        if (name) CFRelease(name);
        if (@available(macOS 15.0, *))
            fprintf(stderr, "TONE_MAP_MODE=%s\n", layer.toneMapMode.UTF8String);
        if (@available(macOS 26.0, *))
            fprintf(stderr, "PREFERRED_DYNAMIC_RANGE=%s CONTENTS_HEADROOM=%.6f\n",
                layer.preferredDynamicRange.UTF8String, layer.contentsHeadroom);
        return native.screen.maximumExtendedDynamicRangeColorComponentValue;
    }
}

void smoke_macos_clear(SDL_Window *window)
{
    @autoreleasepool {
        CAMetalLayer *layer = find_layer(native_window(window).contentView);
        layer.EDRMetadata = nil;
        if (@available(macOS 15.0, *)) layer.toneMapMode = CAToneMapModeAutomatic;
    }
}

bool smoke_macos_output(SDL_Window *window, const char *output, double peak)
{
    @autoreleasepool {
        NSWindow *native = native_window(window);
        CAMetalLayer *layer = find_layer(native.contentView);
        if (!native || !layer) return false;
        layer.EDRMetadata = nil;
        if (@available(macOS 15.0, *)) layer.toneMapMode = CAToneMapModeAutomatic;
        bool hdr = strcmp(output, "sdr") != 0;
        if (hdr && native.screen.maximumPotentialExtendedDynamicRangeColorComponentValue <= 1)
            return false;
        if (hdr) {
            if (!CAEDRMetadata.available) return false;
            bool scrgb = !strcmp(output, "scrgb");
            int scale = scrgb ? 80 : 10000;
            // Equal metadata ranges do not prove equal system tone mapping.
            // scRGB 1.0 is 80 cd/m^2; normalized PQ uses the 10,000-nit scale.
            layer.EDRMetadata = [CAEDRMetadata HDR10MetadataWithMinLuminance:0
                maxLuminance:peak opticalOutputScale:scale];
            fprintf(stderr, "%s_OPTICAL_SCALE=%d OUTPUT_MAX_NITS=%g\n",
                scrgb ? "SCRGB" : "PQ", scale, peak);
        }
        CGDirectDisplayID display = [native.screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        CGColorSpaceRef profile = CGDisplayCopyColorSpace(display);
        CFStringRef profile_name = profile ? CGColorSpaceCopyName(profile) : NULL;
        fprintf(stderr, "DISPLAY_ID=%u DISPLAY_NAME=%s PROFILE=%s\n", display,
            native.screen.localizedName.UTF8String,
            profile_name ? [(__bridge NSString *)profile_name UTF8String] : "unknown");
        if (profile_name) CFRelease(profile_name);
        if (profile) CGColorSpaceRelease(profile);
        smoke_macos_report(window);
        return layer.wantsExtendedDynamicRangeContent == hdr;
    }
}
