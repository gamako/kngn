//! OS system text font のランタイム解決（TASK-85）。
//!
//! ホットパス: **初期化時のみ**。起動時に fc-match subprocess（Linux family 候補数まで
//! 最大数回）+ font file read + `FontFace.init` parse 検証を行う（1 回の load 呼び出しあたり）。
//! フレーム毎・RT・イベント hot path は新設しない。

const std = @import("std");
const builtin = @import("builtin");
const outline_font = @import("outline_font.zig");
const text_layer = @import("text_layer.zig");

const FontFace = outline_font.FontFace;

pub const LoadedFace = struct {
    bytes: []u8,
    face: FontFace,
};

const default_fontconfig_families = [_][]const u8{
    "Noto Sans CJK JP",
    "Noto Sans CJK",
    "Unifont",
    "DejaVu Sans",
    "Liberation Sans",
};

const default_fixed_paths = [_][]const u8{
    // macOS: 日本語 .ttc（ASCII も含むので 1 本で混在描画可）→ ASCII フォールバック
    "/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc",
    "/System/Library/Fonts/ヒラギノ角ゴシック W4.ttc",
    "/System/Library/Fonts/ヒラギノ明朝 ProN.ttc",
    "/System/Library/Fonts/Supplemental/Andale Mono.ttf",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/System/Library/Fonts/Supplemental/Times New Roman.ttf",
    "/Library/Fonts/Arial.ttf",
    // Windows: 日本語 → ASCII
    "C:/Windows/Fonts/YuGothM.ttc",
    "C:/Windows/Fonts/meiryo.ttc",
    "C:/Windows/Fonts/msgothic.ttc",
    "C:/Windows/Fonts/arial.ttf",
    "C:/Windows/Fonts/segoeui.ttf",
    "C:/Windows/Fonts/consola.ttf",
    // Linux（Ubuntu / nix FHS）: 日本語(CJK) → ASCII
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
};

const fc_match_stdout_limit: usize = 4096;
const fc_match_stderr_limit: usize = 512;

const ResolveOptions = struct {
    enable_fontconfig: bool = builtin.os.tag == .linux,
    fontconfig_families: []const []const u8 = &default_fontconfig_families,
    fixed_paths: []const []const u8 = &default_fixed_paths,
};

const FcMatchOutcome = union(enum) {
    path: []const u8,
    unavailable,
    failed,
};

/// Linux のみ `fc-match -f "%{file}\t%{family}" <family>` で path を解決する。
/// `fc-match` 不在（FileNotFound）は `.unavailable` を返し固定パス fallback へ進む。
/// fc-match は要求 family が存在しなくても**代替フォントを返す**（fontconfig の
/// フォールバック）ため、返された family 名に要求名が含まれることを検証し、
/// 代替（不一致）は `.failed` として次候補へ進む（codex P1: CJK 候補が DejaVu 等の
/// 汎用代替で潰され日本語描画に失敗するのを防ぐ）。
fn fcMatchPath(gpa: std.mem.Allocator, io: std.Io, family: []const u8) FcMatchOutcome {
    const argv = [_][]const u8{ "fc-match", "-f", "%{file}\t%{family}", family };
    const result = std.process.run(gpa, io, .{
        .argv = &argv,
        .stdout_limit = .limited(fc_match_stdout_limit),
        .stderr_limit = .limited(fc_match_stderr_limit),
    }) catch |err| switch (err) {
        error.FileNotFound => return .unavailable,
        else => {
            std.debug.print("fc-match spawn {s}: {s}\n", .{ family, @errorName(err) });
            return .failed;
        },
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("fc-match {s}: exit {d}\n", .{ family, code });
                return .failed;
            }
            const out = std.mem.trim(u8, result.stdout, " \r\n");
            const tab = std.mem.indexOfScalar(u8, out, '\t') orelse {
                std.debug.print("fc-match {s}: unexpected output (no family field)\n", .{family});
                return .failed;
            };
            const path = std.mem.trim(u8, out[0..tab], " \r\n");
            const matched_family = std.mem.trim(u8, out[tab + 1 ..], " \r\n");
            if (path.len == 0) {
                std.debug.print("fc-match {s}: empty output\n", .{family});
                return .failed;
            }
            if (std.ascii.indexOfIgnoreCase(matched_family, family) == null) {
                std.debug.print("fc-match {s}: substituted by \"{s}\" (skip)\n", .{ family, matched_family });
                return .failed;
            }
            const duped = gpa.dupe(u8, path) catch |err| {
                std.debug.print("fc-match {s}: alloc {s}\n", .{ family, @errorName(err) });
                return .failed;
            };
            return .{ .path = duped };
        },
        else => {
            std.debug.print("fc-match {s}: abnormal termination\n", .{family});
            return .failed;
        },
    }
}

fn tryLoadPath(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ?LoadedFace {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch |err| {
        if (err != error.FileNotFound) std.debug.print("font read {s}: {s}\n", .{ path, @errorName(err) });
        return null;
    };
    const face = FontFace.init(bytes) catch |err| {
        std.debug.print("font parse {s}: {s}\n", .{ path, @errorName(err) });
        alloc.free(bytes);
        return null;
    };
    std.debug.print("font: loaded {s} ({d} bytes)\n", .{ path, bytes.len });
    return .{ .bytes = bytes, .face = face };
}

/// 候補解決・read・parse 試行の単一集約点（公開 API はこれだけを呼ぶ）。
fn resolveSystemTextFont(io: std.Io, alloc: std.mem.Allocator, opts: ResolveOptions) ?LoadedFace {
    if (opts.enable_fontconfig) {
        var fc_available = true;
        for (opts.fontconfig_families) |family| {
            if (!fc_available) break;
            const outcome = fcMatchPath(alloc, io, family);
            switch (outcome) {
                .unavailable => fc_available = false,
                .failed => {},
                .path => |resolved| {
                    defer alloc.free(resolved);
                    if (tryLoadPath(io, alloc, resolved)) |loaded| return loaded;
                },
            }
        }
    }

    for (opts.fixed_paths) |path| {
        if (tryLoadPath(io, alloc, path)) |loaded| return loaded;
    }
    return null;
}

/// examples 12/19/21 用: parse 検証済み `LoadedFace` を返す。`bytes` は呼び出し側が free する。
pub fn loadSystemTextFace(io: std.Io, alloc: std.mem.Allocator) ?LoadedFace {
    return resolveSystemTextFont(io, alloc, .{});
}

/// pixie 用: parse 検証済み font bytes のみ返す。`bytes` は呼び出し側が free する。
pub fn loadSystemTextFontBytes(io: std.Io, alloc: std.mem.Allocator) ?[]u8 {
    if (builtin.cpu.arch.isWasm()) return null;
    const loaded = resolveSystemTextFont(io, alloc, .{}) orelse return null;
    return loaded.bytes;
}

test "resolveSystemTextFont returns first successful candidate" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "valid.ttf",
        .data = text_layer.default_font_bytes,
    });
    const valid_path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/valid.ttf", .{tmp.sub_path});
    defer gpa.free(valid_path);

    const paths = [_][]const u8{ valid_path, "/nonexistent/vp_font_missing.ttf" };
    const loaded = resolveSystemTextFont(io, gpa, .{
        .enable_fontconfig = false,
        .fixed_paths = &paths,
    }) orelse return error.TestExpectedSuccess;
    defer gpa.free(loaded.bytes);
    try std.testing.expect(loaded.bytes.len > 0);
    try std.testing.expect(loaded.face.cmap.f4 != null or loaded.face.cmap.f12 != null);
}

test "resolveSystemTextFont returns null when all candidates fail parse" {
    const io = std.testing.io;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const leak = gpa.deinit();
        if (leak == .leak) std.debug.panic("memory leak in resolveSystemTextFont failure test", .{});
    }
    const alloc = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "invalid.ttf",
        .data = "not a font",
    });
    const invalid_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/invalid.ttf", .{tmp.sub_path});
    defer alloc.free(invalid_path);

    const paths = [_][]const u8{ invalid_path, "/nonexistent/vp_font_missing_2.ttf" };
    const loaded = resolveSystemTextFont(io, alloc, .{
        .enable_fontconfig = false,
        .fixed_paths = &paths,
    });
    try std.testing.expect(loaded == null);
}
