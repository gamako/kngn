//! ヘッドレス検証 harness（TASK-32: P1 file replay + fb probe / P2 live TCP + audio・stats probe）
//!
//! 目的: 既存アプリを無改造で、`src/platform.zig`(facade) のフックだけで
//!   - 入力注入（key/mouse/scroll）
//!   - 仮想クロック（getTime = frame_index/60）
//!   - probe（`fb` PNG/digest, `audio` WAV/digest, `stats` JSON）
//! を実現する。env 未設定なら全 API は no-op（既存挙動と完全一致）。
//!
//! ## トランスポート（コマンドの来る経路）
//! - **replay（file）**: `VP_HARNESS_SCRIPT=<file>` を全部読み、常に manual clock。step で仮想フレーム前進、EOF/quit で auto-exit。
//! - **listen（TCP loopback）**: `VP_HARNESS_LISTEN[=port]` で `127.0.0.1` に listen。
//!   値なし／空／`0` は ephemeral、正の値は固定 port。既定は free-run clock（アプリ自走 + 非 blocking drain）。
//!   `VP_HARNESS_MANUAL_CLOCK=1` を併用すると旧 step-driven（blocking accept/read）相当。
//! - **スクリプト形式 == listen protocol**: パーサ・実行モデルは共通。差分は source（file/socket）と
//!   clock mode（manual は gate で駆動、free-run は frame barrier / await で待つ）点のみ。
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
//! - import は `std` / `platform_types.zig`(共有型) / `png`(エンコーダ+crc32) / `dsp`(FFT・スペクトル解析) のみ。
//!   backend(platform_macos/linux*) と audio backend には依存しない。audio サンプルは `audio.zig` facade が
//!   `onAudioSamples()` で push する（依存方向 audio→harness）。
//! - facade フックは io を持たないため、ファイル I/O / TCP は harness が自前の `std.Io.Threaded` io で行う。

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const types = @import("platform_types");
const png = @import("png");
const dsp = @import("dsp"); // TASK-92: magnitudeSpectrum（band/centroid/onset）。RT 経路では呼ばない
const capture_synthetic = @import("capture_synthetic"); // synthetic capture source（TASK-49.5）
pub const action_registry = @import("action_registry.zig"); // TASK-62.3.1: Action/registry 分離
pub const netsync = @import("netsync.zig"); // TASK-62.3.2: PROPOSE/COMMIT/REJECT（同一 action_registry インスタンス共有）

const Event = types.Event;
const KeyCode = types.KeyCode;
const KeyEvent = types.KeyEvent;
const MouseEvent = types.MouseEvent;
const ScrollEvent = types.ScrollEvent;
const MouseButton = types.MouseButton;
const MouseButtons = types.MouseButtons;
const ModifierFlags = types.ModifierFlags;
const EventStats = types.EventStats;
const GamepadButton = types.GamepadButton;
const GamepadState = types.GamepadState;
const GamepadInfo = types.GamepadInfo;
const GamepadDisconnect = types.GamepadDisconnect;
const CompositionPhase = types.CompositionPhase;
const CompositionSnapshot = types.CompositionSnapshot;
const MidiEvent = types.MidiEvent;
const MidiDeviceId = types.MidiDeviceId;
const GAMEPAD_NAME_MAX = types.GAMEPAD_NAME_MAX;
const MAX_GAMEPADS = types.MAX_GAMEPADS;

const net = std.Io.net;

const gpa = std.heap.page_allocator;
const Tok = std.mem.TokenIterator(u8, .any);

/// harness 有効時の仮想フレームレート（getTime=frame/60 と整合する固定値。実性能計測ではない）。
const VIRTUAL_FPS: f64 = 60.0;

// audio tap（latest-wins SPSC）。producer=RT スレッドが head を進めて書く（満杯でも上書き）、
// consumer=メインスレッドが「直近窓」を non-destructive に peek する。
const AUDIO_CAP: usize = 1 << 16; // interleaved f32 サンプル数（48kHz stereo で ~0.68s）
const AUDIO_MASK: usize = AUDIO_CAP - 1;
const ANALYZE_FRAMES: usize = 4096; // digest 解析窓（mono frames。既存 rms/peak/f0 用。変更禁止）
const EXT_FRAMES: usize = 32768; // TASK-92 拡張解析窓（LUFS 400ms@48k=19200 を収容。最大 ~0.68s）
const EXT_FFT_N: usize = 4096; // band/centroid 用 FFT 点数
const ONSET_FFT_N: usize = 2048; // onset 用 FFT 点数
const ONSET_HOP: usize = 1024; // onset 用 hop
const LUFS_FLOOR: f32 = -99.0; // 無音・窓不足時の LUFS 床値

// ============================================================================
// module-level state（単一プロセス・単一ウィンドウ前提の debug facility）
// ============================================================================
const Mode = enum { disabled, replay, live };
/// clock ownership（TASK-164）。replay は常に manual。LISTEN 既定は free_run、MANUAL_CLOCK=1 で manual。
const ClockMode = enum { manual, free_run };
var mode: Mode = .disabled;
var clock_mode: ClockMode = .manual;
var initialized = false;

// コマンド source（replay=script 全体 / live=現在のリクエスト）を指す共通バッファ
var cmd_buf: []const u8 = "";
var cursor: usize = 0;
var line_no: usize = 0;
var steps_remaining: usize = 0;
var quit_requested = false;

// expect/assert（TASK-78）+ action（TASK-62.1）の失敗カウンタ（**replay 専用**。live は使わない=
// 合否はレスポンス行のみ）。replay 終了時に >0 なら非0 exit する（AC#1）。resetForTest でゼロクリアする。
var expect_failures: usize = 0;

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

// MIDI synthetic FIFO/state（TASK-115.1・ADR-010）。Window Event queue とは独立させ、
// midi facade の pollMidi() だけが FIFO を読む。state は注入時点で更新し、app の drain 前でも
// `digest midi` が最後の論理状態を観測できるようにする。
const MIDI_FIFO_CAP: usize = 256;
var midi_buf: [MIDI_FIFO_CAP]MidiEvent = undefined;
var midi_count: usize = 0;
var midi_read: usize = 0;
var midi_pressed: [16]u8 = [_]u8{0} ** 16;
var midi_cc_values: [128]u8 = [_]u8{0} ** 128;
var midi_cc_set: [128]bool = [_]bool{false} ** 128;

// マウス状態（move/down/up/scroll の一貫したイベント構築用）
var mouse_x: i32 = 0;
var mouse_y: i32 = 0;
var mouse_buttons: MouseButtons = .{};

// ゲームパッド状態（TASK-80.1。ADR-009）。inject gamepad_connect/disconnect/button/axis で更新し、
// facade の Window.getGamepadState / 組み込み probe `gamepad` が読む。null = 未接続。
var gamepad_states: [MAX_GAMEPADS]?GamepadState = [_]?GamepadState{null} ** MAX_GAMEPADS;

// synthetic IME composition（TASK-79.6.2）。本文は latest-wins snapshot、イベントは状態変化通知。
const COMPOSITION_CAP: usize = 1024;
var composition_text: [COMPOSITION_CAP]u8 = undefined;
var composition_len: usize = 0;
var composition_cursor: usize = 0;
var composition_revision: u32 = 0;
var composition_active = false;

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

// null runtime query（TASK-165: platform が VP_HEADLESS を確定し、互換 query として公開）。
// 一次 framebuffer は platform_null.Window が所有。harness は観測 hook のみ。
var config_parsed = false;
var pending_script_path: ?[]const u8 = null;
var pending_listen_raw: ?[]const u8 = null; // env 値（存在時）。port 解釈は startTransport
var pending_manual_clock = false;
var headless_active = false;

// present 毎の frame copy をスキップする計測専用モード（TASK-156.5 R10。VP_HARNESS_SKIP_FRAME_COPY env）。
// 既定 false で従来と bit 一致。有効時は `fb`/`canvas` 等の snapshot/digest が無効値になるが、
// `digest stats` の frame カウンタは引き続き増分するため fps 計測には使える。
var skip_frame_copy = false;

// synthetic capture source（TASK-49.5）: harness 内蔵の偽 mic/camera。camera.zig/audio.zig への
// facade 配線は無く、このモジュール内（`capture` コマンド + `capture` probe）で完結する。
var capture_synthetic_requested = false; // VP_HARNESS_CAPTURE_SYNTHETIC env
var synth_video: ?capture_synthetic.SyntheticVideoDevice = null;
var synth_audio: ?capture_synthetic.SyntheticAudioDevice = null;

// custom probe registry（app が opt-in 登録。framework は中身を解釈せず raw+digest をルートするだけ）
// 単一プロセスの debug facility なので固定長 module-level 配列で十分（動的確保なし）。
const MAX_PROBES = 16;
pub const DIGEST_BUF_LEN = 1024; // custom digest callback に渡す共通バッファ長（copilot も同契約で使う）
var probes: [MAX_PROBES]Probe = undefined;
var probe_count: usize = 0;

// io（0.16 は std.fs blocking API が無く std.Io 経由のみ）。file 読み書きと TCP の両方に使う。
var threaded: std.Io.Threaded = undefined;
var io_val: std.Io = undefined;

// live transport
var server: net.Server = undefined;
var live_stream: net.Stream = undefined;
var live_req_open = false;
var live_stream_owned = false; // accept 済みのときだけ close する（テストの擬似 request 対策）
var req_bytes: []u8 = &.{}; // 現在のリクエスト（finish 時に free）
var resp_buf: std.ArrayList(u8) = .empty;

// free-run: accept 後・request 完成前の非 blocking 読取（manual の blocking receiver と分離）
var freerun_reading = false;
var freerun_acc: std.ArrayList(u8) = .empty;
/// test-only: free-run 空 drain が listener に対して行った poll(timeout=0) 回数。
var test_poll_zero_count: usize = 0;

// record（live コマンドログ）
var record_path: ?[]const u8 = null;
var record_buf: std.ArrayList(u8) = .empty;

// live fd poll の timeout（ms）。テストのみ短縮上書き可（フレーキー回避）。
var test_live_poll_timeout_ms: ?i32 = null;
const live_poll_timeout_default_ms: i32 = 16;

// audio tap
var audio_buf: [AUDIO_CAP]f32 = undefined;
var audio_head: std.atomic.Value(usize) = .init(0);
var audio_channels: std.atomic.Value(u32) = .init(0);
var audio_rate: std.atomic.Value(u32) = .init(0);
var audio_scratch: [AUDIO_CAP]f32 = undefined; // peek 先（メインスレッド）
var audio_mono: [ANALYZE_FRAMES]f32 = undefined; // downmix scratch（メインスレッド・既存 analyzeAudio）
var audio_mono_ext: [EXT_FRAMES]f32 = undefined; // TASK-92 拡張解析 downmix（メインスレッド）
// FFT scratch（digest 要求時のみ。RT 非接触。module-level で alloc 回避）
var ext_fft_re: [EXT_FFT_N]f32 = undefined;
var ext_fft_im: [EXT_FFT_N]f32 = undefined;
var ext_mags: [EXT_FFT_N / 2]f32 = undefined;
var onset_fft_re: [ONSET_FFT_N]f32 = undefined;
var onset_fft_im: [ONSET_FFT_N]f32 = undefined;
var onset_mags_cur: [ONSET_FFT_N / 2]f32 = undefined;
var onset_mags_prev: [ONSET_FFT_N / 2]f32 = undefined;
var onset_win: [ONSET_FFT_N]f32 = undefined;

// ============================================================================
// 公開: 初期化 / hook API（platform.zig facade から呼ばれる）
// ============================================================================

pub fn isEnabled() bool {
    return mode != .disabled;
}

/// manual clock（replay / LISTEN+MANUAL_CLOCK）か。virtual getTime / frameDelay no-op / blocking gate の判定。
pub fn isManualClock() bool {
    return isEnabled() and clock_mode == .manual;
}

/// 外部 control-plane（copilot。TASK-62.5.2）が probe registry 登録を有効化するフラグ。
/// action 側は `action_registry.setEnabled`（OR 条件）へ転送する（TASK-62.3.1）。
/// 依存は copilot→harness の一方向で、harness から copilot の関数は呼ばない。
var external_registry_enabled = false;

/// 外部 transport（copilot 等）が probe/action registry の登録ゲートを開く。
/// - probe: `registerProbe` の有効判定が `isEnabled() or このフラグ`。
/// - action: `v==true` のときだけ `action_registry.setEnabled(true)` へ転送。
///   `false` は action_registry に伝えない（無効化は `action_registry.resetForTest` 必須）。
pub fn setExternalRegistryEnabled(v: bool) void {
    external_registry_enabled = v;
    if (v) action_registry.setEnabled(true);
}

/// probe registry の登録ゲート（harness 有効 or 外部 transport 有効）。
/// action のゲートは `action_registry.enabled` のみ（registerProbe のゲートはここに残す）。
fn registryEnabled() bool {
    return isEnabled() or external_registry_enabled;
}

/// live 実表示時に harness が accept/read 待機中に呼ぶ native event pump callback。
/// `pollFn` が `false` を返したら window close / compositor disconnect として live wait を中断する。
pub const NativePump = struct {
    ptr: *anyopaque,
    pollFn: *const fn (*anyopaque) bool,

    pub fn poll(self: NativePump) bool {
        return self.pollFn(self.ptr);
    }
};

/// action/probe 共通の args シグネチャ型（TASK-88.1。action_registry が単一ソース）。
pub const ArgSpec = action_registry.ArgSpec;

/// app が register する custom probe。**framework は中身を解釈しない**:
/// snapshot が返す raw バイト列をそのまま file へ書き、digest が返す1行を既存 sink へ流すだけ。
/// 各 probe の意味づけ（PNG 化 / JSON 整形 等）は全て app 側 callback に閉じる。
pub const Probe = struct {
    /// probe 名（snapshot/digest コマンドの引数。fb/audio/stats/capabilities/capture は予約名で登録不可）。
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
    /// capabilities 列挙（TASK-62.4）用の説明文（省略可）。登録時に `sanitizeDesc` で
    /// 禁止文字（`"`/`\`/ASCII 制御文字）・200 bytes 超をチェックし、違反時は空文字へ落とす
    /// （中身の意味解釈ではなく capabilities JSON の wire framing 保護）。
    desc: []const u8 = "",
    /// args シグネチャ（TASK-88.1。省略可・後方互換）。Action と同じ契約:
    /// **null=未指定（JSON に args 無し）/ 空 slice=引数なし明示**。現状の probe は全て null のまま。
    args: ?[]const ArgSpec = null,
};

/// custom probe を登録する。app は `platform.registerProbe(...)` 経由で `platform.init()` 後に呼ぶ。
/// - harness 無効時（env 未設定）は **no-op**（registry を一切触らない＝通常実行の回帰ゼロ）。
/// - 同名は上書き。fb/audio/stats/capabilities/capture は予約名で拒否。registry 満杯はスキップ（いずれも warn）。
pub fn registerProbe(p: Probe) void {
    if (!registryEnabled()) return;
    if (isReservedProbeName(p.name)) {
        std.debug.print("[harness] registerProbe: 予約名 '{s}' は登録できません\n", .{p.name});
        return;
    }
    for (probes[0..probe_count]) |*existing| {
        if (std.mem.eql(u8, existing.name, p.name)) {
            var mp = p;
            mp.desc = sanitizeDesc("probe", p.name, p.desc); // 実際に保存する直前にのみ sanitize（満杯 skip 時に無用な warn を出さない）
            mp.args = sanitizeArgs("probe", p.name, p.args);
            existing.* = mp; // 同名上書き
            return;
        }
    }
    if (probe_count >= MAX_PROBES) {
        std.debug.print("[harness] registerProbe: registry 満杯（{d}）。'{s}' をスキップ\n", .{ MAX_PROBES, p.name });
        return;
    }
    var mp = p;
    mp.desc = sanitizeDesc("probe", p.name, p.desc);
    mp.args = sanitizeArgs("probe", p.name, p.args);
    probes[probe_count] = mp;
    probe_count += 1;
}

fn isReservedProbeName(name: []const u8) bool {
    return std.mem.eql(u8, name, "fb") or std.mem.eql(u8, name, "audio") or std.mem.eql(u8, name, "stats") or
        std.mem.eql(u8, name, "capabilities") or std.mem.eql(u8, name, "capture") or
        std.mem.eql(u8, name, "gamepad") or std.mem.eql(u8, name, "midi");
}

/// JSON 文字列へ未エスケープで埋め込むと破損する文字（`"` / `\` / ASCII 制御文字 `0x00..0x1F`。
/// tab や NUL も含む）を含むかを判定する。`sanitizeDesc`（登録時）と capabilities の entry
/// 組み立て（format 時、name/ext の防御的チェック）の両方が共有する。
fn containsUnsafeJsonChar(s: []const u8) bool {
    for (s) |c| {
        if (c == '"' or c == '\\' or c < 0x20) return true;
    }
    return false;
}

/// capabilities 列挙用の desc を登録時にサニタイズする。禁止文字を含む、または 200 bytes 超の
/// desc は warn を出し空文字を返す（登録自体は成功させ desc だけ無効化。JSON buffer 安全性のための
/// wire framing 保護であり、desc の意味解釈ではない）。
const MAX_DESC_LEN = 200;
const MAX_ARG_NAME_LEN = 32;
const MAX_ARG_KIND_LEN = 32;
const MAX_ARG_VALUE_LEN = 64;
const MAX_ARG_PATTERN_LEN = 100;
fn sanitizeDesc(kind: []const u8, name: []const u8, desc: []const u8) []const u8 {
    if (desc.len == 0) return desc;
    if (desc.len > MAX_DESC_LEN or containsUnsafeJsonChar(desc)) {
        std.debug.print("[harness] {s} desc for '{s}' は無効化されました（禁止文字 or 200 bytes 超）\n", .{ kind, name });
        return "";
    }
    return desc;
}

/// probe args シグネチャの登録時サニタイズ（TASK-88.1。action_registry 側と同規則・重複定義維持）。
/// 違反時は warn + args 全体を null（登録自体は成功）。
fn sanitizeArgs(kind: []const u8, name: []const u8, args: ?[]const ArgSpec) ?[]const ArgSpec {
    const specs = args orelse return null;
    for (specs) |s| {
        // NaN/Inf は JSON 数値として emit できない（常に valid JSON の契約を壊す）ため登録時に拒否
        if ((s.min != null and !std.math.isFinite(s.min.?)) or
            (s.max != null and !std.math.isFinite(s.max.?)))
        {
            std.debug.print("[harness] {s} args for {s} は無効化されました（min/max が非有限）\n", .{ kind, name });
            return null;
        }
        if (s.name.len > MAX_ARG_NAME_LEN or containsUnsafeJsonChar(s.name) or
            s.kind.len > MAX_ARG_KIND_LEN or containsUnsafeJsonChar(s.kind) or
            s.pattern.len > MAX_ARG_PATTERN_LEN or containsUnsafeJsonChar(s.pattern) or
            s.desc.len > MAX_DESC_LEN or containsUnsafeJsonChar(s.desc))
        {
            std.debug.print("[harness] {s} args for '{s}' は無効化されました（禁止文字 or 長さ上限超過）\n", .{ kind, name });
            return null;
        }
        for (s.values) |v| {
            if (v.len > MAX_ARG_VALUE_LEN or containsUnsafeJsonChar(v)) {
                std.debug.print("[harness] {s} args for '{s}' は無効化されました（禁止文字 or 長さ上限超過）\n", .{ kind, name });
                return null;
            }
        }
    }
    return specs;
}

/// 登録済み custom probe の name lookup（copilot 等の外部 control-plane も使う。TASK-62.5.2 で pub 化）。
pub fn findProbe(name: []const u8) ?*Probe {
    for (probes[0..probe_count]) |*p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

// ============================================================================
// custom action（TASK-62.1 → TASK-62.3.1 で action_registry.zig へ移送）
// ============================================================================

/// Action / NetworkPolicy / registerAction / findAction は `action_registry` へ移送済み。
/// 既存 caller（copilot・harness テスト）向けに re-export する。
pub const Action = action_registry.Action;
pub const NetworkPolicy = action_registry.NetworkPolicy;
pub const registerAction = action_registry.registerAction;
pub const findAction = action_registry.findAction;
pub const setActionErrorDetail = action_registry.setActionErrorDetail;

/// `VP_HARNESS_LISTEN` 値の純解釈（I/O 無し・単体テスト用）。
/// - null = env 未設定（listen しない）
/// - 空 / "0" = ephemeral（port=0, ok）
/// - 正の整数 = 固定 port
/// - それ以外 = invalid（transport 無効化）
const ListenPortParse = struct {
    requested: bool,
    port: u16 = 0,
    valid: bool = true,
};

fn parseListenPortValue(raw: ?[]const u8) ListenPortParse {
    const s = raw orelse return .{ .requested = false };
    const trimmed = std.mem.trim(u8, s, " \t");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "0")) {
        return .{ .requested = true, .port = 0, .valid = true };
    }
    const port = std.fmt.parseInt(u16, trimmed, 10) catch {
        return .{ .requested = true, .port = 0, .valid = false };
    };
    if (port == 0) return .{ .requested = true, .port = 0, .valid = true };
    return .{ .requested = true, .port = port, .valid = true };
}

/// SCRIPT / LISTEN / MANUAL_CLOCK の排他・clock 既定（純関数・単体テスト用）。
const TransportDecision = struct {
    enable: bool,
    clock: ClockMode,
    listen_port: u16 = 0,
    reason_disabled: ?[]const u8 = null,
};

fn decideTransport(script: bool, listen: ListenPortParse, manual_clock: bool) TransportDecision {
    if (!script and !listen.requested) {
        if (manual_clock) {
            return .{ .enable = false, .clock = .manual, .reason_disabled = "MANUAL_CLOCK requires LISTEN" };
        }
        return .{ .enable = false, .clock = .manual };
    }
    if (script and listen.requested) {
        return .{ .enable = false, .clock = .manual, .reason_disabled = "SCRIPT and LISTEN mutually exclusive" };
    }
    if (listen.requested and !listen.valid) {
        return .{ .enable = false, .clock = .manual, .reason_disabled = "invalid LISTEN port" };
    }
    if (script) {
        // MANUAL_CLOCK on SCRIPT は無視（常に manual）
        return .{ .enable = true, .clock = .manual };
    }
    // listen
    const clock: ClockMode = if (manual_clock) .manual else .free_run;
    return .{ .enable = true, .clock = clock, .listen_port = listen.port };
}

/// platform.init() の最初に1度だけ呼ぶ。env を読むだけで I/O 副作用（script 読込・listen）は起こさない
/// （TASK-32.4 P4: transport 判定を `backend.init()` の要否より前に確定させるため `startTransport()` と
/// 二段階に分割した。詳細はタスク plan §3.1）。
/// headless（`VP_HEADLESS`）は platform が確定し `setHeadlessActive` で渡す（本関数では読まない。TASK-165）。
pub fn parseConfig() void {
    if (config_parsed) return;
    config_parsed = true;

    pending_script_path = getEnv("VP_HARNESS_SCRIPT");
    pending_listen_raw = getEnv("VP_HARNESS_LISTEN");
    pending_manual_clock = if (getEnv("VP_HARNESS_MANUAL_CLOCK")) |v| std.mem.eql(u8, v, "1") else false;
    if (getEnv("VP_HARNESS_OUT")) |d| out_dir = d;

    capture_synthetic_requested = getEnv("VP_HARNESS_CAPTURE_SYNTHETIC") != null;
    skip_frame_copy = if (getEnv("VP_HARNESS_SKIP_FRAME_COPY")) |v| std.mem.eql(u8, v, "1") else false;
}

/// platform が `VP_HEADLESS=1` を確定したあと呼ぶ互換 setter（TASK-165）。
/// audio/midi/capture 等が `isHeadlessActive()` で参照する。wasm stub は no-op。
pub fn setHeadlessActive(active: bool) void {
    headless_active = active;
}

/// null runtime 判定（platform が `setHeadlessActive` で設定。env の SoT は `VP_HEADLESS`）。
/// facade が Window を null backend にするかの分岐と、audio/midi の native 回避に使う。
pub fn isHeadlessActive() bool {
    return headless_active;
}

/// capture（マイク/カメラ）の synthetic source 有効判定（TASK-49.5）。
/// `VP_HARNESS_CAPTURE_SYNTHETIC` env かつ harness が有効（replay/live）のときのみ `true`。
/// 既定（env 未設定）では常に `false`（回帰ゼロ）。
///
/// **注意（重要な限定）**: `core/camera.zig`/`core/audio.zig` は本タスクでは変更していないため、
/// この関数が `true` を返しても `camera.open()`/`audio.openCapture()` は引き続き
/// `error.Unsupported` を返す（49.1 のプレースホルダ分岐がそのまま残る）。本タスクの synthetic
/// capture は `core/capture_synthetic.zig` + harness 組み込みの `capture` コマンド/probe として
/// **このモジュール内で完結**しており、facade への配線は別タスクに委ねる
/// （`docs/plans/capture-foundation-plan.md` 5章の「1行差し替え」は当初案だったが、`camera.zig`
/// 側の公開 `VideoDevice` 型が具象 alias のため単純な差し替えでは済まないと判明し、TASK-49.5 の
/// codex レビューでスコープ外と確定した）。
///
/// 有効化条件は既存 audio 出力と同じ規約を踏襲する: harness の env 読み（`parseConfig()`）は
/// `platform.init()` 経由でのみ走るため、`platform.init()` を呼ばない capture-only アプリでは
/// 本関数は常に `false` を返す（`examples/15_audio_tone` 等の audio-only アプリが
/// `VP_HEADLESS` を解釈できないのと同じ既知の制約）。
pub fn isCaptureSyntheticActive() bool {
    return capture_synthetic_requested and isEnabled();
}

/// platform.init() が（非 null runtime 時は `native_backend.init()` の後に）1度だけ呼ぶ。
/// script 読込 / live listen の実 I/O はここに閉じる（`parseConfig()` との分割は plan §3.1 参照）。
pub fn startTransport() void {
    if (initialized) return;
    initialized = true;

    const script_path = pending_script_path;
    const listen = parseListenPortValue(pending_listen_raw);
    const decision = decideTransport(script_path != null, listen, pending_manual_clock);
    if (!decision.enable) {
        if (decision.reason_disabled) |why| {
            std.debug.print("[harness] {s}。harness を無効化します。\n", .{why});
        }
        return;
    }

    threaded = std.Io.Threaded.init(gpa, .{});
    io_val = threaded.io();
    clock_mode = decision.clock;

    if (script_path) |path| {
        script_bytes = std.Io.Dir.cwd().readFileAlloc(io_val, path, gpa, .unlimited) catch |err| {
            std.debug.print("[harness] script 読み込み失敗 {s}: {s}\n", .{ path, @errorName(err) });
            return; // disabled のまま
        };
        cmd_buf = script_bytes;
        mode = .replay;
        clock_mode = .manual;
        action_registry.setEnabled(true);
        std.debug.print("[harness] replay 有効: script={s} out={s}\n", .{ path, out_dir });
        return;
    }

    // listen（TCP）
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(decision.listen_port) };
    server = addr.listen(io_val, .{ .reuse_address = true }) catch |err| {
        std.debug.print("[harness] listen 失敗: {s}\n", .{@errorName(err)});
        return; // disabled のまま
    };
    record_path = getEnv("VP_HARNESS_RECORD");
    mode = .live;
    action_registry.setEnabled(true);
    const chosen = server.socket.address.getPort();
    const clock_label: []const u8 = if (clock_mode == .manual) "manual" else "free-run";
    std.debug.print("[harness] listen 有効 ({s}): 127.0.0.1:{d} out={s}\n", .{ clock_label, chosen, out_dir });
    writePortFile(chosen);
}

const CmpOp = enum { eq, ne, gt, lt };
const Cmp = struct { op: CmpOp, key: []const u8, value: []const u8 };
const ExpectExpr = struct {
    probe: []const u8,
    form: union(enum) {
        cmp: Cmp,
        contains: []const u8,
    },
};

/// free-run / await の継続待機（1 接続を保持したまま frame boundary で再開）。
const PendingWait = union(enum) {
    none,
    frame_barrier: struct { target_frame: u64 },
    predicate: struct {
        expr: ExpectExpr,
        expr_text: []const u8,
        start_frame: u64,
        timeout_frames: usize,
    },
};
var pending_wait: PendingWait = .none;

/// フレーム進行の同期点。1 フレーム分の進行を許可するとき true。
/// quit / EOF(replay) / window closed(native_continue=false) / accept 失敗(live manual) で false。
/// free-run では常に true（アプリ自走。agent 不在でも止まらない）— quit/native close のみ false。
pub fn pollGate(native_continue: bool) bool {
    if (mode == .live and clock_mode == .free_run) {
        return pollGateFreeRun(native_continue);
    }
    return pollGateWithPump(native_continue, null);
}

pub fn pollGateWithPump(native_continue: bool, pump: ?NativePump) bool {
    // 早期 return（window close 等で native_continue=false / 既に quit 済み）でも、記帳済みの
    // expect 失敗を exit code へ落とす（TASK-78。replay 終了 3 経路の 1 つ。live/通常実行では no-op）。
    if (quit_requested or !native_continue) {
        replayExitIfFailed();
        return false;
    }
    // await predicate: 不成立なら 1 フレーム駆動して再評価（manual/replay）
    if (resolvePendingWaitManual()) |gate| return gate;

    if (steps_remaining > 0) {
        steps_remaining -= 1;
        return true;
    }
    while (true) {
        if (cursor >= cmd_buf.len) {
            switch (mode) {
                .replay, .disabled => {
                    replayExitIfFailed(); // EOF（replay 終了経路）
                    return false;
                },
                .live => {
                    finishLiveRequest();
                    if (quit_requested) return false;
                    if (!acceptLiveRequest(pump)) return false; // accept 失敗 = 終了
                    continue;
                },
            }
        }
        const raw = nextLine() orelse continue;
        // 先頭空白のみ除去。行末スペースは `inject commit` 等が保持するため残す（TASK-79.6.1 codex D）。
        // 行末 \r のみ落とす（record→replay 対称: commit 本文の前後空白を失わない）。
        var line = std.mem.trimStart(u8, raw, " \t");
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
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
            replayExitIfFailed(); // quit（replay 終了経路。live は finishLiveRequest 後で no-op）
            return false;
        } else if (std.mem.eql(u8, cmd, "inject")) {
            handleInject(&it);
        } else if (std.mem.eql(u8, cmd, "snapshot")) {
            handleSnapshot(&it);
        } else if (std.mem.eql(u8, cmd, "digest")) {
            handleDigest(&it);
        } else if (std.mem.eql(u8, cmd, "action")) {
            handleAction(&it);
        } else if (std.mem.eql(u8, cmd, "capture")) {
            handleCapture(&it);
        } else if (std.mem.eql(u8, cmd, "expect")) {
            handleExpect(&it, false);
        } else if (std.mem.eql(u8, cmd, "assert")) {
            handleExpect(&it, true);
        } else if (std.mem.eql(u8, cmd, "await")) {
            if (handleAwait(&it)) return true; // predicate pending → 1 フレーム駆動
        } else {
            warnLine("不明なコマンド");
        }
    }
}

/// free-run gate: 非 blocking drain。空時は listener poll(0) 1 回のみ。NativePump は呼ばない。
pub fn pollGateFreeRun(native_continue: bool) bool {
    if (quit_requested or !native_continue) {
        if (live_req_open) finishLiveRequest();
        if (freerun_reading) abortFreeRunRead();
        return false;
    }

    // pending wait の解決（frame barrier / await）
    switch (pending_wait) {
        .none => {},
        .frame_barrier => |b| {
            if (frame_index >= b.target_frame) {
                pending_wait = .none;
                // 続きのコマンドへ
            } else {
                return true; // アプリ自走を待つ
            }
        },
        .predicate => {
            switch (evalPendingPredicate()) {
                .pass => {
                    reportAwait(true, pendingPredicateExprText(), null);
                    pending_wait = .none;
                },
                .fail => {
                    reportAwait(false, pendingPredicateExprText(), pendingPredicateActual());
                    pending_wait = .none;
                },
                .pending => return true,
            }
        },
    }

    // アクティブ request のコマンドを進める（step/await で pending になったら戻る）
    if (live_req_open) {
        if (!runFreeRunCommands()) return false; // quit
        if (pending_wait != .none) return true;
        if (cursor >= cmd_buf.len) {
            finishLiveRequest();
        } else {
            return true; // 通常ここには来ない（runFreeRunCommands が尽くすか pending）
        }
    }

    drainFreeRunTransport();
    // drain で request が完成していれば同フレームで処理
    if (live_req_open) {
        if (!runFreeRunCommands()) return false;
        if (pending_wait != .none) return true;
        if (cursor >= cmd_buf.len) finishLiveRequest();
    }
    return true;
}

/// free-run のコマンド実行。false = quit。pending_wait 設定時は true で戻る（呼び出し側が frame 継続）。
fn runFreeRunCommands() bool {
    while (cursor < cmd_buf.len) {
        const raw = nextLine() orelse continue;
        var line = std.mem.trimStart(u8, raw, " \t");
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0 or line[0] == '#') continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const cmd = it.next() orelse continue;
        if (std.mem.eql(u8, cmd, "step")) {
            const n = parseUsize(it.next()) orelse 1;
            if (n == 0) continue;
            pending_wait = .{ .frame_barrier = .{ .target_frame = frame_index + n } };
            return true;
        } else if (std.mem.eql(u8, cmd, "quit")) {
            quit_requested = true;
            finishLiveRequest();
            return false;
        } else if (std.mem.eql(u8, cmd, "inject")) {
            handleInject(&it);
        } else if (std.mem.eql(u8, cmd, "snapshot")) {
            handleSnapshot(&it);
        } else if (std.mem.eql(u8, cmd, "digest")) {
            handleDigest(&it);
        } else if (std.mem.eql(u8, cmd, "action")) {
            handleAction(&it);
        } else if (std.mem.eql(u8, cmd, "capture")) {
            handleCapture(&it);
        } else if (std.mem.eql(u8, cmd, "expect")) {
            handleExpect(&it, false);
        } else if (std.mem.eql(u8, cmd, "assert")) {
            handleExpect(&it, true);
        } else if (std.mem.eql(u8, cmd, "await")) {
            if (handleAwait(&it)) return true;
        } else {
            warnLine("不明なコマンド");
        }
    }
    return true;
}

/// free-run 非 blocking drain。空なら listener へ poll(0) をちょうど 1 回。
fn drainFreeRunTransport() void {
    if (freerun_reading) {
        tryReadFreeRunRequest();
        return;
    }
    if (live_req_open) return;

    switch (pollFdReady(server.socket.handle)) {
        .ready => {
            const stream = server.accept(io_val) catch |err| {
                std.debug.print("[harness] accept 失敗: {s}\n", .{@errorName(err)});
                return;
            };
            live_stream = stream;
            freerun_reading = true;
            freerun_acc.clearRetainingCapacity();
            resp_buf.clearRetainingCapacity();
            tryReadFreeRunRequest();
        },
        .not_ready, .err => {},
    }
}

const PollReady = enum { ready, not_ready, err };

fn pollFdReady(fd: net.Socket.Handle) PollReady {
    switch (comptime builtin.os.tag) {
        .windows => {
            // Windows: 非 blocking 契約は別 API。free-run unit test は POSIX 前提で Skip。
            // accept を試行すると block し得るため、空 drain では not_ready 扱い。
            test_poll_zero_count += 1;
            return .not_ready;
        },
        else => {
            test_poll_zero_count += 1;
            var pfds = [_]posix.pollfd{.{
                .fd = fd,
                .events = posix.POLL.IN | posix.POLL.ERR | posix.POLL.HUP,
                .revents = 0,
            }};
            const n = posix.poll(&pfds, 0) catch return .err;
            if (n == 0) return .not_ready;
            const revents = pfds[0].revents;
            if (revents & (posix.POLL.ERR | posix.POLL.NVAL) != 0) return .err;
            if (revents & (posix.POLL.IN | posix.POLL.HUP) != 0) return .ready;
            return .not_ready;
        },
    }
}

fn tryReadFreeRunRequest() void {
    const fd = live_stream.socket.handle;
    switch (pollFdReady(fd)) {
        .not_ready => return,
        .err => {
            abortFreeRunRead();
            return;
        },
        .ready => {},
    }
    var rbuf: [4096]u8 = undefined;
    var bufs = [_][]u8{rbuf[0..]};
    const n = io_val.vtable.netRead(io_val.userdata, fd, bufs[0..]) catch {
        abortFreeRunRead();
        return;
    };
    if (n == 0) {
        // peer half-close → request 完成
        const bytes = freerun_acc.toOwnedSlice(gpa) catch {
            abortFreeRunRead();
            return;
        };
        freerun_reading = false;
        req_bytes = bytes;
        cmd_buf = bytes;
        cursor = 0;
        line_no = 0;
        live_req_open = true;
        live_stream_owned = true;
        recordRequest(bytes);
        return;
    }
    const limit: usize = 1 << 20;
    if (freerun_acc.items.len + n > limit) {
        appendResp("error: request too large\n");
        // レスポンスを返して閉じる
        freerun_reading = false;
        live_req_open = true;
        live_stream_owned = true;
        req_bytes = &.{};
        cmd_buf = "";
        cursor = 0;
        finishLiveRequest();
        return;
    }
    freerun_acc.appendSlice(gpa, rbuf[0..n]) catch {
        abortFreeRunRead();
        return;
    };
}

fn abortFreeRunRead() void {
    if (freerun_reading) {
        live_stream.close(io_val);
        freerun_reading = false;
    }
    freerun_acc.clearRetainingCapacity();
}

/// manual 経路の pending await 解決。`null` = 続行、`Some(bool)` = 即 return。
fn resolvePendingWaitManual() ?bool {
    switch (pending_wait) {
        .none => return null,
        .frame_barrier => {
            // manual では frame_barrier を使わない（steps_remaining）
            pending_wait = .none;
            return null;
        },
        .predicate => {
            switch (evalPendingPredicate()) {
                .pass => {
                    reportAwait(true, pendingPredicateExprText(), null);
                    pending_wait = .none;
                    return null; // コマンドループへ
                },
                .fail => {
                    reportAwait(false, pendingPredicateExprText(), pendingPredicateActual());
                    pending_wait = .none;
                    return null;
                },
                .pending => return true, // 1 フレーム駆動
            }
        },
    }
}

const PredicateEval = enum { pass, fail, pending };

fn evalPendingPredicate() PredicateEval {
    const p = switch (pending_wait) {
        .predicate => |x| x,
        else => return .fail,
    };
    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    switch (digestPayload(p.expr.probe, &buf)) {
        .unavailable => {
            // unavailable は成立扱いにしない
            if (p.timeout_frames == 0 or frame_index >= p.start_frame + p.timeout_frames) {
                pending_pred_actual_buf_set("unavailable");
                return .fail;
            }
            return .pending;
        },
        .ok => |payload| {
            if (evalExpect(payload, p.expr)) return .pass;
            if (p.timeout_frames == 0 or frame_index >= p.start_frame + p.timeout_frames) {
                pending_pred_actual_buf_set(payload);
                return .fail;
            }
            return .pending;
        },
    }
}

// predicate fail 時の actual 表示用（digest payload は stack。短い理由を保持）
var pending_pred_actual_storage: [DIGEST_BUF_LEN]u8 = undefined;
var pending_pred_actual_len: usize = 0;

fn pending_pred_actual_buf_set(s: []const u8) void {
    const n = @min(s.len, pending_pred_actual_storage.len);
    @memcpy(pending_pred_actual_storage[0..n], s[0..n]);
    pending_pred_actual_len = n;
}

fn pendingPredicateExprText() []const u8 {
    return switch (pending_wait) {
        .predicate => |p| p.expr_text,
        else => "",
    };
}

fn pendingPredicateActual() ?[]const u8 {
    if (pending_pred_actual_len == 0) return null;
    return pending_pred_actual_storage[0..pending_pred_actual_len];
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

/// 当該フレームの synthetic MIDI event を1件返す。FIFO が尽きたら次フレーム用に reset する。
pub fn nextMidiEvent() ?MidiEvent {
    if (midi_read < midi_count) {
        const ev = midi_buf[midi_read];
        midi_read += 1;
        return ev;
    }
    midi_read = 0;
    midi_count = 0;
    return null;
}

/// harness 注入 composition の latest-wins snapshot。commit/cancel 後も最新 revision を返す。
pub fn getCompositionSnapshot(buf: []u8) CompositionSnapshot {
    const n = @min(composition_len, buf.len);
    @memcpy(buf[0..n], composition_text[0..n]);
    return .{
        .text = buf[0..n],
        .revision = composition_revision,
        .cursor = @intCast(@min(composition_cursor, n)),
    };
}

/// native(OS) イベントの取捨。replay 決定性のため quit のみ通し、他の OS 入力は捨てる。
pub fn filterNativeEvent(ev: Event) ?Event {
    return switch (ev) {
        .quit => ev,
        else => null,
    };
}

/// facade `Window.getGamepadState` の5つ目のチョークポイント（TASK-80.1）。index 範囲外は null。
/// イベント時のみ更新される state を読むだけ（alloc/lock 無し。ホットパスではない。ADR-009 参照）。
pub fn getGamepadState(index: u8) ?GamepadState {
    if (index >= gamepad_states.len) return null;
    return gamepad_states[index];
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
/// `VP_HARNESS_SKIP_FRAME_COPY=1`（計測専用モード）時は copy をスキップし frame_index のみ進める
/// （fb/canvas 等の snapshot/digest は無効値になるが、fps 計測に使う `digest stats` の frame は増分する）。
pub fn onPresent() void {
    if (skip_frame_copy) {
        lock_valid = false;
        frame_index += 1;
        return;
    }
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
// live transport
// ============================================================================

fn livePollTimeoutMs() i32 {
    return test_live_poll_timeout_ms orelse live_poll_timeout_default_ms;
}

fn runNativePump(pump: ?NativePump) bool {
    const p = pump orelse return true;
    return p.poll();
}

/// fd が readable になるまで poll し、timeout ごとに native pump を回す。
/// `false` = pump が window close を報告、または fd エラー。
fn waitFdReadable(fd: net.Socket.Handle, pump: ?NativePump) bool {
    switch (comptime builtin.os.tag) {
        .windows => unreachable,
        else => return waitFdReadablePosix(fd, pump),
    }
}

fn waitFdReadablePosix(fd: net.Socket.Handle, pump: ?NativePump) bool {
    const events: i16 = posix.POLL.IN | posix.POLL.ERR | posix.POLL.HUP;
    while (true) {
        var pfds = [_]posix.pollfd{.{
            .fd = fd,
            .events = events,
            .revents = 0,
        }};
        const n = posix.poll(&pfds, livePollTimeoutMs()) catch return false;
        if (n == 0) {
            if (!runNativePump(pump)) return false;
            continue;
        }
        const revents = pfds[0].revents;
        if (revents & (posix.POLL.ERR | posix.POLL.NVAL) != 0) return false;
        // POLLHUP は half-close 後の残データ読み取りに使う（IN と同時/単独どちらも read 試行）。
        if (revents & (posix.POLL.IN | posix.POLL.HUP) != 0) return true;
    }
}

fn waitListenerReadable(pump: ?NativePump) bool {
    return waitFdReadable(server.socket.handle, pump);
}

const ReadLiveRequestError = error{
    ReadFailed,
    RequestTooLarge,
};

fn readLiveRequestBody(stream: net.Stream, pump: ?NativePump) ReadLiveRequestError![]u8 {
    var acc: std.ArrayList(u8) = .empty;
    errdefer acc.deinit(gpa);

    var rbuf: [4096]u8 = undefined;
    const fd = stream.socket.handle;
    const limit: usize = 1 << 20;

    while (true) {
        if (!waitFdReadable(fd, pump)) return error.ReadFailed;
        var bufs = [_][]u8{rbuf[0..]};
        const n = io_val.vtable.netRead(io_val.userdata, fd, bufs[0..]) catch return error.ReadFailed;
        if (n == 0) break;
        if (acc.items.len + n > limit) return error.RequestTooLarge;
        acc.appendSlice(gpa, rbuf[0..n]) catch return error.ReadFailed;
    }
    return acc.toOwnedSlice(gpa) catch error.ReadFailed;
}

/// 1接続を accept し、リクエスト全体（client の half-close まで）を読み込んで cmd_buf に載せる。
/// 戻り false = accept 不能（server 終了）→ アプリ終了。
fn acceptLiveRequest(pump: ?NativePump) bool {
    const use_poll = pump != null and builtin.os.tag != .windows;

    while (true) {
        const stream = if (use_poll) blk: {
            if (!waitListenerReadable(pump)) return false;
            break :blk server.accept(io_val) catch |err| {
                std.debug.print("[harness] accept 失敗: {s}\n", .{@errorName(err)});
                return false;
            };
        } else server.accept(io_val) catch |err| {
            std.debug.print("[harness] accept 失敗: {s}\n", .{@errorName(err)});
            return false;
        };
        live_stream = stream;
        live_req_open = true;
        live_stream_owned = true;
        resp_buf.clearRetainingCapacity();

        const bytes = if (use_poll) blk: {
            break :blk readLiveRequestBody(stream, pump) catch |err| {
                switch (err) {
                    ReadLiveRequestError.RequestTooLarge => appendResp("error: request too large\n"),
                    else => appendResp("error: request read failed\n"),
                }
                std.debug.print("[harness] request read 失敗: {s}\n", .{@errorName(err)});
                finishLiveRequest();
                continue;
            };
        } else blk: {
            var rbuf: [4096]u8 = undefined;
            var reader = stream.reader(io_val, &rbuf);
            break :blk reader.interface.allocRemaining(gpa, std.Io.Limit.limited(1 << 20)) catch |err| {
                std.debug.print("[harness] request read 失敗: {s}\n", .{@errorName(err)});
                appendResp("error: request read failed\n");
                finishLiveRequest();
                continue;
            };
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
    pending_wait = .none;
    if (live_stream_owned) {
        var wbuf: [4096]u8 = undefined;
        var writer = live_stream.writer(io_val, &wbuf);
        writer.interface.writeAll(resp_buf.items) catch {};
        writer.interface.flush() catch {};
        live_stream.close(io_val);
        live_stream_owned = false;
    }
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
        const extras = parseKeyExtras(it) orelse return warnLine("inject: 不明な修飾子または repeat");
        const ke = KeyEvent{ .key = kc, .is_repeat = extras.repeat, .modifiers = extras.modifiers };
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
    } else if (std.mem.eql(u8, kind, "char")) {
        // 確定テキスト文字を注入（TASK-22）。arg は「単一文字リテラル」か「0x/U+ 始まりの16進 codepoint」。
        // 単一数字（例 5）は文字 '5'(=53) 扱い＝制御文字との曖昧回避（decimal codepoint は非対応）。
        const arg = it.next() orelse return warnLine("inject char: 引数不足");
        const cp = parseCodepoint(arg) orelse return warnLine("inject char: codepoint/文字 不正");
        const mods = parseModifiers(it) orelse return warnLine("inject: 不明な修飾子");
        queue(Event{ .char_input = .{ .codepoint = cp, .modifiers = mods } });
    } else if (std.mem.eql(u8, kind, "midi")) {
        const event_kind = it.next() orelse return warnLine("inject midi: event 種別不足");
        if (std.mem.eql(u8, event_kind, "note_on") or std.mem.eql(u8, event_kind, "note_off")) {
            const note = parseMidiValue(it.next()) orelse return warnLine("inject midi note: note は0..127");
            const velocity = parseMidiValue(it.next()) orelse return warnLine("inject midi note: velocity は0..127");
            if (it.next() != null) return warnLine("inject midi note: 引数過多");
            const event: MidiEvent = if (std.mem.eql(u8, event_kind, "note_on") and velocity != 0)
                .{ .note_on = .{ .device_id = 0, .note = note, .velocity = velocity } }
            else
                .{ .note_off = .{ .device_id = 0, .note = note, .velocity = velocity } };
            if (!queueMidi(event)) return;
            applyMidiState(event);
        } else if (std.mem.eql(u8, event_kind, "cc")) {
            const controller = parseMidiValue(it.next()) orelse return warnLine("inject midi cc: controller は0..127");
            const value = parseMidiValue(it.next()) orelse return warnLine("inject midi cc: value は0..127");
            if (it.next() != null) return warnLine("inject midi cc: 引数過多");
            const event: MidiEvent = .{ .cc = .{ .device_id = 0, .controller = controller, .value = value } };
            if (!queueMidi(event)) return;
            applyMidiState(event);
        } else {
            return warnLine("inject midi: 不明な event");
        }
    } else if (std.mem.eql(u8, kind, "commit")) {
        // IME 確定テキスト列を注入（TASK-79.6.1）。残りの行を UTF-8 とみなし codepoint 分解して
        // char_input を連続 queue（実 IME の insertText と同じ消費経路）。modifiers は空。
        //
        // 空白: `it.rest()` は先頭 delimiter を全部飛ばすため、トークン直後の raw を使う。
        // next() 後の index は "commit" 直後（区切り空白上）。区切りは 1 個だけ落とし、
        // その後ろは空白込みでそのまま注入（record→replay 対称。codex 修正 D）。
        var text = it.buffer[it.index..];
        if (text.len > 0 and (text[0] == ' ' or text[0] == '\t')) text = text[1..];
        if (text.len > 0 and text[text.len - 1] == '\r') text = text[0 .. text.len - 1];
        if (text.len == 0) {
            if (!composition_active) return warnLine("inject commit: update 前は no-op");
            clearComposition(.commit);
            return;
        }

        const has_composition = composition_active;

        // Pass 1: 全量検証してから Pass 2 で queue（途中失敗で部分注入しない。codex 修正 C）。
        if (!std.unicode.utf8ValidateSlice(text)) return warnLine("inject commit: 不正 UTF-8");
        {
            var i: usize = 0;
            while (i < text.len) {
                const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
                    return warnLine("inject commit: 不正 UTF-8");
                };
                const cp = std.unicode.utf8Decode(text[i..][0..seq_len]) catch {
                    return warnLine("inject commit: 不正 UTF-8");
                };
                // parseCodepoint と同フィルタ（印字可能スカラーのみ。制御/surrogate/範囲外は拒否）。
                if (cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) or cp < 0x20 or cp == 0x7f) {
                    return warnLine("inject commit: 非印字 codepoint");
                }
                i += seq_len;
            }
        }
        // composition 中だけ commit event を出し snapshot を空にする。bare commit は
        // TASK-79.6.1 の後方互換契約どおり、composition 状態を変更せず char_input のみ積む。
        if (has_composition) clearComposition(.commit);

        // Pass 2: 検証済みのみ queue
        {
            var i: usize = 0;
            while (i < text.len) {
                const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch unreachable;
                const cp = std.unicode.utf8Decode(text[i..][0..seq_len]) catch unreachable;
                queue(Event{ .char_input = .{ .codepoint = cp, .modifiers = .{} } });
                i += seq_len;
            }
        }
    } else if (std.mem.eql(u8, kind, "composition")) {
        const phase = it.next() orelse return warnLine("inject composition: phase 不足");
        if (std.mem.eql(u8, phase, "update")) {
            const cursor_arg = parseUsize(it.next()) orelse return warnLine("inject composition update: cursor 不正");
            var text = it.buffer[it.index..];
            if (text.len > 0 and (text[0] == ' ' or text[0] == '\t')) text = text[1..];
            if (text.len > 0 and text[text.len - 1] == '\r') text = text[0 .. text.len - 1];
            if (!std.unicode.utf8ValidateSlice(text)) return warnLine("inject composition update: 不正 UTF-8");
            const n = utf8SafePrefixLen(text, COMPOSITION_CAP);
            @memcpy(composition_text[0..n], text[0..n]);
            composition_len = n;
            composition_cursor = clampUtf8Offset(composition_text[0..n], cursor_arg);
            const phase_value: CompositionPhase = if (composition_active) .update else .start;
            composition_active = true;
            enqueueComposition(phase_value);
        } else if (std.mem.eql(u8, phase, "cancel")) {
            if (!composition_active) return warnLine("inject composition cancel: update 前は no-op");
            clearComposition(.cancel);
        } else {
            warnLine("inject composition: phase は update/cancel");
        }
    } else if (std.mem.eql(u8, kind, "file_drop")) {
        // TASK-113.4: `inject file_drop <path>`。file_drop token 直後の区切り空白 1 個だけ落とし、
        // 残り全体を 1 path として扱う（内部空白・末尾空白は保持。引用符は特別扱いしない）。
        // `;`/改行は既存コマンド区切りなので path 中では使用不可。
        var path = it.buffer[it.index..];
        if (path.len > 0 and (path[0] == ' ' or path[0] == '\t')) path = path[1..];
        if (path.len > 0 and path[path.len - 1] == '\r') path = path[0 .. path.len - 1];
        it.index = it.buffer.len; // remainder を消費済みにする
        const drop = types.makeFileDropEventFromPath(path) orelse {
            return warnLine("inject file_drop: 不正な path（空/NUL/UTF-8/上限超過）");
        };
        queue(Event{ .file_drop = drop });
    } else if (std.mem.eql(u8, kind, "gamepad_connect")) {
        const idx = parseGamepadIndex(it.next()) orelse return warnLine("inject gamepad_connect: index 不正");
        const raw_name = std.mem.trim(u8, it.rest(), " \t"); // 残り全体を name として使う（TASK-22 char と同系統）
        var info = GamepadInfo{ .index = idx };
        const n = @min(raw_name.len, GAMEPAD_NAME_MAX);
        @memcpy(info.name_buf[0..n], raw_name[0..n]);
        info.name_len = @intCast(n);
        gamepad_states[idx] = .{}; // 既定 state（全ボタン off / stick 0 / trigger 0）
        queue(Event{ .gamepad_connected = info });
    } else if (std.mem.eql(u8, kind, "gamepad_disconnect")) {
        const idx = parseGamepadIndex(it.next()) orelse return warnLine("inject gamepad_disconnect: index 不正");
        gamepad_states[idx] = null;
        queue(Event{ .gamepad_disconnected = .{ .index = idx } });
    } else if (std.mem.eql(u8, kind, "gamepad_button")) {
        const idx = parseGamepadIndex(it.next()) orelse return warnLine("inject gamepad_button: index 不正");
        const btn = parseGamepadButton(it.next()) orelse return warnLine("inject gamepad_button: 不明なボタン");
        const v = parseUsize(it.next()) orelse return warnLine("inject gamepad_button: 値不正（0|1）");
        if (v != 0 and v != 1) return warnLine("inject gamepad_button: 値は0か1");
        if (gamepad_states[idx] == null) return warnLine("inject gamepad_button: pad 未接続");
        gamepad_states[idx].?.buttons.set(btn, v == 1);
    } else if (std.mem.eql(u8, kind, "gamepad_axis")) {
        const idx = parseGamepadIndex(it.next()) orelse return warnLine("inject gamepad_axis: index 不正");
        const axis = it.next() orelse return warnLine("inject gamepad_axis: axis 不足");
        const v = parseF32(it.next()) orelse return warnLine("inject gamepad_axis: 値不正");
        if (gamepad_states[idx] == null) return warnLine("inject gamepad_axis: pad 未接続");
        if (!setGamepadAxis(&gamepad_states[idx].?, axis, v)) return warnLine("inject gamepad_axis: 不明な axis または値域外");
    } else {
        warnLine("inject: 不明な種別");
    }
}

const KeyExtras = struct { modifiers: ModifierFlags, repeat: bool };

/// key 注入だけは modifier に加えて `repeat` トークンを受け付ける。
fn parseKeyExtras(it: *Tok) ?KeyExtras {
    var result: KeyExtras = .{ .modifiers = .{}, .repeat = false };
    while (it.next()) |tok| {
        var buf: [16]u8 = undefined;
        if (tok.len == 0 or tok.len > buf.len) return null;
        for (tok, 0..) |c, i| buf[i] = std.ascii.toLower(c);
        const name = buf[0..tok.len];
        if (std.mem.eql(u8, name, "repeat")) {
            result.repeat = true;
        } else if (std.mem.eql(u8, name, "shift")) {
            result.modifiers.shift = true;
        } else if (std.mem.eql(u8, name, "ctrl")) {
            result.modifiers.ctrl = true;
        } else if (std.mem.eql(u8, name, "alt")) {
            result.modifiers.alt = true;
        } else if (std.mem.eql(u8, name, "cmd")) {
            result.modifiers.cmd = true;
        } else return null;
    }
    return result;
}

fn enqueueComposition(phase: CompositionPhase) void {
    composition_revision +%= 1;
    queue(Event{ .composition_changed = .{
        .revision = composition_revision,
        .phase = phase,
        .cursor = @intCast(composition_cursor),
    } });
}

fn clearComposition(phase: CompositionPhase) void {
    composition_len = 0;
    composition_cursor = 0;
    composition_active = false;
    enqueueComposition(phase);
}

fn utf8SafePrefixLen(text: []const u8, cap: usize) usize {
    var n = @min(text.len, cap);
    while (n > 0 and n < text.len and (text[n] & 0xC0) == 0x80) : (n -= 1) {}
    return n;
}

fn clampUtf8Offset(text: []const u8, offset: usize) usize {
    var n = @min(offset, text.len);
    while (n > 0 and n < text.len and (text[n] & 0xC0) == 0x80) : (n -= 1) {}
    return n;
}

/// gamepad index トークンを parse する（0..MAX_GAMEPADS-1 のみ有効）。
fn parseGamepadIndex(tok: ?[]const u8) ?u8 {
    const v = parseUsize(tok) orelse return null;
    if (v >= MAX_GAMEPADS) return null;
    return @intCast(v);
}

/// MIDI の 7-bit 値を parse する。clamp はせず、範囲外を reject する。
fn parseMidiValue(tok: ?[]const u8) ?u8 {
    const v = parseUsize(tok) orelse return null;
    if (v > 127) return null;
    return @intCast(v);
}

/// gamepad button 名トークンを parse する（大小無視。GamepadButton の宣言名と一致）。
fn parseGamepadButton(tok: ?[]const u8) ?GamepadButton {
    const name = tok orelse return null;
    var buf: [24]u8 = undefined;
    if (name.len == 0 or name.len > buf.len) return null;
    for (name, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return std.meta.stringToEnum(GamepadButton, buf[0..name.len]);
}

/// `inject gamepad_axis` の axis 名 + 値を state へ反映する。
/// 値域は raw 値契約を守るため reject（clamp しない）: stick(left_x/left_y/right_x/right_y) は
/// [-1,1]、trigger(left_trigger/right_trigger) は [0,1]。不明 axis 名 or 値域外は false（state 不変）。
/// NaN/inf は `v < lo or v > hi` の比較が両方 false になり素通りしてしまうため、先頭で明示的に
/// reject する（codex レビューで発見。fail-fast の抜け穴を塞ぐ）。
fn setGamepadAxis(state: *GamepadState, axis: []const u8, v: f32) bool {
    if (!std.math.isFinite(v)) return false;
    var buf: [16]u8 = undefined;
    if (axis.len == 0 or axis.len > buf.len) return false;
    for (axis, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const name = buf[0..axis.len];
    if (std.mem.eql(u8, name, "left_x")) {
        if (v < -1 or v > 1) return false;
        state.left_stick.x = v;
    } else if (std.mem.eql(u8, name, "left_y")) {
        if (v < -1 or v > 1) return false;
        state.left_stick.y = v;
    } else if (std.mem.eql(u8, name, "right_x")) {
        if (v < -1 or v > 1) return false;
        state.right_stick.x = v;
    } else if (std.mem.eql(u8, name, "right_y")) {
        if (v < -1 or v > 1) return false;
        state.right_stick.y = v;
    } else if (std.mem.eql(u8, name, "left_trigger")) {
        if (v < 0 or v > 1) return false;
        state.left_trigger = v;
    } else if (std.mem.eql(u8, name, "right_trigger")) {
        if (v < 0 or v > 1) return false;
        state.right_trigger = v;
    } else return false;
    return true;
}

/// `inject char` の引数を UTF-32 codepoint へ。0x.. / U+.. は16進、それ以外は単一 UTF-8 文字として
/// その codepoint を返す（2文字以上・不正 UTF-8 は null）。decimal は非対応（単一数字を文字扱いにするため）。
fn parseCodepoint(tok: []const u8) ?u32 {
    if (tok.len == 0) return null;
    const hex: ?[]const u8 = if (std.mem.startsWith(u8, tok, "0x") or std.mem.startsWith(u8, tok, "0X"))
        tok[2..]
    else if (std.mem.startsWith(u8, tok, "U+") or std.mem.startsWith(u8, tok, "u+"))
        tok[2..]
    else
        null;
    const cp: u32 = if (hex) |h| blk: {
        if (h.len == 0) return null;
        break :blk std.fmt.parseInt(u32, h, 16) catch return null;
    } else blk: {
        // 単一 UTF-8 文字（token 全体がちょうど1 codepoint のときだけ採用）。
        const seq_len = std.unicode.utf8ByteSequenceLength(tok[0]) catch return null;
        if (seq_len != tok.len) return null;
        break :blk std.unicode.utf8Decode(tok) catch return null;
    };
    // native backend が実際に出す「印字可能な Unicode スカラー値」に限定する（codex 指摘）:
    // surrogate(0xD800-0xDFFF)・範囲外(>0x10FFFF)・制御文字(<0x20 / 0x7f) は replay で作れないよう拒否。
    if (cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) return null;
    if (cp < 0x20 or cp == 0x7f) return null;
    return cp;
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
    } else if (std.mem.eql(u8, probe, "capabilities")) {
        const path = path_arg orelse (std.fmt.bufPrint(&path_buf, "{s}/capabilities_{d}.json", .{ out_dir, frame_index }) catch return warnLine("snapshot: path 生成失敗"));
        const json = formatCapabilitiesPayload(&capabilities_buf);
        std.Io.Dir.cwd().writeFile(io_val, .{ .sub_path = path, .data = json }) catch |err| {
            std.debug.print("[harness] snapshot capabilities 失敗 {s}: {s}\n", .{ path, @errorName(err) });
            return;
        };
        emitSnapshot("capabilities", path, "json");
    } else if (std.mem.eql(u8, probe, "capture")) {
        if (synth_video) |*dev| {
            const frame = dev.renderFrame(frame_index);
            const path = path_arg orelse (std.fmt.bufPrint(&path_buf, "{s}/capture_{d}.png", .{ out_dir, frame_index }) catch return warnLine("snapshot: path 生成失敗"));
            png.savePNG(io_val, path, frame.pixels, frame.width, frame.height, gpa) catch |err| {
                std.debug.print("[harness] snapshot capture 失敗 {s}: {s}\n", .{ path, @errorName(err) });
                return;
            };
            var info_buf: [32]u8 = undefined;
            const info = std.fmt.bufPrint(&info_buf, "{d}x{d}", .{ frame.width, frame.height }) catch "?";
            emitSnapshot("capture", path, info);
        } else {
            warnLine("snapshot capture: video 未 open → skip");
        }
    } else if (std.mem.eql(u8, probe, "gamepad")) {
        const path = path_arg orelse (std.fmt.bufPrint(&path_buf, "{s}/gamepad_{d}.txt", .{ out_dir, frame_index }) catch return warnLine("snapshot: path 生成失敗"));
        var buf: [DIGEST_BUF_LEN]u8 = undefined;
        const payload = formatGamepadPayload(&buf);
        std.Io.Dir.cwd().writeFile(io_val, .{ .sub_path = path, .data = payload }) catch |err| {
            std.debug.print("[harness] snapshot gamepad 失敗 {s}: {s}\n", .{ path, @errorName(err) });
            return;
        };
        emitSnapshot("gamepad", path, "txt");
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

// ============================================================================
// capabilities probe（登録済み probe・action の内省列挙。TASK-62.4）
//
// ホットパス宣言: イベント/接続時のみ（digest/snapshot コマンド処理時に固定長 registry
// （最大 probe 16 + action 16 + 組み込み 6 = 38 件）を1回走査するだけ。フレーム毎・毎サンプルでは
// 走らない）。RT 共有状態には触れない（main スレッドの固定長 registry 読みのみ）。
//
// 中身非解釈の不変条件: name/ext/desc と snapshot/digest の**有無**（callback が non-null か）を
// 登録情報からそのまま転記するだけ。callback 自体は絶対に呼ばない。
// ============================================================================

/// capabilities JSON の組み立て先（単一プロセス debug facility の再利用スクラッチ。
/// audio_scratch/port_file_buf と同型で単一 main スレッド逐次実行のため競合なし）。
var capabilities_buf: [16 * 1024]u8 = undefined;

/// `formatCapabilitiesPayload` が「常に valid JSON を返す」契約を満たすために要求する最小 buf 長。
/// これ未満の buf を渡すのは呼び出し側のバグなので assert で落とす（capabilities_buf・テストの
/// 明示的な buf は常にこれ以上）。
const MIN_CAPABILITIES_BUF_LEN = 128;
/// 末尾のクロージング専用に予約するバイト数。最大想定クロージング文字列
/// `],"actions":[],"truncated":true}`（34B）に対し余裕を持たせる。
const CAPABILITIES_RESERVED_TAIL = 64;

const CapabilityBuiltin = struct {
    name: []const u8,
    ext: []const u8,
    snapshot: bool = true,
    digest: bool = true,
    desc: []const u8,
};
const CAPABILITY_BUILTINS = [_]CapabilityBuiltin{
    .{ .name = "fb", .ext = "png", .desc = "framebuffer PNG/digest" },
    .{ .name = "audio", .ext = "wav", .desc = "audio tap PCM16 WAV / rms・peak・f0・silent / band・centroid・onsets・lufs" },
    .{ .name = "stats", .ext = "json", .desc = "EventStats + 仮想fps JSON" },
    .{ .name = "capabilities", .ext = "json", .desc = "登録済み probe・action の内省列挙" },
    .{ .name = "capture", .ext = "png", .desc = "synthetic mic/camera capture: video PNG snapshot + video/audio state digest" },
    .{ .name = "gamepad", .ext = "txt", .desc = "gamepad state: connected mask + per-pad buttons/sticks/triggers" },
    .{ .name = "midi", .ext = "txt", .snapshot = false, .digest = true, .desc = "MIDI state: device 0 pressed-note bitset + controller values" },
};

/// `s` を `buf[len.*..limit)` に収まる場合のみ書き込む。収まらなければ何も書かず false を返す
/// （書きかけの半端なバイト列を残さない）。**`len`/`limit` は常に `buf` 全体を基準にした絶対
/// オフセット**として扱う（呼び出し元で `buf` 自体をスライスして渡さないこと。`len` がフェーズを
/// またいで大きい `limit`（tail 領域）まで進むことがあるため、`buf` を切り詰めた別スライスと
/// 座標系が食い違うと `limit - len` が負に振れて overflow panic する。実装中に実際にこの形の
/// バグを踏んだので、契約として明記する）。
fn appendRaw(buf: []u8, limit: usize, len: *usize, s: []const u8) bool {
    if (limit < len.* or limit - len.* < s.len) return false;
    @memcpy(buf[len.*..][0..s.len], s);
    len.* += s.len;
    return true;
}

/// 1 個の ArgSpec を JSON object として追記する（非デフォルト値のみ emit。TASK-88.1）。
/// 中身非解釈: 登録済み文字列をそのまま転記するだけ。
fn appendArgSpecEntry(buf: []u8, limit: usize, len: *usize, s: ArgSpec) bool {
    if (containsUnsafeJsonChar(s.name) or containsUnsafeJsonChar(s.kind) or
        containsUnsafeJsonChar(s.pattern) or containsUnsafeJsonChar(s.desc)) return false;
    for (s.values) |v| {
        if (containsUnsafeJsonChar(v)) return false;
    }
    var scratch: [512]u8 = undefined;
    const head = std.fmt.bufPrint(&scratch, "{{\"name\":\"{s}\",\"kind\":\"{s}\"", .{ s.name, s.kind }) catch return false;
    if (!appendRaw(buf, limit, len, head)) return false;
    if (s.min) |m| {
        const part = std.fmt.bufPrint(&scratch, ",\"min\":{d}", .{m}) catch return false;
        if (!appendRaw(buf, limit, len, part)) return false;
    }
    if (s.max) |m| {
        const part = std.fmt.bufPrint(&scratch, ",\"max\":{d}", .{m}) catch return false;
        if (!appendRaw(buf, limit, len, part)) return false;
    }
    if (s.values.len > 0) {
        if (!appendRaw(buf, limit, len, ",\"values\":[")) return false;
        for (s.values, 0..) |v, i| {
            if (i > 0 and !appendRaw(buf, limit, len, ",")) return false;
            const part = std.fmt.bufPrint(&scratch, "\"{s}\"", .{v}) catch return false;
            if (!appendRaw(buf, limit, len, part)) return false;
        }
        if (!appendRaw(buf, limit, len, "]")) return false;
    }
    if (s.pattern.len > 0) {
        const part = std.fmt.bufPrint(&scratch, ",\"pattern\":\"{s}\"", .{s.pattern}) catch return false;
        if (!appendRaw(buf, limit, len, part)) return false;
    }
    if (s.optional and !appendRaw(buf, limit, len, ",\"optional\":true")) return false;
    if (s.variadic and !appendRaw(buf, limit, len, ",\"variadic\":true")) return false;
    if (s.desc.len > 0) {
        const part = std.fmt.bufPrint(&scratch, ",\"desc\":\"{s}\"", .{s.desc}) catch return false;
        if (!appendRaw(buf, limit, len, part)) return false;
    }
    return appendRaw(buf, limit, len, "}");
}

/// `args != null` のときだけ `,"args":[...]` を追記する（null は呼び出し側でスキップ＝従来 bit 一致）。
fn appendArgsField(buf: []u8, limit: usize, len: *usize, args: []const ArgSpec) bool {
    if (!appendRaw(buf, limit, len, ",\"args\":[")) return false;
    for (args, 0..) |s, i| {
        if (i > 0 and !appendRaw(buf, limit, len, ",")) return false;
        if (!appendArgSpecEntry(buf, limit, len, s)) return false;
    }
    return appendRaw(buf, limit, len, "]");
}

/// 1 probe エントリを `buf[0..limit)`（`len` 経由）へ追記する。name/ext に JSON を破損させる
/// 文字が含まれる、またはエントリが収まらない場合は何も書かず false を返す（呼び出し元が
/// truncated フラグを立てる）。中身非解釈: 値をそのまま転記するだけで callback は呼ばない。
/// `args != null` のときのみ `"args":[...]` を追記（TASK-88.1。フィールド追加のみ）。
fn appendProbeEntry(buf: []u8, limit: usize, len: *usize, name: []const u8, ext: []const u8, has_snapshot: bool, has_digest: bool, desc: []const u8, args: ?[]const ArgSpec) bool {
    if (containsUnsafeJsonChar(name) or containsUnsafeJsonChar(ext) or containsUnsafeJsonChar(desc)) return false;
    var scratch: [768]u8 = undefined;
    const head = std.fmt.bufPrint(&scratch, "{{\"name\":\"{s}\",\"ext\":\"{s}\",\"snapshot\":{},\"digest\":{},\"desc\":\"{s}\"", .{ name, ext, has_snapshot, has_digest, desc }) catch return false;
    if (!appendRaw(buf, limit, len, head)) return false;
    if (args) |as| {
        if (!appendArgsField(buf, limit, len, as)) return false;
    }
    return appendRaw(buf, limit, len, "}");
}

/// `appendProbeEntry` の action 版（`ext`/`snapshot`/`digest` フィールドが無い）。
/// `args != null` のときのみ `"args":[...]` を追記（TASK-88.1。null は従来と bit 一致）。
fn appendActionEntry(buf: []u8, limit: usize, len: *usize, name: []const u8, desc: []const u8, args: ?[]const ArgSpec) bool {
    if (containsUnsafeJsonChar(name) or containsUnsafeJsonChar(desc)) return false;
    var scratch: [768]u8 = undefined;
    const head = std.fmt.bufPrint(&scratch, "{{\"name\":\"{s}\",\"desc\":\"{s}\"", .{ name, desc }) catch return false;
    if (!appendRaw(buf, limit, len, head)) return false;
    if (args) |as| {
        if (!appendArgsField(buf, limit, len, as)) return false;
    }
    return appendRaw(buf, limit, len, "}");
}

/// 登録済み probe（組み込み7件 + custom 登録順）・action（登録順）を JSON 1行で列挙する。
/// **常に valid JSON を返す**契約（`buf.len >= MIN_CAPABILITIES_BUF_LEN` が前提）。容量超過や
/// name/ext の不正文字でエントリを省略した場合は末尾に `"truncated":true` を付与する。
fn formatCapabilitiesPayload(buf: []u8) []const u8 {
    std.debug.assert(buf.len >= MIN_CAPABILITIES_BUF_LEN);
    // content_limit: エントリ/区切りを書いてよい範囲。buf.len: クロージング（"]" 等）を書いてよい範囲
    // （末尾 CAPABILITIES_RESERVED_TAIL 分の余裕）。`len` は常に buf 全体基準の絶対オフセットなので、
    // フェーズによって limit を使い分けても座標系は矛盾しない（appendRaw 参照）。
    const content_limit = buf.len - CAPABILITIES_RESERVED_TAIL;
    var len: usize = 0;
    var truncated = false;

    _ = appendRaw(buf, content_limit, &len, "{\"probes\":[");
    var first = true;
    probes_blk: {
        for (CAPABILITY_BUILTINS) |b| {
            const saved_len = len; // entry 追記が失敗したら区切り "," ごとロールバックする（trailing comma 防止）
            if (!first and !appendRaw(buf, content_limit, &len, ",")) {
                len = saved_len;
                truncated = true;
                break :probes_blk;
            }
            if (!appendProbeEntry(buf, content_limit, &len, b.name, b.ext, b.snapshot, b.digest, b.desc, null)) {
                len = saved_len;
                truncated = true;
                break :probes_blk;
            }
            first = false;
        }
        for (probes[0..probe_count]) |p| {
            const saved_len = len;
            if (!first and !appendRaw(buf, content_limit, &len, ",")) {
                len = saved_len;
                truncated = true;
                break :probes_blk;
            }
            if (!appendProbeEntry(buf, content_limit, &len, p.name, p.ext, p.snapshot != null, p.digest != null, p.desc, p.args)) {
                len = saved_len;
                truncated = true;
                break :probes_blk;
            }
            first = false;
        }
    }
    _ = appendRaw(buf, buf.len, &len, "]"); // RESERVED_TAIL 予約分があるので必ず入る

    // "actions" セクションの開始自体が content_limit に収まらない可能性があるため戻り値を確認する
    // （収まらなければ probes 側で打ち切った場合と同じ扱いに倒す。codex レビューで発見。
    // これを確認せず進めると `,"actions":[` を書けないまま後段の `]` だけ追記して invalid JSON になる）。
    if (!truncated and appendRaw(buf, content_limit, &len, ",\"actions\":[")) {
        first = true;
        actions_blk: {
            var i: usize = 0;
            while (i < action_registry.actionCount()) : (i += 1) {
                const a = action_registry.actionAt(i).?;
                const saved_len = len;
                if (!first and !appendRaw(buf, content_limit, &len, ",")) {
                    len = saved_len;
                    truncated = true;
                    break :actions_blk;
                }
                if (!appendActionEntry(buf, content_limit, &len, a.name, a.desc, a.args)) {
                    len = saved_len;
                    truncated = true;
                    break :actions_blk;
                }
                first = false;
            }
        }
        _ = appendRaw(buf, buf.len, &len, "]"); // RESERVED_TAIL 予約分があるので必ず入る
    } else {
        truncated = true;
        _ = appendRaw(buf, buf.len, &len, ",\"actions\":[]"); // probes 側で打ち切った、または "actions":[ 自体が収まらない
    }

    if (truncated) _ = appendRaw(buf, buf.len, &len, ",\"truncated\":true");
    _ = appendRaw(buf, buf.len, &len, "}");
    return buf[0..len];
}

/// `formatCapabilitiesPayload` の pub wrapper（copilot の `digest capabilities` が使う。TASK-62.5.2）。
pub fn capabilitiesPayload(buf: []u8) []const u8 {
    return formatCapabilitiesPayload(buf);
}

/// digest 1行 payload の取得結果。`unavailable` は取得できない理由（静的文字列）を保持し、
/// digest コマンドの warn と expect/assert の `actual=` 表示の両方で診断性を保つ（TASK-78）。
const DigestResult = union(enum) {
    ok: []const u8,
    unavailable: []const u8,
};

/// probe 名から digest の1行 payload を返す（`digest` コマンドと `expect`/`assert` が共有）。
/// buf は payload の書き込み先。fb/stats/audio/custom いずれも収まるよう caller は `DIGEST_BUF_LEN` を渡す
/// （`capabilities` は渡された `buf` を使わず専用の `capabilities_buf`(16KB) を使う。custom probe/action
/// callback 向けの `DIGEST_BUF_LEN=1024` 契約とは別枠のため）。
/// 中身非解釈の不変条件は維持（framework は payload の意味を解釈しない）。
fn digestPayload(probe: []const u8, buf: []u8) DigestResult {
    if (std.mem.eql(u8, probe, "fb")) {
        if (!have_frame) return .{ .unavailable = "fb not presented" };
        return .{ .ok = formatFbPayload(buf) };
    } else if (std.mem.eql(u8, probe, "audio")) {
        return .{ .ok = formatAudioPayload(buf) };
    } else if (std.mem.eql(u8, probe, "stats")) {
        return .{ .ok = formatStatsPayload(buf) };
    } else if (std.mem.eql(u8, probe, "capabilities")) {
        return .{ .ok = formatCapabilitiesPayload(&capabilities_buf) };
    } else if (std.mem.eql(u8, probe, "capture")) {
        return .{ .ok = formatCapturePayload(buf) };
    } else if (std.mem.eql(u8, probe, "gamepad")) {
        return .{ .ok = formatGamepadPayload(buf) };
    } else if (std.mem.eql(u8, probe, "midi")) {
        return .{ .ok = formatMidiPayload(buf) };
    } else if (findProbe(probe)) |p| {
        const dg = p.digest orelse return .{ .unavailable = "digest unsupported" };
        return .{ .ok = dg(p.ctx, buf) };
    } else {
        return .{ .unavailable = "unknown probe" };
    }
}

fn handleDigest(it: *Tok) void {
    const probe = it.next() orelse return warnLine("digest: probe 名不足");
    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    switch (digestPayload(probe, &buf)) {
        .ok => |payload| emitDigest(probe, payload),
        .unavailable => |reason| warnLine(reason),
    }
}

// ============================================================================
// action（probe 対称の高レベル操作。TASK-62.1）
//
// 文法（replay/live 共通）: action <name> [args...]
//   args は <name> の後の残り行 raw テキスト（trim 済み・再トークン化しない = 中身非解釈）。
//   framework は name lookup と run() 呼び出しのみ行う（probe と同じ不変条件）。
//
// 失敗（名前欠落・未知 action・run() エラー）は expect/assert（TASK-78）と同じ `expect_failures`
// カウンタに相乗りする（記帳して続行。assert 相当の即時 abort は無い）。EOF/quit/早期 return の
// 既存3経路（replayExitIfFailed）にタダ乗りするため、新規 exit 経路は追加しない。
// ============================================================================

/// `action` コマンド本体。`routeLocalAction` → 結果 emit のみ（args の解釈・再トークン化はしない）。
/// reportAction の wire 整形・expect_failures 記帳は不変（TASK-62.3.1）。
fn handleAction(it: *Tok) void {
    const name = it.next() orelse "";
    if (name.len == 0) return reportAction(false, "?", "missing action name");
    const args = std.mem.trim(u8, it.rest(), " \t");
    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    const result = action_registry.routeLocalAction(name, args, &buf) catch |err| {
        if (err == error.UnknownAction) return reportAction(false, name, "unknown action");
        return reportAction(false, name, @errorName(err));
    };
    reportAction(true, name, result);
}

/// `msg` を最初の `\r`/`\n` の手前で切る（callback が誤って複数行を返しても wire framing を守る。
/// 特に live の `fail ` 行頭スキャンを次行に誤爆させないための防御実装。中身の解釈ではない）。
fn firstLine(msg: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, msg, '\n');
    const cr = std.mem.indexOfScalar(u8, msg, '\r');
    const cut = @min(nl orelse msg.len, cr orelse msg.len);
    return msg[0..cut];
}

/// structured error の末尾サフィックス（未セット時は空 = 従来 bit 一致。TASK-62.5.9）。
/// ` code=<c> next=<n>`（先頭 space 付き）。next は空白可の残り全体。
fn actionErrorDetailSuffix(buf: []u8) []const u8 {
    const d = action_registry.actionErrorDetail() orelse return "";
    return std.fmt.bufPrint(buf, " code={s} next={s}", .{ d.code, d.next }) catch "";
}

/// action の合否を emit し、失敗を記帳する（replay=stderr / live=resp_buf）。
/// - replay 成功: `[harness] action <name> ok <msg>` / 失敗: `[harness] action <name> FAILED <msg>`
/// - live 成功  : `<name> <msg>`（bare。digest と同じ流儀） / 失敗: `fail <name> <msg>`（drive の
///   行頭スキャンに乗せるための接頭辞）
/// - 失敗時、app が `setActionErrorDetail` 済みなら末尾に ` code=<c> next=<n>` を追記（TASK-62.5.9。
///   未セット時は従来形式と bit 一致。行頭 `fail ` 不変 → scripts/drive の行頭スキャン無改修）
/// - 失敗時のみ `mode == .replay` なら `expect_failures` を加算する（assert 相当の即時 abort は無い）。
fn reportAction(pass: bool, name: []const u8, msg: []const u8) void {
    const line = firstLine(msg);
    var detail_buf: [action_registry.MAX_ERROR_CODE_LEN + action_registry.MAX_ERROR_NEXT_LEN + 16]u8 = undefined;
    const suffix = if (!pass) actionErrorDetailSuffix(&detail_buf) else "";
    if (mode == .live) {
        if (pass) {
            appendResp(name);
            appendResp(" ");
            appendResp(line);
        } else {
            appendResp("fail ");
            appendResp(name);
            appendResp(" ");
            appendResp(line);
            appendResp(suffix);
        }
        appendResp("\n");
    } else if (pass) {
        std.debug.print("[harness] action {s} ok {s}\n", .{ name, line });
    } else {
        std.debug.print("[harness] action {s} FAILED {s}{s}\n", .{ name, line, suffix });
    }

    if (!pass and mode == .replay) {
        expect_failures += 1;
    }
}

// ============================================================================
// synthetic capture source（偽 mic/camera。TASK-49.5）
//
// 文法（replay/live 共通）:
//   capture video open <w> <h> [fps]   # synthetic カメラを開く（既 open 済みなら閉じてから開き直す）
//   capture video close                # synthetic カメラを閉じる
//   capture audio open [sr] [ch] [hz]  # synthetic マイクを開いて即 start（既 open 済みなら開き直す）
//   capture audio close                # synthetic マイクを閉じる（stop+join+close）
//
// `isCaptureSyntheticActive()`（`VP_HARNESS_CAPTURE_SYNTHETIC` env + harness 有効時のみ true）が
// false の間はすべて fail-fast（warnLine のみ・状態変化なし。既存 `inject` の未知トークン処理と同じ
// 思想）。camera.zig/audio.zig への facade 配線は無い（`isCaptureSyntheticActive()` の doc comment
// 参照）。実装は `core/capture_synthetic.zig` に委譲し、ここでは harness state（`synth_video`/
// `synth_audio`）の所有・コマンドパース・probe payload 組み立てのみを行う。
//
// ホットパス宣言: イベント時のみ（コマンド処理時に1回。フレーム毎・毎サンプルではない）。
// ============================================================================

fn handleCapture(it: *Tok) void {
    if (!isCaptureSyntheticActive()) return warnLine("capture: VP_HARNESS_CAPTURE_SYNTHETIC 未設定または harness 無効のため使用不可");
    const domain = it.next() orelse return warnLine("capture: video|audio 不足");
    if (std.mem.eql(u8, domain, "video")) {
        handleCaptureVideo(it);
    } else if (std.mem.eql(u8, domain, "audio")) {
        handleCaptureAudio(it);
    } else {
        warnLine("capture: 不明な種別（video|audio）");
    }
}

fn handleCaptureVideo(it: *Tok) void {
    const verb = it.next() orelse return warnLine("capture video: open|close 不足");
    if (std.mem.eql(u8, verb, "open")) {
        const w = parseUsize(it.next()) orelse return warnLine("capture video open: width 不正");
        const h = parseUsize(it.next()) orelse return warnLine("capture video open: height 不正");
        const fps = parseUsize(it.next()) orelse 30;
        if (synth_video) |*dev| dev.close();
        synth_video = capture_synthetic.openVideo(gpa, .{
            .width = std.math.cast(u32, w) orelse return warnLine("capture video open: width 過大"),
            .height = std.math.cast(u32, h) orelse return warnLine("capture video open: height 過大"),
            .frame_rate = std.math.cast(u32, fps) orelse return warnLine("capture video open: fps 過大"),
        }) catch |err| {
            synth_video = null;
            std.debug.print("[harness] capture video open 失敗: {s}\n", .{@errorName(err)});
            return;
        };
    } else if (std.mem.eql(u8, verb, "close")) {
        if (synth_video) |*dev| {
            dev.close();
            synth_video = null;
        } else {
            warnLine("capture video close: 未 open");
        }
    } else {
        warnLine("capture video: 不明な操作（open|close）");
    }
}

fn noopCaptureAudioCallback(frame: capture_synthetic.AudioInFrame, userdata: ?*anyopaque) void {
    _ = frame;
    _ = userdata;
}

fn handleCaptureAudio(it: *Tok) void {
    const verb = it.next() orelse return warnLine("capture audio: open|close 不足");
    if (std.mem.eql(u8, verb, "open")) {
        const sr = parseUsize(it.next()) orelse 48000;
        const ch = parseUsize(it.next()) orelse 1;
        const hz = parseF32(it.next()) orelse 440.0;
        if (synth_audio) |dev| {
            dev.close();
            synth_audio = null;
        }
        var dev = capture_synthetic.openAudio(gpa, .{
            .sample_rate = std.math.cast(u32, sr) orelse return warnLine("capture audio open: sample_rate 過大"),
            .channels = std.math.cast(u32, ch) orelse return warnLine("capture audio open: channels 過大"),
            .frequency_hz = hz,
            .capture_callback = noopCaptureAudioCallback,
        }) catch |err| {
            std.debug.print("[harness] capture audio open 失敗: {s}\n", .{@errorName(err)});
            return;
        };
        dev.start() catch |err| {
            std.debug.print("[harness] capture audio start 失敗: {s}\n", .{@errorName(err)});
            dev.close();
            return;
        };
        synth_audio = dev;
    } else if (std.mem.eql(u8, verb, "close")) {
        if (synth_audio) |dev| {
            dev.close();
            synth_audio = null;
        } else {
            warnLine("capture audio close: 未 open");
        }
    } else {
        warnLine("capture audio: 不明な操作（open|close）");
    }
}

/// `capture` probe の digest payload（top-level key=value。expect/assert で照合可能）。
/// video/audio いずれも未 open なら該当フィールドは 0 を返す（key は常に存在させる）。
fn formatCapturePayload(buf: []u8) []u8 {
    const v_open: u8 = @intFromBool(synth_video != null);
    const v_w: u32 = if (synth_video) |d| d.width else 0;
    const v_h: u32 = if (synth_video) |d| d.height else 0;
    const a_open: u8 = @intFromBool(synth_audio != null);
    const a_frames: u64 = if (synth_audio) |d| d.framesGenerated() else 0;
    const a_peak: f32 = if (synth_audio) |d| d.lastPeak() else 0;
    return std.fmt.bufPrint(buf, "video_open={d} video_w={d} video_h={d} video_frame={d} audio_open={d} audio_frames={d} audio_peak={d:.4}", .{
        v_open, v_w, v_h, frame_index, a_open, a_frames, a_peak,
    }) catch buf[0..0];
}

// ============================================================================
// gamepad probe（組み込み。TASK-80.1。ADR-009）
//
// ホットパス宣言: digest/snapshot コマンド処理時のみ（イベント時のみ。フレーム毎ではない）。
// ============================================================================

/// `v` が数値上 0（`-0.0` 含む）なら正の `0.0` に正規化する。float format の `-0.0000` 表記ゆれを防ぎ
/// `expect`/`digest` を安定させる（ADR-009「harness state モデル」節）。
fn normalizeZero(v: f32) f32 {
    return if (v == 0) 0 else v;
}

/// `connected=<bitmask> p<idx>_buttons=<hex8> p<idx>_lx=.. p<idx>_ly=.. p<idx>_rx=.. p<idx>_ry=.. p<idx>_lt=.. p<idx>_rt=..`
/// （接続中の pad のみ列挙。top-level key=value を保つため pad ごとに `p<idx>_` prefix。float は固定4桁+
/// 負ゼロ正規化）。
fn formatGamepadPayload(buf: []u8) []u8 {
    var len: usize = 0;
    var mask: u32 = 0;
    for (gamepad_states, 0..) |st, i| {
        if (st != null) mask |= @as(u32, 1) << @intCast(i);
    }
    len += (std.fmt.bufPrint(buf[len..], "connected={d}", .{mask}) catch return buf[0..len]).len;
    for (gamepad_states, 0..) |maybe_st, i| {
        const st = maybe_st orelse continue;
        len += (std.fmt.bufPrint(buf[len..], " p{d}_buttons={X:0>8} p{d}_lx={d:.4} p{d}_ly={d:.4} p{d}_rx={d:.4} p{d}_ry={d:.4} p{d}_lt={d:.4} p{d}_rt={d:.4}", .{
            i, st.buttons.toC(),
            i, normalizeZero(st.left_stick.x),
            i, normalizeZero(st.left_stick.y),
            i, normalizeZero(st.right_stick.x),
            i, normalizeZero(st.right_stick.y),
            i, normalizeZero(st.left_trigger),
            i, normalizeZero(st.right_trigger),
        }) catch return buf[0..len]).len;
    }
    return buf[0..len];
}

// ============================================================================
// MIDI probe（組み込み。TASK-115.1・ADR-010）
//
// ホットパス宣言: digest コマンド処理時のみ（イベント時のみ）。固定長 state を走査するだけで、
// フレーム毎・RT 経路ではない。
// ============================================================================

fn appendMidiHexByte(buf: []u8, len: *usize, value: u8) bool {
    if (buf.len -| len.* < 2) return false;
    const digits = "0123456789ABCDEF";
    buf[len.*] = digits[value >> 4];
    buf[len.* + 1] = digits[value & 0x0F];
    len.* += 2;
    return true;
}

fn formatMidiPayload(buf: []u8) []u8 {
    var note_count: usize = 0;
    for (0..128) |note| {
        if ((midi_pressed[note / 8] & (@as(u8, 1) << @intCast(note % 8))) != 0) note_count += 1;
    }
    var cc_count: usize = 0;
    for (midi_cc_set) |set| {
        if (set) cc_count += 1;
    }

    var len = (std.fmt.bufPrint(buf, "midi device=0 note_count={d} notes=", .{note_count}) catch return buf[0..0]).len;
    for (midi_pressed) |byte| if (!appendMidiHexByte(buf, &len, byte)) return buf[0..len];
    len += (std.fmt.bufPrint(buf[len..], " cc_count={d} cc=", .{cc_count}) catch return buf[0..len]).len;
    for (midi_cc_set, 0..) |set, i| {
        if (set) {
            if (!appendMidiHexByte(buf, &len, midi_cc_values[i])) return buf[0..len];
        } else {
            if (buf.len -| len < 2) return buf[0..len];
            buf[len] = '-';
            buf[len + 1] = '-';
            len += 2;
        }
    }
    return buf[0..len];
}

// ============================================================================
// expect / assert（アサーション層。TASK-78）
//
// 文法（replay/live 共通）:
//   expect <probe> <key><op><value>     op ∈ {= != > <}
//   expect <probe> contains <substr>
//   assert ...（expect と同評価。replay では失敗で即 exit 1）
//   先頭の `digest` トークン（`expect digest fb ...`）はエイリアスで読み飛ばす。
//
// 評価対象は digest 1行 payload の **top-level `key=value`**（空白区切り）。ネスト（`l0{..}`）や
// JSON（stats）は 1 トークンに glue され漏れないので `contains` を使う。中身非解釈の不変条件は維持。
// ============================================================================

/// `expect`/`assert` の引数トークン列を式へ parse する純関数（module-level 状態に触らない=単体テスト可能）。
/// 余剰トークン・op 欠落・key/value 空・contains の substr 欠落・substr 余剰は null（= fail-fast, AC#3）。
fn parseExpectExpr(it: *Tok) ?ExpectExpr {
    var probe = it.next() orelse return null;
    if (std.mem.eql(u8, probe, "digest")) {
        probe = it.next() orelse return null; // `expect digest fb ...` エイリアス
    }
    const t2 = it.next() orelse return null;
    if (std.mem.eql(u8, t2, "contains")) {
        const sub = it.next() orelse return null; // substr 必須
        if (it.next() != null) return null; // 余剰トークン
        return .{ .probe = probe, .form = .{ .contains = sub } };
    }
    const cmp = parseCmpToken(t2) orelse return null;
    if (it.next() != null) return null; // 余剰トークン
    return .{ .probe = probe, .form = .{ .cmp = cmp } };
}

/// `key<op>value` 単一トークンを分割する。op ∈ {= != > <}。先頭から最初の `!`/`=`/`<`/`>` を op 開始とする。
/// key/value いずれか空・op 記号無し・`!` の直後が `=` でない場合は null（不正構文）。
fn parseCmpToken(tok: []const u8) ?Cmp {
    var i: usize = 0;
    while (i < tok.len) : (i += 1) {
        const c = tok[i];
        if (c == '=' or c == '<' or c == '>' or c == '!') break;
    }
    if (i == 0 or i >= tok.len) return null; // key 空 or op 記号無し
    var op: CmpOp = undefined;
    var vstart: usize = undefined;
    switch (tok[i]) {
        '=' => {
            op = .eq;
            vstart = i + 1;
        },
        '>' => {
            op = .gt;
            vstart = i + 1;
        },
        '<' => {
            op = .lt;
            vstart = i + 1;
        },
        '!' => {
            if (i + 1 >= tok.len or tok[i + 1] != '=') return null; // `!` 単独は不正
            op = .ne;
            vstart = i + 2;
        },
        else => unreachable,
    }
    const value = tok[vstart..];
    if (value.len == 0) return null; // value 空
    return .{ .op = op, .key = tok[0..i], .value = value };
}

/// digest payload（1行）から top-level `key=value` の value を抽出する純関数。
/// 空白（` \t`）のみで token 化し `key ++ "="` で始まる最初のトークンの `=` 以降を返す。
/// `tok[key.len]=='='` を要求することで prefix 衝突（`f` が `frames=`/`f0=` を誤マッチ）を防ぐ。
/// ネスト（`l0{..}`）や JSON は空白を含まず 1 トークンに glue されるので拾われない。
fn findKeyValue(payload: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, payload, " \t");
    while (it.next()) |tok| {
        if (tok.len > key.len and std.mem.startsWith(u8, tok, key) and tok[key.len] == '=') {
            return tok[key.len + 1 ..];
        }
    }
    return null;
}

/// actual を op で expected と比較する純関数。
/// `>`/`<` は両辺 f64 parse 必須（不能は fail）。`=`/`!=` は両辺 f64 parse 可能なら数値、それ以外は文字列一致。
fn compareValues(actual: []const u8, op: CmpOp, expected: []const u8) bool {
    const af: ?f64 = std.fmt.parseFloat(f64, actual) catch null;
    const ef: ?f64 = std.fmt.parseFloat(f64, expected) catch null;
    return switch (op) {
        .gt => af != null and ef != null and af.? > ef.?,
        .lt => af != null and ef != null and af.? < ef.?,
        .eq => if (af != null and ef != null) af.? == ef.? else std.mem.eql(u8, actual, expected),
        .ne => if (af != null and ef != null) af.? != ef.? else !std.mem.eql(u8, actual, expected),
    };
}

/// payload（digest 1行）に対し式を評価する純関数。true=pass。key 不在は fail。
fn evalExpect(payload: []const u8, expr: ExpectExpr) bool {
    switch (expr.form) {
        .contains => |sub| return std.mem.indexOf(u8, payload, sub) != null,
        .cmp => |c| {
            const actual = findKeyValue(payload, c.key) orelse return false; // key 不在 = fail
            return compareValues(actual, c.op, c.value);
        },
    }
}

/// `expect`/`assert` コマンド本体。probe の digest payload を取り式を評価し、合否を emit + 記帳する。
/// - replay: 失敗は `expect_failures` に記帳。assert は即 `replayExitIfFailed()`（fail-fast abort）。
/// - live  : プロセスを終了せず `ok`/`fail` 行を返すだけ（記帳しない）。∴ live では expect と assert は同挙動。
fn handleExpect(it: *Tok, is_assert: bool) void {
    const kind: []const u8 = if (is_assert) "assert" else "expect";
    const expr_text = std.mem.trim(u8, it.rest(), " \t"); // 診断表示用（parse 前に確保。cmd_buf への slice）
    const expr = parseExpectExpr(it) orelse return reportExpect(kind, false, expr_text, "invalid syntax", is_assert);
    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    switch (digestPayload(expr.probe, &buf)) {
        .unavailable => |reason| reportExpect(kind, false, expr_text, reason, is_assert),
        .ok => |payload| {
            const pass = evalExpect(payload, expr);
            reportExpect(kind, pass, expr_text, if (pass) null else payload, is_assert);
        },
    }
}

/// `await <probe> <key><op><value> [timeout]`。expect と同じ predicate。timeout は frame budget（0=1回）。
/// 戻り true = predicate 未成立で待機開始（呼び出し側が frame を進める / 接続を保持）。
fn handleAwait(it: *Tok) bool {
    const expr_text = std.mem.trim(u8, it.rest(), " \t");
    const parsed = parseAwaitExpr(it) orelse {
        reportAwait(false, expr_text, "invalid syntax");
        return false;
    };
    // 即時 1 回評価
    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    const pass = switch (digestPayload(parsed.expr.probe, &buf)) {
        .unavailable => false,
        .ok => |payload| evalExpect(payload, parsed.expr),
    };
    if (pass) {
        reportAwait(true, expr_text, null);
        return false;
    }
    if (parsed.timeout_frames == 0) {
        const actual: ?[]const u8 = switch (digestPayload(parsed.expr.probe, &buf)) {
            .unavailable => |r| r,
            .ok => |payload| payload,
        };
        reportAwait(false, expr_text, actual);
        return false;
    }
    pending_wait = .{ .predicate = .{
        .expr = parsed.expr,
        .expr_text = expr_text,
        .start_frame = frame_index,
        .timeout_frames = parsed.timeout_frames,
    } };
    pending_pred_actual_len = 0;
    return true;
}

const AwaitParsed = struct {
    expr: ExpectExpr,
    timeout_frames: usize,
};

/// await 引数の純 parse。optional trailing timeout（usize）。余剰・不正は null。
fn parseAwaitExpr(it: *Tok) ?AwaitParsed {
    var probe = it.next() orelse return null;
    if (std.mem.eql(u8, probe, "digest")) {
        probe = it.next() orelse return null;
    }
    const t2 = it.next() orelse return null;
    const expr: ExpectExpr = if (std.mem.eql(u8, t2, "contains")) blk: {
        const sub = it.next() orelse return null;
        break :blk .{ .probe = probe, .form = .{ .contains = sub } };
    } else blk: {
        const cmp = parseCmpToken(t2) orelse return null;
        break :blk .{ .probe = probe, .form = .{ .cmp = cmp } };
    };
    var timeout_frames: usize = 0;
    if (it.next()) |tok| {
        timeout_frames = parseUsize(tok) orelse return null;
        if (it.next() != null) return null;
    }
    return .{ .expr = expr, .timeout_frames = timeout_frames };
}

fn reportAwait(pass: bool, expr_text: []const u8, actual: ?[]const u8) void {
    if (mode == .live) {
        appendResp(if (pass) "ok " else "fail ");
        appendResp(expr_text);
        if (!pass) {
            if (actual) |a| {
                appendResp(" actual=");
                appendResp(a);
            }
        }
        appendResp("\n");
    } else if (pass) {
        std.debug.print("[harness] await ok line {d}: {s}\n", .{ line_no, expr_text });
    } else if (actual) |a| {
        std.debug.print("[harness] await FAILED line {d}: {s} actual={s}\n", .{ line_no, expr_text, a });
        expect_failures += 1;
    } else {
        std.debug.print("[harness] await FAILED line {d}: {s}\n", .{ line_no, expr_text });
        expect_failures += 1;
    }
}

/// 合否を emit（replay=stderr / live=resp_buf）し、replay の失敗を記帳する。
/// actual は失敗時のみ意味を持つ（payload か unavailable 理由。pass 時は null）。
fn reportExpect(kind: []const u8, pass: bool, expr_text: []const u8, actual: ?[]const u8, is_assert: bool) void {
    if (mode == .live) {
        appendResp(if (pass) "ok " else "fail ");
        appendResp(expr_text);
        if (!pass) {
            if (actual) |a| {
                appendResp(" actual=");
                appendResp(a);
            }
        }
        appendResp("\n");
    } else if (pass) {
        std.debug.print("[harness] {s} ok line {d}: {s}\n", .{ kind, line_no, expr_text });
    } else if (actual) |a| {
        std.debug.print("[harness] {s} FAILED line {d}: {s} actual={s}\n", .{ kind, line_no, expr_text, a });
    } else {
        std.debug.print("[harness] {s} FAILED line {d}: {s}\n", .{ kind, line_no, expr_text });
    }

    if (!pass and mode == .replay) {
        expect_failures += 1;
        if (is_assert) replayExitIfFailed(); // assert は即 abort
    }
}

/// replay 終了時: 失敗があれば summary を出して非0 exit する。
/// **mode gate を関数内に閉じる**ので live / 通常実行（disabled）では常に no-op（process.exit を呼ばない）。
fn replayExitIfFailed() void {
    if (mode == .replay and expect_failures > 0) {
        std.debug.print("[harness] 検証失敗: {d} 件（expect/assert/action）\n", .{expect_failures});
        std.process.exit(1);
    }
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

/// TASK-92 拡張解析結果（既存 AudioStats と独立。additive キー用）。
const AudioExtStats = struct {
    band_low: f32,
    band_mid: f32,
    band_high: f32,
    centroid: f32,
    onsets: u32,
    lufs: f32,
};

const audio_ext_zero = AudioExtStats{
    .band_low = 0,
    .band_mid = 0,
    .band_high = 0,
    .centroid = 0,
    .onsets = 0,
    .lufs = LUFS_FLOOR,
};

/// interleaved サンプルの直近 min(frames, mono_scratch.len) frames を mono downmix して RMS/peak/f0/silent を計算する。
/// 純ロジック（単体テスト可能）。mono_scratch は呼び出し側が渡す（hidden global を持たない）。
/// **TASK-92: 本関数と AudioStats・ANALYZE_FRAMES は変更しない**（既存キー bit 安定）。
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

/// TASK-92: band/centroid/onsets/lufs。digest 要求時（イベント時）のみ呼ばれる。RT 経路非接触。
/// 純ロジック（単体テスト直呼び可）。mono_scratch は呼び出し側が渡す（最大 EXT_FRAMES）。
/// sample_rate==0 / channels==0 / 窓 0 → 全ゼロ + lufs 床値。窓不足は縮退計算（0 なら床値）。
fn analyzeAudioExt(interleaved: []const f32, channels: u32, sample_rate: u32, mono_scratch: []f32) AudioExtStats {
    if (channels == 0 or sample_rate == 0 or interleaved.len < channels) return audio_ext_zero;
    const ch: usize = channels;
    const total_frames = interleaved.len / ch;
    if (total_frames == 0) return audio_ext_zero;
    const w = @min(total_frames, mono_scratch.len);
    const off = total_frames - w;
    var i: usize = 0;
    while (i < w) : (i += 1) {
        var acc: f32 = 0;
        var c: usize = 0;
        while (c < ch) : (c += 1) acc += interleaved[(off + i) * ch + c];
        mono_scratch[i] = acc / @as(f32, @floatFromInt(ch));
    }
    const mono = mono_scratch[0..w];
    const sr: f32 = @floatFromInt(sample_rate);

    const bands = computeBandCentroid(mono, sr);
    const onsets = countOnsets(mono, sr);
    const lufs = computeLufsMomentary(mono, sample_rate);
    return .{
        .band_low = bands.low,
        .band_mid = bands.mid,
        .band_high = bands.high,
        .centroid = bands.centroid,
        .onsets = onsets,
        .lufs = lufs,
    };
}

/// 直近 4096 フレーム（不足はゼロ詰め）に Hann+magnitudeSpectrum を掛け、
/// band_low(20–250) / band_mid(250–2000) / band_high(2000–Nyquist) の正規化エネルギー比と
/// spectral centroid [Hz] を返す。全帯域エネルギー 0 なら全て 0。
fn computeBandCentroid(mono: []const f32, sample_rate: f32) struct { low: f32, mid: f32, high: f32, centroid: f32 } {
    if (mono.len == 0 or sample_rate <= 0) return .{ .low = 0, .mid = 0, .high = 0, .centroid = 0 };

    // 直近 min(len, 4096) をバッファ末尾に置き、先頭はゼロ詰め
    @memset(ext_fft_re[0..], 0);
    const n_copy = @min(mono.len, EXT_FFT_N);
    const src_off = mono.len - n_copy;
    const dst_off = EXT_FFT_N - n_copy;
    @memcpy(ext_fft_re[dst_off..][0..n_copy], mono[src_off..][0..n_copy]);
    // magnitudeSpectrum は samples をコピーして Hann するので、samples 用に re を snapshot
    var samples: [EXT_FFT_N]f32 = undefined;
    @memcpy(samples[0..], ext_fft_re[0..]);
    dsp.magnitudeSpectrum(samples[0..], ext_fft_re[0..], ext_fft_im[0..], ext_mags[0..]);

    const n_bins = EXT_FFT_N / 2;
    const bin_hz = sample_rate / @as(f32, @floatFromInt(EXT_FFT_N));
    const nyquist = sample_rate * 0.5;
    var e_low: f64 = 0;
    var e_mid: f64 = 0;
    var e_high: f64 = 0;
    var sum_mag: f64 = 0;
    var sum_f_mag: f64 = 0;
    var k: usize = 0;
    while (k < n_bins) : (k += 1) {
        const f = @as(f32, @floatFromInt(k)) * bin_hz;
        if (f < 20.0 or f > nyquist) continue;
        const mag = ext_mags[k];
        const e = @as(f64, mag) * @as(f64, mag);
        sum_mag += mag;
        sum_f_mag += @as(f64, f) * mag;
        if (f < 250.0) {
            e_low += e;
        } else if (f < 2000.0) {
            e_mid += e;
        } else {
            e_high += e;
        }
    }
    const e_tot = e_low + e_mid + e_high;
    if (e_tot <= 0) return .{ .low = 0, .mid = 0, .high = 0, .centroid = 0 };
    const centroid: f32 = if (sum_mag > 0) @floatCast(sum_f_mag / sum_mag) else 0;
    return .{
        .low = @floatCast(e_low / e_tot),
        .mid = @floatCast(e_mid / e_tot),
        .high = @floatCast(e_high / e_tot),
        .centroid = centroid,
    };
}

/// hop=1024 / FFT=2048 のスペクトラルフラックス（正差分和）列を作り、
/// threshold=mean+1.5σ 超えのローカルピーク数を数える（決定的・固定係数）。
/// 連続して閾値を超えるプラトーは先頭ピークのみ数える（同一 onset の多重カウント防止）。
fn countOnsets(mono: []const f32, sample_rate: f32) u32 {
    _ = sample_rate;
    if (mono.len < ONSET_FFT_N) return 0;

    // 最大 hop 数: (EXT_FRAMES - ONSET_FFT_N) / ONSET_HOP + 1 ≤ 31
    const max_hops = (EXT_FRAMES - ONSET_FFT_N) / ONSET_HOP + 1;
    var flux: [max_hops]f64 = undefined;
    var n_flux: usize = 0;

    var have_prev = false;
    var frame_start: usize = 0;
    while (frame_start + ONSET_FFT_N <= mono.len) : (frame_start += ONSET_HOP) {
        @memcpy(onset_win[0..], mono[frame_start..][0..ONSET_FFT_N]);
        dsp.magnitudeSpectrum(onset_win[0..], onset_fft_re[0..], onset_fft_im[0..], onset_mags_cur[0..]);
        if (have_prev) {
            var sum: f64 = 0;
            var k: usize = 0;
            while (k < ONSET_FFT_N / 2) : (k += 1) {
                const d = onset_mags_cur[k] - onset_mags_prev[k];
                if (d > 0) sum += d;
            }
            if (n_flux < max_hops) {
                flux[n_flux] = sum;
                n_flux += 1;
            }
        }
        @memcpy(onset_mags_prev[0..], onset_mags_cur[0..]);
        have_prev = true;
    }
    if (n_flux == 0) return 0;

    // mean + 1.5σ
    var mean: f64 = 0;
    for (flux[0..n_flux]) |v| mean += v;
    mean /= @as(f64, @floatFromInt(n_flux));
    var var_acc: f64 = 0;
    for (flux[0..n_flux]) |v| {
        const d = v - mean;
        var_acc += d * d;
    }
    const sigma = @sqrt(var_acc / @as(f64, @floatFromInt(n_flux)));
    const thresh = mean + 1.5 * sigma;

    var count: u32 = 0;
    var i: usize = 0;
    while (i < n_flux) : (i += 1) {
        if (flux[i] <= thresh) continue;
        const left_ok = (i == 0) or (flux[i] >= flux[i - 1]);
        const right_ok = (i + 1 >= n_flux) or (flux[i] > flux[i + 1]); // 右は厳密 > でプラトーを1回だけ
        if (left_ok and right_ok) count += 1;
    }
    return count;
}

/// BS.1770 K-weighting（high-shelf + high-pass の 2 biquad。係数は sample_rate から設計式で算出）
/// → 直近 400ms の mean-square → -0.691 + 10·log10(ms)。mono 1ch 扱い。無音は床値 -99.0。
fn computeLufsMomentary(mono: []const f32, sample_rate: u32) f32 {
    if (mono.len == 0 or sample_rate == 0) return LUFS_FLOOR;
    const sr: f64 = @floatFromInt(sample_rate);
    const win_n = @min(mono.len, @as(usize, @intFromFloat(0.4 * sr)));
    if (win_n == 0) return LUFS_FLOOR;
    const off = mono.len - win_n;

    // Stage 1: high-shelf（ITU-R BS.1770 アナログ原型 → bilinear）
    // f0=1681.974... Hz, G=3.999... dB, Q=0.707175...
    const hs = kWeightShelfCoeffs(sr);
    // Stage 2: high-pass f0=38.135... Hz, Q=0.500327...
    const hp = kWeightHpCoeffs(sr);

    var z1_hs: f64 = 0;
    var z2_hs: f64 = 0;
    var z1_hp: f64 = 0;
    var z2_hp: f64 = 0;
    var sum_sq: f64 = 0;
    var i: usize = 0;
    while (i < win_n) : (i += 1) {
        const x: f64 = mono[off + i];
        // Direct Form I transposed: y = b0*x + z1; z1 = b1*x - a1*y + z2; z2 = b2*x - a2*y
        const y1 = hs.b0 * x + z1_hs;
        z1_hs = hs.b1 * x - hs.a1 * y1 + z2_hs;
        z2_hs = hs.b2 * x - hs.a2 * y1;
        const y2 = hp.b0 * y1 + z1_hp;
        z1_hp = hp.b1 * y1 - hp.a1 * y2 + z2_hp;
        z2_hp = hp.b2 * y1 - hp.a2 * y2;
        sum_sq += y2 * y2;
    }
    const ms = sum_sq / @as(f64, @floatFromInt(win_n));
    if (ms <= 1e-12) return LUFS_FLOOR;
    const lufs = -0.691 + 10.0 * std.math.log10(ms);
    if (lufs < LUFS_FLOOR) return LUFS_FLOOR;
    return @floatCast(lufs);
}

const BiquadCoeffs = struct { b0: f64, b1: f64, b2: f64, a1: f64, a2: f64 };

/// BS.1770 pre-filter（high shelf）係数。sample_rate 依存（48k 決め打ち禁止）。
fn kWeightShelfCoeffs(sample_rate: f64) BiquadCoeffs {
    const f0 = 1681.974450955533;
    const G = 3.999843853973347;
    const Q = 0.7071752369554196;
    const K = @tan(std.math.pi * f0 / sample_rate);
    const Vh = std.math.pow(f64, 10.0, G / 20.0);
    const Vb = std.math.pow(f64, Vh, 0.4996667741545416);
    const a0 = 1.0 + K / Q + K * K;
    return .{
        .b0 = (Vh + Vb * K / Q + K * K) / a0,
        .b1 = 2.0 * (K * K - Vh) / a0,
        .b2 = (Vh - Vb * K / Q + K * K) / a0,
        .a1 = 2.0 * (K * K - 1.0) / a0,
        .a2 = (1.0 - K / Q + K * K) / a0,
    };
}

/// BS.1770 RLB-weighting（high-pass）係数。sample_rate 依存。
fn kWeightHpCoeffs(sample_rate: f64) BiquadCoeffs {
    const f0 = 38.13547087602444;
    const Q = 0.5003270373238773;
    const K = @tan(std.math.pi * f0 / sample_rate);
    const a0 = 1.0 + K / Q + K * K;
    return .{
        .b0 = 1.0 / a0,
        .b1 = -2.0 / a0,
        .b2 = 1.0 / a0,
        .a1 = 2.0 * (K * K - 1.0) / a0,
        .a2 = (1.0 - K / Q + K * K) / a0,
    };
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
    // キー集合は分岐間で一致させる（expect の key 不在失敗を防ぐ）。TASK-92 additive。
    if (n == 0 or channels == 0) {
        return std.fmt.bufPrint(buf, "rms=0.0000 peak=0.0000 f0=0.0 silent=1 frames=0 band_low=0.0000 band_mid=0.0000 band_high=0.0000 centroid=0 onsets=0 lufs=-99.0", .{}) catch buf[0..0];
    }
    const st = analyzeAudio(audio_scratch[0..n], channels, rate, &audio_mono);
    const ext = analyzeAudioExt(audio_scratch[0..n], channels, rate, &audio_mono_ext);
    return std.fmt.bufPrint(buf, "rms={d:.4} peak={d:.4} f0={d:.1} silent={d} frames={d} band_low={d:.4} band_mid={d:.4} band_high={d:.4} centroid={d:.0} onsets={d} lufs={d:.1}", .{
        st.rms,       st.peak,      st.f0,         @intFromBool(st.silent), st.frames,
        ext.band_low, ext.band_mid, ext.band_high, ext.centroid,            ext.onsets,
        ext.lufs,
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

fn queueMidi(ev: MidiEvent) bool {
    if (midi_count >= midi_buf.len) {
        warnLine("midi FIFO 溢れ: drop");
        return false;
    }
    midi_buf[midi_count] = ev;
    midi_count += 1;
    return true;
}

fn applyMidiState(ev: MidiEvent) void {
    switch (ev) {
        .note_on => |note| midi_pressed[note.note / 8] |= @as(u8, 1) << @intCast(note.note % 8),
        .note_off => |note| midi_pressed[note.note / 8] &= ~(@as(u8, 1) << @intCast(note.note % 8)),
        .cc => |cc| {
            midi_cc_values[cc.controller] = cc.value;
            midi_cc_set[cc.controller] = true;
        },
    }
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
    clock_mode = .manual;
    cmd_buf = "";
    cursor = 0;
    line_no = 0;
    steps_remaining = 0;
    quit_requested = false;
    pending_wait = .none;
    expect_failures = 0;
    frame_index = 0;
    inject_count = 0;
    inject_read = 0;
    midi_count = 0;
    midi_read = 0;
    @memset(&midi_pressed, 0);
    @memset(&midi_cc_values, 0);
    @memset(&midi_cc_set, false);
    mouse_x = 0;
    mouse_y = 0;
    mouse_buttons = .{};
    gamepad_states = [_]?GamepadState{null} ** MAX_GAMEPADS;
    @memset(&composition_text, 0);
    composition_len = 0;
    composition_cursor = 0;
    composition_revision = 0;
    composition_active = false;
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
    external_registry_enabled = false;
    // action registry は分離モジュール（TASK-62.3.1）。reset 後に setEnabled(true) して
    // 旧挙動（mode=.replay で registerAction 可）をテスト既定として保つ。
    action_registry.resetForTest();
    action_registry.setEnabled(true);
    // synthetic capture source（TASK-49.5）: 前のテストの残留状態（video の pixel buffer・audio の
    // 生成スレッド）を確実に片付けてからクリーンな状態で始める（テスト間リークを防ぐ）。
    if (synth_video) |*dev| dev.close();
    synth_video = null;
    if (synth_audio) |dev| dev.close();
    synth_audio = null;
    capture_synthetic_requested = false;
    skip_frame_copy = false;
    headless_active = false;
    freerun_reading = false;
    freerun_acc.clearRetainingCapacity();
    test_poll_zero_count = 0;
    pending_pred_actual_len = 0;
    live_stream_owned = false;
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

test "parseKeyExtras: repeat は key_down の token として配送される" {
    var it = std.mem.tokenizeAny(u8, "cmd repeat", " \t");
    const extras = parseKeyExtras(&it).?;
    try testing.expect(extras.repeat);
    try testing.expect(extras.modifiers.cmd);
    var bad = std.mem.tokenizeAny(u8, "repeatt", " \t");
    try testing.expectEqual(@as(?KeyExtras, null), parseKeyExtras(&bad));
}

test "inject composition: update/commit/cancel の latest-wins 状態契約" {
    resetForTest();
    cmd_buf =
        "inject composition update 4 あい\n" ++
        "inject composition update 2 あい\n" ++
        "inject commit 確\n" ++
        "inject composition cancel\n" ++
        "step 1\nquit";
    try testing.expect(pollGate(true));

    // start/update/commit/char の順序を保持する。
    const start = nextInjectedEvent().?;
    try testing.expect(start == .composition_changed and start.composition_changed.phase == .start);
    const update = nextInjectedEvent().?;
    try testing.expect(update == .composition_changed and update.composition_changed.phase == .update);
    const commit = nextInjectedEvent().?;
    try testing.expect(commit == .composition_changed and commit.composition_changed.phase == .commit);
    try testing.expectEqual(@as(u32, 3), commit.composition_changed.revision);
    const ch = nextInjectedEvent().?;
    try testing.expect(ch == .char_input and ch.char_input.codepoint == '確');
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());

    var buf: [COMPOSITION_CAP]u8 = undefined;
    const snapshot = getCompositionSnapshot(&buf);
    try testing.expectEqualStrings("", snapshot.text);
    try testing.expectEqual(@as(u32, 3), snapshot.revision);
    try testing.expectEqual(@as(u32, 0), snapshot.cursor);
}

test "inject commit: bare commit は composition_changed なしで char_input を配送" {
    resetForTest();
    cmd_buf =
        "inject commit AB\n" ++
        "step 1\nquit";
    try testing.expect(pollGate(true));

    const a = nextInjectedEvent().?;
    try testing.expect(a == .char_input and a.char_input.codepoint == 'A');
    const b = nextInjectedEvent().?;
    try testing.expect(b == .char_input and b.char_input.codepoint == 'B');
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());

    var buf: [COMPOSITION_CAP]u8 = undefined;
    const snapshot = getCompositionSnapshot(&buf);
    try testing.expectEqualStrings("", snapshot.text);
    try testing.expectEqual(@as(u32, 0), snapshot.revision);
    try testing.expectEqual(@as(u32, 0), snapshot.cursor);
}

test "inject composition: 空 update は許容、cancel は update 前 no-op、cursor は UTF-8 境界へ clamp" {
    resetForTest();
    cmd_buf =
        "inject composition cancel\n" ++
        "inject composition update 99\n" ++
        "inject composition update 4 あい\n" ++
        "step 1\nquit";
    try testing.expect(pollGate(true));
    const empty = nextInjectedEvent().?;
    try testing.expect(empty == .composition_changed and empty.composition_changed.phase == .start);
    const update = nextInjectedEvent().?;
    try testing.expect(update == .composition_changed and update.composition_changed.cursor == 3);
    var buf: [COMPOSITION_CAP]u8 = undefined;
    const snapshot = getCompositionSnapshot(&buf);
    try testing.expectEqualStrings("あい", snapshot.text);
    try testing.expectEqual(@as(u32, 3), snapshot.cursor);
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());
}

test "inject file_drop: 単一 path / スペース保持 / 連続・末尾空白保持" {
    resetForTest();
    cmd_buf =
        \\inject file_drop /tmp/a.png
        \\step 1
        \\inject file_drop /tmp/My Image.png
        \\step 1
        \\inject file_drop /tmp/trailing  
        \\step 1
        \\inject file_drop /tmp/a  b.png
        \\step 1
        \\quit
    ;
    try testing.expect(pollGate(true));
    var e = nextInjectedEvent().?;
    try testing.expect(e == .file_drop);
    try testing.expectEqual(@as(u8, 1), e.file_drop.count);
    try testing.expectEqualStrings("/tmp/a.png", e.file_drop.paths[0].slice());
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());

    try testing.expect(pollGate(true));
    e = nextInjectedEvent().?;
    try testing.expectEqualStrings("/tmp/My Image.png", e.file_drop.paths[0].slice());
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());

    try testing.expect(pollGate(true));
    e = nextInjectedEvent().?;
    try testing.expectEqualStrings("/tmp/trailing  ", e.file_drop.paths[0].slice());
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());

    try testing.expect(pollGate(true));
    e = nextInjectedEvent().?;
    try testing.expectEqualStrings("/tmp/a  b.png", e.file_drop.paths[0].slice());
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());
    try testing.expect(!pollGate(true));
}

test "inject file_drop: 空 path / 不正 UTF-8 / 上限超過は拒否" {
    resetForTest();
    cmd_buf =
        "inject file_drop\n" ++
        "inject file_drop \n" ++
        "inject file_drop \xff\n" ++
        "step 1\nquit";
    try testing.expect(pollGate(true));
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());
    try testing.expect(!pollGate(true));

    // 上限超過（FILE_DROP_PATH_BYTES+1）
    resetForTest();
    var script_buf: [48 + types.FILE_DROP_PATH_BYTES + 1]u8 = undefined;
    const prefix = "inject file_drop ";
    @memcpy(script_buf[0..prefix.len], prefix);
    @memset(script_buf[prefix.len..][0 .. types.FILE_DROP_PATH_BYTES + 1], 'x');
    const mid = prefix.len + types.FILE_DROP_PATH_BYTES + 1;
    const suffix = "\nstep 1\nquit";
    @memcpy(script_buf[mid..][0..suffix.len], suffix);
    cmd_buf = script_buf[0 .. mid + suffix.len];
    try testing.expect(pollGate(true));
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());
    try testing.expect(!pollGate(true));
}

test "inject file_drop: 複数 token を複数ファイルとして解釈しない" {
    resetForTest();
    cmd_buf =
        \\inject file_drop /tmp/a.png /tmp/b.png
        \\step 1
        \\quit
    ;
    try testing.expect(pollGate(true));
    const e = nextInjectedEvent().?;
    try testing.expect(e == .file_drop);
    try testing.expectEqual(@as(u8, 1), e.file_drop.count);
    try testing.expectEqualStrings("/tmp/a.png /tmp/b.png", e.file_drop.paths[0].slice());
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());
}

test "inject file_drop: live raw record と replay の path bytes 一致" {
    resetForTest();
    const raw = "inject file_drop /tmp/My Image.png";
    // live record は raw request をそのまま保存する契約。replay は同じ行を解釈する。
    cmd_buf = raw ++ "\nstep 1\nquit";
    try testing.expect(pollGate(true));
    const live_ev = nextInjectedEvent().?;
    try testing.expectEqualStrings("/tmp/My Image.png", live_ev.file_drop.paths[0].slice());
    const live_bytes = live_ev.file_drop.paths[0].slice();

    resetForTest();
    cmd_buf = raw ++ "\nstep 1\nquit";
    try testing.expect(pollGate(true));
    const replay_ev = nextInjectedEvent().?;
    try testing.expectEqualStrings(live_bytes, replay_ev.file_drop.paths[0].slice());
}

test "inject file_drop: harness 無効時は inject queue が空のまま（既存 no-op）" {
    resetForTest();
    mode = .disabled;
    cmd_buf = "";
    try testing.expect(!pollGate(true));
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());
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

test "skip_frame_copy: 有効時は frame_index のみ進み、@memcpy はスキップされる（TASK-156.5 R10）" {
    resetForTest();
    skip_frame_copy = true;
    defer skip_frame_copy = false;
    const px = [_]u32{0xFF445566};
    onLock(&px, 1, 1);
    onPresent();
    try testing.expectEqual(@as(u64, 1), frame_index);
    try testing.expectEqual(@as(f64, 1.0 / 60.0), now());
    // フレームは owned copy されないため have_frame は立たない。
    try testing.expect(!have_frame);
    onLock(&px, 1, 1);
    onPresent();
    try testing.expectEqual(@as(u64, 2), frame_index);
    try testing.expect(!have_frame);
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

/// 既知 sine を mono バッファへ埋める（振幅 amp・周波数 freq_hz・sr）。
fn fillSine(dst: []f32, amp: f32, freq_hz: f32, sample_rate: f32) void {
    for (dst, 0..) |*s, i| {
        s.* = amp * @sin(2.0 * std.math.pi * freq_hz * @as(f32, @floatFromInt(i)) / sample_rate);
    }
}

test "analyzeAudioExt: 440Hz sine — band_mid 支配・centroid≈440・onsets=0" {
    var mono_ext: [EXT_FRAMES]f32 = undefined;
    var sine: [4800]f32 = undefined;
    fillSine(&sine, 0.5, 440, 48000);
    const ext = analyzeAudioExt(&sine, 1, 48000, &mono_ext);
    try testing.expect(ext.band_mid > 0.9);
    try testing.expectApproxEqAbs(@as(f32, 440), ext.centroid, 20.0);
    try testing.expectEqual(@as(u32, 0), ext.onsets);
}

test "analyzeAudioExt: 100Hz → band_low 支配 / 6kHz → band_high 支配" {
    var mono_ext: [EXT_FRAMES]f32 = undefined;
    var low: [4800]f32 = undefined;
    fillSine(&low, 0.5, 100, 48000);
    const e_low = analyzeAudioExt(&low, 1, 48000, &mono_ext);
    try testing.expect(e_low.band_low > 0.9);

    var high: [4800]f32 = undefined;
    fillSine(&high, 0.5, 6000, 48000);
    const e_high = analyzeAudioExt(&high, 1, 48000, &mono_ext);
    try testing.expect(e_high.band_high > 0.9);
}

test "analyzeAudioExt: 997Hz sine 振幅 0.5 の LUFS ≈ -9.1" {
    // BS.1770 K-weighting は 997Hz でわずかに boost があり、
    // amp=0.5 連続 sine の momentary は ≈-9.07（unweighted 理論 -9.72 より約 +0.65 dB）。
    // plan の「K≈0dB → -9.7」は近似。実装は標準設計式に忠実。
    var mono_ext: [EXT_FRAMES]f32 = undefined;
    // 400ms @48k = 19200 サンプル以上（momentary 窓を満杯にする）
    var sine: [24000]f32 = undefined;
    fillSine(&sine, 0.5, 997, 48000);
    const ext = analyzeAudioExt(&sine, 1, 48000, &mono_ext);
    try testing.expectApproxEqAbs(@as(f32, -9.1), ext.lufs, 0.5);
}

test "analyzeAudioExt: 無音→バースト×3 で onsets=3" {
    var mono_ext: [EXT_FRAMES]f32 = undefined;
    const sr: usize = 48000;
    const burst_n = sr * 50 / 1000; // 50ms
    const gap_n = sr * 150 / 1000; // 150ms
    // leading silence + 3 bursts + 2 gaps + trailing silence（終端プラトーを避ける）
    const total = 4096 + 3 * burst_n + 2 * gap_n + 4096;
    var buf: [32768]f32 = undefined;
    try testing.expect(total <= buf.len);
    @memset(buf[0..total], 0);
    var pos: usize = 4096; // leading silence
    var b: usize = 0;
    while (b < 3) : (b += 1) {
        // 広帯域に近い決定的バースト（LCG ノイズ）。純 sine は位相で flux が割れ閾値を外しやすい。
        var rng: u32 = 0xA341316C +% @as(u32, @intCast(b)) *% 0x9E3779B9;
        var j: usize = 0;
        while (j < burst_n) : (j += 1) {
            rng = rng *% 1664525 +% 1013904223;
            const u = @as(f32, @floatFromInt(rng >> 8)) * (1.0 / 16777216.0); // [0,1)
            buf[pos + j] = (u * 2.0 - 1.0) * 0.8;
        }
        pos += burst_n;
        if (b + 1 < 3) pos += gap_n;
    }
    const ext = analyzeAudioExt(buf[0..total], 1, 48000, &mono_ext);
    try testing.expectEqual(@as(u32, 3), ext.onsets);
}

test "analyzeAudioExt: 無音は新キー 0 / lufs=-99.0" {
    var mono_ext: [EXT_FRAMES]f32 = undefined;
    var sil = [_]f32{0} ** 4096;
    const ext = analyzeAudioExt(&sil, 1, 48000, &mono_ext);
    try testing.expectEqual(@as(f32, 0), ext.band_low);
    try testing.expectEqual(@as(f32, 0), ext.band_mid);
    try testing.expectEqual(@as(f32, 0), ext.band_high);
    try testing.expectEqual(@as(f32, 0), ext.centroid);
    try testing.expectEqual(@as(u32, 0), ext.onsets);
    try testing.expectEqual(@as(f32, LUFS_FLOOR), ext.lufs);
}

test "analyzeAudioExt: sample_rate=0 / channels=0 は床値ガード" {
    var mono_ext: [EXT_FRAMES]f32 = undefined;
    var sine: [256]f32 = undefined;
    fillSine(&sine, 0.5, 440, 48000);
    const e0 = analyzeAudioExt(&sine, 1, 0, &mono_ext);
    try testing.expectEqual(@as(f32, LUFS_FLOOR), e0.lufs);
    try testing.expectEqual(@as(f32, 0), e0.band_mid);
    const e1 = analyzeAudioExt(&sine, 0, 48000, &mono_ext);
    try testing.expectEqual(@as(f32, LUFS_FLOOR), e1.lufs);
}

test "formatAudioPayload: 既存キー prefix が従来と bit 一致（回帰）+ 新キー存在 + 1024B 以内" {
    resetForTest();
    mode = .replay;
    audio_head = .init(0);
    audio_channels = .init(0);
    audio_rate = .init(0);

    // 空バッファ: 無音分岐。既存キー部分は従来と bit 一致し、新キーが続く。
    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    const empty = formatAudioPayload(&buf);
    try testing.expect(std.mem.startsWith(u8, empty, "rms=0.0000 peak=0.0000 f0=0.0 silent=1 frames=0"));
    try testing.expect(std.mem.indexOf(u8, empty, "band_low=0.0000") != null);
    try testing.expect(std.mem.indexOf(u8, empty, "band_mid=0.0000") != null);
    try testing.expect(std.mem.indexOf(u8, empty, "band_high=0.0000") != null);
    try testing.expect(std.mem.indexOf(u8, empty, "centroid=0") != null);
    try testing.expect(std.mem.indexOf(u8, empty, "onsets=0") != null);
    try testing.expect(std.mem.indexOf(u8, empty, "lufs=-99.0") != null);
    try testing.expect(empty.len < DIGEST_BUF_LEN);

    // 440Hz sine を ring に流し、既存キー prefix が analyzeAudio と bit 一致 + 新キー additive。
    var sine: [4800]f32 = undefined;
    fillSine(&sine, 0.5, 440, 48000);
    onAudioSamples(&sine, 4800, 1, 48000);
    const payload = formatAudioPayload(&buf);
    try testing.expect(std.mem.indexOf(u8, payload, "silent=0") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "band_mid=") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "centroid=") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "onsets=") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "lufs=") != null);
    try testing.expect(payload.len < DIGEST_BUF_LEN);

    // 既存キー部分だけを analyzeAudio の format と bit 比較（新キーを削った prefix = 回帰ゼロ）
    var mono: [ANALYZE_FRAMES]f32 = undefined;
    // formatAudioPayload と同じ直近窓（ring に入れた sine 全体）で legacy を組み立てる
    const st = analyzeAudio(&sine, 1, 48000, &mono);
    var legacy: [128]u8 = undefined;
    const legacy_s = try std.fmt.bufPrint(&legacy, "rms={d:.4} peak={d:.4} f0={d:.1} silent={d} frames={d}", .{
        st.rms, st.peak, st.f0, @intFromBool(st.silent), st.frames,
    });
    try testing.expect(std.mem.startsWith(u8, payload, legacy_s));
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
    registerProbe(.{ .name = "capture", .ctx = &c1, .digest = testProbeDigest }); // TASK-49.5 で追加した予約名
    registerProbe(.{ .name = "gamepad", .ctx = &c1, .digest = testProbeDigest }); // TASK-80.1 で追加した予約名
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
// expect / assert（アサーション層。TASK-78）tests
// ============================================================================

test "parseExpectExpr: 正常系（cmp 4演算子 / contains / digest エイリアス / 負数小数）" {
    {
        var it = std.mem.tokenizeAny(u8, "fb crc=ABCD1234", " \t");
        const e = parseExpectExpr(&it).?;
        try testing.expectEqualStrings("fb", e.probe);
        try testing.expect(e.form == .cmp);
        try testing.expectEqual(CmpOp.eq, e.form.cmp.op);
        try testing.expectEqualStrings("crc", e.form.cmp.key);
        try testing.expectEqualStrings("ABCD1234", e.form.cmp.value);
    }
    {
        var it = std.mem.tokenizeAny(u8, "audio silent!=1", " \t");
        const e = parseExpectExpr(&it).?;
        try testing.expectEqual(CmpOp.ne, e.form.cmp.op);
        try testing.expectEqualStrings("silent", e.form.cmp.key);
        try testing.expectEqualStrings("1", e.form.cmp.value);
    }
    {
        var it = std.mem.tokenizeAny(u8, "canvas nz>0", " \t");
        const e = parseExpectExpr(&it).?;
        try testing.expectEqual(CmpOp.gt, e.form.cmp.op);
        try testing.expectEqualStrings("nz", e.form.cmp.key);
    }
    {
        var it = std.mem.tokenizeAny(u8, "audio f0<500", " \t");
        const e = parseExpectExpr(&it).?;
        try testing.expectEqual(CmpOp.lt, e.form.cmp.op);
    }
    {
        // 負数・小数 value（op より後は全部 value）
        var it = std.mem.tokenizeAny(u8, "audio rms>-0.5", " \t");
        const e = parseExpectExpr(&it).?;
        try testing.expectEqualStrings("rms", e.form.cmp.key);
        try testing.expectEqualStrings("-0.5", e.form.cmp.value);
    }
    {
        // `expect digest fb ...` エイリアス（第2トークン digest を読み飛ばす）
        var it = std.mem.tokenizeAny(u8, "digest fb crc=ABCD", " \t");
        const e = parseExpectExpr(&it).?;
        try testing.expectEqualStrings("fb", e.probe);
        try testing.expectEqualStrings("ABCD", e.form.cmp.value);
    }
    {
        var it = std.mem.tokenizeAny(u8, "fb contains #FF0000", " \t");
        const e = parseExpectExpr(&it).?;
        try testing.expect(e.form == .contains);
        try testing.expectEqualStrings("#FF0000", e.form.contains);
    }
}

test "parseExpectExpr: 異常系は null（fail-fast: op 欠落・空・余剰・! 単独）" {
    const bad = [_][]const u8{
        "fb crcABCD", // op 記号無し
        "fb", // 式無し
        "", // probe 無し
        "fb =5", // key 空
        "fb crc=", // value 空
        "fb crc!5", // `!` 単独（`=` が続かない）
        "fb crc=A extra", // 余剰トークン
        "fb contains", // substr 欠落
        "fb contains a b", // substr 余剰
        "digest", // エイリアス後に probe 無し
        "digest fb", // エイリアス後 probe だけで式無し
    };
    for (bad) |s| {
        var it = std.mem.tokenizeAny(u8, s, " \t");
        try testing.expect(parseExpectExpr(&it) == null);
    }
}

test "findKeyValue: top-level 抽出 / prefix 衝突防止 / ネスト・JSON 非抽出" {
    const audio = "rms=0.5000 peak=0.7000 f0=440.0 silent=0 frames=4096";
    try testing.expectEqualStrings("0.5000", findKeyValue(audio, "rms").?);
    try testing.expectEqualStrings("440.0", findKeyValue(audio, "f0").?);
    try testing.expectEqualStrings("4096", findKeyValue(audio, "frames").?);
    try testing.expectEqualStrings("0", findKeyValue(audio, "silent").?);
    // prefix 衝突: "f" は f0=/frames= を誤マッチしない（tok[key.len]=='=' 要求）
    try testing.expect(findKeyValue(audio, "f") == null);
    try testing.expect(findKeyValue(audio, "nope") == null);

    // ネスト（canvas 風）: top-level layers/comp は拾える、内側 crc/nz は漏れない
    const canvas = "32x32 layers=2 selected=0 comp=DEADBEEF l0{v=1,op=1.00,crc=CAFEBABE,nz=42}";
    try testing.expectEqualStrings("2", findKeyValue(canvas, "layers").?);
    try testing.expectEqualStrings("DEADBEEF", findKeyValue(canvas, "comp").?);
    try testing.expect(findKeyValue(canvas, "nz") == null); // ネスト key は漏れない
    try testing.expect(findKeyValue(canvas, "crc") == null); // 内側 crc は top-level comp とは別

    // JSON（stats 風）: `key=` 形でないので拾わない → contains を使う想定
    const json = "{\"frame\":123,\"virtual_fps\":60.0}";
    try testing.expect(findKeyValue(json, "frame") == null);
}

test "compareValues: 数値/文字列/大小の切り替え" {
    // 数値 =（0.5 ≒ 0.5000）
    try testing.expect(compareValues("0.5000", .eq, "0.5"));
    try testing.expect(!compareValues("0.5000", .eq, "0.6"));
    // 文字列 =（crc hex は非数値 → 完全一致）
    try testing.expect(compareValues("ABCD1234", .eq, "ABCD1234"));
    try testing.expect(!compareValues("ABCD1234", .eq, "ABCD9999"));
    // !=
    try testing.expect(compareValues("ABCD", .ne, "DCBA"));
    try testing.expect(!compareValues("5", .ne, "5.0")); // 数値等価 → != は false
    // > <（両辺数値必須）
    try testing.expect(compareValues("4096", .gt, "4000"));
    try testing.expect(!compareValues("4096", .gt, "5000"));
    try testing.expect(compareValues("440.0", .lt, "500"));
    // > < で非数値は fail（両辺 f64 必須）
    try testing.expect(!compareValues("ABCD", .gt, "0"));
    try testing.expect(!compareValues("5", .lt, "xyz"));
}

test "evalExpect: cmp / contains / key 不在" {
    const audio = "rms=0.5000 peak=0.7000 f0=440.0 silent=0 frames=4096";
    try testing.expect(evalExpect(audio, .{ .probe = "audio", .form = .{ .cmp = .{ .op = .eq, .key = "silent", .value = "0" } } }));
    try testing.expect(evalExpect(audio, .{ .probe = "audio", .form = .{ .cmp = .{ .op = .gt, .key = "rms", .value = "0" } } }));
    try testing.expect(!evalExpect(audio, .{ .probe = "audio", .form = .{ .cmp = .{ .op = .gt, .key = "nope", .value = "0" } } })); // key 不在 = fail
    try testing.expect(evalExpect(audio, .{ .probe = "audio", .form = .{ .contains = "f0=440.0" } }));
    try testing.expect(!evalExpect(audio, .{ .probe = "audio", .form = .{ .contains = "nonexistent" } }));
}

test "expect replay: expect_failures が 成功=据置 / 失敗=+1 / 未知probe=+1（EOF 未到達で exit 回避）" {
    resetForTest(); // mode=.replay
    // 既知 fb フレーム（2x2）を用意して crc を確定
    var px = [_]u32{ 0xFF000000, 0xFF000000, 0xFF000000, 0xFF0000FF };
    frame_pixels = px[0..];
    frame_w = 2;
    frame_h = 2;
    have_frame = true;
    defer frame_pixels = &.{};
    const crc = png.crc32(std.mem.sliceAsBytes(px[0..4]));

    var sbuf: [256]u8 = undefined;
    // 正 crc(pass)→step / 偽 crc(fail)→step / 未知 probe(fail)→step。
    // **EOF/quit に到達させない**（step で止め、最後は pollGate を呼ばない）ことで replayExitIfFailed の exit を踏まない。
    cmd_buf = std.fmt.bufPrint(&sbuf, "expect fb crc={X:0>8}\nstep 1\nexpect fb crc=00000000\nstep 1\nexpect nosuch x=1\nstep 1\n", .{crc}) catch unreachable;
    cursor = 0;

    try testing.expect(pollGate(true)); // frame1: 正 crc(pass) → step
    try testing.expectEqual(@as(usize, 0), expect_failures);
    try testing.expect(pollGate(true)); // frame2: 偽 crc(fail) → step
    try testing.expectEqual(@as(usize, 1), expect_failures);
    try testing.expect(pollGate(true)); // frame3: 未知 probe(fail) → step
    try testing.expectEqual(@as(usize, 2), expect_failures);
    // ここで pollGate を再度呼ぶと EOF → replayExitIfFailed で exit(1) するので**呼ばない**。
    expect_failures = 0; // 次テストへの漏れ防止（明示。resetForTest も後続で行う）
}

test "expect live: ok/fail 行が resp_buf に積まれる / live は記帳せず assert も exit しない" {
    resetForTest();
    mode = .live;
    resp_buf.clearRetainingCapacity();
    defer resp_buf.clearRetainingCapacity();
    var px = [_]u32{0xFF010203};
    frame_pixels = px[0..];
    frame_w = 1;
    frame_h = 1;
    have_frame = true;
    defer frame_pixels = &.{};
    const crc = png.crc32(std.mem.sliceAsBytes(px[0..1]));

    // pass → "ok fb crc=..."
    var lbuf: [64]u8 = undefined;
    {
        const line = std.fmt.bufPrint(&lbuf, "fb crc={X:0>8}", .{crc}) catch unreachable;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        handleExpect(&it, false);
    }
    try testing.expect(std.mem.startsWith(u8, resp_buf.items, "ok fb crc="));
    resp_buf.clearRetainingCapacity();

    // fail（actual= 付き）。live なので expect_failures は増えない
    {
        var it = std.mem.tokenizeAny(u8, "fb crc=00000000", " \t");
        handleExpect(&it, false);
    }
    try testing.expect(std.mem.startsWith(u8, resp_buf.items, "fail fb crc=00000000 actual="));
    try testing.expectEqual(@as(usize, 0), expect_failures);
    resp_buf.clearRetainingCapacity();

    // assert + 未知 probe も live では exit せず fail 行 + 理由のみ
    {
        var it = std.mem.tokenizeAny(u8, "nosuch x=1", " \t");
        handleExpect(&it, true);
    }
    try testing.expect(std.mem.startsWith(u8, resp_buf.items, "fail nosuch x=1 actual=unknown probe"));
    try testing.expectEqual(@as(usize, 0), expect_failures);
}

// ============================================================================
// action（probe 対称の高レベル操作。TASK-62.1）tests
// ============================================================================

const TestActionCtx = struct {
    calls: usize = 0,
    args_buf: [256]u8 = undefined,
    args_len: usize = 0,

    fn lastArgs(self: *const TestActionCtx) []const u8 {
        return self.args_buf[0..self.args_len];
    }
};

fn testActionRun(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const c: *TestActionCtx = @ptrCast(@alignCast(ctx));
    c.calls += 1;
    @memcpy(c.args_buf[0..args.len], args);
    c.args_len = args.len;
    return std.fmt.bufPrint(buf, "ok:{s}", .{args}) catch buf[0..0];
}

fn testActionErr(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = ctx;
    _ = args;
    _ = buf;
    return error.Boom;
}

test "firstLine: 最初の \\r/\\n の手前で切る（無ければ全体・callback の複数行返却を防御）" {
    try testing.expectEqualStrings("abc", firstLine("abc\ndef"));
    try testing.expectEqualStrings("abc", firstLine("abc\r\ndef"));
    try testing.expectEqualStrings("abc", firstLine("abc"));
    try testing.expectEqualStrings("", firstLine("\nabc"));
}

test "registerAction: disabled 時 no-op（回帰ゼロ）" {
    resetForTest();
    mode = .disabled;
    action_registry.resetForTest(); // enabled=false（harness.resetForTest はテスト既定で setEnabled する）
    var c = TestActionCtx{};
    registerAction(.{ .name = "x", .ctx = &c, .run = testActionRun });
    try testing.expectEqual(@as(usize, 0), action_registry.actionCount());
}

test "registerAction: 同名上書き / 不正名（空・空白・;・改行）拒否 / 満杯 skip" {
    resetForTest();
    var c1 = TestActionCtx{};
    var c2 = TestActionCtx{};
    registerAction(.{ .name = "a", .ctx = &c1, .run = testActionRun });
    registerAction(.{ .name = "a", .ctx = &c2, .run = testActionRun }); // 同名上書き
    try testing.expectEqual(@as(usize, 1), action_registry.actionCount());
    try testing.expectEqual(@as(*anyopaque, &c2), findAction("a").?.ctx);

    registerAction(.{ .name = "", .ctx = &c1, .run = testActionRun }); // 空名
    registerAction(.{ .name = "b c", .ctx = &c1, .run = testActionRun }); // 空白混入
    registerAction(.{ .name = "b;c", .ctx = &c1, .run = testActionRun }); // ; 混入
    registerAction(.{ .name = "b\nc", .ctx = &c1, .run = testActionRun }); // 改行混入
    try testing.expectEqual(@as(usize, 1), action_registry.actionCount()); // いずれも拒否され増えない

    // 満杯 skip: "a" + MAX_ACTIONS 件以上を登録しても MAX_ACTIONS(=48) で頭打ち
    var name_bufs: [action_registry.MAX_ACTIONS + 4][8]u8 = undefined;
    for (&name_bufs, 0..) |*nb, i| {
        const nm = std.fmt.bufPrint(nb, "act{d}", .{i}) catch unreachable;
        registerAction(.{ .name = nm, .ctx = &c1, .run = testActionRun });
    }
    try testing.expectEqual(@as(usize, action_registry.MAX_ACTIONS), action_registry.actionCount());
}

test "action dispatch: raw args 透過（再トークン化しない・連続空白/JSON風ペイロード保持）" {
    resetForTest();
    var c = TestActionCtx{};
    registerAction(.{ .name = "foo", .ctx = &c, .run = testActionRun });
    defer action_registry.resetForTest();
    cmd_buf =
        \\action foo 1 2  3
        \\step 1
        \\action foo key=val {"a":1,"b":2}
        \\step 1
        \\quit
    ;

    try testing.expect(pollGate(true));
    try testing.expectEqual(@as(usize, 1), c.calls);
    try testing.expectEqualStrings("1 2  3", c.lastArgs()); // 連続空白が潰れない = 再トークン化していない

    try testing.expect(pollGate(true));
    try testing.expectEqual(@as(usize, 2), c.calls);
    try testing.expectEqualStrings("key=val {\"a\":1,\"b\":2}", c.lastArgs()); // JSON風ペイロードもそのまま

    try testing.expect(!pollGate(true)); // quit
}

test "action: 未知 action / 名前欠落 / run()エラー は記帳（expect_failures 加算・EOF未到達で exit回避）" {
    resetForTest();
    var c = TestActionCtx{};
    registerAction(.{ .name = "boom", .ctx = &c, .run = testActionErr });
    defer action_registry.resetForTest();
    cmd_buf =
        \\action nosuch
        \\step 1
        \\action
        \\step 1
        \\action boom
        \\step 1
    ;

    try testing.expect(pollGate(true)); // 未知 action
    try testing.expectEqual(@as(usize, 1), expect_failures);
    try testing.expect(pollGate(true)); // 名前欠落
    try testing.expectEqual(@as(usize, 2), expect_failures);
    try testing.expect(pollGate(true)); // run() エラー（クラッシュしない）
    try testing.expectEqual(@as(usize, 3), expect_failures);
    // ここで pollGate を再度呼ぶと EOF → replayExitIfFailed で exit(1) するので**呼ばない**。
    expect_failures = 0; // 次テストへの漏れ防止
}

test "action live: 成功は bare `<name> <msg>`、失敗は `fail <name> <msg>`（drive 検知）/ live は記帳しない" {
    resetForTest();
    mode = .live;
    resp_buf.clearRetainingCapacity();
    defer resp_buf.clearRetainingCapacity();
    var c = TestActionCtx{};
    registerAction(.{ .name = "foo", .ctx = &c, .run = testActionRun });
    defer action_registry.resetForTest();

    {
        var it = std.mem.tokenizeAny(u8, "foo bar", " \t");
        handleAction(&it);
    }
    try testing.expectEqualStrings("foo ok:bar\n", resp_buf.items);
    resp_buf.clearRetainingCapacity();

    {
        var it = std.mem.tokenizeAny(u8, "nosuch", " \t");
        handleAction(&it);
    }
    try testing.expect(std.mem.startsWith(u8, resp_buf.items, "fail nosuch unknown action"));
    try testing.expectEqual(@as(usize, 0), expect_failures); // live は記帳しない
}

fn testActionErrWithDetail(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = ctx;
    _ = args;
    _ = buf;
    action_registry.setActionErrorDetail("file_not_found", "check path or use save first");
    return error.Boom;
}

fn testActionErrMaybeDetail(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = ctx;
    _ = buf;
    if (std.mem.eql(u8, args, "set")) {
        action_registry.setActionErrorDetail("stale_code", "should not leak to next fail");
    }
    return error.Boom;
}

test "action structured error: live 失敗行に code=/next= 追記 / 未セット時は従来 bit 一致 / fail 行頭不変" {
    resetForTest();
    mode = .live;
    resp_buf.clearRetainingCapacity();
    defer resp_buf.clearRetainingCapacity();
    var c = TestActionCtx{};
    registerAction(.{ .name = "boom", .ctx = &c, .run = testActionErrWithDetail });
    registerAction(.{ .name = "plain", .ctx = &c, .run = testActionErr });
    defer action_registry.resetForTest();

    {
        var it = std.mem.tokenizeAny(u8, "boom", " \t");
        handleAction(&it);
    }
    // 行頭 `fail ` 不変 → scripts/drive の fail 行頭スキャン回帰（AC#2）
    try testing.expect(std.mem.startsWith(u8, resp_buf.items, "fail boom "));
    try testing.expectEqualStrings("fail boom Boom code=file_not_found next=check path or use save first\n", resp_buf.items);
    resp_buf.clearRetainingCapacity();

    // detail 未セット時は従来形式と bit 一致（code=/next= を一切付けない）
    {
        var it = std.mem.tokenizeAny(u8, "plain", " \t");
        handleAction(&it);
    }
    try testing.expectEqualStrings("fail plain Boom\n", resp_buf.items);
    try testing.expect(std.mem.indexOf(u8, resp_buf.items, "code=") == null);
    try testing.expect(std.mem.indexOf(u8, resp_buf.items, "next=") == null);
    try testing.expectEqual(@as(usize, 0), expect_failures); // live は記帳しない
}

test "action structured error: dispatch 毎クリアで前回 detail が次の失敗に漏れない" {
    resetForTest();
    mode = .live;
    resp_buf.clearRetainingCapacity();
    defer resp_buf.clearRetainingCapacity();
    var c = TestActionCtx{};
    registerAction(.{ .name = "maybe", .ctx = &c, .run = testActionErrMaybeDetail });
    defer action_registry.resetForTest();

    {
        var it = std.mem.tokenizeAny(u8, "maybe set", " \t");
        handleAction(&it);
    }
    try testing.expectEqualStrings("fail maybe Boom code=stale_code next=should not leak to next fail\n", resp_buf.items);
    resp_buf.clearRetainingCapacity();

    {
        var it = std.mem.tokenizeAny(u8, "maybe noset", " \t");
        handleAction(&it);
    }
    try testing.expectEqualStrings("fail maybe Boom\n", resp_buf.items);
}

test "action structured error: next の空白保持 / sanitize（改行→_）" {
    resetForTest();
    mode = .live;
    resp_buf.clearRetainingCapacity();
    defer resp_buf.clearRetainingCapacity();
    var c = TestActionCtx{};
    const run = struct {
        fn f(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
            _ = ctx;
            _ = args;
            _ = buf;
            action_registry.setActionErrorDetail("a b\nc", "use add_layer or 0..N-1");
            return error.Bad;
        }
    }.f;
    registerAction(.{ .name = "x", .ctx = &c, .run = run });
    defer action_registry.resetForTest();

    {
        var it = std.mem.tokenizeAny(u8, "x", " \t");
        handleAction(&it);
    }
    try testing.expectEqualStrings("fail x Bad code=a_b_c next=use add_layer or 0..N-1\n", resp_buf.items);
}

test "action structured error: replay/live 両 wire の suffix 形式（未セットは空）" {
    resetForTest();
    var sbuf: [128]u8 = undefined;
    // 未セット → 空（従来 bit 一致の根拠）
    try testing.expectEqualStrings("", actionErrorDetailSuffix(&sbuf));

    action_registry.setActionErrorDetail("file_not_found", "check path or use save first");
    const suf = actionErrorDetailSuffix(&sbuf);
    try testing.expectEqualStrings(" code=file_not_found next=check path or use save first", suf);

    // live: `fail <name> <msg>` + suffix / replay: `[harness] action <name> FAILED <msg>` + suffix
    // （同一 suffix を両 sink が共有。reportAction が組み立てる）
    try testing.expect(std.mem.endsWith(u8, "fail boom Boom code=file_not_found next=check path or use save first", suf));
    try testing.expect(std.mem.endsWith(u8, "[harness] action boom FAILED Boom code=file_not_found next=check path or use save first", suf));
    try testing.expect(std.mem.startsWith(u8, "fail boom Boom", "fail ")); // drive 行頭スキャン
}

// ============================================================================
// capabilities probe（登録済み probe・action の内省列挙。TASK-62.4）tests
// ============================================================================

fn testProbeSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    _ = ctx;
    return allocator.dupe(u8, "snap");
}

/// capabilities JSON をパースし `std.json.Parsed(std.json.Value)` を返す（呼び出し側が `deinit()`）。
fn parseCapabilities(payload: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
}

test "capabilities: 予約名で登録拒否" {
    resetForTest();
    var c = TestProbeCtx{ .value = 1 };
    registerProbe(.{ .name = "capabilities", .ctx = &c, .digest = testProbeDigest });
    try testing.expectEqual(@as(usize, 0), probe_count);
}

test "capabilities: custom probe/action 0件 → 組み込み7 probe + actions:[]" {
    resetForTest();
    var buf: [MIN_CAPABILITIES_BUF_LEN]u8 = undefined;
    _ = &buf; // 使わない（capabilities_buf を直接使う）
    const payload = formatCapabilitiesPayload(&capabilities_buf);

    var parsed = try parseCapabilities(payload);
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqual(@as(?std.json.Value, null), root.get("truncated"));
    const probes_arr = root.get("probes").?.array.items;
    try testing.expectEqual(@as(usize, 7), probes_arr.len);
    const expected_names = [_][]const u8{ "fb", "audio", "stats", "capabilities", "capture", "gamepad", "midi" };
    for (probes_arr, 0..) |entry, i| {
        try testing.expectEqualStrings(expected_names[i], entry.object.get("name").?.string);
        try testing.expect(if (i == 6) !entry.object.get("snapshot").?.bool else entry.object.get("snapshot").?.bool);
        try testing.expect(entry.object.get("digest").?.bool);
    }
    try testing.expectEqual(@as(usize, 0), root.get("actions").?.array.items.len);
}

test "capabilities: custom probe/action がフィールド値・登録順で現れる" {
    resetForTest();
    var c1 = TestProbeCtx{ .value = 1 };
    var c2 = TestProbeCtx{ .value = 2 };
    registerProbe(.{ .name = "p1", .ctx = &c1, .ext = "png", .desc = "d1", .digest = testProbeDigest }); // digest-only
    registerProbe(.{ .name = "p2", .ctx = &c2, .ext = "json", .snapshot = testProbeSnapshot }); // snapshot-only・desc省略
    var ac1 = TestActionCtx{};
    var ac2 = TestActionCtx{};
    registerAction(.{ .name = "a1", .ctx = &ac1, .run = testActionRun, .desc = "ad1" });
    registerAction(.{ .name = "a2", .ctx = &ac2, .run = testActionRun }); // desc省略

    var parsed = try parseCapabilities(formatCapabilitiesPayload(&capabilities_buf));
    defer parsed.deinit();
    const root = parsed.value.object;
    const probes_arr = root.get("probes").?.array.items;
    try testing.expectEqual(@as(usize, 9), probes_arr.len); // 組み込み7 + custom2

    const p1 = probes_arr[7].object;
    try testing.expectEqualStrings("p1", p1.get("name").?.string);
    try testing.expectEqualStrings("png", p1.get("ext").?.string);
    try testing.expectEqualStrings("d1", p1.get("desc").?.string);
    try testing.expect(!p1.get("snapshot").?.bool);
    try testing.expect(p1.get("digest").?.bool);

    const p2 = probes_arr[8].object;
    try testing.expectEqualStrings("p2", p2.get("name").?.string);
    try testing.expectEqualStrings("json", p2.get("ext").?.string);
    try testing.expectEqualStrings("", p2.get("desc").?.string);
    try testing.expect(p2.get("snapshot").?.bool);
    try testing.expect(!p2.get("digest").?.bool);

    const actions_arr = root.get("actions").?.array.items;
    try testing.expectEqual(@as(usize, 2), actions_arr.len);
    try testing.expectEqualStrings("a1", actions_arr[0].object.get("name").?.string);
    try testing.expectEqualStrings("ad1", actions_arr[0].object.get("desc").?.string);
    try testing.expectEqualStrings("a2", actions_arr[1].object.get("name").?.string);
    try testing.expectEqualStrings("", actions_arr[1].object.get("desc").?.string);
}

test "capabilities: desc 規約違反（禁止文字・200 bytes 超）は登録時に空文字化" {
    resetForTest();
    var c = TestProbeCtx{ .value = 1 };
    registerProbe(.{ .name = "badp", .ctx = &c, .digest = testProbeDigest, .desc = "bad\"desc" });
    try testing.expectEqual(@as(usize, 0), findProbe("badp").?.desc.len);

    const long_desc = [_]u8{'a'} ** (MAX_DESC_LEN + 1);
    registerProbe(.{ .name = "badp2", .ctx = &c, .digest = testProbeDigest, .desc = &long_desc });
    try testing.expectEqual(@as(usize, 0), findProbe("badp2").?.desc.len);

    var ac = TestActionCtx{};
    registerAction(.{ .name = "bada", .ctx = &ac, .run = testActionRun, .desc = "bad\"desc" });
    try testing.expectEqual(@as(usize, 0), findAction("bada").?.desc.len);
}

test "capabilities: name の不正文字（\" / 制御文字）はエントリを省略し truncated=true（手前の正常エントリは残る）" {
    resetForTest();
    var c1 = TestProbeCtx{ .value = 1 };
    var c2 = TestProbeCtx{ .value = 2 };
    registerProbe(.{ .name = "good1", .ctx = &c1, .digest = testProbeDigest }); // 正常（先に登録）
    registerProbe(.{ .name = "bad\"name", .ctx = &c2, .digest = testProbeDigest }); // " を含む
    try testing.expectEqual(@as(usize, 2), probe_count); // 登録自体は成立する

    var parsed = try parseCapabilities(formatCapabilitiesPayload(&capabilities_buf));
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expect(root.get("truncated").?.bool);
    const probes_arr = root.get("probes").?.array.items;
    try testing.expectEqual(@as(usize, 8), probes_arr.len); // 組み込み7 + good1（bad は省略）
    try testing.expectEqualStrings("good1", probes_arr[7].object.get("name").?.string);
}

test "capabilities: action 名の制御文字（NUL。isValidActionName は通過するが JSON では不正）はエントリ省略+truncated" {
    resetForTest();
    var ac = TestActionCtx{};
    registerAction(.{ .name = "bad\x00name", .ctx = &ac, .run = testActionRun });
    try testing.expectEqual(@as(usize, 1), action_registry.actionCount()); // registerAction 自体は成立する

    var parsed = try parseCapabilities(formatCapabilitiesPayload(&capabilities_buf));
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expect(root.get("truncated").?.bool);
    try testing.expectEqual(@as(usize, 0), root.get("actions").?.array.items.len);
}

test "capabilities: ext の不正文字（tab）もエントリを省略し truncated=true" {
    resetForTest();
    var c = TestProbeCtx{ .value = 1 };
    registerProbe(.{ .name = "p", .ctx = &c, .ext = "bad\text", .digest = testProbeDigest });

    var parsed = try parseCapabilities(formatCapabilitiesPayload(&capabilities_buf));
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expect(root.get("truncated").?.bool);
    try testing.expectEqual(@as(usize, 7), root.get("probes").?.array.items.len); // 組み込み7のみ（p は省略）
}

test "capabilities: MIN_CAPABILITIES_BUF_LEN ちょうどの buf でもフェイルセーフで valid JSON + truncated=true" {
    resetForTest();
    var small_buf: [MIN_CAPABILITIES_BUF_LEN]u8 = undefined;
    const payload = formatCapabilitiesPayload(&small_buf);

    var parsed = try parseCapabilities(payload);
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expect(root.get("truncated").?.bool);
    try testing.expectEqual(@as(usize, 0), root.get("probes").?.array.items.len);
    try testing.expectEqual(@as(usize, 0), root.get("actions").?.array.items.len);
}

test "capabilities: buf 境界の全数チェック（probes は収まるが `,\"actions\":[` が収まらない等の境界も含め常に valid JSON）" {
    // codex レビューで発見された実バグ（"actions" セクション開始の追記失敗を無視し invalid JSON になる）の
    // 回帰テスト。ピンポイントの magic number ではなく MIN_CAPABILITIES_BUF_LEN から広い範囲を1バイト刻みで
    // 網羅し、どの buf サイズでも必ず valid JSON になることを固定する。
    resetForTest();
    var big_buf: [MIN_CAPABILITIES_BUF_LEN + 700]u8 = undefined;
    var n: usize = MIN_CAPABILITIES_BUF_LEN;
    while (n <= big_buf.len) : (n += 1) {
        const payload = formatCapabilitiesPayload(big_buf[0..n]);
        var parsed = parseCapabilities(payload) catch |err| {
            std.debug.print("buf len={d} で invalid JSON: {s}\npayload={s}\n", .{ n, @errorName(err), payload });
            return err;
        };
        parsed.deinit();
    }
}

test "capabilities: digestPayload 経由（digest capabilities）でも同じ JSON が得られる" {
    resetForTest();
    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    switch (digestPayload("capabilities", &buf)) {
        .ok => |payload| {
            var parsed = try parseCapabilities(payload);
            defer parsed.deinit();
            try testing.expectEqual(@as(usize, 7), parsed.value.object.get("probes").?.array.items.len);
        },
        .unavailable => try testing.expect(false),
    }
}

test "capabilities: pollGate 経由（digest capabilities コマンド）でも例外なく処理される" {
    resetForTest();
    cmd_buf = "digest capabilities";
    try testing.expect(!pollGate(true)); // EOF → replay 終了（expect_failures=0 なので exit しない）
}

// ============================================================================
// null runtime query（TASK-165）— 一次 buffer は platform_null。ここは互換 setter/query のみ。
// ============================================================================

test "setHeadlessActive / isHeadlessActive: platform 互換 query" {
    resetForTest();
    defer resetForTest();
    try testing.expect(!isHeadlessActive());
    setHeadlessActive(true);
    try testing.expect(isHeadlessActive());
    setHeadlessActive(false);
    try testing.expect(!isHeadlessActive());
}

// ============================================================================
// synthetic capture source（TASK-49.5）tests
// ============================================================================

test "isCaptureSyntheticActive: 既定（env 未設定）では harness の有効/無効に関わらず false" {
    resetForTest(); // mode=.replay
    defer resetForTest();
    try testing.expect(!isCaptureSyntheticActive());
    mode = .disabled;
    try testing.expect(!isCaptureSyntheticActive());
}

test "isCaptureSyntheticActive: requested かつ harness 有効（replay/live）のときのみ true" {
    resetForTest(); // mode=.replay
    defer resetForTest();
    capture_synthetic_requested = true;
    try testing.expect(isCaptureSyntheticActive());
    mode = .live;
    try testing.expect(isCaptureSyntheticActive());
    mode = .disabled;
    try testing.expect(!isCaptureSyntheticActive()); // requested でも harness 無効なら false
}

test "capture コマンド: synthetic 無効時は fail-fast（warn のみ、状態変化なし）" {
    resetForTest();
    defer resetForTest();
    // capture_synthetic_requested は既定 false のまま = synthetic 無効
    cmd_buf = "capture video open 8 8\ncapture audio open\nquit";
    while (pollGate(true)) {}
    try testing.expect(synth_video == null);
    try testing.expect(synth_audio == null);
    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    try testing.expectEqualStrings("video_open=0 video_w=0 video_h=0 video_frame=0 audio_open=0 audio_frames=0 audio_peak=0.0000", formatCapturePayload(&buf));
}

test "capture video: video_frame は harness の仮想クロック(frame_index)に連動する（present で進む）" {
    resetForTest();
    defer resetForTest();
    capture_synthetic_requested = true;
    cmd_buf = "capture video open 8 8 24\nquit";
    while (pollGate(true)) {}
    try testing.expect(synth_video != null);

    // frame_index は `step` コマンド自体ではなく app の onPresent() 呼び出しで進む契約
    // （仮想クロック節参照）。ここでは app 無しで直接3フレーム分 present し、仮想クロックが
    // 進んだことと `capture` probe の `video_frame` がそれに連動することを確認する。
    const px = [_]u32{0xFF000000};
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        onLock(&px, 1, 1);
        onPresent();
    }
    try testing.expectEqual(@as(u64, 3), frame_index);

    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    try testing.expectEqualStrings("video_open=1 video_w=8 video_h=8 video_frame=3 audio_open=0 audio_frames=0 audio_peak=0.0000", formatCapturePayload(&buf));

    if (synth_video) |*dev| dev.close();
    synth_video = null;
}

test "capture video open: 状態が digest に反映される（close 前）" {
    resetForTest();
    defer resetForTest();
    capture_synthetic_requested = true;
    cmd_buf = "capture video open 16 8\nquit";
    while (pollGate(true)) {}
    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    try testing.expectEqualStrings("video_open=1 video_w=16 video_h=8 video_frame=0 audio_open=0 audio_frames=0 audio_peak=0.0000", formatCapturePayload(&buf));
}

test "capture video open: width/height=0 は ConfigFailed で synth_video は null のまま" {
    resetForTest();
    defer resetForTest();
    capture_synthetic_requested = true;
    cmd_buf = "capture video open 0 8\nquit";
    while (pollGate(true)) {}
    try testing.expect(synth_video == null);
}

test "capture video open: 2回目の open は前の device を閉じてから開き直す（リーク無し）" {
    resetForTest();
    defer resetForTest();
    capture_synthetic_requested = true;
    cmd_buf = "capture video open 8 8\ncapture video open 4 4\nquit";
    while (pollGate(true)) {}
    try testing.expect(synth_video != null);
    try testing.expectEqual(@as(u32, 4), synth_video.?.width);
}

test "capture video: snapshot は video 未 open なら skip（present 前 fb skip と同じ思想）" {
    resetForTest();
    defer resetForTest();
    capture_synthetic_requested = true;
    cmd_buf = "snapshot capture /tmp/should_not_write_capture.png\nquit";
    while (pollGate(true)) {}
    try testing.expect(synth_video == null);
}

test "capture audio: open→close で probe 状態がリセットされる（実時間検証は capture_synthetic.zig 側の単体テストで実施）" {
    resetForTest();
    defer resetForTest();
    capture_synthetic_requested = true;
    cmd_buf = "capture audio open 48000 1 440\nquit";
    while (pollGate(true)) {}
    try testing.expect(synth_audio != null);
    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    const payload = formatCapturePayload(&buf);
    try testing.expect(std.mem.indexOf(u8, payload, "audio_open=1") != null);

    resetForTest(); // クリーンアップ（stop+join+close）が安全に終わることを確認
    try testing.expect(synth_audio == null);
}

test "capabilities: capture probe が組み込み一覧に含まれる" {
    resetForTest();
    var parsed = try parseCapabilities(formatCapabilitiesPayload(&capabilities_buf));
    defer parsed.deinit();
    const probes_arr = parsed.value.object.get("probes").?.array.items;
    var found = false;
    for (probes_arr) |entry| {
        if (std.mem.eql(u8, entry.object.get("name").?.string, "capture")) {
            found = true;
            try testing.expectEqualStrings("png", entry.object.get("ext").?.string);
            try testing.expect(entry.object.get("snapshot").?.bool);
            try testing.expect(entry.object.get("digest").?.bool);
        }
    }
    try testing.expect(found);
}

test "capabilities: gamepad probe が組み込み一覧に含まれる" {
    resetForTest();
    var parsed = try parseCapabilities(formatCapabilitiesPayload(&capabilities_buf));
    defer parsed.deinit();
    const probes_arr = parsed.value.object.get("probes").?.array.items;
    var found = false;
    for (probes_arr) |entry| {
        if (std.mem.eql(u8, entry.object.get("name").?.string, "gamepad")) {
            found = true;
            try testing.expectEqualStrings("txt", entry.object.get("ext").?.string);
            try testing.expect(entry.object.get("snapshot").?.bool);
            try testing.expect(entry.object.get("digest").?.bool);
        }
    }
    try testing.expect(found);
}

test "capabilities: midi probe は digest 専用で組み込み一覧に含まれる" {
    resetForTest();
    var parsed = try parseCapabilities(formatCapabilitiesPayload(&capabilities_buf));
    defer parsed.deinit();
    const probes_arr = parsed.value.object.get("probes").?.array.items;
    var found = false;
    for (probes_arr) |entry| {
        if (std.mem.eql(u8, entry.object.get("name").?.string, "midi")) {
            found = true;
            try testing.expectEqualStrings("txt", entry.object.get("ext").?.string);
            try testing.expect(!entry.object.get("snapshot").?.bool);
            try testing.expect(entry.object.get("digest").?.bool);
        }
    }
    try testing.expect(found);
}

// ============================================================================
// capabilities args シグネチャ（TASK-88.1）tests
// ============================================================================

test "capabilities: args=null の action/probe → JSON が従来と文字列一致（args フィールド無し）" {
    resetForTest();
    var c = TestProbeCtx{ .value = 1 };
    var ac = TestActionCtx{};
    // .args 省略（= null）で登録
    registerProbe(.{ .name = "pnull", .ctx = &c, .ext = "txt", .desc = "pd", .digest = testProbeDigest });
    registerAction(.{ .name = "anull", .ctx = &ac, .run = testActionRun, .desc = "ad" });

    var saved: [capabilities_buf.len]u8 = undefined;
    const payload0 = formatCapabilitiesPayload(&capabilities_buf);
    @memcpy(saved[0..payload0.len], payload0);
    const payload = saved[0..payload0.len];
    // 文字列レベルで "args" キーが一切出ない（フィールド追加のみ方針の回帰ゼロ）
    try testing.expect(std.mem.indexOf(u8, payload, "\"args\"") == null);

    // エントリ形が従来どおり name/desc（+ probe は ext/snapshot/digest）のみ
    var parsed = try parseCapabilities(payload);
    defer parsed.deinit();
    const probes_arr = parsed.value.object.get("probes").?.array.items;
    const p = probes_arr[probes_arr.len - 1].object;
    try testing.expectEqualStrings("pnull", p.get("name").?.string);
    try testing.expect(p.get("args") == null);
    const a = parsed.value.object.get("actions").?.array.items[0].object;
    try testing.expectEqualStrings("anull", a.get("name").?.string);
    try testing.expectEqualStrings("ad", a.get("desc").?.string);
    try testing.expect(a.get("args") == null);

    // 明示 .args=null も省略時と bit 一致
    resetForTest();
    registerProbe(.{ .name = "pnull", .ctx = &c, .ext = "txt", .desc = "pd", .digest = testProbeDigest, .args = null });
    registerAction(.{ .name = "anull", .ctx = &ac, .run = testActionRun, .desc = "ad", .args = null });
    const payload2 = formatCapabilitiesPayload(&capabilities_buf);
    try testing.expectEqualStrings(payload, payload2);
}

test "capabilities: args 付き action → 非デフォルトフィールドのみ emit" {
    resetForTest();
    var ac = TestActionCtx{};
    const specs = [_]ArgSpec{
        .{
            .name = "tool",
            .kind = "enum",
            .values = &.{ "pen", "eraser" },
            .optional = true,
            .desc = "tool name",
        },
        .{
            .name = "n",
            .kind = "int",
            .min = 0,
            .max = 255,
            .variadic = true,
        },
        .{
            .name = "color",
            .kind = "string",
            .pattern = "#?RRGGBB",
        },
    };
    registerAction(.{ .name = "full", .ctx = &ac, .run = testActionRun, .args = &specs });

    var parsed = try parseCapabilities(formatCapabilitiesPayload(&capabilities_buf));
    defer parsed.deinit();
    const a = parsed.value.object.get("actions").?.array.items[0].object;
    const args_arr = a.get("args").?.array.items;
    try testing.expectEqual(@as(usize, 3), args_arr.len);

    const t0 = args_arr[0].object;
    try testing.expectEqualStrings("tool", t0.get("name").?.string);
    try testing.expectEqualStrings("enum", t0.get("kind").?.string);
    try testing.expectEqual(@as(usize, 2), t0.get("values").?.array.items.len);
    try testing.expectEqualStrings("pen", t0.get("values").?.array.items[0].string);
    try testing.expect(t0.get("optional").?.bool);
    try testing.expectEqualStrings("tool name", t0.get("desc").?.string);
    try testing.expect(t0.get("min") == null);
    try testing.expect(t0.get("max") == null);
    try testing.expect(t0.get("pattern") == null);
    try testing.expect(t0.get("variadic") == null); // false は省略

    const t1 = args_arr[1].object;
    // JSON 数値は整数リテラルだと .integer になりうる（0/255）
    const min_f: f64 = switch (t1.get("min").?) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => return error.TestUnexpectedResult,
    };
    const max_f: f64 = switch (t1.get("max").?) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(f64, 0), min_f);
    try testing.expectEqual(@as(f64, 255), max_f);
    try testing.expect(t1.get("variadic").?.bool);
    try testing.expect(t1.get("values") == null);
    try testing.expect(t1.get("optional") == null);

    const t2 = args_arr[2].object;
    try testing.expectEqualStrings("#?RRGGBB", t2.get("pattern").?.string);
    try testing.expect(t2.get("desc") == null);
}

test "capabilities: 空 slice → args:[] が現れ null と区別される" {
    resetForTest();
    var ac = TestActionCtx{};
    const empty: []const ArgSpec = &.{};
    registerAction(.{ .name = "none", .ctx = &ac, .run = testActionRun, .args = empty });

    const payload = formatCapabilitiesPayload(&capabilities_buf);
    try testing.expect(std.mem.indexOf(u8, payload, "\"args\":[]") != null);

    var parsed = try parseCapabilities(payload);
    defer parsed.deinit();
    const a = parsed.value.object.get("actions").?.array.items[0].object;
    try testing.expectEqual(@as(usize, 0), a.get("args").?.array.items.len);
}

test "capabilities: args サニタイズ違反（kind 制御文字 / values に \" / pattern 100B 超）→ warn + args 消失・登録成功" {
    resetForTest();
    var ac = TestActionCtx{};
    var c = TestProbeCtx{ .value = 1 };

    // kind に制御文字
    const bad_kind = [_]ArgSpec{.{ .name = "x", .kind = "in\tt" }};
    registerAction(.{ .name = "bk", .ctx = &ac, .run = testActionRun, .args = &bad_kind });
    try testing.expect(findAction("bk") != null);
    try testing.expect(findAction("bk").?.args == null);

    // values に "
    const bad_val = [_]ArgSpec{.{ .name = "x", .kind = "enum", .values = &.{"a\"b"} }};
    registerAction(.{ .name = "bv", .ctx = &ac, .run = testActionRun, .args = &bad_val });
    try testing.expect(findAction("bv") != null);
    try testing.expect(findAction("bv").?.args == null);

    // pattern 100B 超
    const long_pat = [_]u8{'p'} ** (MAX_ARG_PATTERN_LEN + 1);
    const bad_pat = [_]ArgSpec{.{ .name = "x", .kind = "string", .pattern = &long_pat }};
    registerAction(.{ .name = "bp", .ctx = &ac, .run = testActionRun, .args = &bad_pat });
    try testing.expect(findAction("bp") != null);
    try testing.expect(findAction("bp").?.args == null);

    // probe 側も同規則
    const bad_probe = [_]ArgSpec{.{ .name = "x", .kind = "in\tt" }};
    registerProbe(.{ .name = "bp2", .ctx = &c, .digest = testProbeDigest, .args = &bad_probe });
    try testing.expect(findProbe("bp2") != null);
    try testing.expect(findProbe("bp2").?.args == null);

    // capabilities JSON にも args が載らない（消失後）
    const payload = formatCapabilitiesPayload(&capabilities_buf);
    try testing.expect(std.mem.indexOf(u8, payload, "\"args\"") == null);

    // min/max の非有限値（NaN/Inf は JSON 数値にならない）→ args 消失・登録成功（codex P2）
    const nan_min = [_]ArgSpec{.{ .name = "x", .kind = "int", .min = std.math.nan(f64) }};
    registerAction(.{ .name = "bnan", .ctx = &ac, .run = testActionRun, .args = &nan_min });
    try testing.expect(findAction("bnan") != null);
    try testing.expect(findAction("bnan").?.args == null);
    const inf_max = [_]ArgSpec{.{ .name = "x", .kind = "int", .max = std.math.inf(f64) }};
    registerProbe(.{ .name = "binf", .ctx = &c, .digest = testProbeDigest, .args = &inf_max });
    try testing.expect(findProbe("binf") != null);
    try testing.expect(findProbe("binf").?.args == null);
}

test "capabilities: 大量 args で buf 溢れても既存 truncated 機構で valid JSON を維持" {
    resetForTest();
    var ac = TestActionCtx{};
    // 長大 desc 付き ArgSpec を多数載せ、entry が content_limit に収まらない経路を踏む
    const long_desc = [_]u8{'d'} ** 200;
    var many: [40]ArgSpec = undefined;
    for (&many) |*s| {
        s.* = .{ .name = "argname", .kind = "string", .desc = &long_desc };
    }
    registerAction(.{ .name = "huge", .ctx = &ac, .run = testActionRun, .args = &many });

    // 小さめ buf で capabilities を組み立て → 必ず valid JSON
    var small: [MIN_CAPABILITIES_BUF_LEN + 200]u8 = undefined;
    const payload = formatCapabilitiesPayload(&small);
    var parsed = try parseCapabilities(payload);
    defer parsed.deinit();
    // truncated か、収まったかのどちらでも JSON として valid であればよい
    _ = parsed.value.object.get("probes");
    _ = parsed.value.object.get("actions");
}

// ============================================================================
// MIDI（TASK-115.1・ADR-010）tests
// ============================================================================

test "MIDI inject: note/cc/note-off の FIFO 順序と state 更新" {
    resetForTest();
    cmd_buf =
        "inject midi note_on 60 100\n" ++
        "inject midi cc 7 96\n" ++
        "inject midi note_off 60 12\n" ++
        "step 1\nquit";
    try testing.expect(pollGate(true));

    const first = nextMidiEvent().?;
    try testing.expect(first == .note_on);
    try testing.expectEqual(@as(MidiDeviceId, 0), first.note_on.device_id);
    try testing.expectEqual(@as(u8, 60), first.note_on.note);
    const second = nextMidiEvent().?;
    try testing.expect(second == .cc);
    try testing.expectEqual(@as(u8, 7), second.cc.controller);
    const third = nextMidiEvent().?;
    try testing.expect(third == .note_off);
    try testing.expectEqual(@as(u8, 12), third.note_off.velocity);
    try testing.expectEqual(@as(?MidiEvent, null), nextMidiEvent());

    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    const digest = switch (digestPayload("midi", &buf)) {
        .ok => |payload| payload,
        .unavailable => return error.UnexpectedResult,
    };
    try testing.expect(std.mem.startsWith(u8, digest, "midi device=0 note_count=0 notes="));
    try testing.expect(std.mem.indexOf(u8, digest, "cc_count=1") != null);
    const cc_pos = std.mem.indexOf(u8, digest, "cc=").? + 3;
    try testing.expectEqualStrings("60", digest[cc_pos + 7 * 2 ..][0..2]);
}

test "MIDI inject: note_on velocity 0 は note_off に正規化される" {
    resetForTest();
    cmd_buf = "inject midi note_on 9 0\nstep 1";
    try testing.expect(pollGate(true));
    const ev = nextMidiEvent().?;
    try testing.expect(ev == .note_off);
    try testing.expectEqual(@as(u8, 9), ev.note_off.note);
    try testing.expectEqual(@as(?MidiEvent, null), nextMidiEvent());

    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    const digest = switch (digestPayload("midi", &buf)) {
        .ok => |payload| payload,
        .unavailable => return error.UnexpectedResult,
    };
    try testing.expect(std.mem.indexOf(u8, digest, "note_count=0") != null);
}

test "MIDI inject: 範囲外・未知 event・引数不足は queue/state を変更しない" {
    resetForTest();
    cmd_buf =
        "inject midi note_on 60 100\n" ++
        "inject midi note_on 128 1\n" ++
        "inject midi cc 8 128\n" ++
        "inject midi bogus 1 2\n" ++
        "inject midi note_off\n" ++
        "step 1";
    try testing.expect(pollGate(true));
    const ev = nextMidiEvent().?;
    try testing.expect(ev == .note_on);
    try testing.expectEqual(@as(?MidiEvent, null), nextMidiEvent());

    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    const digest = switch (digestPayload("midi", &buf)) {
        .ok => |payload| payload,
        .unavailable => return error.UnexpectedResult,
    };
    try testing.expect(std.mem.indexOf(u8, digest, "note_count=1") != null);
    try testing.expect(std.mem.indexOf(u8, digest, "cc_count=0") != null);
}

test "MIDI digest: 空状態は固定順序・固定長で 1024B 未満" {
    resetForTest();
    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    const digest = switch (digestPayload("midi", &buf)) {
        .ok => |payload| payload,
        .unavailable => return error.UnexpectedResult,
    };
    try testing.expect(digest.len < DIGEST_BUF_LEN);
    try testing.expect(std.mem.startsWith(u8, digest, "midi device=0 note_count=0 notes="));
    try testing.expect(std.mem.indexOf(u8, digest, " cc_count=0 cc=") != null);
    try testing.expectEqual(@as(usize, 256), digest[digest.len - 256 ..].len);

    // 0/127 note と controller 0/127 を昇順 wire order で出す。
    midi_pressed[0] |= 1;
    midi_pressed[15] |= 0x80;
    midi_cc_values[0] = 0;
    midi_cc_values[127] = 127;
    midi_cc_set[0] = true;
    midi_cc_set[127] = true;
    const ordered = switch (digestPayload("midi", &buf)) {
        .ok => |payload| payload,
        .unavailable => return error.UnexpectedResult,
    };
    const notes_pos = std.mem.indexOf(u8, ordered, "notes=").? + 6;
    try testing.expectEqualStrings("01", ordered[notes_pos..][0..2]);
    try testing.expectEqualStrings("80", ordered[notes_pos + 30 ..][0..2]);
    const cc_pos = std.mem.indexOf(u8, ordered, "cc=").? + 3;
    try testing.expectEqualStrings("00", ordered[cc_pos..][0..2]);
    try testing.expectEqualStrings("7F", ordered[cc_pos + 127 * 2 ..][0..2]);
}

test "MIDI reset: state と FIFO が空になる" {
    resetForTest();
    cmd_buf = "inject midi note_on 1 1\ninject midi cc 2 3\nstep 1";
    try testing.expect(pollGate(true));
    resetForTest();
    try testing.expectEqual(@as(?MidiEvent, null), nextMidiEvent());
    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    const digest = switch (digestPayload("midi", &buf)) {
        .ok => |payload| payload,
        .unavailable => return error.UnexpectedResult,
    };
    try testing.expect(std.mem.indexOf(u8, digest, "note_count=0") != null);
    try testing.expect(std.mem.indexOf(u8, digest, "cc_count=0") != null);
}

// ============================================================================
// gamepad（TASK-80.1。ADR-009）tests
// ============================================================================

test "gamepad: 未接続時は getGamepadState が全 index で null" {
    resetForTest();
    var i: u8 = 0;
    while (i < MAX_GAMEPADS) : (i += 1) {
        try testing.expectEqual(@as(?GamepadState, null), getGamepadState(i));
    }
    try testing.expectEqual(@as(?GamepadState, null), getGamepadState(MAX_GAMEPADS)); // 範囲外
}

test "inject gamepad_connect/disconnect: state 更新 + Event 発火 + digest の connected ビット" {
    resetForTest();
    cmd_buf =
        \\inject gamepad_connect 0 TestPad
        \\step 1
        \\digest gamepad
        \\inject gamepad_disconnect 0
        \\step 1
        \\digest gamepad
        \\quit
    ;

    try testing.expect(pollGate(true));
    var e = nextInjectedEvent().?;
    try testing.expect(e == .gamepad_connected);
    try testing.expectEqual(@as(u8, 0), e.gamepad_connected.index);
    try testing.expectEqualStrings("TestPad", e.gamepad_connected.name());
    try testing.expect(std.meta.eql(getGamepadState(0).?, GamepadState{})); // 既定 state（全0）

    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    try testing.expectEqualStrings(
        "connected=1 p0_buttons=00000000 p0_lx=0.0000 p0_ly=0.0000 p0_rx=0.0000 p0_ry=0.0000 p0_lt=0.0000 p0_rt=0.0000",
        formatGamepadPayload(&buf),
    );

    try testing.expect(pollGate(true));
    e = nextInjectedEvent().?;
    try testing.expect(e == .gamepad_disconnected);
    try testing.expectEqual(@as(u8, 0), e.gamepad_disconnected.index);
    try testing.expectEqual(@as(?GamepadState, null), getGamepadState(0));
    try testing.expectEqualStrings("connected=0", formatGamepadPayload(&buf));

    try testing.expect(!pollGate(true));
}

test "inject gamepad_button/gamepad_axis: 接続済み pad の state を更新する" {
    resetForTest();
    cmd_buf =
        \\inject gamepad_connect 0
        \\inject gamepad_button 0 a 1
        \\inject gamepad_button 0 start 1
        \\inject gamepad_axis 0 left_x 0.5
        \\inject gamepad_axis 0 left_y -0.25
        \\inject gamepad_axis 0 right_trigger 1
        \\step 1
        \\quit
    ;
    try testing.expect(pollGate(true));
    const st = getGamepadState(0).?;
    try testing.expect(st.buttons.isSet(.a));
    try testing.expect(st.buttons.isSet(.start));
    try testing.expect(!st.buttons.isSet(.b));
    try testing.expectApproxEqAbs(@as(f32, 0.5), st.left_stick.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -0.25), st.left_stick.y, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), st.right_trigger, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), st.right_stick.x, 1e-6);

    // 別ボタンを off にしても他ボタンは無変更（bit 独立性）
    cmd_buf = "inject gamepad_button 0 a 0\nstep 1\nquit";
    cursor = 0;
    try testing.expect(pollGate(true));
    const st2 = getGamepadState(0).?;
    try testing.expect(!st2.buttons.isSet(.a));
    try testing.expect(st2.buttons.isSet(.start));
}

test "inject gamepad_button/gamepad_axis: 未接続 pad への操作は fail-fast（state 不変・注入なし）" {
    resetForTest();
    cmd_buf =
        \\inject gamepad_button 0 a 1
        \\inject gamepad_axis 0 left_x 0.5
        \\step 1
        \\quit
    ;
    try testing.expect(pollGate(true));
    try testing.expectEqual(@as(?GamepadState, null), getGamepadState(0));
}

test "inject gamepad_button: 不明ボタン名・値不正（0/1以外）は拒否" {
    resetForTest();
    cmd_buf =
        \\inject gamepad_connect 0
        \\inject gamepad_button 0 nosuch 1
        \\inject gamepad_button 0 a 2
        \\step 1
        \\quit
    ;
    try testing.expect(pollGate(true));
    const st = getGamepadState(0).?;
    try testing.expect(!st.buttons.isSet(.a)); // どちらも拒否され state は既定のまま
}

test "inject gamepad_axis: 値域外（stick|trigger）は拒否（state 不変）" {
    resetForTest();
    cmd_buf =
        \\inject gamepad_connect 0
        \\inject gamepad_axis 0 left_x 1.5
        \\inject gamepad_axis 0 left_trigger -0.1
        \\inject gamepad_axis 0 nosuch 0.5
        \\step 1
        \\quit
    ;
    try testing.expect(pollGate(true));
    const st = getGamepadState(0).?;
    try testing.expectEqual(@as(f32, 0), st.left_stick.x);
    try testing.expectEqual(@as(f32, 0), st.left_trigger);
}

test "inject gamepad_axis: NaN/inf は素通りせず拒否（codex レビューで発見した抜け穴の回帰）" {
    // `v < lo or v > hi` は NaN では両方 false になり素通りしうるため、明示 reject が必要。
    resetForTest();
    cmd_buf =
        \\inject gamepad_connect 0
        \\inject gamepad_axis 0 left_x nan
        \\inject gamepad_axis 0 left_y inf
        \\inject gamepad_axis 0 left_trigger -inf
        \\step 1
        \\quit
    ;
    try testing.expect(pollGate(true));
    const st = getGamepadState(0).?;
    try testing.expectEqual(@as(f32, 0), st.left_stick.x);
    try testing.expectEqual(@as(f32, 0), st.left_stick.y);
    try testing.expectEqual(@as(f32, 0), st.left_trigger);
}

test "setGamepadAxis: NaN/inf は直接呼び出しでも false（state 不変）" {
    var st = GamepadState{};
    try testing.expect(!setGamepadAxis(&st, "left_x", std.math.nan(f32)));
    try testing.expect(!setGamepadAxis(&st, "right_trigger", std.math.inf(f32)));
    try testing.expectEqual(@as(f32, 0), st.left_stick.x);
    try testing.expectEqual(@as(f32, 0), st.right_trigger);
}

test "inject gamepad_connect/gamepad_button/gamepad_disconnect: index 範囲外は拒否" {
    resetForTest();
    cmd_buf =
        \\inject gamepad_connect 99
        \\inject gamepad_button 99 a 1
        \\inject gamepad_disconnect 99
        \\step 1
        \\quit
    ;
    try testing.expect(pollGate(true));
    var i: u8 = 0;
    while (i < MAX_GAMEPADS) : (i += 1) try testing.expectEqual(@as(?GamepadState, null), getGamepadState(i));
}

test "inject commit: UTF-8 文字列を codepoint 分解して char_input 連続 queue（TASK-79.6.1）" {
    resetForTest();
    // こんにちは = U+3053 U+3093 U+306B U+3061 U+306F（5 codepoints）
    cmd_buf =
        \\inject composition update 0 x
        \\inject commit こんにちは
        \\step 1
        \\quit
    ;
    try testing.expect(pollGate(true));
    try testing.expect(nextInjectedEvent().? == .composition_changed);
    try testing.expect(nextInjectedEvent().? == .composition_changed);
    const expected = [_]u32{ 0x3053, 0x3093, 0x306B, 0x3061, 0x306F };
    for (expected) |want| {
        const e = nextInjectedEvent().?;
        try testing.expect(e == .char_input);
        try testing.expectEqual(want, e.char_input.codepoint);
        try testing.expect(!e.char_input.modifiers.shift);
        try testing.expect(!e.char_input.modifiers.ctrl);
        try testing.expect(!e.char_input.modifiers.alt);
        try testing.expect(!e.char_input.modifiers.cmd);
    }
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());
    try testing.expect(!pollGate(true));
}

test "inject commit: 空テキスト / 不正 UTF-8 は fail-fast（注入なし）" {
    resetForTest();
    cmd_buf =
        \\inject commit
        \\inject commit 
        \\step 1
        \\quit
    ;
    try testing.expect(pollGate(true));
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());
    try testing.expect(!pollGate(true));
}

test "inject commit: 不正 UTF-8 は途中まで注入せずゼロ件（codex 修正 C）" {
    resetForTest();
    // 先頭 'A' は valid だが後続 0xFF で不正。Pass1 全量検証で拒否し、A も queue しない。
    cmd_buf = "inject composition update 0 x\ninject commit A\xffZ\nstep 1\nquit";
    try testing.expect(pollGate(true));
    try testing.expect(nextInjectedEvent().? == .composition_changed);
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());
    try testing.expect(!pollGate(true));
}

test "inject commit: 区切り後の前後空白を保持（codex 修正 D / record→replay 対称）" {
    resetForTest();
    // `commit` 直後の区切り 1 空白の後ろ: " a b "（先頭スペース + a + スペース + b + 末尾スペース）
    // → 5 codepoints。行末スペースは line の左 trim のみ方針で保持。
    cmd_buf = "inject composition update 0 x\ninject commit  a b \nstep 1\nquit";
    try testing.expect(pollGate(true));
    try testing.expect(nextInjectedEvent().? == .composition_changed);
    try testing.expect(nextInjectedEvent().? == .composition_changed);
    const expected = [_]u32{ ' ', 'a', ' ', 'b', ' ' };
    for (expected) |want| {
        const e = nextInjectedEvent().?;
        try testing.expect(e == .char_input);
        try testing.expectEqual(want, e.char_input.codepoint);
    }
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());
}

test "inject commit: ASCII 混在も char_input 連続（inject char と同経路）" {
    resetForTest();
    cmd_buf =
        \\inject composition update 0 x
        \\inject commit Ab
        \\step 1
        \\quit
    ;
    try testing.expect(pollGate(true));
    try testing.expect(nextInjectedEvent().? == .composition_changed);
    try testing.expect(nextInjectedEvent().? == .composition_changed);
    const e0 = nextInjectedEvent().?;
    try testing.expect(e0 == .char_input and e0.char_input.codepoint == 'A');
    const e1 = nextInjectedEvent().?;
    try testing.expect(e1 == .char_input and e1.char_input.codepoint == 'b');
    try testing.expectEqual(@as(?Event, null), nextInjectedEvent());
}

test "gamepad probe digest: 複数 pad 接続時は connected ビットマスクと p<idx>_ prefix が両立する" {
    resetForTest();
    cmd_buf =
        \\inject gamepad_connect 0
        \\inject gamepad_connect 2
        \\inject gamepad_axis 2 right_y -1
        \\step 1
        \\quit
    ;
    try testing.expect(pollGate(true));
    var buf: [DIGEST_BUF_LEN]u8 = undefined;
    const payload = formatGamepadPayload(&buf);
    try testing.expect(std.mem.startsWith(u8, payload, "connected=5 ")); // pad0(bit0)+pad2(bit2) = 0b101 = 5
    try testing.expect(std.mem.indexOf(u8, payload, "p0_buttons=") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "p1_buttons=") == null); // pad1 は未接続
    try testing.expect(std.mem.indexOf(u8, payload, "p2_ry=-1.0000") != null);
}

test "gamepad probe: digest コマンド経由（headless replay の self-check 経路）でも同じ payload が得られる" {
    resetForTest(); // mode=.replay
    cmd_buf = "inject gamepad_connect 0\nstep 1\nquit";
    try testing.expect(pollGate(true)); // inject 消費 + step
    try testing.expect(!pollGate(true)); // quit → 終了

    // digest のルーティング自体は live framing で確認（既存 "custom probe: register + digest routing" と同型）。
    mode = .live;
    resp_buf.clearRetainingCapacity();
    defer resp_buf.clearRetainingCapacity();
    var it = std.mem.tokenizeAny(u8, "gamepad", " \t");
    handleDigest(&it);
    try testing.expect(std.mem.startsWith(u8, resp_buf.items, "gamepad connected=1 "));
}

test "harness onLock/onPresent: 観測 copy は platform buffer 借用から frame_pixels へ" {
    resetForTest();
    defer resetForTest();

    var pixels = [_]u32{ 0xFF112233, 0xFF112233, 0xFF112233, 0xFF112233 };
    onLock(&pixels, 2, 2);
    onPresent();
    try testing.expect(have_frame);
    try testing.expectEqual(@as(u32, 0xFF112233), frame_pixels[0]);
    try testing.expectEqual(@as(u32, 0xFF112233), frame_pixels[3]);
}

fn testSleepMs(ms: u64) void {
    const sec: i64 = @intCast(ms / 1000);
    const nsec: i64 = @intCast((ms % 1000) * 1_000_000);
    const req = std.posix.timespec{ .sec = sec, .nsec = nsec };
    _ = std.c.nanosleep(&req, null);
}

fn initLiveServerForTest() !u16 {
    threaded = std.Io.Threaded.init(gpa, .{});
    io_val = threaded.io();
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(0) };
    server = try addr.listen(io_val, .{ .reuse_address = true });
    mode = .live;
    clock_mode = .manual; // 既存 live pump テストは blocking 契約
    cmd_buf = "";
    cursor = 0;
    line_no = 0;
    steps_remaining = 0;
    quit_requested = false;
    pending_wait = .none;
    live_req_open = false;
    freerun_reading = false;
    req_bytes = &.{};
    resp_buf.clearRetainingCapacity();
    return server.socket.address.getPort();
}

fn deinitLiveServerForTest() void {
    if (live_req_open) finishLiveRequest();
    server.deinit(io_val);
    test_live_poll_timeout_ms = null;
    mode = .replay;
    cmd_buf = "";
    cursor = 0;
}

test "pollGateWithPump: null pump は pollGate と同じ（replay）" {
    const runSequence = struct {
        fn run(use_with_pump: bool) [2]bool {
            resetForTest();
            cmd_buf = "step 1\nquit";
            return .{
                if (use_with_pump) pollGateWithPump(true, null) else pollGate(true),
                if (use_with_pump) pollGateWithPump(true, null) else pollGate(true),
            };
        }
    }.run;
    try testing.expectEqual(runSequence(false), runSequence(true));
}

test "pollGateWithPump: replay では fake pump が呼ばれない" {
    resetForTest();
    cmd_buf = "step 1\nquit";
    var pump_count: usize = 0;
    const PumpCtx = struct { count: *usize };
    var ctx = PumpCtx{ .count = &pump_count };
    const pump = NativePump{
        .ptr = @ptrCast(&ctx),
        .pollFn = struct {
            fn poll(p: *anyopaque) bool {
                const c: *PumpCtx = @ptrCast(@alignCast(p));
                c.count.* += 1;
                return true;
            }
        }.poll,
    };
    try testing.expect(pollGateWithPump(true, pump));
    try testing.expectEqual(@as(usize, 0), pump_count);
}

test "pollGateWithPump: fake pump false で live accept 待機を中断" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    resetForTest();
    test_live_poll_timeout_ms = 5;
    _ = initLiveServerForTest() catch return error.SkipZigTest;
    defer deinitLiveServerForTest();

    const pump = NativePump{
        .ptr = undefined,
        .pollFn = struct {
            fn poll(_: *anyopaque) bool {
                return false;
            }
        }.poll,
    };
    try testing.expect(!pollGateWithPump(true, pump));
}

test "live pump: accept 待機中に fake pump が呼ばれる" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    resetForTest();
    test_live_poll_timeout_ms = 5;
    const port = initLiveServerForTest() catch return error.SkipZigTest;
    defer deinitLiveServerForTest();

    var pump_count: usize = 0;
    const PumpCtx = struct { count: *usize };
    var ctx = PumpCtx{ .count = &pump_count };
    const pump = NativePump{
        .ptr = @ptrCast(&ctx),
        .pollFn = struct {
            fn poll(p: *anyopaque) bool {
                const c: *PumpCtx = @ptrCast(@alignCast(p));
                c.count.* += 1;
                return true;
            }
        }.poll,
    };

    const Connect = struct {
        fn run(port_val: u16) void {
            var client_threaded = std.Io.Threaded.init(gpa, .{});
            const client_io = client_threaded.io();
            testSleepMs(50);
            const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port_val) };
            const stream = addr.connect(client_io, .{ .mode = .stream }) catch return;
            defer stream.close(client_io);
            var wbuf: [64]u8 = undefined;
            var writer = stream.writer(client_io, &wbuf);
            writer.interface.writeAll("step 1\n") catch return;
            writer.interface.flush() catch return;
            stream.shutdown(client_io, .send) catch {};
        }
    };
    const t = std.Thread.spawn(.{}, Connect.run, .{port}) catch return error.SkipZigTest;
    defer t.join();

    try testing.expect(pollGateWithPump(true, pump));
    try testing.expect(pump_count >= 3);
}

test "live pump: request read 中も fake pump が呼ばれる" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    resetForTest();
    test_live_poll_timeout_ms = 5;
    const port = initLiveServerForTest() catch return error.SkipZigTest;
    defer deinitLiveServerForTest();

    var pump_count: usize = 0;
    const PumpCtx = struct { count: *usize };
    var ctx = PumpCtx{ .count = &pump_count };
    const pump = NativePump{
        .ptr = @ptrCast(&ctx),
        .pollFn = struct {
            fn poll(p: *anyopaque) bool {
                const c: *PumpCtx = @ptrCast(@alignCast(p));
                c.count.* += 1;
                return true;
            }
        }.poll,
    };

    const SlowConnect = struct {
        fn run(port_val: u16) void {
            var client_threaded = std.Io.Threaded.init(gpa, .{});
            const client_io = client_threaded.io();
            const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port_val) };
            const stream = addr.connect(client_io, .{ .mode = .stream }) catch return;
            defer stream.close(client_io);
            var wbuf: [4096]u8 = undefined;
            var writer = stream.writer(client_io, &wbuf);
            writer.interface.writeAll("step") catch return;
            writer.interface.flush() catch return;
            testSleepMs(50);
            writer.interface.writeAll(" 1\n") catch return;
            writer.interface.flush() catch return;
            stream.shutdown(client_io, .send) catch {};
        }
    };
    const t = std.Thread.spawn(.{}, SlowConnect.run, .{port}) catch return error.SkipZigTest;
    defer t.join();

    try testing.expect(pollGateWithPump(true, pump));
    try testing.expect(pump_count >= 3);
}

test "live pump: request 1 MiB 超過後も次接続を accept できる" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    resetForTest();
    test_live_poll_timeout_ms = 5;
    const port = initLiveServerForTest() catch return error.SkipZigTest;
    defer deinitLiveServerForTest();

    const always_pump = NativePump{
        .ptr = undefined,
        .pollFn = struct {
            fn poll(_: *anyopaque) bool {
                return true;
            }
        }.poll,
    };

    const HugeThenStep = struct {
        fn run(port_val: u16) void {
            var client_threaded = std.Io.Threaded.init(gpa, .{});
            const client_io = client_threaded.io();
            {
                const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port_val) };
                const stream = addr.connect(client_io, .{ .mode = .stream }) catch return;
                var wbuf: [8192]u8 = undefined;
                var writer = stream.writer(client_io, &wbuf);
                var chunk: [65536]u8 = undefined;
                @memset(&chunk, 'a');
                var sent: usize = 0;
                const over = (1 << 20) + 1;
                while (sent < over) : (sent += chunk.len) {
                    const n = @min(chunk.len, over - sent);
                    writer.interface.writeAll(chunk[0..n]) catch return;
                }
                writer.interface.flush() catch return;
                stream.shutdown(client_io, .send) catch {};
                stream.close(client_io);
            }
            {
                const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port_val) };
                const stream = addr.connect(client_io, .{ .mode = .stream }) catch return;
                defer stream.close(client_io);
                var wbuf: [64]u8 = undefined;
                var writer = stream.writer(client_io, &wbuf);
                writer.interface.writeAll("step 1\n") catch return;
                writer.interface.flush() catch return;
                stream.shutdown(client_io, .send) catch {};
            }
        }
    };
    const t = std.Thread.spawn(.{}, HugeThenStep.run, .{port}) catch return error.SkipZigTest;
    defer t.join();

    try testing.expect(pollGateWithPump(true, always_pump));
}

test "netsync probe: 無効時は未登録 / host 有効時 expect role=host" {
    resetForTest();
    defer resetForTest();
    // 無効時（register 前）capabilities に netsync は出ない
    try testing.expect(findProbe("netsync") == null);
    {
        var parsed = try parseCapabilities(formatCapabilitiesPayload(&capabilities_buf));
        defer parsed.deinit();
        const probe_list = parsed.value.object.get("probes").?.array;
        for (probe_list.items) |item| {
            const name = item.object.get("name").?.string;
            try testing.expect(!std.mem.eql(u8, name, "netsync"));
        }
    }

    netsync.resetForTest();
    defer netsync.resetForTest();
    netsync.initHost(0);
    registerProbe(.{
        .name = "netsync",
        .ctx = @ptrFromInt(1),
        .ext = "json",
        .desc = "netsync stats",
        .digest = netsync.probeDigest,
        .snapshot = netsync.probeSnapshot,
    });
    try testing.expect(findProbe("netsync") != null);

    // headless replay: expect netsync role=host
    var sbuf: [128]u8 = undefined;
    cmd_buf = "expect netsync role=host\nstep 1\n";
    _ = &sbuf;
    cursor = 0;
    expect_failures = 0;
    try testing.expect(pollGate(true));
    try testing.expectEqual(@as(usize, 0), expect_failures);
}

// ============================================================================
// TASK-164: free-run clock / LISTEN / await
// ============================================================================

test "parseListenPortValue: absent/empty/0/fixed/invalid" {
    try testing.expect(!parseListenPortValue(null).requested);
    {
        const p = parseListenPortValue("");
        try testing.expect(p.requested);
        try testing.expect(p.valid);
        try testing.expectEqual(@as(u16, 0), p.port);
    }
    {
        const p = parseListenPortValue("0");
        try testing.expect(p.requested and p.valid);
        try testing.expectEqual(@as(u16, 0), p.port);
    }
    {
        const p = parseListenPortValue("9110");
        try testing.expect(p.requested and p.valid);
        try testing.expectEqual(@as(u16, 9110), p.port);
    }
    {
        const p = parseListenPortValue("abc");
        try testing.expect(p.requested);
        try testing.expect(!p.valid);
    }
}

test "decideTransport: SCRIPT/LISTEN/MANUAL_CLOCK exclusivity and clock defaults" {
    const ephemeral = ListenPortParse{ .requested = true, .port = 0, .valid = true };
    const none = ListenPortParse{ .requested = false };
    const bad = ListenPortParse{ .requested = true, .port = 0, .valid = false };

    {
        const d = decideTransport(false, none, false);
        try testing.expect(!d.enable);
    }
    {
        const d = decideTransport(false, none, true);
        try testing.expect(!d.enable);
        try testing.expect(d.reason_disabled != null);
    }
    {
        const d = decideTransport(true, ephemeral, false);
        try testing.expect(!d.enable);
    }
    {
        const d = decideTransport(false, bad, false);
        try testing.expect(!d.enable);
    }
    {
        const d = decideTransport(true, none, false);
        try testing.expect(d.enable);
        try testing.expect(d.clock == .manual);
    }
    {
        const d = decideTransport(true, none, true); // MANUAL_CLOCK on SCRIPT ignored
        try testing.expect(d.enable);
        try testing.expect(d.clock == .manual);
    }
    {
        const d = decideTransport(false, ephemeral, false);
        try testing.expect(d.enable);
        try testing.expect(d.clock == .free_run);
    }
    {
        const d = decideTransport(false, ephemeral, true);
        try testing.expect(d.enable);
        try testing.expect(d.clock == .manual);
    }
}

test "free-run: empty drain does poll(0) exactly once and returns true" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    resetForTest();
    _ = initLiveServerForTest() catch return error.SkipZigTest;
    defer deinitLiveServerForTest();
    clock_mode = .free_run;
    test_poll_zero_count = 0;

    try testing.expect(pollGateFreeRun(true));
    try testing.expectEqual(@as(usize, 1), test_poll_zero_count);
    try testing.expect(!live_req_open);
    try testing.expect(!freerun_reading);
}

test "step dual: manual uses steps_remaining, free-run uses frame barrier" {
    // manual
    resetForTest();
    cmd_buf = "step 3\nquit";
    clock_mode = .manual;
    try testing.expect(pollGate(true)); // frame 1, steps_remaining=2
    try testing.expectEqual(@as(usize, 2), steps_remaining);
    try testing.expect(pending_wait == .none);
    try testing.expect(pollGate(true));
    try testing.expectEqual(@as(usize, 1), steps_remaining);
    try testing.expect(pollGate(true));
    try testing.expectEqual(@as(usize, 0), steps_remaining);
    try testing.expect(!pollGate(true)); // quit

    // free-run barrier（live server + in-memory request）
    if (builtin.os.tag == .windows) return;

    resetForTest();
    _ = initLiveServerForTest() catch return;
    defer deinitLiveServerForTest();
    clock_mode = .free_run;
    // 直接 request を載せる（socket 経由せず barrier だけ検証）
    req_bytes = try gpa.dupe(u8, "step 2\n");
    cmd_buf = req_bytes;
    cursor = 0;
    live_req_open = true;
    frame_index = 10;
    try testing.expect(pollGateFreeRun(true));
    try testing.expect(pending_wait == .frame_barrier);
    try testing.expectEqual(@as(u64, 12), pending_wait.frame_barrier.target_frame);
    // 未到達
    frame_index = 11;
    try testing.expect(pollGateFreeRun(true));
    try testing.expect(pending_wait == .frame_barrier);
    // 到達 → コマンド尽きて finish（req_bytes は finishLiveRequest が free）
    frame_index = 12;
    try testing.expect(pollGateFreeRun(true));
    try testing.expect(pending_wait == .none);
    try testing.expect(!live_req_open);
}

test "await: timeout 0 checks once; positive waits across frames (manual)" {
    resetForTest();
    // present 前: fb unavailable → timeout 0 は即 fail（quit しない＝replayExitIfFailed 回避）
    cmd_buf = "await fb crc=DEADBEEF 0\nstep 1\n";
    expect_failures = 0;
    try testing.expect(pollGate(true)); // await fail + step
    try testing.expectEqual(@as(usize, 1), expect_failures);
    try testing.expect(pending_wait == .none);

    resetForTest();
    var pixels = [_]u32{0xFF0000FF} ** 4;
    onLock(&pixels, 2, 2);
    onPresent(); // frame_index=1, have_frame
    // 不一致 + timeout 1: 即 fail せず pending → 1 frame 後に fail
    cmd_buf = "await fb crc=00000000 1\nstep 1\n";
    try testing.expect(pollGate(true)); // start await → pending → return true
    try testing.expect(pending_wait == .predicate);
    // frame を進めて deadline 到達
    onPresent(); // frame_index=2; start was 1; timeout 1 → deadline=2
    try testing.expect(pollGate(true)); // fail await + step
    try testing.expect(pending_wait == .none);
    try testing.expect(expect_failures >= 1);
}

test "await: timeout 0 pass when predicate already true" {
    resetForTest();
    var pixels = [_]u32{0xFF112233} ** 4;
    onLock(&pixels, 2, 2);
    onPresent();
    var digbuf: [DIGEST_BUF_LEN]u8 = undefined;
    const payload = formatFbPayload(&digbuf);
    // crc= を payload から抜く
    const crc_tok = blk: {
        var it = std.mem.tokenizeAny(u8, payload, " \t");
        while (it.next()) |t| {
            if (std.mem.startsWith(u8, t, "crc=")) break :blk t;
        }
        return error.SkipZigTest;
    };
    var script_buf: [128]u8 = undefined;
    const script = try std.fmt.bufPrint(&script_buf, "await fb {s} 0\nstep 1\n", .{crc_tok});
    const owned = try gpa.dupe(u8, script);
    defer gpa.free(owned);
    cmd_buf = owned;
    expect_failures = 0;
    try testing.expect(pollGate(true)); // await ok → step
    try testing.expectEqual(@as(usize, 0), expect_failures);
}

test "parseAwaitExpr: optional timeout and surplus reject" {
    {
        var it = std.mem.tokenizeAny(u8, "fb crc=ABC", " \t");
        const a = parseAwaitExpr(&it).?;
        try testing.expectEqual(@as(usize, 0), a.timeout_frames);
        try testing.expectEqualStrings("fb", a.expr.probe);
    }
    {
        var it = std.mem.tokenizeAny(u8, "audio silent=0 5", " \t");
        const a = parseAwaitExpr(&it).?;
        try testing.expectEqual(@as(usize, 5), a.timeout_frames);
    }
    {
        var it = std.mem.tokenizeAny(u8, "fb crc=ABC 1 extra", " \t");
        try testing.expect(parseAwaitExpr(&it) == null);
    }
}

test "free-run execution model: agent 不在でも毎フレーム true" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    resetForTest();
    _ = initLiveServerForTest() catch return error.SkipZigTest;
    defer deinitLiveServerForTest();
    clock_mode = .free_run;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try testing.expect(pollGateFreeRun(true));
    }
    try testing.expect(!quit_requested);
}

// ============================================================================
// copilot（第3 control-plane。TASK-62.5.2）の namespace 再エクスポート。
// facade が `@import("harness").copilot` で届くようにするためだけの 1 行で、
// harness から copilot の関数は呼ばない（意味的依存は copilot→harness の一方向）。
// ============================================================================
pub const copilot = @import("copilot.zig");

// command model（TASK-62.5.1/62.5.3）の namespace 再エクスポート。copilot と同じく型の単一
// instance 共有のため（facade が `@import("harness").command` で届く。command.zig は std のみ）。
pub const command = @import("command.zig");
