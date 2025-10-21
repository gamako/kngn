# Comments

Zig supports 3 types of comments. Normal comments are ignored, but doc comments and top-level doc comments are used by the compiler to generate the package documentation.

The generated documentation is still experimental, and can be produced with:

```shell
zig test -femit-docs main.zig
```

## Basic Comments

**File: comments.zig**
```zig
const print = @import("std").debug.print;

pub fn main() void {
    // Comments in Zig start with "//" and end at the next LF byte (end of line).
    // The line below is a comment and won't be executed.

    //print("Hello?", .{});

    print("Hello, world!\n", .{}); // another comment
}
```

**Shell**
```shell
$ zig build-exe comments.zig
$ ./comments
Hello, world!
```

There are no multiline comments in Zig (e.g. like `/* */` comments in C). This allows Zig to have the property that each line of code can be tokenized out of context.

## Doc Comments

A doc comment is one that begins with exactly three slashes (i.e. `///` but not `////`); multiple doc comments in a row are merged together to form a multiline doc comment. The doc comment documents whatever immediately follows it.

**File: doc_comments.zig**
```zig
/// A structure for storing a timestamp, with nanosecond precision (this is a
/// multiline doc comment).
const Timestamp = struct {
    /// The number of seconds since the epoch (this is also a doc comment).
    seconds: i64, // signed so we can represent pre-1970 (not a doc comment)
    /// The number of nanoseconds past the second (doc comment again).
    nanos: u32,

    /// Returns a `Timestamp` struct representing the Unix epoch; that is, the
    /// moment of 1970 Jan 1 00:00:00 UTC (this is a doc comment too).
    pub fn unixEpoch() Timestamp {
        return Timestamp{
            .seconds = 0,
            .nanos = 0,
        };
    }
};
```

Doc comments are only allowed in certain places; it is a compile error to have a doc comment in an unexpected place, such as in the middle of an expression, or just before a non-doc comment.

**File: invalid_doc-comment.zig**
```zig
/// doc-comment
//! top-level doc-comment
const std = @import("std");
```

**Error output:**
```
/home/ci/actions-runner/_work/zig-bootstrap/zig/doc/langref/invalid_doc-comment.zig:1:16: error: expected type expression, found 'a document comment'
/// doc-comment
               ^
```

**File: unattached_doc-comment.zig**
```zig
pub fn main() void {}

/// End of file
```

**Error output:**
```
/home/ci/actions-runner/_work/zig-bootstrap/zig/doc/langref/unattached_doc-comment.zig:3:1: error: unattached documentation comment
/// End of file
^~~~~~~~~~~~~~~
```

Doc comments can be interleaved with normal comments. Currently, when producing the package documentation, normal comments are merged with doc comments.

## Top-Level Doc Comments

A top-level doc comment is one that begins with two slashes and an exclamation point: `//!`; it documents the current module.

It is a compile error if a top-level doc comment is not placed at the start of a [container](#containers), before any expressions.

**File: tldoc_comments.zig**
```zig
//! This module provides functions for retrieving the current date and
//! time with varying degrees of precision and accuracy. It does not
//! depend on libc, but will use functions from it if available.

const S = struct {
    //! Top level comments are allowed inside a container other than a module,
    //! but it is not very useful.  Currently, when producing the package
    //! documentation, these comments are ignored.
};
```
