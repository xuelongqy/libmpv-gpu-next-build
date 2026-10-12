#include <pthread.h>
#include <CoreGraphics/CoreGraphics.h>
#include <mpv/render_vk.h>

struct vk_target {
    VkInstance instance;
    VkPhysicalDevice physical;
    VkDevice device;
    VkQueue queue;
    pthread_mutex_t mutex;
    VkDeviceMemory image_memory, buffer_memory;
    VkBuffer buffer;
    VkCommandPool pool;
    VkCommandBuffer command;
    VkFence fence;
    VkPhysicalDeviceFeatures2 features;
    VkPhysicalDeviceVulkan12Features f12;
    VkPhysicalDeviceSynchronization2Features sync2;
    mpv_vulkan_init_params init;
    mpv_vulkan_target target;
    uint8_t *pixels;
};
void vk_target_create(struct vk_target *t);
CGImageRef vk_target_read(struct vk_target *t);
void vk_target_destroy(struct vk_target *t);
