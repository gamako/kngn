# Style Guide

These coding conventions are not enforced by the compiler, but they are shipped in
this documentation along with the compiler in order to provide a point of
reference, should anyone wish to point to an authority on agreed upon Zig
coding style.
 

 
## Avoid Redundancy in Names

 
Avoid these words in type names:

 
- Value
- Data
- Context
- Manager
- utils, misc, or somebody's initials

 
Everything is a value, all types are data, everything is context, all logic manages state.
 Nothing is communicated by using a word that applies to all types.

 
Temptation to use "utilities", "miscellaneous", or somebody's initials
 is a failure to categorize, or more commonly, overcategorization. Such
 declarations can live at the root of a module that needs them with no
 namespace needed.

 

 
## Avoid Redundant Names in Fully-Qualified Namespaces

 
Every declaration is assigned a fully qualified
 namespace by the compiler, creating a tree structure. Choose names based
 on the fully-qualified namespace, and avoid redundant name segments.

 
**File: redundant_fqn.zig**
```zig
const std = @import("std");

pub const json = struct {
 pub const JsonValue = union(enum) {
 number: f64,
 boolean: bool,
 // ...
 };
};

pub fn main() void {
 std.debug.print("{s}\n", .{@typeName(json.JsonValue)});
}
```

**Shell**
```shell
$ zig build-exe redundant_fqn.zig
$ ./redundant_fqn
redundant_fqn.json.JsonValue
```

 
In this example, "json" is repeated in the fully-qualified namespace. The solution
 is to delete `Json` from `JsonValue`. In this example we have
 an empty struct named `json` but remember that files also act
 as part of the fully-qualified namespace.

 
This example is an exception to the rule specified in [Avoid Redundancy in Names](#Avoid-Redundancy-in-Names).
 The meaning of the type has been reduced to its core: it is a json value. The name
 cannot be any more specific without being incorrect.

 

 
## Whitespace

 
- 4 space indentation
- Open braces on same line, unless you need to wrap.
- If a list of things is longer than 2, put each item on its own line and exercise the ability to put an extra comma at the end.
- Line length: aim for 100; use common sense.

 
 
## Names

 

 Roughly speaking: `camelCaseFunctionName`, `TitleCaseTypeName`,
 `snake_case_variable_name`. More precisely:
 

 
- If `x` is a `type` then `x` should be `TitleCase`, unless it is a `struct` with 0 fields and is never meant to be instantiated, in which case it is considered to be a "namespace" and uses `snake_case`.
- If `x` is callable, and `x`'s return type is `type`, then `x` should be `TitleCase`.
- If `x` is otherwise callable, then `x` should be `camelCase`.
- Otherwise, `x` should be `snake_case`.

 

 Acronyms, initialisms, proper nouns, or any other word that has capitalization
 rules in written English are subject to naming conventions just like any other
 word. Even acronyms that are only 2 letters long are subject to these
 conventions.
 

 

 File names fall into two categories: types and namespaces. If the file
 (implicitly a struct) has top level fields, it should be named like any
 other struct with fields using TitleCase. Otherwise,
 it should use snake_case. Directory names should be
 snake_case.
 

 

 These are general rules of thumb; if it makes sense to do something different,
 do what makes sense. For example, if there is an established convention such as
 `ENOENT`, follow the established convention.
 

 
 
## Examples

 
**File: style_example.zig**
```zig
const namespace_name = @import("dir_name/file_name.zig");
const TypeName = @import("dir_name/TypeName.zig");
var global_var: i32 = undefined;
const const_name = 42;
const primitive_type_alias = f32;
const string_alias = []u8;

const StructName = struct {
 field: i32,
};
const StructAlias = StructName;

fn functionName(param_name: TypeName) void {
 var functionPointer = functionName;
 functionPointer();
 functionPointer = otherFunction;
 functionPointer();
}
const functionAlias = functionName;

fn ListTemplateFunction(comptime ChildType: type, comptime fixed_size: usize) type {
 return List(ChildType, fixed_size);
}

fn ShortList(comptime T: type, comptime n: usize) type {
 return struct {
 field_name: [n]T,
 fn methodName() void {}
 };
}

// The word XML loses its casing when used in Zig identifiers.
const xml_document =
 \\
 \\
 \\
;
const XmlParser = struct {
 field: i32,
};

// The initials BE (Big Endian) are just another word in Zig identifier names.
fn readU32Be() u32 {}
```

 

 See the [Zig Standard Library](#Zig-Standard-Library) for more examples.
 

 
 
## Doc Comment Guidance

 
- Omit any information that is redundant based on the name of the thing being documented.
- Duplicating information onto multiple similar functions is encouraged because it helps IDEs and other tools provide better help text.
- Use the word assume to indicate invariants that cause unchecked [Illegal Behavior](#Illegal-Behavior) when violated.
- Use the word assert to indicate invariants that cause safety-checked [Illegal Behavior](#Illegal-Behavior) when violated.

 
 
 Source Encoding §

 
Zig source code is encoded in UTF-8. An invalid UTF-8 byte sequence results in a compile error.

 
Throughout all zig source code (including in comments), some code points are never allowed:

 
- Ascii control characters, except for U+000a (LF), U+000d (CR), and U+0009 (HT): U+0000 - U+0008, U+000b - U+000c, U+000e - U+0001f, U+007f.
- Non-Ascii Unicode line endings: U+0085 (NEL), U+2028 (LS), U+2029 (PS).

 

 LF (byte value 0x0a, code point U+000a, `'\n'`) is the line terminator in Zig source code.
 This byte value terminates every line of zig source code except the last line of the file.
 It is recommended that non-empty source files end with an empty line, which means the last byte would be 0x0a (LF).
 

 

 Each LF may be immediately preceded by a single CR (byte value 0x0d, code point U+000d, `'\r'`)
 to form a Windows style line ending, but this is discouraged. Note that in multiline strings, CRLF sequences will
 be encoded as LF when compiled into a zig program.
 A CR in any other context is not allowed.
 

 

 HT hard tabs (byte value 0x09, code point U+0009, `'\t'`) are interchangeable with
 SP spaces (byte value 0x20, code point U+0020, `' '`) as a token separator,
 but use of hard tabs is discouraged. See [Grammar](#Grammar).
 

 

 For compatibility with other tools, the compiler ignores a UTF-8-encoded byte order mark (U+FEFF)
 if it is the first Unicode code point in the source text. A byte order mark is not allowed anywhere else in the source.
 

 

 Note that running zig fmt on a source file will implement all recommendations mentioned here.
 

 

 Note that a tool reading Zig source code can make assumptions if the source code is assumed to be correct Zig code.
 For example, when identifying the ends of lines, a tool can use a naive search such as `/\n/`,
 or an [advanced](https://msdn.microsoft.com/en-us/library/dd409797.aspx)
 search such as `/\r\n?|[\n\u0085\u2028\u2029]/`, and in either case line endings will be correctly identified.
 For another example, when identifying the whitespace before the first token on a line,
 a tool can either use a naive search such as `/[ \t]/`,
 or an [advanced](https://tc39.es/ecma262/#sec-characterclassescape) search such as `/\s/`,
 and in either case whitespace will be correctly identified.