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
const png_decoder = @import("png-decoder");
const canvas_input = @import("canvas_input.zig");
const palette_mod = @import("palette.zig");
const bezier_input = @import("bezier_input.zig");
const bezier_overlay = @import("bezier_overlay.zig");

const WINDOW_W: u32 = 780;
const WINDOW_H: u32 = 600;
const CANVAS_W: u32 = 256;
const CANVAS_H: u32 = 256;
const ZOOM: i32 = 2;
const SAVE_MSG_DURATION: f64 = 3.0;

/// ファイル操作要求。framebuffer lock 中（フレーム処理中）に発生した要求を保持し、
/// unlock 後の安全点で 1 回だけ実行する（ダイアログのモーダルループ再入を避ける）。
const FileOp = enum { save, save_as, open, save_palette, load_palette };

/// canvas 領域の明示 ID（getNodeRect での外部参照用。自動 ID は不可）
const CANVAS_AREA_ID: gui.Id = 0xC0FFEE01;

const COLOR_WINDOW_BG: u32 = 0xFF_20_20_24;

/// canvas pixel（0xAABBGGRR）→ gui.Color（同一ビットレイアウト）。スウォッチ/プレビュー描画用。
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
        const maybe = platform.saveFileDialog(self.gpa, .{
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
        const maybe = platform.openFileDialog(self.gpa, .{ .allowed_ext = "gpl" }) catch |err| {
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
        const maybe = platform.saveFileDialog(self.gpa, .{
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
        const maybe = platform.openFileDialog(self.gpa, .{ .allowed_ext = "png" }) catch |err| {
            self.setSaveMsg("Load failed: {s}", .{@errorName(err)});
            return;
        };
        const path = maybe orelse return; // キャンセル: サイレント no-op
        var img = png_decoder.decodePNGFile(self.io, self.gpa, path) catch |err| {
            self.setSaveMsg("Load failed: {s}", .{@errorName(err)});
            self.gpa.free(path);
            return;
        };
        defer img.deinit(self.gpa);

        // 左上クロップ/パディング: layer0 を透明クリアし、収まる範囲を行ごとに memcpy。
        // png_decoder の出力は 0xAABBGGRR で canvas と同一レイアウトなので変換不要。
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
        if (k.key == .ESCAPE) {
            self.running = false;
        } else if (k.key == .Q and k.modifiers.cmd) {
            self.running = false;
        } else if (k.key == .S and k.modifiers.cmd and k.modifiers.shift) {
            self.pending_file_op = .save_as;
        } else if (k.key == .S and k.modifiers.cmd) {
            self.pending_file_op = .save;
        } else if (k.key == .O and k.modifiers.cmd) {
            self.pending_file_op = .open;
        } else if (k.key == .Z and k.modifiers.cmd and k.modifiers.shift) {
            self.doRedo();
        } else if (k.key == .Z and k.modifiers.cmd) {
            self.doUndo();
        } else if (k.key == .B) {
            self.setActiveKind(.pen);
        } else if (k.key == .E) {
            self.setActiveKind(.eraser);
        } else if (k.key == .P) {
            self.setActiveKind(.bezier);
        } else if (k.key == .C) {
            self.doClear();
        }
    }

    /// ベジェ確定（現在ブラシ footprint + color/opacity で rasterize → UndoStack へ push）。
    fn commitBezier(self: *App) void {
        const dab = self.brush.footprint();
        if (self.bezier_editor.rasterizeCommit(&self.canvas, &self.recorder, self.gpa, dab, self.brush.color, self.brush.opacity)) |cmd| {
            self.undo.push(self.gpa, cmd);
        }
    }
};

/// canvas_area rect 内に表示領域（256*ZOOM 四方）を中央配置した canvas rect
/// （core.Rect の w/h は canvas ピクセル数。screenToCanvas* がこの形を取る）。
/// 初回フレームは rect キャッシュ未生成なので null（canvas 入力・blit をスキップ）。
fn canvasBlitRect(ctx: *const gui.Context) ?core.Rect {
    const area = ctx.getNodeRect(CANVAS_AREA_ID) orelse return null;
    const vw: i32 = @as(i32, @intCast(CANVAS_W)) * ZOOM;
    const vh: i32 = @as(i32, @intCast(CANVAS_H)) * ZOOM;
    return .{
        .x = area.x + @divFloor(@as(i32, @intCast(area.w)) - vw, 2),
        .y = area.y + @divFloor(@as(i32, @intCast(area.h)) - vh, 2),
        .w = @intCast(CANVAS_W),
        .h = @intCast(CANVAS_H),
    };
}

/// canvas composite を canvas rect へ ZOOM 倍 nearest-neighbor で転送（fb 境界 clip）
fn blitCanvasZoom(fb: []u32, fb_w: u32, fb_h: u32, composite: []const u32, rect: core.Rect) void {
    for (0..CANVAS_H) |cy| {
        for (0..CANVAS_W) |cx| {
            const color = composite[cy * CANVAS_W + cx] | 0xFF000000;
            const base_fx: i32 = rect.x + @as(i32, @intCast(cx)) * ZOOM;
            const base_fy: i32 = rect.y + @as(i32, @intCast(cy)) * ZOOM;
            for (0..@as(usize, @intCast(ZOOM))) |dy| {
                for (0..@as(usize, @intCast(ZOOM))) |dx| {
                    const fx: i32 = base_fx + @as(i32, @intCast(dx));
                    const fy: i32 = base_fy + @as(i32, @intCast(dy));
                    if (fx < 0 or fy < 0) continue;
                    const ufx: u32 = @intCast(fx);
                    const ufy: u32 = @intCast(fy);
                    if (ufx >= fb_w or ufy >= fb_h) continue;
                    fb[ufy * fb_w + ufx] = color;
                }
            }
        }
    }
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
                ZOOM,
            )) |cp| {
                break :blk try std.fmt.allocPrint(arena, "cursor: ({d}, {d})", .{ cp.x, cp.y });
            }
        }
        break :blk "cursor: -";
    };
    ctx.labelEx(cursor_txt, ctx.style.text_subtle);
    {
        const c = app.palette.current();
        const r: u8 = @truncate(c);
        const g: u8 = @truncate(c >> 8);
        const b: u8 = @truncate(c >> 16);
        ctx.labelEx(
            try std.fmt.allocPrint(arena, "color: #{X:0>2}{X:0>2}{X:0>2} ({d})", .{ r, g, b, app.palette.colors.items.len }),
            ctx.style.text_subtle,
        );
    }
    ctx.labelEx(
        try std.fmt.allocPrint(arena, "tool: {s}", .{app.active_kind.name()}),
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
                    else => {},
                }
                if (toGuiEvent(ev)) |ge| ctx.pushEvent(ge);
            }

            // canvas rect は前フレームの layout 結果（初回フレームは null）
            const canvas_rect = canvasBlitRect(&ctx);

            try buildUi(&ctx, &app, canvas_rect);
            ctx.endFrame();

            // ── canvas 入力。capturing 最優先（既存 stroke を完走）。bezier は独立経路 ──
            {
                const in = &ctx.input;
                if (app.active_kind == .bezier and !app.input.capturing) {
                    const frame: bezier_input.BezierInput.Frame = .{
                        .canvas_rect = canvas_rect,
                        .zoom = ZOOM,
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
                        .zoom = ZOOM,
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

            // ── 描画: bg → canvas blit → GUI（上に重ねる） ──
            @memset(fb.pixels, COLOR_WINDOW_BG);
            if (canvas_rect) |rect| {
                if (app.active_kind == .bezier and app.bezier_editor.isEditing()) {
                    // 確定前ブラシプレビュー: 本 layer のコピーへ path(+仮点)を実ブラシ描画して表示（非破壊）
                    @memcpy(app.preview_canvas.layerPixels(0), app.canvas.layerPixels(0));
                    const dab = app.brush.footprint();
                    app.bezier_editor.rasterizePreview(&app.preview_canvas, &app.preview_rec, gpa, dab, app.brush.color, app.brush.opacity);
                    blitCanvasZoom(fb.pixels, fb.width, fb.height, app.preview_canvas.composite(), rect);
                } else {
                    blitCanvasZoom(fb.pixels, fb.width, fb.height, app.canvas.composite(), rect);
                }
            }
            // ベジェ編集中のハンドル/アンカー UI を draw_list へ（プレビューの上、gui.render で焼かれる）
            if (app.active_kind == .bezier) {
                if (canvas_rect) |rect| bezier_overlay.draw(&ctx, &app.bezier_editor, rect, ZOOM);
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
