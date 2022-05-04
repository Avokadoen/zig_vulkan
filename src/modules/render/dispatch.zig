/// This file contains the vk Wrapper types used to call vulkan functions.
/// Wrapper is a vulkan-zig construct that generates compile time types that
/// links with vulkan functions depending on queried function requirements
/// see vk X_Command types for implementation details
const vk = @import("vulkan");

const consts = @import("consts.zig");

pub const Base = vk.BaseWrapper(.{
    .enumerateInstanceLayerProperties = true,
    .enumerateInstanceExtensionProperties = true,
    .createInstance = true,
});

pub const Instance = vk.InstanceWrapper(.{
    .createDebugUtilsMessengerEXT = consts.enable_validation_layers,
    .createDevice = true,
    .destroyDebugUtilsMessengerEXT = consts.enable_validation_layers,
    .destroyInstance = true,
    .destroySurfaceKHR = true,
    .enumerateDeviceExtensionProperties = true,
    .enumeratePhysicalDevices = true,
    .getDeviceProcAddr = true,
    .getPhysicalDeviceFeatures = true,
    .getPhysicalDeviceMemoryProperties = true,
    .getPhysicalDeviceProperties = true,
    .getPhysicalDeviceQueueFamilyProperties = true,
    .getPhysicalDeviceSurfaceCapabilitiesKHR = true,
    .getPhysicalDeviceSurfaceFormatsKHR = true,
    .getPhysicalDeviceSurfacePresentModesKHR = true,
    .getPhysicalDeviceSurfaceSupportKHR = true,
});

// zig fmt: off
pub const Device = vk.DeviceWrapper(.{ 
    .acquireNextImageKHR = true, 
    .allocateCommandBuffers = true, 
    .allocateDescriptorSets = true, 
    .allocateMemory = true, 
    .beginCommandBuffer = true, 
    .bindBufferMemory = true, 
    .bindImageMemory = true, 
    .cmdBeginRenderPass = true, 
    .cmdBindDescriptorSets = true, 
    .cmdBindIndexBuffer = true,
    .cmdBindPipeline = true,
    .cmdBindVertexBuffers = true,
    .cmdBlitImage = true,
    .cmdCopyBuffer = true,
    .cmdCopyBufferToImage = true,
    .cmdCopyImageToBuffer = true,
    .cmdDispatch = true,
    .cmdDrawIndexed = true,
    .cmdEndRenderPass = true,
    .cmdPipelineBarrier = true,
    .cmdPushConstants = true,
    .cmdSetScissor = true,
    .cmdSetViewport = true,
    .createBuffer = true,
    .createCommandPool = true,
    .createComputePipelines = true,
    .createDescriptorPool = true,
    .createDescriptorSetLayout = true,
    .createFence = true,
    .createFramebuffer = true,
    .createGraphicsPipelines = true,
    .createImage = true,
    .createImageView = true,
    .createPipelineCache = true,
    .createPipelineLayout = true,
    .createRenderPass = true,
    .createSampler = true,
    .createSemaphore = true,
    .createShaderModule = true,
    .createSwapchainKHR = true,
    .destroyBuffer = true,
    .destroyCommandPool = true,
    .destroyDescriptorPool = true,
    .destroyDescriptorSetLayout = true,
    .destroyDevice = true,
    .destroyFence = true,
    .destroyFramebuffer = true,
    .destroyImage = true,
    .destroyImageView = true,
    .destroyPipeline = true,
    .destroyPipelineCache = true,
    .destroyPipelineLayout = true,
    .destroyRenderPass = true,
    .destroySampler = true,
    .destroySemaphore = true,
    .destroyShaderModule = true,
    .destroySwapchainKHR = true,
    .deviceWaitIdle = true,
    .endCommandBuffer = true,
    .flushMappedMemoryRanges = true,
    .freeCommandBuffers = true,
    .freeDescriptorSets = true,
    .freeMemory = true,
    .getBufferMemoryRequirements = true,
    .getDeviceQueue = true,
    .getImageMemoryRequirements = true,
    .getSwapchainImagesKHR = true,
    .mapMemory = true,
    .queuePresentKHR = true,
    .queueSubmit = true,
    .queueWaitIdle = true,
    .resetCommandPool = true,
    .resetFences = true,
    .unmapMemory = true,
    .updateDescriptorSets = true,
    .waitForFences = true, 
});
// zig fmt: on

pub const BeginCommandBufferError = Device.BeginCommandBufferError;
