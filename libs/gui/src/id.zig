// widget ID 管理。immediate-mode GUI では widget を ID で同定する。
//
// hash は FNV-1a 64bit（依存ゼロ・十分高速・衝突は実用上問題なし）。
// 親 ID を seed として継続 hash することで、同じラベルでも ID stack の
// 親が違えば異なる Id になる（ネスト widget の同名衝突を防ぐ）。

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Id = u64;

const fnv_offset: u64 = 0xcbf29ce484222325;
const fnv_prime: u64 = 0x100000001b3;

/// FNV-1a 64bit。seed を初期値に取り、bytes を順に畳み込む。
/// seed に親 ID を渡すことで階層的な ID 合成ができる。
pub fn fnv1a(seed: u64, bytes: []const u8) u64 {
    var h = seed;
    for (bytes) |b| {
        h ^= b;
        h *%= fnv_prime;
    }
    return h;
}

// 親 seed を単純に継続 hash するだけだと、FNV が streaming のため
// `make("abc")` と `push("ab"); make("c")` が同値になり、また文字列 "A" と
// 整数 0x41 も衝突しうる。型タグ + 長さを混ぜて階層境界・型境界を保つ。
const tag_string: u8 = 's';
const tag_int: u8 = 'i';

fn hashStr(seed: u64, label: []const u8) Id {
    var h = fnv1a(seed, &[_]u8{tag_string});
    const len: u64 = label.len;
    h = fnv1a(h, std.mem.asBytes(&len));
    return fnv1a(h, label);
}

/// 整数から子 ID を合成する（layout の自動採番でも使用）。
pub fn hashInt(seed: u64, v: u64) Id {
    const h = fnv1a(seed, &[_]u8{tag_int});
    return fnv1a(h, std.mem.asBytes(&v));
}

/// long-lived。各フレーム冒頭で clear する。ArrayList は gpa 保持（unmanaged）。
pub const IdStack = struct {
    alloc: Allocator,
    stack: std.ArrayList(Id) = .empty,

    pub fn init(alloc: Allocator) IdStack {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *IdStack) void {
        self.stack.deinit(self.alloc);
    }

    /// フレーム冒頭で呼ぶ（容量は保持）。
    pub fn clear(self: *IdStack) void {
        self.stack.clearRetainingCapacity();
    }

    /// 現在の親 seed。空（ルート）なら FNV offset basis。
    fn currentSeed(self: *const IdStack) u64 {
        return if (self.stack.items.len > 0)
            self.stack.items[self.stack.items.len - 1]
        else
            fnv_offset;
    }

    /// seed（ラベル文字列 or 整数）から子スコープ ID を作り stack に積む。
    /// ネスト widget のスコープ境界に使う。
    pub fn push(self: *IdStack, seed: anytype) void {
        self.stack.append(self.alloc, self.makeRaw(seed)) catch @panic("IdStack.push: OOM");
    }

    pub fn pop(self: *IdStack) void {
        _ = self.stack.pop();
    }

    /// ラベルから widget ID を作る（stack には積まない）。
    /// 親 seed を継続初期値にするので、親が違えば同名でも別 Id。
    pub fn make(self: *const IdStack, label: []const u8) Id {
        return hashStr(self.currentSeed(), label);
    }

    /// 整数値から widget ID を作る（stack には積まない）。
    /// ColorSwatch の色値などラベル文字列を持たない widget の自動 ID 用。
    pub fn makeInt(self: *const IdStack, v: u64) Id {
        return hashInt(self.currentSeed(), v);
    }

    /// 整数・文字列の両方を seed に取れる内部ヘルパ（push 用）。
    /// 整数でも文字列でもない型は coerce で compile error になる（型安全）。
    fn makeRaw(self: *const IdStack, seed: anytype) Id {
        const parent = self.currentSeed();
        switch (@typeInfo(@TypeOf(seed))) {
            .int, .comptime_int => return hashInt(parent, @intCast(seed)),
            else => return hashStr(parent, @as([]const u8, seed)),
        }
    }
};

// ============================================================
// Tests
// ============================================================

test "IdStack: 同ラベル + 異なる親 stack で別 Id（衝突境界）" {
    var s = IdStack.init(std.testing.allocator);
    defer s.deinit();

    s.push("panelA");
    const a = s.make("button");
    s.pop();

    s.push("panelB");
    const b = s.make("button");
    s.pop();

    try std.testing.expect(a != b);
}

test "IdStack: 同ラベル + 同じ親 stack で同一 Id" {
    var s = IdStack.init(std.testing.allocator);
    defer s.deinit();

    s.push("panel");
    defer s.pop();
    const a = s.make("button");
    const b = s.make("button");
    try std.testing.expectEqual(a, b);
}

test "IdStack: ルート（親なし）でラベルから安定 Id・別ラベルは別 Id" {
    var s = IdStack.init(std.testing.allocator);
    defer s.deinit();

    const a = s.make("save");
    const b = s.make("save");
    const c = s.make("load");
    try std.testing.expectEqual(a, b);
    try std.testing.expect(a != c);
}

test "IdStack: 整数 seed で push できる（明示スコープ）" {
    var s = IdStack.init(std.testing.allocator);
    defer s.deinit();

    s.push(@as(u32, 1));
    const a = s.make("item");
    s.pop();

    s.push(@as(u32, 2));
    const b = s.make("item");
    s.pop();

    try std.testing.expect(a != b);
}

test "IdStack: clear で空になる" {
    var s = IdStack.init(std.testing.allocator);
    defer s.deinit();

    s.push("a");
    s.push("b");
    s.clear();
    try std.testing.expectEqual(@as(usize, 0), s.stack.items.len);
}

test "IdStack: 階層境界が保たれる（'ab'+'c' と 'abc' は別 Id）" {
    var s1 = IdStack.init(std.testing.allocator);
    defer s1.deinit();
    const concat = s1.make("abc");

    var s2 = IdStack.init(std.testing.allocator);
    defer s2.deinit();
    s2.push("ab");
    const split = s2.make("c");

    try std.testing.expect(concat != split);
}

test "IdStack: makeInt は同値で安定・異値/異スコープで別 Id" {
    var s = IdStack.init(std.testing.allocator);
    defer s.deinit();

    const a = s.makeInt(0xFF332211);
    const b = s.makeInt(0xFF332211);
    const c = s.makeInt(0xFF332212);
    try std.testing.expectEqual(a, b);
    try std.testing.expect(a != c);

    s.push(@as(u32, 1));
    const scoped = s.makeInt(0xFF332211);
    s.pop();
    try std.testing.expect(a != scoped);
}

test "IdStack: 文字列 seed と整数 seed は別 Id" {
    var s1 = IdStack.init(std.testing.allocator);
    defer s1.deinit();
    s1.push("A"); // 0x41 = 'A'
    const by_str = s1.make("x");

    var s2 = IdStack.init(std.testing.allocator);
    defer s2.deinit();
    s2.push(@as(u8, 0x41));
    const by_int = s2.make("x");

    try std.testing.expect(by_str != by_int);
}
