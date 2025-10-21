# Variables

A variable is a unit of [Memory](#Memory) storage.
 

 

 It is generally preferable to use `const` rather than
 `var` when declaring a variable. This causes less work for both
 humans and computers to do when reading code, and creates more optimization opportunities.
 

 

 The `extern` keyword or [@extern](#extern) builtin function can be used to link against a variable that is exported
 from another object. The `export` keyword or [@export](#export) builtin function
 can be used to make a variable available to other objects at link time. In both cases,
 the type of the variable must be C ABI compatible.
 

 
See also:

- [Exporting a C Library](#Exporting-a-C-Library)

 
## Identifiers

 

 Variable identifiers are never allowed to shadow identifiers from an outer scope.
 

 

 Identifiers must start with an alphabetic character or underscore and may be followed
 by any number of alphanumeric characters or underscores.
 They must not overlap with any keywords. See [Keyword Reference](#Keyword-Reference).
 

 

 If a name that does not fit these requirements is needed, such as for linking with external libraries, the `@""` syntax may be used.
 

 
**File: identifiers.zig**
```zig
const @"identifier with spaces in it" = 0xff;
const @"1SmallStep4Man" = 112358;

const c = @import("std").c;
pub extern "c" fn @"error"() void;
pub extern "c" fn @"fstat$INODE64"(fd: c.fd_t, buf: *c.Stat) c_int;

const Color = enum {
 red,
 @"really red",
};
const color: Color = .@"really red";
```

 

 
## Container Level Variables

 

 [Container](#Containers) level variables have static lifetime and are order-independent and lazily analyzed.
 The initialization value of container level variables is implicitly
 [comptime](#comptime). If a container level variable is `const` then its value is
 `comptime`-known, otherwise it is runtime-known.
 

 
**File: test_container_level_variables.zig**
```zig
var y: i32 = add(10, x);
const x: i32 = add(12, 34);

test "container level variables" {
 try expect(x == 46);
 try expect(y == 56);
}

fn add(a: i32, b: i32) i32 {
 return a + b;
}

const std = @import("std");
const expect = std.testing.expect;
```

**Shell**
```shell
$ zig test test_container_level_variables.zig
1/1 test_container_level_variables.test.container level variables...OK
All 1 tests passed.
```

 

 Container level variables may be declared inside a [struct](#struct), [union](#union), [enum](#enum), or [opaque](#opaque):
 

 
**File: test_namespaced_container_level_variable.zig**
```zig
const std = @import("std");
const expect = std.testing.expect;

test "namespaced container level variable" {
 try expect(foo() == 1235);
 try expect(foo() == 1236);
}

const S = struct {
 var x: i32 = 1234;
};

fn foo() i32 {
 S.x += 1;
 return S.x;
}
```

**Shell**
```shell
$ zig test test_namespaced_container_level_variable.zig
1/1 test_namespaced_container_level_variable.test.namespaced container level variable...OK
All 1 tests passed.
```

 

 
## Static Local Variables

 

 It is also possible to have local variables with static lifetime by using containers inside functions.
 

 
**File: test_static_local_variable.zig**
```zig
const std = @import("std");
const expect = std.testing.expect;

test "static local variable" {
 try expect(foo() == 1235);
 try expect(foo() == 1236);
}

fn foo() i32 {
 const S = struct {
 var x: i32 = 1234;
 };
 S.x += 1;
 return S.x;
}
```

**Shell**
```shell
$ zig test test_static_local_variable.zig
1/1 test_static_local_variable.test.static local variable...OK
All 1 tests passed.
```

 

 
## Thread Local Variables

 
A variable may be specified to be a thread-local variable using the
 `threadlocal` keyword,
 which makes each thread work with a separate instance of the variable:

 
**File: test_thread_local_variables.zig**
```zig
const std = @import("std");
const assert = std.debug.assert;

threadlocal var x: i32 = 1234;

test "thread local storage" {
 const thread1 = try std.Thread.spawn(.{}, testTls, .{});
 const thread2 = try std.Thread.spawn(.{}, testTls, .{});
 testTls();
 thread1.join();
 thread2.join();
}

fn testTls() void {
 assert(x == 1234);
 x += 1;
 assert(x == 1235);
}
```

**Shell**
```shell
$ zig test test_thread_local_variables.zig
1/1 test_thread_local_variables.test.thread local storage...OK
All 1 tests passed.
```

 

 For [Single Threaded Builds](#Single-Threaded-Builds), all thread local variables are treated as regular [Container Level Variables](#Container-Level-Variables).
 

 

 Thread local variables may not be `const`.
 

 

 
## Local Variables

 

 Local variables occur inside [Functions](#Functions), [comptime](#comptime) blocks, and [@cImport](#cImport) blocks.
 

 

 When a local variable is `const`, it means that after initialization, the variable's
 value will not change. If the initialization value of a `const` variable is
 [comptime](#comptime)-known, then the variable is also `comptime`-known.
 

 

 A local variable may be qualified with the `comptime` keyword. This causes
 the variable's value to be `comptime`-known, and all loads and stores of the
 variable to happen during semantic analysis of the program, rather than at runtime.
 All variables declared in a `comptime` expression are implicitly
 `comptime` variables.
 

 
**File: test_comptime_variables.zig**
```zig
const std = @import("std");
const expect = std.testing.expect;

test "comptime vars" {
 var x: i32 = 1;
 comptime var y: i32 = 1;

 x += 1;
 y += 1;

 try expect(x == 2);
 try expect(y == 2);

 if (y != 2) {
 // This compile error never triggers because y is a comptime variable,
 // and so `y != 2` is a comptime value, and this if is statically evaluated.
 @compileError("wrong y value");
 }
}
```

**Shell**
```shell
$ zig test test_comptime_variables.zig
1/1 test_comptime_variables.test.comptime vars...OK
All 1 tests passed.
```