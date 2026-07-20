//! 20_capture_demo: キャプチャ入力基盤（TASK-49 ファミリー）のドッグフード用デモ。
//!
//! mic → 波形(オシロスコープ) + FFT スペクトログラム + レベルメータ可視化（libs/viz 流用。
//! apps/synth が手本）、camera → canvas（framebuffer）表示、の2系統を1画面にまとめる。
//!
//! ## データソースの選択（本番 vs headless 検証）
//!
//! `harness.isCaptureSyntheticActive()`（`VP_HARNESS_CAPTURE_SYNTHETIC=1` かつ harness 有効時のみ
//! true。core/control/harness.zig, TASK-49.5）で分岐する:
//! - **本番（既定）**: `core/camera.zig`（macOS=AVFoundation 実 backend / 他OS=stub）と
//!   `core/audio.zig` の capture 拡張（macOS=AUHAL input 実 backend / 他OS=stub）を使う。
//!   実カメラ/マイク + macOS TCC 権限ダイアログが要る（人手・実機依存の手動検証レンジ）。
//! - **headless 検証**: `core/capture_synthetic.zig`（harness 内蔵の合成 mic/camera source。
//!   TASK-49.5）を直接使う。実デバイス/TCC 無しで決定論的なパターンを生成できる。
//!
//! 両パスとも同じ `App`/描画/probe 経路に合流する（型は `capture_types.VideoFrame`/`AudioInFrame`
//! の named module 共有により camera.zig 側と capture_synthetic.zig 側で構造的に同一）。
//!
//! ## スコープ判断（capture facade への配線・kit 昇格）
//!
//! `docs/plans/capture-foundation-plan.md` 9章は本タスク(49.6)の役割を「mic/camera を使う最小
//! アプリ + kit への昇格判断」としている。本デモは **kit への camera 昇格を見送り**、
//! `examples/`（ADR-007 R5 の kit-only 強制対象外。build.zig 冒頭コメント参照）として実装した。
//! 理由: headless 検証には `core/capture_synthetic.zig`（harness 内蔵・camera/audio facade 非配線。
//! TASK-49.5 の設計判断）への直 import が必須だが、これは「apps は kit のみ」という R5 の対象外
//! （examples の従来配線）でしか許されない。camera を kit だけ昇格させても synthetic 経路は
//! 依然 kit 化できない（49.5 が意図的に decouple した内部ツールであり、これを kit の公開面に
//! 昇格すると 49.5 の設計意図を薄める）ため、examples 配置に統一した。camera.zig/audio.zig
//! 自体（facade API）は本タスクでは無変更（consume に徹する）。将来 apps/ 配下の本格カメラアプリが
//! 必要になったら、その時点で kit 昇格を再検討する。
//!
//! ホットパス宣言:
//! - 毎フレーム全画素塗り（背景 `@memset`）+ camera フレームの canvas 転写（`drawVideoFrame`）は
//!   **フレーム毎の全画素相当ループ**（性能規約の対象）。ただし転写はブレンド/除算を伴わない不透明
//!   の行コピー（`camera_macos.zig` の `copyBgraRows` と同クラス）で、clip はループ外で1回だけ
//!   計算し内側は無検査の `@memcpy` にする。ブレンドが無いため `pixelops` の SIMD 3点セットは
//!   そもそも該当しない（`copyBgraRows` 自身の判断根拠と同じ）。
//! - mic capture callback（`micCallback`）: **RT（毎サンプル相当。ブロック単位で呼ばれる）**。
//!   malloc/lock/IO/panic 禁止。`SampleTap.write()`（alloc/lock 無しの SPSC drop-on-full）のみ行う。
//! - `capture_synthetic.SyntheticVideoDevice.renderFrame`: 49.5 の判断を継承し
//!   **イベント時のみ**（本デモでは毎フレーム呼ぶが、対象は 320x240 の小解像度合成画像であり
//!   実カメラ描画ホットパスと同じ扱いはしない。49.5 の判断根拠をそのまま踏襲）。
//! - probe digest 組み立て（`captureDemoDigest`）: イベント時のみ（`digest` コマンド発行時）。

const std = @import("std");
const platform = @import("platform");
const harness = @import("harness");
const camera = @import("camera");
const audio = @import("audio");
const capture_synthetic = @import("capture_synthetic");
const spectrogram = @import("spectrogram");
const scope = @import("scope");
const synthlib = @import("synth");

// ============================================================================
// レイアウト
// ============================================================================
const WIN_W = 920;
const WIN_H = 300;

const CAM_X0 = 20;
const CAM_Y0 = 20;
const CAM_W = 320;
const CAM_H = 240;

const SPEC_X0 = 360;
const SPEC_Y0 = 20;
const SPEC_W = 340;
const SPEC_H = 110;

const SCOPE_X0 = 360;
const SCOPE_Y0 = 150;
const SCOPE_W = 300;
const SCOPE_H = 110;

const METER_X0 = 680;
const METER_Y0 = 150;
const METER_W = 40;
const METER_H = 110;

const MIC_SAMPLE_RATE = 48000;
const MIC_CHANNELS = 1;

const BG_COLOR: u32 = 0xFF14141C;
const CAM_EMPTY_COLOR: u32 = 0xFF202028; // カメラ未取得時のプレースホルダ背景
const BORDER_COLOR: u32 = 0xFF404858;

const Spec = spectrogram.Spectrogram(SPEC_W, SPEC_H);
const Scope = scope.Oscilloscope(SCOPE_W, SCOPE_H);
const Tap = synthlib.SampleTap(8192);

// ============================================================================
// データソース（本番 = 実 backend / headless 検証 = synthetic）
// ============================================================================

const VideoSource = union(enum) {
    none,
    real: camera.VideoDevice,
    synthetic: capture_synthetic.SyntheticVideoDevice,
};

const MicSource = union(enum) {
    none,
    real: audio.CaptureDevice,
    synthetic: capture_synthetic.SyntheticAudioDevice,
};

fn videoSourceName(vs: VideoSource) []const u8 {
    return @tagName(std.meta.activeTag(vs));
}

fn micSourceName(ms: MicSource) []const u8 {
    return @tagName(std.meta.activeTag(ms));
}

fn closeVideoSource(vs: *VideoSource) void {
    switch (vs.*) {
        .none => {},
        .real => |dev| dev.close(),
        .synthetic => |*dev| dev.close(),
    }
    vs.* = .none;
}

fn closeMicSource(ms: *MicSource) void {
    switch (ms.*) {
        .none => {},
        .real => |dev| dev.close(),
        .synthetic => |dev| dev.close(),
    }
    ms.* = .none;
}

/// 直近の video フレームを取得する。synthetic は毎回 `renderFrame` を呼ぶ pull 型、
/// real は capture スレッドが publish 済みの最新フレームを覗く poll 型（TripleBuffer）。
fn pollVideoFrame(vs: *VideoSource, tick: *u64) ?camera.VideoFrame {
    return switch (vs.*) {
        .none => null,
        .real => |dev| dev.pollLatestFrame(),
        .synthetic => |*dev| blk: {
            tick.* += 1;
            break :blk dev.renderFrame(tick.*);
        },
    };
}

fn micCallback(frame: audio.AudioInFrame, userdata: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(userdata.?));
    app.tap.write(frame.samples);
}

/// カメラ権限を要求し、拒否/未対応なら理由をログして `.none` を返す（人手/実機依存の TCC 目視は
/// 手動検証レンジ。backlog task-49.6 notes 参照）。
///
/// **headless ガード**: `harness.isHeadlessActive()` が true のときは AVFoundation を一切呼ばず即
/// `.none` を返す。`requestPermission()`（`avRequestAccessBlocking`）は completion handler を
/// runloop 経由で待つブロッキング実装のため、display/runloop の無い headless 環境では応答が
/// 永久に返らずハングしうることを実測確認済み（codex レビュー指摘。TCC ダイアログを見せる
/// 手段が無い headless で real capture を試みること自体が無意味なので、fail-fast で回避する）。
fn openRealVideo(allocator: std.mem.Allocator) VideoSource {
    if (harness.isHeadlessActive()) {
        std.debug.print("[capture_demo] headless active: real camera を試みない（TCC 待機がハングしうるため。VP_HARNESS_CAPTURE_SYNTHETIC=1 を使うこと）\n", .{});
        return .none;
    }
    const perm = camera.requestPermission() catch |err| {
        std.debug.print("[capture_demo] camera.requestPermission failed: {s} (real camera disabled)\n", .{@errorName(err)});
        return .none;
    };
    if (perm != .granted) {
        std.debug.print("[capture_demo] camera permission = {t} (real camera disabled; TCC dialog is manual verification)\n", .{perm});
        return .none;
    }
    var dev = camera.open(allocator, .{ .width = CAM_W, .height = CAM_H, .frame_rate = 30 }) catch |err| {
        std.debug.print("[capture_demo] camera.open failed: {s}\n", .{@errorName(err)});
        return .none;
    };
    dev.start() catch |err| {
        std.debug.print("[capture_demo] camera.start failed: {s}\n", .{@errorName(err)});
        dev.close();
        return .none;
    };
    std.debug.print("[capture_demo] real camera opened {d}x{d}\n", .{ dev.config().width, dev.config().height });
    return .{ .real = dev };
}

fn openSyntheticVideo(allocator: std.mem.Allocator) VideoSource {
    const dev = capture_synthetic.openVideo(allocator, .{ .width = CAM_W, .height = CAM_H, .frame_rate = 30 }) catch |err| {
        std.debug.print("[capture_demo] capture_synthetic.openVideo failed: {s}\n", .{@errorName(err)});
        return .none;
    };
    std.debug.print("[capture_demo] synthetic camera opened {d}x{d}\n", .{ CAM_W, CAM_H });
    return .{ .synthetic = dev };
}

/// マイク権限を要求し、拒否/未対応なら理由をログして `.none` を返す（openRealVideo と対称）。
/// headless ガードは openRealVideo と同じ理由（`requestCapturePermission()` も同じ
/// `avRequestAccessBlocking` 経由でハングしうる）。
fn openRealMic(allocator: std.mem.Allocator, app: *App) MicSource {
    if (harness.isHeadlessActive()) {
        std.debug.print("[capture_demo] headless active: real mic を試みない（TCC 待機がハングしうるため。VP_HARNESS_CAPTURE_SYNTHETIC=1 を使うこと）\n", .{});
        return .none;
    }
    const perm = audio.requestCapturePermission() catch |err| {
        std.debug.print("[capture_demo] audio.requestCapturePermission failed: {s} (real mic disabled)\n", .{@errorName(err)});
        return .none;
    };
    if (perm != .granted) {
        std.debug.print("[capture_demo] mic permission = {t} (real mic disabled; TCC dialog is manual verification)\n", .{perm});
        return .none;
    }
    var dev = audio.openCapture(allocator, .{
        .sample_rate = MIC_SAMPLE_RATE,
        .channels = MIC_CHANNELS,
        .capture_callback = micCallback,
        .userdata = app,
    }) catch |err| {
        std.debug.print("[capture_demo] audio.openCapture failed: {s}\n", .{@errorName(err)});
        return .none;
    };
    dev.start() catch |err| {
        std.debug.print("[capture_demo] mic start failed: {s}\n", .{@errorName(err)});
        dev.close();
        return .none;
    };
    std.debug.print("[capture_demo] real mic opened sr={d} ch={d}\n", .{ dev.config().sample_rate, dev.config().channels });
    // 可視化パイプライン（tap→spec/osc/meter）は mono(1ch) 前提。実デバイスの折衝結果が要求と
    // 異なる場合は明示警告する（downmix はしない。channels 不一致時は周波数軸/波形が実信号と
    // ズレて見えうることをログで示す。codex レビュー指摘）。
    if (dev.config().channels != MIC_CHANNELS) {
        std.debug.print("[capture_demo] warning: real mic negotiated channels={d} (requested {d}); 可視化は mono 前提のためズレて見えうる\n", .{ dev.config().channels, MIC_CHANNELS });
    }
    return .{ .real = dev };
}

fn openSyntheticMic(allocator: std.mem.Allocator, app: *App) MicSource {
    var dev = capture_synthetic.openAudio(allocator, .{
        .sample_rate = MIC_SAMPLE_RATE,
        .channels = MIC_CHANNELS,
        .capture_callback = micCallback,
        .userdata = app,
    }) catch |err| {
        std.debug.print("[capture_demo] capture_synthetic.openAudio failed: {s}\n", .{@errorName(err)});
        return .none;
    };
    dev.start() catch |err| {
        std.debug.print("[capture_demo] synthetic mic start failed: {s}\n", .{@errorName(err)});
        dev.close();
        return .none;
    };
    std.debug.print("[capture_demo] synthetic mic opened sr={d} ch={d}\n", .{ MIC_SAMPLE_RATE, MIC_CHANNELS });
    return .{ .synthetic = dev };
}

/// 実効サンプルレートを取得する（open 済みソースの `.config().sample_rate`。未 open は既定値）。
/// 実マイクは AUHAL のハードウェア折衝で `MIC_SAMPLE_RATE` と異なる値に決まりうるため、
/// スペクトログラムの周波数軸をこの値で再算出する必要がある（codex レビュー指摘）。
fn micSampleRate(ms: MicSource) u32 {
    return switch (ms) {
        .none => MIC_SAMPLE_RATE,
        .real => |dev| dev.config().sample_rate,
        .synthetic => |dev| dev.config().sample_rate,
    };
}

// ============================================================================
// App 状態
// ============================================================================

const App = struct {
    video: VideoSource = .none,
    video_tick: u64 = 0,
    video_frames_seen: u64 = 0,

    mic: MicSource = .none,
    tap: Tap = .{},
    mic_frames_seen: u64 = 0,

    spec: Spec = .{},
    osc: Scope = .{},
    meter: scope.LevelMeter = .{},
};

fn captureDemoDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const mic_silent: u32 = if (app.meter.disp_rms < 1e-4) 1 else 0;
    return std.fmt.bufPrint(buf, "video_source={s} video_w={d} video_h={d} video_frames={d} mic_source={s} mic_frames={d} mic_rms={d:.4} mic_peak={d:.4} mic_silent={d}", .{
        videoSourceName(app.video),
        CAM_W,
        CAM_H,
        app.video_frames_seen,
        micSourceName(app.mic),
        app.mic_frames_seen,
        app.meter.disp_rms,
        app.meter.disp_peak,
        mic_silent,
    }) catch buf[0..0];
}

// ============================================================================
// 描画
// ============================================================================

/// framebuffer のピクセル u32 packing（gui.Color / scope.zig と同じ: メモリ B,G,R,A = u32 0xAARRGGBB）。
fn fillRect(pixels: []u32, fb_w: usize, fb_h: usize, x0: usize, y0: usize, w: usize, h: usize, color: u32) void {
    const copy_w = if (x0 >= fb_w) 0 else @min(w, fb_w - x0);
    const copy_h = if (y0 >= fb_h) 0 else @min(h, fb_h - y0);
    var y: usize = 0;
    while (y < copy_h) : (y += 1) {
        @memset(pixels[(y0 + y) * fb_w + x0 ..][0..copy_w], color);
    }
}

fn drawBorder(pixels: []u32, fb_w: usize, fb_h: usize, x0: usize, y0: usize, w: usize, h: usize, color: u32) void {
    if (w == 0 or h == 0) return;
    fillRect(pixels, fb_w, fb_h, x0, y0, w, 1, color);
    fillRect(pixels, fb_w, fb_h, x0, y0 + h - 1, w, 1, color);
    fillRect(pixels, fb_w, fb_h, x0, y0, 1, h, color);
    fillRect(pixels, fb_w, fb_h, x0 + w - 1, y0, 1, h, color);
}

/// カメラフレームを canvas 領域(x0,y0 固定)へ描画する。
///
/// ホットパス宣言: フレーム到着毎に呼ばれる「フレーム毎の全画素相当」ループだが、ブレンド/除算を
/// 伴わない不透明の行コピー（`core/camera_macos.zig` の `copyBgraRows` と同クラス）。clip はループ外
/// で1回だけ計算し、内側は無検査の `@memcpy`（行連続アクセス）にする。ブレンドが無いため
/// `pixelops` の SIMD 3点セットはそもそも対象外（copyBgraRows 自身の判断根拠と同じ）。
/// カメラフレームを CAM_W×CAM_H の枠に nearest-neighbor で収めて描く。
///
/// frame の実寸（`frame.width/height`）は driver 都合で要求値と食い違う（V4L2 は要求解像度を
/// 対応する離散値へ丸める。例: 320×240 要求 → uvcvideo が 640×480 を返す）。実寸のまま転写すると
/// 枠と隣の可視化パネルにはみ出すため、常に枠サイズへスケールする。640×480→320×240 のように
/// アスペクト比が一致する場合は全視野が歪みなく収まる（一致しない場合は非等方スケールになるが
/// デモのプレビュー用途では許容）。
///
/// ホットパス宣言: 毎フレーム、枠 CAM_W×CAM_H 分の全画素を走る。per-pixel 除算を避けるため列の
/// ソース x マップをループ外で1回だけ作る（性能規約「per-pixel 除算の禁止」）。SIMD 化はしない
/// （camera fps・320×240 のデモプレビューで十分速く、nearest-neighbor gather は SIMD 化の利が薄い）。
fn drawVideoFrame(pixels: []u32, fb_w: usize, fb_h: usize, x0: usize, y0: usize, frame: camera.VideoFrame) void {
    if (x0 >= fb_w or y0 >= fb_h or frame.width == 0 or frame.height == 0) return;
    const box_w = @min(@as(usize, CAM_W), fb_w - x0); // fb 端で clip（枠が画面外に出る分だけ）
    const box_h = @min(@as(usize, CAM_H), fb_h - y0);
    // 列マップ（枠 x → フレーム x）をループ外で1回。box_w <= CAM_W なので [CAM_W]usize で足りる。
    var x_map: [CAM_W]usize = undefined;
    var dx: usize = 0;
    while (dx < box_w) : (dx += 1) x_map[dx] = dx * @as(usize, frame.width) / CAM_W;
    var dy: usize = 0;
    while (dy < box_h) : (dy += 1) {
        const sy = dy * @as(usize, frame.height) / CAM_H; // 行のソース y（per-row・per-pixel ではない）
        const src_base = sy * @as(usize, frame.stride);
        const dst_base = (y0 + dy) * fb_w + x0;
        dx = 0;
        while (dx < box_w) : (dx += 1) pixels[dst_base + dx] = frame.pixels[src_base + x_map[dx]];
    }
}

// ============================================================================
// main
// ============================================================================

pub fn main() !void {
    std.debug.print("20_capture_demo: mic waveform/FFT + camera canvas (TASK-49.6). ESC to quit.\n", .{});

    const allocator = std.heap.c_allocator;

    var app = try allocator.create(App);
    defer allocator.destroy(app);
    app.* = .{};

    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(WIN_W, WIN_H, "20_capture_demo - mic viz + camera canvas");
    defer window.destroy();

    // データソース選択: VP_HARNESS_CAPTURE_SYNTHETIC=1 + harness 有効時のみ synthetic
    // （core/control/harness.zig の isCaptureSyntheticActive()。TASK-49.5）。既定は本番(実 backend)。
    const synthetic_mode = harness.isCaptureSyntheticActive();
    std.debug.print("[capture_demo] mode={s}\n", .{if (synthetic_mode) "synthetic (headless verification)" else "real (production; requires camera/mic + TCC permission)"});

    app.video = if (synthetic_mode) openSyntheticVideo(allocator) else openRealVideo(allocator);
    defer closeVideoSource(&app.video);

    app.mic = if (synthetic_mode) openSyntheticMic(allocator, app) else openRealMic(allocator, app);
    defer closeMicSource(&app.mic);
    // spectrogram の対数周波数軸は実効サンプルレートで算出する（実マイクは AUHAL のハードウェア
    // 折衝で MIC_SAMPLE_RATE と異なる値に決まりうる。codex レビュー指摘）。open 後・feed 前に
    // 呼ぶ（mic 未 open/synthetic は要求どおり MIC_SAMPLE_RATE のまま）。
    app.spec.init(@floatFromInt(micSampleRate(app.mic)));

    // ヘッドレス検証 harness の custom probe を登録（harness 無効時は no-op）。
    platform.registerProbe(.{ .name = "capture_demo", .ctx = app, .digest = captureDemoDigest });

    var mono_scratch: [4096]f32 = undefined;
    var running = true;

    main_loop: while (running and window.pollEvents()) {
        const fb = window.lockFramebuffer() orelse continue :main_loop;
        defer fb.unlock();

        while (window.nextEvent()) |ev| {
            switch (ev) {
                .quit => running = false,
                .key_down => |k| if (k.key == .ESCAPE) {
                    running = false;
                },
                else => {},
            }
        }

        // mic tap を drain → オシロスコープ / スペクトログラム / レベルメータへ供給。
        while (true) {
            const n = app.tap.read(&mono_scratch);
            if (n == 0) break;
            app.mic_frames_seen += n;
            app.spec.feed(mono_scratch[0..n]);
            app.osc.feed(mono_scratch[0..n]);
            app.meter.feed(mono_scratch[0..n]);
        }

        // 描画: 背景 → カメラ領域(プレースホルダ or 実フレーム) → mic 可視化。
        @memset(fb.pixels, BG_COLOR);

        fillRect(fb.pixels, fb.width, fb.height, CAM_X0, CAM_Y0, CAM_W, CAM_H, CAM_EMPTY_COLOR);
        if (pollVideoFrame(&app.video, &app.video_tick)) |frame| {
            drawVideoFrame(fb.pixels, fb.width, fb.height, CAM_X0, CAM_Y0, frame);
            app.video_frames_seen += 1;
        }
        drawBorder(fb.pixels, fb.width, fb.height, CAM_X0, CAM_Y0, CAM_W, CAM_H, BORDER_COLOR);

        app.spec.draw(fb.pixels, fb.width, fb.height, SPEC_X0, SPEC_Y0);
        app.osc.draw(fb.pixels, fb.width, fb.height, SCOPE_X0, SCOPE_Y0);
        app.meter.draw(fb.pixels, fb.width, fb.height, METER_X0, METER_Y0, METER_W, METER_H);

        window.present();

        platform.frameDelay(16_000_000); // ~16ms（約60fps）
    }
}
