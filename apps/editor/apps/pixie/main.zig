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
const fontmod = kit.font; // system font ランタイム読込（TASK-82。examples/12・21 と同じ消費方式）
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
const layer_rename_input = @import("layer_rename_input.zig");
const text_content_input = @import("text_content_input.zig");

// レイヤー名の最大長は libs/paint（保存側）と pixie（編集バッファ側）で独立定義しているため
// （循環 import 回避。詳細は layer_rename_input.zig 冒頭）、乖離しないことを comptime で保証する。
comptime {
    if (core.layer_name_max != layer_rename_input.max_len) {
        @compileError("layer_name_max mismatch between paint.Canvas and layer_rename_input");
    }
}
// テキストレイヤー内容の最大長も同様に独立定義しているため乖離しないことを保証する（TASK-79.5）。
comptime {
    if (core.text_content_max != text_content_input.max_len) {
        @compileError("text_content_max mismatch between paint.Canvas and text_content_input");
    }
}
// brush size 上限も actions.zig（std のみ）と paint 側で独立定義しているため乖離を防ぐ（TASK-62.5.3）。
comptime {
    if (actions.MAX_BRUSH_SIZE != core.Brush.MAX_SIZE) {
        @compileError("MAX_BRUSH_SIZE mismatch between actions.zig and paint.Brush");
    }
}

// ── system font ランタイム読込（TASK-82）───────────────────────────
//
// テキストレイヤーの日本語(CJK)表示のため、TASK-79.4 が同梱した embedded フォント
// （Press Start 2P。ASCII のみ）に代えて OS の system font を優先的に使う。方式は
// `examples/12_outline_font`/`examples/21_char_input` と同一（日本語 `.ttc` を優先候補にし、
// ASCII フォントへフォールバック。再配布ではないのでライセンス問題なし）。
// この候補パス配列・読込ロジックは examples 側と重複するが、pixie は kit-only 消費者（apps は
// libs 非直 import、ADR-007 R5）で examples は独立ビルドツリーのため、共有モジュール化すると
// 新規の共通 helper lib が要りスコープ超過になる。将来 libs/font 側に格上げする際に統合を検討する。
const system_font_paths = [_][]const u8{
    // macOS: 日本語 .ttc（ASCII も含むので 1 本で混在描画可）→ ASCII フォールバック
    "/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc",
    "/System/Library/Fonts/ヒラギノ角ゴシック W4.ttc",
    "/System/Library/Fonts/ヒラギノ明朝 ProN.ttc",
    "/System/Library/Fonts/Supplemental/Andale Mono.ttf",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/System/Library/Fonts/Supplemental/Times New Roman.ttf",
    "/Library/Fonts/Arial.ttf",
    // Windows: 日本語 → ASCII
    "C:/Windows/Fonts/YuGothM.ttc",
    "C:/Windows/Fonts/meiryo.ttc",
    "C:/Windows/Fonts/msgothic.ttc",
    "C:/Windows/Fonts/arial.ttf",
    "C:/Windows/Fonts/segoeui.ttf",
    "C:/Windows/Fonts/consola.ttf",
    // Linux（Ubuntu / nix）: 日本語(CJK) → ASCII
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
};

/// 候補パスを順に読み `fontmod.FontFace.init` で parse 検証し、最初に成功したものの
/// bytes（所有権は呼び出し側へ移譲）を返す。**FontFace 自体は保持しない**（検証のみ。
/// `text_render.rasterizeTextLayer` は毎回 fresh に `FontFace.init(bytes)` するため
/// 十分軽く、Canvas に借用参照として渡す bytes だけキャッシュすれば良い。TASK-82）。
/// 全候補が失敗（FileNotFound 含む）した場合は `null`（呼び出し側は embedded ASCII フォントへ
/// フォールバックする）。initialization 時のみ呼ばれる（ホットパス外）。
fn loadSystemFontBytes(io: std.Io, gpa: std.mem.Allocator) ?[]u8 {
    for (system_font_paths) |path| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err| {
            if (err != error.FileNotFound) std.debug.print("system font read {s}: {s}\n", .{ path, @errorName(err) });
            continue;
        };
        const face = fontmod.FontFace.init(bytes) catch |err| {
            std.debug.print("system font parse {s}: {s}\n", .{ path, @errorName(err) });
            gpa.free(bytes);
            continue;
        };
        _ = face; // 検証のみ（保持しない）
        std.debug.print("system font: loaded {s} ({d} bytes)\n", .{ path, bytes.len });
        return bytes;
    }
    return null;
}

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
/// テキストレイヤー編集パネル（TASK-79.5）の明示 ID 群。
const TEXT_PANEL_ID_BASE: gui.Id = 0xA430_3000;
/// レイヤー行 box 自身の明示 ID に使う `layerWidgetId` part（0..3 は既存: 0=選択ボタン/1=可視
/// トグル/2=opacity slider/3=サムネ）。右クリックのヒットテストは行全体の矩形を使う。
const LAYER_ROW_PART_ROW: gui.Id = 4;
// レイヤーパネルのサムネイル（raw layer をチェッカー下地へ最近傍縮小・等倍 blit）
const LAYER_THUMB_W: i32 = 24;
const LAYER_THUMB_H: i32 = 24;
const LAYER_THUMB_CELL: usize = 4; // サムネ内チェッカーのセル px
/// タイムライン UI（TASK-45.2）
const TIMELINE_SCROLL_ID: gui.Id = 0xC0FFEE07;
const TIMELINE_PANEL_ID_BASE: gui.Id = 0xA440_0000;
const TIMELINE_HEADER_ID_BASE: gui.Id = 0xA441_0000;
const TIMELINE_CELL_ID_BASE: gui.Id = 0xA442_0000;
const TIMELINE_CELL_FRAME_STRIDE: gui.Id = 4096;
const TIMELINE_CELL_W: i32 = 24;
const TIMELINE_CELL_H: i32 = 24;
const TIMELINE_LABEL_W: i32 = 72;
const TIMELINE_LINK_BORDER = gui.Color.rgba(0x40, 0xA0, 0xE0, 0xFF);
const TIMELINE_PLAYHEAD_BORDER = gui.Color.rgba(0xE0, 0xC0, 0x40, 0xFF);

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
        .gamepad_connected, .gamepad_disconnected => null, // TASK-80.1: pixie 未消費（cross-cutting Event 追加。他機能は無改造）
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
    /// system font（TASK-82）バイト列への **borrowed** view。実体の所有・解放は `main()` の
    /// ローカル変数側（起動時に一度だけ `loadSystemFontBytes` で読み込み、`main()` の defer で
    /// 解放する。App はこのフィールドで参照するだけで free しない）。`applySystemFont()` が
    /// `doc.frames` の各 Canvas へこの値を伝播する。見つからない/parse 失敗環境では `null`
    /// のままで、`text_render` 側が embedded ASCII フォントへフォールバックする。
    system_font_bytes: ?[]const u8 = null,
    recorder: core.StrokeRecorder,
    /// ベジェ編集中のブラシプレビュー用一時 canvas/recorder（本 layer のコピーへ非破壊描画）
    preview_canvas: core.Canvas,
    preview_rec: core.StrokeRecorder,
    // undo は独立フィールドを廃止し `doc.undo` を経由する（TASK-45.1。plan 8.3節）。
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
    /// タイムライン UI 状態（TASK-45.2）
    timeline_scroll: gui.Vec2f = .{},
    timeline_playing: bool = false,
    timeline_fps: f32 = 10.0,
    timeline_last_advance: f64 = 0,
    timeline_target_layer: usize = 0,
    timeline_target_frame: u32 = 0,
    /// オニオンスキン（TASK-45.3）。表示専用。
    onion_enabled: bool = false,
    onion_count: u32 = 1,
    onion_buf: []u32 = &.{},
    onion_scratch: []u32 = &.{},
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
    /// レイヤー名インライン編集の状態機械（TASK-79.3）。`rename_in.active` が true の間、
    /// メインループのイベントポンプは char_input/ENTER/ESCAPE/BACKSPACE のみをここへ回し、
    /// 他のキー・gui への pushEvent は止める（タイプ中に B/E 等のツール切替が誤発火しないため）。
    rename_in: layer_rename_input.LayerRenameInput = .{},
    /// テキストレイヤー内容インライン編集の状態機械（TASK-79.5）。`rename_in` と対称
    /// （どちらか一方のみ active。`beginTextEdit`/`beginRenameLayer` が互いを明示的に cancel する）。
    text_in: text_content_input.TextContentInput = .{},

    /// ── command model（TASK-62.5.3）。「誰が（local_user/local_agent）・何を実行したか」の単一 log ──
    /// 常時有効・固定容量（alloc なし）。transport の有無に依存しない（harness replay でも copilot
    /// でも通常起動でも同じ経路）。記録はイベント時のみ（ホットパス外）。
    cmd_log: platform.command.CommandLog = .{},
    /// dispatcher/log は main() で配線する（ctx に &app が要るため field default にできない）。
    cmd_exec: platform.command.Executor = undefined,
    /// UI stroke（canvas_input 経由）の点列蓄積（§5c。press〜release のイベント時 append・固定上限は
    /// actions.MAX_STROKE_POINTS を共有）。連続同一点は追加しない（同一点 move は描画上 no-op）。
    ui_stroke_pts: [actions.MAX_STROKE_POINTS]actions.Point = undefined,
    ui_stroke_len: usize = 0,
    /// 上限超過 → この stroke は記録しない（257 点以上を記録すると 62.5.4 の redo 再 dispatch が
    /// TooManyPoints で失敗するため。Op は legacy UndoStack に残り既存 undo UI では戻せる）。
    ui_stroke_overflow: bool = false,
    /// capture 開始時に latch した実効パラメータ（canonical args の材料。§5c'）。
    ui_stroke_tool: ToolKind = .pen,
    ui_stroke_color: u32 = 0,
    ui_stroke_size: u32 = 4,
    ui_stroke_opacity: u8 = 255,
    ui_stroke_hardness: u8 = 255,

    /// 選択中レイヤーが text kind か（テキストレイヤーへの直接 raster 編集を防ぐガード。
    /// TASK-79.5）。text layer の pixels は「TextParams からの再ラスタライズ結果」という
    /// 不変条件（libs/paint/src/canvas.zig の `TextParams` doc comment 参照）を守るため、
    /// Pen/Eraser/Brush/Fill/Bezier/選択操作（cut/paste/move）の書き込み経路はこれで弾く
    /// （Rasterize 確定後=kind が raster 化した後は通常どおり描画できる）。
    fn selectedLayerIsText(self: *const App) bool {
        return self.canvas.selected_layer < self.canvas.layers.items.len and
            self.canvas.layers.items[self.canvas.selected_layer].kind == .text;
    }

    /// `system_font_bytes`（TASK-82）を `doc.active_view` へ反映する。新しい Document
    /// インスタンス（`core.Document.init`/`document_io.loadDocument` が返す）は
    /// `active_view.system_font` が既定 `null` で始まるため、Document を新規作成/差し替えた直後は
    /// 必ず呼ぶ必要がある（`main()` 起動時 + `doOpenProject`）。`preview_canvas` は
    /// `addTextLayer`/`setLayerTextParams` を一切呼ばないため対象外。イベント時/初期化時のみ
    /// （フレーム毎には呼ばない）。**TASK-45.1**: セルグリッド化により「アクティブフレームの
    /// 編集可能ビュー」は `doc.active_view` の1個のみになった（`resyncActiveView` は
    /// `system_font` を一切触らないため、ここで一度設定すれば保持され続ける。plan 4.2節）。
    fn applySystemFont(self: *App) void {
        self.doc.active_view.system_font = self.system_font_bytes;
    }

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

    /// stroke の実効パラメータを解決する（§5c': 明示 k=v > 現在の App 状態）。tool 未指定かつ
    /// 現在ツールが pen/eraser/brush 以外は `error.UnsupportedTool`（fill は呼び出し側が
    /// legacy 経路で扱う。bezier/select/eyedropper は従来どおり拒否）。
    fn resolveEffectiveStroke(self: *App, p: actions.StrokeParams) error{UnsupportedTool}!actions.EffectiveStroke {
        const tool: actions.StrokeTool = p.tool orelse switch (self.active_kind) {
            .pen => .pen,
            .eraser => .eraser,
            .brush => .brush,
            else => return error.UnsupportedTool,
        };
        return .{
            .tool = tool,
            .color = p.color orelse self.palette.current(),
            .size = p.size orelse self.brush.size,
            .opacity = p.opacity orelse self.brush.opacity,
            .hardness = p.hardness orelse self.brush.hardness_q,
        };
    }

    /// UI stroke の点列蓄積を開始する（capture 開始時。実効パラメータもここで latch する。§5c）。
    fn uiStrokeBegin(self: *App, p: core.Vec2) void {
        self.ui_stroke_len = 0;
        self.ui_stroke_overflow = false;
        self.ui_stroke_tool = self.active_kind;
        self.ui_stroke_color = self.palette.current();
        self.ui_stroke_size = self.brush.size;
        self.ui_stroke_opacity = self.brush.opacity;
        self.ui_stroke_hardness = self.brush.hardness_q;
        self.uiStrokeAppend(p);
    }

    fn uiStrokeAppend(self: *App, p: core.Vec2) void {
        if (self.ui_stroke_overflow) return;
        if (self.ui_stroke_len > 0) {
            const last = self.ui_stroke_pts[self.ui_stroke_len - 1];
            if (last.x == p.x and last.y == p.y) return; // 連続同一点は蓄積しない
        }
        if (self.ui_stroke_len >= actions.MAX_STROKE_POINTS) {
            self.ui_stroke_overflow = true;
            return;
        }
        self.ui_stroke_pts[self.ui_stroke_len] = .{ .x = p.x, .y = p.y };
        self.ui_stroke_len += 1;
    }

    fn uiStrokeDiscard(self: *App) void {
        self.ui_stroke_len = 0;
        self.ui_stroke_overflow = false;
    }

    /// UI stroke の確定点で CommandRecord を記録する（§5c。actor=local_user・canonical args。
    /// one-shot: 蓄積は必ずクリアする）。`pushed` = pushPaintOp で Op が実際に push されたか
    /// （true なら undo_ref = 直近 push の handle = AC #2 の対応付け）。
    fn recordUiStroke(self: *App, pushed: bool) void {
        const len = self.ui_stroke_len;
        const overflow = self.ui_stroke_overflow;
        self.uiStrokeDiscard();
        if (len == 0) return;
        if (overflow) {
            std.debug.print("pixie: UI stroke の記録を skip（{d} 点超過。Op は legacy UndoStack に残る）\n", .{actions.MAX_STROKE_POINTS});
            return;
        }
        const tool: actions.StrokeTool = switch (self.ui_stroke_tool) {
            .pen => .pen,
            .eraser => .eraser,
            .brush => .brush,
            else => return, // fill 等は §5c の記録対象外（pen/eraser/brush のみ）
        };
        var canon_buf: [platform.command.MAX_CMD_ARGS]u8 = undefined;
        const canon = actions.formatCanonicalStroke(&canon_buf, .{
            .tool = tool,
            .color = self.ui_stroke_color,
            .size = self.ui_stroke_size,
            .opacity = self.ui_stroke_opacity,
            .hardness = self.ui_stroke_hardness,
        }, self.ui_stroke_pts[0..len]) catch {
            std.debug.print("pixie: UI stroke の記録を skip（canonical args が {d}B 超過。Op は legacy UndoStack に残る）\n", .{platform.command.MAX_CMD_ARGS});
            return;
        };
        const undo_ref: ?u64 = if (pushed) self.doc.undo.topHandle() else null;
        var msg_buf: [64]u8 = undefined;
        _ = self.cmd_exec.recordExecuted("stroke", canon, .{ .actor = .local_user }, undo_ref, &msg_buf) catch |err| {
            std.debug.print("pixie: UI stroke の記録に失敗: {s}\n", .{@errorName(err)});
        };
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

        // load はドキュメント差し替えなので undo/redo 履歴を破棄（recorder は stroke 非進行中）。
        // `resetCanvasToSingleLayer`（= `doc.resetToSingleBlankLayer`）が既に doc.undo を
        // リセット済みなので、ここで重複して行う必要はない（TASK-45.1）。

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
        // undo handle の採番は App/CommandLog の生存期間で単調に保つ（fresh Document は
        // next_handle=1 で始まるため、引き継がないと load 前の CommandRecord.undo_ref と
        // 新規 Op の handle が衝突し live 判定が偽陽性になる。UndoStack doc 参照）。
        const preserved_next_handle = self.doc.undo.next_handle;
        self.doc.deinit();
        self.doc = new_doc;
        self.doc.undo.next_handle = preserved_next_handle;
        self.doc.resyncActiveView(self.gpa);
        self.canvas = self.doc.activeCanvas();
        self.clampTimelineTarget();
        self.applySystemFont(); // 新 Document の active_view は system_font=null で始まるため再設定（TASK-82）
        // ドキュメント差し替え = undo/redo 履歴破棄・選択/フロート破棄（doOpen と同型。AC#4）。
        // `new_doc`（decodeDocument が返す fresh Document）は元々 undo 履歴を持たないため
        // 追加のリセットは不要（TASK-45.1。旧コードの独立 `app.undo` フィールドは廃止済み）。
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
        self.doc.undoOne(self.gpa);
        self.clampTimelineTarget();
    }

    fn doRedo(self: *App) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        self.doc.redoOne(self.gpa);
        self.clampTimelineTarget();
    }

    fn doClear(self: *App) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        if (self.selectedLayerIsText()) return error.EditingBlocked; // TASK-79.5: text layer 直接編集禁止
        self.doc.pushClear(self.gpa, self.canvas.selected_layer) catch |err| switch (err) {
            error.TextLayerSelected => return error.EditingBlocked, // 上のガードで既に弾いているはずの防御的分岐
        };
    }

    /// 選択範囲を clipboard へコピー（読み取りのみ・undo 不要）。selection 無しは no-op。
    /// 読み取りのみ（pixels を変更しない）なので text layer 選択中でも許可する（TASK-79.5）。
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
        if (self.selectedLayerIsText()) return; // TASK-79.5: text layer 直接編集禁止
        const sel = self.canvas.selection orelse return;
        const block = core.selection.extract(self.gpa, self.canvas, self.canvas.selected_layer, sel);
        if (self.clipboard) |*old| old.deinit(self.gpa);
        self.clipboard = block;
        if (core.selection.clearRectCmd(self.gpa, self.canvas, self.canvas.selected_layer, sel)) |pd| {
            self.doc.pushPaintOp(self.gpa, pd.layer_idx, pd.diffs) catch {}; // 上で text layer は既に弾いている
        }
    }

    /// clipboard を貼り付ける（undo 可）。貼付先は selection の左上（無ければ 0,0）。
    /// selection を貼付矩形（canvas 内 clip）へ更新する。clipboard 無しは no-op。
    fn doPaste(self: *App) void {
        if (self.editingBlocked()) return;
        if (self.selectedLayerIsText()) return; // TASK-79.5: text layer 直接編集禁止
        const block = self.clipboard orelse return;
        const dx: i32 = if (self.canvas.selection) |s| s.x else 0;
        const dy: i32 = if (self.canvas.selection) |s| s.y else 0;
        if (core.selection.pasteCmd(self.gpa, self.canvas, self.canvas.selected_layer, block, dx, dy, self.blend_mode)) |pd| {
            self.doc.pushPaintOp(self.gpa, pd.layer_idx, pd.diffs) catch {}; // 上で text layer は既に弾いている
        }
        const dest = core.Rect{ .x = dx, .y = dy, .w = @intCast(block.w), .h = @intCast(block.h) };
        self.canvas.setSelection(core.selection.clipRect(dest, self.canvas.width, self.canvas.height));
    }

    /// `Document.addLayer` が mutation + Op構築 + push を内部で完結する（plan 5.4節「一般化」）。
    fn doAddLayer(self: *App) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        _ = self.doc.addLayer(self.gpa) catch |err| {
            self.setSaveMsg("Layer add failed: {s}", .{@errorName(err)});
            return err;
        };
        self.clampTimelineTarget();
    }

    fn doDeleteLayer(self: *App) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        const idx = self.canvas.selected_layer;
        try self.doc.deleteLayer(self.gpa, idx);
        self.clampTimelineTarget();
    }

    fn doMoveLayer(self: *App, delta: i32) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        const from = self.canvas.selected_layer;
        const to_i: i32 = @as(i32, @intCast(from)) + delta;
        if (to_i < 0) return error.OutOfRange;
        try self.doc.reorderLayer(self.gpa, from, @intCast(to_i));
    }

    /// レイヤー可視性を明示値へ設定する（`doToggleLayerVisible` の共通実装。TASK-64 で action
    /// `set_layer_visible` からも直接呼べるよう抽出）。`Document.setLayerVisible` が冪等 no-op
    /// 判定込みで mutation + Op構築 + push を完結する。
    fn doSetLayerVisible(self: *App, idx: usize, on: bool) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        try self.doc.setLayerVisible(self.gpa, idx, on);
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
        try self.doc.setLayerOpacity(self.gpa, idx, value);
    }

    /// レイヤー名を変更する（Rename。TASK-79.3）。`Document.renameLayer` が冪等 no-op 判定込みで
    /// mutation + Op構築 + push を完結する。呼び出し元はインライン編集の確定
    /// （`commitRenameLayer`）と harness action（将来採用時）を想定。
    fn doRenameLayer(self: *App, idx: usize, new_name: []const u8) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        try self.doc.renameLayer(self.gpa, idx, new_name);
    }

    /// レイヤー行の右クリックメニュー「Rename...」から呼ぶ。現在名を編集バッファへコピーして
    /// インライン編集を開始する（確定は `commitRenameLayer`、取消は `cancelRenameLayer`）。
    fn beginRenameLayer(self: *App, idx: usize) void {
        if (idx >= self.canvas.layers.items.len) return;
        self.text_in.cancel(); // rename/text 編集は同時に active にしない（TASK-79.5）
        self.rename_in.begin(idx, self.canvas.layers.items[idx].name());
        // rename 開始時点で Space パン modifier が張り付いていると、rename 中は key_up を
        // 素通りさせない設計（下記イベントポンプ参照）のため解除しておく（codex レビュー指摘
        // 2026-07-05: rename 前に Space が押されたまま rename に入ると space_down が残留しうる）。
        self.space_down = false;
    }

    /// 編集を確定する（ENTER）。`doRenameLayer` へ委譲し Undo へ積む。失敗（境界外等）は無視
    /// （他の pending file op 等と同型の「UI からの呼び出しはベストエフォート」扱い）。
    fn commitRenameLayer(self: *App) void {
        if (!self.rename_in.active) return;
        const idx = self.rename_in.layer_idx;
        const committed = self.rename_in.commit();
        self.doRenameLayer(idx, committed) catch {};
    }

    /// 編集を取り消す（ESCAPE）。バッファは破棄するだけで Undo には積まない。
    fn cancelRenameLayer(self: *App) void {
        self.rename_in.cancel();
    }

    /// renaming 中の key_down を処理する（メインループのイベントポンプから、通常の
    /// `handleKey` の代わりに呼ばれる）。ENTER/KP_ENTER=確定・ESCAPE=取消・
    /// BACKSPACE/DELETE=1文字削除。それ以外はすべて無視（B/E 等のショートカットが
    /// タイプ中に誤発火しないようにする。gui への pushEvent もイベントポンプ側で止める）。
    fn handleRenameKey(self: *App, k: platform.KeyEvent) void {
        if (k.key == .ENTER or k.key == .KP_ENTER) {
            self.commitRenameLayer();
        } else if (k.key == .ESCAPE) {
            self.cancelRenameLayer();
        } else if (k.key == .BACKSPACE or k.key == .DELETE) {
            self.rename_in.backspace();
        }
        // その他のキーは無視（ツール切替ショートカット等を遮断）
    }

    // ── テキストレイヤー（TASK-79.5）─────────────────────────────

    /// テキストレイヤーを新規追加する（右クリックメニュー「Add Text Layer」）。既定
    /// テキスト "Text" / font_px=16 / 現在のパレット色 / 位置(8,8) で作成し選択する。
    /// Undo は既存 `.layer_add`（Layer 値コピーに kind/text_params が自動的に乗るため
    /// Op 変更は不要。`doAddLayer` と同じ仕組み）。
    fn doAddTextLayer(self: *App) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        var params: core.TextParams = .{ .x = 8, .y = 8, .color = self.palette.current() };
        params.setText("Text");
        _ = self.doc.addTextLayer(self.gpa, params) catch |err| {
            self.setSaveMsg("Text layer add failed: {s}", .{@errorName(err)});
            return err;
        };
    }

    /// テキストレイヤーの text_params を更新し再ラスタライズする（内容確定・サイズ/位置
    /// スライダー・色ボタンの共通適用口。TASK-79.5）。`Document.setLayerTextParams` が
    /// 冪等 no-op 判定・共有cel再ラスタライズ・Op構築+push を完結する。
    fn doSetTextParams(self: *App, idx: usize, params: core.TextParams) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        try self.doc.setLayerTextParams(self.gpa, idx, params);
    }

    /// テキストレイヤーを通常 raster レイヤーへ確定する（Rasterize。右クリックメニュー。
    /// TASK-79.5）。pixels 不変・kind/text_params のみ変化。Undo 1 回で戻せる。
    fn doRasterizeLayer(self: *App, idx: usize) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        _ = try self.doc.rasterizeLayer(self.gpa, idx);
    }

    /// レイヤー右クリックメニュー「Edit Text...」（kind==text の時のみ有効）から呼ぶ。
    /// 現在テキストを編集バッファへコピーしてインライン編集を開始する（確定は
    /// `commitTextEdit`、取消は `cancelTextEdit`）。`rename_in`/`text_in` は対称実装。
    fn beginTextEdit(self: *App, idx: usize) void {
        if (idx >= self.canvas.layers.items.len) return;
        if (self.canvas.layers.items[idx].kind != .text) return;
        self.rename_in.cancel(); // rename/text 編集は同時に active にしない（beginRenameLayer と対称）
        self.text_in.begin(idx, self.canvas.layers.items[idx].text_params.text());
        self.space_down = false; // beginRenameLayer と同じ理由（Space 残留防止）
    }

    /// 編集を確定する（ENTER）。`doSetTextParams` へ委譲する（色/サイズ/位置は現状値を維持し
    /// 文字列だけ更新）。失敗（境界外等）は無視（他の pending file op 等と同型）。
    fn commitTextEdit(self: *App) void {
        if (!self.text_in.active) return;
        const idx = self.text_in.layer_idx;
        const committed = self.text_in.commit();
        if (idx >= self.canvas.layers.items.len) return;
        var params = self.canvas.layers.items[idx].text_params;
        params.setText(committed);
        self.doSetTextParams(idx, params) catch {};
    }

    /// 編集を取り消す（ESCAPE）。バッファは破棄するだけで Undo には積まない。
    fn cancelTextEdit(self: *App) void {
        self.text_in.cancel();
    }

    /// テキスト編集中の key_down を処理する（`handleRenameKey` と対称）。
    fn handleTextEditKey(self: *App, k: platform.KeyEvent) void {
        if (k.key == .ENTER or k.key == .KP_ENTER) {
            self.commitTextEdit();
        } else if (k.key == .ESCAPE) {
            self.cancelTextEdit();
        } else if (k.key == .BACKSPACE or k.key == .DELETE) {
            self.text_in.backspace();
        }
        // その他のキーは無視（ツール切替ショートカット等を遮断）
    }

    fn doSelectLayer(self: *App, idx: usize) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        try self.doc.selectLayer(idx);
    }

    /// 選択レイヤーを複製し、直上へ挿入する（Duplicate。TASK-79.2。レイヤー右クリックメニュー）。
    /// `Document.duplicateLayer` が raster(各frame深いコピー)/text(新規cel全frameリンク)の
    /// 分岐込みで mutation + Op構築 + push を完結する（4.4/4.5節）。
    fn doDuplicateLayer(self: *App) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        const src_idx = self.canvas.selected_layer;
        _ = self.doc.duplicateLayer(self.gpa, src_idx) catch |err| {
            self.setSaveMsg("Layer duplicate failed: {s}", .{@errorName(err)});
            return err;
        };
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
    ///
    /// **TASK-79.5**: top・bottom いずれかが `kind==.text` なら `error.TextLayerSelected` で
    /// 拒否する（「選択中レイヤーが text か」だけでは top=raster(選択中)・bottom=text の組を
    /// 見逃す＝bottom の pixels が直接書き換えられ「text layer の pixels は text_params からの
    /// 再ラスタライズ結果」という不変条件を破る。codex レビュー指摘 2026-07-05）。
    /// `Document.mergeDown` が frame数1制限（9.1節MVP制限）込みで mutation + Op構築 + push を
    /// 完結する（below の焼き込み・top の削除を1 push でatomicに。plan 4.5/5.3節）。
    fn doMergeDown(self: *App) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        const top_idx = self.canvas.selected_layer;
        try self.doc.mergeDown(self.gpa, top_idx);
    }

    // ── タイムライン（TASK-45.2）──────────────────────────────────

    fn clampTimelineTarget(self: *App) void {
        if (self.doc.layers.items.len == 0) {
            self.timeline_target_layer = 0;
        } else if (self.timeline_target_layer >= self.doc.layers.items.len) {
            self.timeline_target_layer = self.doc.layers.items.len - 1;
        }
        if (self.doc.frames.items.len == 0) {
            self.timeline_target_frame = 0;
        } else if (self.timeline_target_frame >= self.doc.frames.items.len) {
            self.timeline_target_frame = @intCast(self.doc.frames.items.len - 1);
        }
    }

    fn doSelectFrame(self: *App, frame: u32) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        if (frame >= self.doc.frames.items.len) return error.OutOfRange;
        if (self.doc.selected_frame == frame) return;
        self.doc.selected_frame = frame;
        self.doc.resyncActiveView(self.gpa);
        self.syncPreviewCanvas();
        self.clampTimelineTarget();
    }

    fn doAddFrame(self: *App) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        const at = self.doc.selected_frame + 1;
        try self.doc.addFrame(self.gpa, at);
        self.clampTimelineTarget();
    }

    fn doDuplicateFrame(self: *App) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        try self.doc.duplicateFrame(self.gpa, self.doc.selected_frame);
        self.clampTimelineTarget();
    }

    fn doDeleteFrame(self: *App) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        try self.doc.deleteFrame(self.gpa, self.doc.selected_frame);
        self.clampTimelineTarget();
    }

    fn doAdvanceFrame(self: *App, delta: i32) !void {
        const nf: i32 = @intCast(self.doc.frames.items.len);
        if (nf <= 0) return;
        const cur: i32 = @intCast(self.doc.selected_frame);
        const next = std.math.clamp(cur + delta, 0, nf - 1);
        try self.doSelectFrame(@intCast(next));
    }

    fn doCreateCelAt(self: *App, layer: usize, frame: u32) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        if (layer >= self.doc.layers.items.len or frame >= self.doc.frames.items.len) return error.OutOfRange;
        if (self.doc.layers.items[layer].kind == .text) return error.EditingBlocked;
        _ = self.doc.createCel(self.gpa, layer, frame);
    }

    fn doClearCelAt(self: *App, layer: usize, frame: u32) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        if (layer >= self.doc.layers.items.len or frame >= self.doc.frames.items.len) return error.OutOfRange;
        if (self.doc.layers.items[layer].kind == .text) return error.EditingBlocked;
        const was_selected = self.doc.selected_frame == frame;
        self.doc.clearCel(self.gpa, layer, frame);
        if (was_selected) self.doc.resyncActiveView(self.gpa);
        self.clampTimelineTarget();
    }

    fn doLinkCelLeft(self: *App, layer: usize, frame: u32) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        if (layer >= self.doc.layers.items.len or frame == 0 or frame >= self.doc.frames.items.len) return error.OutOfRange;
        if (self.doc.layers.items[layer].kind == .text) return error.EditingBlocked;
        try self.doc.linkCel(self.gpa, layer, frame, frame - 1);
    }

    fn doUnlinkCelAt(self: *App, layer: usize, frame: u32) !void {
        if (self.editingBlocked()) return error.EditingBlocked;
        if (layer >= self.doc.layers.items.len or frame >= self.doc.frames.items.len) return error.OutOfRange;
        if (self.doc.layers.items[layer].kind == .text) return error.EditingBlocked;
        try self.doc.unlinkCel(self.gpa, layer, frame);
    }

    fn tickTimelinePlayback(self: *App, now: f64) void {
        if (!self.timeline_playing or self.editingBlocked()) return;
        const interval = 1.0 / self.timeline_fps;
        if (self.timeline_last_advance == 0) self.timeline_last_advance = now;
        if (now - self.timeline_last_advance < interval) return;
        self.timeline_last_advance = now;
        const nframes = self.doc.frames.items.len;
        if (nframes == 0) return;
        const next: u32 = if (self.doc.selected_frame + 1 >= nframes) 0 else self.doc.selected_frame + 1;
        self.doSelectFrame(next) catch {};
    }

    /// PNG open 用: doc/active_view を「1layer・1frame・1cel(空)」状態へ縮める
    /// （`Document.resetToSingleBlankLayer`。undo/redo も内部で破棄される。plan 8.5節）。
    fn resetCanvasToSingleLayer(self: *App) void {
        self.doc.resetToSingleBlankLayer(self.gpa);
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

    /// 描画用の straight-alpha composite を返す（ベジェ/選択プレビュー時は preview_canvas）。
    fn resolveDisplayComposite(self: *App, gpa: std.mem.Allocator) []const u32 {
        if (self.active_kind == .bezier and self.bezier_editor.isEditing()) {
            self.syncPreviewCanvas();
            const dab = self.brush.footprint();
            self.bezier_editor.rasterizePreview(&self.preview_canvas, &self.preview_rec, gpa, dab, self.brush.color, self.brush.opacity);
            return self.preview_canvas.compositeStraight();
        }
        if (self.active_kind == .select and self.sel_in.state == .moving) {
            self.syncPreviewCanvas();
            _ = self.sel_in.renderMovePreview(self.preview_canvas.layerPixels(self.canvas.selected_layer), CANVAS_W, CANVAS_H, self.blend_mode);
            return self.preview_canvas.compositeStraight();
        }
        return self.canvas.compositeStraight();
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

    /// ベジェ確定（現在ブラシ footprint + color/opacity で rasterize → `Document.pushPaintOp`）。
    fn commitBezier(self: *App) void {
        const dab = self.brush.footprint();
        if (self.bezier_editor.rasterizeCommit(self.canvas, &self.recorder, self.gpa, dab, self.brush.color, self.brush.opacity)) |pd| {
            self.doc.pushPaintOp(self.gpa, pd.layer_idx, pd.diffs) catch {}; // text layer 選択中はこの経路に到達しない
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
        const crc = png.crc32(std.mem.sliceAsBytes(layer.pixels));
        // kind=text の時だけ text= を nested 内へ追加する（TASK-79.5。既存 name= と同じ
        // 「nested は contains で見る」規約。text_content_input が ASCII 制御文字を弾くため
        // 改行等の混入は無い＝1行契約は保たれる）。
        const part = if (layer.kind == .text)
            std.fmt.bufPrint(buf[len..], " l{d}{{v={},op={d},crc={X:0>8},nz={d},name={s},kind=text,text={s}}}", .{
                idx, layer.visible, layer.opacity, crc, nonzero, layer.name(), layer.text_params.text(),
            }) catch break
        else
            std.fmt.bufPrint(buf[len..], " l{d}{{v={},op={d},crc={X:0>8},nz={d},name={s},kind=raster}}", .{
                idx, layer.visible, layer.opacity, crc, nonzero, layer.name(),
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
        app.doc.undo.undo.items.len, app.doc.undo.redo.items.len,
    }) catch buf[0..0];
}
fn undoSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    return std.fmt.allocPrint(allocator, "{{\"depth\":{d},\"redo\":{d}}}", .{
        app.doc.undo.undo.items.len, app.doc.undo.redo.items.len,
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

/// history digest（TASK-62.5.3 §5d の**暫定** probe。正式な summary schema は 62.5.5 で確定し、
/// この digest はその際に置換・拡張してよい）: CommandLog の外部観測手段（AC #1 の headless 検証用）。
/// `last_undo_live` = 最新 record の undo_ref handle が現在 UndoStack に現存するか（AC #2 の
/// 対応付けと §5b' の stale 遷移の外部検証用。undo_ref が無い record は `-`）。
fn historyDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const latest = app.cmd_log.latest() orelse {
        return std.fmt.bufPrint(buf, "count=0 last_seq=0 last_actor=- last_name=- last_undoable=- last_undo_ref=- last_undo_live=- last_tx=-", .{}) catch buf[0..0];
    };
    var ref_buf: [24]u8 = undefined;
    const ref_str: []const u8 = if (latest.undo_ref) |r| (std.fmt.bufPrint(&ref_buf, "{d}", .{r}) catch "-") else "-";
    const live_str: []const u8 = if (latest.undo_ref) |r| (if (app.doc.undo.hasHandle(r)) "1" else "0") else "-";
    var tx_buf: [24]u8 = undefined;
    const tx_str: []const u8 = if (latest.transaction_id) |t| (std.fmt.bufPrint(&tx_buf, "{d}", .{t}) catch "-") else "-";
    return std.fmt.bufPrint(buf, "count={d} last_seq={d} last_actor={s} last_name={s} last_undoable={d} last_undo_ref={s} last_undo_live={s} last_tx={s}", .{
        app.cmd_log.filled,
        latest.seq,
        @tagName(latest.actor),
        latest.name(),
        @as(u1, if (latest.undoable) 1 else 0),
        ref_str,
        live_str,
        tx_str,
    }) catch buf[0..0];
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
//   TASK-79.5（テキストレイヤー: doAddTextLayer/doSetTextParams/doRasterizeLayer）には action を
//   追加していない。harness の action registry は `MAX_ACTIONS=16`（core/control/harness.zig）
//   固定で pixie は既に 16 件を使い切っており、harness.zig 改変はスコープ外（AGENT.md 上位
//   ルール）のため空き slot が無い。これらは UI 操作（右クリックメニュー + `inject char`
//   による文字入力）で harness 検証する。
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

/// `add` で空フレーム追加、`select <idx>` でフレーム選択（harness 向け。registry 節約のため1名）。
fn actionFrame(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    var it = std.mem.tokenizeAny(u8, args, " \t");
    const sub = it.next() orelse return error.Empty;
    if (std.mem.eql(u8, sub, "add")) {
        if (it.next() != null) return error.TooManyTokens;
        try actionApp(ctx).doAddFrame();
        return "ok";
    }
    if (std.mem.eql(u8, sub, "select")) {
        const idx_tok = it.next() orelse return error.Empty;
        if (it.next() != null) return error.TooManyTokens;
        const idx = std.fmt.parseUnsigned(u32, idx_tok, 10) catch return error.InvalidNumber;
        try actionApp(ctx).doSelectFrame(idx);
        return "ok";
    }
    return error.InvalidNumber;
}

fn actionSetOnion(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const p = try actions.parseOnion(args);
    const app = actionApp(ctx);
    app.onion_enabled = p.enabled;
    if (p.count) |c| {
        app.onion_count = @intCast(std.math.clamp(c, 1, core.onion_skin.max_count));
    }
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
/// TASK-62.5.3 §5c': `[tool=|color=|size=|opacity=|hardness=]` の k=v 前置を受け、明示された
/// パラメータを**一時的に latch して実行後に元の App 状態へ復元**する（redo が現在のユーザー
/// 設定を壊さない）。パラメータ無しは従来どおり現在状態を使う（TASK-64 文法と後方互換。
/// fill は tool= で表現できない legacy 経路として従来どおり現在ツールで実行する）。
/// bezier/select/eyedropper は従来どおり明示的に弾く（`activeTool()` の到達しないフォールバック
/// による意図しない Pen 描画の回避）。
fn actionStroke(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    if (app.editingBlocked()) return error.EditingBlocked;
    if (app.selectedLayerIsText()) return error.TextLayerSelected; // TASK-79.5: text layer 直接編集禁止
    var pts_buf: [actions.MAX_STROKE_POINTS]actions.Point = undefined;
    const parsed = try actions.parseStroke(args, &pts_buf);
    const pts = parsed.points;

    // 実効パラメータの解決と latch。fill（tool= 無し + active_kind==.fill）のみ legacy 経路。
    var tool: core.Tool = undefined;
    const saved_pen_color = app.pen.color;
    const saved_brush_color = app.brush.color;
    const saved_brush_size = app.brush.size;
    const saved_brush_opacity = app.brush.opacity;
    const saved_brush_hardness = app.brush.hardness_q;
    defer {
        app.pen.color = saved_pen_color;
        app.brush.color = saved_brush_color;
        app.brush.size = saved_brush_size;
        app.brush.opacity = saved_brush_opacity;
        app.brush.hardness_q = saved_brush_hardness;
    }
    if (app.resolveEffectiveStroke(parsed.params)) |eff| {
        switch (eff.tool) {
            .pen => {
                app.pen.color = eff.color;
                tool = app.pen.tool();
            },
            .eraser => tool = app.eraser.tool(),
            .brush => {
                app.brush.color = eff.color;
                app.brush.size = eff.size;
                app.brush.opacity = eff.opacity;
                app.brush.hardness_q = eff.hardness;
                tool = app.brush.tool();
            },
        }
    } else |err| {
        // tool= 無しで現在ツールが fill → 従来どおり現在状態で実行（TASK-64 後方互換）。
        // bezier/select/eyedropper は従来どおり UnsupportedTool。
        if (app.active_kind != .fill or parsed.params.tool != null) return err;
        tool = app.activeTool();
    }

    _ = tool.onEvent(app.canvas, &app.recorder, app.gpa, .{ .down = .{ .x = pts[0].x, .y = pts[0].y } });
    var cmd: ?core.PaintDiff = null;
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
    if (cmd) |pd| try app.doc.pushPaintOp(app.gpa, pd.layer_idx, pd.diffs);
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

// テキストレイヤー（TASK-79.5）向け action（doAddTextLayer/doSetTextParams/doRasterizeLayer）は
// 未追加のまま（TASK-62.5.3 で MAX_ACTIONS は 32 へ拡張済みで slot は空いたが、追加自体は
// 本タスクのスコープ外）。harness 検証は既存の `inject mouse_down/up` + `inject char` で行う。

// ============================================================================
// command model 統合（TASK-62.5.3）
//
// App が CommandLog + Executor を所有し（常時有効・固定容量）、記録は次の 2 箇所に一元化する:
//   1. registerAction 経由（harness `action` / copilot `action`）→ 下の記録 wrapper が
//      `executeAction(actor=.local_agent)` で実ハンドラ（PIXIE_ACTIONS 表）を dispatch + 記録
//   2. UI の canvas stroke 確定点 → `App.recordUiStroke`（`recordExecuted(actor=.local_user)`）
// undo/redo action は `.no_record`（正規化された undo 表現は 62.5.4 の revert record。normal
// record としてログを汚さない）。undo_ref は `UndoStack.handles` の handle（AC #2 の対応付け）。
// ============================================================================

const ActionEntry = struct {
    name: []const u8,
    run: *const fn (ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8,
};

/// name→実ハンドラ表（`dispatchPixieAction` が引く。登録 wrapper とは分離）。
const PIXIE_ACTIONS = [_]ActionEntry{
    .{ .name = "undo", .run = actionUndo },
    .{ .name = "redo", .run = actionRedo },
    .{ .name = "clear", .run = actionClear },
    .{ .name = "add_layer", .run = actionAddLayer },
    .{ .name = "delete_layer", .run = actionDeleteLayer },
    .{ .name = "select_layer", .run = actionSelectLayer },
    .{ .name = "set_layer_visible", .run = actionSetLayerVisible },
    .{ .name = "set_layer_opacity", .run = actionSetLayerOpacity },
    .{ .name = "move_layer", .run = actionMoveLayer },
    .{ .name = "duplicate_layer", .run = actionDuplicateLayer },
    .{ .name = "merge_down", .run = actionMergeDown },
    .{ .name = "frame", .run = actionFrame },
    .{ .name = "set_onion", .run = actionSetOnion },
    .{ .name = "set_color", .run = actionSetColor },
    .{ .name = "set_tool", .run = actionSetTool },
    .{ .name = "stroke", .run = actionStroke },
    .{ .name = "save", .run = actionSave },
    .{ .name = "open", .run = actionOpen },
};

/// `App.cmd_exec` の Dispatcher: name→実ハンドラ dispatch + noteUndo 配線（§5b）。
/// dispatch 前後の undo push 回数を handle 採番カウンタ（`next_handle` の差分 = 「深さ +
/// topHandle」比較の正確化。max_history 満杯時に深さが増えない push も正しく数える）で判定し、
/// **丁度 1 push のときのみ** `noteUndo(topHandle)` する（0 push = non-undoable、2 push 以上 =
/// 1 command = 1 Op の対応が崩れるため noteUndo しない + warn。現行 action set では発生しない想定）。
fn dispatchPixieAction(ctx: *anyopaque, name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    for (&PIXIE_ACTIONS) |*e| {
        if (std.mem.eql(u8, e.name, name)) {
            const handle_before = app.doc.undo.next_handle;
            const out = try e.run(ctx, args, buf);
            const handle_after = app.doc.undo.next_handle;
            // 防御: 採番は生存期間単調が不変条件（clearHistoryPreservingHandles / doOpenProject の
            // 引き継ぎで維持）だが、万一巻き戻っても unsigned underflow で落とさない（0 push 扱い + warn）。
            const pushes = if (handle_after >= handle_before) handle_after - handle_before else blk: {
                std.debug.print("pixie: action '{s}' で undo handle 採番が巻き戻り（{d}→{d}）。noteUndo を skip\n", .{ name, handle_before, handle_after });
                break :blk 0;
            };
            if (pushes == 1) {
                if (app.doc.undo.topHandle()) |h| app.cmd_exec.noteUndo(h);
            } else if (pushes >= 2) {
                std.debug.print("pixie: action '{s}' が {d} 回 undo.push（1 command = 1 Op が崩れるため noteUndo しない。62.5.4 申し送り）\n", .{ name, pushes });
            }
            return out;
        }
    }
    return error.UnknownAction;
}

/// registerAction 用の記録 wrapper を comptime 生成する（§5a）。executor 経由で実ハンドラを
/// dispatch し `actor=.local_agent` で記録する。copilot の `begin_tx` で開いた transaction には
/// `openTransactionFor` で自動参加する。`policy=.no_record` は undo/redo 用（dispatch のみ）。
fn recordedAction(comptime name: []const u8, comptime policy: platform.command.RecordPolicy) *const fn (*anyopaque, []const u8, []u8) anyerror![]const u8 {
    return &struct {
        fn run(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
            const app: *App = @ptrCast(@alignCast(ctx));
            const res = try app.cmd_exec.executeAction(name, args, .{
                .actor = .local_agent,
                .transaction = app.cmd_exec.openTransactionFor(.local_agent),
                .record_policy = policy,
            }, buf);
            return res.output;
        }
    }.run;
}

/// `stroke` 専用の記録 wrapper（§5c'）: 入力 args を parse → 実効パラメータ解決（明示 k=v >
/// 現在状態）→ **各 key をちょうど一度だけ含む canonical args** を生成 → canonical args で
/// executeAction（dispatch も canonical を実行するため挙動は入力の意味と同一。CommandLog 上の
/// 全 stroke record が状態非依存に再実行可能になる）。fill の legacy 経路（tool= で表現不能）
/// のみ raw args のまま記録する（従来挙動の互換維持。canonical 化は pen/eraser/brush が対象）。
fn recordedStroke(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    var pts_buf: [actions.MAX_STROKE_POINTS]actions.Point = undefined;
    const parsed = try actions.parseStroke(args, &pts_buf);

    var canon_buf: [platform.command.MAX_CMD_ARGS]u8 = undefined;
    const exec_args: []const u8 = if (app.resolveEffectiveStroke(parsed.params)) |eff|
        actions.formatCanonicalStroke(&canon_buf, eff, parsed.points) catch return error.ArgsTooLong
    else |err| blk: {
        if (app.active_kind != .fill or parsed.params.tool != null) return err;
        break :blk args; // fill legacy（actionStroke 側も同じ判定で legacy 経路に入る）
    };

    const res = try app.cmd_exec.executeAction("stroke", exec_args, .{
        .actor = .local_agent,
        .transaction = app.cmd_exec.openTransactionFor(.local_agent),
        .record_policy = .record,
    }, buf);
    return res.output;
}

/// 全 action を一括登録する（`platform.init()` 後・main loop 前に呼ぶ。harness/copilot とも
/// 無効時は `registerAction` 自体が no-op なので通常実行に影響しない）。登録するのは記録
/// wrapper（実ハンドラは `PIXIE_ACTIONS` 表経由で `dispatchPixieAction` が呼ぶ）。
fn registerActions(app: *App) void {
    platform.registerAction(.{ .name = "undo", .ctx = app, .run = recordedAction("undo", .no_record) });
    platform.registerAction(.{ .name = "redo", .ctx = app, .run = recordedAction("redo", .no_record) });
    platform.registerAction(.{ .name = "clear", .ctx = app, .run = recordedAction("clear", .record) });
    platform.registerAction(.{ .name = "add_layer", .ctx = app, .run = recordedAction("add_layer", .record) });
    platform.registerAction(.{ .name = "delete_layer", .ctx = app, .run = recordedAction("delete_layer", .record) });
    platform.registerAction(.{ .name = "select_layer", .ctx = app, .run = recordedAction("select_layer", .record) });
    platform.registerAction(.{ .name = "set_layer_visible", .ctx = app, .run = recordedAction("set_layer_visible", .record) });
    platform.registerAction(.{ .name = "set_layer_opacity", .ctx = app, .run = recordedAction("set_layer_opacity", .record) });
    platform.registerAction(.{ .name = "move_layer", .ctx = app, .run = recordedAction("move_layer", .record) });
    platform.registerAction(.{ .name = "duplicate_layer", .ctx = app, .run = recordedAction("duplicate_layer", .record) });
    platform.registerAction(.{ .name = "merge_down", .ctx = app, .run = recordedAction("merge_down", .record) });
    platform.registerAction(.{ .name = "frame", .ctx = app, .run = recordedAction("frame", .record) });
    platform.registerAction(.{ .name = "set_onion", .ctx = app, .run = recordedAction("set_onion", .record) });
    platform.registerAction(.{ .name = "set_color", .ctx = app, .run = recordedAction("set_color", .record) });
    platform.registerAction(.{ .name = "set_tool", .ctx = app, .run = recordedAction("set_tool", .record) });
    platform.registerAction(.{ .name = "stroke", .ctx = app, .run = recordedStroke });
    platform.registerAction(.{ .name = "save", .ctx = app, .run = recordedAction("save", .record) });
    platform.registerAction(.{ .name = "open", .ctx = app, .run = recordedAction("open", .record) });
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

/// レイヤー名の表示上限（**切り詰め後を含めた総コードポイント数**。TASK-79.3）。右ペイン幅
/// 200px の行に収める表示専用の制約で、保存される名前自体（`layer_name_max`=32B）は切り詰めない。
///
/// 実測値: サムネ(24px)+可視トグル(min_w 22)+opacity slider(track_w 40 他)を差し引いた
/// 右ペイン(200px)の残り予算では、名前欄が**総描画 7 文字**（フォントは固定 8px/コードポイント。
/// `libs/gui/src/font.zig`）を超えると opacity slider がスクロール viewport 外へ押し出され
/// 操作不能になることを harness snapshot で確認済み（7 文字="Layer 1" は収まる／8 文字="Layer 10"
/// 相当は収まらない）。既定名 "Layer N" は 1 桁のうちは 7 文字ちょうどで収まるが、2 桁以降
/// （"Layer 10".."Layer 99"）は下記の切り詰めで "Layer.." のように短縮表示される
/// （番号は失われるが選択ハイライト/サムネで見分けは付く。3 桁以降も同様）。
const LAYER_NAME_DISPLAY_MAX: usize = 7;

/// 表示用にレイヤー名を「切り詰め後を含めた総コードポイント数」が `max_total_chars` に収まるよう
/// 切り詰める（収まらない場合のみ末尾 2 文字を ".." に差し替え）。buttonId/box の width は
/// min_w を「下限」としてしか扱えないため、切り詰めずに渡すと長い名前でレイヤー行が際限なく
/// 広がり opacity slider 等がスクロール viewport 外へ押し出され操作不能になりうる
/// （本関数はその防止専用。保存データは一切変更しない）。
/// **既にちょうど収まる名前（例: "Layer 1"）を無駄に切り詰めない**よう、「切り詰め要否」の判定は
/// 元の総コードポイント数で行う（「先頭 N 文字を機械的に切って ".." を足す」だけだと、
/// 元がわずかに budget を超えるだけの名前で `N+2 > 元の長さ` になり、切り詰めが逆に長くなる
/// 事故を避けるため）。
/// alloc は `ctx.allocator()`（フレーム arena）想定で、収まる場合は allocation なしで name を
/// そのまま返す。
///
/// 毎フレーム呼ばれるが（immediate-mode GUI 構築の一部）、対象は高々「レイヤー数×十数文字」で
/// 全画素ループではない（同じ buildLayerPanel が毎フレーム呼ぶ既存の `fillLayerThumb` と同じ
/// 「小さい per-frame UI 構築コスト」のクラス。性能規約の SIMD 3点セット等は対象外）。
fn truncateForDisplay(alloc: std.mem.Allocator, name: []const u8, max_total_chars: usize) []const u8 {
    const view = std.unicode.Utf8View.init(name) catch return name; // 不正 UTF-8 はそのまま返す（防御）
    var total: usize = 0;
    {
        var counter = view.iterator();
        while (counter.nextCodepointSlice()) |_| total += 1;
    }
    if (total <= max_total_chars) return name; // 収まる → 切り詰め不要

    const keep = if (max_total_chars > 2) max_total_chars - 2 else 0;
    var it = view.iterator();
    var end: usize = 0;
    var count: usize = 0;
    while (it.nextCodepointSlice()) |slice| {
        if (count >= keep) break;
        end += slice.len;
        count += 1;
    }
    return std.fmt.allocPrint(alloc, "{s}..", .{name[0..end]}) catch name[0..end];
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

        // レイヤー名表示（TASK-79.3）。renaming 中の対象行だけ確定前バッファ+カーソルを表示する。
        // どちらも `truncateForDisplay` で表示専用に切り詰める（保存名自体は変えない）: buttonId/
        // beginBox の width は min_w を「下限」としてしか扱えず、テキストが長いと際限なく箱が
        // 広がる。右ペイン幅 200px からサムネ/可視トグル/opacity slider を差し引くと名前欄の
        // 実質予算は 70〜90px 程度しかなく、無制限だと opacity slider 等がスクロール viewport
        // 外へ押し出され操作不能になりうるため。
        if (app.rename_in.active and app.rename_in.layer_idx == idx) {
            var cursor_buf: [96]u8 = undefined;
            const shown = truncateForDisplay(ctx.allocator(), app.rename_in.text(), LAYER_NAME_DISPLAY_MAX);
            const with_cursor = std.fmt.bufPrint(&cursor_buf, "{s}_", .{shown}) catch shown;
            ctx.beginBox(.{
                .padding = .{ 2, 4, 2, 4 },
                .bg = ctx.style.bg_active,
                .border = .{ .color = ctx.style.border_hover, .thickness = 1 },
            });
            ctx.labelEx(with_cursor, ctx.style.text);
            ctx.endBox();
        } else {
            const shown = truncateForDisplay(ctx.allocator(), layer.name(), LAYER_NAME_DISPLAY_MAX);
            if (ctx.buttonId(layerWidgetId(idx, 0), shown, .{ .selected = idx == app.canvas.selected_layer, .min_w = 28 }).clicked) {
                app.doSelectLayer(idx) catch {};
            }
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

/// テキストレイヤー（kind==.text）専用の編集パネル。選択中レイヤーが text の時のみ表示する
/// （TASK-79.5）。内容編集（`text_in` 経由のインライン編集）/ font size / 位置(x,y) /
/// 現在色の適用を扱う。値変化時に `App.doSetTextParams` へ委譲する（既存 opacity スライダーと
/// 同じ「値が変わった時だけ呼ぶ」パターン。ドラッグ中の複数回 push は既存 opacity スライダーと
/// 同クラスの既知トレードオフで新規の懸念ではない）。
///
/// ホットパス宣言: 毎フレーム構築されるが（immediate-mode GUI の一部）、実際の再ラスタライズ
/// （`doSetTextParams` 経由）はスライダー値変化・文字列確定等の**イベント時のみ**走る。
fn buildTextLayerPanel(ctx: *gui.Context, app: *App) !void {
    const idx = app.canvas.selected_layer;
    if (idx >= app.canvas.layers.items.len) return;
    if (app.canvas.layers.items[idx].kind != .text) return;
    const layer = app.canvas.layers.items[idx];

    ctx.label("Text Layer");
    ctx.beginBox(.{ .direction = .column, .gap = 3 });

    if (app.text_in.active and app.text_in.layer_idx == idx) {
        var cursor_buf: [160]u8 = undefined;
        const shown = truncateForDisplay(ctx.allocator(), app.text_in.text(), LAYER_NAME_DISPLAY_MAX);
        const with_cursor = std.fmt.bufPrint(&cursor_buf, "{s}_", .{shown}) catch shown;
        ctx.beginBox(.{
            .padding = .{ 2, 4, 2, 4 },
            .bg = ctx.style.bg_active,
            .border = .{ .color = ctx.style.border_hover, .thickness = 1 },
        });
        ctx.labelEx(with_cursor, ctx.style.text);
        ctx.endBox();
    } else {
        const shown = truncateForDisplay(ctx.allocator(), layer.text_params.text(), LAYER_NAME_DISPLAY_MAX);
        if (ctx.buttonId(TEXT_PANEL_ID_BASE + 1, shown, .{ .min_w = 100 }).clicked) {
            app.beginTextEdit(idx);
        }
    }

    var px_f32: f32 = layer.text_params.font_px;
    if (ctx.sliderF32Id(TEXT_PANEL_ID_BASE + 2, "Size", &px_f32, .{ .min = 6, .max = 96, .step = 1, .track_w = 80 })) {
        var params = layer.text_params;
        params.font_px = px_f32;
        app.doSetTextParams(idx, params) catch {};
    }

    var x_i32: i32 = layer.text_params.x;
    if (ctx.sliderI32Id(TEXT_PANEL_ID_BASE + 3, "X", &x_i32, .{ .min = 0, .max = @as(i32, @intCast(CANVAS_W)) - 1, .track_w = 80 })) {
        var params = layer.text_params;
        params.x = x_i32;
        app.doSetTextParams(idx, params) catch {};
    }

    var y_i32: i32 = layer.text_params.y;
    if (ctx.sliderI32Id(TEXT_PANEL_ID_BASE + 4, "Y", &y_i32, .{ .min = 0, .max = @as(i32, @intCast(CANVAS_H)) - 1, .track_w = 80 })) {
        var params = layer.text_params;
        params.y = y_i32;
        app.doSetTextParams(idx, params) catch {};
    }

    if (ctx.buttonId(TEXT_PANEL_ID_BASE + 5, "Apply Color", .{ .min_w = 80 }).clicked) {
        var params = layer.text_params;
        params.color = app.palette.current();
        app.doSetTextParams(idx, params) catch {};
    }

    ctx.endBox();
}

fn timelineCellId(layer_idx: usize, frame_idx: u32) gui.Id {
    return TIMELINE_CELL_ID_BASE + @as(gui.Id, @intCast(layer_idx)) * TIMELINE_CELL_FRAME_STRIDE + frame_idx;
}

fn timelineHeaderId(frame_idx: u32) gui.Id {
    return TIMELINE_HEADER_ID_BASE + frame_idx;
}

/// 空セル用チェッカーサムネ（cel 無し）。
fn fillEmptyThumb(buf: []u32) void {
    const tw: usize = @intCast(LAYER_THUMB_W);
    const th: usize = @intCast(LAYER_THUMB_H);
    var ty: usize = 0;
    while (ty < th) : (ty += 1) {
        var tx: usize = 0;
        while (tx < tw) : (tx += 1) {
            const checker = (tx / LAYER_THUMB_CELL + ty / LAYER_THUMB_CELL) & 1;
            buf[ty * tw + tx] = if (checker == 0) CHECKER_LIGHT else CHECKER_DARK;
        }
    }
}

const TimelineCellDraw = struct {
    buf: []const u32,
    border_left: bool,
    border_right: bool,
    border_top: bool,
    border_bottom: bool,
    border_color: gui.Color,

    fn draw(ctx_ptr: *anyopaque, dl: *gui.DrawList, rect: gui.Rect) void {
        const self: *const TimelineCellDraw = @ptrCast(@alignCast(ctx_ptr));
        dl.image(rect, self.buf, @intCast(LAYER_THUMB_W), @intCast(LAYER_THUMB_H)) catch @panic("timeline cell: OOM");
        const t: u32 = 1;
        const col = self.border_color;
        const rh: i32 = @intCast(rect.h);
        const rw: i32 = @intCast(rect.w);
        const ti: i32 = @intCast(t);
        if (self.border_top) dl.rectFilled(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = t }, col) catch @panic("timeline cell: OOM");
        if (self.border_bottom) dl.rectFilled(.{ .x = rect.x, .y = rect.y + rh - ti, .w = rect.w, .h = t }, col) catch @panic("timeline cell: OOM");
        if (self.border_left) dl.rectFilled(.{ .x = rect.x, .y = rect.y, .w = t, .h = rect.h }, col) catch @panic("timeline cell: OOM");
        if (self.border_right) dl.rectFilled(.{ .x = rect.x + rw - ti, .y = rect.y, .w = t, .h = rect.h }, col) catch @panic("timeline cell: OOM");
    }
};

fn timelineCellBorderSides(doc: *const core.Document, layer_idx: usize, frame_idx: u32) struct { left: bool, right: bool, is_linked: bool } {
    const cid = doc.gridGet(layer_idx, frame_idx);
    if (cid == null) return .{ .left = true, .right = true, .is_linked = false };
    const left_same = if (frame_idx > 0) doc.gridGet(layer_idx, frame_idx - 1) == cid else false;
    const right_same = if (frame_idx + 1 < doc.frames.items.len) doc.gridGet(layer_idx, frame_idx + 1) == cid else false;
    return .{ .left = !left_same, .right = !right_same, .is_linked = left_same or right_same };
}

/// 下ペインのタイムライン UI（TASK-45.2）。行=layer × 列=frame のセルグリッド。
/// ホットパス宣言: 毎フレーム構築（immediate-mode GUI）。サムネは 24×24 縮小のみ。
fn buildTimelinePanel(ctx: *gui.Context, app: *App) !void {
    app.clampTimelineTarget();
    const tl = TIMELINE_PANEL_ID_BASE;
    const target_layer = app.timeline_target_layer;
    const target_frame = app.timeline_target_frame;

    ctx.beginBox(.{ .direction = .row, .gap = 4, .align_cross = .center });
    const play_label: []const u8 = if (app.timeline_playing) "Pause" else "Play";
    if (ctx.buttonId(tl + 1, play_label, .{ .min_w = 44, .selected = app.timeline_playing }).clicked) {
        app.timeline_playing = !app.timeline_playing;
        app.timeline_last_advance = platform.getTime();
    }
    var fps_f32 = app.timeline_fps;
    if (ctx.sliderF32Id(tl + 2, "FPS", &fps_f32, .{ .min = 1, .max = 30, .step = 1, .track_w = 60 })) {
        app.timeline_fps = fps_f32;
    }
    if (ctx.buttonId(tl + 3, "Fr+", .{ .min_w = 32 }).clicked) app.doAddFrame() catch {};
    if (ctx.buttonId(tl + 4, "Dup", .{ .min_w = 32 }).clicked) app.doDuplicateFrame() catch {};
    if (ctx.buttonId(tl + 5, "Del", .{ .min_w = 32 }).clicked) app.doDeleteFrame() catch {};
    if (ctx.buttonId(tl + 6, "<", .{ .min_w = 24 }).clicked) app.doAdvanceFrame(-1) catch {};
    if (ctx.buttonId(tl + 7, ">", .{ .min_w = 24 }).clicked) app.doAdvanceFrame(1) catch {};
    if (ctx.buttonId(tl + 8, "Cel+", .{ .min_w = 36 }).clicked) app.doCreateCelAt(target_layer, target_frame) catch {};
    if (ctx.buttonId(tl + 9, "Clr", .{ .min_w = 32 }).clicked) app.doClearCelAt(target_layer, target_frame) catch {};
    if (ctx.buttonId(tl + 10, "Link", .{ .min_w = 36 }).clicked) app.doLinkCelLeft(target_layer, target_frame) catch {};
    if (ctx.buttonId(tl + 11, "Unlk", .{ .min_w = 36 }).clicked) app.doUnlinkCelAt(target_layer, target_frame) catch {};
    _ = ctx.toggleId(tl + 12, "Onion", &app.onion_enabled);
    if (app.onion_enabled) {
        var onion_n_i32: i32 = @intCast(app.onion_count);
        if (ctx.sliderI32Id(tl + 13, "On.N", &onion_n_i32, .{ .min = 1, .max = @as(i32, @intCast(core.onion_skin.max_count)), .step = 1, .track_w = 40 })) {
            app.onion_count = @intCast(std.math.clamp(onion_n_i32, 1, @as(i32, @intCast(core.onion_skin.max_count))));
        }
    }
    ctx.endBox();

    ctx.beginScrollArea(TIMELINE_SCROLL_ID, &app.timeline_scroll, .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .direction = .column,
        .gap = 1,
        .content_width = .fit,
        .content_height = .fit,
    });

    ctx.beginBox(.{ .direction = .row, .gap = 1, .align_cross = .center });
    ctx.beginBox(.{ .width = .{ .fixed = TIMELINE_LABEL_W }, .height = .{ .fixed = TIMELINE_CELL_H } });
    ctx.endBox();
    var fi: u32 = 0;
    while (fi < app.doc.frames.items.len) : (fi += 1) {
        var num_buf: [8]u8 = undefined;
        const num_txt = try std.fmt.bufPrint(&num_buf, "{d}", .{fi + 1});
        if (ctx.buttonId(timelineHeaderId(fi), num_txt, .{
            .min_w = TIMELINE_CELL_W,
            .selected = fi == app.doc.selected_frame,
        }).clicked) {
            app.doSelectFrame(fi) catch {};
        }
    }
    ctx.endBox();

    var rev = app.doc.layers.items.len;
    while (rev > 0) {
        rev -= 1;
        const li = rev;
        const layer_def = app.doc.layers.items[li];
        ctx.beginBox(.{ .direction = .row, .gap = 1, .align_cross = .center });
        const shown = truncateForDisplay(ctx.allocator(), layer_def.name(), LAYER_NAME_DISPLAY_MAX);
        if (ctx.buttonId(tl + 100 + @as(gui.Id, @intCast(li)), shown, .{
            .min_w = TIMELINE_LABEL_W,
            .selected = li == app.canvas.selected_layer,
        }).clicked) {
            app.doSelectLayer(li) catch {};
            app.timeline_target_layer = li;
        }

        fi = 0;
        while (fi < app.doc.frames.items.len) : (fi += 1) {
            const thumb = ctx.allocator().alloc(u32, @as(usize, @intCast(LAYER_THUMB_W)) * @as(usize, @intCast(LAYER_THUMB_H))) catch @panic("timeline thumb: OOM");
            if (app.doc.gridGet(li, fi)) |cel_id| {
                if (app.doc.celPixels(cel_id)) |pixels| fillLayerThumb(thumb, pixels);
            } else {
                fillEmptyThumb(thumb);
            }
            const sides = timelineCellBorderSides(&app.doc, li, fi);
            const is_playhead = fi == app.doc.selected_frame;
            const is_target = li == target_layer and fi == target_frame;
            const border_color = if (is_playhead)
                TIMELINE_PLAYHEAD_BORDER
            else if (sides.is_linked)
                TIMELINE_LINK_BORDER
            else if (is_target)
                ctx.style.border_hover
            else
                ctx.style.border;
            const data = ctx.allocator().create(TimelineCellDraw) catch @panic("timeline cell: OOM");
            data.* = .{
                .buf = thumb,
                .border_left = sides.left or is_playhead,
                .border_right = sides.right or is_playhead,
                .border_top = true,
                .border_bottom = true,
                .border_color = border_color,
            };
            ctx.beginBox(.{ .id = timelineCellId(li, fi), .width = .{ .fixed = TIMELINE_CELL_W }, .height = .{ .fixed = TIMELINE_CELL_H } });
            ctx.custom(.{ .x = TIMELINE_CELL_W, .y = TIMELINE_CELL_H }, TimelineCellDraw.draw, data);
            ctx.endBox();
        }
        ctx.endBox();
    }

    ctx.endScrollArea();

    if (ctx.input.mouse_pressed.left) {
        const p = ctx.input.mouse_pressed_pos;
        const in_viewport = if (ctx.getNodeRect(TIMELINE_SCROLL_ID)) |vp| vp.contains(p) else false;
        if (in_viewport) {
            var li2 = app.doc.layers.items.len;
            while (li2 > 0) {
                li2 -= 1;
                fi = 0;
                while (fi < app.doc.frames.items.len) : (fi += 1) {
                    if (ctx.getNodeRect(timelineCellId(li2, fi))) |r| {
                        if (r.contains(p)) {
                            app.timeline_target_layer = li2;
                            app.timeline_target_frame = fi;
                            app.doSelectFrame(fi) catch {};
                            app.doSelectLayer(li2) catch {};
                            return;
                        }
                    }
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
        try buildTextLayerPanel(ctx, app); // TASK-79.5: 選択中レイヤーが text kind の時のみ表示
        ctx.endScrollArea(); // right pane (縦スクロール)
    } // right_visible

    ctx.endBox(); // content row

    // ── 下ペイン（タイムライン枠。中身は Phase5。TASK-42 はリサイズ/トグル枠のみ） ──
    if (app.bottom_visible) {
        _ = ctx.splitter(SPLIT_BOTTOM_ID, .horizontal, &app.bottom_pane_h, .{ .thickness = SPLITTER_T, .min = BOTTOM_PANE_MIN, .max = bottom_max, .invert = true });
        ctx.beginBox(.{
            .direction = .column,
            .width = .{ .grow = 1 },
            .height = .{ .fixed = app.bottom_pane_h },
            .padding = .{ 4, 6, 4, 6 },
            .gap = 4,
            .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF),
            .clip_children = true,
        });
        try buildTimelinePanel(ctx, app);
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
        try std.fmt.allocPrint(arena, "frame: {d}/{d}", .{ app.doc.selected_frame + 1, app.doc.frames.items.len }),
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

    // system font（TASK-82）の読込は App 構築より前に行い、直後に defer で解放する。
    // struct literal 内には複数の fallible 初期化（`try core.Document.init` 等）が続くため、
    // 解放をこの位置に置くことで「後続フィールドの初期化失敗時も含め、どの終了経路でも
    // 必ず一度だけ解放される」を保証する（App 側の cleanup defer には重複して置かない＝
    // 二重解放防止）。
    const system_font_bytes = loadSystemFontBytes(init.io, gpa);
    defer if (system_font_bytes) |b| gpa.free(b);

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
        .system_font_bytes = system_font_bytes,
    };
    app.canvas = app.doc.activeCanvas(); // doc の active_view を指す（ポインタ安定）
    app.applySystemFont(); // 初期 doc の active_view へ system font を反映（TASK-82）
    app.pen.color = app.palette.current(); // 初期描画色 = パレット先頭
    app.brush.color = app.palette.current();
    app.fill.color = app.palette.current();
    const canvas_pixel_count = @as(usize, CANVAS_W) * @as(usize, CANVAS_H);
    app.onion_buf = try gpa.alloc(u32, canvas_pixel_count);
    errdefer gpa.free(app.onion_buf);
    app.onion_scratch = try gpa.alloc(u32, canvas_pixel_count);
    errdefer gpa.free(app.onion_scratch);
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
        gpa.free(app.onion_buf);
        gpa.free(app.onion_scratch);
        // app.doc.deinit() が doc.undo も内部で解放する（TASK-45.1。独立 app.undo は廃止済み）。
        app.recorder.deinit(gpa);
        app.doc.deinit();
    }

    // command model（TASK-62.5.3）: App 所有の CommandLog/Executor を配線し、copilot transport の
    // 共有 executor に設定する（copilot 無効時は no-op。記録自体は transport の有無に依存しない）。
    app.cmd_exec = platform.command.Executor.init(.{ .ctx = &app, .run = dispatchPixieAction });
    app.cmd_exec.log = &app.cmd_log;
    platform.setCommandExecutor(&app.cmd_exec);

    // ヘッドレス検証 harness の custom probe を登録（harness 無効時は no-op）。
    platform.registerProbe(.{ .name = "canvas", .ctx = &app, .ext = "png", .snapshot = canvasSnapshot, .digest = canvasDigest });
    platform.registerProbe(.{ .name = "undo", .ctx = &app, .ext = "json", .snapshot = undoSnapshot, .digest = undoDigest });
    platform.registerProbe(.{ .name = "tool", .ctx = &app, .ext = "txt", .snapshot = toolSnapshot, .digest = toolDigest });
    platform.registerProbe(.{ .name = "cursor", .ctx = &app, .ext = "txt", .snapshot = cursorSnapshot, .digest = cursorDigest });
    platform.registerProbe(.{ .name = "history", .ctx = &app, .ext = "txt", .digest = historyDigest }); // 暫定（§5d。62.5.5 で置換可）
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
                    // レイヤー名インライン編集中（TASK-79.3）・テキストレイヤー内容編集中
                    // （TASK-79.5、`text_in`。rename_in と対称・互いに同時 active にならない）は
                    // key_down を専用ハンドラへ回し、char_input で確定文字を追記する（TASK-22
                    // char_input の初消費）。key_up は常に通す（Space パン modifier 等の held
                    // 状態を編集中に取りこぼさないため。codex レビュー指摘 2026-07-05）。
                    .key_down => |k| if (app.rename_in.active)
                        app.handleRenameKey(k)
                    else if (app.text_in.active)
                        app.handleTextEditKey(k)
                    else
                        app.handleKey(k),
                    .key_up => |k| app.handleKeyUp(k),
                    .char_input => |c| if (app.rename_in.active)
                        app.rename_in.appendCodepoint(c.codepoint)
                    else if (app.text_in.active)
                        app.text_in.appendCodepoint(c.codepoint),
                    else => {},
                }
                // renaming/テキスト編集中は gui へのマウス/キーイベント転送も止める（他行クリック等
                // での干渉を避ける。rename_in/text_in はここで破棄されないため、他行の右クリックで
                // 新たな編集が始まれば単に上書きされるだけでクラッシュはしない）。
                if (!app.rename_in.active and !app.text_in.active) {
                    if (toGuiEvent(ev)) |ge| ctx.pushEvent(ge);
                }
            }

            // canvas rect は前フレームの layout 結果（初回フレームは null）。
            // canvasBlitRect は pan を現 area に clamp して app へ書き戻し、last_area も更新する。
            var canvas_rect = canvasBlitRect(&ctx, &app);

            app.tickTimelinePlayback(platform.getTime());

            try buildUi(&ctx, &app, canvas_rect);
            ctx.endFrame();

            // ── ビューポート: ホイールズーム（カーソル中心）/ パン（Space+左 or middle ドラッグ）──
            // パン中は描画入力を抑止（既存 stroke 完走を妨げないよう pan は capturing 中に開始しない）。
            const panning = updateViewport(&app, &ctx, canvas_rect);
            // zoom/pan が変わり得たので、当フレームの入力・描画が「旧 rect + 新 zoom」で不整合に
            // ならないよう rect を再計算する（endFrame 後なので area は当フレームの layout 結果）。
            canvas_rect = canvasBlitRect(&ctx, &app);

            // ── canvas 入力。capturing 最優先（既存 stroke を完走）。bezier は独立経路 ──
            // TASK-79.5: 選択中レイヤーが text kind の間は、この分岐全体（bezier/select/
            // eyedropper/通常 canvas_input のいずれも）を丸ごと止める。「text layer の pixels は
            // text_params からの再ラスタライズ結果」という不変条件を守るため（eyedropper は
            // 本来読み取りのみで実害は無いが、分岐追加のミスリスクよりシンプルさを優先し
            // 丸ごと止める設計判断。text layer 選択中は色スポイトも一時的に使えない）。
            if (!panning and !app.selectedLayerIsText()) {
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
                        .mouse_released_pos = .{ .x = in.mouse_released_pos.x, .y = in.mouse_released_pos.y },
                        .pressed_left = pressed_left_gated,
                        .released_left = in.mouse_released.left,
                        .time = platform.getTime(),
                    };
                    const dab = app.brush.footprint();
                    if (app.bez_in.update(frame, &app.bezier_editor, app.canvas, &app.recorder, gpa, dab, app.brush.color, app.brush.opacity)) |pd| {
                        app.doc.pushPaintOp(gpa, pd.layer_idx, pd.diffs) catch {}; // text layer 選択中はこの分岐に到達しない
                    }
                } else if (app.active_kind == .select and !app.input.capturing) {
                    const frame: selection_input.SelectionInput.Frame = .{
                        .canvas_rect = canvas_rect,
                        .zoom = app.view_zoom,
                        .mouse_pos = .{ .x = in.mouse_pos.x, .y = in.mouse_pos.y },
                        .mouse_pressed_pos = .{ .x = in.mouse_pressed_pos.x, .y = in.mouse_pressed_pos.y },
                        .mouse_released_pos = .{ .x = in.mouse_released_pos.x, .y = in.mouse_released_pos.y },
                        .pressed_left = pressed_left_gated,
                        .released_left = in.mouse_released.left,
                    };
                    if (app.sel_in.update(frame, app.canvas, app.canvas.selected_layer, gpa, app.blend_mode)) |pd| {
                        app.doc.pushPaintOp(gpa, pd.layer_idx, pd.diffs) catch {}; // text layer 選択中はこの分岐に到達しない
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
                        .mouse_released_pos = .{ .x = in.mouse_released_pos.x, .y = in.mouse_released_pos.y },
                        .pressed_left = pressed_left_gated,
                        .released_left = in.mouse_released.left,
                    };
                    const was_capturing = app.input.capturing;
                    const pd_opt = app.input.update(frame, app.activeTool(), app.canvas, &app.recorder, gpa);
                    // ── UI stroke の点列追跡（TASK-62.5.3 §5c。canvas_input の down/move/up と同じ座標変換）──
                    if (canvas_rect) |rect| {
                        if (pd_opt != null) {
                            // release で確定（同一フレーム press+release は begin から。up は released_pos）
                            if (!was_capturing) app.uiStrokeBegin(core.screenToCanvasRaw(frame.mouse_pressed_pos, rect, frame.zoom));
                            app.uiStrokeAppend(core.screenToCanvasRaw(frame.mouse_released_pos, rect, frame.zoom));
                        } else if (!was_capturing and app.input.capturing) {
                            // capture 開始（down=pressed_pos + 同フレーム move=mouse_pos）
                            app.uiStrokeBegin(core.screenToCanvasRaw(frame.mouse_pressed_pos, rect, frame.zoom));
                            app.uiStrokeAppend(core.screenToCanvasRaw(frame.mouse_pos, rect, frame.zoom));
                        } else if (app.input.capturing) {
                            app.uiStrokeAppend(core.screenToCanvasRaw(frame.mouse_pos, rect, frame.zoom));
                        }
                    }
                    if (pd_opt) |pd| {
                        const handle_before = app.doc.undo.next_handle;
                        app.doc.pushPaintOp(gpa, pd.layer_idx, pd.diffs) catch {}; // text layer 選択中はこの分岐に到達しない
                        // 確定点で CommandRecord を記録（actor=local_user。undo_ref = push された Op の handle）
                        app.recordUiStroke(app.doc.undo.next_handle != handle_before);
                    } else if (!app.input.capturing) {
                        app.uiStrokeDiscard(); // release したが確定 diff なし → 蓄積破棄
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
                    const base_composite = app.resolveDisplayComposite(gpa);
                    const display_composite: []const u32 = if (app.onion_enabled and app.doc.frames.items.len > 1) blk: {
                        const cnt = @min(app.onion_count, core.onion_skin.max_count);
                        core.onion_skin.build(&app.doc, base_composite, app.doc.selected_frame, cnt, app.onion_buf, app.onion_scratch);
                        break :blk app.onion_buf;
                    } else base_composite;
                    blit.blitCanvasZoom(fb.pixels, fb.width, fb.height, display_composite, CANVAS_W, CANVAS_H, rect, zoom, area);
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
                const sel_is_text = app.selectedLayerIsText();
                const items = [_]gui.PopupItem{
                    .{ .label = "Add Layer" },
                    .{ .label = "Add Text Layer" }, // TASK-79.5
                    .{ .label = "Delete Layer", .enabled = app.canvas.layers.items.len > 1 },
                    .{ .label = "Move Up", .enabled = app.canvas.selected_layer + 1 < app.canvas.layers.items.len },
                    .{ .label = "Move Down", .enabled = app.canvas.selected_layer > 0 },
                    .{ .label = if (app.canvas.layers.items[app.canvas.selected_layer].visible) "Hide" else "Show" },
                    .{ .label = "Duplicate" },
                    .{ .label = "Merge Down", .enabled = app.canvas.selected_layer > 0 and !sel_is_text and
                        app.canvas.layers.items[app.canvas.selected_layer - 1].kind != .text },
                    .{ .label = "Rename..." }, // TASK-79.3
                    .{ .label = "Edit Text...", .enabled = sel_is_text }, // TASK-79.5
                    .{ .label = "Rasterize", .enabled = sel_is_text }, // TASK-79.5
                };
                const ctx_menu_result = ctx.popupMenu(LAYER_CTX_MENU_ID, &items);
                if (ctx_menu_result.selected) |sel| {
                    switch (sel) {
                        0 => app.doAddLayer() catch {},
                        1 => app.doAddTextLayer() catch {},
                        2 => app.doDeleteLayer() catch {},
                        3 => app.doMoveLayer(1) catch {},
                        4 => app.doMoveLayer(-1) catch {},
                        5 => app.doToggleLayerVisible(app.canvas.selected_layer),
                        6 => app.doDuplicateLayer() catch {},
                        7 => app.doMergeDown() catch {},
                        8 => app.beginRenameLayer(app.canvas.selected_layer),
                        9 => app.beginTextEdit(app.canvas.selected_layer),
                        10 => app.doRasterizeLayer(app.canvas.selected_layer) catch {},
                        else => {},
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
