
 ![frame capture](screenshot.png)

# Zig vulkan renderer

A toy renderer written in zig using vulkan and glfw

# Requirements

Zig build toolchain does most of the heavy lifting. The only systems
requirement is the [Vulkan SDK](https://www.lunarg.com/vulkan-sdk/). 
Make sure you download Vulkan 1.2 or up 



On linux you should get any [listed requirements for glfw](https://www.glfw.org/docs/latest/compile_guide.html)

**This project also uses latest zig version**

# Run the project

Do the following steps 
```bash
$ git clone --recurse-submodules -j4 <repo>
$ cd <folder>
$ zig build run
```

Or

```bash
$ git clone <repo>
$ cd <folder>
$ git submodule update --init --recursive
$ zig build run
```

# Run tests 

Currently the code base is not really well tested, but you can run the few tests by doin ``zig build test``

# Issues

## Linux
 
### Missing asm/ioctls.h

``error: 'asm/ioctls.h' file not found`` might be due to missing kernel headers. A work around if you have verfified that they are indeed installed is to create a symlink: ``sudo ln -s /usr/include/asm-generic /usr/include/asm``

# Sources:

* Vulkan fundementals: 
  * https://vkguide.dev/
  * https://vulkan-tutorial.com
* Setup Zig for Gamedev: https://dev.to/fabioarnold/setup-zig-for-gamedev-2bmf 
* Using vulkan-zig: https://github.com/Snektron/vulkan-zig/blob/master/examples
