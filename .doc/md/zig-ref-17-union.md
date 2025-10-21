# union

A bare `union` defines a set of possible types that a value
 can be as a list of fields. Only one field can be active at a time.
 The in-memory representation of bare unions is not guaranteed.
 Bare unions cannot be used to reinterpret memory. For that, use [@ptrCast](#ptrCast),
 or use an [extern union](#extern-union) or a [packed union](#packed-union) which have
 guaranteed in-memory layout.
 [Accessing the non-active field](#Wrong-Union-Field-Access) is
 safety-checked [Illegal Behavior](#Illegal-Behavior):
 

 
**File: test_wrong_union_access.zig**
```zig
const Payload = union {
 int: i64,
 float: f64,
 boolean: bool,
};
test "simple union" {
 var payload = Payload{ .int = 1234 };
 payload.float = 12.34;
}
```

**Shell**
```shell
$ zig test test_wrong_union_access.zig
1/1 test_wrong_union_access.test.simple union...thread 3100045 panic: access of union field 'float' while field 'int' is active
/home/ci/actions-runner/_work/zig-bootstrap/zig/doc/langref/test_wrong_union_access.zig:8:12: 0x102d042 in test.simple union (test_wrong_union_access.zig)
 payload.float = 12.34;
 ^
/home/ci/actions-runner/_work/zig-bootstrap/out/host/lib/zig/compiler/test_runner.zig:240:25: 0x11588cf in mainTerminal (test_runner.zig)
 if (test_fn.func()) |_| {
 ^
/home/ci/actions-runner/_work/zig-bootstrap/out/host/lib/zig/compiler/test_runner.zig:69:28: 0x1153106 in main (test_runner.zig)
 return mainTerminal();
 ^
/home/ci/actions-runner/_work/zig-bootstrap/out/host/lib/zig/std/start.zig:618:22: 0x114e7dc in callMain (std.zig)
 root.main();
 ^
/home/ci/actions-runner/_work/zig-bootstrap/out/host/lib/zig/std/start.zig:232:5: 0x114e2b1 in _start (std.zig)
 asm volatile (switch (native_arch) {
 ^
error: the following test command crashed:
/home/ci/actions-runner/_work/zig-bootstrap/out/zig-local-cache/o/ba5a0156643a412bd3e89c79d2cabdc1/test --seed=0x61559cdd
```

 
You can activate another field by assigning the entire union:

 
**File: test_simple_union.zig**
```zig
const std = @import("std");
const expect = std.testing.expect;

const Payload = union {
 int: i64,
 float: f64,
 boolean: bool,
};
test "simple union" {
 var payload = Payload{ .int = 1234 };
 try expect(payload.int == 1234);
 payload = Payload{ .float = 12.34 };
 try expect(payload.float == 12.34);
}
```

**Shell**
```shell
$ zig test test_simple_union.zig
1/1 test_simple_union.test.simple union...OK
All 1 tests passed.
```

 

 In order to use [switch](#switch) with a union, it must be a [Tagged union](#Tagged-union).
 

 

 To initialize a union when the tag is a [comptime](#comptime)-known name, see [@unionInit](#unionInit).
 

 
## Tagged union

 
Unions can be declared with an enum tag type.
 This turns the union into a tagged union, which makes it eligible
 to use with [switch](#switch) expressions.
 Tagged unions coerce to their tag type: [Type Coercion: Unions and Enums](#Type-Coercion-Unions-and-Enums).
 

 
**File: test_tagged_union.zig**
```zig
const std = @import("std");
const expect = std.testing.expect;

const ComplexTypeTag = enum {
 ok,
 not_ok,
};
const ComplexType = union(ComplexTypeTag) {
 ok: u8,
 not_ok: void,
};

test "switch on tagged union" {
 const c = ComplexType{ .ok = 42 };
 try expect(@as(ComplexTypeTag, c) == ComplexTypeTag.ok);

 switch (c) {
 .ok => |value| try expect(value == 42),
 .not_ok => unreachable,
 }
}

test "get tag type" {
 try expect(std.meta.Tag(ComplexType) == ComplexTypeTag);
}
```

**Shell**
```shell
$ zig test test_tagged_union.zig
1/2 test_tagged_union.test.switch on tagged union...OK
2/2 test_tagged_union.test.get tag type...OK
All 2 tests passed.
```

 
In order to modify the payload of a tagged union in a switch expression,
 place a `*` before the variable name to make it a pointer:
 

 
**File: test_switch_modify_tagged_union.zig**
```zig
const std = @import("std");
const expect = std.testing.expect;

const ComplexTypeTag = enum {
 ok,
 not_ok,
};
const ComplexType = union(ComplexTypeTag) {
 ok: u8,
 not_ok: void,
};

test "modify tagged union in switch" {
 var c = ComplexType{ .ok = 42 };

 switch (c) {
 ComplexTypeTag.ok => |*value| value.* += 1,
 ComplexTypeTag.not_ok => unreachable,
 }

 try expect(c.ok == 43);
}
```

**Shell**
```shell
$ zig test test_switch_modify_tagged_union.zig
1/1 test_switch_modify_tagged_union.test.modify tagged union in switch...OK
All 1 tests passed.
```

 

 Unions can be made to infer the enum tag type.
 Further, unions can have methods just like structs and enums.
 

 
**File: test_union_method.zig**
```zig
const std = @import("std");
const expect = std.testing.expect;

const Variant = union(enum) {
 int: i32,
 boolean: bool,

 // void can be omitted when inferring enum tag type.
 none,

 fn truthy(self: Variant) bool {
 return switch (self) {
 Variant.int => |x_int| x_int != 0,
 Variant.boolean => |x_bool| x_bool,
 Variant.none => false,
 };
 }
};

test "union method" {
 var v1: Variant = .{ .int = 1 };
 var v2: Variant = .{ .boolean = false };
 var v3: Variant = .none;

 try expect(v1.truthy());
 try expect(!v2.truthy());
 try expect(!v3.truthy());
}
```

**Shell**
```shell
$ zig test test_union_method.zig
1/1 test_union_method.test.union method...OK
All 1 tests passed.
```

 

 Unions with inferred enum tag types can also assign ordinal values to their inferred tag.
 This requires the tag to specify an explicit integer type.
 [@intFromEnum](#intFromEnum) can be used to access the ordinal value corresponding to the active field.
 

 
**File: test_tagged_union_with_tag_values.zig**
```zig
const std = @import("std");
const expect = std.testing.expect;

const Tagged = union(enum(u32)) {
 int: i64 = 123,
 boolean: bool = 67,
};

test "tag values" {
 const int: Tagged = .{ .int = -40 };
 try expect(@intFromEnum(int) == 123);

 const boolean: Tagged = .{ .boolean = false };
 try expect(@intFromEnum(boolean) == 67);
}
```

**Shell**
```shell
$ zig test test_tagged_union_with_tag_values.zig
1/1 test_tagged_union_with_tag_values.test.tag values...OK
All 1 tests passed.
```

 

 [@tagName](#tagName) can be used to return a [comptime](#comptime)
 `[:0]const u8` value representing the field name:
 

 
**File: test_tagName.zig**
```zig
const std = @import("std");
const expect = std.testing.expect;

const Small2 = union(enum) {
 a: i32,
 b: bool,
 c: u8,
};
test "@tagName" {
 try expect(std.mem.eql(u8, @tagName(Small2.a), "a"));
}
```

**Shell**
```shell
$ zig test test_tagName.zig
1/1 test_tagName.test.@tagName...OK
All 1 tests passed.
```

 

 
## extern union

 

 An `extern union` has memory layout guaranteed to be compatible with
 the target C ABI.
 

 
See also:

- [extern struct](#extern-struct)

 

 
## packed union

 
A `packed union` has well-defined in-memory layout and is eligible
 to be in a [packed struct](#packed-struct).

 
All fields in a packed union must have the same [@bitSizeOf](#bitSizeOf).

 

 
## Anonymous Union Literals

 
[Anonymous Struct Literals](#Anonymous-Struct-Literals) syntax can be used to initialize unions without specifying
 the type:

 
**File: test_anonymous_union.zig**
```zig
const std = @import("std");
const expect = std.testing.expect;

const Number = union {
 int: i32,
 float: f64,
};

test "anonymous union literal syntax" {
 const i: Number = .{ .int = 42 };
 const f = makeNumber();
 try expect(i.int == 42);
 try expect(f.float == 12.34);
}

fn makeNumber() Number {
 return .{ .float = 12.34 };
}
```

**Shell**
```shell
$ zig test test_anonymous_union.zig
1/1 test_anonymous_union.test.anonymous union literal syntax...OK
All 1 tests passed.
```