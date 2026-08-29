//! Reading a sample's declaration.
//!
//! A sample that builds on its own as a package states how it is wired in its own `sample.zon`
//! (`consumer.SampleDecl`). The sample's standalone `build.zig` reads that with `@import`, and the
//! build in this repository reads the same file through here, so the wiring is stated once rather
//! than once per build script.
//!
//! This build cannot use `@import` for it: a file may belong to only one module, and when a sample
//! builds standalone both build scripts are live, so importing the file from both fails with
//! "file exists in modules 'root.@build' and 'root.@dependencies...'".
//!
//! Reading it as text makes *how* it is read part of the contract — the two readers have to agree
//! on what the file says. Scanning for words does not agree: a comment, an empty list and a nested
//! list each mean one thing to `@import` and another to a word scanner. So it is parsed as ZON
//! here too, against the same type the sample annotates its import with.
//!
//! Not a hot path: once per sample, at build configuration time.

const std = @import("std");
const consumer = @import("consumer.zig");

pub const SampleDecl = consumer.SampleDecl;

/// A module a sample may import by name. `platform` and `keyboard` are wired for every sample, so
/// naming them is allowed and carries no further meaning.
pub const Module = enum {
    kit,
    sprite,
    fps_counter,
    fixed_timestep,
    text,
    gui,
    png,
    font,
    paint,
    gmath,
    sound,
    pixelops,
    audio,
    gamepad,
    midi,
    platform,
    keyboard,
};

pub const Set = std.EnumSet(Module);

/// What a `sample.zon` turned out to say. Reporting is the caller's: it knows which file it was
/// reading and decides what a bad one means, which for both readers of a declaration is stopping.
/// A parsed declaration: the module names as a set to switch on, and the declaration itself for
/// the fields that are not module names.
pub const Parsed = struct {
    modules: Set,
    decl: SampleDecl,
};

pub const Result = union(enum) {
    ok: Parsed,
    /// Not a ZON list of strings. `Diagnostics` holds where and why.
    malformed,
    /// A list naming nothing. A sample that imports no module cannot build, so this is never
    /// what the author meant.
    empty,
    /// A name this build does not wire. Reported rather than skipped, so a typo cannot leave a
    /// module quietly unwired.
    unknown: []const u8,
};

/// `source` must be sentinel-terminated because that is what the ZON parser takes.
///
/// Allocates from `gpa` and frees nothing. `gpa` must stay valid for as long as the returned
/// `Result` is used, because `ok` and `unknown` both borrow from the parsed declaration. Pass an
/// arena: the build allocator is one, and every case other than `ok` ends the build, so there is
/// nothing to reclaim.
pub fn parse(
    gpa: std.mem.Allocator,
    source: [:0]const u8,
    diag: ?*std.zon.parse.Diagnostics,
) error{OutOfMemory}!Result {
    const decl = std.zon.parse.fromSliceAlloc(SampleDecl, gpa, source, diag, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => return .malformed,
    };
    if (decl.modules.len == 0) return .empty;

    var set: Set = .{};
    for (decl.modules) |name| {
        const module = std.meta.stringToEnum(Module, name) orelse return .{ .unknown = name };
        set.insert(module);
    }
    return .{ .ok = .{ .modules = set, .decl = decl } };
}

/// What a test needs from a parse, with nothing that outlives the arena: the tag, and for a
/// successful parse the parts that hold no pointers. Returning the `Result` itself would hand back
/// a value borrowing from an arena this function has already freed.
const Outcome = struct {
    tag: std.meta.Tag(Result),
    modules: Set = .{},
    features: consumer.PlatformFeatures = .{},
    console_subsystem: bool = false,
};

fn expectParse(source: [:0]const u8) Outcome {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diag: std.zon.parse.Diagnostics = .{};
    const result = parse(arena.allocator(), source, &diag) catch unreachable;
    return switch (result) {
        .ok => |parsed| .{
            .tag = .ok,
            .modules = parsed.modules,
            .features = parsed.decl.effectiveFeatures(),
            .console_subsystem = parsed.decl.console_subsystem,
        },
        .malformed => .{ .tag = .malformed },
        .empty => .{ .tag = .empty },
        // The name borrows from the arena, so it is checked by the test that keeps one alive.
        .unknown => .{ .tag = .unknown },
    };
}

test "a declaration naming one module parses" {
    const result = expectParse(".{ .modules = .{\"kit\"} }");
    try std.testing.expect(result.tag == .ok);
    try std.testing.expect(result.modules.contains(.kit));
    try std.testing.expect(!result.modules.contains(.gui));
}

test "several names parse, order does not matter" {
    const result = expectParse(".{ .modules = .{ \"font\", \"platform\", \"text\" } }");
    try std.testing.expect(result.tag == .ok);
    try std.testing.expect(result.modules.contains(.font));
    try std.testing.expect(result.modules.contains(.platform));
    try std.testing.expect(result.modules.contains(.text));
}

test "features default to nothing enabled, except text input" {
    const result = expectParse(".{ .modules = .{\"kit\"} }");
    try std.testing.expect(result.tag == .ok);
    try std.testing.expect(!result.features.enable_audio);
    try std.testing.expect(!result.features.enable_gamepad);
    try std.testing.expect(!result.console_subsystem);
    try std.testing.expect(result.features.enable_text_input);
}

test "features and the subsystem are read when stated" {
    const result = expectParse(
        ".{ .modules = .{\"kit\"}, .features = .{ .enable_audio = true }, .console_subsystem = true }",
    );
    try std.testing.expect(result.tag == .ok);
    try std.testing.expect(result.features.enable_audio);
    try std.testing.expect(result.console_subsystem);
}

test "a comment is accepted, because the sample's own import accepts it" {
    const result = expectParse("// what this sample is wired with\n.{ .modules = .{\"kit\"} }");
    try std.testing.expect(result.tag == .ok);
    try std.testing.expect(result.modules.contains(.kit));
}

test "a trailing comma is accepted" {
    try std.testing.expect(expectParse(".{ .modules = .{ \"kit\", } }").tag == .ok);
}

test "a declaration naming no module is rejected rather than read as no modules" {
    try std.testing.expect(expectParse(".{ .modules = .{} }").tag == .empty);
}

test "an empty file is rejected" {
    try std.testing.expect(expectParse("").tag == .malformed);
}

test "a bare list is rejected: the declaration carries more than modules" {
    try std.testing.expect(expectParse(".{\"kit\"}").tag == .malformed);
}

test "a declaration with no modules field is rejected" {
    try std.testing.expect(expectParse(".{ .console_subsystem = true }").tag == .malformed);
}

test "an unknown field is rejected rather than ignored" {
    try std.testing.expect(expectParse(".{ .modules = .{\"kit\"}, .no_such_field = true }").tag == .malformed);
}

test "a nested module list is rejected rather than flattened" {
    try std.testing.expect(expectParse(".{ .modules = .{ .{\"kit\"} } }").tag == .malformed);
}

test "an enum literal is not mistaken for a module name" {
    try std.testing.expect(expectParse(".{ .modules = .{ .kit } }").tag == .malformed);
}

test "an unknown module name is reported with the name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diag: std.zon.parse.Diagnostics = .{};
    const result = try parse(arena.allocator(), ".{ .modules = .{ \"kit\", \"no_such_module\" } }", &diag);
    try std.testing.expect(result == .unknown);
    try std.testing.expectEqualStrings("no_such_module", result.unknown);
}
