/// This file contains the vk Wrapper types used to call vulkan functions. 
/// Wrapper is a vulkan-zig construct that generates compile time types that 
/// links with vulkan functions depending on queried function requirements
/// see vk X_Command types for implementation 
const vk = @import("vulkan");

pub const Base = vk.BaseWrapper([_]vk.BaseCommand{
    .CreateInstance,
    .EnumerateInstanceExtensionProperties,
    .EnumerateInstanceLayerProperties,
});

pub const Instance = vk.InstanceWrapper([_]vk.InstanceCommand{ .CreateDebugUtilsMessengerEXT, .CreateDevice, .DestroyDebugUtilsMessengerEXT, .DestroyInstance, .DestroySurfaceKHR, .EnumerateDeviceExtensionProperties, .EnumeratePhysicalDevices, .GetDeviceProcAddr, .GetPhysicalDeviceFeatures, .GetPhysicalDeviceProperties, .GetPhysicalDeviceQueueFamilyProperties, .GetPhysicalDeviceSurfaceCapabilitiesKHR, .GetPhysicalDeviceSurfaceFormatsKHR, .GetPhysicalDeviceSurfacePresentModesKHR, .GetPhysicalDeviceSurfaceSupportKHR });

pub const Device = vk.DeviceWrapper([_]vk.DeviceCommand{ .AcquireNextImageKHR, .AllocateCommandBuffers, .BeginCommandBuffer, .CmdBeginRenderPass, .CmdBindPipeline, .CmdDraw, .CmdEndRenderPass, .CmdSetScissor, .CmdSetViewport, .CreateCommandPool, .CreateFence, .CreateFramebuffer, .CreateGraphicsPipelines, .CreateImageView, .CreatePipelineLayout, .CreateRenderPass, .CreateSemaphore, .CreateShaderModule, .CreateSwapchainKHR, .DestroyCommandPool, .DestroyDevice, .DestroyFence, .DestroyFramebuffer, .DestroyImageView, .DestroyPipeline, .DestroyPipelineLayout, .DestroyRenderPass, .DestroySemaphore, .DestroyShaderModule, .DestroySwapchainKHR, .DeviceWaitIdle, .EndCommandBuffer, .FreeCommandBuffers, .GetDeviceQueue, .GetSwapchainImagesKHR, .QueuePresentKHR, .QueueSubmit, .ResetFences, .WaitForFences });
