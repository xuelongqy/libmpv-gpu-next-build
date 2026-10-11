#include <Metal/Metal.h>
#define VK_USE_PLATFORM_METAL_EXT
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned errors, unbound_errors, invalid_view_errors;
static unsigned waw_errors, raw_errors;
static bool invalid_view, sync_test;

static VKAPI_ATTR VkBool32 VKAPI_CALL debug_message(
    VkDebugUtilsMessageSeverityFlagBitsEXT severity,
    VkDebugUtilsMessageTypeFlagsEXT type,
    const VkDebugUtilsMessengerCallbackDataEXT *data, void *opaque)
{
    (void)type;
    (void)opaque;
    if (severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) {
        errors++;
        if (data->pMessageIdName &&
            !strcmp(data->pMessageIdName, "VUID-VkImageViewCreateInfo-image-01020"))
            unbound_errors++;
        fprintf(stderr, "%s\n", data->pMessage);
        if (data->pMessageIdName && !strcmp(data->pMessageIdName, "SYNC-HAZARD-WRITE-AFTER-WRITE")) {
            waw_errors++;
            if (sync_test) return VK_TRUE;
        }
        if (data->pMessageIdName && !strcmp(data->pMessageIdName, "SYNC-HAZARD-READ-AFTER-WRITE")) {
            raw_errors++;
            if (sync_test) return VK_TRUE;
        }
        if (invalid_view && data->pMessageIdName &&
            !strcmp(data->pMessageIdName, "VUID-VkImageSubresourceRange-levelCount-01720")) {
            invalid_view_errors++;
            return VK_TRUE; // Abort the invalid view before it reaches the driver.
        }
    }
    return VK_FALSE;
}

#define CHECK(call) do { VkResult result = (call); if (result != VK_SUCCESS) { \
    fprintf(stderr, "%s: %d\n", #call, result); \
    status = result == VK_ERROR_EXTENSION_NOT_PRESENT ? 77 : 2; goto done; \
} } while (0)


static int image_sync(VkDevice device, VkImage image, VkImage destination, uint32_t family,
                      bool missing_barrier, bool expect_hazard, const char *kind)
{
    int status = 0;
    VkCommandPool pool = VK_NULL_HANDLE;
    unsigned before = errors;
    unsigned before_waw = waw_errors;
    if (!destination) destination = image;
    VkCommandPoolCreateInfo pci = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = family};
    CHECK(vkCreateCommandPool(device, &pci, NULL, &pool));
    VkCommandBufferAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
    VkCommandBuffer command;
    CHECK(vkAllocateCommandBuffers(device, &ai, &command));
    VkCommandBufferBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    CHECK(vkBeginCommandBuffer(command, &bi));
    VkImageSubresourceRange range = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    VkImageMemoryBarrier transition = {.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = VK_IMAGE_LAYOUT_GENERAL, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = image, .subresourceRange = range};
    vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
        0, 0, NULL, 0, NULL, 1, &transition);
    if (destination != image) {
        transition.image = destination;
        vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
            0, 0, NULL, 0, NULL, 1, &transition);
    }
    VkClearColorValue color = {.float32 = {0.5, 0.5, 0.5, 1}};
    vkCmdClearColorImage(command, image, VK_IMAGE_LAYOUT_GENERAL, &color, 1, &range);
    VkMemoryBarrier barrier = {.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT};
    if (!missing_barrier)
        vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
            0, 1, &barrier, 0, NULL, 0, NULL);
    sync_test = missing_barrier;
    vkCmdClearColorImage(command, destination, VK_IMAGE_LAYOUT_GENERAL, &color, 1, &range);
    sync_test = false;
    CHECK(vkEndCommandBuffer(command));
    printf("CASE=%s-sync-%s ERRORS=%u EXPECTED=%u\n", kind,
        missing_barrier ? "negative" : "positive", errors-before, expect_hazard ? 1u : 0u);
    if (errors-before != (expect_hazard ? 1u : 0u) ||
        waw_errors-before_waw != (expect_hazard ? 1u : 0u)) status = 1;
done:
    if (pool) vkDestroyCommandPool(device, pool, NULL);
    return status;
}

static int image_read_sync(VkPhysicalDevice physical, VkDevice device, VkImage image, uint32_t family,
                           bool missing_barrier, const char *kind)
{
    int status = 0;
    VkCommandPool pool = VK_NULL_HANDLE;
    VkBuffer buffer = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    unsigned before = errors, before_raw = raw_errors;
    VkBufferCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = 1024, .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT};
    CHECK(vkCreateBuffer(device, &ci, NULL, &buffer));
    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(device, buffer, &req);
    VkPhysicalDeviceMemoryProperties props;
    vkGetPhysicalDeviceMemoryProperties(physical, &props);
    uint32_t type = 0;
    while (type < props.memoryTypeCount && !(req.memoryTypeBits & (1u << type))) type++;
    if (type == props.memoryTypeCount) { status = 2; goto done; }
    VkMemoryAllocateInfo allocation = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = req.size, .memoryTypeIndex = type};
    CHECK(vkAllocateMemory(device, &allocation, NULL, &memory));
    CHECK(vkBindBufferMemory(device, buffer, memory, 0));
    VkCommandPoolCreateInfo pci = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = family};
    CHECK(vkCreateCommandPool(device, &pci, NULL, &pool));
    VkCommandBufferAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
    VkCommandBuffer command;
    CHECK(vkAllocateCommandBuffers(device, &ai, &command));
    VkCommandBufferBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    CHECK(vkBeginCommandBuffer(command, &bi));
    VkImageSubresourceRange range = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    VkImageMemoryBarrier transition = {.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = VK_IMAGE_LAYOUT_GENERAL, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = image, .subresourceRange = range};
    vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
        0, 0, NULL, 0, NULL, 1, &transition);
    VkClearColorValue color = {.float32 = {0.5, 0.5, 0.5, 1}};
    vkCmdClearColorImage(command, image, VK_IMAGE_LAYOUT_GENERAL, &color, 1, &range);
    VkMemoryBarrier barrier = {.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT};
    if (!missing_barrier)
        vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
            0, 1, &barrier, 0, NULL, 0, NULL);
    VkBufferImageCopy copy = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {16, 16, 1}};
    sync_test = missing_barrier;
    vkCmdCopyImageToBuffer(command, image, VK_IMAGE_LAYOUT_GENERAL, buffer, 1, &copy);
    sync_test = false;
    CHECK(vkEndCommandBuffer(command));
    printf("CASE=%s-read-%s ERRORS=%u EXPECTED=%u\n", kind,
        missing_barrier ? "negative" : "positive", errors-before, missing_barrier ? 1u : 0u);
    if (errors-before != (missing_barrier ? 1u : 0u) ||
        raw_errors-before_raw != (missing_barrier ? 1u : 0u)) status = 1;
done:
    if (pool) vkDestroyCommandPool(device, pool, NULL);
    if (buffer) vkDestroyBuffer(device, buffer, NULL);
    if (memory) vkFreeMemory(device, memory, NULL);
    return status;
}

static int surviving_alias(VkDevice device, VkImage image, VkImage *unused_alias, uint32_t family)
{
    int status = 0;
    vkDestroyImage(device, *unused_alias, NULL);
    *unused_alias = VK_NULL_HANDLE;
    for (unsigned negative = 0; negative < 2; negative++)
        if (image_sync(device, image, VK_NULL_HANDLE, family, negative, negative, "surviving-alias"))
            status = 1;
    return status;
}

static int queued_surviving_alias(VkPhysicalDevice physical, VkDevice device, VkImage image,
                                  const VkImageCreateInfo *import_info, uint32_t family)
{
    int status = 0;
    VkImage alias = VK_NULL_HANDLE, guard = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    VkCommandPool pool = VK_NULL_HANDLE;
    unsigned before = errors, before_waw = waw_errors;
    CHECK(vkCreateImage(device, import_info, NULL, &alias));
    VkImageCreateInfo ci = *import_info;
    ci.pNext = NULL;
    CHECK(vkCreateImage(device, &ci, NULL, &guard));
    VkMemoryRequirements req;
    vkGetImageMemoryRequirements(device, guard, &req);
    VkPhysicalDeviceMemoryProperties props;
    vkGetPhysicalDeviceMemoryProperties(physical, &props);
    uint32_t type = 0;
    while (type < props.memoryTypeCount && !(req.memoryTypeBits & (1u << type))) type++;
    if (type == props.memoryTypeCount) { status = 2; goto done; }
    VkMemoryAllocateInfo allocation = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = req.size, .memoryTypeIndex = type};
    CHECK(vkAllocateMemory(device, &allocation, NULL, &memory));
    CHECK(vkBindImageMemory(device, guard, memory, 0));
    VkCommandPoolCreateInfo pci = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = family};
    CHECK(vkCreateCommandPool(device, &pci, NULL, &pool));
    VkCommandBuffer commands[3];
    VkCommandBufferAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 3};
    CHECK(vkAllocateCommandBuffers(device, &ai, commands));
    VkCommandBufferBeginInfo begin = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    VkImageSubresourceRange range = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    VkClearColorValue color = {.float32 = {0.5, 0.5, 0.5, 1}};
    VkQueue queue;
    vkGetDeviceQueue(device, family, 0, &queue);
    for (unsigned i = 0; i < 3; i++) {
        CHECK(vkBeginCommandBuffer(commands[i], &begin));
        if (!i) {
            VkImageMemoryBarrier transition = {.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
                .newLayout = VK_IMAGE_LAYOUT_GENERAL, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = image, .subresourceRange = range};
            vkCmdPipelineBarrier(commands[i], VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                0, 0, NULL, 0, NULL, 1, &transition);
            transition.image = guard;
            vkCmdPipelineBarrier(commands[i], VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                0, 0, NULL, 0, NULL, 1, &transition);
        }
        if (i != 2)
            vkCmdClearColorImage(commands[i], guard, VK_IMAGE_LAYOUT_GENERAL, &color, 1, &range);
        if (i != 1)
            vkCmdClearColorImage(commands[i], image, VK_IMAGE_LAYOUT_GENERAL, &color, 1, &range);
        CHECK(vkEndCommandBuffer(commands[i]));
        VkSubmitInfo submit = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .commandBufferCount = i ? 2 : 1, .pCommandBuffers = i ? &commands[1] : commands};
        if (!i) {
            CHECK(vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE));
            vkDestroyImage(device, alias, NULL);
            alias = VK_NULL_HANDLE;
        } else if (i == 2) {
            // The independent bound-image hazard rejects this submit even if Metal alias tracking regresses.
            sync_test = true;
            VkResult rejected = vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE);
            sync_test = false;
            if (rejected != VK_ERROR_VALIDATION_FAILED_EXT || errors-before != 2 || waw_errors-before_waw != 2)
                status = 1;
            printf("CASE=queued-surviving-alias ERRORS=%u EXPECTED=2 REJECTED=%d\n", errors-before, rejected);
        }
    }
done:
    vkDeviceWaitIdle(device);
    if (pool) vkDestroyCommandPool(device, pool, NULL);
    if (alias) vkDestroyImage(device, alias, NULL);
    if (guard) vkDestroyImage(device, guard, NULL);
    if (memory) vkFreeMemory(device, memory, NULL);
    return status;
}

int main(void)
{
    @autoreleasepool {
        int status = 0;
        VkInstance instance = VK_NULL_HANDLE;
        VkDevice device = VK_NULL_HANDLE;
        VkDebugUtilsMessengerEXT messenger = VK_NULL_HANDLE;
        VkImage image = VK_NULL_HANDLE;
        VkImage alias = VK_NULL_HANDLE, distinct = VK_NULL_HANDLE;
        VkImageView view = VK_NULL_HANDLE;
        VkDeviceMemory memory = VK_NULL_HANDLE;
        VkPhysicalDevice *devices = NULL;
        id<MTLTexture> texture = nil;
        id<MTLTexture> other_texture = nil;
        const char *extensions[] = {VK_EXT_DEBUG_UTILS_EXTENSION_NAME,
            VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME, VK_EXT_VALIDATION_FEATURES_EXTENSION_NAME};
        VkValidationFeatureEnableEXT enable = VK_VALIDATION_FEATURE_ENABLE_SYNCHRONIZATION_VALIDATION_EXT;
        VkValidationFeaturesEXT validation = {.sType = VK_STRUCTURE_TYPE_VALIDATION_FEATURES_EXT,
            .enabledValidationFeatureCount = 1, .pEnabledValidationFeatures = &enable};
        const char *layer = "VK_LAYER_KHRONOS_validation";
        VkDebugUtilsMessengerCreateInfoEXT debug = {
            .sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT, .pNext = &validation,
            .messageSeverity = VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
            .messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                           VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT,
            .pfnUserCallback = debug_message,
        };
        VkExportMetalObjectCreateInfoEXT export_device = {
            .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECT_CREATE_INFO_EXT,
            .pNext = &debug,
            .exportObjectType = VK_EXPORT_METAL_OBJECT_TYPE_METAL_DEVICE_BIT_EXT,
        };
        VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .apiVersion = VK_API_VERSION_1_2};
        VkInstanceCreateInfo ici = {
            .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pNext = &export_device,
            .flags = VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR,
            .pApplicationInfo = &app,
            .enabledLayerCount = 1, .ppEnabledLayerNames = &layer,
            .enabledExtensionCount = 3, .ppEnabledExtensionNames = extensions,
        };
        CHECK(vkCreateInstance(&ici, NULL, &instance));
        PFN_vkCreateDebugUtilsMessengerEXT create_debug =
            (void *)vkGetInstanceProcAddr(instance, "vkCreateDebugUtilsMessengerEXT");
        debug.pNext = NULL;
        CHECK(create_debug(instance, &debug, NULL, &messenger));
        uint32_t count = 0;
        CHECK(vkEnumeratePhysicalDevices(instance, &count, NULL));
        if (!count) { status = 77; goto done; }
        devices = calloc(count, sizeof(*devices));
        if (!devices) { status = 2; goto done; }
        CHECK(vkEnumeratePhysicalDevices(instance, &count, devices));
        if (!count) { status = 77; goto done; }
        VkPhysicalDevice physical = devices[0];
        free(devices); devices = NULL;
        VkQueueFamilyProperties families[32];
        count = 32;
        vkGetPhysicalDeviceQueueFamilyProperties(physical, &count, families);
        uint32_t family = 0;
        while (family < count && !(families[family].queueFlags & VK_QUEUE_GRAPHICS_BIT))
            family++;
        if (family == count) { status = 77; goto done; }
        float priority = 1;
        VkDeviceQueueCreateInfo queue = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = family, .queueCount = 1, .pQueuePriorities = &priority};
        const char *device_extensions[] = {VK_EXT_METAL_OBJECTS_EXTENSION_NAME,
            "VK_KHR_portability_subset"};
        VkDeviceCreateInfo dci = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .queueCreateInfoCount = 1, .pQueueCreateInfos = &queue,
            .enabledExtensionCount = 2, .ppEnabledExtensionNames = device_extensions};
        CHECK(vkCreateDevice(physical, &dci, NULL, &device));
        VkExportMetalDeviceInfoEXT metal_device = {
            .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_DEVICE_INFO_EXT};
        VkExportMetalObjectsInfoEXT objects = {
            .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT,
            .pNext = &metal_device};
        PFN_vkExportMetalObjectsEXT export_objects =
            (void *)vkGetDeviceProcAddr(device, "vkExportMetalObjectsEXT");
        export_objects(device, &objects);
        if (!metal_device.mtlDevice) { status = 77; goto done; }

        VkFormat formats[] = {VK_FORMAT_R16_UNORM, VK_FORMAT_R16G16_UNORM};
        MTLPixelFormat metal_formats[] = {MTLPixelFormatR16Unorm, MTLPixelFormatRG16Unorm};
        // The last two images must still fail: ordinary unbound and export-only.
        for (unsigned i = 0; i < 4; i++) {
            unsigned before = errors;
            unsigned before_unbound = unbound_errors;
            VkImportMetalTextureInfoEXT import = {
                .sType = VK_STRUCTURE_TYPE_IMPORT_METAL_TEXTURE_INFO_EXT,
                .plane = VK_IMAGE_ASPECT_PLANE_0_BIT};
            VkExportMetalObjectCreateInfoEXT export_texture = {
                .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECT_CREATE_INFO_EXT,
                .exportObjectType = VK_EXPORT_METAL_OBJECT_TYPE_METAL_TEXTURE_BIT_EXT};
            if (i < 2) {
                MTLTextureDescriptor *desc = [MTLTextureDescriptor
                    texture2DDescriptorWithPixelFormat:metal_formats[i]
                    width:16 height:16 mipmapped:NO];
                desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
                texture = [metal_device.mtlDevice newTextureWithDescriptor:desc];
                if (!texture) { status = 2; goto done; }
                import.mtlTexture = texture;
            }
            VkImageCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
                .pNext = i < 2 ? (void *)&import : i == 3 ? (void *)&export_texture : NULL,
                .imageType = VK_IMAGE_TYPE_2D, .format = formats[i < 2 ? i : 0],
                .extent = {16, 16, 1}, .mipLevels = 1, .arrayLayers = 1,
                .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
                .usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT};
            CHECK(vkCreateImage(device, &ci, NULL, &image));
            VkImageViewCreateInfo vi = {.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .image = image, .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = ci.format,
                .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
            CHECK(vkCreateImageView(device, &vi, NULL, &view));
            unsigned delta = errors - before;
            printf("CASE=%s ERRORS=%u\n", i < 2 ? "metal-import" :
                   i == 2 ? "unbound-control" : "export-control", delta);
            if ((i < 2 && delta) ||
                (i >= 2 && (delta != 1 || unbound_errors - before_unbound != 1)))
                status = 1;
            vkDestroyImageView(device, view, NULL); view = VK_NULL_HANDLE;
            if (i == 0) {
                invalid_view = true;
                vi.subresourceRange.levelCount = 0;
                unsigned invalid_before = invalid_view_errors, errors_before = errors;
                VkResult invalid_result = vkCreateImageView(device, &vi, NULL, &view);
                invalid_view = false;
                if (invalid_result != VK_ERROR_VALIDATION_FAILED_EXT || view ||
                    invalid_view_errors-invalid_before != 1 || errors-errors_before != 1) {
                    status = 1; goto done;
                }
                printf("CASE=invalid-imported-view ERRORS=1 EXPECTED=1\n");
                CHECK(vkCreateImage(device, &ci, NULL, &alias));
                MTLTextureDescriptor *desc = [MTLTextureDescriptor
                    texture2DDescriptorWithPixelFormat:MTLPixelFormatR16Unorm width:16 height:16 mipmapped:NO];
                desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
                other_texture = [metal_device.mtlDevice newTextureWithDescriptor:desc];
                if (!other_texture) { status = 2; goto done; }
                import.mtlTexture = other_texture;
                CHECK(vkCreateImage(device, &ci, NULL, &distinct));
                import.mtlTexture = texture;
                for (unsigned negative = 0; negative < 2; negative++)
                    if (image_sync(device, image, alias, family, negative, negative, "alias")) status = 1;
                if (image_sync(device, image, distinct, family, true, false, "distinct")) status = 1;
            }
            if (i == 0 || i == 2) {
                if (i == 2) {
                    VkMemoryRequirements req; vkGetImageMemoryRequirements(device, image, &req);
                    VkPhysicalDeviceMemoryProperties props; vkGetPhysicalDeviceMemoryProperties(physical, &props);
                    uint32_t type = 0;
                    while (type < props.memoryTypeCount && !(req.memoryTypeBits & (1u << type))) type++;
                    if (type == props.memoryTypeCount) { status = 2; goto done; }
                    VkMemoryAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                        .allocationSize = req.size, .memoryTypeIndex = type};
                    CHECK(vkAllocateMemory(device, &ai, NULL, &memory));
                    CHECK(vkBindImageMemory(device, image, memory, 0));
                }
                for (unsigned negative = 0; negative < 2; negative++)
                    if (image_sync(device, image, VK_NULL_HANDLE, family, negative, negative,
                                   i == 0 ? "imported" : "bound")) status = 1;
                for (unsigned negative = 0; negative < 2; negative++)
                    if (image_read_sync(physical, device, image, family, negative,
                                        i == 0 ? "imported" : "bound")) status = 1;
                if (i == 0 && !status && queued_surviving_alias(physical, device, image, &ci, family)) status = 1;
                if (i == 0 && !status && surviving_alias(device, image, &alias, family)) status = 1;
            }
            if (alias) vkDestroyImage(device, alias, NULL); alias = VK_NULL_HANDLE;
            if (distinct) vkDestroyImage(device, distinct, NULL); distinct = VK_NULL_HANDLE;
            [other_texture release]; other_texture = nil;
            vkDestroyImage(device, image, NULL); image = VK_NULL_HANDLE;
            if (memory) vkFreeMemory(device, memory, NULL); memory = VK_NULL_HANDLE;
            [texture release]; texture = nil;
        }
done:
        free(devices);
        if (view) vkDestroyImageView(device, view, NULL);
        if (image) vkDestroyImage(device, image, NULL);
        if (alias) vkDestroyImage(device, alias, NULL);
        if (distinct) vkDestroyImage(device, distinct, NULL);
        if (memory) vkFreeMemory(device, memory, NULL);
        [texture release];
        [other_texture release];
        if (device) vkDestroyDevice(device, NULL);
        if (messenger) {
            PFN_vkDestroyDebugUtilsMessengerEXT destroy_debug =
                (void *)vkGetInstanceProcAddr(instance, "vkDestroyDebugUtilsMessengerEXT");
            destroy_debug(instance, messenger, NULL);
        }
        if (instance) vkDestroyInstance(instance, NULL);
        if (!status && errors != 11) status = 1;
        printf("MPV_HANDLE_CREATED=0 EXPECTED_CONTROL_ERRORS=11 RESULT=%s\n",
               status ? "FAIL" : "PASS");
        return status;
    }
}
