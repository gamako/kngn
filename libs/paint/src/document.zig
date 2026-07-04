//! Document — frames × layers のドキュメントモデル（TASK-63）。
//!
//! pixie 等のエディタが保持する「プロジェクト」の in-memory 表現。今フェーズ（MVP）は
//! **1 frame / raster レイヤーのみ**だが、`frames` 配列を持つことで TASK-45（アニメ）へ
//! フォーマット/モデル互換のまま拡張できる器にする。
//!
//! frames は **`*Canvas`（heap 確保・ポインタ安定）** で保持する。App が
//! `canvas: *Canvas = doc.activeCanvas()` を持って参照する設計のため、frame 追加/削除で
//! 既存 Canvas のアドレスがずれないようにする（ArrayList(Canvas) の再確保でムーブしない）。
//!
//! ホットパス宣言: 生成/破棄は初期化時・イベント時のみ（フレーム毎ループ・RT では走らない）。

const std = @import("std");
const canvas_mod = @import("canvas.zig");
const Canvas = canvas_mod.Canvas;

pub const Document = struct {
    width: u32,
    height: u32,
    frames: std.ArrayList(*Canvas),
    selected_frame: u32 = 0,
    allocator: std.mem.Allocator,

    /// 1 frame（blank layer 1 枚）の Document を作る。App 起動時の初期状態。
    pub fn init(gpa: std.mem.Allocator, w: u32, h: u32) !Document {
        var doc = initEmpty(gpa, w, h);
        errdefer doc.deinit();
        const c = try gpa.create(Canvas);
        c.* = Canvas.init(gpa, w, h) catch |e| {
            gpa.destroy(c);
            return e;
        };
        doc.frames.append(gpa, c) catch |e| {
            c.deinit();
            gpa.destroy(c);
            return e;
        };
        return doc;
    }

    /// frame を 1 つも持たない Document（loader が appendFrame で組み立てる土台）。
    pub fn initEmpty(gpa: std.mem.Allocator, w: u32, h: u32) Document {
        return .{ .width = w, .height = h, .frames = .empty, .allocator = gpa };
    }

    pub fn deinit(self: *Document) void {
        for (self.frames.items) |c| {
            c.deinit();
            self.allocator.destroy(c);
        }
        self.frames.deinit(self.allocator);
    }

    /// heap 確保済みの Canvas を frame として末尾に追加する（所有権は Document へ移る）。
    /// loader 用。呼び出し側は成功後 c を free/destroy しないこと（deinit がまとめて解放する）。
    pub fn appendFrame(self: *Document, c: *Canvas) !void {
        try self.frames.append(self.allocator, c);
    }

    /// 現在アクティブなフレームの Canvas（MVP は常に frame 0）。
    pub fn activeCanvas(self: *Document) *Canvas {
        return self.frames.items[self.selected_frame];
    }

    pub fn frameCount(self: *const Document) usize {
        return self.frames.items.len;
    }
};

// ============================ tests ============================

test "Document.init: 1 frame / 1 blank layer で始まる" {
    var doc = try Document.init(std.testing.allocator, 8, 8);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 1), doc.frameCount());
    try std.testing.expectEqual(@as(u32, 8), doc.width);
    const c = doc.activeCanvas();
    try std.testing.expectEqual(@as(usize, 1), c.layers.items.len);
    try std.testing.expectEqual(@as(u32, 8), c.width);
}

test "Document.initEmpty + appendFrame: 所有権が Document へ移り deinit で解放される（リークは testing.allocator が検出）" {
    const gpa = std.testing.allocator;
    var doc = Document.initEmpty(gpa, 4, 4);
    defer doc.deinit();
    const c = try gpa.create(Canvas);
    c.* = try Canvas.init(gpa, 4, 4);
    try doc.appendFrame(c);
    try std.testing.expectEqual(@as(usize, 1), doc.frameCount());
    try std.testing.expectEqual(c, doc.activeCanvas());
}
