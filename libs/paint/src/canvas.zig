const std = @import("std");
const Allocator = std.mem.Allocator;
const pixelops = @import("pixelops");
const bezier = @import("bezier.zig");
const text_render = @import("text_render.zig");

pub const Vec2 = struct { x: i32, y: i32 };
pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    /// 半開区間 [x, x+w) × [y, y+h) に (px,py) を含むか。
    pub fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and py >= self.y and px < self.x + self.w and py < self.y + self.h;
    }
};

/// レイヤー名の最大 byte 数（UTF-8。TASK-79.3）。固定長インラインで持つ（ownership churn 回避:
/// 可変長 owned([]u8) にすると deinit/undo(layer_add/delete/merge_down の held layer 解放)/
/// deleteLayer/allocBlankLayer の全解放経路に新規 free 追従が要るため、既存の
/// 「Layer は pixels だけを所有する POD」という不変条件を保つ固定長を選ぶ）。
pub const layer_name_max: usize = 32;

/// レイヤーの種類（TASK-79.5。TASK-72 の raster|vector 分岐と同じ器）。
/// `.text` は「TextParams から再ラスタライズしたキャッシュを pixels に保持する」レイヤー。
/// composite/compositeStraight/merge/duplicate はいずれも `pixels` のみを見るため kind
/// 非依存で無改造（vector が将来追加されても同様の器を使えば無改造で済む＝AC#4）。
pub const LayerKind = enum(u8) { raster = 0, text = 1 };

/// テキストレイヤーの内容量（UTF-8 バイト数。TASK-79.5）。`layer_name_max`（32）とは独立の定数
/// （テキスト内容はレイヤー名より長くなりうるため）。
pub const text_content_max: usize = 96;

/// テキストレイヤーのパラメータ（文字列/フォントサイズ/色/位置）。固定長 POD
/// （`Layer.name_buf` と同じ ownership churn 回避方針。可変長 owned([]u8) にしない）。
/// **不変条件（TASK-79.5 の要）**: `kind==.text` の Layer の `pixels` は常に
/// 「この TextParams を `text_render.rasterizeTextLayer` で再ラスタライズした結果と bit 一致する」
/// （Undo の `layer_text_params`/`layer_rasterize` が pixels を保持せず再ラスタライズで復元する
/// 設計の前提。この不変条件は pixie（apps/editor/apps/pixie/main.zig）側の
/// `App.selectedLayerIsText()` ガードが「text レイヤーへの直接 raster 編集」を全経路で禁止する
/// ことで維持される。Canvas 自体はこの禁止を強制しない＝既存 `editingBlocked()` と同じ
/// 「App が振る舞いを決め、Canvas は素直に従う」役割分担）。
pub const TextParams = struct {
    text_buf: [text_content_max]u8 = undefined,
    text_len: u8 = 0,
    font_px: f32 = 16.0,
    /// canonical straight BGRA 0xAARRGGBB。`font.Color` と同一ビットレイアウト（@bitCast 可）。
    color: u32 = 0xFFFFFFFF,
    x: i32 = 0,
    y: i32 = 0,

    pub fn text(self: *const TextParams) []const u8 {
        return self.text_buf[0..self.text_len];
    }

    /// text を設定する。`text_content_max` を超える分は UTF-8 継続バイトの途中で切らないように
    /// 安全に切り詰める（`Layer.setName` と同型）。
    pub fn setText(self: *TextParams, s: []const u8) void {
        const n = safeUtf8TruncateLen(s, text_content_max);
        @memcpy(self.text_buf[0..n], s[0..n]);
        self.text_len = @intCast(n);
    }

    /// 意味的等価判定。`text_buf` の未使用末尾バイトは `undefined` 初期化のため raw struct
    /// 比較（`std.meta.eql`）は使わず `text()` の中身のみ比較する（`layer_rename` が
    /// `NameSnapshot.slice()` を比較するのと同じ流儀）。`font_px` は `==` でなく bit 比較にし、
    /// NaN が万一保存されていても「値が変わったか」の判定を安定させる（IEEE754 の NaN!=NaN の
    /// 影響を受けない）。
    pub fn eql(a: TextParams, b: TextParams) bool {
        const a_px_bits: u32 = @bitCast(a.font_px);
        const b_px_bits: u32 = @bitCast(b.font_px);
        return a_px_bits == b_px_bits and a.color == b.color and a.x == b.x and a.y == b.y and
            std.mem.eql(u8, a.text(), b.text());
    }
};

pub const Layer = struct {
    pixels: []u32, // format: canonical BGRA 0xAARRGGBB (bytes [B,G,R,A] on little-endian)
    visible: bool = true,
    opacity: u8 = 255,
    /// レイヤー名（UTF-8。TASK-79.3）。実データは `name_buf[0..name_len]`。既定は空
    /// （`Canvas.init`/`allocBlankLayer` が生成直後に `setName` で既定名 "Layer N" を書き込む）。
    name_buf: [layer_name_max]u8 = undefined,
    name_len: u8 = 0,
    /// レイヤーの種類（TASK-79.5）。既定は raster。
    kind: LayerKind = .raster,
    /// `kind==.text` の時のみ意味を持つサイドカー（TextParams のドキュメント参照）。
    text_params: TextParams = .{},

    pub fn name(self: *const Layer) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    /// name を設定する。`layer_name_max` を超える分は UTF-8 継続バイトの途中で切らないように
    /// 安全に切り詰める（他 reader/将来フォーマットが保存した長い名前を読んでも不正 UTF-8 を
    /// 作らない防御）。イベント時のみ呼ばれる想定＝ホットパスではない。
    pub fn setName(self: *Layer, text: []const u8) void {
        const n = safeUtf8TruncateLen(text, layer_name_max);
        @memcpy(self.name_buf[0..n], text[0..n]);
        self.name_len = @intCast(n);
    }
};

/// text を最大 max バイトへ、UTF-8 継続バイト（0b10xxxxxx）の途中で切らないように
/// 切り詰めた長さを返す。
fn safeUtf8TruncateLen(text: []const u8, max: usize) usize {
    var n = @min(text.len, max);
    while (n > 0 and n < text.len and (text[n] & 0xC0) == 0x80) : (n -= 1) {}
    return n;
}

/// レイヤー名として外部入力（.pix の LNAM 等）を受け入れてよいか。妥当な UTF-8 かつ
/// ASCII 制御文字（0x00-0x1F / 0x7F）を含まないこと。破損 .pix が改行や不正 UTF-8 を LNAM に
/// 持たせても Layer.name に載せない（canvas probe digest の 1 行契約を壊す混入を防ぐ wire framing
/// 保護。UI 入力側は layer_rename_input が別途弾く）。不可なら呼び出し側は既定名を維持する。
/// 妥当 UTF-8 では < 0x20 のバイトは ASCII 制御文字のみ（多バイト列は全バイト >= 0x80）。
pub fn isValidLayerName(text: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(text)) return false;
    for (text) |b| {
        if (b < 0x20 or b == 0x7F) return false;
    }
    return true;
}

pub const Canvas = struct {
    layers: std.ArrayList(Layer),
    width: u32,
    height: u32,
    selected_layer: usize = 0,
    composite_cache: []u32,
    /// composite_cache の状態（TASK-53）。dirty=無効 / white_bg=composite() 結果 / straight=compositeStraight() 結果。
    /// canvas を変更する API と layerPixels()（可変 slice 貸与）が markDirty() で無効化する。
    cache_state: CacheState = .dirty,
    /// フル再合成の実行回数（テスト/計測用。静止時 0 回の性質をテストで固定する）。
    composite_runs: usize = 0,
    allocator: Allocator,
    /// 範囲選択（矩形）。null=選択なし（描画は全域に許可）。canvas 内へ clip 済みの矩形のみ保持する（TASK-44）。
    selection: ?Rect = null,
    /// 次に `allocBlankLayer` が既定名として使う連番（"Layer N"。TASK-79.3）。削除しても
    /// 巻き戻さない単調増加（Photoshop 等と同型）。.pix には永続化しない（UI の便宜のみ・
    /// 一意性は保証しない）。初期レイヤーが "Layer 1" を名乗るため既定値は 2。
    next_layer_num: u32 = 2,

    pub const CacheState = enum { dirty, white_bg, straight };

    pub fn init(gpa: Allocator, w: u32, h: u32) !Canvas {
        const size: usize = @as(usize, w) * h;
        const pixels = try gpa.alloc(u32, size);
        errdefer gpa.free(pixels);
        @memset(pixels, 0);

        const cache = try gpa.alloc(u32, size);
        errdefer gpa.free(cache);
        @memset(cache, 0xFFFFFFFF);

        // Zig 0.16: ArrayList は allocator を保持せず、.empty で初期化し各操作に渡す
        var layers: std.ArrayList(Layer) = .empty;
        errdefer layers.deinit(gpa);
        try layers.append(gpa, .{ .pixels = pixels });
        layers.items[0].setName("Layer 1");

        return .{
            .layers = layers,
            .width = w,
            .height = h,
            .composite_cache = cache,
            .allocator = gpa,
        };
    }

    pub fn deinit(self: *Canvas) void {
        for (self.layers.items) |layer| {
            self.allocator.free(layer.pixels);
        }
        self.layers.deinit(self.allocator);
        self.allocator.free(self.composite_cache);
    }

    /// composite_cache を無効化する（canvas 内容を Canvas API を通さず変更した場合に呼ぶ）。
    pub fn markDirty(self: *Canvas) void {
        self.cache_state = .dirty;
    }

    fn layerPixelCount(self: *const Canvas) usize {
        return @as(usize, self.width) * self.height;
    }

    /// 空レイヤーを確保する。既定名 "Layer {next_layer_num}" を付与して連番を+1する（TASK-79.3。
    /// counter を進めるため `*Canvas`（非 const）が要る）。
    pub fn allocBlankLayer(self: *Canvas, gpa: Allocator) !Layer {
        const pixels = try gpa.alloc(u32, self.layerPixelCount());
        @memset(pixels, 0);
        var layer: Layer = .{ .pixels = pixels };
        var name_buf: [24]u8 = undefined; // "Layer " + u32 最大10桁で十分な余裕
        const default_name = std.fmt.bufPrint(&name_buf, "Layer {d}", .{self.next_layer_num}) catch "Layer";
        layer.setName(default_name);
        self.next_layer_num += 1;
        return layer;
    }

    pub fn addLayer(self: *Canvas, gpa: Allocator) !usize {
        const idx = self.layers.items.len;
        const layer = try self.allocBlankLayer(gpa);
        errdefer gpa.free(layer.pixels);
        try self.insertLayer(gpa, idx, layer);
        return idx;
    }

    pub fn insertLayer(self: *Canvas, gpa: Allocator, index: usize, layer: Layer) !void {
        if (index > self.layers.items.len) return error.InvalidLayer;
        if (layer.pixels.len != self.layerPixelCount()) return error.InvalidLayer;
        try self.layers.insert(gpa, index, layer);
        self.selected_layer = index;
        self.markDirty();
    }

    pub fn deleteLayer(self: *Canvas, index: usize) ?Layer {
        if (self.layers.items.len <= 1 or index >= self.layers.items.len) return null;
        const removed = self.layers.orderedRemove(index);
        if (self.selected_layer == index) {
            self.selected_layer = @min(index, self.layers.items.len - 1);
        } else if (self.selected_layer > index) {
            self.selected_layer -= 1;
        }
        self.markDirty();
        return removed;
    }

    pub fn moveLayer(self: *Canvas, from: usize, to: usize) bool {
        if (from >= self.layers.items.len or to >= self.layers.items.len) return false;
        if (from == to) {
            self.selected_layer = to;
            return true;
        }
        const moved = self.layers.orderedRemove(from);
        self.layers.insert(self.allocator, to, moved) catch @panic("Canvas.moveLayer: OOM");
        self.selected_layer = to;
        self.markDirty();
        return true;
    }

    pub fn selectLayer(self: *Canvas, index: usize) bool {
        if (index >= self.layers.items.len) return false;
        self.selected_layer = index;
        return true;
    }

    pub fn setLayerVisible(self: *Canvas, index: usize, visible: bool) bool {
        if (index >= self.layers.items.len) return false;
        self.layers.items[index].visible = visible;
        self.markDirty();
        return true;
    }

    pub fn setLayerOpacity(self: *Canvas, index: usize, opacity: u8) bool {
        if (index >= self.layers.items.len) return false;
        self.layers.items[index].opacity = opacity;
        self.markDirty();
        return true;
    }

    /// レイヤー名を設定する（TASK-79.3）。visible/opacity と異なり composite() の結果に
    /// 影響しないため markDirty() は呼ばない（cache 無効化は合成結果へ影響する変更のみに
    /// 限定する既存規約。TASK-53）。
    pub fn setLayerName(self: *Canvas, index: usize, text: []const u8) bool {
        if (index >= self.layers.items.len) return false;
        self.layers.items[index].setName(text);
        return true;
    }

    // ── テキストレイヤー（TASK-79.5）───────────────────────────

    /// テキストレイヤーを新規追加する。`allocBlankLayer` で確保した空レイヤーを text kind 化し、
    /// `params` でラスタライズしてから挿入する（既存 `insertLayer` の markDirty 経路に乗る）。
    /// イベント時のみ（レイヤー追加操作の都度1回）。
    pub fn addTextLayer(self: *Canvas, gpa: Allocator, params: TextParams) !usize {
        var layer = try self.allocBlankLayer(gpa);
        errdefer gpa.free(layer.pixels);
        layer.kind = .text;
        layer.text_params = params;
        try text_render.rasterizeTextLayer(
            self.allocator,
            layer.pixels,
            self.width,
            self.height,
            layer.text_params.text(),
            layer.text_params.font_px,
            layer.text_params.color,
            layer.text_params.x,
            layer.text_params.y,
        );
        const idx = self.layers.items.len;
        try self.insertLayer(gpa, idx, layer);
        return idx;
    }

    /// 既存テキストレイヤーの text_params を更新し pixels を再ラスタライズする（TASK-79.5）。
    /// `kind!=.text` は `error.NotTextLayer`。pixels が変わるため `markDirty()` は必須
    /// （`setLayerName` と異なり合成結果に影響する）。イベント時のみ（内容/サイズ/色/位置の
    /// 編集確定の都度1回）。
    pub fn setLayerTextParams(self: *Canvas, index: usize, params: TextParams) !void {
        if (index >= self.layers.items.len) return error.OutOfRange;
        if (self.layers.items[index].kind != .text) return error.NotTextLayer;
        self.layers.items[index].text_params = params;
        const layer = &self.layers.items[index];
        try text_render.rasterizeTextLayer(
            self.allocator,
            layer.pixels,
            self.width,
            self.height,
            layer.text_params.text(),
            layer.text_params.font_px,
            layer.text_params.color,
            layer.text_params.x,
            layer.text_params.y,
        );
        self.markDirty();
    }

    /// テキストレイヤーを通常 raster レイヤーへ確定する（Rasterize/bake。TASK-79.5）。
    /// `kind!=.text` は `error.NotTextLayer`。pixels は不変（不変条件により既に最新の
    /// ラスタライズ結果）なので**再ラスタライズも markDirty も不要**（`setLayerName` と同じ
    /// 「合成結果に影響しない変更は cache 無効化しない」規約。TASK-53）。呼び出し前の
    /// text_params を返す（呼び出し側=App が Undo `.layer_rasterize` へ積む用）。
    pub fn rasterizeLayer(self: *Canvas, index: usize) !TextParams {
        if (index >= self.layers.items.len) return error.OutOfRange;
        if (self.layers.items[index].kind != .text) return error.NotTextLayer;
        const before = self.layers.items[index].text_params;
        self.layers.items[index].kind = .raster;
        self.layers.items[index].text_params = .{};
        return before;
    }

    /// pixels に触れず kind/text_params だけを直接設定する低レベル setter
    /// （`rasterizeLayer` の Undo/Redo 専用。redo は `kind=.raster, params=.{}` の決定的値を
    /// 渡すだけで済むため pixels スナップショットが要らない）。
    pub fn setLayerKindText(self: *Canvas, index: usize, kind: LayerKind, params: TextParams) bool {
        if (index >= self.layers.items.len) return false;
        self.layers.items[index].kind = kind;
        self.layers.items[index].text_params = params;
        return true;
    }

    /// 白背景に各 visible layer を実 src-over する合成。プレビューなど不透明背景向け。
    /// layer.opacity を src alpha に乗算してから合成。a=255 は元色・a=0 は背景維持（RGB 非ゼロでも）・
    /// visible=false はスキップ。partial-alpha（ソフトブラシ）は白地へ正しくブレンドされる。
    ///
    /// 毎フレーム全画素×レイヤ数を走るホットパス（pixie main loop / canvas probe）。
    /// dst は白不透明で始まり srcOverOpaque が out_a=255 を維持するため常に不透明。
    /// pixelops の整数 SIMD（scaleAlpha4 + srcOverOpaque4）で 4px 同時処理し、
    /// 旧 scalar 実装（srcOver+scaleAlpha per-pixel）と bit 一致（テストで固定。TASK-52）。
    /// canvas 無変更なら前回結果（composite_cache）を返し再合成しない（TASK-53）。
    pub fn composite(self: *Canvas) []const u32 {
        if (self.cache_state == .white_bg) return self.composite_cache;
        self.composite_runs += 1;
        @memset(self.composite_cache, 0xFFFFFFFF); // white opaque background
        for (self.layers.items) |layer| {
            if (!layer.visible) continue;
            const op = layer.opacity; // ループ外 latch
            const n = self.composite_cache.len;
            var i: usize = 0;
            while (i + 4 <= n) : (i += 4) {
                const src_chunk: *const [4]u32 = layer.pixels[i..][0..4];
                const dst_chunk: *[4]u32 = self.composite_cache[i..][0..4];
                var sv: pixelops.Vec16u8 = @bitCast(src_chunk.*);
                if (op != 255) sv = pixelops.scaleAlpha4(sv, op); // scaleAlpha(c,255)==c なので省略可
                const dv: pixelops.Vec16u8 = @bitCast(dst_chunk.*);
                dst_chunk.* = @bitCast(pixelops.srcOverOpaque4(dv, sv));
            }
            // scalar tail（0..3 px）
            while (i < n) : (i += 1) {
                const s = if (op != 255) pixelops.scaleAlpha(layer.pixels[i], op) else layer.pixels[i];
                self.composite_cache[i] = pixelops.srcOverOpaque(self.composite_cache[i], s);
            }
        }
        self.cache_state = .white_bg;
        return self.composite_cache;
    }

    /// アルファ保持合成（透明背景に各 visible layer を実 src-over）。チェッカー背景への重ね描きやフラット PNG 保存向け。
    /// composite() と違い背景を白で埋めない（完全透明部は a=0 のまま残る）。
    /// 戻りは straight-alpha BGRA。blit 側では背景（チェッカー）へ src-over する前提。
    ///
    /// 毎フレーム全画素×レイヤ数を走るホットパス（pixie main loop / canvas probe）。
    /// dst alpha が可変なため pixelops の f32 SIMD（srcOverStraight4）で 4px 同時処理する
    /// （丸めは旧整数式から僅かに変わりうる。scalar 参照との bit 一致はテストで固定。TASK-52）。
    /// 不変条件: 単層 opacity=255 は raw pixels と恒等（a=0 ⇒ RGB=0 の cache 不変条件下）。
    /// canvas 無変更なら前回結果（composite_cache）を返し再合成しない（TASK-53）。
    pub fn compositeStraight(self: *Canvas) []const u32 {
        if (self.cache_state == .straight) return self.composite_cache;
        self.composite_runs += 1;
        @memset(self.composite_cache, 0x00000000); // transparent background
        for (self.layers.items) |layer| {
            if (!layer.visible) continue;
            const op = layer.opacity; // ループ外 latch
            const n = self.composite_cache.len;
            var i: usize = 0;
            while (i + 4 <= n) : (i += 4) {
                const s4: [4]u32 = layer.pixels[i..][0..4].*;
                // fast path: 4px 全て src a==0 → dst 不変（sa=0 → 結果=dst が正確なので bit 影響なし）
                if ((s4[0] | s4[1] | s4[2] | s4[3]) & 0xFF000000 == 0) continue;
                const dst_chunk: *[4]u32 = self.composite_cache[i..][0..4];
                dst_chunk.* = @bitCast(pixelops.srcOverStraight4(@bitCast(dst_chunk.*), @bitCast(s4), op));
            }
            // scalar tail（0..3 px）
            while (i < n) : (i += 1) {
                const s = layer.pixels[i];
                if (s & 0xFF000000 == 0) continue;
                self.composite_cache[i] = pixelops.srcOverStraightScalar(self.composite_cache[i], s, op);
            }
        }
        self.cache_state = .straight;
        return self.composite_cache;
    }

    pub fn clear(self: *Canvas) void {
        for (self.layers.items) |layer| {
            @memset(layer.pixels, 0);
        }
        self.selection = null;
        self.markDirty();
    }

    /// 範囲選択を設定する（rect は呼び出し側が canvas 内へ clip 済みとする）。null で解除。
    pub fn setSelection(self: *Canvas, rect: ?Rect) void {
        self.selection = rect;
    }

    /// 範囲選択を解除する。
    pub fn clearSelection(self: *Canvas) void {
        self.selection = null;
    }

    /// レイヤのピクセル配列への直接アクセス（read/write プリミティブ）。
    /// stroke 記録（before 観測）や PNG 保存（raw 取得）はここを使う。
    /// 可変 slice を貸与するため保守的に cache を無効化する（読み取り用途でも dirty になるが、
    /// 呼び出しは全てイベント時のみ＝代償はイベント時の過剰再合成 1 回に限定される。TASK-53）。
    pub fn layerPixels(self: *Canvas, layer_idx: usize) []u32 {
        self.markDirty();
        return self.layers.items[layer_idx].pixels;
    }

    pub fn drawPixel(self: *Canvas, layer_idx: usize, x: i32, y: i32, color: u32) void {
        if (layer_idx >= self.layers.items.len) return;
        if (x < 0 or y < 0) return;
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        if (ux >= self.width or uy >= self.height) return;
        if (self.selection) |sel| if (!sel.contains(x, y)) return; // 選択範囲外は描かない（null=制約なし）
        self.layers.items[layer_idx].pixels[uy * self.width + ux] = color;
        self.markDirty();
    }
};

/// window 座標 → canvas 座標変換。canvas 表示領域外なら null を返す。
pub fn screenToCanvas(screen_pos: Vec2, canvas_rect: Rect, zoom: i32) ?Vec2 {
    const rx = screen_pos.x - canvas_rect.x;
    const ry = screen_pos.y - canvas_rect.y;
    if (rx < 0 or ry < 0) return null;
    const cx = @divFloor(rx, zoom);
    const cy = @divFloor(ry, zoom);
    if (cx < 0 or cy < 0 or cx >= canvas_rect.w or cy >= canvas_rect.h) return null;
    return .{ .x = cx, .y = cy };
}

/// window 座標 → canvas 座標の生変換（境界 clamp なし）。canvas 外でも線形に変換する。
/// stroke の capture 継続（canvas 外へのドラッグ）用。範囲 clip は描画側で行う。
pub fn screenToCanvasRaw(screen_pos: Vec2, canvas_rect: Rect, zoom: i32) Vec2 {
    return .{
        .x = @divFloor(screen_pos.x - canvas_rect.x, zoom),
        .y = @divFloor(screen_pos.y - canvas_rect.y, zoom),
    };
}

/// window 座標 → canvas 論理座標（f32, clamp なし）。ベジェ等の連続座標編集用。
pub fn screenToCanvasF(screen_pos: Vec2, canvas_rect: Rect, zoom: i32) bezier.Vec2f {
    const z: f32 = @floatFromInt(zoom);
    return .{
        .x = @as(f32, @floatFromInt(screen_pos.x - canvas_rect.x)) / z,
        .y = @as(f32, @floatFromInt(screen_pos.y - canvas_rect.y)) / z,
    };
}

test "Canvas init/deinit" {
    const allocator = std.testing.allocator;
    var canvas = try Canvas.init(allocator, 4, 4);
    defer canvas.deinit();
    try std.testing.expectEqual(@as(u32, 4), canvas.width);
    try std.testing.expectEqual(@as(u32, 4), canvas.height);
    try std.testing.expectEqual(@as(usize, 1), canvas.layers.items.len);
    try std.testing.expectEqual(@as(usize, 0), canvas.selected_layer);
}

test "Canvas layer operations keep selected_layer in range" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 2, 2);
    defer c.deinit();

    const l1 = try c.addLayer(gpa);
    try std.testing.expectEqual(@as(usize, 1), l1);
    try std.testing.expectEqual(@as(usize, 2), c.layers.items.len);
    try std.testing.expectEqual(@as(usize, 1), c.selected_layer);

    const l2 = try c.addLayer(gpa);
    try std.testing.expectEqual(@as(usize, 2), l2);
    c.layerPixels(2)[0] = 0xFFFF0000;
    try std.testing.expect(c.moveLayer(2, 0));
    try std.testing.expectEqual(@as(usize, 0), c.selected_layer);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), c.layerPixels(0)[0]);

    const removed = c.deleteLayer(0).?;
    defer gpa.free(removed.pixels);
    try std.testing.expectEqual(@as(usize, 2), c.layers.items.len);
    try std.testing.expectEqual(@as(usize, 0), c.selected_layer);

    const removed2 = c.deleteLayer(1).?;
    gpa.free(removed2.pixels);
    try std.testing.expectEqual(@as(usize, 1), c.layers.items.len);
    try std.testing.expect(c.deleteLayer(0) == null);
    try std.testing.expectEqual(@as(usize, 0), c.selected_layer);
}

test "Canvas drawPixel bounds check" {
    const allocator = std.testing.allocator;
    var canvas = try Canvas.init(allocator, 4, 4);
    defer canvas.deinit();
    canvas.drawPixel(0, 0, 0, 0xFF000000);
    try std.testing.expectEqual(@as(u32, 0xFF000000), canvas.layers.items[0].pixels[0]);
    canvas.drawPixel(0, -1, 0, 0xFF0000FF); // out of bounds, no crash
    canvas.drawPixel(0, 4, 0, 0xFF0000FF); // out of bounds, no crash
}

test "Canvas drawPixel respects selection (null=制約なし / 範囲外は描かない)" {
    const gpa = std.testing.allocator;
    var canvas = try Canvas.init(gpa, 4, 4);
    defer canvas.deinit();
    const RED: u32 = 0xFFFF0000;

    // 選択 [1,3)×[1,3) を設定
    canvas.setSelection(.{ .x = 1, .y = 1, .w = 2, .h = 2 });
    canvas.drawPixel(0, 0, 0, RED); // 範囲外 → 無視
    canvas.drawPixel(0, 1, 1, RED); // 範囲内 → 描画
    canvas.drawPixel(0, 2, 2, RED); // 範囲内（右下端の直前）→ 描画
    canvas.drawPixel(0, 3, 3, RED); // 範囲外（半開区間で 3 は外）→ 無視
    const px = canvas.layerPixels(0);
    try std.testing.expectEqual(@as(u32, 0), px[0 * 4 + 0]);
    try std.testing.expectEqual(RED, px[1 * 4 + 1]);
    try std.testing.expectEqual(RED, px[2 * 4 + 2]);
    try std.testing.expectEqual(@as(u32, 0), px[3 * 4 + 3]);

    // 解除すると全域に描ける
    canvas.clearSelection();
    canvas.drawPixel(0, 0, 0, RED);
    try std.testing.expectEqual(RED, px[0]);
}

test "Rect.contains: 半開区間" {
    const r = Rect{ .x = 2, .y = 3, .w = 4, .h = 5 };
    try std.testing.expect(r.contains(2, 3));
    try std.testing.expect(r.contains(5, 7)); // x+w-1, y+h-1
    try std.testing.expect(!r.contains(6, 7)); // x+w は外
    try std.testing.expect(!r.contains(5, 8)); // y+h は外
    try std.testing.expect(!r.contains(1, 3));
}

test "Canvas clear" {
    const allocator = std.testing.allocator;
    var canvas = try Canvas.init(allocator, 4, 4);
    defer canvas.deinit();
    canvas.drawPixel(0, 1, 1, 0xFF000000);
    canvas.clear();
    for (canvas.layers.items[0].pixels) |p| {
        try std.testing.expectEqual(@as(u32, 0), p);
    }
}

test "screenToCanvas" {
    const rect = Rect{ .x = 64, .y = 32, .w = 256, .h = 256 };
    const zoom: i32 = 2;
    try std.testing.expectEqual(Vec2{ .x = 0, .y = 0 }, screenToCanvas(.{ .x = 64, .y = 32 }, rect, zoom).?);
    try std.testing.expectEqual(Vec2{ .x = 1, .y = 0 }, screenToCanvas(.{ .x = 66, .y = 32 }, rect, zoom).?);
    try std.testing.expect(screenToCanvas(.{ .x = 63, .y = 32 }, rect, zoom) == null);
    try std.testing.expect(screenToCanvas(.{ .x = 64 + 512, .y = 32 }, rect, zoom) == null);
}

test "screenToCanvasRaw: 境界外でも線形に変換する（clamp なし）" {
    const rect = Rect{ .x = 64, .y = 32, .w = 256, .h = 256 };
    const zoom: i32 = 2;
    // 領域内は screenToCanvas と一致
    try std.testing.expectEqual(Vec2{ .x = 1, .y = 0 }, screenToCanvasRaw(.{ .x = 66, .y = 32 }, rect, zoom));
    // 左上の外: 負座標になる（@divFloor で -1 方向に丸め）
    try std.testing.expectEqual(Vec2{ .x = -1, .y = -1 }, screenToCanvasRaw(.{ .x = 63, .y = 31 }, rect, zoom));
    // 右下の外: 幅を超える座標になる
    try std.testing.expectEqual(Vec2{ .x = 256, .y = 0 }, screenToCanvasRaw(.{ .x = 64 + 512, .y = 32 }, rect, zoom));
}

test "composite: a=255 元色 / a=0(RGB非ゼロ) 背景維持 / partial は白地ブレンド" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 3, 1);
    defer c.deinit();
    const px = c.layerPixels(0);
    px[0] = 0xFF0000FF; // 不透明青
    px[1] = 0x00FFFFFF; // a=0 だが RGB 非ゼロ → 背景(白)維持
    px[2] = 0x800000FF; // 半透明青（a=128）→ 白地に約半分

    const out = c.composite();
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), out[0]); // 元色
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), out[1]); // 白維持
    try std.testing.expectEqual(@as(u32, 0xFF), (out[2] >> 24) & 0xFF); // 不透明
    // B は 255、G/R は白(255)と青(0)の中間 ≈ 127
    try std.testing.expectEqual(@as(u32, 0xFF), out[2] & 0xFF); // B=255
    const g = (out[2] >> 8) & 0xFF;
    try std.testing.expect(g > 120 and g < 135);
}

test "composite: visible=false はスキップ / opacity が効く" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 1, 1);
    defer c.deinit();
    c.layerPixels(0)[0] = 0xFF0000FF; // 不透明青
    _ = c.setLayerVisible(0, false);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), c.composite()[0]); // スキップ → 白

    _ = c.setLayerVisible(0, true);
    _ = c.setLayerOpacity(0, 128); // 不透明青 × opacity 128 → 白地に約半分
    const out = c.composite()[0];
    try std.testing.expectEqual(@as(u32, 0xFF), out & 0xFF); // B=255
    const g = (out >> 8) & 0xFF;
    try std.testing.expect(g > 120 and g < 135);
}

test "composite: 2 層 src-over（下層→上層順）" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 1, 1);
    defer c.deinit();
    c.layerPixels(0)[0] = 0xFF0000FF; // 下層: 不透明青
    // 上層を追加（不透明赤で覆う）
    const top = try gpa.alloc(u32, 1);
    top[0] = 0xFFFF0000; // 0xAARRGGBB: a=FF, r=FF（赤）
    try c.insertLayer(gpa, 1, .{ .pixels = top });

    const out = c.composite()[0];
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), out); // 上層(赤)が下層(青)を覆う
}

test "compositeStraight: 全透明は a=0 維持 / 不透明は元色 / 半透明は out_a を保持" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 3, 1);
    defer c.deinit();
    const px = c.layerPixels(0);
    px[0] = 0xFF0000FF; // 不透明青
    px[1] = 0x00000000; // 完全透明
    px[2] = 0x800000FF; // 半透明青（a=128）

    const out = c.compositeStraight();
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), out[0]); // 不透明は元色
    try std.testing.expectEqual(@as(u32, 0x00000000), out[1]); // 透明は a=0 維持（白で埋めない）
    try std.testing.expectEqual(@as(u32, 128), (out[2] >> 24) & 0xFF); // 半透明の out_a を保持
    try std.testing.expectEqual(@as(u32, 0xFF), out[2] & 0xFF); // B=255
}

/// テスト用: 乱数レイヤ内容を充填する（a=0 の画素は RGB=0 に正規化 = cache 不変条件と同じ）。
fn fillRandomLayers(c: *Canvas, seed: u64, opacities: []const u8) void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    for (c.layers.items, 0..) |layer, li| {
        for (layer.pixels) |*p| {
            const a = rng.int(u8);
            p.* = if (a == 0) 0 else (@as(u32, a) << 24) | (rng.int(u32) & 0x00FFFFFF);
        }
        _ = c.setLayerOpacity(li, opacities[li % opacities.len]);
    }
}

test "composite: SIMD 経路が旧 scalar 実装と bit 一致（乱数多層 + opacity 混在）" {
    const gpa = std.testing.allocator;
    // 7x5=35px（チャンク 8 個 + tail 3px）× 3 層。opacity は 255/200/128 を混在。
    var c = try Canvas.init(gpa, 7, 5);
    defer c.deinit();
    _ = try c.addLayer(gpa);
    _ = try c.addLayer(gpa);
    fillRandomLayers(&c, 0xC0117051, &.{ 255, 200, 128 });
    _ = c.setLayerVisible(1, false); // visible スキップ経路も混ぜる

    // 旧アルゴリズム（scalar srcOver + scaleAlpha per-pixel）の参照実装
    const ref = try gpa.alloc(u32, 35);
    defer gpa.free(ref);
    @memset(ref, 0xFFFFFFFF);
    const pix = @import("pixelops");
    for (c.layers.items) |layer| {
        if (!layer.visible) continue;
        for (layer.pixels, ref) |src, *dst| {
            dst.* = pix.srcOver(dst.*, pix.scaleAlpha(src, layer.opacity));
        }
    }

    try std.testing.expectEqualSlices(u32, ref, c.composite());
}

test "compositeStraight: SIMD 経路が srcOverStraightScalar の参照ループと bit 一致（乱数多層）" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 7, 5);
    defer c.deinit();
    _ = try c.addLayer(gpa);
    _ = try c.addLayer(gpa);
    fillRandomLayers(&c, 0x57A167A1, &.{ 200, 255, 128 });

    const ref = try gpa.alloc(u32, 35);
    defer gpa.free(ref);
    @memset(ref, 0x00000000);
    const pix = @import("pixelops");
    for (c.layers.items) |layer| {
        if (!layer.visible) continue;
        for (layer.pixels, ref) |src, *dst| {
            dst.* = pix.srcOverStraightScalar(dst.*, src, layer.opacity);
        }
    }

    try std.testing.expectEqualSlices(u32, ref, c.compositeStraight());
}

test "compositeStraight: 単層 opacity=255 は raw pixels と恒等（AC3。a=0..255 全域 + tail）" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 37, 7); // 259px（チャンク 64 + tail 3）
    defer c.deinit();
    // 先頭 256px に a=0..255 を明示的に 1 回ずつ（a=0 は RGB=0 の cache 不変条件に正規化）、
    // 残り 3px（tail）は乱数
    var prng = std.Random.DefaultPrng.init(0x1DE47177);
    const rng = prng.random();
    const px = c.layerPixels(0);
    for (px[0..256], 0..) |*p, a| {
        p.* = if (a == 0) 0 else (@as(u32, @intCast(a)) << 24) | (rng.int(u32) & 0x00FFFFFF);
    }
    for (px[256..]) |*p| {
        const a = rng.intRangeAtMost(u8, 1, 255);
        p.* = (@as(u32, a) << 24) | (rng.int(u32) & 0x00FFFFFF);
    }
    try std.testing.expectEqualSlices(u32, c.layerPixels(0), c.compositeStraight());
}

test "compositeStraight: visible=false スキップ / 2 層は上が下を src-over してアルファ保持" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 1, 1);
    defer c.deinit();
    c.layerPixels(0)[0] = 0xFF0000FF; // 下層: 不透明青
    _ = c.setLayerVisible(0, false);
    try std.testing.expectEqual(@as(u32, 0x00000000), c.compositeStraight()[0]); // スキップ → 透明維持

    _ = c.setLayerVisible(0, true);
    const top = try gpa.alloc(u32, 1);
    top[0] = 0x80FF0000; // 上層: 半透明赤（a=128）
    try c.insertLayer(gpa, 1, .{ .pixels = top });
    const out = c.compositeStraight()[0];
    try std.testing.expectEqual(@as(u32, 0xFF), (out >> 24) & 0xFF); // 下層不透明 → out_a=255
    const r = (out >> 16) & 0xFF;
    const b = out & 0xFF;
    try std.testing.expect(r > 120 and r < 135); // 赤が約半分
    try std.testing.expect(b > 120 and b < 135); // 青が約半分
}

test "composite cache: 無変更なら再合成しない（counter で固定。TASK-53）" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 4, 4);
    defer c.deinit();
    c.drawPixel(0, 1, 1, 0xFF112233);

    _ = c.compositeStraight();
    try std.testing.expectEqual(@as(usize, 1), c.composite_runs);
    _ = c.compositeStraight(); // 無変更 → キャッシュ再利用
    _ = c.compositeStraight();
    try std.testing.expectEqual(@as(usize, 1), c.composite_runs);

    // モード切替は再合成（cache 共有のため）
    _ = c.composite();
    try std.testing.expectEqual(@as(usize, 2), c.composite_runs);
    _ = c.compositeStraight();
    try std.testing.expectEqual(@as(usize, 3), c.composite_runs);

    // 変更 → 再合成 + 結果が追従（stale cache を返さない）
    c.drawPixel(0, 2, 2, 0xFFAABBCC);
    const out = c.compositeStraight();
    try std.testing.expectEqual(@as(usize, 4), c.composite_runs);
    try std.testing.expectEqual(@as(u32, 0xFFAABBCC), out[2 * 4 + 2]);
}

test "composite cache: 全ての変更 API が cache を無効化する（TASK-53）" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 4, 4);
    defer c.deinit();
    _ = try c.addLayer(gpa); // 2 層で開始（deleteLayer 用）

    // 各操作の後に compositeStraight が再合成される（composite_runs が増える）ことを確認する。
    // 操作は enum で列挙し、漏れなく踏む。
    const Op = enum {
        draw_pixel,
        layer_pixels,
        clear,
        add_layer,
        insert_layer,
        delete_layer,
        move_layer,
        set_visible,
        set_opacity,
        add_text_layer,
        set_text_params,
    };
    inline for (std.meta.fields(Op)) |f| {
        const op: Op = @enumFromInt(f.value);
        _ = c.compositeStraight(); // cache を有効化
        const runs_before = c.composite_runs;
        switch (op) {
            .draw_pixel => c.drawPixel(0, 0, 0, 0xFF010203),
            .layer_pixels => c.layerPixels(0)[1] = 0xFF040506,
            .clear => c.clear(),
            .add_layer => _ = try c.addLayer(gpa),
            .insert_layer => try c.insertLayer(gpa, 0, try c.allocBlankLayer(gpa)),
            .delete_layer => {
                const removed = c.deleteLayer(c.layers.items.len - 1).?;
                gpa.free(removed.pixels);
            },
            .move_layer => _ = c.moveLayer(0, c.layers.items.len - 1),
            .set_visible => _ = c.setLayerVisible(0, false),
            .set_opacity => _ = c.setLayerOpacity(0, 200),
            .add_text_layer => _ = try c.addTextLayer(gpa, .{}), // 末尾に text layer を追加（enum 順序: 直後の set_text_params が同レイヤーを想定）
            .set_text_params => {
                var p: TextParams = .{};
                p.setText("hi");
                try c.setLayerTextParams(c.layers.items.len - 1, p);
            },
        }
        _ = c.compositeStraight();
        std.testing.expectEqual(runs_before + 1, c.composite_runs) catch |err| {
            std.debug.print("op '{s}' did not invalidate cache\n", .{f.name});
            return err;
        };
    }

    // 合成結果に影響しない操作は無効化しない（TASK-79.3: setLayerName / TASK-79.5: rasterizeLayer も追加）。
    // 直前のループの末尾 op が add_text_layer→set_text_params の順だったため、末尾レイヤーは
    // 現在 kind==.text（TextParams.text()=="hi"）。
    _ = c.compositeStraight();
    const runs = c.composite_runs;
    _ = c.selectLayer(0);
    c.setSelection(.{ .x = 0, .y = 0, .w = 2, .h = 2 });
    c.clearSelection();
    _ = c.setLayerName(0, "Background");
    const text_idx = c.layers.items.len - 1;
    try std.testing.expectEqual(LayerKind.text, c.layers.items[text_idx].kind);
    _ = try c.rasterizeLayer(text_idx); // pixels 不変・kind=raster 化のみ → cache 無効化しない
    _ = c.compositeStraight();
    try std.testing.expectEqual(runs, c.composite_runs);
    try std.testing.expectEqual(LayerKind.raster, c.layers.items[text_idx].kind);
}

// ── レイヤー名（TASK-79.3）─────────────────────────────────

test "Layer name: 既定名は Layer 1/2/3.. と単調増加し、削除しても巻き戻らない" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 2, 2);
    defer c.deinit();
    try std.testing.expectEqualStrings("Layer 1", c.layers.items[0].name());

    const idx1 = try c.addLayer(gpa);
    try std.testing.expectEqualStrings("Layer 2", c.layers.items[idx1].name());
    const idx2 = try c.addLayer(gpa);
    try std.testing.expectEqualStrings("Layer 3", c.layers.items[idx2].name());

    // 削除しても連番は巻き戻らない（次の追加は Layer 4）
    const removed = c.deleteLayer(idx2).?;
    gpa.free(removed.pixels);
    const idx3 = try c.addLayer(gpa);
    try std.testing.expectEqualStrings("Layer 4", c.layers.items[idx3].name());
}

test "Layer name: setLayerName/setName は境界を跨いだ UTF-8 continuation byte で切らない" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 1, 1);
    defer c.deinit();

    _ = c.setLayerName(0, "Background");
    try std.testing.expectEqualStrings("Background", c.layers.items[0].name());

    // layer_name_max(32) を超える長い名前は切り詰められる（かつ不正 UTF-8 を作らない）
    const long_ascii = "A" ** 40;
    _ = c.setLayerName(0, long_ascii);
    try std.testing.expectEqual(@as(usize, layer_name_max), c.layers.items[0].name().len);

    // マルチバイト文字（3B/文字の "あ"）を境界ぎりぎりで切り詰めても壊れた UTF-8 を作らない。
    // "あ" を 11 回（33 バイト）→ layer_name_max(32) に収まるのは 10 個(30B)まで。
    const multibyte = "あ" ** 11;
    _ = c.setLayerName(0, multibyte);
    const got = c.layers.items[0].name();
    try std.testing.expect(got.len <= layer_name_max);
    try std.testing.expect(std.unicode.utf8ValidateSlice(got));
    try std.testing.expectEqualStrings("あ" ** 10, got); // 30B（32 に収まる最大個数）

    try std.testing.expect(!c.setLayerName(5, "OOB")); // 範囲外は false
}

test "Layer name: resetCanvasToSingleLayer 相当のシナリオでも Canvas.init は Layer 1 を付与する" {
    // resetCanvasToSingleLayer (pixie main.zig) は既存 layer0 を再利用するため、
    // 呼び出し側が明示的に setLayerName("Layer 1") + next_layer_num リセットを行う契約
    // （このテストは Canvas.init 自体の既定名付与を再確認する）。
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 4, 4);
    defer c.deinit();
    try std.testing.expectEqualStrings("Layer 1", c.layers.items[0].name());
    try std.testing.expectEqual(@as(u32, 2), c.next_layer_num);
}

// ── テキストレイヤー（TASK-79.5）─────────────────────────────

test "TextParams: setText/text は UTF-8 境界を壊さず切り詰める" {
    var p: TextParams = .{};
    p.setText("Hello");
    try std.testing.expectEqualStrings("Hello", p.text());

    const long_ascii = "A" ** (text_content_max + 10);
    p.setText(long_ascii);
    try std.testing.expectEqual(text_content_max, p.text().len);

    const multibyte = "あ" ** 40; // 120B（96 に収まるのは 32 個=96B まで）
    p.setText(multibyte);
    try std.testing.expect(p.text().len <= text_content_max);
    try std.testing.expect(std.unicode.utf8ValidateSlice(p.text()));
    try std.testing.expectEqualStrings("あ" ** 32, p.text());
}

test "TextParams.eql: text_buf の未使用末尾バイトを無視し意味的に比較する（font_px は bit 比較）" {
    var a: TextParams = .{ .font_px = 24, .color = 0xFFFFFFFF, .x = 1, .y = 2 };
    a.setText("Hi");
    var b: TextParams = .{ .font_px = 24, .color = 0xFFFFFFFF, .x = 1, .y = 2 };
    b.setText("Hi");
    // a/b は別々に setText した独立インスタンス（text_buf の未使用末尾は undefined で
    // 一致する保証が無い）。それでも eql は true になる。
    try std.testing.expect(a.eql(b));

    var c: TextParams = a;
    c.setText("Ho"); // 内容が違う
    try std.testing.expect(!a.eql(c));

    var d: TextParams = a;
    d.font_px = 25;
    try std.testing.expect(!a.eql(d));

    // NaN font_px 同士は bit 比較なら同一 NaN 表現で true（IEEE754 の NaN!=NaN の影響を受けない）。
    const nan_val = std.math.nan(f32);
    var e1: TextParams = .{ .font_px = nan_val };
    var e2: TextParams = .{ .font_px = nan_val };
    e1.setText("Z");
    e2.setText("Z");
    try std.testing.expect(e1.eql(e2));
}

test "Canvas.addTextLayer: text kind で追加され pixels がラスタライズ結果になる" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 64, 32);
    defer c.deinit();

    var params: TextParams = .{ .font_px = 16, .color = 0xFFFFFFFF, .x = 0, .y = 0 };
    params.setText("Hi");
    const idx = try c.addTextLayer(gpa, params);
    try std.testing.expectEqual(@as(usize, 1), idx); // layer0 の上に追加
    try std.testing.expectEqual(LayerKind.text, c.layers.items[idx].kind);
    try std.testing.expectEqualStrings("Hi", c.layers.items[idx].text_params.text());

    var non_transparent: usize = 0;
    for (c.layerPixels(idx)) |p| {
        if (p & 0xFF000000 != 0) non_transparent += 1;
    }
    try std.testing.expect(non_transparent > 0); // 文字が焼かれている
}

test "Canvas.setLayerTextParams: kind!=text は NotTextLayer、text は再ラスタライズされる" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 64, 32);
    defer c.deinit();

    try std.testing.expectError(error.NotTextLayer, c.setLayerTextParams(0, .{}));

    var params: TextParams = .{ .font_px = 16, .x = 0, .y = 0 };
    params.setText("A");
    const idx = try c.addTextLayer(gpa, params);
    const before_pixels = try gpa.dupe(u32, c.layerPixels(idx));
    defer gpa.free(before_pixels);

    var params2 = params;
    params2.setText("ABCDE"); // 文字列を変えると pixels が変わるはず
    try c.setLayerTextParams(idx, params2);
    try std.testing.expect(!std.mem.eql(u32, before_pixels, c.layerPixels(idx)));
    try std.testing.expectEqualStrings("ABCDE", c.layers.items[idx].text_params.text());
}

test "Canvas.rasterizeLayer/setLayerKindText: bake は pixels 不変・kind のみ切替、Undo/Redo 相当が可逆" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 64, 32);
    defer c.deinit();

    try std.testing.expectError(error.NotTextLayer, c.rasterizeLayer(0));

    var params: TextParams = .{ .font_px = 16 };
    params.setText("X");
    const idx = try c.addTextLayer(gpa, params);
    const pixels_before = try gpa.dupe(u32, c.layerPixels(idx));
    defer gpa.free(pixels_before);

    const before = try c.rasterizeLayer(idx);
    try std.testing.expect(before.eql(params));
    try std.testing.expectEqual(LayerKind.raster, c.layers.items[idx].kind);
    try std.testing.expectEqualSlices(u32, pixels_before, c.layerPixels(idx)); // pixels 不変

    // setLayerKindText で undo（.text へ戻す）→ redo（.raster へ戻す）
    try std.testing.expect(c.setLayerKindText(idx, .text, before));
    try std.testing.expectEqual(LayerKind.text, c.layers.items[idx].kind);
    try std.testing.expectEqualSlices(u32, pixels_before, c.layerPixels(idx)); // pixels は今も不変
    try std.testing.expect(c.setLayerKindText(idx, .raster, .{}));
    try std.testing.expectEqual(LayerKind.raster, c.layers.items[idx].kind);
    try std.testing.expect(!c.setLayerKindText(999, .text, .{})); // 範囲外は false
}
