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
//! ホットパス宣言: 本ファイルのイベント時 API は **イベント時のみ**（frame 切替・undo/redo・
//! cel/frame/layer 操作はいずれもユーザー操作 1 回につき 1 回)。フレーム毎全画素ループの主経路は
//! `active_view.composite()`/`compositeStraight()`（既存 Canvas の SIMD 経路。無改造）。
//! **例外**: `compositeFrameStraight` は表示フレーム毎・全画素（オニオンスキン経由のみ。TASK-45.3）。
//! `selected_frame` / `active_view` / composite cache は変更しない。
//! `resyncActiveView`/`pushPaintOp` の `@memcpy` は1layer〜数layer分の1回コピーであり、
//! frame切替直後・undo/redo直後・project load直後・stroke確定時のみ走る
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
const pixelops = @import("pixelops");

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

/// 安定レイヤー handle（TASK-94 Phase A）。index とは独立し、move/delete/insert を跨いで
/// 同一レイヤーを指し続ける。**0 は invalid 予約**・単調採番・**再利用なし**
/// （undo で LayerDef ごと戻る場合を除き、削除済み id は再割り当てしない）。
/// 採番・解決はイベント時のみ（フレーム毎 composite には触れない）。
pub const LayerId = enum(u64) {
    invalid = 0,
    _,
};

/// レイヤー定義（Document レベル。全 frame で共有。TASK-79.3/79.5 の name/kind/TextParams は
/// ここへ移動する）。
pub const LayerDef = struct {
    /// 安定 handle。作成時（add/insert/load）に Document が採番する。既定 `.invalid` は
    /// 一時構築用で、Document.layers に載る時点では必ず非 invalid。
    id: LayerId = .invalid,
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

/// 再生の実効間隔（秒）。`interval = (1/fps) × (duration_ms/100)`。
/// fps は全体レート、duration_ms は frame 相対係数（既定 100 → 係数 1.0 = 従来の 1/fps）。
///
/// 仕様（TASK-45.4）:
/// - 計算は全て f64
/// - `fps <= 0` → `+inf`（進まない。UI スライダーは正値のみだが防御）
/// - `duration_ms == 0` → 100 として扱う（ゼロ間隔の busy advance を防ぐ）
/// - 入力は slider(f32 正値)/u32 のみで非有限値は入らない
pub fn playbackIntervalSec(fps: f32, duration_ms: u32) f64 {
    if (fps <= 0) return std.math.inf(f64);
    const fps_f64: f64 = @floatCast(fps);
    const dur: f64 = if (duration_ms == 0) 100.0 else @as(f64, @floatFromInt(duration_ms));
    return dur / 100.0 * (1.0 / fps_f64);
}

/// 追いつき無し advance 判定。`now - last >= interval` なら true。
/// 残余時間の補償はしない（呼び出し側が advance 後に `last = now` へリセットする）。
pub fn shouldAdvance(now: f64, last: f64, interval: f64) bool {
    return now - last >= interval;
}

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
///
/// **handle タグ（TASK-62.5.3）**: `undo` 配列の各 Op に単調一意な u64 handle を並行配列
/// `handles` で対応付ける（CommandRecord の `undo_ref` がこの handle を指す = AC #2 の対応付け。
/// platform 非依存を保つため u64 のみで command 型には依存しない）。`redo` 配列はタグ対象外
/// （undo 候補でないため）。`redoOne` の再 push は**新 handle を採番**する（旧 record との対応は
/// 切れる。62.5.4 で undo/redo が revert record 化されるまでの暫定仕様）。
pub const UndoStack = struct {
    pub const max_history: usize = 128;

    undo: std.ArrayList(Op) = .empty,
    redo: std.ArrayList(Op) = .empty,
    /// `undo` と要素同期する handle 並行配列（handles.items.len == undo.items.len 不変）。
    handles: std.ArrayList(u64) = .empty,
    /// `undo` と要素同期する所有者タグ並行配列（TASK-62.5.4 review: CommandLog リング退避後の
    /// 所有者誤認防止）。**paint は値の意味を解釈しない**（0=unknown を既定とし、それ以外の
    /// 値の規約は app 側 = pixie が持つ）。push/redo 再 push は 0 で積まれ、app が `setOwner` で
    /// 確定する。
    owners: std.ArrayList(u8) = .empty,
    /// 次に採番する handle（単調・再利用なし）。
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

    /// handle を採番する（push と `Document.redoOne` の再 push が使う）。
    fn allocHandle(self: *UndoStack) u64 {
        const h = self.next_handle;
        self.next_handle += 1;
        return h;
    }

    /// 直近 push された op の handle（undo 配列が空なら null）。
    pub fn topHandle(self: *const UndoStack) ?u64 {
        const n = self.handles.items.len;
        if (n == 0) return null;
        return self.handles.items[n - 1];
    }

    /// 指定 handle の op に所有者タグを付ける（handle 不在なら no-op。タグの意味は app 規約）。
    pub fn setOwner(self: *UndoStack, handle: u64, tag: u8) void {
        for (self.handles.items, 0..) |h, i| {
            if (h == handle) {
                self.owners.items[i] = tag;
                return;
            }
        }
    }

    /// 指定 handle の所有者タグ（不在は 0=unknown）。
    pub fn ownerOf(self: *const UndoStack, handle: u64) u8 {
        for (self.handles.items, 0..) |h, i| {
            if (h == handle) return self.owners.items[i];
        }
        return 0;
    }

    /// 指定 handle の Op が undo 配列に現存するか（CommandRecord.undo_ref の live 判定用）。
    pub fn hasHandle(self: *const UndoStack, handle: u64) bool {
        for (self.handles.items) |h| {
            if (h == handle) return true;
        }
        return false;
    }

    /// 非空コマンドを積む。redo 履歴をクリアする。
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

    /// undo/redo 履歴を全クリアするが **handle 採番（next_handle）は保持する**。
    /// ドキュメント読込等のリセット経路は必ずこちらを使う（`deinit` + `= .{}` で作り直すと
    /// next_handle が 1 に戻り、①リセット前の採番値との差分計算が巻き戻って underflow
    /// ②リセット前の CommandRecord.undo_ref と新規 Op の handle が衝突して live 判定が偽陽性、
    /// の 2 つの不具合を生む。handle は App/CommandLog の生存期間で単調・再利用なし。TASK-62.5.3）。
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
    /// null = 解放済みスロット（永久に再利用しない）。
    cel_pool: std.ArrayList(?Cel) = .empty,
    next_cel_id: CelId = 0,
    /// 次に採番する LayerId の raw 値（単調・0=invalid 予約のため 1 始まり・再利用なし。TASK-94）。
    next_layer_id: u64 = 1,
    /// grid[layer_idx * frames.items.len + frame_idx] = ?CelId
    grid: std.ArrayList(?CelId) = .empty,
    selected_layer: usize = 0,
    selected_frame: u32 = 0,
    /// アクティブフレームの合成/ツール描画用ビュー。既存 Canvas 型を無改造で流用。
    active_view: Canvas,
    undo: UndoStack = .{},
    allocator: Allocator,
    /// ドキュメント付属パレット（TASK-89）。空 = 未設定（load 時 DB16 等で初期化は app 側）。
    /// selected は view 状態なので永続化しない。色は canonical BGRA 0xAARRGGBB。
    palette: std.ArrayList(u32) = .empty,

    /// 1 layer / 1 frame（blank）の Document を作る。App 起動時の初期状態。
    pub fn init(gpa: Allocator, w: u32, h: u32) !Document {
        var doc = try initEmpty(gpa, w, h);
        errdefer doc.deinit();
        var def: LayerDef = .{ .id = doc.allocLayerId() };
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

    /// 新規 LayerId を 1 つ採番する（単調・再利用なし。0=invalid は返さない）。
    pub fn allocLayerId(self: *Document) LayerId {
        const raw = self.next_layer_id;
        self.next_layer_id += 1;
        return @enumFromInt(raw);
    }

    /// index → 安定 handle。範囲外は null。
    pub fn layerIdAt(self: *const Document, index: usize) ?LayerId {
        if (index >= self.layers.items.len) return null;
        return self.layers.items[index].id;
    }

    /// 安定 handle → 現在の index。削除済み / invalid / 不在は null。
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

    /// cel_pool の pixels を参照する（タイムラインサムネ等。TASK-45.2）。
    pub fn celPixels(self: *const Document, id: CelId) ?[]const u32 {
        if (id >= self.cel_pool.items.len) return null;
        if (self.cel_pool.items[id]) |cel| return cel.pixels;
        return null;
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

    /// 指定 frame の全 visible layer を straight-alpha 合成して `dst` へ書く（表示専用。TASK-45.3）。
    /// `selected_frame` / `active_view` / composite cache は一切変更しない。
    ///
    /// 毎フレーム全画素×レイヤ数を走るホットパス（オニオンスキン表示のみ。`onion_skin.build` 経由）。
    /// `canvas.compositeStraight` と同型の pixelops SIMD 4px ループ（cel_pool 直読み）。
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

    /// active_view の指定 layer を現 `selected_frame` の cel_pool へ全面書き戻す
    /// （`ensureCelAt` + memcpy。`created` を返す）。pushPaintOp / commitActiveLayerToCel 共用。
    fn writebackActiveLayerToCel(self: *Document, gpa: Allocator, layer_idx: usize) EnsureResult {
        const ensured = self.ensureCelAt(gpa, layer_idx, self.selected_frame);
        @memcpy(self.cel_pool.items[ensured.id].?.pixels, self.active_view.layerPixels(layer_idx));
        return ensured;
    }

    /// active_view の指定 layer を現 `selected_frame` の cel へ書き戻す（undo Op なし）。
    /// PNG open 等、Op 化しない全面置き換え用。frame は常に `selected_frame`
    /// （`resetToSingleBlankLayer` 後は 0）。text layer は呼び出し禁止（assert）。
    /// ホットパス: イベント時のみ（open/save 経路）。
    pub fn commitActiveLayerToCel(self: *Document, gpa: Allocator, layer_idx: usize) void {
        std.debug.assert(self.layers.items[layer_idx].kind != .text);
        _ = self.writebackActiveLayerToCel(gpa, layer_idx);
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
        const ensured = self.writebackActiveLayerToCel(gpa, layer_idx);
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

    /// 選択中 layer の現フレームで色 `from` を `to` に一括置換する（TASK-89）。
    /// 全一致比較・tolerance なし（ドット絵前提）。`from==to` または 0 画素は no-op（Op を積まない）。
    /// 戻り値 = 置換画素数。イベント時のみ（フレーム毎ループではない）。
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

    // ── LayerId 解決 wrapper（additive。既存 index API は不変。TASK-94 Phase A）──
    // 削除済み / invalid id は `error.UnknownLayerId`。index 系と同じ結果を返す。

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

    /// `id` の layer を index `to` へ移動する（`reorderLayer(from, to)` と同値）。
    pub fn moveLayerById(self: *Document, gpa: Allocator, id: LayerId, to: usize) !void {
        const from = self.layerIndexOf(id) orelse return error.UnknownLayerId;
        try self.reorderLayer(gpa, from, to);
    }

    pub fn deleteLayerById(self: *Document, gpa: Allocator, id: LayerId) !void {
        const index = self.layerIndexOf(id) orelse return error.UnknownLayerId;
        try self.deleteLayer(gpa, index);
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

    /// テキストレイヤーを新規追加する。**全既存 frame** に共有 cel をリンクする（4.4節。
    /// raster の addLayer とは非対称）。
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
        // POD 値コピー（text_params・名前継承）+ 新規 LayerId（複製は別 identity。TASK-94）
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
        // LayerId 採番は保持（undo handle と同様・再利用なし。TASK-94）
        var def: LayerDef = .{ .id = self.allocLayerId() };
        def.setName("Layer 1");
        self.layers.append(gpa, def) catch @panic("Document.resetToSingleBlankLayer: OOM");
        self.grid.append(gpa, null) catch @panic("Document.resetToSingleBlankLayer: OOM");
        self.selected_layer = 0;
        self.selected_frame = 0;
        self.undo.clearHistoryPreservingHandles(gpa);
    }

    // ══════════════════════════════════════════════════════════════════
    // undo/redo apply（plan 5.3節）
    // ══════════════════════════════════════════════════════════════════

    pub fn undoOne(self: *Document, gpa: Allocator) void {
        var op = self.undo.undo.pop() orelse return;
        _ = self.undo.handles.pop(); // handle/owner 並行配列を同期（redo 側はタグ対象外）
        _ = self.undo.owners.pop();
        self.applyBefore(gpa, &op);
        self.undo.redo.append(gpa, op) catch @panic("Document.undoOne: OOM");
        self.resyncActiveView(gpa);
    }

    pub fn redoOne(self: *Document, gpa: Allocator) void {
        var op = self.undo.redo.pop() orelse return;
        self.applyAfter(gpa, &op);
        self.undo.undo.append(gpa, op) catch @panic("Document.redoOne: OOM");
        // 再 push は**新 handle を採番**（旧 CommandRecord との対応は復活しない。UndoStack doc 参照）。
        self.undo.handles.append(gpa, self.undo.allocHandle()) catch @panic("Document.redoOne: OOM");
        self.undo.owners.append(gpa, 0) catch @panic("Document.redoOne: OOM"); // 再 push は unknown（app が再確定）
        self.resyncActiveView(gpa);
    }

    // ══════════════════════════════════════════════════════════════════
    // 任意位置 revert（per-actor undo。TASK-62.5.4）
    // ══════════════════════════════════════════════════════════════════

    /// handle 指定の Op を undo stack の**任意位置**から逆適用できるか（TASK-62.5.4 §3）。
    /// true の条件（すべて満たす）:
    ///   1. handle が undo stack に現存
    ///   2. Op 種別が `.paint`
    ///   3. 対象 cel が生存（`cel_pool[op.cel_id] != null`）
    ///   4. 位置前提の維持: `op.layer_idx`/`op.frame_idx` が現 document の範囲内 かつ
    ///      `grid(layer_idx, frame_idx) == op.cel_id`（created の有無によらず一律。後続の
    ///      layer/frame 操作・cel link/unlink で位置対応が崩れた op の逆適用（誤 grid slot 消去・
    ///      panic）を防ぐ。前提が崩れた op は候補外 = per-actor undo の canUndo=false → framework
    ///      の全件事前検証で transaction ごと skip される）
    ///
    /// **構造 Op 制約（MVP 割り切りの明記②）**: layer_add/delete/reorder/visible/opacity/rename/
    /// text/rasterize/merge・frame 系・cel link 系の**構造 Op は任意位置逆適用の対象外**（後続の
    /// 構造変更後に古い index へ逆適用すると別対象を壊す・cel ownership が不整合になるため）。
    /// 全 Op の任意位置 undo は rollback-replay 化（62.3 Stage 2）までスコープ外。agent の構造
    /// action（add_layer 等）は CommandRecord に記録はされるが per-actor undo の候補にならない
    /// （canUndo=false で skip。最上位の未記録構造 Op は従来の `undoOne` でのみ戻せる）。
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

    /// 読み取り専用: handle が指す `.paint` Op の `PixelDiff` 列ビュー（TASK-83.2）。
    /// 借用スライスのみ返し所有権は動かない。呼び出し側は戻り値を保持せず、確定フック内で
    /// サムネイルへコピーすること。handle 不在・構造 Op・既に undo 済みは null。
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
        /// 逆適用した Op を legacy redo stack へ移す（未記録 op の legacy redo 用）。
        move_to_redo,
        /// 逆適用した Op を解放する（CommandRecord 記録済み op 用。redo は CommandLog の
        /// name/args 再 dispatch で行うため Op は不要）。
        discard,
    };

    /// handle 指定の `.paint` Op を undo stack の**任意位置**から逆適用して取り除く（TASK-62.5.4 §3）。
    /// 成功で true。対象が `canRevertByHandle` の条件を満たさない場合は **false を返し何もしない**
    /// （非 paint Op・handle 不在・cel/位置前提の崩れ、いずれも同じ）。内部で `resyncActiveView` まで
    /// 行う（App 側同期 = `clampTimelineTarget` 等は呼び出し側の責務）。
    ///
    /// **pixel 巻き添え artifact（MVP 割り切りの明記①）**: Op は snapshot-inverse（pixel diff）
    /// なので、対象 Op より**後**に同じ画素へ描かれた内容は revert で巻き添えに戻る（diff の
    /// before 値が「対象 Op 実行直後」の画素だから）。solo Co-pilot でも netsync
    /// （62.3 v5 §1.5.1-4）と同じ MVP 割り切り（親 plan §5.1。ユーザー了承済み 2026-07-07）。
    /// 解消は rollback-replay 化（62.3 Stage 2）。実用上の緩和は actor ごとのレイヤー分担。
    /// **created cel の条件付き teardown（applyBefore と異なる点）**: LIFO 前提の `applyBefore` は
    /// created=true で cel を無条件に解放し grid を null にするが、**任意位置** revert では後続 op が
    /// 同じ cel を参照している場合にそれを行うと (a) 後続 op の描画内容ごと消える (b) 後続 op が
    /// 解放済み cel を参照し以後の undo で panic する。よって teardown は「他に参照 op が無い」
    /// 場合のみ行い、参照が残る場合は before 復元済みの cel を生かしたまま op の created を降ろす
    /// （以後その op は「既存 cel への paint」として扱われ redo 側 `applyAfter` とも整合する）。
    /// skip 時に残る blank 相当の cel は描画上透明と同一で無害（メモリ/保存サイズのみ）。
    pub fn revertByHandle(self: *Document, gpa: Allocator, handle: u64, mode: RevertMode) bool {
        if (!self.canRevertByHandle(handle)) return false;
        const idx = self.indexOfHandle(handle).?; // canRevertByHandle が現存を保証
        var op = self.undo.undo.orderedRemove(idx);
        _ = self.undo.handles.orderedRemove(idx);
        _ = self.undo.owners.orderedRemove(idx);

        const p = &op.paint; // canRevertByHandle が .paint を保証
        {
            const pixels = self.cel_pool.items[p.cel_id].?.pixels;
            for (p.diffs) |d| pixels[d.idx] = d.before;
        }
        if (p.created) {
            if (self.celReferencedByOps(p.cel_id)) {
                p.created = false; // teardown skip（doc comment 参照）
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

    /// undo/redo stack 上の op が `cel_id` への「生きた cel 参照」を持ちうるか
    /// （`revertByHandle` の created teardown 判定用）。cel snapshot/link を持つ構造 op は
    /// **保守的に true**（teardown を skip して blank cel を残す方が常に安全。誤 skip の
    /// 影響は lingering blank cel のみ）。
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

// ============================================================================
// tests（UndoStack handle タグ。TASK-62.5.3）
// ============================================================================

const testing = std.testing;

fn testVisOp(index: usize) Op {
    return .{ .layer_visible = .{ .index = index, .before = true, .after = false } };
}

test "UndoStack handles: 採番の単調性 / push→topHandle / 長さ同期の不変条件" {
    const gpa = testing.allocator;
    var s: UndoStack = .{};
    defer s.deinit(gpa);

    try testing.expectEqual(@as(?u64, null), s.topHandle());

    s.push(gpa, testVisOp(0));
    try testing.expectEqual(@as(?u64, 1), s.topHandle());
    s.push(gpa, testVisOp(1));
    try testing.expectEqual(@as(?u64, 2), s.topHandle()); // 単調増加
    try testing.expectEqual(s.undo.items.len, s.handles.items.len);
    try testing.expect(s.hasHandle(1));
    try testing.expect(s.hasHandle(2));
    try testing.expect(!s.hasHandle(3));
}

test "UndoStack handles: max_history 溢れで最古 handle も同期して消える" {
    const gpa = testing.allocator;
    var s: UndoStack = .{};
    defer s.deinit(gpa);

    var i: usize = 0;
    while (i < UndoStack.max_history + 2) : (i += 1) {
        s.push(gpa, testVisOp(i));
    }
    try testing.expectEqual(UndoStack.max_history, s.undo.items.len);
    try testing.expectEqual(s.undo.items.len, s.handles.items.len);
    try testing.expect(!s.hasHandle(1)); // 最古2件は溢れて消えた
    try testing.expect(!s.hasHandle(2));
    try testing.expect(s.hasHandle(3)); // 残存の先頭
    try testing.expectEqual(@as(?u64, UndoStack.max_history + 2), s.topHandle());
}

test "UndoStack handles: Document.undoOne の pop / redoOne の再 push は新 handle 採番" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();

    doc.undo.push(gpa, testVisOp(0));
    doc.undo.push(gpa, testVisOp(0));
    try testing.expectEqual(@as(?u64, 2), doc.undo.topHandle());

    doc.undoOne(gpa); // handle=2 の Op が pop（redo 側はタグ対象外）
    try testing.expectEqual(@as(?u64, 1), doc.undo.topHandle());
    try testing.expectEqual(doc.undo.undo.items.len, doc.undo.handles.items.len);
    try testing.expect(!doc.undo.hasHandle(2));

    doc.redoOne(gpa); // 再 push は**新 handle**（=3。2 は復活しない）
    try testing.expectEqual(@as(?u64, 3), doc.undo.topHandle());
    try testing.expectEqual(doc.undo.undo.items.len, doc.undo.handles.items.len);
    try testing.expect(!doc.undo.hasHandle(2));
}

test "UndoStack handles: リセット後も next_handle は単調（clearHistoryPreservingHandles / 再利用しない）" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();

    doc.undo.push(gpa, testVisOp(0));
    doc.undo.push(gpa, testVisOp(0));
    const before_reset = doc.undo.next_handle; // = 3
    try testing.expectEqual(@as(u64, 3), before_reset);

    // ドキュメント読込相当のリセット（doOpenPath 経由の resetToSingleBlankLayer が使う）
    doc.resetToSingleBlankLayer(gpa);
    try testing.expectEqual(@as(usize, 0), doc.undo.undo.items.len); // 履歴はクリア
    try testing.expectEqual(@as(usize, 0), doc.undo.handles.items.len);
    try testing.expectEqual(before_reset, doc.undo.next_handle); // 採番は保持

    // リセット後の push はリセット前より大きい handle（再利用しない）
    doc.undo.push(gpa, testVisOp(0));
    try testing.expectEqual(@as(?u64, 3), doc.undo.topHandle());
    try testing.expect(doc.undo.topHandle().? >= before_reset);

    // UndoStack 単体でも同様（clearHistoryPreservingHandles 直接）
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

// ── 任意位置 revert（TASK-62.5.4 §3）のテスト ──────────────────────────

fn pushTestPaint(doc: *Document, gpa: Allocator, layer_idx: usize, pixel_idx: u32, color: u32) !void {
    const pixels = doc.active_view.layerPixels(layer_idx);
    const diffs = try gpa.alloc(PixelDiff, 1);
    diffs[0] = .{ .idx = pixel_idx, .before = pixels[pixel_idx], .after = color };
    pixels[pixel_idx] = color;
    try doc.pushPaintOp(gpa, layer_idx, diffs);
}

test "paintDiffsForHandle: paint handle から diffs/layer_idx を借用取得（所有権不変）" {
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
    // 所有権不変: accessor 後も Op が undo に残り、再取得できる
    try testing.expectEqual(@as(usize, 1), doc.undo.undo.items.len);
    try testing.expect(doc.paintDiffsForHandle(h) != null);
    try testing.expectEqual(@as(usize, 1), doc.paintDiffsForHandle(h).?.diffs.len);
}

test "paintDiffsForHandle: 構造 Op / 不存在 handle は null" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();

    _ = try doc.addLayer(gpa); // handle 1（構造 op）
    try testing.expect(doc.paintDiffsForHandle(1) == null);
    try testing.expect(doc.paintDiffsForHandle(999) == null);

    try pushTestPaint(&doc, gpa, 0, 0, 0xFF00FF00); // handle 2
    try testing.expect(doc.paintDiffsForHandle(2) != null);
    try testing.expect(doc.revertByHandle(gpa, 2, .discard));
    try testing.expect(doc.paintDiffsForHandle(2) == null); // undo 済み
}

test "revertByHandle: 最上位でない .paint op を任意位置逆適用（上の op は残る・対象だけ戻る）" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();

    try pushTestPaint(&doc, gpa, 0, 0, 0xFFFF0000); // A: px0（handle 1）
    try pushTestPaint(&doc, gpa, 0, 1, 0xFF00FF00); // B: px1（handle 2）
    try testing.expect(doc.canRevertByHandle(1));

    try testing.expect(doc.revertByHandle(gpa, 1, .discard)); // A だけ任意位置 revert（discard = op 解放）
    const px = doc.active_view.layerPixels(0);
    try testing.expectEqual(@as(u32, 0), px[0]); // A は戻った
    try testing.expectEqual(@as(u32, 0xFF00FF00), px[1]); // B は残る
    try testing.expectEqual(@as(usize, 1), doc.undo.undo.items.len);
    try testing.expectEqual(@as(?u64, 2), doc.undo.topHandle());
    try testing.expect(!doc.canRevertByHandle(1)); // 取り除かれた handle は不在
}

test "revertByHandle: 構造 op は false（任意位置逆適用の対象外）/ 存在しない handle も false" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();

    _ = try doc.addLayer(gpa); // 構造 op（layer_add。handle 1）
    try testing.expect(!doc.canRevertByHandle(1));
    try testing.expect(!doc.revertByHandle(gpa, 1, .discard)); // false + 何もしない
    try testing.expectEqual(@as(usize, 1), doc.undo.undo.items.len); // op は残る
    try testing.expectEqual(@as(usize, 2), doc.layers.items.len); // layer も残る

    try testing.expect(!doc.canRevertByHandle(999)); // 存在しない handle
    try testing.expect(!doc.revertByHandle(gpa, 999, .discard));
}

test "revertByHandle: layer 削除で cel が解放された paint op は false（最終防衛）" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();

    _ = try doc.addLayer(gpa); // handle 1（構造 op）
    try pushTestPaint(&doc, gpa, 1, 0, 0xFFFF0000); // handle 2（layer1 に paint）
    try testing.expect(doc.canRevertByHandle(2));

    try doc.deleteLayer(gpa, 1); // handle 3（構造 op）。layer1 の cel は解放される
    try testing.expect(!doc.canRevertByHandle(2)); // cel 解放 + layer 範囲外 → 候補外
    try testing.expect(!doc.revertByHandle(gpa, 2, .discard));
}

test "revertByHandle: layer reorder で位置対応が崩れた paint op は false（誤 slot を消さない）" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();

    _ = try doc.addLayer(gpa); // 2 layers（handle 1）
    try pushTestPaint(&doc, gpa, 0, 0, 0xFFFF0000); // handle 2: layer0 の cel（grid(0,0)）
    try pushTestPaint(&doc, gpa, 1, 1, 0xFF00FF00); // handle 3: layer1 の cel（grid(1,0)）
    try testing.expect(doc.canRevertByHandle(2));
    try testing.expect(doc.canRevertByHandle(3));

    try doc.reorderLayer(gpa, 0, 1); // grid 行が入れ替わる → 両 op の layer_idx が旧位置を指す
    try testing.expect(!doc.canRevertByHandle(2)); // grid(0,0) != op.cel_id → 候補外
    try testing.expect(!doc.canRevertByHandle(3));
    try testing.expect(!doc.revertByHandle(gpa, 2, .discard));
}

test "revertByHandle: move_to_redo で legacy redoOne が再適用する（新 handle 採番）" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();

    try pushTestPaint(&doc, gpa, 0, 0, 0xFFFF0000); // A（handle 1）
    try pushTestPaint(&doc, gpa, 0, 1, 0xFF00FF00); // B（handle 2）

    try testing.expect(doc.revertByHandle(gpa, 1, .move_to_redo)); // A を legacy redo へ
    try testing.expectEqual(@as(u32, 0), doc.active_view.layerPixels(0)[0]);
    try testing.expectEqual(@as(usize, 1), doc.undo.redo.items.len);

    doc.redoOne(gpa); // legacy redo → A 再適用 + 新 handle（3）で undo stack へ
    try testing.expectEqual(@as(u32, 0xFFFF0000), doc.active_view.layerPixels(0)[0]);
    try testing.expectEqual(@as(usize, 2), doc.undo.undo.items.len);
    try testing.expectEqual(@as(?u64, 3), doc.undo.topHandle());
}

test "revertByHandle: created op 単独なら teardown（cel 解放 + grid null）/ 参照が残れば skip" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();

    // 単独の created op → teardown（legacy undoOne と同じ最終状態）
    try pushTestPaint(&doc, gpa, 0, 0, 0xFFFF0000); // handle 1（created=true）
    const cel_id = doc.gridGet(0, 0).?;
    try testing.expect(doc.revertByHandle(gpa, 1, .discard));
    try testing.expectEqual(@as(?CelId, null), doc.gridGet(0, 0)); // grid null
    try testing.expect(doc.cel_pool.items[cel_id] == null); // cel 解放

    // 参照が残る場合（後続 paint が同一 cel）は skip（test「最上位でない…」が実質検証済み。
    // ここでは grid が生き残ることを明示）
    try pushTestPaint(&doc, gpa, 0, 0, 0xFFFF0000); // handle 2（created=true・新 cel）
    try pushTestPaint(&doc, gpa, 0, 1, 0xFF00FF00); // handle 3（同一 cel）
    const cel2 = doc.gridGet(0, 0).?;
    try testing.expect(doc.revertByHandle(gpa, 2, .discard));
    try testing.expectEqual(@as(?CelId, cel2), doc.gridGet(0, 0)); // cel は生存
    try testing.expectEqual(@as(u32, 0xFF00FF00), doc.active_view.layerPixels(0)[1]); // 後続 op の描画は無傷
}

test "UndoStack owners: push=unknown / setOwner/ownerOf / 溢れ・undo/redo・revert 経路の同期" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();

    try pushTestPaint(&doc, gpa, 0, 0, 0xFFFF0000); // handle 1
    try pushTestPaint(&doc, gpa, 0, 1, 0xFF00FF00); // handle 2
    try testing.expectEqual(@as(u8, 0), doc.undo.ownerOf(1)); // push 直後は unknown
    doc.undo.setOwner(1, 1);
    doc.undo.setOwner(2, 2);
    try testing.expectEqual(@as(u8, 1), doc.undo.ownerOf(1));
    try testing.expectEqual(@as(u8, 2), doc.undo.ownerOf(2));
    try testing.expectEqual(@as(u8, 0), doc.undo.ownerOf(999)); // 不在は unknown
    doc.undo.setOwner(999, 1); // 不在 handle は no-op（クラッシュしない）

    // undoOne の pop で owners も同期
    doc.undoOne(gpa);
    try testing.expectEqual(doc.undo.undo.items.len, doc.undo.owners.items.len);
    try testing.expectEqual(@as(u8, 0), doc.undo.ownerOf(2)); // handle 2 は不在扱い

    // 再 push（legacy redo）は unknown で積まれる（app が再確定する規約）
    doc.redoOne(gpa); // 新 handle 3
    try testing.expectEqual(@as(u8, 0), doc.undo.ownerOf(3));
    try testing.expectEqual(doc.undo.undo.items.len, doc.undo.owners.items.len);

    // revertByHandle でも同期（任意位置除去）
    doc.undo.setOwner(1, 1);
    try testing.expect(doc.revertByHandle(gpa, 1, .discard));
    try testing.expectEqual(doc.undo.undo.items.len, doc.undo.owners.items.len);
    try testing.expectEqual(@as(u8, 0), doc.undo.ownerOf(1));
}

test "UndoStack owners: max_history 溢れで最古の owner も同期して消える" {
    const gpa = testing.allocator;
    var s: UndoStack = .{};
    defer s.deinit(gpa);

    var i: usize = 0;
    while (i < UndoStack.max_history + 1) : (i += 1) {
        s.push(gpa, testVisOp(i));
    }
    try testing.expectEqual(s.undo.items.len, s.owners.items.len);
    try testing.expectEqual(s.undo.items.len, s.handles.items.len);
    try testing.expectEqual(@as(u8, 0), s.ownerOf(1)); // 溢れた handle は不在
}

// ── LayerId 安定 handle（TASK-94 Phase A）──────────────────────────────

test "LayerId: add→move→delete→insert を跨いで id が安定・再利用なし" {
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
    try testing.expectEqual(@as(u64, 4), doc.next_layer_id); // 1,2,3 使用済み → next=4

    // move: reorderLayer(0, 2) 後も id は同じ layer を指す
    try doc.reorderLayer(gpa, 0, 2); // [id1, id2, id0]
    try testing.expectEqual(id1, doc.layerIdAt(0).?);
    try testing.expectEqual(id2, doc.layerIdAt(1).?);
    try testing.expectEqual(id0, doc.layerIdAt(2).?);
    try testing.expectEqual(@as(?usize, 2), doc.layerIndexOf(id0));
    try testing.expectEqual(@as(?usize, 0), doc.layerIndexOf(id1));
    try testing.expectEqual(@as(?usize, 1), doc.layerIndexOf(id2));

    // delete id1: 解決は null・next_layer_id は戻らない
    try doc.deleteLayerById(gpa, id1);
    try testing.expectEqual(@as(?usize, null), doc.layerIndexOf(id1));
    try testing.expectEqual(@as(u64, 4), doc.next_layer_id);
    try testing.expectEqual(@as(?usize, 0), doc.layerIndexOf(id2));
    try testing.expectEqual(@as(?usize, 1), doc.layerIndexOf(id0));

    // insert（add）: 新規 id は削除済み id1 を再利用しない
    const idx_new = try doc.addLayer(gpa);
    const id_new = doc.layerIdAt(idx_new).?;
    try testing.expect(id_new != id1);
    try testing.expectEqual(@as(LayerId, @enumFromInt(4)), id_new);
    try testing.expectEqual(@as(u64, 5), doc.next_layer_id);

    // invalid / 範囲外
    try testing.expectEqual(@as(?LayerId, null), doc.layerIdAt(99));
    try testing.expectEqual(@as(?usize, null), doc.layerIndexOf(.invalid));
}

test "LayerId ById wrapper: index 系と同一結果 / 削除済み id は UnknownLayerId" {
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
    // index 系と同値（既に false/100 なので no-op 相当。再設定で状態一致を確認）
    try doc.setLayerVisible(gpa, 2, true);
    try doc.setLayerVisibleById(gpa, id2, false);
    try testing.expectEqual(false, doc.layers.items[doc.layerIndexOf(id2).?].visible);
    try doc.setLayerOpacity(gpa, 2, 200);
    try doc.setLayerOpacityById(gpa, id2, 50);
    try testing.expectEqual(@as(u8, 50), doc.layers.items[doc.layerIndexOf(id2).?].opacity);

    // move: id0 を to=2 へ
    try doc.moveLayerById(gpa, id0, 2);
    try testing.expectEqual(id1, doc.layerIdAt(0).?);
    try testing.expectEqual(id2, doc.layerIdAt(1).?);
    try testing.expectEqual(id0, doc.layerIdAt(2).?);

    // delete
    try doc.deleteLayerById(gpa, id2);
    try testing.expectEqual(@as(?usize, null), doc.layerIndexOf(id2));
    try testing.expectEqual(@as(usize, 2), doc.layers.items.len);

    // 削除済み id → UnknownLayerId
    try testing.expectError(error.UnknownLayerId, doc.selectLayerById(id2));
    try testing.expectError(error.UnknownLayerId, doc.setLayerVisibleById(gpa, id2, true));
    try testing.expectError(error.UnknownLayerId, doc.setLayerOpacityById(gpa, id2, 1));
    try testing.expectError(error.UnknownLayerId, doc.moveLayerById(gpa, id2, 0));
    try testing.expectError(error.UnknownLayerId, doc.deleteLayerById(gpa, id2));
    try testing.expectError(error.UnknownLayerId, doc.selectLayerById(.invalid));
}

test "LayerId: duplicateLayer は新規 id / reset 後も next_layer_id は単調" {
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
    try testing.expectEqual(@as(?usize, null), doc.layerIndexOf(id0)); // 旧 id は不在
}

// ── TASK-89: pushReplaceColor ──────────────────────────────────────────

test "pushReplaceColor: 置換→undo で bit 復元 / from==to と 0 画素は no-op" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 4, 4);
    defer doc.deinit();
    const px = doc.active_view.layerPixels(0);
    const red: u32 = 0xFFFF0000;
    const blue: u32 = 0xFF0000FF;
    // 4 画素を red に
    try pushTestPaint(&doc, gpa, 0, 0, red);
    try pushTestPaint(&doc, gpa, 0, 1, red);
    try pushTestPaint(&doc, gpa, 0, 2, red);
    try pushTestPaint(&doc, gpa, 0, 3, red);
    const before = try gpa.dupe(u32, px);
    defer gpa.free(before);

    // from==to → no-op（Op を積まない）
    const depth_before = doc.undo.undo.items.len;
    const n0 = try doc.pushReplaceColor(gpa, 0, red, red);
    try testing.expectEqual(@as(u32, 0), n0);
    try testing.expectEqual(depth_before, doc.undo.undo.items.len);

    // 存在しない色 → replaced=0・no-op
    const n1 = try doc.pushReplaceColor(gpa, 0, 0xFF00FF00, blue);
    try testing.expectEqual(@as(u32, 0), n1);
    try testing.expectEqual(depth_before, doc.undo.undo.items.len);

    // 4 画素置換
    const n2 = try doc.pushReplaceColor(gpa, 0, red, blue);
    try testing.expectEqual(@as(u32, 4), n2);
    try testing.expectEqual(blue, px[0]);
    try testing.expectEqual(blue, px[3]);
    try testing.expectEqual(depth_before + 1, doc.undo.undo.items.len);

    // undo で bit 復元
    doc.undoOne(gpa);
    try testing.expectEqualSlices(u32, before, px);
}

test "pushReplaceColor: 全画素置換" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, 2, 2);
    defer doc.deinit();
    const px = doc.active_view.layerPixels(0);
    @memset(px, 0xFF112233);
    // pushPaintOp で cel にコミットしてから置換（pushReplaceColor が ensureCelAt する）
    try doc.pushPaintOp(gpa, 0, blk: {
        const d = try gpa.alloc(PixelDiff, px.len);
        for (px, 0..) |p, i| d[i] = .{ .idx = @intCast(i), .before = 0, .after = p };
        break :blk d;
    });
    const n = try doc.pushReplaceColor(gpa, 0, 0xFF112233, 0xFFAABBCC);
    try testing.expectEqual(@as(u32, 4), n);
    for (px) |p| try testing.expectEqual(@as(u32, 0xFFAABBCC), p);
}

// ── TASK-45.4: 再生 interval / advance 判定 ──────────────────────────

test "playbackIntervalSec: 100ms→1/fps / 200ms→2/fps / 50ms→0.5/fps / fps=0→inf / duration=0→1/fps" {
    // fps=10 → 1/fps = 0.1
    try testing.expectApproxEqAbs(@as(f64, 0.1), playbackIntervalSec(10.0, 100), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.2), playbackIntervalSec(10.0, 200), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.05), playbackIntervalSec(10.0, 50), 1e-12);
    try testing.expect(std.math.isInf(playbackIntervalSec(0.0, 100)));
    try testing.expect(std.math.isInf(playbackIntervalSec(-1.0, 100)));
    // duration_ms==0 は 100 扱い → 1/fps
    try testing.expectApproxEqAbs(@as(f64, 0.1), playbackIntervalSec(10.0, 0), 1e-12);
    // fps=1 で係数そのまま秒数になることも固定
    try testing.expectApproxEqAbs(@as(f64, 1.0), playbackIntervalSec(1.0, 100), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 2.0), playbackIntervalSec(1.0, 200), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.5), playbackIntervalSec(1.0, 50), 1e-12);
}

test "shouldAdvance: 追いつき無し（0.35s 経過でも 1 tick で 1 frame・残余補償なし）" {
    const interval: f64 = 0.1; // fps=10, duration=100
    try testing.expect(!shouldAdvance(0.05, 0.0, interval));
    try testing.expect(shouldAdvance(0.1, 0.0, interval));
    // 0.35 秒経過: 判定は true だが、呼び出し側が last=now にリセットするので
    // 同 tick で複数 frame は進まない（残余 0.25s の補償なし）。
    const now: f64 = 0.35;
    try testing.expect(shouldAdvance(now, 0.0, interval));
    const last_after = now; // last_advance = now（既存挙動）
    try testing.expect(!shouldAdvance(now, last_after, interval));
    // 次の advance は last_after からフル interval 必要（残余クレジットなし）。
    // f64 の 0.1 は非有限小数なので境界ちょうどではなく 0.5× / 1.5× で固定する。
    try testing.expect(!shouldAdvance(last_after + interval * 0.5, last_after, interval));
    try testing.expect(shouldAdvance(last_after + interval * 1.5, last_after, interval));
}
