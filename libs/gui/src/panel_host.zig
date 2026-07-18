//! PanelHost — dock-slot panel system (TASK-147).
//!
//! left / right / bottom / center の 4 スロットに分割し、registry の panel を
//! Collapsible 付きで縦積みする。center は空 box のみで、rect / hit-test をアプリへ返す。
//!
//! ホットパス宣言:
//! - layout と registry 走査はフレーム毎だが widget 数オーダー。
//! - 全画素ループ・RT 経路・per-frame heap allocation / registry 複製は行わない。
//! - 永続化 hook は初期化時または明示操作時のみ。

const std = @import("std");

const context_mod = @import("context.zig");
const geom = @import("geom.zig");
const id_mod = @import("id.zig");
const color_mod = @import("color.zig");
const widgets = @import("widgets.zig");
const font_mod = @import("font.zig");
const layout = @import("layout.zig");

pub const Context = context_mod.Context;
pub const Rect = geom.Rect;
pub const Vec2 = geom.Vec2;
pub const Id = id_mod.Id;
pub const Color = color_mod.Color;
pub const Orient = widgets.Orient;

pub const Slot = enum {
    left,
    right,
    bottom,
    center,
};

pub const PanelBuildFn = *const fn (ctx: *Context, user_data: *anyopaque) anyerror!void;

pub const Panel = struct {
    name: []const u8,
    slot: Slot,
    visible: bool = true,
    open: bool = true,
    build: PanelBuildFn,
    user_data: *anyopaque,
    /// 表示専用タイトル（null なら name を表示）。ID・永続化キーは常に name 基準なので、
    /// 「Tool Options — Brush」のような動的タイトルはここを毎フレーム差し替えてよい。
    title: ?[]const u8 = null,
};

pub const SlotOptions = struct {
    visible: bool = true,
    extent: i32,
    min_extent: i32,
    max_extent: i32,
};

pub const Options = struct {
    left: SlotOptions = .{ .extent = 200, .min_extent = 120, .max_extent = 800 },
    right: SlotOptions = .{ .extent = 200, .min_extent = 120, .max_extent = 800 },
    bottom: SlotOptions = .{ .extent = 160, .min_extent = 80, .max_extent = 600 },
    splitter_thickness: i32 = 6,
    min_center_width: i32 = 120,
    min_center_height: i32 = 120,
};

pub const Hit = union(enum) {
    center,
    panel: struct {
        slot: Slot,
        index: usize,
    },
    splitter: Slot,
    outside,
};

pub const PersistSlotField = enum {
    visible,
    extent,
};

pub const PersistPanelField = enum {
    visible,
    open,
};

pub const PersistKey = union(enum) {
    slot: struct {
        slot: Slot,
        field: PersistSlotField,
    },
    panel: struct {
        name: []const u8,
        field: PersistPanelField,
    },
};

pub const PersistValue = union(enum) {
    boolean: bool,
    integer: i64,
};

pub const Persistence = struct {
    user_data: *anyopaque,
    read: *const fn (*anyopaque, PersistKey) ?PersistValue,
    write: *const fn (*anyopaque, PersistKey, PersistValue) anyerror!void,
};

pub const InitError = error{
    EmptyPanelName,
    DuplicatePanelName,
    PanelInCenterSlot,
};

const SlotState = struct {
    visible: bool,
    extent: i32,
    min_extent: i32,
    max_extent: i32,
};

/// IdStack と同じ string hash（root seed → label）。allocator 不要。
fn hashStr(seed: u64, label: []const u8) Id {
    var h = id_mod.fnv1a(seed, &[_]u8{'s'});
    const len: u64 = label.len;
    h = id_mod.fnv1a(h, std.mem.asBytes(&len));
    return id_mod.fnv1a(h, label);
}

const host_seed: Id = hashStr(0xcbf29ce484222325, "PanelHost");

fn idKind(kind: []const u8) Id {
    return hashStr(host_seed, kind);
}

fn idKindName(kind: []const u8, name: []const u8) Id {
    return hashStr(idKind(kind), name);
}

pub const PanelHost = struct {
    panels: []Panel,
    left: SlotState,
    right: SlotState,
    bottom: SlotState,
    splitter_thickness: i32,
    min_center_width: i32,
    min_center_height: i32,

    // 安定 ID（name / slot 由来。registry 並び替えで移らない）
    id_root: Id = idKind("root"),
    id_main: Id = idKind("main"),
    id_content_row: Id = idKind("content_row"),
    id_center: Id = idKind("center"),
    id_slot_left: Id = idKind("slot/left"),
    id_slot_right: Id = idKind("slot/right"),
    id_slot_bottom: Id = idKind("slot/bottom"),
    id_split_left: Id = idKind("splitter/left"),
    id_split_right: Id = idKind("splitter/right"),
    id_split_bottom: Id = idKind("splitter/bottom"),

    pub fn init(panels: []Panel, options: Options) InitError!PanelHost {
        try validatePanels(panels);
        return .{
            .panels = panels,
            .left = slotFromOptions(options.left),
            .right = slotFromOptions(options.right),
            .bottom = slotFromOptions(options.bottom),
            .splitter_thickness = @max(1, options.splitter_thickness),
            .min_center_width = @max(0, options.min_center_width),
            .min_center_height = @max(0, options.min_center_height),
        };
    }

    pub fn build(self: *PanelHost, ctx: *Context) anyerror!void {
        self.clampExtents(ctx);

        const left_on = self.slotActive(.left);
        const right_on = self.slotActive(.right);
        const bottom_on = self.slotActive(.bottom);

        // defer で begin/end 対称を保証（panel callback の error 伝播でも box が開いたまま残らない）
        ctx.beginBox(.{
            .id = self.id_root,
            .direction = .column,
            .width = .{ .grow = 1 },
            .height = .{ .grow = 1 },
            .gap = 0,
        });
        defer ctx.endBox();

        ctx.beginBox(.{
            .id = self.id_main,
            .direction = .column,
            .width = .{ .grow = 1 },
            .height = .{ .grow = 1 },
            .gap = 0,
        });
        defer ctx.endBox();

        {
            ctx.beginBox(.{
                .id = self.id_content_row,
                .direction = .row,
                .width = .{ .grow = 1 },
                .height = .{ .grow = 1 },
                .gap = 0,
            });
            defer ctx.endBox();

            if (left_on) {
                try self.buildSlot(ctx, .left);
                _ = ctx.splitter(self.id_split_left, .vertical, &self.left.extent, .{
                    .thickness = self.splitter_thickness,
                    .min = self.left.min_extent,
                    .max = self.maxExtentFor(.left, ctx),
                    .invert = false,
                });
            }

            ctx.beginBox(.{
                .id = self.id_center,
                .width = .{ .grow = 1 },
                .height = .{ .grow = 1 },
            });
            ctx.endBox();

            if (right_on) {
                _ = ctx.splitter(self.id_split_right, .vertical, &self.right.extent, .{
                    .thickness = self.splitter_thickness,
                    .min = self.right.min_extent,
                    .max = self.maxExtentFor(.right, ctx),
                    .invert = true,
                });
                try self.buildSlot(ctx, .right);
            }
        }

        if (bottom_on) {
            _ = ctx.splitter(self.id_split_bottom, .horizontal, &self.bottom.extent, .{
                .thickness = self.splitter_thickness,
                .min = self.bottom.min_extent,
                .max = self.maxExtentFor(.bottom, ctx),
                .invert = true,
            });
            try self.buildSlot(ctx, .bottom);
        }
    }

    pub fn setSlotVisible(self: *PanelHost, slot: Slot, visible: bool) void {
        switch (slot) {
            .left => self.left.visible = visible,
            .right => self.right.visible = visible,
            .bottom => self.bottom.visible = visible,
            .center => {},
        }
    }

    pub fn slotVisible(self: *const PanelHost, slot: Slot) bool {
        return switch (slot) {
            .left => self.left.visible,
            .right => self.right.visible,
            .bottom => self.bottom.visible,
            .center => true,
        };
    }

    pub fn setSlotExtent(self: *PanelHost, slot: Slot, extent: i32) void {
        const st = self.slotStatePtr(slot) orelse return;
        st.extent = std.math.clamp(extent, st.min_extent, st.max_extent);
    }

    pub fn slotExtent(self: *const PanelHost, slot: Slot) i32 {
        return switch (slot) {
            .left => self.left.extent,
            .right => self.right.extent,
            .bottom => self.bottom.extent,
            .center => 0,
        };
    }

    pub fn setPanelVisible(self: *PanelHost, name: []const u8, visible: bool) bool {
        const p = self.findPanel(name) orelse return false;
        p.visible = visible;
        return true;
    }

    pub fn setPanelOpen(self: *PanelHost, name: []const u8, open: bool) bool {
        const p = self.findPanel(name) orelse return false;
        p.open = open;
        return true;
    }

    pub fn panelRect(self: *const PanelHost, ctx: *const Context, name: []const u8) ?Rect {
        const p = self.findPanelConst(name) orelse return null;
        if (!p.visible) return null;
        if (!self.slotActiveConst(p.slot)) return null;
        return ctx.getNodeRect(panelWrapId(name));
    }

    pub fn slotRect(self: *const PanelHost, ctx: *const Context, slot: Slot) ?Rect {
        if (slot == .center) return self.centerRect(ctx);
        if (!self.slotActiveConst(slot)) return null;
        return ctx.getNodeRect(self.slotId(slot));
    }

    pub fn centerRect(self: *const PanelHost, ctx: *const Context) ?Rect {
        return ctx.getNodeRect(self.id_center);
    }

    /// hit-test 優先順位: panel → splitter → center → outside。
    /// （splitter を center より先に見て canvas への誤貫通を防ぐ。リスク節の順序）
    pub fn hitTest(self: *const PanelHost, ctx: *const Context, point: Vec2) Hit {
        // panels（visible + slot active）
        for (self.panels) |p| {
            if (!p.visible) continue;
            if (!self.slotActiveConst(p.slot)) continue;
            if (ctx.getNodeRect(panelWrapId(p.name))) |r| {
                if (r.contains(point)) {
                    return .{ .panel = .{ .slot = p.slot, .index = self.panelIndexInSlot(p.name, p.slot) } };
                }
            }
        }

        // splitters
        const split_checks = [_]struct { slot: Slot, id: Id }{
            .{ .slot = .left, .id = self.id_split_left },
            .{ .slot = .right, .id = self.id_split_right },
            .{ .slot = .bottom, .id = self.id_split_bottom },
        };
        for (split_checks) |entry| {
            if (!self.slotActiveConst(entry.slot)) continue;
            if (ctx.getNodeRect(entry.id)) |r| {
                if (r.contains(point)) return .{ .splitter = entry.slot };
            }
        }

        if (self.centerRect(ctx)) |r| {
            if (r.contains(point)) return .center;
        }
        return .outside;
    }

    pub fn restore(self: *PanelHost, persistence: Persistence) void {
        inline for (.{ Slot.left, Slot.right, Slot.bottom }) |slot| {
            if (persistence.read(persistence.user_data, .{ .slot = .{ .slot = slot, .field = .visible } })) |v| {
                if (v == .boolean) self.setSlotVisible(slot, v.boolean);
            }
            if (persistence.read(persistence.user_data, .{ .slot = .{ .slot = slot, .field = .extent } })) |v| {
                if (v == .integer) {
                    const st = self.slotStatePtr(slot).?;
                    st.extent = std.math.clamp(@as(i32, @intCast(std.math.clamp(v.integer, std.math.minInt(i32), std.math.maxInt(i32)))), st.min_extent, st.max_extent);
                }
            }
        }
        for (self.panels) |*p| {
            if (persistence.read(persistence.user_data, .{ .panel = .{ .name = p.name, .field = .visible } })) |v| {
                if (v == .boolean) p.visible = v.boolean;
            }
            if (persistence.read(persistence.user_data, .{ .panel = .{ .name = p.name, .field = .open } })) |v| {
                if (v == .boolean) p.open = v.boolean;
            }
        }
    }

    pub fn persist(self: *const PanelHost, persistence: Persistence) anyerror!void {
        inline for (.{ Slot.left, Slot.right, Slot.bottom }) |slot| {
            try persistence.write(persistence.user_data, .{ .slot = .{ .slot = slot, .field = .visible } }, .{ .boolean = self.slotVisible(slot) });
            try persistence.write(persistence.user_data, .{ .slot = .{ .slot = slot, .field = .extent } }, .{ .integer = self.slotExtent(slot) });
        }
        for (self.panels) |p| {
            try persistence.write(persistence.user_data, .{ .panel = .{ .name = p.name, .field = .visible } }, .{ .boolean = p.visible });
            try persistence.write(persistence.user_data, .{ .panel = .{ .name = p.name, .field = .open } }, .{ .boolean = p.open });
        }
    }

    // ── internal ──────────────────────────────────────────────

    fn slotFromOptions(o: SlotOptions) SlotState {
        const min_e = @max(0, o.min_extent);
        const max_e = @max(min_e, o.max_extent);
        return .{
            .visible = o.visible,
            .extent = std.math.clamp(o.extent, min_e, max_e),
            .min_extent = min_e,
            .max_extent = max_e,
        };
    }

    fn validatePanels(panels: []const Panel) InitError!void {
        for (panels, 0..) |p, i| {
            if (p.name.len == 0) return error.EmptyPanelName;
            if (p.slot == .center) return error.PanelInCenterSlot;
            for (panels[0..i]) |prev| {
                if (std.mem.eql(u8, prev.name, p.name)) return error.DuplicatePanelName;
            }
        }
    }

    fn slotStatePtr(self: *PanelHost, slot: Slot) ?*SlotState {
        return switch (slot) {
            .left => &self.left,
            .right => &self.right,
            .bottom => &self.bottom,
            .center => null,
        };
    }

    fn slotStateConst(self: *const PanelHost, slot: Slot) ?SlotState {
        return switch (slot) {
            .left => self.left,
            .right => self.right,
            .bottom => self.bottom,
            .center => null,
        };
    }

    fn slotId(self: *const PanelHost, slot: Slot) Id {
        return switch (slot) {
            .left => self.id_slot_left,
            .right => self.id_slot_right,
            .bottom => self.id_slot_bottom,
            .center => self.id_center,
        };
    }

    fn hasVisiblePanel(self: *const PanelHost, slot: Slot) bool {
        for (self.panels) |p| {
            if (p.slot == slot and p.visible) return true;
        }
        return false;
    }

    fn slotActive(self: *const PanelHost, slot: Slot) bool {
        return self.slotActiveConst(slot);
    }

    fn slotActiveConst(self: *const PanelHost, slot: Slot) bool {
        if (slot == .center) return true;
        const st = self.slotStateConst(slot) orelse return false;
        return st.visible and self.hasVisiblePanel(slot);
    }

    fn panelWrapId(name: []const u8) Id {
        return idKindName("panel", name);
    }

    fn panelCollapseId(name: []const u8) Id {
        return idKindName("collapse", name);
    }

    fn findPanel(self: *PanelHost, name: []const u8) ?*Panel {
        for (self.panels) |*p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }

    fn findPanelConst(self: *const PanelHost, name: []const u8) ?*const Panel {
        for (self.panels) |*p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }

    /// 同一 slot 内の visible panel に対する 0-based index（非表示は数えない）。
    fn panelIndexInSlot(self: *const PanelHost, name: []const u8, slot: Slot) usize {
        var i: usize = 0;
        for (self.panels) |p| {
            if (p.slot != slot) continue;
            if (!p.visible) continue;
            if (std.mem.eql(u8, p.name, name)) return i;
            i += 1;
        }
        return 0;
    }

    /// splitter ドラッグ上限。他 slot の現在 extent と center 最小を差し引いた残り（下限 0）。
    /// min_extent は保証しない（狭小画面では clampExtents が min 未満へ圧縮し得る）。
    fn maxExtentFor(self: *const PanelHost, slot: Slot, ctx: *const Context) i32 {
        const st = self.slotStateConst(slot) orelse return 0;
        switch (slot) {
            .left, .right => {
                if (ctx.getNodeRect(self.id_content_row)) |row| {
                    var budget: i32 = @as(i32, @intCast(row.w)) - self.min_center_width;
                    if (self.slotActiveConst(.left)) budget -= self.splitter_thickness;
                    if (self.slotActiveConst(.right)) budget -= self.splitter_thickness;
                    if (slot == .left and self.slotActiveConst(.right)) budget -= self.right.extent;
                    if (slot == .right and self.slotActiveConst(.left)) budget -= self.left.extent;
                    return @max(0, @min(st.max_extent, budget));
                }
                return st.max_extent;
            },
            .bottom => {
                if (ctx.getNodeRect(self.id_main)) |main| {
                    const budget: i32 = @as(i32, @intCast(main.h)) - self.min_center_height - self.splitter_thickness;
                    return @max(0, @min(st.max_extent, budget));
                }
                return st.max_extent;
            },
            .center => return 0,
        }
    }

    /// 共有予算クランプ: center の min_center_width / min_center_height を常に優先する。
    ///
    /// 横軸: budget = content_row.w - min_center_width - (active splitter 合計厚み)。
    /// left/right をまず [min_extent, max_extent] に寄せ、合計が budget を超える場合は
    /// **比例配分**で圧縮する（同条件なら同量。下限 0 まで min_extent を下回り得る）。
    /// 縦軸: bottom も同様に main.h - min_center_height - splitter 厚みを budget とする。
    /// 前フレーム rect が無い初回は [min_extent, max_extent] のみ適用する。
    fn clampExtents(self: *PanelHost, ctx: *const Context) void {
        const left_on = self.slotActiveConst(.left);
        const right_on = self.slotActiveConst(.right);
        const bottom_on = self.slotActiveConst(.bottom);

        if (ctx.getNodeRect(self.id_content_row)) |row| {
            var budget: i32 = @as(i32, @intCast(row.w)) - self.min_center_width;
            if (left_on) budget -= self.splitter_thickness;
            if (right_on) budget -= self.splitter_thickness;
            budget = @max(0, budget);

            if (left_on) {
                self.left.extent = std.math.clamp(self.left.extent, self.left.min_extent, self.left.max_extent);
            }
            if (right_on) {
                self.right.extent = std.math.clamp(self.right.extent, self.right.min_extent, self.right.max_extent);
            }

            var sum: i32 = 0;
            if (left_on) sum += self.left.extent;
            if (right_on) sum += self.right.extent;
            if (sum > budget) {
                if (left_on and right_on) {
                    // 比例配分（丸めは left 側に寄せ、right = budget - left で合計一致）
                    const new_left = if (sum > 0) @divTrunc(self.left.extent * budget, sum) else 0;
                    self.left.extent = @max(0, new_left);
                    self.right.extent = @max(0, budget - self.left.extent);
                } else if (left_on) {
                    self.left.extent = @min(self.left.extent, budget);
                } else if (right_on) {
                    self.right.extent = @min(self.right.extent, budget);
                }
            }
        } else {
            if (left_on) {
                self.left.extent = std.math.clamp(self.left.extent, self.left.min_extent, self.left.max_extent);
            }
            if (right_on) {
                self.right.extent = std.math.clamp(self.right.extent, self.right.min_extent, self.right.max_extent);
            }
        }

        if (ctx.getNodeRect(self.id_main)) |main| {
            if (bottom_on) {
                self.bottom.extent = std.math.clamp(self.bottom.extent, self.bottom.min_extent, self.bottom.max_extent);
                const budget: i32 = @max(0, @as(i32, @intCast(main.h)) - self.min_center_height - self.splitter_thickness);
                if (self.bottom.extent > budget) {
                    self.bottom.extent = budget; // min_extent 未満も許容（下限 0）
                }
            }
        } else if (bottom_on) {
            self.bottom.extent = std.math.clamp(self.bottom.extent, self.bottom.min_extent, self.bottom.max_extent);
        }
    }

    fn buildSlot(self: *PanelHost, ctx: *Context, slot: Slot) anyerror!void {
        const st = self.slotStateConst(slot).?;
        const width: layout.Sizing = if (slot == .bottom) .{ .grow = 1 } else .{ .fixed = st.extent };
        const height: layout.Sizing = if (slot == .bottom) .{ .fixed = st.extent } else .{ .grow = 1 };

        ctx.beginBox(.{
            .id = self.slotId(slot),
            .direction = .column,
            .width = width,
            .height = height,
            .gap = 4,
            .padding = .{ 4, 4, 4, 4 },
            .bg = Color.rgba(0x20, 0x24, 0x2C, 0xFF),
            .clip_children = true,
        });
        defer ctx.endBox();

        for (self.panels) |*panel| {
            if (panel.slot != slot) continue;
            if (!panel.visible) continue;
            try self.buildPanel(ctx, panel);
        }
    }

    fn buildPanel(self: *PanelHost, ctx: *Context, panel: *Panel) anyerror!void {
        _ = self;
        const wrap_id = panelWrapId(panel.name);
        const collapse_id = panelCollapseId(panel.name);

        ctx.beginBox(.{
            .id = wrap_id,
            .direction = .column,
            .width = .{ .grow = 1 },
            .gap = 0,
        });
        defer ctx.endBox();

        if (ctx.beginCollapsible(collapse_id, panel.title orelse panel.name, &panel.open)) {
            // error 時も endCollapsible を必ず呼び、collapsible_body_depth / layout を壊さない
            panel.build(ctx, panel.user_data) catch |err| {
                ctx.endCollapsible();
                return err;
            };
            ctx.endCollapsible();
        }
    }
};

// ── tests ────────────────────────────────────────────────────

fn testCtx() Context {
    return Context.init(std.testing.allocator, font_mod.default_font);
}

fn noopBuild(ctx: *Context, user_data: *anyopaque) anyerror!void {
    _ = user_data;
    ctx.label("body");
}

fn countingBuild(ctx: *Context, user_data: *anyopaque) anyerror!void {
    const counter: *u32 = @ptrCast(@alignCast(user_data));
    counter.* += 1;
    _ = ctx.buttonId(0x147B01, "inner", .{});
}

fn erroringBuild(ctx: *Context, user_data: *anyopaque) anyerror!void {
    _ = ctx;
    _ = user_data;
    return error.PanelBuildFailed;
}

fn moveTo(ctx: *Context, x: i32, y: i32) void {
    ctx.pushEvent(.{ .mouse_move = .{ .x = x, .y = y, .modifiers = 0 } });
}

fn pressAt(ctx: *Context, x: i32, y: i32) void {
    moveTo(ctx, x, y);
    ctx.pushEvent(.{ .mouse_down = .{ .x = x, .y = y, .button = 0, .modifiers = 0 } });
}

fn centerOf(rect: Rect) struct { x: i32, y: i32 } {
    return .{
        .x = rect.x + @as(i32, @intCast(rect.w / 2)),
        .y = rect.y + @as(i32, @intCast(rect.h / 2)),
    };
}

fn frame(host: *PanelHost, ctx: *Context, w: u32, h: u32) !void {
    ctx.beginFrame(w, h);
    try host.build(ctx);
    ctx.endFrame();
}

test "PanelHost.init: 空名・重複名・center slot を拒否" {
    var dummy: u8 = 0;
    var panels_empty = [_]Panel{
        .{ .name = "", .slot = .left, .build = noopBuild, .user_data = &dummy },
    };
    try std.testing.expectError(error.EmptyPanelName, PanelHost.init(panels_empty[0..], .{}));

    var panels_dup = [_]Panel{
        .{ .name = "A", .slot = .left, .build = noopBuild, .user_data = &dummy },
        .{ .name = "A", .slot = .right, .build = noopBuild, .user_data = &dummy },
    };
    try std.testing.expectError(error.DuplicatePanelName, PanelHost.init(panels_dup[0..], .{}));

    var panels_center = [_]Panel{
        .{ .name = "Canvas", .slot = .center, .build = noopBuild, .user_data = &dummy },
    };
    try std.testing.expectError(error.PanelInCenterSlot, PanelHost.init(panels_center[0..], .{}));
}

test "PanelHost: left/right/bottom 矩形配置と center" {
    var ctx = testCtx();
    defer ctx.deinit();
    var dummy: u8 = 0;
    var panels = [_]Panel{
        .{ .name = "Tools", .slot = .left, .build = noopBuild, .user_data = &dummy },
        .{ .name = "Inspector", .slot = .right, .build = noopBuild, .user_data = &dummy },
        .{ .name = "Timeline", .slot = .bottom, .build = noopBuild, .user_data = &dummy },
    };
    var host = try PanelHost.init(panels[0..], .{
        .left = .{ .extent = 180, .min_extent = 100, .max_extent = 400 },
        .right = .{ .extent = 220, .min_extent = 100, .max_extent = 400 },
        .bottom = .{ .extent = 140, .min_extent = 80, .max_extent = 400 },
    });

    try frame(&host, &ctx, 800, 600); // warm
    try frame(&host, &ctx, 800, 600);

    const left = host.slotRect(&ctx, .left).?;
    const right = host.slotRect(&ctx, .right).?;
    const bottom = host.slotRect(&ctx, .bottom).?;
    const center = host.centerRect(&ctx).?;

    try std.testing.expectEqual(@as(u32, 180), left.w);
    try std.testing.expectEqual(@as(u32, 220), right.w);
    try std.testing.expectEqual(@as(u32, 140), bottom.h);
    try std.testing.expect(center.w >= 120);
    try std.testing.expect(center.h >= 120);
    try std.testing.expect(left.x < center.x);
    try std.testing.expect(center.x + @as(i32, @intCast(center.w)) <= right.x);
    try std.testing.expect(center.y + @as(i32, @intCast(center.h)) <= bottom.y);
}

test "PanelHost: slot 非表示で splitter/slot が消え center が拡張" {
    var ctx = testCtx();
    defer ctx.deinit();
    var dummy: u8 = 0;
    var panels = [_]Panel{
        .{ .name = "Inspector", .slot = .right, .build = noopBuild, .user_data = &dummy },
        .{ .name = "Tools", .slot = .left, .build = noopBuild, .user_data = &dummy },
    };
    var host = try PanelHost.init(panels[0..], .{});

    try frame(&host, &ctx, 800, 600);
    try frame(&host, &ctx, 800, 600);
    const center_before = host.centerRect(&ctx).?;

    host.setSlotVisible(.right, false);
    try frame(&host, &ctx, 800, 600);
    try frame(&host, &ctx, 800, 600);

    try std.testing.expect(host.slotRect(&ctx, .right) == null);
    try std.testing.expect(ctx.getNodeRect(host.id_split_right) == null);
    const center_after = host.centerRect(&ctx).?;
    try std.testing.expect(center_after.w > center_before.w);
}

test "PanelHost: panel visible=false で callback/rect/hit から除外" {
    var ctx = testCtx();
    defer ctx.deinit();
    var count: u32 = 0;
    var panels = [_]Panel{
        .{ .name = "Inspector", .slot = .right, .build = countingBuild, .user_data = &count },
    };
    var host = try PanelHost.init(panels[0..], .{});

    try frame(&host, &ctx, 800, 600);
    try frame(&host, &ctx, 800, 600);
    try std.testing.expect(count >= 1);
    try std.testing.expect(host.panelRect(&ctx, "Inspector") != null);

    count = 0;
    _ = host.setPanelVisible("Inspector", false);
    try frame(&host, &ctx, 800, 600);
    try frame(&host, &ctx, 800, 600);
    try std.testing.expectEqual(@as(u32, 0), count);
    try std.testing.expect(host.panelRect(&ctx, "Inspector") == null);
    // slot に visible panel が無いので slot 自体も消える
    try std.testing.expect(host.slotRect(&ctx, .right) == null);
}

test "PanelHost: 同一 slot の複数 panel が宣言順に縦積み" {
    var ctx = testCtx();
    defer ctx.deinit();
    var dummy: u8 = 0;
    var panels = [_]Panel{
        .{ .name = "Color", .slot = .right, .build = noopBuild, .user_data = &dummy },
        .{ .name = "Layers", .slot = .right, .build = noopBuild, .user_data = &dummy },
    };
    var host = try PanelHost.init(panels[0..], .{});
    try frame(&host, &ctx, 800, 600);
    try frame(&host, &ctx, 800, 600);

    const a = host.panelRect(&ctx, "Color").?;
    const b = host.panelRect(&ctx, "Layers").?;
    try std.testing.expect(a.y < b.y);
    try std.testing.expectEqual(a.x, b.x);
}

test "PanelHost: Collapsible open/closed で body callback と高さ変化" {
    var ctx = testCtx();
    defer ctx.deinit();
    var count: u32 = 0;
    var panels = [_]Panel{
        .{ .name = "Inspector", .slot = .right, .open = true, .build = countingBuild, .user_data = &count },
    };
    var host = try PanelHost.init(panels[0..], .{});
    try frame(&host, &ctx, 800, 600);
    try frame(&host, &ctx, 800, 600);
    const h_open = host.panelRect(&ctx, "Inspector").?.h;
    try std.testing.expect(count >= 1);

    count = 0;
    _ = host.setPanelOpen("Inspector", false);
    try frame(&host, &ctx, 800, 600);
    try frame(&host, &ctx, 800, 600);
    try std.testing.expectEqual(@as(u32, 0), count);
    const h_closed = host.panelRect(&ctx, "Inspector").?.h;
    try std.testing.expect(h_closed < h_open);
}

test "PanelHost: narrow framebuffer で center 最小を残す extent clamp" {
    var ctx = testCtx();
    defer ctx.deinit();
    var dummy: u8 = 0;
    var panels = [_]Panel{
        .{ .name = "L", .slot = .left, .build = noopBuild, .user_data = &dummy },
        .{ .name = "R", .slot = .right, .build = noopBuild, .user_data = &dummy },
        .{ .name = "B", .slot = .bottom, .build = noopBuild, .user_data = &dummy },
    };
    var host = try PanelHost.init(panels[0..], .{
        .left = .{ .extent = 500, .min_extent = 50, .max_extent = 800 },
        .right = .{ .extent = 500, .min_extent = 50, .max_extent = 800 },
        .bottom = .{ .extent = 400, .min_extent = 40, .max_extent = 800 },
        .min_center_width = 120,
        .min_center_height = 120,
        .splitter_thickness = 6,
    });

    // 狭い FB: 400x300
    try frame(&host, &ctx, 400, 300);
    try frame(&host, &ctx, 400, 300);
    const center = host.centerRect(&ctx).?;
    try std.testing.expect(center.w >= 100); // clamp 後に最低限残る
    try std.testing.expect(center.h >= 100);
    try std.testing.expect(host.left.extent + host.right.extent < 400);
}

test "PanelHost: zero-size / thick splitter でも panic しない" {
    var ctx = testCtx();
    defer ctx.deinit();
    var dummy: u8 = 0;
    var panels = [_]Panel{
        .{ .name = "L", .slot = .left, .build = noopBuild, .user_data = &dummy },
    };
    var host = try PanelHost.init(panels[0..], .{
        .splitter_thickness = 6,
        .min_center_width = 0,
        .min_center_height = 0,
        .left = .{ .extent = 100, .min_extent = 0, .max_extent = 1000 },
    });
    try frame(&host, &ctx, 1, 1);
    try frame(&host, &ctx, 0, 0);
    try frame(&host, &ctx, 50, 50);
}

test "PanelHost: splitter drag で extent が変わり center 最小を維持" {
    var ctx = testCtx();
    defer ctx.deinit();
    var dummy: u8 = 0;
    var panels = [_]Panel{
        .{ .name = "Inspector", .slot = .right, .build = noopBuild, .user_data = &dummy },
    };
    var host = try PanelHost.init(panels[0..], .{
        .right = .{ .extent = 200, .min_extent = 120, .max_extent = 500 },
        .min_center_width = 120,
    });
    try frame(&host, &ctx, 800, 600);
    try frame(&host, &ctx, 800, 600);

    const split = ctx.getNodeRect(host.id_split_right).?;
    const c = centerOf(split);

    // 先に splitter 上へ移動（press フレームの大きな delta を避ける）
    ctx.beginFrame(800, 600);
    moveTo(&ctx, c.x, c.y);
    try host.build(&ctx);
    ctx.endFrame();

    // press（移動なし）
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_down = .{ .x = c.x, .y = c.y, .button = 0, .modifiers = 0 } });
    try host.build(&ctx);
    ctx.endFrame();
    const before = host.right.extent;

    // drag left 40px → invert=true なので right extent += 40
    ctx.beginFrame(800, 600);
    moveTo(&ctx, c.x - 40, c.y);
    try host.build(&ctx);
    ctx.endFrame();
    try std.testing.expectEqual(before + 40, host.right.extent);

    // 大きく広げても center min を残す
    ctx.beginFrame(800, 600);
    moveTo(&ctx, c.x - 2000, c.y);
    try host.build(&ctx);
    ctx.endFrame();
    try frame(&host, &ctx, 800, 600);
    const center = host.centerRect(&ctx).?;
    try std.testing.expect(center.w >= 120);
}

test "PanelHost: hit-test panel/center/splitter/outside" {
    var ctx = testCtx();
    defer ctx.deinit();
    var dummy: u8 = 0;
    var panels = [_]Panel{
        .{ .name = "Inspector", .slot = .right, .build = noopBuild, .user_data = &dummy },
    };
    var host = try PanelHost.init(panels[0..], .{});
    try frame(&host, &ctx, 800, 600);
    try frame(&host, &ctx, 800, 600);

    const pr = host.panelRect(&ctx, "Inspector").?;
    const pc = centerOf(pr);
    const hit_p = host.hitTest(&ctx, .{ .x = pc.x, .y = pc.y });
    try std.testing.expect(hit_p == .panel);
    try std.testing.expect(hit_p.panel.slot == .right);

    const sr = ctx.getNodeRect(host.id_split_right).?;
    const sc = centerOf(sr);
    try std.testing.expect(host.hitTest(&ctx, .{ .x = sc.x, .y = sc.y }) == .splitter);

    const cr = host.centerRect(&ctx).?;
    const cc = centerOf(cr);
    try std.testing.expect(host.hitTest(&ctx, .{ .x = cc.x, .y = cc.y }) == .center);

    try std.testing.expect(host.hitTest(&ctx, .{ .x = -10, .y = -10 }) == .outside);
}

test "PanelHost: persistence 全フィールド保存・復元" {
    var dummy: u8 = 0;
    var panels = [_]Panel{
        .{ .name = "Inspector", .slot = .right, .visible = true, .open = true, .build = noopBuild, .user_data = &dummy },
        .{ .name = "Tools", .slot = .left, .visible = true, .open = false, .build = noopBuild, .user_data = &dummy },
    };
    var host = try PanelHost.init(panels[0..], .{
        .right = .{ .extent = 240, .min_extent = 100, .max_extent = 500 },
    });
    host.setSlotVisible(.left, false);
    host.setSlotExtent(.right, 320);
    _ = host.setPanelVisible("Inspector", false);
    _ = host.setPanelOpen("Tools", true);

    var store = PersistStore{};
    try host.persist(store.persistence());

    // reset
    var panels2 = [_]Panel{
        .{ .name = "Inspector", .slot = .right, .visible = true, .open = true, .build = noopBuild, .user_data = &dummy },
        .{ .name = "Tools", .slot = .left, .visible = true, .open = false, .build = noopBuild, .user_data = &dummy },
    };
    var host2 = try PanelHost.init(panels2[0..], .{});
    host2.restore(store.persistence());

    try std.testing.expect(!host2.slotVisible(.left));
    try std.testing.expectEqual(@as(i32, 320), host2.slotExtent(.right));
    try std.testing.expect(!panels2[0].visible);
    try std.testing.expect(panels2[1].open);
}

test "PanelHost: persistence 未知 panel・型不一致・範囲外・未指定を安全に扱う" {
    var dummy: u8 = 0;
    var panels = [_]Panel{
        .{ .name = "Inspector", .slot = .right, .visible = true, .open = true, .build = noopBuild, .user_data = &dummy },
    };
    var host = try PanelHost.init(panels[0..], .{
        .right = .{ .extent = 200, .min_extent = 120, .max_extent = 400 },
    });

    var store = PersistStore{};
    // 型不一致
    store.put(.{ .slot = .{ .slot = .right, .field = .extent } }, .{ .boolean = true });
    // 範囲外
    store.put(.{ .slot = .{ .slot = .right, .field = .extent } }, .{ .integer = 9999 });
    // 未知 panel（restore 時に無視）
    store.put(.{ .panel = .{ .name = "Ghost", .field = .visible } }, .{ .boolean = false });
    // 正しい visible
    store.put(.{ .slot = .{ .slot = .right, .field = .visible } }, .{ .boolean = false });

    host.restore(store.persistence());
    try std.testing.expectEqual(@as(i32, 400), host.right.extent); // clamped
    try std.testing.expect(!host.slotVisible(.right));
    try std.testing.expect(panels[0].visible); // 未指定のまま
    try std.testing.expect(panels[0].open);
}

test "PanelHost: 安定 ID — registry 並び替えでも open が移らない" {
    var ctx = testCtx();
    defer ctx.deinit();
    var dummy: u8 = 0;
    var panels = [_]Panel{
        .{ .name = "Color", .slot = .right, .open = true, .build = noopBuild, .user_data = &dummy },
        .{ .name = "Layers", .slot = .right, .open = false, .build = noopBuild, .user_data = &dummy },
    };
    var host = try PanelHost.init(panels[0..], .{});
    try frame(&host, &ctx, 800, 600);
    try frame(&host, &ctx, 800, 600);
    const id_color = PanelHost.panelCollapseId("Color");
    const id_layers = PanelHost.panelCollapseId("Layers");
    try std.testing.expect(ctx.getNodeRect(id_color) != null);
    try std.testing.expect(ctx.getNodeRect(id_layers) != null);

    // 並び替え
    var panels2 = [_]Panel{
        .{ .name = "Layers", .slot = .right, .open = false, .build = noopBuild, .user_data = &dummy },
        .{ .name = "Color", .slot = .right, .open = true, .build = noopBuild, .user_data = &dummy },
    };
    var host2 = try PanelHost.init(panels2[0..], .{});
    try frame(&host2, &ctx, 800, 600);
    try frame(&host2, &ctx, 800, 600);
    try std.testing.expectEqual(id_color, PanelHost.panelCollapseId("Color"));
    try std.testing.expectEqual(id_layers, PanelHost.panelCollapseId("Layers"));
    try std.testing.expect(panels2[1].open);
    try std.testing.expect(!panels2[0].open);
}

test "PanelHost: panel build error でも begin/end 対称で次フレームへ進める" {
    var ctx = testCtx();
    defer ctx.deinit();
    var dummy: u8 = 0;
    var panels = [_]Panel{
        .{ .name = "Boom", .slot = .right, .build = erroringBuild, .user_data = &dummy },
        .{ .name = "Tools", .slot = .left, .build = noopBuild, .user_data = &dummy },
    };
    var host = try PanelHost.init(panels[0..], .{});

    ctx.beginFrame(800, 600);
    try std.testing.expectError(error.PanelBuildFailed, host.build(&ctx));
    // box / collapsible が閉じられていれば endFrame の layout_current==root assert を通る
    ctx.endFrame();

    // 次フレーム: beginFrame の !frame_active assert を通る
    panels[0].build = noopBuild;
    try frame(&host, &ctx, 800, 600);
    try std.testing.expect(host.centerRect(&ctx) != null);
}

test "PanelHost: min_extent 合計超過でも center 最小を優先し slot を圧縮" {
    var ctx = testCtx();
    defer ctx.deinit();
    var dummy: u8 = 0;
    var panels = [_]Panel{
        .{ .name = "L", .slot = .left, .build = noopBuild, .user_data = &dummy },
        .{ .name = "R", .slot = .right, .build = noopBuild, .user_data = &dummy },
    };
    // min 合計 150+150 + splitter 6+6 + min_center 200 = 512 > 400
    var host = try PanelHost.init(panels[0..], .{
        .left = .{ .extent = 200, .min_extent = 150, .max_extent = 800 },
        .right = .{ .extent = 200, .min_extent = 150, .max_extent = 800 },
        .min_center_width = 200,
        .splitter_thickness = 6,
    });

    try frame(&host, &ctx, 400, 300);
    try frame(&host, &ctx, 400, 300);

    const center = host.centerRect(&ctx).?;
    try std.testing.expect(center.w >= 200);
    // min_extent 未満へ圧縮されていること
    try std.testing.expect(host.left.extent < 150);
    try std.testing.expect(host.right.extent < 150);
    try std.testing.expect(host.left.extent + host.right.extent + 12 + @as(i32, @intCast(center.w)) <= 400);
}

test "PanelHost: left/right 同条件なら比例圧縮で同量" {
    var ctx = testCtx();
    defer ctx.deinit();
    var dummy: u8 = 0;
    var panels = [_]Panel{
        .{ .name = "L", .slot = .left, .build = noopBuild, .user_data = &dummy },
        .{ .name = "R", .slot = .right, .build = noopBuild, .user_data = &dummy },
    };
    var host = try PanelHost.init(panels[0..], .{
        .left = .{ .extent = 200, .min_extent = 150, .max_extent = 800 },
        .right = .{ .extent = 200, .min_extent = 150, .max_extent = 800 },
        .min_center_width = 200,
        .splitter_thickness = 6,
    });

    try frame(&host, &ctx, 400, 300);
    try frame(&host, &ctx, 400, 300);
    try std.testing.expectEqual(host.left.extent, host.right.extent);
}

// ── in-memory persistence for tests ──────────────────────────

const PersistStore = struct {
    // 固定サイズの簡易 KV（テスト用）
    entries: [64]Entry = undefined,
    len: usize = 0,

    const Entry = struct {
        key: StoredKey,
        value: PersistValue,
    };

    const StoredKey = union(enum) {
        slot: struct { slot: Slot, field: PersistSlotField },
        panel: struct { name_buf: [32]u8, name_len: usize, field: PersistPanelField },
    };

    fn put(self: *PersistStore, key: PersistKey, value: PersistValue) void {
        const sk = storeKey(key);
        for (self.entries[0..self.len]) |*e| {
            if (keysEqual(e.key, sk)) {
                e.value = value;
                return;
            }
        }
        std.debug.assert(self.len < self.entries.len);
        self.entries[self.len] = .{ .key = sk, .value = value };
        self.len += 1;
    }

    fn storeKey(key: PersistKey) StoredKey {
        return switch (key) {
            .slot => |s| .{ .slot = .{ .slot = s.slot, .field = s.field } },
            .panel => |p| blk: {
                var buf: [32]u8 = undefined;
                const n = @min(p.name.len, buf.len);
                @memcpy(buf[0..n], p.name[0..n]);
                break :blk .{ .panel = .{ .name_buf = buf, .name_len = n, .field = p.field } };
            },
        };
    }

    fn keysEqual(a: StoredKey, b: StoredKey) bool {
        return switch (a) {
            .slot => |as| b == .slot and as.slot == b.slot.slot and as.field == b.slot.field,
            .panel => |ap| b == .panel and ap.field == b.panel.field and std.mem.eql(u8, ap.name_buf[0..ap.name_len], b.panel.name_buf[0..b.panel.name_len]),
        };
    }

    fn keyMatch(stored: StoredKey, key: PersistKey) bool {
        return switch (key) {
            .slot => |s| stored == .slot and stored.slot.slot == s.slot and stored.slot.field == s.field,
            .panel => |p| stored == .panel and stored.panel.field == p.field and std.mem.eql(u8, stored.panel.name_buf[0..stored.panel.name_len], p.name),
        };
    }

    fn readFn(ud: *anyopaque, key: PersistKey) ?PersistValue {
        const self: *PersistStore = @ptrCast(@alignCast(ud));
        for (self.entries[0..self.len]) |e| {
            if (keyMatch(e.key, key)) return e.value;
        }
        return null;
    }

    fn writeFn(ud: *anyopaque, key: PersistKey, value: PersistValue) anyerror!void {
        const self: *PersistStore = @ptrCast(@alignCast(ud));
        self.put(key, value);
    }

    fn persistence(self: *PersistStore) Persistence {
        return .{
            .user_data = self,
            .read = readFn,
            .write = writeFn,
        };
    }
};

test "PanelHost: title は表示専用で ID/永続化は name 基準のまま" {
    var ctx = testCtx();
    defer ctx.deinit();
    var dummy: u8 = 0;
    var panels = [_]Panel{
        .{ .name = "Tool Options", .slot = .right, .build = noopBuild, .user_data = &dummy, .title = "Tool Options — Brush" },
    };
    var host = try PanelHost.init(panels[0..], .{});
    try frame(&host, &ctx, 800, 600);
    try frame(&host, &ctx, 800, 600);

    // name 基準の rect/操作が title 設定後も機能する（ID は name から生成）
    try std.testing.expect(host.panelRect(&ctx, "Tool Options") != null);
    try std.testing.expect(host.setPanelOpen("Tool Options", false));
    panels[0].title = "Tool Options — Fill"; // 毎フレーム差し替え可
    try frame(&host, &ctx, 800, 600);
    try frame(&host, &ctx, 800, 600);
    // title を変えても open 状態（name 基準 ID）が保持される
    try std.testing.expect(!panels[0].open);

    // 永続化キーも name 基準（title は persist に現れない）
    var store = PersistStore{};
    try host.persist(store.persistence());
    var found_name = false;
    var found_title = false;
    for (store.entries[0..store.len]) |e| {
        switch (e.key) {
            .panel => |p| {
                const n = p.name_buf[0..p.name_len];
                if (std.mem.eql(u8, n, "Tool Options")) found_name = true;
                if (std.mem.startsWith(u8, n, "Tool Options —")) found_title = true;
            },
            else => {},
        }
    }
    try std.testing.expect(found_name);
    try std.testing.expect(!found_title);
}
