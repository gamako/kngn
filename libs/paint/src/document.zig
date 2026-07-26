//! Document — cell-grid / linked-cel model.
//!
//! frames × layers × cel_pool linked-cel model. Replaces the prior `frames:[]*Canvas`
//! layout with an Aseprite-style cell grid (sparse layer×frame → cel refs; null=empty cel=transparent;
//! multiple frames pointing at the same CelId yields linked edit = shared edit).
//!
//! - `Canvas` (`active_view`) is reused unchanged as the "editable view of the active frame"
//!   (ownership model unchanged. Option B = copy-sync).
//! - `Op`/`UndoStack` (push/apply · `CelSetSnapshot`) live in this file (`undo.zig` holds only
//!   `PixelDiff`/`NameSnapshot`/`StrokeRecorder`/`PaintDiff` and does not import this file —
//!   one-way dependency; avoids circular import).
//! - A CelId, once issued for the Document lifetime, is **never reassigned to a different cel**
//!   (no free-list; undo/redo history keeps old CelId values).
//!
//! Hot-path declaration: event-time APIs in this file are **event-time only** (frame switch, undo/redo,
//! cel/frame/layer ops each run once per user action). The main per-frame full-pixel path is
//! `active_view.composite()`/`compositeStraight()` (existing Canvas SIMD path; unchanged).
//! **Exception**: `compositeFrameStraight` is per display-frame, full-pixel (onion-skin path only).
//! Does not mutate `selected_frame` / `active_view` / composite cache.
//! `@memcpy` in `resyncActiveView`/`pushPaintOp` copies 1..few layers once, and runs only
//! right after frame switch, undo/redo, project load, or stroke commit
//! (must not enter the main loop's every-frame path — explicit ban).

const std = @import("std");
const Allocator = std.mem.Allocator;
const canvas_mod = @import("canvas.zig");
const Canvas = canvas_mod.Canvas;
const LayerKind = canvas_mod.LayerKind;
const TextParams = canvas_mod.TextParams;
const layer_name_max = canvas_mod.layer_name_max;
const undo_mod = @import("undo.zig");
pub const PixelDiff = undo_mod.PixelDiff;
const NameSnapshot = undo_mod.NameSnapshot;
const text_render = @import("text_render.zig");
const blend = @import("blend.zig");
const pixelops = @import("pixelops");

/// Truncate text to at most max bytes without cutting mid a UTF-8 continuation byte (0b10xxxxxx);
/// return the truncated length (same logic as the private helper of the same name in `canvas.zig`.
/// Duplicated for `LayerDef.setName` only so `canvas.zig` visibility stays unchanged; same fixed-length policy).
fn safeUtf8TruncateLen(text: []const u8, max: usize) usize {
    var n = @min(text.len, max);
    while (n > 0 and n < text.len and (text[n] & 0xC0) == 0x80) : (n -= 1) {}
    return n;
}

/// Slot id in cel_pool. **Once issued for the Document lifetime, a value is never
/// reassigned to a different cel**.
pub const CelId = u32;

pub const Cel = struct {
    pixels: []u32, // canonical BGRA; owned by gpa
    refcount: u32 = 1, // How many frame columns within the same layer reference this cel
};

/// Stable layer handle. Independent of index; keeps pointing at the same layer across
/// move/delete/insert. **0 is reserved invalid**; monotonic allocation; **no reuse**
/// (except when undo restores a whole LayerDef; deleted ids are not reassigned otherwise).
/// Allocate/resolve event-time only (does not touch per-frame composite).
pub const LayerId = enum(u64) {
    invalid = 0,
    _,
};

/// Layer definition (Document level; shared across all frames. name/kind/TextParams
/// live here).
pub const LayerDef = struct {
    /// Stable handle. Document allocates on create (add/insert/load). Default `.invalid` is for
    /// temporary construction; once on Document.layers it must be non-invalid.
    id: LayerId = .invalid,
    visible: bool = true,
    opacity: u8 = 255,
    name_buf: [layer_name_max]u8 = undefined,
    name_len: u8 = 0,
    kind: LayerKind = .raster,
    text_params: TextParams = .{}, // Meaningful only when kind==.text

    pub fn name(self: *const LayerDef) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn setName(self: *LayerDef, text: []const u8) void {
        const n = safeUtf8TruncateLen(text, layer_name_max);
        @memcpy(self.name_buf[0..n], text[0..n]);
        self.name_len = @intCast(n);
    }
};

pub const Frame = struct {
    duration_ms: u32 = 100,
};

/// Effective playback interval in seconds. `interval = (1/fps) × (duration_ms/100)`.
/// fps is the global rate; duration_ms is a per-frame relative factor (default 100 → factor 1.0 = classic 1/fps).
///
/// Spec:
/// - All math in f64
/// - `fps <= 0` → `+inf` (does not advance; UI slider is positive-only, but defend)
/// - `duration_ms == 0` → treat as 100 (prevents busy advance at zero interval)
/// - Inputs are slider(f32 positive)/u32 only; non-finite values do not enter
pub fn playbackIntervalSec(fps: f32, duration_ms: u32) f64 {
    if (fps <= 0) return std.math.inf(f64);
    const fps_f64: f64 = @floatCast(fps);
    const dur: f64 = if (duration_ms == 0) 100.0 else @as(f64, @floatFromInt(duration_ms));
    return dur / 100.0 * (1.0 / fps_f64);
}

/// Catch-up-free advance check. True when `now - last >= interval`.
/// Does not compensate leftover time (caller resets `last = now` after advance).
pub fn shouldAdvance(now: f64, last: f64, interval: f64) bool {
    return now - last >= interval;
}

/// Temporarily holds one layer's full frame row (for layer_add/delete) or one frame's full layer column
/// (for frame_add/delete/duplicate) for delete/restore.
/// Shared named type for `CelSetSnapshot.fully_released`/`Document.mergeDown` (anonymous structs
/// are distinct types per occurrence and do not unify under Zig type checking, so name it to match
/// producers such as `.captureAndReleaseSlots`).
pub const CelSnapshotItem = struct { id: CelId, pixels: []u32 };

pub const CelSetSnapshot = struct {
    /// Per-slot original CelId (null=was already empty). frames.len for a row, layers.len for a column.
    /// **This array alone does not tell whether a body is held** (cross-check with fully_released below).
    slots: []?CelId,
    /// Among CelIds appearing in slots, keep **only those whose refcount hit 0 from this delete and were
    /// actually removed from `cel_pool`**, without duplicates (each id once).
    fully_released: []CelSnapshotItem,
};

/// Shared Op payload for layer_add/layer_delete (same type so switch prongs can merge).
pub const LayerStructOp = struct {
    index: usize,
    selected_before: usize,
    selected_after: usize,
    /// Right after push=null (structure already changed; canvas no longer held) → non-null on undo (capture)
    /// → null on redo (restore). Meaning flips for layer_add/delete (same toggle pattern).
    def: ?LayerDef = null,
    row: ?CelSetSnapshot = null,
};

/// Shared Op payload for frame_add/frame_delete.
pub const FrameStructOp = struct {
    index: u32,
    selected_before: u32,
    selected_after: u32,
    duration_ms: u32,
    col: ?CelSetSnapshot = null,
};

/// Body of one operation. Lives in `document.zig` (avoids circular import between undo.zig ⇄ document.zig).
pub const Op = union(enum) {
    /// Commit of a raster pixel edit (built by `Document.pushPaintOp`/`pushClear`; sole construction site).
    paint: struct {
        cel_id: CelId,
        diffs: []PixelDiff,
        layer_idx: usize,
        frame_idx: u32,
        /// Whether `ensureCelAt` created a new blank cel when this paint committed
        /// (= whether the grid slot was null until then).
        created: bool = false,
        /// Meaningful only when created==true. Non-null ⇔ the "before (not yet created)" state is currently applied
        /// (grid slot=null; cel removed from cel_pool; this Op owns the pixels).
        created_released: ?[]u32 = null,
    },

    // ── layer metadata (frame-independent) ───────────
    layer_visible: struct { index: usize, before: bool, after: bool },
    layer_opacity: struct { index: usize, before: u8, after: u8 },
    layer_rename: struct { index: usize, before: NameSnapshot, after: NameSnapshot },
    layer_reorder: struct { from: usize, to: usize, selected_before: usize, selected_after: usize },
    layer_text_params: struct { index: usize, before: TextParams, after: TextParams },
    layer_rasterize: struct { index: usize, before: TextParams },

    // ── layer structure (holds a row across all frames) ───────────
    layer_add: LayerStructOp,
    layer_delete: LayerStructOp,

    // ── frame structure (holds a column across all layers) ───────────
    frame_add: FrameStructOp,
    frame_delete: FrameStructOp,
    frame_duplicate: struct {
        src: u32,
        new_index: u32,
        selected_before: u32,
        selected_after: u32,
        duration_ms: u32,
        col: ?CelSetSnapshot = null,
    },

    // ── merge down (MVP: only allowed while frame count is 1) ─
    layer_merge_down: struct {
        index: usize,
        selected_before: usize,
        selected_after: usize,
        def: ?LayerDef = null,
        cel: ?CelSnapshotItem = null,
        below_before: []u32,
        below_after: []u32,
    },

    // ── cel link edit (apply CelSetSnapshot fully_released principle to one slot) ──
    cel_link: struct {
        layer_idx: usize,
        frame_idx: u32,
        before: ?CelId,
        after: CelId,
        before_released: ?[]u32 = null,
    },
    cel_unlink: struct {
        layer_idx: usize,
        frame_idx: u32,
        before: CelId,
        after: CelId,
        after_released: ?[]u32 = null,
    },
};

fn freeCelSetSnapshot(gpa: Allocator, snap: CelSetSnapshot) void {
    gpa.free(snap.slots);
    for (snap.fully_released) |fr| gpa.free(fr.pixels);
    gpa.free(snap.fully_released);
}

/// Free container arrays only, called **after** restoring a snapshot into cel_pool (pixels ownership
/// already moved to cel_pool, so do not free the pixels themselves).
fn freeCelSetSnapshotContainer(gpa: Allocator, snap: CelSetSnapshot) void {
    gpa.free(snap.slots);
    gpa.free(snap.fully_released);
}

fn freeOp(gpa: Allocator, op: *Op) void {
    switch (op.*) {
        .paint => |p| {
            gpa.free(p.diffs);
            if (p.created_released) |pixels| gpa.free(pixels);
        },
        .layer_add, .layer_delete => |ld| {
            if (ld.row) |row| freeCelSetSnapshot(gpa, row);
        },
        .frame_add, .frame_delete => |fd| {
            if (fd.col) |col| freeCelSetSnapshot(gpa, col);
        },
        .frame_duplicate => |fdup| {
            if (fdup.col) |col| freeCelSetSnapshot(gpa, col);
        },
        .layer_merge_down => |lm| {
            if (lm.cel) |c| gpa.free(c.pixels);
            gpa.free(lm.below_before);
            gpa.free(lm.below_after);
        },
        .cel_link => |cl| {
            if (cl.before_released) |pixels| gpa.free(pixels);
        },
        .cel_unlink => |cu| {
            if (cu.after_released) |pixels| gpa.free(pixels);
        },
        .layer_visible, .layer_opacity, .layer_rename, .layer_reorder, .layer_text_params, .layer_rasterize => {},
    }
}

/// Undo/Redo stack. Each Op's owned slices are owned by gpa.
///
/// **handle tag**: parallel array `handles` maps each Op in `undo` to a monotonic unique u64 handle
/// (`CommandRecord.undo_ref` points at this handle. u64 only — no dependency on command types, keeps
/// platform independence). `redo` is not tagged (not an undo candidate). Re-push via `redoOne`
/// **allocates a new handle** (link to the old record is broken; interim until undo/redo become
/// revert records).
pub const UndoStack = struct {
    pub const max_history: usize = 128;

    undo: std.ArrayList(Op) = .empty,
    redo: std.ArrayList(Op) = .empty,
    /// Handle parallel array synced with `undo` (invariant: handles.items.len == undo.items.len).
    handles: std.ArrayList(u64) = .empty,
    /// Owner-tag parallel array synced with `undo` (avoids owner misattribution after CommandLog
    /// ring eviction). **paint does not interpret tag meaning** (default 0=unknown; other values
    /// are app/pixie convention). push/redo re-push stack 0; app confirms via
    /// `setOwner`.
    owners: std.ArrayList(u8) = .empty,
    /// Next handle to allocate (monotonic; no reuse).
    next_handle: u64 = 1,

    pub fn deinit(self: *UndoStack, gpa: Allocator) void {
        freeStack(gpa, &self.undo);
        freeStack(gpa, &self.redo);
        self.handles.deinit(gpa);
        self.owners.deinit(gpa);
    }

    fn freeStack(gpa: Allocator, stack: *std.ArrayList(Op)) void {
        for (stack.items) |*op| freeOp(gpa, op);
        stack.deinit(gpa);
    }

    fn clearRedo(self: *UndoStack, gpa: Allocator) void {
        for (self.redo.items) |*op| freeOp(gpa, op);
        self.redo.clearRetainingCapacity();
    }

    /// Allocate a handle (used by push and `Document.redoOne` re-push).
    fn allocHandle(self: *UndoStack) u64 {
        const h = self.next_handle;
        self.next_handle += 1;
        return h;
    }

    /// Handle of the most recently pushed op (null if undo is empty).
    pub fn topHandle(self: *const UndoStack) ?u64 {
        const n = self.handles.items.len;
        if (n == 0) return null;
        return self.handles.items[n - 1];
    }

    /// Attach an owner tag to the op for the given handle (no-op if handle missing; tag meaning is app convention).
    pub fn setOwner(self: *UndoStack, handle: u64, tag: u8) void {
        for (self.handles.items, 0..) |h, i| {
            if (h == handle) {
                self.owners.items[i] = tag;
                return;
            }
        }
    }

    /// Owner tag for the given handle (missing → 0=unknown).
    pub fn ownerOf(self: *const UndoStack, handle: u64) u8 {
        for (self.handles.items, 0..) |h, i| {
            if (h == handle) return self.owners.items[i];
        }
        return 0;
    }

    /// Whether the Op for the given handle is still present on the undo array (live check for CommandRecord.undo_ref).
    pub fn hasHandle(self: *const UndoStack, handle: u64) bool {
        for (self.handles.items) |h| {
            if (h == handle) return true;
        }
        return false;
    }

    /// Push a non-empty command. Clears redo history.
    pub fn push(self: *UndoStack, gpa: Allocator, op: Op) void {
        self.clearRedo(gpa);
        if (self.undo.items.len >= max_history) {
            var oldest = self.undo.orderedRemove(0);
            freeOp(gpa, &oldest);
            _ = self.handles.orderedRemove(0);
            _ = self.owners.orderedRemove(0);
        }
        self.undo.append(gpa, op) catch @panic("UndoStack.push: OOM");
        self.handles.append(gpa, self.allocHandle()) catch @panic("UndoStack.push: OOM");
        self.owners.append(gpa, 0) catch @panic("UndoStack.push: OOM");
    }

    /// Clear all undo/redo history but **keep handle allocation (`next_handle`)**.
    /// Reset paths such as document load must use this (`deinit` + `= .{}` rebuilds would
    /// reset next_handle to 1, causing (1) underflow when differencing against pre-reset allocation values and
    /// (2) collisions between pre-reset CommandRecord.undo_ref and new Op handles → false-positive live checks.
    /// Handles stay monotonic with no reuse for the App/CommandLog lifetime).
    pub fn clearHistoryPreservingHandles(self: *UndoStack, gpa: Allocator) void {
        const preserved = self.next_handle;
        self.deinit(gpa);
        self.* = .{ .next_handle = preserved };
    }
};

pub const EnsureResult = struct { id: CelId, created: bool };

pub const Document = struct {
    width: u32,
    height: u32,
    layers: std.ArrayList(LayerDef) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    /// null = freed slot (never reused).
    cel_pool: std.ArrayList(?Cel) = .empty,
    next_cel_id: CelId = 0,
    /// Next LayerId raw value to allocate (monotonic; starts at 1 because 0=invalid reserved; no reuse).
    next_layer_id: u64 = 1,
    /// grid[layer_idx * frames.items.len + frame_idx] = ?CelId
    grid: std.ArrayList(?CelId) = .empty,
    selected_layer: usize = 0,
    selected_frame: u32 = 0,
    /// Editable view of the active frame for composite/tool drawing. Reuses existing Canvas type unchanged.
    active_view: Canvas,
    undo: UndoStack = .{},
    allocator: Allocator,
    /// Document-attached palette. Empty = unset (app initializes e.g. DB16 on load).
    /// selected is view state and is not persisted. Colors are canonical BGRA 0xAARRGGBB.
    palette: std.ArrayList(u32) = .empty,

    /// Create a Document with 1 layer / 1 frame (blank). App startup initial state.
    pub fn init(gpa: Allocator, w: u32, h: u32) !Document {
        var doc = try initEmpty(gpa, w, h);
        errdefer doc.deinit();
        var def: LayerDef = .{ .id = doc.allocLayerId() };
        def.setName("Layer 1");
        try doc.layers.append(gpa, def);
        try doc.frames.append(gpa, .{});
        try doc.grid.append(gpa, null); // Empty cel=transparent (lazy create)
        return doc;
    }

    /// Document with no layers/frames (scaffold the decoder builds into).
    /// `active_view` starts from Canvas.init's default 1 blank layer (after decode finishes,
    /// `resyncActiveView` reconciles it to match doc.layers).
    pub fn initEmpty(gpa: Allocator, w: u32, h: u32) !Document {
        const view = try Canvas.init(gpa, w, h);
        return .{ .width = w, .height = h, .active_view = view, .allocator = gpa };
    }

    /// Allocate one new LayerId (monotonic; no reuse; never returns 0=invalid).
    pub fn allocLayerId(self: *Document) LayerId {
        const raw = self.next_layer_id;
        self.next_layer_id += 1;
        return @enumFromInt(raw);
    }

    /// index → stable handle. Out of range → null.
    pub fn layerIdAt(self: *const Document, index: usize) ?LayerId {
        if (index >= self.layers.items.len) return null;
        return self.layers.items[index].id;
    }

    /// Stable handle → current index. Deleted / invalid / missing → null.
    pub fn layerIndexOf(self: *const Document, id: LayerId) ?usize {
        if (id == .invalid) return null;
        for (self.layers.items, 0..) |def, i| {
            if (def.id == id) return i;
        }
        return null;
    }

    pub fn deinit(self: *Document) void {
        for (self.cel_pool.items) |maybe_cel| if (maybe_cel) |cel| self.allocator.free(cel.pixels);
        self.cel_pool.deinit(self.allocator);
        self.layers.deinit(self.allocator);
        self.frames.deinit(self.allocator);
        self.grid.deinit(self.allocator);
        self.undo.deinit(self.allocator);
        self.palette.deinit(self.allocator);
        self.active_view.deinit();
    }

    /// Accessor for the `*Canvas` held by callers such as pixie.
    pub fn activeCanvas(self: *Document) *Canvas {
        return &self.active_view;
    }

    pub fn frameCount(self: *const Document) usize {
        return self.frames.items.len;
    }
    pub fn layerCount(self: *const Document) usize {
        return self.layers.items.len;
    }

    fn gridIndex(self: *const Document, layer_idx: usize, frame_idx: u32) usize {
        return layer_idx * self.frames.items.len + frame_idx;
    }

    pub fn gridGet(self: *const Document, layer_idx: usize, frame_idx: u32) ?CelId {
        return self.grid.items[self.gridIndex(layer_idx, frame_idx)];
    }

    /// Borrow cel_pool pixels (timeline thumbnails, etc.).
    pub fn celPixels(self: *const Document, id: CelId) ?[]const u32 {
        if (id >= self.cel_pool.items.len) return null;
        if (self.cel_pool.items[id]) |cel| return cel.pixels;
        return null;
    }

    fn setGrid(self: *Document, layer_idx: usize, frame_idx: u32, id: ?CelId) void {
        self.grid.items[self.gridIndex(layer_idx, frame_idx)] = id;
    }

    // ══════════════════════════════════════════════════════════════════
    // cel create / delete / link / GC
    // ══════════════════════════════════════════════════════════════════

    /// Allocate one blank cel and push it onto cel_pool (consumes one `next_cel_id`; no reuse).
    /// Returned CelId is always `cel_pool.items.len - 1` (append-only; nulling does not compact, so
    /// `cel_pool.items.len == next_cel_id` always holds).
    fn allocBlankCel(self: *Document, gpa: Allocator) CelId {
        const n = @as(usize, self.width) * self.height;
        const pixels = gpa.alloc(u32, n) catch @panic("Document.allocBlankCel: OOM");
        @memset(pixels, 0);
        const id = self.next_cel_id;
        self.next_cel_id += 1;
        self.cel_pool.append(gpa, Cel{ .pixels = pixels, .refcount = 1 }) catch @panic("Document.allocBlankCel: OOM");
        std.debug.assert(self.cel_pool.items.len == self.next_cel_id);
        return id;
    }

    /// Decrement refcount by 1. On reaching 0, take ownership of pixels and set `cel_pool[id]=null`
    /// (otherwise return null and leave the cel alive). Low-level single-decrement helper
    /// (separate from CelSetSnapshot capture; same principle, but for the simple case with no
    /// occurrence counting).
    fn releaseCelMaybeCapture(self: *Document, id: CelId) ?[]u32 {
        var cel = &(self.cel_pool.items[id].?);
        std.debug.assert(cel.refcount > 0);
        cel.refcount -= 1;
        if (cel.refcount == 0) {
            const pixels = cel.pixels;
            self.cel_pool.items[id] = null;
            return pixels;
        }
        return null;
    }

    fn retainCel(self: *Document, id: CelId) void {
        self.cel_pool.items[id].?.refcount += 1;
    }

    /// Return existing if present (no-op); otherwise allocate a new blank cel, set it on the grid, and return it.
    /// `created` is used by the caller (`pushPaintOp`) for the undo created flag.
    /// For kind==.text layers, the premise is that a shared cel already exists (assert if missing).
    pub fn ensureCelAt(self: *Document, gpa: Allocator, layer_idx: usize, frame_idx: u32) EnsureResult {
        if (self.gridGet(layer_idx, frame_idx)) |id| return .{ .id = id, .created = false };
        std.debug.assert(self.layers.items[layer_idx].kind != .text); // text should already have a shared cel
        const id = self.allocBlankCel(gpa);
        self.setGrid(layer_idx, frame_idx, id);
        return .{ .id = id, .created = true };
    }

    /// Thin public wrapper over `ensureCelAt` (for callers that discard whether created).
    pub fn createCel(self: *Document, gpa: Allocator, layer_idx: usize, frame_idx: u32) CelId {
        return self.ensureCelAt(gpa, layer_idx, frame_idx).id;
    }

    /// Clear a slot (release the cel ref; reclaim at 0). Already empty → no-op. Not Undo-aware
    /// (low-level primitive; callers design Undo separately as needed).
    pub fn clearCel(self: *Document, gpa: Allocator, layer_idx: usize, frame_idx: u32) void {
        const id = self.gridGet(layer_idx, frame_idx) orelse return;
        if (self.releaseCelMaybeCapture(id)) |pixels| gpa.free(pixels);
        self.setGrid(layer_idx, frame_idx, null);
    }

    /// Sole enforcement point for the text-layer invariant (every frame points at the same CelId).
    /// Scan the layer's grid column; the first non-null CelId found is canonical (create if none).
    /// Retarget remaining columns to the canonical (release/retain).
    pub fn normalizeTextLayerLinks(self: *Document, gpa: Allocator, layer_idx: usize) void {
        const nframes = self.frames.items.len;
        var canonical: ?CelId = null;
        for (0..nframes) |f| {
            if (self.gridGet(layer_idx, @intCast(f))) |id| {
                canonical = id;
                break;
            }
        }
        const canon = canonical orelse blk: {
            const id = self.allocBlankCel(gpa);
            self.cel_pool.items[id].?.refcount = 0; // No grid slot points at anything yet
            break :blk id;
        };
        for (0..nframes) |f| {
            const fi: u32 = @intCast(f);
            const cur = self.gridGet(layer_idx, fi);
            if (cur != null and cur.? == canon) continue; // Already canonical
            if (cur) |old_id| {
                if (self.releaseCelMaybeCapture(old_id)) |pixels| gpa.free(pixels);
            }
            self.retainCel(canon);
            self.setGrid(layer_idx, fi, canon);
        }
    }

    /// Immediate `active_view` update for `linkCel`/`unlinkCel` (normal Document API paths may update
    /// `active_view` themselves; do not go through resyncActiveView).
    fn syncActiveViewSlot(self: *Document, layer_idx: usize, frame_idx: u32) void {
        if (frame_idx != self.selected_frame) return;
        const dst = self.active_view.layerPixels(layer_idx);
        if (self.gridGet(layer_idx, frame_idx)) |id| {
            @memcpy(dst, self.cel_pool.items[id].?.pixels);
        } else {
            @memset(dst, 0);
        }
    }

    /// Retarget the `dst_frame` slot to the CelId that `src_frame` points at (establishes shared edit (a)).
    /// Undo-aware (`Op.cel_link`; one-slot application of CelSetSnapshot fully_released).
    pub fn linkCel(self: *Document, gpa: Allocator, layer_idx: usize, dst_frame: u32, src_frame: u32) !void {
        if (self.layers.items[layer_idx].kind == .text) return error.TextLayerLinked;
        const src_id = self.gridGet(layer_idx, src_frame) orelse return error.SourceCelEmpty;
        const dst_before = self.gridGet(layer_idx, dst_frame);
        if (dst_before != null and dst_before.? == src_id) return; // Already linked (no-op)
        var before_released: ?[]u32 = null;
        if (dst_before) |bid| before_released = self.releaseCelMaybeCapture(bid);
        self.retainCel(src_id);
        self.setGrid(layer_idx, dst_frame, src_id);
        self.undo.push(gpa, .{ .cel_link = .{
            .layer_idx = layer_idx,
            .frame_idx = dst_frame,
            .before = dst_before,
            .after = src_id,
            .before_released = before_released,
        } });
        self.syncActiveViewSlot(layer_idx, dst_frame);
    }

    /// Duplicate the shared cel at the target slot into an independent cel (refcount--; new cel has
    /// refcount=1). Undo-aware (`Op.cel_unlink`). Already unshared (refcount<=1) → no-op.
    pub fn unlinkCel(self: *Document, gpa: Allocator, layer_idx: usize, frame_idx: u32) !void {
        if (self.layers.items[layer_idx].kind == .text) return error.TextLayerLinked;
        const cid = self.gridGet(layer_idx, frame_idx) orelse return error.EmptySlot;
        const refcount = self.cel_pool.items[cid].?.refcount;
        if (refcount <= 1) return; // Already independent (no-op)
        const new_id = self.allocBlankCel(gpa);
        @memcpy(self.cel_pool.items[new_id].?.pixels, self.cel_pool.items[cid].?.pixels);
        std.debug.assert(self.releaseCelMaybeCapture(cid) == null); // Shared, so will not hit 0
        self.setGrid(layer_idx, frame_idx, new_id);
        self.undo.push(gpa, .{ .cel_unlink = .{
            .layer_idx = layer_idx,
            .frame_idx = frame_idx,
            .before = cid,
            .after = new_id,
            .after_released = null,
        } });
        self.syncActiveViewSlot(layer_idx, frame_idx);
    }

    // ══════════════════════════════════════════════════════════════════
    // Sync with Canvas
    // ══════════════════════════════════════════════════════════════════

    /// Rebuild each layer of the current frame from doc.layers+grid[*][selected_frame] (read path).
    /// Call sites: only the three places right after frame switch, undoOne/redoOne, or project load
    /// (must not enter the main loop's every-frame path — explicit ban).
    pub fn resyncActiveView(self: *Document, gpa: Allocator) void {
        // Layer-count reconcile: alloc/free of Canvas-owned pixels is left to the Canvas API.
        while (self.active_view.layers.items.len > self.layers.items.len) {
            const removed = self.active_view.deleteLayer(self.active_view.layers.items.len - 1) orelse break;
            gpa.free(removed.pixels);
        }
        while (self.active_view.layers.items.len < self.layers.items.len) {
            const blank = self.active_view.allocBlankLayer(gpa) catch @panic("Document.resyncActiveView: OOM");
            self.active_view.insertLayer(gpa, self.active_view.layers.items.len, blank) catch @panic("Document.resyncActiveView: OOM");
        }
        // per-layer content + metadata (via layerPixels() accessor: do not touch `layers.items[i].pixels`
        // directly so composite-cache invalidation stays automatic).
        for (self.layers.items, 0..) |def, i| {
            const dst = self.active_view.layerPixels(i);
            if (self.gridGet(i, self.selected_frame)) |cel_id| {
                @memcpy(dst, self.cel_pool.items[cel_id].?.pixels);
            } else {
                @memset(dst, 0);
            }
            self.active_view.layers.items[i].visible = def.visible;
            self.active_view.layers.items[i].opacity = def.opacity;
            self.active_view.layers.items[i].setName(def.name());
            self.active_view.layers.items[i].kind = def.kind;
            self.active_view.layers.items[i].text_params = def.text_params;
        }
        // selected_layer: Document is the sole authority. Never touch system_font.
        self.active_view.selected_layer = self.selected_layer;
    }

    /// Composite all visible layers of the given frame with straight alpha into `dst` (display only).
    /// Does not mutate `selected_frame` / `active_view` / composite cache at all.
    ///
    /// Hot path that runs every frame over all pixels × layer count (onion-skin display only; via `onion_skin.build`).
    /// Same shape as `canvas.compositeStraight`: pixelops SIMD 4px loop (reads cel_pool directly).
    pub fn compositeFrameStraight(self: *const Document, frame_idx: u32, dst: []u32) void {
        const n = @as(usize, self.width) * self.height;
        std.debug.assert(dst.len == n);
        std.debug.assert(frame_idx < self.frames.items.len);
        @memset(dst, 0);
        for (self.layers.items, 0..) |def, i| {
            if (!def.visible) continue;
            const op = def.opacity;
            const cel_id = self.gridGet(i, frame_idx) orelse continue;
            const layer_pixels = self.cel_pool.items[cel_id].?.pixels;
            var j: usize = 0;
            while (j + 4 <= n) : (j += 4) {
                const s4: [4]u32 = layer_pixels[j..][0..4].*;
                if ((s4[0] | s4[1] | s4[2] | s4[3]) & 0xFF000000 == 0) continue;
                const dst_chunk: *[4]u32 = dst[j..][0..4];
                dst_chunk.* = @bitCast(pixelops.srcOverStraight4(@bitCast(dst_chunk.*), @bitCast(s4), op));
            }
            while (j < n) : (j += 1) {
                const s = layer_pixels[j];
                if (s & 0xFF000000 == 0) continue;
                dst[j] = pixelops.srcOverStraightScalar(dst[j], s, op);
            }
        }
    }

    /// Write the given active_view layer fully back into the current `selected_frame` cel_pool
    /// (`ensureCelAt` + memcpy; returns `created`). Shared by pushPaintOp / commitActiveLayerToCel.
    fn writebackActiveLayerToCel(self: *Document, gpa: Allocator, layer_idx: usize) EnsureResult {
        const ensured = self.ensureCelAt(gpa, layer_idx, self.selected_frame);
        @memcpy(self.cel_pool.items[ensured.id].?.pixels, self.active_view.layerPixels(layer_idx));
        return ensured;
    }

    /// Write the given active_view layer back into the current `selected_frame` cel (no undo Op).
    /// For full replacement that is not Op-ified (e.g. PNG open). Frame is always `selected_frame`
    /// (0 after `resetToSingleBlankLayer`). Forbidden on text layers (assert).
    /// Hot path: event-time only (open/save path).
    pub fn commitActiveLayerToCel(self: *Document, gpa: Allocator, layer_idx: usize) void {
        std.debug.assert(self.layers.items[layer_idx].kind != .text);
        _ = self.writebackActiveLayerToCel(gpa, layer_idx);
    }

    /// Sole commit site for every operation that mutates raster pixels
    /// (folds ensureCelAt → write-back → Op build → push into one call).
    /// Ownership of `diffs` always transfers to doc on entry (must free even on early return).
    pub fn pushPaintOp(self: *Document, gpa: Allocator, layer_idx: usize, diffs: []PixelDiff) error{TextLayerSelected}!void {
        if (self.layers.items[layer_idx].kind == .text) {
            gpa.free(diffs);
            return error.TextLayerSelected;
        }
        if (diffs.len == 0) {
            gpa.free(diffs); // No change. Do not create a cel or push.
            return;
        }
        const ensured = self.writebackActiveLayerToCel(gpa, layer_idx);
        self.undo.push(gpa, .{ .paint = .{
            .cel_id = ensured.id,
            .diffs = diffs,
            .layer_idx = layer_idx,
            .frame_idx = self.selected_frame,
            .created = ensured.created,
        } });
    }

    /// Build and push an Op that clears the selected layer's current frame (thin wrapper that folds
    /// `pushPaintOp`'s "build→memset→push" into one API).
    pub fn pushClear(self: *Document, gpa: Allocator, layer_idx: usize) error{TextLayerSelected}!void {
        if (self.layers.items[layer_idx].kind == .text) return error.TextLayerSelected;
        const pixels = self.active_view.layerPixels(layer_idx);
        var diffs: std.ArrayList(PixelDiff) = .empty;
        diffs.ensureTotalCapacity(gpa, pixels.len) catch @panic("Document.pushClear: OOM");
        for (pixels, 0..) |p, i| {
            if (p == 0) continue;
            diffs.appendAssumeCapacity(.{ .idx = @intCast(i), .before = p, .after = 0 });
        }
        if (diffs.items.len == 0) {
            diffs.deinit(gpa);
            return;
        }
        @memset(pixels, 0);
        const owned = diffs.toOwnedSlice(gpa) catch @panic("Document.pushClear: OOM");
        try self.pushPaintOp(gpa, layer_idx, owned);
    }

    /// Bulk-replace color `from` with `to` on the selected layer's current frame.
    /// Exact match; no tolerance (pixel-art premise). `from==to` or 0 pixels → no-op (no Op pushed).
    /// Return value = replaced pixel count. Event-time only (not a per-frame loop).
    pub fn pushReplaceColor(self: *Document, gpa: Allocator, layer_idx: usize, from: u32, to: u32) error{TextLayerSelected}!u32 {
        if (from == to) return 0;
        if (self.layers.items[layer_idx].kind == .text) return error.TextLayerSelected;
        const pixels = self.active_view.layerPixels(layer_idx);
        var diffs: std.ArrayList(PixelDiff) = .empty;
        diffs.ensureTotalCapacity(gpa, pixels.len) catch @panic("Document.pushReplaceColor: OOM");
        for (pixels, 0..) |p, i| {
            if (p != from) continue;
            diffs.appendAssumeCapacity(.{ .idx = @intCast(i), .before = p, .after = to });
        }
        if (diffs.items.len == 0) {
            diffs.deinit(gpa);
            return 0;
        }
        const count: u32 = @intCast(diffs.items.len);
        for (diffs.items) |d| pixels[d.idx] = to;
        const owned = diffs.toOwnedSlice(gpa) catch @panic("Document.pushReplaceColor: OOM");
        try self.pushPaintOp(gpa, layer_idx, owned);
        return count;
    }

    // ══════════════════════════════════════════════════════════════════
    // CelSetSnapshot capture/restore (batch: row=all frames of a layer; column=all layers of a frame)
    // ══════════════════════════════════════════════════════════════════

    /// For each cel occupied by `slots` (raw ?CelId array already extracted from the grid by the caller;
    /// ownership moves to the snapshot), compare occurrence count inside these slots against refcount:
    /// if occurrence==refcount, actually release and capture pixels (into fully_released);
    /// if occurrence<refcount, only decrement for the releases (cel stays alive).
    fn captureAndReleaseSlots(self: *Document, gpa: Allocator, slots: []?CelId) CelSetSnapshot {
        var fully: std.ArrayList(CelSnapshotItem) = .empty;
        var i: usize = 0;
        while (i < slots.len) : (i += 1) {
            const id = slots[i] orelse continue;
            var already = false;
            for (fully.items) |f| {
                if (f.id == id) {
                    already = true;
                    break;
                }
            }
            if (already) continue;
            var occurrences: u32 = 0;
            for (slots) |s| {
                if (s != null and s.? == id) occurrences += 1;
            }
            var cel = &(self.cel_pool.items[id].?);
            std.debug.assert(occurrences <= cel.refcount);
            if (occurrences == cel.refcount) {
                fully.append(gpa, .{ .id = id, .pixels = cel.pixels }) catch @panic("Document.captureAndReleaseSlots: OOM");
                self.cel_pool.items[id] = null;
            } else {
                cel.refcount -= occurrences;
            }
        }
        return .{ .slots = slots, .fully_released = fully.toOwnedSlice(gpa) catch @panic("Document.captureAndReleaseSlots: OOM") };
    }

    /// Restore snapshot contents into cel_pool (fully_released are rebuilt; survivors get refcount bumped
    /// by occurrence count). **Writing the grid is the caller's job** (this method touches
    /// cel_pool only).
    fn restoreCelPoolRefs(self: *Document, gpa: Allocator, snapshot: CelSetSnapshot) void {
        for (snapshot.fully_released) |fr| {
            var occ: u32 = 0;
            for (snapshot.slots) |s| {
                if (s != null and s.? == fr.id) occ += 1;
            }
            self.cel_pool.items[fr.id] = .{ .pixels = fr.pixels, .refcount = occ };
        }
        var seen: std.ArrayList(CelId) = .empty;
        defer seen.deinit(gpa);
        for (snapshot.slots) |maybe_id| {
            const id = maybe_id orelse continue;
            var already = false;
            for (seen.items) |s| if (s == id) {
                already = true;
                break;
            };
            if (already) continue;
            seen.append(gpa, id) catch @panic("Document.restoreCelPoolRefs: OOM");
            var in_fully = false;
            for (snapshot.fully_released) |fr| if (fr.id == id) {
                in_fully = true;
                break;
            };
            if (in_fully) continue; // Already restored by the loop above
            var occ: u32 = 0;
            for (snapshot.slots) |s| {
                if (s != null and s.? == id) occ += 1;
            }
            self.cel_pool.items[id].?.refcount += occ;
        }
    }

    // ── layer-row capture/restore (for layer_add/layer_delete) ──────────

    fn removeLayerRow(self: *Document, gpa: Allocator, layer_idx: usize) CelSetSnapshot {
        const nframes = self.frames.items.len;
        const start = layer_idx * nframes;
        const raw = gpa.dupe(?CelId, self.grid.items[start..][0..nframes]) catch @panic("Document.removeLayerRow: OOM");
        self.grid.replaceRange(gpa, start, nframes, &.{}) catch @panic("Document.removeLayerRow: OOM");
        return self.captureAndReleaseSlots(gpa, raw);
    }

    fn insertLayerRowFromSnapshot(self: *Document, gpa: Allocator, layer_idx: usize, snapshot: CelSetSnapshot) void {
        const nframes = self.frames.items.len;
        self.grid.insertSlice(gpa, layer_idx * nframes, snapshot.slots) catch @panic("Document.insertLayerRowFromSnapshot: OOM");
        self.restoreCelPoolRefs(gpa, snapshot);
        freeCelSetSnapshotContainer(gpa, snapshot);
    }

    // ── raw frame-column ops (cel_pool untouched; normal addFrame/duplicateFrame path) ──────

    /// Rebuild the grid into a shape with a new column at frame_idx (does not touch cel_pool).
    /// At call time self.frames is still pre-update (stride uses current frames.items.len).
    fn insertFrameColumnValues(self: *Document, gpa: Allocator, frame_idx: u32, values: []const ?CelId) void {
        const nlayers = self.layers.items.len;
        const old_stride = self.frames.items.len;
        std.debug.assert(values.len == nlayers);
        var new_grid: std.ArrayList(?CelId) = .empty;
        new_grid.ensureTotalCapacity(gpa, nlayers * (old_stride + 1)) catch @panic("Document.insertFrameColumnValues: OOM");
        for (0..nlayers) |l| {
            for (0..old_stride + 1) |f| {
                if (f == frame_idx) {
                    new_grid.appendAssumeCapacity(values[l]);
                } else {
                    const old_f = if (f < frame_idx) f else f - 1;
                    new_grid.appendAssumeCapacity(self.grid.items[l * old_stride + old_f]);
                }
            }
        }
        self.grid.deinit(gpa);
        self.grid = new_grid;
    }

    /// Rebuild the grid without the frame_idx column and return the removed column (does not touch
    /// cel_pool; at call time self.frames is still pre-update).
    fn removeFrameColumnValues(self: *Document, gpa: Allocator, frame_idx: u32) []?CelId {
        const nlayers = self.layers.items.len;
        const old_stride = self.frames.items.len;
        const removed = gpa.alloc(?CelId, nlayers) catch @panic("Document.removeFrameColumnValues: OOM");
        for (0..nlayers) |l| removed[l] = self.grid.items[l * old_stride + frame_idx];
        var new_grid: std.ArrayList(?CelId) = .empty;
        new_grid.ensureTotalCapacity(gpa, nlayers * (old_stride -| 1)) catch @panic("Document.removeFrameColumnValues: OOM");
        for (0..nlayers) |l| {
            for (0..old_stride) |f| {
                if (f == frame_idx) continue;
                new_grid.appendAssumeCapacity(self.grid.items[l * old_stride + f]);
            }
        }
        self.grid.deinit(gpa);
        self.grid = new_grid;
        return removed;
    }

    // ══════════════════════════════════════════════════════════════════
    // layer metadata ops (frame-independent)
    // ══════════════════════════════════════════════════════════════════

    /// Switch the selected layer (not Undo-aware. Same "no push" shape as existing UI/action
    /// `select_layer`. Sole Document-side entry so pixie does not call `active_view.selectLayer`
    /// directly).
    pub fn selectLayer(self: *Document, index: usize) !void {
        if (index >= self.layers.items.len) return error.OutOfRange;
        self.selected_layer = index;
        _ = self.active_view.selectLayer(index);
    }

    pub fn setLayerVisible(self: *Document, gpa: Allocator, index: usize, visible: bool) !void {
        if (index >= self.layers.items.len) return error.OutOfRange;
        const before = self.layers.items[index].visible;
        if (before == visible) return;
        self.layers.items[index].visible = visible;
        _ = self.active_view.setLayerVisible(index, visible);
        self.undo.push(gpa, .{ .layer_visible = .{ .index = index, .before = before, .after = visible } });
    }

    pub fn setLayerOpacity(self: *Document, gpa: Allocator, index: usize, opacity: u8) !void {
        if (index >= self.layers.items.len) return error.OutOfRange;
        const before = self.layers.items[index].opacity;
        if (before == opacity) return;
        self.layers.items[index].opacity = opacity;
        _ = self.active_view.setLayerOpacity(index, opacity);
        self.undo.push(gpa, .{ .layer_opacity = .{ .index = index, .before = before, .after = opacity } });
    }

    pub fn renameLayer(self: *Document, gpa: Allocator, index: usize, new_name: []const u8) !void {
        if (index >= self.layers.items.len) return error.OutOfRange;
        const before = NameSnapshot.of(self.layers.items[index].name());
        self.layers.items[index].setName(new_name);
        const after = NameSnapshot.of(self.layers.items[index].name());
        if (std.mem.eql(u8, before.slice(), after.slice())) return; // Idempotent no-op
        _ = self.active_view.setLayerName(index, self.layers.items[index].name());
        self.undo.push(gpa, .{ .layer_rename = .{ .index = index, .before = before, .after = after } });
    }

    pub fn reorderLayer(self: *Document, gpa: Allocator, from: usize, to: usize) !void {
        if (from >= self.layers.items.len or to >= self.layers.items.len or from == to) return error.OutOfRange;
        const selected_before = self.selected_layer;
        self.moveLayerRaw(gpa, from, to);
        self.selected_layer = to;
        _ = self.active_view.moveLayer(from, to);
        self.undo.push(gpa, .{ .layer_reorder = .{ .from = from, .to = to, .selected_before = selected_before, .selected_after = self.selected_layer } });
    }

    // ── LayerId resolve wrappers (additive; existing index APIs unchanged) ──
    // Deleted / invalid id → `error.UnknownLayerId`. Same results as the index APIs.

    pub fn selectLayerById(self: *Document, id: LayerId) !void {
        const index = self.layerIndexOf(id) orelse return error.UnknownLayerId;
        try self.selectLayer(index);
    }

    pub fn setLayerVisibleById(self: *Document, gpa: Allocator, id: LayerId, visible: bool) !void {
        const index = self.layerIndexOf(id) orelse return error.UnknownLayerId;
        try self.setLayerVisible(gpa, index, visible);
    }

    pub fn setLayerOpacityById(self: *Document, gpa: Allocator, id: LayerId, opacity: u8) !void {
        const index = self.layerIndexOf(id) orelse return error.UnknownLayerId;
        try self.setLayerOpacity(gpa, index, opacity);
    }

    /// Move the layer for `id` to index `to` (equivalent to `reorderLayer(from, to)`).
    pub fn moveLayerById(self: *Document, gpa: Allocator, id: LayerId, to: usize) !void {
        const from = self.layerIndexOf(id) orelse return error.UnknownLayerId;
        try self.reorderLayer(gpa, from, to);
    }

    pub fn deleteLayerById(self: *Document, gpa: Allocator, id: LayerId) !void {
        const index = self.layerIndexOf(id) orelse return error.UnknownLayerId;
        try self.deleteLayer(gpa, index);
    }

    /// Swap rows in doc.layers and the grid (same index semantics as `ArrayList.orderedRemove`+`insert`;
    /// `to` is the insertion position in the post-remove array).
    fn moveLayerRaw(self: *Document, gpa: Allocator, from: usize, to: usize) void {
        const moved = self.layers.orderedRemove(from);
        self.layers.insert(gpa, to, moved) catch @panic("Document.moveLayerRaw: OOM");
        const nframes = self.frames.items.len;
        const row = gpa.dupe(?CelId, self.grid.items[from * nframes ..][0..nframes]) catch @panic("Document.moveLayerRaw: OOM");
        defer gpa.free(row);
        self.grid.replaceRange(gpa, from * nframes, nframes, &.{}) catch @panic("Document.moveLayerRaw: OOM");
        self.grid.insertSlice(gpa, to * nframes, row) catch @panic("Document.moveLayerRaw: OOM");
    }

    // ══════════════════════════════════════════════════════════════════
    // layer structure ops
    // ══════════════════════════════════════════════════════════════════

    /// Append a new grid row; allocate a blank cel for **the current selected_frame only** (other frames
    /// stay null=transparent; lazy-created on first paint).
    pub fn addLayer(self: *Document, gpa: Allocator) !usize {
        const idx = self.layers.items.len;
        const selected_before = self.selected_layer;
        const av_layer = try self.active_view.allocBlankLayer(gpa);
        errdefer gpa.free(av_layer.pixels);
        var def: LayerDef = .{ .id = self.allocLayerId() };
        def.setName(av_layer.name());
        try self.layers.append(gpa, def);
        const nframes = self.frames.items.len;
        {
            const tmp = gpa.alloc(?CelId, nframes) catch @panic("Document.addLayer: OOM");
            defer gpa.free(tmp);
            @memset(tmp, null);
            self.grid.insertSlice(gpa, idx * nframes, tmp) catch @panic("Document.addLayer: OOM");
        }
        try self.active_view.insertLayer(gpa, idx, av_layer);
        self.selected_layer = idx;
        _ = self.ensureCelAt(gpa, idx, self.selected_frame);
        self.undo.push(gpa, .{ .layer_add = .{ .index = idx, .selected_before = selected_before, .selected_after = idx } });
        return idx;
    }

    /// Add a new text layer. Link a shared cel across **all existing frames**
    /// (asymmetric vs raster addLayer).
    pub fn addTextLayer(self: *Document, gpa: Allocator, params: TextParams) !usize {
        const idx = self.layers.items.len;
        const selected_before = self.selected_layer;
        const av_layer = try self.active_view.allocBlankLayer(gpa);
        errdefer gpa.free(av_layer.pixels);
        var def: LayerDef = .{ .id = self.allocLayerId(), .kind = .text, .text_params = params };
        def.setName(av_layer.name());
        const nframes = self.frames.items.len;
        const cel_id = self.allocBlankCel(gpa);
        text_render.rasterizeTextLayer(
            gpa,
            self.cel_pool.items[cel_id].?.pixels,
            self.width,
            self.height,
            params.text(),
            params.font_px,
            params.color,
            params.x,
            params.y,
            self.active_view.system_font,
        ) catch |e| {
            gpa.free(av_layer.pixels);
            return e;
        };
        self.cel_pool.items[cel_id].?.refcount = if (nframes == 0) 1 else @intCast(nframes);
        {
            const row = gpa.alloc(?CelId, nframes) catch @panic("Document.addTextLayer: OOM");
            defer gpa.free(row);
            @memset(row, cel_id);
            try self.layers.append(gpa, def);
            self.grid.insertSlice(gpa, idx * nframes, row) catch @panic("Document.addTextLayer: OOM");
        }
        try self.active_view.insertLayer(gpa, idx, av_layer);
        self.selected_layer = idx;
        self.undo.push(gpa, .{ .layer_add = .{ .index = idx, .selected_before = selected_before, .selected_after = idx } });
        self.resyncActiveView(gpa); // Reflect pixels/kind/text_params into active_view
        return idx;
    }

    /// Delete a grid row. Release each frame's cel ref (refcount--; reclaim at 0).
    pub fn deleteLayer(self: *Document, gpa: Allocator, index: usize) !void {
        if (self.layers.items.len <= 1) return error.LastLayer;
        if (index >= self.layers.items.len) return error.OutOfRange;
        const selected_before = self.selected_layer;
        const def = self.layers.orderedRemove(index);
        const snapshot = self.removeLayerRow(gpa, index);
        if (self.active_view.deleteLayer(index)) |removed| gpa.free(removed.pixels);
        if (self.selected_layer == index) {
            self.selected_layer = @min(index, self.layers.items.len -| 1);
        } else if (self.selected_layer > index) {
            self.selected_layer -= 1;
        }
        self.active_view.selected_layer = self.selected_layer;
        self.undo.push(gpa, .{ .layer_delete = .{
            .index = index,
            .selected_before = selected_before,
            .selected_after = self.selected_layer,
            .def = def,
            .row = snapshot,
        } });
    }

    /// Duplicate the selected layer and insert it immediately above. raster: independent deep copy per frame;
    /// text: treat as an independent layer linking a new cel across all existing frames.
    pub fn duplicateLayer(self: *Document, gpa: Allocator, src_idx: usize) !usize {
        if (src_idx >= self.layers.items.len) return error.OutOfRange;
        const new_idx = src_idx + 1;
        const selected_before = self.selected_layer;
        const src_def = self.layers.items[src_idx];
        // POD value copy (inherit text_params/name) + new LayerId (duplicate is a distinct identity)
        var new_def = src_def;
        new_def.id = self.allocLayerId();
        const nframes = self.frames.items.len;
        const row = gpa.alloc(?CelId, nframes) catch @panic("Document.duplicateLayer: OOM");
        defer gpa.free(row);
        if (src_def.kind == .text) {
            const new_cel = self.allocBlankCel(gpa);
            text_render.rasterizeTextLayer(
                gpa,
                self.cel_pool.items[new_cel].?.pixels,
                self.width,
                self.height,
                new_def.text_params.text(),
                new_def.text_params.font_px,
                new_def.text_params.color,
                new_def.text_params.x,
                new_def.text_params.y,
                self.active_view.system_font,
            ) catch @panic("Document.duplicateLayer: OOM");
            @memset(row, new_cel);
            self.cel_pool.items[new_cel].?.refcount = if (nframes == 0) 1 else @intCast(nframes);
        } else {
            for (0..nframes) |f| {
                if (self.gridGet(src_idx, @intCast(f))) |cid| {
                    const nid = self.allocBlankCel(gpa);
                    @memcpy(self.cel_pool.items[nid].?.pixels, self.cel_pool.items[cid].?.pixels);
                    row[f] = nid;
                } else {
                    row[f] = null;
                }
            }
        }
        try self.layers.insert(gpa, new_idx, new_def);
        self.grid.insertSlice(gpa, new_idx * nframes, row) catch @panic("Document.duplicateLayer: OOM");
        self.selected_layer = new_idx;
        self.undo.push(gpa, .{ .layer_add = .{ .index = new_idx, .selected_before = selected_before, .selected_after = new_idx } });
        self.resyncActiveView(gpa);
        return new_idx;
    }

    /// Update a text layer's text_params and re-rasterize the shared cel.
    pub fn setLayerTextParams(self: *Document, gpa: Allocator, index: usize, params: TextParams) !void {
        if (index >= self.layers.items.len) return error.OutOfRange;
        if (self.layers.items[index].kind != .text) return error.NotTextLayer;
        const before = self.layers.items[index].text_params;
        if (before.eql(params)) return;
        try self.rasterizeSharedTextCel(gpa, index, params);
        if (self.gridGet(index, self.selected_frame)) |cel_id| {
            @memcpy(self.active_view.layerPixels(index), self.cel_pool.items[cel_id].?.pixels);
        }
        self.active_view.layers.items[index].text_params = params;
        self.undo.push(gpa, .{ .layer_text_params = .{ .index = index, .before = before, .after = params } });
    }

    /// Find the layer's shared cel (premise: same CelId on every frame) and re-rasterize.
    fn sharedTextCelId(self: *const Document, layer_idx: usize) CelId {
        const nframes = self.frames.items.len;
        for (0..nframes) |f| {
            if (self.gridGet(layer_idx, @intCast(f))) |id| return id;
        }
        unreachable; // text-layer invariant: every frame has a cel
    }

    fn rasterizeSharedTextCel(self: *Document, gpa: Allocator, layer_idx: usize, params: TextParams) !void {
        self.layers.items[layer_idx].text_params = params;
        const cel_id = self.sharedTextCelId(layer_idx);
        const pixels = self.cel_pool.items[cel_id].?.pixels;
        try text_render.rasterizeTextLayer(gpa, pixels, self.width, self.height, params.text(), params.font_px, params.color, params.x, params.y, self.active_view.system_font);
    }

    /// Bake a text layer into a normal raster layer. pixels are unchanged (already the latest
    /// rasterize result). Returns pre-call text_params (for Undo).
    pub fn rasterizeLayer(self: *Document, gpa: Allocator, index: usize) !TextParams {
        if (index >= self.layers.items.len) return error.OutOfRange;
        if (self.layers.items[index].kind != .text) return error.NotTextLayer;
        const before = self.layers.items[index].text_params;
        self.layers.items[index].kind = .raster;
        self.layers.items[index].text_params = .{};
        self.active_view.layers.items[index].kind = .raster; // pixels unchanged; markDirty not needed
        self.active_view.layers.items[index].text_params = .{};
        self.undo.push(gpa, .{ .layer_rasterize = .{ .index = index, .before = before } });
        return before;
    }

    /// Bake the selected layer (top) into the one below (bottom=top-1) with opacity via src-over, then delete top.
    /// **Allowed only while frame count is 1** (MVP constraint; multi-frame support deferred).
    pub fn mergeDown(self: *Document, gpa: Allocator, top_idx: usize) !void {
        if (self.frames.items.len != 1) return error.MultiFrameMergeUnsupported;
        if (top_idx == 0) return error.OutOfRange;
        if (top_idx >= self.layers.items.len) return error.OutOfRange;
        const bottom_idx = top_idx - 1;
        if (self.layers.items[top_idx].kind == .text or self.layers.items[bottom_idx].kind == .text) {
            return error.TextLayerSelected;
        }
        const selected_before = self.selected_layer;
        const below_before = gpa.dupe(u32, self.active_view.layerPixels(bottom_idx)) catch @panic("Document.mergeDown: OOM");
        errdefer gpa.free(below_before);
        const top_def = self.layers.items[top_idx];
        const bottom_pixels = self.active_view.layerPixels(bottom_idx);
        if (top_def.visible) {
            const top_pixels = self.active_view.layerPixels(top_idx);
            for (bottom_pixels, 0..) |*bp, i| {
                const s = if (top_def.opacity != 255) blend.scaleAlpha(top_pixels[i], top_def.opacity) else top_pixels[i];
                bp.* = blend.srcOver(bp.*, s);
            }
        }
        const below_after = gpa.dupe(u32, bottom_pixels) catch @panic("Document.mergeDown: OOM");
        errdefer gpa.free(below_after);
        const bottom_cel = self.ensureCelAt(gpa, bottom_idx, 0);
        @memcpy(self.cel_pool.items[bottom_cel.id].?.pixels, bottom_pixels);

        const removed_id = self.gridGet(top_idx, 0);
        var cel_snapshot: ?CelSnapshotItem = null;
        if (removed_id) |rid| {
            const pixels = self.releaseCelMaybeCapture(rid) orelse @panic("Document.mergeDown: shared cel at frame-count==1 layer (invariant violated)");
            cel_snapshot = .{ .id = rid, .pixels = pixels };
        }
        const def = self.layers.orderedRemove(top_idx);
        self.grid.replaceRange(gpa, top_idx, 1, &.{}) catch @panic("Document.mergeDown: OOM");
        if (self.active_view.deleteLayer(top_idx)) |removed_layer| gpa.free(removed_layer.pixels);
        if (self.selected_layer == top_idx) {
            self.selected_layer = @min(top_idx, self.layers.items.len -| 1);
        } else if (self.selected_layer > top_idx) {
            self.selected_layer -= 1;
        }
        self.active_view.selected_layer = self.selected_layer;
        self.undo.push(gpa, .{ .layer_merge_down = .{
            .index = top_idx,
            .selected_before = selected_before,
            .selected_after = self.selected_layer,
            .def = def,
            .cel = cel_snapshot,
            .below_before = below_before,
            .below_after = below_after,
        } });
    }

    // ══════════════════════════════════════════════════════════════════
    // frame structure ops
    //
    // frame add/delete/duplicate rebuilds the whole grid (flat array with stride=frames.len).
    // Because selected_frame changes, the normal path (these three methods) also calls
    // resyncActiveView as a kind of "frame switch" (aligns with the three-site rule in intent:
    // never enter every-frame paths such as syncPreviewCanvas).
    // ══════════════════════════════════════════════════════════════════

    /// Insert an empty frame. raster layers: null=transparent; text layers: link to the shared cel.
    pub fn addFrame(self: *Document, gpa: Allocator, at: u32) !void {
        if (at > self.frames.items.len) return error.OutOfRange;
        const selected_before = self.selected_frame;
        const nlayers = self.layers.items.len;
        const values = gpa.alloc(?CelId, nlayers) catch @panic("Document.addFrame: OOM");
        defer gpa.free(values);
        @memset(values, null);
        self.insertFrameColumnValues(gpa, at, values);
        self.frames.insert(gpa, at, .{}) catch @panic("Document.addFrame: OOM");
        for (self.layers.items, 0..) |def, li| {
            if (def.kind == .text) self.normalizeTextLayerLinks(gpa, li);
        }
        self.selected_frame = if (selected_before >= at) selected_before + 1 else selected_before;
        self.undo.push(gpa, .{ .frame_add = .{ .index = at, .selected_before = selected_before, .selected_after = self.selected_frame, .duration_ms = 100 } });
        self.resyncActiveView(gpa);
    }

    /// Duplicate a frame (insert right after src). raster: deep-copy non-null (independent cel, refcount=1);
    /// leave null as null. text: do not deep-copy; link to the shared cel.
    pub fn duplicateFrame(self: *Document, gpa: Allocator, src: u32) !void {
        if (src >= self.frames.items.len) return error.OutOfRange;
        const new_index = src + 1;
        const selected_before = self.selected_frame;
        const duration_ms = self.frames.items[src].duration_ms;
        const nlayers = self.layers.items.len;
        const values = gpa.alloc(?CelId, nlayers) catch @panic("Document.duplicateFrame: OOM");
        defer gpa.free(values);
        for (self.layers.items, 0..) |def, li| {
            const src_cel = self.gridGet(li, src);
            if (def.kind == .text) {
                values[li] = src_cel; // Link to shared cel (retain happens in the loop below)
            } else if (src_cel) |cid| {
                const new_id = self.allocBlankCel(gpa);
                @memcpy(self.cel_pool.items[new_id].?.pixels, self.cel_pool.items[cid].?.pixels);
                values[li] = new_id;
            } else {
                values[li] = null;
            }
        }
        self.insertFrameColumnValues(gpa, new_index, values);
        for (self.layers.items, 0..) |def, li| {
            if (def.kind == .text) if (values[li]) |cid| self.retainCel(cid);
        }
        self.frames.insert(gpa, new_index, .{ .duration_ms = duration_ms }) catch @panic("Document.duplicateFrame: OOM");
        self.selected_frame = new_index;
        self.undo.push(gpa, .{ .frame_duplicate = .{ .src = src, .new_index = new_index, .selected_before = selected_before, .selected_after = self.selected_frame, .duration_ms = duration_ms } });
        self.resyncActiveView(gpa);
    }

    /// Delete a frame. Release each layer's cel ref for that column. Clamp selected_frame.
    pub fn deleteFrame(self: *Document, gpa: Allocator, index: u32) !void {
        if (self.frames.items.len <= 1) return error.LastFrame;
        if (index >= self.frames.items.len) return error.OutOfRange;
        const selected_before = self.selected_frame;
        const duration_ms = self.frames.items[index].duration_ms;
        const removed_values = self.removeFrameColumnValues(gpa, index);
        const snapshot = self.captureAndReleaseSlots(gpa, removed_values);
        _ = self.frames.orderedRemove(index);
        if (self.selected_frame > index) self.selected_frame -= 1;
        if (self.selected_frame >= self.frames.items.len) self.selected_frame = @intCast(self.frames.items.len - 1);
        self.undo.push(gpa, .{ .frame_delete = .{ .index = index, .selected_before = selected_before, .selected_after = self.selected_frame, .duration_ms = duration_ms, .col = snapshot } });
        self.resyncActiveView(gpa);
    }

    /// Change canvas size (keep contents; top-left-anchored crop/pad).
    /// Event-time only (action/menu confirm). Not per-frame or RT.
    ///
    /// - `new_w==0` / `new_h==0` / `new_w*new_h` overflow → recoverable error; state unchanged.
    /// - Same size → no-op.
    /// - build-new-before-swap: fully build the new cel_pool / active_view, then swap atomically.
    ///   On build failure **before swap**, free only the new resources; leave Document intact.
    ///   OOM in `resyncActiveView` after swap `@panic`s like existing paths (ADR-006).
    /// - CelId / layer / frame reference relations are preserved. Only live Cel pixel arrays are reallocated to the new size.
    /// - After swap: `resyncActiveView` → free old resources → clear undo history (old PixelDiff.idx invalid).
    pub fn resize(self: *Document, gpa: Allocator, new_w: u32, new_h: u32) error{ InvalidSize, SizeOverflow, OutOfMemory }!void {
        if (new_w == 0 or new_h == 0) return error.InvalidSize;
        const new_n = std.math.mul(usize, new_w, new_h) catch return error.SizeOverflow;
        // Pixel-array byte count must not overflow either (u32×u32 fits 64-bit usize, but ×4 can overflow)
        _ = std.math.mul(usize, new_n, @sizeOf(u32)) catch return error.SizeOverflow;
        if (self.width == new_w and self.height == new_h) return;

        const old_w = self.width;
        const old_h = self.height;
        const copy_w: usize = @min(old_w, new_w);
        const copy_h: usize = @min(old_h, new_h);

        var new_pool: std.ArrayList(?Cel) = .empty;
        var pool_transferred = false;
        errdefer if (!pool_transferred) {
            for (new_pool.items) |maybe| if (maybe) |cel| gpa.free(cel.pixels);
            new_pool.deinit(gpa);
        };
        try new_pool.ensureTotalCapacity(gpa, self.cel_pool.items.len);
        for (self.cel_pool.items) |maybe_old| {
            if (maybe_old) |old_cel| {
                const pixels = try gpa.alloc(u32, new_n);
                errdefer gpa.free(pixels);
                @memset(pixels, 0);
                var y: usize = 0;
                while (y < copy_h) : (y += 1) {
                    const src_off = y * old_w;
                    const dst_off = y * new_w;
                    @memcpy(pixels[dst_off..][0..copy_w], old_cel.pixels[src_off..][0..copy_w]);
                }
                new_pool.appendAssumeCapacity(.{ .pixels = pixels, .refcount = old_cel.refcount });
            } else {
                new_pool.appendAssumeCapacity(null);
            }
        }

        var new_view = try Canvas.init(gpa, new_w, new_h);
        var view_transferred = false;
        errdefer if (!view_transferred) new_view.deinit();
        new_view.system_font = self.active_view.system_font;

        // From here infallible (transfer new-resource ownership to Document)
        const old_pool = self.cel_pool;
        const old_view = self.active_view;
        self.width = new_w;
        self.height = new_h;
        self.cel_pool = new_pool;
        pool_transferred = true;
        self.active_view = new_view;
        view_transferred = true;

        self.resyncActiveView(gpa);

        for (old_pool.items) |maybe| if (maybe) |cel| gpa.free(cel.pixels);
        {
            var pool = old_pool;
            pool.deinit(gpa);
        }
        {
            var view = old_view;
            view.deinit();
        }

        self.undo.clearHistoryPreservingHandles(gpa);
    }

    /// For PNG open: shrink doc/active_view to "1 layer · 1 frame · 1 cel (empty)".
    /// Shrink existing `active_view` structure without re-init. Also discard undo/redo.
    pub fn resetToSingleBlankLayer(self: *Document, gpa: Allocator) void {
        while (self.active_view.layers.items.len > 1) {
            const removed = self.active_view.deleteLayer(self.active_view.layers.items.len - 1).?;
            gpa.free(removed.pixels);
        }
        self.active_view.selected_layer = 0;
        self.active_view.layers.items[0].visible = true;
        self.active_view.layers.items[0].opacity = 255;
        self.active_view.layers.items[0].setName("Layer 1");
        self.active_view.layers.items[0].kind = .raster;
        self.active_view.layers.items[0].text_params = .{};
        self.active_view.next_layer_num = 2;
        @memset(self.active_view.layerPixels(0), 0);
        self.active_view.clearSelection();

        for (self.cel_pool.items) |maybe_cel| if (maybe_cel) |cel| gpa.free(cel.pixels);
        self.cel_pool.clearRetainingCapacity();
        self.next_cel_id = 0;
        self.grid.clearRetainingCapacity();
        self.frames.clearRetainingCapacity();
        self.frames.append(gpa, .{}) catch @panic("Document.resetToSingleBlankLayer: OOM");
        self.layers.clearRetainingCapacity();
        // Keep LayerId allocation (like undo handles; no reuse)
        var def: LayerDef = .{ .id = self.allocLayerId() };
        def.setName("Layer 1");
        self.layers.append(gpa, def) catch @panic("Document.resetToSingleBlankLayer: OOM");
        self.grid.append(gpa, null) catch @panic("Document.resetToSingleBlankLayer: OOM");
        self.selected_layer = 0;
        self.selected_frame = 0;
        self.undo.clearHistoryPreservingHandles(gpa);
    }

    // ══════════════════════════════════════════════════════════════════
    // undo/redo apply
    // ══════════════════════════════════════════════════════════════════

    pub fn undoOne(self: *Document, gpa: Allocator) void {
        var op = self.undo.undo.pop() orelse return;
        _ = self.undo.handles.pop(); // Sync handle/owner parallel arrays (redo side is not tagged)
        _ = self.undo.owners.pop();
        self.applyBefore(gpa, &op);
        self.undo.redo.append(gpa, op) catch @panic("Document.undoOne: OOM");
        self.resyncActiveView(gpa);
    }

    pub fn redoOne(self: *Document, gpa: Allocator) void {
        var op = self.undo.redo.pop() orelse return;
        self.applyAfter(gpa, &op);
        self.undo.undo.append(gpa, op) catch @panic("Document.redoOne: OOM");
        // Re-push **allocates a new handle** (link to the old CommandRecord does not revive; see UndoStack docs).
        self.undo.handles.append(gpa, self.undo.allocHandle()) catch @panic("Document.redoOne: OOM");
        self.undo.owners.append(gpa, 0) catch @panic("Document.redoOne: OOM"); // Re-push is unknown (app re-confirms)
        self.resyncActiveView(gpa);
    }

    // ══════════════════════════════════════════════════════════════════
    // Arbitrary-position revert (per-actor undo)
    // ══════════════════════════════════════════════════════════════════

    /// Whether the Op for a handle can be inverse-applied from an **arbitrary position** on the undo stack.
    /// True when all of:
    ///   1. handle is present on the undo stack
    ///   2. Op kind is `.paint`
    ///   3. target cel is alive (`cel_pool[op.cel_id] != null`)
    ///   4. position premise holds: `op.layer_idx`/`op.frame_idx` are in range for the current document and
    ///      `grid(layer_idx, frame_idx) == op.cel_id` (uniform whether or not created; prevents inverse-apply
    ///      of ops whose position mapping broke via later layer/frame ops or cel link/unlink — wrong grid-slot
    ///      clear / panic). Broken-premise ops are non-candidates = per-actor undo canUndo=false → framework
    ///      pre-validates the whole set and skips the transaction)
    ///
    /// **Structural Op constraint (MVP cut, noted ②)**: structural Ops — layer_add/delete/reorder/visible/opacity/rename/
    /// text/rasterize/merge, frame ops, cel-link ops — are **out of scope for arbitrary-position inverse-apply**
    /// (inverse-applying an old index after later structural changes would hit the wrong target / break cel ownership).
    /// Arbitrary-position undo for all Op kinds is out of scope until rollback-replay. Agent structural
    /// actions (add_layer, etc.) are recorded in CommandRecord but are not per-actor undo candidates
    /// (skipped with canUndo=false. Topmost unrecorded structural Ops can only be undone via classic `undoOne`).
    pub fn canRevertByHandle(self: *const Document, handle: u64) bool {
        const idx = self.indexOfHandle(handle) orelse return false;
        const op = &self.undo.undo.items[idx];
        if (op.* != .paint) return false;
        const p = op.paint;
        if (p.cel_id >= self.cel_pool.items.len) return false;
        if (self.cel_pool.items[p.cel_id] == null) return false;
        if (p.layer_idx >= self.layers.items.len) return false;
        if (p.frame_idx >= self.frames.items.len) return false;
        const current = self.gridGet(p.layer_idx, p.frame_idx) orelse return false;
        return current == p.cel_id;
    }

    fn indexOfHandle(self: *const Document, handle: u64) ?usize {
        for (self.undo.handles.items, 0..) |h, i| {
            if (h == handle) return i;
        }
        return null;
    }

    /// Read-only: `PixelDiff` column view of the `.paint` Op for a handle.
    /// Returns a borrowed slice only; ownership does not move. Caller must not retain the return value —
    /// copy into a thumbnail inside the confirm hook. Missing handle / structural Op / already undone → null.
    pub const PaintDiffView = struct {
        layer_idx: usize,
        frame_idx: u32,
        diffs: []const PixelDiff,
    };

    pub fn paintDiffsForHandle(self: *const Document, handle: u64) ?PaintDiffView {
        const idx = self.indexOfHandle(handle) orelse return null;
        const op = &self.undo.undo.items[idx];
        if (op.* != .paint) return null;
        const p = op.paint;
        return .{
            .layer_idx = p.layer_idx,
            .frame_idx = p.frame_idx,
            .diffs = p.diffs,
        };
    }

    pub const RevertMode = enum {
        /// Move an inverse-applied Op onto the legacy redo stack (legacy redo for unrecorded ops).
        move_to_redo,
        /// Free an inverse-applied Op (for ops already recorded in CommandRecord; redo re-dispatches
        /// CommandLog name/args, so the Op is not needed).
        discard,
    };

    /// Inverse-apply and remove the `.paint` Op for a handle from an **arbitrary position** on the undo stack.
    /// Returns true on success. If the target fails `canRevertByHandle`, **return false and do nothing**
    /// (non-paint Op, missing handle, or broken cel/position premise — all the same). Internally runs through
    /// `resyncActiveView` (App-side sync such as `clampTimelineTarget` is the caller's job).
    ///
    /// **Pixel collateral artifact (MVP cut, noted ①)**: Ops are snapshot-inverse (pixel diff), so content
    /// painted on the same pixels **after** the target Op is collateral-reverted too (the diff's before
    /// value is the pixel right after the target Op ran). Same MVP cut as netsync
    /// for solo Co-pilot.
    /// Resolution is rollback-replay; practical mitigation is per-actor layer ownership.
    /// **Conditional teardown of a created cel (differs from applyBefore)**: LIFO `applyBefore` always frees
    /// the cel and nulls the grid when created=true, but on **arbitrary-position** revert that would (a) erase
    /// later ops' paint on the same cel and (b) leave later ops pointing at a freed cel → panic on later undo.
    /// So teardown runs only when no other ops still reference the cel; if references remain, keep the
    /// before-restored cel alive and clear the op's created flag (thereafter treated as "paint onto an
    /// existing cel", consistent with redo-side `applyAfter`).
    /// A blank-equivalent cel left on skip is display-identical to transparent and harmless (memory/save size only).
    pub fn revertByHandle(self: *Document, gpa: Allocator, handle: u64, mode: RevertMode) bool {
        if (!self.canRevertByHandle(handle)) return false;
        const idx = self.indexOfHandle(handle).?; // canRevertByHandle guarantees present
        var op = self.undo.undo.orderedRemove(idx);
        _ = self.undo.handles.orderedRemove(idx);
        _ = self.undo.owners.orderedRemove(idx);

        const p = &op.paint; // canRevertByHandle guarantees .paint
        {
            const pixels = self.cel_pool.items[p.cel_id].?.pixels;
            for (p.diffs) |d| pixels[d.idx] = d.before;
        }
        if (p.created) {
            if (self.celReferencedByOps(p.cel_id)) {
                p.created = false; // teardown skip (see doc comment)
            } else {
                if (self.releaseCelMaybeCapture(p.cel_id)) |captured| p.created_released = captured;
                self.setGrid(p.layer_idx, p.frame_idx, null);
            }
        }
        switch (mode) {
            .move_to_redo => self.undo.redo.append(gpa, op) catch @panic("Document.revertByHandle: OOM"),
            .discard => freeOp(gpa, &op),
        }
        self.resyncActiveView(gpa);
        return true;
    }

    /// Whether an op on the undo/redo stack can hold a "live cel ref" to `cel_id`
    /// (for `revertByHandle` created-teardown decisions). Structural ops that hold a cel snapshot/link are
    /// **conservatively true** (skipping teardown and leaving a blank cel is always safer; the only cost of a
    /// false skip is a lingering blank cel).
    fn opMayReferenceCel(op: *const Op, cel_id: CelId) bool {
        return switch (op.*) {
            .paint => |p2| p2.cel_id == cel_id,
            .layer_visible, .layer_opacity, .layer_rename, .layer_reorder, .layer_text_params, .layer_rasterize => false,
            else => true,
        };
    }

    fn celReferencedByOps(self: *const Document, cel_id: CelId) bool {
        for (self.undo.undo.items) |*op| {
            if (opMayReferenceCel(op, cel_id)) return true;
        }
        for (self.undo.redo.items) |*op| {
            if (opMayReferenceCel(op, cel_id)) return true;
        }
        return false;
    }

    fn applyBefore(self: *Document, gpa: Allocator, op_ptr: *Op) void {
        switch (op_ptr.*) {
            .paint => |*op| {
                {
                    const pixels = self.cel_pool.items[op.cel_id].?.pixels;
                    for (op.diffs) |d| pixels[d.idx] = d.before;
                }
                if (op.created) {
                    if (self.releaseCelMaybeCapture(op.cel_id)) |captured| op.created_released = captured;
                    self.setGrid(op.layer_idx, op.frame_idx, null);
                }
            },
            .layer_visible => |op| self.layers.items[op.index].visible = op.before,
            .layer_opacity => |op| self.layers.items[op.index].opacity = op.before,
            .layer_rename => |op| self.layers.items[op.index].setName(op.before.slice()),
            .layer_reorder => |op| {
                self.moveLayerRaw(gpa, op.to, op.from);
                self.selected_layer = op.selected_before;
            },
            .layer_text_params => |op| self.rasterizeSharedTextCel(gpa, op.index, op.before) catch @panic("Document.applyBefore(.layer_text_params): rasterize failed"),
            .layer_rasterize => |op| {
                self.layers.items[op.index].kind = .text;
                self.layers.items[op.index].text_params = op.before;
                self.normalizeTextLayerLinks(gpa, op.index);
            },
            .layer_add => |*op| {
                const def = self.layers.orderedRemove(op.index);
                const snapshot = self.removeLayerRow(gpa, op.index);
                op.def = def;
                op.row = snapshot;
                self.selected_layer = op.selected_before;
            },
            .layer_delete => |*op| {
                const def = op.def orelse @panic("Document.applyBefore(.layer_delete): missing held def");
                const snapshot = op.row orelse @panic("Document.applyBefore(.layer_delete): missing held row");
                self.layers.insert(gpa, op.index, def) catch @panic("Document.applyBefore(.layer_delete): OOM");
                self.insertLayerRowFromSnapshot(gpa, op.index, snapshot);
                op.def = null;
                op.row = null;
                self.selected_layer = op.selected_before;
            },
            .frame_add => |*op| {
                const removed_values = self.removeFrameColumnValues(gpa, op.index);
                const snapshot = self.captureAndReleaseSlots(gpa, removed_values);
                _ = self.frames.orderedRemove(op.index);
                op.col = snapshot;
                self.selected_frame = op.selected_before;
            },
            .frame_delete => |*op| {
                const snapshot = op.col orelse @panic("Document.applyBefore(.frame_delete): missing held col");
                self.insertFrameColumnValues(gpa, op.index, snapshot.slots);
                self.restoreCelPoolRefs(gpa, snapshot);
                freeCelSetSnapshotContainer(gpa, snapshot);
                self.frames.insert(gpa, op.index, .{ .duration_ms = op.duration_ms }) catch @panic("Document.applyBefore(.frame_delete): OOM");
                op.col = null;
                self.selected_frame = op.selected_before;
            },
            .frame_duplicate => |*op| {
                const removed_values = self.removeFrameColumnValues(gpa, op.new_index);
                const snapshot = self.captureAndReleaseSlots(gpa, removed_values);
                _ = self.frames.orderedRemove(op.new_index);
                op.col = snapshot;
                self.selected_frame = op.selected_before;
            },
            .layer_merge_down => |*op| {
                std.debug.assert(self.frames.items.len == 1);
                const below_idx = op.index - 1;
                @memcpy(self.cel_pool.items[self.gridGet(below_idx, 0).?].?.pixels, op.below_before);
                const def = op.def orelse @panic("Document.applyBefore(.layer_merge_down): missing held def");
                self.layers.insert(gpa, op.index, def) catch @panic("Document.applyBefore(.layer_merge_down): OOM");
                const id: ?CelId = if (op.cel) |c| c.id else null;
                self.grid.insertSlice(gpa, op.index, &[_]?CelId{id}) catch @panic("Document.applyBefore(.layer_merge_down): OOM");
                if (op.cel) |c| self.cel_pool.items[c.id] = .{ .pixels = c.pixels, .refcount = 1 };
                op.def = null;
                op.cel = null;
                self.selected_layer = op.selected_before;
            },
            .cel_link => |*op| {
                std.debug.assert(self.gridGet(op.layer_idx, op.frame_idx) == op.after);
                if (self.releaseCelMaybeCapture(op.after)) |_| @panic("Document.applyBefore(.cel_link): 'after' unexpectedly released");
                if (op.before_released) |pixels| {
                    self.cel_pool.items[op.before.?] = .{ .pixels = pixels, .refcount = 1 };
                    op.before_released = null;
                } else if (op.before) |bid| {
                    self.retainCel(bid);
                }
                self.setGrid(op.layer_idx, op.frame_idx, op.before);
            },
            .cel_unlink => |*op| {
                std.debug.assert(self.gridGet(op.layer_idx, op.frame_idx) == op.after);
                const pixels = self.releaseCelMaybeCapture(op.after) orelse @panic("Document.applyBefore(.cel_unlink): 'after' did not fully release");
                op.after_released = pixels;
                self.retainCel(op.before);
                self.setGrid(op.layer_idx, op.frame_idx, op.before);
            },
        }
    }

    fn applyAfter(self: *Document, gpa: Allocator, op_ptr: *Op) void {
        switch (op_ptr.*) {
            .paint => |*op| {
                if (op.created) {
                    if (op.created_released) |captured| {
                        self.cel_pool.items[op.cel_id] = .{ .pixels = captured, .refcount = 1 };
                        op.created_released = null;
                    } else {
                        std.debug.assert(false); // Defensive branch not reached in current scope
                        self.retainCel(op.cel_id);
                    }
                    self.setGrid(op.layer_idx, op.frame_idx, op.cel_id);
                }
                const pixels = self.cel_pool.items[op.cel_id].?.pixels;
                for (op.diffs) |d| pixels[d.idx] = d.after;
            },
            .layer_visible => |op| self.layers.items[op.index].visible = op.after,
            .layer_opacity => |op| self.layers.items[op.index].opacity = op.after,
            .layer_rename => |op| self.layers.items[op.index].setName(op.after.slice()),
            .layer_reorder => |op| {
                self.moveLayerRaw(gpa, op.from, op.to);
                self.selected_layer = op.selected_after;
            },
            .layer_text_params => |op| self.rasterizeSharedTextCel(gpa, op.index, op.after) catch @panic("Document.applyAfter(.layer_text_params): rasterize failed"),
            .layer_rasterize => |op| {
                self.layers.items[op.index].kind = .raster;
                self.layers.items[op.index].text_params = .{};
            },
            .layer_add => |*op| {
                const def = op.def orelse @panic("Document.applyAfter(.layer_add): missing held def");
                const snapshot = op.row orelse @panic("Document.applyAfter(.layer_add): missing held row");
                self.layers.insert(gpa, op.index, def) catch @panic("Document.applyAfter(.layer_add): OOM");
                self.insertLayerRowFromSnapshot(gpa, op.index, snapshot);
                op.def = null;
                op.row = null;
                self.selected_layer = op.selected_after;
            },
            .layer_delete => |*op| {
                const def = self.layers.orderedRemove(op.index);
                const snapshot = self.removeLayerRow(gpa, op.index);
                op.def = def;
                op.row = snapshot;
                self.selected_layer = op.selected_after;
            },
            .frame_add => |*op| {
                const snapshot = op.col orelse @panic("Document.applyAfter(.frame_add): missing held col");
                self.insertFrameColumnValues(gpa, op.index, snapshot.slots);
                self.restoreCelPoolRefs(gpa, snapshot);
                freeCelSetSnapshotContainer(gpa, snapshot);
                self.frames.insert(gpa, op.index, .{ .duration_ms = op.duration_ms }) catch @panic("Document.applyAfter(.frame_add): OOM");
                op.col = null;
                self.selected_frame = op.selected_after;
            },
            .frame_delete => |*op| {
                const removed_values = self.removeFrameColumnValues(gpa, op.index);
                const snapshot = self.captureAndReleaseSlots(gpa, removed_values);
                _ = self.frames.orderedRemove(op.index);
                op.col = snapshot;
                self.selected_frame = op.selected_after;
            },
            .frame_duplicate => |*op| {
                const snapshot = op.col orelse @panic("Document.applyAfter(.frame_duplicate): missing held col");
                self.insertFrameColumnValues(gpa, op.new_index, snapshot.slots);
                self.restoreCelPoolRefs(gpa, snapshot);
                freeCelSetSnapshotContainer(gpa, snapshot);
                self.frames.insert(gpa, op.new_index, .{ .duration_ms = op.duration_ms }) catch @panic("Document.applyAfter(.frame_duplicate): OOM");
                op.col = null;
                self.selected_frame = op.selected_after;
            },
            .layer_merge_down => |*op| {
                std.debug.assert(self.frames.items.len == 1);
                const below_idx = op.index - 1;
                @memcpy(self.cel_pool.items[self.gridGet(below_idx, 0).?].?.pixels, op.below_after);
                var cel_snapshot: ?CelSnapshotItem = null;
                if (self.gridGet(op.index, 0)) |rid| {
                    const pixels = self.releaseCelMaybeCapture(rid) orelse @panic("Document.applyAfter(.layer_merge_down): expected full release");
                    cel_snapshot = .{ .id = rid, .pixels = pixels };
                }
                op.def = self.layers.orderedRemove(op.index);
                self.grid.replaceRange(gpa, op.index, 1, &.{}) catch @panic("Document.applyAfter(.layer_merge_down): OOM");
                op.cel = cel_snapshot;
                self.selected_layer = op.selected_after;
            },
            .cel_link => |*op| {
                std.debug.assert(self.gridGet(op.layer_idx, op.frame_idx) == op.before);
                if (op.before) |bid| {
                    if (self.releaseCelMaybeCapture(bid)) |pixels| op.before_released = pixels;
                }
                self.retainCel(op.after);
                self.setGrid(op.layer_idx, op.frame_idx, op.after);
            },
            .cel_unlink => |*op| {
                std.debug.assert(self.gridGet(op.layer_idx, op.frame_idx) == op.before);
                const pixels = op.after_released orelse @panic("Document.applyAfter(.cel_unlink): missing captured pixels");
                self.cel_pool.items[op.after] = .{ .pixels = pixels, .refcount = 1 };
                op.after_released = null;
                if (self.releaseCelMaybeCapture(op.before)) |_| @panic("Document.applyAfter(.cel_unlink): 'before' unexpectedly released");
                self.setGrid(op.layer_idx, op.frame_idx, op.after);
            },
        }
    }
};

// ============================================================================
// tests (UndoStack handle tags)
// ============================================================================

const testing = std.testing;

fn testVisOp(index: usize) Op {
    return .{ .layer_visible = .{ .index = index, .before = true, .after = false } };
}

test "UndoStack handles: monotonic allocation / push→topHandle / length-sync invariant" {
    const gpa = testing.allocator;
    var s: UndoStack = .{};
    defer s.deinit(gpa);

    try testing.expectEqual(@as(?u64, null), s.topHandle());

    s.push(gpa, testVisOp(0));
    try testing.expectEqual(@as(?u64, 1), s.topHandle());
    s.push(gpa, testVisOp(1));
    try testing.expectEqual(@as(?u64, 2), s.topHandle()); // Monotonic increase
    try testing.expectEqual(s.undo.items.len, s.handles.items.len);
    try testing.expect(s.hasHandle(1));
    try testing.expect(s.hasHandle(2));
    try testing.expect(!s.hasHandle(3));
}

test "UndoStack handles: max_history overflow also drops the oldest handle in sync" {
    const gpa = testing.allocator;
    var s: UndoStack = .{};
    defer s.deinit(gpa);

    var i: usize = 0;
    while (i < UndoStack.max_history + 2) : (i += 1) {
        s.push(gpa, testVisOp(i));
    }
    try testing.expectEqual(UndoStack.max_history, s.undo.items.len);
    try testing.expectEqual(s.undo.items.len, s.handles.items.len);
    try testing.expect(!s.hasHandle(1)); // Oldest 2 spilled and are gone
    try testing.expect(!s.hasHandle(2));
    try testing.expect(s.hasHandle(3)); // First of the survivors
    try testing.expectEqual(@as(?u64, UndoStack.max_history + 2), s.topHandle());
}

test "UndoStack handles: Document.undoOne pop / redoOne re-push issues a new handle" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();

    doc.undo.push(gpa, testVisOp(0));
    doc.undo.push(gpa, testVisOp(0));
    try testing.expectEqual(@as(?u64, 2), doc.undo.topHandle());

    doc.undoOne(gpa); // Op with handle=2 popped (redo side is not tagged)
    try testing.expectEqual(@as(?u64, 1), doc.undo.topHandle());
    try testing.expectEqual(doc.undo.undo.items.len, doc.undo.handles.items.len);
    try testing.expect(!doc.undo.hasHandle(2));

    doc.redoOne(gpa); // Re-push gets a **new handle** (=3; 2 does not revive)
    try testing.expectEqual(@as(?u64, 3), doc.undo.topHandle());
    try testing.expectEqual(doc.undo.undo.items.len, doc.undo.handles.items.len);
    try testing.expect(!doc.undo.hasHandle(2));
}

test "UndoStack handles: next_handle stays monotonic after reset (clearHistoryPreservingHandles / no reuse)" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();

    doc.undo.push(gpa, testVisOp(0));
    doc.undo.push(gpa, testVisOp(0));
    const before_reset = doc.undo.next_handle; // = 3
    try testing.expectEqual(@as(u64, 3), before_reset);

    // Reset equivalent to document load (used by resetToSingleBlankLayer via doOpenPath)
    doc.resetToSingleBlankLayer(gpa);
    try testing.expectEqual(@as(usize, 0), doc.undo.undo.items.len); // History cleared
    try testing.expectEqual(@as(usize, 0), doc.undo.handles.items.len);
    try testing.expectEqual(before_reset, doc.undo.next_handle); // Allocation preserved

    // Post-reset push gets a handle larger than pre-reset (no reuse)
    doc.undo.push(gpa, testVisOp(0));
    try testing.expectEqual(@as(?u64, 3), doc.undo.topHandle());
    try testing.expect(doc.undo.topHandle().? >= before_reset);

    // Same for UndoStack alone (clearHistoryPreservingHandles directly)
    var s: UndoStack = .{};
    defer s.deinit(gpa);
    s.push(gpa, testVisOp(0));
    s.push(gpa, testVisOp(0));
    const nh = s.next_handle;
    s.clearHistoryPreservingHandles(gpa);
    try testing.expectEqual(nh, s.next_handle);
    s.push(gpa, testVisOp(0));
    try testing.expect(s.topHandle().? >= nh);
}

// ── Arbitrary-position revert tests ──────────────────────────

fn pushTestPaint(doc: *Document, gpa: Allocator, layer_idx: usize, pixel_idx: u32, color: u32) !void {
    const pixels = doc.active_view.layerPixels(layer_idx);
    const diffs = try gpa.alloc(PixelDiff, 1);
    diffs[0] = .{ .idx = pixel_idx, .before = pixels[pixel_idx], .after = color };
    pixels[pixel_idx] = color;
    try doc.pushPaintOp(gpa, layer_idx, diffs);
}

test "paintDiffsForHandle: borrow diffs/layer_idx from a paint handle (ownership unchanged)" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();

    try pushTestPaint(&doc, gpa, 0, 0, 0xFFFF0000); // handle 1
    const h = doc.undo.topHandle().?;
    const view = doc.paintDiffsForHandle(h) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 0), view.layer_idx);
    try testing.expectEqual(@as(u32, 0), view.frame_idx);
    try testing.expectEqual(@as(usize, 1), view.diffs.len);
    try testing.expectEqual(@as(u32, 0), view.diffs[0].idx);
    try testing.expectEqual(@as(u32, 0xFFFF0000), view.diffs[0].after);
    // Ownership invariant: after accessor, Op stays on undo and can be fetched again
    try testing.expectEqual(@as(usize, 1), doc.undo.undo.items.len);
    try testing.expect(doc.paintDiffsForHandle(h) != null);
    try testing.expectEqual(@as(usize, 1), doc.paintDiffsForHandle(h).?.diffs.len);
}

test "paintDiffsForHandle: structural Op / missing handle → null" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();

    _ = try doc.addLayer(gpa); // handle 1 (structural op)
    try testing.expect(doc.paintDiffsForHandle(1) == null);
    try testing.expect(doc.paintDiffsForHandle(999) == null);

    try pushTestPaint(&doc, gpa, 0, 0, 0xFF00FF00); // handle 2
    try testing.expect(doc.paintDiffsForHandle(2) != null);
    try testing.expect(doc.revertByHandle(gpa, 2, .discard));
    try testing.expect(doc.paintDiffsForHandle(2) == null); // Already undone
}

test "revertByHandle: inverse-apply a non-top .paint op at any position (ops above remain; only target reverts)" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();

    try pushTestPaint(&doc, gpa, 0, 0, 0xFFFF0000); // A: px0 (handle 1)
    try pushTestPaint(&doc, gpa, 0, 1, 0xFF00FF00); // B: px1 (handle 2)
    try testing.expect(doc.canRevertByHandle(1));

    try testing.expect(doc.revertByHandle(gpa, 1, .discard)); // Arbitrary-position revert of A only (discard = free the op)
    const px = doc.active_view.layerPixels(0);
    try testing.expectEqual(@as(u32, 0), px[0]); // A restored
    try testing.expectEqual(@as(u32, 0xFF00FF00), px[1]); // B remains
    try testing.expectEqual(@as(usize, 1), doc.undo.undo.items.len);
    try testing.expectEqual(@as(?u64, 2), doc.undo.topHandle());
    try testing.expect(!doc.canRevertByHandle(1)); // Removed handle is missing
}

test "revertByHandle: structural op → false (not eligible for any-position inverse) / missing handle also false" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();

    _ = try doc.addLayer(gpa); // Structural op (layer_add; handle 1)
    try testing.expect(!doc.canRevertByHandle(1));
    try testing.expect(!doc.revertByHandle(gpa, 1, .discard)); // false + do nothing
    try testing.expectEqual(@as(usize, 1), doc.undo.undo.items.len); // op remains
    try testing.expectEqual(@as(usize, 2), doc.layers.items.len); // layer remains

    try testing.expect(!doc.canRevertByHandle(999)); // Nonexistent handle
    try testing.expect(!doc.revertByHandle(gpa, 999, .discard));
}

test "revertByHandle: paint op whose cel was freed by layer delete → false (last defence)" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();

    _ = try doc.addLayer(gpa); // handle 1 (structural op)
    try pushTestPaint(&doc, gpa, 1, 0, 0xFFFF0000); // handle 2 (paint on layer1)
    try testing.expect(doc.canRevertByHandle(2));

    try doc.deleteLayer(gpa, 1); // handle 3 (structural op). layer1's cel is freed
    try testing.expect(!doc.canRevertByHandle(2)); // cel freed + layer out of range → non-candidate
    try testing.expect(!doc.revertByHandle(gpa, 2, .discard));
}

test "revertByHandle: paint op whose position mapping broke after layer reorder → false (do not clear wrong slot)" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();

    _ = try doc.addLayer(gpa); // 2 layers (handle 1)
    try pushTestPaint(&doc, gpa, 0, 0, 0xFFFF0000); // handle 2: layer0's cel (grid(0,0))
    try pushTestPaint(&doc, gpa, 1, 1, 0xFF00FF00); // handle 3: layer1's cel (grid(1,0))
    try testing.expect(doc.canRevertByHandle(2));
    try testing.expect(doc.canRevertByHandle(3));

    try doc.reorderLayer(gpa, 0, 1); // grid rows swap → both ops' layer_idx point at old positions
    try testing.expect(!doc.canRevertByHandle(2)); // grid(0,0) != op.cel_id → non-candidate
    try testing.expect(!doc.canRevertByHandle(3));
    try testing.expect(!doc.revertByHandle(gpa, 2, .discard));
}

test "revertByHandle: move_to_redo lets legacy redoOne re-apply (new handle issued)" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();

    try pushTestPaint(&doc, gpa, 0, 0, 0xFFFF0000); // A (handle 1)
    try pushTestPaint(&doc, gpa, 0, 1, 0xFF00FF00); // B (handle 2)

    try testing.expect(doc.revertByHandle(gpa, 1, .move_to_redo)); // A onto legacy redo
    try testing.expectEqual(@as(u32, 0), doc.active_view.layerPixels(0)[0]);
    try testing.expectEqual(@as(usize, 1), doc.undo.redo.items.len);

    doc.redoOne(gpa); // legacy redo → re-apply A + new handle (3) onto undo stack
    try testing.expectEqual(@as(u32, 0xFFFF0000), doc.active_view.layerPixels(0)[0]);
    try testing.expectEqual(@as(usize, 2), doc.undo.undo.items.len);
    try testing.expectEqual(@as(?u64, 3), doc.undo.topHandle());
}

test "revertByHandle: lone created op → teardown (free cel + grid null) / skip if references remain" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();

    // Lone created op → teardown (same end state as legacy undoOne)
    try pushTestPaint(&doc, gpa, 0, 0, 0xFFFF0000); // handle 1 (created=true)
    const cel_id = doc.gridGet(0, 0).?;
    try testing.expect(doc.revertByHandle(gpa, 1, .discard));
    try testing.expectEqual(@as(?CelId, null), doc.gridGet(0, 0)); // grid null
    try testing.expect(doc.cel_pool.items[cel_id] == null); // cel freed

    // When a later paint still references the same cel, skip (the "not topmost…" test covers this;
    // here we assert the grid survives)
    try pushTestPaint(&doc, gpa, 0, 0, 0xFFFF0000); // handle 2 (created=true; new cel)
    try pushTestPaint(&doc, gpa, 0, 1, 0xFF00FF00); // handle 3 (same cel)
    const cel2 = doc.gridGet(0, 0).?;
    try testing.expect(doc.revertByHandle(gpa, 2, .discard));
    try testing.expectEqual(@as(?CelId, cel2), doc.gridGet(0, 0)); // cel stays alive
    try testing.expectEqual(@as(u32, 0xFF00FF00), doc.active_view.layerPixels(0)[1]); // Later op's paint is intact
}

test "UndoStack owners: push=unknown / setOwner/ownerOf / sync on overflow, undo/redo, and revert paths" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();

    try pushTestPaint(&doc, gpa, 0, 0, 0xFFFF0000); // handle 1
    try pushTestPaint(&doc, gpa, 0, 1, 0xFF00FF00); // handle 2
    try testing.expectEqual(@as(u8, 0), doc.undo.ownerOf(1)); // Right after push: unknown
    doc.undo.setOwner(1, 1);
    doc.undo.setOwner(2, 2);
    try testing.expectEqual(@as(u8, 1), doc.undo.ownerOf(1));
    try testing.expectEqual(@as(u8, 2), doc.undo.ownerOf(2));
    try testing.expectEqual(@as(u8, 0), doc.undo.ownerOf(999)); // Missing → unknown
    doc.undo.setOwner(999, 1); // Missing handle is no-op (does not crash)

    // undoOne pop also syncs owners
    doc.undoOne(gpa);
    try testing.expectEqual(doc.undo.undo.items.len, doc.undo.owners.items.len);
    try testing.expectEqual(@as(u8, 0), doc.undo.ownerOf(2)); // handle 2 treated as missing

    // Re-push (legacy redo) stacks as unknown (app re-confirms by convention)
    doc.redoOne(gpa); // New handle 3
    try testing.expectEqual(@as(u8, 0), doc.undo.ownerOf(3));
    try testing.expectEqual(doc.undo.undo.items.len, doc.undo.owners.items.len);

    // Also synced by revertByHandle (arbitrary-position remove)
    doc.undo.setOwner(1, 1);
    try testing.expect(doc.revertByHandle(gpa, 1, .discard));
    try testing.expectEqual(doc.undo.undo.items.len, doc.undo.owners.items.len);
    try testing.expectEqual(@as(u8, 0), doc.undo.ownerOf(1));
}

test "UndoStack owners: max_history overflow also drops the oldest owner in sync" {
    const gpa = testing.allocator;
    var s: UndoStack = .{};
    defer s.deinit(gpa);

    var i: usize = 0;
    while (i < UndoStack.max_history + 1) : (i += 1) {
        s.push(gpa, testVisOp(i));
    }
    try testing.expectEqual(s.undo.items.len, s.owners.items.len);
    try testing.expectEqual(s.undo.items.len, s.handles.items.len);
    try testing.expectEqual(@as(u8, 0), s.ownerOf(1)); // Spilled handle is missing
}

// ── LayerId stable handle ──────────────────────────────

test "LayerId: id stable across add→move→delete→insert with no reuse" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();

    const id0 = doc.layerIdAt(0).?;
    try testing.expect(id0 != .invalid);
    try testing.expectEqual(@as(?usize, 0), doc.layerIndexOf(id0));

    const idx1 = try doc.addLayer(gpa);
    const id1 = doc.layerIdAt(idx1).?;
    const idx2 = try doc.addLayer(gpa);
    const id2 = doc.layerIdAt(idx2).?;
    try testing.expect(id0 != id1 and id1 != id2 and id0 != id2);
    try testing.expectEqual(@as(u64, 4), doc.next_layer_id); // 1,2,3 used → next=4

    // move: after reorderLayer(0, 2), id still points at the same layer
    try doc.reorderLayer(gpa, 0, 2); // [id1, id2, id0]
    try testing.expectEqual(id1, doc.layerIdAt(0).?);
    try testing.expectEqual(id2, doc.layerIdAt(1).?);
    try testing.expectEqual(id0, doc.layerIdAt(2).?);
    try testing.expectEqual(@as(?usize, 2), doc.layerIndexOf(id0));
    try testing.expectEqual(@as(?usize, 0), doc.layerIndexOf(id1));
    try testing.expectEqual(@as(?usize, 1), doc.layerIndexOf(id2));

    // delete id1: resolve is null; next_layer_id does not rewind
    try doc.deleteLayerById(gpa, id1);
    try testing.expectEqual(@as(?usize, null), doc.layerIndexOf(id1));
    try testing.expectEqual(@as(u64, 4), doc.next_layer_id);
    try testing.expectEqual(@as(?usize, 0), doc.layerIndexOf(id2));
    try testing.expectEqual(@as(?usize, 1), doc.layerIndexOf(id0));

    // insert (add): new id does not reuse deleted id1
    const idx_new = try doc.addLayer(gpa);
    const id_new = doc.layerIdAt(idx_new).?;
    try testing.expect(id_new != id1);
    try testing.expectEqual(@as(LayerId, @enumFromInt(4)), id_new);
    try testing.expectEqual(@as(u64, 5), doc.next_layer_id);

    // invalid / out of range
    try testing.expectEqual(@as(?LayerId, null), doc.layerIdAt(99));
    try testing.expectEqual(@as(?usize, null), doc.layerIndexOf(.invalid));
}

test "LayerId ById wrapper: same results as index APIs / deleted id → UnknownLayerId" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();
    _ = try doc.addLayer(gpa);
    _ = try doc.addLayer(gpa);
    const id0 = doc.layerIdAt(0).?;
    const id1 = doc.layerIdAt(1).?;
    const id2 = doc.layerIdAt(2).?;

    // select
    try doc.selectLayerById(id1);
    try testing.expectEqual(@as(usize, 1), doc.selected_layer);
    try doc.selectLayer(0);
    try testing.expectEqual(@as(usize, 0), doc.selected_layer);
    try doc.selectLayerById(id0);
    try testing.expectEqual(@as(usize, 0), doc.selected_layer);

    // visible / opacity
    try doc.setLayerVisibleById(gpa, id2, false);
    try testing.expectEqual(false, doc.layers.items[2].visible);
    try doc.setLayerOpacityById(gpa, id2, 100);
    try testing.expectEqual(@as(u8, 100), doc.layers.items[2].opacity);
    // Equivalent to index APIs (already false/100 so no-op-ish; re-set to confirm state match)
    try doc.setLayerVisible(gpa, 2, true);
    try doc.setLayerVisibleById(gpa, id2, false);
    try testing.expectEqual(false, doc.layers.items[doc.layerIndexOf(id2).?].visible);
    try doc.setLayerOpacity(gpa, 2, 200);
    try doc.setLayerOpacityById(gpa, id2, 50);
    try testing.expectEqual(@as(u8, 50), doc.layers.items[doc.layerIndexOf(id2).?].opacity);

    // move: id0 to to=2
    try doc.moveLayerById(gpa, id0, 2);
    try testing.expectEqual(id1, doc.layerIdAt(0).?);
    try testing.expectEqual(id2, doc.layerIdAt(1).?);
    try testing.expectEqual(id0, doc.layerIdAt(2).?);

    // delete
    try doc.deleteLayerById(gpa, id2);
    try testing.expectEqual(@as(?usize, null), doc.layerIndexOf(id2));
    try testing.expectEqual(@as(usize, 2), doc.layers.items.len);

    // Deleted id → UnknownLayerId
    try testing.expectError(error.UnknownLayerId, doc.selectLayerById(id2));
    try testing.expectError(error.UnknownLayerId, doc.setLayerVisibleById(gpa, id2, true));
    try testing.expectError(error.UnknownLayerId, doc.setLayerOpacityById(gpa, id2, 1));
    try testing.expectError(error.UnknownLayerId, doc.moveLayerById(gpa, id2, 0));
    try testing.expectError(error.UnknownLayerId, doc.deleteLayerById(gpa, id2));
    try testing.expectError(error.UnknownLayerId, doc.selectLayerById(.invalid));
}

test "LayerId: duplicateLayer gets a new id / next_layer_id stays monotonic after reset" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();
    const id0 = doc.layerIdAt(0).?;
    const dup_idx = try doc.duplicateLayer(gpa, 0);
    const id_dup = doc.layerIdAt(dup_idx).?;
    try testing.expect(id_dup != id0);
    try testing.expectEqual(@as(?usize, 0), doc.layerIndexOf(id0));
    try testing.expectEqual(@as(?usize, 1), doc.layerIndexOf(id_dup));

    const before_reset = doc.next_layer_id;
    doc.resetToSingleBlankLayer(gpa);
    try testing.expectEqual(@as(usize, 1), doc.layers.items.len);
    try testing.expect(doc.layerIdAt(0).? != .invalid);
    try testing.expect(doc.next_layer_id > before_reset);
    try testing.expectEqual(@as(?usize, null), doc.layerIndexOf(id0)); // Old id is missing
}

// ── pushReplaceColor ──────────────────────────────────────────

test "pushReplaceColor: replace→undo restores bits / from==to and 0 pixels are no-op" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();
    const px = doc.active_view.layerPixels(0);
    const red: u32 = 0xFFFF0000;
    const blue: u32 = 0xFF0000FF;
    // 4 pixels to red
    try pushTestPaint(&doc, gpa, 0, 0, red);
    try pushTestPaint(&doc, gpa, 0, 1, red);
    try pushTestPaint(&doc, gpa, 0, 2, red);
    try pushTestPaint(&doc, gpa, 0, 3, red);
    const before = try gpa.dupe(u32, px);
    defer gpa.free(before);

    // from==to → no-op (no Op pushed)
    const depth_before = doc.undo.undo.items.len;
    const n0 = try doc.pushReplaceColor(gpa, 0, red, red);
    try testing.expectEqual(@as(u32, 0), n0);
    try testing.expectEqual(depth_before, doc.undo.undo.items.len);

    // Color not present → replaced=0 · no-op
    const n1 = try doc.pushReplaceColor(gpa, 0, 0xFF00FF00, blue);
    try testing.expectEqual(@as(u32, 0), n1);
    try testing.expectEqual(depth_before, doc.undo.undo.items.len);

    // Replace 4 pixels
    const n2 = try doc.pushReplaceColor(gpa, 0, red, blue);
    try testing.expectEqual(@as(u32, 4), n2);
    try testing.expectEqual(blue, px[0]);
    try testing.expectEqual(blue, px[3]);
    try testing.expectEqual(depth_before + 1, doc.undo.undo.items.len);

    // undo restores bit-identical
    doc.undoOne(gpa);
    try testing.expectEqualSlices(u32, before, px);
}

test "pushReplaceColor: replace all pixels" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 2, 2);
    defer doc.deinit();
    const px = doc.active_view.layerPixels(0);
    @memset(px, 0xFF112233);
    // Commit to cel via pushPaintOp first, then replace (pushReplaceColor calls ensureCelAt)
    try doc.pushPaintOp(gpa, 0, blk: {
        const d = try gpa.alloc(PixelDiff, px.len);
        for (px, 0..) |p, i| d[i] = .{ .idx = @intCast(i), .before = 0, .after = p };
        break :blk d;
    });
    const n = try doc.pushReplaceColor(gpa, 0, 0xFF112233, 0xFFAABBCC);
    try testing.expectEqual(@as(u32, 4), n);
    for (px) |p| try testing.expectEqual(@as(u32, 0xFFAABBCC), p);
}

// ── Playback interval / advance check ──────────────────────────

test "playbackIntervalSec: 100ms→1/fps / 200ms→2/fps / 50ms→0.5/fps / fps=0→inf / duration=0→1/fps" {
    // fps=10 → 1/fps = 0.1
    try testing.expectApproxEqAbs(@as(f64, 0.1), playbackIntervalSec(10.0, 100), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.2), playbackIntervalSec(10.0, 200), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.05), playbackIntervalSec(10.0, 50), 1e-12);
    try testing.expect(std.math.isInf(playbackIntervalSec(0.0, 100)));
    try testing.expect(std.math.isInf(playbackIntervalSec(-1.0, 100)));
    // duration_ms==0 treated as 100 → 1/fps
    try testing.expectApproxEqAbs(@as(f64, 0.1), playbackIntervalSec(10.0, 0), 1e-12);
    // Also pin that at fps=1 the factor becomes seconds as-is
    try testing.expectApproxEqAbs(@as(f64, 1.0), playbackIntervalSec(1.0, 100), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 2.0), playbackIntervalSec(1.0, 200), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.5), playbackIntervalSec(1.0, 50), 1e-12);
}

test "shouldAdvance: no catch-up (even after 0.35s, 1 tick advances 1 frame; no residual credit)" {
    const interval: f64 = 0.1; // fps=10, duration=100
    try testing.expect(!shouldAdvance(0.05, 0.0, interval));
    try testing.expect(shouldAdvance(0.1, 0.0, interval));
    // After 0.35s: check is true, but caller resets last=now so
    // multiple frames do not advance in the same tick (no leftover 0.25s credit).
    const now: f64 = 0.35;
    try testing.expect(shouldAdvance(now, 0.0, interval));
    const last_after = now; // last_advance = now (existing behavior)
    try testing.expect(!shouldAdvance(now, last_after, interval));
    // Next advance needs a full interval from last_after (no leftover credit).
    // f64 0.1 is not a finite binary fraction, so pin at 0.5× / 1.5× rather than the exact boundary.
    try testing.expect(!shouldAdvance(last_after + interval * 0.5, last_after, interval));
    try testing.expect(shouldAdvance(last_after + interval * 1.5, last_after, interval));
}

// ── Document.resize ────────────────────────────────────────

test "Document.resize: 4x3→2x2 keeps top-left / 4x3→6x5 new region 0 / undo depth 0" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 4, 3);
    defer doc.deinit();

    // Allocate cel and write a known pattern (row-major: y*w+x)
    _ = doc.createCel(gpa, 0, 0);
    const px = doc.cel_pool.items[0].?.pixels;
    px[0] = 0xFF000001; // (0,0)
    px[1] = 0xFF000002; // (1,0)
    px[4] = 0xFF000003; // (0,1)
    px[5] = 0xFF000004; // (1,1)
    px[8] = 0xFF000005; // (0,2) — dropped by crop
    doc.resyncActiveView(gpa);
    doc.undo.push(gpa, testVisOp(0));
    try testing.expectEqual(@as(usize, 1), doc.undo.undo.items.len);

    try doc.resize(gpa, 2, 2);
    try testing.expectEqual(@as(u32, 2), doc.width);
    try testing.expectEqual(@as(u32, 2), doc.height);
    try testing.expectEqual(@as(u32, 2), doc.active_view.width);
    try testing.expectEqual(@as(u32, 2), doc.active_view.height);
    try testing.expectEqual(@as(usize, 4), doc.active_view.composite_cache.len);
    try testing.expectEqual(@as(usize, 0), doc.undo.undo.items.len);
    try testing.expectEqual(@as(usize, 0), doc.undo.redo.items.len);

    const shrunk = doc.cel_pool.items[0].?.pixels;
    try testing.expectEqual(@as(usize, 4), shrunk.len);
    try testing.expectEqual(@as(u32, 0xFF000001), shrunk[0]);
    try testing.expectEqual(@as(u32, 0xFF000002), shrunk[1]);
    try testing.expectEqual(@as(u32, 0xFF000003), shrunk[2]);
    try testing.expectEqual(@as(u32, 0xFF000004), shrunk[3]);
    try testing.expectEqual(@as(u32, 0xFF000001), doc.active_view.layerPixels(0)[0]);

    try doc.resize(gpa, 6, 5);
    try testing.expectEqual(@as(u32, 6), doc.width);
    try testing.expectEqual(@as(u32, 5), doc.height);
    const grown = doc.cel_pool.items[0].?.pixels;
    try testing.expectEqual(@as(usize, 30), grown.len);
    try testing.expectEqual(@as(u32, 0xFF000001), grown[0]);
    try testing.expectEqual(@as(u32, 0xFF000002), grown[1]);
    try testing.expectEqual(@as(u32, 0), grown[2]); // New region
    try testing.expectEqual(@as(u32, 0xFF000003), grown[6]); // y=1
    try testing.expectEqual(@as(u32, 0xFF000004), grown[7]);
    try testing.expectEqual(@as(u32, 0), grown[12]); // y=2 was not in the old 2x2 → 0
    try testing.expectEqual(@as(usize, 30), doc.active_view.composite_cache.len);
}

test "Document.resize: keeps multi-layer/frame/linked-cel refs / same size no-op / unchanged on 0 or overflow" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();

    _ = try doc.addLayer(gpa); // Note: ensureCelAt attaches a cel to layer1 first
    try doc.addFrame(gpa, 1);
    const cel0 = doc.createCel(gpa, 0, 0);
    doc.cel_pool.items[cel0].?.pixels[0] = 0xFFFF0000;
    doc.cel_pool.items[cel0].?.pixels[5] = 0xFF00FF00;
    try doc.linkCel(gpa, 0, 1, 0); // frame1 → same CelId
    const cel1 = doc.createCel(gpa, 1, 0);
    doc.cel_pool.items[cel1].?.pixels[0] = 0xFF0000FF;
    doc.resyncActiveView(gpa);

    try testing.expectEqual(cel0, doc.gridGet(0, 1).?);
    try testing.expect(cel0 != cel1);
    const ref_before = doc.cel_pool.items[cel0].?.refcount;

    // Invalid size: state unchanged
    const w_before = doc.width;
    const h_before = doc.height;
    const pool_len_before = doc.cel_pool.items.len;
    const red_before = doc.cel_pool.items[cel0].?.pixels[0];
    try testing.expectEqual(@as(u32, 0xFFFF0000), red_before);
    try testing.expectError(error.InvalidSize, doc.resize(gpa, 0, 16));
    try testing.expectError(error.InvalidSize, doc.resize(gpa, 16, 0));
    try testing.expectError(error.SizeOverflow, doc.resize(gpa, std.math.maxInt(u32), std.math.maxInt(u32)));
    try testing.expectEqual(w_before, doc.width);
    try testing.expectEqual(h_before, doc.height);
    try testing.expectEqual(pool_len_before, doc.cel_pool.items.len);
    try testing.expectEqual(@as(u32, 0xFFFF0000), doc.cel_pool.items[cel0].?.pixels[0]);

    // Same size no-op (pointers preserved)
    const px_ptr = doc.cel_pool.items[cel0].?.pixels.ptr;
    try doc.resize(gpa, 4, 4);
    try testing.expect(doc.cel_pool.items[cel0].?.pixels.ptr == px_ptr);

    try doc.resize(gpa, 2, 2);
    try testing.expectEqual(cel0, doc.gridGet(0, 0).?);
    try testing.expectEqual(cel0, doc.gridGet(0, 1).?);
    try testing.expectEqual(cel1, doc.gridGet(1, 0).?);
    try testing.expectEqual(ref_before, doc.cel_pool.items[cel0].?.refcount);
    try testing.expectEqual(@as(u32, 0xFFFF0000), doc.cel_pool.items[cel0].?.pixels[0]);
    // (1,1) = idx 5 on 4x4 → (1,1) = idx 3 on 2x2
    try testing.expectEqual(@as(u32, 0xFF00FF00), doc.cel_pool.items[cel0].?.pixels[3]);
    try testing.expectEqual(@as(u32, 0xFF0000FF), doc.cel_pool.items[cel1].?.pixels[0]);
    try testing.expectEqual(@as(usize, 2), doc.layers.items.len);
    try testing.expectEqual(@as(usize, 2), doc.frames.items.len);
    try testing.expectEqual(@as(u32, 2), doc.active_view.width);
    try testing.expectEqual(@as(usize, 2), doc.active_view.layers.items.len);
}
