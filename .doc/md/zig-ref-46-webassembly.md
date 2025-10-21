# WebAssembly

Zig supports building for WebAssembly out of the box.

 
## Freestanding

 
For host environments like the web browser and nodejs, build as an executable using the freestanding
 OS target. Here's an example of running Zig code compiled to WebAssembly with nodejs.

 
**File: math.zig**
```zig
extern fn print(i32) void;

export fn add(a: i32, b: i32) void {
 print(a + b);
}
```

**Shell**
```shell
$ zig build-exe math.zig -target wasm32-freestanding -fno-entry --export=add
```

 
```zig
const fs = require('fs');
const source = fs.readFileSync("./math.wasm");
const typedArray = new Uint8Array(source);

WebAssembly.instantiate(typedArray, {
 env: {
 print: (result) => { console.log(`The result is ${result}`); }
 }}).then(result => {
 const add = result.instance.exports.add;
 add(1, 2);
});
```

 
**Shell**
```shell
$ node test.js
The result is 3
```

 
 
## WASI

 
Zig's support for WebAssembly System Interface (WASI) is under active development.
 Example of using the standard library and reading command line arguments:

 
**File: wasi_args.zig**
```zig
const std = @import("std");

pub fn main() !void {
 var general_purpose_allocator: std.heap.GeneralPurposeAllocator(.{}) = .init;
 const gpa = general_purpose_allocator.allocator();
 const args = try std.process.argsAlloc(gpa);
 defer std.process.argsFree(gpa, args);

 for (args, 0..) |arg, i| {
 std.debug.print("{}: {s}\n", .{ i, arg });
 }
}
```

**Shell**
```shell
$ zig build-exe wasi_args.zig -target wasm32-wasi
```

 
**Shell**
```shell
$ wasmtime wasi_args.wasm 123 hello
0: wasi_args.wasm
1: 123
2: hello
```

 
A more interesting example would be extracting the list of preopens from the runtime.
 This is now supported in the standard library via `std.fs.wasi.Preopens`:

 
**File: wasi_preopens.zig**
```zig
const std = @import("std");
const fs = std.fs;

pub fn main() !void {
 var general_purpose_allocator: std.heap.GeneralPurposeAllocator(.{}) = .init;
 const gpa = general_purpose_allocator.allocator();

 var arena_instance = std.heap.ArenaAllocator.init(gpa);
 defer arena_instance.deinit();
 const arena = arena_instance.allocator();

 const preopens = try fs.wasi.preopensAlloc(arena);

 for (preopens.names, 0..) |preopen, i| {
 std.debug.print("{}: {s}\n", .{ i, preopen });
 }
}
```

**Shell**
```shell
$ zig build-exe wasi_preopens.zig -target wasm32-wasi
```

 
**Shell**
```shell
$ wasmtime --dir=. wasi_preopens.wasm
0: stdin
1: stdout
2: stderr
3: .
```