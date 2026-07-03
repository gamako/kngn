//! ヘッドレス検証 harness（TASK-32: P1 file replay + fb probe / P2 live TCP + audio・stats probe）
//!
//! 目的: 既存アプリを無改造で、`src/platform.zig`(facade) のフックだけで
//!   - 入力注入（key/mouse/scroll）
//!   - 仮想クロック（getTime = frame_index/60）
//!   - probe（`fb` PNG/digest, `audio` WAV/digest, `stats` JSON）
//! を実現する。env 未設定なら全 API は no-op（既存挙動と完全一致）。
//!
//! ## トランスポート（コマンドの来る経路）
//! - **replay（file）**: `VP_HARNESS_SCRIPT=<file>` を全部読み、step で仮想フレーム前進、EOF/quit で auto-exit。
//! - **live（TCP loopback）**: `VP_HARNESS_LIVE=1`（ephemeral）または `VP_HARNESS_PORT=<n>`（固定）で
//!   `127.0.0.1` に listen。driver が1接続=1リクエスト（複数コマンド可）=1レスポンスで叩く。状態はプロセスに残る。
//! - **スクリプト形式 == ライブ protocol**: パーサ・実行モデルは共通。差分は「コマンド source（file/socket）」と
//!   「step がコマンド到着まで block する（live は pollGate が accept でブロック）」点のみ。
//!
//! ## レスポンス sink と framing
//! digest/snapshot のコア payload は共通。framing は sink が決める:
//!   - replay: stderr に `[harness] digest <probe> <payload>` / `[harness] snapshot <probe> -> <path> (<info>)`（P1 と byte 一致）
//!   - live  : 接続へ prefix なしの protocol 行 `<probe> <payload>` / `<path>` を返す
//!
//! ## record↔replay 対称
//! live 受信コマンドを `VP_HARNESS_RECORD=<file>` に追記すれば、それを `VP_HARNESS_SCRIPT` に渡して replay できる
//! （文法・状態遷移の対称。`fb` は仮想クロックで bit 決定論、`audio` は RT 実時間依存で bit 一致は非保証）。
//!
//! ## 依存と非依存
//! - import は `std` / `platform_types.zig`(共有型) / `png`(エンコーダ+crc32) のみ。
//!   backend(platform_macos/linux*) と audio backend には依存しない。audio サンプルは `audio.zig` facade が
//!   `onAudioSamples()` で push する（依存方向 audio→harness）。
//! - facade フックは io を持たないため、ファイル I/O / TCP は harness が自前の `std.Io.Threaded` io で行う。

const std = @import("std");
const types = @import("platform_types");
const png = @import("png");

const Event = types.Event;
const KeyCode = types.KeyCode;
const KeyEvent = types.KeyEvent;
const MouseEvent = types.MouseEvent;
const ScrollEvent = types.ScrollEvent;
const MouseButton = types.MouseButton;
const MouseButtons = types.MouseButtons;
const ModifierFlags = types.ModifierFlags;
const EventStats = types.EventStats;

const net = std.Io.net;

const gpa = std.heap.page_allocator;
const Tok = std.mem.TokenIterator(u8, .any);

/// harness 有効時の仮想フレームレート（getTime=frame/60 と整合する固定値。実性能計測ではない）。
const VIRTUAL_FPS: f64 = 60.0;

// audio tap（latest-wins SPSC）。producer=RT スレッドが head を進めて書く（満杯でも上書き）、
// consumer=メインスレッドが「直近窓」を non-destructive に peek する。
const AUDIO_CAP: usize = 1 << 16; // interleaved f32 サンプル数（48kHz stereo で ~0.68s）
const AUDIO_MASK: usize = AUDIO_CAP - 1;
const ANALYZE_FRAMES: usize = 4096; // digest 解析窓（mono frames）

// ============================================================================
// module-level state（単一プロセス・単一ウィンドウ前提の debug facility）
// ============================================================================
const Mode = enum { disabled, replay, live };
var mode: Mode = .disabled;
var initialized = false;

// コマンド source（replay=script 全体 / live=現在のリクエスト）を指す共通バッファ
var cmd_buf: []const u8 = "";
var cursor: usize = 0;
var line_no: usize = 0;
var steps_remaining: usize = 0;
var quit_requested = false;

// replay 用 script bytes（プロセス寿命まで保持。page_allocator）
var script_bytes: []const u8 = "";

// frame
var frame_index: u64 = 0;

// 出力先（snapshot path 省略時）。env 文字列はプロセス寿命まで有効。
var out_dir: []const u8 = ".";
var port_file_buf: [1024]u8 = undefined;

// 当該フレームの注入イベント（pollGate で積み、nextEvent で drain）
var inject_buf: [256]Event = undefined;
var inject_count: usize = 0;
var inject_read: usize = 0;

// マウス状態（move/down/up/scroll の一貫したイベント構築用）
var mouse_x: i32 = 0;
var mouse_y: i32 = 0;
var mouse_buttons: MouseButtons = .{};

// lockFramebuffer で記録する現在のフレームバッファ view（present/unlock まで有効）
var lock_pixels: []const u32 = &.{};
var lock_w: u32 = 0;
var lock_h: u32 = 0;
var lock_valid = false;

// 直近 present 済みフレーム（owned copy・growable reuse）
var frame_pixels: []u32 = &.{};
var frame_w: u32 = 0;
var frame_h: u32 = 0;
var have_frame = false;

// 直近の EventStats（present で push される）
var last_stats: EventStats = .{ .mouse_move_merge_count = 0, .mouse_scroll_merge_count = 0, .event_drop_count = 0 };

// headless window state（TASK-32.4 P4: VP_HARNESS_HEADLESS=1 のとき facade が backend を
// 一切呼ばず、この module-level buffer だけを Window として扱う。既存の単一 window 前提を踏襲）。
var config_parsed = false;
var pending_script_path: ?[]const u8 = null;
var pending_live_requested = false;
var headless_requested = false;
var headless_active = false;
var headless_pixels: []u32 = &.{};
var headless_w: u32 = 0;
var headless_h: u32 = 0;

// custom probe registry（app が opt-in 登録。framework は中身を解釈せず raw+digest をルートするだけ）
// 単一プロセスの debug facility なので固定長 module-level 配列で十分（動的確保なし）。
const MAX_PROBES = 16;
const DIGEST_BUF_LEN = 1024; // custom digest callback に渡す共通バッファ長
var probes: [MAX_PROBES]Probe = undefined;
var probe_count: usize = 0;

// io（0.16 は std.fs blocking API が無く std.Io 経由のみ）。file 読み書きと TCP の両方に使う。
var threaded: std.Io.Threaded = undefined;
var io_val: std.Io = undefined;

// live transport
var server: net.Server = undefined;
var live_stream: net.Stream = undefined;
var live_req_open = false;
var req_bytes: []u8 = &.{}; // 現在のリクエスト（finish 時に free）
var resp_buf: std.ArrayList(u8) = .empty;

// record（live コマンドログ）
var record_path: ?[]const u8 = null;
var record_buf: std.ArrayList(u8) = .empty;

// audio tap
var audio_buf: [AUDIO_CAP]f32 = undefined;
var audio_head: std.atomic.Value(usize) = .init(0);
var audio_channels: std.atomic.Value(u32) = .init(0);
var audio_rate: std.atomic.Value(u32) = .init(0);
var audio_scratch: [AUDIO_CAP]f32 = undefined; // peek 先（メインスレッド）
var audio_mono: [ANALYZE_FRAMES]f32 = undefined; // downmix scratch（メインスレッド）

// ============================================================================
// 公開: 初期化 / hook API（platform.zig facade から呼ばれる）
// ============================================================================

pub fn isEnabled() bool {
    return mode != .disabled;
}

/// app が register する custom probe。**framework は中身を解釈しない**:
/// snapshot が返す raw バイト列をそのまま file へ書き、digest が返す1行を既存 sink へ流すだけ。
/// 各 probe の意味づけ（PNG 化 / JSON 整形 等）は全て app 側 callback に閉じる。
pub const Probe = struct {
    /// probe 名（snapshot/digest コマンドの引数。fb/audio/stats は予約名で登録不可）。
    name: []const u8,
    /// callback に渡す不透明コンテキスト（app の状態へのポインタ）。
    ctx: *anyopaque,
    /// path 省略時の既定拡張子（"png" / "json" / "txt" 等）。
    ext: []const u8 = "bin",
    /// raw バイト列を allocator で確保して返す。harness が file へ書き同じ allocator で free。
    /// null なら snapshot 非対応。
    snapshot: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 = null,
    /// 1行テキストを buf（DIGEST_BUF_LEN バイト）に書いて返す。改行は含めない。null なら digest 非対応。
    digest: ?*const fn (ctx: *anyopaque, buf: []u8) []const u8 = null,
};

/// custom probe を登録する。app は `platform.registerProbe(...)` 経由で `platform.init()` 後に呼ぶ。
/// - harness 無効時（env 未設定）は **no-op**（registry を一切触らない＝通常実行の回帰ゼロ）。
/// - 同名は上書き。fb/audio/stats は予約名で拒否。registry 満杯はスキップ（いずれも warn）。
pub fn registerProbe(p: Probe) void {
    if (!isEnabled()) return;
    if (isReservedProbeName(p.name)) {
        std.debug.print("[harness] registerProbe: 予約名 '{s}' は登録できません\n", .{p.name});
        return;
    }
    for (probes[0..probe_count]) |*existing| {
        if (std.mem.eql(u8, existing.name, p.name)) {
            existing.* = p; // 同名上書き
            return;
        }
    }
    if (probe_count >= MAX_PROBES) {
        std.debug.print("[harness] registerProbe: registry 満杯（{d}）。'{s}' をスキップ\n", .{ MAX_PROBES, p.name });
        return;
    }
    probes[probe_count] = p;
    probe_count += 1;
}

fn isReservedProbeName(name: []const u8) bool {
    return std.mem.eql(u8, name, "fb") or std.mem.eql(u8, name, "audio") or std.mem.eql(u8, name, "stats");
}

fn findProbe(name: []const u8) ?*Probe {
    for (probes[0..probe_count]) |*p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

/// headless 判定の純粋ロジック（env I/O から分離。単体テスト用）。
/// `VP_HARNESS_HEADLESS` 単独指定（script も live も無し）は無効（false = 通常実行）。
fn decideHeadless(requested: bool, script_path: ?[]const u8, live_requested: bool) bool {
    return requested and (script_path != null or live_requested);
}

/// platform.init() の最初に1度だけ呼ぶ。env を読むだけで I/O 副作用（script 読込・listen）は起こさない
/// （TASK-32.4 P4: headless 判定を `backend.init()` の要否より前に確定させるため `startTransport()` と
/// 二段階に分割した。詳細はタスク plan §3.1）。
pub fn parseConfig() void {
    if (config_parsed) return;
    config_parsed = true;

    pending_script_path = getEnv("VP_HARNESS_SCRIPT");
    pending_live_requested = getEnv("VP_HARNESS_LIVE") != null or getEnv("VP_HARNESS_PORT") != null;
    if (getEnv("VP_HARNESS_OUT")) |d| out_dir = d;

    headless_requested = getEnv("VP_HARNESS_HEADLESS") != null;
    headless_active = decideHeadless(headless_requested, pending_script_path, pending_live_requested);
    if (headless_requested and !headless_active) {
        std.debug.print("[harness] VP_HARNESS_HEADLESS は VP_HARNESS_SCRIPT か VP_HARNESS_LIVE/PORT と併用が必要です。無視します（通常実行）。\n", .{});
    }
}

/// headless 判定（`parseConfig()` 後に確定。env 由来で transport の成否に依存しない）。
/// facade が `backend.init()` を呼ぶか・Window を backend 実体にするかの分岐に使う。
pub fn isHeadlessActive() bool {
    return headless_active;
}

/// platform.init() が（非 headless 時は `backend.init()` の後に）1度だけ呼ぶ。
/// script 読込 / live listen の実 I/O はここに閉じる（`parseConfig()` との分割は plan §3.1 参照）。
pub fn startTransport() void {
    if (initialized) return;
    initialized = true;

    const script_path = pending_script_path;
    const live_requested = pending_live_requested;
    if (script_path == null and !live_requested) return; // env 未設定 → 完全パススルー

    if (script_path != null and live_requested) {
        std.debug.print("[harness] VP_HARNESS_SCRIPT と live(VP_HARNESS_LIVE/PORT) は同時指定不可。harness を無効化します。\n", .{});
        return;
    }

    threaded = std.Io.Threaded.init(gpa, .{});
    io_val = threaded.io();

    if (script_path) |path| {
        script_bytes = std.Io.Dir.cwd().readFileAlloc(io_val, path, gpa, .unlimited) catch |err| {
            std.debug.print("[harness] script 読み込み失敗 {s}: {s}\n", .{ path, @errorName(err) });
            return; // disabled のまま
        };
        cmd_buf = script_bytes;
        mode = .replay;
        std.debug.print("[harness] replay 有効: script={s} out={s}\n", .{ path, out_dir });
        return;
    }

    // live
    const req_port: u16 = if (getEnv("VP_HARNESS_PORT")) |pe| (std.fmt.parseInt(u16, pe, 10) catch 0) else 0;
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(req_port) };
    server = addr.listen(io_val, .{ .reuse_address = true }) catch |err| {
        std.debug.print("[harness] live listen 失敗: {s}\n", .{@errorName(err)});
        return; // disabled のまま
    };
    record_path = getEnv("VP_HARNESS_RECORD");
    mode = .live;
    const chosen = server.socket.address.getPort();
    std.debug.print("[harness] live 有効: 127.0.0.1:{d} out={s}\n", .{ chosen, out_dir });
    writePortFile(chosen);
}

/// フレーム進行の同期点。1 フレーム分の進行を許可するとき true。
/// quit / EOF(replay) / window closed(native_continue=false) / accept 失敗(live) で false。
/// live ではコマンド到着まで accept でブロックする（= step 待ちで block）。
pub fn pollGate(native_continue: bool) bool {
    if (quit_requested or !native_continue) return false;
    if (steps_remaining > 0) {
        steps_remaining -= 1;
        return true;
    }
    while (true) {
        if (cursor >= cmd_buf.len) {
            switch (mode) {
                .replay, .disabled => return false, // EOF
                .live => {
                    finishLiveRequest();
                    if (quit_requested) return false;
                    if (!acceptLiveRequest()) return false; // accept 失敗 = 終了
                    continue;
                },
            }
        }
        const raw = nextLine() orelse continue;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const cmd = it.next() orelse continue;
        if (std.mem.eql(u8, cmd, "step")) {
            const n = parseUsize(it.next()) orelse 1;
            if (n == 0) continue;
            steps_remaining = n - 1;
            return true;
        } else if (std.mem.eql(u8, cmd, "quit")) {
            quit_requested = true;
            if (mode == .live) finishLiveRequest();
            return false;
        } else if (std.mem.eql(u8, cmd, "inject")) {
            handleInject(&it);
        } else if (std.mem.eql(u8, cmd, "snapshot")) {
            handleSnapshot(&it);
        } else if (std.mem.eql(u8, cmd, "digest")) {
            handleDigest(&it);
        } else {
            warnLine("不明なコマンド");
        }
    }
}

/// 当該フレームの注入イベントを1つ返す。尽きたら（次フレーム用に reset して）null。
pub fn nextInjectedEvent() ?Event {
    if (inject_read < inject_count) {
        const ev = inject_buf[inject_read];
        inject_read += 1;
        return ev;
    }
    inject_read = 0;
    inject_count = 0;
    return null;
}

/// native(OS) イベントの取捨。replay 決定性のため quit のみ通し、他の OS 入力は捨てる。
pub fn filterNativeEvent(ev: Event) ?Event {
    return switch (ev) {
        .quit => ev,
        else => null,
    };
}

/// lockFramebuffer 成功時に現在の pixels/寸法を記録する（present で owned copy するため）。
pub fn onLock(pixels: []const u32, w: u32, h: u32) void {
    lock_pixels = pixels;
    lock_w = w;
    lock_h = h;
    lock_valid = true;
}

/// lockFramebuffer が null を返したとき。stale pixel を present で再コピーしないよう無効化する。
pub fn onLockMiss() void {
    lock_valid = false;
}

/// present 直前に呼ぶ。最新の EventStats を `stats` probe 用に保持する。
pub fn onStats(s: EventStats) void {
    last_stats = s;
}

/// present 時にフレームを owned copy して確定し、frame_index を進める。
pub fn onPresent() void {
    const n = @as(usize, lock_w) * @as(usize, lock_h);
    if (lock_valid and n > 0 and lock_pixels.len >= n) {
        if (frame_pixels.len < n) {
            if (frame_pixels.len > 0) gpa.free(frame_pixels);
            frame_pixels = gpa.alloc(u32, n) catch {
                warnLine("frame buffer alloc 失敗");
                lock_valid = false;
                frame_index += 1;
                return;
            };
        }
        @memcpy(frame_pixels[0..n], lock_pixels[0..n]);
        frame_w = lock_w;
        frame_h = lock_h;
        have_frame = true;
    }
    lock_valid = false; // 次フレームは改めて onLock が必要
    frame_index += 1;
}

/// 仮想クロック（frame 駆動）。getTime を使うアプリの replay を決定論にする。
pub fn now() f64 {
    return @as(f64, @floatFromInt(frame_index)) / VIRTUAL_FPS;
}

/// audio facade(`src/audio.zig`) の render trampoline から **RT スレッドで** 呼ばれる。
/// **alloc/lock/IO/panic 禁止**。samples は interleaved（frames*channels）。
/// latest-wins: 満杯でも head を進めて上書きする（取りこぼし可。probe は直近窓を見る）。
pub fn onAudioSamples(samples: []const f32, frames: u32, channels: u32, sample_rate: u32) void {
    if (mode == .disabled) return;
    _ = frames;
    audio_channels.store(channels, .monotonic);
    audio_rate.store(sample_rate, .monotonic);
    var head = audio_head.load(.monotonic);
    for (samples) |s| {
        // slot は consumer の peek と並行し得る。latest-wins で torn を許容するが、Zig 上の data race UB を
        // 避けるため `.unordered`（aligned f32 では実質プレーン load/store・no-fence）で読み書きする。
        @atomicStore(f32, &audio_buf[head & AUDIO_MASK], s, .unordered);
        head +%= 1;
    }
    audio_head.store(head, .release);
}

// ============================================================================
// headless window（TASK-32.4 P4: display 無しの facade window。backend を一切呼ばない）
//
/// ホットパス宣言: `createHeadlessWindow` は Window.create 時（初期化時のみ）に w*h の
/// framebuffer を確保する。フレーム毎に走るのは呼び出し元（facade lockFramebuffer/present）の
/// 既存 onLock/onPresent（@memcpy のみ・per-pixel 演算の新設なし）。
// ============================================================================

/// headless framebuffer の view（facade の Framebuffer が公開 pixels/width/height に詰め替える）。
pub const HeadlessFramebufferView = struct { pixels: []u32, width: u32, height: u32 };

/// facade の `Window.create` が headless 時に呼ぶ。単一 window 前提（既存の module-level 設計を踏襲）。
/// w*h の CPU framebuffer を確保する（初回は alloc、以降はサイズ一致なら再利用・不一致なら再確保）。
/// alloc 失敗時は `error.OutOfMemory`（native 経路の `Window.create` が `Error!Window` を返すのと
/// 対称に、facade 側で `error.WindowCreationFailed` へ畳めるよう panic ではなく伝播する）。
pub fn createHeadlessWindow(width: u32, height: u32) std.mem.Allocator.Error!void {
    const n = @as(usize, width) * @as(usize, height);
    if (headless_pixels.len != n) {
        if (headless_pixels.len > 0) gpa.free(headless_pixels);
        headless_pixels = &.{};
        headless_pixels = try gpa.alloc(u32, n);
    }
    @memset(headless_pixels, 0);
    headless_w = width;
    headless_h = height;
}

/// headless framebuffer を lock する（native と異なり retry-able な null は無く常に成功）。
pub fn headlessLock() HeadlessFramebufferView {
    return .{ .pixels = headless_pixels, .width = headless_w, .height = headless_h };
}

/// facade の `Window.destroy()` が headless 時に呼ぶ（buffer 解放。テストの独立性にも使う）。
pub fn destroyHeadlessWindow() void {
    if (headless_pixels.len > 0) gpa.free(headless_pixels);
    headless_pixels = &.{};
    headless_w = 0;
    headless_h = 0;
}

// ============================================================================
// live transport
// ============================================================================

/// 1接続を accept し、リクエスト全体（client の half-close まで）を読み込んで cmd_buf に載せる。
/// 戻り false = accept 不能（server 終了）→ アプリ終了。
fn acceptLiveRequest() bool {
    while (true) {
        const stream = server.accept(io_val) catch |err| {
            std.debug.print("[harness] accept 失敗: {s}\n", .{@errorName(err)});
            return false;
        };
        live_stream = stream;
        live_req_open = true;
        resp_buf.clearRetainingCapacity();

        var rbuf: [4096]u8 = undefined;
        var reader = stream.reader(io_val, &rbuf);
        const bytes = reader.interface.allocRemaining(gpa, std.Io.Limit.limited(1 << 20)) catch |err| {
            std.debug.print("[harness] request read 失敗: {s}\n", .{@errorName(err)});
            appendResp("error: request read failed\n");
            finishLiveRequest();
            continue; // 次の接続を待つ
        };
        req_bytes = bytes;
        cmd_buf = bytes;
        cursor = 0;
        line_no = 0;
        recordRequest(bytes);
        return true;
    }
}

/// 現在のリクエストを終了する: response を flush し stream を閉じ、バッファを片付ける。
fn finishLiveRequest() void {
    if (!live_req_open) return;
    var wbuf: [4096]u8 = undefined;
    var writer = live_stream.writer(io_val, &wbuf);
    writer.interface.writeAll(resp_buf.items) catch {};
    writer.interface.flush() catch {};
    live_stream.close(io_val);
    live_req_open = false;
    if (req_bytes.len > 0) {
        gpa.free(req_bytes);
        req_bytes = &.{};
    }
    cmd_buf = "";
    cursor = 0;
}

fn appendResp(s: []const u8) void {
    resp_buf.appendSlice(gpa, s) catch {};
}

/// live で受信した raw リクエストを record file に追記する（コメント境界 + raw + 末尾 newline）。
/// crash 耐性のため毎回 record_buf 全体を書き直す（debug 用途・コマンド量は小）。
fn recordRequest(bytes: []const u8) void {
    const path = record_path orelse return;
    record_buf.appendSlice(gpa, "# --- live request ---\n") catch return;
    record_buf.appendSlice(gpa, bytes) catch return;
    if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') record_buf.appendSlice(gpa, "\n") catch return;
    std.Io.Dir.cwd().writeFile(io_val, .{ .sub_path = path, .data = record_buf.items }) catch |err| {
        std.debug.print("[harness] record 書き込み失敗 {s}: {s}\n", .{ path, @errorName(err) });
    };
}

fn writePortFile(port: u16) void {
    const path = getEnv("VP_HARNESS_PORT_FILE") orelse (std.fmt.bufPrint(&port_file_buf, "{s}/harness.port", .{out_dir}) catch return);
    var pbuf: [16]u8 = undefined;
    const txt = std.fmt.bufPrint(&pbuf, "{d}\n", .{port}) catch return;
    std.Io.Dir.cwd().writeFile(io_val, .{ .sub_path = path, .data = txt }) catch |err| {
        std.debug.print("[harness] port file 書き込み失敗 {s}: {s}\n", .{ path, @errorName(err) });
    };
}

// ============================================================================
// response sink（framing は mode で分岐）
// ============================================================================

/// digest 結果を出力する。`<probe> <payload>`（live）/ `[harness] digest <probe> <payload>`（replay）。
fn emitDigest(probe: []const u8, payload: []const u8) void {
    if (mode == .live) {
        appendResp(probe);
        appendResp(" ");
        appendResp(payload);
        appendResp("\n");
    } else {
        std.debug.print("[harness] digest {s} {s}\n", .{ probe, payload });
    }
}

/// snapshot 結果を出力する。`<path>`（live）/ `[harness] snapshot <probe> -> <path> (<info>)`（replay）。
fn emitSnapshot(probe: []const u8, path: []const u8, info: []const u8) void {
    if (mode == .live) {
        appendResp(path);
        appendResp("\n");
    } else {
        std.debug.print("[harness] snapshot {s} -> {s} ({s})\n", .{ probe, path, info });
    }
}

// ============================================================================
// コマンド処理
// ============================================================================

fn handleInject(it: *Tok) void {
    const kind = it.next() orelse {
        warnLine("inject: 種別不足");
        return;
    };
    if (std.mem.eql(u8, kind, "key_down") or std.mem.eql(u8, kind, "key_up")) {
        const name = it.next() orelse {
            warnLine("inject key: KEY 不足");
            return;
        };
        const kc = parseKey(name) orelse {
            warnLine("inject key: 不明なキー");
            return;
        };
        const mods = parseModifiers(it) orelse return warnLine("inject: 不明な修飾子");
        const ke = KeyEvent{ .key = kc, .is_repeat = false, .modifiers = mods };
        queue(if (std.mem.eql(u8, kind, "key_down")) Event{ .key_down = ke } else Event{ .key_up = ke });
    } else if (std.mem.eql(u8, kind, "mouse_move")) {
        const x = parseI32(it.next()) orelse return warnLine("inject mouse_move: 座標不正");
        const y = parseI32(it.next()) orelse return warnLine("inject mouse_move: 座標不正");
        // modifiers を座標 state 更新より前に parse（未知 modifier で fail-fast する際に mouse_x/y を汚さない）
        const mods = parseModifiers(it) orelse return warnLine("inject: 不明な修飾子");
        mouse_x = x;
        mouse_y = y;
        queue(Event{ .mouse_move = .{ .x = x, .y = y, .button = .none, .buttons = mouse_buttons, .modifiers = mods } });
    } else if (std.mem.eql(u8, kind, "mouse_down") or std.mem.eql(u8, kind, "mouse_up")) {
        const btn = parseButton(it.next()) orelse return warnLine("inject mouse: 不明なボタン");
        const down = std.mem.eql(u8, kind, "mouse_down");
        // modifiers を setButton より前に parse（未知 modifier で fail-fast する際に mouse_buttons を汚さない）
        const mods = parseModifiers(it) orelse return warnLine("inject: 不明な修飾子");
        setButton(&mouse_buttons, btn, down);
        const ev = MouseEvent{ .x = mouse_x, .y = mouse_y, .button = btn, .buttons = mouse_buttons, .modifiers = mods };
        queue(if (down) Event{ .mouse_down = ev } else Event{ .mouse_up = ev });
    } else if (std.mem.eql(u8, kind, "scroll")) {
        const dx = parseF32(it.next()) orelse return warnLine("inject scroll: 量不正");
        const dy = parseF32(it.next()) orelse return warnLine("inject scroll: 量不正");
        const mods = parseModifiers(it) orelse return warnLine("inject: 不明な修飾子");
        queue(Event{ .mouse_scroll = .{ .x = mouse_x, .y = mouse_y, .dx = dx, .dy = dy, .is_precise = false, .buttons = mouse_buttons, .modifiers = mods } });
    } else {
        warnLine("inject: 不明な種別");
    }
}

fn handleSnapshot(it: *Tok) void {
    const probe = it.next() orelse return warnLine("snapshot: probe 名不足");
    const path_arg = it.next();
    var path_buf: [1024]u8 = undefined;

    if (std.mem.eql(u8, probe, "fb")) {
        if (!have_frame) return warnLine("snapshot fb: present 前（フレーム未確定）→ skip");
        const path = path_arg orelse (std.fmt.bufPrint(&path_buf, "{s}/frame_{d}.png", .{ out_dir, frame_index }) catch return warnLine("snapshot: path 生成失敗"));
        const n = @as(usize, frame_w) * @as(usize, frame_h);
        png.savePNG(io_val, path, frame_pixels[0..n], frame_w, frame_h, gpa) catch |err| {
            std.debug.print("[harness] snapshot fb 失敗 {s}: {s}\n", .{ path, @errorName(err) });
            return;
        };
        var info_buf: [32]u8 = undefined;
        const info = std.fmt.bufPrint(&info_buf, "{d}x{d}", .{ frame_w, frame_h }) catch "?";
        emitSnapshot("fb", path, info);
    } else if (std.mem.eql(u8, probe, "audio")) {
        const channels = audio_channels.load(.monotonic);
        const rate = audio_rate.load(.monotonic);
        const n = peekRecentAudio(&audio_scratch);
        if (n == 0 or channels == 0) return warnLine("snapshot audio: サンプル無し → skip");
        const path = path_arg orelse (std.fmt.bufPrint(&path_buf, "{s}/audio_{d}.wav", .{ out_dir, frame_index }) catch return warnLine("snapshot: path 生成失敗"));
        writeWav(io_val, path, audio_scratch[0..n], channels, rate, gpa) catch |err| {
            std.debug.print("[harness] snapshot audio 失敗 {s}: {s}\n", .{ path, @errorName(err) });
            return;
        };
        var info_buf: [32]u8 = undefined;
        const info = std.fmt.bufPrint(&info_buf, "{d} samples", .{n}) catch "?";
        emitSnapshot("audio", path, info);
    } else if (std.mem.eql(u8, probe, "stats")) {
        const path = path_arg orelse (std.fmt.bufPrint(&path_buf, "{s}/stats_{d}.json", .{ out_dir, frame_index }) catch return warnLine("snapshot: path 生成失敗"));
        var json_buf: [512]u8 = undefined;
        const json = formatStatsPayload(&json_buf);
        std.Io.Dir.cwd().writeFile(io_val, .{ .sub_path = path, .data = json }) catch |err| {
            std.debug.print("[harness] snapshot stats 失敗 {s}: {s}\n", .{ path, @errorName(err) });
            return;
        };
        emitSnapshot("stats", path, "json");
    } else if (findProbe(probe)) |p| {
        snapshotCustom(p, path_arg, &path_buf);
    } else {
        warnLine("snapshot: 未知の probe");
    }
}

/// custom probe の snapshot をルートする（中身非解釈）: callback の raw bytes を file へ書き、同 allocator で free。
fn snapshotCustom(p: *const Probe, path_arg: ?[]const u8, path_buf: []u8) void {
    const snap = p.snapshot orelse return warnLine("snapshot: この probe は snapshot 非対応");
    const bytes = snap(p.ctx, gpa) catch |err| {
        std.debug.print("[harness] snapshot {s} 失敗: {s}\n", .{ p.name, @errorName(err) });
        return;
    };
    defer gpa.free(bytes);
    const path = path_arg orelse (std.fmt.bufPrint(path_buf, "{s}/{s}_{d}.{s}", .{ out_dir, p.name, frame_index, p.ext }) catch return warnLine("snapshot: path 生成失敗"));
    std.Io.Dir.cwd().writeFile(io_val, .{ .sub_path = path, .data = bytes }) catch |err| {
        std.debug.print("[harness] snapshot {s} 失敗 {s}: {s}\n", .{ p.name, path, @errorName(err) });
        return;
    };
    var info_buf: [32]u8 = undefined;
    const info = std.fmt.bufPrint(&info_buf, "{d} bytes", .{bytes.len}) catch "?";
    emitSnapshot(p.name, path, info);
}

fn handleDigest(it: *Tok) void {
    const probe = it.next() orelse return warnLine("digest: probe 名不足");
    if (std.mem.eql(u8, probe, "fb")) {
        if (!have_frame) return warnLine("digest fb: present 前（フレーム未確定）→ skip");
        var buf: [512]u8 = undefined;
        emitDigest("fb", formatFbPayload(&buf));
    } else if (std.mem.eql(u8, probe, "audio")) {
        var buf: [128]u8 = undefined;
        emitDigest("audio", formatAudioPayload(&buf));
    } else if (std.mem.eql(u8, probe, "stats")) {
        var buf: [512]u8 = undefined;
        emitDigest("stats", formatStatsPayload(&buf));
    } else if (findProbe(probe)) |p| {
        digestCustom(p);
    } else {
        warnLine("digest: 未知の probe");
    }
}

/// custom probe の digest をルートする（中身非解釈）: callback が 1024B バッファへ書いた1行を emit するだけ。
fn digestCustom(p: *const Probe) void {
    const dg = p.digest orelse return warnLine("digest: この probe は digest 非対応");
    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    emitDigest(p.name, dg(p.ctx, &buf));
}

// ============================================================================
// fb probe payload
// ============================================================================

/// `<w>x<h> crc=<hex> top=[#RRGGBB:NN%,...]`（上位3色）を buf に書いて返す。
fn formatFbPayload(buf: []u8) []u8 {
    const n = @as(usize, frame_w) * @as(usize, frame_h);
    const px = frame_pixels[0..n];
    const crc = png.crc32(std.mem.sliceAsBytes(px));

    const Top = struct { color: u32 = 0, count: u32 = 0 };
    var top = [_]Top{.{}} ** 3;
    var counts = std.AutoHashMap(u32, u32).init(gpa);
    defer counts.deinit();
    var ok = true;
    for (px) |p| {
        const gop = counts.getOrPut(p) catch {
            ok = false;
            break;
        };
        if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
    }
    if (ok) {
        // tie-break を明示（count 降順、同数は color 昇順）。hashmap iterator 順に依存させない。
        const cmp = struct {
            fn better(a: Top, b: Top) bool {
                return a.count > b.count or (a.count == b.count and a.color < b.color);
            }
        }.better;
        var cit = counts.iterator();
        while (cit.next()) |e| {
            const cand = Top{ .color = e.key_ptr.*, .count = e.value_ptr.* };
            if (cmp(cand, top[0])) {
                top[2] = top[1];
                top[1] = top[0];
                top[0] = cand;
            } else if (cmp(cand, top[1])) {
                top[2] = top[1];
                top[1] = cand;
            } else if (cmp(cand, top[2])) {
                top[2] = cand;
            }
        }
    }

    var len: usize = 0;
    len += (std.fmt.bufPrint(buf[len..], "{d}x{d} crc={X:0>8} top=[", .{ frame_w, frame_h, crc }) catch return buf[0..len]).len;
    var first = true;
    for (top) |t| {
        if (t.count == 0) continue;
        const pct = @as(u64, t.count) * 100 / n;
        const sep = if (first) "" else ",";
        first = false;
        len += (std.fmt.bufPrint(buf[len..], "{s}#{X:0>6}:{d}%", .{ sep, t.color & 0xFFFFFF, pct }) catch break).len;
    }
    len += (std.fmt.bufPrint(buf[len..], "]", .{}) catch return buf[0..len]).len;
    return buf[0..len];
}

// ============================================================================
// audio probe（tap drain + 解析 + WAV）
// ============================================================================

/// 直近 `dst.len`（最大 AUDIO_CAP）サンプルを non-destructive に取り出す。tail を動かさない
/// （digest と snapshot が同じ直近窓を見られるよう peek にする）。戻り = 取り出した数。
fn peekRecentAudio(dst: []f32) usize {
    const head = audio_head.load(.acquire);
    const want = @min(dst.len, @min(AUDIO_CAP, head));
    const start = head -% want;
    var i: usize = 0;
    // producer の `.unordered` store と対称に `.unordered` load（torn を許容しつつ data race UB を回避）。
    while (i < want) : (i += 1) dst[i] = @atomicLoad(f32, &audio_buf[(start +% i) & AUDIO_MASK], .unordered);
    return want;
}

const AudioStats = struct { rms: f32, peak: f32, f0: f32, silent: bool, frames: usize };

/// interleaved サンプルの直近 min(frames, mono_scratch.len) frames を mono downmix して RMS/peak/f0/silent を計算する。
/// 純ロジック（単体テスト可能）。mono_scratch は呼び出し側が渡す（hidden global を持たない）。
fn analyzeAudio(interleaved: []const f32, channels: u32, sample_rate: u32, mono_scratch: []f32) AudioStats {
    if (channels == 0 or interleaved.len < channels) return .{ .rms = 0, .peak = 0, .f0 = 0, .silent = true, .frames = 0 };
    const ch: usize = channels;
    const total_frames = interleaved.len / ch;
    const w = @min(total_frames, mono_scratch.len);
    const off = total_frames - w; // 直近 w frames
    var i: usize = 0;
    while (i < w) : (i += 1) {
        var acc: f32 = 0;
        var c: usize = 0;
        while (c < ch) : (c += 1) acc += interleaved[(off + i) * ch + c];
        mono_scratch[i] = acc / @as(f32, @floatFromInt(ch));
    }
    const mono = mono_scratch[0..w];

    var sumsq: f64 = 0;
    var peak: f32 = 0;
    for (mono) |s| {
        sumsq += @as(f64, s) * @as(f64, s);
        const a = @abs(s);
        if (a > peak) peak = a;
    }
    const rms: f32 = if (w > 0) @floatCast(@sqrt(sumsq / @as(f64, @floatFromInt(w)))) else 0;
    const silent = rms < 1e-4;
    const f0: f32 = if (silent) 0 else estimateF0(mono, sample_rate);
    return .{ .rms = rms, .peak = peak, .f0 = f0, .silent = silent, .frames = w };
}

/// 自己相関で基本周波数を推定する（50–2000Hz）。clean tone に強い。検出不能/無音は 0。
fn estimateF0(mono: []const f32, sample_rate: u32) f32 {
    const n = mono.len;
    if (n < 64 or sample_rate == 0) return 0;
    const sr: f32 = @floatFromInt(sample_rate);

    var mean: f32 = 0;
    for (mono) |s| mean += s;
    mean /= @floatFromInt(n);

    var energy: f64 = 0;
    for (mono) |s| {
        const c = s - mean;
        energy += @as(f64, c) * @as(f64, c);
    }
    if (energy <= 1e-9) return 0;

    const min_lag: usize = @max(2, @as(usize, @intFromFloat(sr / 2000.0)));
    const max_lag: usize = @min(n / 2, @as(usize, @intFromFloat(sr / 50.0)));
    if (max_lag <= min_lag) return 0;

    var best_lag: usize = 0;
    var best_corr: f64 = 0;
    var lag = min_lag;
    while (lag <= max_lag) : (lag += 1) {
        var corr: f64 = 0;
        var i = lag;
        while (i < n) : (i += 1) {
            corr += @as(f64, mono[i] - mean) * @as(f64, mono[i - lag] - mean);
        }
        if (corr > best_corr) {
            best_corr = corr;
            best_lag = lag;
        }
    }
    if (best_lag == 0 or best_corr / energy < 0.3) return 0;
    return sr / @as(f32, @floatFromInt(best_lag));
}

fn formatAudioPayload(buf: []u8) []u8 {
    const channels = audio_channels.load(.monotonic);
    const rate = audio_rate.load(.monotonic);
    const n = peekRecentAudio(&audio_scratch);
    if (n == 0 or channels == 0) {
        return std.fmt.bufPrint(buf, "rms=0.0000 peak=0.0000 f0=0.0 silent=1 frames=0", .{}) catch buf[0..0];
    }
    const st = analyzeAudio(audio_scratch[0..n], channels, rate, &audio_mono);
    return std.fmt.bufPrint(buf, "rms={d:.4} peak={d:.4} f0={d:.1} silent={d} frames={d}", .{
        st.rms, st.peak, st.f0, @intFromBool(st.silent), st.frames,
    }) catch buf[0..0];
}

/// PCM16 little-endian RIFF/WAVE を encode する（純ロジック・単体テスト可能）。
fn encodeWav(interleaved: []const f32, channels: u32, sample_rate: u32, allocator: std.mem.Allocator) ![]u8 {
    const num_samples = interleaved.len;
    const data_size: u32 = @intCast(num_samples * 2);
    const total = 44 + @as(usize, data_size);
    const buf = try allocator.alloc(u8, total);
    errdefer allocator.free(buf);

    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], 36 + data_size, .little);
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    std.mem.writeInt(u32, buf[16..20], 16, .little); // subchunk1 size (PCM)
    std.mem.writeInt(u16, buf[20..22], 1, .little); // audio format = PCM
    std.mem.writeInt(u16, buf[22..24], @intCast(channels), .little);
    std.mem.writeInt(u32, buf[24..28], sample_rate, .little);
    std.mem.writeInt(u32, buf[28..32], sample_rate * channels * 2, .little); // byte_rate
    std.mem.writeInt(u16, buf[32..34], @intCast(channels * 2), .little); // block_align
    std.mem.writeInt(u16, buf[34..36], 16, .little); // bits_per_sample
    @memcpy(buf[36..40], "data");
    std.mem.writeInt(u32, buf[40..44], data_size, .little);

    var off: usize = 44;
    for (interleaved) |s| {
        const clamped = std.math.clamp(s, -1.0, 1.0);
        const v: i16 = @intFromFloat(clamped * 32767.0);
        std.mem.writeInt(i16, buf[off..][0..2], v, .little);
        off += 2;
    }
    return buf;
}

fn writeWav(io: std.Io, path: []const u8, interleaved: []const f32, channels: u32, sample_rate: u32, allocator: std.mem.Allocator) !void {
    const bytes = try encodeWav(interleaved, channels, sample_rate, allocator);
    defer allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

// ============================================================================
// stats probe
// ============================================================================

fn formatStatsPayload(buf: []u8) []u8 {
    return std.fmt.bufPrint(buf, "{{\"frame\":{d},\"virtual_fps\":{d:.1},\"mouse_move_merge_count\":{d},\"mouse_scroll_merge_count\":{d},\"event_drop_count\":{d}}}", .{
        frame_index,
        VIRTUAL_FPS,
        last_stats.mouse_move_merge_count,
        last_stats.mouse_scroll_merge_count,
        last_stats.event_drop_count,
    }) catch buf[0..0];
}

// ============================================================================
// helpers
// ============================================================================

fn queue(ev: Event) void {
    if (inject_count >= inject_buf.len) {
        warnLine("inject queue 溢れ: drop");
        return;
    }
    inject_buf[inject_count] = ev;
    inject_count += 1;
}

/// 次の1コマンドを返す。区切りは `\n` または `;`（1引数で `'inject A; step 3; digest fb'` と書けるように）。
fn nextLine() ?[]const u8 {
    if (cursor >= cmd_buf.len) return null;
    const start = cursor;
    var end = cursor;
    while (end < cmd_buf.len and cmd_buf[end] != '\n' and cmd_buf[end] != ';') end += 1;
    cursor = if (end < cmd_buf.len) end + 1 else end;
    line_no += 1;
    return cmd_buf[start..end];
}

fn setButton(b: *MouseButtons, btn: MouseButton, down: bool) void {
    switch (btn) {
        .left => b.left = down,
        .right => b.right = down,
        .middle => b.middle = down,
        else => {},
    }
}

fn parseKey(name: []const u8) ?KeyCode {
    var buf: [32]u8 = undefined;
    if (name.len == 0 or name.len > buf.len) return null;
    for (name, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
    return std.meta.stringToEnum(KeyCode, buf[0..name.len]);
}

fn parseButton(tok: ?[]const u8) ?MouseButton {
    const name = tok orelse return null;
    var buf: [16]u8 = undefined;
    if (name.len == 0 or name.len > buf.len) return null;
    for (name, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return std.meta.stringToEnum(MouseButton, buf[0..name.len]);
}

/// 残りトークンを shift/ctrl/alt/cmd（大小無視）に照合してフラグを立てる。
/// 未知トークンが 1 つでもあれば null を返す（caller が warn してそのイベントを捨てる = fail-fast。
/// parseKey/parseButton と同じ「不正トークン→null、warn は caller」の慣習）。
/// 残り 0 トークンなら空 ModifierFlags（非 null）。
fn parseModifiers(it: *Tok) ?ModifierFlags {
    var m = ModifierFlags{};
    while (it.next()) |tok| {
        var buf: [16]u8 = undefined;
        if (tok.len == 0 or tok.len > buf.len) return null;
        for (tok, 0..) |c, i| buf[i] = std.ascii.toLower(c);
        const name = buf[0..tok.len];
        if (std.mem.eql(u8, name, "shift")) {
            m.shift = true;
        } else if (std.mem.eql(u8, name, "ctrl")) {
            m.ctrl = true;
        } else if (std.mem.eql(u8, name, "alt")) {
            m.alt = true;
        } else if (std.mem.eql(u8, name, "cmd")) {
            m.cmd = true;
        } else {
            return null;
        }
    }
    return m;
}

fn parseUsize(tok: ?[]const u8) ?usize {
    return std.fmt.parseInt(usize, tok orelse return null, 10) catch null;
}

fn parseI32(tok: ?[]const u8) ?i32 {
    return std.fmt.parseInt(i32, tok orelse return null, 10) catch null;
}

fn parseF32(tok: ?[]const u8) ?f32 {
    return std.fmt.parseFloat(f32, tok orelse return null) catch null;
}

fn warnLine(msg: []const u8) void {
    std.debug.print("[harness] line {d}: {s}\n", .{ line_no, msg });
    if (mode == .live) {
        appendResp("error: ");
        appendResp(msg);
        appendResp("\n");
    }
}

/// 環境変数を読む。0.16 std には libc 非依存の getenv が無いため libc getenv を使う
/// （platform module は常に link_libc）。
fn getEnv(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    return std.mem.span(v);
}

// ============================================================================
// tests（display 不要・絶対値 assert で誤実装を落とす）
// ============================================================================
const testing = std.testing;

fn resetForTest() void {
    mode = .replay; // EOF 時の挙動を replay として確定（テストは file source 相当）
    cmd_buf = "";
    cursor = 0;
    line_no = 0;
    steps_remaining = 0;
    quit_requested = false;
    frame_index = 0;
    inject_count = 0;
    inject_read = 0;
    mouse_x = 0;
    mouse_y = 0;
    mouse_buttons = .{};
    lock_pixels = &.{};
    lock_w = 0;
    lock_h = 0;
    lock_valid = false;
    frame_w = 0;
    frame_h = 0;
    have_frame = false;
    audio_head = .init(0);
    audio_channels = .init(0);
    audio_rate = .init(0);
    probe_count = 0;
}

test "parseKey: 名前→KeyCode（大小無視・数字）" {
    try testing.expectEqual(KeyCode.A, parseKey("a").?);
    try testing.expectEqual(KeyCode.A, parseKey("A").?);
    try testing.expectEqual(KeyCode.ESCAPE, parseKey("escape").?);
    try testing.expectEqual(KeyCode.SPACE, parseKey("Space").?);
    try testing.expectEqual(KeyCode.@"0", parseKey("0").?);
    try testing.expectEqual(@as(?KeyCode, null), parseKey("nope"));
}

test "parseButton: 名前→MouseButton" {
    try testing.expectEqual(MouseButton.left, parseButton("left").?);
    try testing.expectEqual(MouseButton.right, parseButton("RIGHT").?);
    try testing.expectEqual(MouseButton.middle, parseButton("Middle").?);
    try testing.expectEqual(@as(?MouseButton, null), parseButton("x"));
}

test "parseModifiers: 0個=空 / 単一 / 複数（大小無視）/ 未知=null" {
    {
        var it = std.mem.tokenizeAny(u8, "", " \t");
        const m = parseModifiers(&it).?;
        try testing.expect(!m.shift and !m.ctrl and !m.alt and !m.cmd);
    }
    {
        var it = std.mem.tokenizeAny(u8, "cmd", " \t");
        const m = parseModifiers(&it).?;
        try testing.expect(m.cmd and !m.shift and !m.ctrl and !m.alt);
    }
    {
        var it = std.mem.tokenizeAny(u8, "Cmd SHIFT", " \t"); // 大小混在
        const m = parseModifiers(&it).?;
        try testing.expect(m.cmd and m.shift and !m.ctrl and !m.alt);
    }
    {
        var it = std.mem.tokenizeAny(u8, "shift ctrl alt cmd", " \t");
        const m = parseModifiers(&it).?;
        try testing.expect(m.shift and m.ctrl and m.alt and m.cmd);
    }
    {
        var it = std.mem.tokenizeAny(u8, "bogus", " \t");
        try testing.expectEqual(@as(?ModifierFlags, null), parseModifiers(&it));
    }
    {
        var it = std.mem.tokenizeAny(u8, "cmd bogus", " \t"); // 認識済みが先でも未知が混ざれば null
        try testing.expectEqual(@as(?ModifierFlags, null), parseModifiers(&it));
    }
}

test "inject modifiers: 全6経路で反映 / 無指定は空" {
    resetForTest();
    cmd_buf =
        \\inject key_down S cmd
        \\step 1
        \\inject key_up A shift
        \\step 1
        \\inject key_down S cmd shift
        \\step 1
        \\inject mouse_move 10 20 ctrl
        \\step 1
        \\inject mouse_down left alt
        \\step 1
        \\inject mouse_up right cmd
        \\step 1
        \\inject scroll 0 -3 ctrl
        \\step 1
        \\inject key_down A
        \\step 1
        \\quit
    ;

    // key_down S cmd
    try testing.expect(pollGate(true));
    var e = nextInjectedEvent().?;
    try testing.expect(e == .key_down and e.key_down.key == .S);
    try testing.expect(e.key_down.modifiers.cmd and !e.key_down.modifiers.shift and !e.key_down.modifiers.ctrl and !e.key_down.modifiers.alt);
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());

    // key_up A shift（key_up 分岐）
    try testing.expect(pollGate(true));
    e = nextInjectedEvent().?;
    try testing.expect(e == .key_up and e.key_up.key == .A and e.key_up.modifiers.shift and !e.key_up.modifiers.cmd);
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());

    // key_down S cmd shift（複数）
    try testing.expect(pollGate(true));
    e = nextInjectedEvent().?;
    try testing.expect(e == .key_down and e.key_down.modifiers.cmd and e.key_down.modifiers.shift and !e.key_down.modifiers.ctrl);
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());

    // mouse_move 10 20 ctrl（mouse_move 分岐・座標維持）
    try testing.expect(pollGate(true));
    e = nextInjectedEvent().?;
    try testing.expect(e == .mouse_move and e.mouse_move.x == 10 and e.mouse_move.y == 20 and e.mouse_move.modifiers.ctrl);
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());

    // mouse_down left alt（button/buttons 維持）
    try testing.expect(pollGate(true));
    e = nextInjectedEvent().?;
    try testing.expect(e == .mouse_down and e.mouse_down.button == .left and e.mouse_down.buttons.left and e.mouse_down.modifiers.alt);
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());

    // mouse_up right cmd（mouse_up 分岐）
    try testing.expect(pollGate(true));
    e = nextInjectedEvent().?;
    try testing.expect(e == .mouse_up and e.mouse_up.button == .right and e.mouse_up.modifiers.cmd);
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());

    // scroll 0 -3 ctrl（dx/dy 維持）
    try testing.expect(pollGate(true));
    e = nextInjectedEvent().?;
    try testing.expect(e == .mouse_scroll and e.mouse_scroll.dx == 0 and e.mouse_scroll.dy == -3 and e.mouse_scroll.modifiers.ctrl);
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());

    // key_down A（修飾子無し → 全 false）
    try testing.expect(pollGate(true));
    e = nextInjectedEvent().?;
    try testing.expect(e == .key_down and e.key_down.key == .A);
    const m = e.key_down.modifiers;
    try testing.expect(!m.shift and !m.ctrl and !m.alt and !m.cmd);
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());

    try testing.expect(!pollGate(true));
}

test "inject modifiers: 未知 modifier は fail-fast（注入されず state も汚さない）" {
    resetForTest();
    cmd_buf =
        \\inject mouse_down left bogus
        \\inject mouse_move 10 20 bogus
        \\inject key_down S bogus
        \\step 1
        \\inject mouse_down left
        \\step 1
        \\quit
    ;

    // frame 1: 3 件とも fail-fast で queue されない
    try testing.expect(pollGate(true));
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());
    // mouse_down left bogus は setButton されない（button state 汚染なし）
    try testing.expect(!mouse_buttons.left);

    // frame 2: 正常な mouse_down left。座標は mouse_move 10 20 bogus で汚れず初期値(0,0)のまま
    try testing.expect(pollGate(true));
    const e = nextInjectedEvent().?;
    try testing.expect(e == .mouse_down and e.mouse_down.button == .left and e.mouse_down.buttons.left);
    try testing.expect(e.mouse_down.x == 0 and e.mouse_down.y == 0);
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());

    try testing.expect(!pollGate(true));
}

test "実行モデル: inject→nextEvent FIFO / step がフレームを gate" {
    resetForTest();
    cmd_buf =
        \\inject key_down A
        \\inject mouse_down left
        \\step 1
        \\step 2
        \\quit
    ;
    // frame 1: step 1（直前に inject 2 件積む）
    try testing.expect(pollGate(true));
    const e0 = nextInjectedEvent().?;
    try testing.expect(e0 == .key_down and e0.key_down.key == .A);
    const e1 = nextInjectedEvent().?;
    try testing.expect(e1 == .mouse_down and e1.mouse_down.button == .left and e1.mouse_down.buttons.left);
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());

    // frame 2,3: step 2（注入なし）
    try testing.expect(pollGate(true));
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());
    try testing.expect(pollGate(true));
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());

    // quit → 終了
    try testing.expect(!pollGate(true));
}

test "実行モデル: native_continue=false で停止" {
    resetForTest();
    cmd_buf = "step 5\n";
    try testing.expect(!pollGate(false));
}

test "仮想クロック: getTime = frame_index/60、present で進む" {
    resetForTest();
    try testing.expectEqual(@as(f64, 0.0), now());
    const px = [_]u32{0xFF112233};
    onLock(&px, 1, 1);
    onPresent();
    try testing.expectEqual(@as(f64, 1.0 / 60.0), now());
    onLock(&px, 1, 1);
    onPresent();
    try testing.expectEqual(@as(f64, 2.0 / 60.0), now());
    try testing.expect(have_frame);
    try testing.expectEqual(@as(u32, 0xFF112233), frame_pixels[0]);
}

test "lock miss: null lock 後の present は stale を再コピーしない" {
    resetForTest();
    const px = [_]u32{0xFFAABBCC};
    onLock(&px, 1, 1);
    onPresent();
    try testing.expect(have_frame);
    try testing.expectEqual(@as(u32, 0xFFAABBCC), frame_pixels[0]);
    onLockMiss();
    onPresent();
    try testing.expectEqual(@as(u32, 0xFFAABBCC), frame_pixels[0]);
    try testing.expectEqual(@as(u64, 2), frame_index);
}

test "snapshot/digest: present 前は skip（io/フレーム未確定でも安全）" {
    resetForTest();
    cmd_buf =
        \\snapshot fb /tmp/should_not_write.png
        \\digest fb
        \\quit
    ;
    try testing.expect(!pollGate(true));
    try testing.expect(!have_frame);
}

test "fb payload: 既知 pixels → crc/top を絶対値 assert" {
    resetForTest();
    // 2x2: 3px = 0xFF000000, 1px = 0xFF0000FF
    var px = [_]u32{ 0xFF000000, 0xFF000000, 0xFF000000, 0xFF0000FF };
    frame_pixels = px[0..];
    frame_w = 2;
    frame_h = 2;
    have_frame = true;
    const crc = png.crc32(std.mem.sliceAsBytes(px[0..4]));
    var expect_buf: [128]u8 = undefined;
    const expected = std.fmt.bufPrint(&expect_buf, "2x2 crc={X:0>8} top=[#000000:75%,#0000FF:25%]", .{crc}) catch unreachable;
    var buf: [256]u8 = undefined;
    const payload = formatFbPayload(&buf);
    try testing.expectEqualStrings(expected, payload);
    // frame_pixels はテスト所有なので harness に解放させない
    frame_pixels = &.{};
}

test "audio ring: latest-wins で直近 capacity のみ peek できる" {
    resetForTest();
    mode = .replay; // disabled 以外
    audio_head = .init(0);
    // capacity を超える書き込み: 0,1,2,...,AUDIO_CAP+99 を1サンプルずつ
    var v: usize = 0;
    const overflow = AUDIO_CAP + 100;
    while (v < overflow) : (v += 1) {
        const s = [_]f32{@floatFromInt(v)};
        onAudioSamples(&s, 1, 1, 48000);
    }
    var dst: [8]f32 = undefined;
    const n = peekRecentAudio(&dst);
    try testing.expectEqual(@as(usize, 8), n);
    // 直近 8 サンプル = overflow-8 .. overflow-1
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        try testing.expectEqual(@as(f32, @floatFromInt(overflow - 8 + i)), dst[i]);
    }
}

test "analyzeAudio: silence / 定数 / 440Hz sine を絶対値 assert" {
    var mono: [4096]f32 = undefined;

    // silence
    var sil = [_]f32{0} ** 256;
    const a0 = analyzeAudio(&sil, 1, 48000, &mono);
    try testing.expect(a0.silent);
    try testing.expectApproxEqAbs(@as(f32, 0), a0.rms, 1e-6);
    try testing.expectEqual(@as(f32, 0), a0.f0);

    // 振幅 0.5 の 440Hz sine（mono, 48000Hz, 4800 サンプル = 0.1s）
    const sr: f32 = 48000;
    const freq: f32 = 440;
    var sine: [4800]f32 = undefined;
    var i: usize = 0;
    while (i < sine.len) : (i += 1) {
        sine[i] = 0.5 * @sin(2.0 * std.math.pi * freq * @as(f32, @floatFromInt(i)) / sr);
    }
    const a1 = analyzeAudio(&sine, 1, 48000, &mono);
    try testing.expect(!a1.silent);
    try testing.expectApproxEqAbs(@as(f32, 0.5), a1.peak, 0.02); // 振幅 0.5
    try testing.expectApproxEqAbs(@as(f32, 0.3536), a1.rms, 0.02); // 0.5/√2
    try testing.expectApproxEqAbs(@as(f32, 440), a1.f0, 5.0); // ±5Hz
}

test "encodeWav: PCM16 RIFF/WAVE ヘッダの byte offset を絶対値 assert" {
    const interleaved = [_]f32{ 0, 0, 0, 0 }; // 4 samples, 2ch → 2 frames
    const bytes = try encodeWav(&interleaved, 2, 48000, testing.allocator);
    defer testing.allocator.free(bytes);

    try testing.expectEqual(@as(usize, 44 + 8), bytes.len);
    try testing.expectEqualStrings("RIFF", bytes[0..4]);
    try testing.expectEqual(@as(u32, 36 + 8), std.mem.readInt(u32, bytes[4..8], .little));
    try testing.expectEqualStrings("WAVE", bytes[8..12]);
    try testing.expectEqualStrings("fmt ", bytes[12..16]);
    try testing.expectEqual(@as(u32, 16), std.mem.readInt(u32, bytes[16..20], .little));
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, bytes[20..22], .little)); // PCM
    try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, bytes[22..24], .little)); // channels
    try testing.expectEqual(@as(u32, 48000), std.mem.readInt(u32, bytes[24..28], .little)); // sample_rate
    try testing.expectEqual(@as(u32, 48000 * 2 * 2), std.mem.readInt(u32, bytes[28..32], .little)); // byte_rate
    try testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, bytes[32..34], .little)); // block_align
    try testing.expectEqual(@as(u16, 16), std.mem.readInt(u16, bytes[34..36], .little)); // bits
    try testing.expectEqualStrings("data", bytes[36..40]);
    try testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, bytes[40..44], .little)); // data_size
}

test "stats payload: JSON 1行（frame/virtual_fps/EventStats）" {
    resetForTest();
    frame_index = 12;
    last_stats = .{ .mouse_move_merge_count = 3, .mouse_scroll_merge_count = 1, .event_drop_count = 0 };
    var buf: [512]u8 = undefined;
    const json = formatStatsPayload(&buf);
    try testing.expectEqualStrings(
        "{\"frame\":12,\"virtual_fps\":60.0,\"mouse_move_merge_count\":3,\"mouse_scroll_merge_count\":1,\"event_drop_count\":0}",
        json,
    );
}

const TestProbeCtx = struct { value: u32 };
fn testProbeDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const c: *TestProbeCtx = @ptrCast(@alignCast(ctx));
    return std.fmt.bufPrint(buf, "value={d}", .{c.value}) catch buf[0..0];
}

test "custom probe: register + digest routing（generic・framework 非パース・live framing）" {
    resetForTest(); // mode=.replay（disabled 以外 → register 有効）
    var c = TestProbeCtx{ .value = 42 };
    registerProbe(.{ .name = "test", .ctx = &c, .ext = "bin", .digest = testProbeDigest });
    try testing.expectEqual(@as(usize, 1), probe_count);

    // live framing: prefix なし `test value=42\n`
    mode = .live;
    resp_buf.clearRetainingCapacity();
    defer resp_buf.clearRetainingCapacity();
    var it = std.mem.tokenizeAny(u8, "test", " \t");
    handleDigest(&it);
    try testing.expectEqualStrings("test value=42\n", resp_buf.items);
    probe_count = 0;
}

test "custom probe: disabled 時 registerProbe は no-op（回帰ゼロ）" {
    resetForTest();
    mode = .disabled;
    probe_count = 0;
    var c = TestProbeCtx{ .value = 1 };
    registerProbe(.{ .name = "x", .ctx = &c, .digest = testProbeDigest });
    try testing.expectEqual(@as(usize, 0), probe_count);
}

test "custom probe: 同名は上書き / 予約名は拒否 / 満杯は skip" {
    resetForTest();
    probe_count = 0;
    var c1 = TestProbeCtx{ .value = 1 };
    var c2 = TestProbeCtx{ .value = 2 };
    registerProbe(.{ .name = "p", .ctx = &c1, .digest = testProbeDigest });
    registerProbe(.{ .name = "p", .ctx = &c2, .digest = testProbeDigest }); // 同名上書き
    try testing.expectEqual(@as(usize, 1), probe_count);
    const got: *TestProbeCtx = @ptrCast(@alignCast(findProbe("p").?.ctx));
    try testing.expectEqual(@as(u32, 2), got.value);

    // 予約名は登録されない
    registerProbe(.{ .name = "fb", .ctx = &c1, .digest = testProbeDigest });
    registerProbe(.{ .name = "audio", .ctx = &c1, .digest = testProbeDigest });
    registerProbe(.{ .name = "stats", .ctx = &c1, .digest = testProbeDigest });
    try testing.expectEqual(@as(usize, 1), probe_count);

    // 満杯（MAX_PROBES 到達）まで詰め、超過分は skip される（既存 "p" + 新規ユニーク名で埋める）
    const names = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "q", "r" };
    for (names) |nm| registerProbe(.{ .name = nm, .ctx = &c1, .digest = testProbeDigest });
    try testing.expectEqual(@as(usize, MAX_PROBES), probe_count); // 16 で頭打ち（17 個目以降は skip）
    probe_count = 0;
}

test "live framing: digest/snapshot が response buffer に prefix なしで積まれる" {
    resetForTest();
    mode = .live;
    resp_buf.clearRetainingCapacity();
    defer resp_buf.clearRetainingCapacity();
    // fb digest をライブで emit
    var px = [_]u32{0xFF010203};
    frame_pixels = px[0..];
    frame_w = 1;
    frame_h = 1;
    have_frame = true;
    var buf: [256]u8 = undefined;
    emitDigest("fb", formatFbPayload(&buf));
    emitSnapshot("audio", "/tmp/a.wav", "10 samples");
    // response は "fb ...\n/tmp/a.wav\n"
    try testing.expect(std.mem.startsWith(u8, resp_buf.items, "fb 1x1 crc="));
    try testing.expect(std.mem.endsWith(u8, resp_buf.items, "/tmp/a.wav\n"));
    try testing.expect(std.mem.indexOf(u8, resp_buf.items, "[harness]") == null);
    frame_pixels = &.{};
}

// ============================================================================
// headless（TASK-32.4 P4）tests
// ============================================================================

test "decideHeadless: SCRIPT/LIVE 併用時のみ true、単独指定・未要求は false" {
    try testing.expect(!decideHeadless(false, null, false)); // 何も無し
    try testing.expect(!decideHeadless(true, null, false)); // HEADLESS 単独 → 無視
    try testing.expect(decideHeadless(true, "script.txt", false)); // HEADLESS + SCRIPT
    try testing.expect(decideHeadless(true, null, true)); // HEADLESS + LIVE
    try testing.expect(decideHeadless(true, "script.txt", true)); // 両方（後段の矛盾判定は別）
    try testing.expect(!decideHeadless(false, "script.txt", true)); // HEADLESS 未要求なら無関係
}

test "headless window: create→lock→onLock/onPresent で fb 捕捉、サイズ変更で再確保" {
    resetForTest();
    defer destroyHeadlessWindow();

    try createHeadlessWindow(2, 2);
    var view = headlessLock();
    try testing.expectEqual(@as(u32, 2), view.width);
    try testing.expectEqual(@as(u32, 2), view.height);
    try testing.expectEqual(@as(usize, 4), view.pixels.len);

    for (view.pixels) |*p| p.* = 0xFF112233;
    onLock(view.pixels, view.width, view.height);
    onPresent();
    try testing.expect(have_frame);
    try testing.expectEqual(@as(u32, 0xFF112233), frame_pixels[0]);
    try testing.expectEqual(@as(u32, 0xFF112233), frame_pixels[3]);

    // サイズ変更で再確保される（前回の内容を引きずらない: create 直後は 0 クリア）
    try createHeadlessWindow(3, 1);
    view = headlessLock();
    try testing.expectEqual(@as(usize, 3), view.pixels.len);
    try testing.expectEqual(@as(u32, 0), view.pixels[0]);
}
