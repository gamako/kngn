# unreachable

In [Debug](#Debug) and [ReleaseSafe](#ReleaseSafe) mode
 `unreachable` emits a call to `panic` with the message `reached unreachable code`.
 

 

 In [ReleaseFast](#ReleaseFast) and [ReleaseSmall](#ReleaseSmall) mode, the optimizer uses the assumption that `unreachable` code
 will never be hit to perform optimizations.
 

 
## Basics

 
**File: test_unreachable.zig**
```zig
// unreachable is used to assert that control flow will never reach a
// particular location:
test "basic math" {
 const x = 1;
 const y = 2;
 if (x + y != 3) {
 unreachable;
 }
}
```

**Shell**
```shell
$ zig test test_unreachable.zig
1/1 test_unreachable.test.basic math...OK
All 1 tests passed.
```

 
In fact, this is how `std.debug.assert` is implemented:

 
**File: test_assertion_failure.zig**
```zig
// This is how std.debug.assert is implemented
fn assert(ok: bool) void {
 if (!ok) unreachable; // assertion failure
}

// This test will fail because we hit unreachable.
test "this will fail" {
 assert(false);
}
```

**Shell**
```shell
$ zig test test_assertion_failure.zig
1/1 test_assertion_failure.test.this will fail...thread 3099891 panic: reached unreachable code
/home/ci/actions-runner/_work/zig-bootstrap/zig/doc/langref/test_assertion_failure.zig:3:14: 0x102d039 in assert (test_assertion_failure.zig)
 if (!ok) unreachable; // assertion failure
 ^
/home/ci/actions-runner/_work/zig-bootstrap/zig/doc/langref/test_assertion_failure.zig:8:11: 0x102d00e in test.this will fail (test_assertion_failure.zig)
 assert(false);
 ^
/home/ci/actions-runner/_work/zig-bootstrap/out/host/lib/zig/compiler/test_runner.zig:240:25: 0x115872f in mainTerminal (test_runner.zig)
 if (test_fn.func()) |_| {
 ^
/home/ci/actions-runner/_work/zig-bootstrap/out/host/lib/zig/compiler/test_runner.zig:69:28: 0x1152f66 in main (test_runner.zig)
 return mainTerminal();
 ^
/home/ci/actions-runner/_work/zig-bootstrap/out/host/lib/zig/std/start.zig:618:22: 0x114e63c in callMain (std.zig)
 root.main();
 ^
/home/ci/actions-runner/_work/zig-bootstrap/out/host/lib/zig/std/start.zig:232:5: 0x114e111 in _start (std.zig)
 asm volatile (switch (native_arch) {
 ^
error: the following test command crashed:
/home/ci/actions-runner/_work/zig-bootstrap/out/zig-local-cache/o/e47dc9b182d578933621ceceafbd6473/test --seed=0xc9ddb48c
```

 
 
## At Compile-Time

 
**File: test_comptime_unreachable.zig**
```zig
const assert = @import("std").debug.assert;

test "type of unreachable" {
 comptime {
 // The type of unreachable is noreturn.

 // However this assertion will still fail to compile because
 // unreachable expressions are compile errors.

 assert(@TypeOf(unreachable) == noreturn);
 }
}
```

**Shell**
```shell
$ zig test test_comptime_unreachable.zig
/home/ci/actions-runner/_work/zig-bootstrap/zig/doc/langref/test_comptime_unreachable.zig:10:16: error: unreachable code
 assert(@TypeOf(unreachable) == noreturn);
 ^~~~~~~~~~~~~~~~~~~~
/home/ci/actions-runner/_work/zig-bootstrap/zig/doc/langref/test_comptime_unreachable.zig:10:24: note: control flow is diverted here
 assert(@TypeOf(unreachable) == noreturn);
 ^~~~~~~~~~~
```

 
See also:

- [Zig Test](#Zig-Test)
- [Build Mode](#Build-Mode)
- [comptime](#comptime)