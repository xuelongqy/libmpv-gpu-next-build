#include <Metal/Metal.h>
#define VK_USE_PLATFORM_METAL_EXT
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned errors, unbound_errors;

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
    }
    return VK_FALSE;
}

#define CHECK(call) do { VkResult result = (call); if (result != VK_SUCCESS) { \
    fprintf(stderr, "%s: %d\n", #call, result); \
    status = result == VK_ERROR_EXTENSION_NOT_PRESENT ? 77 : 2; goto done; \
} } while (0)

int main(void)
{
    @autoreleasepool {
        int status = 0;
        VkInstance instance = VK_NULL_HANDLE;
        VkDevice device = VK_NULL_HANDLE;
        VkDebugUtilsMessengerEXT messenger = VK_NULL_HANDLE;
        VkImage image = VK_NULL_HANDLE;
        VkImageView view = VK_NULL_HANDLE;
        VkPhysicalDevice *devices = NULL;
        id<MTLTexture> texture = nil;
        const char *extensions[] = {VK_EXT_DEBUG_UTILS_EXTENSION_NAME,
            VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME};
        const char *layer = "VK_LAYER_KHRONOS_validation";
        VkDebugUtilsMessengerCreateInfoEXT debug = {
            .sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
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
            .enabledExtensionCount = 2, .ppEnabledExtensionNames = extensions,
        };
        CHECK(vkCreateInstance(&ici, NULL, &instance));
        PFN_vkCreateDebugUtilsMessengerEXT create_debug =
            (void *)vkGetInstanceProcAddr(instance, "vkCreateDebugUtilsMessengerEXT");
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
                desc.usage = MTLTextureUsageShaderRead;
                texture = [metal_device.mtlDevice newTextureWithDescriptor:desc];
                if (!texture) { status = 2; goto done; }
                import.mtlTexture = texture;
            }
            VkImageCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
                .pNext = i < 2 ? (void *)&import : i == 3 ? (void *)&export_texture : NULL,
                .imageType = VK_IMAGE_TYPE_2D, .format = formats[i < 2 ? i : 0],
                .extent = {16, 16, 1}, .mipLevels = 1, .arrayLayers = 1,
                .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
                .usage = VK_IMAGE_USAGE_SAMPLED_BIT};
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
            vkDestroyImage(device, image, NULL); image = VK_NULL_HANDLE;
            [texture release]; texture = nil;
        }
done:
        free(devices);
        if (view) vkDestroyImageView(device, view, NULL);
        if (image) vkDestroyImage(device, image, NULL);
        [texture release];
        if (device) vkDestroyDevice(device, NULL);
        if (messenger) {
            PFN_vkDestroyDebugUtilsMessengerEXT destroy_debug =
                (void *)vkGetInstanceProcAddr(instance, "vkDestroyDebugUtilsMessengerEXT");
            destroy_debug(instance, messenger, NULL);
        }
        if (instance) vkDestroyInstance(instance, NULL);
        if (!status && errors != 2) status = 1;
        printf("MPV_HANDLE_CREATED=0 EXPECTED_CONTROL_ERRORS=2 RESULT=%s\n",
               status ? "FAIL" : "PASS");
        return status;
    }
}
