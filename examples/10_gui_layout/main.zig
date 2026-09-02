// example_10: layout catalog
//
// Observes layout resolution as the container width changes. Each item is
// title + specimen + resolved numbers (child widths, wrap line membership,
// leftover, visible range). The width slider and harness action
// `layout_width <px>` set the specimen width. Window resize only changes the
// viewport and scroll; it does not change specimen width.
// `digest layout` exposes the same figures for harness `expect`.
//
// Readouts and `digest layout` read the previous-frame rect cache
// (`getNodeRect`), the same contract as widget hit-test. A width change
// therefore shows new specimens on this frame and matching numbers on the
// next. Slider drag follows one frame behind. `layout_width` needs at least
// two presented frames (`step 2`) before digest/snapshot match the specimen.
// An empty cache (the first frame) prints `--` instead of -1/0.
//
// Hot path declaration: build, layout, and number formatting run every frame
// on the GUI path (DrawList appends only, not a per-pixel loop). Slider
// writes are event-only. Does not touch the real-time audio path.

const std = @import("std");
const kit = @import("kit");
const platform = kit.platform;
const gui = kit.gui;

const WINDOW_W: u32 = 1024;
const WINDOW_H: u32 = 768;
const WIDTH_MIN: i32 = 120;
const WIDTH_MAX: i32 = 1000;
const WIDTH_DEFAULT: i32 = 640;

const VIRT_COUNT: usize = 60;
const VIRT_ROW_H: i32 = 16;
const VIRT_VP_H: i32 = 80;
const VIRT_OVERSCAN: u16 = 1;

const CHIP_H: i32 = 20;
const ROW_H: i32 = 22;
const GAP: i32 = 4;
/// Cross-axis gap on the wrap specimen that demonstrates `cross_gap` ≠ `gap`.
const WRAP_CROSS_GAP: i32 = 12;

const Ids = struct {
    const width_slider: gui.Id = 0x0A10_0001;
    const catalog_scroll: gui.Id = 0x0A10_0002;

    const mix_row: gui.Id = 0x0A10_0100;
    const mix_fixed: gui.Id = 0x0A10_0101;
    const mix_fit: gui.Id = 0x0A10_0102;
    const mix_grow: gui.Id = 0x0A10_0103;
    const mix_pct: gui.Id = 0x0A10_0104;

    const clamp_row: gui.Id = 0x0A10_0200;
    const clamp_free: gui.Id = 0x0A10_0201;
    const clamp_min: gui.Id = 0x0A10_0202;
    const clamp_max: gui.Id = 0x0A10_0203;
    const clamp_w0: gui.Id = 0x0A10_0204;

    const left_row: gui.Id = 0x0A10_0300;
    const left_a: gui.Id = 0x0A10_0301;
    const left_b: gui.Id = 0x0A10_0302;
    const left_c: gui.Id = 0x0A10_0303;

    const am_start: gui.Id = 0x0A10_0350;
    const am_start_a: gui.Id = 0x0A10_0351;
    const am_center: gui.Id = 0x0A10_0360;
    const am_center_a: gui.Id = 0x0A10_0361;
    const am_end: gui.Id = 0x0A10_0370;
    const am_end_a: gui.Id = 0x0A10_0371;
    const am_grow: gui.Id = 0x0A10_0380;
    const am_grow_a: gui.Id = 0x0A10_0381;
    const am_grow_g: gui.Id = 0x0A10_0382;

    const wrap_row: gui.Id = 0x0A10_0400;
    const wrap_a: gui.Id = 0x0A10_0401;
    const wrap_b: gui.Id = 0x0A10_0402;
    const wrap_c: gui.Id = 0x0A10_0403;
    const wrap_d: gui.Id = 0x0A10_0404;
    const wrap_e: gui.Id = 0x0A10_0405;
    const wrap_f: gui.Id = 0x0A10_0406;
    const wrap_gap_row: gui.Id = 0x0A10_0410;
    const wrap_gap_0: gui.Id = 0x0A10_0411;
    const wrap_gap_1: gui.Id = 0x0A10_0412;
    const wrap_gap_2: gui.Id = 0x0A10_0413;
    const wrap_gap_3: gui.Id = 0x0A10_0414;

    const xgrow_row: gui.Id = 0x0A10_0500;
    const xgrow_a: gui.Id = 0x0A10_0501;
    const xgrow_g0: gui.Id = 0x0A10_0502;
    const xgrow_b: gui.Id = 0x0A10_0503;
    const xgrow_g1: gui.Id = 0x0A10_0504;

    const pos_plain: gui.Id = 0x0A10_0600;
    const pos_ovl: gui.Id = 0x0A10_0601;
    const pos_badge: gui.Id = 0x0A10_0602;
    const pos_wplain: gui.Id = 0x0A10_0610;
    const pos_wplain_0: gui.Id = 0x0A10_0611;
    const pos_wplain_1: gui.Id = 0x0A10_0612;
    const pos_wplain_2: gui.Id = 0x0A10_0613;
    const pos_wplain_3: gui.Id = 0x0A10_0614;
    const pos_wovl: gui.Id = 0x0A10_0620;
    const pos_wovl_0: gui.Id = 0x0A10_0621;
    const pos_wovl_1: gui.Id = 0x0A10_0622;
    const pos_wovl_2: gui.Id = 0x0A10_0623;
    const pos_wovl_3: gui.Id = 0x0A10_0624;

    const ext_vp: gui.Id = 0x0A10_0700;
    const ext_inner: gui.Id = 0x0A10_0701;
    const ext_card0: gui.Id = 0x0A10_0710;

    const table: gui.Id = 0x0A10_0800;
    const tbl_fixed: gui.Id = 0x0A10_0801;
    const tbl_fit: gui.Id = 0x0A10_0802;
    const tbl_grow: gui.Id = 0x0A10_0803;

    const virt: gui.Id = 0x0A10_0900;
    const virt_row0: gui.Id = 0x0A10_8000;
};

const Col = struct {
    fn rgba(r: u8, g: u8, b: u8) gui.Color {
        return gui.Color.rgba(r, g, b, 0xFF);
    }

    const bg = rgba(0x18, 0x18, 0x1C);
    const panel = rgba(0x20, 0x24, 0x2C);
    const bar = rgba(0x28, 0x28, 0x30);
    const row = rgba(0x16, 0x18, 0x1E);
    const fixed = rgba(0x2C, 0x4A, 0x72);
    const fit = rgba(0x2C, 0x5A, 0x3C);
    const grow = rgba(0x7A, 0x4A, 0x20);
    const pct = rgba(0x5A, 0x38, 0x6C);
    const minc = rgba(0x1E, 0x5A, 0x58);
    const maxc = rgba(0x6C, 0x2C, 0x2C);
    const w0 = rgba(0x4A, 0x4A, 0x28);
    const tall = rgba(0x3A, 0x28, 0x18);
    const line0 = rgba(0x24, 0x48, 0x48);
    const line1 = rgba(0x48, 0x34, 0x1C);
    const badge = rgba(0xC0, 0x40, 0x40);
    const even = rgba(0x24, 0x28, 0x30);
    const odd = rgba(0x1C, 0x20, 0x26);
};

const App = struct {
    ctx: *gui.Context,
    catalog_width: i32 = WIDTH_DEFAULT,
    catalog_scroll: gui.Vec2f = .{},
    extent_scroll: gui.Vec2f = .{},
    virt_scroll: gui.Vec2f = .{},
    virt_range: gui.VirtualRange = .{},
};

fn nodeW(ctx: *const gui.Context, id: gui.Id) i32 {
    const r = ctx.getNodeRect(id) orelse return -1;
    return @intCast(r.w);
}

fn nodeH(ctx: *const gui.Context, id: gui.Id) i32 {
    const r = ctx.getNodeRect(id) orelse return -1;
    return @intCast(r.h);
}

fn nodeX(ctx: *const gui.Context, id: gui.Id) i32 {
    const r = ctx.getNodeRect(id) orelse return -1;
    return r.x;
}

fn nodeY(ctx: *const gui.Context, id: gui.Id) i32 {
    const r = ctx.getNodeRect(id) orelse return -1;
    return r.y;
}

fn allCached(ctx: *const gui.Context, ids: []const gui.Id) bool {
    for (ids) |id| {
        if (ctx.getNodeRect(id) == null) return false;
    }
    return true;
}

fn appendFmt(buf: []u8, off: *usize, comptime fmt: []const u8, args: anytype) void {
    if (off.* >= buf.len) return;
    const written = std.fmt.bufPrint(buf[off.*..], fmt, args) catch {
        off.* = buf.len;
        return;
    };
    off.* += written.len;
}

/// Format a readout on a stack buffer and hand it to `ctx.text` (one arena
/// dupe inside `text`). Per-frame GUI path; not a per-pixel loop; not RT.
fn emitReadout(ctx: *gui.Context, ready: bool, comptime fmt: []const u8, args: anytype) void {
    if (!ready) {
        ctx.text("--", .{ .wrap = true, .color = ctx.style.text_subtle });
        return;
    }
    var buf: [192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    ctx.text(s, .{ .wrap = true, .color = ctx.style.text_subtle });
}

fn beginItem(ctx: *gui.Context, title: []const u8, width: i32) void {
    ctx.beginBox(.{ .direction = .column, .width = .{ .fixed = width }, .gap = 3 });
    ctx.labelStyled(title, .title);
}

fn endItem(ctx: *gui.Context, ready: bool, comptime fmt: []const u8, args: anytype) void {
    emitReadout(ctx, ready, fmt, args);
    ctx.endBox();
}

fn chip(ctx: *gui.Context, id: gui.Id, label: []const u8, width: gui.Sizing, bg: gui.Color) void {
    chipEx(ctx, id, label, width, .{ .fixed = CHIP_H }, 0, std.math.maxInt(i32), bg, null);
}

fn chipEx(
    ctx: *gui.Context,
    id: gui.Id,
    label: []const u8,
    width: gui.Sizing,
    height: gui.Sizing,
    min_width: i32,
    max_width: i32,
    bg: gui.Color,
    position: ?gui.Position,
) void {
    ctx.beginBox(.{
        .id = id,
        .width = width,
        .height = height,
        .min_width = min_width,
        .max_width = max_width,
        .position = position,
        .padding = .{ 2, 4, 2, 4 },
        .bg = bg,
    });
    ctx.label(label);
    ctx.endBox();
}

/// Group explicit-id children by placed y. Per-frame GUI path (small N).
/// `counts` and `ys` share an index: `ys[i]` is the settled y of line i.
fn wrapLines(ctx: *const gui.Context, ids: []const gui.Id, counts: []u8, ys: []i32) u8 {
    var n: u8 = 0;
    @memset(counts, 0);
    for (ys) |*y| y.* = -1;
    for (ids) |id| {
        const r = ctx.getNodeRect(id) orelse continue;
        var found: ?u8 = null;
        for (ys[0..n], 0..) |ly, i| {
            if (ly == r.y) {
                found = @intCast(i);
                break;
            }
        }
        if (found) |i| {
            counts[i] += 1;
        } else if (n < counts.len and n < ys.len) {
            ys[n] = r.y;
            counts[n] = 1;
            n += 1;
        }
    }
    return n;
}

fn leftoverOf(ctx: *const gui.Context, row: gui.Id, kids: []const gui.Id, gap: i32) i32 {
    const row_w = nodeW(ctx, row);
    if (row_w < 0) return -1;
    var sum: i32 = 0;
    var n: i32 = 0;
    for (kids) |id| {
        const w = nodeW(ctx, id);
        if (w < 0) return -1;
        sum += w;
        n += 1;
    }
    const gaps = if (n > 1) (n - 1) * gap else 0;
    return row_w - sum - gaps;
}

fn itemMixed(ctx: *gui.Context, width: i32) void {
    beginItem(ctx, "1. mixed sizing", width);
    ctx.beginBox(.{
        .id = Ids.mix_row,
        .direction = .row,
        .width = .{ .fixed = width },
        .height = .{ .fixed = ROW_H },
        .gap = GAP,
        .bg = Col.row,
    });
    chip(ctx, Ids.mix_fixed, "fix", .{ .fixed = 64 }, Col.fixed);
    chip(ctx, Ids.mix_fit, "fit", .fit, Col.fit);
    chip(ctx, Ids.mix_grow, "grow", .{ .grow = 1 }, Col.grow);
    chip(ctx, Ids.mix_pct, "25%", .{ .percent = 0.25 }, Col.pct);
    ctx.endBox();
    const ids = [_]gui.Id{ Ids.mix_fixed, Ids.mix_fit, Ids.mix_grow, Ids.mix_pct };
    endItem(ctx, allCached(ctx, &ids), "fixed={d} fit={d} grow={d} pct={d}", .{
        nodeW(ctx, Ids.mix_fixed),
        nodeW(ctx, Ids.mix_fit),
        nodeW(ctx, Ids.mix_grow),
        nodeW(ctx, Ids.mix_pct),
    });
}

fn itemClamp(ctx: *gui.Context, width: i32) void {
    beginItem(ctx, "2. min/max clamp", width);
    ctx.beginBox(.{
        .id = Ids.clamp_row,
        .direction = .row,
        .width = .{ .fixed = width },
        .height = .{ .fixed = ROW_H },
        .gap = GAP,
        .bg = Col.row,
    });
    chipEx(ctx, Ids.clamp_free, "g", .{ .grow = 1 }, .{ .fixed = CHIP_H }, 0, std.math.maxInt(i32), Col.grow, null);
    chipEx(ctx, Ids.clamp_min, "min80", .{ .grow = 1 }, .{ .fixed = CHIP_H }, 80, std.math.maxInt(i32), Col.minc, null);
    chipEx(ctx, Ids.clamp_max, "max60", .{ .grow = 1 }, .{ .fixed = CHIP_H }, 0, 60, Col.maxc, null);
    chipEx(ctx, Ids.clamp_w0, "w0", .{ .grow = 0 }, .{ .fixed = CHIP_H }, 40, std.math.maxInt(i32), Col.w0, null);
    ctx.endBox();
    const ids = [_]gui.Id{ Ids.clamp_free, Ids.clamp_min, Ids.clamp_max, Ids.clamp_w0 };
    endItem(ctx, allCached(ctx, &ids), "free={d} min80={d} max60={d} w0min40={d}", .{
        nodeW(ctx, Ids.clamp_free),
        nodeW(ctx, Ids.clamp_min),
        nodeW(ctx, Ids.clamp_max),
        nodeW(ctx, Ids.clamp_w0),
    });
}

fn itemLeftover(ctx: *gui.Context, width: i32) void {
    beginItem(ctx, "3. leftover", width);
    ctx.beginBox(.{
        .id = Ids.left_row,
        .direction = .row,
        .width = .{ .fixed = width },
        .height = .{ .fixed = ROW_H },
        .gap = 8,
        .bg = Col.row,
    });
    chipEx(ctx, Ids.left_a, "max80", .{ .grow = 1 }, .{ .fixed = CHIP_H }, 0, 80, Col.maxc, null);
    chipEx(ctx, Ids.left_b, "max80", .{ .grow = 1 }, .{ .fixed = CHIP_H }, 0, 80, Col.maxc, null);
    chipEx(ctx, Ids.left_c, "max80", .{ .grow = 1 }, .{ .fixed = CHIP_H }, 0, 80, Col.maxc, null);
    ctx.endBox();
    const kids = [_]gui.Id{ Ids.left_a, Ids.left_b, Ids.left_c };
    endItem(ctx, allCached(ctx, &kids), "a={d} b={d} c={d} leftover={d}", .{
        nodeW(ctx, Ids.left_a),
        nodeW(ctx, Ids.left_b),
        nodeW(ctx, Ids.left_c),
        leftoverOf(ctx, Ids.left_row, &kids, 8),
    });
}

/// x of an explicit-id child relative to its row, so the readout does not move with the
/// catalog's own position. -1 while either rect is still uncached (first frame).
fn relX(ctx: *const gui.Context, row: gui.Id, child: gui.Id) i32 {
    const rx = nodeX(ctx, row);
    const cx = nodeX(ctx, child);
    if (rx < 0 or cx < 0) return -1;
    return cx - rx;
}

fn alignRow(ctx: *gui.Context, row_id: gui.Id, first_id: gui.Id, width: i32, alignment: gui.Align, label: []const u8) void {
    ctx.beginBox(.{
        .id = row_id,
        .direction = .row,
        .width = .{ .fixed = width },
        .height = .{ .fixed = ROW_H },
        .gap = GAP,
        .align_main = alignment,
        .bg = Col.row,
    });
    chip(ctx, first_id, label, .{ .fixed = 60 }, Col.fixed);
    chip(ctx, 0, label, .{ .fixed = 60 }, Col.fit);
    ctx.endBox();
}

fn itemAlignMain(ctx: *gui.Context, width: i32) void {
    beginItem(ctx, "4. align_main", width);
    alignRow(ctx, Ids.am_start, Ids.am_start_a, width, .start, "start");
    alignRow(ctx, Ids.am_center, Ids.am_center_a, width, .center, "center");
    alignRow(ctx, Ids.am_end, Ids.am_end_a, width, .end, "end");
    // A grow child takes the space align_main would place, so `.end` here is a no-op.
    ctx.beginBox(.{
        .id = Ids.am_grow,
        .direction = .row,
        .width = .{ .fixed = width },
        .height = .{ .fixed = ROW_H },
        .gap = GAP,
        .align_main = .end,
        .bg = Col.row,
    });
    chip(ctx, Ids.am_grow_a, "end", .{ .fixed = 60 }, Col.fixed);
    chip(ctx, Ids.am_grow_g, "grow", .{ .grow = 1 }, Col.grow);
    ctx.endBox();
    const ids = [_]gui.Id{ Ids.am_start_a, Ids.am_center_a, Ids.am_end_a, Ids.am_grow_a };
    endItem(ctx, allCached(ctx, &ids), "start_x={d} center_x={d} end_x={d} grow_x={d}", .{
        relX(ctx, Ids.am_start, Ids.am_start_a),
        relX(ctx, Ids.am_center, Ids.am_center_a),
        relX(ctx, Ids.am_end, Ids.am_end_a),
        relX(ctx, Ids.am_grow, Ids.am_grow_a),
    });
}

fn itemWrap(ctx: *gui.Context, width: i32) void {
    beginItem(ctx, "5. wrap", width);
    ctx.beginBox(.{
        .id = Ids.wrap_row,
        .direction = .row,
        .wrap = true,
        .width = .{ .fixed = width },
        .height = .fit,
        .gap = GAP,
        .bg = Col.row,
    });
    chip(ctx, Ids.wrap_a, "72", .{ .fixed = 72 }, Col.fixed);
    chip(ctx, Ids.wrap_b, "30%", .{ .percent = 0.3 }, Col.pct);
    chipEx(ctx, Ids.wrap_c, "g48", .{ .grow = 1 }, .{ .fixed = CHIP_H }, 48, std.math.maxInt(i32), Col.grow, null);
    chip(ctx, Ids.wrap_d, "72", .{ .fixed = 72 }, Col.fixed);
    chip(ctx, Ids.wrap_e, "30%", .{ .percent = 0.3 }, Col.pct);
    chipEx(ctx, Ids.wrap_f, "g48", .{ .grow = 1 }, .{ .fixed = CHIP_H }, 48, std.math.maxInt(i32), Col.grow, null);
    ctx.endBox();

    var counts: [8]u8 = undefined;
    var wrap_ys: [8]i32 = undefined;
    const wrap_ids = [_]gui.Id{ Ids.wrap_a, Ids.wrap_b, Ids.wrap_c, Ids.wrap_d, Ids.wrap_e, Ids.wrap_f };
    const lines = wrapLines(ctx, &wrap_ids, &counts, &wrap_ys);

    ctx.beginBox(.{
        .id = Ids.wrap_gap_row,
        .direction = .row,
        .wrap = true,
        .width = .{ .fixed = width },
        .height = .fit,
        .gap = GAP,
        .cross_gap = WRAP_CROSS_GAP,
        .bg = Col.row,
    });
    chip(ctx, Ids.wrap_gap_0, "72", .{ .fixed = 72 }, Col.fixed);
    chip(ctx, Ids.wrap_gap_1, "72", .{ .fixed = 72 }, Col.fit);
    chip(ctx, Ids.wrap_gap_2, "72", .{ .fixed = 72 }, Col.grow);
    chip(ctx, Ids.wrap_gap_3, "72", .{ .fixed = 72 }, Col.pct);
    ctx.endBox();
    var gap_counts: [8]u8 = undefined;
    var gap_ys: [8]i32 = undefined;
    const gap_ids = [_]gui.Id{ Ids.wrap_gap_0, Ids.wrap_gap_1, Ids.wrap_gap_2, Ids.wrap_gap_3 };
    const gap_lines = wrapLines(ctx, &gap_ids, &gap_counts, &gap_ys);
    const gap_dy: i32 = if (gap_lines >= 2) gap_ys[1] - gap_ys[0] else -1;

    endItem(ctx, allCached(ctx, &wrap_ids) and allCached(ctx, &gap_ids), "lines={d} per=[{d},{d},{d},{d}]  cross_gap={d} lines={d} dy={d}", .{
        lines,
        counts[0],
        counts[1],
        counts[2],
        counts[3],
        WRAP_CROSS_GAP,
        gap_lines,
        gap_dy,
    });
}

fn itemCrossGrow(ctx: *gui.Context, width: i32) void {
    beginItem(ctx, "6. wrap cross grow", width);
    ctx.beginBox(.{
        .id = Ids.xgrow_row,
        .direction = .row,
        .wrap = true,
        .width = .{ .fixed = width },
        .height = .fit,
        .gap = GAP,
        .bg = Col.row,
    });
    ctx.beginBox(.{
        .id = Ids.xgrow_a,
        .width = .{ .fixed = 76 },
        .height = .{ .fixed = 16 },
        .bg = Col.tall,
        .padding = .{ 0, 4, 0, 4 },
    });
    ctx.label("h16");
    ctx.endBox();
    ctx.beginBox(.{
        .id = Ids.xgrow_g0,
        .width = .{ .fixed = 76 },
        .height = .{ .grow = 1 },
        .min_height = 8,
        .bg = Col.line0,
        .padding = .{ 0, 4, 0, 4 },
    });
    ctx.label("g");
    ctx.endBox();
    ctx.beginBox(.{
        .id = Ids.xgrow_b,
        .width = .{ .fixed = 76 },
        .height = .{ .fixed = 36 },
        .bg = Col.tall,
        .padding = .{ 0, 4, 0, 4 },
    });
    ctx.label("h36");
    ctx.endBox();
    ctx.beginBox(.{
        .id = Ids.xgrow_g1,
        .width = .{ .fixed = 76 },
        .height = .{ .grow = 1 },
        .min_height = 8,
        .bg = Col.line1,
        .padding = .{ 0, 4, 0, 4 },
    });
    ctx.label("g");
    ctx.endBox();
    ctx.endBox();
    var counts: [8]u8 = undefined;
    var ys: [8]i32 = undefined;
    const ids = [_]gui.Id{ Ids.xgrow_a, Ids.xgrow_g0, Ids.xgrow_b, Ids.xgrow_g1 };
    const lines = wrapLines(ctx, &ids, &counts, &ys);
    endItem(ctx, allCached(ctx, &ids), "g0.h={d} g1.h={d} lines={d} per=[{d},{d}]", .{
        nodeH(ctx, Ids.xgrow_g0),
        nodeH(ctx, Ids.xgrow_g1),
        lines,
        counts[0],
        counts[1],
    });
}

fn flowBody(ctx: *gui.Context) void {
    ctx.label("flow");
    ctx.beginBox(.{ .width = .{ .fixed = 40 }, .height = .{ .fixed = 12 }, .bg = Col.fixed });
    ctx.endBox();
}

fn wrapFour(ctx: *gui.Context, ids: [4]gui.Id) void {
    inline for (ids) |id| {
        chip(ctx, id, "72", .{ .fixed = 72 }, Col.fixed);
    }
}

fn itemPosition(ctx: *gui.Context, width: i32) void {
    beginItem(ctx, "7. position", width);

    ctx.beginBox(.{ .direction = .row, .gap = 8 });
    ctx.beginBox(.{
        .id = Ids.pos_plain,
        .direction = .column,
        .width = .fit,
        .padding = .{ 4, 8, 4, 8 },
        .gap = 2,
        .bg = Col.panel,
    });
    flowBody(ctx);
    ctx.endBox();
    ctx.beginBox(.{
        .id = Ids.pos_ovl,
        .direction = .column,
        .width = .fit,
        .padding = .{ 4, 8, 4, 8 },
        .gap = 2,
        .bg = Col.panel,
    });
    flowBody(ctx);
    ctx.beginBox(.{
        .id = Ids.pos_badge,
        .position = .{ .top = .{ .length = .{ .px = -8 } }, .right = .{ .length = .{ .px = -12 } } },
        .width = .{ .fixed = 10 },
        .height = .{ .fixed = 10 },
        .bg = Col.badge,
    });
    ctx.endBox();
    ctx.endBox();
    ctx.endBox();

    ctx.beginBox(.{
        .id = Ids.pos_wplain,
        .direction = .row,
        .wrap = true,
        .width = .{ .fixed = width },
        .height = .fit,
        .gap = GAP,
        .bg = Col.row,
    });
    wrapFour(ctx, .{ Ids.pos_wplain_0, Ids.pos_wplain_1, Ids.pos_wplain_2, Ids.pos_wplain_3 });
    ctx.endBox();

    ctx.beginBox(.{
        .id = Ids.pos_wovl,
        .direction = .row,
        .wrap = true,
        .width = .{ .fixed = width },
        .height = .fit,
        .gap = GAP,
        .bg = Col.row,
    });
    wrapFour(ctx, .{ Ids.pos_wovl_0, Ids.pos_wovl_1, Ids.pos_wovl_2, Ids.pos_wovl_3 });
    ctx.beginBox(.{
        .position = .{ .top = .{ .length = .{} }, .right = .{ .length = .{} } },
        .width = .{ .fixed = 10 },
        .height = .{ .fixed = 10 },
        .bg = Col.badge,
    });
    ctx.endBox();
    ctx.endBox();

    var pcounts: [8]u8 = undefined;
    var ocounts: [8]u8 = undefined;
    var pys: [8]i32 = undefined;
    var oys: [8]i32 = undefined;
    const pids = [_]gui.Id{ Ids.pos_wplain_0, Ids.pos_wplain_1, Ids.pos_wplain_2, Ids.pos_wplain_3 };
    const oids = [_]gui.Id{ Ids.pos_wovl_0, Ids.pos_wovl_1, Ids.pos_wovl_2, Ids.pos_wovl_3 };
    const plines = wrapLines(ctx, &pids, &pcounts, &pys);
    const olines = wrapLines(ctx, &oids, &ocounts, &oys);
    const size_ids = [_]gui.Id{ Ids.pos_plain, Ids.pos_ovl, Ids.pos_badge };
    endItem(ctx, allCached(ctx, &size_ids) and allCached(ctx, &pids) and allCached(ctx, &oids), "plain={d}x{d} overlay={d}x{d} dh={d}  wrap_plain={d}[{d},{d}] wrap_ovl={d}[{d},{d}]", .{
        nodeW(ctx, Ids.pos_plain),
        nodeH(ctx, Ids.pos_plain),
        nodeW(ctx, Ids.pos_ovl),
        nodeH(ctx, Ids.pos_ovl),
        nodeH(ctx, Ids.pos_ovl) - nodeH(ctx, Ids.pos_plain),
        plines,
        pcounts[0],
        pcounts[1],
        olines,
        ocounts[0],
        ocounts[1],
    });
}

fn itemExtent(ctx: *gui.Context, app: *App, width: i32) void {
    beginItem(ctx, "8. content extent", width);
    ctx.beginScrollArea(Ids.ext_vp, &app.extent_scroll, .{
        .width = .{ .fixed = width },
        .height = .{ .fixed = 48 },
        .content_width = .{ .grow = 1 },
        .content_height = .{ .grow = 1 },
        .gap = 0,
        .bg = Col.row,
        .border = .{ .color = ctx.style.border, .thickness = 1 },
    });
    ctx.beginBox(.{
        .id = Ids.ext_inner,
        .direction = .row,
        .wrap = true,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .gap = GAP,
    });
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        ctx.beginBox(.{
            .id = Ids.ext_card0 + i,
            .width = .{ .fixed = 56 },
            .height = .{ .fixed = 16 },
            .bg = if (i % 2 == 0) Col.fixed else Col.grow,
            .padding = .{ 0, 4, 0, 4 },
        });
        var lab_buf: [4]u8 = undefined;
        const lab = std.fmt.bufPrint(&lab_buf, "{d}", .{i}) catch "";
        ctx.label(lab);
        ctx.endBox();
    }
    ctx.endBox();
    ctx.endScrollArea();

    const cached = ctx.getNodeCachedRect(Ids.ext_inner);
    const meas_h: i32 = if (cached) |c| c.measured_h else -1;
    const ext_h: i32 = if (cached) |c| c.content_h else -1;
    const vp_h = nodeH(ctx, Ids.ext_vp);
    const max_y: i32 = if (ext_h >= 0 and vp_h >= 0) @max(0, ext_h - vp_h) else -1;
    endItem(ctx, cached != null and vp_h >= 0, "measured_h={d} extent_h={d} vp_h={d} max_y={d}", .{
        meas_h,
        ext_h,
        vp_h,
        max_y,
    });
}

const TableRow = struct { kind: []const u8, name: []const u8, note: []const u8 };

const TABLE_ROWS = [_]TableRow{
    .{ .kind = "A", .name = "Xi", .note = "short" },
    .{ .kind = "B", .name = "MediumName", .note = "fit follows this cell" },
    .{ .kind = "C", .name = "Y", .note = "grow takes the rest" },
};

fn itemTable(ctx: *gui.Context, width: i32) void {
    beginItem(ctx, "9. table columns", width);
    const cols = [_]gui.TableCol{
        .{ .width = .{ .fixed = 48 }, .header = "Kind" },
        .{ .width = .fit, .header = "Name" },
        .{ .width = .{ .grow = 1 }, .header = "Note" },
    };
    ctx.beginTable(Ids.table, &cols, .{
        .width = .{ .fixed = width },
        .height = .fit,
        .column_gap = 6,
        .header_bg = Col.bar,
        .bg = Col.row,
        .border = .{ .color = ctx.style.border, .thickness = 1 },
    });
    ctx.tableHeaderRow();
    for (TABLE_ROWS, 0..) |row, ri| {
        ctx.beginTableRow(.{
            .idle_bg = if (ri % 2 == 0) Col.even else null,
        });
        ctx.beginTableCell();
        if (ri == 0) {
            ctx.beginBox(.{ .id = Ids.tbl_fixed, .width = .{ .grow = 1 } });
            ctx.label(row.kind);
            ctx.endBox();
        } else ctx.label(row.kind);
        ctx.endTableCell();
        ctx.beginTableCell();
        if (ri == 0) {
            ctx.beginBox(.{ .id = Ids.tbl_fit, .width = .{ .grow = 1 } });
            ctx.label(row.name);
            ctx.endBox();
        } else ctx.label(row.name);
        ctx.endTableCell();
        ctx.beginTableCell();
        if (ri == 0) {
            ctx.beginBox(.{ .id = Ids.tbl_grow, .width = .{ .grow = 1 } });
            ctx.label(row.note);
            ctx.endBox();
        } else ctx.label(row.note);
        ctx.endTableCell();
        _ = ctx.endTableRow();
    }
    ctx.endTable();
    const ids = [_]gui.Id{ Ids.tbl_fixed, Ids.tbl_fit, Ids.tbl_grow };
    endItem(ctx, allCached(ctx, &ids), "fixed={d} fit={d} grow={d}", .{
        nodeW(ctx, Ids.tbl_fixed),
        nodeW(ctx, Ids.tbl_fit),
        nodeW(ctx, Ids.tbl_grow),
    });
}

fn itemVirtual(ctx: *gui.Context, app: *App, width: i32) void {
    beginItem(ctx, "10. virtual list", width);
    const opts = gui.VirtualListOpts{
        .row_height = VIRT_ROW_H,
        .row_count = VIRT_COUNT,
        .width = .{ .fixed = width },
        .height = .{ .fixed = VIRT_VP_H },
        .gap = 0,
        .overscan = VIRT_OVERSCAN,
        .bg = Col.row,
        .border = .{ .color = ctx.style.border, .thickness = 1 },
    };
    const range = ctx.beginVirtualList(Ids.virt, &app.virt_scroll, opts);
    app.virt_range = range;
    var i = range.first;
    while (i < range.end) : (i += 1) {
        ctx.beginBox(.{
            .id = Ids.virt_row0 + @as(gui.Id, @intCast(i)),
            .width = .{ .grow = 1 },
            .height = .{ .fixed = VIRT_ROW_H },
            .bg = if (i % 2 == 0) Col.even else Col.odd,
            .padding = .{ 0, 4, 0, 4 },
        });
        var lab_buf: [16]u8 = undefined;
        const lab = std.fmt.bufPrint(&lab_buf, "row {d}", .{i}) catch "";
        ctx.label(lab);
        ctx.endBox();
    }
    ctx.endVirtualList();
    endItem(ctx, ctx.getNodeRect(Ids.virt) != null, "first={d} end={d} count={d} scroll={d}", .{
        range.first,
        range.end,
        VIRT_COUNT,
        @as(i32, @intFromFloat(@round(app.virt_scroll.y))),
    });
}

/// Per-frame GUI path: one catalog build. Not a per-pixel loop; not RT.
fn buildCatalog(ctx: *gui.Context, app: *App) void {
    ctx.beginBox(.{
        .direction = .column,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .bg = Col.bg,
    });

    ctx.beginBox(.{
        .direction = .column,
        .width = .{ .grow = 1 },
        .padding = .{ 6, 8, 6, 8 },
        .gap = 4,
        .bg = Col.bar,
    });
    ctx.beginBox(.{
        .direction = .row,
        .width = .{ .grow = 1 },
        .gap = 8,
        .align_cross = .center,
    });
    ctx.labelStyled("layout catalog", .title);
    _ = ctx.sliderI32Id(Ids.width_slider, "width", &app.catalog_width, .{
        .min = WIDTH_MIN,
        .max = WIDTH_MAX,
        .track_w = 360,
    });
    var wbuf: [16]u8 = undefined;
    const wtxt = std.fmt.bufPrint(&wbuf, "{d}px", .{app.catalog_width}) catch "";
    ctx.labelStyled(wtxt, .caption);
    ctx.endBox();
    ctx.labelStyled("resolved (settled layout, updates one frame after a width change)", .caption);
    ctx.endBox();

    // Specimen width is the value after the slider write. Readouts still
    // come from the previous-frame cache, so they match on the next frame.
    const width = app.catalog_width;

    ctx.beginScrollArea(Ids.catalog_scroll, &app.catalog_scroll, .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .content_width = .fit,
        .content_height = .fit,
        .padding = .{ 8, 8, 8, 8 },
        .gap = 6,
        .bg = Col.panel,
    });
    itemMixed(ctx, width);
    itemClamp(ctx, width);
    itemLeftover(ctx, width);
    itemAlignMain(ctx, width);
    itemWrap(ctx, width);
    itemCrossGrow(ctx, width);
    itemPosition(ctx, width);
    itemExtent(ctx, app, width);
    itemTable(ctx, width);
    itemVirtual(ctx, app, width);
    ctx.endScrollArea();

    ctx.endBox();
}

fn layoutDigest(ctx_ptr: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx_ptr));
    const ctx = app.ctx;
    var off: usize = 0;

    appendFmt(buf, &off, "width={d}", .{app.catalog_width});
    appendFmt(buf, &off, " mix_fixed={d} mix_fit={d} mix_grow={d} mix_pct={d}", .{
        nodeW(ctx, Ids.mix_fixed),
        nodeW(ctx, Ids.mix_fit),
        nodeW(ctx, Ids.mix_grow),
        nodeW(ctx, Ids.mix_pct),
    });
    appendFmt(buf, &off, " clamp_free={d} clamp_min={d} clamp_max={d} clamp_w0={d}", .{
        nodeW(ctx, Ids.clamp_free),
        nodeW(ctx, Ids.clamp_min),
        nodeW(ctx, Ids.clamp_max),
        nodeW(ctx, Ids.clamp_w0),
    });
    const left_kids = [_]gui.Id{ Ids.left_a, Ids.left_b, Ids.left_c };
    appendFmt(buf, &off, " left_w={d} leftover={d}", .{
        nodeW(ctx, Ids.left_row),
        leftoverOf(ctx, Ids.left_row, &left_kids, 8),
    });

    appendFmt(buf, &off, " am_start_x={d} am_center_x={d} am_end_x={d} am_grow_x={d} am_grow_w={d}", .{
        relX(ctx, Ids.am_start, Ids.am_start_a),
        relX(ctx, Ids.am_center, Ids.am_center_a),
        relX(ctx, Ids.am_end, Ids.am_end_a),
        relX(ctx, Ids.am_grow, Ids.am_grow_a),
        nodeW(ctx, Ids.am_grow_g),
    });

    var wcounts: [8]u8 = undefined;
    var wys: [8]i32 = undefined;
    const wrap_ids = [_]gui.Id{ Ids.wrap_a, Ids.wrap_b, Ids.wrap_c, Ids.wrap_d, Ids.wrap_e, Ids.wrap_f };
    const wrap_lines = wrapLines(ctx, &wrap_ids, &wcounts, &wys);
    appendFmt(buf, &off, " wrap_lines={d} wrap_l0={d} wrap_l1={d} wrap_l2={d} wrap_l3={d}", .{
        wrap_lines,
        wcounts[0],
        wcounts[1],
        wcounts[2],
        wcounts[3],
    });

    var gcounts: [8]u8 = undefined;
    var gys: [8]i32 = undefined;
    const gap_ids = [_]gui.Id{ Ids.wrap_gap_0, Ids.wrap_gap_1, Ids.wrap_gap_2, Ids.wrap_gap_3 };
    const gap_lines = wrapLines(ctx, &gap_ids, &gcounts, &gys);
    const gap_dy: i32 = if (gap_lines >= 2) gys[1] - gys[0] else -1;
    appendFmt(buf, &off, " wrap_gap_lines={d} wrap_gap_y0={d} wrap_gap_y1={d} wrap_gap_dy={d}", .{
        gap_lines,
        gys[0],
        gys[1],
        gap_dy,
    });

    var xcounts: [8]u8 = undefined;
    var xys: [8]i32 = undefined;
    const xids = [_]gui.Id{ Ids.xgrow_a, Ids.xgrow_g0, Ids.xgrow_b, Ids.xgrow_g1 };
    const xlines = wrapLines(ctx, &xids, &xcounts, &xys);
    appendFmt(buf, &off, " xgrow_g0={d} xgrow_g1={d} xgrow_lines={d}", .{
        nodeH(ctx, Ids.xgrow_g0),
        nodeH(ctx, Ids.xgrow_g1),
        xlines,
    });

    var pcounts: [8]u8 = undefined;
    var ocounts: [8]u8 = undefined;
    var pys: [8]i32 = undefined;
    var oys: [8]i32 = undefined;
    const pids = [_]gui.Id{ Ids.pos_wplain_0, Ids.pos_wplain_1, Ids.pos_wplain_2, Ids.pos_wplain_3 };
    const oids = [_]gui.Id{ Ids.pos_wovl_0, Ids.pos_wovl_1, Ids.pos_wovl_2, Ids.pos_wovl_3 };
    const plines = wrapLines(ctx, &pids, &pcounts, &pys);
    const olines = wrapLines(ctx, &oids, &ocounts, &oys);
    const plain_h = nodeH(ctx, Ids.pos_plain);
    const ovl_h = nodeH(ctx, Ids.pos_ovl);
    const pos_dh: i32 = if (plain_h >= 0 and ovl_h >= 0) ovl_h - plain_h else -1;
    appendFmt(buf, &off, " pos_plain={d} pos_plain_h={d} pos_ovl={d} pos_ovl_h={d} pos_dh={d}", .{
        nodeW(ctx, Ids.pos_plain),
        plain_h,
        nodeW(ctx, Ids.pos_ovl),
        ovl_h,
        pos_dh,
    });
    appendFmt(buf, &off, " pos_badge_x={d} pos_badge_y={d} pos_ovl_x={d} pos_ovl_y={d}", .{
        nodeX(ctx, Ids.pos_badge),
        nodeY(ctx, Ids.pos_badge),
        nodeX(ctx, Ids.pos_ovl),
        nodeY(ctx, Ids.pos_ovl),
    });
    appendFmt(buf, &off, " pos_wplain={d} pos_wovl={d}", .{
        plines,
        olines,
    });

    const cached = ctx.getNodeCachedRect(Ids.ext_inner);
    const meas_h: i32 = if (cached) |c| c.measured_h else -1;
    const ext_h: i32 = if (cached) |c| c.content_h else -1;
    const vp_h = nodeH(ctx, Ids.ext_vp);
    const max_y: i32 = if (ext_h >= 0 and vp_h >= 0) @max(0, ext_h - vp_h) else -1;
    appendFmt(buf, &off, " ext_meas_h={d} ext_h={d} ext_vp_h={d} ext_max_y={d}", .{
        meas_h,
        ext_h,
        vp_h,
        max_y,
    });

    appendFmt(buf, &off, " tbl_fixed={d} tbl_fit={d} tbl_grow={d}", .{
        nodeW(ctx, Ids.tbl_fixed),
        nodeW(ctx, Ids.tbl_fit),
        nodeW(ctx, Ids.tbl_grow),
    });
    appendFmt(buf, &off, " virt_first={d} virt_end={d} virt_n={d}", .{
        app.virt_range.first,
        app.virt_range.end,
        VIRT_COUNT,
    });
    return buf[0..off];
}

fn runLayoutWidth(ctx_ptr: *anyopaque, args: []const u8, buf: []u8) ![]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx_ptr));
    const raw = std.mem.trim(u8, args, " \t");
    const px = std.fmt.parseInt(i32, raw, 10) catch return error.InvalidArgument;
    if (px < WIDTH_MIN or px > WIDTH_MAX) return error.InvalidArgument;
    app.catalog_width = px;
    // A width sweep starts from the origin so nested scroll does not leak
    // across widths. The next two presented frames settle getNodeRect.
    app.catalog_scroll = .{};
    app.extent_scroll = .{};
    app.virt_scroll = .{};
    return std.fmt.bufPrint(buf, "ok width={d}", .{px}) catch error.BufferTooSmall;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(WINDOW_W, WINDOW_H, "example_10: layout catalog");
    defer window.destroy();

    var ctx = gui.Context.init(gpa, gui.default_font);
    defer ctx.deinit();

    var app: App = .{ .ctx = &ctx };

    platform.registerProbe(.{
        .name = "layout",
        .ctx = &app,
        .ext = "txt",
        .digest = layoutDigest,
        .desc = "layout catalog resolved sizes",
    });
    platform.registerAction(.{
        .name = "layout_width",
        .ctx = &app,
        .args = &.{.{ .name = "px", .kind = "int", .min = 120, .max = 1000 }},
        .network_policy = .local_only,
        .run = runLayoutWidth,
        .desc = "set catalog width and reset scroll; step at least 2 to settle readouts",
    });

    var running = true;
    main_loop: while (running and window.pollEvents()) {
        const fb = window.lockFramebuffer() orelse continue :main_loop;
        defer fb.unlock();

        ctx.beginFrame(fb.width, fb.height);

        while (window.nextEvent()) |ev| {
            switch (ev) {
                .quit => running = false,
                .key_down => |ke| {
                    if (ke.key == .ESCAPE) running = false;
                },
                else => {},
            }
            if (kit.toGuiEvent(ev)) |ge| ctx.pushEvent(ge);
        }

        @memset(fb.pixels, 0xFF_18_18_1C);
        const target: gui.RenderTarget = .{
            .pixels = fb.pixels,
            .width = fb.width,
            .height = fb.height,
        };

        buildCatalog(&ctx, &app);
        ctx.endFrame();

        gui.render(target, &ctx.draw_list, ctx.font, 1.0);
        window.present();
    }
}
