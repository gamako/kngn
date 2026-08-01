// Cross-widget drag-and-drop primitive.
//
// Hot-path note: event-path only, gated by mouse press/move/release. Not a per-frame
// full-framebuffer loop and not RT (per sample).
//
// Scope: this is the mechanics only (start detection, payload capture, drop detection). Ghost
// rendering, highlighting a hovered target, and restoring a rejected/cancelled drag's source
// state are all left to the caller, the same "library owns the state machine, the app owns the
// pixels" split `tooltip()`/popup already use.
//
// Design (single Context-level "current drag" singleton, like the tooltip/popup state above it):
// only one drag can ever be in flight UI-wide, so there is nowhere else for it to live.
//
//   armed:     a press landed on a source widget's previous-frame rect (sync hit-test, same
//              contract as buttonBehavior). Nothing observable yet: isDragging() is false,
//              dropTarget never fires.
//   dragging:  the pointer moved past `drag_threshold_px` from the press origin while still
//              held. The caller's payload is captured at this instant and does not change again
//              even if the caller passes a different value on a later call for the same id.
//
// Once `dragging`, the source widget's id no longer matters: the payload was already captured by
// value, so a source widget that stops being built (its item left the data model, its panel
// closed, ...) does not end the drag. `armed` is the opposite: it depends entirely on the source
// widget being called again next frame to progress (that call is where the threshold check and
// the release-without-a-drag check both live), so an armed drag whose source widget is not
// resubmitted is cancelled at the next endFrame (see the `drag_submitted_this_frame` bookkeeping
// below) rather than left stuck forever.
//
// Calling convention: call `dragSource` for every enter-able source widget every frame regardless
// of press state (the same "build every candidate every frame" shape the grid-hover/tooltip loop
// already uses elsewhere) -- this is what keeps an armed drag resubmitted while the pointer is
// still deciding whether to cross the threshold.
//
// Contract with popups: opening a popup while a drag is in flight is a caller error (call
// `cancelDrag` first). `openPopup`/`openPopupStacked` clear `ctx.drag` as a fail-safe (matching
// the existing active_id/hot_id/next_hot_id reset there), but the payload is lost when that
// fail-safe fires -- it is not a substitute for calling `cancelDrag`.

const std = @import("std");
const context_mod = @import("context.zig");
const geom = @import("geom.zig");
const id_mod = @import("id.zig");

pub const Context = context_mod.Context;
pub const Rect = geom.Rect;
pub const Vec2 = geom.Vec2;
pub const Id = id_mod.Id;

/// How far the pointer must move from the press origin before an armed drag becomes a real one
/// (screen pixels; squared-distance compared, so no per-pixel sqrt).
pub const drag_threshold_px: i32 = 4;

/// An opaque, fixed-size, trivially-copyable payload. `kind` is a caller-chosen tag the library
/// never interprets (a hash of a name, an enum ordinal, whatever the caller finds convenient) --
/// it exists so `read` can refuse to reinterpret bytes as the wrong type.
///
/// Only trivially-copyable values belong here (integers, fixed arrays, structs of those). A slice
/// or pointer embedded in `T` is copied shallow (the header only): the pointee's lifetime is the
/// caller's responsibility, exactly as it is for `action_registry.ArgSpec`'s static-lifetime
/// contract elsewhere in this repository. Prefer a small stable handle (an index, a database id)
/// over embedding a whole record.
pub const MAX_DRAG_PAYLOAD_BYTES = 64;

pub const DragPayload = struct {
    kind: u32,
    bytes: [MAX_DRAG_PAYLOAD_BYTES]u8 = undefined,
    len: usize = 0,

    /// Builds a payload from a trivially-copyable `T` (asserted at comptime to fit). The bytes are
    /// copied out immediately, so `value` need not outlive this call.
    pub fn fromValue(comptime T: type, kind: u32, value: T) DragPayload {
        comptime std.debug.assert(@sizeOf(T) <= MAX_DRAG_PAYLOAD_BYTES);
        var p: DragPayload = .{ .kind = kind, .len = @sizeOf(T) };
        @memcpy(p.bytes[0..@sizeOf(T)], std.mem.asBytes(&value));
        return p;
    }

    /// Reads the payload back as `T`. Returns null when `kind` does not match or the stored byte
    /// length differs from `@sizeOf(T)` (a mismatched read is a caller bug, not silently coerced).
    pub fn read(self: DragPayload, comptime T: type, kind: u32) ?T {
        if (kind != self.kind or self.len != @sizeOf(T)) return null;
        return std.mem.bytesToValue(T, self.bytes[0..@sizeOf(T)]);
    }
};

const DragPhase = enum { armed, dragging };

pub const DragState = struct {
    source_id: Id,
    payload: DragPayload,
    phase: DragPhase,
    press_pos: Vec2,
    /// Set by a `dropTarget` that accepted this drag this frame. `finishDrag` consults it once
    /// to decide whether the caller gets the payload back (not accepted) or nothing (accepted --
    /// the target already has it via its own return value).
    accepted: bool = false,
};

pub const DragSourceResult = struct {
    /// True once this id's press has crossed the threshold (this frame or a later one, as long as
    /// the same id keeps calling in). False while merely armed, and false for any id other than
    /// the one currently owning the drag.
    dragging: bool = false,
    /// True only on the single frame the threshold is crossed. This is the caller's cue to mutate
    /// its data model (lift the item out, mark the pane detached, ...) -- not `dragging` staying
    /// true afterward, and not the raw press.
    started: bool = false,
};

fn pointHitsVisible(rect: Rect, clip: Rect, p: Vec2) bool {
    return context_mod.pointHitsVisible(rect, clip, p);
}

/// Call once per candidate source widget, right after building it (the same placement as
/// `ctx.tooltip(...)`/`ctx.noteLastInteractive(...)`), every frame regardless of press state (see
/// this file's doc comment for why). `payload` is only read on the frame the drag actually starts
/// (`.started == true`); a call before or after that frame may pass a stale/placeholder value with
/// no effect.
///
/// A drag source never claims keyboard focus or joins the Tab order: this is a pointer-capture
/// primitive, not a button. A widget must not be both a `dragSource` and a `buttonBehavior`-based
/// widget under the same id.
pub fn dragSource(ctx: *Context, id: Id, payload: DragPayload) DragSourceResult {
    std.debug.assert(ctx.frame_active);
    std.debug.assert(id != 0);
    if (ctx.isDisabled()) {
        ctx.clearDisabledInteraction(id);
        return .{};
    }
    if (ctx.popup_state != null or ctx.popup_stack.len != 0) return .{};

    if (ctx.drag) |*d| {
        if (d.source_id != id) return .{}; // a different drag (or none started by this id) owns the singleton
        ctx.drag_submitted_this_frame = true;
        switch (d.phase) {
            .armed => {
                if (!ctx.input.mouse_buttons.left) {
                    // Released before crossing the threshold: an ordinary click, not a drag. The
                    // caller never mutated anything for `armed` alone (that is deferred to
                    // `.started`), so there is nothing to restore.
                    ctx.drag = null;
                    if (ctx.state.active_id == id) ctx.state.active_id = 0;
                    return .{};
                }
                const dx = ctx.input.mouse_pos.x - d.press_pos.x;
                const dy = ctx.input.mouse_pos.y - d.press_pos.y;
                if (dx * dx + dy * dy >= drag_threshold_px * drag_threshold_px) {
                    d.phase = .dragging;
                    d.payload = payload; // committed now, at the moment the caller's data model also commits
                    return .{ .dragging = true, .started = true };
                }
                return .{};
            },
            .dragging => return .{ .dragging = true },
        }
    }

    if (ctx.state.active_id != 0) return .{}; // another widget (button, slider, ...) already owns the press
    const cached = ctx.rect_cache.get(id) orelse return .{};
    if (ctx.input.mouse_pressed.left and pointHitsVisible(cached.rect, cached.clip, ctx.input.mouse_pressed_pos)) {
        ctx.state.active_id = id;
        ctx.drag = .{ .source_id = id, .payload = payload, .phase = .armed, .press_pos = ctx.input.mouse_pressed_pos };
        ctx.drag_submitted_this_frame = true;
    }
    return .{};
}

pub const DropResult = struct {
    /// True while the pointer is over this target during an in-flight (`.dragging`) drag,
    /// regardless of whether it can accept it (for a caller-drawn highlight either way).
    hovering: bool = false,
    /// Set only on the release frame this target accepted the drop (`can_accept == true` and the
    /// release landed inside this target's previous-frame rect). Exactly one target can receive
    /// this in a given frame (whichever calls `dropTarget` first among overlapping candidates).
    accepted: ?DragPayload = null,
};

/// Call once per candidate drop-target widget, after building it. Deliberately does not go
/// through `buttonBehavior`: that gate only grants hover while `active_id == 0 or active_id ==
/// id`, which would starve every target since `active_id` belongs to the *source* widget for the
/// whole drag. No-op (returns `.{}`) unless a drag is actually `.dragging` (an armed-but-not-yet-
/// dragging press does not make targets light up).
pub fn dropTarget(ctx: *Context, id: Id, can_accept: bool) DropResult {
    std.debug.assert(ctx.frame_active);
    std.debug.assert(id != 0);
    if (ctx.isDisabled()) {
        ctx.clearDisabledInteraction(id);
        return .{};
    }
    if (ctx.popup_state != null or ctx.popup_stack.len != 0) return .{};

    const d = if (ctx.drag) |*d| d else return .{};
    if (d.phase != .dragging or d.accepted) return .{};
    const cached = ctx.rect_cache.get(id) orelse return .{};
    if (!pointHitsVisible(cached.rect, cached.clip, ctx.input.mouse_pos)) return .{};

    if (ctx.input.mouse_released.left and can_accept and
        pointHitsVisible(cached.rect, cached.clip, ctx.input.mouse_released_pos))
    {
        d.accepted = true;
        return .{ .hovering = true, .accepted = d.payload };
    }
    return .{ .hovering = true };
}

/// True only once a drag has crossed the threshold (`armed` alone does not count -- nothing is
/// observably "in flight" yet).
pub fn isDragging(ctx: *const Context) bool {
    return if (ctx.drag) |d| d.phase == .dragging else false;
}

/// The in-flight drag's payload, or null when not `.dragging` (including merely `armed`).
pub fn dragPayload(ctx: *const Context) ?DragPayload {
    return if (ctx.drag) |d| (if (d.phase == .dragging) d.payload else null) else null;
}

/// The live pointer position while `.dragging` (for the caller's own ghost drawing), else null.
pub fn dragPosition(ctx: *const Context) ?Vec2 {
    return if (isDragging(ctx)) ctx.input.mouse_pos else null;
}

/// Call once per frame, after every `dropTarget` call for the frame (recommended: right before
/// `ctx.endFrame()`, still inside the same frame `dragSource`/`dropTarget` ran in -- this keeps
/// `ctx.drag`/`active_id` already resolved by the time `endFrame`'s own active_id bookkeeping
/// runs, so the two never fight over the same frame). No-op unless the drag is `.dragging` and
/// the mouse was released this frame. Returns the payload only when nothing accepted it (the
/// caller's cue to restore its source state, mirroring the "released outside any target" branch
/// every drag-and-drop caller needs); returns null when a `dropTarget` already claimed it (that
/// target's own return value is the caller's copy) or the drag is still in flight.
pub fn finishDrag(ctx: *Context) ?DragPayload {
    const d = ctx.drag orelse return null;
    if (d.phase != .dragging or !ctx.input.mouse_released.left) return null;
    ctx.drag = null;
    if (ctx.state.active_id == d.source_id) ctx.state.active_id = 0;
    return if (d.accepted) null else d.payload;
}

/// Ends the current drag immediately regardless of mouse state (for an app's own Escape handling,
/// the same way it already owns Escape's meaning for a popup). Returns the payload when a real
/// drag (`.dragging`) was cancelled, so the caller can restore its source state; returns null for
/// `armed` (nothing was ever committed) or when there was no drag at all.
pub fn cancelDrag(ctx: *Context) ?DragPayload {
    const d = ctx.drag orelse return null;
    ctx.drag = null;
    if (ctx.state.active_id == d.source_id) ctx.state.active_id = 0;
    return if (d.phase == .dragging) d.payload else null;
}

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;
const font_mod = @import("font.zig");

fn testCtx() Context {
    return Context.init(testing.allocator, font_mod.default_font);
}

fn press(ctx: *Context, x: i32, y: i32) void {
    ctx.pushEvent(.{ .mouse_move = .{ .x = x, .y = y, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = x, .y = y, .button = 0, .modifiers = 0 } });
}
fn moveTo(ctx: *Context, x: i32, y: i32) void {
    ctx.pushEvent(.{ .mouse_move = .{ .x = x, .y = y, .modifiers = 0 } });
}
fn release(ctx: *Context, x: i32, y: i32) void {
    ctx.pushEvent(.{ .mouse_up = .{ .x = x, .y = y, .button = 0, .modifiers = 0 } });
}

/// One frame with a single 20x20 box at `id`, placed at the layout root's origin (registered in
/// the rect cache after endFrame, so the next frame's dragSource/dropTarget calls can sync-hit-
/// test against it).
fn frameWithBox(ctx: *Context, id: Id) void {
    ctx.beginFrame(200, 200);
    ctx.beginBox(.{ .id = id, .width = .{ .fixed = 20 }, .height = .{ .fixed = 20 } });
    ctx.endBox();
    ctx.endFrame();
}

/// One frame with two 20x20 boxes side by side in a row (a wide gap keeps them from touching).
/// Both survive in the rect cache simultaneously, unlike two separate `frameWithBox` calls would
/// (`endFrame` wipes and rebuilds the whole cache from just that frame's tree each time). Returns
/// their placed rects so a caller picks press/move/release coordinates from the real layout
/// rather than a guessed position.
fn frameWithTwoBoxes(ctx: *Context, id_a: Id, id_b: Id) struct { a: Rect, b: Rect } {
    ctx.beginFrame(200, 200);
    ctx.beginBox(.{ .direction = .row, .gap = 60 });
    ctx.beginBox(.{ .id = id_a, .width = .{ .fixed = 20 }, .height = .{ .fixed = 20 } });
    ctx.endBox();
    ctx.beginBox(.{ .id = id_b, .width = .{ .fixed = 20 }, .height = .{ .fixed = 20 } });
    ctx.endBox();
    ctx.endBox();
    ctx.endFrame();
    return .{ .a = ctx.getNodeRect(id_a).?, .b = ctx.getNodeRect(id_b).? };
}

const TestPayload = struct { slot: i32 };
const test_kind: u32 = 0xD1;

test "dragSource: a press alone does not start a drag (armed only)" {
    var ctx = testCtx();
    defer ctx.deinit();
    frameWithBox(&ctx, 1);

    ctx.beginFrame(200, 200);
    press(&ctx, 5, 5);
    const r = dragSource(&ctx, 1, DragPayload.fromValue(TestPayload, test_kind, .{ .slot = 1 }));
    try testing.expect(!r.dragging);
    try testing.expect(!r.started);
    try testing.expect(!isDragging(&ctx));
    ctx.endFrame();
}

test "dragSource: crossing the threshold starts a drag exactly once, payload readable" {
    var ctx = testCtx();
    defer ctx.deinit();
    frameWithBox(&ctx, 1);

    ctx.beginFrame(200, 200);
    press(&ctx, 5, 5);
    _ = dragSource(&ctx, 1, DragPayload.fromValue(TestPayload, test_kind, .{ .slot = 7 }));
    ctx.endFrame();

    ctx.beginFrame(200, 200);
    moveTo(&ctx, 5 + drag_threshold_px, 5);
    const r = dragSource(&ctx, 1, DragPayload.fromValue(TestPayload, test_kind, .{ .slot = 7 }));
    try testing.expect(r.dragging);
    try testing.expect(r.started);
    try testing.expect(isDragging(&ctx));
    const got = dragPayload(&ctx).?.read(TestPayload, test_kind).?;
    try testing.expectEqual(@as(i32, 7), got.slot);
    ctx.endFrame();

    // A later frame, still dragging: reports dragging, `started` is false, payload unchanged.
    ctx.beginFrame(200, 200);
    const r2 = dragSource(&ctx, 1, DragPayload.fromValue(TestPayload, test_kind, .{ .slot = 999 }));
    try testing.expect(r2.dragging);
    try testing.expect(!r2.started);
    try testing.expectEqual(@as(i32, 7), dragPayload(&ctx).?.read(TestPayload, test_kind).?.slot);
    ctx.endFrame();
}

test "dragSource: release before the threshold is a plain click, not a drag" {
    var ctx = testCtx();
    defer ctx.deinit();
    frameWithBox(&ctx, 1);

    ctx.beginFrame(200, 200);
    press(&ctx, 5, 5);
    _ = dragSource(&ctx, 1, DragPayload.fromValue(TestPayload, test_kind, .{ .slot = 1 }));
    ctx.endFrame();

    ctx.beginFrame(200, 200);
    release(&ctx, 5, 5);
    const r = dragSource(&ctx, 1, DragPayload.fromValue(TestPayload, test_kind, .{ .slot = 1 }));
    try testing.expect(!r.dragging);
    try testing.expect(!isDragging(&ctx));
    ctx.endFrame();
}

test "dropTarget: accepts on release inside its rect, finishDrag reports claimed" {
    var ctx = testCtx();
    defer ctx.deinit();
    const boxes = frameWithTwoBoxes(&ctx, 1, 2);
    const pa: Vec2 = .{ .x = boxes.a.x + 2, .y = boxes.a.y + 2 };
    const pb: Vec2 = .{ .x = boxes.b.x + 2, .y = boxes.b.y + 2 };

    ctx.beginFrame(200, 200);
    press(&ctx, pa.x, pa.y);
    _ = dragSource(&ctx, 1, DragPayload.fromValue(TestPayload, test_kind, .{ .slot = 1 }));
    ctx.endFrame();

    ctx.beginFrame(200, 200);
    moveTo(&ctx, pa.x + drag_threshold_px + 1, pa.y); // still held, past threshold, not yet over b
    _ = dragSource(&ctx, 1, DragPayload.fromValue(TestPayload, test_kind, .{ .slot = 1 }));
    ctx.endFrame();

    ctx.beginFrame(200, 200);
    moveTo(&ctx, pb.x, pb.y);
    release(&ctx, pb.x, pb.y);
    _ = dragSource(&ctx, 1, DragPayload.fromValue(TestPayload, test_kind, .{ .slot = 1 }));
    const drop = dropTarget(&ctx, 2, true);
    try testing.expect(drop.hovering);
    try testing.expect(drop.accepted != null);
    try testing.expectEqual(@as(i32, 1), drop.accepted.?.read(TestPayload, test_kind).?.slot);
    const finished = finishDrag(&ctx);
    try testing.expect(finished == null); // claimed: dropTarget's own return is the caller's copy
    try testing.expect(!isDragging(&ctx));
    ctx.endFrame();
}

test "dropTarget: can_accept=false leaves the drag unclaimed; finishDrag hands the payload back" {
    var ctx = testCtx();
    defer ctx.deinit();
    const boxes = frameWithTwoBoxes(&ctx, 1, 2);
    const pa: Vec2 = .{ .x = boxes.a.x + 2, .y = boxes.a.y + 2 };
    const pb: Vec2 = .{ .x = boxes.b.x + 2, .y = boxes.b.y + 2 };

    ctx.beginFrame(200, 200);
    press(&ctx, pa.x, pa.y);
    _ = dragSource(&ctx, 1, DragPayload.fromValue(TestPayload, test_kind, .{ .slot = 3 }));
    ctx.endFrame();

    ctx.beginFrame(200, 200);
    moveTo(&ctx, pa.x + drag_threshold_px + 1, pa.y);
    _ = dragSource(&ctx, 1, DragPayload.fromValue(TestPayload, test_kind, .{ .slot = 3 }));
    ctx.endFrame();

    ctx.beginFrame(200, 200);
    moveTo(&ctx, pb.x, pb.y);
    release(&ctx, pb.x, pb.y);
    _ = dragSource(&ctx, 1, DragPayload.fromValue(TestPayload, test_kind, .{ .slot = 3 }));
    const drop = dropTarget(&ctx, 2, false); // locked destination, say
    try testing.expect(drop.hovering);
    try testing.expect(drop.accepted == null);
    const finished = finishDrag(&ctx);
    try testing.expect(finished != null);
    try testing.expectEqual(@as(i32, 3), finished.?.read(TestPayload, test_kind).?.slot);
    try testing.expect(!isDragging(&ctx));
    ctx.endFrame();
}

test "finishDrag: released over nothing hands the payload back" {
    var ctx = testCtx();
    defer ctx.deinit();
    frameWithBox(&ctx, 1);

    ctx.beginFrame(200, 200);
    press(&ctx, 5, 5);
    _ = dragSource(&ctx, 1, DragPayload.fromValue(TestPayload, test_kind, .{ .slot = 2 }));
    ctx.endFrame();

    ctx.beginFrame(200, 200);
    moveTo(&ctx, 5 + drag_threshold_px, 5);
    _ = dragSource(&ctx, 1, DragPayload.fromValue(TestPayload, test_kind, .{ .slot = 2 }));
    ctx.endFrame();

    ctx.beginFrame(200, 200);
    moveTo(&ctx, 150, 150);
    release(&ctx, 150, 150);
    _ = dragSource(&ctx, 1, DragPayload.fromValue(TestPayload, test_kind, .{ .slot = 2 }));
    const finished = finishDrag(&ctx);
    try testing.expect(finished != null);
    try testing.expectEqual(@as(i32, 2), finished.?.read(TestPayload, test_kind).?.slot);
    ctx.endFrame();
}

test "cancelDrag: cancels an armed press with no payload back, and a dragging one with the payload" {
    var ctx = testCtx();
    defer ctx.deinit();
    frameWithBox(&ctx, 1);

    ctx.beginFrame(200, 200);
    press(&ctx, 5, 5);
    _ = dragSource(&ctx, 1, DragPayload.fromValue(TestPayload, test_kind, .{ .slot = 4 }));
    try testing.expect(cancelDrag(&ctx) == null); // armed only: nothing committed yet
    try testing.expect(!isDragging(&ctx));
    ctx.endFrame();

    frameWithBox(&ctx, 1);
    ctx.beginFrame(200, 200);
    press(&ctx, 5, 5);
    _ = dragSource(&ctx, 1, DragPayload.fromValue(TestPayload, test_kind, .{ .slot = 4 }));
    ctx.endFrame();
    ctx.beginFrame(200, 200);
    moveTo(&ctx, 5 + drag_threshold_px, 5);
    _ = dragSource(&ctx, 1, DragPayload.fromValue(TestPayload, test_kind, .{ .slot = 4 }));
    const cancelled = cancelDrag(&ctx);
    try testing.expect(cancelled != null);
    try testing.expectEqual(@as(i32, 4), cancelled.?.read(TestPayload, test_kind).?.slot);
    try testing.expect(!isDragging(&ctx));
    ctx.endFrame();
}

test "an armed drag whose source is not resubmitted is cancelled at the next endFrame" {
    var ctx = testCtx();
    defer ctx.deinit();
    frameWithBox(&ctx, 1);

    // Frame 1: the press arms the drag (dragSource is called, so it survives this endFrame --
    // being freshly created this same frame counts as "submitted").
    ctx.beginFrame(200, 200);
    press(&ctx, 5, 5);
    _ = dragSource(&ctx, 1, DragPayload.fromValue(TestPayload, test_kind, .{ .slot = 9 }));
    try testing.expect(ctx.drag != null);
    ctx.endFrame();
    try testing.expect(ctx.drag != null);

    // Frame 2: the source widget is not called at all (simulating it having vanished from the
    // tree). Still armed (never crossed the threshold), so endFrame cancels it outright.
    ctx.beginFrame(200, 200);
    ctx.endFrame();

    try testing.expect(ctx.drag == null);
    try testing.expectEqual(@as(Id, 0), ctx.state.active_id);
}

test "DragPayload.read: a kind or size mismatch returns null rather than misreading bytes" {
    const p = DragPayload.fromValue(TestPayload, test_kind, .{ .slot = 5 });
    try testing.expect(p.read(TestPayload, test_kind + 1) == null);
    const Other = struct { a: i32, b: i32 };
    try testing.expect(p.read(Other, test_kind) == null);
    try testing.expectEqual(@as(i32, 5), p.read(TestPayload, test_kind).?.slot);
}
