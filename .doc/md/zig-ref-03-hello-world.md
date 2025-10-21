# Hello World

## Basic Example

**File: hello.zig**
```zig
const std = @import("std");

pub fn main() !void {
    try std.fs.File.stdout().writeAll("Hello, World!\n");
}
```

**Shell**
```shell
$ zig build-exe hello.zig
$ ./hello
Hello, World!
```

## Simpler Approach

Most of the time, it is more appropriate to write to stderr rather than stdout, and whether or not the message is successfully written to the stream is irrelevant. Also, formatted printing often comes in handy. For this common case, there is a simpler API:

**File: hello_again.zig**
```zig
const std = @import("std");

pub fn main() void {
    std.debug.print("Hello, {s}!\n", .{"World"});
}
```

**Shell**
```shell
$ zig build-exe hello_again.zig
$ ./hello_again
Hello, World!
```

In this case, the `!` may be omitted from the return type of `main` because no errors are returned from the function.

## See also

- [Values](#values)
- [Tuples](#tuples)
- [@import](#import)
- [Errors](#errors)
- [Entry Point](#entry-point)
- [Source Encoding](#source-encoding)
- [try](#try)
