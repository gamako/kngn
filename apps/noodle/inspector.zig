//! Parameter inspector for the selected DynGraph primitive node.
//!
//! Hot-path declaration: descriptor enumeration and slider/radio evaluation run at frame-rate (main thread); the change callback
//! runs only on interaction (event-rate). Only passes the callback's fixed-length Mailbox publish to RT;
//! this file never calls `params.setParam()` directly.
//! PanelHost owns the outer shape/header/open; only the body is built here.
//!
//! On group selection: an internal primitive list → member drill-down. choice is a set of radioIds.

const std = @import("std");
const kit = @import("kit");
const gui = kit.gui;
const modular = @import("modular");
const canvas = @import("canvas.zig");
const view = @import("param_view.zig");

pub const ChangeFn = *const fn (ctx: *anyopaque, handle: modular.dyn.Handle, name: []const u8, value: modular.ParamValue) void;
pub const DisplayFn = *const fn (ctx: *anyopaque, key: view.FieldKey, snapshot: view.ParamSnapshot) modular.ParamValue;
pub const SnapshotFn = *const fn (ctx: *anyopaque, handle: modular.dyn.Handle, name: []const u8) ?view.ParamSnapshot;
pub const MemberSelectFn = *const fn (ctx: *anyopaque, handle: modular.dyn.Handle) void;

const SUBTLE = gui.Color.rgba(0x9A, 0xA4, 0xB0, 0xFF);
const TITLE = gui.Color.rgba(0xE0, 0xE6, 0xEE, 0xFF);

/// One row of the group member list (the caller enumerates it into a fixed buffer; no per-frame alloc).
pub const MemberInfo = struct {
    handle: modular.dyn.Handle,
    kind_name: []const u8,
};

/// The view the Inspector draws. main assembles it from canvas selected and inspector_target.
pub const View = union(enum) {
    empty,
    /// Group selected but no target selected: the member list.
    group_members: struct {
        group_name: []const u8,
        members: []const MemberInfo,
    },
    /// After selecting a primitive or drilling into a group: the descriptor of the actual handle.
    params: modular.dyn.Handle,
};

pub fn paramId(ctx: *const gui.Context, handle: modular.dyn.Handle, index: usize) gui.Id {
    const key = (@as(u64, handle) << 32) | @as(u64, @intCast(index + 1));
    return ctx.id_stack.makeInt(key);
}

/// For choice radios. Avoids collisions via handle + descriptor index + option index.
pub fn paramOptionId(ctx: *const gui.Context, handle: modular.dyn.Handle, desc_index: usize, option_index: usize) gui.Id {
    // The high byte 0xC0 separates the namespace from paramId (slider).
    const key = (@as(u64, 0xC0) << 56) | (@as(u64, handle) << 40) | (@as(u64, @intCast(desc_index & 0xFF)) << 16) | @as(u64, @intCast(option_index & 0xFFFF));
    return ctx.id_stack.makeInt(key);
}

/// ID for the member-selection button (0xB0 namespace, distinct from paramId / paramOptionId).
pub fn memberButtonId(ctx: *const gui.Context, handle: modular.dyn.Handle) gui.Id {
    const key = (@as(u64, 0xB0) << 56) | (@as(u64, handle) << 32) | 1;
    return ctx.id_stack.makeInt(key);
}

fn labelWithUnit(buf: []u8, name: []const u8, unit: []const u8) []const u8 {
    if (unit.len == 0) return name;
    return std.fmt.bufPrint(buf, "{s} ({s})", .{ name, unit }) catch name;
}

/// Turns Mixer's `inX_gain` / `inX_mute` into a display name with `input_labels[X]`. Frame-local buf, no alloc.
/// null for anything other than canonical names / non-Mixer (the caller falls back to the descriptor name).
fn mixerParamDisplayName(buf: []u8, mixer: *const modular.Mixer, name: []const u8) ?[]const u8 {
    // "in0_gain" / "in0_mute" (length 8)
    if (name.len != 8) return null;
    if (name[0] != 'i' or name[1] != 'n') return null;
    if (name[2] < '0' or name[2] > '3') return null;
    const slot: usize = @intCast(name[2] - '0');
    const label = mixer.input_labels[slot];
    if (std.mem.eql(u8, name[3..], "_gain")) {
        return std.fmt.bufPrint(buf, "{s} gain", .{label}) catch null;
    }
    if (std.mem.eql(u8, name[3..], "_mute")) {
        return std.fmt.bufPrint(buf, "{s} mute", .{label}) catch null;
    }
    return null;
}

/// descriptor canonical name → Inspector display name. set_param/NPRM always use the canonical form.
fn paramDisplayName(buf: []u8, graph: *const modular.DynGraph, kind: modular.ModuleKind, h: modular.dyn.Handle, name: []const u8) []const u8 {
    if (kind == .mixer) {
        if (mixerParamDisplayName(buf, graph.ptrOfConst(.mixer, h), name)) |display| return display;
    }
    return name;
}

/// Fits into the given pixel width while preserving BitmapFont codepoint boundaries.
fn truncateLabel(label: []const u8, max_w: i32, font: gui.Font) []const u8 {
    if (max_w <= 0) return "";
    if (font.measure(label) <= @as(u32, @intCast(max_w))) return label;

    var end: usize = 0;
    while (end < label.len) {
        const cp_len: usize = std.unicode.utf8ByteSequenceLength(label[end]) catch 1;
        if (end + cp_len > label.len) break;
        if (font.measure(label[0 .. end + cp_len]) > @as(u32, @intCast(max_w))) break;
        end += cp_len;
    }
    return label[0..end];
}

fn paramLabel(ctx: *const gui.Context, label: []const u8, avail: i32) []const u8 {
    const label_w: i32 = @intCast(ctx.font.measure(label));
    const row = canvas.inspectorParamRowLayout(avail, label_w);
    return truncateLabel(label, row.label_w, ctx.font);
}

fn trackWidthWithRightAlignedValue(row: canvas.ParamRowLayout, value_text_w: i32) i32 {
    return row.track_w + @max(0, row.value_w - value_text_w);
}

fn drawParams(
    ctx: *gui.Context,
    graph: *const modular.DynGraph,
    h: modular.dyn.Handle,
    avail: i32,
    snapshot_ctx: *anyopaque,
    snapshot: SnapshotFn,
    display_ctx: *anyopaque,
    display: DisplayFn,
    callback_ctx: *anyopaque,
    on_change: ChangeFn,
) void {
    const kind = graph.kindOf(h) orelse {
        ctx.labelEx("Select a primitive node", SUBTLE);
        return;
    };
    ctx.labelEx(@tagName(kind), SUBTLE);

    const descs = switch (kind) {
        inline else => |comptime_kind| modular.descriptors(comptime_kind),
    };
    if (descs.len == 0) {
        ctx.labelEx("No editable parameters", SUBTLE);
        return;
    }
    for (descs, 0..) |desc, index| {
        const snapshot_raw = snapshot(snapshot_ctx, h, desc.name) orelse continue;
        const key = view.fieldKey(h, desc.name);
        const value = display(display_ctx, key, .{
            .field = snapshot_raw.field,
            .instant = snapshot_raw.instant,
            .has_instant = snapshot_raw.has_instant,
        });
        switch (desc.kind) {
            .scalar => |s| {
                const raw = switch (value) {
                    .scalar => |v| v,
                    .choice => continue,
                };
                var current = raw;
                var name_buf: [64]u8 = undefined;
                const display_name = paramDisplayName(&name_buf, graph, kind, h, desc.name);
                var label_buf: [96]u8 = undefined;
                const label = labelWithUnit(&label_buf, display_name, s.unit);
                const row = canvas.inspectorParamRowLayout(avail, @intCast(ctx.font.measure(label)));
                const visible_label = paramLabel(ctx, label, avail);
                var value_buf: [32]u8 = undefined;
                const value_text = std.fmt.bufPrint(&value_buf, "{d:.2}", .{current}) catch "?";
                const changed = ctx.sliderF32Id(paramId(ctx, h, index), visible_label, &current, .{
                    .min = s.min,
                    .max = s.max,
                    .step = s.step,
                    .track_w = trackWidthWithRightAlignedValue(row, @intCast(ctx.font.measure(value_text))),
                });
                if (changed) on_change(callback_ctx, h, desc.name, .{ .scalar = current });
            },
            .choice => |c| {
                const raw = switch (value) {
                    .choice => |v| v,
                    .scalar => continue,
                };
                const current: usize = @min(raw, c.options.len -| 1);
                var name_buf: [64]u8 = undefined;
                const display_name = paramDisplayName(&name_buf, graph, kind, h, desc.name);
                // Parameter name label plus one radio per option (inside a .fixed-width column).
                ctx.beginBox(.{
                    .direction = .column,
                    .width = .{ .fixed = @max(1, avail) },
                    .gap = 3,
                });
                ctx.labelEx(display_name, SUBTLE);
                ctx.beginBox(.{
                    .direction = .column,
                    .width = .{ .fixed = @max(1, avail) },
                    .gap = 2,
                });
                for (c.options, 0..) |opt, oi| {
                    const selected = oi == current;
                    if (ctx.radioId(paramOptionId(ctx, h, index, oi), opt, selected)) {
                        if (!selected) on_change(callback_ctx, h, desc.name, .{ .choice = oi });
                    }
                }
                ctx.endBox();
                ctx.endBox();
            },
        }
    }
}

fn drawGroupMembers(
    ctx: *gui.Context,
    group_name: []const u8,
    members: []const MemberInfo,
    avail: i32,
    member_ctx: *anyopaque,
    on_member: MemberSelectFn,
) void {
    ctx.labelEx(group_name, TITLE);
    ctx.labelEx("members (select to edit)", SUBTLE);
    if (members.len == 0) {
        ctx.labelEx("No active members", SUBTLE);
        return;
    }
    // The button row is .fixed width (avoids grow-in-fit).
    for (members) |m| {
        var label_buf: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "#{d} {s}", .{ m.handle, m.kind_name }) catch "member";
        const id = memberButtonId(ctx, m.handle);
        if (ctx.buttonId(id, label, .{ .min_w = @max(1, avail) }).clicked) {
            on_member(member_ctx, m.handle);
        }
    }
}

/// Only the body, called from the PanelHost callback.
/// `body_w` is the outer width from the panel rect. Collapsible body has width=.fit, so it's built with .fixed.
pub fn drawBody(
    ctx: *gui.Context,
    graph: *const modular.DynGraph,
    view_state: View,
    body_w: i32,
    snapshot_ctx: *anyopaque,
    snapshot: SnapshotFn,
    display_ctx: *anyopaque,
    display: DisplayFn,
    callback_ctx: *anyopaque,
    on_change: ChangeFn,
    member_ctx: *anyopaque,
    on_member: MemberSelectFn,
) void {
    const pad: i32 = 6;
    const outer_w = @max(1, body_w);
    const avail = @max(0, outer_w - pad * 2);

    ctx.beginBox(.{
        .direction = .column,
        .width = .{ .fixed = outer_w },
        .gap = 7,
        .padding = .{ pad, pad, pad, pad },
    });

    switch (view_state) {
        .empty => ctx.labelEx("Select a primitive node", SUBTLE),
        .group_members => |gm| drawGroupMembers(ctx, gm.group_name, gm.members, avail, member_ctx, on_member),
        .params => |h| drawParams(ctx, graph, h, avail, snapshot_ctx, snapshot, display_ctx, display, callback_ctx, on_change),
    }
    ctx.endBox();
}
