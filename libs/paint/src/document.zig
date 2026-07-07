//! Document — セルグリッド・linked cel モデル（TASK-45.1）。
//!
//! frames × layers × cel_pool の linked-cel モデル。TASK-63 の `frames:[]*Canvas` から
//! 置き換え、Aseprite 型のセルグリッド（layer×frame → cel の疎な参照。null=空セル=透明、
//! 同一 CelId を複数 frame が指すことでリンク編集=共有編集が成立する）を実装する。
//!
//! - `Canvas`（`active_view`）は「アクティブフレームの編集可能ビュー」として無改造で流用する
//!   （所有権モデル不変。案B=コピー同期。詳細は backlog task-45.1 の Implementation Plan 4.2節）。
//! - `Op`/`UndoStack`（push/apply・`CelSetSnapshot`）は本ファイルに置く（`undo.zig` は
//!   `PixelDiff`/`NameSnapshot`/`StrokeRecorder`/`PaintDiff` のみを持ち、本ファイルを
//!   import しない一方向依存。循環 import 回避。plan 5.1節）。
//! - CelId は Document 生存期間中 **一度払い出したら二度と別の cel へ再割り当てしない**
//!   （free-list 無し。plan 4.3節。undo/redo 履歴が古い CelId を値として保持し続けるため）。
//!
//! ホットパス宣言: 本ファイルの API はすべて **イベント時のみ**（frame 切替・undo/redo・
//! cel/frame/layer 操作はいずれもユーザー操作 1 回につき 1 回)。フレーム毎全画素ループは
//! `active_view.composite()`/`compositeStraight()`（既存 Canvas の SIMD 経路。無改造）のみで、
//! 本ファイルは一切新設しない。`resyncActiveView`/`pushPaintOp` の `@memcpy` は1layer〜数layer分の
//! 1回コピーであり、frame切替直後・undo/redo直後・project load直後・stroke確定時のみ走る
//! （main loop の毎フレーム経路には混入させない。plan 2節の明示的禁止事項）。

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

/// text を最大 max バイトへ、UTF-8 継続バイト（0b10xxxxxx）の途中で切らないように
/// 切り詰めた長さを返す（`canvas.zig` の同名 private 関数と同じロジック。`LayerDef.setName`
/// 専用に複製し `canvas.zig` の可視性を変更しない。TASK-79.3 と同型の固定長方針）。
fn safeUtf8TruncateLen(text: []const u8, max: usize) usize {
    var n = @min(text.len, max);
    while (n > 0 and n < text.len and (text[n] & 0xC0) == 0x80) : (n -= 1) {}
    return n;
}

/// cel_pool のスロット識別子。**Document のライフタイム中、一度払い出した値を
/// 二度と別の cel へ再割り当てしない**（plan 4.3節）。
pub const CelId = u32;

pub const Cel = struct {
    pixels: []u32, // canonical BGRA。gpa 所有
    refcount: u32 = 1, // 同一 layer 内で何個の frame 列がこの cel を参照しているか
};

/// レイヤー定義（Document レベル。全 frame で共有。TASK-79.3/79.5 の name/kind/TextParams は
/// ここへ移動する）。
pub const LayerDef = struct {
    visible: bool = true,
    opacity: u8 = 255,
    name_buf: [layer_name_max]u8 = undefined,
    name_len: u8 = 0,
    kind: LayerKind = .raster,
    text_params: TextParams = .{}, // kind==.text の時のみ意味を持つ

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

/// 1 layer の全 frame 分の行（layer_add/delete 用）、または 1 frame の全 layer 分の列
/// （frame_add/delete/duplicate 用）を、削除/復元のために一時保持する。
/// `CelSetSnapshot.fully_released`/`Document.mergeDown` 用の共有 named 型（匿名 struct は
/// 出現ごとに別型になり Zig の型検査で unify されないため、`.captureAndReleaseSlots` 等の
/// 生成側と一致させるために名前を付ける）。
pub const CelSnapshotItem = struct { id: CelId, pixels: []u32 };

pub const CelSetSnapshot = struct {
    /// スロットごとの元 CelId（null=元々空だった）。行なら frames.len 個、列なら layers.len 個。
    /// **この配列だけでは「実体を持つか」は分からない**（下記 fully_released と突き合わせる）。
    slots: []?CelId,
    /// slots に現れる CelId のうち、**この削除によって refcount が 0 になり実際に
    /// `cel_pool` から取り除かれたもの**だけを、重複無く保持する（同一 id は1回だけ）。
    fully_released: []CelSnapshotItem,
};

/// layer_add/layer_delete 共通の Op payload（同一型にして switch prong を統合できるようにする）。
pub const LayerStructOp = struct {
    index: usize,
    selected_before: usize,
    selected_after: usize,
    /// push直後=null（構造は既に変更済み・canvasはもう保持しない）→undoで非nullへ（捕捉）
    /// →redoでnullへ（復元）。layer_add/delete で意味が反転する（4.6節と同じトグル）。
    def: ?LayerDef = null,
    row: ?CelSetSnapshot = null,
};

/// frame_add/frame_delete 共通の Op payload。
pub const FrameStructOp = struct {
    index: u32,
    selected_before: u32,
    selected_after: u32,
    duration_ms: u32,
    col: ?CelSetSnapshot = null,
};

/// 1 操作の中身。`document.zig` 側に移設（undo.zig ⇄ document.zig の循環 import 回避。plan 5.1節）。
pub const Op = union(enum) {
    /// raster ピクセル編集のコミット（`Document.pushPaintOp`/`pushClear` が構築する。唯一の生成口）。
    paint: struct {
        cel_id: CelId,
        diffs: []PixelDiff,
        layer_idx: usize,
        frame_idx: u32,
        /// この paint がコミットされた時点で `ensureCelAt` が新規 blank cel を生成したか
        /// （= grid スロットがそれまで null だったか）。
        created: bool = false,
        /// created==true の時のみ意味を持つ。非null ⇔ 現在「before（未作成）」状態が適用中
        /// （grid スロット=null・cel は cel_pool から除去済み・この Op が pixels の所有権を保持）。
        created_released: ?[]u32 = null,
    },

    // ── layer メタデータ（frame非依存） ───────────
    layer_visible: struct { index: usize, before: bool, after: bool },
    layer_opacity: struct { index: usize, before: u8, after: u8 },
    layer_rename: struct { index: usize, before: NameSnapshot, after: NameSnapshot },
    layer_reorder: struct { from: usize, to: usize, selected_before: usize, selected_after: usize },
    layer_text_params: struct { index: usize, before: TextParams, after: TextParams },
    layer_rasterize: struct { index: usize, before: TextParams },

    // ── layer 構造（全frameの行を保持） ───────────
    layer_add: LayerStructOp,
    layer_delete: LayerStructOp,

    // ── frame 構造（全layerの列を保持） ───────────
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

    // ── merge down（frame数1のみ許可のMVP制限。9.1節で承認済み） ─
    layer_merge_down: struct {
        index: usize,
        selected_before: usize,
        selected_after: usize,
        def: ?LayerDef = null,
        cel: ?CelSnapshotItem = null,
        below_before: []u32,
        below_after: []u32,
    },

    // ── cel リンク編集（4.6節 CelSetSnapshot の fully_released 原則を1スロットへ応用） ──
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

/// snapshot を cel_pool へ復元した**後**に呼ぶ、コンテナ配列だけの解放（pixels の所有権は
/// 既に cel_pool へ移っているため pixels 自体は解放しない）。
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

/// Undo/Redo スタック。各 Op の owned スライスは gpa 所有。
pub const UndoStack = struct {
    pub const max_history: usize = 128;

    undo: std.ArrayList(Op) = .empty,
    redo: std.ArrayList(Op) = .empty,

    pub fn deinit(self: *UndoStack, gpa: Allocator) void {
        freeStack(gpa, &self.undo);
        freeStack(gpa, &self.redo);
    }

    fn freeStack(gpa: Allocator, stack: *std.ArrayList(Op)) void {
        for (stack.items) |*op| freeOp(gpa, op);
        stack.deinit(gpa);
    }

    fn clearRedo(self: *UndoStack, gpa: Allocator) void {
        for (self.redo.items) |*op| freeOp(gpa, op);
        self.redo.clearRetainingCapacity();
    }

    /// 非空コマンドを積む。redo 履歴をクリアする。
    pub fn push(self: *UndoStack, gpa: Allocator, op: Op) void {
        self.clearRedo(gpa);
        if (self.undo.items.len >= max_history) {
            var oldest = self.undo.orderedRemove(0);
            freeOp(gpa, &oldest);
        }
        self.undo.append(gpa, op) catch @panic("UndoStack.push: OOM");
    }
};

pub const EnsureResult = struct { id: CelId, created: bool };

pub const Document = struct {
    width: u32,
    height: u32,
    layers: std.ArrayList(LayerDef) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    /// null = 解放済みスロット（永久に再利用しない）。
    cel_pool: std.ArrayList(?Cel) = .empty,
    next_cel_id: CelId = 0,
    /// grid[layer_idx * frames.items.len + frame_idx] = ?CelId
    grid: std.ArrayList(?CelId) = .empty,
    selected_layer: usize = 0,
    selected_frame: u32 = 0,
    /// アクティブフレームの合成/ツール描画用ビュー。既存 Canvas 型を無改造で流用。
    active_view: Canvas,
    undo: UndoStack = .{},
    allocator: Allocator,

    /// 1 layer / 1 frame（blank）の Document を作る。App 起動時の初期状態。
    pub fn init(gpa: Allocator, w: u32, h: u32) !Document {
        var doc = try initEmpty(gpa, w, h);
        errdefer doc.deinit();
        var def: LayerDef = .{};
        def.setName("Layer 1");
        try doc.layers.append(gpa, def);
        try doc.frames.append(gpa, .{});
        try doc.grid.append(gpa, null); // 空セル=透明（遅延生成）
        return doc;
    }

    /// layer/frame を 1 つも持たない Document（decoder が組み立てる土台）。
    /// `active_view` は Canvas.init 既定の 1 blank layer から始まる（decode 完了後に
    /// `resyncActiveView` で doc.layers に合わせて reconcile される）。
    pub fn initEmpty(gpa: Allocator, w: u32, h: u32) !Document {
        const view = try Canvas.init(gpa, w, h);
        return .{ .width = w, .height = h, .active_view = view, .allocator = gpa };
    }

    pub fn deinit(self: *Document) void {
        for (self.cel_pool.items) |maybe_cel| if (maybe_cel) |cel| self.allocator.free(cel.pixels);
        self.cel_pool.deinit(self.allocator);
        self.layers.deinit(self.allocator);
        self.frames.deinit(self.allocator);
        self.grid.deinit(self.allocator);
        self.undo.deinit(self.allocator);
        self.active_view.deinit();
    }

    /// pixie 等の呼び出し元が保持する `*Canvas` の取得口（TASK-63 互換）。
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

    fn setGrid(self: *Document, layer_idx: usize, frame_idx: u32, id: ?CelId) void {
        self.grid.items[self.gridIndex(layer_idx, frame_idx)] = id;
    }

    // ══════════════════════════════════════════════════════════════════
    // cel の生成・削除・リンク・GC（plan 4.3節）
    // ══════════════════════════════════════════════════════════════════

    /// blank cel を1個確保して cel_pool へ push する（`next_cel_id` を1消費。非再利用）。
    /// 返る CelId は常に `cel_pool.items.len - 1`（append-only。null 化されても詰めないため
    /// `cel_pool.items.len == next_cel_id` が常に成立する）。
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

    /// refcount を1減らす。0に到達したら pixels の所有権を取り出しつつ `cel_pool[id]=null`
    /// にする（0に到達しなければ null を返し cel は生存継続）。単発 decrement の低レベル
    /// ヘルパー（4.6節の CelSetSnapshot capture とは別実装。原則は同じだが出現回数集計を
    /// 伴わない単純ケース専用）。
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

    /// 既存なら no-op で返す、無ければ新規 blank cel を確保して grid にセットし返す。
    /// `created` は呼び出し元（`pushPaintOp`）が undo の created フラグに使う。
    /// kind==.text の layer では既存の共有 cel を返すだけの前提（無ければバグ＝assert）。
    pub fn ensureCelAt(self: *Document, gpa: Allocator, layer_idx: usize, frame_idx: u32) EnsureResult {
        if (self.gridGet(layer_idx, frame_idx)) |id| return .{ .id = id, .created = false };
        std.debug.assert(self.layers.items[layer_idx].kind != .text); // 4.4節: text は既に共有celを持つはず
        const id = self.allocBlankCel(gpa);
        self.setGrid(layer_idx, frame_idx, id);
        return .{ .id = id, .created = true };
    }

    /// `ensureCelAt` の薄い公開ラッパー（created の有無を捨てる用途向け）。
    pub fn createCel(self: *Document, gpa: Allocator, layer_idx: usize, frame_idx: u32) CelId {
        return self.ensureCelAt(gpa, layer_idx, frame_idx).id;
    }

    /// スロットを空へ戻す（cel参照をrelease。0到達で回収）。既に空なら no-op。Undo 非対応
    /// （低レベルプリミティブ。呼び出し元は用途に応じて Undo を別途設計する）。
    pub fn clearCel(self: *Document, gpa: Allocator, layer_idx: usize, frame_idx: u32) void {
        const id = self.gridGet(layer_idx, frame_idx) orelse return;
        if (self.releaseCelMaybeCapture(id)) |pixels| gpa.free(pixels);
        self.setGrid(layer_idx, frame_idx, null);
    }

    /// text layer の不変条件（全frameが同一CelIdを指す）を強制する唯一のポイント（4.4節）。
    /// 対象 layer の grid 列を走査し、最初に見つかった non-null CelId を正典とする（無ければ
    /// 新規作成）。残りの列は正典へ張り替える（release/retain）。
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
            self.cel_pool.items[id].?.refcount = 0; // まだどの grid スロットも指していない
            break :blk id;
        };
        for (0..nframes) |f| {
            const fi: u32 = @intCast(f);
            const cur = self.gridGet(layer_idx, fi);
            if (cur != null and cur.? == canon) continue; // 既に正典
            if (cur) |old_id| {
                if (self.releaseCelMaybeCapture(old_id)) |pixels| gpa.free(pixels);
            }
            self.retainCel(canon);
            self.setGrid(layer_idx, fi, canon);
        }
    }

    /// `linkCel`/`unlinkCel` の active_view 即時反映（4.2節: 通常経路の Document API は
    /// 自分で active_view も更新してよい。resyncActiveView は経由しない）。
    fn syncActiveViewSlot(self: *Document, layer_idx: usize, frame_idx: u32) void {
        if (frame_idx != self.selected_frame) return;
        const dst = self.active_view.layerPixels(layer_idx);
        if (self.gridGet(layer_idx, frame_idx)) |id| {
            @memcpy(dst, self.cel_pool.items[id].?.pixels);
        } else {
            @memset(dst, 0);
        }
    }

    /// `dst_frame` のスロットを `src_frame` が指す CelId へ張り替える（共有編集(a)の確立）。
    /// Undo 対応（`Op.cel_link`。4.6節 CelSetSnapshot の fully_released 原則の1スロット応用）。
    pub fn linkCel(self: *Document, gpa: Allocator, layer_idx: usize, dst_frame: u32, src_frame: u32) !void {
        if (self.layers.items[layer_idx].kind == .text) return error.TextLayerLinked;
        const src_id = self.gridGet(layer_idx, src_frame) orelse return error.SourceCelEmpty;
        const dst_before = self.gridGet(layer_idx, dst_frame);
        if (dst_before != null and dst_before.? == src_id) return; // 既にリンク済み（no-op）
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

    /// 対象スロットの共有 cel を複製して独立 cel へ切り替える（refcount--・新規 cel は
    /// refcount=1）。Undo 対応（`Op.cel_unlink`）。既に非共有（refcount<=1）は no-op。
    pub fn unlinkCel(self: *Document, gpa: Allocator, layer_idx: usize, frame_idx: u32) !void {
        if (self.layers.items[layer_idx].kind == .text) return error.TextLayerLinked;
        const cid = self.gridGet(layer_idx, frame_idx) orelse return error.EmptySlot;
        const refcount = self.cel_pool.items[cid].?.refcount;
        if (refcount <= 1) return; // 既に独立（no-op）
        const new_id = self.allocBlankCel(gpa);
        @memcpy(self.cel_pool.items[new_id].?.pixels, self.cel_pool.items[cid].?.pixels);
        std.debug.assert(self.releaseCelMaybeCapture(cid) == null); // 共有中なので0に到達しない
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
    // Canvas との同期（plan 4.2節）
    // ══════════════════════════════════════════════════════════════════

    /// 現フレームの各 layer を doc.layers+grid[*][selected_frame] から作り直す（読み出し）。
    /// 呼び出し元は: frame切替直後・undoOne/redoOne直後・project load直後の3箇所のみ
    /// （main loop の毎フレーム経路へ混入させない。plan 2節の明示的禁止事項）。
    pub fn resyncActiveView(self: *Document, gpa: Allocator) void {
        // レイヤー数 reconcile（v5補遺(b)）: Canvas 所有 pixels の alloc/free は Canvas API に任せる。
        while (self.active_view.layers.items.len > self.layers.items.len) {
            const removed = self.active_view.deleteLayer(self.active_view.layers.items.len - 1) orelse break;
            gpa.free(removed.pixels);
        }
        while (self.active_view.layers.items.len < self.layers.items.len) {
            const blank = self.active_view.allocBlankLayer(gpa) catch @panic("Document.resyncActiveView: OOM");
            self.active_view.insertLayer(gpa, self.active_view.layers.items.len, blank) catch @panic("Document.resyncActiveView: OOM");
        }
        // per-layer content + metadata（layerPixels() アクセサ経由。v5補遺(a): composite cache
        // 無効化を自動成立させるため直接 `layers.items[i].pixels` を触らない）。
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
        // selected_layer は doc が唯一の権威（4.5節）。system_font は一切触らない。
        self.active_view.selected_layer = self.selected_layer;
    }

    /// raster ピクセルを変更する全ての操作が経由する唯一のコミット口
    /// （ensureCelAt→書き戻し→Op構築→push の3手順を1回の呼び出しに集約）。
    /// `diffs` の所有権は呼ばれた時点で常に doc へ移る（早期returnでも必ず解放する）。
    pub fn pushPaintOp(self: *Document, gpa: Allocator, layer_idx: usize, diffs: []PixelDiff) error{TextLayerSelected}!void {
        if (self.layers.items[layer_idx].kind == .text) {
            gpa.free(diffs);
            return error.TextLayerSelected;
        }
        if (diffs.len == 0) {
            gpa.free(diffs); // 変化なし。cel を作らない・push しない
            return;
        }
        const ensured = self.ensureCelAt(gpa, layer_idx, self.selected_frame);
        @memcpy(self.cel_pool.items[ensured.id].?.pixels, self.active_view.layerPixels(layer_idx));
        self.undo.push(gpa, .{ .paint = .{
            .cel_id = ensured.id,
            .diffs = diffs,
            .layer_idx = layer_idx,
            .frame_idx = self.selected_frame,
            .created = ensured.created,
        } });
    }

    /// 選択中 layer の現フレームを全消去する Op を構築して push する（`pushPaintOp` の
    /// 「build→memset→push」を1 API に集約した薄いラッパー）。
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

    // ══════════════════════════════════════════════════════════════════
    // CelSetSnapshot capture/restore（4.6節。行=layer全frame分・列=frame全layer分の一括処理）
    // ══════════════════════════════════════════════════════════════════

    /// `slots`（既に呼び出し側が grid から抜き取り済みの生の ?CelId 配列。所有権は snapshot へ
    /// 移る）を占有する各 cel について、この slots 内での出現回数と refcount を比較し、
    /// 出現回数==refcount なら実際に release して pixels を capture（fully_released へ）、
    /// 出現回数<refcount なら release分だけ decrement する（生存継続）。
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

    /// snapshot の内容を cel_pool へ復元する（fully_released は新規再構築・生存分は
    /// refcount を出現回数分戻す）。**grid への書き込みは呼び出し側の責務**（このメソッドは
    /// cel_pool 側のみを扱う）。
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
            if (in_fully) continue; // 上のループで既に復元済み
            var occ: u32 = 0;
            for (snapshot.slots) |s| {
                if (s != null and s.? == id) occ += 1;
            }
            self.cel_pool.items[id].?.refcount += occ;
        }
    }

    // ── layer 行の capture/restore（layer_add/layer_delete 用） ──────────

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

    // ── frame 列の raw 操作（cel_pool 非関与。addFrame/duplicateFrame の通常経路用） ──────

    /// grid を「frame_idx 列を追加した」新しい形へ再構築する（cel_pool 側には触れない）。
    /// 呼び出し時点で self.frames はまだ更新前（stride は現在の frames.items.len を使う）。
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

    /// grid から frame_idx 列を除いた新しい形へ再構築し、除かれた列を返す（cel_pool 側には
    /// 触れない。呼び出し時点で self.frames はまだ更新前）。
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
    // layer メタデータ操作（frame非依存。plan 4.5節）
    // ══════════════════════════════════════════════════════════════════

    /// 選択レイヤーを切り替える（Undo 非対応。既存 UI/action の `select_layer` と同型の
    /// 「no push」操作。plan §8.4「pixie側は active_view.selectLayer を直接呼ばない」に対応する
    /// Document 側の唯一の入口）。
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
        if (std.mem.eql(u8, before.slice(), after.slice())) return; // 冪等 no-op
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

    /// doc.layers と grid の行を入れ替える（`ArrayList.orderedRemove`+`insert` と同じ
    /// index 意味論。`to` は削除後の配列における挿入位置）。
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
    // layer 構造操作（plan 4.5節）
    // ══════════════════════════════════════════════════════════════════

    /// grid に新しい行を追加、**現在の selected_frame のみ** blank cel を確保（他 frame は
    /// null=透明。初回描画時に遅延生成）。
    pub fn addLayer(self: *Document, gpa: Allocator) !usize {
        const idx = self.layers.items.len;
        const selected_before = self.selected_layer;
        const av_layer = try self.active_view.allocBlankLayer(gpa);
        errdefer gpa.free(av_layer.pixels);
        var def: LayerDef = .{};
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

    /// テキストレイヤーを新規追加する。**全既存 frame** に共有 cel をリンクする（4.4節。
    /// raster の addLayer とは非対称）。
    pub fn addTextLayer(self: *Document, gpa: Allocator, params: TextParams) !usize {
        const idx = self.layers.items.len;
        const selected_before = self.selected_layer;
        const av_layer = try self.active_view.allocBlankLayer(gpa);
        errdefer gpa.free(av_layer.pixels);
        var def: LayerDef = .{ .kind = .text, .text_params = params };
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
        self.resyncActiveView(gpa); // pixels/kind/text_params を active_view へ反映
        return idx;
    }

    /// grid の行を削除。各 frame の cel 参照を release（refcount減算・0で回収）。
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

    /// 選択レイヤーを複製し、直上へ挿入する。raster は各 frame を独立 deep copy、
    /// text は新規 cel を全既存 frame へリンクする独立レイヤーとして扱う（4.4節item4）。
    pub fn duplicateLayer(self: *Document, gpa: Allocator, src_idx: usize) !usize {
        if (src_idx >= self.layers.items.len) return error.OutOfRange;
        const new_idx = src_idx + 1;
        const selected_before = self.selected_layer;
        const src_def = self.layers.items[src_idx];
        const new_def = src_def; // POD値コピー（text_params含む・名前も継承）
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

    /// テキストレイヤーの text_params を更新し、共有 cel を再ラスタライズする。
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

    /// layer の共有 cel（全frame同一CelIdの前提。4.4節）を探して再ラスタライズする。
    fn sharedTextCelId(self: *const Document, layer_idx: usize) CelId {
        const nframes = self.frames.items.len;
        for (0..nframes) |f| {
            if (self.gridGet(layer_idx, @intCast(f))) |id| return id;
        }
        unreachable; // 4.4節不変条件: text layer は全frameにcelを持つ
    }

    fn rasterizeSharedTextCel(self: *Document, gpa: Allocator, layer_idx: usize, params: TextParams) !void {
        self.layers.items[layer_idx].text_params = params;
        const cel_id = self.sharedTextCelId(layer_idx);
        const pixels = self.cel_pool.items[cel_id].?.pixels;
        try text_render.rasterizeTextLayer(gpa, pixels, self.width, self.height, params.text(), params.font_px, params.color, params.x, params.y, self.active_view.system_font);
    }

    /// テキストレイヤーを通常 raster レイヤーへ確定する（bake）。pixels は不変（既に
    /// 最新のラスタライズ結果）。呼び出し前の text_params を返す（Undo 用）。
    pub fn rasterizeLayer(self: *Document, gpa: Allocator, index: usize) !TextParams {
        if (index >= self.layers.items.len) return error.OutOfRange;
        if (self.layers.items[index].kind != .text) return error.NotTextLayer;
        const before = self.layers.items[index].text_params;
        self.layers.items[index].kind = .raster;
        self.layers.items[index].text_params = .{};
        self.active_view.layers.items[index].kind = .raster; // pixels不変・markDirty不要
        self.active_view.layers.items[index].text_params = .{};
        self.undo.push(gpa, .{ .layer_rasterize = .{ .index = index, .before = before } });
        return before;
    }

    /// 選択レイヤー(top)を直下(bottom=top-1)へ opacity 込みで src-over 焼き込みし、top を削除する。
    /// **frame数が1の間だけ許可**（9.1節MVP制限。多フレーム対応は別タスクへ先送り）。
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
    // frame 構造操作（plan 4.5節）
    //
    // frame add/delete/duplicate は grid（stride=frames.len の flat 配列）の全面再構築を
    // 伴う（v5補遺(e)③）。selected_frame が変わるため、通常経路（この3メソッド）も
    // 「frame切替」の一種として resyncActiveView を呼ぶ（2節の3箇所ルールは「意図」レベルで
    // 一致させる: syncPreviewCanvas 等の毎フレーム経路には決して混入しない、という趣旨）。
    // ══════════════════════════════════════════════════════════════════

    /// 空フレームを挿入する。raster layer は null=透明、text layer は共有 cel へリンク（4.4節）。
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

    /// frame を複製する（src の直後へ挿入）。raster layer は non-null なら深いコピー
    /// （独立cel・refcount=1）、null は null のまま。text layer は深いコピーせず共有celへリンク。
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
                values[li] = src_cel; // 共有celへリンク（retainは下のループで実施）
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

    /// frame を削除する。各 layer の該当列の cel 参照を release。selected_frame を clamp。
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

    /// PNG open 用: doc/active_view を「1layer・1frame・1cel(空)」状態へ縮める。
    /// `active_view` は再init せず既存構造を縮める（plan 4.2節の制約準拠）。undo/redo も破棄する。
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
        var def: LayerDef = .{};
        def.setName("Layer 1");
        self.layers.append(gpa, def) catch @panic("Document.resetToSingleBlankLayer: OOM");
        self.grid.append(gpa, null) catch @panic("Document.resetToSingleBlankLayer: OOM");
        self.selected_layer = 0;
        self.selected_frame = 0;
        self.undo.deinit(gpa);
        self.undo = .{};
    }

    // ══════════════════════════════════════════════════════════════════
    // undo/redo apply（plan 5.3節）
    // ══════════════════════════════════════════════════════════════════

    pub fn undoOne(self: *Document, gpa: Allocator) void {
        var op = self.undo.undo.pop() orelse return;
        self.applyBefore(gpa, &op);
        self.undo.redo.append(gpa, op) catch @panic("Document.undoOne: OOM");
        self.resyncActiveView(gpa);
    }

    pub fn redoOne(self: *Document, gpa: Allocator) void {
        var op = self.undo.redo.pop() orelse return;
        self.applyAfter(gpa, &op);
        self.undo.undo.append(gpa, op) catch @panic("Document.redoOne: OOM");
        self.resyncActiveView(gpa);
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
                        std.debug.assert(false); // 45.1スコープでは到達しない防御分岐（plan 5.3節）
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
