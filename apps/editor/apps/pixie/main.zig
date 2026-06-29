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
const platform = @import("platform");
const gui = @import("gui");
const core = @import("core");
const png = @import("png");
const canvas_input = @import("canvas_input.zig");
const palette_mod = @import("palette.zig");
const bezier_input = @import("bezier_input.zig");
const bezier_overlay = @import("bezier_overlay.zig");
const selection_input = @import("selection_input.zig");
const selection_overlay = @import("selection_overlay.zig");

const WINDOW_W: u32 = 780;
const WINDOW_H: u32 = 600;
const CANVAS_W: u32 = 256;
const CANVAS_H: u32 = 256;
// ビューポート（TASK-39）: ズームは整数倍のランタイム値。既定 2x で従来の見た目を維持。
const ZOOM_MIN: i32 = 1;
const ZOOM_MAX: i32 = 32;
const ZOOM_DEFAULT: i32 = 2;
// 透明背景チェッカー（screen 固定セル。canonical BGRA 0xAARRGGBB）
const CHECKER_CELL: i32 = 8;
const CHECKER_LIGHT: u32 = 0xFF_6A_6A_6A;
const CHECKER_DARK: u32 = 0xFF_4E_4E_4E;
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
const FileOp = enum { save, save_as, open, save_palette, load_palette };

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

    fn name(self: ToolKind) []const u8 {
        return switch (self) {
            .pen => "Pen",
            .eraser => "Eraser",
            .brush => "Brush",
            .bezier => "Bezier",
            .select => "Select",
        };
    }
};

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
    canvas: core.Canvas,
    recorder: core.StrokeRecorder,
    /// ベジェ編集中のブラシプレビュー用一時 canvas/recorder（本 layer のコピーへ非破壊描画）
    preview_canvas: core.Canvas,
    preview_rec: core.StrokeRecorder,
    undo: core.UndoStack = .{},
    pen: core.Pen,
    eraser: core.Eraser = .{},
    brush: core.Brush,
    input: canvas_input.CanvasInput = .{},
    /// ベジェ(ペン)ツール（独立経路。TASK-21.13）。状態機械 + マウス入力アダプタ。
    bezier_editor: core.PathEditor = .{},
    bez_in: bezier_input.BezierInput = .{},
    /// 範囲選択ツール（独立経路。TASK-44）。マーキー作成 / 選択範囲移動の状態機械。
    sel_in: selection_input.SelectionInput = .{},
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
    /// 編集可能パレット（colors.len>=1）。描画色 = palette.current()。
    palette: palette_mod.Palette,
    /// 編集中 HSV 状態。選択切替/load 後のみ RGB→HSV で再同期（s==0 でも hue を失わない）。
    edit_h: f32 = 0,
    edit_s: f32 = 0,
    edit_v: f32 = 0,
    /// HSV を同期済みの selected。null/不一致なら再同期。
    edit_synced_for: ?usize = null,
    running: bool = true,
    /// 現在の保存先（gpa 所有）。Cmd+S はここへ直接上書き、保存/読込ダイアログ成功時に更新。
    current_path: ?[]u8 = null,
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
        };
    }

    /// ツール切替を一元化（active_kind への代入は全てここ経由）。
    /// capture / 選択ドラッグ中は切替しない（進行中操作を宙ぶらりんにしない）。
    /// .bezier から出る時は未確定パスを cancel。.select から出る時は進行中ドラッグを破棄（selection は保持）。
    fn setActiveKind(self: *App, next: ToolKind) void {
        if (self.input.capturing or self.sel_in.state != .idle) return;
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
        }
    }

    /// 選択スウォッチの色を編集中 HSV から決定し、palette と描画色（pen）へ反映する。
    /// edit_synced_for と palette.selected が一致するフレームでだけ呼ぶ（選択切替フレームの上書き事故回避）。
    fn applyEditColor(self: *App) void {
        const c: u32 = @bitCast(gui.Color.fromHsv(self.edit_h, self.edit_s, self.edit_v));
        self.palette.setSelectedColor(c);
        self.pen.color = c;
        self.brush.color = c; // Brush の描画色もパレット編集色に追従
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

    /// 記憶している保存先へ直接上書き。未設定なら「名前を付けて保存」へフォールバック。
    fn doSave(self: *App) void {
        const path = self.current_path orelse return self.doSaveAs();
        const flat = self.canvas.compositeStraight();
        core.savePNG(self.io, path, flat, CANVAS_W, CANVAS_H, self.gpa) catch |err| {
            // current_path は永続パスなので失敗しても保持（free しない）
            self.setSaveMsg("Save failed: {s}", .{@errorName(err)});
            return;
        };
        self.setSaveMsg("Saved: {s}", .{std.fs.path.basename(path)});
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
    fn doOpen(self: *App) void {
        if (self.input.capturing or self.bezier_editor.isEditing()) return;
        const maybe = platform.openFileDialog(self.gpa, self.io, .{ .allowed_ext = "png" }) catch |err| {
            self.setSaveMsg("Load failed: {s}", .{@errorName(err)});
            return;
        };
        const path = maybe orelse return; // キャンセル: サイレント no-op
        var img = png.decodePNGFile(self.io, self.gpa, path) catch |err| {
            self.setSaveMsg("Load failed: {s}", .{@errorName(err)});
            self.gpa.free(path);
            return;
        };
        defer img.deinit(self.gpa);

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
        self.current_path = path; // 移譲
        self.setSaveMsg("Loaded: {s}", .{std.fs.path.basename(path)});
    }

    /// 編集系コマンドは stroke 中は無視する（仕様の簡略化指示）
    fn doUndo(self: *App) void {
        if (self.editingBlocked()) return;
        self.undo.undoOne(self.gpa, &self.canvas);
    }

    fn doRedo(self: *App) void {
        if (self.editingBlocked()) return;
        self.undo.redoOne(self.gpa, &self.canvas);
    }

    fn doClear(self: *App) void {
        if (self.editingBlocked()) return;
        self.undo.pushClear(self.gpa, &self.canvas, self.canvas.selected_layer);
    }

    /// 選択範囲を clipboard へコピー（読み取りのみ・undo 不要）。selection 無しは no-op。
    fn doCopy(self: *App) void {
        if (self.editingBlocked()) return;
        const sel = self.canvas.selection orelse return;
        const block = core.selection.extract(self.gpa, &self.canvas, self.canvas.selected_layer, sel);
        if (self.clipboard) |*old| old.deinit(self.gpa);
        self.clipboard = block;
    }

    /// 選択範囲を clipboard へコピーし、選択内を透明化する（undo 可）。selection 無しは no-op。
    fn doCut(self: *App) void {
        if (self.editingBlocked()) return;
        const sel = self.canvas.selection orelse return;
        const block = core.selection.extract(self.gpa, &self.canvas, self.canvas.selected_layer, sel);
        if (self.clipboard) |*old| old.deinit(self.gpa);
        self.clipboard = block;
        if (core.selection.clearRectCmd(self.gpa, &self.canvas, self.canvas.selected_layer, sel)) |cmd| {
            self.undo.push(self.gpa, cmd);
        }
    }

    /// clipboard を貼り付ける（undo 可）。貼付先は selection の左上（無ければ 0,0）。
    /// selection を貼付矩形（canvas 内 clip）へ更新する。clipboard 無しは no-op。
    fn doPaste(self: *App) void {
        if (self.editingBlocked()) return;
        const block = self.clipboard orelse return;
        const dx: i32 = if (self.canvas.selection) |s| s.x else 0;
        const dy: i32 = if (self.canvas.selection) |s| s.y else 0;
        if (core.selection.pasteCmd(self.gpa, &self.canvas, self.canvas.selected_layer, block, dx, dy, self.blend_mode)) |cmd| {
            self.undo.push(self.gpa, cmd);
        }
        const dest = core.Rect{ .x = dx, .y = dy, .w = @intCast(block.w), .h = @intCast(block.h) };
        self.canvas.setSelection(core.selection.clipRect(dest, self.canvas.width, self.canvas.height));
    }

    fn doAddLayer(self: *App) void {
        if (self.editingBlocked()) return;
        const selected_before = self.canvas.selected_layer;
        const idx = self.canvas.addLayer(self.gpa) catch |err| {
            self.setSaveMsg("Layer add failed: {s}", .{@errorName(err)});
            return;
        };
        self.undo.push(self.gpa, .{ .layer_add = .{
            .index = idx,
            .selected_before = selected_before,
            .selected_after = self.canvas.selected_layer,
        } });
    }

    fn doDeleteLayer(self: *App) void {
        if (self.editingBlocked()) return;
        const idx = self.canvas.selected_layer;
        const selected_before = self.canvas.selected_layer;
        const removed = self.canvas.deleteLayer(idx) orelse return;
        self.undo.push(self.gpa, .{ .layer_delete = .{
            .index = idx,
            .selected_before = selected_before,
            .selected_after = self.canvas.selected_layer,
            .layer = removed,
        } });
    }

    fn doMoveLayer(self: *App, delta: i32) void {
        if (self.editingBlocked()) return;
        const from = self.canvas.selected_layer;
        const to_i: i32 = @as(i32, @intCast(from)) + delta;
        if (to_i < 0) return;
        const to: usize = @intCast(to_i);
        if (to >= self.canvas.layers.items.len or to == from) return;
        const selected_before = self.canvas.selected_layer;
        if (!self.canvas.moveLayer(from, to)) return;
        self.undo.push(self.gpa, .{ .layer_reorder = .{
            .from = from,
            .to = to,
            .selected_before = selected_before,
            .selected_after = self.canvas.selected_layer,
        } });
    }

    fn doToggleLayerVisible(self: *App, idx: usize) void {
        if (self.editingBlocked() or idx >= self.canvas.layers.items.len) return;
        const before = self.canvas.layers.items[idx].visible;
        const after = !before;
        _ = self.canvas.setLayerVisible(idx, after);
        self.undo.push(self.gpa, .{ .layer_visible = .{ .index = idx, .before = before, .after = after } });
    }

    fn doSetLayerOpacity(self: *App, idx: usize, value: u8) void {
        if (self.editingBlocked() or idx >= self.canvas.layers.items.len) return;
        const before = self.canvas.layers.items[idx].opacity;
        if (before == value) return;
        _ = self.canvas.setLayerOpacity(idx, value);
        self.undo.push(self.gpa, .{ .layer_opacity = .{ .index = idx, .before = before, .after = value } });
    }

    fn doSelectLayer(self: *App, idx: usize) void {
        if (self.editingBlocked()) return;
        _ = self.canvas.selectLayer(idx);
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
            self.doRedo();
        } else if (k.key == .Z and accel) {
            self.doUndo();
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
        } else if (k.key == .C) {
            self.doClear();
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
        if (self.bezier_editor.rasterizeCommit(&self.canvas, &self.recorder, self.gpa, dab, self.brush.color, self.brush.opacity)) |cmd| {
            self.undo.push(self.gpa, cmd);
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

/// canvas の straight-alpha composite を canvas rect へ zoom 倍 nearest で転送。
/// fb 境界 + clip（canvas area）で intersection clip し、既存 fb 内容（チェッカー背景）へ src-over する。
/// 不透明 src は置換 / 完全透明は背景維持 / partial はチェッカーへブレンド。
fn blitCanvasZoom(fb: []u32, fb_w: u32, fb_h: u32, composite: []const u32, rect: core.Rect, zoom: i32, clip: core.Rect) void {
    const zu: usize = @intCast(zoom);
    for (0..CANVAS_H) |cy| {
        for (0..CANVAS_W) |cx| {
            const src = composite[cy * CANVAS_W + cx];
            const base_fx: i32 = rect.x + @as(i32, @intCast(cx)) * zoom;
            const base_fy: i32 = rect.y + @as(i32, @intCast(cy)) * zoom;
            for (0..zu) |dy| {
                for (0..zu) |dx| {
                    const fx: i32 = base_fx + @as(i32, @intCast(dx));
                    const fy: i32 = base_fy + @as(i32, @intCast(dy));
                    if (fx < 0 or fy < 0) continue;
                    // canvas area clip（右ペイン/メニュー侵食防止）
                    if (fx < clip.x or fy < clip.y or fx >= clip.x + clip.w or fy >= clip.y + clip.h) continue;
                    const ufx: u32 = @intCast(fx);
                    const ufy: u32 = @intCast(fy);
                    if (ufx >= fb_w or ufy >= fb_h) continue;
                    const idx = ufy * fb_w + ufx;
                    fb[idx] = core.blend.srcOver(fb[idx], src);
                }
            }
        }
    }
}

/// 透明背景チェッカーを screen_rect ∩ clip ∩ fb へ直接描く（screen 固定セル）。canvas blit の直前に呼ぶ。
fn drawCheckerboard(fb: []u32, fb_w: u32, fb_h: u32, screen_rect: core.Rect, clip: core.Rect) void {
    const x0 = @max(@max(screen_rect.x, clip.x), 0);
    const y0 = @max(@max(screen_rect.y, clip.y), 0);
    const x1 = @min(@min(screen_rect.x + screen_rect.w, clip.x + clip.w), @as(i32, @intCast(fb_w)));
    const y1 = @min(@min(screen_rect.y + screen_rect.h, clip.y + clip.h), @as(i32, @intCast(fb_h)));
    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            const cell = @divFloor(x, CHECKER_CELL) + @divFloor(y, CHECKER_CELL);
            const color: u32 = if (@mod(cell, 2) == 0) CHECKER_LIGHT else CHECKER_DARK;
            fb[@as(usize, @intCast(y)) * fb_w + @as(usize, @intCast(x))] = color;
        }
    }
}

/// ビューポートのズーム/パン入力を処理する（endFrame 後・canvas 入力前に呼ぶ）。
/// 戻り値: パン中なら true（呼び出し側は描画入力を抑止する）。zoom/pan の変更は app へ書き戻し、
/// 実際の clamp は次フレームの canvasBlitRect が現 area に対して行う。
fn updateViewport(app: *App, ctx: *const gui.Context, canvas_rect: ?core.Rect) bool {
    const in = &ctx.input;
    const area = app.last_area;

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
    if (in_area and in.scroll_delta.y != 0) {
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
        if (pan_press and !app.input.capturing and !bezier_editing) {
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
    if (ctx.buttonId(LAYER_PANEL_ID_BASE + 1, "+", .{ .min_w = 28 }).clicked) app.doAddLayer();
    if (ctx.buttonId(LAYER_PANEL_ID_BASE + 2, "-", .{ .min_w = 28 }).clicked) app.doDeleteLayer();
    if (ctx.buttonId(LAYER_PANEL_ID_BASE + 3, "Up", .{ .min_w = 34 }).clicked) app.doMoveLayer(1);
    if (ctx.buttonId(LAYER_PANEL_ID_BASE + 4, "Dn", .{ .min_w = 34 }).clicked) app.doMoveLayer(-1);
    ctx.endBox();

    var rev = app.canvas.layers.items.len;
    while (rev > 0) {
        rev -= 1;
        const idx = rev;
        const layer = app.canvas.layers.items[idx];
        // 1 行 = [サムネイル][選択 L{d}][visible][opacity slider]。行高はサムネイル(24px)律速。
        // 横一列で 200px 幅に収め、行を低く保って縦方向に多くの layer を見せる。
        ctx.beginBox(.{ .direction = .row, .gap = 3, .align_cross = .center });

        // サムネイル: raw layer をチェッカー下地へ縮小合成。選択中は枠を明色に。
        const thumb = ctx.allocator().alloc(u32, @as(usize, @intCast(LAYER_THUMB_W)) * @as(usize, @intCast(LAYER_THUMB_H))) catch @panic("layer thumb: OOM");
        fillLayerThumb(thumb, layer.pixels);
        const thumb_border = if (idx == app.canvas.selected_layer) ctx.style.border_hover else ctx.style.border;
        ctx.imageBox(layerWidgetId(idx, 3), thumb, LAYER_THUMB_W, LAYER_THUMB_H, .{ .border = thumb_border });

        const name = try std.fmt.allocPrint(ctx.allocator(), "L{d}", .{idx});
        if (ctx.buttonId(layerWidgetId(idx, 0), name, .{ .selected = idx == app.canvas.selected_layer, .min_w = 28 }).clicked) {
            app.doSelectLayer(idx);
        }
        const vis_label: []const u8 = if (layer.visible) "V" else "H";
        if (ctx.buttonId(layerWidgetId(idx, 1), vis_label, .{ .selected = layer.visible, .min_w = 22 }).clicked) {
            app.doToggleLayerVisible(idx);
        }
        var op_i32: i32 = layer.opacity;
        if (ctx.sliderI32Id(layerWidgetId(idx, 2), "O", &op_i32, .{ .min = 0, .max = 255, .track_w = 40 })) {
            app.doSetLayerOpacity(idx, @intCast(std.math.clamp(op_i32, 0, 255)));
        }
        ctx.endBox(); // row
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
        .gap = 8,
        .bg = gui.Color.rgba(0x28, 0x28, 0x30, 0xFF),
    });
    if (ctx.button("Open")) app.pending_file_op = .open;
    if (ctx.button("Save")) app.pending_file_op = .save;
    if (ctx.button("Save As")) app.pending_file_op = .save_as;
    if (ctx.button("Undo")) app.doUndo();
    if (ctx.button("Redo")) app.doRedo();
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
        // 4 ツールは右ペイン幅に収めるため 2 行に折り返す
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
        ctx.endBox();
        // paste/move のブロック配置トグル（gui に checkbox/radio が無いため、ラベルで ON/OFF 状態を明示する）。
        // ON=透明を保持(src-over・下の絵を残す) / OFF=上書き(replace)。
        const blend_label: []const u8 = if (app.blend_mode == .over) "Keep Transp: ON" else "Keep Transp: OFF";
        if (ctx.buttonEx(blend_label, .{ .selected = app.blend_mode == .over, .min_w = 130 }).clicked) {
            app.blend_mode = if (app.blend_mode == .over) .replace else .over;
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
        .canvas = try core.Canvas.init(gpa, CANVAS_W, CANVAS_H),
        .recorder = try core.StrokeRecorder.init(gpa, CANVAS_W, CANVAS_H),
        .preview_canvas = try core.Canvas.init(gpa, CANVAS_W, CANVAS_H),
        .preview_rec = try core.StrokeRecorder.init(gpa, CANVAS_W, CANVAS_H),
        .palette = try palette_mod.Palette.initDb16(gpa),
        .pen = .{ .color = 0 },
        .brush = .{ .color = 0 },
    };
    app.pen.color = app.palette.current(); // 初期描画色 = パレット先頭
    app.brush.color = app.palette.current();
    defer {
        if (app.current_path) |p| gpa.free(p);
        if (app.palette_path) |p| gpa.free(p);
        if (app.clipboard) |*cb| cb.deinit(gpa);
        app.sel_in.deinit(gpa);
        app.bezier_editor.deinit(gpa);
        app.preview_rec.deinit(gpa);
        app.preview_canvas.deinit();
        app.palette.deinit(gpa);
        app.undo.deinit(gpa);
        app.recorder.deinit(gpa);
        app.canvas.deinit();
    }

    // ヘッドレス検証 harness の custom probe を登録（harness 無効時は no-op）。
    platform.registerProbe(.{ .name = "canvas", .ctx = &app, .ext = "png", .snapshot = canvasSnapshot, .digest = canvasDigest });
    platform.registerProbe(.{ .name = "undo", .ctx = &app, .ext = "json", .snapshot = undoSnapshot, .digest = undoDigest });
    platform.registerProbe(.{ .name = "tool", .ctx = &app, .ext = "txt", .snapshot = toolSnapshot, .digest = toolDigest });

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
                    break :gate in_area and ctx.state.active_id == 0;
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
                    if (app.bez_in.update(frame, &app.bezier_editor, &app.canvas, &app.recorder, gpa, dab, app.brush.color, app.brush.opacity)) |cmd| {
                        app.undo.push(gpa, cmd);
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
                    if (app.sel_in.update(frame, &app.canvas, app.canvas.selected_layer, gpa, app.blend_mode)) |cmd| {
                        app.undo.push(gpa, cmd);
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
                    if (app.input.update(frame, app.activeTool(), &app.canvas, &app.recorder, gpa)) |cmd| {
                        app.undo.push(gpa, cmd);
                    }
                }
            }

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
                    drawCheckerboard(fb.pixels, fb.width, fb.height, screen_rect, area);
                    if (app.active_kind == .bezier and app.bezier_editor.isEditing()) {
                        // 確定前ブラシプレビュー: 本 canvas 全 layer のコピーへ path(+仮点)を実ブラシ描画して表示（非破壊）
                        app.syncPreviewCanvas();
                        const dab = app.brush.footprint();
                        app.bezier_editor.rasterizePreview(&app.preview_canvas, &app.preview_rec, gpa, dab, app.brush.color, app.brush.opacity);
                        blitCanvasZoom(fb.pixels, fb.width, fb.height, app.preview_canvas.compositeStraight(), rect, zoom, area);
                    } else if (app.active_kind == .select and app.sel_in.state == .moving) {
                        // フローティング move プレビュー: 実 canvas は不変のまま、preview_canvas の選択レイヤーへ
                        // 「base+block@現在位置（blend_mode 合成）」を描いて表示する（確定は release）。
                        app.syncPreviewCanvas();
                        _ = app.sel_in.renderMovePreview(app.preview_canvas.layerPixels(app.canvas.selected_layer), CANVAS_W, CANVAS_H, app.blend_mode);
                        blitCanvasZoom(fb.pixels, fb.width, fb.height, app.preview_canvas.compositeStraight(), rect, zoom, area);
                    } else {
                        blitCanvasZoom(fb.pixels, fb.width, fb.height, app.canvas.compositeStraight(), rect, zoom, area);
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
                    (app.sel_in.previewRect(&app.canvas) orelse app.canvas.selection)
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
