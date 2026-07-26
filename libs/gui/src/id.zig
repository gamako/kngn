// Widget ID management. Immediate-mode GUI identifies widgets by ID.
//
// Hash is FNV-1a 64-bit (zero deps, fast enough; collisions are not a practical issue).
// Continuing the hash with the parent ID as seed means the same label yields a different Id
// when the ID stack parent differs (avoids same-name collisions for nested widgets).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Id = u64;

const fnv_offset: u64 = 0xcbf29ce484222325;
const fnv_prime: u64 = 0x100000001b3;

/// FNV-1a 64-bit. Takes `seed` as the initial value and folds `bytes` in order.
/// Pass the parent ID as seed to compose hierarchical IDs.
pub fn fnv1a(seed: u64, bytes: []const u8) u64 {
    var h = seed;
    for (bytes) |b| {
        h ^= b;
        h *%= fnv_prime;
    }
    return h;
}

// Simply continuing the parent seed is not enough: because FNV is streaming,
// `make("abc")` equals `push("ab"); make("c")`, and string "A" can also collide with
// integer 0x41. Mix a type tag + length to keep hierarchy and type boundaries.
const tag_string: u8 = 's';
const tag_int: u8 = 'i';

fn hashStr(seed: u64, label: []const u8) Id {
    var h = fnv1a(seed, &[_]u8{tag_string});
    const len: u64 = label.len;
    h = fnv1a(h, std.mem.asBytes(&len));
    return fnv1a(h, label);
}

/// Compose a child ID from an integer (also used for layout auto-numbering).
pub fn hashInt(seed: u64, v: u64) Id {
    const h = fnv1a(seed, &[_]u8{tag_int});
    return fnv1a(h, std.mem.asBytes(&v));
}

/// Long-lived. Clear at the start of each frame. ArrayList keeps gpa (unmanaged).
pub const IdStack = struct {
    alloc: Allocator,
    stack: std.ArrayList(Id) = .empty,

    pub fn init(alloc: Allocator) IdStack {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *IdStack) void {
        self.stack.deinit(self.alloc);
    }

    /// Call at frame start (capacity retained).
    pub fn clear(self: *IdStack) void {
        self.stack.clearRetainingCapacity();
    }

    /// Current parent seed. Empty (root) → FNV offset basis.
    fn currentSeed(self: *const IdStack) u64 {
        return if (self.stack.items.len > 0)
            self.stack.items[self.stack.items.len - 1]
        else
            fnv_offset;
    }

    /// Build a child-scope ID from a seed (label string or integer) and push it on the stack.
    /// Use at nest-widget scope boundaries.
    pub fn push(self: *IdStack, seed: anytype) void {
        self.stack.append(self.alloc, self.makeRaw(seed)) catch @panic("IdStack.push: OOM");
    }

    pub fn pop(self: *IdStack) void {
        _ = self.stack.pop();
    }

    /// Build a widget ID from a label (does not push on the stack).
    /// Continues from the parent seed, so the same name under a different parent is a different Id.
    pub fn make(self: *const IdStack, label: []const u8) Id {
        return hashStr(self.currentSeed(), label);
    }

    /// Build a widget ID from an integer (does not push on the stack).
    /// For auto-IDs of widgets with no label string (e.g. ColorSwatch color value).
    pub fn makeInt(self: *const IdStack, v: u64) Id {
        return hashInt(self.currentSeed(), v);
    }

    /// Internal helper for push that accepts either an integer or a string seed.
    /// Non-integer/non-string types become a compile error via coerce (type-safe).
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

test "IdStack: same label + different parent stack → different Id (collision boundary)" {
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

test "IdStack: same label + same parent stack → same Id" {
    var s = IdStack.init(std.testing.allocator);
    defer s.deinit();

    s.push("panel");
    defer s.pop();
    const a = s.make("button");
    const b = s.make("button");
    try std.testing.expectEqual(a, b);
}

test "IdStack: at root (no parent), label yields a stable Id; different labels differ" {
    var s = IdStack.init(std.testing.allocator);
    defer s.deinit();

    const a = s.make("save");
    const b = s.make("save");
    const c = s.make("load");
    try std.testing.expectEqual(a, b);
    try std.testing.expect(a != c);
}

test "IdStack: can push with an integer seed (explicit scope)" {
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

test "IdStack: clear empties the stack" {
    var s = IdStack.init(std.testing.allocator);
    defer s.deinit();

    s.push("a");
    s.push("b");
    s.clear();
    try std.testing.expectEqual(@as(usize, 0), s.stack.items.len);
}

test "IdStack: hierarchy boundary held ('ab'+'c' differs from 'abc')" {
    var s1 = IdStack.init(std.testing.allocator);
    defer s1.deinit();
    const concat = s1.make("abc");

    var s2 = IdStack.init(std.testing.allocator);
    defer s2.deinit();
    s2.push("ab");
    const split = s2.make("c");

    try std.testing.expect(concat != split);
}

test "IdStack: makeInt is stable for equal values; differs across value/scope" {
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

test "IdStack: string seed and integer seed yield different Ids" {
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
