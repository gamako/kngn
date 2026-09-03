// Column table: rows share one column-width spec, with an optional sticky header.
//
// Hot path declaration: table build, fit-column measure, stretch-cell measure, and
// DrawList command generation run every frame on the GUI widget path. They are not a
// per-pixel loop (rect / text / image appends only, same class as stepgrid) and they
// do not touch the real-time audio path. Transient state lives on the Context frame
// arena; the widget adds no long-lived allocation.
//
// A table is a flex extension that shares column widths across rows. The model is
// the slider group: cell nodes are collected while the table builds, and endTable
// writes `.fixed` widths back so layout (which runs in endFrame) settles the same
// frame. There is no previous-frame column-width lag.
//
// Column identity is the column index. A future sort / resize / hide / frozen
// column feature should add a stable column id on TableCol first; this widget
// does not invent one speculatively.
//
// Vertical contract: `TableCol.align_cross` aligns that cell's own content inside
// the cell box. It does not make sibling cells the same height. A row defaults to
// `height = .fit`, so each cell keeps its intrinsic height. Cross-axis grow
// measures as 0, so stretching every cell with grow would collapse the row to 0.
// `TableOpts.stretch_cells` is the opt-in that equalises cell heights: endTableRow
// measures each cell subtree and writes the row's height back as `.fixed` (the
// same write-back used for fit columns, and the same kind of extra walk). It is
// legal only when the row height is `.fit` or `.fixed`. `.grow` is rejected
// because the row's final cross size is unknown at endTableRow. A `.fixed` row
// writes that fixed height, not the content max.
//
// Horizontal scroll cannot coexist with grow / percent columns: those sizes mean
// "fill what is left in the viewport" and so cannot exceed it. `h_scroll = true`
// therefore rejects grow / percent (requireContract) and requires `opts.scroll`.
// Fit is allowed because endTable resolves it to `.fixed`.
//
// A scrolling table (`opts.scroll != null`) cannot use `.fit` width or height.
// The body is a ScrollArea whose outer box is grow; grow-in-fit measures as 0,
// so a fit table would give the viewport no size. A scroll region needs its
// viewport from the parent (fixed / grow / percent). A non-scrolling table
// may still be `.fit`.
//
// Content width:
//   h_scroll = true  → body ScrollArea `content_width = .fit`, row width `.fit`.
//                      Columns are all fixed (fit already written back), so the
//                      row's fit width is the column sum plus gaps and does not
//                      depend on the viewport. No extra width write-back.
//   h_scroll = false → body ScrollArea `content_width = .{ .grow = 1 }`, row
//                      width `.grow = 1`. Overflow is clipped by the viewport.
// Scrollbar appearance (`need_h` / `need_v`) follows ScrollArea's previous-frame
// contract, so the first frame and a viewport resize lag the bars by one frame.
//
// Fit-column cost: endTable walks every fit cell subtree with `layout.measure`
// (a pure, Context-free function) and then endFrame walks the same nodes again.
// Large tables should prefer fixed / grow / percent. A virtualized table must
// use those too: a fit max taken only from the visible window would change
// column widths as the user scrolls.
//
// Tables do not nest (same contract as a slider group).
//
// Do not derive a row id from a display name: two rows with the same label would
// collide. The caller passes a data-identity id when the row is interactive.
//
// Tab order: an interactive row is registered first, then focusable cell
// widgets in build order (row → its cells). Keep cells display-only when the
// row selection is the only focus the caller wants.

const std = @import("std");

const context_mod = @import("context.zig");
const layout = @import("layout.zig");
const color_mod = @import("color.zig");
const id_mod = @import("id.zig");
const input_mod = @import("input.zig");
const font_mod = @import("font.zig");
const geom = @import("geom.zig");

const Context = context_mod.Context;
const Color = color_mod.Color;
const Id = id_mod.Id;
const Rect = geom.Rect;
const Vec2f = input_mod.Vec2f;

/// One column spec. Identity is the column's index in the `cols` slice.
pub const TableCol = struct {
    width: layout.Sizing,
    header: ?[]const u8 = null,
    /// Vertical alignment of this cell's own content inside the cell box
    /// (`direction = .row` so `align_cross` is the vertical axis). Sibling
    /// cells are not stretched to a shared height unless `stretch_cells`.
    align_cross: layout.Align = .start,
};

pub const TableOpts = struct {
    /// Outer size. A scrolling table (`scroll != null`) rejects `.fit` on either
    /// axis: the body ScrollArea is grow, and grow-in-fit measures as 0, so the
    /// viewport would have no size. Use `.fixed`, `.grow`, or `.percent`. A
    /// non-scrolling table may be `.fit`.
    width: layout.Sizing = .{ .grow = 1 },
    height: layout.Sizing = .{ .grow = 1 },
    column_gap: i32 = 8,
    row_gap: i32 = 0,
    /// top, right, bottom, left. Insets the table's whole content — the header row
    /// (sticky or not) and every body row alike, since they are all direct or indirect
    /// children of this one outer box — from the outer border set by `border`. Applies
    /// once around the whole table, not per row (`row_gap` is the space between rows).
    padding: [4]i32 = .{ 0, 0, 0, 0 },
    /// Caller-owned scroll. null = a small non-scrolling table (no sticky header,
    /// no body ScrollArea). Non-null opens a body ScrollArea and, when a header
    /// row is built, a sticky header strip outside that viewport. Requires a
    /// definite width and height (not `.fit`).
    scroll: ?*Vec2f = null,
    /// Horizontal scrolling. Requires `scroll != null`. Grow / percent columns
    /// are illegal (they cannot exceed the viewport).
    h_scroll: bool = false,
    /// When true, endTableRow writes a shared cell height (`.fixed`) so cell
    /// backgrounds and rules line up. Extra per-row `layout.measure` of every
    /// cell subtree; same class of cost as the fit-column walk at endTable.
    stretch_cells: bool = false,
    header_bg: ?Color = null,
    bg: ?Color = null,
    border: ?layout.Border = null,
    wheel_px: f32 = 32.0,
    bar_thickness: i32 = 8,
};

pub const TableRowInteractive = struct {
    /// Caller-owned data identity. Do not hash a display name.
    id: Id,
    selected: bool,
};

pub const TableRowOpts = struct {
    interactive: ?TableRowInteractive = null,
    idle_bg: ?Color = null,
    height: layout.Sizing = .fit,
};

pub const TableRowResult = struct {
    /// Click, or Space/Enter while this row holds the focus (same contract as
    /// `beginListboxRow`). The caller applies this to its own selection model.
    activated: bool = false,
};

const TableCellRec = struct {
    node: *layout.Node,
    col: usize,
    next: ?*TableCellRec = null,
};

/// Frame-local table build state. Lives on Context; reset each beginFrame.
pub const TableState = struct {
    id: Id,
    cols: []TableCol,
    width: layout.Sizing,
    column_gap: i32,
    row_gap: i32,
    scroll: ?*Vec2f,
    h_scroll: bool,
    stretch_cells: bool,
    has_fit_col: bool,
    header_bg: ?Color,
    wheel_px: f32,
    bar_thickness: i32,
    cells: ?*TableCellRec = null,
    last_cell: ?*TableCellRec = null,
    header_strip_node: ?*layout.Node = null,
    header_built: bool = false,
    body_opened: bool = false,
    row_index: usize = 0,
    row_open: bool = false,
    cell_open: bool = false,
    row_cell_count: usize = 0,
    row_cell_nodes: []*layout.Node = &.{},
    row_height: layout.Sizing = .fit,
    row_id: ?Id = null,
    row_selected: bool = false,
    row_node: ?*layout.Node = null,
};

const body_vp_salt: u64 = 1;
const header_strip_salt: u64 = 2;
const header_row_salt: u64 = 3;

fn tableState(ctx: *Context) *TableState {
    Context.requireContract(ctx.table != null, "table API without a matching beginTable");
    return &ctx.table.?;
}

fn rowWidth(t: *const TableState) layout.Sizing {
    if (t.h_scroll) return .fit;
    // Grow inside a fit parent measures as 0. A fit table therefore uses fit
    // rows (the column sum). A definite table width uses grow rows so they
    // fill the table / viewport.
    return switch (t.width) {
        .fit => .fit,
        else => .{ .grow = 1 },
    };
}

fn sizingFillsViewport(s: layout.Sizing) bool {
    return switch (s) {
        .grow, .percent => true,
        else => false,
    };
}

fn keyboardActivated(ctx: *const Context, id: Id) bool {
    if (id == 0 or ctx.state.focused_id != id or !ctx.current_layer_scope.keyboard_enabled) return false;
    if (ctx.popup_state != null or ctx.popup_stack.len != 0 or ctx.pointerEngaged()) return false;
    const all = input_mod.mod.all;
    return ctx.input.pressedPlain(input_mod.key.space, 0, all) or
        ctx.input.pressedPlain(input_mod.key.enter, 0, all);
}

fn popupOpen(ctx: *const Context) bool {
    return ctx.popup_state != null or ctx.popup_stack.len != 0;
}

/// Hover-only half of the row hit-test (phase 1, beginTableRow).
///
/// The row is a background interactive region: it must lose both hover (last
/// writer wins) and press (first writer wins) to any cell widget built after
/// this. Phase 1 therefore registers hover and never acquires press.
///
/// Side effects assigned to this phase: popup suppression, disabled
/// `clearDisabledInteraction` + zero-rect `noteLastInteractive`, previous-frame
/// rect/clip hover, `next_hot_id` (only when `active_id == 0 or active_id ==
/// row_id`), `this_frame_hovered_any`, selected-row `registerFocusable`
/// (roving tab stop), `noteLastInteractive`.
fn rowHoverOnly(ctx: *Context, id: Id, selected: bool) void {
    if (popupOpen(ctx)) return;
    if (ctx.isDisabled()) {
        ctx.clearDisabledInteraction(id);
        ctx.noteLastInteractive(id, .{ .x = 0, .y = 0, .w = 0, .h = 0 }, false);
        return;
    }
    if (selected) ctx.registerFocusable(id);
    if (ctx.rect_cache.get(id)) |cached| {
        if (!ctx.current_layer_scope.pointer_enabled) {
            ctx.noteLastInteractive(id, cached.rect, false);
            return;
        }
        const hovered = context_mod.pointHitsVisible(cached.rect, cached.clip, ctx.input.mouse_pos);
        if (hovered) {
            if (ctx.state.active_id == 0 or ctx.state.active_id == id) {
                ctx.state.next_hot_id = id;
            }
            ctx.state.this_frame_hovered_any = true;
        }
        ctx.noteLastInteractive(id, cached.rect, hovered);
    } else {
        ctx.noteLastInteractive(id, .{ .x = 0, .y = 0, .w = 0, .h = 0 }, false);
    }
}

/// Press / held / click / keyboard half of the row hit-test (phase 2, endTableRow).
///
/// Re-checks popup and disabled against the state after cell build: a cell that
/// opens a popup in this frame must not leave the row activating. `openPopup`
/// already resets `active_id` to 0, so a row that was active is already
/// released and needs no extra case.
///
/// Side effects assigned to this phase: press acquire (`active_id == 0` and
/// left press origin inside the visible region), held + `active_submitted`
/// while `active_id == row_id` (required so endFrame's anti-stick cleanup does
/// not drop a row drag), click on release when `dragPos` is visible (clip-out
/// release frees active without clicking), keyboard activate.
fn rowPressResolve(ctx: *Context, id: Id, rect: Rect, clip: Rect) TableRowResult {
    if (popupOpen(ctx)) return .{};
    if (ctx.isDisabled()) {
        ctx.clearDisabledInteraction(id);
        return .{};
    }

    if (!ctx.current_layer_scope.pointer_enabled) return .{ .activated = keyboardActivated(ctx, id) };

    var clicked = false;
    var held = false;
    // `active_id == 0` is not enough on a same-frame cell click: the cell
    // acquires, then releases, leaving active_id clear while `mouse_pressed`
    // is still true. The cell sets `active_submitted` while it is active, so
    // that flag means a foreground widget already claimed this press.
    if (ctx.state.active_id == 0 and ctx.input.mouse_pressed.left and !ctx.state.active_submitted) {
        if (context_mod.pointHitsVisible(rect, clip, ctx.input.mouse_pressed_pos)) {
            ctx.state.active_id = id;
        }
    }
    if (ctx.state.active_id == id) {
        held = true;
        ctx.state.active_submitted = true;
        if (ctx.input.mouse_released.left) {
            if (context_mod.pointHitsVisible(rect, clip, ctx.input.dragPos())) clicked = true;
            ctx.state.active_id = 0;
        }
    }
    if (held) _ = ctx.claimFocus(id);
    return .{ .activated = clicked or keyboardActivated(ctx, id) };
}

fn rowFill(ctx: *const Context, id: Id, selected: bool, held: bool, idle_bg: ?Color) ?Color {
    const style = ctx.style;
    const hot = ctx.state.hot_id == id;
    if (ctx.isDisabled()) {
        return if (selected) style.disabledColor(style.accent.selected) else idle_bg;
    }
    if (held) return style.accent.primary;
    if (hot) return style.surface.control_hover;
    if (selected) return style.accent.selected;
    return idle_bg;
}

fn beginCellBox(ctx: *Context, col: usize) *layout.Node {
    const t = tableState(ctx);
    Context.requireContract(col < t.cols.len, "table cell index exceeds column count");
    const spec = t.cols[col];
    ctx.beginBox(.{
        .id = ctx.id_stack.makeInt(col),
        .direction = .row,
        .width = spec.width,
        .height = .fit,
        .align_cross = spec.align_cross,
    });
    const node = ctx.openBox();
    if (spec.width == .fit) {
        const rec = ctx.allocator().create(TableCellRec) catch @panic("table: OOM");
        rec.* = .{ .node = node, .col = col };
        if (t.last_cell) |last| last.next = rec else t.cells = rec;
        t.last_cell = rec;
    }
    return node;
}

fn dupeCols(ctx: *Context, cols: []const TableCol) []TableCol {
    const out = ctx.allocator().alloc(TableCol, cols.len) catch @panic("beginTable: OOM");
    for (cols, 0..) |col, i| {
        out[i] = col;
        if (col.header) |h| {
            out[i].header = ctx.allocator().dupe(u8, h) catch @panic("beginTable: OOM");
        }
    }
    return out;
}

/// Open a table. `id` is required and becomes the outer box id plus the IdStack
/// table scope (row scopes nest inside it so two tables in one parent do not
/// collide on a cell widget that shares a label).
///
/// A table is forbidden inside a display-only tooltip builder. It keeps its own
/// Context-owned state stack and interactive rows write hover / tooltip state,
/// so allowing one would need a full save/restore plus a second interactive-row
/// ban. That cost is not worth putting a table in a tooltip.
pub fn beginTable(ctx: *Context, id: Id, cols: []const TableCol, opts: TableOpts) void {
    ctx.requireFrame("beginTable");
    ctx.requireInteractiveAllowed("beginTable");
    Context.requireContract(ctx.table == null, "beginTable inside another table");
    Context.requireContract(id != 0, "beginTable requires a non-zero id");
    if (opts.scroll != null) {
        Context.requireContract(opts.width != .fit, "a scrolling table cannot use .fit width");
        Context.requireContract(opts.height != .fit, "a scrolling table cannot use .fit height");
    }
    if (opts.h_scroll) {
        Context.requireContract(opts.scroll != null, "h_scroll requires opts.scroll");
        for (cols) |col| {
            Context.requireContract(
                !sizingFillsViewport(col.width),
                "h_scroll cannot use grow or percent columns",
            );
        }
    }
    var has_fit_col = false;
    for (cols) |col| {
        if (col.width == .fit) has_fit_col = true;
    }

    ctx.id_stack.push(id);
    ctx.beginBox(.{
        .id = id,
        .direction = .column,
        .width = opts.width,
        .height = opts.height,
        .padding = opts.padding,
        .gap = if (opts.scroll == null) opts.row_gap else 0,
        .bg = opts.bg,
        .border = opts.border,
    });
    ctx.table = .{
        .id = id,
        .cols = dupeCols(ctx, cols),
        .width = opts.width,
        .column_gap = opts.column_gap,
        .row_gap = opts.row_gap,
        .scroll = opts.scroll,
        .h_scroll = opts.h_scroll,
        .stretch_cells = opts.stretch_cells,
        .has_fit_col = has_fit_col,
        .header_bg = opts.header_bg,
        .wheel_px = opts.wheel_px,
        .bar_thickness = opts.bar_thickness,
    };
}

fn buildHeaderCells(ctx: *Context) void {
    const t = tableState(ctx);
    ctx.id_stack.push("header");
    for (t.cols, 0..) |col, i| {
        _ = beginCellBox(ctx, i);
        if (col.header) |text| ctx.labelEx(text, ctx.style.text_tokens.subtle);
        ctx.endBox();
    }
    ctx.id_stack.pop();
}

/// Emit the header row from each column's `header` string (null → an empty cell).
/// At most once, and only before any body row. With `opts.scroll` the header sits
/// in a strip outside the body ScrollArea (structurally sticky). Without scroll
/// it is an ordinary first row.
pub fn tableHeaderRow(ctx: *Context) void {
    ctx.requireFrame("tableHeaderRow");
    ctx.requireInteractiveAllowed("tableHeaderRow");
    const t = tableState(ctx);
    Context.requireContract(!t.header_built, "tableHeaderRow called twice");
    Context.requireContract(!t.body_opened, "tableHeaderRow after body rows have started");
    Context.requireContract(!t.row_open, "tableHeaderRow while a row is still open");
    t.header_built = true;

    if (t.scroll) |scroll| {
        const sx: i32 = @intFromFloat(@round(scroll.x));
        ctx.beginBox(.{
            .id = id_mod.hashInt(t.id, header_strip_salt),
            .direction = .column,
            .width = .{ .grow = 1 },
            .height = .fit,
            .clip_children = true,
            .scroll_x = sx,
            .bg = t.header_bg,
        });
        t.header_strip_node = ctx.openBox();
        ctx.beginBox(.{
            .id = id_mod.hashInt(t.id, header_row_salt),
            .direction = .row,
            .width = rowWidth(t),
            .height = .fit,
            .gap = t.column_gap,
            .bg = t.header_bg,
        });
        buildHeaderCells(ctx);
        ctx.endBox();
        ctx.endBox();
    } else {
        ctx.beginBox(.{
            .id = id_mod.hashInt(t.id, header_row_salt),
            .direction = .row,
            .width = rowWidth(t),
            .height = .fit,
            .gap = t.column_gap,
            .bg = t.header_bg,
        });
        buildHeaderCells(ctx);
        ctx.endBox();
    }
}

fn ensureBody(ctx: *Context) void {
    const t = tableState(ctx);
    if (t.body_opened) return;
    t.body_opened = true;
    const scroll = t.scroll orelse return;
    const vp_id = id_mod.hashInt(t.id, body_vp_salt);
    const content_w: layout.Sizing = if (t.h_scroll) .fit else .{ .grow = 1 };
    ctx.beginScrollArea(vp_id, scroll, .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .direction = .column,
        .gap = t.row_gap,
        .content_width = content_w,
        .content_height = .fit,
        .wheel_px = t.wheel_px,
        .bar_thickness = t.bar_thickness,
    });
}

/// Open a body row. Push a row IdStack scope (the interactive id, or the row
/// index via `makeInt`) so cell auto-IDs do not collide across rows or across
/// two tables that share a parent.
///
/// Interactive rows use a two-phase hit-test: this call registers hover only.
/// Press, held, click, and keyboard activate run in `endTableRow` so a cell
/// widget built in between wins both hover (last writer) and press (first
/// writer). Roving tab stop and `pollListNav` follow `beginListboxRow`.
pub fn beginTableRow(ctx: *Context, opts: TableRowOpts) void {
    ctx.requireFrame("beginTableRow");
    ctx.requireInteractiveAllowed("beginTableRow");
    const t = tableState(ctx);
    Context.requireContract(!t.row_open, "beginTableRow while a row is still open");
    if (t.stretch_cells) {
        switch (opts.height) {
            .fit, .fixed => {},
            .grow, .percent => Context.requireContract(false, "stretch_cells requires row height .fit or .fixed"),
        }
    }
    if (opts.interactive) |spec| {
        Context.requireContract(spec.id != 0, "interactive table row requires a non-zero id");
    }

    ensureBody(ctx);

    t.row_open = true;
    t.cell_open = false;
    t.row_cell_count = 0;
    t.row_height = opts.height;
    t.row_cell_nodes = if (t.stretch_cells)
        ctx.allocator().alloc(*layout.Node, t.cols.len) catch @panic("beginTableRow: OOM")
    else
        &.{};

    if (opts.interactive) |spec| {
        t.row_id = spec.id;
        t.row_selected = spec.selected;
        ctx.id_stack.push(spec.id);
        rowHoverOnly(ctx, spec.id, spec.selected);
        const bg = rowFill(ctx, spec.id, spec.selected, false, opts.idle_bg);
        ctx.beginBox(.{
            .id = spec.id,
            .direction = .row,
            .width = rowWidth(t),
            .height = opts.height,
            .gap = t.column_gap,
            .bg = bg,
        });
    } else {
        t.row_id = null;
        t.row_selected = false;
        ctx.id_stack.push(t.row_index);
        ctx.beginBox(.{
            .direction = .row,
            .width = rowWidth(t),
            .height = opts.height,
            .gap = t.column_gap,
            .bg = opts.idle_bg,
        });
    }
    t.row_node = ctx.openBox();
    t.row_index += 1;
}

/// Close the row opened by `beginTableRow`. Asserts the cell count matches
/// `cols.len`. When `stretch_cells` is set, writes a shared `.fixed` height
/// onto every cell of this row.
pub fn endTableRow(ctx: *Context) TableRowResult {
    ctx.requireFrame("endTableRow");
    ctx.requireInteractiveAllowed("endTableRow");
    const t = tableState(ctx);
    Context.requireContract(t.row_open, "endTableRow without an open row");
    Context.requireContract(!t.cell_open, "endTableRow while a cell is still open");
    Context.requireContract(t.row_cell_count == t.cols.len, "table row cell count does not match column count");

    if (t.stretch_cells) {
        switch (t.row_height) {
            .fixed => |h| {
                for (t.row_cell_nodes[0..t.row_cell_count]) |node| {
                    node.cfg.height = .{ .fixed = h };
                }
            },
            .fit => {
                var max_h: i32 = 0;
                for (t.row_cell_nodes[0..t.row_cell_count]) |node| {
                    layout.measure(node, ctx.font);
                    max_h = @max(max_h, node.measured_h);
                }
                for (t.row_cell_nodes[0..t.row_cell_count]) |node| {
                    node.cfg.height = .{ .fixed = max_h };
                }
            },
            .grow, .percent => unreachable,
        }
    }

    var result: TableRowResult = .{};
    if (t.row_id) |id| {
        if (ctx.rect_cache.get(id)) |cached| {
            result = rowPressResolve(ctx, id, cached.rect, cached.clip);
            if (ctx.state.active_id == id) {
                if (t.row_node) |node| {
                    node.cfg.bg = rowFill(ctx, id, t.row_selected, true, node.cfg.bg);
                }
            }
        }
    }

    ctx.endBox();
    ctx.id_stack.pop();
    t.row_open = false;
    t.row_id = null;
    t.row_node = null;
    t.row_cell_nodes = &.{};
    return result;
}

/// Open the next cell. The column index advances automatically. The cell box
/// carries that column's width and `align_cross`; the caller builds any widget
/// inside (labelEllipsis, imageBox, checkbox, …).
pub fn beginTableCell(ctx: *Context) void {
    ctx.requireFrame("beginTableCell");
    ctx.requireInteractiveAllowed("beginTableCell");
    const t = tableState(ctx);
    Context.requireContract(t.row_open, "beginTableCell without an open row");
    Context.requireContract(!t.cell_open, "beginTableCell while a cell is still open");
    Context.requireContract(t.row_cell_count < t.cols.len, "table row has more cells than columns");
    const node = beginCellBox(ctx, t.row_cell_count);
    if (t.stretch_cells) t.row_cell_nodes[t.row_cell_count] = node;
    t.row_cell_count += 1;
    t.cell_open = true;
}

pub fn endTableCell(ctx: *Context) void {
    ctx.requireFrame("endTableCell");
    ctx.requireInteractiveAllowed("endTableCell");
    const t = tableState(ctx);
    Context.requireContract(t.cell_open, "endTableCell without an open cell");
    ctx.endBox();
    t.cell_open = false;
}

fn applyHeaderWheel(ctx: *Context, header_rect: Rect, st: *context_mod.ScrollState) void {
    if (!ctx.current_layer_scope.wheel_enabled) return;
    ctx.ensureWheelChain();
    if (!ctx.wheel_remaining_seeded) {
        ctx.wheel_remaining = ctx.input.scroll_delta;
        ctx.wheel_remaining_seeded = true;
    }
    const rem = &ctx.wheel_remaining;
    if (rem.x == 0 and rem.y == 0) return;

    const mp = ctx.wheel_chain_mouse;
    const rw: i32 = @intCast(header_rect.w);
    const rh: i32 = @intCast(header_rect.h);
    const inside = mp.x >= header_rect.x and mp.x < header_rect.x + rw and
        mp.y >= header_rect.y and mp.y < header_rect.y + rh;
    if (!inside) return;
    if (st.wheel_px == 0) return;

    const scroll = st.scroll;
    const max_x_f: f32 = @floatFromInt(st.max_x);
    const max_y_f: f32 = @floatFromInt(st.max_y);
    const req_x = -rem.x * st.wheel_px;
    const req_y = -rem.y * st.wheel_px;
    const old_x = scroll.x;
    const old_y = scroll.y;
    scroll.x = std.math.clamp(scroll.x + req_x, 0, max_x_f);
    scroll.y = std.math.clamp(scroll.y + req_y, 0, max_y_f);
    const act_x = scroll.x - old_x;
    const act_y = scroll.y - old_y;
    rem.x -= -act_x / st.wheel_px;
    rem.y -= -act_y / st.wheel_px;

    if (st.viewport_node) |node| {
        node.cfg.scroll_x = @intFromFloat(@round(scroll.x));
        node.cfg.scroll_y = @intFromFloat(@round(scroll.y));
    }
    if (st.need_v and st.max_y > 0) {
        const travel = st.vp_h - st.v_len;
        st.v_off = @intFromFloat(@round(scroll.y / max_y_f * @as(f32, @floatFromInt(travel))));
    }
    if (st.need_h and st.max_x > 0) {
        const travel = st.vp_w - st.h_len;
        st.h_off = @intFromFloat(@round(scroll.x / max_x_f * @as(f32, @floatFromInt(travel))));
    }
}

fn resolveFitColumns(ctx: *Context, t: *const TableState) void {
    if (!t.has_fit_col or t.cols.len == 0) return;
    const widths = ctx.allocator().alloc(i32, t.cols.len) catch @panic("endTable: OOM");
    @memset(widths, 0);

    var it = t.cells;
    while (it) |cell| : (it = cell.next) {
        if (t.cols[cell.col].width != .fit) continue;
        layout.measure(cell.node, ctx.font);
        widths[cell.col] = @max(widths[cell.col], cell.node.measured_w);
    }
    it = t.cells;
    while (it) |cell| : (it = cell.next) {
        if (t.cols[cell.col].width != .fit) continue;
        cell.node.cfg.width = .{ .fixed = widths[cell.col] };
    }
}

/// Close the table opened by `beginTable`. Resolves fit columns to the max
/// measured cell (header included) and, when sticky, writes the body's final
/// `scroll.x` and the vertical-bar padding onto the header strip.
pub fn endTable(ctx: *Context) void {
    ctx.requireFrame("endTable");
    ctx.requireInteractiveAllowed("endTable");
    Context.requireContract(ctx.table != null, "endTable without a matching beginTable");
    const t = tableState(ctx);
    Context.requireContract(!t.row_open, "endTable with a row still open");
    Context.requireContract(!t.cell_open, "endTable with a cell still open");

    ensureBody(ctx);

    if (t.scroll != null) {
        Context.requireContract(ctx.scroll_stack.items.len > 0, "endTable: missing body ScrollArea");
        const st = &ctx.scroll_stack.items[ctx.scroll_stack.items.len - 1];
        if (t.header_strip_node != null) {
            if (ctx.rect_cache.get(id_mod.hashInt(t.id, header_strip_salt))) |cached| {
                applyHeaderWheel(ctx, cached.rect, st);
            }
        }
        const need_v = st.need_v;
        const bar_thickness = st.bar_thickness;
        const scroll = st.scroll;
        ctx.endScrollArea();
        if (t.header_strip_node) |strip| {
            strip.cfg.scroll_x = @intFromFloat(@round(scroll.x));
            // Match the body viewport: a vertical bar steals `bar_thickness` from
            // the content width. `clip_children` clips to the content box (inside
            // this padding), so header ink does not draw over the gutter.
            // `need_v` is previous-frame, so the bar's first appearance lags
            // the header padding by one frame.
            strip.cfg.padding = .{ 0, if (need_v) bar_thickness else 0, 0, 0 };
        }
    }

    resolveFitColumns(ctx, t);

    ctx.endBox();
    ctx.id_stack.pop();
    ctx.table = null;
}

// ============================================================
// Tests
// ============================================================

fn testCtx() Context {
    return Context.init(std.testing.allocator, font_mod.default_font);
}

fn moveTo(ctx: *Context, x: i32, y: i32) void {
    ctx.pushEvent(.{ .mouse_move = .{ .x = x, .y = y, .modifiers = 0 } });
}

fn pressAt(ctx: *Context, x: i32, y: i32) void {
    moveTo(ctx, x, y);
    ctx.pushEvent(.{ .mouse_down = .{ .x = x, .y = y, .button = 0, .modifiers = 0 } });
}

fn releaseAt(ctx: *Context, x: i32, y: i32) void {
    ctx.pushEvent(.{ .mouse_up = .{ .x = x, .y = y, .button = 0, .modifiers = 0 } });
}

fn clickAt(ctx: *Context, x: i32, y: i32) void {
    pressAt(ctx, x, y);
    releaseAt(ctx, x, y);
}

fn wheelAt(ctx: *Context, x: i32, y: i32, dx: f32, dy: f32) void {
    moveTo(ctx, x, y);
    ctx.pushEvent(.{ .mouse_scroll = .{ .x = x, .y = y, .dx = dx, .dy = dy, .modifiers = 0 } });
}

fn center(rect: Rect) struct { x: i32, y: i32 } {
    return .{
        .x = rect.x + @as(i32, @intCast(rect.w / 2)),
        .y = rect.y + @as(i32, @intCast(rect.h / 2)),
    };
}

fn cellId(ctx: *Context, table_id: Id, row_seed: anytype, col: u64) Id {
    ctx.id_stack.push(table_id);
    ctx.id_stack.push(row_seed);
    const id = ctx.id_stack.makeInt(col);
    ctx.id_stack.pop();
    ctx.id_stack.pop();
    return id;
}

fn headerCellId(ctx: *Context, table_id: Id, col: u64) Id {
    return cellId(ctx, table_id, "header", col);
}

const FitProbe = struct {
    table: Id,
    cols: []const TableCol,
    texts: []const []const []const u8,
    header: bool = true,
};

fn buildFitTable(ctx: *Context, p: FitProbe) void {
    ctx.beginTable(p.table, p.cols, .{
        .width = .fit,
        .height = .fit,
        .column_gap = 0,
        .row_gap = 0,
    });
    if (p.header) ctx.tableHeaderRow();
    for (p.texts) |row| {
        ctx.beginTableRow(.{});
        for (row) |text| {
            ctx.beginTableCell();
            ctx.label(text);
            ctx.endTableCell();
        }
        _ = ctx.endTableRow();
    }
    ctx.endTable();
}

test "table fit columns: cell widths match the max across rows and the header" {
    var ctx = testCtx();
    defer ctx.deinit();
    const TID: Id = 0xA001;
    const cols = [_]TableCol{
        .{ .width = .fit, .header = "Name" },
        .{ .width = .fit, .header = "V" },
    };
    const row0 = [_][]const u8{ "A", "xxxx" };
    const row1 = [_][]const u8{ "AAAA", "x" };
    const rows = [_][]const []const u8{ &row0, &row1 };

    ctx.beginFrame(400, 200);
    buildFitTable(&ctx, .{ .table = TID, .cols = &cols, .texts = &rows });
    ctx.endFrame();

    const h0 = ctx.getNodeRect(headerCellId(&ctx, TID, 0)).?;
    const h1 = ctx.getNodeRect(headerCellId(&ctx, TID, 1)).?;
    const r00 = ctx.getNodeRect(cellId(&ctx, TID, @as(u64, 0), 0)).?;
    const r01 = ctx.getNodeRect(cellId(&ctx, TID, @as(u64, 0), 1)).?;
    const r10 = ctx.getNodeRect(cellId(&ctx, TID, @as(u64, 1), 0)).?;
    const r11 = ctx.getNodeRect(cellId(&ctx, TID, @as(u64, 1), 1)).?;

    try std.testing.expectEqual(h0.w, r00.w);
    try std.testing.expectEqual(r00.w, r10.w);
    try std.testing.expectEqual(h1.w, r01.w);
    try std.testing.expectEqual(r01.w, r11.w);
    // "Name" / "AAAA" = 4 glyphs; "xxxx" = 4 glyphs. Default font is 8px/glyph.
    try std.testing.expectEqual(@as(u32, 32), h0.w);
    try std.testing.expectEqual(@as(u32, 32), h1.w);
    try std.testing.expectEqual(h0.x, r00.x);
    try std.testing.expectEqual(r00.x, r10.x);
    try std.testing.expectEqual(h1.x, r01.x);
    try std.testing.expectEqual(r01.x, r11.x);
}

test "table fit columns: a content change realigns on the same frame" {
    var ctx = testCtx();
    defer ctx.deinit();
    const TID: Id = 0xA002;
    const cols = [_]TableCol{.{ .width = .fit, .header = "H" }};

    ctx.beginFrame(400, 200);
    buildFitTable(&ctx, .{
        .table = TID,
        .cols = &cols,
        .texts = &[_][]const []const u8{&[_][]const u8{"A"}},
    });
    ctx.endFrame();
    try std.testing.expectEqual(@as(u32, 8), ctx.getNodeRect(cellId(&ctx, TID, @as(u64, 0), 0)).?.w);

    ctx.beginFrame(400, 200);
    buildFitTable(&ctx, .{
        .table = TID,
        .cols = &cols,
        .texts = &[_][]const []const u8{&[_][]const u8{"WIDEHEADER"}},
    });
    ctx.endFrame();
    const body = ctx.getNodeRect(cellId(&ctx, TID, @as(u64, 0), 0)).?;
    const head = ctx.getNodeRect(headerCellId(&ctx, TID, 0)).?;
    try std.testing.expectEqual(body.w, head.w);
    try std.testing.expectEqual(@as(u32, 80), body.w);
}

test "table mixed columns: fixed / fit / grow / percent share one row width" {
    var ctx = testCtx();
    defer ctx.deinit();
    const TID: Id = 0xA003;
    const cols = [_]TableCol{
        .{ .width = .{ .fixed = 40 }, .header = "A" },
        .{ .width = .fit, .header = "B" },
        .{ .width = .{ .percent = 0.25 }, .header = "C" },
        .{ .width = .{ .grow = 1 }, .header = "D" },
    };
    const HOST: Id = 0xA0030;

    ctx.beginFrame(500, 200);
    ctx.beginBox(.{ .id = HOST, .width = .{ .fixed = 400 }, .height = .fit });
    ctx.beginTable(TID, &cols, .{
        .width = .{ .grow = 1 },
        .height = .fit,
        .column_gap = 0,
        .h_scroll = false,
    });
    ctx.tableHeaderRow();
    ctx.beginTableRow(.{});
    ctx.beginTableCell();
    ctx.label("1");
    ctx.endTableCell();
    ctx.beginTableCell();
    ctx.label("xx");
    ctx.endTableCell();
    ctx.beginTableCell();
    ctx.label("3");
    ctx.endTableCell();
    ctx.beginTableCell();
    ctx.label("4");
    ctx.endTableCell();
    _ = ctx.endTableRow();
    ctx.endTable();
    ctx.endBox();
    ctx.endFrame();

    const a = ctx.getNodeRect(cellId(&ctx, TID, @as(u64, 0), 0)).?;
    const b = ctx.getNodeRect(cellId(&ctx, TID, @as(u64, 0), 1)).?;
    const c = ctx.getNodeRect(cellId(&ctx, TID, @as(u64, 0), 2)).?;
    const d = ctx.getNodeRect(cellId(&ctx, TID, @as(u64, 0), 3)).?;
    try std.testing.expectEqual(@as(u32, 40), a.w);
    try std.testing.expectEqual(@as(u32, 16), b.w); // "xx"
    try std.testing.expectEqual(@as(u32, 100), c.w); // 0.25 * 400
    try std.testing.expectEqual(@as(u32, 244), d.w); // 400 - 40 - 16 - 100
    try std.testing.expectEqual(a.x + @as(i32, @intCast(a.w)), b.x);
    try std.testing.expectEqual(b.x + @as(i32, @intCast(b.w)), c.x);
    try std.testing.expectEqual(c.x + @as(i32, @intCast(c.w)), d.x);

    const ha = ctx.getNodeRect(headerCellId(&ctx, TID, 0)).?;
    try std.testing.expectEqual(a.x, ha.x);
    try std.testing.expectEqual(a.w, ha.w);
}

test "table stretch_cells: false keeps intrinsic cell heights; true matches the row max" {
    var ctx = testCtx();
    defer ctx.deinit();
    const TID: Id = 0xA004;
    const cols = [_]TableCol{
        .{ .width = .{ .fixed = 40 } },
        .{ .width = .{ .fixed = 40 } },
    };

    ctx.beginFrame(200, 200);
    ctx.beginTable(TID, &cols, .{ .width = .fit, .height = .fit, .stretch_cells = false });
    ctx.beginTableRow(.{});
    ctx.beginTableCell();
    ctx.custom(.{ .x = 16, .y = 40 }, dummyDraw, undefined);
    ctx.endTableCell();
    ctx.beginTableCell();
    ctx.custom(.{ .x = 16, .y = 16 }, dummyDraw, undefined);
    ctx.endTableCell();
    _ = ctx.endTableRow();
    ctx.endTable();
    ctx.endFrame();

    const a = ctx.getNodeRect(cellId(&ctx, TID, @as(u64, 0), 0)).?;
    const b = ctx.getNodeRect(cellId(&ctx, TID, @as(u64, 0), 1)).?;
    try std.testing.expectEqual(@as(u32, 40), a.h);
    try std.testing.expectEqual(@as(u32, 16), b.h);

    ctx.beginFrame(200, 200);
    ctx.beginTable(TID, &cols, .{ .width = .fit, .height = .fit, .stretch_cells = true });
    ctx.beginTableRow(.{});
    ctx.beginTableCell();
    ctx.custom(.{ .x = 16, .y = 40 }, dummyDraw, undefined);
    ctx.endTableCell();
    ctx.beginTableCell();
    ctx.custom(.{ .x = 16, .y = 16 }, dummyDraw, undefined);
    ctx.endTableCell();
    _ = ctx.endTableRow();
    ctx.endTable();
    ctx.endFrame();

    const a2 = ctx.getNodeRect(cellId(&ctx, TID, @as(u64, 0), 0)).?;
    const b2 = ctx.getNodeRect(cellId(&ctx, TID, @as(u64, 0), 1)).?;
    try std.testing.expectEqual(a2.h, b2.h);
    try std.testing.expectEqual(@as(u32, 40), a2.h);
}

fn dummyDraw(_: *anyopaque, _: *context_mod.DrawList, _: Rect) void {}

test "table stretch_cells: a fixed-height row writes that height, not the content max" {
    var ctx = testCtx();
    defer ctx.deinit();
    const TID: Id = 0xA005;
    const cols = [_]TableCol{
        .{ .width = .{ .fixed = 40 } },
        .{ .width = .{ .fixed = 40 } },
    };

    ctx.beginFrame(200, 200);
    ctx.beginTable(TID, &cols, .{ .width = .fit, .height = .fit, .stretch_cells = true });
    ctx.beginTableRow(.{ .height = .{ .fixed = 24 } });
    ctx.beginTableCell();
    ctx.custom(.{ .x = 16, .y = 40 }, dummyDraw, undefined);
    ctx.endTableCell();
    ctx.beginTableCell();
    ctx.custom(.{ .x = 16, .y = 8 }, dummyDraw, undefined);
    ctx.endTableCell();
    _ = ctx.endTableRow();
    ctx.endTable();
    ctx.endFrame();

    const a = ctx.getNodeRect(cellId(&ctx, TID, @as(u64, 0), 0)).?;
    const b = ctx.getNodeRect(cellId(&ctx, TID, @as(u64, 0), 1)).?;
    try std.testing.expectEqual(@as(u32, 24), a.h);
    try std.testing.expectEqual(@as(u32, 24), b.h);
}

test "table degenerate: zero columns, zero rows, and an empty first-frame cache" {
    var ctx = testCtx();
    defer ctx.deinit();
    const TID: Id = 0xA006;
    const cols = [_]TableCol{};

    ctx.beginFrame(200, 200);
    ctx.beginTable(TID, &cols, .{ .width = .fit, .height = .fit });
    ctx.tableHeaderRow();
    ctx.endTable();
    ctx.endFrame();
    try std.testing.expect(ctx.getNodeRect(TID) != null);

    const TID2: Id = 0xA007;
    const cols2 = [_]TableCol{.{ .width = .{ .fixed = 40 }, .header = "H" }};
    ctx.beginFrame(200, 200);
    ctx.beginTable(TID2, &cols2, .{ .width = .fit, .height = .fit });
    ctx.tableHeaderRow();
    ctx.endTable();
    ctx.endFrame();
    try std.testing.expect(ctx.getNodeRect(headerCellId(&ctx, TID2, 0)) != null);

    const RID: Id = 0xA0071;
    ctx.beginFrame(200, 200);
    clickAt(&ctx, 10, 10);
    ctx.beginTable(TID2, &cols2, .{ .width = .fit, .height = .fit });
    ctx.beginTableRow(.{ .interactive = .{ .id = RID, .selected = true } });
    ctx.beginTableCell();
    ctx.label("x");
    ctx.endTableCell();
    const first = ctx.endTableRow();
    ctx.endTable();
    ctx.endFrame();
    try std.testing.expect(!first.activated);
}

test "table viewport resize: grow column follows the new host width" {
    var ctx = testCtx();
    defer ctx.deinit();
    const TID: Id = 0xA008;
    const HOST: Id = 0xA0080;
    const cols = [_]TableCol{
        .{ .width = .{ .fixed = 40 } },
        .{ .width = .{ .grow = 1 } },
    };

    const build = struct {
        fn f(c: *Context, host_w: i32) void {
            c.beginBox(.{ .id = HOST, .width = .{ .fixed = host_w }, .height = .fit });
            c.beginTable(TID, &cols, .{ .width = .{ .grow = 1 }, .height = .fit, .column_gap = 0 });
            c.beginTableRow(.{});
            c.beginTableCell();
            c.label("a");
            c.endTableCell();
            c.beginTableCell();
            c.label("b");
            c.endTableCell();
            _ = c.endTableRow();
            c.endTable();
            c.endBox();
        }
    }.f;

    ctx.beginFrame(500, 200);
    build(&ctx, 200);
    ctx.endFrame();
    try std.testing.expectEqual(@as(u32, 160), ctx.getNodeRect(cellId(&ctx, TID, @as(u64, 0), 1)).?.w);

    ctx.beginFrame(500, 200);
    build(&ctx, 400);
    ctx.endFrame();
    try std.testing.expectEqual(@as(u32, 360), ctx.getNodeRect(cellId(&ctx, TID, @as(u64, 0), 1)).?.w);
}

fn buildScrollTable(ctx: *Context, table_id: Id, scroll: *Vec2f, rows: usize, h_scroll: bool, opts_h: i32) void {
    const cols = [_]TableCol{
        .{ .width = if (h_scroll) .{ .fixed = 80 } else .{ .grow = 1 }, .header = "Name" },
        .{ .width = .{ .fixed = 80 }, .header = "Value" },
    };
    ctx.beginTable(table_id, &cols, .{
        .width = .{ .fixed = 160 },
        .height = .{ .fixed = opts_h },
        .column_gap = 0,
        .row_gap = 0,
        .scroll = scroll,
        .h_scroll = h_scroll,
        .wheel_px = 16,
        .bar_thickness = 8,
    });
    ctx.tableHeaderRow();
    var i: usize = 0;
    while (i < rows) : (i += 1) {
        ctx.beginTableRow(.{});
        ctx.beginTableCell();
        ctx.label("rowname");
        ctx.endTableCell();
        ctx.beginTableCell();
        ctx.label("valuexx");
        ctx.endTableCell();
        _ = ctx.endTableRow();
    }
    ctx.endTable();
}

test "table sticky header: header y is unchanged after a vertical scroll" {
    var ctx = testCtx();
    defer ctx.deinit();
    const TID: Id = 0xA010;
    var scroll: Vec2f = .{};

    ctx.beginFrame(300, 300);
    buildScrollTable(&ctx, TID, &scroll, 20, false, 80);
    ctx.endFrame();
    const header_y0 = ctx.getNodeRect(id_mod.hashInt(TID, header_row_salt)).?.y;
    const body0 = ctx.getNodeRect(cellId(&ctx, TID, @as(u64, 0), 0)).?;

    ctx.beginFrame(300, 300);
    buildScrollTable(&ctx, TID, &scroll, 20, false, 80);
    ctx.endFrame();

    const vp = ctx.getNodeRect(id_mod.hashInt(TID, body_vp_salt)).?;
    const hc = center(vp);
    ctx.beginFrame(300, 300);
    wheelAt(&ctx, hc.x, hc.y, 0, -4);
    buildScrollTable(&ctx, TID, &scroll, 20, false, 80);
    ctx.endFrame();

    try std.testing.expect(scroll.y > 0);
    const header_y1 = ctx.getNodeRect(id_mod.hashInt(TID, header_row_salt)).?.y;
    const body1 = ctx.getNodeRect(cellId(&ctx, TID, @as(u64, 0), 0)).?;
    try std.testing.expectEqual(header_y0, header_y1);
    try std.testing.expect(body1.y < body0.y);
}

test "table sticky header: a vertical scrollbar keeps header and body column x aligned" {
    var ctx = testCtx();
    defer ctx.deinit();
    const TID: Id = 0xA011;
    var scroll: Vec2f = .{};

    var frame: usize = 0;
    while (frame < 3) : (frame += 1) {
        ctx.beginFrame(300, 300);
        buildScrollTable(&ctx, TID, &scroll, 20, false, 80);
        ctx.endFrame();
    }

    const vthumb = id_mod.hashInt(id_mod.hashInt(TID, body_vp_salt), 2);
    try std.testing.expect(ctx.getNodeRect(vthumb) != null);

    const hx0 = ctx.getNodeRect(headerCellId(&ctx, TID, 0)).?.x;
    const hx1 = ctx.getNodeRect(headerCellId(&ctx, TID, 1)).?.x;
    const bx0 = ctx.getNodeRect(cellId(&ctx, TID, @as(u64, 0), 0)).?.x;
    const bx1 = ctx.getNodeRect(cellId(&ctx, TID, @as(u64, 0), 1)).?.x;
    try std.testing.expectEqual(hx0, bx0);
    try std.testing.expectEqual(hx1, bx1);
}

fn buildHScrollTable(ctx: *Context, table_id: Id, scroll: *Vec2f, rows: usize) void {
    const cols = [_]TableCol{
        .{ .width = .{ .fixed = 120 }, .header = "LeftCol" },
        .{ .width = .{ .fixed = 120 }, .header = "RightCol" },
    };
    ctx.beginTable(table_id, &cols, .{
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 80 },
        .column_gap = 0,
        .scroll = scroll,
        .h_scroll = true,
        .wheel_px = 16,
        .bar_thickness = 8,
    });
    ctx.tableHeaderRow();
    var i: usize = 0;
    while (i < rows) : (i += 1) {
        ctx.beginTableRow(.{});
        ctx.beginTableCell();
        ctx.label("leftcell");
        ctx.endTableCell();
        ctx.beginTableCell();
        ctx.label("rightcel");
        ctx.endTableCell();
        _ = ctx.endTableRow();
    }
    ctx.endTable();
}

test "table horizontal scroll: header and body share the same rounded x offset" {
    var ctx = testCtx();
    defer ctx.deinit();
    const TID: Id = 0xA012;
    var scroll: Vec2f = .{};

    var warm: usize = 0;
    while (warm < 2) : (warm += 1) {
        ctx.beginFrame(300, 300);
        buildHScrollTable(&ctx, TID, &scroll, 3);
        ctx.endFrame();
    }

    const vp = ctx.getNodeRect(id_mod.hashInt(TID, body_vp_salt)).?;
    const hc = center(vp);
    const h0_before = ctx.getNodeRect(headerCellId(&ctx, TID, 0)).?;
    const b0_before = ctx.getNodeRect(cellId(&ctx, TID, @as(u64, 0), 0)).?;
    try std.testing.expectEqual(h0_before.x, b0_before.x);

    ctx.beginFrame(300, 300);
    wheelAt(&ctx, hc.x, hc.y, -3, 0);
    buildHScrollTable(&ctx, TID, &scroll, 3);
    ctx.endFrame();

    try std.testing.expect(scroll.x > 0);
    const h0 = ctx.getNodeRect(headerCellId(&ctx, TID, 0)).?;
    const b0 = ctx.getNodeRect(cellId(&ctx, TID, @as(u64, 0), 0)).?;
    const h1 = ctx.getNodeRect(headerCellId(&ctx, TID, 1)).?;
    const b1 = ctx.getNodeRect(cellId(&ctx, TID, @as(u64, 0), 1)).?;
    try std.testing.expectEqual(h0.x, b0.x);
    try std.testing.expectEqual(h1.x, b1.x);
    try std.testing.expect(h0.x < h0_before.x);

    const sx: i32 = @intFromFloat(@round(scroll.x));
    try std.testing.expectEqual(h0_before.x - sx, h0.x);
}

test "table horizontal scroll: wheel on the header strip moves header and body together" {
    var ctx = testCtx();
    defer ctx.deinit();
    const TID: Id = 0xA013;
    var scroll: Vec2f = .{};

    var warm: usize = 0;
    while (warm < 2) : (warm += 1) {
        ctx.beginFrame(300, 300);
        buildHScrollTable(&ctx, TID, &scroll, 3);
        ctx.endFrame();
    }

    const strip = ctx.getNodeRect(id_mod.hashInt(TID, header_strip_salt)).?;
    const hc = center(strip);
    const before = ctx.getNodeRect(headerCellId(&ctx, TID, 0)).?.x;

    ctx.beginFrame(300, 300);
    wheelAt(&ctx, hc.x, hc.y, -2, 0);
    buildHScrollTable(&ctx, TID, &scroll, 3);
    ctx.endFrame();

    try std.testing.expect(scroll.x > 0);
    const hx = ctx.getNodeRect(headerCellId(&ctx, TID, 0)).?.x;
    const bx = ctx.getNodeRect(cellId(&ctx, TID, @as(u64, 0), 0)).?.x;
    try std.testing.expectEqual(hx, bx);
    try std.testing.expect(hx < before);
}

test "table horizontal scroll: clamp at the end keeps header and body aligned" {
    var ctx = testCtx();
    defer ctx.deinit();
    const TID: Id = 0xA014;
    var scroll: Vec2f = .{};

    var warm: usize = 0;
    while (warm < 2) : (warm += 1) {
        ctx.beginFrame(300, 300);
        buildHScrollTable(&ctx, TID, &scroll, 3);
        ctx.endFrame();
    }

    const vp = ctx.getNodeRect(id_mod.hashInt(TID, body_vp_salt)).?;
    const hc = center(vp);
    ctx.beginFrame(300, 300);
    wheelAt(&ctx, hc.x, hc.y, -40, 0);
    buildHScrollTable(&ctx, TID, &scroll, 3);
    ctx.endFrame();

    const max_x = scroll.x;
    try std.testing.expect(max_x > 0);
    ctx.beginFrame(300, 300);
    wheelAt(&ctx, hc.x, hc.y, -40, 0);
    buildHScrollTable(&ctx, TID, &scroll, 3);
    ctx.endFrame();
    try std.testing.expectEqual(max_x, scroll.x);
    try std.testing.expectEqual(
        ctx.getNodeRect(headerCellId(&ctx, TID, 0)).?.x,
        ctx.getNodeRect(cellId(&ctx, TID, @as(u64, 0), 0)).?.x,
    );
}

test "table interactive row: selected look, click activate, and pollListNav match a listbox row" {
    var ctx = testCtx();
    defer ctx.deinit();
    const TID: Id = 0xA020;
    const R0: Id = 0xA021;
    const R1: Id = 0xA022;
    const cols = [_]TableCol{.{ .width = .{ .fixed = 80 } }};

    const build = struct {
        fn f(c: *Context, selected: Id) [2]TableRowResult {
            var out: [2]TableRowResult = undefined;
            c.beginTable(TID, &cols, .{ .width = .fit, .height = .fit });
            c.beginTableRow(.{ .interactive = .{ .id = R0, .selected = selected == R0 } });
            c.beginTableCell();
            c.label("one");
            c.endTableCell();
            out[0] = c.endTableRow();
            c.beginTableRow(.{ .interactive = .{ .id = R1, .selected = selected == R1 } });
            c.beginTableCell();
            c.label("two");
            c.endTableCell();
            out[1] = c.endTableRow();
            c.endTable();
            return out;
        }
    }.f;

    ctx.beginFrame(200, 200);
    _ = build(&ctx, R0);
    ctx.endFrame();
    try std.testing.expectEqual(@as(usize, 1), ctx.focus_order.items.len);
    try std.testing.expectEqual(R0, ctx.focus_order.items[0]);

    const c1 = center(ctx.getNodeRect(R1).?);
    ctx.beginFrame(200, 200);
    clickAt(&ctx, c1.x, c1.y);
    const res = build(&ctx, R0);
    ctx.endFrame();
    try std.testing.expect(res[1].activated);
    try std.testing.expectEqual(R1, ctx.focusedId());

    ctx.beginFrame(200, 200);
    ctx.pushEvent(.{ .key_down = .{ .code = input_mod.key.down, .modifiers = 0, .repeat = false } });
    ctx.beginTable(TID, &cols, .{ .width = .fit, .height = .fit });
    ctx.beginTableRow(.{ .interactive = .{ .id = R1, .selected = true } });
    ctx.beginTableCell();
    ctx.label("two");
    ctx.endTableCell();
    _ = ctx.endTableRow();
    ctx.endTable();
    try std.testing.expectEqual(.next, ctx.pollListNav(R1));
    ctx.endFrame();
}

test "table interactive row: a cell checkbox takes press; the row does not activate" {
    var ctx = testCtx();
    defer ctx.deinit();
    const TID: Id = 0xA030;
    const RID: Id = 0xA031;
    const cols = [_]TableCol{
        .{ .width = .{ .fixed = 40 } },
        .{ .width = .fit },
    };
    var checked = false;

    const build = struct {
        fn f(c: *Context, value: *bool) TableRowResult {
            c.beginTable(TID, &cols, .{ .width = .fit, .height = .fit, .column_gap = 4 });
            c.beginTableRow(.{ .interactive = .{ .id = RID, .selected = false } });
            c.beginTableCell();
            c.label("x");
            c.endTableCell();
            c.beginTableCell();
            _ = c.checkbox("On", value);
            c.endTableCell();
            const r = c.endTableRow();
            c.endTable();
            return r;
        }
    }.f;

    ctx.beginFrame(300, 200);
    _ = build(&ctx, &checked);
    ctx.endFrame();

    ctx.id_stack.push(TID);
    ctx.id_stack.push(RID);
    const box_id = ctx.id_stack.make("On");
    ctx.id_stack.pop();
    ctx.id_stack.pop();
    const box = ctx.getNodeRect(box_id).?;
    const bc = center(box);

    ctx.beginFrame(300, 200);
    clickAt(&ctx, bc.x, bc.y);
    const row = build(&ctx, &checked);
    ctx.endFrame();
    try std.testing.expect(checked);
    try std.testing.expect(!row.activated);
}

test "table interactive row: cell hover wins over the row" {
    var ctx = testCtx();
    defer ctx.deinit();
    const TID: Id = 0xA032;
    const RID: Id = 0xA033;
    const cols = [_]TableCol{
        .{ .width = .{ .fixed = 40 } },
        .{ .width = .fit },
    };
    var checked = false;

    ctx.beginFrame(300, 200);
    ctx.beginTable(TID, &cols, .{ .width = .fit, .height = .fit, .column_gap = 4 });
    ctx.beginTableRow(.{ .interactive = .{ .id = RID, .selected = false } });
    ctx.beginTableCell();
    ctx.label("x");
    ctx.endTableCell();
    ctx.beginTableCell();
    _ = ctx.checkbox("On", &checked);
    ctx.endTableCell();
    _ = ctx.endTableRow();
    ctx.endTable();
    ctx.endFrame();

    ctx.id_stack.push(TID);
    ctx.id_stack.push(RID);
    const box_id = ctx.id_stack.make("On");
    ctx.id_stack.pop();
    ctx.id_stack.pop();
    const bc = center(ctx.getNodeRect(box_id).?);

    ctx.beginFrame(300, 200);
    moveTo(&ctx, bc.x, bc.y);
    ctx.beginTable(TID, &cols, .{ .width = .fit, .height = .fit, .column_gap = 4 });
    ctx.beginTableRow(.{ .interactive = .{ .id = RID, .selected = false } });
    ctx.beginTableCell();
    ctx.label("x");
    ctx.endTableCell();
    ctx.beginTableCell();
    _ = ctx.checkbox("On", &checked);
    ctx.endTableCell();
    _ = ctx.endTableRow();
    ctx.endTable();
    ctx.endFrame();
    try std.testing.expectEqual(box_id, ctx.state.next_hot_id);
}

test "table cell auto-ids: the same label in two rows (and two tables) does not collide" {
    var ctx = testCtx();
    defer ctx.deinit();
    const A: Id = 0xA040;
    const B: Id = 0xA041;
    const cols = [_]TableCol{.{ .width = .fit }};
    var a0 = false;
    var a1 = false;
    var b0 = false;

    const build = struct {
        fn f(c: *Context, va0: *bool, va1: *bool, vb0: *bool) void {
            c.beginTable(A, &cols, .{ .width = .fit, .height = .fit });
            c.beginTableRow(.{});
            c.beginTableCell();
            _ = c.checkbox("Enabled", va0);
            c.endTableCell();
            _ = c.endTableRow();
            c.beginTableRow(.{});
            c.beginTableCell();
            _ = c.checkbox("Enabled", va1);
            c.endTableCell();
            _ = c.endTableRow();
            c.endTable();
            c.beginTable(B, &cols, .{ .width = .fit, .height = .fit });
            c.beginTableRow(.{});
            c.beginTableCell();
            _ = c.checkbox("Enabled", vb0);
            c.endTableCell();
            _ = c.endTableRow();
            c.endTable();
        }
    }.f;

    ctx.beginFrame(400, 300);
    build(&ctx, &a0, &a1, &b0);
    ctx.endFrame();

    ctx.id_stack.push(A);
    ctx.id_stack.push(@as(u64, 0));
    const id_a0 = ctx.id_stack.make("Enabled");
    ctx.id_stack.pop();
    ctx.id_stack.push(@as(u64, 1));
    const id_a1 = ctx.id_stack.make("Enabled");
    ctx.id_stack.pop();
    ctx.id_stack.pop();
    ctx.id_stack.push(B);
    ctx.id_stack.push(@as(u64, 0));
    const id_b0 = ctx.id_stack.make("Enabled");
    ctx.id_stack.pop();
    ctx.id_stack.pop();
    try std.testing.expect(id_a0 != id_a1);
    try std.testing.expect(id_a0 != id_b0);
    try std.testing.expect(ctx.getNodeRect(id_a0) != null);
    try std.testing.expect(ctx.getNodeRect(id_a1) != null);
    try std.testing.expect(ctx.getNodeRect(id_b0) != null);

    const c1 = center(ctx.getNodeRect(id_a1).?);
    ctx.beginFrame(400, 300);
    clickAt(&ctx, c1.x, c1.y);
    build(&ctx, &a0, &a1, &b0);
    ctx.endFrame();
    try std.testing.expect(!a0);
    try std.testing.expect(a1);
    try std.testing.expect(!b0);
}

test "table interactive row: same-frame press+release activates; clip-out release does not" {
    var ctx = testCtx();
    defer ctx.deinit();
    const TID: Id = 0xA050;
    const RID: Id = 0xA051;
    var scroll: Vec2f = .{};
    const cols = [_]TableCol{.{ .width = .{ .grow = 1 } }};

    const build = struct {
        fn f(c: *Context, s: *Vec2f) TableRowResult {
            c.beginTable(TID, &cols, .{
                .width = .{ .fixed = 80 },
                .height = .{ .fixed = 40 },
                .scroll = s,
            });
            var i: usize = 0;
            var last: TableRowResult = .{};
            while (i < 12) : (i += 1) {
                const id: Id = RID + i;
                c.beginTableRow(.{ .interactive = .{ .id = id, .selected = i == 0 } });
                c.beginTableCell();
                c.label("rowxxxx");
                c.endTableCell();
                last = c.endTableRow();
            }
            c.endTable();
            return last;
        }
    }.f;

    ctx.beginFrame(200, 200);
    _ = build(&ctx, &scroll);
    ctx.endFrame();
    ctx.beginFrame(200, 200);
    _ = build(&ctx, &scroll);
    ctx.endFrame();

    const row = ctx.getNodeRect(RID).?;
    const rc = center(row);
    ctx.beginFrame(200, 200);
    clickAt(&ctx, rc.x, rc.y);
    ctx.beginTable(TID, &cols, .{
        .width = .{ .fixed = 80 },
        .height = .{ .fixed = 40 },
        .scroll = &scroll,
    });
    ctx.beginTableRow(.{ .interactive = .{ .id = RID, .selected = true } });
    ctx.beginTableCell();
    ctx.label("rowxxxx");
    ctx.endTableCell();
    const same = ctx.endTableRow();
    ctx.endTable();
    ctx.endFrame();
    try std.testing.expect(same.activated);

    ctx.beginFrame(200, 200);
    pressAt(&ctx, rc.x, rc.y);
    ctx.beginTable(TID, &cols, .{
        .width = .{ .fixed = 80 },
        .height = .{ .fixed = 40 },
        .scroll = &scroll,
    });
    ctx.beginTableRow(.{ .interactive = .{ .id = RID, .selected = true } });
    ctx.beginTableCell();
    ctx.label("rowxxxx");
    ctx.endTableCell();
    _ = ctx.endTableRow();
    ctx.endTable();
    ctx.endFrame();
    try std.testing.expectEqual(RID, ctx.state.active_id);

    ctx.beginFrame(200, 200);
    releaseAt(&ctx, 400, 400);
    ctx.beginTable(TID, &cols, .{
        .width = .{ .fixed = 80 },
        .height = .{ .fixed = 40 },
        .scroll = &scroll,
    });
    ctx.beginTableRow(.{ .interactive = .{ .id = RID, .selected = true } });
    ctx.beginTableCell();
    ctx.label("rowxxxx");
    ctx.endTableCell();
    const outside = ctx.endTableRow();
    ctx.endTable();
    ctx.endFrame();
    try std.testing.expect(!outside.activated);
    try std.testing.expectEqual(@as(Id, 0), ctx.state.active_id);
}

test "table interactive row: press-drag-release keeps active_submitted so the drag is not cleared" {
    var ctx = testCtx();
    defer ctx.deinit();
    const TID: Id = 0xA052;
    const RID: Id = 0xA053;
    const cols = [_]TableCol{.{ .width = .{ .fixed = 80 } }};

    ctx.beginFrame(200, 200);
    ctx.beginTable(TID, &cols, .{ .width = .fit, .height = .fit });
    ctx.beginTableRow(.{ .interactive = .{ .id = RID, .selected = false } });
    ctx.beginTableCell();
    ctx.label("dragme");
    ctx.endTableCell();
    _ = ctx.endTableRow();
    ctx.endTable();
    ctx.endFrame();

    const rc = center(ctx.getNodeRect(RID).?);
    ctx.beginFrame(200, 200);
    pressAt(&ctx, rc.x, rc.y);
    ctx.beginTable(TID, &cols, .{ .width = .fit, .height = .fit });
    ctx.beginTableRow(.{ .interactive = .{ .id = RID, .selected = false } });
    ctx.beginTableCell();
    ctx.label("dragme");
    ctx.endTableCell();
    _ = ctx.endTableRow();
    ctx.endTable();
    ctx.endFrame();
    try std.testing.expectEqual(RID, ctx.state.active_id);

    ctx.beginFrame(200, 200);
    moveTo(&ctx, rc.x + 20, rc.y + 4);
    ctx.beginTable(TID, &cols, .{ .width = .fit, .height = .fit });
    ctx.beginTableRow(.{ .interactive = .{ .id = RID, .selected = false } });
    ctx.beginTableCell();
    ctx.label("dragme");
    ctx.endTableCell();
    _ = ctx.endTableRow();
    ctx.endTable();
    ctx.endFrame();
    try std.testing.expectEqual(RID, ctx.state.active_id);
}

test "table interactive row: disabled and an open popup suppress activate" {
    var ctx = testCtx();
    defer ctx.deinit();
    const TID: Id = 0xA054;
    const RID: Id = 0xA055;
    const cols = [_]TableCol{.{ .width = .{ .fixed = 80 } }};

    ctx.beginFrame(200, 200);
    ctx.beginTable(TID, &cols, .{ .width = .fit, .height = .fit });
    ctx.beginTableRow(.{ .interactive = .{ .id = RID, .selected = false } });
    ctx.beginTableCell();
    ctx.label("row");
    ctx.endTableCell();
    _ = ctx.endTableRow();
    ctx.endTable();
    ctx.endFrame();
    const rc = center(ctx.getNodeRect(RID).?);

    ctx.beginFrame(200, 200);
    clickAt(&ctx, rc.x, rc.y);
    ctx.beginDisabled();
    ctx.beginTable(TID, &cols, .{ .width = .fit, .height = .fit });
    ctx.beginTableRow(.{ .interactive = .{ .id = RID, .selected = false } });
    ctx.beginTableCell();
    ctx.label("row");
    ctx.endTableCell();
    const dis = ctx.endTableRow();
    ctx.endTable();
    ctx.endDisabled();
    ctx.endFrame();
    try std.testing.expect(!dis.activated);

    ctx.beginFrame(200, 200);
    clickAt(&ctx, rc.x, rc.y);
    ctx.openPopup(0xA056, .{ .x = 0, .y = 0 });
    ctx.beginTable(TID, &cols, .{ .width = .fit, .height = .fit });
    ctx.beginTableRow(.{ .interactive = .{ .id = RID, .selected = false } });
    ctx.beginTableCell();
    ctx.label("row");
    ctx.endTableCell();
    const pop = ctx.endTableRow();
    ctx.endTable();
    ctx.endFrame();
    try std.testing.expect(!pop.activated);
}

test "table interactive row: a cell that opens a popup in the same frame does not activate the row" {
    var ctx = testCtx();
    defer ctx.deinit();
    const TID: Id = 0xA057;
    const RID: Id = 0xA058;
    const BID: Id = 0xA059;
    const PID: Id = 0xA05A;
    const cols = [_]TableCol{.{ .width = .fit }};

    ctx.beginFrame(300, 200);
    ctx.beginTable(TID, &cols, .{ .width = .fit, .height = .fit });
    ctx.beginTableRow(.{ .interactive = .{ .id = RID, .selected = false } });
    ctx.beginTableCell();
    _ = ctx.buttonId(BID, "Menu", .{});
    ctx.endTableCell();
    _ = ctx.endTableRow();
    ctx.endTable();
    ctx.endFrame();

    const bc = center(ctx.getNodeRect(BID).?);
    ctx.beginFrame(300, 200);
    clickAt(&ctx, bc.x, bc.y);
    ctx.beginTable(TID, &cols, .{ .width = .fit, .height = .fit });
    ctx.beginTableRow(.{ .interactive = .{ .id = RID, .selected = false } });
    ctx.beginTableCell();
    if (ctx.buttonId(BID, "Menu", .{}).clicked) ctx.openPopup(PID, .{ .x = 8, .y = 8 });
    ctx.endTableCell();
    const row = ctx.endTableRow();
    ctx.endTable();
    ctx.endFrame();
    try std.testing.expect(ctx.popup_state != null);
    try std.testing.expect(!row.activated);
}

test "table tab order: interactive row then its focusable cells" {
    var ctx = testCtx();
    defer ctx.deinit();
    const TID: Id = 0xA060;
    const RID: Id = 0xA061;
    const cols = [_]TableCol{
        .{ .width = .{ .fixed = 40 } },
        .{ .width = .fit },
    };
    var checked = false;

    ctx.beginFrame(300, 200);
    ctx.beginTable(TID, &cols, .{ .width = .fit, .height = .fit });
    ctx.beginTableRow(.{ .interactive = .{ .id = RID, .selected = true } });
    ctx.beginTableCell();
    ctx.label("x");
    ctx.endTableCell();
    ctx.beginTableCell();
    _ = ctx.checkbox("On", &checked);
    ctx.endTableCell();
    _ = ctx.endTableRow();
    ctx.endTable();
    ctx.endFrame();

    ctx.id_stack.push(TID);
    ctx.id_stack.push(RID);
    const box_id = ctx.id_stack.make("On");
    ctx.id_stack.pop();
    ctx.id_stack.pop();

    try std.testing.expectEqual(@as(usize, 2), ctx.focus_order.items.len);
    try std.testing.expectEqual(RID, ctx.focus_order.items[0]);
    try std.testing.expectEqual(box_id, ctx.focus_order.items[1]);
}

test "table no-scroll: header is an ordinary row (no sticky strip)" {
    var ctx = testCtx();
    defer ctx.deinit();
    const TID: Id = 0xA070;
    const cols = [_]TableCol{.{ .width = .{ .fixed = 40 }, .header = "H" }};

    ctx.beginFrame(200, 200);
    ctx.beginTable(TID, &cols, .{ .width = .fit, .height = .fit });
    ctx.tableHeaderRow();
    ctx.beginTableRow(.{});
    ctx.beginTableCell();
    ctx.label("b");
    ctx.endTableCell();
    _ = ctx.endTableRow();
    ctx.endTable();
    ctx.endFrame();

    try std.testing.expectEqual(@as(?Rect, null), ctx.getNodeRect(id_mod.hashInt(TID, header_strip_salt)));
    try std.testing.expect(ctx.getNodeRect(id_mod.hashInt(TID, header_row_salt)) != null);
}

test "table fixed columns align across rows without a fit walk" {
    var ctx = testCtx();
    defer ctx.deinit();
    const TID: Id = 0xA071;
    const cols = [_]TableCol{
        .{ .width = .{ .fixed = 24 } },
        .{ .width = .{ .fixed = 48 } },
    };

    ctx.beginFrame(200, 200);
    ctx.beginTable(TID, &cols, .{ .width = .fit, .height = .fit, .column_gap = 4 });
    var r: usize = 0;
    while (r < 3) : (r += 1) {
        ctx.beginTableRow(.{});
        ctx.beginTableCell();
        ctx.label("a");
        ctx.endTableCell();
        ctx.beginTableCell();
        ctx.label("bbbbbb");
        ctx.endTableCell();
        _ = ctx.endTableRow();
    }
    ctx.endTable();
    ctx.endFrame();

    const a0 = ctx.getNodeRect(cellId(&ctx, TID, @as(u64, 0), 0)).?;
    const a1 = ctx.getNodeRect(cellId(&ctx, TID, @as(u64, 1), 0)).?;
    const a2 = ctx.getNodeRect(cellId(&ctx, TID, @as(u64, 2), 0)).?;
    try std.testing.expectEqual(a0.x, a1.x);
    try std.testing.expectEqual(a1.x, a2.x);
    try std.testing.expectEqual(a0.w, a1.w);
    try std.testing.expectEqual(@as(u32, 24), a0.w);
}

test "table sticky header: header clip excludes the vertical scrollbar gutter" {
    var ctx = testCtx();
    defer ctx.deinit();
    const TID: Id = 0xA080;
    var scroll: Vec2f = .{};
    const cols = [_]TableCol{
        .{ .width = .{ .fixed = 80 }, .header = "LeftCol" },
        .{ .width = .{ .fixed = 80 }, .header = "RightCol" },
    };

    var frame: usize = 0;
    while (frame < 3) : (frame += 1) {
        ctx.beginFrame(300, 300);
        ctx.beginTable(TID, &cols, .{
            .width = .{ .fixed = 100 },
            .height = .{ .fixed = 80 },
            .column_gap = 0,
            .scroll = &scroll,
            .bar_thickness = 8,
        });
        ctx.tableHeaderRow();
        var i: usize = 0;
        while (i < 20) : (i += 1) {
            ctx.beginTableRow(.{});
            ctx.beginTableCell();
            ctx.label("leftcell");
            ctx.endTableCell();
            ctx.beginTableCell();
            ctx.label("rightcel");
            ctx.endTableCell();
            _ = ctx.endTableRow();
        }
        ctx.endTable();
        ctx.endFrame();
    }

    const vthumb = id_mod.hashInt(id_mod.hashInt(TID, body_vp_salt), 2);
    try std.testing.expect(ctx.getNodeRect(vthumb) != null);

    const header_r = ctx.getNodeCachedRect(headerCellId(&ctx, TID, 1)).?;
    const body_r = ctx.getNodeCachedRect(cellId(&ctx, TID, @as(u64, 0), 1)).?;
    const vp = ctx.getNodeRect(id_mod.hashInt(TID, body_vp_salt)).?;
    const header_clip_r = header_r.clip.x + @as(i32, @intCast(header_r.clip.w));
    const body_clip_r = body_r.clip.x + @as(i32, @intCast(body_r.clip.w));
    const vp_r = vp.x + @as(i32, @intCast(vp.w));
    try std.testing.expectEqual(vp_r, header_clip_r);
    try std.testing.expectEqual(vp_r, body_clip_r);
    try std.testing.expect(header_r.rect.x + @as(i32, @intCast(header_r.rect.w)) > header_clip_r);
}

fn buildPaddedFitTable(ctx: *Context, table_id: Id, padding: [4]i32) void {
    const cols = [_]TableCol{.{ .width = .{ .fixed = 40 }, .header = "A" }};
    ctx.beginTable(table_id, &cols, .{
        .width = .fit,
        .height = .fit,
        .column_gap = 0,
        .row_gap = 0,
        .padding = padding,
    });
    ctx.tableHeaderRow();
    ctx.beginTableRow(.{});
    ctx.beginTableCell();
    ctx.label("x");
    ctx.endTableCell();
    _ = ctx.endTableRow();
    ctx.endTable();
}

test "table padding: insets header and body alike, and the fit outer box grows to hold it" {
    var base = testCtx();
    defer base.deinit();
    const TID: Id = 0xA090;
    base.beginFrame(400, 200);
    buildPaddedFitTable(&base, TID, .{ 0, 0, 0, 0 });
    base.endFrame();
    const base_table = base.getNodeRect(TID).?;
    const base_header = base.getNodeRect(headerCellId(&base, TID, 0)).?;
    const base_body = base.getNodeRect(cellId(&base, TID, @as(u64, 0), 0)).?;

    var padded = testCtx();
    defer padded.deinit();
    const pad: [4]i32 = .{ 5, 7, 9, 11 };
    padded.beginFrame(400, 200);
    buildPaddedFitTable(&padded, TID, pad);
    padded.endFrame();
    const padded_table = padded.getNodeRect(TID).?;
    const padded_header = padded.getNodeRect(headerCellId(&padded, TID, 0)).?;
    const padded_body = padded.getNodeRect(cellId(&padded, TID, @as(u64, 0), 0)).?;

    // Left padding shifts both rows' first (and only) column by the same amount:
    // header and body receive the same inset, not just one of the two.
    try std.testing.expectEqual(base_header.x + pad[3], padded_header.x);
    try std.testing.expectEqual(base_body.x + pad[3], padded_body.x);
    try std.testing.expectEqual(base_header.y + pad[0], padded_header.y);

    // A `.fit` table's own outer box grows to hold the padding (real box padding,
    // not a fake extra column that would leave the outer box's own size unchanged).
    try std.testing.expectEqual(base_table.w + @as(u32, @intCast(pad[1] + pad[3])), padded_table.w);
    try std.testing.expectEqual(base_table.h + @as(u32, @intCast(pad[0] + pad[2])), padded_table.h);
}

test "table padding: scrollbar and content-extent invariants still hold with padding set" {
    var ctx = testCtx();
    defer ctx.deinit();
    const TID: Id = 0xA091;
    var scroll: Vec2f = .{};
    const cols = [_]TableCol{
        .{ .width = .{ .fixed = 80 }, .header = "LeftCol" },
        .{ .width = .{ .fixed = 80 }, .header = "RightCol" },
    };
    const pad: [4]i32 = .{ 4, 6, 4, 10 };
    const table_w: i32 = 100;
    const bar_thickness: i32 = 8;

    var frame: usize = 0;
    while (frame < 3) : (frame += 1) {
        ctx.beginFrame(300, 300);
        ctx.beginTable(TID, &cols, .{
            .width = .{ .fixed = table_w },
            .height = .{ .fixed = 80 },
            .column_gap = 0,
            .scroll = &scroll,
            .bar_thickness = bar_thickness,
            .padding = pad,
        });
        ctx.tableHeaderRow();
        var i: usize = 0;
        while (i < 20) : (i += 1) {
            ctx.beginTableRow(.{});
            ctx.beginTableCell();
            ctx.label("leftcell");
            ctx.endTableCell();
            ctx.beginTableCell();
            ctx.label("rightcel");
            ctx.endTableCell();
            _ = ctx.endTableRow();
        }
        ctx.endTable();
        ctx.endFrame();
    }

    const vthumb = id_mod.hashInt(id_mod.hashInt(TID, body_vp_salt), 2);
    try std.testing.expect(ctx.getNodeRect(vthumb) != null);

    // With table-level padding set, the header and body clips still stop exactly at
    // the viewport's right edge (the scrollbar gutter draws that line, not the
    // padding), and the viewport itself is narrower by the left/right padding plus
    // the scrollbar's own gutter.
    const header_r = ctx.getNodeCachedRect(headerCellId(&ctx, TID, 1)).?;
    const body_r = ctx.getNodeCachedRect(cellId(&ctx, TID, @as(u64, 0), 1)).?;
    const vp = ctx.getNodeRect(id_mod.hashInt(TID, body_vp_salt)).?;
    const header_clip_r = header_r.clip.x + @as(i32, @intCast(header_r.clip.w));
    const body_clip_r = body_r.clip.x + @as(i32, @intCast(body_r.clip.w));
    const vp_r = vp.x + @as(i32, @intCast(vp.w));
    try std.testing.expectEqual(vp_r, header_clip_r);
    try std.testing.expectEqual(vp_r, body_clip_r);

    const expected_vp_w: u32 = @intCast(table_w - pad[3] - pad[1] - bar_thickness);
    try std.testing.expectEqual(expected_vp_w, vp.w);

    // Left padding insets the first column for both header and body, same as the
    // fit-table case above.
    const table_r = ctx.getNodeRect(TID).?;
    const header_col0 = ctx.getNodeRect(headerCellId(&ctx, TID, 0)).?;
    const body_col0 = ctx.getNodeRect(cellId(&ctx, TID, @as(u64, 0), 0)).?;
    try std.testing.expectEqual(table_r.x + pad[3], header_col0.x);
    try std.testing.expectEqual(header_col0.x, body_col0.x);
}

test "table padding: h_scroll's row keeps its column-sum fit width; only the viewport narrows" {
    var ctx = testCtx();
    defer ctx.deinit();
    const TID: Id = 0xA092;
    var scroll: Vec2f = .{};
    const cols = [_]TableCol{
        .{ .width = .{ .fixed = 120 }, .header = "LeftCol" },
        .{ .width = .{ .fixed = 120 }, .header = "RightCol" },
    };
    const pad: [4]i32 = .{ 2, 6, 2, 10 };
    const table_w: i32 = 100;

    const build = struct {
        fn f(c: *Context, id: Id, s: *Vec2f) void {
            c.beginTable(id, &cols, .{
                .width = .{ .fixed = table_w },
                .height = .{ .fixed = 80 },
                .column_gap = 0,
                .scroll = s,
                .h_scroll = true,
                .wheel_px = 16,
                .padding = pad,
            });
            c.tableHeaderRow();
            var i: usize = 0;
            while (i < 3) : (i += 1) {
                c.beginTableRow(.{});
                c.beginTableCell();
                c.label("leftcell");
                c.endTableCell();
                c.beginTableCell();
                c.label("rightcel");
                c.endTableCell();
                _ = c.endTableRow();
            }
            c.endTable();
        }
    }.f;

    var warm: usize = 0;
    while (warm < 2) : (warm += 1) {
        ctx.beginFrame(300, 300);
        build(&ctx, TID, &scroll);
        ctx.endFrame();
    }

    // The row's `.fit` content width is the two columns' sum (240px, column_gap=0):
    // padding narrows the viewport it scrolls inside, not this row width itself
    // (the invariant this file's header comment states for the h_scroll path).
    const vp = ctx.getNodeRect(id_mod.hashInt(TID, body_vp_salt)).?;
    const expected_vp_w: u32 = @intCast(table_w - pad[3] - pad[1]);
    try std.testing.expectEqual(expected_vp_w, vp.w);

    const hc = center(vp);
    ctx.beginFrame(300, 300);
    wheelAt(&ctx, hc.x, hc.y, -40, 0);
    build(&ctx, TID, &scroll);
    ctx.endFrame();

    try std.testing.expect(scroll.x > 0);
    const content_w: i32 = 240;
    const expected_max_x: f32 = @floatFromInt(content_w - @as(i32, @intCast(expected_vp_w)));
    try std.testing.expectEqual(expected_max_x, scroll.x);
    // Header and body settle on the same scrolled x, same as the unpadded case.
    try std.testing.expectEqual(
        ctx.getNodeRect(headerCellId(&ctx, TID, 0)).?.x,
        ctx.getNodeRect(cellId(&ctx, TID, @as(u64, 0), 0)).?.x,
    );
}

test "table fixed columns: no fit or stretch bookkeeping on the frame arena" {
    var ctx = testCtx();
    defer ctx.deinit();
    const TID: Id = 0xA081;
    const cols = [_]TableCol{
        .{ .width = .{ .fixed = 24 } },
        .{ .width = .{ .fixed = 48 } },
    };

    ctx.beginFrame(200, 200);
    ctx.beginTable(TID, &cols, .{ .width = .fit, .height = .fit, .column_gap = 4 });
    ctx.tableHeaderRow();
    ctx.beginTableRow(.{});
    try std.testing.expect(ctx.table.?.cells == null);
    try std.testing.expectEqual(@as(usize, 0), ctx.table.?.row_cell_nodes.len);
    try std.testing.expect(!ctx.table.?.has_fit_col);
    ctx.beginTableCell();
    ctx.label("a");
    ctx.endTableCell();
    ctx.beginTableCell();
    ctx.label("bbbbbb");
    ctx.endTableCell();
    try std.testing.expect(ctx.table.?.cells == null);
    try std.testing.expectEqual(@as(usize, 0), ctx.table.?.row_cell_nodes.len);
    _ = ctx.endTableRow();
    ctx.endTable();
    ctx.endFrame();
}
