#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#define main metal_probe_main
#include "../smoke/test-metal-import.m"
#undef main

static const char *case_id = "standalone";

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options
{
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [UIViewController new];
    [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSString *bundle = NSBundle.mainBundle.bundlePath;
            if (setenv("VK_DRIVER_FILES", [[bundle stringByAppendingPathComponent:@"vulkan/icd.d/MoltenVK.json"] UTF8String], 1) ||
                setenv("VK_LAYER_PATH", [[bundle stringByAppendingPathComponent:@"vulkan/explicit_layer.d"] UTF8String], 1)) exit(2);
            Dl_info loader;
            if (!dladdr((void *)vkGetInstanceProcAddr, &loader)) exit(2);
            fprintf(stderr, "LOADER_PATH=%s MPV_HANDLE_CREATED=0\n", loader.dli_fname);
            int status = metal_probe_main();
            for (uint32_t i = 0; i < _dyld_image_count(); i++) {
                const char *name = _dyld_get_image_name(i);
                if (strstr(name, "vulkan.framework") || strstr(name, "khronos_validation") || strstr(name, "MoltenVK.framework"))
                    fprintf(stderr, "LOADED_LIBRARY=%s\n", name);
            }
            fprintf(stderr, "IOS_METAL_PROBE_EXIT=%d\n", status);
            if (!status) {
                fprintf(stderr, "IOS_RESULT=PASS MEDIA=metal-import CASE_ID=%s\n", case_id);
                fprintf(stderr, "IOS_CONTEXTS=1 PASS CASE_ID=%s\n", case_id);
            }
            fflush(NULL);
            exit(status);
        }
    });
    return YES;
}
@end
int main(int argc, char **argv)
{
    for (int i = 1; i < argc; i++)
        if (!strncmp(argv[i], "--case-id=", 10)) case_id = argv[i] + 10;
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class)); }
}
