# Zig Build System

The Zig Build System provides a cross-platform, dependency-free way to declare
 the logic required to build a project. With this system, the logic to build
 a project is written in a build.zig file, using the Zig Build System API to
 declare and configure build artifacts and other tasks.
 

 

 Some examples of tasks the build system can help with:
 

 
- Performing tasks in parallel and caching the results.
- Depending on other projects.
- Providing a package for other projects to depend on.
- Creating build artifacts by executing the Zig compiler. This includes building Zig source code as well as C and C++ source code.
- Capturing user-configured options and using those options to configure the build.
- Surfacing build configuration as [comptime](#comptime) values by providing a file that can be [imported](#import) by Zig code.
- Caching build artifacts to avoid unnecessarily repeating steps.
- Executing build artifacts or system-installed tools.
- Running tests and verifying the output of executing a build artifact matches the expected value.
- Running `zig fmt` on a codebase or a subset of it.
- Custom tasks.

 

 To use the build system, run zig build --help
 to see a command-line usage help menu. This will include project-specific
 options that were declared in the build.zig script.
 

 

 For the time being, the build system documentation is hosted externally:
 [Build System Documentation](https://ziglang.org/learn/build-system/)