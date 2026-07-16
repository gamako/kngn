//! Linux platform backend — X11/Xlib 実装（TASK-28.2 / 28.6 / 28.5.1 で分離）
//!
//! `src/platform_linux.zig`（dispatcher）が `build_options.platform_backend == "x11"` のとき選ぶ。
//! display 非依存の `getTime` / ファイルダイアログは `platform_linux_common.zig` に分離し re-export する。
//!
//! ソフトウェアフレームバッファ方式。caller は canonical BGRA `[]u32`
//! （u32 0xAARRGGBB / メモリ [B,G,R,A]）を書く。
//!
//! present 時の blit は visual 分類（`platform_linux_convert.classifyVisual`、TASK-28.6 / AC#4）で 2 経路に分かれる:
//!   - **direct**: 32bpp & LSBFirst & rs16/gs8/bs0 & stride==width*4。canonical BGRA の低24bit が
//!     標準 visual の 0x00RRGGBB に一致するため、XImage/shm バッファを caller に直接書かせ
//!     （`lockFramebuffer` が image data を返す）、present は XShmPutImage/XPutImage のみ（**毎フレーム変換コピー無し**）。
//!   - **fallback**: 32bpp & LSBFirst & RGB 各8bit連続だが（非標準 shift または stride padding）の visual。
//!     別持ちの backing(BGRA) を present で `packPixel`（BGRA→visual mask）変換してから blit する。
//!   - **fail**: 16/24bpp・565・非連続/重複 mask・MSBFirst は create を WindowCreationFailed にする（拡張しない）。
//!
//! direct/fallback の判定と変換は純粋ロジック（`platform_linux_convert.zig`）に分離し display 無しで単体テストする。
//! 実装方針の詳細は docs/plans/28.2-plan.md / 28.3-plan.md を参照。入力（key/mouse）は本ファイル（TASK-28.3）、
//! ファイルダイアログは TASK-28.4、Wayland は TASK-28.5。
//!
//! 入力の純粋な変換（keycode→KeyCode / state→modifiers / EventQueue 合体 / KeyDownSet）は
//! `platform_linux_input.zig`（@cImport しない純 Zig）に分離し、本ファイルは XEvent から値を取り出して呼ぶだけ。

const std = @import("std");
const types = @import("platform_types");
const input = @import("platform_linux_input.zig");
const conv = @import("platform_linux_convert.zig");
const common = @import("platform_linux_common.zig");
const build_options = @import("build_options");

const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
    @cInclude("X11/Xatom.h"); // XA_ATOM（createFullscreen の _NET_WM_STATE 設定用。TASK-100）
    @cInclude("X11/XKBlib.h"); // XkbSetDetectableAutoRepeat
    @cInclude("X11/cursorfont.h"); // XC_left_ptr / XC_crosshair（system cursor。TASK-75.3）
    @cInclude("X11/extensions/XShm.h");
    @cInclude("X11/extensions/shape.h"); // クリック透過の input shape（TASK-104.2）
    @cInclude("sys/ipc.h");
    @cInclude("sys/shm.h");
});

const Error = types.Error;
const Event = types.Event;
const EventStats = types.EventStats;
const MouseButton = types.MouseButton;
const MouseButtons = types.MouseButtons;
const MouseEvent = types.MouseEvent;

comptime {
    // 本ファイルは x11 実装。dispatcher(platform_linux.zig)が build_options.platform_backend=="x11"
    // のときだけ import する。誤って他 backend で取り込まれた場合に明確に落とす二重防御（28.5.1）。
    if (!std.mem.eql(u8, build_options.platform_backend, "x11")) {
        @compileError("platform_linux_x11: backend '" ++ build_options.platform_backend ++
            "' で X11 実装が import された（dispatcher は x11 のときだけ選ぶはず）");
    }
}

const alloc = std.heap.c_allocator;

// getTime / ファイルダイアログ（display 非依存）は common に分離。公開面を保つため re-export する。
pub const getTime = common.getTime;
pub const saveFileDialog = common.saveFileDialog;
pub const openFileDialog = common.openFileDialog;

/// `XDestroyImage` は Xlib のマクロ（`(*((img)->f.destroy_image))(img)`）で、@cImport が
/// optional 関数ポインタを unwrap せず変換するためそのままでは呼べない。関数ポインタを手動で呼ぶ。
inline fn destroyImage(img: *c.XImage) void {
    _ = img.f.destroy_image.?(img);
}

// ============================================================================
// init / shutdown（プロセス単一の Display）
// ============================================================================
var g_display: ?*c.Display = null;

/// detectable auto-repeat が有効化できたか（Display スコープ）。init で確定し、create で State へコピーする。
/// 有効時はキーリピートが KeyRelease を伴わない連続 KeyPress として来る（is_repeat 判定が単純化）。
var g_detectable_repeat: bool = false;

pub fn init() Error!void {
    if (g_display != null) return;
    const dpy = c.XOpenDisplay(null) orelse return error.InitFailed;
    g_display = dpy;

    // is_repeat 判定の第一候補。supported=true なら KeyDownSet の「既 down か」だけで repeat を判定できる。
    // 非対応環境では pollEvents 側の KeyRelease→KeyPress 先読み fallback に切り替わる。
    var supported: c.Bool = 0;
    _ = c.XkbSetDetectableAutoRepeat(dpy, 1, &supported);
    g_detectable_repeat = supported != 0;
}

pub fn shutdown() void {
    if (g_display) |d| {
        _ = c.XCloseDisplay(d);
        g_display = null;
    }
}

// ============================================================================
// XShm attach 用の一時 X error handler（BadAccess/BadShmSeg を握る）
// ============================================================================
var g_shm_error: bool = false;

fn shmErrorHandler(d: ?*c.Display, e: ?*c.XErrorEvent) callconv(.c) c_int {
    _ = d;
    _ = e;
    g_shm_error = true;
    return 0;
}

// ============================================================================
// Window / State
// ============================================================================

const State = struct {
    display: *c.Display,
    window: c.Window,
    gc: c.GC,
    width: u32,
    height: u32,
    wm_delete: c.Atom,
    // resize（TASK-23）で setupBlit を再実行するため、作成時の visual/depth を保持する。
    visual: ?*c.Visual,
    depth: c_uint,

    // canonical BGRA framebuffer（caller が書く。lockFramebuffer が返す）。
    // direct: image data を別名参照（別 alloc しない）。fallback: 別持ち alloc。
    backing: []u32,

    // blit
    image: *c.XImage,
    bytes_per_line: usize,
    use_shm: bool,
    shminfo: c.XShmSegmentInfo,
    shmat_ok: bool,
    attached: bool,
    // XPutImage 経路で Zig 所有の image data バッファ（shm 経路では未使用）。
    // []u32 で確保し u32 alignment を保証する（image data を []u32 として直書き/変換するため）。
    xfer: []u32,

    // 直書き可否（classifyVisual の結果）。true なら present は変換コピー無しで blit。
    direct: bool,
    // fallback 時の pixel 変換 shift（visual mask から算出。direct では未使用）
    r_shift: u5,
    g_shift: u5,
    b_shift: u5,

    // events
    closing: bool,
    quit_delivered: bool,
    queue: input.EventQueue, // 合体 + drop カウントは EventQueue に閉じ込め（純 Zig・テスト可）

    // 入力状態（post-state を作るための backend 内部追跡）
    buttons: MouseButtons, // 現在押下中のマウスボタン集合
    keys: input.KeyDownSet, // keycode 押下集合（is_repeat / 修飾 post-state 判定）
    detectable_repeat: bool, // g_detectable_repeat のコピー

    // system cursor（TASK-75.3）: CursorShape(default/crosshair/hidden) 別に遅延生成した
    // X11 Cursor をキャッシュ（0=None=未生成）。destroy で XFreeCursor する。
    cursors: [3]c.Cursor = .{ 0, 0, 0 },

    // 透過 / borderless / クリック透過（TASK-104.2）
    transparent: bool = false,
    borderless: bool = false,
    click_through: bool = false,
    colormap: c.Colormap = 0, // 透過 ARGB visual 用（destroy で XFreeColormap。0=既定 visual で未作成）
    own_gc: bool = false, // st.gc を XCreateGC で自作したか（透過 window 用。destroy で XFreeGC）
    ct_region_valid: bool = false, // click-through input shape 設定済みか（未設定なら次 present で 1 回計算）

    fn enqueue(self: *State, ev: Event) void {
        self.queue.enqueue(ev);
    }

    fn dequeue(self: *State) ?Event {
        return self.queue.dequeue();
    }
};

pub const Window = struct {
    state: *State,

    pub fn create(width: u32, height: u32, title: [:0]const u8) Error!Window {
        return createInternal(width, height, title, false, .{});
    }

    /// 透過 / borderless オプション付き作成（TASK-104.2）。facade が @hasDecl で検出して使う。
    /// 透過は 32bit ARGB visual（XMatchVisualInfo。無ければ error.Unsupported）+ colormap + XCreateWindow。
    /// **実際に背後が透けるにはコンポジタ（picom 等）が必要**。ホットパス宣言: 初期化時のみ。
    pub fn createWithOptions(width: u32, height: u32, title: [:0]const u8, opts: types.WindowOptions) Error!Window {
        return createInternal(width, height, title, false, opts);
    }

    /// 本物のフルスクリーンウィンドウを作成する（agent-face 向け。TASK-100。装飾なし・画面解像度いっぱい）。
    /// 画面解像度は `XDisplayWidth`/`XDisplayHeight`（既定 screen）で取得し、`XMapWindow` 前に
    /// EWMH `_NET_WM_STATE_FULLSCREEN` を `_NET_WM_STATE` プロパティへセットする。準拠 WM は
    /// map 時点でこれを見て装飾なし・画面サイズへフルスクリーン化する（`create()` の挙動は無変更）。
    pub fn createFullscreen(title: [:0]const u8) Error!Window {
        const dpy = g_display orelse return error.WindowCreationFailed;
        const screen = c.XDefaultScreen(dpy);
        const w: u32 = @intCast(c.XDisplayWidth(dpy, screen));
        const h: u32 = @intCast(c.XDisplayHeight(dpy, screen));
        return createInternal(w, h, title, true, .{});
    }

    fn createInternal(width: u32, height: u32, title: [:0]const u8, fullscreen: bool, opts: types.WindowOptions) Error!Window {
        const dpy = g_display orelse return error.WindowCreationFailed;
        if (width == 0 or height == 0) return error.WindowCreationFailed;

        const screen = c.XDefaultScreen(dpy);
        const root = c.XRootWindow(dpy, screen);

        var visual: ?*c.Visual = undefined;
        var depth: c_uint = undefined;
        var win: c.Window = undefined;
        var colormap: c.Colormap = 0;
        var own_gc = false;
        var gc: c.GC = undefined;

        if (opts.transparent) {
            // 32bit ARGB TrueColor visual を探す（無ければ透過不可）。colormap + XCreateWindow で作る。
            var vinfo: c.XVisualInfo = undefined;
            if (c.XMatchVisualInfo(dpy, screen, 32, c.TrueColor, &vinfo) == 0) return error.Unsupported;
            // canonical BGRA(0xAARRGGBB) の直書き経路（classifyVisual=direct）で alpha を保つには標準
            // ARGB 配置（R=0xFF0000/G=0xFF00/B=0xFF）が必須。非標準 shift は fallback 変換で alpha が
            // 落ちる（全画素透明化）ため、ここで弾いて Unsupported にする（codex 指摘）。
            if (vinfo.visual.*.red_mask != 0xFF0000 or vinfo.visual.*.green_mask != 0x00FF00 or vinfo.visual.*.blue_mask != 0x0000FF) {
                return error.Unsupported;
            }
            visual = vinfo.visual;
            depth = 32;
            colormap = c.XCreateColormap(dpy, root, vinfo.visual, c.AllocNone);
            if (colormap == 0) return error.WindowCreationFailed;
            errdefer _ = c.XFreeColormap(dpy, colormap); // colormap のみこの分岐内で守る（win 前に確保するため）
            var attrs = std.mem.zeroes(c.XSetWindowAttributes);
            attrs.colormap = colormap;
            attrs.border_pixel = 0;
            attrs.background_pixel = 0; // 透明背景
            attrs.event_mask = c.ExposureMask | c.StructureNotifyMask |
                c.KeyPressMask | c.KeyReleaseMask |
                c.ButtonPressMask | c.ButtonReleaseMask | c.PointerMotionMask;
            const valuemask: c_ulong = c.CWColormap | c.CWBorderPixel | c.CWBackPixel | c.CWEventMask;
            win = c.XCreateWindow(dpy, root, 0, 0, @intCast(width), @intCast(height), 0, 32, c.InputOutput, vinfo.visual, valuemask, &attrs);
            if (win == 0) return error.WindowCreationFailed; // ここまでで失敗 → 上の errdefer が colormap 解放
            // 32bit drawable には depth 一致の GC が要る（既定 GC は depth 24 で BadMatch になりうる）。
            gc = c.XCreateGC(dpy, win, 0, null) orelse {
                _ = c.XDestroyWindow(dpy, win);
                return error.WindowCreationFailed; // colormap は errdefer が解放
            };
            own_gc = true;
        } else {
            visual = c.XDefaultVisual(dpy, screen);
            if (visual == null) return error.WindowCreationFailed;
            depth = @intCast(c.XDefaultDepth(dpy, screen));
            const black = c.XBlackPixel(dpy, screen);
            // §2.1: 既定 visual が TrueColor であることを要求（DirectColor 等は colormap 前提で非対応）
            if (visual.?.class != c.TrueColor) return error.WindowCreationFailed;
            win = c.XCreateSimpleWindow(dpy, root, 0, 0, @intCast(width), @intCast(height), 0, black, black);
            gc = c.XDefaultGC(dpy, screen);
        }
        // 以降（setupBlit / alloc.create 等）の失敗で win/GC/colormap をまとめて解放（透過生成のリーク防止）。
        // 成功時は State が所有し destroy() が解放するので、この errdefer は発火しない。非透過は own_gc=false /
        // colormap=0 なので XDestroyWindow のみ（従来と同じ）。
        errdefer {
            if (own_gc) _ = c.XFreeGC(dpy, gc);
            _ = c.XDestroyWindow(dpy, win);
            if (colormap != 0) _ = c.XFreeColormap(dpy, colormap);
        }

        _ = c.XStoreName(dpy, win, title.ptr);
        _ = c.XSelectInput(dpy, win, c.ExposureMask | c.StructureNotifyMask |
            c.KeyPressMask | c.KeyReleaseMask |
            c.ButtonPressMask | c.ButtonReleaseMask | c.PointerMotionMask);

        var wm_delete = c.XInternAtom(dpy, "WM_DELETE_WINDOW", 0);
        _ = c.XSetWMProtocols(dpy, win, &wm_delete, 1);

        if (fullscreen) {
            // EWMH: map 前に _NET_WM_STATE へ _NET_WM_STATE_FULLSCREEN をセットしておくと、
            // 準拠 WM は map 時点で装飾なしの本物のフルスクリーンにする（後追いの
            // ClientMessage 送信は不要）。format=32 の要素は Atom(=c_ulong. 64bit では long 幅)。
            const net_wm_state = c.XInternAtom(dpy, "_NET_WM_STATE", 0);
            var fullscreen_atom = c.XInternAtom(dpy, "_NET_WM_STATE_FULLSCREEN", 0);
            _ = c.XChangeProperty(dpy, win, net_wm_state, c.XA_ATOM, 32, c.PropModeReplace, @ptrCast(&fullscreen_atom), 1);
        } else {
            // resizable（TASK-23）。最小サイズだけ与え、max は与えない（自由リサイズ）。
            var hints = std.mem.zeroes(c.XSizeHints);
            hints.flags = c.PMinSize;
            hints.min_width = 1;
            hints.min_height = 1;
            _ = c.XSetWMNormalHints(dpy, win, &hints);
        }

        // TASK-104.2: borderless は _MOTIF_WM_HINTS で装飾を落とす + タスクバー/pager 非表示（マスコット向け）。
        if (opts.borderless) {
            const motif = c.XInternAtom(dpy, "_MOTIF_WM_HINTS", 0);
            // MotifWmHints: [flags, functions, decorations, input_mode, status]。flags=MWM_HINTS_DECORATIONS(1<<1)、decorations=0。
            var mwm = [5]c_ulong{ 2, 0, 0, 0, 0 };
            _ = c.XChangeProperty(dpy, win, motif, motif, 32, c.PropModeReplace, @ptrCast(&mwm), 5);
            const net_wm_state = c.XInternAtom(dpy, "_NET_WM_STATE", 0);
            var skip = [2]c.Atom{
                c.XInternAtom(dpy, "_NET_WM_STATE_SKIP_TASKBAR", 0),
                c.XInternAtom(dpy, "_NET_WM_STATE_SKIP_PAGER", 0),
            };
            _ = c.XChangeProperty(dpy, win, net_wm_state, c.XA_ATOM, 32, c.PropModeReplace, @ptrCast(&skip), 2);
        }

        const st = alloc.create(State) catch return error.WindowCreationFailed;
        errdefer alloc.destroy(st);

        st.* = .{
            .display = dpy,
            .window = win,
            .gc = gc,
            .width = width,
            .height = height,
            .wm_delete = wm_delete,
            .visual = visual,
            .depth = depth,
            .transparent = opts.transparent,
            .borderless = opts.borderless,
            .colormap = colormap,
            .own_gc = own_gc,
            .backing = &.{},
            .image = undefined,
            .bytes_per_line = 0,
            .use_shm = false,
            .shminfo = std.mem.zeroes(c.XShmSegmentInfo),
            .shmat_ok = false,
            .attached = false,
            .xfer = &.{},
            .direct = false,
            .r_shift = 0,
            .g_shift = 0,
            .b_shift = 0,
            .closing = false,
            .quit_delivered = false,
            .queue = .{},
            .buttons = .{},
            .keys = .{},
            .detectable_repeat = g_detectable_repeat,
        };

        // blit セットアップ（XShm 可なら shm、不可/失敗なら XPutImage）。
        // visual 分類で direct/fallback を決め、st.backing（caller が書く canonical BGRA）も確定する。
        try setupBlit(st, visual, depth, width, height);

        // blit 準備が成功してから map（失敗時に一瞬 map されるのを防ぐ）
        _ = c.XMapWindow(dpy, win);
        _ = c.XFlush(dpy);
        return .{ .state = st };
    }

    pub fn destroy(self: Window) void {
        const st = self.state;
        const dpy = st.display;

        teardownBlit(st);
        // system cursor（TASK-75.3）: キャッシュ済み Cursor を解放。
        for (st.cursors) |cur| {
            if (cur != 0) _ = c.XFreeCursor(dpy, cur);
        }
        if (st.own_gc) _ = c.XFreeGC(dpy, st.gc); // TASK-104.2: 透過 window 用の自作 GC を解放
        _ = c.XDestroyWindow(dpy, st.window);
        if (st.colormap != 0) _ = c.XFreeColormap(dpy, st.colormap); // 透過 ARGB colormap を解放
        // fallback の backing は別 alloc。direct の backing は image data の別名なので teardownBlit が解放済み。
        if (!st.direct) alloc.free(st.backing);
        alloc.destroy(st);
    }

    pub fn pollEvents(self: Window) bool {
        const st = self.state;
        const dpy = st.display;
        // XPending を毎回確認するループ（固定回数 snapshot にしない）。KeyRelease の repeat fallback が
        // XNextEvent で 1 件余分に消費しても件数ずれでブロックしないため（§28.3-plan 2.5）。
        while (c.XPending(dpy) > 0) {
            var ev: c.XEvent = undefined;
            _ = c.XNextEvent(dpy, &ev);
            switch (ev.type) {
                c.ClientMessage => {
                    // WM_DELETE_WINDOW
                    const atom: c.Atom = @intCast(ev.xclient.data.l[0]);
                    if (atom == st.wm_delete and !st.closing) {
                        st.closing = true;
                        st.enqueue(.quit);
                    }
                },
                c.ConfigureNotify => {
                    // 自由リサイズ（TASK-23）。新サイズで blit を two-phase 再確保する。
                    // pollEvents はフレーム境界（lock 外）で呼ばれるので再確保は安全。
                    const cw: u32 = @intCast(ev.xconfigure.width);
                    const ch: u32 = @intCast(ev.xconfigure.height);
                    resizeBlit(st, cw, ch);
                },
                c.Expose => {}, // present は毎フレーム呼ばれるので no-op
                c.KeyPress => handleKeyPress(st, &ev.xkey),
                c.KeyRelease => handleKeyRelease(st, dpy, &ev.xkey),
                c.ButtonPress => handleButtonPress(st, &ev.xbutton),
                c.ButtonRelease => handleButtonRelease(st, &ev.xbutton),
                c.MotionNotify => handleMotion(st, &ev.xmotion),
                else => {},
            }
        }
        return !st.quit_delivered;
    }

    pub fn nextEvent(self: Window) ?Event {
        const st = self.state;
        const ev = st.dequeue() orelse return null;
        if (ev == .quit) st.quit_delivered = true;
        return ev;
    }

    /// quit event を consumer が処理した後、close latch を解除する。
    /// ホットパス宣言: quit/close イベント時のみ。
    pub fn cancelQuit(self: Window) void {
        self.state.closing = false;
        self.state.quit_delivered = false;
    }

    pub fn getEventStats(self: Window) EventStats {
        const q = &self.state.queue;
        return .{
            .mouse_move_merge_count = q.mouse_move_merge_count,
            .mouse_scroll_merge_count = q.mouse_scroll_merge_count,
            .event_drop_count = q.event_drop_count,
        };
    }

    pub fn lockFramebuffer(self: Window) ?Framebuffer {
        const st = self.state;
        return .{
            .pixels = st.backing,
            .width = st.width,
            .height = st.height,
            .state = st,
        };
    }

    pub fn present(self: Window) void {
        const st = self.state;
        const dpy = st.display;
        if (st.click_through and !st.ct_region_valid) refreshInputShape(st); // TASK-104.2: 有効化後 1 回だけ
        // direct は caller が image data を直接書いているので変換不要。fallback のみ backing→image data 変換。
        if (!st.direct) convert(st);
        const w: c_uint = @intCast(st.width);
        const h: c_uint = @intCast(st.height);
        if (st.use_shm) {
            _ = c.XShmPutImage(dpy, st.window, st.gc, st.image, 0, 0, 0, 0, w, h, 0);
        } else {
            _ = c.XPutImage(dpy, st.window, st.gc, st.image, 0, 0, 0, 0, w, h);
        }
        _ = c.XFlush(dpy);
    }

    /// TASK-104.2: 対話的ウィンドウ移動を WM へ依頼する（_NET_WM_MOVERESIZE）。押下 grab を外し、
    /// 現在のポインタ root 座標 + button + source を載せて root へ ClientMessage を送る。
    /// ホットパス宣言: イベント時のみ。
    pub fn beginDrag(self: Window) void {
        const st = self.state;
        const dpy = st.display;
        const screen = c.XDefaultScreen(dpy);
        const root = c.XRootWindow(dpy, screen);
        // ポインタ root 座標を取得。
        var rret: c.Window = undefined;
        var cret: c.Window = undefined;
        var rx: c_int = 0;
        var ry: c_int = 0;
        var wx: c_int = 0;
        var wy: c_int = 0;
        var mask: c_uint = 0;
        _ = c.XQueryPointer(dpy, st.window, &rret, &cret, &rx, &ry, &wx, &wy, &mask);
        _ = c.XUngrabPointer(dpy, c.CurrentTime); // press grab を外して WM に move を渡す
        const net = c.XInternAtom(dpy, "_NET_WM_MOVERESIZE", 0);
        var ev = std.mem.zeroes(c.XEvent);
        ev.xclient.type = c.ClientMessage;
        ev.xclient.window = st.window;
        ev.xclient.message_type = net;
        ev.xclient.format = 32;
        ev.xclient.data.l[0] = rx; // x_root
        ev.xclient.data.l[1] = ry; // y_root
        ev.xclient.data.l[2] = 8; // _NET_WM_MOVERESIZE_MOVE
        ev.xclient.data.l[3] = 1; // button 1（左）
        ev.xclient.data.l[4] = 1; // source indication = application
        _ = c.XSendEvent(dpy, root, 0, c.SubstructureRedirectMask | c.SubstructureNotifyMask, &ev);
        _ = c.XFlush(dpy);
    }

    /// TASK-104.2: 常に最前面（_NET_WM_STATE_ABOVE の add/remove ClientMessage）。WM 依存（graceful）。
    /// ホットパス宣言: イベント時のみ。
    pub fn setAlwaysOnTop(self: Window, on: bool) void {
        const st = self.state;
        const dpy = st.display;
        const screen = c.XDefaultScreen(dpy);
        const root = c.XRootWindow(dpy, screen);
        const net_state = c.XInternAtom(dpy, "_NET_WM_STATE", 0);
        const above = c.XInternAtom(dpy, "_NET_WM_STATE_ABOVE", 0);
        var ev = std.mem.zeroes(c.XEvent);
        ev.xclient.type = c.ClientMessage;
        ev.xclient.window = st.window;
        ev.xclient.message_type = net_state;
        ev.xclient.format = 32;
        ev.xclient.data.l[0] = if (on) 1 else 0; // _NET_WM_STATE_ADD / REMOVE
        ev.xclient.data.l[1] = @intCast(above);
        ev.xclient.data.l[2] = 0;
        ev.xclient.data.l[3] = 1; // source = application
        _ = c.XSendEvent(dpy, root, 0, c.SubstructureRedirectMask | c.SubstructureNotifyMask, &ev);
        _ = c.XFlush(dpy);
    }

    /// TASK-104.2: クリック透過（X Shape の input shape）。on のとき次 present で不透明画素 bbox を
    /// input shape に設定し透明余白のクリックを背後へ抜けさせる。off で input shape を全面へ戻す。
    /// ホットパス宣言: イベント時のみ（present 側の bbox 走査は有効化後 1 回だけ・ct_region_valid ゲート）。
    pub fn setClickThrough(self: Window, on: bool) void {
        const st = self.state;
        st.click_through = on;
        st.ct_region_valid = false; // 再有効化でも silhouette 再走査（次 present）
        if (!on) {
            // input shape を全面（NULL region = bounding と一致）へ戻す。
            c.XShapeCombineMask(st.display, st.window, c.ShapeInput, 0, 0, 0, c.ShapeSet);
            _ = c.XFlush(st.display);
        }
    }

    /// カーソル形状の設定（TASK-75.3）。CursorShape 別に Cursor を遅延生成・キャッシュし XDefineCursor で反映。
    /// 呼び出し頻度: ツール切替・キー入力等のイベント時のみ（性能規約の対象外）。
    /// 生成失敗は best-effort no-op（描画・実行を壊さない）。
    pub fn setCursor(self: Window, shape: types.CursorShape) void {
        const st = self.state;
        const idx: usize = @intCast(@intFromEnum(shape));
        if (idx >= st.cursors.len) return; // non-exhaustive な値は無視
        if (st.cursors[idx] == 0) st.cursors[idx] = createCursor(st, shape);
        const cur = st.cursors[idx];
        if (cur == 0) return; // 作成失敗
        _ = c.XDefineCursor(st.display, st.window, cur);
        _ = c.XFlush(st.display);
    }

    /// ライブリサイズ再描画コールバック（TASK-23.1）。X11 はモーダルループが無く元々ライブなので no-op スタブ。
    pub fn setRedrawCallback(self: Window, ctx: *anyopaque, cb: *const fn (ctx: *anyopaque) void) void {
        _ = self;
        _ = ctx;
        _ = cb;
    }

    /// destroy 用の private clear 経路（no-op。TASK-23.1）。
    pub fn clearRedrawCallback(self: Window) void {
        _ = self;
    }

    /// IME composition snapshot（TASK-79.6.1）。Linux IME は 79.6.3。常に空。
    pub fn getCompositionSnapshot(self: Window, buf: []u8) types.CompositionSnapshot {
        _ = self;
        return .{ .text = buf[0..0], .revision = 0, .cursor = 0 };
    }
};

/// CursorShape → X11 Cursor を生成する（失敗時は 0=None）。default/crosshair は標準カーソルフォント、
/// hidden は透明 1x1 pixmap カーソル。
fn createCursor(st: *State, shape: types.CursorShape) c.Cursor {
    return switch (shape) {
        .default => c.XCreateFontCursor(st.display, c.XC_left_ptr),
        .crosshair => c.XCreateFontCursor(st.display, c.XC_crosshair),
        .hidden => createHiddenCursor(st),
    };
}

/// 透明カーソル: 全ビット 0 の 1x1 bitmap を source/mask に使い XCreatePixmapCursor で作る。
fn createHiddenCursor(st: *State) c.Cursor {
    var data = [_]u8{0};
    const bmp = c.XCreateBitmapFromData(st.display, st.window, &data, 1, 1);
    if (bmp == 0) return 0;
    defer _ = c.XFreePixmap(st.display, bmp);
    var col = std.mem.zeroes(c.XColor);
    return c.XCreatePixmapCursor(st.display, bmp, bmp, &col, &col, 0, 0);
}

/// Locked framebuffer view（公開 contract は canonical BGRA `[]u32`、u32 0xAARRGGBB）。
/// direct モードでは pixels が XImage/shm バッファを直接指す（present で変換コピーされない）。
pub const Framebuffer = struct {
    pixels: []u32,
    width: u32,
    height: u32,
    state: *State,

    pub fn unlock(self: Framebuffer) void {
        _ = self; // present 時に変換するので unlock 自体は no-op
    }
};

// ============================================================================
// 入力イベント変換（XEvent → platform.Event）。純粋ロジックは platform_linux_input.zig。
// ============================================================================

fn handleKeyPress(st: *State, e: *c.XKeyEvent) void {
    const keycode: u32 = @intCast(e.keycode);
    // detectable auto-repeat 有効時、リピートは KeyRelease を伴わない連続 KeyPress として来る。
    // 「直前に既に down だったか」がそのまま is_repeat になる（非対応時の repeat は handleKeyRelease の fallback が直接生成）。
    const was_down = st.keys.isDown(keycode);
    st.keys.setDown(keycode, true); // 修飾 post-state 算出は反映後に行う
    const mods = input.keyEventModifiers(@intCast(e.state), &st.keys, keycode);
    st.enqueue(.{ .key_down = .{
        .key = input.keycodeToKeyCode(keycode),
        .is_repeat = was_down,
        .modifiers = mods,
    } });
    // 確定文字 (TASK-22): XLookupString で確定文字を取り char_input を流す。英数 MVP は Latin-1 で十分
    // （UTF-8/CJK は XIM/Xutf8LookupString が要る=将来スコープ）。key_down 経路は上で不変。
    var cbuf: [8]u8 = undefined;
    var keysym: c.KeySym = undefined;
    const n = c.XLookupString(e, &cbuf, cbuf.len, &keysym, null);
    if (n > 0) {
        var i: usize = 0;
        while (i < @as(usize, @intCast(n))) : (i += 1) {
            const cp: u32 = cbuf[i]; // Latin-1 codepoint
            if (input.isTextCodepoint(cp)) {
                st.enqueue(.{ .char_input = .{ .codepoint = cp, .modifiers = mods } });
            }
        }
    }
}

fn handleKeyRelease(st: *State, dpy: *c.Display, e: *c.XKeyEvent) void {
    const keycode: u32 = @intCast(e.keycode);

    // 非 detectable 環境の repeat fallback: KeyRelease の直後に同 keycode・同 time の KeyPress が
    // 控えていれば、それはリピート（キーは離されていない）。Release を握り潰し、その KeyPress を
    // 実消費して is_repeat=true で流す（peek だけでは消費されない）。
    if (!st.detectable_repeat and c.XPending(dpy) > 0) {
        var next: c.XEvent = undefined;
        _ = c.XPeekEvent(dpy, &next);
        if (next.type == c.KeyPress and next.xkey.keycode == e.keycode and next.xkey.time == e.time) {
            _ = c.XNextEvent(dpy, &next); // peek した KeyPress を実消費
            // keys は down のまま（離していない）。
            const rmods = input.keyEventModifiers(@intCast(next.xkey.state), &st.keys, keycode);
            st.enqueue(.{ .key_down = .{
                .key = input.keycodeToKeyCode(keycode),
                .is_repeat = true,
                .modifiers = rmods,
            } });
            // repeat 中も char_input を出す（押しっぱなしのテキスト入力。codex 指摘 #4）。消費した
            // KeyPress を XLookupString（Ctrl+A 等は制御文字化されて isTextCodepoint で自然に除外される）。
            var cbuf: [8]u8 = undefined;
            var ksym: c.KeySym = undefined;
            const rn = c.XLookupString(&next.xkey, &cbuf, cbuf.len, &ksym, null);
            if (rn > 0) {
                var i: usize = 0;
                while (i < @as(usize, @intCast(rn))) : (i += 1) {
                    const cp: u32 = cbuf[i];
                    if (input.isTextCodepoint(cp)) {
                        st.enqueue(.{ .char_input = .{ .codepoint = cp, .modifiers = rmods } });
                    }
                }
            }
            return;
        }
    }

    // 通常の解放
    st.keys.setDown(keycode, false);
    st.enqueue(.{ .key_up = .{
        .key = input.keycodeToKeyCode(keycode),
        .is_repeat = false,
        .modifiers = input.keyEventModifiers(@intCast(e.state), &st.keys, keycode),
    } });
}

fn setButton(st: *State, mb: MouseButton, down: bool) void {
    switch (mb) {
        .left => st.buttons.left = down,
        .right => st.buttons.right = down,
        .middle => st.buttons.middle = down,
        else => {},
    }
}

/// MouseEvent を組む。buttons は内部追跡（post-state）、modifiers は state mask（mouse は修飾が変化しない）。
fn mouseEvent(st: *State, x: c_int, y: c_int, button: MouseButton, state: u32) MouseEvent {
    return .{
        .x = @intCast(x),
        .y = @intCast(y),
        .button = button,
        .buttons = st.buttons,
        .modifiers = input.stateToModifiers(state),
    };
}

fn handleButtonPress(st: *State, e: *c.XButtonEvent) void {
    const button: u32 = @intCast(e.button);
    if (input.buttonToMouseButton(button)) |mb| {
        setButton(st, mb, true); // post-state（押下を含む）にしてから event を作る
        st.enqueue(.{ .mouse_down = mouseEvent(st, e.x, e.y, mb, @intCast(e.state)) });
    } else if (input.wheelDelta(button)) |d| {
        st.enqueue(.{ .mouse_scroll = .{
            .x = @intCast(e.x),
            .y = @intCast(e.y),
            .dx = d.dx,
            .dy = d.dy,
            .is_precise = false,
            .buttons = st.buttons,
            .modifiers = input.stateToModifiers(@intCast(e.state)),
        } });
    }
    // それ以外の button は無視
}

fn handleButtonRelease(st: *State, e: *c.XButtonEvent) void {
    const button: u32 = @intCast(e.button);
    if (input.buttonToMouseButton(button)) |mb| {
        setButton(st, mb, false); // post-state（解放を反映）にしてから event を作る
        st.enqueue(.{ .mouse_up = mouseEvent(st, e.x, e.y, mb, @intCast(e.state)) });
    }
    // wheel(4-7) の Release は無視
}

fn handleMotion(st: *State, e: *c.XMotionEvent) void {
    st.enqueue(.{ .mouse_move = mouseEvent(st, e.x, e.y, .none, @intCast(e.state)) });
}

// ============================================================================
// blit セットアップ / pixel 変換
// ============================================================================

/// TASK-104.2: クリック透過用に不透明画素（alpha>0）から **per-pixel の 1bit マスク**を作り、X Shape の
/// input shape に設定する（透明画素＝alpha0 のクリックは正確に背後へ抜け、不透明画素＝本体はクリックを受ける）。
/// bounding box では丸い絵の透明な四隅も窓が受けてしまう（クリック透過が効かない）ため、per-pixel マスクにする。
/// ct_region_valid でゲートし有効化後 1 回だけ走る（毎フレーム全画素ループにしない＝性能規約準拠）。
/// canonical BGRA の alpha は上位 8bit。XCreateBitmapFromData は LSB-first・行ごと byte 境界 pad。
fn refreshInputShape(st: *State) void {
    const w = st.width;
    const h = st.height;
    const px = st.backing;
    if (px.len < @as(usize, w) * @as(usize, h)) return;
    const stride = (w + 7) / 8; // 1 行あたりの byte 数（8px/byte、byte 境界 pad）
    const data = alloc.alloc(u8, @as(usize, stride) * @as(usize, h)) catch return;
    defer alloc.free(data);
    @memset(data, 0);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const row = @as(usize, y) * @as(usize, w);
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            if ((px[row + x] >> 24) != 0) { // 不透明画素 → bit を立てる（この画素はクリックを受ける）
                data[@as(usize, y) * @as(usize, stride) + (x >> 3)] |= (@as(u8, 1) << @intCast(x & 7));
            }
        }
    }
    const bmp = c.XCreateBitmapFromData(st.display, st.window, @ptrCast(data.ptr), @intCast(w), @intCast(h));
    if (bmp == 0) return; // 失敗時は valid を立てず次 present で再試行
    c.XShapeCombineMask(st.display, st.window, c.ShapeInput, 0, 0, bmp, c.ShapeSet);
    _ = c.XFreePixmap(st.display, bmp);
    _ = c.XFlush(st.display);
    st.ct_region_valid = true;
}

fn setupBlit(st: *State, visual: ?*c.Visual, depth: c_uint, width: u32, height: u32) Error!void {
    const dpy = st.display;

    // XShm 利用可なら shm 経路を試す。
    // 環境変数 VIDEO_PROTO_DISABLE_XSHM をセットすると XShm をスキップして XPutImage 経路を強制する
    // （XShm 不可環境での fallback 検証用。AC#3）。
    const disable_shm = std.c.getenv("VIDEO_PROTO_DISABLE_XSHM") != null;
    if (!disable_shm and c.XShmQueryExtension(dpy) != 0) {
        if (trySetupShm(st, visual, depth, width, height)) {
            try classifyAndSetupBacking(st, width, height);
            return;
        }
        // 失敗 → fallback
    }
    try setupPutImage(st, visual, depth, width, height);
    try classifyAndSetupBacking(st, width, height);
}

/// XShm 経路。成功で true、失敗（fallback すべき）で false。
fn trySetupShm(st: *State, visual: ?*c.Visual, depth: c_uint, width: u32, height: u32) bool {
    const dpy = st.display;
    // shminfo は image / X サーバから参照され続けるため、安定アドレス（heap の st.shminfo）を直接使う。
    // ローカル変数を渡すと関数を抜けた後 dangling になり XShmPutImage で BadShmSeg になる。
    st.shminfo = std.mem.zeroes(c.XShmSegmentInfo);

    const image = c.XShmCreateImage(dpy, visual, depth, c.ZPixmap, null, &st.shminfo, @intCast(width), @intCast(height)) orelse return false;

    const bpl: c_int = image.*.bytes_per_line;
    if (bpl <= 0) {
        destroyImage(image);
        return false;
    }
    const size = std.math.mul(usize, @intCast(bpl), height) catch {
        destroyImage(image);
        return false;
    };

    const shmid = c.shmget(c.IPC_PRIVATE, @intCast(size), c.IPC_CREAT | 0o600);
    if (shmid < 0) {
        destroyImage(image);
        return false;
    }
    st.shminfo.shmid = shmid;

    const addr = c.shmat(shmid, null, 0);
    if (@intFromPtr(addr) == @as(usize, @bitCast(@as(isize, -1)))) {
        _ = c.shmctl(shmid, c.IPC_RMID, null);
        destroyImage(image);
        return false;
    }
    st.shminfo.shmaddr = @ptrCast(addr);
    image.*.data = @ptrCast(addr);
    st.shminfo.readOnly = 0;

    // 既存の未処理 X error を drain してから handler を差し替える（attach 判定の偽陽性を防ぐ）
    _ = c.XSync(dpy, 0);
    g_shm_error = false;
    const old = c.XSetErrorHandler(shmErrorHandler);
    _ = c.XShmAttach(dpy, &st.shminfo);
    _ = c.XSync(dpy, 0);
    _ = c.XSetErrorHandler(old);

    if (g_shm_error) {
        // attach 失敗: XShmDetach は呼ばない
        _ = c.shmdt(st.shminfo.shmaddr);
        _ = c.shmctl(st.shminfo.shmid, c.IPC_RMID, null);
        image.*.data = null;
        destroyImage(image);
        return false;
    }

    // attach 成功 → 「最後の detach で自動削除」マーク（ここ 1 回だけ）
    _ = c.shmctl(st.shminfo.shmid, c.IPC_RMID, null);

    st.image = image;
    st.shmat_ok = true;
    st.attached = true;
    st.use_shm = true;
    st.bytes_per_line = @intCast(bpl);
    return true;
}

/// XPutImage 経路（XShm 不可/失敗時）。data は Zig 所有。
fn setupPutImage(st: *State, visual: ?*c.Visual, depth: c_uint, width: u32, height: u32) Error!void {
    const dpy = st.display;
    // data=null で作成し bytes_per_line を確定させる
    const image = c.XCreateImage(dpy, visual, depth, c.ZPixmap, 0, null, @intCast(width), @intCast(height), 32, 0) orelse return error.WindowCreationFailed;

    const bpl: c_int = image.*.bytes_per_line;
    if (bpl <= 0) {
        destroyImage(image);
        return error.WindowCreationFailed;
    }
    const size = std.math.mul(usize, @intCast(bpl), height) catch {
        destroyImage(image);
        return error.WindowCreationFailed;
    };

    // image data は []u32 として別名参照（direct）/ 変換書き込み（fallback）するため、
    // u32 単位で確保して alignment を型で保証する。size を u32 個数へ切り上げ（>= size バイト）。
    const u32_len = (size + 3) / 4;
    const buf = alloc.alloc(u32, u32_len) catch {
        destroyImage(image);
        return error.WindowCreationFailed;
    };
    @memset(buf, 0);
    image.*.data = @ptrCast(buf.ptr);

    st.image = image;
    st.xfer = buf;
    st.use_shm = false;
    st.bytes_per_line = @intCast(bpl);
}

/// XImage 作成後、visual を classifyVisual で分類し direct/fallback の backing を確定する（AC#4）。
/// fail（非32bpp / MSBFirst / 非連続・重複 mask / 16・24bpp・565 等）は WindowCreationFailed。
fn classifyAndSetupBacking(st: *State, width: u32, height: u32) Error!void {
    const img = st.image;
    const bpp: u32 = @intCast(img.*.bits_per_pixel);
    const byte_order: conv.ByteOrder = if (img.*.byte_order == c.MSBFirst) .msb_first else .lsb_first;
    const rm: u64 = img.*.red_mask;
    const gm: u64 = img.*.green_mask;
    const bm: u64 = img.*.blue_mask;

    const px_count = std.math.mul(usize, width, height) catch return failBlit(st);

    switch (conv.classifyVisual(bpp, byte_order, st.bytes_per_line, width, rm, gm, bm)) {
        .fail => return failBlit(st),
        .direct => {
            // 標準 visual: 低24bit が 0x00RRGGBB に一致するので caller が image data を直接書く（変換コピー無し）。
            // backing は image data の別名（別 alloc しない）。
            st.direct = true;
            const base: [*]u32 = @ptrCast(@alignCast(img.*.data));
            st.backing = base[0..px_count];
            @memset(st.backing, 0);
        },
        .fallback => {
            // 非標準 shift / stride padding: backing(BGRA) を別持ちし present で packPixel 変換する。
            st.direct = false;
            st.r_shift = conv.maskShift(rm) orelse return failBlit(st);
            st.g_shift = conv.maskShift(gm) orelse return failBlit(st);
            st.b_shift = conv.maskShift(bm) orelse return failBlit(st);
            const buf = alloc.alloc(u32, px_count) catch return failBlit(st);
            @memset(buf, 0);
            st.backing = buf;
        },
    }
}

/// blit リソース（XImage / XShm seg or Zig 所有転送バッファ）の解放。`destroy` と `failBlit` で共用。
/// RMID は attach 成功時に実施済みなので、ここでは行わない（§3.7 の状態機械）。
fn teardownBlit(st: *State) void {
    if (st.use_shm) {
        if (st.attached) _ = c.XShmDetach(st.display, &st.shminfo);
        destroyImage(st.image);
        if (st.shmat_ok) _ = c.shmdt(st.shminfo.shmaddr);
    } else {
        // XPutImage 経路: image data は Zig 所有（st.xfer）。XDestroyImage に解放させない。
        st.image.data = null;
        destroyImage(st.image);
        if (st.xfer.len != 0) alloc.free(st.xfer);
    }
}

fn failBlit(st: *State) Error {
    // 検証失敗時は確保済み blit リソースを解放してから失敗を返す（backing は未確定なので解放不要、
    // create の errdefer が window/State を解放）。
    teardownBlit(st);
    return error.WindowCreationFailed;
}

// ── リサイズ（TASK-23）。two-phase: 新 blit を確保成功後に旧 blit を解放する ──

/// blit 関連フィールドの snapshot。resize の two-phase（新確保→旧解放 / 失敗時は旧復元）に使う。
const BlitState = struct {
    backing: []u32,
    image: *c.XImage,
    bytes_per_line: usize,
    use_shm: bool,
    shminfo: c.XShmSegmentInfo,
    shmat_ok: bool,
    attached: bool,
    xfer: []u32,
    direct: bool,
    r_shift: u5,
    g_shift: u5,
    b_shift: u5,
};

fn captureBlit(st: *const State) BlitState {
    return .{
        .backing = st.backing,
        .image = st.image,
        .bytes_per_line = st.bytes_per_line,
        .use_shm = st.use_shm,
        .shminfo = st.shminfo,
        .shmat_ok = st.shmat_ok,
        .attached = st.attached,
        .xfer = st.xfer,
        .direct = st.direct,
        .r_shift = st.r_shift,
        .g_shift = st.g_shift,
        .b_shift = st.b_shift,
    };
}

fn restoreBlit(st: *State, b: BlitState) void {
    st.backing = b.backing;
    st.image = b.image;
    st.bytes_per_line = b.bytes_per_line;
    st.use_shm = b.use_shm;
    st.shminfo = b.shminfo;
    st.shmat_ok = b.shmat_ok;
    st.attached = b.attached;
    st.xfer = b.xfer;
    st.direct = b.direct;
    st.r_shift = b.r_shift;
    st.g_shift = b.g_shift;
    st.b_shift = b.b_shift;
}

/// BlitState（snapshot 値）のリソースを解放する。teardownBlit の value 版 + fallback backing 解放。
fn freeBlitState(dpy: *c.Display, b: *BlitState) void {
    if (b.use_shm) {
        if (b.attached) _ = c.XShmDetach(dpy, &b.shminfo);
        destroyImage(b.image);
        if (b.shmat_ok) _ = c.shmdt(b.shminfo.shmaddr);
    } else {
        b.image.data = null;
        destroyImage(b.image);
        if (b.xfer.len != 0) alloc.free(b.xfer);
    }
    // fallback backing は別 alloc。direct backing は image data の別名なので上で解放済み。
    if (!b.direct and b.backing.len != 0) alloc.free(b.backing);
}

/// ConfigureNotify で呼ぶ。新サイズで setupBlit を試し、成功したら旧 blit を解放して
/// st.width/height を更新する。失敗（OOM 等）時は旧 blit を復元して旧サイズを維持する（window を壊さない）。
fn resizeBlit(st: *State, new_w: u32, new_h: u32) void {
    if (new_w == 0 or new_h == 0) return; // 最小化/ゼロは無視
    if (new_w == st.width and new_h == st.height) return;

    var old = captureBlit(st);
    // setupBlit は st の blit フィールドを新リソースで上書きする（失敗時は内部の failBlit が
    // 新リソースを解放するが st のフィールドは dangling のまま残る → 下の catch で旧値へ復元する）。
    setupBlit(st, st.visual, st.depth, new_w, new_h) catch {
        restoreBlit(st, old);
        return;
    };
    st.width = new_w;
    st.height = new_h;
    st.ct_region_valid = false; // TASK-104.2: サイズ変更で click-through input shape を再計算させる（旧マスクは stale）
    freeBlitState(st.display, &old);
}

/// fallback 経路: canonical BGRA(0xAARRGGBB) backing → image data（visual mask 配置）へ変換。
/// stride padding は bytes_per_line を見ることで吸収する。direct 経路では呼ばれない。
fn convert(st: *State) void {
    const w = st.width;
    const h = st.height;
    const data: [*]u8 = @ptrCast(st.image.*.data);
    const bpl = st.bytes_per_line;

    var y: usize = 0;
    while (y < h) : (y += 1) {
        const row: [*]u32 = @ptrCast(@alignCast(data + y * bpl));
        const src = st.backing[y * w ..][0..w];
        var x: usize = 0;
        while (x < w) : (x += 1) {
            row[x] = conv.packPixel(src[x], st.r_shift, st.g_shift, st.b_shift);
        }
    }
}
