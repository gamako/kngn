# Blocks

Blocks are used to limit the scope of variable declarations:
 

 
**File: test_blocks.zig**
```zig
test "access variable after block scope" {
 {
 var x: i32 = 1;
 _ = &x;
 }
 x += 1;
}
```

**Shell**
```shell
$ zig test test_blocks.zig
/home/ci/actions-runner/_work/zig-bootstrap/zig/doc/langref/test_blocks.zig:6:5: error: use of undeclared identifier 'x'
 x += 1;
 ^
```

 
Blocks are expressions. When labeled, `break` can be used
 to return a value from the block:
 

 
**File: test_labeled_break.zig**
```zig
const std = @import("std");
const expect = std.testing.expect;

test "labeled break from labeled block expression" {
 var y: i32 = 123;

 const x = blk: {
 y += 1;
 break :blk y;
 };
 try expect(x == 124);
 try expect(y == 124);
}
```

**Shell**
```shell
$ zig test test_labeled_break.zig
1/1 test_labeled_break.test.labeled break from labeled block expression...OK
All 1 tests passed.
```

 
Here, `blk` can be any name.

 
See also:

- [Labeled while](#Labeled-while)
- [Labeled for](#Labeled-for)

 
## Shadowing

 
[Identifiers](#Identifiers) are never allowed to "hide" other identifiers by using the same name:

 
**File: test_shadowing.zig**
```zig
const pi = 3.14;

test "inside test block" {
 // Let's even go inside another block
 {
 var pi: i32 = 1234;
 }
}
```

**Shell**
```shell
$ zig test test_shadowing.zig
/home/ci/actions-runner/_work/zig-bootstrap/zig/doc/langref/test_shadowing.zig:6:13: error: local variable shadows declaration of 'pi'
 var pi: i32 = 1234;
 ^~
/home/ci/actions-runner/_work/zig-bootstrap/zig/doc/langref/test_shadowing.zig:1:1: note: declared here
const pi = 3.14;
^~~~~~~~~~~~~~~
```

 

 Because of this, when you read Zig code you can always rely on an identifier to consistently mean
 the same thing within the scope it is defined. Note that you can, however, use the same name if
 the scopes are separate:
 

 
**File: test_scopes.zig**
```zig
test "separate scopes" {
 {
 const pi = 3.14;
 _ = pi;
 }
 {
 var pi: bool = true;
 _ = π
 }
}
```

**Shell**
```shell
$ zig test test_scopes.zig
1/1 test_scopes.test.separate scopes...OK
All 1 tests passed.
```

 

 
## Empty Blocks

 
An empty block is equivalent to `void{}`:

 
**File: test_empty_block.zig**
```zig
const std = @import("std");
const expect = std.testing.expect;

test {
 const a = {};
 const b = void{};
 try expect(@TypeOf(a) == void);
 try expect(@TypeOf(b) == void);
 try expect(a == b);
}
```

**Shell**
```shell
$ zig test test_empty_block.zig
1/1 test_empty_block.test_0...OK
All 1 tests passed.
```