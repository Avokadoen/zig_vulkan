// source: https://github.com/Snektron/vulkan-zig/blob/de0a048f45a2257ba855d4e3660170a4e365d684/examples/c.zig
pub usingnamespace @cImport({
    @cDefine("GLFW_INCLUDE_NONE", {});
    @cInclude("GLFW/glfw3.h");
});

const vk = @import("vulkan");

// usually the GLFW vulkan functions are exported if Vulkan is included,
// but since thats not the case here, they are manually imported.
pub extern fn glfwGetInstanceProcAddress(instance: vk.Instance, procname: [*:0]const u8) vk.PfnVoidFunction;
pub extern fn glfwGetPhysicalDevicePresentationSupport(instance: vk.Instance, pdev: vk.PhysicalDevice, queuefamily: u32) c_int;
pub extern fn glfwCreateWindowSurface(
    instance: vk.Instance, 
    window: *GLFWwindow, 
    allocation_callbacks: ?*const vk.AllocationCallbacks, 
    surface: *vk.SurfaceKHR
) vk.Result;