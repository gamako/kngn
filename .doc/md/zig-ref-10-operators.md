# Operators

There is no operator overloading. When you see an operator in Zig, you know that
 it is doing something from this table, and nothing else.
 

 
## Table of Operators

 
| Name | Syntax | Types | Remarks | Example |
| --- | --- | --- | --- | --- |
| Addition | `a + b a += b` | - [Integers](#Integers) - [Floats](#Floats) | - Can cause [overflow](#Default-Operations) for integers. - Invokes [Peer Type Resolution](#Peer-Type-Resolution) for the operands. - See also [@addWithOverflow](#addWithOverflow). | `2 + 5 == 7` |
| Wrapping Addition | `a +% b a +%= b` | - [Integers](#Integers) | - Twos-complement wrapping behavior. - Invokes [Peer Type Resolution](#Peer-Type-Resolution) for the operands. - See also [@addWithOverflow](#addWithOverflow). | `@as(u32, 0xffffffff) +% 1 == 0` |
| Saturating Addition | `a +| b a +|= b` | - [Integers](#Integers) | - Invokes [Peer Type Resolution](#Peer-Type-Resolution) for the operands. | `@as(u8, 255) +| 1 == @as(u8, 255)` |
| Subtraction | `a - b a -= b` | - [Integers](#Integers) - [Floats](#Floats) | - Can cause [overflow](#Default-Operations) for integers. - Invokes [Peer Type Resolution](#Peer-Type-Resolution) for the operands. - See also [@subWithOverflow](#subWithOverflow). | `2 - 5 == -3` |
| Wrapping Subtraction | `a -% b a -%= b` | - [Integers](#Integers) | - Twos-complement wrapping behavior. - Invokes [Peer Type Resolution](#Peer-Type-Resolution) for the operands. - See also [@subWithOverflow](#subWithOverflow). | `@as(u8, 0) -% 1 == 255` |
| Saturating Subtraction | `a -| b a -|= b` | - [Integers](#Integers) | - Invokes [Peer Type Resolution](#Peer-Type-Resolution) for the operands. | `@as(u32, 0) -| 1 == 0` |
| Negation | `-a` | - [Integers](#Integers) - [Floats](#Floats) | - Can cause [overflow](#Default-Operations) for integers. | `-1 == 0 - 1` |
| Wrapping Negation | `-%a` | - [Integers](#Integers) | - Twos-complement wrapping behavior. | `-%@as(i8, -128) == -128` |
| Multiplication | `a * b a *= b` | - [Integers](#Integers) - [Floats](#Floats) | - Can cause [overflow](#Default-Operations) for integers. - Invokes [Peer Type Resolution](#Peer-Type-Resolution) for the operands. - See also [@mulWithOverflow](#mulWithOverflow). | `2 * 5 == 10` |
| Wrapping Multiplication | `a *% b a *%= b` | - [Integers](#Integers) | - Twos-complement wrapping behavior. - Invokes [Peer Type Resolution](#Peer-Type-Resolution) for the operands. - See also [@mulWithOverflow](#mulWithOverflow). | `@as(u8, 200) *% 2 == 144` |
| Saturating Multiplication | `a *| b a *|= b` | - [Integers](#Integers) | - Invokes [Peer Type Resolution](#Peer-Type-Resolution) for the operands. | `@as(u8, 200) *| 2 == 255` |
| Division | `a / b a /= b` | - [Integers](#Integers) - [Floats](#Floats) | - Can cause [overflow](#Default-Operations) for integers. - Can cause [Division by Zero](#Division-by-Zero) for integers. - Can cause [Division by Zero](#Division-by-Zero) for floats in [FloatMode.Optimized Mode](#Floating-Point-Operations). - Signed integer operands must be comptime-known and positive. In other cases, use [@divTrunc](#divTrunc), [@divFloor](#divFloor), or [@divExact](#divExact) instead. - Invokes [Peer Type Resolution](#Peer-Type-Resolution) for the operands. | `10 / 5 == 2` |
| Remainder Division | `a % b a %= b` | - [Integers](#Integers) - [Floats](#Floats) | - Can cause [Division by Zero](#Division-by-Zero) for integers. - Can cause [Division by Zero](#Division-by-Zero) for floats in [FloatMode.Optimized Mode](#Floating-Point-Operations). - Signed or floating-point operands must be comptime-known and positive. In other cases, use [@rem](#rem) or [@mod](#mod) instead. - Invokes [Peer Type Resolution](#Peer-Type-Resolution) for the operands. | `10 % 3 == 1` |
| Bit Shift Left | `a > b a >>= b` | - [Integers](#Integers) | - Moves all bits to the right, inserting zeroes at the most-significant bit. - `b` must be [comptime-known](#comptime) or have a type with log2 number of bits as `a`. - See also [@shrExact](#shrExact). | `0b1010 >> 1 == 0b101` |
| Bitwise And | `a & b a &= b` | - [Integers](#Integers) | - Invokes [Peer Type Resolution](#Peer-Type-Resolution) for the operands. | `0b011 & 0b101 == 0b001` |
| Bitwise Or | `a | b a |= b` | - [Integers](#Integers) | - Invokes [Peer Type Resolution](#Peer-Type-Resolution) for the operands. | `0b010 | 0b100 == 0b110` |
| Bitwise Xor | `a ^ b a ^= b` | - [Integers](#Integers) | - Invokes [Peer Type Resolution](#Peer-Type-Resolution) for the operands. | `0b011 ^ 0b101 == 0b110` |
| Bitwise Not | `~a` | - [Integers](#Integers) | | `~@as(u8, 0b10101111) == 0b01010000` |
| Defaulting Optional Unwrap | `a orelse b` | - [Optionals](#Optionals) | If `a` is `null`, returns `b` ("default value"), otherwise returns the unwrapped value of `a`. Note that `b` may be a value of type [noreturn](#noreturn). | `const value: ?u32 = null; const unwrapped = value orelse 1234; unwrapped == 1234` |
| Optional Unwrap | `a.?` | - [Optionals](#Optionals) | Equivalent to: `a orelse unreachable` | `const value: ?u32 = 5678; value.? == 5678` |
| Defaulting Error Unwrap | `a catch b a catch |err| b` | - [Error Unions](#Errors) | If `a` is an `error`, returns `b` ("default value"), otherwise returns the unwrapped value of `a`. Note that `b` may be a value of type [noreturn](#noreturn). `err` is the `error` and is in scope of the expression `b`. | `const value: anyerror!u32 = error.Broken; const unwrapped = value catch 1234; unwrapped == 1234` |
| Logical And | `a and b` | - [bool](#Primitive-Types) | If `a` is `false`, returns `false` without evaluating `b`. Otherwise, returns `b`. | `(false and true) == false` |
| Logical Or | `a or b` | - [bool](#Primitive-Types) | If `a` is `true`, returns `true` without evaluating `b`. Otherwise, returns `b`. | `(false or true) == true` |
| Boolean Not | `!a` | - [bool](#Primitive-Types) | | `!false == true` |
| Equality | `a == b` | - [Integers](#Integers) - [Floats](#Floats) - [bool](#Primitive-Types) - [type](#Primitive-Types) - [packed struct](#packed-struct) | Returns `true` if a and b are equal, otherwise returns `false`. Invokes [Peer Type Resolution](#Peer-Type-Resolution) for the operands. | `(1 == 1) == true` |
| Null Check | `a == null` | - [Optionals](#Optionals) | Returns `true` if a is `null`, otherwise returns `false`. | `const value: ?u32 = null; (value == null) == true` |
| Inequality | `a != b` | - [Integers](#Integers) - [Floats](#Floats) - [bool](#Primitive-Types) - [type](#Primitive-Types) | Returns `false` if a and b are equal, otherwise returns `true`. Invokes [Peer Type Resolution](#Peer-Type-Resolution) for the operands. | `(1 != 1) == false` |
| Non-Null Check | `a != null` | - [Optionals](#Optionals) | Returns `false` if a is `null`, otherwise returns `true`. | `const value: ?u32 = null; (value != null) == false` |
| Greater Than | `a > b` | - [Integers](#Integers) - [Floats](#Floats) | Returns `true` if a is greater than b, otherwise returns `false`. Invokes [Peer Type Resolution](#Peer-Type-Resolution) for the operands. | `(2 > 1) == true` |
| Greater or Equal | `a >= b` | - [Integers](#Integers) - [Floats](#Floats) | Returns `true` if a is greater than or equal to b, otherwise returns `false`. Invokes [Peer Type Resolution](#Peer-Type-Resolution) for the operands. | `(2 >= 1) == true` |
| Less Than | `a `x() x[] x.y x.* x.?
a!b
x{}
!x -x -%x ~x &x ?x
* / % ** *% *| ||
+ - ++ +% -% +| -|
<< >> <<|
& ^ | orelse catch
== != < > <= >=
and
or
= *= *%= *|= /= %= += +%= +|= -= -%= -|= <<= <<|= >>= &= ^= |=`