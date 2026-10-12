// Offscreen validation target; follows the existing Vulkan smoke's queue/readback flow.
#import <Foundation/Foundation.h>
#include "vk-target.h"
#define VK(call) do { VkResult r=(call); if (r) { fprintf(stderr,"VK_FAIL=%d LINE=%d\n",r,__LINE__); exit(1); } } while (0)
#define CHECK(c) do { if (!(c)) { fprintf(stderr,"VK_CHECK_FAIL=%d\n",__LINE__); exit(1); } } while (0)
static const char *extensions[] = {"VK_KHR_synchronization2","VK_KHR_portability_subset"};

static void lock(void *data, uint32_t family, uint32_t index)
{ (void)family; (void)index; CHECK(!pthread_mutex_lock(&((struct vk_target *)data)->mutex)); }
static void unlock(void *data, uint32_t family, uint32_t index)
{ (void)family; (void)index; CHECK(!pthread_mutex_unlock(&((struct vk_target *)data)->mutex)); }
static uint32_t memory_type(struct vk_target *t,uint32_t bits,VkMemoryPropertyFlags flags)
{
    VkPhysicalDeviceMemoryProperties p; vkGetPhysicalDeviceMemoryProperties(t->physical,&p);
    for (uint32_t n=0;n<p.memoryTypeCount;n++)
        if ((bits&(1u<<n)) && (p.memoryTypes[n].propertyFlags&flags)==flags) return n;
    exit(77);
}
void vk_target_create(struct vk_target *t)
{
    CHECK(!pthread_mutex_init(&t->mutex,NULL));
    VkApplicationInfo app={.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO,.apiVersion=VK_API_VERSION_1_2};
    // Static MoltenVK, like the existing iOS smoke; not a desktop Vulkan loader.
    VkInstanceCreateInfo instance={.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,.pApplicationInfo=&app};
    VK(vkCreateInstance(&instance,NULL,&t->instance));
    uint32_t count=0; VK(vkEnumeratePhysicalDevices(t->instance,&count,NULL)); CHECK(count);
    VkPhysicalDevice *devices=calloc(count,sizeof(*devices)); CHECK(devices);
    VK(vkEnumeratePhysicalDevices(t->instance,&count,devices)); t->physical=devices[0]; free(devices);
    VkPhysicalDeviceProperties p; vkGetPhysicalDeviceProperties(t->physical,&p);
    CHECK(p.apiVersion>=VK_API_VERSION_1_2);
    fprintf(stderr,"GPU=%s VK_API=%u\n",p.deviceName,p.apiVersion);
    vkGetPhysicalDeviceQueueFamilyProperties(t->physical,&count,NULL);
    VkQueueFamilyProperties *queues=calloc(count,sizeof(*queues)); CHECK(queues);
    vkGetPhysicalDeviceQueueFamilyProperties(t->physical,&count,queues);
    uint32_t family=UINT32_MAX;
    VkQueueFlags required=VK_QUEUE_GRAPHICS_BIT|VK_QUEUE_COMPUTE_BIT;
    for (uint32_t n=0;n<count;n++) if ((queues[n].queueFlags&required)==required) { family=n; break; }
    free(queues); CHECK(family!=UINT32_MAX);
    t->sync2=(VkPhysicalDeviceSynchronization2Features){.sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES};
    t->f12=(VkPhysicalDeviceVulkan12Features){.sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,.pNext=&t->sync2};
    t->features=(VkPhysicalDeviceFeatures2){.sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,.pNext=&t->f12};
    vkGetPhysicalDeviceFeatures2(t->physical,&t->features);
    CHECK(t->f12.timelineSemaphore && t->f12.hostQueryReset && t->sync2.synchronization2);
    float priority=1;
    VkDeviceQueueCreateInfo queue={.sType=VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,.queueFamilyIndex=family,.queueCount=1,.pQueuePriorities=&priority};
    VkDeviceCreateInfo device={.sType=VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,.pNext=&t->features,
        .queueCreateInfoCount=1,.pQueueCreateInfos=&queue,.enabledExtensionCount=2,.ppEnabledExtensionNames=extensions};
    VK(vkCreateDevice(t->physical,&device,NULL,&t->device)); vkGetDeviceQueue(t->device,family,0,&t->queue);
    t->init=(mpv_vulkan_init_params){.version=1,.instance_api_version=VK_API_VERSION_1_2,
        .instance=t->instance,.physical_device=t->physical,.device=t->device,.get_proc_address=vkGetInstanceProcAddr,
        .features=&t->features,.extensions=extensions,.num_extensions=2,.queue_family=family,
        .lock_queue=lock,.unlock_queue=unlock,.queue_context=t};
    VkImageUsageFlags usage=VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT|VK_IMAGE_USAGE_TRANSFER_DST_BIT|VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    VkImageCreateInfo image={.sType=VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,.imageType=VK_IMAGE_TYPE_2D,
        .format=VK_FORMAT_R8G8B8A8_UNORM,.extent={512,288,1},.mipLevels=1,.arrayLayers=1,
        .samples=VK_SAMPLE_COUNT_1_BIT,.tiling=VK_IMAGE_TILING_OPTIMAL,.usage=usage};
    t->target=(mpv_vulkan_target){.version=1,.generation=1,.format=image.format,.width=512,.height=288,.usage=usage,
        .output_layout=VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL};
    VK(vkCreateImage(t->device,&image,NULL,&t->target.image));
    VkMemoryRequirements mr; vkGetImageMemoryRequirements(t->device,t->target.image,&mr);
    VkMemoryAllocateInfo alloc={.sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,.allocationSize=mr.size,
        .memoryTypeIndex=memory_type(t,mr.memoryTypeBits,VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)};
    VK(vkAllocateMemory(t->device,&alloc,NULL,&t->image_memory)); VK(vkBindImageMemory(t->device,t->target.image,t->image_memory,0));
    VkBufferCreateInfo buffer={.sType=VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,.size=512*288*4,.usage=VK_BUFFER_USAGE_TRANSFER_DST_BIT};
    VK(vkCreateBuffer(t->device,&buffer,NULL,&t->buffer)); vkGetBufferMemoryRequirements(t->device,t->buffer,&mr);
    alloc.allocationSize=mr.size; alloc.memoryTypeIndex=memory_type(t,mr.memoryTypeBits,VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    VK(vkAllocateMemory(t->device,&alloc,NULL,&t->buffer_memory)); VK(vkBindBufferMemory(t->device,t->buffer,t->buffer_memory,0));
    VK(vkMapMemory(t->device,t->buffer_memory,0,VK_WHOLE_SIZE,0,(void **)&t->pixels));
    VkSemaphoreTypeCreateInfo type={.sType=VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO,.semaphoreType=VK_SEMAPHORE_TYPE_TIMELINE};
    VkSemaphoreCreateInfo sem={.sType=VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,.pNext=&type};
    VK(vkCreateSemaphore(t->device,&sem,NULL,&t->target.completion));
    VkCommandPoolCreateInfo pool={.sType=VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,.queueFamilyIndex=family,.flags=VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT};
    VK(vkCreateCommandPool(t->device,&pool,NULL,&t->pool));
    VkCommandBufferAllocateInfo command={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,.commandPool=t->pool,.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY,.commandBufferCount=1};
    VK(vkAllocateCommandBuffers(t->device,&command,&t->command));
    VkFenceCreateInfo fence={.sType=VK_STRUCTURE_TYPE_FENCE_CREATE_INFO}; VK(vkCreateFence(t->device,&fence,NULL,&t->fence));
}
CGImageRef vk_target_read(struct vk_target *t)
{
    CHECK(t->target.state==MPV_VULKAN_TARGET_RETURNED);
    VK(vkResetCommandBuffer(t->command,0)); VK(vkResetFences(t->device,1,&t->fence));
    VkCommandBufferBeginInfo begin={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO}; VK(vkBeginCommandBuffer(t->command,&begin));
    VkBufferImageCopy copy={.imageSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1},.imageExtent={512,288,1}};
    vkCmdCopyImageToBuffer(t->command,t->target.image,t->target.output_layout,t->buffer,1,&copy);
    VkBufferMemoryBarrier barrier={.sType=VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask=VK_ACCESS_HOST_READ_BIT,.srcQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED,.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED,.buffer=t->buffer,.size=VK_WHOLE_SIZE};
    vkCmdPipelineBarrier(t->command,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,0,NULL,1,&barrier,0,NULL);
    VK(vkEndCommandBuffer(t->command));
    VkTimelineSemaphoreSubmitInfo timeline={.sType=VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO,.waitSemaphoreValueCount=1,.pWaitSemaphoreValues=&t->target.completion_value};
    VkPipelineStageFlags stage=VK_PIPELINE_STAGE_TRANSFER_BIT;
    VkSubmitInfo submit={.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO,.pNext=&timeline,.waitSemaphoreCount=1,
        .pWaitSemaphores=&t->target.completion,.pWaitDstStageMask=&stage,.commandBufferCount=1,.pCommandBuffers=&t->command};
    lock(t,0,0); VK(vkQueueSubmit(t->queue,1,&submit,t->fence)); unlock(t,0,0);
    VK(vkWaitForFences(t->device,1,&t->fence,VK_TRUE,10000000000ULL));
    t->target.input_layout=t->target.output_layout;
    NSData *data=[NSData dataWithBytes:t->pixels length:512*288*4];
    CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGColorSpaceRef color=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef result=CGImageCreate(512,288,8,32,512*4,color,(CGBitmapInfo)kCGImageAlphaLast,provider,NULL,false,kCGRenderingIntentDefault);
    CGColorSpaceRelease(color); CGDataProviderRelease(provider); CHECK(result); return result;
}
void vk_target_destroy(struct vk_target *t)
{
    VK(vkDeviceWaitIdle(t->device)); // Teardown only; never used in the render loop.
    vkDestroyFence(t->device,t->fence,NULL); vkDestroyCommandPool(t->device,t->pool,NULL);
    vkDestroySemaphore(t->device,t->target.completion,NULL); vkUnmapMemory(t->device,t->buffer_memory);
    vkDestroyBuffer(t->device,t->buffer,NULL); vkFreeMemory(t->device,t->buffer_memory,NULL);
    vkDestroyImage(t->device,t->target.image,NULL); vkFreeMemory(t->device,t->image_memory,NULL);
    vkDestroyDevice(t->device,NULL); vkDestroyInstance(t->instance,NULL); CHECK(!pthread_mutex_destroy(&t->mutex));
}
