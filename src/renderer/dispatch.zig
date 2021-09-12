/// This file contains the vk Wrapper types used to call vulkan functions. 
/// Wrapper is a vulkan-zig construct that generates compile time types that 
/// links with vulkan functions depending on queried function requirements
/// see vk X_Command types for implementation details
const vk = @import("vulkan");

const consts = @import("consts.zig");

pub const Base = vk.BaseWrapper([_]vk.BaseCommand{
    .CreateInstance,
    .EnumerateInstanceExtensionProperties,
    .EnumerateInstanceLayerProperties,
});

pub const Instance = blk: {
    var default_commands = [_]vk.InstanceCommand{ .CreateDevice, .DestroyInstance, .DestroySurfaceKHR, .EnumerateDeviceExtensionProperties, .EnumeratePhysicalDevices, .GetDeviceProcAddr, .GetPhysicalDeviceFeatures, .GetPhysicalDeviceMemoryProperties, .GetPhysicalDeviceProperties, .GetPhysicalDeviceQueueFamilyProperties, .GetPhysicalDeviceSurfaceCapabilitiesKHR, .GetPhysicalDeviceSurfaceFormatsKHR, .GetPhysicalDeviceSurfacePresentModesKHR, .GetPhysicalDeviceSurfaceSupportKHR };
    var output_commands = default_commands ++ if(consts.enable_validation_layers) [_]vk.InstanceCommand{ .CreateDebugUtilsMessengerEXT, .DestroyDebugUtilsMessengerEXT, } else [_]vk.InstanceCommand{};
    break :blk vk.InstanceWrapper(output_commands);
};

pub const Device = vk.DeviceWrapper([_]vk.DeviceCommand{ .AcquireNextImageKHR, .AllocateCommandBuffers, .AllocateDescriptorSets, .AllocateMemory, .BeginCommandBuffer, .BindBufferMemory, .BindImageMemory, .CmdBeginRenderPass, .CmdBindDescriptorSets, .CmdBindIndexBuffer, .CmdBindPipeline, .CmdBindVertexBuffers, .CmdCopyBuffer, .CmdCopyBufferToImage, .CmdCopyImageToBuffer, .CmdDrawIndexed, .CmdEndRenderPass, .CmdPipelineBarrier, .CmdSetScissor, .CmdSetViewport, .CreateBuffer, .CreateCommandPool, .CreateDescriptorPool, .CreateDescriptorSetLayout, .CreateFence, .CreateFramebuffer, .CreateGraphicsPipelines, .CreateImage, .CreateImageView, .CreatePipelineLayout, .CreateRenderPass, .CreateSampler, .CreateSemaphore, .CreateShaderModule, .CreateSwapchainKHR, .DestroyBuffer, .DestroyCommandPool, .DestroyDescriptorPool, .DestroyDescriptorSetLayout, .DestroyDevice, .DestroyFence, .DestroyFramebuffer, .DestroyImage, .DestroyImageView, .DestroyPipeline, .DestroyPipelineLayout, .DestroyRenderPass, .DestroySampler, .DestroySemaphore, .DestroyShaderModule, .DestroySwapchainKHR, .DeviceWaitIdle, .EndCommandBuffer, .FreeCommandBuffers, .FreeMemory, .GetBufferMemoryRequirements, .GetDeviceQueue, .GetImageMemoryRequirements, .GetSwapchainImagesKHR, .MapMemory, .QueuePresentKHR, .QueueSubmit, .QueueWaitIdle, .ResetFences, .UnmapMemory, .UpdateDescriptorSets, .WaitForFences });
