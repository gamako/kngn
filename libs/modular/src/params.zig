//! UI 非依存の module parameter descriptor と live field binding。
//!
//! このファイルは control/event 側からだけ呼ばれる。descriptor は comptime で焼かれた
//! 静的データで、DynGraph の processBlock / per-sample 経路には入らない。

const std = @import("std");
const dsp = @import("dsp");
const dyn = @import("dyn.zig");
const modules = @import("modules.zig");
const signal = @import("signal.zig");

pub const ScalarDesc = struct {
    min: f32,
    max: f32,
    default: f32,
    unit: []const u8,
    step: f32,
};

pub const ChoiceDesc = struct {
    options: []const []const u8,
    default: usize,
};

pub const ParamKind = union(enum) {
    scalar: ScalarDesc,
    choice: ChoiceDesc,
};

pub const ParamDesc = struct {
    name: []const u8,
    kind: ParamKind,
};

pub const ParamValue = union(enum) {
    scalar: f32,
    choice: usize,
};

/// GUI が表示する parameter の best-effort snapshot。
/// `field` は descriptor の source field、`instant` は runtime modulation の直近値。
/// RT との同期は追加せず、既存 module field の read-only 値だけを返す。
pub const ParamSnapshot = struct {
    field: ParamValue,
    instant: ?ParamValue = null,
    has_instant: bool = false,
};

pub const Error = error{
    InvalidHandle,
    InactiveHandle,
    UnknownParam,
    WrongValueKind,
    OutOfRange,
    ChoiceIndexOutOfRange,
};

const Binding = struct {
    desc: ParamDesc,
    get: *const fn (*const anyopaque) ParamValue,
    set: *const fn (*anyopaque, ParamValue) Error!void,
    /// set と同一の受理判定（instance 不要）。set は必ずこれを呼んでから書く。
    validate: *const fn (ParamValue) Error!void,
};

fn scalarDesc(name: []const u8, min: f32, max: f32, default: f32, step: f32, unit: []const u8) ParamDesc {
    return .{ .name = name, .kind = .{ .scalar = .{
        .min = min,
        .max = max,
        .default = default,
        .step = step,
        .unit = unit,
    } } };
}

fn choiceDesc(name: []const u8, options: []const []const u8, default: usize) ParamDesc {
    return .{ .name = name, .kind = .{ .choice = .{ .options = options, .default = default } } };
}

fn numericRead(comptime F: type, value: F) f32 {
    return switch (@typeInfo(F)) {
        .float => @floatCast(value),
        .int => @floatFromInt(value),
        else => @compileError("parameter binding requires a float or integer field"),
    };
}

fn numericWrite(comptime F: type, value: f32) ?F {
    return switch (@typeInfo(F)) {
        .float => @floatCast(value),
        .int => blk: {
            if (!std.math.isFinite(value) or @trunc(value) != value) break :blk null;
            const min: f64 = @floatFromInt(std.math.minInt(F));
            const max: f64 = @floatFromInt(std.math.maxInt(F));
            const v: f64 = value;
            if (v < min or v > max) break :blk null;
            break :blk @intFromFloat(value);
        },
        else => @compileError("parameter binding requires a float or integer field"),
    };
}

fn scalarBinding(comptime T: type, comptime field_name: []const u8, comptime desc: ParamDesc) Binding {
    comptime if (!@hasField(T, field_name)) @compileError("parameter field does not exist: " ++ field_name);
    const F = @TypeOf(@field(T{}, field_name));
    comptime switch (desc.kind) {
        .scalar => {},
        .choice => @compileError("scalar binding requires a scalar descriptor"),
    };

    const limits = desc.kind.scalar;
    const Impl = struct {
        fn get(ctx: *const anyopaque) ParamValue {
            const self: *const T = @ptrCast(@alignCast(ctx));
            return .{ .scalar = numericRead(F, @field(self.*, field_name)) };
        }

        fn validate(value: ParamValue) Error!void {
            const raw = switch (value) {
                .scalar => |v| v,
                .choice => return Error.WrongValueKind,
            };
            if (!std.math.isFinite(raw) or raw < limits.min or raw > limits.max) return Error.OutOfRange;
            _ = numericWrite(F, raw) orelse return Error.OutOfRange;
        }

        fn set(ctx: *anyopaque, value: ParamValue) Error!void {
            try validate(value);
            const self: *T = @ptrCast(@alignCast(ctx));
            @field(self.*, field_name) = numericWrite(F, value.scalar).?;
        }
    };
    return .{ .desc = desc, .get = Impl.get, .set = Impl.set, .validate = Impl.validate };
}

fn nestedScalarBinding(comptime T: type, comptime outer: []const u8, comptime inner: []const u8, comptime desc: ParamDesc) Binding {
    comptime if (!@hasField(T, outer)) @compileError("parameter field does not exist: " ++ outer);
    const Outer = @TypeOf(@field(T{}, outer));
    comptime if (!@hasField(Outer, inner)) @compileError("nested parameter field does not exist: " ++ outer ++ "." ++ inner);
    const F = @TypeOf(@field(Outer{}, inner));
    comptime switch (desc.kind) {
        .scalar => {},
        .choice => @compileError("scalar binding requires a scalar descriptor"),
    };

    const limits = desc.kind.scalar;
    const Impl = struct {
        fn get(ctx: *const anyopaque) ParamValue {
            const self: *const T = @ptrCast(@alignCast(ctx));
            return .{ .scalar = numericRead(F, @field(@field(self.*, outer), inner)) };
        }

        fn validate(value: ParamValue) Error!void {
            const raw = switch (value) {
                .scalar => |v| v,
                .choice => return Error.WrongValueKind,
            };
            if (!std.math.isFinite(raw) or raw < limits.min or raw > limits.max) return Error.OutOfRange;
            _ = numericWrite(F, raw) orelse return Error.OutOfRange;
        }

        fn set(ctx: *anyopaque, value: ParamValue) Error!void {
            try validate(value);
            const self: *T = @ptrCast(@alignCast(ctx));
            @field(@field(self.*, outer), inner) = numericWrite(F, value.scalar).?;
        }
    };
    return .{ .desc = desc, .get = Impl.get, .set = Impl.set, .validate = Impl.validate };
}

fn enumBinding(comptime T: type, comptime field_name: []const u8, comptime desc: ParamDesc) Binding {
    comptime if (!@hasField(T, field_name)) @compileError("parameter field does not exist: " ++ field_name);
    const F = @TypeOf(@field(T{}, field_name));
    comptime if (@typeInfo(F) != .@"enum") @compileError("choice binding requires an enum field");
    comptime switch (desc.kind) {
        .choice => {},
        .scalar => @compileError("enum binding requires a choice descriptor"),
    };

    const choice = desc.kind.choice;
    const fields = @typeInfo(F).@"enum".fields;
    comptime {
        if (choice.options.len != fields.len) @compileError("choice options must match enum fields");
        for (fields, 0..) |field, index| {
            if (!std.mem.eql(u8, field.name, choice.options[index])) @compileError("choice option order must match enum order");
        }
    }
    const Impl = struct {
        fn get(ctx: *const anyopaque) ParamValue {
            const self: *const T = @ptrCast(@alignCast(ctx));
            return .{ .choice = @intFromEnum(@field(self.*, field_name)) };
        }

        fn validate(value: ParamValue) Error!void {
            const index = switch (value) {
                .choice => |v| v,
                .scalar => return Error.WrongValueKind,
            };
            if (index >= choice.options.len) return Error.ChoiceIndexOutOfRange;
        }

        fn set(ctx: *anyopaque, value: ParamValue) Error!void {
            try validate(value);
            const self: *T = @ptrCast(@alignCast(ctx));
            @field(self.*, field_name) = @enumFromInt(value.choice);
        }
    };
    return .{ .desc = desc, .get = Impl.get, .set = Impl.set, .validate = Impl.validate };
}

fn nestedEnumBinding(comptime T: type, comptime outer: []const u8, comptime inner: []const u8, comptime desc: ParamDesc) Binding {
    comptime if (!@hasField(T, outer)) @compileError("parameter field does not exist: " ++ outer);
    const Outer = @TypeOf(@field(T{}, outer));
    comptime if (!@hasField(Outer, inner)) @compileError("nested parameter field does not exist: " ++ outer ++ "." ++ inner);
    const F = @TypeOf(@field(Outer{}, inner));
    comptime if (@typeInfo(F) != .@"enum") @compileError("choice binding requires an enum field");
    comptime switch (desc.kind) {
        .choice => {},
        .scalar => @compileError("enum binding requires a choice descriptor"),
    };

    const choice = desc.kind.choice;
    const fields = @typeInfo(F).@"enum".fields;
    comptime {
        if (choice.options.len != fields.len) @compileError("choice options must match enum fields");
        for (fields, 0..) |field, index| {
            if (!std.mem.eql(u8, field.name, choice.options[index])) @compileError("choice option order must match enum order");
        }
    }
    const Impl = struct {
        fn get(ctx: *const anyopaque) ParamValue {
            const self: *const T = @ptrCast(@alignCast(ctx));
            return .{ .choice = @intFromEnum(@field(@field(self.*, outer), inner)) };
        }

        fn validate(value: ParamValue) Error!void {
            const index = switch (value) {
                .choice => |v| v,
                .scalar => return Error.WrongValueKind,
            };
            if (index >= choice.options.len) return Error.ChoiceIndexOutOfRange;
        }

        fn set(ctx: *anyopaque, value: ParamValue) Error!void {
            try validate(value);
            const self: *T = @ptrCast(@alignCast(ctx));
            @field(@field(self.*, outer), inner) = @enumFromInt(value.choice);
        }
    };
    return .{ .desc = desc, .get = Impl.get, .set = Impl.set, .validate = Impl.validate };
}

fn nestedBoolBinding(comptime T: type, comptime outer: []const u8, comptime inner: []const u8, comptime desc: ParamDesc) Binding {
    comptime if (!@hasField(T, outer)) @compileError("parameter field does not exist: " ++ outer);
    const Outer = @TypeOf(@field(T{}, outer));
    comptime if (!@hasField(Outer, inner)) @compileError("nested parameter field does not exist: " ++ outer ++ "." ++ inner);
    comptime if (@TypeOf(@field(Outer{}, inner)) != bool) @compileError("boolean binding requires a bool field");
    comptime switch (desc.kind) {
        .choice => {},
        .scalar => @compileError("boolean binding requires a choice descriptor"),
    };

    const choice = desc.kind.choice;
    comptime {
        if (choice.options.len != 2 or !std.mem.eql(u8, choice.options[0], "off") or !std.mem.eql(u8, choice.options[1], "on"))
            @compileError("boolean choices must be off/on");
    }
    const Impl = struct {
        fn get(ctx: *const anyopaque) ParamValue {
            const self: *const T = @ptrCast(@alignCast(ctx));
            return .{ .choice = if (@field(@field(self.*, outer), inner)) 1 else 0 };
        }

        fn validate(value: ParamValue) Error!void {
            const index = switch (value) {
                .choice => |v| v,
                .scalar => return Error.WrongValueKind,
            };
            if (index >= choice.options.len) return Error.ChoiceIndexOutOfRange;
        }

        fn set(ctx: *anyopaque, value: ParamValue) Error!void {
            try validate(value);
            const self: *T = @ptrCast(@alignCast(ctx));
            @field(@field(self.*, outer), inner) = value.choice == 1;
        }
    };
    return .{ .desc = desc, .get = Impl.get, .set = Impl.set, .validate = Impl.validate };
}

fn boolBinding(comptime T: type, comptime field_name: []const u8, comptime desc: ParamDesc) Binding {
    comptime if (!@hasField(T, field_name)) @compileError("parameter field does not exist: " ++ field_name);
    comptime if (@TypeOf(@field(T{}, field_name)) != bool) @compileError("boolean binding requires a bool field");
    comptime switch (desc.kind) {
        .choice => {},
        .scalar => @compileError("boolean binding requires a choice descriptor"),
    };

    const choice = desc.kind.choice;
    comptime {
        if (choice.options.len != 2 or !std.mem.eql(u8, choice.options[0], "off") or !std.mem.eql(u8, choice.options[1], "on"))
            @compileError("boolean choices must be off/on");
    }
    const Impl = struct {
        fn get(ctx: *const anyopaque) ParamValue {
            const self: *const T = @ptrCast(@alignCast(ctx));
            return .{ .choice = if (@field(self.*, field_name)) 1 else 0 };
        }

        fn validate(value: ParamValue) Error!void {
            const index = switch (value) {
                .choice => |v| v,
                .scalar => return Error.WrongValueKind,
            };
            if (index >= choice.options.len) return Error.ChoiceIndexOutOfRange;
        }

        fn set(ctx: *anyopaque, value: ParamValue) Error!void {
            try validate(value);
            const self: *T = @ptrCast(@alignCast(ctx));
            @field(self.*, field_name) = value.choice == 1;
        }
    };
    return .{ .desc = desc, .get = Impl.get, .set = Impl.set, .validate = Impl.validate };
}

/// `[N]f32` 配列フィールドの index 番目へスカラー binding。
fn arrayScalarBinding(comptime T: type, comptime field_name: []const u8, comptime index: usize, comptime desc: ParamDesc) Binding {
    comptime if (!@hasField(T, field_name)) @compileError("parameter field does not exist: " ++ field_name);
    const Arr = @TypeOf(@field(T{}, field_name));
    const arr_info = @typeInfo(Arr);
    comptime {
        if (arr_info != .array) @compileError("arrayScalarBinding requires an array field");
        if (index >= arr_info.array.len) @compileError("arrayScalarBinding index out of range");
    }
    const F = arr_info.array.child;
    comptime switch (desc.kind) {
        .scalar => {},
        .choice => @compileError("scalar binding requires a scalar descriptor"),
    };

    const limits = desc.kind.scalar;
    const Impl = struct {
        fn get(ctx: *const anyopaque) ParamValue {
            const self: *const T = @ptrCast(@alignCast(ctx));
            return .{ .scalar = numericRead(F, @field(self.*, field_name)[index]) };
        }

        fn validate(value: ParamValue) Error!void {
            const raw = switch (value) {
                .scalar => |v| v,
                .choice => return Error.WrongValueKind,
            };
            if (!std.math.isFinite(raw) or raw < limits.min or raw > limits.max) return Error.OutOfRange;
            _ = numericWrite(F, raw) orelse return Error.OutOfRange;
        }

        fn set(ctx: *anyopaque, value: ParamValue) Error!void {
            try validate(value);
            const self: *T = @ptrCast(@alignCast(ctx));
            @field(self.*, field_name)[index] = numericWrite(F, value.scalar).?;
        }
    };
    return .{ .desc = desc, .get = Impl.get, .set = Impl.set, .validate = Impl.validate };
}

/// `[N]bool` 配列フィールドの index 番目へ off/on choice binding。
fn arrayBoolBinding(comptime T: type, comptime field_name: []const u8, comptime index: usize, comptime desc: ParamDesc) Binding {
    comptime if (!@hasField(T, field_name)) @compileError("parameter field does not exist: " ++ field_name);
    const Arr = @TypeOf(@field(T{}, field_name));
    const arr_info = @typeInfo(Arr);
    comptime {
        if (arr_info != .array) @compileError("arrayBoolBinding requires an array field");
        if (index >= arr_info.array.len) @compileError("arrayBoolBinding index out of range");
        if (arr_info.array.child != bool) @compileError("arrayBoolBinding requires a bool array");
    }
    comptime switch (desc.kind) {
        .choice => {},
        .scalar => @compileError("boolean binding requires a choice descriptor"),
    };

    const choice = desc.kind.choice;
    comptime {
        if (choice.options.len != 2 or !std.mem.eql(u8, choice.options[0], "off") or !std.mem.eql(u8, choice.options[1], "on"))
            @compileError("boolean choices must be off/on");
    }
    const Impl = struct {
        fn get(ctx: *const anyopaque) ParamValue {
            const self: *const T = @ptrCast(@alignCast(ctx));
            return .{ .choice = if (@field(self.*, field_name)[index]) 1 else 0 };
        }

        fn validate(value: ParamValue) Error!void {
            const index_v = switch (value) {
                .choice => |v| v,
                .scalar => return Error.WrongValueKind,
            };
            if (index_v >= choice.options.len) return Error.ChoiceIndexOutOfRange;
        }

        fn set(ctx: *anyopaque, value: ParamValue) Error!void {
            try validate(value);
            const self: *T = @ptrCast(@alignCast(ctx));
            @field(self.*, field_name)[index] = value.choice == 1;
        }
    };
    return .{ .desc = desc, .get = Impl.get, .set = Impl.set, .validate = Impl.validate };
}

const osc_options = [_][]const u8{ "sine", "saw", "square", "triangle" };
const lfo_options = [_][]const u8{ "sine", "triangle", "saw" };
const filter_options = [_][]const u8{ "lowpass", "highpass", "bandpass", "notch" };
const scale_options = [_][]const u8{ "minor_pentatonic", "minor", "major" };
const bool_options = [_][]const u8{ "off", "on" };
const logic_options = [_][]const u8{ "and", "or", "xor" };

const vco_bindings = [_]Binding{
    scalarBinding(modules.Vco, "base_hz", scalarDesc("base_hz", 0.0, 20000.0, signal.pitch_base_hz, 1.0, "Hz")),
    nestedEnumBinding(modules.Vco, "osc", "waveform", choiceDesc("waveform", &osc_options, 0)),
    nestedBoolBinding(modules.Vco, "osc", "antialias", choiceDesc("antialias", &bool_options, 1)),
};
const vca_bindings = [_]Binding{
    scalarBinding(modules.Vca, "gain", scalarDesc("gain", 0.0, 4.0, 1.0, 0.01, "")),
};
const env_gen_bindings = [_]Binding{
    nestedScalarBinding(modules.EnvGen, "env", "attack", scalarDesc("env.attack", 0.0, 10.0, 0.01, 0.001, "s")),
    nestedScalarBinding(modules.EnvGen, "env", "decay", scalarDesc("env.decay", 0.0, 10.0, 0.1, 0.001, "s")),
    nestedScalarBinding(modules.EnvGen, "env", "sustain", scalarDesc("env.sustain", 0.0, 1.0, 0.7, 0.01, "")),
    nestedScalarBinding(modules.EnvGen, "env", "release", scalarDesc("env.release", 0.0, 10.0, 0.2, 0.001, "s")),
};
const vcf_bindings = [_]Binding{
    scalarBinding(modules.Vcf, "cutoff", scalarDesc("cutoff", 1.0, 20000.0, 1000.0, 1.0, "Hz")),
    scalarBinding(modules.Vcf, "resonance", scalarDesc("resonance", 0.5, 20.0, 0.707, 0.01, "Q")),
    enumBinding(modules.Vcf, "mode", choiceDesc("mode", &filter_options, 0)),
    scalarBinding(modules.Vcf, "mod_octaves", scalarDesc("mod_octaves", 0.0, 8.0, 2.0, 0.01, "oct")),
};
const mixer_bindings = [_]Binding{
    scalarBinding(modules.Mixer, "gain", scalarDesc("gain", 0.0, 4.0, 1.0, 0.01, "")),
    arrayScalarBinding(modules.Mixer, "input_gain", 0, scalarDesc("in0_gain", 0.0, 2.0, 1.0, 0.01, "")),
    arrayScalarBinding(modules.Mixer, "input_gain", 1, scalarDesc("in1_gain", 0.0, 2.0, 1.0, 0.01, "")),
    arrayScalarBinding(modules.Mixer, "input_gain", 2, scalarDesc("in2_gain", 0.0, 2.0, 1.0, 0.01, "")),
    arrayScalarBinding(modules.Mixer, "input_gain", 3, scalarDesc("in3_gain", 0.0, 2.0, 1.0, 0.01, "")),
    arrayBoolBinding(modules.Mixer, "input_mute", 0, choiceDesc("in0_mute", &bool_options, 0)),
    arrayBoolBinding(modules.Mixer, "input_mute", 1, choiceDesc("in1_mute", &bool_options, 0)),
    arrayBoolBinding(modules.Mixer, "input_mute", 2, choiceDesc("in2_mute", &bool_options, 0)),
    arrayBoolBinding(modules.Mixer, "input_mute", 3, choiceDesc("in3_mute", &bool_options, 0)),
};
const output_bindings = [_]Binding{
    scalarBinding(modules.Output, "gain", scalarDesc("gain", 0.0, 4.0, 1.0, 0.01, "")),
    scalarBinding(modules.Output, "pan", scalarDesc("pan", -1.0, 1.0, 0.0, 0.01, "")),
    boolBinding(modules.Output, "soft_clip", choiceDesc("soft_clip", &bool_options, 1)),
};
const clock_bindings = [_]Binding{
    scalarBinding(modules.Clock, "bpm", scalarDesc("bpm", 20.0, 300.0, 120.0, 1.0, "BPM")),
    scalarBinding(modules.Clock, "ppqn", scalarDesc("ppqn", 1.0, 64.0, 4.0, 1.0, "")),
    scalarBinding(modules.Clock, "swing", scalarDesc("swing", 0.0, 1.0, 0.0, 0.01, "")),
};
const clock_divider_bindings = [_]Binding{
    scalarBinding(modules.ClockDivider, "div", scalarDesc("div", 1.0, 64.0, 2.0, 1.0, "")),
};
const euclid_bindings = [_]Binding{
    scalarBinding(modules.EuclideanSeq, "steps", scalarDesc("steps", 1.0, 32.0, 8.0, 1.0, "")),
    scalarBinding(modules.EuclideanSeq, "pulses", scalarDesc("pulses", 0.0, 32.0, 4.0, 1.0, "")),
    scalarBinding(modules.EuclideanSeq, "rotation", scalarDesc("rotation", 0.0, 31.0, 0.0, 1.0, "")),
};
const quantizer_bindings = [_]Binding{
    enumBinding(modules.Quantizer, "scale", choiceDesc("scale", &scale_options, 0)),
    scalarBinding(modules.Quantizer, "root_semitone", scalarDesc("root_semitone", -48.0, 48.0, 0.0, 1.0, "st")),
    scalarBinding(modules.Quantizer, "octaves", scalarDesc("octaves", 1.0, 8.0, 2.0, 1.0, "")),
    scalarBinding(modules.Quantizer, "input_cv", scalarDesc("input_cv", 0.0, 1.0, 0.0, 0.01, "")),
};
const step_seq_bindings = [_]Binding{
    enumBinding(modules.StepSeq, "scale", choiceDesc("scale", &scale_options, 0)),
    scalarBinding(modules.StepSeq, "root_semitone", scalarDesc("root_semitone", -48.0, 48.0, 0.0, 1.0, "st")),
    scalarBinding(modules.StepSeq, "octaves", scalarDesc("octaves", 1.0, 8.0, 2.0, 1.0, "")),
    scalarBinding(modules.StepSeq, "glide_rate", scalarDesc("glide_rate", 0.0, 100.0, 6.0, 0.1, "oct/s")),
    boolBinding(modules.StepSeq, "evolve", choiceDesc("evolve", &bool_options, 0)),
    boolBinding(modules.StepSeq, "lock", choiceDesc("lock", &bool_options, 0)),
    scalarBinding(modules.StepSeq, "density", scalarDesc("density", 0.0, 1.0, 0.25, 0.01, "")),
};
const lfo_bindings = [_]Binding{
    scalarBinding(modules.Lfo, "rate_hz", scalarDesc("rate_hz", 0.0, 100.0, 0.1, 0.01, "Hz")),
    nestedEnumBinding(modules.Lfo, "lfo", "waveform", choiceDesc("waveform", &lfo_options, 0)),
};
const kick_bindings = [_]Binding{
    scalarBinding(modules.Kick, "base_hz", scalarDesc("base_hz", 1.0, 2000.0, 50.0, 1.0, "Hz")),
    scalarBinding(modules.Kick, "start_hz", scalarDesc("start_hz", 1.0, 5000.0, 140.0, 1.0, "Hz")),
    scalarBinding(modules.Kick, "pitch_decay", scalarDesc("pitch_decay", 0.001, 10.0, 0.03, 0.001, "s")),
    scalarBinding(modules.Kick, "amp_decay", scalarDesc("amp_decay", 0.001, 10.0, 0.28, 0.001, "s")),
    scalarBinding(modules.Kick, "body_gain", scalarDesc("body_gain", 0.0, 4.0, 1.0, 0.01, "")),
    scalarBinding(modules.Kick, "drive", scalarDesc("drive", 0.0, 10.0, 1.9, 0.01, "")),
    scalarBinding(modules.Kick, "click_gain", scalarDesc("click_gain", 0.0, 4.0, 0.35, 0.01, "")),
    scalarBinding(modules.Kick, "click_decay", scalarDesc("click_decay", 0.0001, 1.0, 0.005, 0.0001, "s")),
    scalarBinding(modules.Kick, "click_cutoff", scalarDesc("click_cutoff", 1.0, 20000.0, 1400.0, 1.0, "Hz")),
    scalarBinding(modules.Kick, "gain", scalarDesc("gain", 0.0, 4.0, 0.8, 0.01, "")),
};
const hat_bindings = [_]Binding{
    scalarBinding(modules.Hat, "decay", scalarDesc("decay", 0.001, 10.0, 0.045, 0.001, "s")),
    scalarBinding(modules.Hat, "brightness", scalarDesc("brightness", 0.3, 2.5, 1.0, 0.01, "")),
    scalarBinding(modules.Hat, "hp_cutoff", scalarDesc("hp_cutoff", 1.0, 20000.0, 7000.0, 1.0, "Hz")),
    scalarBinding(modules.Hat, "bp_cutoff", scalarDesc("bp_cutoff", 1.0, 20000.0, 9000.0, 1.0, "Hz")),
    scalarBinding(modules.Hat, "bp_q", scalarDesc("bp_q", 0.5, 20.0, 1.2, 0.01, "Q")),
    scalarBinding(modules.Hat, "gain", scalarDesc("gain", 0.0, 4.0, 0.28, 0.01, "")),
};
const perc_env_bindings = [_]Binding{
    scalarBinding(modules.PercEnv, "decay", scalarDesc("decay", 0.001, 10.0, 0.18, 0.001, "s")),
    scalarBinding(modules.PercEnv, "peak", scalarDesc("peak", 0.0, 4.0, 1.0, 0.01, "")),
};
const random_bindings = [_]Binding{
    scalarBinding(modules.Random, "min", scalarDesc("min", -1.0, 1.0, 0.0, 0.01, "")),
    scalarBinding(modules.Random, "max", scalarDesc("max", -1.0, 1.0, 1.0, 0.01, "")),
};
const turing_bindings = [_]Binding{
    scalarBinding(modules.TuringMachine, "bits", scalarDesc("bits", 1.0, 16.0, 8.0, 1.0, "")),
    scalarBinding(modules.TuringMachine, "anchor_register", scalarDesc("anchor_register", 0.0, 65535.0, 181.0, 1.0, "")),
    scalarBinding(modules.TuringMachine, "lock", scalarDesc("lock", 0.85, 0.98, 0.93, 0.01, "")),
    scalarBinding(modules.TuringMachine, "anchor_period", scalarDesc("anchor_period", 0.0, 65535.0, 64.0, 1.0, "")),
    scalarBinding(modules.TuringMachine, "anchor_return_prob", scalarDesc("anchor_return_prob", 0.0, 1.0, 0.04, 0.01, "")),
};
const clap_bindings = [_]Binding{
    scalarBinding(modules.Clap, "gain", scalarDesc("gain", 0.0, 4.0, 0.35, 0.01, "")),
    scalarBinding(modules.Clap, "tone_hz", scalarDesc("tone_hz", 1.0, 20000.0, 180.0, 1.0, "Hz")),
    scalarBinding(modules.Clap, "tone_gain", scalarDesc("tone_gain", 0.0, 1.0, 0.06, 0.01, "")),
    scalarBinding(modules.Clap, "decay", scalarDesc("decay", 0.001, 10.0, 0.12, 0.001, "s")),
    scalarBinding(modules.Clap, "spread_ms", scalarDesc("spread_ms", 1.0, 40.0, 10.0, 0.1, "ms")),
    scalarBinding(modules.Clap, "hp_cutoff", scalarDesc("hp_cutoff", 1.0, 20000.0, 1200.0, 1.0, "Hz")),
    scalarBinding(modules.Clap, "bp_cutoff", scalarDesc("bp_cutoff", 1.0, 20000.0, 1800.0, 1.0, "Hz")),
    scalarBinding(modules.Clap, "bp_q", scalarDesc("bp_q", 0.5, 20.0, 1.0, 0.01, "Q")),
};
const chord_pad_bindings = [_]Binding{
    scalarBinding(modules.ChordPad, "base_hz", scalarDesc("base_hz", 1.0, 20000.0, 130.81, 0.01, "Hz")),
    scalarBinding(modules.ChordPad, "detune", scalarDesc("detune", 0.0, 0.1, 0.004, 0.0001, "")),
    scalarBinding(modules.ChordPad, "warmth", scalarDesc("warmth", 0.0, 1.0, 0.6, 0.01, "")),
    scalarBinding(modules.ChordPad, "cutoff", scalarDesc("cutoff", 1.0, 20000.0, 1400.0, 1.0, "Hz")),
    scalarBinding(modules.ChordPad, "cutoff_mod_oct", scalarDesc("cutoff_mod_oct", 0.0, 8.0, 0.6, 0.01, "oct")),
    scalarBinding(modules.ChordPad, "level_mod_depth", scalarDesc("level_mod_depth", 0.0, 1.0, 0.25, 0.01, "")),
    scalarBinding(modules.ChordPad, "attack", scalarDesc("attack", 0.001, 10.0, 0.35, 0.001, "s")),
    scalarBinding(modules.ChordPad, "release", scalarDesc("release", 0.001, 20.0, 1.4, 0.001, "s")),
    scalarBinding(modules.ChordPad, "gain", scalarDesc("gain", 0.0, 2.0, 0.22, 0.01, "")),
};
const saturator_bindings = [_]Binding{
    scalarBinding(modules.Saturator, "drive", scalarDesc("drive", 0.0, 10.0, 1.4, 0.01, "")),
    scalarBinding(modules.Saturator, "post_gain", scalarDesc("post_gain", 0.0, 4.0, 0.8, 0.01, "")),
};
const bitcrusher_bindings = [_]Binding{
    nestedScalarBinding(modules.Bitcrusher, "bc", "bit_depth", scalarDesc("bc.bit_depth", 1.0, 16.0, 8.0, 1.0, "bit")),
    nestedScalarBinding(modules.Bitcrusher, "bc", "hold_samples", scalarDesc("bc.hold_samples", 1.0, 65535.0, 4.0, 1.0, "samples")),
    nestedScalarBinding(modules.Bitcrusher, "bc", "wet", scalarDesc("bc.wet", 0.0, 1.0, 1.0, 0.01, "")),
};
const delay_bindings = [_]Binding{
    scalarBinding(modules.DelayFx, "delay_ms", scalarDesc("delay_ms", 0.0, 1365.0, 375.0, 0.1, "ms")),
    scalarBinding(modules.DelayFx, "feedback", scalarDesc("feedback", 0.0, 0.92, 0.35, 0.01, "")),
    scalarBinding(modules.DelayFx, "wet", scalarDesc("wet", 0.0, 0.8, 0.2, 0.01, "")),
};
const reverb_bindings = [_]Binding{
    scalarBinding(modules.ReverbFx, "decay", scalarDesc("decay", 0.0, 1.0, 0.6, 0.01, "")),
    scalarBinding(modules.ReverbFx, "damping", scalarDesc("damping", 0.0, 0.99, 0.3, 0.01, "")),
    scalarBinding(modules.ReverbFx, "wet", scalarDesc("wet", 0.0, 0.8, 0.12, 0.01, "")),
};
const vinyl_bindings = [_]Binding{
    nestedScalarBinding(modules.VinylNoiseFx, "vn", "hiss_gain", scalarDesc("vn.hiss_gain", 0.0, 1.0, 0.003, 0.001, "")),
    nestedScalarBinding(modules.VinylNoiseFx, "vn", "crackle_gain", scalarDesc("vn.crackle_gain", 0.0, 1.0, 0.08, 0.01, "")),
    nestedScalarBinding(modules.VinylNoiseFx, "vn", "crackle_prob", scalarDesc("vn.crackle_prob", 0.0, 1.0, 0.00035, 0.0001, "")),
    nestedScalarBinding(modules.VinylNoiseFx, "vn", "decay", scalarDesc("vn.decay", 0.0, 0.999, 0.92, 0.001, "")),
};
const wow_flutter_bindings = [_]Binding{
    nestedScalarBinding(modules.WowFlutterFx, "wf", "base_delay_ms", scalarDesc("base_delay_ms", 0.0, 100.0, 8.0, 0.1, "ms")),
    nestedScalarBinding(modules.WowFlutterFx, "wf", "wow_depth_ms", scalarDesc("wow_depth_ms", 0.0, 100.0, 2.5, 0.1, "ms")),
    nestedScalarBinding(modules.WowFlutterFx, "wf", "flutter_depth_ms", scalarDesc("flutter_depth_ms", 0.0, 100.0, 0.35, 0.01, "ms")),
    nestedScalarBinding(modules.WowFlutterFx, "wf", "wow_rate_hz", scalarDesc("wow_rate_hz", 0.0, 20.0, 0.35, 0.01, "Hz")),
    nestedScalarBinding(modules.WowFlutterFx, "wf", "flutter_rate_hz", scalarDesc("flutter_rate_hz", 0.0, 100.0, 6.0, 0.01, "Hz")),
    nestedScalarBinding(modules.WowFlutterFx, "wf", "wet", scalarDesc("wet", 0.0, 1.0, 0.35, 0.01, "")),
};
const sidechain_bindings = [_]Binding{
    scalarBinding(modules.Sidechain, "amount", scalarDesc("amount", 0.0, 1.0, 0.0, 0.01, "")),
    scalarBinding(modules.Sidechain, "release", scalarDesc("release", 0.001, 10.0, 0.18, 0.001, "s")),
};
const slew_bindings = [_]Binding{
    scalarBinding(modules.Slew, "rise", scalarDesc("rise", 0.0, 100.0, 1.0, 0.01, "CV/s")),
    scalarBinding(modules.Slew, "fall", scalarDesc("fall", 0.0, 100.0, 1.0, 0.01, "CV/s")),
};
const logic_bindings = [_]Binding{
    enumBinding(modules.Logic, "op", choiceDesc("op", &logic_options, 2)),
};

fn validateBindings(comptime list: []const Binding) void {
    inline for (list, 0..) |binding, i| {
        if (binding.desc.name.len == 0) @compileError("parameter descriptor name must not be empty");
        switch (binding.desc.kind) {
            .scalar => |s| {
                if (!std.math.isFinite(s.min) or !std.math.isFinite(s.max) or !std.math.isFinite(s.default) or !std.math.isFinite(s.step))
                    @compileError("scalar descriptor must be finite");
                if (s.min > s.default or s.default > s.max) @compileError("scalar descriptor default is outside its range");
                if (s.step <= 0.0) @compileError("scalar descriptor step must be positive");
            },
            .choice => |c| {
                if (c.options.len == 0) @compileError("choice descriptor options must not be empty");
                if (c.default >= c.options.len) @compileError("choice descriptor default is outside its options");
            },
        }
        inline for (list[0..i]) |previous| {
            if (std.mem.eql(u8, previous.desc.name, binding.desc.name)) @compileError("duplicate parameter descriptor name");
        }
    }
}

fn bindings(comptime k: dyn.ModuleKind) []const Binding {
    const result = comptime switch (k) {
        .vco => &vco_bindings,
        .vca => &vca_bindings,
        .env_gen => &env_gen_bindings,
        .vcf => &vcf_bindings,
        .mixer => &mixer_bindings,
        .output => &output_bindings,
        .clock => &clock_bindings,
        .clock_divider => &clock_divider_bindings,
        .euclid => &euclid_bindings,
        .quantizer => &quantizer_bindings,
        .step_seq => &step_seq_bindings,
        .lfo => &lfo_bindings,
        .kick => &kick_bindings,
        .hat => &hat_bindings,
        .perc_env => &perc_env_bindings,
        .random => &random_bindings,
        .turing => &turing_bindings,
        .clap => &clap_bindings,
        .chord_pad => &chord_pad_bindings,
        .saturator => &saturator_bindings,
        .bitcrusher => &bitcrusher_bindings,
        .delay => &delay_bindings,
        .reverb => &reverb_bindings,
        .vinyl => &vinyl_bindings,
        .wow_flutter => &wow_flutter_bindings,
        .sidechain => &sidechain_bindings,
        .slew => &slew_bindings,
        .sample_hold => &[_]Binding{},
        .comparator => &[_]Binding{},
        .ring_mod => &[_]Binding{},
        .logic => &logic_bindings,
    };
    comptime validateBindings(result);
    return result;
}

fn descriptorTable(comptime k: dyn.ModuleKind) []const ParamDesc {
    const result = switch (k) {
        .vco => &[_]ParamDesc{ vco_bindings[0].desc, vco_bindings[1].desc, vco_bindings[2].desc },
        .vca => &[_]ParamDesc{vca_bindings[0].desc},
        .env_gen => &[_]ParamDesc{ env_gen_bindings[0].desc, env_gen_bindings[1].desc, env_gen_bindings[2].desc, env_gen_bindings[3].desc },
        .vcf => &[_]ParamDesc{ vcf_bindings[0].desc, vcf_bindings[1].desc, vcf_bindings[2].desc, vcf_bindings[3].desc },
        .mixer => &[_]ParamDesc{
            mixer_bindings[0].desc,
            mixer_bindings[1].desc,
            mixer_bindings[2].desc,
            mixer_bindings[3].desc,
            mixer_bindings[4].desc,
            mixer_bindings[5].desc,
            mixer_bindings[6].desc,
            mixer_bindings[7].desc,
            mixer_bindings[8].desc,
        },
        .output => &[_]ParamDesc{ output_bindings[0].desc, output_bindings[1].desc, output_bindings[2].desc },
        .clock => &[_]ParamDesc{ clock_bindings[0].desc, clock_bindings[1].desc, clock_bindings[2].desc },
        .clock_divider => &[_]ParamDesc{clock_divider_bindings[0].desc},
        .euclid => &[_]ParamDesc{ euclid_bindings[0].desc, euclid_bindings[1].desc, euclid_bindings[2].desc },
        .quantizer => &[_]ParamDesc{ quantizer_bindings[0].desc, quantizer_bindings[1].desc, quantizer_bindings[2].desc, quantizer_bindings[3].desc },
        .step_seq => &[_]ParamDesc{ step_seq_bindings[0].desc, step_seq_bindings[1].desc, step_seq_bindings[2].desc, step_seq_bindings[3].desc, step_seq_bindings[4].desc, step_seq_bindings[5].desc, step_seq_bindings[6].desc },
        .lfo => &[_]ParamDesc{ lfo_bindings[0].desc, lfo_bindings[1].desc },
        .kick => &[_]ParamDesc{ kick_bindings[0].desc, kick_bindings[1].desc, kick_bindings[2].desc, kick_bindings[3].desc, kick_bindings[4].desc, kick_bindings[5].desc, kick_bindings[6].desc, kick_bindings[7].desc, kick_bindings[8].desc, kick_bindings[9].desc },
        .hat => &[_]ParamDesc{ hat_bindings[0].desc, hat_bindings[1].desc, hat_bindings[2].desc, hat_bindings[3].desc, hat_bindings[4].desc, hat_bindings[5].desc },
        .perc_env => &[_]ParamDesc{ perc_env_bindings[0].desc, perc_env_bindings[1].desc },
        .random => &[_]ParamDesc{ random_bindings[0].desc, random_bindings[1].desc },
        .turing => &[_]ParamDesc{ turing_bindings[0].desc, turing_bindings[1].desc, turing_bindings[2].desc, turing_bindings[3].desc, turing_bindings[4].desc },
        .clap => &[_]ParamDesc{ clap_bindings[0].desc, clap_bindings[1].desc, clap_bindings[2].desc, clap_bindings[3].desc, clap_bindings[4].desc, clap_bindings[5].desc, clap_bindings[6].desc, clap_bindings[7].desc },
        .chord_pad => &[_]ParamDesc{ chord_pad_bindings[0].desc, chord_pad_bindings[1].desc, chord_pad_bindings[2].desc, chord_pad_bindings[3].desc, chord_pad_bindings[4].desc, chord_pad_bindings[5].desc, chord_pad_bindings[6].desc, chord_pad_bindings[7].desc, chord_pad_bindings[8].desc },
        .saturator => &[_]ParamDesc{ saturator_bindings[0].desc, saturator_bindings[1].desc },
        .bitcrusher => &[_]ParamDesc{ bitcrusher_bindings[0].desc, bitcrusher_bindings[1].desc, bitcrusher_bindings[2].desc },
        .delay => &[_]ParamDesc{ delay_bindings[0].desc, delay_bindings[1].desc, delay_bindings[2].desc },
        .reverb => &[_]ParamDesc{ reverb_bindings[0].desc, reverb_bindings[1].desc, reverb_bindings[2].desc },
        .vinyl => &[_]ParamDesc{ vinyl_bindings[0].desc, vinyl_bindings[1].desc, vinyl_bindings[2].desc, vinyl_bindings[3].desc },
        .wow_flutter => &[_]ParamDesc{ wow_flutter_bindings[0].desc, wow_flutter_bindings[1].desc, wow_flutter_bindings[2].desc, wow_flutter_bindings[3].desc, wow_flutter_bindings[4].desc, wow_flutter_bindings[5].desc },
        .sidechain => &[_]ParamDesc{ sidechain_bindings[0].desc, sidechain_bindings[1].desc },
        .slew => &[_]ParamDesc{ slew_bindings[0].desc, slew_bindings[1].desc },
        .sample_hold, .comparator, .ring_mod => &[_]ParamDesc{},
        .logic => &[_]ParamDesc{logic_bindings[0].desc},
    };
    const source = comptime bindings(k);
    comptime {
        if (source.len != result.len) @compileError("descriptor table and binding table length differ");
        for (source, 0..) |binding, index| {
            if (!std.mem.eql(u8, binding.desc.name, result[index].name))
                @compileError("descriptor table and binding table differ");
        }
    }
    return result;
}

pub fn descriptors(comptime k: dyn.ModuleKind) []const ParamDesc {
    return descriptorTable(k);
}

fn checkedHandle(graph: *const dyn.DynGraph, h: dyn.Handle) Error!void {
    if (h >= dyn.MAX_MODULES) return Error.InvalidHandle;
    if (!graph.isActive(h)) return Error.InactiveHandle;
}

fn getForKind(comptime k: dyn.ModuleKind, graph: *const dyn.DynGraph, h: dyn.Handle, name: []const u8) Error!ParamValue {
    const object = graph.ptrOfConst(k, h);
    for (bindings(k)) |binding| {
        if (std.mem.eql(u8, binding.desc.name, name)) return binding.get(object);
    }
    return Error.UnknownParam;
}

fn setForKind(comptime k: dyn.ModuleKind, graph: *dyn.DynGraph, h: dyn.Handle, name: []const u8, value: ParamValue) Error!void {
    const object = graph.ptrOf(k, h);
    for (bindings(k)) |binding| {
        if (std.mem.eql(u8, binding.desc.name, name)) return binding.set(object, value);
    }
    return Error.UnknownParam;
}

pub fn getParam(graph: *const dyn.DynGraph, h: dyn.Handle, name: []const u8) Error!ParamValue {
    try checkedHandle(graph, h);
    const kind = graph.kindOf(h) orelse return Error.InactiveHandle;
    return switch (kind) {
        inline else => |comptime_kind| getForKind(comptime_kind, graph, h, name),
    };
}

fn runtimeInstant(graph: *const dyn.DynGraph, kind: dyn.ModuleKind, h: dyn.Handle, name: []const u8) ?ParamValue {
    return switch (kind) {
        .vcf => if (std.mem.eql(u8, name, "cutoff")) blk: {
            const value = graph.ptrOfConst(.vcf, h).applied_cutoff;
            if (!std.math.isFinite(value) or value < 0.0) break :blk null;
            break :blk .{ .scalar = value };
        } else null,
        .chord_pad => if (std.mem.eql(u8, name, "base_hz")) blk: {
            const value = graph.ptrOfConst(.chord_pad, h).root_hz;
            if (!std.math.isFinite(value) or value < 0.0) break :blk null;
            break :blk .{ .scalar = value };
        } else if (std.mem.eql(u8, name, "cutoff")) blk: {
            const value = graph.ptrOfConst(.chord_pad, h).applied_fc;
            if (!std.math.isFinite(value) or value < 0.0) break :blk null;
            break :blk .{ .scalar = value };
        } else null,
        else => null,
    };
}

/// `getParam()` の field 値に、既存 runtime modulation field の instant を添える。
/// GUI/frame-rate の best-effort read 専用で、RT callback からは呼ばない。
pub fn getParamSnapshot(graph: *const dyn.DynGraph, h: dyn.Handle, name: []const u8) Error!ParamSnapshot {
    try checkedHandle(graph, h);
    const kind = graph.kindOf(h) orelse return Error.InactiveHandle;
    const field = try getParam(graph, h, name);
    const instant = runtimeInstant(graph, kind, h, name);
    return .{ .field = field, .instant = instant, .has_instant = instant != null };
}

/// Control/event 側専用。active module の non-atomic source field を直接更新するため、
/// RT が同時に読む状態を別スレッドから直接書き換えず、app 側の既存 Mailbox/atomic/control-rate
/// 経路で呼び出し側が同期を担保する。ここでは publish/lock/alloc を追加しない。
pub fn setParam(graph: *dyn.DynGraph, h: dyn.Handle, name: []const u8, value: ParamValue) Error!void {
    try checkedHandle(graph, h);
    const kind = graph.kindOf(h) orelse return Error.InactiveHandle;
    return switch (kind) {
        inline else => |comptime_kind| setForKind(comptime_kind, graph, h, name, value),
    };
}

fn validateForKind(comptime k: dyn.ModuleKind, name: []const u8, value: ParamValue) Error!void {
    for (bindings(k)) |binding| {
        if (std.mem.eql(u8, binding.desc.name, name)) return binding.validate(value);
    }
    return Error.UnknownParam;
}

/// 実 module インスタンス無しで `setParam` と同一の受理判定を行う（NPRM clearGraph 前検証用）。
/// WrongValueKind / OutOfRange（非有限・range 外・整数バックの非整数）/ ChoiceIndexOutOfRange / UnknownParam。
pub fn validateParam(kind: dyn.ModuleKind, name: []const u8, value: ParamValue) Error!void {
    return switch (kind) {
        inline else => |comptime_kind| validateForKind(comptime_kind, name, value),
    };
}

test "params: every ModuleKind has valid, unique descriptors" {
    inline for (std.enums.values(dyn.ModuleKind)) |kind| {
        const list = descriptors(kind);
        var seen: [64][]const u8 = undefined;
        var n: usize = 0;
        for (list) |desc| {
            try std.testing.expect(desc.name.len > 0);
            for (seen[0..n]) |previous| try std.testing.expect(!std.mem.eql(u8, previous, desc.name));
            seen[n] = desc.name;
            n += 1;
            switch (desc.kind) {
                .scalar => |s| {
                    try std.testing.expect(std.math.isFinite(s.min));
                    try std.testing.expect(std.math.isFinite(s.max));
                    try std.testing.expect(std.math.isFinite(s.default));
                    try std.testing.expect(std.math.isFinite(s.step));
                    try std.testing.expect(s.min <= s.default and s.default <= s.max);
                    try std.testing.expect(s.step > 0.0);
                },
                .choice => |c| try std.testing.expect(c.options.len > 0 and c.default < c.options.len),
            }
        }
    }
}

test "params: descriptor defaults match concrete module defaults" {
    inline for (std.enums.values(dyn.ModuleKind)) |kind| {
        var value: dyn.KindType(kind) = .{};
        const list = bindings(kind);
        for (list) |binding| {
            const actual = binding.get(@ptrCast(&value));
            switch (binding.desc.kind) {
                .scalar => |s| switch (actual) {
                    .scalar => |v| try std.testing.expectEqual(s.default, v),
                    .choice => return error.TestExpectedEqual,
                },
                .choice => |c| switch (actual) {
                    .choice => |v| try std.testing.expectEqual(c.default, v),
                    .scalar => return error.TestExpectedEqual,
                },
            }
        }
    }
}

test "params: DynGraph dispatch round-trips scalar and every choice without publish" {
    var graph = try dyn.DynGraph.create(std.testing.allocator, 48000);
    defer graph.destroy();
    const view_gen = graph.currentView().gen;
    const rebuilds = graph.rebuildCount();

    inline for (std.enums.values(dyn.ModuleKind)) |kind| {
        const h = try graph.add(kind, .{});
        for (descriptors(kind)) |desc| {
            switch (desc.kind) {
                .scalar => |s| {
                    const initial = try getParam(graph, h, desc.name);
                    switch (initial) {
                        .scalar => |v| try std.testing.expectEqual(s.default, v),
                        .choice => return error.TestExpectedEqual,
                    }
                    try setParam(graph, h, desc.name, .{ .scalar = s.min });
                    const changed = try getParam(graph, h, desc.name);
                    switch (changed) {
                        .scalar => |v| try std.testing.expectEqual(s.min, v),
                        .choice => return error.TestExpectedEqual,
                    }
                    try setParam(graph, h, desc.name, .{ .scalar = s.default });
                },
                .choice => |c| {
                    for (c.options, 0..) |_, index| {
                        try setParam(graph, h, desc.name, .{ .choice = index });
                        const value = try getParam(graph, h, desc.name);
                        switch (value) {
                            .choice => |v| try std.testing.expectEqual(index, v),
                            .scalar => return error.TestExpectedEqual,
                        }
                    }
                    try setParam(graph, h, desc.name, .{ .choice = c.default });
                },
            }
        }
    }

    try std.testing.expectEqual(view_gen, graph.currentView().gen);
    try std.testing.expectEqual(rebuilds, graph.rebuildCount());
}

test "params: snapshots expose only existing runtime modulation fields" {
    var graph = try dyn.DynGraph.create(std.testing.allocator, 48000);
    defer graph.destroy();
    const vcf = try graph.add(.vcf, .{ .cutoff = 1200.0 });
    const chord = try graph.add(.chord_pad, .{ .base_hz = 130.81, .cutoff = 1400.0 });
    const kick = try graph.add(.kick, .{});
    try graph.publish();

    var buf: [1]f32 = undefined;
    graph.processBlock(&buf, 1, 1);

    const vcf_snapshot = try getParamSnapshot(graph, vcf, "cutoff");
    try std.testing.expect(vcf_snapshot.has_instant);
    try std.testing.expectEqual(@as(f32, 1200.0), vcf_snapshot.field.scalar);
    try std.testing.expectEqual(@as(f32, 1200.0), vcf_snapshot.instant.?.scalar);

    const chord_base = try getParamSnapshot(graph, chord, "base_hz");
    const chord_cutoff = try getParamSnapshot(graph, chord, "cutoff");
    try std.testing.expect(chord_base.has_instant);
    try std.testing.expect(chord_cutoff.has_instant);
    try std.testing.expectEqual(@as(f32, 130.81), chord_base.instant.?.scalar);
    try std.testing.expectEqual(@as(f32, 1400.0), chord_cutoff.instant.?.scalar);

    const kick_gain = try getParamSnapshot(graph, kick, "gain");
    try std.testing.expect(!kick_gain.has_instant);
    try std.testing.expect(kick_gain.instant == null);
}

test "params: invalid handles, names, value kinds, and ranges are explicit errors" {
    var graph = try dyn.DynGraph.create(std.testing.allocator, 48000);
    defer graph.destroy();
    const h = try graph.add(.vca, .{});
    const logic = try graph.add(.logic, .{});

    // -Dmax-modules で MAX_MODULES が変わっても常に範囲外であることを保証する（TASK-146: 固定値 100 は
    // N>100 で有効 handle 範囲に入ってしまい error.InactiveHandle に化けていた）。
    try std.testing.expectError(Error.InvalidHandle, getParam(graph, @intCast(dyn.MAX_MODULES), "gain"));
    try std.testing.expectError(Error.InactiveHandle, getParam(graph, 2, "gain"));
    try std.testing.expectError(Error.UnknownParam, getParam(graph, h, "missing"));
    try std.testing.expectError(Error.WrongValueKind, setParam(graph, h, "gain", .{ .choice = 0 }));
    try std.testing.expectError(Error.OutOfRange, setParam(graph, h, "gain", .{ .scalar = -1.0 }));
    try std.testing.expectError(Error.ChoiceIndexOutOfRange, setParam(graph, logic, "op", .{ .choice = 3 }));

    graph.removeModule(h);
    try std.testing.expectError(Error.InactiveHandle, getParam(graph, h, "gain"));
}

test "params: Mixer inX_mute is off/on choice; gain defaults/range/roundtrip" {
    const descs = descriptors(.mixer);
    try std.testing.expectEqual(@as(usize, 9), descs.len);

    inline for (.{ "in0_mute", "in1_mute", "in2_mute", "in3_mute" }) |mute_name| {
        const desc = blk: {
            for (descs) |d| {
                if (std.mem.eql(u8, d.name, mute_name)) break :blk d;
            }
            return error.TestUnexpectedResult;
        };
        switch (desc.kind) {
            .choice => |c| {
                try std.testing.expectEqual(@as(usize, 2), c.options.len);
                try std.testing.expectEqualStrings("off", c.options[0]);
                try std.testing.expectEqualStrings("on", c.options[1]);
                try std.testing.expectEqual(@as(usize, 0), c.default);
            },
            .scalar => return error.TestUnexpectedResult,
        }
    }

    inline for (.{ "in0_gain", "in1_gain", "in2_gain", "in3_gain" }) |gain_name| {
        const desc = blk: {
            for (descs) |d| {
                if (std.mem.eql(u8, d.name, gain_name)) break :blk d;
            }
            return error.TestUnexpectedResult;
        };
        switch (desc.kind) {
            .scalar => |s| {
                try std.testing.expectEqual(@as(f32, 0.0), s.min);
                try std.testing.expectEqual(@as(f32, 2.0), s.max);
                try std.testing.expectEqual(@as(f32, 1.0), s.default);
                try std.testing.expectEqual(@as(f32, 0.01), s.step);
            },
            .choice => return error.TestUnexpectedResult,
        }
    }

    var graph = try dyn.DynGraph.create(std.testing.allocator, 48000);
    defer graph.destroy();
    const h = try graph.add(.mixer, .{});

    try setParam(graph, h, "in0_gain", .{ .scalar = 0.25 });
    try setParam(graph, h, "in2_mute", .{ .choice = 1 });
    const gain = try getParam(graph, h, "in0_gain");
    const mute = try getParam(graph, h, "in2_mute");
    try std.testing.expectEqual(@as(f32, 0.25), gain.scalar);
    try std.testing.expectEqual(@as(usize, 1), mute.choice);

    try std.testing.expectError(Error.OutOfRange, setParam(graph, h, "in1_gain", .{ .scalar = 2.5 }));
    try std.testing.expectError(Error.WrongValueKind, setParam(graph, h, "in0_mute", .{ .scalar = 1.0 }));

    const mix = graph.ptrOfConst(.mixer, h);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), mix.input_gain[0], 1e-6);
    try std.testing.expect(mix.input_mute[2]);
}

test "params: StepSeq evolve/lock/density descriptor defaults and roundtrip" {
    const descs = descriptors(.step_seq);
    try std.testing.expectEqual(@as(usize, 7), descs.len);

    const evolve_desc = blk: {
        for (descs) |d| {
            if (std.mem.eql(u8, d.name, "evolve")) break :blk d;
        }
        return error.TestUnexpectedResult;
    };
    switch (evolve_desc.kind) {
        .choice => |c| {
            try std.testing.expectEqualStrings("off", c.options[0]);
            try std.testing.expectEqualStrings("on", c.options[1]);
            try std.testing.expectEqual(@as(usize, 0), c.default);
        },
        .scalar => return error.TestUnexpectedResult,
    }
    const lock_desc = blk: {
        for (descs) |d| {
            if (std.mem.eql(u8, d.name, "lock")) break :blk d;
        }
        return error.TestUnexpectedResult;
    };
    switch (lock_desc.kind) {
        .choice => |c| try std.testing.expectEqual(@as(usize, 0), c.default),
        .scalar => return error.TestUnexpectedResult,
    }
    const dens_desc = blk: {
        for (descs) |d| {
            if (std.mem.eql(u8, d.name, "density")) break :blk d;
        }
        return error.TestUnexpectedResult;
    };
    switch (dens_desc.kind) {
        .scalar => |s| {
            try std.testing.expectEqual(@as(f32, 0.0), s.min);
            try std.testing.expectEqual(@as(f32, 1.0), s.max);
            try std.testing.expectEqual(@as(f32, 0.25), s.default);
            try std.testing.expectEqual(@as(f32, 0.01), s.step);
        },
        .choice => return error.TestUnexpectedResult,
    }

    var graph = try dyn.DynGraph.create(std.testing.allocator, 48000);
    defer graph.destroy();
    const h = try graph.add(.step_seq, .{});

    try setParam(graph, h, "evolve", .{ .choice = 1 });
    try setParam(graph, h, "lock", .{ .choice = 1 });
    try setParam(graph, h, "density", .{ .scalar = 0.42 });
    try std.testing.expectEqual(@as(usize, 1), (try getParam(graph, h, "evolve")).choice);
    try std.testing.expectEqual(@as(usize, 1), (try getParam(graph, h, "lock")).choice);
    try std.testing.expectEqual(@as(f32, 0.42), (try getParam(graph, h, "density")).scalar);

    const seq = graph.ptrOfConst(.step_seq, h);
    try std.testing.expect(seq.evolve);
    try std.testing.expect(seq.lock);
    try std.testing.expectApproxEqAbs(@as(f32, 0.42), seq.density, 1e-6);

    try std.testing.expectError(Error.OutOfRange, setParam(graph, h, "density", .{ .scalar = 1.5 }));
    try std.testing.expectError(Error.WrongValueKind, setParam(graph, h, "evolve", .{ .scalar = 1.0 }));
}

fn expectSetValidateAgree(graph: *dyn.DynGraph, h: dyn.Handle, kind: dyn.ModuleKind, name: []const u8, value: ParamValue) !void {
    const set_result = setParam(graph, h, name, value);
    const val_result = validateParam(kind, name, value);
    if (set_result) |_| {
        try val_result;
    } else |set_err| {
        try std.testing.expectError(set_err, val_result);
    }
}

test "params: validateParam agrees with setParam for all kinds/descriptors" {
    var graph = try dyn.DynGraph.create(std.testing.allocator, 48000);
    defer graph.destroy();

    var comparisons: usize = 0;
    inline for (std.enums.values(dyn.ModuleKind)) |kind| {
        const h = try graph.add(kind, .{});
        for (descriptors(kind)) |desc| {
            switch (desc.kind) {
                .scalar => |s| {
                    const mid = s.min + (s.max - s.min) * 0.5;
                    const samples = [_]ParamValue{
                        .{ .scalar = s.min },
                        .{ .scalar = s.max },
                        .{ .scalar = mid },
                        .{ .scalar = mid + 0.5 },
                        .{ .scalar = std.math.nan(f32) },
                        .{ .choice = 0 }, // WrongValueKind
                    };
                    for (samples) |value| {
                        try expectSetValidateAgree(graph, h, kind, desc.name, value);
                        comparisons += 1;
                    }
                },
                .choice => |c| {
                    var index: usize = 0;
                    while (index < c.options.len) : (index += 1) {
                        try expectSetValidateAgree(graph, h, kind, desc.name, .{ .choice = index });
                        comparisons += 1;
                    }
                    try expectSetValidateAgree(graph, h, kind, desc.name, .{ .choice = c.options.len });
                    comparisons += 1;
                    try expectSetValidateAgree(graph, h, kind, desc.name, .{ .scalar = 0.0 });
                    comparisons += 1;
                },
            }
        }
        // 次 kind 用に slot を空ける（pool 枯渇回避）
        graph.removeModule(h);
    }
    // 組合せ数の下限（descriptor 増減で変わりうるが 0 ではないこと）
    try std.testing.expect(comparisons > 100);
    // テスト報告用に件数を固定ログ（失敗時の再現用）
    std.debug.print("validateParam/setParam comparisons={d}\n", .{comparisons});
}

test "params: dirty-gated coefficient updates observe source fields on the next block" {
    var graph = try dyn.DynGraph.create(std.testing.allocator, 48000);
    defer graph.destroy();
    const vcf = try graph.add(.vcf, .{});
    const kick = try graph.add(.kick, .{});
    const hat = try graph.add(.hat, .{});
    const perc = try graph.add(.perc_env, .{});
    const clap = try graph.add(.clap, .{});
    const chord = try graph.add(.chord_pad, .{});
    const reverb = try graph.add(.reverb, .{});
    const sidechain = try graph.add(.sidechain, .{});
    try graph.publish();

    var buf: [1]f32 = undefined;
    graph.processBlock(&buf, 1, 1);
    const vcf_updates = graph.ptrOf(.vcf, vcf).coeff_updates;
    graph.processBlock(&buf, 1, 1);
    try std.testing.expectEqual(vcf_updates, graph.ptrOf(.vcf, vcf).coeff_updates);
    try setParam(graph, vcf, "cutoff", .{ .scalar = 2000.0 });
    graph.processBlock(&buf, 1, 1);
    try std.testing.expectEqual(vcf_updates + 1, graph.ptrOf(.vcf, vcf).coeff_updates);

    const kick_k = graph.ptrOf(.kick, kick).amp_k;
    try setParam(graph, kick, "amp_decay", .{ .scalar = 0.5 });
    graph.processBlock(&buf, 1, 1);
    try std.testing.expect(kick_k != graph.ptrOf(.kick, kick).amp_k);

    const hat_k = graph.ptrOf(.hat, hat).amp_k;
    try setParam(graph, hat, "decay", .{ .scalar = 0.2 });
    graph.processBlock(&buf, 1, 1);
    try std.testing.expect(hat_k != graph.ptrOf(.hat, hat).amp_k);

    const perc_k = graph.ptrOf(.perc_env, perc).k;
    try setParam(graph, perc, "decay", .{ .scalar = 0.5 });
    graph.processBlock(&buf, 1, 1);
    try std.testing.expect(perc_k != graph.ptrOf(.perc_env, perc).k);

    const clap_k = graph.ptrOf(.clap, clap).amp_k;
    try setParam(graph, clap, "decay", .{ .scalar = 0.5 });
    graph.processBlock(&buf, 1, 1);
    try std.testing.expect(clap_k != graph.ptrOf(.clap, clap).amp_k);

    const chord_freq = graph.ptrOf(.chord_pad, chord).freqs[0];
    try setParam(graph, chord, "base_hz", .{ .scalar = 220.0 });
    graph.processBlock(&buf, 1, 1);
    try std.testing.expect(chord_freq != graph.ptrOf(.chord_pad, chord).freqs[0]);

    const feedback = graph.ptrOf(.reverb, reverb).rev.feedback;
    try setParam(graph, reverb, "decay", .{ .scalar = 0.9 });
    graph.processBlock(&buf, 1, 1);
    try std.testing.expect(feedback != graph.ptrOf(.reverb, reverb).rev.feedback);

    const sidechain_k = graph.ptrOf(.sidechain, sidechain).k;
    try setParam(graph, sidechain, "release", .{ .scalar = 0.5 });
    graph.processBlock(&buf, 1, 1);
    try std.testing.expect(sidechain_k != graph.ptrOf(.sidechain, sidechain).k);
}

test "params: same-value writes keep all applied dirty keys stable" {
    var graph = try dyn.DynGraph.create(std.testing.allocator, 48000);
    defer graph.destroy();
    const kick = try graph.add(.kick, .{});
    const hat = try graph.add(.hat, .{});
    const perc = try graph.add(.perc_env, .{});
    const clap = try graph.add(.clap, .{});
    const chord = try graph.add(.chord_pad, .{});
    const reverb = try graph.add(.reverb, .{});
    const sidechain = try graph.add(.sidechain, .{});
    try graph.publish();

    var buf: [1]f32 = undefined;
    graph.processBlock(&buf, 1, 1);
    const kick_applied = .{
        graph.ptrOf(.kick, kick).applied_sr,
        graph.ptrOf(.kick, kick).applied_amp_decay,
        graph.ptrOf(.kick, kick).applied_pitch_decay,
        graph.ptrOf(.kick, kick).applied_click_decay,
        graph.ptrOf(.kick, kick).applied_click_cutoff,
    };
    const hat_applied = .{
        graph.ptrOf(.hat, hat).coeffs_sr,
        graph.ptrOf(.hat, hat).applied_bright,
        graph.ptrOf(.hat, hat).applied_decay,
        graph.ptrOf(.hat, hat).applied_hp_cutoff,
        graph.ptrOf(.hat, hat).applied_bp_cutoff,
        graph.ptrOf(.hat, hat).applied_bp_q,
    };
    const perc_applied = .{ graph.ptrOf(.perc_env, perc).applied_sr, graph.ptrOf(.perc_env, perc).applied_decay };
    const clap_applied = .{
        graph.ptrOf(.clap, clap).coeffs_sr,
        graph.ptrOf(.clap, clap).applied_decay,
        graph.ptrOf(.clap, clap).applied_hp_cutoff,
        graph.ptrOf(.clap, clap).applied_bp_cutoff,
        graph.ptrOf(.clap, clap).applied_bp_q,
    };
    const chord_applied = .{
        graph.ptrOf(.chord_pad, chord).applied_sr,
        graph.ptrOf(.chord_pad, chord).applied_base_hz,
        graph.ptrOf(.chord_pad, chord).applied_detune,
        graph.ptrOf(.chord_pad, chord).applied_cutoff,
        graph.ptrOf(.chord_pad, chord).applied_attack,
        graph.ptrOf(.chord_pad, chord).applied_release,
        graph.ptrOf(.chord_pad, chord).applied_warmth,
    };
    const reverb_applied = .{ graph.ptrOf(.reverb, reverb).applied_decay, graph.ptrOf(.reverb, reverb).applied_damping };
    const sidechain_applied = .{ graph.ptrOf(.sidechain, sidechain).applied_sr, graph.ptrOf(.sidechain, sidechain).applied_release };

    try setParam(graph, kick, "amp_decay", .{ .scalar = 0.28 });
    try setParam(graph, hat, "decay", .{ .scalar = 0.045 });
    try setParam(graph, perc, "decay", .{ .scalar = 0.18 });
    try setParam(graph, clap, "decay", .{ .scalar = 0.12 });
    try setParam(graph, chord, "base_hz", .{ .scalar = 130.81 });
    try setParam(graph, reverb, "decay", .{ .scalar = 0.6 });
    try setParam(graph, sidechain, "release", .{ .scalar = 0.18 });
    graph.processBlock(&buf, 1, 1);

    try std.testing.expectEqual(kick_applied, .{
        graph.ptrOf(.kick, kick).applied_sr,
        graph.ptrOf(.kick, kick).applied_amp_decay,
        graph.ptrOf(.kick, kick).applied_pitch_decay,
        graph.ptrOf(.kick, kick).applied_click_decay,
        graph.ptrOf(.kick, kick).applied_click_cutoff,
    });
    try std.testing.expectEqual(hat_applied, .{
        graph.ptrOf(.hat, hat).coeffs_sr,
        graph.ptrOf(.hat, hat).applied_bright,
        graph.ptrOf(.hat, hat).applied_decay,
        graph.ptrOf(.hat, hat).applied_hp_cutoff,
        graph.ptrOf(.hat, hat).applied_bp_cutoff,
        graph.ptrOf(.hat, hat).applied_bp_q,
    });
    try std.testing.expectEqual(perc_applied, .{ graph.ptrOf(.perc_env, perc).applied_sr, graph.ptrOf(.perc_env, perc).applied_decay });
    try std.testing.expectEqual(clap_applied, .{
        graph.ptrOf(.clap, clap).coeffs_sr,
        graph.ptrOf(.clap, clap).applied_decay,
        graph.ptrOf(.clap, clap).applied_hp_cutoff,
        graph.ptrOf(.clap, clap).applied_bp_cutoff,
        graph.ptrOf(.clap, clap).applied_bp_q,
    });
    try std.testing.expectEqual(chord_applied, .{
        graph.ptrOf(.chord_pad, chord).applied_sr,
        graph.ptrOf(.chord_pad, chord).applied_base_hz,
        graph.ptrOf(.chord_pad, chord).applied_detune,
        graph.ptrOf(.chord_pad, chord).applied_cutoff,
        graph.ptrOf(.chord_pad, chord).applied_attack,
        graph.ptrOf(.chord_pad, chord).applied_release,
        graph.ptrOf(.chord_pad, chord).applied_warmth,
    });
    try std.testing.expectEqual(reverb_applied, .{ graph.ptrOf(.reverb, reverb).applied_decay, graph.ptrOf(.reverb, reverb).applied_damping });
    try std.testing.expectEqual(sidechain_applied, .{ graph.ptrOf(.sidechain, sidechain).applied_sr, graph.ptrOf(.sidechain, sidechain).applied_release });
}
