const vk = @import("vulkan");
const zglfw = @import("zglfw");

pub extern fn glfwGetInstanceProcAddress(instance: vk.Instance, procname: [*:0]const u8) vk.PfnVoidFunction;
pub extern fn glfwGetPhysicalDevicePresentationSupport(instance: vk.Instance, pdev: vk.PhysicalDevice, queuefamily: u32) c_int;
pub extern fn glfwCreateWindowSurface(instance: vk.Instance, window: *zglfw.Window, allocation_callbacks: ?*const vk.AllocationCallbacks, surface: *vk.SurfaceKHR) vk.Result;
