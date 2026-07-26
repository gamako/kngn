//! Bezier (pen) tool edit state machine. Pure logic; GUI/platform independent.
//!
//! Abstract events (pointer_down/move/up, cancel, delete) → Path state transitions. Commit is
//! solely `rasterizeCommit` (rasterize then clear path; Input has no commit to avoid double clear).
//! The pixie-side adapter (bezier_input.zig) drives input events and commit/cancel.

const std = @import("std");
const bezier = @import("bezier.zig");
const Vec2f = bezier.Vec2f;
const path_mod = @import("path.zig");
const Path = path_mod.Path;
const Hit = path_mod.Hit;
const canvas_mod = @import("canvas.zig");
const Canvas = canvas_mod.Canvas;
const undo_mod = @import("undo.zig");
const StrokeRecorder = undo_mod.StrokeRecorder;
const PaintDiff = undo_mod.PaintDiff;
const Dab = undo_mod.Dab;

pub const Input = union(enum) {
    pointer_down: Vec2f,
    pointer_move: Vec2f,
    pointer_up: Vec2f,
    cancel,
    delete,
};

const Drag = union(enum) {
    none,
    new_out: usize, // Dragging h_out of a new anchor
    anchor: usize,
    handle_in: usize,
    handle_out: usize,
};

pub const PathEditor = struct {
    path: Path = .{},
    drag: Drag = .none,
    selected: ?Hit = null, // Target for later edit/delete (updated on pointer_down hit; kept across pointer_up)
    hit_radius: f32 = 6, // Logical px. pixie sets 6/zoom every frame
    preview_point: ?Vec2f = null, // Hover cursor (provisional next-anchor point). Preview-only; not part of state transitions

    pub fn deinit(self: *PathEditor, gpa: std.mem.Allocator) void {
        self.path.deinit(gpa);
    }

    pub fn isEditing(self: *const PathEditor) bool {
        return self.path.anchors.items.len > 0;
    }

    pub fn update(self: *PathEditor, gpa: std.mem.Allocator, in: Input) void {
        switch (in) {
            .pointer_down => |p| self.onDown(gpa, p),
            .pointer_move => |p| self.onMove(p),
            .pointer_up => self.drag = .none, // Keep selected (Delete target)
            .cancel => {
                self.path.anchors.clearRetainingCapacity();
                self.drag = .none;
                self.selected = null;
                self.preview_point = null;
            },
            .delete => self.onDelete(),
        }
    }

    fn onDown(self: *PathEditor, gpa: std.mem.Allocator, p: Vec2f) void {
        if (self.path.hitTest(p, self.hit_radius)) |hit| {
            self.selected = hit;
            self.drag = switch (hit.kind) {
                .anchor => .{ .anchor = hit.idx },
                .handle_in => .{ .handle_in = hit.idx },
                .handle_out => .{ .handle_out = hit.idx },
            };
            return;
        }
        // No hit → append a new anchor (zero-length handles = corner). Drag pulls h_out.
        self.path.anchors.append(gpa, .{ .pos = p, .h_in = p, .h_out = p }) catch @panic("PathEditor.onDown: OOM");
        const last = self.path.anchors.items.len - 1;
        self.drag = .{ .new_out = last };
        self.selected = .{ .idx = last, .kind = .anchor };
    }

    fn onMove(self: *PathEditor, p: Vec2f) void {
        switch (self.drag) {
            .none => {},
            .new_out, .handle_out => |i| {
                const a = &self.path.anchors.items[i];
                a.h_out = p;
                a.h_in = mirror(a.pos, p); // Symmetric
            },
            .handle_in => |i| {
                const a = &self.path.anchors.items[i];
                a.h_in = p;
                a.h_out = mirror(a.pos, p);
            },
            .anchor => |i| {
                const a = &self.path.anchors.items[i];
                const dx = p.x - a.pos.x;
                const dy = p.y - a.pos.y;
                a.pos = p;
                a.h_in = .{ .x = a.h_in.x + dx, .y = a.h_in.y + dy };
                a.h_out = .{ .x = a.h_out.x + dx, .y = a.h_out.y + dy };
            },
        }
    }

    fn onDelete(self: *PathEditor) void {
        if (self.path.anchors.items.len == 0) return;
        const idx = if (self.selected) |s| s.idx else self.path.anchors.items.len - 1;
        if (idx < self.path.anchors.items.len) {
            _ = self.path.anchors.orderedRemove(idx);
        }
        self.selected = null;
        self.drag = .none;
    }

    /// Sole commit path. rasterize → take return value → clear path. pixie calls this on Enter/double-click
    /// and pushes a non-null return onto UndoStack (no commit on Input; avoids double clear).
    pub fn rasterizeCommit(self: *PathEditor, canvas: *Canvas, rec: *StrokeRecorder, gpa: std.mem.Allocator, dab: Dab, color: u32, opacity: u8) ?PaintDiff {
        const cmd = self.path.rasterize(canvas, rec, gpa, dab, color, opacity);
        self.path.anchors.clearRetainingCapacity();
        self.drag = .none;
        self.selected = null;
        self.preview_point = null;
        return cmd;
    }

    /// In-edit preview: brush-draw path (+ provisional trailing anchor if preview_point) onto dst.
    /// Diff is discarded (non-destructive; caller must pass a copy of the real layer as dst). Path state is unchanged.
    pub fn rasterizePreview(self: *PathEditor, dst: *Canvas, rec: *StrokeRecorder, gpa: std.mem.Allocator, dab: Dab, color: u32, opacity: u8) void {
        const added = self.preview_point != null;
        if (self.preview_point) |p| {
            self.path.anchors.append(gpa, .{ .pos = p, .h_in = p, .h_out = p }) catch @panic("PathEditor.rasterizePreview: OOM");
        }
        defer if (added) {
            _ = self.path.anchors.pop();
        };
        if (self.path.rasterize(dst, rec, gpa, dab, color, opacity)) |pd| gpa.free(pd.diffs);
    }
};

fn mirror(center: Vec2f, p: Vec2f) Vec2f {
    return .{ .x = 2 * center.x - p.x, .y = 2 * center.y - p.y };
}

// ============================================================
// Tests
// ============================================================

const HitKind = path_mod.HitKind;

test "down adds a new anchor; move sets h_out and mirrored h_in" {
    const gpa = std.testing.allocator;
    var ed: PathEditor = .{};
    defer ed.deinit(gpa);

    ed.update(gpa, .{ .pointer_down = .{ .x = 10, .y = 10 } });
    try std.testing.expectEqual(@as(usize, 1), ed.path.anchors.items.len);
    try std.testing.expect(ed.isEditing());

    ed.update(gpa, .{ .pointer_move = .{ .x = 14, .y = 10 } });
    const a = ed.path.anchors.items[0];
    try std.testing.expectEqual(@as(f32, 14), a.h_out.x);
    try std.testing.expectEqual(@as(f32, 6), a.h_in.x); // mirror(10, 14) = 6
}

test "selected is kept after pointer_up" {
    const gpa = std.testing.allocator;
    var ed: PathEditor = .{};
    defer ed.deinit(gpa);
    ed.update(gpa, .{ .pointer_down = .{ .x = 5, .y = 5 } });
    ed.update(gpa, .{ .pointer_up = .{ .x = 5, .y = 5 } });
    try std.testing.expectEqual(Drag.none, ed.drag);
    try std.testing.expect(ed.selected != null);
    try std.testing.expectEqual(@as(usize, 0), ed.selected.?.idx);
}

test "grab an existing anchor and move it (handles follow)" {
    const gpa = std.testing.allocator;
    var ed: PathEditor = .{};
    defer ed.deinit(gpa);
    // Place one corner anchor and up
    ed.update(gpa, .{ .pointer_down = .{ .x = 20, .y = 20 } });
    ed.update(gpa, .{ .pointer_up = .{ .x = 20, .y = 20 } });
    // down nearby → grab anchor, move relocates
    ed.update(gpa, .{ .pointer_down = .{ .x = 21, .y = 20 } });
    try std.testing.expectEqual(@as(usize, 1), ed.path.anchors.items.len); // Do not append a new one
    ed.update(gpa, .{ .pointer_move = .{ .x = 30, .y = 25 } });
    const a = ed.path.anchors.items[0];
    try std.testing.expectEqual(@as(f32, 30), a.pos.x);
    try std.testing.expectEqual(@as(f32, 25), a.pos.y);
}

test "delete: selected preferred / unselected deletes the last" {
    const gpa = std.testing.allocator;
    var ed: PathEditor = .{};
    defer ed.deinit(gpa);
    ed.update(gpa, .{ .pointer_down = .{ .x = 0, .y = 0 } });
    ed.update(gpa, .{ .pointer_up = .{ .x = 0, .y = 0 } });
    ed.update(gpa, .{ .pointer_down = .{ .x = 10, .y = 0 } });
    ed.update(gpa, .{ .pointer_up = .{ .x = 10, .y = 0 } });
    try std.testing.expectEqual(@as(usize, 2), ed.path.anchors.items.len);
    // selected is last-placed idx=1 → delete removes idx=1
    ed.update(gpa, .delete);
    try std.testing.expectEqual(@as(usize, 1), ed.path.anchors.items.len);
    try std.testing.expectEqual(@as(f32, 0), ed.path.anchors.items[0].pos.x);
    // Unselected (selected=null) → delete last
    ed.update(gpa, .delete);
    try std.testing.expectEqual(@as(usize, 0), ed.path.anchors.items.len);
}

test "cancel clears to empty" {
    const gpa = std.testing.allocator;
    var ed: PathEditor = .{};
    defer ed.deinit(gpa);
    ed.update(gpa, .{ .pointer_down = .{ .x = 1, .y = 1 } });
    ed.update(gpa, .{ .pointer_down = .{ .x = 8, .y = 1 } });
    try std.testing.expect(ed.isEditing());
    ed.update(gpa, .cancel);
    try std.testing.expect(!ed.isEditing());
    try std.testing.expectEqual(@as(?Hit, null), ed.selected);
}

test "rasterizeCommit: draws then clears the path" {
    const gpa = std.testing.allocator;
    var canvas = try Canvas.init(gpa, 16, 16);
    defer canvas.deinit();
    var rec = try StrokeRecorder.init(gpa, 16, 16);
    defer rec.deinit(gpa);
    var ed: PathEditor = .{};
    defer ed.deinit(gpa);

    // Build a corner→corner line
    ed.update(gpa, .{ .pointer_down = .{ .x = 2, .y = 4 } });
    ed.update(gpa, .{ .pointer_up = .{ .x = 2, .y = 4 } });
    ed.update(gpa, .{ .pointer_down = .{ .x = 12, .y = 4 } });
    ed.update(gpa, .{ .pointer_up = .{ .x = 12, .y = 4 } });

    const dab: Dab = .{ .offsets = &[_]undo_mod.Offset{.{ .dx = 0, .dy = 0, .cov = 255 }} };
    const RED: u32 = 0xFFFF0000; // canonical BGRA (red)
    const pd = ed.rasterizeCommit(&canvas, &rec, gpa, dab, RED, 255) orelse return error.TestUnexpectedNull;
    defer gpa.free(pd.diffs);

    try std.testing.expect(!ed.isEditing()); // Cleared
    try std.testing.expectEqual(@as(?Hit, null), ed.selected);
    for (2..13) |x| try std.testing.expectEqual(RED, canvas.layerPixels(0)[4 * 16 + x]);
}

test "rasterizePreview: draws preview_point as a provisional anchor; path is unchanged" {
    const gpa = std.testing.allocator;
    var canvas = try Canvas.init(gpa, 16, 16);
    defer canvas.deinit();
    var rec = try StrokeRecorder.init(gpa, 16, 16);
    defer rec.deinit(gpa);
    var ed: PathEditor = .{};
    defer ed.deinit(gpa);

    // One anchor + preview_point (hover) previews a provisional segment
    ed.update(gpa, .{ .pointer_down = .{ .x = 2, .y = 4 } });
    ed.update(gpa, .{ .pointer_up = .{ .x = 2, .y = 4 } });
    ed.preview_point = .{ .x = 12, .y = 4 };

    const dab: Dab = .{ .offsets = &[_]undo_mod.Offset{.{ .dx = 0, .dy = 0, .cov = 255 }} };
    const RED: u32 = 0xFFFF0000; // canonical BGRA (red)
    ed.rasterizePreview(&canvas, &rec, gpa, dab, RED, 255);

    // Drawn out to the provisional point (y=4, x=2..12)
    for (2..13) |x| try std.testing.expectEqual(RED, canvas.layerPixels(0)[4 * 16 + x]);
    // Path unchanged (still 1 anchor; preview_point kept)
    try std.testing.expectEqual(@as(usize, 1), ed.path.anchors.items.len);
    try std.testing.expect(ed.preview_point != null);
}
