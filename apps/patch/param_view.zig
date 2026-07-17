//! Transport/inspector の parameter projection と編集状態。
//!
//! ホットパス宣言: ここで扱う列挙・比較は GUI の frame-rate、override purge と
//! pending 更新は event/frame-rate で走る。全画素 loop / RT loop は新設しない。

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

/// Action/replay 由来の一時 slice を descriptor 表の static name へ正規化する。
/// 戻り値は入力 slice を保持せず、descriptor 自身の name slice を返す。
pub fn canonicalDescriptorName(descs: []const modular.ParamDesc, name: []const u8) ?[]const u8 {
    for (descs) |desc| {
        if (std.mem.eql(u8, desc.name, name)) return desc.name;
    }
    return null;
}

pub const TransportAlias = enum {
    tempo,
    cutoff,
    density,
    swing,
    sidechain,
    kick_gain,
    hat_gain,
    clap_gain,
    bass_gain,
    pad_gain,
};

pub const TransportHandles = struct {
    clock: usize,
    master_vcf: usize,
    sidechain: usize,
    kick: usize,
    hat: usize,
    clap: usize,
    bass_perc: usize,
    pad: usize,
};

pub const Conversion = struct {
    cutoff_min: f32,
    cutoff_max: f32,
    kick_base_gain: f32,
    hat_base_gain: f32,
    clap_base_gain: f32,
    pad_base_gain: f32,
};

pub fn keyFor(alias: TransportAlias, handles: TransportHandles) FieldKey {
    return switch (alias) {
        .tempo => fieldKey(handles.clock, "bpm"),
        .cutoff => fieldKey(handles.master_vcf, "cutoff"),
        .density => fieldKey(INVALID_HANDLE, "density_target"),
        .swing => fieldKey(handles.clock, "swing"),
        .sidechain => fieldKey(handles.sidechain, "amount"),
        .kick_gain => fieldKey(handles.kick, "gain"),
        .hat_gain => fieldKey(handles.hat, "gain"),
        .clap_gain => fieldKey(handles.clap, "gain"),
        .bass_gain => fieldKey(handles.bass_perc, "peak"),
        .pad_gain => fieldKey(handles.pad, "gain"),
    };
}

pub fn cutoffHz(norm: f32, conversion: Conversion) f32 {
    const n = std.math.clamp(norm, 0.0, 1.0);
    return conversion.cutoff_min * std.math.pow(f32, conversion.cutoff_max / conversion.cutoff_min, n);
}

pub fn cutoffNorm(hz: f32, conversion: Conversion) f32 {
    const value = std.math.clamp(hz, conversion.cutoff_min, conversion.cutoff_max);
    return std.math.log(f32, conversion.cutoff_max / conversion.cutoff_min, value / conversion.cutoff_min);
}

pub fn gainToModule(alias: TransportAlias, ui_gain: f32, conversion: Conversion) f32 {
    return switch (alias) {
        .kick_gain => conversion.kick_base_gain * ui_gain,
        .hat_gain => conversion.hat_base_gain * ui_gain,
        .clap_gain => conversion.clap_base_gain * ui_gain,
        .pad_gain => conversion.pad_base_gain * ui_gain,
        else => ui_gain,
    };
}

pub fn gainToUi(alias: TransportAlias, module_gain: f32, conversion: Conversion) f32 {
    return switch (alias) {
        .kick_gain => module_gain / conversion.kick_base_gain,
        .hat_gain => module_gain / conversion.hat_base_gain,
        .clap_gain => module_gain / conversion.clap_base_gain,
        .pad_gain => module_gain / conversion.pad_base_gain,
        else => module_gain,
    };
}

pub fn toCanonical(alias: TransportAlias, ui_value: f32, conversion: Conversion) f32 {
    return switch (alias) {
        .cutoff => cutoffHz(ui_value, conversion),
        .kick_gain, .hat_gain, .clap_gain, .pad_gain => gainToModule(alias, ui_value, conversion),
        else => ui_value,
    };
}

pub fn toUi(alias: TransportAlias, field_value: f32, conversion: Conversion) f32 {
    return switch (alias) {
        .cutoff => cutoffNorm(field_value, conversion),
        .kick_gain, .hat_gain, .clap_gain, .pad_gain => gainToUi(alias, field_value, conversion),
        else => field_value,
    };
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

test "transport aliases map to canonical fields" {
    const handles: TransportHandles = .{ .clock = 1, .master_vcf = 2, .sidechain = 3, .kick = 4, .hat = 5, .clap = 6, .bass_perc = 7, .pad = 8 };
    try std.testing.expect(sameField(keyFor(.tempo, handles), fieldKey(1, "bpm")));
    try std.testing.expect(sameField(keyFor(.cutoff, handles), fieldKey(2, "cutoff")));
    try std.testing.expect(sameField(keyFor(.bass_gain, handles), fieldKey(7, "peak")));
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

test "cutoff norm and gain conversions round trip" {
    const conversion: Conversion = .{ .cutoff_min = 80.0, .cutoff_max = 18000.0, .kick_base_gain = 0.8, .hat_base_gain = 0.28, .clap_base_gain = 0.42, .pad_base_gain = 0.22 };
    for ([_]f32{ 0.0, 0.25, 0.5, 1.0 }) |norm| {
        try std.testing.expectApproxEqAbs(norm, cutoffNorm(cutoffHz(norm, conversion), conversion), 1e-5);
    }
    try std.testing.expectApproxEqAbs(1.0, gainToUi(.kick_gain, gainToModule(.kick_gain, 1.0, conversion), conversion), 1e-6);
    try std.testing.expectApproxEqAbs(1.0, gainToUi(.pad_gain, gainToModule(.pad_gain, 1.0, conversion), conversion), 1e-6);
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
