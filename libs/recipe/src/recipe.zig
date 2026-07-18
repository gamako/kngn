//! recipe — CommandRecord 列（意味的コマンド列）の save/load（TASK-62.5.8）。
//!
//! std + libs/serde のみ（core 非依存）。CommandLog→Entry の変換は app 側が
//! `RecordView` を渡して `collectNormalEntries` を呼ぶ（型結合を避けて薄く保つ）。
//!
//! フォーマット（serde versioned container。magic='RCP1'、schema=format_version）:
//! - HEAD(1個・先頭): app_name UTF-8（≤ MAX_APP_NAME）
//! - ENTR(N回・出現順): name_len u8 | name | args_len u16 LE | args
//!
//! **サイズ上限（共有ファイル防御）**:
//! - `MAX_RECIPE_BYTES`（4MiB）: ファイル全体 / 累積 ENTR payload の上限。action args は
//!   CommandRecord 契約で ≤4096B（`MAX_CMD_ARGS`）なので、現実的なコマンド列（数千〜数万）を
//!   余裕をもって収める値。共有・外部から渡される recipe を無制限に読むとメモリ枯渇を
//!   誘発できるため、`load` の read と `decode` の双方で拒否する。
//! - `MAX_ENTRIES`（65536）: 細切れ ENTR による alloc 嵐を防ぐ。CommandLog リングは 128 だが、
//!   共有レシピはそれより長くなりうるため余裕を持たせつつ上限を設ける。
//!
//! ホットパス宣言: save/load/collect はすべてイベント時のみ（action 実行時・ファイル I/O）。
//! フレーム毎・RT に触れない。

const std = @import("std");
const Allocator = std.mem.Allocator;
const serde = @import("serde");

/// .recipe の magic（FourCC 'RCP1' の little-endian u32）。
pub const magic: u32 = @as(u32, 'R') | (@as(u32, 'C') << 8) | (@as(u32, 'P') << 16) | (@as(u32, '1') << 24);
/// レシピ schema / format_version（serde の schema_version に載せる）。
pub const format_version: u16 = 1;
/// header.app_name の上限バイト数。
pub const MAX_APP_NAME: usize = 64;
/// レシピファイル全体（および decode 中の累積 ENTR payload）の上限バイト数。根拠はファイル先頭 doc。
pub const MAX_RECIPE_BYTES: usize = 4 * 1024 * 1024;
/// ENTR チャンク数の上限。根拠はファイル先頭 doc。
pub const MAX_ENTRIES: usize = 65536;

const TAG_HEAD: [4]u8 = "HEAD".*;
const TAG_ENTR: [4]u8 = "ENTR".*;

pub const Error = error{
    AppNameTooLong,
    UnsupportedFormatVersion,
    MissingHeader,
    DuplicateHeader,
    CorruptEntry,
    AppMismatch,
    NestedReplay,
    RecipeTooLarge,
    TooManyEntries,
};

pub const RecipeHeader = struct {
    app_name: []const u8,
    format_version: u16 = format_version,
};

pub const Entry = struct {
    name: []const u8,
    args: []const u8,
};

/// CommandLog 相当の 1 record への view（core 非依存。app が埋める）。
pub const RecordView = struct {
    is_normal: bool,
    name: []const u8,
    args: []const u8,
};

/// load 結果（所有。caller が `deinit`）。
pub const Loaded = struct {
    header: RecipeHeader,
    entries: []Entry,
    /// header.app_name と各 entry の name/args を含む単一 arena 相当の所有ブロック。
    /// （簡易: 個別 alloc。deinit で全て free）
    alloc: Allocator,

    pub fn deinit(self: *Loaded) void {
        self.alloc.free(self.header.app_name);
        for (self.entries) |e| {
            self.alloc.free(e.name);
            self.alloc.free(e.args);
        }
        self.alloc.free(self.entries);
        self.* = undefined;
    }
};

/// kind=normal のみを出現順（= seq 順。呼び出し側が seq 昇順で渡す）で Entry 化する。
/// 返る Entry の name/args は `records` への借用（encode/save 完了まで records が生きていること）。
/// スライス自体は caller が `gpa.free` する。
pub fn collectNormalEntries(gpa: Allocator, records: []const RecordView) Allocator.Error![]Entry {
    var list: std.ArrayList(Entry) = .empty;
    errdefer list.deinit(gpa);
    for (records) |r| {
        if (!r.is_normal) continue;
        try list.append(gpa, .{ .name = r.name, .args = r.args });
    }
    return list.toOwnedSlice(gpa);
}

/// ファイルの app_name が期待値と一致するか（不一致は `error.AppMismatch`）。
pub fn checkAppName(file_app: []const u8, expected: []const u8) Error!void {
    if (!std.mem.eql(u8, file_app, expected)) return error.AppMismatch;
}

/// recipe_replay 入れ子防止（既に replay 中なら `error.NestedReplay`）。
pub fn checkNotReplaying(replaying: bool) Error!void {
    if (replaying) return error.NestedReplay;
}

/// Recipe をバイト列へ直列化する（caller が free）。
pub fn encode(gpa: Allocator, header: RecipeHeader, entries: []const Entry) (Error || Allocator.Error || error{PayloadTooLarge})![]u8 {
    if (header.app_name.len > MAX_APP_NAME) return error.AppNameTooLong;
    if (header.format_version != format_version) return error.UnsupportedFormatVersion;

    var w = try serde.Writer.init(gpa, magic, header.format_version);
    errdefer w.deinit();

    try w.addChunk(TAG_HEAD, header.app_name);

    for (entries) |e| {
        if (e.name.len > std.math.maxInt(u8)) return error.CorruptEntry;
        if (e.args.len > std.math.maxInt(u16)) return error.CorruptEntry;
        const payload_len = 1 + e.name.len + 2 + e.args.len;
        const buf = try gpa.alloc(u8, payload_len);
        defer gpa.free(buf);
        buf[0] = @intCast(e.name.len);
        @memcpy(buf[1..][0..e.name.len], e.name);
        std.mem.writeInt(u16, buf[1 + e.name.len ..][0..2], @intCast(e.args.len), .little);
        @memcpy(buf[1 + e.name.len + 2 ..][0..e.args.len], e.args);
        try w.addChunk(TAG_ENTR, buf);
    }

    return w.finish();
}

/// バイト列から Recipe を復元する（所有。caller が `Loaded.deinit`）。
/// `bytes.len > MAX_RECIPE_BYTES` / ENTR 数 > `MAX_ENTRIES` / 累積 ENTR payload >
/// `MAX_RECIPE_BYTES` はそれぞれ `RecipeTooLarge` / `TooManyEntries` / `RecipeTooLarge`。
pub fn decode(gpa: Allocator, bytes: []const u8) (Error || serde.Error || Allocator.Error)!Loaded {
    if (bytes.len > MAX_RECIPE_BYTES) return error.RecipeTooLarge;

    const container = try serde.Container.parse(bytes, magic);
    if (container.schemaVersion() != format_version) return error.UnsupportedFormatVersion;

    var app_name: ?[]u8 = null;
    errdefer if (app_name) |n| gpa.free(n);

    var list: std.ArrayList(Entry) = .empty;
    errdefer {
        for (list.items) |e| {
            gpa.free(e.name);
            gpa.free(e.args);
        }
        list.deinit(gpa);
    }

    var it = container.iterator();
    var seen_head = false;
    var entr_count: usize = 0;
    var entr_payload_total: usize = 0;
    while (it.next()) |chunk| {
        if (std.mem.eql(u8, &chunk.tag, &TAG_HEAD)) {
            if (seen_head) return error.DuplicateHeader;
            if (list.items.len != 0) return error.MissingHeader; // HEAD は先頭（ENTR より前）必須
            if (chunk.payload.len > MAX_APP_NAME) return error.AppNameTooLong;
            app_name = try gpa.dupe(u8, chunk.payload);
            seen_head = true;
        } else if (std.mem.eql(u8, &chunk.tag, &TAG_ENTR)) {
            if (!seen_head) return error.MissingHeader;
            entr_count += 1;
            if (entr_count > MAX_ENTRIES) return error.TooManyEntries;
            entr_payload_total += chunk.payload.len;
            if (entr_payload_total > MAX_RECIPE_BYTES) return error.RecipeTooLarge;
            const e = try decodeEntry(gpa, chunk.payload);
            try list.append(gpa, e);
        }
        // 未知 tag は serde 流儀で skip（前方互換）。ただし HEAD 前の未知 tag も
        // 「先頭が HEAD」規約に反するため拒否する。
        else if (!seen_head) return error.MissingHeader;
    }

    const name = app_name orelse return error.MissingHeader;
    app_name = null;
    const entries = try list.toOwnedSlice(gpa);
    return .{
        .header = .{ .app_name = name, .format_version = container.schemaVersion() },
        .entries = entries,
        .alloc = gpa,
    };
}

fn decodeEntry(gpa: Allocator, payload: []const u8) (Error || Allocator.Error)!Entry {
    if (payload.len < 1 + 2) return error.CorruptEntry;
    const name_len: usize = payload[0];
    if (payload.len < 1 + name_len + 2) return error.CorruptEntry;
    const name_bytes = payload[1..][0..name_len];
    const args_len: usize = std.mem.readInt(u16, payload[1 + name_len ..][0..2], .little);
    if (payload.len != 1 + name_len + 2 + args_len) return error.CorruptEntry;
    const args_bytes = payload[1 + name_len + 2 ..][0..args_len];
    const name = try gpa.dupe(u8, name_bytes);
    errdefer gpa.free(name);
    const args = try gpa.dupe(u8, args_bytes);
    return .{ .name = name, .args = args };
}

/// path へ保存する（encode → writeFile）。
pub fn save(io: std.Io, path: []const u8, header: RecipeHeader, entries: []const Entry, gpa: Allocator) !void {
    const bytes = try encode(gpa, header, entries);
    defer gpa.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

/// path から読む（所有。caller が `Loaded.deinit`）。
/// ファイルが `MAX_RECIPE_BYTES` を超えると `error.RecipeTooLarge`（read 上限は
/// `MAX_RECIPE_BYTES+1` で「ちょうど上限は許可・超過は拒否」を区別）。
pub fn load(io: std.Io, gpa: Allocator, path: []const u8) !Loaded {
    // +1: ちょうど MAX_RECIPE_BYTES は許可し、それより大きいときだけ拒否する
    // （`.limited(N)` は N バイト読み切った時点で StreamTooLong になりうるため）。
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(MAX_RECIPE_BYTES + 1)) catch |err| {
        if (err == error.StreamTooLong) return error.RecipeTooLarge;
        return err;
    };
    defer gpa.free(bytes);
    if (bytes.len > MAX_RECIPE_BYTES) return error.RecipeTooLarge;
    return decode(gpa, bytes);
}

// ============================ tests ============================

const testing = std.testing;

fn expectRoundTrip(header: RecipeHeader, entries: []const Entry) !void {
    const gpa = testing.allocator;
    const bytes = try encode(gpa, header, entries);
    defer gpa.free(bytes);
    var loaded = try decode(gpa, bytes);
    defer loaded.deinit();
    try testing.expectEqualStrings(header.app_name, loaded.header.app_name);
    try testing.expectEqual(format_version, loaded.header.format_version);
    try testing.expectEqual(entries.len, loaded.entries.len);
    for (entries, loaded.entries) |a, b| {
        try testing.expectEqualStrings(a.name, b.name);
        try testing.expectEqualStrings(a.args, b.args);
    }
}

test "round-trip: 空 entries" {
    try expectRoundTrip(.{ .app_name = "pixie" }, &.{});
}

test "round-trip: 1件 / args 空白 / 長大 args" {
    var long_args: [4000]u8 = undefined;
    @memset(&long_args, 'x');
    try expectRoundTrip(.{ .app_name = "pixie" }, &.{
        .{ .name = "set_color", .args = "ff0000" },
    });
    try expectRoundTrip(.{ .app_name = "modular" }, &.{
        .{ .name = "set_param", .args = "tempo 122.5" },
        .{ .name = "stroke", .args = &long_args },
    });
}

test "round-trip: 多数 entries" {
    var bufs: [64][8]u8 = undefined;
    var entries: [64]Entry = undefined;
    for (&entries, 0..) |*e, i| {
        const name = try std.fmt.bufPrint(&bufs[i], "a{d}", .{i});
        e.* = .{ .name = name, .args = "x" };
    }
    try expectRoundTrip(.{ .app_name = "pixie" }, &entries);
}

test "破損 CRC → CrcMismatch" {
    const gpa = testing.allocator;
    const bytes = try encode(gpa, .{ .app_name = "pixie" }, &.{.{ .name = "clear", .args = "" }});
    defer gpa.free(bytes);
    // footer CRC を壊す
    bytes[bytes.len - 1] ^= 0xff;
    try testing.expectError(error.CrcMismatch, decode(gpa, bytes));
}

test "版不一致 → UnsupportedFormatVersion" {
    const gpa = testing.allocator;
    var w = try serde.Writer.init(gpa, magic, 99);
    defer w.deinit();
    try w.addChunk(TAG_HEAD, "pixie");
    const bytes = try w.finish();
    defer gpa.free(bytes);
    try testing.expectError(error.UnsupportedFormatVersion, decode(gpa, bytes));
}

test "app_name 長超過 → AppNameTooLong" {
    const gpa = testing.allocator;
    var long: [MAX_APP_NAME + 1]u8 = undefined;
    @memset(&long, 'a');
    try testing.expectError(error.AppNameTooLong, encode(gpa, .{ .app_name = &long }, &.{}));

    // decode 側: HEAD payload が長すぎる
    var w = try serde.Writer.init(gpa, magic, format_version);
    defer w.deinit();
    try w.addChunk(TAG_HEAD, &long);
    const bytes = try w.finish();
    defer gpa.free(bytes);
    try testing.expectError(error.AppNameTooLong, decode(gpa, bytes));
}

test "collectNormalEntries: normal のみ・出現順（seq 順）" {
    const gpa = testing.allocator;
    const views = [_]RecordView{
        .{ .is_normal = true, .name = "set_color", .args = "ff0000" },
        .{ .is_normal = false, .name = "undo", .args = "" }, // revert 相当 → 除外
        .{ .is_normal = true, .name = "stroke", .args = "1 2 3 4" },
        .{ .is_normal = false, .name = "redo", .args = "" },
        .{ .is_normal = true, .name = "clear", .args = "" },
    };
    const entries = try collectNormalEntries(gpa, &views);
    defer gpa.free(entries);
    try testing.expectEqual(@as(usize, 3), entries.len);
    try testing.expectEqualStrings("set_color", entries[0].name);
    try testing.expectEqualStrings("stroke", entries[1].name);
    try testing.expectEqualStrings("clear", entries[2].name);
}

test "checkAppName / checkNotReplaying" {
    try checkAppName("pixie", "pixie");
    try testing.expectError(error.AppMismatch, checkAppName("modular", "pixie"));
    try checkNotReplaying(false);
    try testing.expectError(error.NestedReplay, checkNotReplaying(true));
}

test "file I/O: save→load 往復" {
    const gpa = testing.allocator;
    const io = std.testing.io;
    const path = ".task6258_recipe_test.recipe";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const entries = [_]Entry{
        .{ .name = "seed", .args = "42" },
        .{ .name = "set_param", .args = "tempo 100" },
    };
    try save(io, path, .{ .app_name = "modular" }, &entries, gpa);
    var loaded = try load(io, gpa, path);
    defer loaded.deinit();
    try testing.expectEqualStrings("modular", loaded.header.app_name);
    try testing.expectEqual(@as(usize, 2), loaded.entries.len);
    try testing.expectEqualStrings("seed", loaded.entries[0].name);
    try testing.expectEqualStrings("42", loaded.entries[0].args);
}

test "duplicate HEAD → DuplicateHeader" {
    const gpa = testing.allocator;
    var w = try serde.Writer.init(gpa, magic, format_version);
    defer w.deinit();
    try w.addChunk(TAG_HEAD, "pixie");
    try w.addChunk(TAG_HEAD, "modular");
    const bytes = try w.finish();
    defer gpa.free(bytes);
    try testing.expectError(error.DuplicateHeader, decode(gpa, bytes));
}

test "corrupt ENTR payload → CorruptEntry" {
    const gpa = testing.allocator;

    // payload 全体が短すぎる
    {
        var w = try serde.Writer.init(gpa, magic, format_version);
        defer w.deinit();
        try w.addChunk(TAG_HEAD, "pixie");
        const entr = [_]u8{ 5, 'c' };
        try w.addChunk(TAG_ENTR, &entr);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.CorruptEntry, decode(gpa, bytes));
    }

    // name_len と実 payload 長が不一致
    {
        var w = try serde.Writer.init(gpa, magic, format_version);
        defer w.deinit();
        try w.addChunk(TAG_HEAD, "pixie");
        const entr = [_]u8{ 10, 'c', 'l', 'e', 'a', 'r', 0, 0 };
        try w.addChunk(TAG_ENTR, &entr);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.CorruptEntry, decode(gpa, bytes));
    }

    // args_len と実 payload 長が不一致
    {
        var w = try serde.Writer.init(gpa, magic, format_version);
        defer w.deinit();
        try w.addChunk(TAG_HEAD, "pixie");
        const entr = [_]u8{ 5, 'c', 'l', 'e', 'a', 'r', 10, 0 };
        try w.addChunk(TAG_ENTR, &entr);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.CorruptEntry, decode(gpa, bytes));
    }
}

test "HEAD が先頭でない / 欠落 → MissingHeader" {
    const gpa = testing.allocator;

    // ENTR のみ（HEAD なし）
    {
        var w = try serde.Writer.init(gpa, magic, format_version);
        defer w.deinit();
        var entr: [1 + 5 + 2]u8 = undefined;
        entr[0] = 5;
        @memcpy(entr[1..6], "clear");
        std.mem.writeInt(u16, entr[6..8], 0, .little);
        try w.addChunk(TAG_ENTR, &entr);
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.MissingHeader, decode(gpa, bytes));
    }

    // ENTR → HEAD（順序違反）
    {
        var w = try serde.Writer.init(gpa, magic, format_version);
        defer w.deinit();
        var entr: [1 + 5 + 2]u8 = undefined;
        entr[0] = 5;
        @memcpy(entr[1..6], "clear");
        std.mem.writeInt(u16, entr[6..8], 0, .little);
        try w.addChunk(TAG_ENTR, &entr);
        try w.addChunk(TAG_HEAD, "pixie");
        const bytes = try w.finish();
        defer gpa.free(bytes);
        try testing.expectError(error.MissingHeader, decode(gpa, bytes));
    }
}

test "バイト数超過 → RecipeTooLarge（decode / load）" {
    const gpa = testing.allocator;

    // decode: 総バイト数が上限超（serde より先に拒否）
    {
        const big = try gpa.alloc(u8, MAX_RECIPE_BYTES + 1);
        defer gpa.free(big);
        @memset(big, 0);
        try testing.expectError(error.RecipeTooLarge, decode(gpa, big));
    }

    // load: ファイルが上限超
    {
        const io = std.testing.io;
        const path = ".task6258_recipe_too_large.recipe";
        defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
        const big = try gpa.alloc(u8, MAX_RECIPE_BYTES + 1);
        defer gpa.free(big);
        @memset(big, 0xab);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = big });
        try testing.expectError(error.RecipeTooLarge, load(io, gpa, path));
    }
}

test "エントリ数超過 → TooManyEntries" {
    const gpa = testing.allocator;
    var w = try serde.Writer.init(gpa, magic, format_version);
    defer w.deinit();
    try w.addChunk(TAG_HEAD, "pixie");
    // 最小 ENTR: name_len=1, name='a', args_len=0
    const entr = [_]u8{ 1, 'a', 0, 0 };
    var i: usize = 0;
    while (i < MAX_ENTRIES + 1) : (i += 1) {
        try w.addChunk(TAG_ENTR, &entr);
    }
    const bytes = try w.finish();
    defer gpa.free(bytes);
    try testing.expect(bytes.len <= MAX_RECIPE_BYTES); // 細切れでもファイル自体は上限内
    try testing.expectError(error.TooManyEntries, decode(gpa, bytes));
}
