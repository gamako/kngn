//! Linux platform backend — X11/Xlib 実装（TASK-28.2）
//!
//! ソフトウェアフレームバッファ方式。caller が書く canonical RGBA `[]u32`
//! （pixel = (R<<24)|(G<<16)|(B<<8)|A）を、present 時に X visual の mask 配置へ変換して
//! XShmPutImage（利用可なら）/ XPutImage で blit する。GPU 不要。
//!
//! 実装方針の詳細は docs/plans/28.2-plan.md / 28.3-plan.md を参照。入力（key/mouse）は本ファイル（TASK-28.3）、
//! ファイルダイアログは TASK-28.4、Wayland は TASK-28.5。
//!
//! 入力の純粋な変換（keycode→KeyCode / state→modifiers / EventQueue 合体 / KeyDownSet）は
//! `platform_linux_input.zig`（@cImport しない純 Zig）に分離し、本ファイルは XEvent から値を取り出して呼ぶだけ。

const std = @import("std");
const types = @import("platform_types.zig");
const input = @import("platform_linux_input.zig");
const build_options = @import("build_options");

const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
    @cInclude("X11/XKBlib.h"); // XkbSetDetectableAutoRepeat
    @cInclude("X11/extensions/XShm.h");
    @cInclude("sys/ipc.h");
    @cInclude("sys/shm.h");
});

const Error = types.Error;
const Event = types.Event;
const EventStats = types.EventStats;
const MouseButton = types.MouseButton;
const MouseButtons = types.MouseButtons;
const MouseEvent = types.MouseEvent;
const SaveDialogOptions = types.SaveDialogOptions;
const OpenDialogOptions = types.OpenDialogOptions;

comptime {
    // 本 backend は x11。wayland は TASK-28.5。build_options 経由で backend が渡る（28.1）。
    if (!std.mem.eql(u8, build_options.platform_backend, "x11")) {
        @compileError("platform_linux: backend '" ++ build_options.platform_backend ++
            "' は未実装です（x11 のみ。wayland は TASK-28.5）");
    }
}

const alloc = std.heap.c_allocator;

/// `XDestroyImage` は Xlib のマクロ（`(*((img)->f.destroy_image))(img)`）で、@cImport が
/// optional 関数ポインタを unwrap せず変換するためそのままでは呼べない。関数ポインタを手動で呼ぶ。
inline fn destroyImage(img: *c.XImage) void {
    _ = img.f.destroy_image.?(img);
}

// ============================================================================
// getTime: clock_gettime(CLOCK_MONOTONIC_RAW) → 失敗時 CLOCK_MONOTONIC
// （link_libc 済み。型を確実に制御するため extern を自前宣言）
// ============================================================================
extern fn clock_gettime(clk_id: c_int, tp: *std.c.timespec) c_int;
const CLOCK_MONOTONIC: c_int = 1;
const CLOCK_MONOTONIC_RAW: c_int = 4;

pub fn getTime() f64 {
    var ts: std.c.timespec = undefined;
    if (clock_gettime(CLOCK_MONOTONIC_RAW, &ts) != 0) {
        if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    }
    return @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) * 1e-9;
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

    // canonical RGBA backing（caller が書く。常にこれを返す）
    backing: []u32,

    // blit
    image: *c.XImage,
    bytes_per_line: usize,
    use_shm: bool,
    shminfo: c.XShmSegmentInfo,
    shmat_ok: bool,
    attached: bool,
    // XPutImage fallback で Zig 所有の転送バッファ（shm 経路では未使用）
    xfer: []u8,

    // pixel 変換（visual mask から算出）
    r_shift: u5,
    g_shift: u5,
    b_shift: u5,
    fast_path: bool,

    // events
    closing: bool,
    quit_delivered: bool,
    queue: input.EventQueue, // 合体 + drop カウントは EventQueue に閉じ込め（純 Zig・テスト可）

    // 入力状態（post-state を作るための backend 内部追跡）
    buttons: MouseButtons, // 現在押下中のマウスボタン集合
    keys: input.KeyDownSet, // keycode 押下集合（is_repeat / 修飾 post-state 判定）
    detectable_repeat: bool, // g_detectable_repeat のコピー

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
        const dpy = g_display orelse return error.WindowCreationFailed;
        if (width == 0 or height == 0) return error.WindowCreationFailed;

        const screen = c.XDefaultScreen(dpy);
        const root = c.XRootWindow(dpy, screen);
        const visual = c.XDefaultVisual(dpy, screen);
        if (visual == null) return error.WindowCreationFailed;
        const depth: c_uint = @intCast(c.XDefaultDepth(dpy, screen));
        const black = c.XBlackPixel(dpy, screen);

        // §2.1: 既定 visual が TrueColor であることを要求（DirectColor 等は colormap 前提で非対応）
        if (visual.*.class != c.TrueColor) return error.WindowCreationFailed;

        const win = c.XCreateSimpleWindow(
            dpy,
            root,
            0,
            0,
            @intCast(width),
            @intCast(height),
            0,
            black,
            black,
        );
        errdefer _ = c.XDestroyWindow(dpy, win);

        _ = c.XStoreName(dpy, win, title.ptr);
        _ = c.XSelectInput(dpy, win, c.ExposureMask | c.StructureNotifyMask |
            c.KeyPressMask | c.KeyReleaseMask |
            c.ButtonPressMask | c.ButtonReleaseMask | c.PointerMotionMask);

        var wm_delete = c.XInternAtom(dpy, "WM_DELETE_WINDOW", 0);
        _ = c.XSetWMProtocols(dpy, win, &wm_delete, 1);

        // 固定サイズを WM に要求（resize 抑止。実 resize 対応は TASK-23）。min=max にする。
        var hints = std.mem.zeroes(c.XSizeHints);
        hints.flags = c.PMinSize | c.PMaxSize;
        hints.min_width = @intCast(width);
        hints.max_width = @intCast(width);
        hints.min_height = @intCast(height);
        hints.max_height = @intCast(height);
        _ = c.XSetWMNormalHints(dpy, win, &hints);

        const gc = c.XDefaultGC(dpy, screen);

        const st = alloc.create(State) catch return error.WindowCreationFailed;
        errdefer alloc.destroy(st);

        st.* = .{
            .display = dpy,
            .window = win,
            .gc = gc,
            .width = width,
            .height = height,
            .wm_delete = wm_delete,
            .backing = undefined,
            .image = undefined,
            .bytes_per_line = 0,
            .use_shm = false,
            .shminfo = std.mem.zeroes(c.XShmSegmentInfo),
            .shmat_ok = false,
            .attached = false,
            .xfer = &.{},
            .r_shift = 0,
            .g_shift = 0,
            .b_shift = 0,
            .fast_path = false,
            .closing = false,
            .quit_delivered = false,
            .queue = .{},
            .buttons = .{},
            .keys = .{},
            .detectable_repeat = g_detectable_repeat,
        };

        // canonical backing（caller が書く）
        const px_count = std.math.mul(usize, width, height) catch return error.WindowCreationFailed;
        st.backing = alloc.alloc(u32, px_count) catch return error.WindowCreationFailed;
        errdefer alloc.free(st.backing);
        @memset(st.backing, 0);

        // blit セットアップ（XShm 可なら shm、不可/失敗なら XPutImage）
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
        _ = c.XDestroyWindow(dpy, st.window);
        alloc.free(st.backing);
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
                    // 固定サイズ運用（resize は TASK-23）。framebuffer 寸法 st.width/height は作成時のまま保持し、
                    // ここでは更新しない（更新すると backing/XImage の範囲外アクセスになる）。WM ヒントで resize 抑止済み。
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
        convert(st);
        const w: c_uint = @intCast(st.width);
        const h: c_uint = @intCast(st.height);
        if (st.use_shm) {
            _ = c.XShmPutImage(dpy, st.window, st.gc, st.image, 0, 0, 0, 0, w, h, 0);
        } else {
            _ = c.XPutImage(dpy, st.window, st.gc, st.image, 0, 0, 0, 0, w, h);
        }
        _ = c.XFlush(dpy);
    }
};

/// Locked framebuffer view（公開 contract は RGBA `[]u32`）。
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
    st.enqueue(.{ .key_down = .{
        .key = input.keycodeToKeyCode(keycode),
        .is_repeat = was_down,
        .modifiers = input.keyEventModifiers(@intCast(e.state), &st.keys, keycode),
    } });
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
            st.enqueue(.{ .key_down = .{
                .key = input.keycodeToKeyCode(keycode),
                .is_repeat = true,
                .modifiers = input.keyEventModifiers(@intCast(next.xkey.state), &st.keys, keycode),
            } });
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

fn setupBlit(st: *State, visual: ?*c.Visual, depth: c_uint, width: u32, height: u32) Error!void {
    const dpy = st.display;

    // XShm 利用可なら shm 経路を試す。
    // 環境変数 VIDEO_PROTO_DISABLE_XSHM をセットすると XShm をスキップして XPutImage 経路を強制する
    // （XShm 不可環境での fallback 検証用。AC#3）。
    const disable_shm = std.c.getenv("VIDEO_PROTO_DISABLE_XSHM") != null;
    if (!disable_shm and c.XShmQueryExtension(dpy) != 0) {
        if (trySetupShm(st, visual, depth, width, height)) {
            try validateAndComputeShifts(st);
            return;
        }
        // 失敗 → fallback
    }
    try setupPutImage(st, visual, depth, width, height);
    try validateAndComputeShifts(st);
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

    const buf = alloc.alloc(u8, size) catch {
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

/// §2.1: bits_per_pixel==32 / mask 8bit 連続 を検証し、shift を算出。
fn validateAndComputeShifts(st: *State) Error!void {
    const img = st.image;
    if (img.*.bits_per_pixel != 32) return failBlit(st);

    const rm: c_ulong = img.*.red_mask;
    const gm: c_ulong = img.*.green_mask;
    const bm: c_ulong = img.*.blue_mask;
    if (rm == 0 or gm == 0 or bm == 0) return failBlit(st);
    // mask が互いに重ならないこと（重なると変換結果が壊れる）
    if ((rm & gm) != 0 or (rm & bm) != 0 or (gm & bm) != 0) return failBlit(st);

    const rs = maskShift(rm) orelse return failBlit(st);
    const gs = maskShift(gm) orelse return failBlit(st);
    const bs = maskShift(bm) orelse return failBlit(st);

    st.r_shift = rs;
    st.g_shift = gs;
    st.b_shift = bs;
    st.fast_path = (rs == 16 and gs == 8 and bs == 0);
}

/// 8bit 連続マスクの shift 量（trailing zeros）。8bit 連続でなければ null。
fn maskShift(mask: c_ulong) ?u5 {
    const sh: u6 = @intCast(@ctz(mask));
    if (sh > 31) return null;
    if ((mask >> @intCast(sh)) != 0xFF) return null; // 8bit 連続でない
    return @intCast(sh);
}

/// blit リソース（XImage / XShm seg or Zig 所有転送バッファ）の解放。`destroy` と `failBlit` で共用。
/// RMID は attach 成功時に実施済みなので、ここでは行わない（§3.7 の状態機械）。
fn teardownBlit(st: *State) void {
    if (st.use_shm) {
        if (st.attached) _ = c.XShmDetach(st.display, &st.shminfo);
        destroyImage(st.image);
        if (st.shmat_ok) _ = c.shmdt(st.shminfo.shmaddr);
    } else {
        // XPutImage fallback: data は Zig 所有。XDestroyImage に解放させない。
        st.image.data = null;
        destroyImage(st.image);
        if (st.xfer.len != 0) alloc.free(st.xfer);
    }
}

fn failBlit(st: *State) Error {
    // 検証失敗時は確保済みリソースを解放してから失敗を返す（create の errdefer が backing/State を解放）
    teardownBlit(st);
    return error.WindowCreationFailed;
}

/// canonical RGBA(0xRRGGBBAA) → image.data（visual mask 配置）へ変換。
fn convert(st: *State) void {
    const w = st.width;
    const h = st.height;
    const data: [*]u8 = @ptrCast(st.image.*.data);
    const bpl = st.bytes_per_line;

    var y: usize = 0;
    while (y < h) : (y += 1) {
        const row: [*]u32 = @ptrCast(@alignCast(data + y * bpl));
        const src = st.backing[y * w ..][0..w];
        if (st.fast_path) {
            var x: usize = 0;
            while (x < w) : (x += 1) row[x] = src[x] >> 8; // 0xRRGGBBAA → 0x00RRGGBB
        } else {
            var x: usize = 0;
            while (x < w) : (x += 1) {
                const p = src[x];
                const r: u32 = (p >> 24) & 0xFF;
                const g: u32 = (p >> 16) & 0xFF;
                const b: u32 = (p >> 8) & 0xFF;
                row[x] = (r << st.r_shift) | (g << st.g_shift) | (b << st.b_shift);
            }
        }
    }
}

// ============================================================================
// ファイル選択ダイアログ（TASK-28.4 で zenity 実装。現状 stub）
// ============================================================================
pub fn saveFileDialog(gpa: std.mem.Allocator, opts: SaveDialogOptions) std.mem.Allocator.Error!?[]u8 {
    _ = gpa;
    _ = opts;
    @panic("platform_linux: file dialog not implemented yet (TASK-28.4)");
}

pub fn openFileDialog(gpa: std.mem.Allocator, opts: OpenDialogOptions) std.mem.Allocator.Error!?[]u8 {
    _ = gpa;
    _ = opts;
    @panic("platform_linux: file dialog not implemented yet (TASK-28.4)");
}
