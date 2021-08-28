# stb_image zig wrapper 
A primitive wrapper for stb in zig

# What
stb_image is a part of the great header only library stb. Source code can be found [here](https://github.com/nothings/stb)

# How to use
Add the following to your build script
```zig 
const stbi = @import("path/to/stbi/build.zig");

// ... later in build function
stbi.linkStep(b, exe);
```
