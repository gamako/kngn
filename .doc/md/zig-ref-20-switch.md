# switch

**File: test_switch.zig**
```zig
const std = @import("std");
const builtin = @import("builtin");
const expect = std.testing.expect;

test "switch simple" {
 const a: u64 = 10;
 const zz: u64 = 103;

 // All branches of a switch expression must be able to be coerced to a
 // common type.
 //
 // Branches cannot fallthrough. If fallthrough behavior is desired, combine
 // the cases and use an if.
 const b = switch (a) {
 // Multiple cases can be combined via a ','
 1, 2, 3 => 0,

 // Ranges can be specified using the ... syntax. These are inclusive
 // of both ends.
 5...100 => 1,

 // Branches can be arbitrarily complex.
 101 => blk: {
 const c: u64 = 5;
 break :blk c * 2 + 1;
 },

 // Switching on arbitrary expressions is allowed as long as the
 // expression is known at compile-time.
 zz => zz,
 blk: {
 const d: u32 = 5;
 const e: u32 = 100;
 break :blk d + e;
 } => 107,

 // The else branch catches everything not already captured.
 // Else branches are mandatory unless the entire range of values
 // is handled.
 else => 9,
 };

 try expect(b == 1);
}

// Switch expressions can be used outside a function:
const os_msg = switch (builtin.target.os.tag) {
 .linux => "we found a linux user",
 else => "not a linux user",
};

// Inside a function, switch statements implicitly are compile-time
// evaluated if the target expression is compile-time known.
test "switch inside function" {
 switch (builtin.target.os.tag) {
 .fuchsia => {
 // On an OS other than fuchsia, block is not even analyzed,
 // so this compile error is not triggered.
 // On fuchsia this compile error would be triggered.
 @compileError("fuchsia not supported");
 },
 else => {},
 }
}
```

**Shell**
```shell
$ zig test test_switch.zig
1/2 test_switch.test.switch simple...OK
2/2 test_switch.test.switch inside function...OK
All 2 tests passed.
```

 

 `switch` can be used to capture the field values
 of a [Tagged union](#Tagged-union). Modifications to the field values can be
 done by placing a `*` before the capture variable name,
 turning it into a pointer.
 

 
**File: test_switch_tagged_union.zig**
```zig
const expect = @import("std").testing.expect;

test "switch on tagged union" {
 const Point = struct {
 x: u8,
 y: u8,
 };
 const Item = union(enum) {
 a: u32,
 c: Point,
 d,
 e: u32,
 };

 var a = Item{ .c = Point{ .x = 1, .y = 2 } };

 // Switching on more complex enums is allowed.
 const b = switch (a) {
 // A capture group is allowed on a match, and will return the enum
 // value matched. If the payload types of both cases are the same
 // they can be put into the same switch prong.
 Item.a, Item.e => |item| item,

 // A reference to the matched value can be obtained using `*` syntax.
 Item.c => |*item| blk: {
 item.*.x += 1;
 break :blk 6;
 },

 // No else is required if the types cases was exhaustively handled
 Item.d => 8,
 };

 try expect(b == 6);
 try expect(a.c.x == 2);
}
```

**Shell**
```shell
$ zig test test_switch_tagged_union.zig
1/1 test_switch_tagged_union.test.switch on tagged union...OK
All 1 tests passed.
```

 
See also:

- [comptime](#comptime)
- [enum](#enum)
- [@compileError](#compileError)
- [Compile Variables](#Compile-Variables)

 
## Exhaustive Switching

 

 When a `switch` expression does not have an `else` clause,
 it must exhaustively list all the possible values. Failure to do so is a compile error:
 

 
**File: test_unhandled_enumeration_value.zig**
```zig
const Color = enum {
 auto,
 off,
 on,
};

test "exhaustive switching" {
 const color = Color.off;
 switch (color) {
 Color.auto => {},
 Color.on => {},
 }
}
```

**Shell**
```shell
$ zig test test_unhandled_enumeration_value.zig
/home/ci/actions-runner/_work/zig-bootstrap/zig/doc/langref/test_unhandled_enumeration_value.zig:9:5: error: switch must handle all possibilities
 switch (color) {
 ^~~~~~
/home/ci/actions-runner/_work/zig-bootstrap/zig/doc/langref/test_unhandled_enumeration_value.zig:3:5: note: unhandled enumeration value: 'off'
 off,
 ^~~
/home/ci/actions-runner/_work/zig-bootstrap/zig/doc/langref/test_unhandled_enumeration_value.zig:1:15: note: enum 'test_unhandled_enumeration_value.Color' declared here
const Color = enum {
 ^~~~
```

 

 
## Switching with Enum Literals

 

 [Enum Literals](#Enum-Literals) can be useful to use with `switch` to avoid
 repetitively specifying [enum](#enum) or [union](#union) types:
 

 
**File: test_exhaustive_switch.zig**
```zig
const std = @import("std");
const expect = std.testing.expect;

const Color = enum {
 auto,
 off,
 on,
};

test "enum literals with switch" {
 const color = Color.off;
 const result = switch (color) {
 .auto => false,
 .on => false,
 .off => true,
 };
 try expect(result);
}
```

**Shell**
```shell
$ zig test test_exhaustive_switch.zig
1/1 test_exhaustive_switch.test.enum literals with switch...OK
All 1 tests passed.
```

 

 
## Labeled switch

 

 When a switch statement is labeled, it can be referenced from a
 `break` or `continue`.
 `break` will return a value from the `switch`.
 

 

 A `continue` targeting a switch must have an
 operand. When executed, it will jump to the matching prong, as if the
 `switch` were executed again with the `continue`'s operand replacing the initial switch value.
 

 
**File: test_switch_continue.zig**
```zig
const std = @import("std");

test "switch continue" {
 sw: switch (@as(i32, 5)) {
 5 => continue :sw 4,

 // `continue` can occur multiple times within a single switch prong.
 2...4 => |v| {
 if (v > 3) {
 continue :sw 2;
 } else if (v == 3) {

 // `break` can target labeled loops.
 break :sw;
 }

 continue :sw 1;
 },

 1 => return,

 else => unreachable,
 }
}
```

**Shell**
```shell
$ zig test test_switch_continue.zig
1/1 test_switch_continue.test.switch continue...OK
All 1 tests passed.
```

 

 Semantically, this is equivalent to the following loop:
 

 
**File: test_switch_continue_equivalent.zig**
```zig
const std = @import("std");

test "switch continue, equivalent loop" {
 var sw: i32 = 5;
 while (true) {
 switch (sw) {
 5 => {
 sw = 4;
 continue;
 },
 2...4 => |v| {
 if (v > 3) {
 sw = 2;
 continue;
 } else if (v == 3) {
 break;
 }

 sw = 1;
 continue;
 },
 1 => return,
 else => unreachable,
 }
 }
}
```

**Shell**
```shell
$ zig test test_switch_continue_equivalent.zig
1/1 test_switch_continue_equivalent.test.switch continue, equivalent loop...OK
All 1 tests passed.
```

 

 This can improve clarity of (for example) state machines, where the syntax `continue :sw .next_state` is unambiguous, explicit, and immediately understandable.
 

 

 However, the motivating example is a switch on each element of an array, where using a single switch can improve clarity and performance:
 

 
**File: test_switch_dispatch_loop.zig**
```zig
const std = @import("std");
const expectEqual = std.testing.expectEqual;

const Instruction = enum {
 add,
 mul,
 end,
};

fn evaluate(initial_stack: []const i32, code: []const Instruction) !i32 {
 var buffer: [8]i32 = undefined;
 var stack = std.ArrayListUnmanaged(i32).initBuffer(&buffer);
 try stack.appendSliceBounded(initial_stack);
 var ip: usize = 0;

 return vm: switch (code[ip]) {
 // Because all code after `continue` is unreachable, this branch does
 // not provide a result.
 .add => {
 try stack.appendBounded(stack.pop().? + stack.pop().?);

 ip += 1;
 continue :vm code[ip];
 },
 .mul => {
 try stack.appendBounded(stack.pop().? * stack.pop().?);

 ip += 1;
 continue :vm code[ip];
 },
 .end => stack.pop().?,
 };
}

test "evaluate" {
 const result = try evaluate(&.{ 7, 2, -3 }, &.{ .mul, .add, .end });
 try expectEqual(1, result);
}
```

**Shell**
```shell
$ zig test test_switch_dispatch_loop.zig
1/1 test_switch_dispatch_loop.test.evaluate...OK
All 1 tests passed.
```

 

 If the operand to `continue` is
 [comptime](#comptime)-known, then it can be lowered to an unconditional branch
 to the relevant case. Such a branch is perfectly predicted, and hence
 typically very fast to execute.
 

 

 If the operand is runtime-known, each `continue` can
 embed a conditional branch inline (ideally through a jump table), which
 allows a CPU to predict its target independently of any other prong. A
 loop-based lowering would force every branch through the same dispatch
 point, hindering branch prediction.
 

 

 
## Inline Switch Prongs

 

 Switch prongs can be marked as `inline` to generate
 the prong's body for each possible value it could have, making the
 captured value [comptime](#comptime).
 

 
**File: test_inline_switch.zig**
```zig
const std = @import("std");
const expect = std.testing.expect;
const expectError = std.testing.expectError;

fn isFieldOptional(comptime T: type, field_index: usize) !bool {
 const fields = @typeInfo(T).@"struct".fields;
 return switch (field_index) {
 // This prong is analyzed twice with `idx` being a
 // comptime-known value each time.
 inline 0, 1 => |idx| @typeInfo(fields[idx].type) == .optional,
 else => return error.IndexOutOfBounds,
 };
}

const Struct1 = struct { a: u32, b: ?u32 };

test "using @typeInfo with runtime values" {
 var index: usize = 0;
 try expect(!try isFieldOptional(Struct1, index));
 index += 1;
 try expect(try isFieldOptional(Struct1, index));
 index += 1;
 try expectError(error.IndexOutOfBounds, isFieldOptional(Struct1, index));
}

// Calls to `isFieldOptional` on `Struct1` get unrolled to an equivalent
// of this function:
fn isFieldOptionalUnrolled(field_index: usize) !bool {
 return switch (field_index) {
 0 => false,
 1 => true,
 else => return error.IndexOutOfBounds,
 };
}
```

**Shell**
```shell
$ zig test test_inline_switch.zig
1/1 test_inline_switch.test.using @typeInfo with runtime values...OK
All 1 tests passed.
```

 
The `inline` keyword may also be combined with ranges:

 
**File: inline_prong_range.zig**
```zig
fn isFieldOptional(comptime T: type, field_index: usize) !bool {
 const fields = @typeInfo(T).@"struct".fields;
 return switch (field_index) {
 inline 0...fields.len - 1 => |idx| @typeInfo(fields[idx].type) == .optional,
 else => return error.IndexOutOfBounds,
 };
}
```

 

 `inline else` prongs can be used as a type safe
 alternative to `inline for` loops:
 

 
**File: test_inline_else.zig**
```zig
const std = @import("std");
const expect = std.testing.expect;

const SliceTypeA = extern struct {
 len: usize,
 ptr: [*]u32,
};
const SliceTypeB = extern struct {
 ptr: [*]SliceTypeA,
 len: usize,
};
const AnySlice = union(enum) {
 a: SliceTypeA,
 b: SliceTypeB,
 c: []const u8,
 d: []AnySlice,
};

fn withFor(any: AnySlice) usize {
 const Tag = @typeInfo(AnySlice).@"union".tag_type.?;
 inline for (@typeInfo(Tag).@"enum".fields) |field| {
 // With `inline for` the function gets generated as
 // a series of `if` statements relying on the optimizer
 // to convert it to a switch.
 if (field.value == @intFromEnum(any)) {
 return @field(any, field.name).len;
 }
 }
 // When using `inline for` the compiler doesn't know that every
 // possible case has been handled requiring an explicit `unreachable`.
 unreachable;
}

fn withSwitch(any: AnySlice) usize {
 return switch (any) {
 // With `inline else` the function is explicitly generated
 // as the desired switch and the compiler can check that
 // every possible case is handled.
 inline else => |slice| slice.len,
 };
}

test "inline for and inline else similarity" {
 const any = AnySlice{ .c = "hello" };
 try expect(withFor(any) == 5);
 try expect(withSwitch(any) == 5);
}
```

**Shell**
```shell
$ zig test test_inline_else.zig
1/1 test_inline_else.test.inline for and inline else similarity...OK
All 1 tests passed.
```

 

 When using an inline prong switching on an union an additional
 capture can be used to obtain the union's enum tag value.
 

 
**File: test_inline_switch_union_tag.zig**
```zig
const std = @import("std");
const expect = std.testing.expect;

const U = union(enum) {
 a: u32,
 b: f32,
};

fn getNum(u: U) u32 {
 switch (u) {
 // Here `num` is a runtime-known value that is either
 // `u.a` or `u.b` and `tag` is `u`'s comptime-known tag value.
 inline else => |num, tag| {
 if (tag == .b) {
 return @intFromFloat(num);
 }
 return num;
 },
 }
}

test "test" {
 const u = U{ .b = 42 };
 try expect(getNum(u) == 42);
}
```

**Shell**
```shell
$ zig test test_inline_switch_union_tag.zig
1/1 test_inline_switch_union_tag.test.test...OK
All 1 tests passed.
```

 
See also:

- [inline while](#inline-while)
- [inline for](#inline-for)