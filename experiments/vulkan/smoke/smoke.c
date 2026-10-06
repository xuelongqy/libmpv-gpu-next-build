// Independent Vulkan Render API draft client; not an installed mpv example.
#define SDL_MAIN_HANDLED
#ifdef __ANDROID__
#include "android/platform.h"
#else
#include <SDL.h>
#include <SDL_vulkan.h>
#endif
#include <mpv/client.h>
#ifdef __APPLE__
#define VK_USE_PLATFORM_METAL_EXT
#endif
#include <mpv/render_vk.h>
#include <limits.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if MPV_CLIENT_API_VERSION < MPV_MAKE_VERSION(2, 7)
#error "The Vulkan client requires matching downstream client API 2.7 headers"
#endif

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #x); exit(1); } } while (0)
#define VK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { fprintf(stderr, "%s: VkResult %d\n", #x, r_); exit(1); } } while (0)

enum output_mode { OUTPUT_SDR, OUTPUT_PQ, OUTPUT_SCRGB };
static const char *const output_names[] = {"sdr", "pq", "scrgb"};
#ifdef _WIN32
bool smoke_windows_display(SDL_Window *window, bool hdr);
#endif
#ifdef __APPLE__
bool smoke_macos_output(SDL_Window *window, const char *output, double peak);
void smoke_macos_clear(SDL_Window *window);
double smoke_macos_report(SDL_Window *window);
#endif

struct app {
    SDL_Window *window;
    VkInstance instance;
    VkDebugUtilsMessengerEXT debug;
    VkPhysicalDevice physical;
    VkDevice device;
    VkQueue queue;
    uint32_t family;
    VkPhysicalDeviceVulkan11Features f11;
    VkPhysicalDeviceVulkan12Features f12;
    VkPhysicalDeviceSynchronization2Features sync2;
    VkPhysicalDeviceFeatures2 features;
    const char *extensions[4];
    int num_extensions;
    pthread_mutex_t mutex;
    VkSurfaceKHR surface;
    VkSwapchainKHR swapchain;
    VkDeviceMemory memory[8];
    mpv_vulkan_target targets[8];
    uint32_t num_targets, width, height;
    uint64_t generation, value;
    unsigned sequence;
    bool timeline;
    VkSemaphore acquire[3], complete[3], present[8];
    VkCommandPool pool;
    VkCommandBuffer commands[3];
    VkFence fences[3];
    VkBuffer readback;
    VkDeviceMemory readback_memory;
    void *pixels;
    mpv_handle *mpv;
    mpv_render_context *render;
    SDL_atomic_t dirty;
    uint64_t command_id, replied;
    uint64_t playback_restarts;
    int command_error;
    bool loaded;
    bool configured;
    double pts;
    int flip;
    int display;
    bool fullscreen;
    const char *start;
    enum output_mode output;
    const char *peak;
    const char *vf;
    const char *gamut;
    const char *hwdec, *audio_device, *volume;
    int play_seconds, result;
    bool hw_seen, audio_seen, ended;
    double audio_pts, avsync;
    uint64_t audio_progress;
    bool cycle_output;
    bool force_bgr10;
    bool pattern, compare_hdr, quit, toggle_hdr;
    double headroom;
    unsigned stable_samples;
};

static const char *output_peak(struct app *a)
{
    return a->peak ? a->peak : a->output == OUTPUT_SDR ? "100" : "500";
}

static void unsupported(const char *reason)
{
    fprintf(stderr, "RESULT=UNSUPPORTED REASON=%s\n", reason);
    exit(77);
}

static atomic_int validation_errors;
static atomic_int fail_submit;
static atomic_bool simulated_loss;
static PFN_vkGetDeviceProcAddr real_device_proc;
static PFN_vkQueueSubmit real_submit;
static PFN_vkQueueSubmit2 real_submit2;
static PFN_vkWaitForFences real_wait_fences;
static PFN_vkWaitSemaphores real_wait_semaphores;
static PFN_vkGetFenceStatus real_fence_status;

static bool fail_now(void)
{
    if (atomic_exchange(&fail_submit,0)) atomic_store(&simulated_loss,true);
    return atomic_load(&simulated_loss);
}

static VKAPI_ATTR VkResult VKAPI_CALL submit_hook(VkQueue queue, uint32_t count,
    const VkSubmitInfo *info, VkFence fence)
{
    if (fail_now()) return VK_ERROR_DEVICE_LOST;
    return real_submit(queue,count,info,fence);
}

static VKAPI_ATTR VkResult VKAPI_CALL submit2_hook(VkQueue queue, uint32_t count,
    const VkSubmitInfo2 *info, VkFence fence)
{
    if (fail_now()) return VK_ERROR_DEVICE_LOST;
    return real_submit2(queue,count,info,fence);
}

static VKAPI_ATTR VkResult VKAPI_CALL wait_fences_hook(VkDevice device, uint32_t count,
    const VkFence *fences, VkBool32 all, uint64_t timeout)
{
    if (atomic_load(&simulated_loss)) return VK_ERROR_DEVICE_LOST;
    return real_wait_fences(device,count,fences,all,timeout);
}

static VKAPI_ATTR VkResult VKAPI_CALL wait_semaphores_hook(VkDevice device,
    const VkSemaphoreWaitInfo *info, uint64_t timeout)
{
    if (atomic_load(&simulated_loss)) return VK_ERROR_DEVICE_LOST;
    return real_wait_semaphores(device,info,timeout);
}

static VKAPI_ATTR VkResult VKAPI_CALL fence_status_hook(VkDevice device, VkFence fence)
{
    if (atomic_load(&simulated_loss)) return VK_ERROR_DEVICE_LOST;
    return real_fence_status(device,fence);
}

static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL device_proc(VkDevice device, const char *name)
{
    PFN_vkVoidFunction fn = real_device_proc(device,name);
    if (!strcmp(name,"vkQueueSubmit") && fn) {
        real_submit = (void *)fn; return (void *)submit_hook;
    }
    if ((!strcmp(name,"vkQueueSubmit2") || !strcmp(name,"vkQueueSubmit2KHR")) && fn) {
        real_submit2 = (void *)fn; return (void *)submit2_hook;
    }
    if (!strcmp(name,"vkWaitForFences")) {
        real_wait_fences = (void *)fn; return (void *)wait_fences_hook;
    }
    if (!strcmp(name,"vkWaitSemaphores") || !strcmp(name,"vkWaitSemaphoresKHR")) {
        real_wait_semaphores = (void *)fn; return (void *)wait_semaphores_hook;
    }
    if (!strcmp(name,"vkGetFenceStatus")) {
        real_fence_status = (void *)fn; return (void *)fence_status_hook;
    }
    return fn;
}

static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL instance_proc(VkInstance instance, const char *name)
{
    if (!strcmp(name,"vkGetDeviceProcAddr")) {
        real_device_proc = (void *)vkGetInstanceProcAddr(instance,name);
        return (void *)device_proc;
    }
    return vkGetInstanceProcAddr(instance,name);
}

static VKAPI_ATTR VkBool32 VKAPI_CALL message(
    VkDebugUtilsMessageSeverityFlagBitsEXT severity,
    VkDebugUtilsMessageTypeFlagsEXT type,
    const VkDebugUtilsMessengerCallbackDataEXT *data, void *opaque)
{
    (void)type; (void)opaque;
    if (severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT)
        atomic_fetch_add(&validation_errors, 1);
    fprintf(stderr, "VALIDATION: %s\n", data->pMessage);
    return VK_FALSE;
}

static void lock(void *opaque, uint32_t family, uint32_t index)
{
    struct app *a = opaque;
    CHECK(family == a->family && index == 0);
    pthread_mutex_lock(&a->mutex);
}

static void unlock(void *opaque, uint32_t family, uint32_t index)
{
    (void)family; (void)index;
    pthread_mutex_unlock(&((struct app *)opaque)->mutex);
}

static uint32_t memory_type(struct app *a, uint32_t bits, VkMemoryPropertyFlags flags)
{
    VkPhysicalDeviceMemoryProperties m;
    vkGetPhysicalDeviceMemoryProperties(a->physical, &m);
    for (uint32_t i = 0; i < m.memoryTypeCount; i++)
        if ((bits & (1u << i)) && (m.memoryTypes[i].propertyFlags & flags) == flags)
            return i;
    CHECK(false);
    return 0;
}

static void init_vulkan(struct app *a, bool window)
{
    pthread_mutex_init(&a->mutex, NULL);
#ifdef _WIN32
    CHECK(SDL_SetHint(SDL_HINT_WINDOWS_DPI_AWARENESS, "permonitorv2"));
#endif
    CHECK(SDL_Init(SDL_INIT_VIDEO | SDL_INIT_TIMER) == 0);
    if (window) {
        int x = 60, y = 80;
#ifdef _WIN32
        int displays = SDL_GetNumVideoDisplays();
        CHECK(displays > 0 && a->display < displays);
        for (int i = 0; i < displays; i++) {
            SDL_Rect bounds;
            CHECK(SDL_GetDisplayBounds(i, &bounds) == 0);
            fprintf(stderr, "SDL_DISPLAY=%d NAME=%s BOUNDS=%d,%d,%d,%d\n", i,
                SDL_GetDisplayName(i), bounds.x, bounds.y, bounds.w, bounds.h);
        }
        if (a->display >= 0) x = y = SDL_WINDOWPOS_CENTERED_DISPLAY(a->display);
#endif
        a->window = SDL_CreateWindow("libmpv gpu-next Vulkan / SDR", x, y,
            a->width, a->height, SDL_WINDOW_VULKAN | SDL_WINDOW_RESIZABLE |
            (a->fullscreen ? SDL_WINDOW_FULLSCREEN_DESKTOP | SDL_WINDOW_ALLOW_HIGHDPI : 0));
        CHECK(a->window);
#ifdef _WIN32
        int actual_display = SDL_GetWindowDisplayIndex(a->window);
        fprintf(stderr, "WINDOW_DISPLAY=%d REQUESTED_DISPLAY=%d\n", actual_display, a->display);
        CHECK(a->display < 0 || actual_display == a->display);
#endif
    }
    const char *extensions[16] = {0};
    unsigned count = 0;
    if (window) {
        CHECK(SDL_Vulkan_GetInstanceExtensions(a->window, &count, NULL));
        CHECK(count < 12);
        CHECK(SDL_Vulkan_GetInstanceExtensions(a->window, &count, extensions));
    }
    extensions[count++] = VK_EXT_DEBUG_UTILS_EXTENSION_NAME;
    extensions[count++] = VK_EXT_VALIDATION_FEATURES_EXTENSION_NAME;
    uint32_t instance_count = 0;
    VK(vkEnumerateInstanceExtensionProperties(NULL, &instance_count, NULL));
    VkExtensionProperties *instance_exts = calloc(instance_count, sizeof(*instance_exts));
    VK(vkEnumerateInstanceExtensionProperties(NULL, &instance_count, instance_exts));
    bool colorspace = false;
    for (uint32_t i = 0; i < instance_count; i++)
        colorspace |= !strcmp(instance_exts[i].extensionName, VK_EXT_SWAPCHAIN_COLOR_SPACE_EXTENSION_NAME);
    free(instance_exts);
    if (window && colorspace)
        extensions[count++] = VK_EXT_SWAPCHAIN_COLOR_SPACE_EXTENSION_NAME;
    else if (window && (a->output != OUTPUT_SDR || a->cycle_output))
        unsupported("VK_EXT_swapchain_colorspace unavailable");
#ifdef __APPLE__
    extensions[count++] = VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME;
#endif
    const char *layer = "VK_LAYER_KHRONOS_validation";
    VkValidationFeatureEnableEXT sync = VK_VALIDATION_FEATURE_ENABLE_SYNCHRONIZATION_VALIDATION_EXT;
    VkValidationFeaturesEXT validation = {
        .sType = VK_STRUCTURE_TYPE_VALIDATION_FEATURES_EXT,
        .enabledValidationFeatureCount = 1, .pEnabledValidationFeatures = &sync,
    };
    VkDebugUtilsMessengerCreateInfoEXT debug = {
        .sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        .pNext = &validation,
        .messageSeverity = VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                           VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
        .messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                       VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                       VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
        .pfnUserCallback = message,
    };
    VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "libmpv Vulkan smoke", .apiVersion = VK_API_VERSION_1_2};
    VkInstanceCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pNext = &debug,
#ifdef __APPLE__
        .flags = VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR,
#endif
        .pApplicationInfo = &app, .enabledLayerCount = 1, .ppEnabledLayerNames = &layer,
        .enabledExtensionCount = count, .ppEnabledExtensionNames = extensions};
#ifdef __APPLE__
    VkExportMetalObjectCreateInfoEXT metal_export = {
        .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECT_CREATE_INFO_EXT,
        .pNext = ci.pNext,
        .exportObjectType = VK_EXPORT_METAL_OBJECT_TYPE_METAL_DEVICE_BIT_EXT,
    };
    if (!strcmp(a->hwdec, "videotoolbox"))
        ci.pNext = &metal_export;
#endif
    VK(vkCreateInstance(&ci, NULL, &a->instance));
    debug.pNext = NULL;
    PFN_vkCreateDebugUtilsMessengerEXT create_debug = (void *)vkGetInstanceProcAddr(
        a->instance, "vkCreateDebugUtilsMessengerEXT");
    CHECK(create_debug);
    VK(create_debug(a->instance, &debug, NULL, &a->debug));
    if (window)
        CHECK(SDL_Vulkan_CreateSurface(a->window, a->instance, &a->surface));
    uint32_t num = 0;
    VK(vkEnumeratePhysicalDevices(a->instance, &num, NULL));
    CHECK(num);
    VkPhysicalDevice *devices = calloc(num, sizeof(*devices));
    VK(vkEnumeratePhysicalDevices(a->instance, &num, devices));
    a->physical = devices[0];
    free(devices);
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(a->physical, &props);
    fprintf(stderr, "DEVICE=%s API=%u.%u.%u DRIVER=%u VALIDATION=sync\n",
        props.deviceName, VK_API_VERSION_MAJOR(props.apiVersion),
        VK_API_VERSION_MINOR(props.apiVersion), VK_API_VERSION_PATCH(props.apiVersion),
        props.driverVersion);
    vkGetPhysicalDeviceQueueFamilyProperties(a->physical, &num, NULL);
    VkQueueFamilyProperties *queues = calloc(num, sizeof(*queues));
    vkGetPhysicalDeviceQueueFamilyProperties(a->physical, &num, queues);
    a->family = UINT32_MAX;
    VkQueueFlags required = VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT;
    for (uint32_t i = 0; i < num; i++) {
        VkBool32 present = VK_TRUE;
        if (window) VK(vkGetPhysicalDeviceSurfaceSupportKHR(a->physical, i, a->surface, &present));
        if ((queues[i].queueFlags & required) == required && present) {
            a->family = i; break;
        }
    }
    free(queues);
    CHECK(a->family != UINT32_MAX);
    a->sync2 = (VkPhysicalDeviceSynchronization2Features){.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES};
    a->f12 = (VkPhysicalDeviceVulkan12Features){.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, .pNext = &a->sync2};
    a->f11 = (VkPhysicalDeviceVulkan11Features){.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, .pNext = &a->f12};
    a->features = (VkPhysicalDeviceFeatures2){.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &a->f11};
    vkGetPhysicalDeviceFeatures2(a->physical, &a->features);
    CHECK(a->f12.timelineSemaphore && a->f12.hostQueryReset);
    CHECK(a->sync2.synchronization2);
    a->extensions[a->num_extensions++] = VK_KHR_SYNCHRONIZATION_2_EXTENSION_NAME;
    VK(vkEnumerateDeviceExtensionProperties(a->physical, NULL, &num, NULL));
    VkExtensionProperties *ext = calloc(num, sizeof(*ext));
    VK(vkEnumerateDeviceExtensionProperties(a->physical, NULL, &num, ext));
    for (uint32_t i = 0; i < num; i++) {
        if (!strcmp(ext[i].extensionName, "VK_KHR_portability_subset"))
            a->extensions[a->num_extensions++] = "VK_KHR_portability_subset";
#ifdef __APPLE__
        if (!strcmp(a->hwdec, "videotoolbox") &&
            !strcmp(ext[i].extensionName, VK_EXT_METAL_OBJECTS_EXTENSION_NAME))
            a->extensions[a->num_extensions++] = VK_EXT_METAL_OBJECTS_EXTENSION_NAME;
#endif
    }
    free(ext);
#ifdef __APPLE__
    if (!strcmp(a->hwdec, "videotoolbox")) {
        bool metal = false;
        for (int i = 0; i < a->num_extensions; i++)
            metal |= !strcmp(a->extensions[i], VK_EXT_METAL_OBJECTS_EXTENSION_NAME);
        if (!metal) unsupported("VideoToolbox direct mapping requires VK_EXT_metal_objects");
    }
#endif
    if (window) a->extensions[a->num_extensions++] = VK_KHR_SWAPCHAIN_EXTENSION_NAME;
    float priority = 1;
    VkDeviceQueueCreateInfo q = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = a->family, .queueCount = 1, .pQueuePriorities = &priority};
    VkDeviceCreateInfo dc = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = &a->features, .queueCreateInfoCount = 1, .pQueueCreateInfos = &q,
        .enabledExtensionCount = a->num_extensions, .ppEnabledExtensionNames = a->extensions};
    VK(vkCreateDevice(a->physical, &dc, NULL, &a->device));
    vkGetDeviceQueue(a->device, a->family, 0, &a->queue);
    VkCommandPoolCreateInfo pc = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = a->family};
    VK(vkCreateCommandPool(a->device, &pc, NULL, &a->pool));
    VkCommandBufferAllocateInfo ca = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = a->pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 3};
    VK(vkAllocateCommandBuffers(a->device, &ca, a->commands));
    for (int i = 0; i < 3; i++) {
        VkSemaphoreTypeCreateInfo type = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO,
            .semaphoreType = a->timeline ? VK_SEMAPHORE_TYPE_TIMELINE : VK_SEMAPHORE_TYPE_BINARY};
        VkSemaphoreCreateInfo sc = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, .pNext = &type};
        VK(vkCreateSemaphore(a->device, &sc, NULL, &a->acquire[i]));
        VK(vkCreateSemaphore(a->device, &sc, NULL, &a->complete[i]));
        VkFenceCreateInfo fc = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, .flags = VK_FENCE_CREATE_SIGNALED_BIT};
        VK(vkCreateFence(a->device, &fc, NULL, &a->fences[i]));
    }
    for (int i = 0; i < 8; i++) {
        VkSemaphoreCreateInfo sc = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
        VK(vkCreateSemaphore(a->device, &sc, NULL, &a->present[i]));
    }
}

static void drop_targets(struct app *a)
{
    // Retirement/resize, never the steady-state rendering path.
    if (a->device) VK(vkDeviceWaitIdle(a->device));
#ifdef __APPLE__
    if (a->window && a->num_targets)
        smoke_macos_clear(a->window);
#endif
    for (uint32_t i = 0; i < a->num_targets; i++) {
        if (a->render && a->targets[i].state == MPV_VULKAN_TARGET_RETURNED) {
            mpv_vulkan_retire_target retire = {.version = MPV_VULKAN_DRAFT_VERSION,
                .image = a->targets[i].image, .generation = a->targets[i].generation};
            CHECK(mpv_render_context_set_parameter(a->render,
                (mpv_render_param){MPV_RENDER_PARAM_VULKAN_RETIRE_TARGET, &retire}) == 0);
        }
        if (!a->swapchain) {
            vkDestroyImage(a->device, a->targets[i].image, NULL);
            vkFreeMemory(a->device, a->memory[i], NULL);
        }
    }
    a->num_targets = 0;
    if (a->swapchain) vkDestroySwapchainKHR(a->device, a->swapchain, NULL);
    a->swapchain = VK_NULL_HANDLE;
    if (a->pixels) vkUnmapMemory(a->device, a->readback_memory);
    if (a->readback) vkDestroyBuffer(a->device, a->readback, NULL);
    if (a->readback_memory) vkFreeMemory(a->device, a->readback_memory, NULL);
    a->pixels = NULL; a->readback = VK_NULL_HANDLE; a->readback_memory = VK_NULL_HANDLE;
}

static void make_targets(struct app *a, uint32_t width, uint32_t height)
{
    drop_targets(a);
    VkFormat preferred[] = {VK_FORMAT_R8G8B8A8_UNORM, VK_FORMAT_B8G8R8A8_UNORM};
    VkColorSpaceKHR space = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;
    if (a->output == OUTPUT_PQ) {
        preferred[0] = a->force_bgr10 ? VK_FORMAT_A2R10G10B10_UNORM_PACK32 : VK_FORMAT_A2B10G10R10_UNORM_PACK32;
        preferred[1] = VK_FORMAT_A2R10G10B10_UNORM_PACK32;
        space = VK_COLOR_SPACE_HDR10_ST2084_EXT;
    } else if (a->output == OUTPUT_SCRGB) {
        preferred[0] = preferred[1] = VK_FORMAT_R16G16B16A16_SFLOAT;
        space = VK_COLOR_SPACE_EXTENDED_SRGB_LINEAR_EXT;
    }
    VkFormat format = preferred[0];
    VkImage images[8];
    VkImageUsageFlags usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
        VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    a->num_targets = 3;
    if (a->window) {
#ifdef _WIN32
        if (!smoke_windows_display(a->window, a->output != OUTPUT_SDR || a->cycle_output))
            unsupported("Windows target display HDR unavailable or not enabled");
#endif
        VkSurfaceCapabilitiesKHR caps;
        VK(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(a->physical, a->surface, &caps));
        if ((caps.supportedUsageFlags & usage) != usage)
            unsupported("surface lacks required image usage");
        uint32_t count = 0;
        VK(vkGetPhysicalDeviceSurfaceFormatsKHR(a->physical, a->surface, &count, NULL));
        VkSurfaceFormatKHR *formats = calloc(count, sizeof(*formats));
        VK(vkGetPhysicalDeviceSurfaceFormatsKHR(a->physical, a->surface, &count, formats));
        bool found = false;
        for (unsigned choice = 0; choice < 2 && !found; choice++) {
            for (uint32_t i = 0; i < count; i++) {
                fprintf(stderr, "SURFACE_FORMAT=%d COLORSPACE=%d\n", formats[i].format, formats[i].colorSpace);
                if (formats[i].format == preferred[choice] && formats[i].colorSpace == space) {
                    format = formats[i].format; found = true; break;
                }
            }
        }
        free(formats);
        if (!found) unsupported("requested format/colorspace pair unavailable");
        int window_w, window_h, drawable_w, drawable_h;
        SDL_GetWindowSize(a->window, &window_w, &window_h);
        SDL_Vulkan_GetDrawableSize(a->window, &drawable_w, &drawable_h);
        CHECK(drawable_w > 0 && drawable_h > 0);
        fprintf(stderr, "WINDOW_SIZE=%dx%d DRAWABLE_SIZE=%dx%d FULLSCREEN=%d\n",
                window_w, window_h, drawable_w, drawable_h, a->fullscreen);
        if (caps.currentExtent.width != UINT32_MAX) {
            width = caps.currentExtent.width; height = caps.currentExtent.height;
        } else {
            width = drawable_w; height = drawable_h;
        }
        CHECK(!a->fullscreen || (width == (uint32_t)drawable_w && height == (uint32_t)drawable_h));
        uint32_t images_requested = caps.minImageCount > 3 ? caps.minImageCount : 3;
        if (caps.maxImageCount && images_requested > caps.maxImageCount) images_requested = caps.maxImageCount;
        const VkCompositeAlphaFlagBitsKHR alpha_modes[] = {
            VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR, VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR,
            VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR, VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR,
        };
        VkCompositeAlphaFlagBitsKHR alpha = 0;
        for (unsigned i = 0; i < sizeof(alpha_modes)/sizeof(alpha_modes[0]); i++) {
            if (caps.supportedCompositeAlpha & alpha_modes[i]) {
                alpha = alpha_modes[i]; break;
            }
        }
        CHECK(alpha);
        VkSwapchainCreateInfoKHR sc = {.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .surface = a->surface, .minImageCount = images_requested,
            .imageFormat = format, .imageColorSpace = space,
            .imageExtent = {width, height}, .imageArrayLayers = 1, .imageUsage = usage,
            .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE, .preTransform = caps.currentTransform,
            .compositeAlpha = alpha, .presentMode = VK_PRESENT_MODE_FIFO_KHR,
            .clipped = VK_TRUE};
        VK(vkCreateSwapchainKHR(a->device, &sc, NULL, &a->swapchain));
        VK(vkGetSwapchainImagesKHR(a->device, a->swapchain, &a->num_targets, NULL));
        CHECK(a->num_targets <= 8);
        VK(vkGetSwapchainImagesKHR(a->device, a->swapchain, &a->num_targets, images));
#ifdef __APPLE__
        if (!smoke_macos_output(a->window, output_names[a->output], strtod(output_peak(a), NULL)))
            unsupported("requested macOS HDR layer unavailable");
#endif
    } else {
        VkImageFormatProperties props;
        VkResult supported = vkGetPhysicalDeviceImageFormatProperties(a->physical, format,
            VK_IMAGE_TYPE_2D, VK_IMAGE_TILING_OPTIMAL, usage, 0, &props);
        if (supported == VK_ERROR_FORMAT_NOT_SUPPORTED)
            unsupported("offscreen image format/usage unavailable");
        VK(supported);
        for (uint32_t i = 0; i < a->num_targets; i++) {
            VkImageCreateInfo ic = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
                .imageType = VK_IMAGE_TYPE_2D, .format = format, .extent = {width, height, 1},
                .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT,
                .tiling = VK_IMAGE_TILING_OPTIMAL, .usage = usage, .sharingMode = VK_SHARING_MODE_EXCLUSIVE};
            VK(vkCreateImage(a->device, &ic, NULL, &images[i]));
            VkMemoryRequirements mr; vkGetImageMemoryRequirements(a->device, images[i], &mr);
            VkMemoryAllocateInfo ma = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                .allocationSize = mr.size, .memoryTypeIndex = memory_type(a, mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)};
            VK(vkAllocateMemory(a->device, &ma, NULL, &a->memory[i]));
            VK(vkBindImageMemory(a->device, images[i], a->memory[i], 0));
        }
    }
    a->width = width; a->height = height; a->generation++;
    for (uint32_t i = 0; i < a->num_targets; i++) {
        a->targets[i] = (mpv_vulkan_target){.version = MPV_VULKAN_DRAFT_VERSION,
            .image = images[i], .generation = a->generation, .format = format,
            .width = width, .height = height, .usage = usage,
            .input_layout = VK_IMAGE_LAYOUT_UNDEFINED};
    }
    VkBufferCreateInfo bc = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = (VkDeviceSize)width * height * (format == VK_FORMAT_R16G16B16A16_SFLOAT ? 8 : 4),
        .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT |
                 (a->pattern ? VK_BUFFER_USAGE_TRANSFER_SRC_BIT : 0)};
    VK(vkCreateBuffer(a->device, &bc, NULL, &a->readback));
    VkMemoryRequirements mr; vkGetBufferMemoryRequirements(a->device, a->readback, &mr);
    VkMemoryAllocateInfo ma = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = mr.size, .memoryTypeIndex = memory_type(a, mr.memoryTypeBits,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)};
    VK(vkAllocateMemory(a->device, &ma, NULL, &a->readback_memory));
    VK(vkBindBufferMemory(a->device, a->readback, a->readback_memory, 0));
    VK(vkMapMemory(a->device, a->readback_memory, 0, VK_WHOLE_SIZE, 0, &a->pixels));
    a->stable_samples = 0;
    fprintf(stderr, "TARGETS=%u SIZE=%ux%u FORMAT=%d GENERATION=%llu\n", a->num_targets,
        width, height, format, (unsigned long long)a->generation);
    fprintf(stderr, "OUTPUT=%s COLORSPACE=%d TARGET_PEAK=%s\n", output_names[a->output], space, output_peak(a));
#ifndef __ANDROID__
    if (a->window) {
        char title[96];
        snprintf(title, sizeof(title), "libmpv Vulkan / %ux%u / %s / target %s nits",
                 width, height, output_names[a->output], output_peak(a));
        SDL_SetWindowTitle(a->window, title);
    }
#endif
}

static void wakeup(void *opaque) { SDL_AtomicSet(opaque, 1); }

static mpv_vulkan_init_params init_params(struct app *a)
{
    return (mpv_vulkan_init_params){.version = MPV_VULKAN_DRAFT_VERSION,
        .instance_api_version = VK_API_VERSION_1_2, .instance = a->instance,
        .physical_device = a->physical, .device = a->device,
        .get_proc_address = instance_proc, .features = &a->features,
        .extensions = a->extensions, .num_extensions = a->num_extensions,
        .queue_family = a->family, .lock_queue = lock, .unlock_queue = unlock, .queue_context = a};
}

static void create_mpv(struct app *a)
{
    a->mpv = mpv_create(); CHECK(a->mpv);
#ifdef __APPLE__
    if (!strcmp(a->hwdec, "videotoolbox"))
        CHECK(mpv_set_option_string(a->mpv, "gpu-hwdec-interop", "videotoolbox") == 0);
#endif
    const char *opts[][2] = {
        {"config", "no"}, {"vo", "libmpv"}, {"hwdec", a->hwdec},
        {"audio", a->play_seconds ? "auto" : "no"},
        {"pause", "yes"}, {"keep-open", "yes"}, {"idle", "yes"},
        {"target-prim", a->output == OUTPUT_PQ ? "bt.2020" : "bt.709"},
        {"target-trc", a->output == OUTPUT_PQ ? "pq" : a->output == OUTPUT_SCRGB ? "scrgb" : "srgb"},
        {"target-peak", output_peak(a)},
        {"treat-srgb-as-power22", "no"},
        {"icc-profile-auto", "no"}, {"hdr-compute-peak", "no"}, {"interpolation", "no"},
        {"temporal-dither", "no"}, {"dither-depth", a->output == OUTPUT_SCRGB ? "no" : "auto"},
        {"video-timing-offset", a->play_seconds ? "0.050" : "0"},
        {"osd-level", "0"}, {"sub", "no"}, {"screenshot-sw", "no"},
        {"background", "color"}, {"background-color", "#000000"},
        {"border-background", "color"},
        {"screenshot-high-bit-depth", a->output == OUTPUT_SDR ? "no" : "yes"},
        {"video-sync", a->play_seconds ? "audio" : "desync"}, {"start", a->start},
    };
    for (unsigned i = 0; i < sizeof(opts)/sizeof(opts[0]); i++)
        CHECK(mpv_set_option_string(a->mpv, opts[i][0], opts[i][1]) == 0);
    if (a->vf) CHECK(mpv_set_option_string(a->mpv, "vf", a->vf) == 0);
    if (a->gamut) CHECK(mpv_set_option_string(a->mpv, "target-gamut", a->gamut) == 0);
    if (a->play_seconds) {
        CHECK(mpv_set_option_string(a->mpv, "audio-device", a->audio_device) == 0);
        CHECK(mpv_set_option_string(a->mpv, "audio-channels", "stereo") == 0);
        CHECK(mpv_set_option_string(a->mpv, "audio-spdif", "") == 0);
        CHECK(mpv_set_option_string(a->mpv, "audio-fallback-to-null", "no") == 0);
        CHECK(mpv_set_option_string(a->mpv, "volume", a->volume ? a->volume : "20") == 0);
    }
    CHECK(mpv_initialize(a->mpv) == 0);
    CHECK(mpv_observe_property(a->mpv, 1, "time-pos", MPV_FORMAT_DOUBLE) == 0);
    CHECK(mpv_observe_property(a->mpv, 2, "vo-configured", MPV_FORMAT_FLAG) == 0);
    CHECK(mpv_request_log_messages(a->mpv, "v") == 0);
    mpv_vulkan_init_params init = init_params(a);
    int advanced = 1;
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_VULKAN},
        {MPV_RENDER_PARAM_RENDERER, "gpu-next"},
        {MPV_RENDER_PARAM_VULKAN_INIT_PARAMS, &init},
        {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced}, {0}};
    CHECK(mpv_render_context_create(&a->render, a->mpv, params) == 0);
    mpv_render_context_set_update_callback(a->render, wakeup, &a->dirty);
    a->loaded = false;
    a->configured = false;
    a->pts = -1;
    a->hw_seen = a->audio_seen = a->ended = false;
    a->audio_pts = a->avsync = NAN;
}

static void metrics(struct app *a)
{
    static const char *const names[] = {
        "hwdec-current", "video-dec-params", "video-params", "time-pos",
        "current-ao", "audio-device", "audio-out-params", "volume", "mute", "audio-pts", "avsync",
        "total-avsync-change", "decoder-frame-drop-count", "frame-drop-count",
    };
    for (unsigned i = 0; i < sizeof(names) / sizeof(names[0]); i++)
        CHECK(mpv_get_property_async(a->mpv, 100, names[i], MPV_FORMAT_STRING) == 0);
}

static void playback_error(struct app *a, int result, const char *reason)
{
    if (!a->result) {
        a->result = result;
        fprintf(stderr, "PLAYBACK_ERROR=%s CODE=%d\n", reason, result);
    }
}

static void pump(struct app *a)
{
    SDL_PumpEvents();
#ifndef __ANDROID__
    SDL_Event event;
    while (SDL_PollEvent(&event)) {
        if (event.type == SDL_QUIT ||
            (event.type == SDL_WINDOWEVENT && event.window.event == SDL_WINDOWEVENT_CLOSE) ||
            (event.type == SDL_KEYDOWN && event.key.keysym.sym == SDLK_ESCAPE))
            a->quit = true;
        if (a->compare_hdr && event.type == SDL_MOUSEBUTTONUP &&
            event.button.button == SDL_BUTTON_RIGHT)
            a->toggle_hdr = true;
        if (event.type != SDL_KEYDOWN || event.key.repeat || !a->compare_hdr) continue;
        if (event.key.keysym.sym == SDLK_SPACE) a->toggle_hdr = true;
    }
#endif
    if (!a->render) return;
    mpv_render_context_update(a->render);
    for (;;) {
        mpv_event *e = mpv_wait_event(a->mpv, 0);
        if (!e || e->event_id == MPV_EVENT_NONE) break;
        if (e->event_id == MPV_EVENT_LOG_MESSAGE) {
            mpv_event_log_message *m = e->data;
            fprintf(stderr, "[%s/%s] %s", m->prefix, m->level, m->text);
        } else if (e->event_id == MPV_EVENT_COMMAND_REPLY) {
            a->replied = e->reply_userdata; a->command_error = e->error;
        } else if (e->event_id == MPV_EVENT_FILE_LOADED) {
            a->loaded = true;
            a->ended = false;
        } else if (e->event_id == MPV_EVENT_PLAYBACK_RESTART) {
            a->playback_restarts++;
        } else if (e->event_id == MPV_EVENT_END_FILE) {
            a->loaded = false;
            a->ended = true;
            mpv_event_end_file *end = e->data;
            if (end->reason == MPV_END_FILE_REASON_ERROR)
                playback_error(a, 1, mpv_error_string(end->error));
        } else if (e->event_id == MPV_EVENT_GET_PROPERTY_REPLY) {
            mpv_event_property *p = e->data;
            const char *value = !e->error && p->data ? *(char **)p->data : NULL;
            fprintf(stderr, "METRIC t_ms=%llu name=%s value=%s\n",
                (unsigned long long)SDL_GetTicks64(), p->name, value ? value : "unavailable");
            if (!strcmp(p->name, "hwdec-current") && value) {
                if (strcmp(value, a->hwdec))
                    playback_error(a, a->hw_seen ? 1 : 77, "requested decoder not active");
                a->hw_seen = true;
            }
            if (!strcmp(p->name, "current-ao") && value && a->play_seconds) {
                if (!strcmp(value, "null")) playback_error(a, 1, "null audio output");
                a->audio_seen = true;
            }
            if (!strcmp(p->name, "audio-pts") && value) {
                double pts = strtod(value, NULL);
                if (isfinite(pts) && (!isfinite(a->audio_pts) || pts > a->audio_pts))
                    a->audio_progress = SDL_GetTicks64();
                a->audio_pts = pts;
            }
            if (!strcmp(p->name, "avsync")) a->avsync = value ? strtod(value, NULL) : NAN;
        } else if (e->event_id == MPV_EVENT_PROPERTY_CHANGE) {
            mpv_event_property *p = e->data;
            if (e->reply_userdata == 1)
                a->pts = p->data ? *(double *)p->data : -1;
            if (e->reply_userdata == 2)
                a->configured = p->data && *(int *)p->data;
        }
    }
}

static void command(struct app *a, const char **cmd, bool video)
{
    uint64_t id = ++a->command_id;
    if (!strcmp(cmd[0], "loadfile")) {
        a->loaded = a->hw_seen = false;
    }
    CHECK(mpv_command_async(a->mpv, id, cmd) == 0);
    uint64_t deadline = SDL_GetTicks64() + 15000;
    for (;;) {
        pump(a);
        bool ready = a->replied == id;
        if (ready) CHECK(a->command_error == 0);
        if (ready && video) {
            mpv_render_frame_info info = {0};
            CHECK(mpv_render_context_get_info(a->render,
                (mpv_render_param){MPV_RENDER_PARAM_NEXT_FRAME_INFO, &info}) == 0);
            ready = a->loaded && (info.flags & MPV_RENDER_FRAME_INFO_PRESENT) &&
                !(info.flags & MPV_RENDER_FRAME_INFO_REDRAW);
        }
        if (ready && !strcmp(cmd[0], "stop")) {
            ready = !a->loaded && !a->configured;
        }
        if (ready) break;
        CHECK(SDL_GetTicks64() < deadline);
        SDL_Delay(1);
    }
}

static float half_float(uint16_t bits)
{
    int exponent = (bits >> 10) & 31;
    int mantissa = bits & 1023;
    float value = exponent == 31 ? (mantissa ? NAN : INFINITY) :
        exponent ? ldexpf(1024 + mantissa, exponent - 25) : ldexpf(mantissa, -24);
    return bits & 32768 ? -value : value;
}

static void pixels(struct app *a, VkFormat format, int expected, const char *file)
{
    const unsigned char *data = a->pixels;
    bool sdr = format == VK_FORMAT_R8G8B8A8_UNORM || format == VK_FORMAT_B8G8R8A8_UNORM;
    bool fp16 = format == VK_FORMAT_R16G16B16A16_SFLOAT;
    float low[3] = {INFINITY,INFINITY,INFINITY}, high[3] = {-INFINITY,-INFINITY,-INFINITY};
    size_t length = (size_t)a->width * a->height;
    FILE *f = file ? fopen(file, "wb") : NULL;
    if (file) {
        CHECK(f);
        if (sdr) fprintf(f, "P6\n%u %u\n255\n", a->width, a->height);
        else CHECK(fwrite(data, fp16 ? 8 : 4, length, f) == length);
    }
    for (size_t i = 0; i < length; i++) {
        unsigned char bytes[3] = {0};
        for (int c = 0; c < 3; c++) {
            float value;
            if (sdr) {
                bytes[c] = data[i*4 + (format == VK_FORMAT_B8G8R8A8_UNORM ? 2-c : c)];
                value = bytes[c] / 255.0f;
            } else if (fp16) {
                uint16_t bits;
                memcpy(&bits, data + i*8 + c*2, sizeof(bits));
                value = half_float(bits);
            } else {
                uint32_t bits;
                memcpy(&bits, data + i*4, sizeof(bits));
                int channel = format == VK_FORMAT_A2R10G10B10_UNORM_PACK32 ? 2-c : c;
                value = ((bits >> (10 * channel)) & 1023) / 1023.0f;
            }
            CHECK(isfinite(value));
            if (value < low[c]) low[c] = value;
            if (value > high[c]) high[c] = value;
        }
        if (f && sdr) CHECK(fwrite(bytes, 3, 1, f) == 1);
    }
    if (f) CHECK(fclose(f) == 0);
    if (file && !sdr) {
        char path[1024];
        CHECK(snprintf(path, sizeof(path), "%s.json", file) < (int)sizeof(path));
        f = fopen(path, "wb"); CHECK(f);
        fprintf(f, "{\"width\":%u,\"height\":%u,\"format\":%d,\"output\":\"%s\",\"peak\":%.9g,\"pts\":%.9f,\"byte_order\":\"little\"}\n",
            a->width, a->height, format, output_names[a->output], strtod(output_peak(a), NULL), a->pts);
        CHECK(fclose(f) == 0);
    }
    bool content = high[0] > low[0] || high[1] > low[1] || high[2] > low[2];
    fprintf(stderr,"PIXEL_RANGE=%g:%g,%g:%g,%g:%g\n",low[0],high[0],low[1],high[1],low[2],high[2]);
    if (expected == 1) CHECK(content);
    if (expected == 0) CHECK(high[0] <= 1.0f/255 && high[1] <= 1.0f/255 && high[2] <= 1.0f/255 &&
                             low[0] >= 0 && low[1] >= 0 && low[2] >= 0);
    fprintf(stderr, "PIXELS=PASS EXPECT=%d RGB=%g:%g,%g:%g,%g:%g\n", expected,
        low[0], high[0], low[1], high[1], low[2], high[2]);
}

static void smoke_fill_pattern(void *pixels, uint32_t width, uint32_t height, bool scrgb)
{
#ifdef __APPLE__
    const double nits[] = {0, 80, 100, 203, 400, 500};
    unsigned char colors[6][8] = {{0}};
    size_t stride = scrgb ? 8 : 4;
    for (int i = 0; i < 6; i++) {
        if (scrgb) {
            _Float16 gray = nits[i] / 80;
            _Float16 rgba[] = {gray, gray, gray, 1};
            memcpy(colors[i], rgba, 8);
        } else {
            double p = pow(nits[i] / 10000, 2610.0 / 16384);
            double pq = pow((3424.0/4096 + 2413.0/128 * p) / (1 + 2392.0/128 * p), 2523.0/32);
            uint32_t code = (uint32_t)lround(pq * 1023);
            uint32_t rgba = code | code << 10 | code << 20 | 3u << 30;
            memcpy(colors[i], &rgba, 4);
        }
    }
    for (uint32_t y = 0; y < height; y++) {
        for (uint32_t x = 0; x < width; x++) {
            int patch = y * 2 / height * 3 + x * 3 / width;
            memcpy((char *)pixels + ((size_t)y * width + x) * stride, colors[patch], stride);
        }
    }
#else
    (void)pixels; (void)width; (void)height; (void)scrgb;
    unsupported("pattern diagnostic is macOS-only");
#endif
}

static void upload_pattern(struct app *a, VkCommandBuffer cb, mpv_vulkan_target *t)
{
    CHECK(!a->mpv && !a->render && a->output != OUTPUT_SDR);
    // This diagnostic waits for every readback, so the shared staging buffer is idle.
    smoke_fill_pattern(a->pixels, a->width, a->height, a->output == OUTPUT_SCRGB);
    VkImageMemoryBarrier image = {.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = t->image, .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1}};
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
        0, 0,NULL, 0,NULL, 1,&image);
    VkBufferImageCopy copy = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT,0,0,1},
        .imageExtent = {a->width,a->height,1}};
    vkCmdCopyBufferToImage(cb, a->readback, t->image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
    image.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    image.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    image.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    image.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    VkBufferMemoryBarrier buffer = {.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT, .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .buffer = a->readback, .size = VK_WHOLE_SIZE};
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
        0, 0,NULL, 1,&buffer, 1,&image);
}

static void draw(struct app *a, int expected, const char *capture)
{
    unsigned slot = a->sequence++ % 3;
    VK(vkWaitForFences(a->device, 1, &a->fences[slot], VK_TRUE, 10000000000ULL));
    uint32_t index = (a->sequence - 1) % a->num_targets;
    if (a->window) {
        VkResult r = vkAcquireNextImageKHR(a->device, a->swapchain, 10000000000ULL,
            a->acquire[slot], VK_NULL_HANDLE, &index);
        if (r == VK_ERROR_OUT_OF_DATE_KHR) { make_targets(a, a->width, a->height); draw(a, expected, capture); return; }
        CHECK(r == VK_SUCCESS || r == VK_SUBOPTIMAL_KHR);
    }
    bool read = a->pattern || expected >= 0 || capture;
    mpv_vulkan_target *t = &a->targets[index];
    t->state = MPV_VULKAN_TARGET_UNTOUCHED;
    t->acquire = a->window || a->timeline ? a->acquire[slot] : VK_NULL_HANDLE;
    t->completion = a->complete[slot];
    t->acquire_value = t->completion_value = a->timeline ? ++a->value : 0;
    if (a->timeline) {
        VkSemaphoreSignalInfo signal = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_SIGNAL_INFO,
            .semaphore = t->acquire, .value = t->acquire_value};
        PFN_vkSignalSemaphore signal_semaphore = (void *)
            vkGetDeviceProcAddr(a->device, "vkSignalSemaphore");
        CHECK(signal_semaphore);
        VK(signal_semaphore(a->device, &signal));
    }
    t->output_layout = read ? VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL :
        a->window ? VK_IMAGE_LAYOUT_PRESENT_SRC_KHR : VK_IMAGE_LAYOUT_GENERAL;
    int block = a->play_seconds != 0, depth = a->output == OUTPUT_PQ ? 10 : 8;
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_VULKAN_TARGET, t}, {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block},
        {MPV_RENDER_PARAM_FLIP_Y, &a->flip}, {MPV_RENDER_PARAM_DEPTH, &depth}, {0}};
    if (!a->pattern) {
        int err = mpv_render_context_render(a->render, params);
        fprintf(stderr, "RENDER=%d STATE=%d TARGET=%u PTS=", err, t->state, index);
        fprintf(stderr, "%.6f\n", a->pts);
        pump(a);
        CHECK(t->state == MPV_VULKAN_TARGET_RETURNED);
        CHECK(err == 0);
    }
    VK(vkResetFences(a->device, 1, &a->fences[slot]));
    VkCommandBuffer cb = a->commands[slot];
    VK(vkResetCommandBuffer(cb, 0));
    VkCommandBufferBeginInfo begin = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
    VK(vkBeginCommandBuffer(cb, &begin));
    if (a->pattern) upload_pattern(a, cb, t);
    if (read) {
        VkBufferImageCopy copy = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT,0,0,1},
            .imageExtent = {a->width,a->height,1}};
        vkCmdCopyImageToBuffer(cb, t->image, t->output_layout, a->readback, 1, &copy);
        VkBufferMemoryBarrier barrier = {.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
            .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .buffer = a->readback, .size = VK_WHOLE_SIZE};
        vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
            0, 0,NULL, 1,&barrier, 0,NULL);
        if (a->window) {
            VkImageMemoryBarrier ib = {.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                .srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT, .oldLayout = t->output_layout,
                .newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
                .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                .image = t->image, .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1}};
            vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
                0, 0,NULL, 0,NULL, 1,&ib);
        }
    }
    VK(vkEndCommandBuffer(cb));
    uint64_t zero = 0;
    VkSemaphore wait = a->pattern ? t->acquire : t->completion;
    uint64_t wait_value = a->pattern ? t->acquire_value : t->completion_value;
    VkTimelineSemaphoreSubmitInfo timeline = {.sType = VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO,
        .waitSemaphoreValueCount = wait ? 1 : 0, .pWaitSemaphoreValues = &wait_value,
        .signalSemaphoreValueCount = a->window ? 1 : 0, .pSignalSemaphoreValues = &zero};
    VkPipelineStageFlags stage = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
    VkSubmitInfo submit = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .pNext = &timeline,
        .waitSemaphoreCount = wait ? 1 : 0, .pWaitSemaphores = &wait, .pWaitDstStageMask = &stage,
        .commandBufferCount = 1, .pCommandBuffers = &cb,
        .signalSemaphoreCount = a->window ? 1 : 0, .pSignalSemaphores = &a->present[index]};
    lock(a,a->family,0);
    VK(vkQueueSubmit(a->queue,1,&submit,a->fences[slot]));
    if (a->window) {
        VkPresentInfoKHR present = {.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .waitSemaphoreCount = 1, .pWaitSemaphores = &a->present[index],
            .swapchainCount = 1, .pSwapchains = &a->swapchain, .pImageIndices = &index};
        VkResult r = vkQueuePresentKHR(a->queue,&present);
        CHECK(r == VK_SUCCESS || r == VK_SUBOPTIMAL_KHR || r == VK_ERROR_OUT_OF_DATE_KHR);
    }
    unlock(a,a->family,0);
    if (a->render) mpv_render_context_report_swap(a->render);
    // Offscreen targets use host completion before reuse; window tests retain
    // up to three submissions in flight when no readback is requested.
    if (read || !a->window) {
        VK(vkWaitForFences(a->device,1,&a->fences[slot],VK_TRUE,10000000000ULL));
        if (read) pixels(a,t->format,expected,capture);
    }
    t->input_layout = a->window ? VK_IMAGE_LAYOUT_PRESENT_SRC_KHR : t->output_layout;
    pump(a);
#ifdef _WIN32
    if (a->window && a->compare_hdr) {
        char title[160];
        snprintf(title, sizeof(title), "libmpv Vulkan / %s / target %s nits / frame READY | Right-click/Space: PQ-scRGB  Esc: close",
                 output_names[a->output], output_peak(a));
        SDL_SetWindowTitle(a->window, title);
    }
#endif
#ifdef __APPLE__
    if (a->window && (!a->play_seconds || read)) {
        double headroom = smoke_macos_report(a->window);
        if (fabs(headroom - a->headroom) > 0.005 * headroom) {
            a->headroom = headroom;
            a->stable_samples = 0;
        } else {
            a->stable_samples++;
        }
        if (a->compare_hdr) {
            char title[256];
            snprintf(title, sizeof(title), "%s / %s / %s | Right-click/Space: PQ-scRGB  Esc: close",
                a->pattern ? "No libmpv" : "libmpv", output_names[a->output],
                a->stable_samples >= 10 ? "READY" : "SETTLING");
            SDL_SetWindowTitle(a->window, title);
        }
        fprintf(stderr, "COMPARISON_READY=%d OUTPUT=%s\n",
            a->stable_samples >= 10, output_names[a->output]);
    }
#endif
}

static void play(struct app *a, int seconds)
{
    command(a, (const char *[]){"set", "pause", "no", NULL}, false);
    uint64_t begin = SDL_GetTicks64(), next_sample = begin, progress = begin, drift = 0;
    double pts = a->pts;
    a->audio_progress = begin;
    while (!a->result && !a->quit && SDL_GetTicks64() - begin < (uint64_t)seconds * 1000) {
        pump(a);
        uint64_t now = SDL_GetTicks64();
        if (a->ended) { playback_error(a, 1, "file ended before requested duration"); break; }
        if (now >= next_sample) { metrics(a); next_sample = now + 1000; }
        if (a->pts > pts) { pts = a->pts; progress = now; }
        if (now - begin > 5000) {
            if (!a->audio_seen || !isfinite(a->audio_pts) || !isfinite(a->avsync))
                playback_error(a, 1, "audio/sync statistics unavailable");
            if (now - progress > 5000 || now - a->audio_progress > 5000)
                playback_error(a, 1, "audio or video progress stalled");
            if (isfinite(a->avsync) && fabs(a->avsync) > 0.100) {
                if (!drift) drift = now;
                if (now - drift >= 5000) playback_error(a, 1, "sustained A/V drift over 100 ms");
            } else { drift = 0; }
        }
        if (a->result || a->quit) break;
        mpv_render_frame_info info = {0};
        CHECK(mpv_render_context_get_info(a->render,
            (mpv_render_param){MPV_RENDER_PARAM_NEXT_FRAME_INFO, &info}) == 0);
        if (info.flags & MPV_RENDER_FRAME_INFO_PRESENT) draw(a, -1, NULL);
        else SDL_Delay(1);
    }
    if (a->quit) playback_error(a, 2, "user closed before requested duration");
    if (progress <= begin || a->audio_progress <= begin)
        playback_error(a, 1, "no measured audio/video progress");
    fprintf(stderr, "PLAY_DURATION_MS=%llu REQUESTED_SECONDS=%d RESULT=%d\n",
        (unsigned long long)(SDL_GetTicks64() - begin), seconds, a->result);
    command(a, (const char *[]){"set", "pause", "yes", NULL}, false);
}

static void hold(struct app *a, int seconds)
{
    uint64_t end = SDL_GetTicks64() + (uint64_t)seconds * 1000;
    while (!a->quit && SDL_GetTicks64() < end) {
        pump(a);
        if (a->toggle_hdr) {
            drop_targets(a);
            a->output = a->output == OUTPUT_PQ ? OUTPUT_SCRGB : OUTPUT_PQ;
            if (a->render) {
                command(a,(const char *[]){"set","target-prim",a->output == OUTPUT_PQ ? "bt.2020" : "bt.709",NULL},false);
                command(a,(const char *[]){"set","target-trc",a->output == OUTPUT_PQ ? "pq" : "scrgb",NULL},false);
                command(a,(const char *[]){"set","dither-depth",a->output == OUTPUT_PQ ? "auto" : "no",NULL},false);
            }
            make_targets(a,a->width,a->height);
            a->toggle_hdr = false;
        }
        if (a->quit) break;
        draw(a,1,NULL);
        SDL_Delay(100);
    }
    fprintf(stderr, "HOLD_ENDED=%s\n", a->quit ? "user-close" : "deadline");
}

static void close_mpv(struct app *a)
{
    mpv_render_context_set_update_callback(a->render, NULL, NULL);
    mpv_render_context_free(a->render); a->render = NULL;
    mpv_terminate_destroy(a->mpv); a->mpv = NULL;
    for (uint32_t i = 0; i < a->num_targets; i++)
        a->targets[i].state = MPV_VULKAN_TARGET_UNTOUCHED;
}

static VKAPI_ATTR void VKAPI_CALL graphics_only_queues(VkPhysicalDevice physical,
    uint32_t *count, VkQueueFamilyProperties *properties)
{
    vkGetPhysicalDeviceQueueFamilyProperties(physical, count, properties);
    if (properties) {
        for (uint32_t i = 0; i < *count; i++)
            properties[i].queueFlags &= ~VK_QUEUE_COMPUTE_BIT;
    }
}

static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL graphics_only_proc(
    VkInstance instance, const char *name)
{
    if (!strcmp(name, "vkGetPhysicalDeviceQueueFamilyProperties"))
        return (void *)graphics_only_queues;
    return instance_proc(instance, name);
}

static void probe(struct app *a)
{
    mpv_vulkan_init_params good = init_params(a);
    for (int i = 0; i < 9; i++) {
        mpv_vulkan_init_params init = good;
        VkPhysicalDeviceFeatures2 empty = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2};
        const char *renderer = i == 0 ? "gpu" : i == 1 ? "invalid" : "gpu-next";
        if (i == 3) init.version++;
        if (i == 4) init.features = &empty;
        if (i == 5) init.lock_queue = NULL;
        if (i == 6) init.queue_family = UINT32_MAX;
        VkPhysicalDeviceVulkan12Features f12 = a->f12;
        VkPhysicalDeviceFeatures2 no_sync = a->features;
        if (i == 7) { f12.pNext = NULL; no_sync.pNext = &f12; init.features = &no_sync; }
        if (i == 8) init.get_proc_address = graphics_only_proc;
        mpv_render_param params[] = {
            {MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_VULKAN},
            {MPV_RENDER_PARAM_RENDERER, (void *)renderer},
            {MPV_RENDER_PARAM_VULKAN_INIT_PARAMS, i == 2 ? NULL : &init}, {0}};
        mpv_handle *m = mpv_create(); CHECK(m); CHECK(mpv_initialize(m) == 0);
        mpv_render_context *r = NULL;
        int expected = i == 0 ? MPV_ERROR_NOT_IMPLEMENTED : (i == 4 || i == 7 || i == 8) ? MPV_ERROR_UNSUPPORTED : MPV_ERROR_INVALID_PARAMETER;
        int err = mpv_render_context_create(&r,m,params);
        fprintf(stderr,"INIT_PROBE=%d EXPECT=%d RESULT=%d\n",i,expected,err);
        CHECK(err == expected && !r);
        mpv_terminate_destroy(m);
    }
}

static void target_probes(struct app *a)
{
    for (int i = 0; i < 9; i++) {
        mpv_vulkan_target t = a->targets[0];
        t.state = MPV_VULKAN_TARGET_UNTOUCHED;
        if (i == 1) t.version++;
        if (i == 2) t.format = VK_FORMAT_R8_UNORM;
        if (i == 3) t.width = 0;
        if (i == 4) t.generation++;
        if (i == 5) t.usage &= ~VK_IMAGE_USAGE_TRANSFER_DST_BIT;
        if (i == 6) t.output_layout = VK_IMAGE_LAYOUT_UNDEFINED;
        if (i == 7) t.completion = VK_NULL_HANDLE;
        int skip = i == 8, block = 0;
        mpv_render_param params[] = {{MPV_RENDER_PARAM_VULKAN_TARGET, i ? &t : NULL},
            {MPV_RENDER_PARAM_SKIP_RENDERING,&skip},
            {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME,&block},{0}};
        int err = mpv_render_context_render(a->render,params);
        int expected = skip ? 0 : i == 2 ? MPV_ERROR_UNSUPPORTED : MPV_ERROR_INVALID_PARAMETER;
        fprintf(stderr,"TARGET_PROBE=%d EXPECT=%d RESULT=%d STATE=%d\n",i,expected,err,t.state);
        CHECK(err == expected && t.state == MPV_VULKAN_TARGET_UNTOUCHED);
    }
    mpv_vulkan_retire_target r = {.version = MPV_VULKAN_DRAFT_VERSION,
        .image = a->targets[0].image, .generation = a->targets[0].generation};
    r.version++;
    CHECK(mpv_render_context_set_parameter(a->render,(mpv_render_param){MPV_RENDER_PARAM_VULKAN_RETIRE_TARGET,&r}) == MPV_ERROR_INVALID_PARAMETER);
    r.version = MPV_VULKAN_DRAFT_VERSION;
    CHECK(mpv_render_context_set_parameter(a->render,(mpv_render_param){MPV_RENDER_PARAM_VULKAN_RETIRE_TARGET,&r}) == 0);
    CHECK(mpv_render_context_set_parameter(a->render,(mpv_render_param){MPV_RENDER_PARAM_VULKAN_RETIRE_TARGET,&r}) == MPV_ERROR_INVALID_PARAMETER);
    a->targets[0].state = MPV_VULKAN_TARGET_UNTOUCHED;
    fprintf(stderr,"RETIRE_PROBE=PASS\n");
}

static void fault_probe(struct app *a)
{
    VK(vkDeviceWaitIdle(a->device));
    mpv_vulkan_target t = a->targets[0];
    t.state = MPV_VULKAN_TARGET_UNTOUCHED;
    t.acquire = VK_NULL_HANDLE; t.acquire_value = 0;
    t.completion = a->complete[0];
    t.completion_value = a->timeline ? ++a->value : 0;
    t.output_layout = VK_IMAGE_LAYOUT_GENERAL;
    int block = 0;
    mpv_render_param params[] = {{MPV_RENDER_PARAM_VULKAN_TARGET,&t},
        {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME,&block},{0}};
    atomic_store(&fail_submit,1);
    int err = mpv_render_context_render(a->render,params);
    CHECK(!atomic_load(&fail_submit));
    CHECK(err < 0 && t.state == MPV_VULKAN_TARGET_FAILED);
    // The real device is not lost. Never wait for the unsubmitted completion.
    VK(vkDeviceWaitIdle(a->device));
    t.state = MPV_VULKAN_TARGET_UNTOUCHED;
    CHECK(mpv_render_context_render(a->render,params) < 0);
    CHECK(t.state == MPV_VULKAN_TARGET_UNTOUCHED);
    pump(a);
    fprintf(stderr,"INJECTED_SUBMIT_FAILURE=PASS (not a real device loss)\n");
}

int main(int argc, char **argv)
{
    unsigned long api = mpv_client_api_version();
    fprintf(stderr, "CLIENT_API=%lu.%lu VULKAN_DRAFT=%d\n", api >> 16,
            api & 0xffff, MPV_VULKAN_DRAFT_VERSION);
    if (api < MPV_MAKE_VERSION(2, 7)) {
        fprintf(stderr, "downstream client API 2.7 or newer required\n");
        return 2;
    }

    struct app a = {.start = "2", .width = 960, .height = 540,
        .display = -1, .hwdec = "no", .audio_device = "auto"};
    bool window = false, stress = false, probes = false, fault = false;
    int contexts = 1, frames = 3, hold_seconds = 0;
    const char *file = NULL, *capture = NULL, *screenshot = NULL;
#ifdef __ANDROID__
    bool import_only = false;
    extern int android_import_probe(mpv_vulkan_init_params init);
#endif
    for (int i = 1; i < argc; i++) {
#ifdef __ANDROID__
        if (!strcmp(argv[i],"--import-only")) { import_only = true; continue; }
#endif
        if (!strcmp(argv[i],"--window")) { window = true; continue; }
        if (!strcmp(argv[i],"--fullscreen")) { window = a.fullscreen = true; continue; }
        if (!strcmp(argv[i],"--timeline")) { a.timeline = true; continue; }
        if (!strcmp(argv[i],"--stress")) { stress = true; continue; }
        if (!strcmp(argv[i],"--probe")) { probes = true; continue; }
        if (!strcmp(argv[i],"--fault")) { fault = true; continue; }
        if (!strcmp(argv[i],"--cycle-output")) { a.cycle_output = true; continue; }
        if (!strcmp(argv[i],"--bgr10")) { a.force_bgr10 = true; continue; }
        if (!strcmp(argv[i],"--pattern")) { a.pattern = true; continue; }
        if (!strcmp(argv[i],"--compare-hdr")) { a.compare_hdr = true; continue; }
        if (argv[i][0] != '-') { file = argv[i]; continue; }
        CHECK(i + 1 < argc);
        const char *key = argv[i++], *value = argv[i];
        if (!strcmp(key,"--contexts")) contexts = atoi(value);
        else if (!strcmp(key,"--frames")) frames = atoi(value);
        else if (!strcmp(key,"--capture")) capture = value;
        else if (!strcmp(key,"--screenshot")) screenshot = value;
        else if (!strcmp(key,"--start")) a.start = value;
        else if (!strcmp(key,"--hwdec")) {
            CHECK(!strcmp(value,"no") || !strcmp(value,"d3d11va-copy") || !strcmp(value,"videotoolbox-copy")
#ifdef __APPLE__
                  || !strcmp(value,"videotoolbox")
#endif
            );
            a.hwdec = value;
        }
        else if (!strcmp(key,"--audio-device")) a.audio_device = value;
        else if (!strcmp(key,"--volume")) {
            char *end;
            long volume = strtol(value, &end, 10);
            CHECK(*value && !*end && volume >= 0 && volume <= 100);
            a.volume = value;
        }
        else if (!strcmp(key,"--play-seconds")) {
            char *end;
            long seconds = strtol(value, &end, 10);
            CHECK(*value && !*end && seconds > 0 && seconds <= 900);
            a.play_seconds = seconds;
        }
        else if (!strcmp(key,"--flip")) a.flip = atoi(value);
        else if (!strcmp(key,"--width")) a.width = atoi(value);
        else if (!strcmp(key,"--height")) a.height = atoi(value);
        else if (!strcmp(key,"--hold-seconds")) hold_seconds = atoi(value);
#ifdef _WIN32
        else if (!strcmp(key,"--display")) {
            char *end;
            long display = strtol(value, &end, 10);
            CHECK(*value && !*end && display >= 0 && display <= INT_MAX);
            a.display = display;
        }
#endif
        else if (!strcmp(key,"--vf")) a.vf = value;
        else if (!strcmp(key,"--target-gamut")) a.gamut = value;
        else if (!strcmp(key,"--target-peak")) {
            char *end;
            double peak = strtod(value, &end);
            CHECK(*value && !*end && isfinite(peak) && peak > 0 && peak <= 10000);
            a.peak = value;
        } else if (!strcmp(key,"--output")) {
            bool found = false;
            for (unsigned n = 0; n < sizeof(output_names)/sizeof(output_names[0]); n++) {
                if (!strcmp(value, output_names[n])) { a.output = n; found = true; break; }
            }
            CHECK(found);
        }
        else CHECK(false);
    }
    CHECK(!window || !a.timeline);
    CHECK(!a.fullscreen || !stress);
    CHECK(a.width > 0 && a.width <= INT_MAX && a.height > 0 && a.height <= INT_MAX);
    CHECK(contexts > 0 && frames > 0);
    CHECK(!a.play_seconds || (window && file && !a.pattern && !hold_seconds &&
        !a.compare_hdr && !a.cycle_output && !probes && !fault && contexts == 1 && frames == 3));
    CHECK(a.play_seconds || !strcmp(a.audio_device,"auto"));
    CHECK(a.play_seconds || !a.volume);
    CHECK(hold_seconds >= 0 && (!a.force_bgr10 || a.output == OUTPUT_PQ));
    CHECK(!a.compare_hdr || (window && hold_seconds > 0 && a.output != OUTPUT_SDR && (a.pattern || file)));
    CHECK(!a.pattern || (!file && !probes && !fault && !stress && !a.cycle_output && contexts == 1 && a.output != OUTPUT_SDR));
#if !defined(__APPLE__) && !defined(_WIN32)
    if (a.compare_hdr) unsupported("HDR comparison is not enabled on this platform");
#endif
#ifndef __APPLE__
    if (a.pattern) unsupported("pattern diagnostic is macOS-only");
#endif
    init_vulkan(&a,window);
#ifdef __ANDROID__
    if (import_only) {
        CHECK(android_import_probe(init_params(&a)) == 0);
        contexts = 0;
    }
#endif
    if (probes) probe(&a);
    make_targets(&a,a.width,a.height);
    if (a.pattern) {
        fprintf(stderr, "MPV_HANDLE_CREATED=0 GRAY_NITS=0,80,100,203,400,500\n");
        a.pts = -1;
        for (int i = 0; i < frames; i++) draw(&a,1,i ? NULL : capture);
        hold(&a,hold_seconds);
        contexts = 0;
    }
    for (int c = 0; c < contexts; c++) {
        create_mpv(&a);
        draw(&a,0,NULL);
        if (probes && c == 0) target_probes(&a);
        if (file) {
            command(&a,(const char *[]){"loadfile",file,NULL},true);
            draw(&a,1,capture);
            metrics(&a);
            uint64_t hw_deadline = SDL_GetTicks64() + 5000;
            while (!a.hw_seen && !a.result && SDL_GetTicks64() < hw_deadline) { pump(&a); SDL_Delay(1); }
            if (!a.hw_seen) playback_error(&a, 1, "decoder identity unavailable");
            if (a.result) goto stop_file;
            if (screenshot) command(&a,(const char *[]){"screenshot-to-file",screenshot,"window",NULL},false);
            if (a.play_seconds) play(&a, a.play_seconds);
            if (a.result) goto stop_file;
            if (frames > 3) command(&a,(const char *[]){"set","pause","no",NULL},false);
            for (int i = 1; i < frames; i++) {
                pump(&a);
                mpv_render_frame_info info = {0};
                mpv_render_context_get_info(a.render,(mpv_render_param){MPV_RENDER_PARAM_NEXT_FRAME_INFO,&info});
                if (frames > 3 && !(info.flags & MPV_RENDER_FRAME_INFO_PRESENT)) { SDL_Delay(1); i--; continue; }
                draw(&a,window ? -1 : 1,NULL);
            }
            if (stress) {
                command(&a,(const char *[]){"set","pause","yes",NULL},false);
                for (int i = 0; i < 100; i++) {
                    if (window) { SDL_SetWindowSize(a.window,960 + i%2*64,540 + i%2*36); SDL_PumpEvents(); }
                    make_targets(&a,960 + i%2*64,540 + i%2*36);
                    draw(&a,1,NULL);
                }
                fprintf(stderr,"RESIZES=100 PASS\n");
                if (a.play_seconds) play(&a, 2);
                for (int i = 0; i < 20; i++) {
                    command(&a,(const char *[]){"loadfile",file,NULL},true);
                    draw(&a,1,NULL);
                    if (a.play_seconds) play(&a, 2);
                    if (a.result) goto stop_file;
                }
                fprintf(stderr,"LOADS=20 PASS\n");
                CHECK(screenshot);
                for (int i = 0; i < 20; i++) {
                    uint64_t restart = a.playback_restarts;
                    command(&a,(const char *[]){"seek",i%2 ? "2" : "3","absolute+exact",NULL},false);
                    int skip = 1, block = 0;
                    mpv_render_param ps[] = {{MPV_RENDER_PARAM_SKIP_RENDERING,&skip},
                        {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME,&block},{0}};
                    uint64_t deadline = SDL_GetTicks64() + 15000;
                    int skipped = 0;
                    // A seek reply can precede decoding; skip until the new frame restarts playback.
                    while (a.playback_restarts == restart) {
                        pump(&a);
                        if (a.playback_restarts != restart) break;
                        mpv_render_frame_info info = {0};
                        CHECK(mpv_render_context_get_info(a.render,
                            (mpv_render_param){MPV_RENDER_PARAM_NEXT_FRAME_INFO,&info}) == 0);
                        if (info.flags & MPV_RENDER_FRAME_INFO_PRESENT) {
                            CHECK(mpv_render_context_render(a.render,ps) == 0);
                            mpv_render_context_report_swap(a.render);
                            skipped++;
                        } else {
                            SDL_Delay(1);
                        }
                        CHECK(!a.result && !a.quit && SDL_GetTicks64() < deadline);
                    }
                    CHECK(skipped > 0);
                    fprintf(stderr,"SEEK_RESTART=%d SKIPPED_FRAMES=%d PTS=%.6f\n",i,skipped,a.pts);
                    char path[1024]; snprintf(path,sizeof(path),"%s-skip-%02d.png",screenshot,i);
                    command(&a,(const char *[]){"screenshot-to-file",path,"window",NULL},false);
                    snprintf(path,sizeof(path),"%s-skip-%02d.%s",screenshot,i,
                             a.output == OUTPUT_SDR ? "ppm" : "raw");
                    draw(&a,1,path);
                    if (a.play_seconds) play(&a, 2);
                    if (a.result) goto stop_file;
                }
                fprintf(stderr,"SKIP_SCREENSHOT_CYCLES=20 PASS\n");
            }
            if (a.cycle_output) {
                command(&a,(const char *[]){"set","pause","yes",NULL},false);
                for (int i = 0; i < 20; i++) {
                    for (unsigned mode = 0; mode < 4; mode++) {
                        drop_targets(&a);
                        a.output = mode % 3;
                        command(&a,(const char *[]){"set","target-prim",a.output == OUTPUT_PQ ? "bt.2020" : "bt.709",NULL},false);
                        command(&a,(const char *[]){"set","target-trc",a.output == OUTPUT_PQ ? "pq" : a.output == OUTPUT_SCRGB ? "scrgb" : "srgb",NULL},false);
                        command(&a,(const char *[]){"set","target-peak",output_peak(&a),NULL},false);
                        command(&a,(const char *[]){"set","dither-depth",a.output == OUTPUT_SCRGB ? "no" : "auto",NULL},false);
                        make_targets(&a,a.width,a.height);
                        draw(&a,1,NULL);
                    }
                }
                fprintf(stderr,"OUTPUT_CYCLES=20 PASS\n");
            }
            if (hold_seconds) {
                command(&a,(const char *[]){"set","pause","yes",NULL},false);
                hold(&a,hold_seconds);
            }
stop_file:
            command(&a,(const char *[]){"stop",NULL},false);
            // Drain the VO detach work before testing the no-video target.
            pump(&a);
            draw(&a,0,NULL);
        }
        if (fault) fault_probe(&a);
        close_mpv(&a);
        fprintf(stderr,"CONTEXT=%d CLOSED\n",c);
        if (a.result) break;
    }
    drop_targets(&a);
    vkDestroyCommandPool(a.device,a.pool,NULL);
    for (int i = 0; i < 3; i++) {
        vkDestroySemaphore(a.device,a.acquire[i],NULL);
        vkDestroySemaphore(a.device,a.complete[i],NULL);
        vkDestroyFence(a.device,a.fences[i],NULL);
    }
    for (int i = 0; i < 8; i++) vkDestroySemaphore(a.device,a.present[i],NULL);
    vkDestroyDevice(a.device,NULL);
    if (a.surface) vkDestroySurfaceKHR(a.instance,a.surface,NULL);
    PFN_vkDestroyDebugUtilsMessengerEXT destroy_debug = (void *)vkGetInstanceProcAddr(a.instance,"vkDestroyDebugUtilsMessengerEXT");
    destroy_debug(a.instance,a.debug,NULL);
    vkDestroyInstance(a.instance,NULL);
    if (a.window) SDL_DestroyWindow(a.window);
    SDL_Quit();
    pthread_mutex_destroy(&a.mutex);
    fprintf(stderr,"VALIDATION_ERRORS=%d\n",atomic_load(&validation_errors));
    if (a.result) return a.result;
    if (atomic_load(&validation_errors)) {
        fprintf(stderr,"RENDER_CHECKS=PASS VALIDATION=FAIL\n");
        return 1;
    }
    fprintf(stderr,"RESULT=PASS\n");
    return 0;
}
