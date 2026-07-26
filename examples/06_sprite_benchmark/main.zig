// === Sprite drawing benchmark ===
//
// What this bench shows:
// 1. Measure blit performance for many sprites (draw_ms / frame_ms / fps / estimated throughput)
// 2. static mode fixes the workload for before/after optimisation comparison
// 3. moving mode is a dynamic-load reference (not used as a comparison metric)
//
// Ownership:
// - The PNG is decoded once; `template: Sprite` owns the image.
// - `Instance` keeps only position and velocity and shares the image. A `Sprite` value is a
//   borrowed drawing view and must not be deinited. Only `template` frees the image.
//
// Aggregation assumptions:
// - `report_frames` is the count of successfully drawn frames (`lock_framebuffer` failures are counted separately).
// - So `fps = report_frames / report_elapsed` is strictly a "successful-frame rate" and
//   diverges from wall-clock rate when `dropped_frames > 0`. Use for comparison only
//   samples with `dropped_frames == 0`.
// - `present_call_ms` is the CPU-side `platform_present` call time, not GPU completion time.

const std = @import("std");
const platform = @import("platform");
const sprite = @import("sprite");
const FpsCounter = @import("fps_counter").FpsCounter;
const build_options = @import("build_options");

const usako_png = @embedFile("image/usako.png");

const WINDOW_W: i32 = 800;
const WINDOW_H: i32 = 600;
const RNG_SEED: u64 = 0xDEAD_BEEF_CAFE_BABE;
const VELOCITY_MAX: f32 = 200.0;
const WARMUP_SEC: f64 = 2.0;
const NUM_WINDOWS: usize = 5;

const Mode = enum { static, moving };

const Instance = struct {
    x: f32,
    y: f32,
    vx: f32,
    vy: f32,
};

const State = enum { warmup, measuring, done };

const WindowResult = struct {
    fps: f64,
    frame_ms: f64,
    frame_ms_p95: ?f64, // null = unmeasurable due to sample_overflow
    draw_ms: f64,
    present_call_ms: f64,
    processed_px_per_frame: f64,
    dropped_frames: u32,
};

fn usageAndExit() noreturn {
    std.debug.print(
        \\usage: example_06 <sprite_count> [static|moving]
        \\
        \\  sprite_count: integer in 1..100000
        \\  mode:         "static" (default) or "moving"
        \\
    , .{});
    std.process.exit(2);
}

/// Reflect position so it stays in `[-iw/2, w-iw/2]`
fn reflectAxis(pos: *f32, vel: *f32, lo: f32, hi: f32) void {
    if (pos.* < lo) {
        pos.* = lo + (lo - pos.*);
        vel.* = -vel.*;
    } else if (pos.* > hi) {
        pos.* = hi - (pos.* - hi);
        vel.* = -vel.*;
    }
}

/// Visible overlap area of one instance (i32 arithmetic; excludes off-screen parts)
fn instanceVisiblePixels(inst: Instance, iw: i32, ih: i32, fb_w: i32, fb_h: i32) u64 {
    const ix: i32 = @intFromFloat(@floor(inst.x));
    const iy: i32 = @intFromFloat(@floor(inst.y));
    const left = @max(ix, 0);
    const right = @min(ix + iw, fb_w);
    const top = @max(iy, 0);
    const bottom = @min(iy + ih, fb_h);
    if (right <= left or bottom <= top) return 0;
    return @as(u64, @intCast(right - left)) * @as(u64, @intCast(bottom - top));
}

/// Sum visible overlap areas across all instances
fn computeProcessedPx(instances: []const Instance, iw: i32, ih: i32, fb_w: i32, fb_h: i32) u64 {
    var total: u64 = 0;
    for (instances) |inst| {
        total += instanceVisiblePixels(inst, iw, ih, fb_w, fb_h);
    }
    return total;
}

/// Return p95. Destructively sorts samples.
fn computeP95(samples: []f64) ?f64 {
    if (samples.len == 0) return null;
    std.mem.sort(f64, samples, {}, std.sort.asc(f64));
    // 95th percentile: round(0.95 * (n-1))
    const idx_f = 0.95 * @as(f64, @floatFromInt(samples.len - 1));
    const idx: usize = @intFromFloat(@round(idx_f));
    return samples[idx];
}

pub fn main(minimal: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    // -------- argument parsing --------
    var args_it = try minimal.args.iterateAllocator(allocator);
    defer args_it.deinit();

    _ = args_it.next(); // skip program name

    var sprite_count: u32 = 1000;
    var mode: Mode = .static;

    if (args_it.next()) |arg1| {
        sprite_count = std.fmt.parseInt(u32, arg1, 10) catch usageAndExit();
        if (sprite_count == 0 or sprite_count > 100_000) usageAndExit();
    }
    if (args_it.next()) |arg2| {
        if (std.mem.eql(u8, arg2, "static")) {
            mode = .static;
        } else if (std.mem.eql(u8, arg2, "moving")) {
            mode = .moving;
        } else {
            usageAndExit();
        }
    }

    // -------- start banner --------
    const build_mode_name = @tagName(@import("builtin").mode);
    std.debug.print(
        "[bench:start] platform={s} build={s} (note: performance comparison targets the objc build primarily)\n",
        .{ build_options.platform_name, build_mode_name },
    );

    // -------- platform init --------
    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(@intCast(WINDOW_W), @intCast(WINDOW_H), "06: Sprite Benchmark");
    defer window.destroy();

    // -------- sprite setup --------
    var template = try sprite.Sprite.initFromData(allocator, usako_png, 0, 0);
    defer template.deinit(allocator);
    const shared_image = template.image;

    const iw_u32 = shared_image.width;
    const ih_u32 = shared_image.height;
    const iw: i32 = @intCast(iw_u32);
    const ih: i32 = @intCast(ih_u32);

    const instances = try allocator.alloc(Instance, sprite_count);
    defer allocator.free(instances);

    {
        var prng = std.Random.DefaultPrng.init(RNG_SEED);
        const rng = prng.random();
        // Placement range: allow half the sprite to hang off the edge
        // x ∈ [-iw/2, w - iw/2], y ∈ [-ih/2, h - ih/2]
        const x_lo: f32 = -@as(f32, @floatFromInt(iw)) * 0.5;
        const x_hi: f32 = @as(f32, @floatFromInt(WINDOW_W)) - @as(f32, @floatFromInt(iw)) * 0.5;
        const y_lo: f32 = -@as(f32, @floatFromInt(ih)) * 0.5;
        const y_hi: f32 = @as(f32, @floatFromInt(WINDOW_H)) - @as(f32, @floatFromInt(ih)) * 0.5;
        for (instances) |*inst| {
            inst.x = x_lo + rng.float(f32) * (x_hi - x_lo);
            inst.y = y_lo + rng.float(f32) * (y_hi - y_lo);
            inst.vx = (rng.float(f32) * 2.0 - 1.0) * VELOCITY_MAX;
            inst.vy = (rng.float(f32) * 2.0 - 1.0) * VELOCITY_MAX;
        }
    }

    const x_lo: f32 = -@as(f32, @floatFromInt(iw)) * 0.5;
    const x_hi: f32 = @as(f32, @floatFromInt(WINDOW_W)) - @as(f32, @floatFromInt(iw)) * 0.5;
    const y_lo: f32 = -@as(f32, @floatFromInt(ih)) * 0.5;
    const y_hi: f32 = @as(f32, @floatFromInt(WINDOW_H)) - @as(f32, @floatFromInt(ih)) * 0.5;

    const input_px_per_frame: u64 = @as(u64, sprite_count) * @as(u64, iw_u32) * @as(u64, ih_u32);
    const initial_processed_px: u64 = computeProcessedPx(instances, iw, ih, WINDOW_W, WINDOW_H);

    std.debug.print(
        "[bench] config sprites={d} mode={s} window={d}x{d} image={d}x{d} input_px_per_frame={d} processed_px_per_frame={d} [warm-up {d}s, measurement {d}x1s]\n",
        .{
            sprite_count,
            @tagName(mode),
            WINDOW_W,
            WINDOW_H,
            iw_u32,
            ih_u32,
            input_px_per_frame,
            initial_processed_px,
            WARMUP_SEC,
            NUM_WINDOWS,
        },
    );

    // -------- measurement state --------
    var fps_counter = FpsCounter.init(1.0);
    var state: State = .warmup;
    var warmup_left: f64 = WARMUP_SEC;
    var window_idx: usize = 0;
    var results: [NUM_WINDOWS]WindowResult = undefined;

    // Per-window accumulators
    var report_elapsed: f64 = 0.0;
    var report_frames: u32 = 0;
    var dropped_frames: u32 = 0;
    var draw_time_acc: f64 = 0.0;
    var present_time_acc: f64 = 0.0;
    var frame_ms_samples: std.ArrayList(f64) = .empty;
    defer frame_ms_samples.deinit(allocator);
    var sample_overflow: bool = false;

    // -------- main loop --------
    var last_time = platform.getTime();

    main_loop: while (window.pollEvents()) {
        // ESC quit handling
        while (window.nextEvent()) |ev| switch (ev) {
            .quit => break :main_loop,
            .key_down => |k| if (k.key == .ESCAPE) break :main_loop,
            .key_up => {},
            else => {},
        };

        const now = platform.getTime();
        const frame_time = now - last_time;
        last_time = now;

        // Drain remaining warmup
        if (state == .warmup) {
            warmup_left -= frame_time;
            if (warmup_left <= 0.0) {
                // Reset accumulators / buffers / fps_counter; measurement starts next frame.
                // This transition frame's frame_time spans warmup→now, so folding it into the first measuring
                // window would corrupt frame_ms / fps.
                report_elapsed = 0.0;
                report_frames = 0;
                dropped_frames = 0;
                draw_time_acc = 0.0;
                present_time_acc = 0.0;
                frame_ms_samples.clearRetainingCapacity();
                sample_overflow = false;
                fps_counter.reset();
                state = .measuring;
                continue;
            }
        }

        // moving mode: update positions (wall bounce)
        if (mode == .moving) {
            const ft_f32: f32 = @floatCast(frame_time);
            for (instances) |*inst| {
                inst.x += inst.vx * ft_f32;
                inst.y += inst.vy * ft_f32;
                reflectAxis(&inst.x, &inst.vx, x_lo, x_hi);
                reflectAxis(&inst.y, &inst.vy, y_lo, y_hi);
            }
        }

        // Lock the framebuffer
        var fb = window.lockFramebuffer() orelse {
            if (state == .measuring) dropped_frames += 1;
            continue;
        };

        const fb_w_u32 = fb.width;
        const fb_h_u32 = fb.height;

        // Clear the background
        @memset(fb.pixels, 0xFF000000);

        // Sprite drawing (timed as draw_ms)
        const t0 = platform.getTime();
        for (instances) |inst| {
            const s = sprite.Sprite{
                .image = shared_image,
                .x = @intFromFloat(@floor(inst.x)),
                .y = @intFromFloat(@floor(inst.y)),
            };
            sprite.drawSprite(fb.pixels, fb_w_u32, fb_h_u32, &s);
        }
        const draw_dt = platform.getTime() - t0;

        // present
        const tp0 = platform.getTime();
        window.present();
        const present_dt = platform.getTime() - tp0;

        fb.unlock();

        // Accumulate only while measuring
        if (state == .measuring) {
            report_elapsed += frame_time;
            report_frames += 1;
            draw_time_acc += draw_dt;
            present_time_acc += present_dt;
            frame_ms_samples.append(allocator, frame_time * 1000.0) catch {
                sample_overflow = true;
            };

            if (fps_counter.update(frame_time)) {
                // Finalise the window
                const rf_f64: f64 = @floatFromInt(report_frames);
                const processed_px_for_window: u64 = if (mode == .static)
                    initial_processed_px
                else
                    computeProcessedPx(instances, iw, ih, WINDOW_W, WINDOW_H);

                const result = WindowResult{
                    .fps = rf_f64 / report_elapsed,
                    .frame_ms = 1000.0 * report_elapsed / rf_f64,
                    .frame_ms_p95 = if (sample_overflow) null else computeP95(frame_ms_samples.items),
                    .draw_ms = 1000.0 * draw_time_acc / rf_f64,
                    .present_call_ms = 1000.0 * present_time_acc / rf_f64,
                    .processed_px_per_frame = @floatFromInt(processed_px_for_window),
                    .dropped_frames = dropped_frames,
                };

                var p95_buf: [32]u8 = undefined;
                const p95_str: []const u8 = if (result.frame_ms_p95) |p|
                    std.fmt.bufPrint(&p95_buf, "{d:.2}", .{p}) catch "n/a"
                else
                    "n/a";

                std.debug.print(
                    "[bench] window={d}/{d} draw={d:.3}ms frame={d:.3}ms p95={s}ms present_call={d:.3}ms fps={d:.1} dropped={d}\n",
                    .{
                        window_idx + 1,
                        NUM_WINDOWS,
                        result.draw_ms,
                        result.frame_ms,
                        p95_str,
                        result.present_call_ms,
                        result.fps,
                        result.dropped_frames,
                    },
                );

                results[window_idx] = result;
                window_idx += 1;

                // Reset accumulators
                report_elapsed = 0.0;
                report_frames = 0;
                dropped_frames = 0;
                draw_time_acc = 0.0;
                present_time_acc = 0.0;
                frame_ms_samples.clearRetainingCapacity();
                sample_overflow = false;

                if (window_idx >= NUM_WINDOWS) {
                    printFinal(results[0..NUM_WINDOWS], sprite_count, mode, build_mode_name, input_px_per_frame);
                    std.debug.print("[bench:done] press ESC to exit\n", .{});
                    state = .done;
                }
            }
        }
    }
}

fn printFinal(
    results: []const WindowResult,
    sprite_count: u32,
    mode: Mode,
    build_mode_name: []const u8,
    input_px_per_frame: u64,
) void {
    var draw_sum: f64 = 0;
    var draw_min: f64 = std.math.inf(f64);
    var draw_max: f64 = -std.math.inf(f64);
    var frame_sum: f64 = 0;
    var p95_sum: f64 = 0;
    var p95_valid_windows: usize = 0;
    var present_sum: f64 = 0;
    var fps_sum: f64 = 0;
    var processed_px_sum: f64 = 0;
    var dropped_total: u32 = 0;

    for (results) |r| {
        draw_sum += r.draw_ms;
        draw_min = @min(draw_min, r.draw_ms);
        draw_max = @max(draw_max, r.draw_ms);
        frame_sum += r.frame_ms;
        if (r.frame_ms_p95) |p| {
            p95_sum += p;
            p95_valid_windows += 1;
        }
        present_sum += r.present_call_ms;
        fps_sum += r.fps;
        processed_px_sum += r.processed_px_per_frame;
        dropped_total += r.dropped_frames;
    }

    const n: f64 = @floatFromInt(results.len);
    const draw_avg = draw_sum / n;
    const frame_avg = frame_sum / n;
    // Adopt a final p95 only when every window produced a p95.
    // If any window is n/a due to sample_overflow=true, the final is also n/a (so a partial average
    // does not mix with the 5-window avg).
    const p95_avg: ?f64 = if (p95_valid_windows == results.len) p95_sum / n else null;
    const present_avg = present_sum / n;
    const fps_avg = fps_sum / n;
    const processed_px_avg = processed_px_sum / n;

    // Throughput is based on avg draw_ms
    const draw_sec_avg = draw_avg / 1000.0;
    const input_gpx_per_sec: f64 = @as(f64, @floatFromInt(input_px_per_frame)) / draw_sec_avg / 1.0e9;
    const processed_gpx_per_sec: f64 = processed_px_avg / draw_sec_avg / 1.0e9;

    var p95_buf: [32]u8 = undefined;
    const p95_str = if (p95_avg) |p|
        std.fmt.bufPrint(&p95_buf, "{d:.2}", .{p}) catch "n/a"
    else
        std.fmt.bufPrint(&p95_buf, "n/a", .{}) catch "n/a";

    const moving_label = if (mode == .moving) " [approx, moving-only]" else "";
    const moving_note = if (mode == .moving)
        "  [note: moving mode — comparison-grade numbers require static mode]\n"
    else
        "";
    const dropped_note = if (dropped_total > 0)
        "  [note: dropped_frames > 0 — comparison-invalid; rerun on an idle system]\n"
    else
        "";

    std.debug.print(
        \\[bench:final] mode={s} sprites={d} build={s} platform={s}
        \\  draw_ms          avg={d:.3} min={d:.3} max={d:.3}
        \\  frame_ms         avg={d:.3} p95={s}
        \\  present_call_ms  avg={d:.3}
        \\  fps              avg={d:.1}
        \\  input≈{d:.2}Gpx/s   processed≈{d:.2}Gpx/s{s}
        \\  dropped_frames   total={d}
        \\{s}{s}
    , .{
        @tagName(mode),
        sprite_count,
        build_mode_name,
        build_options.platform_name,
        draw_avg,
        draw_min,
        draw_max,
        frame_avg,
        p95_str,
        present_avg,
        fps_avg,
        input_gpx_per_sec,
        processed_gpx_per_sec,
        moving_label,
        dropped_total,
        moving_note,
        dropped_note,
    });
}
