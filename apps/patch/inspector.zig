//! 選択中の DynGraph primitive node の parameter inspector。
//!
//! ホットパス宣言: descriptor 列挙と slider 評価は frame-rate（main thread）、変更 callback は
//! slider 操作時のみ（event-rate）。RT へは callback の固定長 Mailbox publish だけを渡し、
//! このファイルから `params.setParam()` を直接呼ばない。

const std = @import("std");
const kit = @import("kit");
const gui = kit.gui;
const modular = @import("modular");
const canvas = @import("canvas.zig");
const view = @import("param_view.zig");

pub const ChangeFn = *const fn (ctx: *anyopaque, handle: modular.dyn.Handle, name: []const u8, value: modular.ParamValue) void;
pub const DisplayFn = *const fn (ctx: *anyopaque, key: view.FieldKey, snapshot: view.ParamSnapshot) modular.ParamValue;
pub const SnapshotFn = *const fn (ctx: *anyopaque, handle: modular.dyn.Handle, name: []const u8) ?view.ParamSnapshot;

const PANEL_BG = gui.Color.rgba(0x1B, 0x21, 0x29, 0xFF);
const PANEL_BORDER = gui.Color.rgba(0x50, 0x58, 0x64, 0xFF);
const TITLE = gui.Color.rgba(0xE0, 0xE6, 0xEE, 0xFF);
const SUBTLE = gui.Color.rgba(0x9A, 0xA4, 0xB0, 0xFF);

pub fn paramId(ctx: *const gui.Context, handle: modular.dyn.Handle, index: usize) gui.Id {
    const key = (@as(u64, handle) << 32) | @as(u64, @intCast(index + 1));
    return ctx.id_stack.makeInt(key);
}

fn labelWithUnit(buf: []u8, name: []const u8, unit: []const u8) []const u8 {
    if (unit.len == 0) return name;
    return std.fmt.bufPrint(buf, "{s} ({s})", .{ name, unit }) catch name;
}

/// BitmapFont のコードポイント境界を保ったまま、指定 pixel 幅に収める。
/// descriptor 名と unit は ASCII だが、Font 契約に合わせて UTF-8 の境界で切る。
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
    // slider widget は値文字列を自然幅で置くため、予約値幅との差分を track へ戻す。
    // これにより実際の値文字列の終端が row の右端に揃う。
    return row.track_w + @max(0, row.value_w - value_text_w);
}

fn drawHeader(ctx: *gui.Context, panel_w: i32, open: *bool) void {
    const label = if (open.*) "[−] PARAM INSPECTOR" else "[+] PARAM INSPECTOR";
    const id = ctx.id_stack.makeInt(0x494E_5350_0000_0000);
    if (ctx.buttonId(id, label, .{ .min_w = @max(0, panel_w - 20) }).clicked) open.* = !open.*;
}

/// 右端 panel 本体を共有 GUI root の 1 子として登録し、選択 node の descriptor を slider 化する。
/// 呼び出し側が root の `beginBox/endBox`、`endFrame()`、draw list の render を行う。
pub fn drawPanel(
    ctx: *gui.Context,
    graph: *const modular.DynGraph,
    selected: ?modular.dyn.Handle,
    panel: gui.Rect,
    open: *bool,
    snapshot_ctx: *anyopaque,
    snapshot: SnapshotFn,
    display_ctx: *anyopaque,
    display: DisplayFn,
    callback_ctx: *anyopaque,
    on_change: ChangeFn,
) void {
    const panel_w: i32 = @intCast(panel.w);
    const panel_h: i32 = @intCast(panel.h);

    ctx.beginBox(.{
        .width = .{ .fixed = panel_w },
        .height = .{ .fixed = panel_h },
        .padding = .{ 10, 10, 10, 10 },
        .gap = 7,
        .bg = PANEL_BG,
        .border = .{ .color = PANEL_BORDER, .thickness = 1 },
        .clip_children = true,
    });
    const was_open = open.*;
    drawHeader(ctx, panel_w, open);
    if (!was_open) {
        ctx.endBox();
        return;
    }

    const h = selected orelse {
        ctx.labelEx("Select a primitive node", SUBTLE);
        ctx.endBox();
        return;
    };
    const kind = graph.kindOf(h) orelse {
        ctx.labelEx("Select a primitive node", SUBTLE);
        ctx.endBox();
        return;
    };
    ctx.labelEx(@tagName(kind), SUBTLE);

    // panel の fixed width から padding 左右を除いた content 幅。各 slider はこの
    // 幅を超えないよう、値列を先に予約してからラベルを切り詰める。
    const param_avail = @max(0, panel_w - 20);

    const descs = switch (kind) {
        inline else => |comptime_kind| modular.descriptors(comptime_kind),
    };
    if (descs.len == 0) {
        ctx.labelEx("No editable parameters", SUBTLE);
        ctx.endBox();
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
                const row = canvas.inspectorParamRowLayout(param_avail, @intCast(ctx.font.measure(label)));
                const visible_label = paramLabel(ctx, label, param_avail);
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
                var current: i32 = @intCast(@min(raw, c.options.len - 1));
                var label_buf: [96]u8 = undefined;
                const option = c.options[@intCast(current)];
                const label = std.fmt.bufPrint(&label_buf, "{s} [{s}]", .{ desc.name, option }) catch desc.name;
                const row = canvas.inspectorParamRowLayout(param_avail, @intCast(ctx.font.measure(label)));
                const visible_label = paramLabel(ctx, label, param_avail);
                var value_buf: [32]u8 = undefined;
                const value_text = std.fmt.bufPrint(&value_buf, "{d}", .{@as(i64, current)}) catch "?";
                const changed = ctx.sliderI32Id(paramId(ctx, h, index), visible_label, &current, .{
                    .min = 0,
                    .max = @intCast(c.options.len - 1),
                    .step = 1,
                    .track_w = trackWidthWithRightAlignedValue(row, @intCast(ctx.font.measure(value_text))),
                });
                if (changed) on_change(callback_ctx, h, desc.name, .{ .choice = @intCast(current) });
            },
        }
    }
    ctx.endBox();
}

/// 旧 caller 向けの単独 root wrapper。統合 app は `drawPanel` を共有 root から呼ぶ。
pub fn draw(
    ctx: *gui.Context,
    graph: *const modular.DynGraph,
    selected: ?modular.dyn.Handle,
    panel: gui.Rect,
    open: *bool,
    snapshot_ctx: *anyopaque,
    snapshot: SnapshotFn,
    display_ctx: *anyopaque,
    display: DisplayFn,
    callback_ctx: *anyopaque,
    on_change: ChangeFn,
) void {
    ctx.beginBox(.{ .direction = .row, .width = .{ .fixed = @intCast(ctx.screen_w) }, .height = .{ .fixed = @intCast(ctx.screen_h) } });
    ctx.beginBox(.{ .width = .{ .fixed = @max(0, panel.x) }, .height = .{ .fixed = @intCast(panel.h) } });
    ctx.endBox();
    drawPanel(ctx, graph, selected, panel, open, snapshot_ctx, snapshot, display_ctx, display, callback_ctx, on_change);
    ctx.endBox();
}
