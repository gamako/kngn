# Zig Test

Code written within one or more `test` declarations can be used to ensure behavior meets expectations:
 

 
**File: testing_introduction.zig**
```zig
const std = @import("std");

test "expect addOne adds one to 41" {

 // The Standard Library contains useful functions to help create tests.
 // `expect` is a function that verifies its argument is true.
 // It will return an error if its argument is false to indicate a failure.
 // `try` is used to return an error to the test runner to notify it that the test failed.
 try std.testing.expect(addOne(41) == 42);
}

test addOne {
 // A test name can also be written using an identifier.
 // This is a doctest, and serves as documentation for `addOne`.
 try std.testing.expect(addOne(41) == 42);
}

/// The function `addOne` adds one to the number given as its argument.
fn addOne(number: i32) i32 {
 return number + 1;
}
```

**Shell**
```shell
$ zig test testing_introduction.zig
1/2 testing_introduction.test.expect addOne adds one to 41...OK
2/2 testing_introduction.decltest.addOne...OK
All 2 tests passed.
```

 

 The testing_introduction.zig code sample tests the [function](#Functions)
 `addOne` to ensure that it returns `42` given the input
 `41`. From this test's perspective, the `addOne` function is
 said to be code under test.
 

 

 zig test is a tool that creates and runs a test build. By default, it builds and runs an
 executable program using the default test runner provided by the [Zig Standard Library](#Zig-Standard-Library)
 as its main entry point. During the build, `test` declarations found while
 [resolving](#File-and-Declaration-Discovery) the given Zig source file are included for the default test runner
 to run and report on.
 

 
> This documentation discusses the features of the default test runner as provided by the Zig Standard Library.
> Its source code is located in lib/compiler/test_runner.zig.

 

 The shell output shown above displays two lines after the zig test command. These lines are
 printed to standard error by the default test runner:
 

 
 1/2 testing_introduction.test.expect addOne adds one to 41...
 Lines like this indicate which test, out of the total number of tests, is being run.
 In this case, 1/2 indicates that the first test, out of a total of two tests,
 is being run. Note that, when the test runner program's standard error is output
 to the terminal, these lines are cleared when a test succeeds.
 
 2/2 testing_introduction.decltest.addOne...
 When the test name is an identifier, the default test runner uses the text
 decltest instead of test.
 
 All 2 tests passed.
 This line indicates the total number of tests that have passed.
 
 
## Test Declarations

 

 Test declarations contain the [keyword](#Keyword-Reference) `test`, followed by an
 optional name written as a [string literal](#String-Literals-and-Unicode-Code-Point-Literals) or an
 [identifier](#Identifiers), followed by a [block](#Blocks) containing any valid Zig code that
 is allowed in a [function](#Functions).
 

 
Non-named test blocks always run during test builds and are exempt from
 [Skip Tests](#Skip-Tests).

 

 Test declarations are similar to [Functions](#Functions): they have a return type and a block of code. The implicit
 return type of `test` is the [Error Union Type](#Error-Union-Type) `anyerror!void`,
 and it cannot be changed. When a Zig source file is not built using the zig test tool, the test
 declarations are omitted from the build.
 

 

 Test declarations can be written in the same file, where code under test is written, or in a separate Zig source file.
 Since test declarations are top-level declarations, they are order-independent and can
 be written before or after the code under test.
 

 
See also:

- [The Global Error Set](#The-Global-Error-Set)
- [Grammar](#Grammar)

 
### Doctests

 

 Test declarations named using an identifier are doctests. The identifier must refer to another declaration in
 scope. A doctest, like a [doc comment](#Doc-Comments), serves as documentation for the associated declaration, and
 will appear in the generated documentation for the declaration.
 

 

 An effective doctest should be self-contained and focused on the declaration being tested, answering questions a new
 user might have about its interface or intended usage, while avoiding unnecessary or confusing details. A doctest is not
 a substitute for a doc comment, but rather a supplement and companion providing a testable, code-driven example, verified
 by zig test.
 

 
 
 
## Test Failure

 

 The default test runner checks for an [error](#Errors) returned from a test.
 When a test returns an error, the test is considered a failure and its [error return trace](#Error-Return-Traces)
 is output to standard error. The total number of failures will be reported after all tests have run.
 

 
**File: testing_failure.zig**
```zig
const std = @import("std");

test "expect this to fail" {
 try std.testing.expect(false);
}

test "expect this to succeed" {
 try std.testing.expect(true);
}
```

**Shell**
```shell
$ zig test testing_failure.zig
1/2 testing_failure.test.expect this to fail...FAIL (TestUnexpectedResult)
/home/ci/actions-runner/_work/zig-bootstrap/out/host/lib/zig/std/testing.zig:601:14: 0x1030019 in expect (std.zig)
 if (!ok) return error.TestUnexpectedResult;
 ^
/home/ci/actions-runner/_work/zig-bootstrap/zig/doc/langref/testing_failure.zig:4:5: 0x1030078 in test.expect this to fail (testing_failure.zig)
 try std.testing.expect(false);
 ^
2/2 testing_failure.test.expect this to succeed...OK
1 passed; 0 skipped; 1 failed.
error: the following test command failed with exit code 1:
/home/ci/actions-runner/_work/zig-bootstrap/out/zig-local-cache/o/c5ce6e534cd927e96a211abfd48df9a7/test --seed=0x4dc514d
```

 
 
## Skip Tests

 

 One way to skip tests is to filter them out by using the zig test command line parameter
 --test-filter [text]. This makes the test build only include tests whose name contains the
 supplied filter text. Note that non-named tests are run even when using the --test-filter [text]
 command line parameter.
 

 

 To programmatically skip a test, make a `test` return the error
 `error.SkipZigTest` and the default test runner will consider the test as being skipped.
 The total number of skipped tests will be reported after all tests have run.
 

 
**File: testing_skip.zig**
```zig
test "this will be skipped" {
 return error.SkipZigTest;
}
```

**Shell**
```shell
$ zig test testing_skip.zig
1/1 testing_skip.test.this will be skipped...SKIP
0 passed; 1 skipped; 0 failed.
```

 

 
## Report Memory Leaks

 

 When code allocates [Memory](#Memory) using the [Zig Standard Library](#Zig-Standard-Library)'s testing allocator,
 `std.testing.allocator`, the default test runner will report any leaks that are
 found from using the testing allocator:
 

 
**File: testing_detect_leak.zig**
```zig
const std = @import("std");

test "detect leak" {
 var list = std.array_list.Managed(u21).init(std.testing.allocator);
 // missing `defer list.deinit();`
 try list.append('☔');

 try std.testing.expect(list.items.len == 1);
}
```

**Shell**
```shell
$ zig test testing_detect_leak.zig
1/1 testing_detect_leak.test.detect leak...OK
[gpa] (err): memory address 0x7f683c360000 leaked:
/home/ci/actions-runner/_work/zig-bootstrap/out/host/lib/zig/std/array_list.zig:435:67: 0x1051e35 in ensureTotalCapacityPrecise (std.zig)
 const new_memory = try self.allocator.alignedAlloc(T, alignment, new_capacity);
 ^
/home/ci/actions-runner/_work/zig-bootstrap/out/host/lib/zig/std/array_list.zig:411:51: 0x103fc48 in ensureTotalCapacity (std.zig)
 return self.ensureTotalCapacityPrecise(better_capacity);
 ^
/home/ci/actions-runner/_work/zig-bootstrap/out/host/lib/zig/std/array_list.zig:461:41: 0x103a467 in addOne (std.zig)
 try self.ensureTotalCapacity(newlen);
 ^
/home/ci/actions-runner/_work/zig-bootstrap/out/host/lib/zig/std/array_list.zig:252:49: 0x1035df1 in append (std.zig)
 const new_item_ptr = try self.addOne();
 ^
/home/ci/actions-runner/_work/zig-bootstrap/zig/doc/langref/testing_detect_leak.zig:6:20: 0x1033089 in test.detect leak (testing_detect_leak.zig)
 try list.append('☔');
 ^
/home/ci/actions-runner/_work/zig-bootstrap/out/host/lib/zig/compiler/test_runner.zig:240:25: 0x116bd8f in mainTerminal (test_runner.zig)
 if (test_fn.func()) |_| {
 ^
/home/ci/actions-runner/_work/zig-bootstrap/out/host/lib/zig/compiler/test_runner.zig:69:28: 0x11691a6 in main (test_runner.zig)
 return mainTerminal();
 ^
/home/ci/actions-runner/_work/zig-bootstrap/out/host/lib/zig/std/start.zig:618:22: 0x116487c in callMain (std.zig)
 root.main();
 ^
/home/ci/actions-runner/_work/zig-bootstrap/out/host/lib/zig/std/start.zig:232:5: 0x1164351 in _start (std.zig)
 asm volatile (switch (native_arch) {
 ^

All 1 tests passed.
1 errors were logged.
1 tests leaked memory.
error: the following test command failed with exit code 1:
/home/ci/actions-runner/_work/zig-bootstrap/out/zig-local-cache/o/2bbf2b8adfe56b1d56bf5ab1f08235e9/test --seed=0xb7caabd4
```

 
See also:

- [defer](#defer)
- [Memory](#Memory)

 
 
## Detecting Test Build

 

 Use the [compile variable](#Compile-Variables) `@import("builtin").is_test`
 to detect a test build:
 

 
**File: testing_detect_test.zig**
```zig
const std = @import("std");
const builtin = @import("builtin");
const expect = std.testing.expect;

test "builtin.is_test" {
 try expect(isATest());
}

fn isATest() bool {
 return builtin.is_test;
}
```

**Shell**
```shell
$ zig test testing_detect_test.zig
1/1 testing_detect_test.test.builtin.is_test...OK
All 1 tests passed.
```

 
 
## Test Output and Logging

 

 The default test runner and the Zig Standard Library's testing namespace output messages to standard error.
 

 
 
## The Testing Namespace

 

 The Zig Standard Library's `testing` namespace contains useful functions to help
 you create tests. In addition to the `expect` function, this document uses a couple of more functions
 as exemplified here:
 

 
**File: testing_namespace.zig**
```zig
const std = @import("std");

test "expectEqual demo" {
 const expected: i32 = 42;
 const actual = 42;

 // The first argument to `expectEqual` is the known, expected, result.
 // The second argument is the result of some expression.
 // The actual's type is casted to the type of expected.
 try std.testing.expectEqual(expected, actual);
}

test "expectError demo" {
 const expected_error = error.DemoError;
 const actual_error_union: anyerror!void = error.DemoError;

 // `expectError` will fail when the actual error is different than
 // the expected error.
 try std.testing.expectError(expected_error, actual_error_union);
}
```

**Shell**
```shell
$ zig test testing_namespace.zig
1/2 testing_namespace.test.expectEqual demo...OK
2/2 testing_namespace.test.expectError demo...OK
All 2 tests passed.
```

 
The Zig Standard Library also contains functions to compare [Slices](#Slices), strings, and more. See the rest of the
 `std.testing` namespace in the [Zig Standard Library](#Zig-Standard-Library) for more available functions.

 
 
## Test Tool Documentation

 

 zig test has a few command line parameters which affect the compilation.
 See zig test --help for a full list.