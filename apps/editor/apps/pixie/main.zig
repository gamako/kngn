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
const SAVE_MSG_DURATION: f64 = 3.0;

/// ファイル操作要求。framebuffer lock 中（フレーム処理中）に発生した要求を保持し、
/// unlock 後の安全点で 1 回だけ実行する（ダイアログのモーダルループ再入を避ける）。
const FileOp = enum { save, save_as, open, save_palette, load_palette };

/// canvas 領域の明示 ID（getNodeRect での外部参照用。自動 ID は不可）
const CANVAS_AREA_ID: gui.Id = 0xC0FFEE01;

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

    fn name(self: ToolKind) []const u8 {
        return switch (self) {
            .pen => "Pen",
            .eraser => "Eraser",
            .brush => "Brush",
            .bezier => "Bezier",
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
        };
    }

    /// ツール切替を一元化（active_kind への代入は全てここ経由）。
    /// capture 中は切替しない（既存 stroke を宙ぶらりんにしない）。.bezier から出る時は未確定パスを cancel。
    fn setActiveKind(self: *App, next: ToolKind) void {
        if (self.input.capturing) return;
        if (self.active_kind == .bezier and next != .bezier) {
            self.bezier_editor.update(self.gpa, .cancel);
        }
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
        // 表示は composite だが、保存は raw layer pixels（21.6 の不変条件:
        // composite を保存すると消しゴムの透明が白に潰れて round-trip が壊れる）
        const raw = self.canvas.layerPixels(0);
        core.savePNG(self.io, path, raw, CANVAS_W, CANVAS_H, self.gpa) catch |err| {
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
        const raw = self.canvas.layerPixels(0);
        core.savePNG(self.io, path, raw, CANVAS_W, CANVAS_H, self.gpa) catch |err| {
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

        // load はドキュメント差し替えなので undo/redo 履歴を破棄（recorder は stroke 非進行中）
        self.undo.deinit(self.gpa);
        self.undo = .{};

        if (self.current_path) |old| self.gpa.free(old);
        self.current_path = path; // 移譲
        self.setSaveMsg("Loaded: {s}", .{std.fs.path.basename(path)});
    }

    /// 編集系コマンドは stroke 中は無視する（仕様の簡略化指示）
    fn doUndo(self: *App) void {
        if (self.input.capturing or self.bezier_editor.isEditing()) return;
        self.undo.undoOne(self.gpa, &self.canvas);
    }

    fn doRedo(self: *App) void {
        if (self.input.capturing or self.bezier_editor.isEditing()) return;
        self.undo.redoOne(self.gpa, &self.canvas);
    }

    fn doClear(self: *App) void {
        if (self.input.capturing or self.bezier_editor.isEditing()) return;
        self.undo.pushClear(self.gpa, &self.canvas, 0);
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
            self.running = false;
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
        } else if (k.key == .B) {
            self.setActiveKind(.pen);
        } else if (k.key == .E) {
            self.setActiveKind(.eraser);
        } else if (k.key == .P) {
            self.setActiveKind(.bezier);
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

/// canvas digest: サイズ / layer 数 / raw layer pixels の crc / 非ゼロ画素数（描画変化を検出できる）。
fn canvasDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const raw = app.canvas.layerPixels(0);
    const crc = png.crc32(std.mem.sliceAsBytes(raw));
    var nonzero: usize = 0;
    for (raw) |p| {
        if (p != 0) nonzero += 1;
    }
    return std.fmt.bufPrint(buf, "{d}x{d} layers={d} crc={X:0>8} nonzero={d}", .{
        CANVAS_W, CANVAS_H, app.canvas.layers.items.len, crc, nonzero,
    }) catch buf[0..0];
}

/// canvas snapshot: raw layer pixels を PNG 化（表示 composite ではなく raw＝透明保持の不変条件）。
fn canvasSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    return core.encodePNG(app.canvas.layerPixels(0), CANVAS_W, CANVAS_H, allocator);
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

/// UI ツリー構築（widget の同期 hit-test もここで走る）
fn buildUi(ctx: *gui.Context, app: *App, canvas_rect: ?core.Rect) !void {
    // 選択/load 変更フレームに編集 HSV を現在色から再同期（以後は編集中 HSV を保持）
    app.syncEditHsv();
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
    ctx.endBox();

    // ── 2 段目: canvas area (grow) + right pane (fixed 200) ──
    ctx.beginBox(.{
        .direction = .row,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .gap = 8,
    });

    // canvas area: 明示 ID・中身空（blit は endFrame 後に別パスで行う）。
    // GUI render は canvas blit の後に重ねるため、bg を持たせると canvas を上塗り
    // してしまう → bg なし（ウィンドウ背景がそのまま見える）
    ctx.beginBox(.{
        .id = CANVAS_AREA_ID,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
    });
    ctx.endBox();

    // right pane: Palette + Tool
    ctx.beginBox(.{
        .width = .{ .fixed = 200 },
        .height = .{ .grow = 1 },
        .padding = .{ 8, 8, 8, 8 },
        .gap = 6,
        .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF),
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
    ctx.endBox(); // right pane

    ctx.endBox(); // 2 段目

    // ── 3 段目: timeline placeholder（将来用、高さ 0） ──
    ctx.beginBox(.{ .width = .{ .grow = 1 }, .height = .{ .fixed = 0 } });
    ctx.endBox();

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
                if (app.active_kind == .bezier and !app.input.capturing) {
                    const frame: bezier_input.BezierInput.Frame = .{
                        .canvas_rect = canvas_rect,
                        .zoom = app.view_zoom,
                        .mouse_pos = .{ .x = in.mouse_pos.x, .y = in.mouse_pos.y },
                        .mouse_pressed_pos = .{ .x = in.mouse_pressed_pos.x, .y = in.mouse_pressed_pos.y },
                        .pressed_left = in.mouse_pressed.left,
                        .released_left = in.mouse_released.left,
                        .time = platform.getTime(),
                    };
                    const dab = app.brush.footprint();
                    if (app.bez_in.update(frame, &app.bezier_editor, &app.canvas, &app.recorder, gpa, dab, app.brush.color, app.brush.opacity)) |cmd| {
                        app.undo.push(gpa, cmd);
                    }
                } else {
                    const frame: canvas_input.CanvasInput.Frame = .{
                        .canvas_rect = canvas_rect,
                        .zoom = app.view_zoom,
                        .mouse_pos = .{ .x = in.mouse_pos.x, .y = in.mouse_pos.y },
                        .mouse_pressed_pos = .{ .x = in.mouse_pressed_pos.x, .y = in.mouse_pressed_pos.y },
                        .pressed_left = in.mouse_pressed.left,
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
                        // 確定前ブラシプレビュー: 本 layer のコピーへ path(+仮点)を実ブラシ描画して表示（非破壊）
                        @memcpy(app.preview_canvas.layerPixels(0), app.canvas.layerPixels(0));
                        const dab = app.brush.footprint();
                        app.bezier_editor.rasterizePreview(&app.preview_canvas, &app.preview_rec, gpa, dab, app.brush.color, app.brush.opacity);
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
