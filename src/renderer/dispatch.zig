/// This file contains the vk Wrapper types used to call vulkan functions. 
/// Wrapper is a vulkan-zig construct that generates compile time types that 
/// links with vulkan functions depending on queried function requirements
/// see vk X_Command types for implementation details
const vk = @import("vulkan");

pub const Base = vk.BaseWrapper([_]vk.BaseCommand{
    .CreateInstance,
    .EnumerateInstanceExtensionProperties,
    .EnumerateInstanceLayerProperties,
});

pub const Instance = vk.InstanceWrapper([_]vk.InstanceCommand{ .CreateDebugUtilsMessengerEXT, .CreateDevice, .DestroyDebugUtilsMessengerEXT, .DestroyInstance, .DestroySurfaceKHR, .EnumerateDeviceExtensionProperties, .EnumeratePhysicalDevices, .GetDeviceProcAddr, .GetPhysicalDeviceFeatures, .GetPhysicalDeviceMemoryProperties, .GetPhysicalDeviceProperties, .GetPhysicalDeviceQueueFamilyProperties, .GetPhysicalDeviceSurfaceCapabilitiesKHR, .GetPhysicalDeviceSurfaceFormatsKHR, .GetPhysicalDeviceSurfacePresentModesKHR, .GetPhysicalDeviceSurfaceSupportKHR });

pub const Device = vk.DeviceWrapper([_]vk.DeviceCommand{ .AcquireNextImageKHR, .AllocateCommandBuffers, .AllocateMemory, .BeginCommandBuffer, .BindBufferMemory, .BindImageMemory, .CmdBeginRenderPass, .CmdBindIndexBuffer, .CmdBindPipeline, .CmdBindVertexBuffers, .CmdCopyBuffer, .CmdCopyBufferToImage, .CmdCopyImageToBuffer, .CmdDrawIndexed, .CmdEndRenderPass, .CmdPipelineBarrier, .CmdSetScissor, .CmdSetViewport, .CreateBuffer, .CreateCommandPool, .CreateFence, .CreateFramebuffer, .CreateGraphicsPipelines, .CreateImage, .CreateImageView, .CreatePipelineLayout, .CreateRenderPass, .CreateSampler, .CreateSemaphore, .CreateShaderModule, .CreateSwapchainKHR, .DestroyBuffer, .DestroyCommandPool, .DestroyDevice, .DestroyFence, .DestroyFramebuffer, .DestroyImage, .DestroyImageView, .DestroyPipeline, .DestroyPipelineLayout, .DestroyRenderPass, .DestroySampler, .DestroySemaphore, .DestroyShaderModule, .DestroySwapchainKHR, .DeviceWaitIdle, .EndCommandBuffer, .FreeCommandBuffers, .FreeMemory, .GetBufferMemoryRequirements, .GetDeviceQueue, .GetImageMemoryRequirements, .GetSwapchainImagesKHR, .MapMemory, .QueuePresentKHR, .QueueSubmit, .QueueWaitIdle, .ResetFences, .UnmapMemory, .WaitForFences });
