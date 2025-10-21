# noreturn

`noreturn` is the type of:
 

 
- `break`
- `continue`
- `return`
- `unreachable`
- `while (true) {}`

 
When resolving types together, such as `if` clauses or `switch` prongs,
 the `noreturn` type is compatible with every other type. Consider:
 

 
**File: test_noreturn.zig**
```zig
fn foo(condition: bool, b: u32) void {
 const a = if (condition) b else return;
 _ = a;
 @panic("do something with a");
}
test "noreturn" {
 foo(false, 1);
}
```

**Shell**
```shell
$ zig test test_noreturn.zig
1/1 test_noreturn.test.noreturn...OK
All 1 tests passed.
```

 
Another use case for `noreturn` is the `exit` function:

 
**File: test_noreturn_from_exit.zig**
```zig
const std = @import("std");
const builtin = @import("builtin");
const native_arch = builtin.cpu.arch;
const expect = std.testing.expect;

const WINAPI: std.builtin.CallingConvention = if (native_arch == .x86) .{ .x86_stdcall = .{} } else .c;
extern "kernel32" fn ExitProcess(exit_code: c_uint) callconv(WINAPI) noreturn;

test "foo" {
 const value = bar() catch ExitProcess(1);
 try expect(value == 1234);
}

fn bar() anyerror!u32 {
 return 1234;
}
```

**Shell**
```shell
$ zig test test_noreturn_from_exit.zig -target x86_64-windows --test-no-exec
```