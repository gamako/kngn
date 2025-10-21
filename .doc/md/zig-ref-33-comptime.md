# comptime

Zig places importance on the concept of whether an expression is known at compile-time.
 There are a few different places this concept is used, and these building blocks are used
 to keep the language small, readable, and powerful.
 

 
## Introducing the Compile-Time Concept

 
### Compile-Time Parameters

 

 Compile-time parameters is how Zig implements generics. It is compile-time duck typing.
 

 
**File: compile-time_duck_typing.zig**
```zig
fn max(comptime T: type, a: T, b: T) T {
 return if (a > b) a else b;
}
fn gimmeTheBiggerFloat(a: f32, b: f32) f32 {
 return max(f32, a, b);
}
fn gimmeTheBiggerInteger(a: u64, b: u64) u64 {
 return max(u64, a, b);
}
```

 

 In Zig, types are first-class citizens. They can be assigned to variables, passed as parameters to functions,
 and returned from functions. However, they can only be used in expressions which are known at compile-time,
 which is why the parameter `T` in the above snippet must be marked with `comptime`.
 

 

 A `comptime` parameter means that:
 

 
- At the callsite, the value must be known at compile-time, or it is a compile error.
- In the function definition, the value is known at compile-time.

 

 For example, if we were to introduce another function to the above snippet:
 

 
**File: test_unresolved_comptime_value.zig**
```zig
fn max(comptime T: type, a: T, b: T) T {
 return if (a > b) a else b;
}
test "try to pass a runtime type" {
 foo(false);
}
fn foo(condition: bool) void {
 const result = max(if (condition) f32 else u64, 1234, 5678);
 _ = result;
}
```

**Shell**
```shell
$ zig test test_unresolved_comptime_value.zig
/home/ci/actions-runner/_work/zig-bootstrap/zig/doc/langref/test_unresolved_comptime_value.zig:8:28: error: unable to resolve comptime value
 const result = max(if (condition) f32 else u64, 1234, 5678);
 ^~~~~~~~~
/home/ci/actions-runner/_work/zig-bootstrap/zig/doc/langref/test_unresolved_comptime_value.zig:8:24: note: argument to comptime parameter must be comptime-known
 const result = max(if (condition) f32 else u64, 1234, 5678);
 ^~~~~~~~~~~~~~~~~~~~~~~~~~~
/home/ci/actions-runner/_work/zig-bootstrap/zig/doc/langref/test_unresolved_comptime_value.zig:1:8: note: parameter declared comptime here
fn max(comptime T: type, a: T, b: T) T {
 ^~~~~~~~
referenced by:
 test.try to pass a runtime type: /home/ci/actions-runner/_work/zig-bootstrap/zig/doc/langref/test_unresolved_comptime_value.zig:5:8
```

 

 This is an error because the programmer attempted to pass a value only known at run-time
 to a function which expects a value known at compile-time.
 

 

 Another way to get an error is if we pass a type that violates the type checker when the
 function is analyzed. This is what it means to have compile-time duck typing.
 

 

 For example:
 

 
**File: test_comptime_mismatched_type.zig**
```zig
fn max(comptime T: type, a: T, b: T) T {
 return if (a > b) a else b;
}
test "try to compare bools" {
 _ = max(bool, true, false);
}
```

**Shell**
```shell
$ zig test test_comptime_mismatched_type.zig
/home/ci/actions-runner/_work/zig-bootstrap/zig/doc/langref/test_comptime_mismatched_type.zig:2:18: error: operator > not allowed for type 'bool'
 return if (a > b) a else b;
 ~~^~~
referenced by:
 test.try to compare bools: /home/ci/actions-runner/_work/zig-bootstrap/zig/doc/langref/test_comptime_mismatched_type.zig:5:12
```

 

 On the flip side, inside the function definition with the `comptime` parameter, the
 value is known at compile-time. This means that we actually could make this work for the bool type
 if we wanted to:
 

 
**File: test_comptime_max_with_bool.zig**
```zig
fn max(comptime T: type, a: T, b: T) T {
 if (T == bool) {
 return a or b;
 } else if (a > b) {
 return a;
 } else {
 return b;
 }
}
test "try to compare bools" {
 try @import("std").testing.expect(max(bool, false, true) == true);
}
```

**Shell**
```shell
$ zig test test_comptime_max_with_bool.zig
1/1 test_comptime_max_with_bool.test.try to compare bools...OK
All 1 tests passed.
```

 

 This works because Zig implicitly inlines `if` expressions when the condition
 is known at compile-time, and the compiler guarantees that it will skip analysis of
 the branch not taken.
 

 

 This means that the actual function generated for `max` in this situation looks like
 this:
 

 
**File: compiler_generated_function.zig**
```zig
fn max(a: bool, b: bool) bool {
 {
 return a or b;
 }
}
```

 

 All the code that dealt with compile-time known values is eliminated and we are left with only
 the necessary run-time code to accomplish the task.
 

 

 This works the same way for `switch` expressions - they are implicitly inlined
 when the target expression is compile-time known.
 

 
 
### Compile-Time Variables

 

 In Zig, the programmer can label variables as `comptime`. This guarantees to the compiler
 that every load and store of the variable is performed at compile-time. Any violation of this results in a
 compile error.
 

 

 This combined with the fact that we can `inline` loops allows us to write
 a function which is partially evaluated at compile-time and partially at run-time.
 

 

 For example:
 

 
**File: test_comptime_evaluation.zig**
```zig
const expect = @import("std").testing.expect;

const CmdFn = struct {
 name: []const u8,
 func: fn (i32) i32,
};

const cmd_fns = [_]CmdFn{
 CmdFn{ .name = "one", .func = one },
 CmdFn{ .name = "two", .func = two },
 CmdFn{ .name = "three", .func = three },
};
fn one(value: i32) i32 {
 return value + 1;
}
fn two(value: i32) i32 {
 return value + 2;
}
fn three(value: i32) i32 {
 return value + 3;
}

fn performFn(comptime prefix_char: u8, start_value: i32) i32 {
 var result: i32 = start_value;
 comptime var i = 0;
 inline while (i should happen
 at compile-time, does happen at compile-time. This catches more errors and allows expressiveness
 that in other languages requires using macros, generated code, or a preprocessor to accomplish.
 

 
 
### Compile-Time Expressions

 

 In Zig, it matters whether a given expression is known at compile-time or run-time. A programmer can
 use a `comptime` expression to guarantee that the expression will be evaluated at compile-time.
 If this cannot be accomplished, the compiler will emit an error. For example:
 

 
**File: test_comptime_call_extern_function.zig**
```zig
extern fn exit() noreturn;

test "foo" {
 comptime {
 exit();
 }
}
```

**Shell**
```shell
$ zig test test_comptime_call_extern_function.zig
/home/ci/actions-runner/_work/zig-bootstrap/zig/doc/langref/test_comptime_call_extern_function.zig:5:13: error: comptime call of extern function
 exit();
 ~~~~^~
/home/ci/actions-runner/_work/zig-bootstrap/zig/doc/langref/test_comptime_call_extern_function.zig:4:5: note: 'comptime' keyword forces comptime evaluation
 comptime {
 ^~~~~~~~
```

 

 It doesn't make sense that a program could call `exit()` (or any other external function)
 at compile-time, so this is a compile error. However, a `comptime` expression does much
 more than sometimes cause a compile error.
 

 

 Within a `comptime` expression:
 

 
- All variables are `comptime` variables.
- All `if`, `while`, `for`, and `switch` expressions are evaluated at compile-time, or emit a compile error if this is not possible.
- All `return` and `try` expressions are invalid (unless the function itself is called at compile-time).
- All code with runtime side effects or depending on runtime values emits a compile error.
- All function calls cause the compiler to interpret the function at compile-time, emitting a compile error if the function tries to do something that has global runtime side effects.

 

 This means that a programmer can create a function which is called both at compile-time and run-time, with
 no modification to the function required.
 

 

 Let's look at an example:
 

 
**File: test_fibonacci_recursion.zig**
```zig
const expect = @import("std").testing.expect;

fn fibonacci(index: u32) u32 {
 if (index @0 = internal unnamed_addr constant [25 x i32] [i32 2, i32 3, i32 5, i32 7, i32 11, i32 13, i32 17, i32 19, i32 23, i32 29, i32 31, i32 37, i32 41, i32 43, i32 47, i32 53, i32 59, i32 61, i32 67, i32 71, i32 73, i32 79, i32 83, i32 89, i32 97]
@1 = internal unnamed_addr constant i32 1060
 

 Note that we did not have to do anything special with the syntax of these functions. For example,
 we could call the `sum` function as is with a slice of numbers whose length and values were
 only known at run-time.
 

 
 
 
## Generic Data Structures

 

 Zig uses comptime capabilities to implement generic data structures without introducing any
 special-case syntax.
 

 

 Here is an example of a generic `List` data structure.
 

 
**File: generic_data_structure.zig**
```zig
fn List(comptime T: type) type {
 return struct {
 items: []T,
 len: usize,
 };
}

// The generic List data structure can be instantiated by passing in a type:
var buffer: [10]i32 = undefined;
var list = List(i32){
 .items = &buffer,
 .len = 0,
};
```

 

 That's it. It's a function that returns an anonymous `struct`.
 For the purposes of error messages and debugging, Zig infers the name
 `"List(i32)"` from the function name and parameters invoked when creating
 the anonymous struct.
 

 

 To explicitly give a type a name, we assign it to a constant.
 

 
**File: anonymous_struct_name.zig**
```zig
const Node = struct {
 next: ?*Node,
 name: []const u8,
};

var node_a = Node{
 .next = null,
 .name = "Node A",
};

var node_b = Node{
 .next = &node_a,
 .name = "Node B",
};
```

 

 In this example, the `Node` struct refers to itself.
 This works because all top level declarations are order-independent.
 As long as the compiler can determine the size of the struct, it is free to refer to itself.
 In this case, `Node` refers to itself as a pointer, which has a
 well-defined size at compile time, so it works fine.
 

 
 
## Case Study: print in Zig

 

 Putting all of this together, let's see how `print` works in Zig.
 

 
**File: print.zig**
```zig
const print = @import("std").debug.print;

const a_number: i32 = 1234;
const a_string = "foobar";

pub fn main() void {
 print("here is a string: '{s}' here is a number: {}\n", .{ a_string, a_number });
}
```

**Shell**
```shell
$ zig build-exe print.zig
$ ./print
here is a string: 'foobar' here is a number: 1234
```

 

 Let's crack open the implementation of this and see how it works:
 

 
**File: poc_print_fn.zig**
```zig
const Writer = struct {
 /// Calls print and then flushes the buffer.
 pub fn print(self: *Writer, comptime format: []const u8, args: anytype) anyerror!void {
 const State = enum {
 start,
 open_brace,
 close_brace,
 };

 comptime var start_index: usize = 0;
 comptime var state = State.start;
 comptime var next_arg: usize = 0;

 inline for (format, 0..) |c, i| {
 switch (state) {
 State.start => switch (c) {
 '{' => {
 if (start_index {
 if (start_index {},
 },
 State.open_brace => switch (c) {
 '{' => {
 state = State.start;
 start_index = i;
 },
 '}' => {
 try self.printValue(args[next_arg]);
 next_arg += 1;
 state = State.start;
 start_index = i + 1;
 },
 's' => {
 continue;
 },
 else => @compileError("Unknown format character: " ++ [1]u8{c}),
 },
 State.close_brace => switch (c) {
 '}' => {
 state = State.start;
 start_index = i;
 },
 else => @compileError("Single '}' encountered in format string"),
 },
 }
 }
 comptime {
 if (args.len != next_arg) {
 @compileError("Unused arguments");
 }
 if (state != State.start) {
 @compileError("Incomplete format string: " ++ format);
 }
 }
 if (start_index {
 return self.writeInt(value);
 },
 .float => {
 return self.writeFloat(value);
 },
 .pointer => {
 return self.write(value);
 },
 else => {
 @compileError("Unable to print type '" ++ @typeName(@TypeOf(value)) ++ "'");
 },
 }
 }

 fn write(self: *Writer, value: []const u8) !void {
 _ = self;
 _ = value;
 }
 fn writeInt(self: *Writer, value: anytype) !void {
 _ = self;
 _ = value;
 }
 fn writeFloat(self: *Writer, value: anytype) !void {
 _ = self;
 _ = value;
 }
};
```

 

 And now, what happens if we give too many arguments to `print`?
 

 
**File: test_print_too_many_args.zig**
```zig
const print = @import("std").debug.print;

const a_number: i32 = 1234;
const a_string = "foobar";

test "print too many arguments" {
 print("here is a string: '{s}' here is a number: {}\n", .{
 a_string,
 a_number,
 a_number,
 });
}
```

**Shell**
```shell
$ zig test test_print_too_many_args.zig
/home/ci/actions-runner/_work/zig-bootstrap/out/host/lib/zig/std/Io/Writer.zig:718:18: error: unused argument in 'here is a string: '{s}' here is a number: {}
 '
 1 => @compileError("unused argument in '" ++ fmt ++ "'"),
 ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
referenced by:
 print__anon_455: /home/ci/actions-runner/_work/zig-bootstrap/out/host/lib/zig/std/debug.zig:299:23
 test.print too many arguments: /home/ci/actions-runner/_work/zig-bootstrap/zig/doc/langref/test_print_too_many_args.zig:7:10
```

 

 Zig gives programmers the tools needed to protect themselves against their own mistakes.
 

 

 Zig doesn't care whether the format argument is a string literal,
 only that it is a compile-time known value that can be coerced to a `[]const u8`:
 

 
**File: print_comptime-known_format.zig**
```zig
const print = @import("std").debug.print;

const a_number: i32 = 1234;
const a_string = "foobar";
const fmt = "here is a string: '{s}' here is a number: {}\n";

pub fn main() void {
 print(fmt, .{ a_string, a_number });
}
```

**Shell**
```shell
$ zig build-exe print_comptime-known_format.zig
$ ./print_comptime-known_format
here is a string: 'foobar' here is a number: 1234
```

 

 This works fine.
 

 

 Zig does not special case string formatting in the compiler and instead exposes enough power to accomplish this
 task in userland. It does so without introducing another language on top of Zig, such as
 a macro language or a preprocessor language. It's Zig all the way down.
 

 
 
See also:

- [inline while](#inline-while)
- [inline for](#inline-for)