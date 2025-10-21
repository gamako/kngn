# defer

Executes an expression unconditionally at scope exit.

 
**File: test_defer.zig**
```zig
const std = @import("std");
const expect = std.testing.expect;
const print = std.debug.print;

fn deferExample() !usize {
 var a: usize = 1;

 {
 defer a = 2;
 a = 1;
 }
 try expect(a == 2);

 a = 5;
 return a;
}

test "defer basics" {
 try expect((try deferExample()) == 5);
}
```

**Shell**
```shell
$ zig test test_defer.zig
1/1 test_defer.test.defer basics...OK
All 1 tests passed.
```

 
Defer expressions are evaluated in reverse order.

 
**File: defer_unwind.zig**
```zig
const std = @import("std");
const print = std.debug.print;

pub fn main() void {
 print("\n", .{});

 defer {
 print("1 ", .{});
 }
 defer {
 print("2 ", .{});
 }
 if (false) {
 // defers are not run if they are never executed.
 defer {
 print("3 ", .{});
 }
 }
}
```

**Shell**
```shell
$ zig build-exe defer_unwind.zig
$ ./defer_unwind

2 1
```

 
Inside a defer expression the return statement is not allowed.

 
**File: test_invalid_defer.zig**
```zig
fn deferInvalidExample() !void {
 defer {
 return error.DeferError;
 }

 return error.DeferError;
}
```

**Shell**
```shell
$ zig test test_invalid_defer.zig
/home/ci/actions-runner/_work/zig-bootstrap/zig/doc/langref/test_invalid_defer.zig:3:9: error: cannot return from defer expression
 return error.DeferError;
 ^~~~~~~~~~~~~~~~~~~~~~~
/home/ci/actions-runner/_work/zig-bootstrap/zig/doc/langref/test_invalid_defer.zig:2:5: note: defer expression here
 defer {
 ^~~~~
```

 
See also:

- [Errors](#Errors)