//! Host-side gate: a browser wasm artefact must export neither `_start` nor `_initialize`.
//!
//! Those two names are the entry symbols of wasi-libc's startup objects, so seeing either
//! one means libc reached the wasm module graph. The browser glue in `web/kngn.js` provides
//! a small WASI shim that does not implement what those startup objects import, so such a
//! module fails to instantiate — a failure that a successful compile and link cannot catch.
//!
//! Only the export section (id 7) is read, so a matching string elsewhere in the file
//! (a custom section, a data segment) cannot cause a false positive. A malformed input is
//! an error rather than a pass: a checker that reports "no forbidden export" for bytes it
//! could not parse would be worse than no checker.
//!
//! Build-graph tool only: the executable is not installed to zig-out/.
//! All work runs at package time (not per-frame / RT).

const std = @import("std");

/// Export names that must not appear in a wasm artefact meant for the browser.
pub const forbidden_exports = [_][]const u8{ "_start", "_initialize" };

pub const CheckError = error{
    /// The file does not start with the wasm magic.
    NotWasm,
    /// The wasm version field is not the one this checker understands.
    UnsupportedVersion,
    /// A read ran past the end of the input or of the section being read.
    Truncated,
    /// A LEB128 value does not fit in the width it is being decoded into.
    LebOverflow,
    /// A section declares a size that runs past the end of the file.
    SectionOverrun,
    /// An export entry carries a descriptor kind the format does not define.
    InvalidExportKind,
    /// An export section holds bytes beyond the vector it declares.
    TrailingSectionBytes,
};

const wasm_magic = [_]u8{ 0x00, 0x61, 0x73, 0x6d };
const wasm_version = [_]u8{ 0x01, 0x00, 0x00, 0x00 };

const export_section_id: u8 = 7;

/// Export descriptor kinds: func, table, mem, global, and tag from the exception proposal.
const max_export_kind: u8 = 4;

/// Bounds-checked cursor over a byte range. Every read either succeeds or fails;
/// there is no silent short read.
const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn byte(self: *Cursor) CheckError!u8 {
        if (self.pos >= self.bytes.len) return error.Truncated;
        const b = self.bytes[self.pos];
        self.pos += 1;
        return b;
    }

    fn take(self: *Cursor, n: usize) CheckError![]const u8 {
        if (n > self.bytes.len - self.pos) return error.Truncated;
        const slice = self.bytes[self.pos..][0..n];
        self.pos += n;
        return slice;
    }

    /// Unsigned LEB128 into u32. Rejects both a value too wide for u32 and a
    /// continuation bit that runs off the end of the input.
    fn leb32(self: *Cursor) CheckError!u32 {
        var result: u32 = 0;
        var shift: u32 = 0;
        while (true) {
            const b = try self.byte();
            const payload: u32 = b & 0x7f;
            if (shift >= 32) return error.LebOverflow;
            // At the last group only the low 4 bits still fit in a u32.
            if (shift == 28 and (payload >> 4) != 0) return error.LebOverflow;
            result |= payload << @intCast(shift);
            if (b & 0x80 == 0) return result;
            shift += 7;
        }
    }

    fn atEnd(self: *const Cursor) bool {
        return self.pos == self.bytes.len;
    }
};

/// Return the first forbidden export name found, or null when the module exports none.
/// The returned slice points into `wasm`.
pub fn findForbiddenExport(wasm: []const u8) CheckError!?[]const u8 {
    var cursor: Cursor = .{ .bytes = wasm };
    if (!std.mem.eql(u8, try cursor.take(wasm_magic.len), &wasm_magic)) return error.NotWasm;
    if (!std.mem.eql(u8, try cursor.take(wasm_version.len), &wasm_version)) return error.UnsupportedVersion;

    // A module may carry several export sections only in malformed input, but scanning
    // every one of them costs nothing and removes a way to hide a name from the check.
    while (!cursor.atEnd()) {
        const id = try cursor.byte();
        const size = try cursor.leb32();
        const body = cursor.take(size) catch return error.SectionOverrun;
        if (id != export_section_id) continue;

        var section: Cursor = .{ .bytes = body };
        var remaining = try section.leb32();
        while (remaining > 0) : (remaining -= 1) {
            const name_len = try section.leb32();
            const name = try section.take(name_len);
            const kind = try section.byte();
            if (kind > max_export_kind) return error.InvalidExportKind;
            _ = try section.leb32(); // index into the kind's space
            for (forbidden_exports) |forbidden| {
                if (std.mem.eql(u8, name, forbidden)) return name;
            }
        }
        // The section body is exactly its vector. Bytes left over mean the vector length
        // does not describe the content, so the entries read above cannot be trusted to be
        // all of them — the one name being looked for could be hiding in the remainder.
        if (!section.atEnd()) return error.TrailingSectionBytes;
    }
    return null;
}

fn reportForbidden(wasm_path: []const u8, name: []const u8) void {
    std.log.err(
        \\{s} exports `{s}`, which a wasm module built for the browser must not do.
        \\
        \\`_start` and `_initialize` are the entry symbols of wasi-libc's startup objects, so
        \\seeing one usually means libc reached the wasm module graph. The browser glue in
        \\web/kngn.js provides a small WASI shim that does not implement what those startup
        \\objects import, so the module fails before it can be instantiated.
        \\
        \\Check that every module in the wasm graph is created with link_libc = false;
        \\createPlatformModule in build_helpers/platform.zig is the worked example.
    ,
        .{ wasm_path, name },
    );
}

const CliArgs = struct {
    wasm: []const u8,
    out: []const u8,
};

fn parseArgs(it: *std.process.Args.Iterator) !CliArgs {
    var wasm: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--wasm")) {
            wasm = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--out")) {
            out = it.next() orelse return error.MissingValue;
        } else {
            std.log.err("unknown argument: {s}", .{a});
            return error.UnknownArg;
        }
    }
    return .{
        .wasm = wasm orelse return error.MissingWasm,
        .out = out orelse return error.MissingOut,
    };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer it.deinit();
    _ = it.next(); // program name

    const cli = parseArgs(&it) catch {
        std.log.err("usage: check-wasm-exports --wasm app.wasm --out stamp.txt", .{});
        std.process.exit(2);
    };

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, cli.wasm, gpa, .limited(256 * 1024 * 1024));
    defer gpa.free(wasm);

    const found = findForbiddenExport(wasm) catch |err| {
        std.log.err("{s}: cannot read the wasm export section ({s})", .{ cli.wasm, @errorName(err) });
        std.process.exit(1);
    };
    if (found) |name| {
        reportForbidden(cli.wasm, name);
        std.process.exit(1);
    }

    // The stamp turns this into a cacheable build step with a declared output.
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = cli.out,
        .data = "no forbidden wasm export\n",
    });
}

// ---------------------------------------------------------------------------
// Unit tests (host-only; step name test-check-wasm-exports)
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Build a wasm module whose export section names `names`, each as a func export.
fn buildModule(gpa: std.mem.Allocator, names: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &wasm_magic);
    try out.appendSlice(gpa, &wasm_version);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.append(gpa, @intCast(names.len)); // vector length (< 128, one LEB byte)
    for (names, 0..) |name, i| {
        try body.append(gpa, @intCast(name.len));
        try body.appendSlice(gpa, name);
        try body.append(gpa, 0x00); // kind: func
        try body.append(gpa, @intCast(i)); // index
    }

    try out.append(gpa, export_section_id);
    try out.append(gpa, @intCast(body.items.len));
    try out.appendSlice(gpa, body.items);
    return out.toOwnedSlice(gpa);
}

test "a module exporting neither name passes" {
    const gpa = testing.allocator;
    const wasm = try buildModule(gpa, &.{ "memory", "kngn_frame" });
    defer gpa.free(wasm);
    try testing.expectEqual(@as(?[]const u8, null), try findForbiddenExport(wasm));
}

test "_start is reported" {
    const gpa = testing.allocator;
    const wasm = try buildModule(gpa, &.{"_start"});
    defer gpa.free(wasm);
    try testing.expectEqualStrings("_start", (try findForbiddenExport(wasm)).?);
}

test "_initialize is reported" {
    const gpa = testing.allocator;
    const wasm = try buildModule(gpa, &.{"_initialize"});
    defer gpa.free(wasm);
    try testing.expectEqualStrings("_initialize", (try findForbiddenExport(wasm)).?);
}

test "a forbidden name after other entries is still reported" {
    const gpa = testing.allocator;
    const wasm = try buildModule(gpa, &.{ "memory", "kngn_init", "kngn_frame", "_initialize" });
    defer gpa.free(wasm);
    try testing.expectEqualStrings("_initialize", (try findForbiddenExport(wasm)).?);
}

test "a name that merely contains a forbidden one passes" {
    const gpa = testing.allocator;
    const wasm = try buildModule(gpa, &.{ "_start_extra", "prefix_start", "my_initialize" });
    defer gpa.free(wasm);
    try testing.expectEqual(@as(?[]const u8, null), try findForbiddenExport(wasm));
}

test "sections before the export section are skipped" {
    const gpa = testing.allocator;
    const tail = try buildModule(gpa, &.{"_start"});
    defer gpa.free(tail);

    var wasm: std.ArrayList(u8) = .empty;
    defer wasm.deinit(gpa);
    try wasm.appendSlice(gpa, tail[0..8]); // magic + version
    // A custom section (id 0) whose payload spells out the forbidden name.
    const custom_body = [_]u8{ 0x04, 'n', 'a', 'm', 'e' } ++ "_start".*;
    try wasm.append(gpa, 0x00);
    try wasm.append(gpa, @intCast(custom_body.len));
    try wasm.appendSlice(gpa, &custom_body);
    try wasm.appendSlice(gpa, tail[8..]);

    try testing.expectEqualStrings("_start", (try findForbiddenExport(wasm.items)).?);
}

test "a forbidden name only in a custom section is not a match" {
    const gpa = testing.allocator;
    var wasm: std.ArrayList(u8) = .empty;
    defer wasm.deinit(gpa);
    try wasm.appendSlice(gpa, &wasm_magic);
    try wasm.appendSlice(gpa, &wasm_version);
    const custom_body = "_start".*;
    try wasm.append(gpa, 0x00);
    try wasm.append(gpa, @intCast(custom_body.len));
    try wasm.appendSlice(gpa, &custom_body);

    try testing.expectEqual(@as(?[]const u8, null), try findForbiddenExport(wasm.items));
}

test "a second export section is scanned too" {
    const gpa = testing.allocator;
    const first = try buildModule(gpa, &.{"memory"});
    defer gpa.free(first);
    const second = try buildModule(gpa, &.{"_start"});
    defer gpa.free(second);

    var wasm: std.ArrayList(u8) = .empty;
    defer wasm.deinit(gpa);
    try wasm.appendSlice(gpa, first);
    try wasm.appendSlice(gpa, second[8..]); // the export section only

    try testing.expectEqualStrings("_start", (try findForbiddenExport(wasm.items)).?);
}

test "a file that is not wasm is an error" {
    try testing.expectError(error.NotWasm, findForbiddenExport("not a wasm file at all"));
}

test "an unsupported version is an error" {
    var wasm = wasm_magic ++ [_]u8{ 0x02, 0x00, 0x00, 0x00 };
    try testing.expectError(error.UnsupportedVersion, findForbiddenExport(&wasm));
}

test "a file shorter than the header is an error" {
    try testing.expectError(error.Truncated, findForbiddenExport(&wasm_magic));
}

test "a section running past the end of the file is an error" {
    const gpa = testing.allocator;
    var wasm: std.ArrayList(u8) = .empty;
    defer wasm.deinit(gpa);
    try wasm.appendSlice(gpa, &wasm_magic);
    try wasm.appendSlice(gpa, &wasm_version);
    try wasm.append(gpa, export_section_id);
    try wasm.append(gpa, 0x40); // claims 64 bytes
    try wasm.appendSlice(gpa, &.{ 0x01, 0x02 }); // supplies 2

    try testing.expectError(error.SectionOverrun, findForbiddenExport(wasm.items));
}

test "an export vector cut short is an error" {
    const gpa = testing.allocator;
    const whole = try buildModule(gpa, &.{ "memory", "_start" });
    defer gpa.free(whole);

    // Keep the section header but drop the last byte of its body, and shrink the
    // declared size to match so the truncation is inside the vector, not the section.
    var wasm: std.ArrayList(u8) = .empty;
    defer wasm.deinit(gpa);
    try wasm.appendSlice(gpa, whole[0 .. whole.len - 1]);
    wasm.items[9] -= 1;

    try testing.expectError(error.Truncated, findForbiddenExport(wasm.items));
}

test "a LEB128 value wider than u32 is an error" {
    const gpa = testing.allocator;
    var wasm: std.ArrayList(u8) = .empty;
    defer wasm.deinit(gpa);
    try wasm.appendSlice(gpa, &wasm_magic);
    try wasm.appendSlice(gpa, &wasm_version);
    try wasm.append(gpa, export_section_id);
    // Six continuation bytes: more groups than a u32 can hold.
    try wasm.appendSlice(gpa, &.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 });

    try testing.expectError(error.LebOverflow, findForbiddenExport(wasm.items));
}

test "bytes left over after the export vector are an error" {
    const gpa = testing.allocator;
    var wasm: std.ArrayList(u8) = .empty;
    defer wasm.deinit(gpa);
    try wasm.appendSlice(gpa, &wasm_magic);
    try wasm.appendSlice(gpa, &wasm_version);
    try wasm.append(gpa, export_section_id);
    try wasm.appendSlice(gpa, &.{ 0x02, 0x00, 0xff }); // size 2: an empty vector plus a stray byte

    try testing.expectError(error.TrailingSectionBytes, findForbiddenExport(wasm.items));
}

test "an undefined export kind is an error" {
    const gpa = testing.allocator;
    const wasm = try buildModule(gpa, &.{"memory"});
    defer gpa.free(wasm);
    // Overwrite the kind byte of the single entry: magic(4) version(4) id(1) size(1)
    // count(1) name_len(1) name(6) → kind.
    wasm[18] = 0x05;
    try testing.expectError(error.InvalidExportKind, findForbiddenExport(wasm));
}

test "a five-byte LEB128 whose top group overflows u32 is an error" {
    const gpa = testing.allocator;
    var wasm: std.ArrayList(u8) = .empty;
    defer wasm.deinit(gpa);
    try wasm.appendSlice(gpa, &wasm_magic);
    try wasm.appendSlice(gpa, &wasm_version);
    try wasm.append(gpa, export_section_id);
    // Five groups where the last contributes bits above bit 31.
    try wasm.appendSlice(gpa, &.{ 0x80, 0x80, 0x80, 0x80, 0x10 });

    try testing.expectError(error.LebOverflow, findForbiddenExport(wasm.items));
}

test "a LEB128 value whose continuation bit runs off the end is an error" {
    const gpa = testing.allocator;
    var wasm: std.ArrayList(u8) = .empty;
    defer wasm.deinit(gpa);
    try wasm.appendSlice(gpa, &wasm_magic);
    try wasm.appendSlice(gpa, &wasm_version);
    try wasm.append(gpa, export_section_id);
    try wasm.append(gpa, 0x80); // asks for another byte that never arrives

    try testing.expectError(error.Truncated, findForbiddenExport(wasm.items));
}
