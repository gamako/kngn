//! 選択中の DynGraph primitive node の parameter inspector。
//!
//! ホットパス宣言: descriptor 列挙と slider/radio 評価は frame-rate（main thread）、変更 callback は
//! 操作時のみ（event-rate）。RT へは callback の固定長 Mailbox publish だけを渡し、
//! このファイルから `params.setParam()` を直接呼ばない。
//! 外形・header・open は PanelHost が所有し、ここでは body のみを構築する（TASK-149.1）。
//!
//! TASK-149.2: group 選択時は内部 primitive 一覧 → member drill-down。choice は radioId 群。

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

/// group member 一覧の 1 行（呼び出し側が固定バッファで列挙。毎フレーム alloc なし）。
pub const MemberInfo = struct {
    handle: modular.dyn.Handle,
    kind_name: []const u8,
};

/// Inspector が描画する view。canvas selected と inspector_target から main が組み立てる。
pub const View = union(enum) {
    empty,
    /// group 選択かつ target 未選択: member 一覧。
    group_members: struct {
        group_name: []const u8,
        members: []const MemberInfo,
    },
    /// primitive または group drill-down 後: 実 handle の descriptor。
    params: modular.dyn.Handle,
};

pub fn paramId(ctx: *const gui.Context, handle: modular.dyn.Handle, index: usize) gui.Id {
    const key = (@as(u64, handle) << 32) | @as(u64, @intCast(index + 1));
    return ctx.id_stack.makeInt(key);
}

/// choice radio 用。handle + descriptor index + option index で衝突回避。
pub fn paramOptionId(ctx: *const gui.Context, handle: modular.dyn.Handle, desc_index: usize, option_index: usize) gui.Id {
    // 上位バイト 0xC0 で paramId（slider）と名前空間分離。
    const key = (@as(u64, 0xC0) << 56) | (@as(u64, handle) << 40) | (@as(u64, @intCast(desc_index & 0xFF)) << 16) | @as(u64, @intCast(option_index & 0xFFFF));
    return ctx.id_stack.makeInt(key);
}

/// member 選択 button 用 ID（paramId / paramOptionId と衝突しない 0xB0 名前空間）。
pub fn memberButtonId(ctx: *const gui.Context, handle: modular.dyn.Handle) gui.Id {
    const key = (@as(u64, 0xB0) << 56) | (@as(u64, handle) << 32) | 1;
    return ctx.id_stack.makeInt(key);
}

fn labelWithUnit(buf: []u8, name: []const u8, unit: []const u8) []const u8 {
    if (unit.len == 0) return name;
    return std.fmt.bufPrint(buf, "{s} ({s})", .{ name, unit }) catch name;
}

/// BitmapFont のコードポイント境界を保ったまま、指定 pixel 幅に収める。
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
                var label_buf: [96]u8 = undefined;
                const label = labelWithUnit(&label_buf, desc.name, s.unit);
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
                // パラメータ名ラベル + option ごとの radio（.fixed 幅の column 内）。
                ctx.beginBox(.{
                    .direction = .column,
                    .width = .{ .fixed = @max(1, avail) },
                    .gap = 3,
                });
                ctx.labelEx(desc.name, SUBTLE);
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
    // button 行は .fixed 幅（grow-in-fit 回避）。
    for (members) |m| {
        var label_buf: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "#{d} {s}", .{ m.handle, m.kind_name }) catch "member";
        const id = memberButtonId(ctx, m.handle);
        if (ctx.buttonId(id, label, .{ .min_w = @max(1, avail) }).clicked) {
            on_member(member_ctx, m.handle);
        }
    }
}

/// PanelHost callback から呼ばれる body のみ。
/// `body_w` は panel rect 由来の外側幅。Collapsible body は width=.fit のため .fixed で構築する。
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
