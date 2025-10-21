# while

A while loop is used to repeatedly execute an expression until
 some condition is no longer true.
 

 
**File: test_while.zig**
```zig
const expect = @import("std").testing.expect;

test "while basic" {
 var i: usize = 0;
 while (i f32,
 1 => i8,
 2 => bool,
 else => unreachable,
 };
 sum += typeNameLength(T);
 }
 try expect(sum == 9);
}

fn typeNameLength(comptime T: type) usize {
 return @typeName(T).len;
}
```

**Shell**
```shell
$ zig test test_inline_while.zig
1/1 test_inline_while.test.inline while loop...OK
All 1 tests passed.
```

 

 It is recommended to use `inline` loops only for one of these reasons:
 

 
- You need the loop to execute at [comptime](#comptime) for the semantics to work.
- You have a benchmark to prove that forcibly unrolling the loop in this way is measurably faster.

 
 
See also:

- [if](#if)
- [Optionals](#Optionals)
- [Errors](#Errors)
- [comptime](#comptime)
- [unreachable](#unreachable)