//! レイヤー名インライン編集の入力状態機械（TASK-79.3）。
//!
//! platform / GUI / paint 非依存の純ロジック。canvas_input.zig / eyedropper_input.zig と同型の
//! 「入力状態機械を独立ファイルに分離し test-core から display 無しで単体テストする」慣習に従う。
//! main.zig の `App` は本構造体を1つ持ち、右クリックメニュー「Rename...」で `begin`、
//! `char_input` イベントで `appendCodepoint`、BACKSPACE で `backspace`、ENTER で `commit`、
//! ESCAPE で `cancel` を呼ぶ（実際の Canvas への反映・Undo push は呼び出し側=main.zig の責務。
//! ここは「編集中バッファをどう更新するか」にのみ責務を持つ）。
//!
//! `max_len` は `libs/paint/src/canvas.zig` の `layer_name_max` と同じ値（32）に揃える契約。
//! 循環 import を避けるため独立定義とし、main.zig 側で `comptime` の一致 assert を置く。
//!
//! ホットパス宣言: イベント時のみ（rename 開始/文字入力/確定/取消の都度1回）。
//! フレーム毎の全画素ループ・RT 経路のいずれでもないため、性能規約（SIMD 3点セット等）は対象外。

const std = @import("std");

/// `libs/paint/src/canvas.zig` の `layer_name_max` と同じ値（main.zig の comptime assert で保証）。
pub const max_len: usize = 32;

pub const LayerRenameInput = struct {
    active: bool = false,
    layer_idx: usize = 0,
    buf: [max_len]u8 = undefined,
    len: u8 = 0,

    /// 指定レイヤーの現在名をバッファへコピーして編集を開始する。
    /// `current_name` が `max_len` を超えていても安全に切り詰める（UTF-8 継続バイトの途中で
    /// 切らない。Layer.setName と同じ防御）。
    pub fn begin(self: *LayerRenameInput, layer_idx: usize, current_name: []const u8) void {
        self.active = true;
        self.layer_idx = layer_idx;
        const n = safeUtf8TruncateLen(current_name, max_len);
        @memcpy(self.buf[0..n], current_name[0..n]);
        self.len = @intCast(n);
    }

    /// 確定文字を1つ追記する（`char_input` の codepoint。TASK-22）。非 active 中は no-op。
    /// ASCII 制御文字（0x00-0x1F, 0x7F）は無視する（digest/probe の 1 行契約を壊す改行等の
    /// 混入を防ぐ wire framing 保護。文字の意味解釈ではない）。容量超過も無視する
    /// （fail-safe。呼び出し側にエラーを伝播させない＝タイプの取りこぼしがあるだけでクラッシュしない）。
    pub fn appendCodepoint(self: *LayerRenameInput, codepoint: u32) void {
        if (!self.active) return;
        if (codepoint < 0x20 or codepoint == 0x7F) return;
        if (codepoint > std.math.maxInt(u21)) return;
        var enc: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(codepoint), &enc) catch return; // 不正/サロゲート等は無視
        if (@as(usize, self.len) + n > max_len) return;
        @memcpy(self.buf[self.len..][0..n], enc[0..n]);
        self.len += @intCast(n);
    }

    /// 直前の1コードポイントを削除する（BACKSPACE）。UTF-8 継続バイトを遡って安全に削る。
    pub fn backspace(self: *LayerRenameInput) void {
        if (!self.active or self.len == 0) return;
        var n: u8 = self.len - 1;
        while (n > 0 and (self.buf[n] & 0xC0) == 0x80) : (n -= 1) {}
        self.len = n;
    }

    /// 現在の編集中バッファ（未確定）。
    pub fn text(self: *const LayerRenameInput) []const u8 {
        return self.buf[0..self.len];
    }

    /// 編集を確定し、確定文字列を返す（呼び出し側が Canvas へ反映し Undo へ積む）。
    pub fn commit(self: *LayerRenameInput) []const u8 {
        self.active = false;
        return self.text();
    }

    /// 編集を取り消す（Undo には積まない）。
    pub fn cancel(self: *LayerRenameInput) void {
        self.active = false;
    }
};

/// text を最大 max バイトへ、UTF-8 継続バイト（0b10xxxxxx）の途中で切らないように
/// 切り詰めた長さを返す（`libs/paint/src/canvas.zig` の `safeUtf8TruncateLen` と同型）。
fn safeUtf8TruncateLen(text: []const u8, max: usize) usize {
    var n = @min(text.len, max);
    while (n > 0 and n < text.len and (text[n] & 0xC0) == 0x80) : (n -= 1) {}
    return n;
}

// ============================ tests ============================

const testing = std.testing;

test "begin: 現在名をコピーして active になる" {
    var r: LayerRenameInput = .{};
    r.begin(3, "Background");
    try testing.expect(r.active);
    try testing.expectEqual(@as(usize, 3), r.layer_idx);
    try testing.expectEqualStrings("Background", r.text());
}

test "appendCodepoint: ASCII を1文字ずつ追記できる" {
    var r: LayerRenameInput = .{};
    r.begin(0, "");
    r.appendCodepoint('S');
    r.appendCodepoint('k');
    r.appendCodepoint('y');
    try testing.expectEqualStrings("Sky", r.text());
}

test "appendCodepoint: マルチバイト文字（日本語）を追記できる（char_input 経由の想定経路）" {
    var r: LayerRenameInput = .{};
    r.begin(0, "");
    // 'あ' = U+3042
    r.appendCodepoint(0x3042);
    r.appendCodepoint('日');
    try testing.expectEqualStrings("あ日", r.text());
}

test "appendCodepoint: 非 active 中は無視される" {
    var r: LayerRenameInput = .{};
    r.appendCodepoint('X');
    try testing.expectEqual(@as(u8, 0), r.len);
}

test "appendCodepoint: ASCII 制御文字は無視される（digest 1行契約を壊さない）" {
    var r: LayerRenameInput = .{};
    r.begin(0, "");
    r.appendCodepoint('A');
    r.appendCodepoint('\n');
    r.appendCodepoint(0x7F); // DEL
    r.appendCodepoint('B');
    try testing.expectEqualStrings("AB", r.text());
}

test "appendCodepoint: 容量超過は無視される（クラッシュしない）" {
    var r: LayerRenameInput = .{};
    r.begin(0, "");
    var i: usize = 0;
    while (i < max_len) : (i += 1) r.appendCodepoint('A');
    try testing.expectEqual(@as(u8, @intCast(max_len)), r.len);
    r.appendCodepoint('B'); // 満杯 → 無視
    try testing.expectEqual(@as(u8, @intCast(max_len)), r.len);
    try testing.expect(std.mem.allEqual(u8, r.text(), 'A'));

    // マルチバイト文字がギリギリ入らない場合も部分書き込みせず丸ごと無視する
    var r2: LayerRenameInput = .{};
    r2.begin(0, "");
    i = 0;
    while (i < max_len - 1) : (i += 1) r2.appendCodepoint('A'); // 残り1バイト
    r2.appendCodepoint(0x3042); // 'あ' は3バイト必要 → 丸ごと拒否
    try testing.expectEqual(@as(u8, @intCast(max_len - 1)), r2.len);
    try testing.expect(std.unicode.utf8ValidateSlice(r2.text()));
}

test "backspace: 1コードポイント分だけ削除する（マルチバイトも壊さない）" {
    var r: LayerRenameInput = .{};
    r.begin(0, "");
    r.appendCodepoint('A');
    r.appendCodepoint(0x3042); // 'あ'
    try testing.expectEqualStrings("Aあ", r.text());
    r.backspace();
    try testing.expectEqualStrings("A", r.text());
    try testing.expect(std.unicode.utf8ValidateSlice(r.text()));
    r.backspace();
    try testing.expectEqualStrings("", r.text());
    r.backspace(); // 空でも no-op（クラッシュしない）
    try testing.expectEqualStrings("", r.text());
}

test "backspace: 非 active 中は無視される" {
    var r: LayerRenameInput = .{};
    r.backspace();
    try testing.expectEqual(@as(u8, 0), r.len);
}

test "commit: active を false にして確定文字列を返す" {
    var r: LayerRenameInput = .{};
    r.begin(1, "Old");
    r.backspace(); // "Old" → "Ol"
    r.appendCodepoint('t'); // "Ol" → "Olt"
    const committed = r.commit();
    try testing.expectEqualStrings("Olt", committed);
    try testing.expect(!r.active);
}

test "cancel: active を false にするだけ（バッファは触らない）" {
    var r: LayerRenameInput = .{};
    r.begin(0, "X");
    r.appendCodepoint('Y');
    r.cancel();
    try testing.expect(!r.active);
    try testing.expectEqualStrings("XY", r.text()); // 呼び出し側が参照しない限り無害
}

test "begin: max_len を超える現在名は UTF-8 境界を壊さず切り詰める" {
    var r: LayerRenameInput = .{};
    const long_name = "あ" ** 11; // 33 バイト（32 に収まるのは 10 個=30B まで）
    r.begin(0, long_name);
    try testing.expect(r.len <= max_len);
    try testing.expect(std.unicode.utf8ValidateSlice(r.text()));
    try testing.expectEqualStrings("あ" ** 10, r.text());
}
