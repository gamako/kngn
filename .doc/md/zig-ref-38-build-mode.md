# Build Mode

Zig has four build modes:
 

 
- [Debug](#Debug) (default)
- [ReleaseFast](#ReleaseFast)
- [ReleaseSafe](#ReleaseSafe)
- [ReleaseSmall](#ReleaseSmall)

 

 To add standard build options to a build.zig file:
 

 
**File: build.zig**
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
 const optimize = b.standardOptimizeOption(.{});
 const exe = b.addExecutable(.{
 .name = "example",
 .root_module = b.createModule(.{
 .root_source_file = b.path("example.zig"),
 .optimize = optimize,
 }),
 });
 b.default_step.dependOn(&exe.step);
}
```

 

 This causes these options to be available:
 

 
 -Doptimize=DebugOptimizations off and safety on (default)
 -Doptimize=ReleaseSafeOptimizations on and safety on
 -Doptimize=ReleaseFastOptimizations on and safety off
 -Doptimize=ReleaseSmallSize optimizations on and safety off
 
 
## Debug

 
**Shell**
```shell
$ zig build-exe example.zig
```

 
- Fast compilation speed
- Safety checks enabled
- Slow runtime performance
- Large binary size
- No reproducible build requirement

 
 
## ReleaseFast

 
**Shell**
```shell
$ zig build-exe example.zig -O ReleaseFast
```

 
- Fast runtime performance
- Safety checks disabled
- Slow compilation speed
- Large binary size
- Reproducible build

 
 
## ReleaseSafe

 
**Shell**
```shell
$ zig build-exe example.zig -O ReleaseSafe
```

 
- Medium runtime performance
- Safety checks enabled
- Slow compilation speed
- Large binary size
- Reproducible build

 
 
## ReleaseSmall

 
**Shell**
```shell
$ zig build-exe example.zig -O ReleaseSmall
```

 
- Medium runtime performance
- Safety checks disabled
- Slow compilation speed
- Small binary size
- Reproducible build

 
 
See also:

- [Compile Variables](#Compile-Variables)
- [Zig Build System](#Zig-Build-System)
- [Illegal Behavior](#Illegal-Behavior)