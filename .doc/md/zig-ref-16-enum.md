# enum

**File: test_enums.zig**
```zig
const expect = @import("std").testing.expect;
const mem = @import("std").mem;

// Declare an enum.
const Type = enum {
 ok,
 not_ok,
};

// Declare a specific enum field.
const c = Type.ok;

// If you want access to the ordinal value of an enum, you
// can specify the tag type.
const Value = enum(u2) {
 zero,
 one,
 two,
};
// Now you can cast between u2 and Value.
// The ordinal value starts from 0, counting up by 1 from the previous member.
test "enum ordinal value" {
 try expect(@intFromEnum(Value.zero) == 0);
 try expect(@intFromEnum(Value.one) == 1);
 try expect(@intFromEnum(Value.two) == 2);
}

// You can override the ordinal value for an enum.
const Value2 = enum(u32) {
 hundred = 100,
 thousand = 1000,
 million = 1000000,
};
test "set enum ordinal value" {
 try expect(@intFromEnum(Value2.hundred) == 100);
 try expect(@intFromEnum(Value2.thousand) == 1000);
 try expect(@intFromEnum(Value2.million) == 1000000);
}

// You can also override only some values.
const Value3 = enum(u4) {
 a,
 b = 8,
 c,
 d = 4,
 e,
};
test "enum implicit ordinal values and overridden values" {
 try expect(@intFromEnum(Value3.a) == 0);
 try expect(@intFromEnum(Value3.b) == 8);
 try expect(@intFromEnum(Value3.c) == 9);
 try expect(@intFromEnum(Value3.d) == 4);
 try expect(@intFromEnum(Value3.e) == 5);
}

// Enums can have methods, the same as structs and unions.
// Enum methods are not special, they are only namespaced
// functions that you can call with dot syntax.
const Suit = enum {
 clubs,
 spades,
 diamonds,
 hearts,

 pub fn isClubs(self: Suit) bool {
 return self == Suit.clubs;
 }
};
test "enum method" {
 const p = Suit.spades;
 try expect(!p.isClubs());
}

// An enum can be switched upon.
const Foo = enum {
 string,
 number,
 none,
};
test "enum switch" {
 const p = Foo.number;
 const what_is_it = switch (p) {
 Foo.string => "this is a string",
 Foo.number => "this is a number",
 Foo.none => "this is a none",
 };
 try expect(mem.eql(u8, what_is_it, "this is a number"));
}

// @typeInfo can be used to access the integer tag type of an enum.
const Small = enum {
 one,
 two,
 three,
 four,
};
test "std.meta.Tag" {
 try expect(@typeInfo(Small).@"enum".tag_type == u2);
}

// @typeInfo tells us the field count and the fields names:
test "@typeInfo" {
 try expect(@typeInfo(Small).@"enum".fields.len == 4);
 try expect(mem.eql(u8, @typeInfo(Small).@"enum".fields[1].name, "two"));
}

// @tagName gives a [:0]const u8 representation of an enum value:
test "@tagName" {
 try expect(mem.eql(u8, @tagName(Small.three), "three"));
}
```

**Shell**
```shell
$ zig test test_enums.zig
1/8 test_enums.test.enum ordinal value...OK
2/8 test_enums.test.set enum ordinal value...OK
3/8 test_enums.test.enum implicit ordinal values and overridden values...OK
4/8 test_enums.test.enum method...OK
5/8 test_enums.test.enum switch...OK
6/8 test_enums.test.std.meta.Tag...OK
7/8 test_enums.test.@typeInfo...OK
8/8 test_enums.test.@tagName...OK
All 8 tests passed.
```

 
See also:

- [@typeInfo](#typeInfo)
- [@tagName](#tagName)
- [@sizeOf](#sizeOf)

 
## extern enum

 

 By default, enums are not guaranteed to be compatible with the C ABI:
 

 
**File: enum_export_error.zig**
```zig
const Foo = enum { a, b, c };
export fn entry(foo: Foo) void {
 _ = foo;
}
```

**Shell**
```shell
$ zig build-obj enum_export_error.zig -target x86_64-linux
/home/ci/actions-runner/_work/zig-bootstrap/zig/doc/langref/enum_export_error.zig:2:17: error: parameter of type 'enum_export_error.Foo' not allowed in function with calling convention 'x86_64_sysv'
export fn entry(foo: Foo) void {
 ^~~~~~~~
/home/ci/actions-runner/_work/zig-bootstrap/zig/doc/langref/enum_export_error.zig:2:17: note: enum tag type 'u2' is not extern compatible
/home/ci/actions-runner/_work/zig-bootstrap/zig/doc/langref/enum_export_error.zig:2:17: note: only integers with 0, 8, 16, 32, 64 and 128 bits are extern compatible
/home/ci/actions-runner/_work/zig-bootstrap/zig/doc/langref/enum_export_error.zig:1:13: note: enum declared here
const Foo = enum { a, b, c };
 ^~~~~~~~~~~~~~~~
referenced by:
 root: /home/ci/actions-runner/_work/zig-bootstrap/out/host/lib/zig/std/start.zig:3:22
 comptime: /home/ci/actions-runner/_work/zig-bootstrap/out/host/lib/zig/std/start.zig:31:9
 2 reference(s) hidden; use '-freference-trace=4' to see all references
```

 

 For a C-ABI-compatible enum, provide an explicit tag type to
 the enum:
 

 
**File: enum_export.zig**
```zig
const Foo = enum(c_int) { a, b, c };
export fn entry(foo: Foo) void {
 _ = foo;
}
```

**Shell**
```shell
$ zig build-obj enum_export.zig
```

 

 
## Enum Literals

 

 Enum literals allow specifying the name of an enum field without specifying the enum type:
 

 
**File: test_enum_literals.zig**
```zig
const std = @import("std");
const expect = std.testing.expect;

const Color = enum {
 auto,
 off,
 on,
};

test "enum literals" {
 const color1: Color = .auto;
 const color2 = Color.auto;
 try expect(color1 == color2);
}

test "switch using enum literals" {
 const color = Color.on;
 const result = switch (color) {
 .auto => false,
 .on => true,
 .off => false,
 };
 try expect(result);
}
```

**Shell**
```shell
$ zig test test_enum_literals.zig
1/2 test_enum_literals.test.enum literals...OK
2/2 test_enum_literals.test.switch using enum literals...OK
All 2 tests passed.
```

 

 
## Non-exhaustive enum

 

 A non-exhaustive enum can be created by adding a trailing `_` field.
 The enum must specify a tag type and cannot consume every enumeration value.
 

 

 [@enumFromInt](#enumFromInt) on a non-exhaustive enum involves the safety semantics
 of [@intCast](#intCast) to the integer tag type, but beyond that always results in
 a well-defined enum value.
 

 

 A switch on a non-exhaustive enum can include a `_` prong as an alternative to an `else` prong.
 With a `_` prong the compiler errors if all the known tag names are not handled by the switch.
 

 
**File: test_switch_non-exhaustive.zig**
```zig
const std = @import("std");
const expect = std.testing.expect;

const Number = enum(u8) {
 one,
 two,
 three,
 _,
};

test "switch on non-exhaustive enum" {
 const number = Number.one;
 const result = switch (number) {
 .one => true,
 .two, .three => false,
 _ => false,
 };
 try expect(result);
 const is_one = switch (number) {
 .one => true,
 else => false,
 };
 try expect(is_one);
}
```

**Shell**
```shell
$ zig test test_switch_non-exhaustive.zig
1/1 test_switch_non-exhaustive.test.switch on non-exhaustive enum...OK
All 1 tests passed.
```