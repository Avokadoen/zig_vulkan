/// This file contains the vk Wrapper types used to call vulkan functions. 
/// Wrapper is a vulkan-zig construct that generates compile time types that 
/// links with vulkan functions depending on queried function requirements
/// see vk X_Command types for implementation details
const vk = @import("vulkan");

const consts = @import("consts.zig");

pub const Base = vk.BaseWrapper(&[_]vk.BaseCommand{
    .createInstance,
    .enumerateInstanceExtensionProperties,
    .enumerateInstanceLayerProperties,
});

pub const Instance = blk: {
    // zig fmt: off
    var default_commands = [_]vk.InstanceCommand{ 
        .createDevice, 
        .destroyInstance, 
        .destroySurfaceKHR,
        .enumerateDeviceExtensionProperties,
        .enumeratePhysicalDevices, 
        .getDeviceProcAddr, 
        .getPhysicalDeviceFeatures, 
        .getPhysicalDeviceMemoryProperties, 
        .getPhysicalDeviceProperties, 
        .getPhysicalDeviceQueueFamilyProperties, 
        .getPhysicalDeviceSurfaceCapabilitiesKHR, 
        .getPhysicalDeviceSurfaceFormatsKHR, 
        .getPhysicalDeviceSurfacePresentModesKHR, 
        .getPhysicalDeviceSurfaceSupportKHR 
    };
    // zig fmt: on
    var output_commands = default_commands ++ if (consts.enable_validation_layers) [_]vk.InstanceCommand{
        .createDebugUtilsMessengerEXT,
        .destroyDebugUtilsMessengerEXT,
    } else [_]vk.InstanceCommand{};
    break :blk vk.InstanceWrapper(&output_commands);
};

// zig fmt: off
pub const Device = vk.DeviceWrapper(&[_]vk.DeviceCommand{ 
    .acquireNextImageKHR, 
    .allocateCommandBuffers, 
    .allocateDescriptorSets, 
    .allocateMemory, 
    .beginCommandBuffer, 
    .bindBufferMemory, 
    .bindImageMemory, 
    .cmdBlitImage,
    .cmdBeginRenderPass, 
    .cmdBindDescriptorSets, 
    .cmdBindIndexBuffer,
    .cmdBindPipeline,
    .cmdBindVertexBuffers,
    .cmdCopyBuffer,
    .cmdCopyBufferToImage,
    .cmdCopyImageToBuffer,
    .cmdDispatch,
    .cmdDrawIndexed,
    .cmdEndRenderPass,
    .cmdPipelineBarrier,
    .cmdSetScissor,
    .cmdSetViewport,
    .createBuffer,
    .createCommandPool,
    .createComputePipelines,
    .createDescriptorPool,
    .createDescriptorSetLayout,
    .createFence,
    .createFramebuffer,
    .createGraphicsPipelines,
    .createImage,
    .createImageView,
    .createPipelineLayout,
    .createRenderPass,
    .createSampler,
    .createSemaphore,
    .createShaderModule,
    .createSwapchainKHR,
    .destroyBuffer,
    .destroyCommandPool,
    .destroyDescriptorPool,
    .destroyDescriptorSetLayout,
    .destroyDevice,
    .destroyFence,
    .destroyFramebuffer,
    .destroyImage,
    .destroyImageView,
    .destroyPipeline,
    .destroyPipelineLayout,
    .destroyRenderPass,
    .destroySampler,
    .destroySemaphore,
    .destroyShaderModule,
    .destroySwapchainKHR,
    .deviceWaitIdle,
    .endCommandBuffer,
    .freeCommandBuffers,
    .freeMemory,
    .getBufferMemoryRequirements,
    .getDeviceQueue,
    .getImageMemoryRequirements,
    .getSwapchainImagesKHR,
    .mapMemory,
    .queuePresentKHR,
    .queueSubmit,
    .queueWaitIdle,
    .resetFences,
    .unmapMemory,
    .updateDescriptorSets,
    .waitForFences 
});
// zig fmt: on

pub const BeginCommandBufferError = Device.BeginCommandBufferError;
