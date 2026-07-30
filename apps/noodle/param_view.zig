//! Inspector's parameter projection and edit state (the Transport-only projection has been removed).
//!
//! Hot-path declaration: the enumeration/comparison handled here runs at the GUI's frame-rate; override purge and
//! pending updates run at event/frame-rate. No new all-pixel loop or RT loop is introduced.

const std = @import("std");
const modular = @import("modular");

pub const INVALID_HANDLE: usize = std.math.maxInt(usize);
pub const PENDING_RELEASE_FRAMES: u8 = 30;
pub const PENDING_REL_EPSILON: f32 = 0.01;
pub const PENDING_ABS_EPSILON: f32 = 0.001;

pub const FieldKey = struct {
    handle: usize = INVALID_HANDLE,
    name: []const u8 = "",

    pub fn invalid(self: FieldKey) bool {
        return self.handle == INVALID_HANDLE or self.name.len == 0;
    }
};

pub fn fieldKey(handle: usize, name: []const u8) FieldKey {
    return .{ .handle = handle, .name = name };
}

pub fn sameField(a: FieldKey, b: FieldKey) bool {
    return a.handle == b.handle and std.mem.eql(u8, a.name, b.name);
}

pub fn sameFieldParts(key: FieldKey, handle: usize, name: []const u8) bool {
    return key.handle == handle and std.mem.eql(u8, key.name, name);
}

/// Normalizes a temporary slice from action/replay to the descriptor table's static name.
/// The return value doesn't retain the input slice; it returns the descriptor's own name slice.
pub fn canonicalDescriptorName(descs: []const modular.ParamDesc, name: []const u8) ?[]const u8 {
    for (descs) |desc| {
        if (std.mem.eql(u8, desc.name, name)) return desc.name;
    }
    return null;
}

/// Picks the "primary parameter" descriptor per kind (cutoff preferred, otherwise the first).
/// Shared by main.zig's observedFieldForNode (Inspector follow) and drawNodeParamValues (in-node value display).
pub fn primaryDescriptor(descs: []const modular.ParamDesc) ?modular.ParamDesc {
    if (descs.len == 0) return null;
    const name = canonicalDescriptorName(descs, "cutoff") orelse descs[0].name;
    for (descs) |desc| {
        if (std.mem.eql(u8, desc.name, name)) return desc;
    }
    return descs[0];
}

/// Compatibility conversion between SPRM `cutoff_norm` and Master VCF Hz (for the load_pattern / offline one-shot bridge).
pub const CutoffRange = struct {
    min: f32,
    max: f32,
};

pub fn cutoffHz(norm: f32, range: CutoffRange) f32 {
    const n = std.math.clamp(norm, 0.0, 1.0);
    return range.min * std.math.pow(f32, range.max / range.min, n);
}

pub fn cutoffNorm(hz: f32, range: CutoffRange) f32 {
    const value = std.math.clamp(hz, range.min, range.max);
    return std.math.log(f32, range.max / range.min, value / range.min);
}

pub const ParamSnapshot = struct {
    field: modular.ParamValue,
    instant: ?modular.ParamValue = null,
    has_instant: bool = false,
};

pub const ParamEditState = struct {
    key: FieldKey = .{},
    pending: ?modular.ParamValue = null,
    dragging: bool = false,
    released_frames: u8 = 0,

    pub fn begin(self: *ParamEditState, key: FieldKey, value: modular.ParamValue) void {
        self.key = key;
        self.pending = value;
        self.dragging = true;
        self.released_frames = 0;
    }

    pub fn release(self: *ParamEditState) void {
        if (self.pending != null) self.dragging = false;
    }

    pub fn shown(self: *const ParamEditState, snapshot: ParamSnapshot) modular.ParamValue {
        if (self.pending) |value| return value;
        return snapshot.field;
    }

    pub fn advance(self: *ParamEditState, snapshot: ParamSnapshot) void {
        if (self.pending == null or self.dragging) return;
        const pending = self.pending.?;
        const matched = switch (pending) {
            .scalar => |wanted| switch (snapshot.field) {
                .scalar => |actual| approxEqual(actual, wanted),
                .choice => false,
            },
            .choice => |wanted| switch (snapshot.field) {
                .choice => |actual| actual == wanted,
                .scalar => false,
            },
        };
        if (matched) {
            self.pending = null;
            self.key = .{};
            self.released_frames = 0;
        } else {
            self.released_frames += 1;
            if (self.released_frames >= PENDING_RELEASE_FRAMES) {
                self.pending = null;
                self.key = .{};
                self.released_frames = 0;
            }
        }
    }
};

pub fn approxEqual(actual: f32, wanted: f32) bool {
    if (!std.math.isFinite(actual) or !std.math.isFinite(wanted)) return false;
    const tolerance = @max(PENDING_ABS_EPSILON, @abs(wanted) * PENDING_REL_EPSILON);
    return @abs(actual - wanted) <= tolerance;
}

pub fn displayValue(snapshot: ParamSnapshot, state: ?*const ParamEditState, key: FieldKey) modular.ParamValue {
    if (state) |edit| {
        if (sameField(edit.key, key)) return edit.shown(snapshot);
    }
    return snapshot.field;
}

pub fn ghostFraction(snapshot: ParamSnapshot, min: f32, max: f32) ?f32 {
    if (!snapshot.has_instant or snapshot.instant == null or max <= min) return null;
    const field = switch (snapshot.field) {
        .scalar => |v| v,
        .choice => return null,
    };
    const instant = switch (snapshot.instant.?) {
        .scalar => |v| v,
        .choice => return null,
    };
    if (!std.math.isFinite(field) or !std.math.isFinite(instant)) return null;
    if (approxEqual(field, instant)) return null;
    return std.math.clamp((instant - min) / (max - min), 0.0, 1.0);
}

pub const OverrideSlot = struct {
    key: FieldKey = .{},
    touched: bool = false,
};

pub fn purgeOverrideSlots(slots: []OverrideSlot, target: FieldKey) usize {
    var purged: usize = 0;
    for (slots) |*slot| {
        if (slot.touched and sameField(slot.key, target)) {
            slot.* = .{};
            purged += 1;
        }
    }
    return purged;
}

test "fieldKey equality helpers" {
    try std.testing.expect(sameField(fieldKey(1, "bpm"), fieldKey(1, "bpm")));
    try std.testing.expect(!sameField(fieldKey(1, "bpm"), fieldKey(2, "bpm")));
    try std.testing.expect(sameFieldParts(fieldKey(3, "cutoff"), 3, "cutoff"));
    try std.testing.expect(!sameFieldParts(fieldKey(3, "cutoff"), 3, "resonance"));
}

test "descriptor name normalization retains static descriptor slice" {
    const descs = modular.descriptors(.chord_pad);
    const normalized = canonicalDescriptorName(descs, "cutoff") orelse return error.TestUnexpectedResult;
    var expected: ?[]const u8 = null;
    for (descs) |desc| {
        if (std.mem.eql(u8, desc.name, "cutoff")) {
            expected = desc.name;
            break;
        }
    }
    const descriptor_name = expected orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@intFromPtr(descriptor_name.ptr), @intFromPtr(normalized.ptr));
    try std.testing.expectEqual(descriptor_name.len, normalized.len);
    try std.testing.expect(canonicalDescriptorName(descs, "not_a_param") == null);
}

test "cutoff norm round trip" {
    const range: CutoffRange = .{ .min = 80.0, .max = 18000.0 };
    for ([_]f32{ 0.0, 0.25, 0.5, 1.0 }) |norm| {
        try std.testing.expectApproxEqAbs(norm, cutoffNorm(cutoffHz(norm, range), range), 1e-5);
    }
}

test "pending edit wins, then releases on epsilon or fixed frame deadline" {
    const key = fieldKey(2, "cutoff");
    var state: ParamEditState = .{};
    state.begin(key, .{ .scalar = 600.0 });
    const far: ParamSnapshot = .{ .field = .{ .scalar = 1000.0 } };
    try std.testing.expectEqual(@as(f32, 600.0), state.shown(far).scalar);
    state.release();
    state.advance(.{ .field = .{ .scalar = 604.0 } });
    try std.testing.expect(state.pending == null);

    state.begin(key, .{ .scalar = 600.0 });
    state.release();
    var i: u8 = 0;
    while (i < PENDING_RELEASE_FRAMES) : (i += 1) state.advance(far);
    try std.testing.expect(state.pending == null);
}

test "ghost fraction clamps and ignores non-finite or unmodulated values" {
    const snap: ParamSnapshot = .{ .field = .{ .scalar = 100.0 }, .instant = .{ .scalar = 200.0 }, .has_instant = true };
    try std.testing.expectEqual(@as(f32, 1.0), ghostFraction(snap, 0.0, 150.0).?);
    try std.testing.expect(ghostFraction(.{ .field = .{ .scalar = 100.0 } }, 0.0, 200.0) == null);
    try std.testing.expect(ghostFraction(.{ .field = .{ .scalar = std.math.nan(f32) }, .instant = .{ .scalar = 1.0 }, .has_instant = true }, 0.0, 2.0) == null);
}

test "purge removes only the matching override field" {
    var slots = [_]OverrideSlot{
        .{ .key = fieldKey(1, "cutoff"), .touched = true },
        .{ .key = fieldKey(1, "resonance"), .touched = true },
        .{ .key = fieldKey(2, "cutoff"), .touched = true },
    };
    try std.testing.expectEqual(@as(usize, 1), purgeOverrideSlots(&slots, fieldKey(1, "cutoff")));
    try std.testing.expect(!slots[0].touched);
    try std.testing.expect(slots[1].touched);
    try std.testing.expect(slots[2].touched);
}
