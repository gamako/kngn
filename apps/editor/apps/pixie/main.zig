//! Pixie MVP: libs/gui UI + Pen/Eraser/DB16 パレット/Undo/PNG 保存
//!
//! - レイアウト: menu bar / row(canvas, right pane) / timeline placeholder / status bar
//!   の 4 段 Flex（毎フレーム fb サイズから再フロー。リサイズ対応自体は TASK-23）
//! - canvas 入力: press 起点 capture（canvas_input.zig の状態機械）。stroke 中は GUI 上に
//!   逸れても継続（座標は clamp なし変換 + ピクセル側 clip）
//! - Tool / Undo: core の Tool(Pen/Eraser) / StrokeRecorder / UndoStack（TASK-21.7 で core 化）
//! - ファイル I/O: Cmd+S=保存(記憶パス) / Cmd+Shift+S=名前を付けて保存 / Cmd+O=開く（TASK-24）。
//!   ファイルダイアログは framebuffer lock 中に呼べない（再入の危険）ため、handleKey/ボタンは
//!   pending_file_op をセットするだけにし、フレーム末の安全点 runPendingFileOp() で実行する。
//! - キー: B=Pen / E=Eraser / C=全消去 / Cmd+Z=Undo / Cmd+Shift+Z=Redo
//!         ESC・Cmd+Q=終了（ウィンドウクローズ含め running=false の単一経路）

const std = @import("std");
const kit = @import("kit"); // 公開 umbrella（ADR-007 R4/R5: apps は kit-only 消費者）
const platform = kit.platform;
const gui = kit.gui;
const core = @import("paint");
const png = kit.png;
const canvas_input = @import("canvas_input.zig");
const actions = @import("actions.zig");
const blit = @import("blit.zig");
const palette_mod = @import("palette.zig");
const bezier_input = @import("bezier_input.zig");
const bezier_overlay = @import("bezier_overlay.zig");
const selection_input = @import("selection_input.zig");
const selection_overlay = @import("selection_overlay.zig");
const eyedropper_input = @import("eyedropper_input.zig");
const brush_edge_cache = @import("brush_edge_cache.zig");
const cursor_overlay = @import("cursor_overlay.zig");

const WINDOW_W: u32 = 780;
const WINDOW_H: u32 = 600;
const CANVAS_W: u32 = 256;
const CANVAS_H: u32 = 256;
// ビューポート（TASK-39）: ズームは整数倍のランタイム値。既定 2x で従来の見た目を維持。
const ZOOM_MIN: i32 = 1;
const ZOOM_MAX: i32 = 32;
const ZOOM_DEFAULT: i32 = 2;
// 透明背景チェッカー（screen 固定セル。canonical BGRA 0xAARRGGBB）
// チェッカー定数の単一ソースは blit.zig（TASK-54 で移動）
const CHECKER_LIGHT = blit.CHECKER_LIGHT;
const CHECKER_DARK = blit.CHECKER_DARK;
// ペイン分割（TASK-42）: 右/下ペインのリサイズ + 表示非表示。pane は fixed px・canvas は grow。
const RIGHT_PANE_DEFAULT: i32 = 200;
const RIGHT_PANE_MIN: i32 = 120;
const BOTTOM_PANE_DEFAULT: i32 = 120;
const BOTTOM_PANE_MIN: i32 = 80;
const CANVAS_MIN: i32 = 120; // pane リサイズ時に canvas へ残す最小辺
const SPLITTER_T: i32 = 6; // 境界帯の太さ
const SAVE_MSG_DURATION: f64 = 3.0;
// 範囲選択のマーチングアンツ（TASK-44）。phase 速度（units/sec）と周期（=2*DASH。selection_overlay の DASH=4）。
const MARCH_SPEED: f64 = 12.0;
const MARCH_PERIOD: f64 = 8.0;

/// ファイル操作要求。framebuffer lock 中（フレーム処理中）に発生した要求を保持し、
/// unlock 後の安全点で 1 回だけ実行する（ダイアログのモーダルループ再入を避ける）。
const FileOp = enum { save, save_as, open, save_palette, load_palette, save_project, open_project };

/// canvas 領域の明示 ID（getNodeRect での外部参照用。自動 ID は不可）
const CANVAS_AREA_ID: gui.Id = 0xC0FFEE01;
/// ペイン分割（TASK-42）の明示 ID。CONTENT_ROW=横分割の利用可能幅、MAIN_AREA=縦分割の利用可能高 の基準。
const CONTENT_ROW_ID: gui.Id = 0xC0FFEE02;
const MAIN_AREA_ID: gui.Id = 0xC0FFEE03;
const SPLIT_RIGHT_ID: gui.Id = 0xC0FFEE04;
const SPLIT_BOTTOM_ID: gui.Id = 0xC0FFEE05;
const RIGHT_SCROLL_ID: gui.Id = 0xC0FFEE06; // 右ペイン縦スクロール領域（TASK-46）
const LAYER_PANEL_ID_BASE: gui.Id = 0xA430_0000;
const LAYER_ROW_ID_BASE: gui.Id = 0xA430_1000;
const LAYER_PANEL_ID_STRIDE: gui.Id = 8;
/// レイヤー行の右クリックコンテキストメニュー（TASK-79.2）。popup primitive（TASK-79.1）の id。
const LAYER_CTX_MENU_ID: gui.Id = 0xA430_2000;
/// レイヤー行 box 自身の明示 ID に使う `layerWidgetId` part（0..3 は既存: 0=選択ボタン/1=可視
/// トグル/2=opacity slider/3=サムネ）。右クリックのヒットテストは行全体の矩形を使う。
const LAYER_ROW_PART_ROW: gui.Id = 4;
// レイヤーパネルのサムネイル（raw layer をチェッカー下地へ最近傍縮小・等倍 blit）
const LAYER_THUMB_W: i32 = 24;
const LAYER_THUMB_H: i32 = 24;
const LAYER_THUMB_CELL: usize = 4; // サムネ内チェッカーのセル px

const COLOR_WINDOW_BG: u32 = 0xFF_24_20_20; // canonical BGRA: r=24,g=20,b=20（従来の見た目を維持）

/// canvas pixel（canonical BGRA 0xAARRGGBB）→ gui.Color（同一ビットレイアウト）。スウォッチ/プレビュー描画用。
fn guiColor(c: u32) gui.Color {
    return @bitCast(c);
}

/// 現在の描画ツール種別（UI 表示・選択ハイライト用。dispatch は core.Tool が担う）
const ToolKind = enum {
    pen,
    eraser,
    brush,
    bezier,
    select,
    fill,
    eyedropper,

    fn name(self: ToolKind) []const u8 {
        return switch (self) {
            .pen => "Pen",
            .eraser => "Eraser",
            .brush => "Brush",
            .bezier => "Bezier",
            .select => "Select",
            .fill => "Fill",
            .eyedropper => "Eyedropper",
        };
    }

    /// ソフトオーバーレイのツールバッジ（cursor_overlay.drawGlyph）用の2文字ラベル + 背景色
    /// （TASK-75.4）。label は全て string literal（DrawList.text の寿命契約を満たす）。
    fn glyph(self: ToolKind) struct { label: []const u8, color: gui.Color } {
        return switch (self) {
            .pen => .{ .label = "Pn", .color = gui.Color.rgba(0x2A, 0x5F, 0xB0, 0xFF) },
            .eraser => .{ .label = "Er", .color = gui.Color.rgba(0xB0, 0x33, 0x5A, 0xFF) },
            .brush => .{ .label = "Br", .color = gui.Color.rgba(0xC9, 0x7A, 0x20, 0xFF) },
            .bezier => .{ .label = "Bz", .color = gui.Color.rgba(0x1E, 0x9E, 0xC9, 0xFF) },
            .select => .{ .label = "Sl", .color = gui.Color.rgba(0xB8, 0x9A, 0x16, 0xFF) },
            .fill => .{ .label = "Fl", .color = gui.Color.rgba(0x2E, 0x9E, 0x52, 0xFF) },
            .eyedropper => .{ .label = "Ey", .color = gui.Color.rgba(0x7A, 0x4A, 0xC9, 0xFF) },
        };
    }
};

/// ブラシ footprint 輪郭リングの配色（selection_overlay の marching ants と同じ「偶奇で交互」流儀。
/// 任意の canvas 背景色に対するコントラストを確保する）。
const RING_COLOR_A = gui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF); // 白
const RING_COLOR_B = gui.Color.rgba(0xC9, 0x7A, 0x20, 0xFF); // ブラシバッジと同系オレンジ

/// platform.MouseButton → InputEvent の button index（0=left/1=right/2=middle）。
fn buttonToU8(b: platform.MouseButton) u8 {
    return switch (b) {
        .left => 0,
        .right => 1,
        .middle => 2,
        else => 0xFF,
    };
}

/// platform.Event → gui.InputEvent。GUI に関係しない quit は null。
/// key の負値（platform KeyCode.UNKNOWN = -1）は捨てる（libs/gui は u32 code 前提）。
fn toGuiEvent(ev: platform.Event) ?gui.InputEvent {
    return switch (ev) {
        .quit => null,
        .char_input => null,
        .mouse_move => |m| .{ .mouse_move = .{ .x = m.x, .y = m.y, .modifiers = m.modifiers.toC() } },
        .mouse_down => |m| .{ .mouse_down = .{ .x = m.x, .y = m.y, .button = buttonToU8(m.button), .modifiers = m.modifiers.toC() } },
        .mouse_up => |m| .{ .mouse_up = .{ .x = m.x, .y = m.y, .button = buttonToU8(m.button), .modifiers = m.modifiers.toC() } },
        .mouse_scroll => |s| .{ .mouse_scroll = .{ .x = s.x, .y = s.y, .dx = s.dx, .dy = s.dy, .modifiers = s.modifiers.toC() } },
        .key_down => |k| blk: {
            const code = @intFromEnum(k.key);
            if (code < 0) break :blk null;
            break :blk .{ .key_down = .{ .code = @intCast(code), .modifiers = k.modifiers.toC(), .repeat = k.is_repeat } };
        },
        .key_up => |k| blk: {
            const code = @intFromEnum(k.key);
            if (code < 0) break :blk null;
            break :blk .{ .key_up = .{ .code = @intCast(code), .modifiers = k.modifiers.toC() } };
        },
    };
}

/// アプリ状態（イベント処理と UI 構築の両方から触る）
const App = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// ドキュメント（frames × layers。MVP は 1 frame）。Canvas は heap 所有・ポインタ安定（TASK-63）。
    doc: core.Document,
    /// アクティブフレームの Canvas（doc.activeCanvas()）。既存参照の churn 最小化のため *Canvas を保持。
    canvas: *core.Canvas = undefined,
    recorder: core.StrokeRecorder,
    /// ベジェ編集中のブラシプレビュー用一時 canvas/recorder（本 layer のコピーへ非破壊描画）
    preview_canvas: core.Canvas,
    preview_rec: core.StrokeRecorder,
    undo: core.UndoStack = .{},
    pen: core.Pen,
    eraser: core.Eraser = .{},
    brush: core.Brush,
    /// 塗りつぶし（バケツ）ツール（TASK-76）。Pen/Eraser/Brush と同じく canvas_input 経由の
    /// down/move/up 契約に乗る（bezier/select のような独立経路は不要）。
    fill: core.Fill,
    input: canvas_input.CanvasInput = .{},
    /// ベジェ(ペン)ツール（独立経路。TASK-21.13）。状態機械 + マウス入力アダプタ。
    bezier_editor: core.PathEditor = .{},
    bez_in: bezier_input.BezierInput = .{},
    /// 範囲選択ツール（独立経路。TASK-44）。マーキー作成 / 選択範囲移動の状態機械。
    sel_in: selection_input.SelectionInput = .{},
    /// スポイトツール（独立経路。TASK-68）。press-capture の最小状態機械（塗り操作が無いため
    /// Tool vtable / StrokeRecorder / Undo は不要）。専用ツール選択・Alt+クリック一時スポイトの両方で使う。
    eye_in: eyedropper_input.EyedropperInput = .{},
    /// clipboard（copy/cut で確保し paste で参照。gpa 所有・deinit で free）。
    clipboard: ?core.PixelBlock = null,
    /// paste/move のブロック配置方法（既定 over=透明を保持＝下の絵を残す）。右ペインのトグルで切替（TASK-44）。
    blend_mode: core.selection.Blend = .over,
    active_kind: ToolKind = .pen,
    /// ── ビューポート（TASK-39）。view_zoom は整数倍、pan は表示領域中央基準の screen px オフセット ──
    view_zoom: i32 = ZOOM_DEFAULT,
    pan_x: i32 = 0,
    pan_y: i32 = 0,
    /// 直近フレームの canvas area rect（Fit ズーム計算用。canvasBlitRect が毎フレーム更新）
    last_area: ?core.Rect = null,
    /// Space 押下継続（key_down/up で更新）。Space+左ドラッグでパン
    space_down: bool = false,
    /// パンドラッグ進行中。開始時に anchor を latch（描画 capture とは排他）
    pan_active: bool = false,
    pan_anchor_mouse: core.Vec2 = .{ .x = 0, .y = 0 },
    pan_anchor_pan: core.Vec2 = .{ .x = 0, .y = 0 },
    /// ── ソフトオーバーレイ（ツールグリフ + ブラシ footprint 輪郭リング。TASK-75.4）──
    /// hover 中の生スクリーン座標（ツールバッジの錨点）。in_canvas かつ非 busy の時だけ Some
    /// （updateCursorAndHover が毎フレーム設定）。
    hover_screen: ?core.Vec2 = null,
    /// hover 中の canvas 画素座標（footprint リングの錨点）。`core.screenToCanvas` 経由（実 canvas
    /// 画素範囲外なら null）なので、レターボックス／canvas 外では自然にリングだけ非表示になる。
    hover_cell: ?core.Vec2 = null,
    /// 直近に OS へ要求した cursor shape（変化検出用 + `cursor` probe 公開用）。
    cursor_shape: platform.CursorShape = .default,
    /// Brush footprint 輪郭リングの縁セルキャッシュ（(size,hardness) 変化時のみ再計算）。
    brush_edges: brush_edge_cache.EdgeCache = .{},
    /// ── ペイン（TASK-42）。pane は fixed px・canvas は grow。幅/高さは毎フレーム利用可能領域へ clamp ──
    right_pane_w: i32 = RIGHT_PANE_DEFAULT,
    right_visible: bool = true,
    /// 右ペインの縦スクロール量（TASK-46。横は content_width=grow で不要）
    right_scroll: gui.Vec2f = .{},
    bottom_pane_h: i32 = BOTTOM_PANE_DEFAULT,
    bottom_visible: bool = false,
    /// Brush パラメータの UI 状態（Slider の *i32/*f32 と Brush の u32/u8 の型差を吸収）。
    brush_size_i32: i32 = 8,
    brush_opacity_i32: i32 = 255,
    brush_hardness_f32: f32 = 1.0,
    /// Fill の色許容差 tolerance の UI 状態（Slider の *i32 と u8 の型差吸収。brush_size_i32 と同パターン）。
    fill_tolerance_i32: i32 = 0,
    /// 編集可能パレット（colors.len>=1）。描画色 = palette.current()。
    palette: palette_mod.Palette,
    /// 編集中 HSV 状態。選択切替/load 後のみ RGB→HSV で再同期（s==0 でも hue を失わない）。
    edit_h: f32 = 0,
    edit_s: f32 = 0,
    edit_v: f32 = 0,
    /// HSV を同期済みの selected。null/不一致なら再同期。
    edit_synced_for: ?usize = null,
    running: bool = true,
    /// 現在の PNG 保存先（gpa 所有）。Cmd+S はここへ直接上書き、保存/読込ダイアログ成功時に更新。
    current_path: ?[]u8 = null,
    /// 現在の .pix プロジェクト保存先（gpa 所有。PNG の current_path とは別管理。TASK-63）。
    current_project_path: ?[]u8 = null,
    /// パレットの .gpl 保存先（gpa 所有。PNG の current_path とは別管理）。
    palette_path: ?[]u8 = null,
    /// 安全点で実行する保留中のファイル操作（フレーム処理中にセット、unlock 後に消費）。
    pending_file_op: ?FileOp = null,
    save_msg_buf: [128]u8 = undefined,
    save_msg_len: usize = 0,
    save_msg_until: f64 = 0,

    /// 現在 UI 選択中の Tool（fat-pointer。capture 開始時に canvas_input が latch する）
    fn activeTool(self: *App) core.Tool {
        return switch (self.active_kind) {
            .pen => self.pen.tool(),
            .eraser => self.eraser.tool(),
            .brush => self.brush.tool(),
            .bezier => self.pen.tool(), // bezier は独立経路で canvas_input を経由しない（到達しないフォールバック）
            .select => self.pen.tool(), // select も独立経路（到達しないフォールバック）
            .fill => self.fill.tool(),
            .eyedropper => self.pen.tool(), // eyedropper も独立経路（到達しないフォールバック。actionStroke で明示的に弾く）
        };
    }

    /// ツール切替を一元化（active_kind への代入は全てここ経由）。
    /// capture / 選択ドラッグ / スポイト picking 中は切替しない（進行中操作を宙ぶらりんにしない）。
    /// .bezier から出る時は未確定パスを cancel。.select から出る時は進行中ドラッグを破棄（selection は保持）。
    fn setActiveKind(self: *App, next: ToolKind) void {
        if (self.input.capturing or self.sel_in.state != .idle or self.eye_in.picking) return;
        if (self.active_kind == .bezier and next != .bezier) {
            self.bezier_editor.update(self.gpa, .cancel);
        }
        if (next != .select) self.sel_in.discardFloat(self.gpa); // 選択ツールを離れる → フロート破棄（canvas は最終形のまま）
        self.active_kind = next;
    }

    /// ズーム倍率を [ZOOM_MIN, ZOOM_MAX] に clamp して設定（パンは canvasBlitRect が次フレームに再クランプ）。
    fn zoomTo(self: *App, z: i32) void {
        self.view_zoom = std.math.clamp(z, ZOOM_MIN, ZOOM_MAX);
    }

    /// canvas が表示領域に収まる最大整数倍へ（Fit）。pan は中央へリセット。last_area 未確定時は無処理。
    fn fitZoom(self: *App) void {
        const area = self.last_area orelse return;
        const fz_x = @divFloor(area.w, @as(i32, @intCast(CANVAS_W)));
        const fz_y = @divFloor(area.h, @as(i32, @intCast(CANVAS_H)));
        self.zoomTo(@min(fz_x, fz_y));
        self.pan_x = 0;
        self.pan_y = 0;
    }

    fn setSaveMsg(self: *App, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.bufPrint(&self.save_msg_buf, fmt, args) catch &self.save_msg_buf;
        self.save_msg_len = msg.len;
        self.save_msg_until = platform.getTime() + SAVE_MSG_DURATION;
    }

    fn saveMsg(self: *const App) ?[]const u8 {
        if (self.save_msg_len == 0 or platform.getTime() >= self.save_msg_until) return null;
        return self.save_msg_buf[0..self.save_msg_len];
    }

    fn editingBlocked(self: *const App) bool {
        return self.input.capturing or self.bezier_editor.isEditing() or self.sel_in.state != .idle;
    }

    /// ソフトオーバーレイ（ツールグリフ + footprint リング）を隠すべきか（TASK-75.4）。
    /// 実際に描画/入力操作が進行中（stroke capture・選択ドラッグ・ベジェのハンドルドラッグ・パン）の間は
    /// 隠す（bezier hover プレビューの「ドラッグ中は隠す」流儀と同じ）。これにより
    /// `brush_edges.refresh()`（Brush.footprint() 経由で buildDab を再実行する）が Brush ストローク中に
    /// 呼ばれることも無くなり、「footprint は down 時に latch・stroke 中不変」という既存契約を壊さない。
    fn isPointerBusy(self: *const App) bool {
        return self.input.capturing or self.sel_in.state != .idle or self.bez_in.in_drag or self.pan_active or self.eye_in.picking;
    }

    /// 安全点（framebuffer unlock 後・入力更新後）で保留中のファイル操作を 1 回だけ実行する。
    /// 冒頭で one-shot 消費するので、capturing 等による早期 return でも要求は残らない。
    fn runPendingFileOp(self: *App) void {
        const op = self.pending_file_op orelse return;
        self.pending_file_op = null;
        switch (op) {
            .save => self.doSave(),
            .save_as => self.doSaveAs(),
            .open => self.doOpen(),
            .save_palette => self.doSavePalette(),
            .load_palette => self.doLoadPalette(),
            .save_project => self.doSaveProject(),
            .open_project => self.doOpenProject(),
        }
    }

    /// 選択スウォッチの色を編集中 HSV から決定し、palette と描画色（pen）へ反映する。
    /// edit_synced_for と palette.selected が一致するフレームでだけ呼ぶ（選択切替フレームの上書き事故回避）。
    fn applyEditColor(self: *App) void {
        const c: u32 = @bitCast(gui.Color.fromHsv(self.edit_h, self.edit_s, self.edit_v));
        self.palette.setSelectedColor(c);
        self.pen.color = c;
        self.brush.color = c; // Brush の描画色もパレット編集色に追従
        self.fill.color = c; // Fill の塗り色もパレット編集色に追従
    }

    /// 指定色を直接パレット選択色へ設定する（action `set_color` 用）。HSV ウィジェットを経由しない
    /// 直接代入のため `edit_synced_for = null` で次フレームの `syncEditHsv` に再同期を強制する
    /// （無いと HSV スライダーに触れた瞬間に古い HSV から色が巻き戻る）。`applyEditColor` 同様
    /// guard 無し（色選択は既存 UI でも editingBlocked に関わらず常に効く）。
    fn doSetColorHex(self: *App, color: u32) void {
        self.palette.setSelectedColor(color);
        self.pen.color = color;
        self.brush.color = color;
        self.fill.color = color;
        self.edit_synced_for = null;
    }

    /// スポイト（TASK-68）: 指定 canvas 座標の色を描画色へ反映する。座標は呼び出し側
    /// （`eyedropper_input.EyedropperInput.update`）が既に canvas 範囲内であることを保証している。
    /// 取得色は「合成色」（`compositeStraight()`。表示されている見た目の色。設計判断は plan 参照）。
    /// alpha==0（未描画/透明）は無視する（黒などの偽色を拾わせない）。alpha は不透明へ強制してから
    /// `doSetColorHex` へ渡す（`palette.zig` の不変条件「色は常に不透明」を守るため）。
    /// Eraser 選択中に拾った場合は Pen へ自動切替する（Eraser 自体には描画色の概念が無いため。
    /// パレットスウォッチクリックと同じ既存慣習）。`setActiveKind` は経由しない直接代入で切り替える
    /// （`setActiveKind` は `eye_in.picking` 中は競合ガードで no-op になるため、drag 中に不透明色を
    /// 拾った時点で切り替えたい本メソッドの意図と噛み合わない。この切替は「進行中の eyedrop 操作
    /// 自身の帰結」であり他ツールとの競合ではないので安全にバイパスできる。かつ .eraser から離れる
    /// 遷移は bezier cancel も sel_in フロート破棄も不要＝`setActiveKind` のガード外処理を再現する
    /// 必要が無い。codex レビュー指摘 2026-07-05）。
    fn pickColor(self: *App, x: i32, y: i32) void {
        const idx = @as(usize, @intCast(y)) * CANVAS_W + @as(usize, @intCast(x));
        const sampled = self.canvas.compositeStraight()[idx];
        if (sampled & 0xFF000000 == 0) return; // 透明部は無視
        self.doSetColorHex(0xFF000000 | (sampled & 0x00FFFFFF));
        if (self.active_kind == .eraser) self.active_kind = .pen;
    }

    /// 選択（or load）が変わったフレームに編集中 HSV を現在色から再同期する。
    fn syncEditHsv(self: *App) void {
        if (self.edit_synced_for == self.palette.selected) return;
        const hsv = guiColor(self.palette.current()).toHsv();
        self.edit_h = hsv.h;
        self.edit_s = hsv.s;
        self.edit_v = hsv.v;
        self.edit_synced_for = self.palette.selected;
    }

    /// パレットを .gpl で保存（名前を付けて保存。成功でダイアログ戻り値を palette_path へ移譲）。
    fn doSavePalette(self: *App) void {
        const maybe = platform.saveFileDialog(self.gpa, self.io, .{
            .default_name = "palette.gpl",
            .allowed_ext = "gpl",
        }) catch |err| {
            self.setSaveMsg("Palette save failed: {s}", .{@errorName(err)});
            return;
        };
        const path = maybe orelse return;
        const bytes = palette_mod.encodeGpl(self.palette.colors.items, "pixie", self.gpa) catch |err| {
            self.setSaveMsg("Palette save failed: {s}", .{@errorName(err)});
            self.gpa.free(path);
            return;
        };
        defer self.gpa.free(bytes);
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = bytes }) catch |err| {
            self.setSaveMsg("Palette save failed: {s}", .{@errorName(err)});
            self.gpa.free(path);
            return;
        };
        if (self.palette_path) |old| self.gpa.free(old);
        self.palette_path = path;
        self.setSaveMsg("Palette saved: {s}", .{std.fs.path.basename(path)});
    }

    /// .gpl を読み込んでパレットを差し替える（成功時のみ。失敗時は既存パレットを保持）。
    fn doLoadPalette(self: *App) void {
        const maybe = platform.openFileDialog(self.gpa, self.io, .{ .allowed_ext = "gpl" }) catch |err| {
            self.setSaveMsg("Palette load failed: {s}", .{@errorName(err)});
            return;
        };
        const path = maybe orelse return;
        defer self.gpa.free(path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .unlimited) catch |err| {
            self.setSaveMsg("Palette load failed: {s}", .{@errorName(err)});
            return;
        };
        defer self.gpa.free(bytes);
        const colors = palette_mod.decodeGpl(self.gpa, bytes) catch |err| {
            self.setSaveMsg("Palette load failed: {s}", .{@errorName(err)});
            return;
        };
        // 成功: 旧 colors を解放して差し替え、selected/HSV を初期化
        self.palette.colors.deinit(self.gpa);
        self.palette.colors = colors;
        self.palette.selected = 0;
        self.edit_synced_for = null; // 次フレームで HSV 再同期
        self.setSaveMsg("Palette loaded: {s}", .{std.fs.path.basename(path)});
    }

    /// 指定パスへ直接保存する（ダイアログ不使用。`doSave` の共通実装 + action `save <path>` 用）。
    /// current_path は更新しない（headless 呼び出しが UI の「名前を付けて保存」の永続状態へ
    /// 暗黙に介入しないため）。editingBlocked チェックは無い（既存 doSave/doSaveAs に無いのでそのまま）。
    fn doSaveTo(self: *App, path: []const u8) !void {
        const flat = self.canvas.compositeStraight();
        try core.savePNG(self.io, path, flat, CANVAS_W, CANVAS_H, self.gpa);
        self.setSaveMsg("Saved: {s}", .{std.fs.path.basename(path)});
    }

    /// 記憶している保存先へ直接上書き。未設定なら「名前を付けて保存」へフォールバック。
    fn doSave(self: *App) void {
        const path = self.current_path orelse return self.doSaveAs();
        // current_path は永続パスなので失敗しても保持（free しない）
        self.doSaveTo(path) catch |err| {
            self.setSaveMsg("Save failed: {s}", .{@errorName(err)});
        };
    }

    /// ダイアログで保存先を選んで保存。成功時にダイアログ戻り値を current_path へ移譲する。
    fn doSaveAs(self: *App) void {
        const maybe = platform.saveFileDialog(self.gpa, self.io, .{
            .default_name = "untitled.png",
            .allowed_ext = "png",
        }) catch |err| {
            self.setSaveMsg("Save failed: {s}", .{@errorName(err)});
            return;
        };
        const path = maybe orelse return; // キャンセル: サイレント no-op
        const flat = self.canvas.compositeStraight();
        core.savePNG(self.io, path, flat, CANVAS_W, CANVAS_H, self.gpa) catch |err| {
            self.setSaveMsg("Save failed: {s}", .{@errorName(err)});
            self.gpa.free(path); // 失敗時はダイアログ戻り値を解放・旧 current_path は触らない
            return;
        };
        if (self.current_path) |old| self.gpa.free(old);
        self.current_path = path; // 移譲（再 dupe しない）
        self.setSaveMsg("Saved: {s}", .{std.fs.path.basename(path)});
    }

    /// ダイアログで PNG を選んでキャンバスへ読み込む（左上クロップ/パディング）。
    /// 進行中 stroke 中は破棄。undo/redo はクリアし、current_path を開いたファイルに更新。
    /// 指定パスから直接読み込む（ダイアログ不使用。`doOpen` の共通実装 + action `open <path>` 用）。
    /// `doOpen` と同じ narrow guard（`input.capturing or bezier_editor.isEditing()`。`sel_in.state`
    /// は見ない＝既存 doOpen の挙動をそのまま踏襲）。path は `gpa.dupe` して current_path へ独立
    /// 所有コピーとして格納する（呼び出し側の path 所有権には関与しない）。
    fn doOpenPath(self: *App, path: []const u8) !void {
        if (self.input.capturing or self.bezier_editor.isEditing()) return error.EditingBlocked;
        var img = try png.decodePNGFile(self.io, self.gpa, path);
        defer img.deinit(self.gpa);
        // current_path 用の独立コピーを、ドキュメントを差し替える**前**に確保する（後段はすべて
        // infallible なので、ここで OOM を弾いておけば「読み込み済みだが失敗扱い」という中途半端な
        // 状態を作らない）。
        const owned = try self.gpa.dupe(u8, path);

        // PNG はフラット形式として読み込み、layer0 だけの新規ドキュメントへ置き換える。
        self.resetCanvasToSingleLayer();

        // 左上クロップ/パディング: layer0 を透明クリアし、収まる範囲を行ごとに memcpy。
        // png の出力は canonical BGRA 0xAARRGGBB で canvas と同一レイアウトなので変換不要。
        const layer0 = self.canvas.layerPixels(0);
        @memset(layer0, 0);
        const iw: usize = img.width;
        const rows = @min(@as(usize, img.height), @as(usize, CANVAS_H));
        const cols = @min(iw, @as(usize, CANVAS_W));
        for (0..rows) |y| {
            @memcpy(layer0[y * CANVAS_W ..][0..cols], img.pixels[y * iw ..][0..cols]);
        }
        self.syncPreviewCanvas();

        // load はドキュメント差し替えなので undo/redo 履歴を破棄（recorder は stroke 非進行中）
        self.undo.deinit(self.gpa);
        self.undo = .{};

        if (self.current_path) |old| self.gpa.free(old);
        self.current_path = owned;
        self.setSaveMsg("Loaded: {s}", .{std.fs.path.basename(path)});
    }

    /// ダイアログで PNG を選んでキャンバスへ読み込む（左上クロップ/パディング）。
    fn doOpen(self: *App) void {
        if (self.input.capturing or self.bezier_editor.isEditing()) return;
        const maybe = platform.openFileDialog(self.gpa, self.io, .{ .allowed_ext = "png" }) catch |err| {
            self.setSaveMsg("Load failed: {s}", .{@errorName(err)});
            return;
        };
        const path = maybe orelse return; // キャンセル: サイレント no-op
        defer self.gpa.free(path);
        self.doOpenPath(path) catch |err| {
            self.setSaveMsg("Load failed: {s}", .{@errorName(err)});
        };
    }

    // ── .pix プロジェクト保存/読込（レイヤー構造保持。TASK-63）─────────────────

    /// 記憶している .pix 保存先へ直接上書き。未設定なら「名前を付けて保存」へフォールバック。
    fn doSaveProject(self: *App) void {
        const path = self.current_project_path orelse return self.doSaveAsProject();
        core.document_io.saveDocument(self.io, path, &self.doc, self.gpa) catch |err| {
            self.setSaveMsg("Project save failed: {s}", .{@errorName(err)});
            return;
        };
        self.setSaveMsg("Project saved: {s}", .{std.fs.path.basename(path)});
    }

    /// ダイアログで .pix 保存先を選んで保存。成功時にダイアログ戻り値を current_project_path へ移譲。
    fn doSaveAsProject(self: *App) void {
        const maybe = platform.saveFileDialog(self.gpa, self.io, .{
            .default_name = "untitled.pix",
            .allowed_ext = "pix",
        }) catch |err| {
            self.setSaveMsg("Project save failed: {s}", .{@errorName(err)});
            return;
        };
        const path = maybe orelse return; // キャンセル: サイレント no-op
        core.document_io.saveDocument(self.io, path, &self.doc, self.gpa) catch |err| {
            self.setSaveMsg("Project save failed: {s}", .{@errorName(err)});
            self.gpa.free(path);
            return;
        };
        if (self.current_project_path) |old| self.gpa.free(old);
        self.current_project_path = path; // 移譲
        self.setSaveMsg("Project saved: {s}", .{std.fs.path.basename(path)});
    }

    /// .pix プロジェクトを読み込んでドキュメントを差し替える（レイヤー構造保持）。
    /// 進行中 stroke/編集中は破棄。undo/redo はクリア、selection/float 破棄、current_project_path 更新。
    /// MVP は 256x256 以外を拒否する（layer 復元前にサイズ検査）。任意サイズは resize フェーズ（TASK-39）へ。
    fn doOpenProject(self: *App) void {
        if (self.editingBlocked()) return;
        const maybe = platform.openFileDialog(self.gpa, self.io, .{ .allowed_ext = "pix" }) catch |err| {
            self.setSaveMsg("Project load failed: {s}", .{@errorName(err)});
            return;
        };
        const path = maybe orelse return; // キャンセル: サイレント no-op
        const new_doc = core.document_io.loadDocument(self.io, self.gpa, path, CANVAS_W, CANVAS_H) catch |err| {
            self.setSaveMsg("Project load failed: {s}", .{@errorName(err)});
            self.gpa.free(path);
            return;
        };
        // 成功: 旧 doc を破棄して差し替え、canvas ポインタと preview を張り直す。
        self.doc.deinit();
        self.doc = new_doc;
        self.doc.selected_frame = 0;
        self.canvas = self.doc.activeCanvas();
        // ドキュメント差し替え = undo/redo 履歴破棄・選択/フロート破棄（doOpen と同型。AC#4）
        self.undo.deinit(self.gpa);
        self.undo = .{};
        self.canvas.clearSelection();
        self.sel_in.discardFloat(self.gpa);
        self.syncPreviewCanvas();
        if (self.current_project_path) |old| self.gpa.free(old);
        self.current_project_path = path; // 移譲
        self.setSaveMsg("Project loaded: {s}", .{std.fs.path.basename(path)});
    }

    /// 編集系コマンドは stroke 中は無視する（仕様の簡略化指示）。`!void` 化（TASK-64）は UI
    /// （`catch {}` で無視）と action（`try` で伝播）が同じ判定コードを共有するための変更で、
    /// 挙動そのものは変わらない（action ⇄ UndoCmd 対応表は下部「custom action」セクションの
    /// doc comment 参照）。undo/redo スタックが空の場合は失敗にせず冪等 no-op として成功する
    /// （`UndoStack.undoOne`/`redoOne` も空なら何もしない既存実装のため、新規挙動ではない）。
    fn doUndo(self: *App) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        self.undo.undoOne(self.gpa, self.doc.frames.items);
    }

    fn doRedo(self: *App) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        self.undo.redoOne(self.gpa, self.doc.frames.items);
    }

    fn doClear(self: *App) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        self.undo.pushClear(self.gpa, self.canvas, self.doc.selected_frame, self.canvas.selected_layer);
    }

    /// 選択範囲を clipboard へコピー（読み取りのみ・undo 不要）。selection 無しは no-op。
    fn doCopy(self: *App) void {
        if (self.editingBlocked()) return;
        const sel = self.canvas.selection orelse return;
        const block = core.selection.extract(self.gpa, self.canvas, self.canvas.selected_layer, sel);
        if (self.clipboard) |*old| old.deinit(self.gpa);
        self.clipboard = block;
    }

    /// 選択範囲を clipboard へコピーし、選択内を透明化する（undo 可）。selection 無しは no-op。
    fn doCut(self: *App) void {
        if (self.editingBlocked()) return;
        const sel = self.canvas.selection orelse return;
        const block = core.selection.extract(self.gpa, self.canvas, self.canvas.selected_layer, sel);
        if (self.clipboard) |*old| old.deinit(self.gpa);
        self.clipboard = block;
        if (core.selection.clearRectCmd(self.gpa, self.canvas, self.canvas.selected_layer, sel)) |cmd| {
            self.undo.push(self.gpa, .{ .frame = self.doc.selected_frame, .op = cmd });
        }
    }

    /// clipboard を貼り付ける（undo 可）。貼付先は selection の左上（無ければ 0,0）。
    /// selection を貼付矩形（canvas 内 clip）へ更新する。clipboard 無しは no-op。
    fn doPaste(self: *App) void {
        if (self.editingBlocked()) return;
        const block = self.clipboard orelse return;
        const dx: i32 = if (self.canvas.selection) |s| s.x else 0;
        const dy: i32 = if (self.canvas.selection) |s| s.y else 0;
        if (core.selection.pasteCmd(self.gpa, self.canvas, self.canvas.selected_layer, block, dx, dy, self.blend_mode)) |cmd| {
            self.undo.push(self.gpa, .{ .frame = self.doc.selected_frame, .op = cmd });
        }
        const dest = core.Rect{ .x = dx, .y = dy, .w = @intCast(block.w), .h = @intCast(block.h) };
        self.canvas.setSelection(core.selection.clipRect(dest, self.canvas.width, self.canvas.height));
    }

    fn doAddLayer(self: *App) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        const selected_before = self.canvas.selected_layer;
        const idx = self.canvas.addLayer(self.gpa) catch |err| {
            self.setSaveMsg("Layer add failed: {s}", .{@errorName(err)});
            return err;
        };
        self.undo.push(self.gpa, .{ .frame = self.doc.selected_frame, .op = .{ .layer_add = .{
            .index = idx,
            .selected_before = selected_before,
            .selected_after = self.canvas.selected_layer,
        } } });
    }

    fn doDeleteLayer(self: *App) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        const idx = self.canvas.selected_layer;
        const selected_before = self.canvas.selected_layer;
        const removed = self.canvas.deleteLayer(idx) orelse return error.LastLayer;
        self.undo.push(self.gpa, .{ .frame = self.doc.selected_frame, .op = .{ .layer_delete = .{
            .index = idx,
            .selected_before = selected_before,
            .selected_after = self.canvas.selected_layer,
            .layer = removed,
        } } });
    }

    fn doMoveLayer(self: *App, delta: i32) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        const from = self.canvas.selected_layer;
        const to_i: i32 = @as(i32, @intCast(from)) + delta;
        if (to_i < 0) return error.OutOfRange;
        const to: usize = @intCast(to_i);
        if (to >= self.canvas.layers.items.len or to == from) return error.OutOfRange;
        const selected_before = self.canvas.selected_layer;
        if (!self.canvas.moveLayer(from, to)) return error.OutOfRange;
        self.undo.push(self.gpa, .{ .frame = self.doc.selected_frame, .op = .{ .layer_reorder = .{
            .from = from,
            .to = to,
            .selected_before = selected_before,
            .selected_after = self.canvas.selected_layer,
        } } });
    }

    /// レイヤー可視性を明示値へ設定する（`doToggleLayerVisible` の共通実装。TASK-64 で action
    /// `set_layer_visible` からも直接呼べるよう抽出）。`before == on` は冪等 no-op として黙って
    /// 成功する（`doSetLayerOpacity` と同じ扱い＝既存 UI のスライダー挙動を踏襲）。
    fn doSetLayerVisible(self: *App, idx: usize, on: bool) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        if (idx >= self.canvas.layers.items.len) return error.OutOfRange;
        const before = self.canvas.layers.items[idx].visible;
        if (before == on) return;
        _ = self.canvas.setLayerVisible(idx, on);
        self.undo.push(self.gpa, .{ .frame = self.doc.selected_frame, .op = .{ .layer_visible = .{ .index = idx, .before = before, .after = on } } });
    }

    /// UI のトグルボタン用（現在値の反転）。範囲外は既存どおり黙って無視（idx 境界は `doSetLayerVisible`
    /// 呼び出し前に確認する必要がある＝ `!before` 読み出しの OOB を避けるため）。
    fn doToggleLayerVisible(self: *App, idx: usize) void {
        if (idx >= self.canvas.layers.items.len) return;
        const before = self.canvas.layers.items[idx].visible;
        self.doSetLayerVisible(idx, !before) catch {};
    }

    fn doSetLayerOpacity(self: *App, idx: usize, value: u8) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        if (idx >= self.canvas.layers.items.len) return error.OutOfRange;
        const before = self.canvas.layers.items[idx].opacity;
        if (before == value) return;
        _ = self.canvas.setLayerOpacity(idx, value);
        self.undo.push(self.gpa, .{ .frame = self.doc.selected_frame, .op = .{ .layer_opacity = .{ .index = idx, .before = before, .after = value } } });
    }

    fn doSelectLayer(self: *App, idx: usize) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        if (!self.canvas.selectLayer(idx)) return error.OutOfRange;
    }

    /// 選択レイヤーを複製し、直上へ挿入する（Duplicate。TASK-79.2。レイヤー右クリックメニュー）。
    /// 新規 Undo Op は不要: 既存 `.layer_add` の undo（`canvas.deleteLayer(op.index)` の戻り値を
    /// その場でスナップショットする実装。undo.zig 参照）は push 時点でレイヤーが空か複製済みかを
    /// 関知しないため、push 前に複製済みの pixels/visible/opacity を書き込んでおくだけで
    /// undo/redo とも複製内容込みで正しく可逆になる（`doAddLayer` が空レイヤーで同じ Op を使う
    /// のと全く同じ仕組み）。1 push でアトミック。
    fn doDuplicateLayer(self: *App) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        const src_idx = self.canvas.selected_layer;
        const selected_before = self.canvas.selected_layer;
        const src = self.canvas.layers.items[src_idx];
        var new_layer = self.canvas.allocBlankLayer(self.gpa) catch |err| {
            self.setSaveMsg("Layer duplicate failed: {s}", .{@errorName(err)});
            return err;
        };
        errdefer self.gpa.free(new_layer.pixels);
        @memcpy(new_layer.pixels, src.pixels);
        new_layer.visible = src.visible;
        new_layer.opacity = src.opacity;
        const new_idx = src_idx + 1;
        try self.canvas.insertLayer(self.gpa, new_idx, new_layer);
        self.undo.push(self.gpa, .{ .frame = self.doc.selected_frame, .op = .{ .layer_add = .{
            .index = new_idx,
            .selected_before = selected_before,
            .selected_after = self.canvas.selected_layer,
        } } });
    }

    /// 選択レイヤーを直下のレイヤーへ結合する（Merge Down。TASK-79.2。レイヤー右クリックメニュー）。
    /// 選択中レイヤー(top)の内容を opacity 込みで下位レイヤー(bottom=top-1)へ src-over 焼き込みし、
    /// top 自体を削除する。最下層（index 0）は結合先が無いため error.OutOfRange。
    ///
    /// 「下位への合成」と「上位の削除」という 2 つの構造変化は、libs/paint の atomic な
    /// `.layer_merge_down` Op（undo.zig, TASK-79.2）へ **1 push** で表現する（2 つの UndoCmd に
    /// 分けると、片方だけ undo された状態で別操作が push された際に古い座標参照が残り不整合を
    /// 起こし得るため。codex レビュー指摘 2026-07-05）。
    ///
    /// ホットパス宣言: イベント時のみ（結合ボタン/メニュー項目クリック時に1回）。下位レイヤーの
    /// 全画素(256x256)を走るが event-time の1回ループであり、フレーム毎ではない
    /// （`Canvas.composite`/`UndoStack.pushClear` と同じ既存前例に倣うスカラーループで足りる。
    /// 性能規約の SIMD 3点セット等は対象外）。
    fn doMergeDown(self: *App) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        const top_idx = self.canvas.selected_layer;
        if (top_idx == 0) return error.OutOfRange;
        const bottom_idx = top_idx - 1;
        const selected_before = self.canvas.selected_layer;

        const below_before = self.gpa.dupe(u32, self.canvas.layerPixels(bottom_idx)) catch @panic("doMergeDown: OOM");
        errdefer self.gpa.free(below_before);

        const top_layer = self.canvas.layers.items[top_idx];
        const bottom_pixels = self.canvas.layerPixels(bottom_idx);
        if (top_layer.visible) {
            for (bottom_pixels, 0..) |*bp, i| {
                const s = if (top_layer.opacity != 255) core.blend.scaleAlpha(top_layer.pixels[i], top_layer.opacity) else top_layer.pixels[i];
                bp.* = core.blend.srcOver(bp.*, s);
            }
        }
        const below_after = self.gpa.dupe(u32, bottom_pixels) catch @panic("doMergeDown: OOM");
        errdefer self.gpa.free(below_after);

        const removed = self.canvas.deleteLayer(top_idx) orelse return error.LastLayer;
        self.undo.push(self.gpa, .{ .frame = self.doc.selected_frame, .op = .{ .layer_merge_down = .{
            .index = top_idx,
            .selected_before = selected_before,
            .selected_after = self.canvas.selected_layer,
            .layer = removed,
            .below_before = below_before,
            .below_after = below_after,
        } } });
    }

    fn resetCanvasToSingleLayer(self: *App) void {
        while (self.canvas.layers.items.len > 1) {
            const removed = self.canvas.deleteLayer(self.canvas.layers.items.len - 1).?;
            self.gpa.free(removed.pixels);
        }
        self.canvas.selected_layer = 0;
        self.canvas.layers.items[0].visible = true;
        self.canvas.layers.items[0].opacity = 255;
        @memset(self.canvas.layerPixels(0), 0);
        self.canvas.clearSelection(); // ドキュメント差し替えで選択は解除（TASK-44）
        self.sel_in.discardFloat(self.gpa); // フロートも破棄
    }

    fn syncPreviewCanvas(self: *App) void {
        while (self.preview_canvas.layers.items.len > self.canvas.layers.items.len) {
            const removed = self.preview_canvas.deleteLayer(self.preview_canvas.layers.items.len - 1).?;
            self.gpa.free(removed.pixels);
        }
        while (self.preview_canvas.layers.items.len < self.canvas.layers.items.len) {
            _ = self.preview_canvas.addLayer(self.gpa) catch @panic("syncPreviewCanvas: OOM");
        }
        for (self.canvas.layers.items, self.preview_canvas.layers.items) |src, *dst| {
            @memcpy(dst.pixels, src.pixels);
            dst.visible = src.visible;
            dst.opacity = src.opacity;
        }
        self.preview_canvas.selected_layer = self.canvas.selected_layer;
        // selection も同期（bezier プレビューが描画制約を commit と一致させる。TASK-44）
        self.preview_canvas.selection = self.canvas.selection;
        // 上の @memcpy / visible / opacity は Canvas API を通らない直接書きのため、
        // composite_cache を明示的に無効化する（TASK-53 の dirty フラグ導入に伴う）
        self.preview_canvas.markDirty();
    }

    fn handleKey(self: *App, k: platform.KeyEvent) void {
        // Space はパン用 modifier（押下継続を追跡。解放は handleKeyUp）。他処理には回さない。
        if (k.key == .SPACE) {
            self.space_down = true;
            return;
        }
        // ベジェ編集中はツール固有キーを横取り（Enter=確定 / Esc=キャンセル / Delete・Backspace=点削除）
        if (self.active_kind == .bezier and self.bezier_editor.isEditing()) {
            if (k.key == .ENTER or k.key == .KP_ENTER) {
                self.commitBezier();
                return;
            } else if (k.key == .ESCAPE) {
                self.bezier_editor.update(self.gpa, .cancel);
                return;
            } else if (k.key == .DELETE or k.key == .BACKSPACE) {
                self.bezier_editor.update(self.gpa, .delete);
                return;
            }
        }
        // 保存系などのアクセラレータ修飾: macOS=Cmd / Linux=Ctrl。
        // Linux(GNOME 等)は Super(=cmd) を WM が予約してアプリに届かないため Ctrl も受ける
        // （Ctrl+S 等は Linux の保存の慣習にも合致。macOS は従来どおり Cmd で、Ctrl も追加で効く）。
        const accel = k.modifiers.cmd or k.modifiers.ctrl;
        if (k.key == .ESCAPE) {
            // 選択ドラッグ中なら破棄 → 選択(またはフロート)があれば解除 → それ以外は終了（TASK-44 で優先動作を追加）
            if (self.sel_in.state != .idle) {
                self.sel_in.cancel(self.gpa); // drag 中断（フロート破棄・実レイヤーは drag 中不変）
            } else if (self.canvas.selection != null or self.sel_in.float != null) {
                self.canvas.clearSelection();
                self.sel_in.discardFloat(self.gpa);
            } else {
                self.running = false;
            }
        } else if (k.key == .Q and accel) {
            self.running = false;
        } else if (k.key == .S and accel and k.modifiers.shift) {
            self.pending_file_op = .save_as;
        } else if (k.key == .S and accel) {
            self.pending_file_op = .save;
        } else if (k.key == .O and accel) {
            self.pending_file_op = .open;
        } else if (k.key == .Z and accel and k.modifiers.shift) {
            self.doRedo() catch {};
        } else if (k.key == .Z and accel) {
            self.doUndo() catch {};
        } else if (k.key == .C and accel) {
            self.doCopy(); // accel+C は copy（bare C の clear より前に判定）
        } else if (k.key == .X and accel) {
            self.doCut();
        } else if (k.key == .V and accel) {
            self.doPaste();
        } else if (k.key == .B) {
            self.setActiveKind(.pen);
        } else if (k.key == .E) {
            self.setActiveKind(.eraser);
        } else if (k.key == .P) {
            self.setActiveKind(.bezier);
        } else if (k.key == .M) {
            self.setActiveKind(.select);
        } else if (k.key == .G) {
            self.setActiveKind(.fill);
        } else if (k.key == .I) {
            self.setActiveKind(.eyedropper); // Photoshop/GIMP 慣習のキー割当（一時スポイトは Alt+クリック）
        } else if (k.key == .C) {
            self.doClear() catch {};
        } else if (k.key == .@"0") {
            self.zoomTo(1); // 100% (1x)
            self.pan_x = 0;
            self.pan_y = 0;
        } else if (k.key == .F) {
            self.fitZoom();
        } else if (k.key == .KP_ADD) {
            self.zoomTo(self.view_zoom + 1);
        } else if (k.key == .KP_SUBTRACT) {
            self.zoomTo(self.view_zoom - 1);
        }
    }

    /// key_up 処理。現状は Space パン modifier の解放のみ。
    fn handleKeyUp(self: *App, k: platform.KeyEvent) void {
        if (k.key == .SPACE) self.space_down = false;
    }

    /// ベジェ確定（現在ブラシ footprint + color/opacity で rasterize → UndoStack へ push）。
    fn commitBezier(self: *App) void {
        const dab = self.brush.footprint();
        if (self.bezier_editor.rasterizeCommit(self.canvas, &self.recorder, self.gpa, dab, self.brush.color, self.brush.opacity)) |cmd| {
            self.undo.push(self.gpa, .{ .frame = self.doc.selected_frame, .op = cmd });
        }
    }
};

// ============================================================================
// ヘッドレス検証 harness の custom probe（TASK-32.3）
//
// `platform.registerProbe` で opt-in 登録する。framework は中身を解釈せず、snapshot の raw bytes を
// file へ書き / digest の1行を sink へ流すだけ。各 probe の意味づけは下の callback に閉じる。
// ctx は *App。harness 無効時は登録自体が no-op なので通常実行に影響しない。
// ============================================================================

/// canvas digest: サイズ / layer 数 / selected / composite crc / layer metadata。
fn canvasDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    var len: usize = 0;
    const head = std.fmt.bufPrint(buf[len..], "{d}x{d} layers={d} selected={d} comp={X:0>8}", .{
        CANVAS_W,
        CANVAS_H,
        app.canvas.layers.items.len,
        app.canvas.selected_layer,
        png.crc32(std.mem.sliceAsBytes(app.canvas.compositeStraight())),
    }) catch return buf[0..0];
    len += head.len;
    const sel_part = if (app.canvas.selection) |s|
        std.fmt.bufPrint(buf[len..], " sel={d},{d},{d},{d}", .{ s.x, s.y, s.w, s.h }) catch return buf[0..len]
    else
        std.fmt.bufPrint(buf[len..], " sel=none", .{}) catch return buf[0..len];
    len += sel_part.len;
    for (app.canvas.layers.items, 0..) |layer, idx| {
        var nonzero: usize = 0;
        for (layer.pixels) |p| {
            if (p != 0) nonzero += 1;
        }
        const part = std.fmt.bufPrint(buf[len..], " l{d}{{v={},op={d},crc={X:0>8},nz={d}}}", .{
            idx,
            layer.visible,
            layer.opacity,
            png.crc32(std.mem.sliceAsBytes(layer.pixels)),
            nonzero,
        }) catch break;
        len += part.len;
    }
    return buf[0..len];
}

/// canvas snapshot: visible layer を合成したフラット透明 PNG。
fn canvasSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    return core.encodePNG(app.canvas.compositeStraight(), CANVAS_W, CANVAS_H, allocator);
}

/// undo digest/snapshot: undo/redo スタックの深さ（JSON 1行）。undo で depth が減る。
fn undoDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    return std.fmt.bufPrint(buf, "{{\"depth\":{d},\"redo\":{d}}}", .{
        app.undo.undo.items.len, app.undo.redo.items.len,
    }) catch buf[0..0];
}
fn undoSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    return std.fmt.allocPrint(allocator, "{{\"depth\":{d},\"redo\":{d}}}", .{
        app.undo.undo.items.len, app.undo.redo.items.len,
    });
}

/// tool digest/snapshot: 現在ツール名 + 描画色 #RRGGBB。
fn toolDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const c = app.palette.current();
    const r: u8 = @truncate(c >> 16);
    const g: u8 = @truncate(c >> 8);
    const b: u8 = @truncate(c);
    return std.fmt.bufPrint(buf, "tool={s} color=#{X:0>2}{X:0>2}{X:0>2}", .{
        app.active_kind.name(), r, g, b,
    }) catch buf[0..0];
}
fn toolSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    var buf: [128]u8 = undefined;
    return allocator.dupe(u8, toolDigest(ctx, &buf));
}

/// cursor digest/snapshot（TASK-75.4）: 要求中の OS cursor shape + 現在ツール + footprint リング半径。
/// OS カーソル自体は framebuffer に写らないため、「pixie が要求した値」を assert する用途
/// （実際に OS カーソルが変わったかは各 backend 手動目視。docs/plans/cursor-support-plan.md 参照）。
fn cursorDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const shape_name: []const u8 = switch (app.cursor_shape) {
        .default => "default",
        .crosshair => "crosshair",
        .hidden => "hidden",
    };
    // ring_r は Brush 選択時のみ意味を持つ（それ以外は 0）。EdgeCache と同じ clampedSize 経由で
    // size 解釈をズレさせない（brush_edge_cache.clampedSize 参照）。
    const ring_r: u32 = if (app.active_kind == .brush) brush_edge_cache.clampedSize(&app.brush) / 2 else 0;
    return std.fmt.bufPrint(buf, "shape={s} tool={s} ring_r={d}", .{
        shape_name, app.active_kind.name(), ring_r,
    }) catch buf[0..0];
}
fn cursorSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    var buf: [128]u8 = undefined;
    return allocator.dupe(u8, cursorDigest(ctx, &buf));
}

// ============================================================================
// ヘッドレス検証 harness の custom action（TASK-64。TASK-62.1 の registerAction を pixie が採用）
//
// `platform.registerAction` で opt-in 登録する。probe（read）と対称の write/operate 口。
// 全 action は既存の UI/キーボードと同じ `App.do*` メソッドを呼ぶだけ（入口の一本化＝
// undo単位=action単位。UI/キーボード/action の3経路が同じ判定コード＝ do* 内のガードを通る）。
// パーサは `actions.zig`（std のみ・App/kit/platform 非依存）に切り出し単体テストする。
//
// action ⇄ UndoCmd 対応表（push は「この action 呼び出しで undo.push が起きるか」。
// 高々1回＝0 or 1。複数回 push する action は無い）:
//
//   action              → App メソッド          push  失敗時の error
//   ------------------  ---------------------  ----  --------------------------------
//   undo                doUndo                  no    EditingBlocked（空履歴は冪等成功）
//   redo                doRedo                  no    EditingBlocked（空履歴は冪等成功）
//   clear               doClear                 yes   EditingBlocked
//   add_layer           doAddLayer              yes   EditingBlocked / allocator error
//   delete_layer        doDeleteLayer           yes   EditingBlocked / LastLayer
//   select_layer        doSelectLayer           no    EditingBlocked / OutOfRange
//   set_layer_visible   doSetLayerVisible       yes*  EditingBlocked / OutOfRange
//   set_layer_opacity   doSetLayerOpacity       yes*  EditingBlocked / OutOfRange
//   move_layer          doMoveLayer             yes   EditingBlocked / OutOfRange
//   duplicate_layer     doDuplicateLayer        yes   EditingBlocked / allocator error（TASK-79.2）
//   merge_down          doMergeDown             yes   EditingBlocked / OutOfRange / LastLayer（TASK-79.2。
//                                                      atomic `.layer_merge_down` 1 entry。2 push ではない）
//   set_color           doSetColorHex           no    （guard 無し。常に成功）
//   set_tool            setActiveKind           no    （guard 無し。既存 UI と同じ「無反応」を許容）
//   stroke              activeTool().onEvent 直接 yes  EditingBlocked / UnsupportedTool / parse系
//   save                doSaveTo                no    savePNG の元 error
//   open                doOpenPath              no    EditingBlocked / decode 系
//
//   * before==after の冪等呼び出しは push 無し（既存 UI のスライダー/チェックボックス挙動と同じ）。
//
// 非 push action（select_layer/set_color/set_tool/save/open/undo/redo 自体）が undo 対象外なのは
// 新たな非一貫ではない: 既存 UI でも同じ操作（ツール切替キー・HSV スライダー・ファイル I/O）は
// undo.push を呼ばない設計だった（`applyEditColor`/`setActiveKind`/`doSave` 参照）。本タスクの主眼は
// 「UI が辿る undo 判定と全く同じコードを agent（action）からも辿れるようにする」ことで、UndoCmd
// 自体の構造拡張（tool/color の履歴化等）はスコープ外（TASK-64 plan 参照）。
//
// 将来 TASK-65（他アプリへの action 横展開）/ network（TASK-62.3）への申し送り: action 呼び出し列
// （name+args）がそのまま「ネットワークで流す操作ストリーム」の単位になる、という設計意図をここに
// 残す。UndoCmd の pixel diff は各ノードでの決定的 re-apply の実装詳細であり、ネットワーク越しに
// 流す粒度ではない。
// ============================================================================

fn actionApp(ctx: *anyopaque) *App {
    return @ptrCast(@alignCast(ctx));
}

fn actionUndo(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    try actions.parseNoArgs(args);
    try actionApp(ctx).doUndo();
    return "ok";
}

fn actionRedo(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    try actions.parseNoArgs(args);
    try actionApp(ctx).doRedo();
    return "ok";
}

fn actionClear(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    try actions.parseNoArgs(args);
    try actionApp(ctx).doClear();
    return "ok";
}

fn actionAddLayer(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    try actions.parseNoArgs(args);
    try actionApp(ctx).doAddLayer();
    return "ok";
}

fn actionDeleteLayer(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    try actions.parseNoArgs(args);
    try actionApp(ctx).doDeleteLayer();
    return "ok";
}

fn actionSelectLayer(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const idx = try actions.parseUsize(args);
    try actionApp(ctx).doSelectLayer(idx);
    return "ok";
}

fn actionSetLayerVisible(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const p = try actions.parseIdxBool(args);
    try actionApp(ctx).doSetLayerVisible(p.idx, p.on);
    return "ok";
}

fn actionSetLayerOpacity(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const p = try actions.parseIdxU8(args);
    try actionApp(ctx).doSetLayerOpacity(p.idx, p.value);
    return "ok";
}

fn actionMoveLayer(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const delta = try actions.parseMoveDelta(args);
    try actionApp(ctx).doMoveLayer(delta);
    return "ok";
}

fn actionDuplicateLayer(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    try actions.parseNoArgs(args);
    try actionApp(ctx).doDuplicateLayer();
    return "ok";
}

fn actionMergeDown(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    try actions.parseNoArgs(args);
    try actionApp(ctx).doMergeDown();
    return "ok";
}

fn actionSetColor(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const color = try actions.parseHexColor(args);
    actionApp(ctx).doSetColorHex(color);
    return "ok";
}

fn actionSetTool(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const trimmed = std.mem.trim(u8, args, " \t");
    const kind = std.meta.stringToEnum(ToolKind, trimmed) orelse return error.UnknownTool;
    actionApp(ctx).setActiveKind(kind);
    return "ok";
}

/// canvas 座標の点列を down→move×N→up で直接駆動する（既存 canvas_input と同じ Tool 経路）。
/// `active_kind==.bezier/.select/.eyedropper` は `activeTool()` が到達しないフォールバック（pen）を
/// 返す実装のため、意図しない Pen 描画を避けるべく明示的に弾く。
fn actionStroke(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    if (app.active_kind == .bezier or app.active_kind == .select or app.active_kind == .eyedropper) return error.UnsupportedTool;
    if (app.editingBlocked()) return error.EditingBlocked;
    var pts_buf: [actions.MAX_STROKE_POINTS]actions.Point = undefined;
    const pts = try actions.parseStrokePoints(args, &pts_buf);

    const tool = app.activeTool();
    _ = tool.onEvent(app.canvas, &app.recorder, app.gpa, .{ .down = .{ .x = pts[0].x, .y = pts[0].y } });
    var cmd: ?core.Op = null;
    if (pts.len == 1) {
        cmd = tool.onEvent(app.canvas, &app.recorder, app.gpa, .{ .up = .{ .x = pts[0].x, .y = pts[0].y } });
    } else {
        for (pts[1..], 0..) |p, i| {
            if (i == pts.len - 2) {
                cmd = tool.onEvent(app.canvas, &app.recorder, app.gpa, .{ .up = .{ .x = p.x, .y = p.y } });
            } else {
                _ = tool.onEvent(app.canvas, &app.recorder, app.gpa, .{ .move = .{ .x = p.x, .y = p.y } });
            }
        }
    }
    if (cmd) |c| app.undo.push(app.gpa, .{ .frame = app.doc.selected_frame, .op = c });
    return "ok";
}

fn actionSave(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const path = try actions.parsePath(args);
    try actionApp(ctx).doSaveTo(path);
    return "ok";
}

fn actionOpen(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const path = try actions.parsePath(args);
    try actionApp(ctx).doOpenPath(path);
    return "ok";
}

/// 16 action を一括登録する（`platform.init()` 後・main loop 前に呼ぶ。harness 無効時は
/// `registerAction` 自体が no-op なので通常実行に影響しない）。
fn registerActions(app: *App) void {
    platform.registerAction(.{ .name = "undo", .ctx = app, .run = actionUndo });
    platform.registerAction(.{ .name = "redo", .ctx = app, .run = actionRedo });
    platform.registerAction(.{ .name = "clear", .ctx = app, .run = actionClear });
    platform.registerAction(.{ .name = "add_layer", .ctx = app, .run = actionAddLayer });
    platform.registerAction(.{ .name = "delete_layer", .ctx = app, .run = actionDeleteLayer });
    platform.registerAction(.{ .name = "select_layer", .ctx = app, .run = actionSelectLayer });
    platform.registerAction(.{ .name = "set_layer_visible", .ctx = app, .run = actionSetLayerVisible });
    platform.registerAction(.{ .name = "set_layer_opacity", .ctx = app, .run = actionSetLayerOpacity });
    platform.registerAction(.{ .name = "move_layer", .ctx = app, .run = actionMoveLayer });
    platform.registerAction(.{ .name = "duplicate_layer", .ctx = app, .run = actionDuplicateLayer });
    platform.registerAction(.{ .name = "merge_down", .ctx = app, .run = actionMergeDown });
    platform.registerAction(.{ .name = "set_color", .ctx = app, .run = actionSetColor });
    platform.registerAction(.{ .name = "set_tool", .ctx = app, .run = actionSetTool });
    platform.registerAction(.{ .name = "stroke", .ctx = app, .run = actionStroke });
    platform.registerAction(.{ .name = "save", .ctx = app, .run = actionSave });
    platform.registerAction(.{ .name = "open", .ctx = app, .run = actionOpen });
}

/// canvas_area rect 内に表示領域（CANVAS*zoom 四方）を配置した canvas rect を返す。
/// vw<=area.w 軸は中央固定（pan=0）、vw>area.w 軸は canvas が area を完全に覆う範囲へ pan を clamp し
/// app.pan_x/y へ書き戻す。毎フレーム app.last_area も更新する（Fit ズーム計算用）。
/// 返す core.Rect の w/h は canvas ピクセル数（screenToCanvas* の契約）。初回フレームは null。
fn canvasBlitRect(ctx: *const gui.Context, app: *App) ?core.Rect {
    const area = ctx.getNodeRect(CANVAS_AREA_ID) orelse return null;
    app.last_area = .{ .x = area.x, .y = area.y, .w = @intCast(area.w), .h = @intCast(area.h) };

    const zoom = app.view_zoom;
    const aw: i32 = @intCast(area.w);
    const ah: i32 = @intCast(area.h);
    const vw: i32 = @as(i32, @intCast(CANVAS_W)) * zoom;
    const vh: i32 = @as(i32, @intCast(CANVAS_H)) * zoom;

    const rx = axisPlace(area.x, aw, vw, &app.pan_x);
    const ry = axisPlace(area.y, ah, vh, &app.pan_y);
    return .{ .x = rx, .y = ry, .w = @intCast(CANVAS_W), .h = @intCast(CANVAS_H) };
}

/// 1 軸の表示原点を決め、pan を clamp して書き戻す。
/// vw<=aw: 中央固定（pan=0）。vw>aw: 原点 r ∈ [a + aw - vw, a]（canvas が area を隙間なく覆う）。
/// off-by-one 回避のため r を clamp してから pan を逆算する。
fn axisPlace(a: i32, aw: i32, vw: i32, pan: *i32) i32 {
    const half = @divFloor(aw - vw, 2);
    if (vw <= aw) {
        pan.* = 0;
        return a + half;
    }
    var r = a + half + pan.*;
    const lo = a + aw - vw; // 右/下端を覆う最小原点
    const hi = a; // 左/上端を覆う最大原点
    if (r < lo) r = lo;
    if (r > hi) r = hi;
    pan.* = r - a - half; // 状態整合
    return r;
}

/// ビューポートのズーム/パン入力を処理する（endFrame 後・canvas 入力前に呼ぶ）。
/// 戻り値: パン中なら true（呼び出し側は描画入力を抑止する）。zoom/pan の変更は app へ書き戻し、
/// 実際の clamp は次フレームの canvasBlitRect が現 area に対して行う。
fn updateViewport(app: *App, ctx: *const gui.Context, canvas_rect: ?core.Rect) bool {
    const in = &ctx.input;
    const area = app.last_area;
    // popup（レイヤー右クリックメニュー等。TASK-79.2）表示中は新規のズーム/パン**開始**を
    // 抑止する（canvas への入力貫通防止。既存の stroke 開始ゲートと同じ狙い）。既に進行中の
    // パンはそのまま release まで完走させる（下の `if (app.pan_active)` は popup_open を見ない）。
    const popup_open = ctx.hasOpenPopup();

    // マウスが canvas area 内か（ズーム/パン開始の判定に使う）
    const in_area = blk: {
        if (area) |a| {
            const p = in.mouse_pos;
            break :blk (p.x >= a.x and p.y >= a.y and p.x < a.x + a.w and p.y < a.y + a.h);
        }
        break :blk false;
    };

    // ── ホイールズーム（カーソル中心。area 内のみ）──
    // scroll_delta.y > 0 = 上スクロール = ズームイン（backend により符号が逆なら調整）。
    if (in_area and in.scroll_delta.y != 0 and !popup_open) {
        if (canvas_rect) |cr| if (area) |a| {
            const old_zoom = app.view_zoom;
            const step: i32 = if (in.scroll_delta.y > 0) 1 else -1;
            const new_zoom = std.math.clamp(old_zoom + step, ZOOM_MIN, ZOOM_MAX);
            if (new_zoom != old_zoom) {
                const mx: f32 = @floatFromInt(in.mouse_pos.x);
                const my: f32 = @floatFromInt(in.mouse_pos.y);
                const oz: f32 = @floatFromInt(old_zoom);
                const nz: f32 = @floatFromInt(new_zoom);
                // zoom 前のカーソル下 canvas 位置（f32, セル内位置を保持）
                const cfx = (mx - @as(f32, @floatFromInt(cr.x))) / oz;
                const cfy = (my - @as(f32, @floatFromInt(cr.y))) / oz;
                const vw_new: i32 = @as(i32, @intCast(CANVAS_W)) * new_zoom;
                const vh_new: i32 = @as(i32, @intCast(CANVAS_H)) * new_zoom;
                const half_x = @divFloor(a.w - vw_new, 2);
                const half_y = @divFloor(a.h - vh_new, 2);
                // 望ましい表示原点 = カーソル位置 - canvas位置*新zoom。pan = 原点 - (area原点 + half)
                const new_rx = mx - cfx * nz;
                const new_ry = my - cfy * nz;
                app.pan_x = @intFromFloat(@round(new_rx - @as(f32, @floatFromInt(a.x + half_x))));
                app.pan_y = @intFromFloat(@round(new_ry - @as(f32, @floatFromInt(a.y + half_y))));
                app.view_zoom = new_zoom;
            }
        };
    }

    // ── パン（Space+左 or middle ドラッグ）。capturing / bezier 編集中は開始しない ──
    const pan_held = (app.space_down and in.mouse_buttons.left) or in.mouse_buttons.middle;
    if (!app.pan_active) {
        const pan_press = (app.space_down and in.mouse_pressed.left) or in.mouse_pressed.middle;
        const bezier_editing = app.active_kind == .bezier and app.bezier_editor.isEditing();
        if (pan_press and !app.input.capturing and !bezier_editing and !popup_open) {
            if (area) |a| {
                const p = in.mouse_pressed_pos;
                if (p.x >= a.x and p.y >= a.y and p.x < a.x + a.w and p.y < a.y + a.h) {
                    app.pan_active = true;
                    app.pan_anchor_mouse = .{ .x = in.mouse_pos.x, .y = in.mouse_pos.y };
                    app.pan_anchor_pan = .{ .x = app.pan_x, .y = app.pan_y };
                }
            }
        }
    }
    if (app.pan_active) {
        if (pan_held) {
            app.pan_x = app.pan_anchor_pan.x + (in.mouse_pos.x - app.pan_anchor_mouse.x);
            app.pan_y = app.pan_anchor_pan.y + (in.mouse_pos.y - app.pan_anchor_mouse.y);
        } else {
            app.pan_active = false;
        }
    }
    return app.pan_active;
}

/// M1 配線（TASK-75.4）: hover 領域（canvas / パネル・外）から OS cursor shape を決め、前フレームと
/// 異なる時だけ `window.setCursor` を呼ぶ（canvas → crosshair、パネル/外 → default）。
/// あわせて free-hover 位置（`hover_screen`/`hover_cell`）を更新する。
///
/// 呼び出しタイミングは「canvas 入力ディスパッチの後・描画の前」（main loop 内）にすること。
/// ディスパッチ前だと、当フレームで新規 stroke が開始しても `isPointerBusy()` がまだ false のままの
/// 状態で hover が確定してしまい、直後の描画パスで busy 開始直後の footprint リング（Brush の場合）が
/// 一瞬出てしまう（codex レビュー指摘。2026-07-05）。
///
/// ホットパス宣言: 毎フレーム呼ばれるが O(1)（矩形内外判定 + 座標変換のみ）。全画素ループ非該当。
fn updateCursorAndHover(app: *App, window: platform.Window, ctx: *const gui.Context, canvas_rect: ?core.Rect) void {
    const mouse = core.Vec2{ .x = ctx.input.mouse_pos.x, .y = ctx.input.mouse_pos.y };
    const in_canvas = if (app.last_area) |a| a.contains(mouse.x, mouse.y) else false;

    const shape: platform.CursorShape = if (in_canvas) .crosshair else .default;
    if (shape != app.cursor_shape) {
        app.cursor_shape = shape;
        window.setCursor(shape);
    }

    app.hover_screen = if (in_canvas and !app.isPointerBusy()) mouse else null;
    app.hover_cell = if (app.hover_screen != null and canvas_rect != null)
        core.screenToCanvas(mouse, canvas_rect.?, app.view_zoom)
    else
        null;
}

fn layerWidgetId(idx: usize, part: gui.Id) gui.Id {
    return LAYER_ROW_ID_BASE + @as(gui.Id, idx) * LAYER_PANEL_ID_STRIDE + part;
}

/// raw layer pixels（CANVAS_W×CANVAS_H, straight BGRA 0xAARRGGBB）を THUMB へ縮小し、
/// チェッカー下地へ src-over して不透明サムネを作る（透明部はチェッカーが見える）。
/// 各サムネ画素は元領域の **alpha 重み付き平均（premultiplied 平均）** にして、1px の細線も
/// 薄く残し内容が分かるようにする（最近傍だと細線が抜け落ちる）。opacity は反映しない（生の内容を表示）。
/// buf.len == LAYER_THUMB_W * LAYER_THUMB_H 前提。
fn fillLayerThumb(buf: []u32, layer_pixels: []const u32) void {
    const tw: usize = @intCast(LAYER_THUMB_W);
    const th: usize = @intCast(LAYER_THUMB_H);
    const cw: usize = CANVAS_W;
    const ch: usize = CANVAS_H;
    var ty: usize = 0;
    while (ty < th) : (ty += 1) {
        const sy0 = ty * ch / th;
        const sy1 = @max(sy0 + 1, (ty + 1) * ch / th); // 必ず 1 行以上
        var tx: usize = 0;
        while (tx < tw) : (tx += 1) {
            const sx0 = tx * cw / tw;
            const sx1 = @max(sx0 + 1, (tx + 1) * cw / tw);
            // 元領域 [sx0,sx1)×[sy0,sy1) の premultiplied 平均で straight BGRA を作る
            var sum_a: u64 = 0;
            var sum_r: u64 = 0;
            var sum_g: u64 = 0;
            var sum_b: u64 = 0;
            var n: u64 = 0;
            var sy = sy0;
            while (sy < sy1) : (sy += 1) {
                var sx = sx0;
                while (sx < sx1) : (sx += 1) {
                    const px = layer_pixels[sy * cw + sx];
                    const a: u64 = (px >> 24) & 0xFF;
                    const r: u64 = (px >> 16) & 0xFF;
                    const g: u64 = (px >> 8) & 0xFF;
                    const b: u64 = px & 0xFF;
                    sum_a += a;
                    sum_r += r * a;
                    sum_g += g * a;
                    sum_b += b * a;
                    n += 1;
                }
            }
            const avg_a: u32 = @intCast(sum_a / n);
            const avg_r: u32 = if (sum_a > 0) @intCast(sum_r / sum_a) else 0;
            const avg_g: u32 = if (sum_a > 0) @intCast(sum_g / sum_a) else 0;
            const avg_b: u32 = if (sum_a > 0) @intCast(sum_b / sum_a) else 0;
            const src = (avg_a << 24) | (avg_r << 16) | (avg_g << 8) | avg_b;
            const checker = (tx / LAYER_THUMB_CELL + ty / LAYER_THUMB_CELL) & 1;
            const bg: u32 = if (checker == 0) CHECKER_LIGHT else CHECKER_DARK;
            buf[ty * tw + tx] = core.blend.srcOver(bg, src);
        }
    }
}

fn buildLayerPanel(ctx: *gui.Context, app: *App) !void {
    ctx.label("Layers");
    ctx.beginBox(.{ .direction = .row, .gap = 4 });
    if (ctx.buttonId(LAYER_PANEL_ID_BASE + 1, "+", .{ .min_w = 28 }).clicked) app.doAddLayer() catch {};
    if (ctx.buttonId(LAYER_PANEL_ID_BASE + 2, "-", .{ .min_w = 28 }).clicked) app.doDeleteLayer() catch {};
    if (ctx.buttonId(LAYER_PANEL_ID_BASE + 3, "Up", .{ .min_w = 34 }).clicked) app.doMoveLayer(1) catch {};
    if (ctx.buttonId(LAYER_PANEL_ID_BASE + 4, "Dn", .{ .min_w = 34 }).clicked) app.doMoveLayer(-1) catch {};
    ctx.endBox();

    var rev = app.canvas.layers.items.len;
    while (rev > 0) {
        rev -= 1;
        const idx = rev;
        const layer = app.canvas.layers.items[idx];
        // 1 行 = [サムネイル][選択 L{d}][visible][opacity slider]。行高はサムネイル(24px)律速。
        // 横一列で 200px 幅に収め、行を低く保って縦方向に多くの layer を見せる。
        // 明示 ID（row_id）を付けて rect_cache に登録する（右クリックのヒットテスト用。TASK-79.2）。
        const row_id = layerWidgetId(idx, LAYER_ROW_PART_ROW);
        ctx.beginBox(.{ .id = row_id, .direction = .row, .gap = 3, .align_cross = .center });

        // サムネイル: raw layer をチェッカー下地へ縮小合成。選択中は枠を明色に。
        const thumb = ctx.allocator().alloc(u32, @as(usize, @intCast(LAYER_THUMB_W)) * @as(usize, @intCast(LAYER_THUMB_H))) catch @panic("layer thumb: OOM");
        fillLayerThumb(thumb, layer.pixels);
        const thumb_border = if (idx == app.canvas.selected_layer) ctx.style.border_hover else ctx.style.border;
        ctx.imageBox(layerWidgetId(idx, 3), thumb, LAYER_THUMB_W, LAYER_THUMB_H, .{ .border = thumb_border });

        const name = try std.fmt.allocPrint(ctx.allocator(), "L{d}", .{idx});
        if (ctx.buttonId(layerWidgetId(idx, 0), name, .{ .selected = idx == app.canvas.selected_layer, .min_w = 28 }).clicked) {
            app.doSelectLayer(idx) catch {};
        }
        const vis_label: []const u8 = if (layer.visible) "V" else "H";
        if (ctx.buttonId(layerWidgetId(idx, 1), vis_label, .{ .selected = layer.visible, .min_w = 22 }).clicked) {
            app.doToggleLayerVisible(idx);
        }
        var op_i32: i32 = layer.opacity;
        if (ctx.sliderI32Id(layerWidgetId(idx, 2), "O", &op_i32, .{ .min = 0, .max = 255, .track_w = 40 })) {
            app.doSetLayerOpacity(idx, @intCast(std.math.clamp(op_i32, 0, 255))) catch {};
        }
        ctx.endBox(); // row

        // 右クリックでこの行のレイヤーを選択しコンテキストメニューを開く（TASK-79.2）。
        // 行矩形は「前フレームの rect_cache」（既存 widget と同じ同期 hit-test 契約。
        // context.zig 冒頭の契約コメント参照）。openPopup は endFrame 前でも呼べる
        // （endFrame 後を要求するのは描画+hit-test を行う popupMenu 側のみ。popup.zig 参照）。
        // レイヤーパネルは右ペインの縦スクロール領域（RIGHT_SCROLL_ID, clip_children=true）配下
        // にあるため、行 rect 単体だけでは「スクロールでクリップされ実際には見えていない部分」を
        // 誤ヒットし得る（codex レビュー指摘 2026-07-05）。RIGHT_SCROLL_ID のビューポート矩形
        // （beginScrollArea が clip_children 付きで登録する viewport box の rect）にも収まっている
        // ことを追加で確認する（既存 widget の buttonBehavior(rect, clip) と同じ「祖先 clip を
        // hit-test に使う」契約を、手動 hit-test でも踏襲する）。
        if (ctx.input.mouse_pressed.right) {
            if (ctx.getNodeRect(row_id)) |r| {
                const p = ctx.input.mouse_pressed_pos;
                const in_viewport = if (ctx.getNodeRect(RIGHT_SCROLL_ID)) |vp| vp.contains(p) else true;
                if (in_viewport and r.contains(p)) {
                    app.doSelectLayer(idx) catch {};
                    ctx.openPopup(LAYER_CTX_MENU_ID, p);
                }
            }
        }
    }
}

/// UI ツリー構築（widget の同期 hit-test もここで走る）
fn buildUi(ctx: *gui.Context, app: *App, canvas_rect: ?core.Rect) !void {
    // 選択/load 変更フレームに編集 HSV を現在色から再同期（以後は編集中 HSV を保持）
    app.syncEditHsv();
    // 右ペイン非表示時は HSV widget が無く applyEditColor がブロック内で呼ばれない（TASK-42）。
    // Pal Load 等で current が変わっても pen/brush.color が旧色のままになるのを防ぐためここで同期する
    // （visible 時は従来どおり HSV slider 更新後・palette grid より前のブロック内で呼ぶ）。
    if (!app.right_visible) app.applyEditColor();

    // ペイン幅/高さを前フレーム rect の「利用可能領域」へ clamp（TASK-42）。
    // 基準は CONTENT_ROW（横分割の全幅）/ MAIN_AREA（縦分割の全高）。CANVAS_AREA は pane 差引後の
    // 残りなので max 基準に使えない。max は splitter にも渡し、ウィンドウ縮小時も canvas を CANVAS_MIN 残す。
    var right_max: i32 = RIGHT_PANE_DEFAULT;
    if (ctx.getNodeRect(CONTENT_ROW_ID)) |row| {
        right_max = @max(RIGHT_PANE_MIN, @as(i32, @intCast(row.w)) - SPLITTER_T - CANVAS_MIN);
    }
    app.right_pane_w = std.math.clamp(app.right_pane_w, RIGHT_PANE_MIN, right_max);
    var bottom_max: i32 = BOTTOM_PANE_DEFAULT;
    if (ctx.getNodeRect(MAIN_AREA_ID)) |m| {
        bottom_max = @max(BOTTOM_PANE_MIN, @as(i32, @intCast(m.h)) - SPLITTER_T - CANVAS_MIN);
    }
    app.bottom_pane_h = std.math.clamp(app.bottom_pane_h, BOTTOM_PANE_MIN, bottom_max);

    ctx.beginBox(.{
        .direction = .column,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .{ 4, 4, 4, 4 },
        .gap = 4,
    });

    // ── 1 段目: menu bar ──
    ctx.beginBox(.{
        .direction = .row,
        .width = .{ .grow = 1 },
        .padding = .{ 4, 4, 4, 4 },
        .gap = 5, // TASK-63: プロジェクトボタン 2 個追加で横溢れするため 8→5 に詰める
        .bg = gui.Color.rgba(0x28, 0x28, 0x30, 0xFF),
    });
    if (ctx.button("Open")) app.pending_file_op = .open;
    if (ctx.button("Save")) app.pending_file_op = .save;
    if (ctx.button("Save As")) app.pending_file_op = .save_as;
    // .pix プロジェクト（レイヤー保持）。PNG 保存とは別（TASK-63）。ラベルは "Pal" と対の短縮 "Prj"
    if (ctx.button("Prj Open")) app.pending_file_op = .open_project;
    if (ctx.button("Prj Save")) app.pending_file_op = .save_project;
    if (ctx.button("Undo")) app.doUndo() catch {};
    if (ctx.button("Redo")) app.doRedo() catch {};
    if (ctx.button("Pal Save")) app.pending_file_op = .save_palette;
    if (ctx.button("Pal Load")) app.pending_file_op = .load_palette;
    // ペイン表示トグル（TASK-42）
    if (ctx.buttonEx("Panel", .{ .selected = app.right_visible }).clicked) app.right_visible = !app.right_visible;
    if (ctx.buttonEx("Timeline", .{ .selected = app.bottom_visible }).clicked) app.bottom_visible = !app.bottom_visible;
    ctx.endBox();

    // ── main area: content row(canvas + 右ペイン) + 任意の下ペイン（TASK-42。縦分割の基準 ID） ──
    ctx.beginBox(.{ .id = MAIN_AREA_ID, .direction = .column, .width = .{ .grow = 1 }, .height = .{ .grow = 1 }, .gap = 0 });

    // content row: canvas(grow) + [splitter + right pane]。gap=0 で splitter を境界帯にする（横分割の基準 ID）。
    ctx.beginBox(.{ .id = CONTENT_ROW_ID, .direction = .row, .width = .{ .grow = 1 }, .height = .{ .grow = 1 }, .gap = 0 });

    // canvas area: 明示 ID・中身空（blit は endFrame 後に別パスで行う）。bg なし（canvas を上塗りしない）。
    ctx.beginBox(.{ .id = CANVAS_AREA_ID, .width = .{ .grow = 1 }, .height = .{ .grow = 1 } });
    ctx.endBox();

    if (app.right_visible) {
        _ = ctx.splitter(SPLIT_RIGHT_ID, .vertical, &app.right_pane_w, .{ .thickness = SPLITTER_T, .min = RIGHT_PANE_MIN, .max = right_max, .invert = true });
        // right pane: Color / Palette / Tool / Layers を縦スクロール領域に入れる（TASK-46）。
        // content_width=grow で content を viewport 幅いっぱい（横スクロール不要）、高さは fit で縦スクロール。
        ctx.beginScrollArea(RIGHT_SCROLL_ID, &app.right_scroll, .{
            .width = .{ .fixed = app.right_pane_w },
            .height = .{ .grow = 1 },
            .padding = .{ 8, 8, 8, 8 },
            .gap = 6,
            .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF),
            .content_width = .{ .grow = 1 },
        });
        // ── カラーエディタ（HSV）。grid より前に write-back する（選択変更の上書き事故回避） ──
        ctx.label("Color");
        ctx.beginBox(.{ .direction = .row, .gap = 8, .align_cross = .start });
        _ = ctx.svSquareId(0xCED10001, app.edit_h, &app.edit_s, &app.edit_v, .{ .size = 120 });
        _ = ctx.hueBarId(0xCED10002, &app.edit_h, .{ .h = 120 });
        ctx.endBox();
        _ = ctx.sliderF32Id(0xCED10003, "H", &app.edit_h, .{ .min = 0, .max = 360, .step = 1, .track_w = 96 });
        _ = ctx.sliderF32Id(0xCED10004, "S", &app.edit_s, .{ .min = 0, .max = 1, .step = 0.01, .track_w = 96 });
        _ = ctx.sliderF32Id(0xCED10005, "V", &app.edit_v, .{ .min = 0, .max = 1, .step = 0.01, .track_w = 96 });
        app.edit_h = @min(app.edit_h, 360 - 1e-3); // hueBar と同じ [0,360) 契約
        app.applyEditColor(); // 編集中 HSV → 選択スウォッチ色 + pen.color（grid クリックより前）

        // ── 編集可能パレット（可変長スウォッチ + 追加/削除） ──
        ctx.label("Palette");
        {
            var idx: usize = 0;
            while (idx < app.palette.colors.items.len) {
                ctx.beginBox(.{ .direction = .row, .gap = 3 });
                var col: u32 = 0;
                while (col < 4 and idx < app.palette.colors.items.len) : (col += 1) {
                    const swatch_id: gui.Id = 0x1000 + @as(gui.Id, idx);
                    if (ctx.colorSwatchId(swatch_id, .{
                        .color = guiColor(app.palette.colors.items[idx]),
                        .selected = idx == app.palette.selected,
                        .size = 22,
                    }).clicked) {
                        app.palette.select(idx); // HSV は次フレームで再同期
                        if (app.active_kind == .eraser) app.setActiveKind(.pen); // 色は pen 用（brush/bezier は維持）
                    }
                    idx += 1;
                }
                ctx.endBox();
            }
        }
        ctx.beginBox(.{ .direction = .row, .gap = 4 });
        if (ctx.buttonEx("+", .{ .min_w = 28 }).clicked) {
            app.palette.addColor(app.gpa, app.palette.current()) catch {};
        }
        if (ctx.buttonEx("-", .{ .min_w = 28 }).clicked) {
            app.palette.removeSelected();
            // 非末尾削除で index が詰まると selected が同値のまま別色を指す。
            // edit_synced_for を無効化し、次フレームで現 current 色から HSV 再同期する
            // （さもないと applyEditColor が旧 HSV で新色を上書きする）。
            app.edit_synced_for = null;
        }
        ctx.endBox();

        ctx.label("Tool");
        // 7 ツールは右ペイン幅に収めるため 2 個ずつ折り返す（TASK-68 で Eyedrop 追加・奇数個なので最終行は単独）
        ctx.beginBox(.{ .direction = .row, .gap = 4 });
        if (ctx.buttonEx("Pen", .{ .selected = app.active_kind == .pen, .min_w = 56 }).clicked) app.setActiveKind(.pen);
        if (ctx.buttonEx("Eraser", .{ .selected = app.active_kind == .eraser, .min_w = 56 }).clicked) app.setActiveKind(.eraser);
        ctx.endBox();
        ctx.beginBox(.{ .direction = .row, .gap = 4 });
        if (ctx.buttonEx("Brush", .{ .selected = app.active_kind == .brush, .min_w = 56 }).clicked) app.setActiveKind(.brush);
        if (ctx.buttonEx("Bezier", .{ .selected = app.active_kind == .bezier, .min_w = 56 }).clicked) app.setActiveKind(.bezier);
        ctx.endBox();
        ctx.beginBox(.{ .direction = .row, .gap = 4 });
        if (ctx.buttonEx("Select", .{ .selected = app.active_kind == .select, .min_w = 56 }).clicked) app.setActiveKind(.select);
        if (ctx.buttonEx("Fill", .{ .selected = app.active_kind == .fill, .min_w = 56 }).clicked) app.setActiveKind(.fill);
        ctx.endBox();
        ctx.beginBox(.{ .direction = .row, .gap = 4 });
        if (ctx.buttonEx("Eyedrop", .{ .selected = app.active_kind == .eyedropper, .min_w = 56 }).clicked) app.setActiveKind(.eyedropper);
        ctx.endBox();
        ctx.labelEx("(Alt+click = temp eyedrop)", ctx.style.text_subtle);
        // paste/move のブロック配置トグル（gui.toggle スイッチ。TASK-48）。
        // ON=透明を保持(src-over・下の絵を残す) / OFF=上書き(replace)。
        var keep_transp = app.blend_mode == .over;
        if (ctx.toggle("Keep Transp", &keep_transp)) {
            app.blend_mode = if (keep_transp) .over else .replace;
        }
        // Brush/Bezier 選択時に Size/Opacity/Hardness の Slider を表示（bezier も同じブラシ設定で描く）
        if (app.active_kind == .brush or app.active_kind == .bezier) {
            _ = ctx.sliderI32Id(0xB0_0001, "Size", &app.brush_size_i32, .{ .min = 1, .max = 64, .track_w = 90 });
            _ = ctx.sliderI32Id(0xB0_0002, "Opac", &app.brush_opacity_i32, .{ .min = 0, .max = 255, .track_w = 90 });
            _ = ctx.sliderF32Id(0xB0_0003, "Hard", &app.brush_hardness_f32, .{ .min = 0, .max = 1, .step = 0.05, .track_w = 90 });
        }
        // UI 状態 → Brush（毎フレーム clamp/変換。型差吸収）
        app.brush.size = @intCast(std.math.clamp(app.brush_size_i32, 1, 64));
        app.brush.opacity = @intCast(std.math.clamp(app.brush_opacity_i32, 0, 255));
        app.brush.hardness_q = @intFromFloat(std.math.clamp(app.brush_hardness_f32, 0, 1) * 255 + 0.5);

        // Fill 選択時に色許容差(Tol)の Slider を表示（TASK-76）
        if (app.active_kind == .fill) {
            _ = ctx.sliderI32Id(0xFEED_0001, "Tol", &app.fill_tolerance_i32, .{ .min = 0, .max = 255, .track_w = 90 });
        }
        // UI 状態 → Fill（毎フレーム clamp/変換。型差吸収）
        app.fill.tolerance = @intCast(std.math.clamp(app.fill_tolerance_i32, 0, 255));

        try buildLayerPanel(ctx, app);
        ctx.endScrollArea(); // right pane (縦スクロール)
    } // right_visible

    ctx.endBox(); // content row

    // ── 下ペイン（タイムライン枠。中身は Phase5。TASK-42 はリサイズ/トグル枠のみ） ──
    if (app.bottom_visible) {
        _ = ctx.splitter(SPLIT_BOTTOM_ID, .horizontal, &app.bottom_pane_h, .{ .thickness = SPLITTER_T, .min = BOTTOM_PANE_MIN, .max = bottom_max, .invert = true });
        ctx.beginBox(.{
            .direction = .row,
            .width = .{ .grow = 1 },
            .height = .{ .fixed = app.bottom_pane_h },
            .padding = .{ 6, 8, 6, 8 },
            .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF),
            .clip_children = true,
        });
        ctx.labelEx("Timeline (placeholder)", ctx.style.text_subtle);
        ctx.endBox(); // bottom pane
    }

    ctx.endBox(); // main area

    // ── 4 段目: status bar ──
    ctx.beginBox(.{
        .direction = .row,
        .width = .{ .grow = 1 },
        .padding = .{ 2, 6, 2, 6 },
        .gap = 16,
        .bg = gui.Color.rgba(0x28, 0x28, 0x30, 0xFF),
    });
    const arena = ctx.allocator();
    // cursor の canvas 座標（表示領域外は "-"）。rect は前フレーム値（同期 hit-test 契約と同じ）
    const cursor_txt = blk: {
        if (canvas_rect) |rect| {
            if (core.screenToCanvas(
                .{ .x = ctx.input.mouse_pos.x, .y = ctx.input.mouse_pos.y },
                rect,
                app.view_zoom,
            )) |cp| {
                break :blk try std.fmt.allocPrint(arena, "cursor: ({d}, {d})", .{ cp.x, cp.y });
            }
        }
        break :blk "cursor: -";
    };
    ctx.labelEx(cursor_txt, ctx.style.text_subtle);
    {
        const c = app.palette.current();
        // canonical BGRA(0xAARRGGBB) から #RRGGBB 用に明示抽出。
        const r: u8 = @truncate(c >> 16);
        const g: u8 = @truncate(c >> 8);
        const b: u8 = @truncate(c);
        ctx.labelEx(
            try std.fmt.allocPrint(arena, "color: #{X:0>2}{X:0>2}{X:0>2} ({d})", .{ r, g, b, app.palette.colors.items.len }),
            ctx.style.text_subtle,
        );
    }
    ctx.labelEx(
        try std.fmt.allocPrint(arena, "tool: {s}", .{app.active_kind.name()}),
        ctx.style.text_subtle,
    );
    ctx.labelEx(
        try std.fmt.allocPrint(arena, "layer: {d}/{d}", .{ app.canvas.selected_layer + 1, app.canvas.layers.items.len }),
        ctx.style.text_subtle,
    );
    ctx.labelEx(
        try std.fmt.allocPrint(arena, "zoom: {d}%", .{app.view_zoom * 100}),
        ctx.style.text_subtle,
    );
    if (app.active_kind == .brush or app.active_kind == .bezier) {
        ctx.labelEx(
            try std.fmt.allocPrint(arena, "brush: sz={d} op={d} hard={d:.2}", .{
                app.brush.size, app.brush.opacity, app.brush_hardness_f32,
            }),
            ctx.style.text_subtle,
        );
    }
    if (app.active_kind == .fill) {
        ctx.labelEx(
            try std.fmt.allocPrint(arena, "fill: tol={d}", .{app.fill.tolerance}),
            ctx.style.text_subtle,
        );
    }
    if (app.active_kind == .bezier and app.bezier_editor.isEditing()) {
        ctx.labelEx(
            try std.fmt.allocPrint(arena, "anchors: {d}", .{app.bezier_editor.path.anchors.items.len}),
            ctx.style.text_subtle,
        );
    }
    if (app.saveMsg()) |msg| ctx.label(msg);
    ctx.endBox();

    ctx.endBox(); // root
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    try platform.init();
    defer platform.shutdown();

    const window = try platform.Window.create(WINDOW_W, WINDOW_H, "Pixie");
    defer window.destroy();

    var ctx = gui.Context.init(gpa, gui.default_font);
    defer ctx.deinit();

    var app: App = .{
        .io = init.io,
        .gpa = gpa,
        .doc = try core.Document.init(gpa, CANVAS_W, CANVAS_H),
        .recorder = try core.StrokeRecorder.init(gpa, CANVAS_W, CANVAS_H),
        .preview_canvas = try core.Canvas.init(gpa, CANVAS_W, CANVAS_H),
        .preview_rec = try core.StrokeRecorder.init(gpa, CANVAS_W, CANVAS_H),
        .palette = try palette_mod.Palette.initDb16(gpa),
        .pen = .{ .color = 0 },
        .brush = .{ .color = 0 },
        .fill = .{ .color = 0 },
    };
    app.canvas = app.doc.activeCanvas(); // doc の frame 0 canvas を指す（ポインタ安定）
    app.pen.color = app.palette.current(); // 初期描画色 = パレット先頭
    app.brush.color = app.palette.current();
    app.fill.color = app.palette.current();
    defer {
        if (app.current_path) |p| gpa.free(p);
        if (app.current_project_path) |p| gpa.free(p);
        if (app.palette_path) |p| gpa.free(p);
        if (app.clipboard) |*cb| cb.deinit(gpa);
        app.sel_in.deinit(gpa);
        app.bezier_editor.deinit(gpa);
        app.preview_rec.deinit(gpa);
        app.preview_canvas.deinit();
        app.palette.deinit(gpa);
        app.undo.deinit(gpa);
        app.recorder.deinit(gpa);
        app.doc.deinit();
    }

    // ヘッドレス検証 harness の custom probe を登録（harness 無効時は no-op）。
    platform.registerProbe(.{ .name = "canvas", .ctx = &app, .ext = "png", .snapshot = canvasSnapshot, .digest = canvasDigest });
    platform.registerProbe(.{ .name = "undo", .ctx = &app, .ext = "json", .snapshot = undoSnapshot, .digest = undoDigest });
    platform.registerProbe(.{ .name = "tool", .ctx = &app, .ext = "txt", .snapshot = toolSnapshot, .digest = toolDigest });
    platform.registerProbe(.{ .name = "cursor", .ctx = &app, .ext = "txt", .snapshot = cursorSnapshot, .digest = cursorDigest });
    // ヘッドレス検証 harness の custom action を登録（harness 無効時は no-op。TASK-64）。
    registerActions(&app);

    main_loop: while (app.running and window.pollEvents()) {
        // フレーム処理は内側ブロックに閉じ、ブロックを抜けたところで framebuffer を unlock する。
        // ファイルダイアログ（モーダル）は lock 中に呼ぶと再入で危険なので、ここでは pending を
        // セットするだけにし、unlock 後の安全点（下の runPendingFileOp）で実行する。
        {
            const fb = window.lockFramebuffer() orelse continue :main_loop;
            defer fb.unlock();

            ctx.beginFrame(fb.width, fb.height);

            while (window.nextEvent()) |ev| {
                switch (ev) {
                    .quit => app.running = false, // ウィンドウクローズも同一経路
                    .key_down => |k| app.handleKey(k),
                    .key_up => |k| app.handleKeyUp(k),
                    else => {},
                }
                if (toGuiEvent(ev)) |ge| ctx.pushEvent(ge);
            }

            // canvas rect は前フレームの layout 結果（初回フレームは null）。
            // canvasBlitRect は pan を現 area に clamp して app へ書き戻し、last_area も更新する。
            var canvas_rect = canvasBlitRect(&ctx, &app);

            try buildUi(&ctx, &app, canvas_rect);
            ctx.endFrame();

            // ── ビューポート: ホイールズーム（カーソル中心）/ パン（Space+左 or middle ドラッグ）──
            // パン中は描画入力を抑止（既存 stroke 完走を妨げないよう pan は capturing 中に開始しない）。
            const panning = updateViewport(&app, &ctx, canvas_rect);
            // zoom/pan が変わり得たので、当フレームの入力・描画が「旧 rect + 新 zoom」で不整合に
            // ならないよう rect を再計算する（endFrame 後なので area は当フレームの layout 結果）。
            canvas_rect = canvasBlitRect(&ctx, &app);

            // ── canvas 入力。capturing 最優先（既存 stroke を完走）。bezier は独立経路 ──
            if (!panning) {
                const in = &ctx.input;
                // 新規 stroke 開始の gate（TASK-42）: press が canvas area(last_area) 内 かつ gui（widget/
                // splitter）が press を取っていない（!wantsMouse）時だけ新規開始を許可。進行中 stroke は
                // pressed_left のみ落として update は通し、release を届けて完走させる（capturing 張り付き防止）。
                const pressed_left_gated = in.mouse_pressed.left and gate: {
                    const p = in.mouse_pressed_pos;
                    const in_area = if (app.last_area) |a|
                        (p.x >= a.x and p.y >= a.y and p.x < a.x + a.w and p.y < a.y + a.h)
                    else
                        false;
                    // active_id==0 = どの widget/splitter も press を取っていない（hover だけの wantsMouse は
                    // 抑止しない＝canvas 内 press → 同一フレーム UI 上へ move でも stroke は開始できる）。
                    // !hasOpenPopup() = レイヤー右クリックメニュー（TASK-79.2）表示中は新規 stroke を
                    // 開始しない（popup は active_id を 0 のまま保つため、上の条件だけでは防げない。
                    // popup.zig の wantsMouse() が popup_state を OR しているのと同じ理由）。
                    break :gate in_area and ctx.state.active_id == 0 and !ctx.hasOpenPopup();
                };
                if (app.active_kind == .bezier and !app.input.capturing) {
                    const frame: bezier_input.BezierInput.Frame = .{
                        .canvas_rect = canvas_rect,
                        .zoom = app.view_zoom,
                        .mouse_pos = .{ .x = in.mouse_pos.x, .y = in.mouse_pos.y },
                        .mouse_pressed_pos = .{ .x = in.mouse_pressed_pos.x, .y = in.mouse_pressed_pos.y },
                        .pressed_left = pressed_left_gated,
                        .released_left = in.mouse_released.left,
                        .time = platform.getTime(),
                    };
                    const dab = app.brush.footprint();
                    if (app.bez_in.update(frame, &app.bezier_editor, app.canvas, &app.recorder, gpa, dab, app.brush.color, app.brush.opacity)) |cmd| {
                        app.undo.push(gpa, .{ .frame = app.doc.selected_frame, .op = cmd });
                    }
                } else if (app.active_kind == .select and !app.input.capturing) {
                    const frame: selection_input.SelectionInput.Frame = .{
                        .canvas_rect = canvas_rect,
                        .zoom = app.view_zoom,
                        .mouse_pos = .{ .x = in.mouse_pos.x, .y = in.mouse_pos.y },
                        .mouse_pressed_pos = .{ .x = in.mouse_pressed_pos.x, .y = in.mouse_pressed_pos.y },
                        .pressed_left = pressed_left_gated,
                        .released_left = in.mouse_released.left,
                    };
                    if (app.sel_in.update(frame, app.canvas, app.canvas.selected_layer, gpa, app.blend_mode)) |cmd| {
                        app.undo.push(gpa, .{ .frame = app.doc.selected_frame, .op = cmd });
                    }
                } else if (app.eye_in.picking or app.active_kind == .eyedropper or
                    (pressed_left_gated and in.modifiers.alt))
                {
                    // スポイト（独立経路。TASK-68）。専用ツール選択中、または進行中の picking を完走、
                    // または Alt+クリックの一時スポイト（bezier/select は上の分岐で既に弾かれているので
                    // ここに来る active_kind は pen/eraser/brush/fill/eyedropper のいずれか。4ツール
                    // 全てで Alt+クリックを一律有効にする最小の場合分け）。
                    const frame: eyedropper_input.EyedropperInput.Frame = .{
                        .canvas_rect = canvas_rect,
                        .zoom = app.view_zoom,
                        .mouse_pos = .{ .x = in.mouse_pos.x, .y = in.mouse_pos.y },
                        .mouse_pressed_pos = .{ .x = in.mouse_pressed_pos.x, .y = in.mouse_pressed_pos.y },
                        .pressed_left = pressed_left_gated,
                        .released_left = in.mouse_released.left,
                    };
                    if (app.eye_in.update(frame)) |cp| {
                        app.pickColor(cp.x, cp.y);
                    }
                } else {
                    const frame: canvas_input.CanvasInput.Frame = .{
                        .canvas_rect = canvas_rect,
                        .zoom = app.view_zoom,
                        .mouse_pos = .{ .x = in.mouse_pos.x, .y = in.mouse_pos.y },
                        .mouse_pressed_pos = .{ .x = in.mouse_pressed_pos.x, .y = in.mouse_pressed_pos.y },
                        .pressed_left = pressed_left_gated,
                        .released_left = in.mouse_released.left,
                    };
                    if (app.input.update(frame, app.activeTool(), app.canvas, &app.recorder, gpa)) |cmd| {
                        app.undo.push(gpa, .{ .frame = app.doc.selected_frame, .op = cmd });
                    }
                }
            }

            // ── ソフトオーバーレイ用 hover 追跡 + OS カーソル形状の M1 配線（TASK-75.4）。
            // 入力ディスパッチの後に置くことで、当フレームで新規 stroke が始まった場合の busy 判定
            // （isPointerBusy）を正しく反映する（描画パスで footprint リングが一瞬出ることを防ぐ）。
            updateCursorAndHover(&app, window, &ctx, canvas_rect);

            // ── 描画: bg → チェッカー背景 → canvas blit(α src-over) → GUI（上に重ねる） ──
            @memset(fb.pixels, COLOR_WINDOW_BG);
            if (canvas_rect) |rect| {
                if (app.last_area) |area| {
                    const zoom = app.view_zoom;
                    // 表示矩形（screen px 実寸。canvasBlitRect の rect.w/h は canvas px なので zoom 倍）
                    const screen_rect: core.Rect = .{
                        .x = rect.x,
                        .y = rect.y,
                        .w = @as(i32, @intCast(CANVAS_W)) * zoom,
                        .h = @as(i32, @intCast(CANVAS_H)) * zoom,
                    };
                    blit.drawCheckerboard(fb.pixels, fb.width, fb.height, screen_rect, area);
                    if (app.active_kind == .bezier and app.bezier_editor.isEditing()) {
                        // 確定前ブラシプレビュー: 本 canvas 全 layer のコピーへ path(+仮点)を実ブラシ描画して表示（非破壊）
                        app.syncPreviewCanvas();
                        const dab = app.brush.footprint();
                        app.bezier_editor.rasterizePreview(&app.preview_canvas, &app.preview_rec, gpa, dab, app.brush.color, app.brush.opacity);
                        blit.blitCanvasZoom(fb.pixels, fb.width, fb.height, app.preview_canvas.compositeStraight(), CANVAS_W, CANVAS_H, rect, zoom, area);
                    } else if (app.active_kind == .select and app.sel_in.state == .moving) {
                        // フローティング move プレビュー: 実 canvas は不変のまま、preview_canvas の選択レイヤーへ
                        // 「base+block@現在位置（blend_mode 合成）」を描いて表示する（確定は release）。
                        app.syncPreviewCanvas();
                        _ = app.sel_in.renderMovePreview(app.preview_canvas.layerPixels(app.canvas.selected_layer), CANVAS_W, CANVAS_H, app.blend_mode);
                        blit.blitCanvasZoom(fb.pixels, fb.width, fb.height, app.preview_canvas.compositeStraight(), CANVAS_W, CANVAS_H, rect, zoom, area);
                    } else {
                        blit.blitCanvasZoom(fb.pixels, fb.width, fb.height, app.canvas.compositeStraight(), CANVAS_W, CANVAS_H, rect, zoom, area);
                    }
                }
            }
            // ベジェ編集中のハンドル/アンカー UI を draw_list へ（プレビューの上、gui.render で焼かれる。area で clip）
            if (app.active_kind == .bezier) {
                if (canvas_rect) |rect| if (app.last_area) |area| {
                    const clip_area: gui.Rect = .{ .x = area.x, .y = area.y, .w = @intCast(area.w), .h = @intCast(area.h) };
                    bezier_overlay.draw(&ctx, &app.bezier_editor, rect, app.view_zoom, clip_area);
                };
            }
            // 範囲選択のマーチングアンツ（選択があれば常時表示。select ツール時はドラッグ中の preview を優先）
            {
                const display_sel: ?core.Rect = if (app.active_kind == .select)
                    (app.sel_in.previewRect(app.canvas) orelse app.canvas.selection)
                else
                    app.canvas.selection;
                if (display_sel != null) {
                    if (canvas_rect) |rect| if (app.last_area) |area| {
                        const clip_area: gui.Rect = .{ .x = area.x, .y = area.y, .w = @intCast(area.w), .h = @intCast(area.h) };
                        // phase は時間由来。MARCH_PERIOD(=2*DASH) で mod し i32 overflow を防ぐ（パターンは保存）。
                        const phase: i32 = @intFromFloat(@mod(platform.getTime() * MARCH_SPEED, MARCH_PERIOD));
                        selection_overlay.draw(&ctx, display_sel, rect, app.view_zoom, clip_area, phase);
                    };
                }
            }
            // ツールグリフ + ブラシ footprint 輪郭リング（ソフトオーバーレイ最前面。TASK-75.4）。
            // hover_screen は「in_canvas かつ非 busy」の時だけ Some（updateCursorAndHover 参照）なので、
            // stroke/選択ドラッグ/ベジェドラッグ/パン中はここに来ない。
            if (app.hover_screen) |hs| {
                if (app.last_area) |area| {
                    const clip_area: gui.Rect = .{ .x = area.x, .y = area.y, .w = @intCast(area.w), .h = @intCast(area.h) };
                    const glyph = app.active_kind.glyph();
                    cursor_overlay.drawGlyph(&ctx, .{ .x = hs.x, .y = hs.y }, glyph.label, glyph.color, clip_area);
                    if (app.active_kind == .brush) {
                        if (app.hover_cell) |hc| if (canvas_rect) |rect| {
                            app.brush_edges.refresh(&app.brush);
                            cursor_overlay.drawRing(&ctx, &app.brush_edges, hc, rect, app.view_zoom, clip_area, RING_COLOR_A, RING_COLOR_B);
                        };
                    }
                }
            }
            // レイヤー右クリックコンテキストメニュー（TASK-79.2）。popup.zig の「endFrame 後」契約
            // + 他のオーバーレイ（bezier/selection/cursor）より後に呼ぶことで最前面に描画される。
            // 呼び出しは毎フレーム無条件でよい（対象 popup が閉じていれば no-op で即返る。
            // popup.zig の doc comment 参照）。items は selected_layer の現在値から都度算出する
            // （右クリック時に doSelectLayer 済みなので、以降の全項目は selected_layer に対して動く）。
            {
                const items = [_]gui.PopupItem{
                    .{ .label = "Add Layer" },
                    .{ .label = "Delete Layer", .enabled = app.canvas.layers.items.len > 1 },
                    .{ .label = "Move Up", .enabled = app.canvas.selected_layer + 1 < app.canvas.layers.items.len },
                    .{ .label = "Move Down", .enabled = app.canvas.selected_layer > 0 },
                    .{ .label = if (app.canvas.layers.items[app.canvas.selected_layer].visible) "Hide" else "Show" },
                    .{ .label = "Duplicate" },
                    .{ .label = "Merge Down", .enabled = app.canvas.selected_layer > 0 },
                    .{ .label = "Rename...", .enabled = false }, // placeholder（TASK-79.3 で実装）
                    .{ .label = "Rasterize", .enabled = false }, // placeholder（TASK-79.5 で実装）
                };
                const ctx_menu_result = ctx.popupMenu(LAYER_CTX_MENU_ID, &items);
                if (ctx_menu_result.selected) |sel| {
                    switch (sel) {
                        0 => app.doAddLayer() catch {},
                        1 => app.doDeleteLayer() catch {},
                        2 => app.doMoveLayer(1) catch {},
                        3 => app.doMoveLayer(-1) catch {},
                        4 => app.doToggleLayerVisible(app.canvas.selected_layer),
                        5 => app.doDuplicateLayer() catch {},
                        6 => app.doMergeDown() catch {},
                        else => {}, // Rename/Rasterize は disabled 固定のためここへは来ない
                    }
                }
            }
            gui.render(
                .{ .pixels = fb.pixels, .width = fb.width, .height = fb.height },
                &ctx.draw_list,
                ctx.font,
            );
            window.present();
        } // ← ここで framebuffer unlock

        // 安全点: framebuffer unlock 済み・当フレームの入力更新も完了。ここでモーダルを開く。
        // 終了要求と同フレームで保存/読込が pending でも、終了中はダイアログを開かない。
        if (app.running) app.runPendingFileOp();
    }
}
