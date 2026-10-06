#define VK_USE_PLATFORM_METAL_EXT
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <AVFoundation/AVFoundation.h>
#include <mpv/client.h>
#include <mpv/render_vk.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <math.h>
#include <unistd.h>
#include <string.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line=%d: %s\n", __LINE__, #x); abort(); } } while (0)
#define VK(x) do { VkResult r = (x); if (r != VK_SUCCESS) { fprintf(stderr, "VK_FAIL line=%d result=%d\n", __LINE__, r); abort(); } } while (0)

static pthread_mutex_t ui_mutex = PTHREAD_MUTEX_INITIALIZER;
static bool ui_active;
static uint32_t ui_width, ui_height;

struct test {
    VkInstance instance;
    VkPhysicalDevice physical;
    VkDevice device;
    VkQueue queue;
    uint32_t family;
    pthread_mutex_t mutex;
    VkSurfaceKHR surface;
    VkSwapchainKHR swapchain;
    VkDeviceMemory image_memory;
    mpv_vulkan_target targets[8];
    uint32_t count, width, height;
    uint64_t generation;
    __unsafe_unretained CAMetalLayer *layer;
    bool expect_black;
    unsigned resumes;
    double background_seconds;
    VkFormat format;
    VkCommandPool pool;
    VkCommandBuffer command;
    VkFence fence;
    VkSemaphore acquire, complete, present[8];
    uint64_t value;
    VkBuffer buffer;
    VkDeviceMemory buffer_memory;
    uint8_t *pixels;
    mpv_handle *mpv;
    mpv_render_context *render;
    atomic_bool dirty;
    bool loaded;
    bool pq;
    const char *hwdec;
    double play_seconds;
    uint64_t command_id, replied;
    int command_error;
    unsigned restarts;
    bool configured, ended, paused;
    double pts, audio_pts, avsync;
    bool audio_seen;
    char decoder[64];
    NSString *raw_capture;
};

static void window_state(struct test *t);

static void queue_lock(void *ctx, uint32_t family, uint32_t index)
{
    struct test *t = ctx;
    CHECK(family == t->family && index == 0);
    CHECK(pthread_mutex_lock(&t->mutex) == 0);
}

static void queue_unlock(void *ctx, uint32_t family, uint32_t index)
{
    struct test *t = ctx;
    CHECK(family == t->family && index == 0);
    CHECK(pthread_mutex_unlock(&t->mutex) == 0);
}

static void wakeup(void *ctx) { atomic_store((atomic_bool *)ctx, true); }

static uint32_t memory_type(struct test *t, uint32_t bits, VkMemoryPropertyFlags flags)
{
    VkPhysicalDeviceMemoryProperties p;
    vkGetPhysicalDeviceMemoryProperties(t->physical, &p);
    for (uint32_t i = 0; i < p.memoryTypeCount; i++)
        if ((bits & (1u << i)) && (p.memoryTypes[i].propertyFlags & flags) == flags)
            return i;
    CHECK(false);
    return 0;
}

static void pump(struct test *t)
{
    if (atomic_exchange(&t->dirty, false)) mpv_render_context_update(t->render);
    for (;;) {
        mpv_event *e = mpv_wait_event(t->mpv, 0);
        if (e->event_id == MPV_EVENT_NONE) break;
        if (e->event_id == MPV_EVENT_LOG_MESSAGE) {
            mpv_event_log_message *m = e->data;
            fprintf(stderr, "[%s/%s] %s", m->prefix, m->level, m->text);
        }
        if (e->event_id == MPV_EVENT_FILE_LOADED) t->loaded = true;
        if (e->event_id == MPV_EVENT_PLAYBACK_RESTART) t->restarts++;
        if (e->event_id == MPV_EVENT_COMMAND_REPLY) {
            t->replied = e->reply_userdata;
            t->command_error = e->error;
            if (t->raw_capture && !e->error) {
                mpv_node *result = &((mpv_event_command *)e->data)->result;
                CHECK(result->format == MPV_FORMAT_NODE_MAP);
                int64_t w = 0, h = 0, stride = 0;
                mpv_byte_array *bytes = NULL;
                for (int i = 0; i < result->u.list->num; i++) {
                    mpv_node *value = &result->u.list->values[i];
                    const char *key = result->u.list->keys[i];
                    if (!strcmp(key,"w")) w = value->u.int64;
                    if (!strcmp(key,"h")) h = value->u.int64;
                    if (!strcmp(key,"stride")) stride = value->u.int64;
                    if (!strcmp(key,"data")) bytes = value->u.ba;
                    if (!strcmp(key,"format")) CHECK(!strcmp(value->u.string,"rgba"));
                }
                CHECK(w > 0 && h > 0 && stride >= w*4 && bytes && bytes->size >= (size_t)stride*(size_t)h);
                FILE *file = fopen(t->raw_capture.fileSystemRepresentation,"wb"); CHECK(file);
                fprintf(file,"P6\n%lld %lld\n255\n",(long long)w,(long long)h);
                for (int64_t y = 0; y < h; y++) for (int64_t x = 0; x < w; x++)
                    CHECK(fwrite((uint8_t *)bytes->data+y*stride+x*4,3,1,file) == 1);
                CHECK(fclose(file) == 0);
                t->raw_capture = nil;
            }
        }
        if (e->event_id == MPV_EVENT_PROPERTY_CHANGE) {
            mpv_event_property *p = e->data;
            if (!strcmp(p->name, "time-pos")) t->pts = p->data ? *(double *)p->data : -1;
            if (!strcmp(p->name, "audio-pts")) t->audio_pts = p->data ? *(double *)p->data : NAN;
            if (!strcmp(p->name, "avsync")) t->avsync = p->data ? *(double *)p->data : NAN;
            if (!strcmp(p->name, "vo-configured"))
                t->configured = p->data && *(int *)p->data;
            if (!strcmp(p->name, "pause") && p->data) t->paused = *(int *)p->data;
            if (!strcmp(p->name, "hwdec-current"))
                snprintf(t->decoder, sizeof(t->decoder), "%s", p->data ? *(char **)p->data : "");
            if (!strcmp(p->name, "current-ao") && p->data) {
                const char *ao = *(char **)p->data;
                fprintf(stderr, "AUDIO_OUTPUT=%s\n", ao);
                CHECK(strcmp(ao, "null"));
                t->audio_seen = true;
            }
        }
        if (e->event_id == MPV_EVENT_END_FILE) {
            t->loaded = false;
            t->ended = true;
            mpv_event_end_file *end = e->data;
            CHECK(end->reason != MPV_END_FILE_REASON_ERROR);
        }
    }
}

static void command(struct test *t, const char **args)
{
    uint64_t id = ++t->command_id;
    if (!strcmp(args[0], "loadfile")) {
        t->loaded = false;
        t->ended = false;
    }
    CHECK(mpv_command_async(t->mpv, id, args) == 0);
    double deadline = CACurrentMediaTime() + 15;
    do { pump(t); CHECK(CACurrentMediaTime() < deadline); usleep(1000); } while (t->replied != id);
    CHECK(t->command_error == 0);
}

static void wait_frame(struct test *t)
{
    window_state(t);
    double deadline = CACurrentMediaTime() + 20;
    for (;;) {
        pump(t);
        mpv_render_frame_info info = {0};
        CHECK(mpv_render_context_get_info(t->render,
            (mpv_render_param){MPV_RENDER_PARAM_NEXT_FRAME_INFO, &info}) == 0);
        if (t->loaded && (info.flags & MPV_RENDER_FRAME_INFO_PRESENT) &&
            !(info.flags & MPV_RENDER_FRAME_INFO_REDRAW)) return;
        CHECK(CACurrentMediaTime() < deadline);
        usleep(1000);
    }
}

static void pixels(struct test *t, NSString *path)
{
    unsigned low = t->pq ? 1023 : 255, high = 0;
    size_t nonblack = 0;
    FILE *f = path ? fopen(path.fileSystemRepresentation, "wb") : NULL;
    if (path) {
        CHECK(f);
        if (t->pq) CHECK(fwrite(t->pixels, 4, (size_t)t->width * t->height, f) == (size_t)t->width * t->height);
        else fprintf(f, "P6\n%u %u\n255\n", t->width, t->height);
    }
    for (size_t i = 0; i < (size_t)t->width * t->height; i++) {
        unsigned rgb[3];
        for (int c = 0; c < 3; c++) {
            unsigned v;
            if (t->pq) {
                uint32_t packed; memcpy(&packed, t->pixels + i * 4, 4);
                int channel = t->format == VK_FORMAT_A2R10G10B10_UNORM_PACK32 ? 2-c : c;
                v = (packed >> (10 * channel)) & 1023;
            } else {
                v = t->pixels[i * 4 + (t->format == VK_FORMAT_B8G8R8A8_UNORM ? 2-c : c)];
            }
            rgb[c] = v;
            if (v < low) low = v;
            if (v > high) high = v;
        }
        nonblack += rgb[0] || rgb[1] || rgb[2];
        if (f && !t->pq) {
            uint8_t bytes[] = {rgb[0],rgb[1],rgb[2]};
            CHECK(fwrite(bytes, 3, 1, f) == 1);
        }
    }
    if (f) CHECK(fclose(f) == 0);
    if (t->expect_black) CHECK(high == 0);
    else CHECK(high > low && nonblack > (size_t)t->width * t->height / 10);
    fprintf(stderr, "PIXELS=PASS SIZE=%ux%u RANGE=%u:%u NONBLACK=%zu\n",
        t->width, t->height, low, high, nonblack);
    if (t->pq) {
        double p = pow(high / 1023.0, 32.0 / 2523);
        double nits = 10000 * pow(fmax(p - 3424.0/4096, 0) / (2413.0/128 - 2392.0/128 * p), 16384.0/2610);
        fprintf(stderr, "PQ_MAX_CHANNEL_NITS=%.6f\n", nits);
    }
    if (path && t->pq) {
        NSDictionary *info = @{@"width":@(t->width), @"height":@(t->height),
            @"format":@(t->format), @"output":@"pq", @"byte_order":@"little"};
        NSData *json = [NSJSONSerialization dataWithJSONObject:info options:0 error:nil]; CHECK(json);
        CHECK([json writeToFile:[path stringByAppendingString:@".json"] atomically:YES]);
    }
}

static void report_display(CAMetalLayer *layer)
{
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (@available(iOS 16.0, *)) {
            UIScreen *screen = UIScreen.mainScreen;
            NSString *space = layer.colorspace ? CFBridgingRelease(CGColorSpaceCopyName(layer.colorspace)) : @"nil";
            fprintf(stderr, "DISPLAY CURRENT_EDR=%g POTENTIAL_EDR=%g BRIGHTNESS=%g LAYER_FORMAT=%lu EDR_REQUEST=%d COLORSPACE=%s\n",
                screen.currentEDRHeadroom, screen.potentialEDRHeadroom, screen.brightness,
                (unsigned long)layer.pixelFormat, layer.wantsExtendedDynamicRangeContent, space.UTF8String);
        }
    });
}

static void draw(struct test *t, NSString *capture, bool read)
{
    window_state(t);
    VK(vkWaitForFences(t->device, 1, &t->fence, VK_TRUE, 10000000000ULL));
    uint32_t index = 0;
    if (t->swapchain) {
        VkResult r = vkAcquireNextImageKHR(t->device, t->swapchain, 10000000000ULL,
            t->acquire, VK_NULL_HANDLE, &index);
        CHECK(r == VK_SUCCESS || r == VK_SUBOPTIMAL_KHR);
    }
    mpv_vulkan_target *target = &t->targets[index];
    target->state = MPV_VULKAN_TARGET_UNTOUCHED;
    target->acquire = t->swapchain ? t->acquire : VK_NULL_HANDLE;
    target->completion = t->complete;
    target->completion_value = t->swapchain ? 0 : ++t->value;
    target->output_layout = read ? VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL :
        t->swapchain ? VK_IMAGE_LAYOUT_PRESENT_SRC_KHR : VK_IMAGE_LAYOUT_GENERAL;
    int depth = t->pq ? 10 : 8, block = t->play_seconds > 0, flip = 0;
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_VULKAN_TARGET, target}, {MPV_RENDER_PARAM_DEPTH, &depth},
        {MPV_RENDER_PARAM_FLIP_Y, &flip}, {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block}, {0}};
    int result = mpv_render_context_render(t->render, params);
    fprintf(stderr, "RENDER=%d STATE=%d TARGET=%u\n", result, target->state, index);
    CHECK(result == 0 && target->state == MPV_VULKAN_TARGET_RETURNED);
    VK(vkResetFences(t->device, 1, &t->fence));
    VK(vkResetCommandBuffer(t->command, 0));
    VkCommandBufferBeginInfo begin = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
    VK(vkBeginCommandBuffer(t->command, &begin));
    if (read) {
    VkBufferImageCopy copy = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT,0,0,1},
        .imageExtent = {t->width,t->height,1}};
    vkCmdCopyImageToBuffer(t->command, target->image, target->output_layout, t->buffer, 1, &copy);
    VkBufferMemoryBarrier buffer = {.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .buffer = t->buffer, .size = VK_WHOLE_SIZE};
    vkCmdPipelineBarrier(t->command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
        0, 0,NULL, 1,&buffer, 0,NULL);
    }
    if (t->swapchain && read) {
        VkImageMemoryBarrier image = {.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
            .oldLayout = target->output_layout, .newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .image = target->image, .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1}};
        vkCmdPipelineBarrier(t->command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
            0, 0,NULL, 0,NULL, 1,&image);
    }
    VK(vkEndCommandBuffer(t->command));
    uint64_t zero = 0;
    VkTimelineSemaphoreSubmitInfo timeline = {.sType = VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO,
        .waitSemaphoreValueCount = 1, .pWaitSemaphoreValues = &target->completion_value,
        .signalSemaphoreValueCount = t->swapchain ? 1 : 0, .pSignalSemaphoreValues = &zero};
    VkPipelineStageFlags stage = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
    VkSubmitInfo submit = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .pNext = &timeline,
        .waitSemaphoreCount = 1, .pWaitSemaphores = &t->complete, .pWaitDstStageMask = &stage,
        .commandBufferCount = 1, .pCommandBuffers = &t->command,
        .signalSemaphoreCount = t->swapchain ? 1 : 0, .pSignalSemaphores = &t->present[index]};
    queue_lock(t,t->family,0);
    VK(vkQueueSubmit(t->queue, 1, &submit, t->fence));
    if (t->swapchain) {
        VkPresentInfoKHR present = {.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .waitSemaphoreCount = 1, .pWaitSemaphores = &t->present[index],
            .swapchainCount = 1, .pSwapchains = &t->swapchain, .pImageIndices = &index};
        VkResult r = vkQueuePresentKHR(t->queue, &present);
        CHECK(r == VK_SUCCESS || r == VK_SUBOPTIMAL_KHR);
    }
    queue_unlock(t,t->family,0);
    mpv_render_context_report_swap(t->render);
    if (read) {
        VK(vkWaitForFences(t->device, 1, &t->fence, VK_TRUE, 10000000000ULL));
        pixels(t, capture);
    }
    target->input_layout = t->swapchain ? VK_IMAGE_LAYOUT_PRESENT_SRC_KHR : target->output_layout;
    pump(t);
}

static void drop_targets(struct test *t)
{
    VK(vkWaitForFences(t->device, 1, &t->fence, VK_TRUE, 10000000000ULL));
    queue_lock(t,t->family,0);
    VK(vkQueueWaitIdle(t->queue));
    queue_unlock(t,t->family,0);
    for (uint32_t i = 0; i < t->count; i++) {
        if (t->targets[i].state == MPV_VULKAN_TARGET_RETURNED) {
            mpv_vulkan_retire_target retire = {.version = MPV_VULKAN_DRAFT_VERSION,
                .image = t->targets[i].image, .generation = t->targets[i].generation};
            CHECK(mpv_render_context_set_parameter(t->render,
                (mpv_render_param){MPV_RENDER_PARAM_VULKAN_RETIRE_TARGET,&retire}) == 0);
        }
        vkDestroySemaphore(t->device, t->present[i], NULL);
    }
    vkUnmapMemory(t->device, t->buffer_memory);
    vkDestroyBuffer(t->device, t->buffer, NULL);
    vkFreeMemory(t->device, t->buffer_memory, NULL);
    if (t->swapchain) vkDestroySwapchainKHR(t->device, t->swapchain, NULL);
    else {
        vkDestroyImage(t->device, t->targets[0].image, NULL);
        vkFreeMemory(t->device, t->image_memory, NULL);
    }
    memset(t->targets, 0, sizeof(t->targets));
    t->swapchain = VK_NULL_HANDLE;
    t->count = 0;
}

static void make_targets(struct test *t)
{
    VkImage images[8]; t->count = 1;
    CAMetalLayer *layer = t->layer;
    t->format = t->pq ? VK_FORMAT_A2B10G10R10_UNORM_PACK32 : VK_FORMAT_R8G8B8A8_UNORM;
    VkColorSpaceKHR color_space = t->pq ? VK_COLOR_SPACE_HDR10_ST2084_EXT : VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;
    VkImageUsageFlags usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT|VK_IMAGE_USAGE_TRANSFER_DST_BIT|VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    if (t->surface) {
        VkSurfaceCapabilitiesKHR caps;
        VK(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(t->physical, t->surface, &caps));
        CHECK((caps.supportedUsageFlags & usage) == usage);
        uint32_t n = 0;
        VK(vkGetPhysicalDeviceSurfaceFormatsKHR(t->physical, t->surface, &n, NULL));
        VkSurfaceFormatKHR *formats = calloc(n, sizeof(*formats)); CHECK(formats);
        VK(vkGetPhysicalDeviceSurfaceFormatsKHR(t->physical, t->surface, &n, formats));
        bool found = false;
        VkFormat preferred[] = {t->pq ? VK_FORMAT_A2B10G10R10_UNORM_PACK32 : VK_FORMAT_B8G8R8A8_UNORM,
            t->pq ? VK_FORMAT_A2R10G10B10_UNORM_PACK32 : VK_FORMAT_R8G8B8A8_UNORM};
        for (uint32_t i = 0; i < n; i++)
            fprintf(stderr, "SURFACE_FORMAT=%d COLORSPACE=%d\n", formats[i].format, formats[i].colorSpace);
        for (unsigned choice = 0; choice < 2 && !found; choice++)
            for (uint32_t i = 0; i < n; i++)
                if (formats[i].format == preferred[choice] && formats[i].colorSpace == color_space) {
                    t->format = formats[i].format; found = true; break;
                }
        free(formats); CHECK(found);
        if (caps.currentExtent.width != UINT32_MAX) { t->width = caps.currentExtent.width; t->height = caps.currentExtent.height; }
        uint32_t requested = caps.minImageCount > 3 ? caps.minImageCount : 3;
        if (caps.maxImageCount && requested > caps.maxImageCount) requested = caps.maxImageCount;
        VkCompositeAlphaFlagBitsKHR alpha = caps.supportedCompositeAlpha & VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR ?
            VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR : VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR;
        CHECK(caps.supportedCompositeAlpha & alpha);
        VkSwapchainCreateInfoKHR sc = {.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .surface = t->surface, .minImageCount = requested, .imageFormat = t->format,
            .imageColorSpace = color_space, .imageExtent = {t->width,t->height},
            .imageArrayLayers = 1, .imageUsage = usage, .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
            .preTransform = caps.currentTransform, .compositeAlpha = alpha, .presentMode = VK_PRESENT_MODE_FIFO_KHR, .clipped = VK_TRUE};
        VK(vkCreateSwapchainKHR(t->device, &sc, NULL, &t->swapchain));
        VK(vkGetSwapchainImagesKHR(t->device, t->swapchain, &t->count, NULL)); CHECK(t->count <= 8);
        VK(vkGetSwapchainImagesKHR(t->device, t->swapchain, &t->count, images));
        dispatch_sync(dispatch_get_main_queue(), ^{
            if (@available(iOS 16.0, *)) {
                CHECK(!t->pq || UIScreen.mainScreen.potentialEDRHeadroom > 1);
                layer.wantsExtendedDynamicRangeContent = t->pq;
                layer.EDRMetadata = nil;
            } else CHECK(!t->pq);
            CGColorSpaceRef space = CGColorSpaceCreateWithName(t->pq ? kCGColorSpaceITUR_2100_PQ : kCGColorSpaceSRGB);
            CHECK(space); layer.colorspace = space; CGColorSpaceRelease(space);
        });
        report_display(layer);
    } else {
        VkImageCreateInfo image = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .imageType = VK_IMAGE_TYPE_2D, .format = t->format, .extent = {t->width,t->height,1},
            .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT,
            .tiling = VK_IMAGE_TILING_OPTIMAL, .usage = usage, .sharingMode = VK_SHARING_MODE_EXCLUSIVE};
        VK(vkCreateImage(t->device, &image, NULL, images));
        VkMemoryRequirements mr; vkGetImageMemoryRequirements(t->device, images[0], &mr);
        VkMemoryAllocateInfo ma = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = mr.size, .memoryTypeIndex = memory_type(t, mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)};
        VK(vkAllocateMemory(t->device, &ma, NULL, &t->image_memory));
        VK(vkBindImageMemory(t->device, images[0], t->image_memory, 0));
    }
    ++t->generation;
    for (uint32_t i = 0; i < t->count; i++)
        t->targets[i] = (mpv_vulkan_target){.version = MPV_VULKAN_DRAFT_VERSION, .generation = t->generation,
            .image = images[i], .format = t->format, .width = t->width, .height = t->height, .usage = usage};
    VkSemaphoreCreateInfo sem = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    for (uint32_t i = 0; i < t->count; i++) VK(vkCreateSemaphore(t->device, &sem, NULL, &t->present[i]));
    VkBufferCreateInfo buffer = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = (VkDeviceSize)t->width * t->height * 4, .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT};
    VK(vkCreateBuffer(t->device, &buffer, NULL, &t->buffer));
    VkMemoryRequirements mr; vkGetBufferMemoryRequirements(t->device, t->buffer, &mr);
    VkMemoryAllocateInfo ma = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size,
        .memoryTypeIndex = memory_type(t, mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)};
    VK(vkAllocateMemory(t->device, &ma, NULL, &t->buffer_memory));
    VK(vkBindBufferMemory(t->device, t->buffer, t->buffer_memory, 0));
    VK(vkMapMemory(t->device, t->buffer_memory, 0, VK_WHOLE_SIZE, 0, (void **)&t->pixels));
}

static void window_state(struct test *t)
{
    if (!t->surface) return;
    bool active;
    uint32_t width, height;
    pthread_mutex_lock(&ui_mutex);
    active = ui_active; width = ui_width; height = ui_height;
    pthread_mutex_unlock(&ui_mutex);
    bool resumed = !active;
    if (resumed) {
        pump(t);
        bool paused = t->paused;
        command(t,(const char *[]){"set","pause","yes",NULL});
        double started = CACurrentMediaTime();
        fprintf(stderr,"IOS_BACKGROUND=1\n");
        while (!active) {
            pump(t); usleep(10000);
            pthread_mutex_lock(&ui_mutex);
            active = ui_active; width = ui_width; height = ui_height;
            pthread_mutex_unlock(&ui_mutex);
        }
        t->background_seconds += CACurrentMediaTime()-started;
        command(t,(const char *[]){"set","pause",paused ? "yes" : "no",NULL});
        t->resumes++;
        fprintf(stderr,"IOS_RESUME=%u\n",t->resumes);
    }
    if (width && height && (resumed || width != t->width || height != t->height)) {
        drop_targets(t);
        make_targets(t);
        fprintf(stderr,"IOS_TARGET_REBUILT=%ux%u GENERATION=%llu\n",t->width,t->height,(unsigned long long)t->generation);
    }
}

static void run(CAMetalLayer *layer, unsigned context)
{
    struct test t = {.width = 640, .height = 360, .layer = layer, .paused = true};
    atomic_init(&t.dirty, false);
    CHECK(pthread_mutex_init(&t.mutex, NULL) == 0);
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    bool window = [args containsObject:@"--window"];
    NSString *media = @"sdr";
    NSString *file_name = nil;
    NSString *output = @"sdr";
    double hold_seconds = 0;
    NSString *hwdec = @"no";
    t.pts = -1; t.audio_pts = t.avsync = NAN;
    bool require_validation = [args containsObject:@"--require-validation"];
    NSString *case_id = @"result";
    for (NSString *arg in args) {
        if ([arg hasPrefix:@"--media="]) media = [arg substringFromIndex:8];
        if ([arg hasPrefix:@"--output="]) output = [arg substringFromIndex:9];
        if ([arg hasPrefix:@"--hold-seconds="]) hold_seconds = [arg substringFromIndex:15].doubleValue;
        if ([arg hasPrefix:@"--hwdec="]) hwdec = [arg substringFromIndex:8];
        if ([arg hasPrefix:@"--play-seconds="]) t.play_seconds = [arg substringFromIndex:15].doubleValue;
        if ([arg hasPrefix:@"--case-id="]) case_id = [arg substringFromIndex:10];
        if ([arg hasPrefix:@"--file="]) file_name = [arg substringFromIndex:7];
    }
    t.hwdec = hwdec.UTF8String;
    CHECK(([@[@"sdr", @"hdr10", @"dv-p5", @"av", @"sync"] containsObject:media]));
    CHECK(!strcmp(t.hwdec,"no") || !strcmp(t.hwdec,"videotoolbox-copy") || !strcmp(t.hwdec,"videotoolbox"));
    CHECK(t.play_seconds >= 0 && t.play_seconds <= 600 && (!t.play_seconds || (window && !hold_seconds)));
    CHECK(case_id.length && [case_id rangeOfCharacterFromSet:
        [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"] invertedSet]].location == NSNotFound);
    CHECK(([@[@"sdr", @"pq"] containsObject:output]));
    CHECK(hold_seconds >= 0 && hold_seconds <= 60 && (!hold_seconds || window));
    t.pq = [output isEqualToString:@"pq"];
    NSString *file = [NSBundle.mainBundle pathForResource:[media stringByAppendingString:@"-20s"] ofType:@"mkv"];
    if (file_name) {
        CHECK([file_name isEqualToString:file_name.lastPathComponent] && [file_name.pathExtension isEqualToString:@"mkv"]);
        file = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
            stringByAppendingPathComponent:file_name];
    }
    CHECK(file);
    fprintf(stderr, "IOS_SMOKE MEDIA=%s WINDOW=%d OUTPUT=%s VALIDATION=NOT_ENABLED\n", media.UTF8String, window, output.UTF8String);
    uint32_t layer_count = 0;
    VK(vkEnumerateInstanceLayerProperties(&layer_count, NULL));
    fprintf(stderr, "VULKAN_LAYER_COUNT=%u VALIDATION=NOT_ENABLED\n", layer_count);
    if (require_validation) { fprintf(stderr, "IOS_SETUP_ERROR=matching_validation_loader_required\n"); exit(2); }
    const char *instance_ext[4] = {VK_KHR_SURFACE_EXTENSION_NAME, VK_EXT_METAL_SURFACE_EXTENSION_NAME};
    uint32_t instance_count = 0, enabled_instance_count = 2;
    VK(vkEnumerateInstanceExtensionProperties(NULL, &instance_count, NULL));
    VkExtensionProperties *instance_properties = calloc(instance_count, sizeof(*instance_properties)); CHECK(instance_properties);
    VK(vkEnumerateInstanceExtensionProperties(NULL, &instance_count, instance_properties));
    bool portability_enumeration = false, swapchain_colorspace = false;
    for (uint32_t i = 0; i < instance_count; i++) {
        portability_enumeration |= !strcmp(instance_properties[i].extensionName, VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);
        swapchain_colorspace |= !strcmp(instance_properties[i].extensionName, VK_EXT_SWAPCHAIN_COLOR_SPACE_EXTENSION_NAME);
    }
    free(instance_properties);
    if (portability_enumeration) instance_ext[enabled_instance_count++] = VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME;
    if (swapchain_colorspace) instance_ext[enabled_instance_count++] = VK_EXT_SWAPCHAIN_COLOR_SPACE_EXTENSION_NAME;
    if (t.pq && window) CHECK(swapchain_colorspace);
    VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "iOS libmpv smoke", .apiVersion = VK_API_VERSION_1_2};
    VkInstanceCreateInfo instance = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .flags = portability_enumeration ? VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR : 0, .pApplicationInfo = &app,
        .enabledExtensionCount = enabled_instance_count, .ppEnabledExtensionNames = instance_ext};
    VkExportMetalObjectCreateInfoEXT export_device = {
        .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECT_CREATE_INFO_EXT,
        .exportObjectType = VK_EXPORT_METAL_OBJECT_TYPE_METAL_DEVICE_BIT_EXT};
    bool direct = !strcmp(t.hwdec, "videotoolbox");
    if (direct) instance.pNext = &export_device;
    VK(vkCreateInstance(&instance, NULL, &t.instance));
    uint32_t count = 0;
    VK(vkEnumeratePhysicalDevices(t.instance, &count, NULL)); CHECK(count);
    VkPhysicalDevice *devices = calloc(count, sizeof(*devices)); CHECK(devices);
    VK(vkEnumeratePhysicalDevices(t.instance, &count, devices)); t.physical = devices[0]; free(devices);
    VkPhysicalDeviceProperties properties;
    vkGetPhysicalDeviceProperties(t.physical, &properties);
    fprintf(stderr, "DEVICE=%s VULKAN=%u.%u.%u CLIENT_API=%lu\n", properties.deviceName,
        VK_API_VERSION_MAJOR(properties.apiVersion), VK_API_VERSION_MINOR(properties.apiVersion),
        VK_API_VERSION_PATCH(properties.apiVersion), mpv_client_api_version());
    CHECK(properties.apiVersion >= VK_API_VERSION_1_2);
    if (window) {
        VkMetalSurfaceCreateInfoEXT surface = {.sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT,
            .pLayer = layer};
        VK(vkCreateMetalSurfaceEXT(t.instance, &surface, NULL, &t.surface));
    }
    vkGetPhysicalDeviceQueueFamilyProperties(t.physical, &count, NULL);
    VkQueueFamilyProperties *queues = calloc(count, sizeof(*queues)); CHECK(queues);
    vkGetPhysicalDeviceQueueFamilyProperties(t.physical, &count, queues);
    t.family = UINT32_MAX;
    for (uint32_t i = 0; i < count; i++) {
        VkBool32 present = VK_TRUE;
        if (window) VK(vkGetPhysicalDeviceSurfaceSupportKHR(t.physical, i, t.surface, &present));
        if ((queues[i].queueFlags & (VK_QUEUE_GRAPHICS_BIT|VK_QUEUE_COMPUTE_BIT)) ==
            (VK_QUEUE_GRAPHICS_BIT|VK_QUEUE_COMPUTE_BIT) && present) { t.family = i; break; }
    }
    free(queues); CHECK(t.family != UINT32_MAX);
    VkPhysicalDeviceSynchronization2Features sync2 = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES};
    VkPhysicalDeviceVulkan12Features f12 = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, .pNext = &sync2};
    VkPhysicalDeviceFeatures2 features = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &f12};
    vkGetPhysicalDeviceFeatures2(t.physical, &features);
    CHECK(f12.hostQueryReset && f12.timelineSemaphore && sync2.synchronization2);
    const char *ext[4] = {VK_KHR_SYNCHRONIZATION_2_EXTENSION_NAME, "VK_KHR_portability_subset"};
    unsigned ext_count = 2;
    if (window) ext[ext_count++] = VK_KHR_SWAPCHAIN_EXTENSION_NAME;
    if (direct) {
        uint32_t n = 0;
        VK(vkEnumerateDeviceExtensionProperties(t.physical, NULL, &n, NULL));
        VkExtensionProperties *p = calloc(n, sizeof(*p)); CHECK(p);
        VK(vkEnumerateDeviceExtensionProperties(t.physical, NULL, &n, p));
        bool supported = false;
        for (uint32_t i = 0; i < n; i++) supported |= !strcmp(p[i].extensionName, VK_EXT_METAL_OBJECTS_EXTENSION_NAME);
        free(p);
        if (!supported) {
            fprintf(stderr, "IOS_UNSUPPORTED=metal_objects\n");
            if (t.surface) vkDestroySurfaceKHR(t.instance, t.surface, NULL);
            vkDestroyInstance(t.instance, NULL);
            pthread_mutex_destroy(&t.mutex);
            exit(77);
        }
        ext[ext_count++] = VK_EXT_METAL_OBJECTS_EXTENSION_NAME;
    }
    float priority = 1;
    VkDeviceQueueCreateInfo queue = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = t.family, .queueCount = 1, .pQueuePriorities = &priority};
    VkDeviceCreateInfo device = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &features,
        .queueCreateInfoCount = 1, .pQueueCreateInfos = &queue,
        .enabledExtensionCount = ext_count, .ppEnabledExtensionNames = ext};
    VK(vkCreateDevice(t.physical, &device, NULL, &t.device));
    vkGetDeviceQueue(t.device, t.family, 0, &t.queue);
    t.mpv = mpv_create(); CHECK(t.mpv);
    if (direct) CHECK(mpv_set_option_string(t.mpv, "gpu-hwdec-interop", "videotoolbox") == 0);
    const char *opts[][2] = {{"config","no"},{"vo","libmpv"},{"hwdec",t.hwdec},{"audio",t.play_seconds ? "auto" : "no"},
        {"pause","yes"},{"keep-open","yes"},{"idle","yes"},{"video-sync",t.play_seconds ? "audio" : "desync"},
        {"ao","audiounit"},{"audio-channels","stereo"},{"audio-spdif",""},{"volume","50"},
        {"target-prim",t.pq ? "bt.2020" : "bt.709"},{"target-trc",t.pq ? "pq" : "srgb"},{"target-peak",t.pq ? "500" : "100"},
        {"icc-profile-auto","no"},{"hdr-compute-peak","no"},{"interpolation","no"},
        {"temporal-dither","no"},{"treat-srgb-as-power22","no"},{"osd-level","0"},{"sub","no"},
        {"screenshot-sw","no"},{"screenshot-high-bit-depth",t.pq ? "yes" : "no"},{"start","1"}};
    for (unsigned i = 0; i < sizeof(opts)/sizeof(opts[0]); i++)
        CHECK(mpv_set_option_string(t.mpv, opts[i][0], opts[i][1]) == 0);
    CHECK(mpv_initialize(t.mpv) == 0);
    CHECK(mpv_request_log_messages(t.mpv, "v") == 0);
    const char *observed[] = {"time-pos","audio-pts","avsync","vo-configured","hwdec-current","current-ao","pause"};
    mpv_format formats[] = {MPV_FORMAT_DOUBLE,MPV_FORMAT_DOUBLE,MPV_FORMAT_DOUBLE,MPV_FORMAT_FLAG,MPV_FORMAT_STRING,MPV_FORMAT_STRING,MPV_FORMAT_FLAG};
    for (unsigned i = 0; i < sizeof(observed)/sizeof(observed[0]); i++)
        CHECK(mpv_observe_property(t.mpv, i+1, observed[i], formats[i]) == 0);
    mpv_vulkan_init_params init = {.version = MPV_VULKAN_DRAFT_VERSION,
        .instance_api_version = VK_API_VERSION_1_2, .instance = t.instance,
        .physical_device = t.physical, .device = t.device, .get_proc_address = vkGetInstanceProcAddr,
        .features = &features, .extensions = ext, .num_extensions = ext_count,
        .queue_family = t.family, .lock_queue = queue_lock, .unlock_queue = queue_unlock, .queue_context = &t};
    int advanced = 1;
    mpv_render_param params[] = {{MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_VULKAN},
        {MPV_RENDER_PARAM_RENDERER, "gpu-next"}, {MPV_RENDER_PARAM_VULKAN_INIT_PARAMS, &init},
        {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced}, {0}};
    CHECK(mpv_render_context_create(&t.render, t.mpv, params) == 0);
    mpv_render_context_set_update_callback(t.render, wakeup, &t.dirty);
    VkCommandPoolCreateInfo pool = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = t.family};
    VK(vkCreateCommandPool(t.device, &pool, NULL, &t.pool));
    VkCommandBufferAllocateInfo cb = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = t.pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
    VK(vkAllocateCommandBuffers(t.device, &cb, &t.command));
    VkFenceCreateInfo fence = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, .flags = VK_FENCE_CREATE_SIGNALED_BIT};
    VK(vkCreateFence(t.device, &fence, NULL, &t.fence));
    VkSemaphoreTypeCreateInfo type = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO,
        .semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE};
    VkSemaphoreCreateInfo sem = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, .pNext = window ? NULL : &type};
    VK(vkCreateSemaphore(t.device, &sem, NULL, &t.complete)); sem.pNext = NULL;
    VK(vkCreateSemaphore(t.device, &sem, NULL, &t.acquire));
    make_targets(&t);
    t.expect_black = true;
    draw(&t, nil, true);
    t.expect_black = false;
    command(&t, (const char *[]){"loadfile",file.fileSystemRepresentation,NULL});
    wait_frame(&t);
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    documents = [documents stringByAppendingPathComponent:case_id];
    documents = [documents stringByAppendingPathComponent:[NSString stringWithFormat:@"context-%02u",context]];
    CHECK(![NSFileManager.defaultManager fileExistsAtPath:documents]);
    CHECK([NSFileManager.defaultManager createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:nil]);
    NSString *capture = [documents stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@-%@.%@",media,output,
        window ? @"window" : @"offscreen", t.pq ? @"rgb10a2" : @"ppm"]];
    draw(&t, capture, true);
    NSString *screenshot = [capture stringByAppendingString:@".png"];
    if (!t.pq) {
        t.raw_capture = [capture stringByAppendingString:@"-gpu-raw.ppm"];
        command(&t,(const char *[]){"screenshot-raw","window","rgba",NULL});
    }
    command(&t, (const char *[]){"screenshot-to-file",screenshot.fileSystemRepresentation,"window",NULL});
    if ([args containsObject:@"--stress"]) {
        for (int i = 0; i < 20; i++) {
            command(&t,(const char *[]){"loadfile",file.fileSystemRepresentation,NULL});
            wait_frame(&t); draw(&t,nil,true);
        }
        fprintf(stderr,"IOS_LOADS=20 PASS\n");
        for (int i = 0; i < 20; i++) {
            unsigned restart = t.restarts;
            command(&t,(const char *[]){"seek",i%2 ? "2" : "3","absolute+exact",NULL});
            double deadline = CACurrentMediaTime() + 15;
            unsigned skipped = 0;
            while (t.restarts == restart) {
                pump(&t);
                if (t.restarts != restart) break;
                mpv_render_frame_info info = {0};
                CHECK(mpv_render_context_get_info(t.render,
                    (mpv_render_param){MPV_RENDER_PARAM_NEXT_FRAME_INFO,&info}) == 0);
                if (info.flags & MPV_RENDER_FRAME_INFO_PRESENT) {
                    int skip = 1, block = 0;
                    mpv_render_param ps[] = {{MPV_RENDER_PARAM_SKIP_RENDERING,&skip},
                        {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME,&block},{0}};
                    CHECK(mpv_render_context_render(t.render,ps) == 0);
                    mpv_render_context_report_swap(t.render);
                    skipped++;
                } else usleep(1000);
                CHECK(CACurrentMediaTime() < deadline);
            }
            CHECK(skipped);
            NSString *shot = [documents stringByAppendingPathComponent:[NSString stringWithFormat:@"skip-%02d.png",i]];
            command(&t,(const char *[]){"screenshot-to-file",shot.fileSystemRepresentation,"window",NULL});
            draw(&t,[documents stringByAppendingPathComponent:[NSString stringWithFormat:@"skip-%02d.%@",i,t.pq ? @"rgb10a2" : @"ppm"]],true);
            CHECK(fabs(t.pts - (i%2 ? 2 : 3)) < 0.05);
        }
        fprintf(stderr,"IOS_SEEK_SKIP_SCREENSHOTS=20 PASS\n");
        if (window && [args containsObject:@"--rotate"]) {
            for (int i = 0; i < 10; i++) {
                uint32_t old_width = t.width;
                bool landscape = t.width < t.height;
                dispatch_sync(dispatch_get_main_queue(), ^{
                    if (@available(iOS 16.0, *)) {
                        UIView *view = (UIView *)layer.delegate;
                        CHECK([view isKindOfClass:UIView.class] && view.window.windowScene);
                        UIWindowSceneGeometryPreferencesIOS *geometry = [[UIWindowSceneGeometryPreferencesIOS alloc]
                            initWithInterfaceOrientations:landscape ? UIInterfaceOrientationMaskLandscapeRight : UIInterfaceOrientationMaskPortrait];
                        [view.window.windowScene requestGeometryUpdateWithPreferences:geometry errorHandler:^(NSError *error) {
                            fprintf(stderr,"IOS_ROTATION_ERROR=%s\n",error.description.UTF8String);
                        }];
                    } else CHECK(false);
                });
                double deadline = CACurrentMediaTime() + 10;
                do { window_state(&t); usleep(10000); CHECK(CACurrentMediaTime()<deadline); } while(t.width == old_width);
                draw(&t,nil,true);
                fprintf(stderr,"IOS_ROTATION=%d SIZE=%ux%u\n",i,t.width,t.height);
            }
        }
    }
    pump(&t);
    double initial = t.pts, final = -1;
    CHECK(initial >= 0);
    if (window) {
        command(&t, (const char *[]){"set","pause","no",NULL});
        if (t.play_seconds) {
            double started = CACurrentMediaTime(), next_metric = started, last_audio = started, last_video = started, bad_sync = 0;
            double old_audio = NAN, old_video = -1;
            unsigned resumes = t.resumes;
            while (CACurrentMediaTime() - started - t.background_seconds < t.play_seconds) {
                wait_frame(&t); draw(&t, nil, false);
                double now = CACurrentMediaTime();
                if (resumes != t.resumes) { last_audio = last_video = now; bad_sync = 0; resumes = t.resumes; }
                if (isfinite(t.audio_pts) && (!isfinite(old_audio) || t.audio_pts > old_audio)) last_audio = now;
                if (t.pts > old_video) last_video = now;
                old_audio = t.audio_pts; old_video = t.pts;
                if (now >= next_metric) {
                    fprintf(stderr, "METRIC ELAPSED=%.3f PTS=%.6f AUDIO_PTS=%.6f AVSYNC=%.6f DECODER=%s AUDIO=%d\n",
                        now-started,t.pts,t.audio_pts,t.avsync,t.decoder,t.audio_seen);
                    next_metric = now + 1;
                }
                if (now - started > 5) {
                    CHECK(now-last_audio <= 5 && now-last_video <= 5);
                    CHECK(!strcmp(t.decoder,t.hwdec) && t.audio_seen);
                    if (isfinite(t.avsync) && fabs(t.avsync) > 0.1) {
                        if (!bad_sync) bad_sync = now;
                        CHECK(now - bad_sync < 5);
                    } else bad_sync = 0;
                }
                CHECK(!t.ended);
            }
            fprintf(stderr, "IOS_PLAYBACK=PASS SECONDS=%.3f REQUESTED=%.3f\n",CACurrentMediaTime()-started,t.play_seconds);
            dispatch_sync(dispatch_get_main_queue(), ^{
                AVAudioSession *session = AVAudioSession.sharedInstance;
                for (AVAudioSessionPortDescription *port in session.currentRoute.outputs)
                    fprintf(stderr, "AUDIO_ROUTE=%s TYPE=%s SAMPLE_RATE=%.0f CHANNELS=%ld\n",port.portName.UTF8String,
                        port.portType.UTF8String,session.sampleRate,(long)session.outputNumberOfChannels);
            });
        } else for (int i = 0; i < 24; i++) { wait_frame(&t); draw(&t, nil, false); }
        pump(&t);
        final = t.pts;
        CHECK(final > initial + 0.5);
        report_display(layer);
        if (hold_seconds) {
            command(&t, (const char *[]){"set","pause","yes",NULL});
            double deadline = CACurrentMediaTime() + hold_seconds;
            while (CACurrentMediaTime() < deadline) { usleep(100000); pump(&t); }
            report_display(layer);
        }
    }
    pump(&t);
    fprintf(stderr, "DECODER=%s PTS_INITIAL=%.6f PTS_FINAL=%.6f\n", t.decoder, initial, final);
    CHECK(!strcmp(t.decoder, t.hwdec));
    command(&t, (const char *[]){"stop",NULL});
    double detach_deadline = CACurrentMediaTime() + 10;
    do { pump(&t); CHECK(CACurrentMediaTime() < detach_deadline); usleep(1000); } while (t.loaded || t.configured);
    t.expect_black = true;
    draw(&t, nil, true);
    drop_targets(&t);
    mpv_render_context_free(t.render);
    mpv_terminate_destroy(t.mpv);
    vkDestroyFence(t.device, t.fence, NULL); vkDestroyCommandPool(t.device, t.pool, NULL);
    vkDestroySemaphore(t.device, t.acquire, NULL); vkDestroySemaphore(t.device, t.complete, NULL);
    vkDestroyDevice(t.device, NULL);
    if (t.surface) vkDestroySurfaceKHR(t.instance, t.surface, NULL);
    vkDestroyInstance(t.instance, NULL); pthread_mutex_destroy(&t.mutex);
    fprintf(stderr, "IOS_RESULT=PASS MEDIA=%s MODE=%s CAPTURE=%s OUTPUT=%s HWDEC=%s CASE_ID=%s\n", media.UTF8String,
        window ? "window" : "offscreen", capture.UTF8String, output.UTF8String,t.hwdec,case_id.UTF8String);
    fflush(stderr);
}

@interface VideoView : UIView @end
@implementation VideoView
+ (Class)layerClass { return CAMetalLayer.class; }
- (void)layoutSubviews
{
    [super layoutSubviews];
    CAMetalLayer *layer = (CAMetalLayer *)self.layer;
    layer.drawableSize = CGSizeMake(self.bounds.size.width * self.contentScaleFactor,
        self.bounds.size.height * self.contentScaleFactor);
    pthread_mutex_lock(&ui_mutex);
    ui_width = layer.drawableSize.width; ui_height = layer.drawableSize.height;
    pthread_mutex_unlock(&ui_mutex);
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation AppDelegate
- (void)applicationDidBecomeActive:(UIApplication *)application
{
    pthread_mutex_lock(&ui_mutex); ui_active = true; pthread_mutex_unlock(&ui_mutex);
}
- (void)applicationWillResignActive:(UIApplication *)application
{
    pthread_mutex_lock(&ui_mutex); ui_active = false; pthread_mutex_unlock(&ui_mutex);
}
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options
{
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *controller = [UIViewController new];
    VideoView *view = [[VideoView alloc] initWithFrame:self.window.bounds];
    controller.view = view; self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    CAMetalLayer *layer = (CAMetalLayer *)view.layer;
    view.contentScaleFactor = UIScreen.mainScreen.scale;
    layer.contentsScale = UIScreen.mainScreen.scale;
    layer.drawableSize = CGSizeMake(view.bounds.size.width * layer.contentsScale,
        view.bounds.size.height * layer.contentsScale);
    layer.framebufferOnly = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            unsigned contexts = 1;
            NSString *case_id = @"result";
            for (NSString *arg in NSProcessInfo.processInfo.arguments) {
                if ([arg hasPrefix:@"--contexts="]) contexts = [arg substringFromIndex:11].intValue;
                if ([arg hasPrefix:@"--case-id="]) case_id = [arg substringFromIndex:10];
            }
            CHECK(contexts >= 1 && contexts <= 20);
            for (unsigned i = 0; i < contexts; i++) run(layer,i);
            fprintf(stderr, "IOS_CONTEXTS=%u PASS CASE_ID=%s\n",contexts,case_id.UTF8String);
            exit(0);
        }
    });
    return YES;
}
@end

int main(int argc, char **argv)
{
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class)); }
}
